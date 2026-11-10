/* Debug generator for Bluetooth DualSense haptics.
 * Feeds the same 0x32 packer and output coalescer the client uses: one
 * 142-byte report in flight, 10.667 ms period, newest report only.
 * Speaker PCM is not sent. Compile on macOS; it does not change settings.
 */
#include "../../Limelight/Input/DS5BluetoothPcm.h"
#include "../../Limelight/Input/DS5OutputCoalescer.h"
#include "alkaidlab/ds5_core/ds5_core.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hid/IOHIDManager.h>

#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define DS5_VENDOR 0x054c
#define DS5_PRODUCT 0x0ce6
#define DS5_RUN_SECONDS 65.0
#define DS5_PERIOD_US 10667ull
#define DS5_SAMPLE_CAP 8192u

typedef struct Probe {
    IOHIDManagerRef manager;
    IOHIDDeviceRef device;
    DS5OutputCoalescer coal;
    pthread_mutex_t lock;
    uint8_t stamped[DS5_BT_REPORT_0x32_BYTES];
    uint8_t sequence;
    int sending;
    int max_inflight;
    uint64_t submit_us;
    double max_call_ms;
    unsigned started;
    unsigned completed;
    unsigned errors;
    unsigned samples;
    double complete_ms[DS5_SAMPLE_CAP];
    uint64_t run_start_us;
    uint64_t first_complete_us;
    uint64_t last_complete_us;
    DS5BtStream stream;
    uint64_t generated;
} Probe;

static uint64_t monotonic_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000ull + (uint64_t)ts.tv_nsec / 1000ull;
}

static double now_ms(void) { return (double)monotonic_us() / 1000.0; }

static int timing_logs(void) {
    const char *value = getenv("DS5_HID_TIMING");
    return value != NULL && value[0] != '\0' && value[0] != '0';
}

static void fill_haptics(Probe *probe, int16_t *frames, size_t count) {
    size_t index;
    for (index = 0; index < count; index++) {
        const double t = (double)(probe->generated + (uint64_t)index) / 48000.0;
        const double left = sin(2.0 * 3.14159265358979323846 * 140.0 * t);
        const double right = sin(2.0 * 3.14159265358979323846 * 90.0 * t);
        frames[index * 2u] = (int16_t)lrint(left * 14000.0);
        frames[index * 2u + 1u] = (int16_t)lrint(right * 14000.0);
    }
    probe->generated += (uint64_t)count;
}

static void pump(Probe *probe);

static void output_callback(void *context, IOReturn result, void *sender, IOHIDReportType type, uint32_t report_id,
                            uint8_t *report, CFIndex report_length) {
    Probe *probe = context;
    const uint64_t done = monotonic_us();
    double complete_ms;
    (void)sender;
    (void)type;
    (void)report_id;
    (void)report;
    (void)report_length;
    pthread_mutex_lock(&probe->lock);
    complete_ms = probe->submit_us == 0 ? 0.0 : (double)(done - probe->submit_us) / 1000.0;
    ds5_outc_complete(&probe->coal, now_ms(), result == kIOReturnSuccess);
    probe->sending = 0;
    if (result == kIOReturnSuccess) {
        if (probe->samples < DS5_SAMPLE_CAP) probe->complete_ms[probe->samples++] = complete_ms;
        probe->completed++;
        if (probe->first_complete_us == 0) probe->first_complete_us = done;
        probe->last_complete_us = done;
        if (timing_logs()) {
            printf("timing id=0x32 len=142 complete_ms=%.3f result=0x0\n", complete_ms);
            fflush(stdout);
        }
    } else {
        probe->errors++;
        fprintf(stderr, "complete error=0x%08x complete_ms=%.3f\n", (unsigned)result, complete_ms);
    }
    pthread_mutex_unlock(&probe->lock);
    pump(probe);
}
static void pump(Probe *probe) {
    uint8_t report[DS5_OUTC_CAPACITY];
    size_t length = 0;
    uint64_t key = 0;
    double wait = 0.0;
    DS5OutputStep step;
    IOReturn result;
    double call_ms;
    uint64_t call_started;
    pthread_mutex_lock(&probe->lock);
    if (probe->sending || probe->device == NULL) {
        pthread_mutex_unlock(&probe->lock);
        return;
    }
    step = ds5_outc_next(&probe->coal, now_ms(), report, &length, &key, &wait);
    if (step != DS5_OUTC_WRITE || length != DS5_BT_REPORT_0x32_BYTES || report[0] != 0x32u) {
        pthread_mutex_unlock(&probe->lock);
        return;
    }
    memcpy(probe->stamped, report, length);
    probe->stamped[1] = (uint8_t)((probe->sequence++ & 0x0fu) << 4u);
    {
        const uint32_t crc = alk_ds5_crc32_seed(0xa2u, probe->stamped, length - 4u);
        size_t index;
        for (index = 0; index < 4u; index++) probe->stamped[length - 4u + index] = (uint8_t)(crc >> (8u * index));
    }
    probe->sending = 1;
    probe->submit_us = monotonic_us();
    if ((int)probe->coal.audioInflight > probe->max_inflight) probe->max_inflight = (int)probe->coal.audioInflight;
    probe->started++;
    pthread_mutex_unlock(&probe->lock);

    call_started = monotonic_us();
    result = IOHIDDeviceSetReportWithCallback(probe->device, kIOHIDReportTypeOutput, probe->stamped[0], probe->stamped,
                                              (CFIndex)length, 500.0, output_callback, probe);
    call_ms = (double)(monotonic_us() - call_started) / 1000.0;
    pthread_mutex_lock(&probe->lock);
    if (call_ms > probe->max_call_ms) probe->max_call_ms = call_ms;
    pthread_mutex_unlock(&probe->lock);
    if (timing_logs()) {
        printf("timing id=0x32 len=%zu call_ms=%.3f submit=0x%08x\n", length, call_ms, (unsigned)result);
        fflush(stdout);
    }
    if (result != kIOReturnSuccess) {
        pthread_mutex_lock(&probe->lock);
        ds5_outc_complete(&probe->coal, now_ms(), false);
        probe->sending = 0;
        probe->errors++;
        pthread_mutex_unlock(&probe->lock);
        fprintf(stderr, "submit error=0x%08x call_ms=%.3f\n", (unsigned)result, call_ms);
    }
}

static int submit_period(Probe *probe) {
    int16_t chunk[256 * 2];
    DS5BtPeriod period;
    uint8_t report[DS5_BT_REPORT_0x32_BYTES];
    int produced = 0;
    int half;
    for (half = 0; half < 2; half++) {
        fill_haptics(probe, chunk, 256);
        if (ds5_bt_stream_push(&probe->stream, NULL, chunk, 256, &period) && period.kind == DS5_BT_PERIOD_HAPTICS) {
            ds5_bt_pack_0x32(report, 0, period.haptics);
            pthread_mutex_lock(&probe->lock);
            ds5_outc_submit(&probe->coal, 1, true, report, sizeof(report));
            pthread_mutex_unlock(&probe->lock);
            produced = 1;
        }
    }
    if (produced) pump(probe);
    return produced;
}

static int compare_double(const void *a, const void *b) {
    const double left = *(const double *)a;
    const double right = *(const double *)b;
    return (left > right) - (left < right);
}

static double percentile(double *values, unsigned count, double p) {
    double *copy;
    double result;
    unsigned index;
    if (count == 0) return 0.0;
    copy = malloc((size_t)count * sizeof(double));
    if (copy == NULL) return 0.0;
    memcpy(copy, values, (size_t)count * sizeof(double));
    qsort(copy, count, sizeof(double), compare_double);
    index = (unsigned)((p / 100.0) * (double)(count - 1u));
    result = copy[index];
    free(copy);
    return result;
}

static void print_summary(Probe *probe) {
    const double elapsed = probe->last_complete_us > probe->first_complete_us
                               ? (double)(probe->last_complete_us - probe->first_complete_us) / 1000000.0
                               : 0.0;
    const double rate = elapsed > 0.0 ? (double)(probe->completed > 0 ? probe->completed - 1u : 0u) / elapsed : 0.0;
    DS5OutputStats stats;
    unsigned i;
    unsigned buckets[8] = {0};
    pthread_mutex_lock(&probe->lock);
    stats = probe->coal.stats;
    pthread_mutex_unlock(&probe->lock);
    for (i = 0; i < probe->samples; i++) {
        const double value = probe->complete_ms[i];
        const int bucket = value < 0.5 ? 0 : value < 1.0 ? 1 : value < 2.0 ? 2 : value < 5.0 ? 3 : value < 10.0 ? 4
                                                                                          : value < 20.0   ? 5
                                                                                          : value < 50.0   ? 6
                                                                                                           : 7;
        buckets[bucket]++;
    }
    printf("summary seconds=%.3f started=%u completed=%u errors=%u max_inflight=%d\n", elapsed, probe->started,
           probe->completed, probe->errors, probe->max_inflight);
    printf("rate_hz=%.3f target_hz=93.750 ratio=%.4f dropped=%u written=%u\n", rate, rate / 93.75, stats.dropped, stats.written);
    printf("call_ms_max=%.3f\n", probe->max_call_ms);
    printf("complete_ms n=%u p50=%.3f p95=%.3f p99=%.3f max=%.3f\n", probe->samples, percentile(probe->complete_ms, probe->samples, 50.0),
           percentile(probe->complete_ms, probe->samples, 95.0), percentile(probe->complete_ms, probe->samples, 99.0),
           percentile(probe->complete_ms, probe->samples, 100.0));
    printf("histogram_ms <0.5=%u <1=%u <2=%u <5=%u <10=%u <20=%u <50=%u >=50=%u\n", buckets[0], buckets[1], buckets[2],
           buckets[3], buckets[4], buckets[5], buckets[6], buckets[7]);
    fflush(stdout);
}

static bool bluetooth_pad(IOHIDDeviceRef device) {
    CFTypeRef transport = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDTransportKey));
    CFTypeRef max_out = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDMaxOutputReportSizeKey));
    int max_value = 0;
    if (transport == NULL || CFGetTypeID(transport) != CFStringGetTypeID()) return false;
    if (CFStringCompare((CFStringRef)transport, CFSTR("Bluetooth"), kCFCompareCaseInsensitive) != kCFCompareEqualTo) return false;
    if (max_out != NULL && CFGetTypeID(max_out) == CFNumberGetTypeID()) CFNumberGetValue((CFNumberRef)max_out, kCFNumberIntType, &max_value);
    return max_value >= (int)DS5_BT_REPORT_0x32_BYTES;
}

static void matched_callback(void *context, IOReturn result, void *sender, IOHIDDeviceRef device) {
    Probe *probe = context;
    (void)result;
    (void)sender;
    if (probe->device != NULL || !bluetooth_pad(device)) return;
    if (IOHIDDeviceOpen(device, kIOHIDOptionsTypeNone) != kIOReturnSuccess) {
        fprintf(stderr, "open failed\n");
        return;
    }
    probe->device = (IOHIDDeviceRef)CFRetain(device);
    printf("device transport=Bluetooth vid=0x%04x pid=0x%04x report=0x32 bytes=%d\n", DS5_VENDOR, DS5_PRODUCT,
           DS5_BT_REPORT_0x32_BYTES);
    fflush(stdout);
}

static void removed_callback(void *context, IOReturn result, void *sender, IOHIDDeviceRef device) {
    Probe *probe = context;
    (void)result;
    (void)sender;
    if (probe->device == device) probe->device = NULL;
}

static int start_hid(Probe *probe) {
    CFMutableDictionaryRef matching;
    int vendor = DS5_VENDOR, product = DS5_PRODUCT;
    CFNumberRef vendor_number, product_number;
    probe->manager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    if (probe->manager == NULL) return 0;
    matching = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    vendor_number = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &vendor);
    product_number = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &product);
    CFDictionarySetValue(matching, CFSTR(kIOHIDVendorIDKey), vendor_number);
    CFDictionarySetValue(matching, CFSTR(kIOHIDProductIDKey), product_number);
    CFRelease(vendor_number);
    CFRelease(product_number);
    IOHIDManagerSetDeviceMatching(probe->manager, matching);
    CFRelease(matching);
    IOHIDManagerRegisterDeviceMatchingCallback(probe->manager, matched_callback, probe);
    IOHIDManagerRegisterDeviceRemovalCallback(probe->manager, removed_callback, probe);
    IOHIDManagerScheduleWithRunLoop(probe->manager, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    return IOHIDManagerOpen(probe->manager, kIOHIDOptionsTypeNone) == kIOReturnSuccess;
}

static void stop_hid(Probe *probe) {
    if (probe->device != NULL) {
        IOHIDDeviceClose(probe->device, kIOHIDOptionsTypeNone);
        CFRelease(probe->device);
        probe->device = NULL;
    }
    if (probe->manager != NULL) {
        IOHIDManagerUnscheduleFromRunLoop(probe->manager, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
        IOHIDManagerClose(probe->manager, kIOHIDOptionsTypeNone);
        CFRelease(probe->manager);
        probe->manager = NULL;
    }
}

int main(void) {
    Probe probe;
    uint64_t next_due;
    uint64_t progress;
    memset(&probe, 0, sizeof(probe));
    pthread_mutex_init(&probe.lock, NULL);
    ds5_outc_init(&probe.coal);
    ds5_bt_stream_reset(&probe.stream);
    if (!start_hid(&probe)) {
        fprintf(stderr, "hid manager failed\n");
        return 2;
    }
    {
        unsigned waited;
        for (waited = 0; waited < 2000u && probe.device == NULL; waited += 10u)
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.010, true);
    }
    if (probe.device == NULL) {
        fprintf(stderr, "no bluetooth dualsense\n");
        stop_hid(&probe);
        return 3;
    }
    probe.run_start_us = monotonic_us();
    next_due = probe.run_start_us;
    progress = probe.run_start_us;
    while ((double)(monotonic_us() - probe.run_start_us) / 1000000.0 < DS5_RUN_SECONDS && probe.device != NULL) {
        const uint64_t now = monotonic_us();
        if (now >= next_due) {
            submit_period(&probe);
            next_due += DS5_PERIOD_US;
            if (next_due + DS5_PERIOD_US < now) next_due = now;
        }
        if (now >= progress + 10000000ull) {
            printf("progress completed=%u errors=%u\n", probe.completed, probe.errors);
            fflush(stdout);
            progress = now;
        }
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.002, true);
        pump(&probe);
    }
    {
        const uint64_t deadline = monotonic_us() + 500000ull;
        while (probe.sending && monotonic_us() < deadline) {
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.002, true);
        }
    }
    print_summary(&probe);
    stop_hid(&probe);
    pthread_mutex_destroy(&probe.lock);
    return probe.errors == 0 && probe.completed > 0 && probe.max_inflight <= 1 ? 0 : 4;
}
