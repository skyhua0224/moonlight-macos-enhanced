// Protocol records: ds5-gcsman-bt-audio-20261107 §§2–3 and
// ds5-dongle-audio-20261107 §§3–4. Codec records:
// ds5-rfc6716-20261107 §§2.1.4, 2.1.8, 3.1 and ds5-opus-api-20261107.
// Apple OS facilities: apple-iohid-manager-20261107,
// apple-iohid-device-20261107, apple-corefoundation-runloop-20261107 and
// apple-xnu-mach-time-20261107 (mach_absolute_time/mach_timebase_info).

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hid/IOHIDKeys.h>
#include <IOKit/hid/IOHIDManager.h>
#include <mach/mach_time.h>
#include <opus/opus.h>

#include "../../Limelight/Input/DS5BluetoothPcm.h"
#include "../../core/interaction/ds5-core/include/alkaidlab/ds5_core/ds5_core.h"

#include <errno.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define DS5_VENDOR 0x054c
#define DS5_PRODUCT 0x0ce6
#define DS5_INPUT_BYTES 78u
#define DS5_CONTROL_BYTES 78u
#define DS5_AUDIO_BYTES 547u
#define DS5_AUDIO_PAYLOAD_BYTES 200u
#define DS5_AUDIO_FRAMES 480u
#define DS5_AUDIO_REPORT_FRAMES 1024u
#define DS5_AUDIO_RATE 48000u
#define DS5_REPORT_PERIOD_US 21333u
#define DS5_DEFAULT_SECONDS 30u
#define DS5_OUTPUT_QUEUE_CAPACITY 8u
#define DS5_AUDIO_JITTER_REPORTS 2u
#define DS5_HID_TIMEOUT_MS 500.0

typedef struct {
  int16_t *samples;
  size_t frames;
  uint32_t sample_rate;
  uint16_t channels;
} Pcm;

typedef enum {
  OUTPUT_CONTROL,
  OUTPUT_AUDIO,
} OutputKind;

typedef struct {
  uint8_t data[DS5_AUDIO_BYTES];
  size_t size;
  OutputKind kind;
  uint64_t deadline_us;
} OutputFrame;

typedef struct {
  IOHIDManagerRef manager;
  IOHIDDeviceRef device;
  uint8_t input_buffer[1024];
  uint8_t sequence;
  uint8_t audio_counter;
  bool headset;
  bool input_seen;
  unsigned reports;
  unsigned errors;
  unsigned input_reports;
  unsigned audio_reports;
  unsigned dropped_reports;
  unsigned underruns;
  uint64_t max_submit_us;
  uint64_t max_completion_us;
  uint64_t audio_deadline_us;
  OutputFrame output_queue[DS5_OUTPUT_QUEUE_CAPACITY];
  size_t output_head;
  size_t output_count;
  OutputFrame output_inflight;
  bool output_inflight_valid;
  uint64_t output_submit_started_us;
  uint64_t output_submit_us;
  uint64_t output_next_due_us;
  bool output_audio_started;
  bool playing;
} Player;

static uint64_t monotonic_us(void) {
  static mach_timebase_info_data_t timebase;
  static bool initialized;
  if (!initialized) {
    if (mach_timebase_info(&timebase) != KERN_SUCCESS || timebase.denom == 0u)
      return 0u;
    initialized = true;
  }
  return (uint64_t)(((__uint128_t)mach_absolute_time() * timebase.numer) /
                    ((__uint128_t)timebase.denom * 1000u));
}

static void make_control_report(Player *player,
                                uint8_t report[DS5_CONTROL_BYTES]);
static bool enqueue_report(Player *player, const uint8_t *report, size_t size,
                           OutputKind kind, uint64_t deadline_us);
static void output_pump(Player *player);
static void output_finish(Player *player, IOReturn result);

static uint16_t read_le16(const uint8_t *p) {
  return (uint16_t)p[0] | ((uint16_t)p[1] << 8u);
}
static uint32_t read_le32(const uint8_t *p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8u) | ((uint32_t)p[2] << 16u) |
         ((uint32_t)p[3] << 24u);
}
static uint16_t read_be16(const uint8_t *p) {
  return ((uint16_t)p[0] << 8u) | p[1];
}
static uint32_t read_be32(const uint8_t *p) {
  return ((uint32_t)p[0] << 24u) | ((uint32_t)p[1] << 16u) |
         ((uint32_t)p[2] << 8u) | p[3];
}
static uint64_t read_be64(const uint8_t *p) {
  uint64_t value = 0;
  for (unsigned i = 0; i < 8u; i++)
    value = (value << 8u) | p[i];
  return value;
}

static bool is_tag(const uint8_t *p, const char *tag) {
  return memcmp(p, tag, 4u) == 0;
}

static bool load_file(const char *path, uint8_t **data, size_t *size) {
  FILE *file = fopen(path, "rb");
  if (file == NULL)
    return false;
  if (fseek(file, 0, SEEK_END) != 0) {
    fclose(file);
    return false;
  }
  long length = ftell(file);
  if (length <= 0 || fseek(file, 0, SEEK_SET) != 0) {
    fclose(file);
    return false;
  }
  uint8_t *buffer = malloc((size_t)length);
  if (buffer == NULL ||
      fread(buffer, 1u, (size_t)length, file) != (size_t)length) {
    free(buffer);
    fclose(file);
    return false;
  }
  fclose(file);
  *data = buffer;
  *size = (size_t)length;
  return true;
}

static bool append_pcm(Pcm *pcm, const uint8_t *bytes, size_t frames,
                       uint16_t channels, bool big_endian) {
  if (channels == 0u || channels > 2u ||
      frames > SIZE_MAX / sizeof(int16_t) / 2u)
    return false;
  if (pcm->frames > SIZE_MAX - frames)
    return false;
  int16_t *result =
      realloc(pcm->samples, (pcm->frames + frames) * 2u * sizeof(int16_t));
  if (result == NULL)
    return false;
  pcm->samples = result;
  for (size_t frame = 0; frame < frames; frame++) {
    int16_t left = 0, right = 0;
    for (uint16_t channel = 0; channel < channels; channel++) {
      const uint8_t *sample = bytes + (frame * channels + channel) * 2u;
      int16_t value =
          big_endian ? (int16_t)read_be16(sample) : (int16_t)read_le16(sample);
      if (channel == 0u)
        left = value;
      if (channel == 1u)
        right = value;
    }
    if (channels == 1u)
      right = left;
    pcm->samples[(pcm->frames + frame) * 2u] = left;
    pcm->samples[(pcm->frames + frame) * 2u + 1u] = right;
  }
  pcm->frames += frames;
  return true;
}

static double read_extended_rate(const uint8_t *bytes) {
  uint16_t exponent = read_be16(bytes);
  uint64_t mantissa = read_be64(bytes + 2u);
  if (exponent == 0u || mantissa == 0u)
    return 0.0;
  int sign = (exponent & 0x8000u) != 0u ? -1 : 1;
  int power = (int)(exponent & 0x7fffu) - 16383;
  return sign * ldexp((double)mantissa / 9223372036854775808.0, power + 1);
}

static bool load_wav(const uint8_t *data, size_t size, Pcm *pcm) {
  if (size < 12u || !is_tag(data, "RIFF") || !is_tag(data + 8u, "WAVE"))
    return false;
  uint16_t channels = 0, bits = 0;
  uint32_t sample_rate = 0;
  const uint8_t *samples = NULL;
  size_t sample_bytes = 0;
  for (size_t offset = 12u; offset + 8u <= size;) {
    uint32_t chunk_size = read_le32(data + offset + 4u);
    size_t available = size - offset - 8u;
    if (chunk_size > available)
      return false;
    const uint8_t *chunk = data + offset + 8u;
    if (is_tag(data + offset, "fmt ") && chunk_size >= 16u) {
      if (read_le16(chunk) != 1u)
        return false;
      channels = read_le16(chunk + 2u);
      sample_rate = read_le32(chunk + 4u);
      bits = read_le16(chunk + 14u);
    } else if (is_tag(data + offset, "data")) {
      samples = chunk;
      sample_bytes = chunk_size;
    }
    size_t step = 8u + chunk_size + (chunk_size & 1u);
    if (step > size - offset)
      break;
    offset += step;
  }
  if (channels == 0u || sample_rate == 0u || bits != 16u || samples == NULL ||
      sample_bytes % ((size_t)channels * 2u) != 0u)
    return false;
  pcm->sample_rate = sample_rate;
  pcm->channels = channels;
  return append_pcm(pcm, samples, sample_bytes / ((size_t)channels * 2u),
                    channels, false);
}

static bool load_aiff(const uint8_t *data, size_t size, Pcm *pcm) {
  if (size < 12u || !is_tag(data, "FORM") ||
      (!is_tag(data + 8u, "AIFF") && !is_tag(data + 8u, "AIFC")))
    return false;
  uint16_t channels = 0, bits = 0;
  uint32_t sample_rate = 0;
  const uint8_t *samples = NULL;
  size_t sample_bytes = 0;
  for (size_t offset = 12u; offset + 8u <= size;) {
    uint32_t chunk_size = read_be32(data + offset + 4u);
    size_t available = size - offset - 8u;
    if (chunk_size > available)
      return false;
    const uint8_t *chunk = data + offset + 8u;
    if (is_tag(data + offset, "COMM") && chunk_size >= 18u) {
      channels = read_be16(chunk);
      bits = read_be16(chunk + 6u);
      double rate = read_extended_rate(chunk + 8u);
      if (rate < 1.0 || rate > 192000.0)
        return false;
      sample_rate = (uint32_t)llround(rate);
    } else if (is_tag(data + offset, "SSND") && chunk_size >= 8u) {
      uint32_t data_offset = read_be32(chunk);
      if (data_offset > chunk_size - 8u)
        return false;
      samples = chunk + 8u + data_offset;
      sample_bytes = chunk_size - 8u - data_offset;
    }
    size_t step = 8u + chunk_size + (chunk_size & 1u);
    if (step > size - offset)
      break;
    offset += step;
  }
  if (channels == 0u || sample_rate == 0u || bits != 16u || samples == NULL ||
      sample_bytes % ((size_t)channels * 2u) != 0u)
    return false;
  pcm->sample_rate = sample_rate;
  pcm->channels = channels;
  return append_pcm(pcm, samples, sample_bytes / ((size_t)channels * 2u),
                    channels, true);
}

static bool make_melody(Pcm *pcm, unsigned seconds) {
  const size_t frames = (size_t)seconds * DS5_AUDIO_RATE;
  pcm->samples = calloc(frames * 2u, sizeof(int16_t));
  if (pcm->samples == NULL)
    return false;
  pcm->frames = frames;
  pcm->sample_rate = DS5_AUDIO_RATE;
  pcm->channels = 2u;
  const double notes[] = {261.6256, 329.6276, 392.0,    523.2511,
                          392.0,    329.6276, 293.6648, 392.0};
  const size_t note_frames = DS5_AUDIO_RATE / 2u;
  for (size_t frame = 0; frame < frames; frame++) {
    double time = (double)frame / DS5_AUDIO_RATE;
    double note_time =
        fmod(time, (double)(sizeof(notes) / sizeof(notes[0])) * 0.5);
    size_t note =
        (size_t)(note_time / 0.5) % (sizeof(notes) / sizeof(notes[0]));
    double phase = 2.0 * 3.14159265358979323846 * notes[note] * time;
    double envelope = fmin(1.0, (double)(frame % note_frames) / 1200.0);
    envelope *=
        fmin(1.0, (double)(note_frames - (frame % note_frames)) / 2400.0);
    int16_t value = (int16_t)lrint(5000.0 * envelope *
                                   (sin(phase) + 0.25 * sin(2.0 * phase)));
    pcm->samples[frame * 2u] = value;
    pcm->samples[frame * 2u + 1u] = value;
  }
  return true;
}

static bool resample(Pcm *pcm) {
  if (pcm->sample_rate == DS5_AUDIO_RATE)
    return true;
  if (pcm->sample_rate == 0u || pcm->frames == 0u)
    return false;
  size_t output_frames =
      (size_t)llround((double)pcm->frames * DS5_AUDIO_RATE / pcm->sample_rate);
  int16_t *output = malloc(output_frames * 2u * sizeof(int16_t));
  if (output == NULL)
    return false;
  for (size_t out = 0; out < output_frames; out++) {
    double source = (double)out * pcm->sample_rate / DS5_AUDIO_RATE;
    size_t left = (size_t)source;
    size_t right = left + 1u < pcm->frames ? left + 1u : left;
    double fraction = source - left;
    for (unsigned channel = 0; channel < 2u; channel++) {
      double value = pcm->samples[left * 2u + channel] * (1.0 - fraction) +
                     pcm->samples[right * 2u + channel] * fraction;
      output[out * 2u + channel] = (int16_t)lrint(value);
    }
  }
  free(pcm->samples);
  pcm->samples = output;
  pcm->frames = output_frames;
  pcm->sample_rate = DS5_AUDIO_RATE;
  return true;
}

static void make_control_report(Player *player,
                                uint8_t report[DS5_CONTROL_BYTES]) {
  memset(report, 0, DS5_CONTROL_BYTES);
  report[0] = 0x31u;
  report[1] = (uint8_t)(((player->sequence++ & 0x0fu) << 4u) | 0x02u);
  report[2] = 0x10u;
  report[3] = 0xb0u;
  // Source ds5-gcsman-bt-audio-20261107 §§2 and 5: volume and output path
  // are state in 0x31, not fields in the 0x39 audio report. Keep both volume
  // values valid and let the path mute the inactive endpoint.
  report[7] = 0x58u; // headphone volume
  report[8] = 0x64u; // speaker volume
  report[9] = 0x20u;
  report[10] = (uint8_t)((player->headset ? 0u : 3u) << 4u);
  uint32_t crc = alk_ds5_crc32_seed(0xa2u, report, DS5_CONTROL_BYTES - 4u);
  for (unsigned i = 0; i < 4u; i++)
    report[DS5_CONTROL_BYTES - 4u + i] = (uint8_t)(crc >> (8u * i));
}

static void make_audio_report(Player *player, const uint8_t *first,
                              const uint8_t *second,
                              uint8_t report[DS5_AUDIO_BYTES]) {
  uint8_t haptics[DS5_BT_HAPTIC_BLOCK_BYTES * 2u] = {0};
  const uint8_t counter = (uint8_t)(player->audio_counter + 2u);
  player->audio_counter = counter;
  ds5_bt_pack_0x39(report, counter, player->headset ? 1 : 0, haptics, first, second);
  uint32_t crc = alk_ds5_crc32_seed(0xa2u, report, DS5_AUDIO_BYTES - 4u);
  for (unsigned i = 0; i < 4u; i++)
    report[DS5_AUDIO_BYTES - 4u + i] = (uint8_t)(crc >> (8u * i));
}

static const char *output_kind_name(OutputKind kind) {
  return kind == OUTPUT_AUDIO ? "audio-0x39" : "control";
}

static void drop_output_head(Player *player) {
  if (player->output_count == 0u)
    return;
  player->output_head = (player->output_head + 1u) % DS5_OUTPUT_QUEUE_CAPACITY;
  player->output_count--;
  player->dropped_reports++;
  player->underruns++;
}

static bool enqueue_report(Player *player, const uint8_t *report, size_t size,
                           OutputKind kind, uint64_t deadline_us) {
  if (player == NULL || player->device == NULL || report == NULL ||
      size == 0u || size > DS5_AUDIO_BYTES)
    return false;

  // A jack transition invalidates every queued audio frame encoded for the old
  // path. The in-flight report cannot be interrupted, so the new control state
  // is placed first and the next audio report follows it.
  if (kind == OUTPUT_CONTROL) {
    while (player->output_count != 0u)
      drop_output_head(player);
  } else if (player->output_count >= DS5_OUTPUT_QUEUE_CAPACITY) {
    // The oldest queued audio frame is already late. Keep the newest frame so
    // the bounded jitter buffer never grows latency without bound.
    drop_output_head(player);
  }

  const size_t index =
      (player->output_head + player->output_count) % DS5_OUTPUT_QUEUE_CAPACITY;
  OutputFrame *frame = &player->output_queue[index];
  memcpy(frame->data, report, size);
  frame->size = size;
  frame->kind = kind;
  frame->deadline_us = deadline_us;
  player->output_count++;
  output_pump(player);
  return true;
}

static void output_callback(void *context, IOReturn result, void *sender,
                            IOHIDReportType type, uint32_t report_id,
                            uint8_t *report, CFIndex report_length) {
  (void)sender;
  (void)type;
  (void)report_id;
  (void)report;
  (void)report_length;
  output_finish((Player *)context, result);
}

static void output_finish(Player *player, IOReturn result) {
  if (player == NULL || !player->output_inflight_valid)
    return;
  const uint64_t finished_us = monotonic_us();
  const uint64_t completion_us =
      finished_us >= player->output_submit_started_us
          ? finished_us - player->output_submit_started_us
          : 0u;
  if (completion_us > player->max_completion_us)
    player->max_completion_us = completion_us;
  const OutputFrame frame = player->output_inflight;
  player->output_inflight_valid = false;
  if (result != kIOReturnSuccess) {
    player->errors++;
    fprintf(stderr,
            "report kind=%s count=%u size=%zu id=0x%02x send_ms=%.3f "
            "complete_ms=%.3f error=0x%08x\n",
            output_kind_name(frame.kind), player->reports + 1u, frame.size,
            frame.data[0], (double)player->output_submit_us / 1000.0,
            (double)completion_us / 1000.0, (unsigned)result);
  } else {
    player->reports++;
    if (frame.kind == OUTPUT_AUDIO)
      player->audio_reports++;
    printf("report kind=%s count=%u size=%zu id=0x%02x send_ms=%.3f "
           "complete_ms=%.3f error=0x00000000\n",
           output_kind_name(frame.kind), player->reports, frame.size,
           frame.data[0], (double)player->output_submit_us / 1000.0,
           (double)completion_us / 1000.0);
    fflush(stdout);
  }
  output_pump(player);
}

static void output_pump(Player *player) {
  if (player == NULL || player->device == NULL || player->output_inflight_valid)
    return;
  while (player->output_count != 0u) {
    const uint64_t now_us = monotonic_us();
    OutputFrame *queued = &player->output_queue[player->output_head];
    if (queued->kind == OUTPUT_AUDIO) {
      if (!player->output_audio_started &&
          player->output_count < DS5_AUDIO_JITTER_REPORTS)
        return;
      player->output_audio_started = true;
      while (player->output_count > 1u &&
             queued->deadline_us + DS5_REPORT_PERIOD_US < now_us) {
        drop_output_head(player);
        queued = &player->output_queue[player->output_head];
      }
      if (queued->deadline_us > now_us)
        return;
    }
    if (player->output_next_due_us > now_us)
      return;

    player->output_inflight = *queued;
    player->output_head =
        (player->output_head + 1u) % DS5_OUTPUT_QUEUE_CAPACITY;
    player->output_count--;
    player->output_inflight_valid = true;
    player->output_submit_started_us = monotonic_us();
    player->output_next_due_us =
        player->output_submit_started_us + DS5_REPORT_PERIOD_US;
    const uint64_t call_started_us = player->output_submit_started_us;
    IOReturn result = IOHIDDeviceSetReportWithCallback(
        player->device, kIOHIDReportTypeOutput, player->output_inflight.data[0],
        player->output_inflight.data, (CFIndex)player->output_inflight.size,
        DS5_HID_TIMEOUT_MS, output_callback, player);
    const uint64_t call_finished_us = monotonic_us();
    const uint64_t submit_us = call_finished_us >= call_started_us
                                   ? call_finished_us - call_started_us
                                   : 0u;
    if (submit_us > player->max_submit_us)
      player->max_submit_us = submit_us;
    player->output_submit_us = submit_us;
    if (result != kIOReturnSuccess) {
      output_finish(player, result);
      continue;
    }
    return;
  }
}

static void drain_output(Player *player, uint64_t timeout_us) {
  const uint64_t deadline_us = monotonic_us() + timeout_us;
  while ((player->output_count != 0u || player->output_inflight_valid) &&
         monotonic_us() < deadline_us) {
    output_pump(player);
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.002, true);
  }
  while (player->output_count != 0u)
    drop_output_head(player);
}

static bool send_report(Player *player, const uint8_t *report, size_t size,
                        const char *kind) {
  const OutputKind output_kind =
      strcmp(kind, "audio-0x39") == 0 ? OUTPUT_AUDIO : OUTPUT_CONTROL;
  uint64_t deadline_us = 0u;
  if (output_kind == OUTPUT_AUDIO) {
    const uint64_t now_us = monotonic_us();
    if (player->audio_deadline_us == 0u)
      player->audio_deadline_us =
          now_us + DS5_AUDIO_JITTER_REPORTS * DS5_REPORT_PERIOD_US;
    else
      player->audio_deadline_us += DS5_REPORT_PERIOD_US;
    deadline_us = player->audio_deadline_us;
  }
  return enqueue_report(player, report, size, output_kind, deadline_us);
}

static void input_callback(void *context, IOReturn result, void *sender,
                           IOHIDReportType type, uint32_t report_id,
                           uint8_t *report, CFIndex length) {
  (void)result;
  (void)sender;
  (void)type;
  (void)report_id;
  Player *player = context;
  if (player == NULL || report == NULL || length != DS5_INPUT_BYTES ||
      report[0] != 0x31u)
    return;
  AlkDs5ExtendedInput input = {.struct_size = sizeof(input),
                               .abi = ALK_DS5_CORE_ABI_VERSION};
  if (alk_ds5_parse_bluetooth_input_report(report, (size_t)length, &input) ==
      ALK_DS5_OK) {
    const bool headset = input.jack.headset_present != 0u;
    const bool changed = player->input_seen && player->headset != headset;
    player->headset = headset;
    player->input_seen = true;
    player->input_reports++;
    if (changed && player->playing) {
      uint8_t control[DS5_CONTROL_BYTES];
      make_control_report(player, control);
      (void)enqueue_report(player, control, sizeof(control), OUTPUT_CONTROL,
                           0u);
      printf("jack route=%s control-refresh=1\n",
             player->headset ? "headset" : "speaker");
      fflush(stdout);
    }
  }
}

static bool bluetooth_device(IOHIDDeviceRef device) {
  CFTypeRef transport =
      IOHIDDeviceGetProperty(device, CFSTR(kIOHIDTransportKey));
  return transport != NULL && CFGetTypeID(transport) == CFStringGetTypeID() &&
         CFStringCompare((CFStringRef)transport, CFSTR("Bluetooth"),
                         kCFCompareCaseInsensitive) == kCFCompareEqualTo;
}

static void matched_callback(void *context, IOReturn result, void *sender,
                             IOHIDDeviceRef device) {
  (void)result;
  (void)sender;
  Player *player = context;
  if (player == NULL || player->device != NULL || !bluetooth_device(device))
    return;
  if (IOHIDDeviceOpen(device, kIOHIDOptionsTypeNone) != kIOReturnSuccess)
    return;
  player->device = (IOHIDDeviceRef)CFRetain(device);
  IOHIDDeviceRegisterInputReportCallback(device, player->input_buffer,
                                         sizeof(player->input_buffer),
                                         input_callback, player);
  printf("device transport=Bluetooth vid=0x%04x pid=0x%04x\n", DS5_VENDOR,
         DS5_PRODUCT);
  fflush(stdout);
}

static void removed_callback(void *context, IOReturn result, void *sender,
                             IOHIDDeviceRef device) {
  (void)result;
  (void)sender;
  Player *player = context;
  if (player != NULL && player->device == device)
    player->device = NULL;
}

static bool start_hid(Player *player) {
  player->manager =
      IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
  if (player->manager == NULL)
    return false;
  CFMutableDictionaryRef matching = CFDictionaryCreateMutable(
      kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks,
      &kCFTypeDictionaryValueCallBacks);
  if (matching == NULL)
    return false;
  int vendor = DS5_VENDOR, product = DS5_PRODUCT;
  CFNumberRef vendor_number =
      CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &vendor);
  CFNumberRef product_number =
      CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &product);
  CFDictionarySetValue(matching, CFSTR(kIOHIDVendorIDKey), vendor_number);
  CFDictionarySetValue(matching, CFSTR(kIOHIDProductIDKey), product_number);
  CFRelease(vendor_number);
  CFRelease(product_number);
  IOHIDManagerSetDeviceMatching(player->manager, matching);
  CFRelease(matching);
  IOHIDManagerRegisterDeviceMatchingCallback(player->manager, matched_callback,
                                             player);
  IOHIDManagerRegisterDeviceRemovalCallback(player->manager, removed_callback,
                                            player);
  IOHIDManagerScheduleWithRunLoop(player->manager, CFRunLoopGetCurrent(),
                                  kCFRunLoopDefaultMode);
  if (IOHIDManagerOpen(player->manager, kIOHIDOptionsTypeNone) !=
      kIOReturnSuccess)
    return false;
  return true;
}

static void stop_hid(Player *player) {
  if (player->device != NULL) {
    IOHIDDeviceClose(player->device, kIOHIDOptionsTypeNone);
    CFRelease(player->device);
    player->device = NULL;
  }
  if (player->manager != NULL) {
    IOHIDManagerUnscheduleFromRunLoop(player->manager, CFRunLoopGetCurrent(),
                                      kCFRunLoopDefaultMode);
    IOHIDManagerClose(player->manager, kIOHIDOptionsTypeNone);
    CFRelease(player->manager);
    player->manager = NULL;
  }
}

static bool wait_for_device(Player *player, unsigned milliseconds) {
  for (unsigned elapsed = 0; elapsed < milliseconds && player->device == NULL;
       elapsed += 10u)
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.010, true);
  return player->device != NULL;
}

static bool encode_frame(OpusEncoder *encoder, const int16_t *samples,
                         uint8_t output[DS5_AUDIO_PAYLOAD_BYTES]) {
  int encoded = opus_encode(encoder, samples, DS5_AUDIO_FRAMES, output,
                            DS5_AUDIO_PAYLOAD_BYTES);
  return encoded == (int)DS5_AUDIO_PAYLOAD_BYTES;
}

static int play(Player *player, const Pcm *pcm, unsigned seconds) {
  int error = OPUS_OK;
  OpusEncoder *encoder =
      opus_encoder_create(DS5_AUDIO_RATE, 2, OPUS_APPLICATION_AUDIO, &error);
  if (encoder == NULL || error != OPUS_OK)
    return 2;
  if (opus_encoder_ctl(encoder, OPUS_SET_EXPERT_FRAME_DURATION(
                                    OPUS_FRAMESIZE_10_MS)) != OPUS_OK ||
      opus_encoder_ctl(encoder, OPUS_SET_BITRATE(160000)) != OPUS_OK ||
      opus_encoder_ctl(encoder, OPUS_SET_VBR(0)) != OPUS_OK ||
      opus_encoder_ctl(encoder, OPUS_SET_COMPLEXITY(0)) != OPUS_OK) {
    opus_encoder_destroy(encoder);
    return 2;
  }
  const uint64_t play_started_us = monotonic_us();
  player->playing = true;
  uint8_t control[DS5_CONTROL_BYTES];
  make_control_report(player, control);
  if (!send_report(player, control, sizeof(control), "control")) {
    player->playing = false;
    opus_encoder_destroy(encoder);
    return 3;
  }
  size_t limit = (size_t)seconds * DS5_AUDIO_RATE;
  if (limit > pcm->frames)
    limit = pcm->frames;
  size_t cursor = 0;
  uint64_t next_deadline = monotonic_us();
  DS5BtPitch pitch;
  ds5_bt_pitch_reset(&pitch);
  while (cursor + DS5_AUDIO_REPORT_FRAMES <= limit && player->device != NULL &&
         player->errors == 0u) {
    int16_t pitched[DS5_AUDIO_FRAMES * 2u * 2u];
    uint8_t first[DS5_AUDIO_PAYLOAD_BYTES], second[DS5_AUDIO_PAYLOAD_BYTES],
        report[DS5_AUDIO_BYTES];
    ds5_bt_pitch_512_to_480(&pitch, pcm->samples + cursor * 2u, pitched);
    ds5_bt_pitch_512_to_480(&pitch, pcm->samples + (cursor + DS5_BT_PITCH_IN_FRAMES) * 2u,
                            pitched + DS5_AUDIO_FRAMES * 2u);
    if (!encode_frame(encoder, pitched, first) ||
        !encode_frame(encoder, pitched + DS5_AUDIO_FRAMES * 2u, second)) {
      fprintf(stderr, "opus encode failed at frame=%zu\n", cursor);
      player->errors++;
      break;
    }
    make_audio_report(player, first, second, report);
    if (!send_report(player, report, sizeof(report), "audio-0x39"))
      break;
    cursor += DS5_AUDIO_REPORT_FRAMES;
    next_deadline += DS5_REPORT_PERIOD_US;
    for (;;) {
      output_pump(player);
      uint64_t now = monotonic_us();
      if (now >= next_deadline)
        break;
      uint64_t wait = next_deadline - now;
      CFRunLoopRunInMode(kCFRunLoopDefaultMode,
                         fmin((double)wait / 1000000.0, 0.002), true);
    }
  }
  player->playing = false;
  drain_output(player, 2000000u);
  const uint64_t elapsed_us = monotonic_us() - play_started_us;
  const double elapsed_seconds = (double)elapsed_us / 1000000.0;
  const double audio_rate =
      elapsed_seconds > 0.0 ? (double)player->audio_reports / elapsed_seconds
                            : 0.0;
  opus_encoder_destroy(encoder);
  printf("summary reports=%u audio_reports=%u audio_rate=%.2f underruns=%u "
         "dropped=%u errors=%u input_reports=%u elapsed_s=%.3f "
         "max_submit_ms=%.3f max_complete_ms=%.3f variant=0x39/547 "
         "frames=%zu headset=%u\n",
         player->reports, player->audio_reports, audio_rate, player->underruns,
         player->dropped_reports, player->errors, player->input_reports,
         elapsed_seconds, (double)player->max_submit_us / 1000.0,
         (double)player->max_completion_us / 1000.0, cursor,
         player->headset ? 1u : 0u);
  return player->errors == 0u ? 0 : 3;
}

static void usage(const char *name) {
  fprintf(stderr, "usage: %s [WAV-or-AIFF] [--seconds N]\n", name);
}

int main(int argc, char **argv) {
  const char *path = NULL;
  unsigned seconds = DS5_DEFAULT_SECONDS;
  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--seconds") == 0 && i + 1 < argc) {
      seconds = (unsigned)strtoul(argv[++i], NULL, 10);
      if (seconds == 0u || seconds > 600u) {
        usage(argv[0]);
        return 64;
      }
    } else if (argv[i][0] == '-') {
      usage(argv[0]);
      return 64;
    } else if (path == NULL) {
      path = argv[i];
    } else {
      usage(argv[0]);
      return 64;
    }
  }
  Pcm pcm = {0};
  if (path == NULL) {
    if (!make_melody(&pcm, seconds))
      return 2;
    printf("source=synthesized-melody seconds=%u\n", seconds);
  } else {
    uint8_t *file = NULL;
    size_t size = 0;
    bool loaded = load_file(path, &file, &size) &&
                  (load_wav(file, size, &pcm) || load_aiff(file, size, &pcm));
    free(file);
    if (!loaded || !resample(&pcm)) {
      fprintf(stderr, "unsupported or unreadable 16-bit PCM WAV/AIFF: %s\n",
              path);
      free(pcm.samples);
      return 64;
    }
    printf("source=%s sample_rate=%u frames=%zu\n", path, pcm.sample_rate,
           pcm.frames);
  }
  Player player = {0};
  if (!start_hid(&player) || !wait_for_device(&player, 5000u)) {
    fprintf(stderr,
            "no Bluetooth DualSense (VID=0x%04x PID=0x%04x) is connected\n",
            DS5_VENDOR, DS5_PRODUCT);
    stop_hid(&player);
    free(pcm.samples);
    return 4;
  }
  printf("starting variant=0x39/547 after device check; headset route follows "
         "input reports\n");
  int result = play(&player, &pcm, seconds);
  stop_hid(&player);
  free(pcm.samples);
  return result;
}
