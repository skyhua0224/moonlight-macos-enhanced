#import "DS5RawHIDBridge.h"

#import <IOKit/hid/IOHIDKeys.h>
#import <IOKit/hid/IOHIDManager.h>
#import <IOKit/IOKitLib.h>
#include <stdatomic.h>
#include <stdlib.h>

#include "Limelight-internal.h"
#include "DS5OutputCoalescer.h"
#include "DS5BluetoothPolicy.h"

/* Apple IOHIDDevice.h (apple-iohid-device-20261107) documents SetReport as
 * blocking until the report is issued, and SetReportWithCallback as
 * asynchronous. The timeout argument is milliseconds. IOHIDManager.h requires
 * the manager dispatch queue before activation. The kernel still runs those
 * queued requests one synchronous setReport at a time
 * (apple-iohid-setreport-kernel-20261109), so Bluetooth audio is submitted
 * again on the 64/3000 s clock from this run loop without waiting for the
 * callback. DS5_HID_TIMING=1 logs queue, call and completion times. */
static const CFTimeInterval kDS5HIDReportTimeoutMilliseconds = 500.0;
static const CFTimeInterval kDS5HIDSlowCallSeconds = 0.050;

static void DS5OutputSourcePerform(void *info) { (void)info; }

@class DS5RawHIDBridge;

@interface DS5FeatureRead : NSObject {
@public
    uint8_t _report[ALK_DS5_FEATURE_FIRMWARE_BYTES];
    CFIndex _reportLength;
}
@property(nonatomic, strong) DS5RawHIDBridge *bridge;
@property(nonatomic, copy) NSString *identity;
@property(nonatomic, copy) DS5RawHIDFeatureHandler handler;
@property(nonatomic, assign) IOHIDDeviceRef device;
@property(nonatomic, assign) uint8_t reportID;
@property(nonatomic, assign) NSUInteger reportIndex;
@property(nonatomic, assign) CFIndex reportLength;
@property(nonatomic, assign) CFAbsoluteTime startedAt;
@end

@implementation DS5FeatureRead
- (void)dealloc {
    if (_device != NULL) CFRelease(_device);
}
@end

@interface DS5OutputWrite : NSObject
@property(nonatomic, strong) DS5RawHIDBridge *bridge;
@property(nonatomic, assign) IOHIDDeviceRef device;
@property(nonatomic, strong) NSData *data;
@property(nonatomic, assign) CFAbsoluteTime startedAt;
@property(nonatomic, assign) CFAbsoluteTime enqueuedAt;
@property(nonatomic, assign) uint32_t generation;
@end

@implementation DS5OutputWrite
- (void)dealloc {
    if (_device != NULL) CFRelease(_device);
}
@end

@interface DS5RawHIDBridge () {
    IOHIDManagerRef _manager;
    DS5RawHIDInputHandler _handler;
    DS5RawHIDFeatureHandler _featureHandler;
    NSMutableDictionary<NSString *, NSValue *> *_devices;
    NSMutableDictionary<NSString *, NSString *> *_deviceTransports;
    NSMutableSet<NSString *> *_featureIdentities;
    dispatch_queue_t _ioQueue;
    NSLock *_stateLock;
    // Output writes run on their own serial queue, never on _ioQueue, which delivers the input
    // reports. _outputLock guards the coalescer, the pending identity and the flags below, and is
    // never held across an IOKit call.
    dispatch_queue_t _outputQueue;
    NSLock *_outputLock;
    DS5OutputCoalescer _coalescer;
    NSString *_pendingIdentity;
    BOOL _drainScheduled;
    uint32_t _outputGeneration;
    _Atomic uint32_t _outputSequence;
    BOOL _stopping;
    CFRunLoopRef _outputRunLoop;
    NSThread *_outputThread;
    dispatch_semaphore_t _outputThreadReady;
    _Atomic int _outputThreadStop;
    BOOL _timingLogs;
}
@property(nonatomic, readwrite) BOOL hasDevice;
- (void)handleInputReport:(uint8_t *)report length:(CFIndex)length device:(IOHIDDeviceRef)device;
- (NSString *)identityForDevice:(IOHIDDeviceRef)device;
- (void)matchedDevice:(IOHIDDeviceRef)device;
- (void)removedDevice:(IOHIDDeviceRef)device;
- (void)startFeatureReadsForIdentity:(NSString *)identity device:(IOHIDDeviceRef)device;
- (void)startFeatureReadForIdentity:(NSString *)identity device:(IOHIDDeviceRef)device index:(NSUInteger)index;
- (void)finishFeatureRead:(DS5FeatureRead *)read result:(IOReturn)result reportLength:(CFIndex)reportLength;
- (void)drainOutput;
- (void)outputRunLoopMain;
- (void)scheduleAudioFollowUp;
- (void)finishOutputWrite:(DS5OutputWrite *)write result:(IOReturn)result;
@end

static double DS5NowMilliseconds(void) {
    return [NSProcessInfo processInfo].systemUptime * 1000.0;
}

static void DS5LogSlowHIDCall(NSString *operation, CFAbsoluteTime elapsed) {
    if (elapsed > kDS5HIDSlowCallSeconds) {
        Log(LOG_W, @"[ds5-hid] HID call %@ took %.1f ms", operation, elapsed * 1000.0);
    }
}

static void DS5RawHIDInput(void *context, IOReturn result, void *sender,
                           IOHIDReportType reportType, uint32_t reportId,
                           uint8_t *report, CFIndex reportLength) {
    (void)result;
    (void)reportType;
    (void)reportId;
    DS5RawHIDBridge *bridge = (__bridge DS5RawHIDBridge *)context;
    if (bridge == nil || report == NULL || reportLength <= 0) return;
    [bridge handleInputReport:report length:reportLength device:(IOHIDDeviceRef)sender];
}

static void DS5RawHIDMatched(void *context, IOReturn result, void *sender,
                             IOHIDDeviceRef device) {
    (void)result;
    (void)sender;
    DS5RawHIDBridge *bridge = (__bridge DS5RawHIDBridge *)context;
    if (bridge == nil || device == NULL) return;
    [bridge matchedDevice:device];
}

static void DS5RawHIDRemoved(void *context, IOReturn result, void *sender,
                             IOHIDDeviceRef device) {
    (void)result;
    (void)sender;
    DS5RawHIDBridge *bridge = (__bridge DS5RawHIDBridge *)context;
    if (bridge == nil) return;
    [bridge removedDevice:device];
}

static void DS5RawHIDFeatureReport(void *context, IOReturn result, void *sender,
                                   IOHIDReportType reportType, uint32_t reportId,
                                   uint8_t *report, CFIndex reportLength) {
    (void)sender;
    (void)reportType;
    (void)reportId;
    (void)report;
    DS5FeatureRead *read = CFBridgingRelease(context);
    [read.bridge finishFeatureRead:read result:result reportLength:reportLength];
}

static void DS5RawHIDOutputReport(void *context, IOReturn result, void *sender,
                                  IOHIDReportType reportType, uint32_t reportId,
                                  uint8_t *report, CFIndex reportLength) {
    (void)sender;
    (void)reportType;
    (void)reportId;
    (void)report;
    (void)reportLength;
    DS5OutputWrite *write = CFBridgingRelease(context);
    [write.bridge finishOutputWrite:write result:result];
}

@implementation DS5RawHIDBridge

- (void)handleInputReport:(uint8_t *)report length:(CFIndex)reportLength device:(IOHIDDeviceRef)device {
    [_stateLock lock];
    DS5RawHIDInputHandler handler = _handler;
    [_stateLock unlock];
    if (handler == nil) return;
    AlkDs5ExtendedInput input = {sizeof(input), ALK_DS5_CORE_ABI_VERSION};
    BOOL bluetooth = reportLength == ALK_DS5_BT_INPUT_REPORT_BYTES;
    AlkDs5Error error = bluetooth
        ? alk_ds5_parse_bluetooth_input_report(report, (size_t)reportLength, &input)
        : alk_ds5_parse_input_report_ex(report, (size_t)reportLength, &input);
    if (error == ALK_DS5_OK) handler([self identityForDevice:device] ?: @"unknown", &input, bluetooth);
}

- (NSString *)identityForDevice:(IOHIDDeviceRef)device {
    if (device == NULL) return nil;
    CFAbsoluteTime startedAt = CFAbsoluteTimeGetCurrent();
    CFTypeRef serial = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDSerialNumberKey));
    DS5LogSlowHIDCall(@"GetProperty(serial)", CFAbsoluteTimeGetCurrent() - startedAt);
    if (serial != NULL && CFGetTypeID(serial) == CFStringGetTypeID()) return (__bridge NSString *)serial;
    startedAt = CFAbsoluteTimeGetCurrent();
    CFTypeRef location = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDLocationIDKey));
    DS5LogSlowHIDCall(@"GetProperty(location)", CFAbsoluteTimeGetCurrent() - startedAt);
    if (location != NULL && CFGetTypeID(location) == CFNumberGetTypeID()) {
        int32_t value = 0;
        CFNumberGetValue((CFNumberRef)location, kCFNumberSInt32Type, &value);
        return [NSString stringWithFormat:@"location-%08x", (uint32_t)value];
    }
    return [NSString stringWithFormat:@"device-%p", device];
}

- (void)matchedDevice:(IOHIDDeviceRef)device {
    NSString *identity = [self identityForDevice:device];
    if (identity.length == 0) return;

    CFAbsoluteTime startedAt = CFAbsoluteTimeGetCurrent();
    CFTypeRef transportValue = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDTransportKey));
    DS5LogSlowHIDCall(@"GetProperty(transport)", CFAbsoluteTimeGetCurrent() - startedAt);
    NSString *transport = transportValue != NULL && CFGetTypeID(transportValue) == CFStringGetTypeID()
        ? [(__bridge NSString *)transportValue copy] : @"";
    IOHIDDeviceRef oldDevice = NULL;
    [_stateLock lock];
    if (_stopping) {
        [_stateLock unlock];
        return;
    }
    NSValue *oldValue = _devices[identity];
    oldDevice = oldValue != nil ? (IOHIDDeviceRef)[oldValue pointerValue] : NULL;
    _devices[identity] = [NSValue valueWithPointer:(const void *)CFRetain(device)];
    _deviceTransports[identity] = transport;
    BOOL hasDevice = _devices.count != 0;
    [_stateLock unlock];
    if (oldDevice != NULL) CFRelease(oldDevice);
    self.hasDevice = hasDevice;
    [self forgetLastOutputForIdentity:identity];
    [self startFeatureReadsForIdentity:identity device:device];
}

- (void)removedDevice:(IOHIDDeviceRef)device {
    NSString *identity = [self identityForDevice:device];
    if (identity.length == 0) return;
    IOHIDDeviceRef removed = NULL;
    [_stateLock lock];
    NSValue *value = _devices[identity];
    if (value != nil && [value pointerValue] == device) {
        removed = (IOHIDDeviceRef)[value pointerValue];
        [_devices removeObjectForKey:identity];
        [_deviceTransports removeObjectForKey:identity];
        [_featureIdentities removeObject:identity];
    }
    BOOL hasDevice = _devices.count != 0;
    [_stateLock unlock];
    if (removed != NULL) CFRelease(removed);
    self.hasDevice = hasDevice;
    [self forgetLastOutputForIdentity:identity];
}

// What was last written to a pad no longer holds once the pad is matched again or gone.
- (void)forgetLastOutputForIdentity:(NSString *)identity {
    if (_outputLock == nil) return;
    [_outputLock lock];
    ds5_outc_forget_last(&_coalescer, (uint64_t)identity.hash);
    [_outputLock unlock];
}

- (void)startFeatureReadsForIdentity:(NSString *)identity device:(IOHIDDeviceRef)device {
    if (identity.length == 0 || device == NULL) return;
    [_stateLock lock];
    if (_stopping || _featureHandler == nil || [_featureIdentities containsObject:identity]) {
        [_stateLock unlock];
        return;
    }
    [_featureIdentities addObject:identity];
    [_stateLock unlock];
    [self startFeatureReadForIdentity:identity device:device index:0];
}

- (void)startFeatureReadForIdentity:(NSString *)identity device:(IOHIDDeviceRef)device index:(NSUInteger)index {
    const uint8_t reportIDs[] = {
        ALK_DS5_FEATURE_CALIBRATION_ID, ALK_DS5_FEATURE_PAIRING_ID, ALK_DS5_FEATURE_FIRMWARE_ID
    };
    if (index >= sizeof(reportIDs) || device == NULL) return;
    size_t expected = 0;
    if (alk_ds5_feature_report_length(reportIDs[index], &expected) != ALK_DS5_OK ||
        expected > ALK_DS5_FEATURE_FIRMWARE_BYTES) {
        [_stateLock lock];
        [_featureIdentities removeObject:identity];
        [_stateLock unlock];
        return;
    }
    DS5FeatureRead *read = [DS5FeatureRead new];
    read.bridge = self;
    read.identity = identity;
    [_stateLock lock];
    read.handler = _featureHandler;
    [_stateLock unlock];
    read.device = (IOHIDDeviceRef)CFRetain(device);
    read.reportID = reportIDs[index];
    read.reportIndex = index;
    read.reportLength = (CFIndex)expected;
    read.startedAt = CFAbsoluteTimeGetCurrent();
    void *context = (__bridge_retained void *)read;
    CFAbsoluteTime startedAt = CFAbsoluteTimeGetCurrent();
    IOReturn result = IOHIDDeviceGetReportWithCallback(
        device, kIOHIDReportTypeFeature, read.reportID, read->_report, &read->_reportLength,
        kDS5HIDReportTimeoutMilliseconds, DS5RawHIDFeatureReport, context);
    DS5LogSlowHIDCall([NSString stringWithFormat:@"GetReportWithCallback(0x%02x)", read.reportID],
                      CFAbsoluteTimeGetCurrent() - startedAt);
    if (result != kIOReturnSuccess) {
        DS5FeatureRead *ownedRead = CFBridgingRelease(context);
        [self finishFeatureRead:ownedRead result:result reportLength:0];
    }
}

- (void)finishFeatureRead:(DS5FeatureRead *)read result:(IOReturn)result reportLength:(CFIndex)reportLength {
    if (read == nil) return;
    CFAbsoluteTime elapsed = CFAbsoluteTimeGetCurrent() - read.startedAt;
    DS5LogSlowHIDCall([NSString stringWithFormat:@"GetReport(0x%02x)", read.reportID], elapsed);
    if (elapsed >= kDS5HIDReportTimeoutMilliseconds / 1000.0 || result == kIOReturnTimeout) {
        Log(LOG_W, @"[ds5-hid] feature report 0x%02x timed out after %.1f ms; capability remains unknown",
            read.reportID, elapsed * 1000.0);
    } else if (result == kIOReturnSuccess && reportLength > 0 &&
               reportLength <= (CFIndex)sizeof(read->_report) && read.handler != nil) {
        read.handler(read.identity, read.reportID, read->_report, (size_t)reportLength);
    }

    NSUInteger nextIndex = read.reportIndex + 1;
    if (nextIndex < 3) {
        IOHIDDeviceRef current = NULL;
        [_stateLock lock];
        NSValue *value = _devices[read.identity];
        if (!_stopping && value != nil && [value pointerValue] == read.device) current = (IOHIDDeviceRef)[value pointerValue];
        [_stateLock unlock];
        if (current != NULL) {
            [self startFeatureReadForIdentity:read.identity device:current index:nextIndex];
            return;
        }
    }
    [_stateLock lock];
    [_featureIdentities removeObject:read.identity];
    [_stateLock unlock];
}

- (void)startWithInputHandler:(DS5RawHIDInputHandler)handler
               featureHandler:(DS5RawHIDFeatureHandler)featureHandler {
    [self stop];
    _handler = [handler copy];
    _featureHandler = [featureHandler copy];
    _stateLock = [[NSLock alloc] init];
    _outputLock = [[NSLock alloc] init];
    dispatch_queue_attr_t outputAttr = dispatch_queue_attr_make_with_qos_class(
        DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0);
    [_outputLock lock];
    ds5_outc_init(&_coalescer);
    _pendingIdentity = nil;
    _drainScheduled = NO;
    _outputGeneration++;
    _outputQueue = dispatch_queue_create("com.skyhua.moonlight.ds5-hid-output", outputAttr);
    [_outputLock unlock];
    _devices = [NSMutableDictionary dictionary];
    _deviceTransports = [NSMutableDictionary dictionary];
    _featureIdentities = [NSMutableSet set];
    _stopping = NO;
    atomic_store_explicit(&_outputThreadStop, 0, memory_order_release);
    const char *timing = getenv("DS5_HID_TIMING");
    _timingLogs = timing != NULL && timing[0] != '\0' && timing[0] != '0';
    _outputThreadReady = dispatch_semaphore_create(0);
    _outputThread = [[NSThread alloc] initWithTarget:self selector:@selector(outputRunLoopMain) object:nil];
    _outputThread.name = @"ds5-hid-output";
    _outputThread.qualityOfService = NSQualityOfServiceUserInteractive;
    [_outputThread start];
    dispatch_semaphore_wait(_outputThreadReady, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)));
    _ioQueue = dispatch_queue_create("com.skyhua.moonlight.ds5-hid-io", DISPATCH_QUEUE_SERIAL);
    __weak DS5RawHIDBridge *weakSelf = self;
    dispatch_async(_ioQueue, ^{
        DS5RawHIDBridge *strongSelf = weakSelf;
        if (strongSelf == nil) return;
        dispatch_queue_t ioQueue = strongSelf->_ioQueue;
        IOHIDManagerRef manager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
        if (manager == NULL) return;
        [strongSelf->_stateLock lock];
        BOOL stopping = strongSelf->_stopping;
        if (!stopping) strongSelf->_manager = manager;
        [strongSelf->_stateLock unlock];
        if (stopping) {
            CFRelease(manager);
            return;
        }
        NSArray *matches = @[
            @{(__bridge NSString *)CFSTR(kIOHIDVendorIDKey): @0x054c,
              (__bridge NSString *)CFSTR(kIOHIDProductIDKey): @0x0ce6,
              (__bridge NSString *)CFSTR(kIOHIDPrimaryUsagePageKey): @0x01,
              (__bridge NSString *)CFSTR(kIOHIDPrimaryUsageKey): @0x05},
            @{(__bridge NSString *)CFSTR(kIOHIDVendorIDKey): @0x054c,
              (__bridge NSString *)CFSTR(kIOHIDProductIDKey): @0x0df2,
              (__bridge NSString *)CFSTR(kIOHIDPrimaryUsagePageKey): @0x01,
              (__bridge NSString *)CFSTR(kIOHIDPrimaryUsageKey): @0x05}
        ];
        IOHIDManagerSetDeviceMatchingMultiple(manager, (__bridge CFArrayRef)matches);
        IOHIDManagerRegisterDeviceMatchingCallback(manager, DS5RawHIDMatched, (__bridge void *)strongSelf);
        IOHIDManagerRegisterDeviceRemovalCallback(manager, DS5RawHIDRemoved, (__bridge void *)strongSelf);
        IOHIDManagerRegisterInputReportCallback(manager, DS5RawHIDInput, (__bridge void *)strongSelf);
        IOHIDManagerSetDispatchQueue(manager, ioQueue);
        IOHIDManagerSetCancelHandler(manager, ^{
            (void)strongSelf;
            CFRelease(manager);
        });
        CFAbsoluteTime startedAt = CFAbsoluteTimeGetCurrent();
        IOReturn openResult = IOHIDManagerOpen(manager, kIOHIDOptionsTypeNone);
        DS5LogSlowHIDCall(@"ManagerOpen", CFAbsoluteTimeGetCurrent() - startedAt);
        if (openResult != kIOReturnSuccess) {
            Log(LOG_W, @"[ds5-hid] IOHIDManagerOpen failed: 0x%x", openResult);
        }
        startedAt = CFAbsoluteTimeGetCurrent();
        IOHIDManagerActivate(manager);
        DS5LogSlowHIDCall(@"ManagerActivate", CFAbsoluteTimeGetCurrent() - startedAt);
    });
}

- (void)stop {
    IOHIDManagerRef manager = NULL;
    dispatch_queue_t queue = _ioQueue;
    if (_stateLock != nil) {
        [_stateLock lock];
        _stopping = YES;
        manager = _manager;
        _manager = NULL;
        _handler = nil;
        _featureHandler = nil;
        [_stateLock unlock];
    }
    if (_outputLock != nil) {
        [_outputLock lock];
        ds5_outc_clear(&_coalescer);
        _pendingIdentity = nil;
        _outputGeneration++;
        _outputQueue = nil;
        [_outputLock unlock];
    }
    if (manager != NULL && queue != NULL) {
        dispatch_async(queue, ^{
            CFAbsoluteTime startedAt = CFAbsoluteTimeGetCurrent();
            IOHIDManagerCancel(manager);
            DS5LogSlowHIDCall(@"ManagerCancel", CFAbsoluteTimeGetCurrent() - startedAt);
        });
    }
    self.hasDevice = NO;
    if (_stateLock != nil) {
        [_stateLock lock];
        for (NSValue *value in _devices.allValues) {
            IOHIDDeviceRef device = (IOHIDDeviceRef)[value pointerValue];
            if (device != NULL) CFRelease(device);
        }
        [_devices removeAllObjects];
        [_deviceTransports removeAllObjects];
        [_featureIdentities removeAllObjects];
        [_stateLock unlock];
    }
    _manager = NULL;
    _ioQueue = NULL;
    atomic_store_explicit(&_outputThreadStop, 1, memory_order_release);
    CFRunLoopRef outputLoop = _outputRunLoop;
    if (outputLoop != NULL) CFRunLoopWakeUp(outputLoop);
    NSThread *outputThread = _outputThread;
    _outputThread = nil;
    if (outputThread != nil) {
        const CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + 1.0;
        while (!outputThread.isFinished && CFAbsoluteTimeGetCurrent() < deadline) usleep(2000);
    }
}

- (BOOL)isUSBDeviceForIdentity:(NSString *)identity {
    if (identity.length == 0 || _stateLock == nil) return NO;
    [_stateLock lock];
    NSString *transport = [_deviceTransports[identity] copy];
    BOOL present = _devices[identity] != nil;
    [_stateLock unlock];
    return present && [transport caseInsensitiveCompare:@"USB"] == NSOrderedSame;
}

- (BOOL)hasDeviceForIdentity:(NSString *)identity {
    if (identity.length == 0 || _stateLock == nil) return NO;
    [_stateLock lock];
    BOOL present = _devices[identity] != nil;
    [_stateLock unlock];
    return present;
}

- (NSString *)transportNameForIdentity:(NSString *)identity {
    if (identity.length == 0 || _stateLock == nil) return @"unknown";
    [_stateLock lock];
    NSString *transport = [_deviceTransports[identity] copy];
    BOOL present = _devices[identity] != nil;
    [_stateLock unlock];
    if (!present || transport.length == 0) return @"unknown";
    if ([transport caseInsensitiveCompare:@"USB"] == NSOrderedSame) return @"usb";
    if ([transport caseInsensitiveCompare:@"Bluetooth"] == NSOrderedSame) return @"bluetooth";
    return [transport lowercaseString];
}

+ (int)connectedPadLinkUsb:(int *)usbOut bluetooth:(int *)bluetoothOut other:(int *)otherOut {
    int usb = 0, bluetooth = 0, other = 0;
    BOOL failed = NO;
    const int products[2] = {0x0ce6, 0x0df2};
    for (int index = 0; index < 2 && !failed; index++) {
        CFMutableDictionaryRef match = IOServiceMatching(kIOHIDDeviceKey);
        if (match == NULL) { failed = YES; break; }
        int vendor = 0x054c;
        int product = products[index];
        int page = 0x01;
        int usage = 0x05;
        CFNumberRef vendorNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &vendor);
        CFNumberRef productNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &product);
        CFNumberRef pageNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &page);
        CFNumberRef usageNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &usage);
        if (vendorNum == NULL || productNum == NULL || pageNum == NULL || usageNum == NULL) {
            if (vendorNum) CFRelease(vendorNum);
            if (productNum) CFRelease(productNum);
            if (pageNum) CFRelease(pageNum);
            if (usageNum) CFRelease(usageNum);
            CFRelease(match);
            failed = YES;
            break;
        }
        CFDictionarySetValue(match, CFSTR(kIOHIDVendorIDKey), vendorNum);
        CFDictionarySetValue(match, CFSTR(kIOHIDProductIDKey), productNum);
        CFDictionarySetValue(match, CFSTR(kIOHIDPrimaryUsagePageKey), pageNum);
        CFDictionarySetValue(match, CFSTR(kIOHIDPrimaryUsageKey), usageNum);
        CFRelease(vendorNum);
        CFRelease(productNum);
        CFRelease(pageNum);
        CFRelease(usageNum);
        io_iterator_t iterator = IO_OBJECT_NULL;
        // IOServiceGetMatchingServices consumes match.
        kern_return_t result = IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator);
        if (result != KERN_SUCCESS) { failed = YES; break; }
        io_object_t device;
        while ((device = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
            CFTypeRef transport = IORegistryEntryCreateCFProperty(device, CFSTR(kIOHIDTransportKey), kCFAllocatorDefault, 0);
            if (transport != NULL && CFGetTypeID(transport) == CFStringGetTypeID()) {
                if (CFStringCompare((CFStringRef)transport, CFSTR("USB"), kCFCompareCaseInsensitive) == kCFCompareEqualTo) usb++;
                else if (CFStringCompare((CFStringRef)transport, CFSTR("Bluetooth"), kCFCompareCaseInsensitive) == kCFCompareEqualTo) bluetooth++;
                else other++;
            } else {
                other++;
            }
            if (transport != NULL) CFRelease(transport);
            IOObjectRelease(device);
        }
        IOObjectRelease(iterator);
    }
    if (usbOut != NULL) *usbOut = usb;
    if (bluetoothOut != NULL) *bluetoothOut = bluetooth;
    if (otherOut != NULL) *otherOut = other;
    if (failed) return DS5_LINK_UNKNOWN;
    if (usb > 0 && bluetooth > 0) return DS5_LINK_MIXED;
    if (bluetooth > 0) return DS5_LINK_BLUETOOTH;
    if (usb > 0) return DS5_LINK_USB;
    if (other > 0) return DS5_LINK_UNKNOWN;
    return DS5_LINK_NONE;
}

- (BOOL)submitReport:(const uint8_t *)report length:(size_t)length playerIdentity:(NSString *)identity bluetoothAudio:(BOOL)bluetoothAudio {
    if (report == NULL || identity.length == 0 || _stateLock == nil) return NO;
    [_stateLock lock];
    BOOL available = _devices[identity] != nil && !_stopping;
    NSString *transport = [_deviceTransports[identity] copy];
    [_stateLock unlock];
    const BOOL framedStream = length >= 334u || (length == 142u && report[0] == 0x32u);
    if (!available || (bluetoothAudio &&
                       ([transport caseInsensitiveCompare:@"Bluetooth"] != NSOrderedSame || !framedStream)) ||
        (!bluetoothAudio && length != ALK_DS5_USB_OUTPUT_REPORT_BYTES)) return NO;

    // Everything that is not known to be USB is paced like Bluetooth.
    const BOOL paced = [transport caseInsensitiveCompare:@"USB"] != NSOrderedSame;
    // The audio bytes of a USB output report, logged whenever they change: the valid flags that select the
    // volumes and the audio control (flag0 0x10 headphone volume, 0x20 speaker volume, 0x40 microphone volume,
    // 0x80 audio control; flag1 0x80 audio control 2), the three volumes, audio control (byte 8) and control 2 (byte 38).
    if (!bluetoothAudio && !paced && ((report[1] & 0xf0) != 0 || (report[2] & 0x80) != 0)) {
        static uint8_t last[8];
        const uint8_t now[8] = {(uint8_t)(report[1] & 0xf0), (uint8_t)(report[2] & 0x80), report[5], report[6], report[7], report[8], report[38], 1};
        if (memcmp(last, now, sizeof(now)) != 0) {
            memcpy(last, now, sizeof(now));
            Log(LOG_I, @"[ds5-output] USB audio bytes: flag0&0xf0=0x%02x flag1&0x80=0x%02x headphoneVolume=0x%02x speakerVolume=0x%02x micVolume=0x%02x audioControl(8)=0x%02x audioControl2(38)=0x%02x",
                now[0], now[1], now[2], now[3], now[4], now[5], now[6]);
        }
    }
    [_outputLock lock];
    const BOOL accepted = _outputQueue != nil &&
        ds5_outc_submit(&_coalescer, (uint64_t)identity.hash, paced, report, length);
    if (accepted) _pendingIdentity = [identity copy];
    const BOOL schedule = accepted && !_drainScheduled;
    if (schedule) _drainScheduled = YES;
    dispatch_queue_t queue = _outputQueue;
    [_outputLock unlock];
    if (schedule) dispatch_async(queue, ^{ [self drainOutput]; });
    return accepted;
}

- (BOOL)sendOutputReport:(const uint8_t *)report length:(size_t)length playerIdentity:(NSString *)identity {
    return [self submitReport:report length:length playerIdentity:identity bluetoothAudio:NO];
}

- (BOOL)sendBluetoothAudioReport:(const uint8_t *)report length:(size_t)length playerIdentity:(NSString *)identity {
    return [self submitReport:report length:length playerIdentity:identity bluetoothAudio:YES];
}

- (void)flushOutputWithTimeout:(NSTimeInterval)timeout {
    if (_outputLock == nil) return;
    const CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + timeout;
    for (;;) {
        [_outputLock lock];
        const BOOL busy = ds5_outc_busy(&_coalescer);
        [_outputLock unlock];
        if (!busy || CFAbsoluteTimeGetCurrent() >= deadline) break;
        usleep(2000);
    }
}

- (DS5OutputStats)takeOutputStats {
    DS5OutputStats stats;
    memset(&stats, 0, sizeof(stats));
    if (_outputLock == nil) return stats;
    [_outputLock lock];
    stats = ds5_outc_take_stats(&_coalescer);
    [_outputLock unlock];
    return stats;
}

// Runs on _outputQueue. Starts at most one write; the completion starts the next.
- (void)drainOutput {
    uint8_t report[DS5_OUTC_CAPACITY];
    size_t length = 0;
    uint64_t key = 0;
    double waitMs = 0.0;
    [_outputLock lock];
    _drainScheduled = NO;
    const DS5OutputStep step = ds5_outc_next(&_coalescer, DS5NowMilliseconds(), report, &length, &key, &waitMs);
    NSString *identity = step == DS5_OUTC_WRITE ? _pendingIdentity : nil;
    const uint32_t generation = _outputGeneration;
    const BOOL timer = step == DS5_OUTC_WAIT && waitMs > 0.0 && _outputQueue != nil;
    if (timer) _drainScheduled = YES;
    dispatch_queue_t queue = _outputQueue;
    [_outputLock unlock];
    if (timer) {
        // The wait ends with the pacing interval; a report that arrives meanwhile is merged into the pending one.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(waitMs * (double)NSEC_PER_MSEC) + 1000), queue,
                       ^{ [self drainOutput]; });
        return;
    }
    if (step != DS5_OUTC_WRITE) return;
    [self writeOutputReport:report length:length identity:identity generation:generation];
    [self scheduleAudioFollowUp];
}

- (void)outputRunLoopMain {
    @autoreleasepool {
        CFRunLoopSourceContext context = {0};
        context.perform = DS5OutputSourcePerform;
        CFRunLoopSourceRef source = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context);
        CFRunLoopRef loop = CFRunLoopGetCurrent();
        if (source != NULL) CFRunLoopAddSource(loop, source, kCFRunLoopDefaultMode);
        _outputRunLoop = loop;
        if (_outputThreadReady != NULL) dispatch_semaphore_signal(_outputThreadReady);
        while (atomic_load_explicit(&_outputThreadStop, memory_order_acquire) == 0) {
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.2, false);
        }
        if (source != NULL) {
            CFRunLoopRemoveSource(loop, source, kCFRunLoopDefaultMode);
            CFRelease(source);
        }
        if (_outputRunLoop == loop) _outputRunLoop = NULL;
    }
}

- (void)scheduleAudioFollowUp {
    [_outputLock lock];
    const double waitMs = ds5_outc_audio_wait_ms(&_coalescer, DS5NowMilliseconds());
    const BOOL audioWaiting = _coalescer.hasAudioLane && _coalescer.audioCount > 0 && _coalescer.audioInflight < ds5_outc_pcm_pipeline(&_coalescer);
    const BOOL timer = audioWaiting && waitMs > 0.0 && _outputQueue != nil && !_drainScheduled;
    if (timer) _drainScheduled = YES;
    dispatch_queue_t queue = _outputQueue;
    [_outputLock unlock];
    if (!timer || queue == nil) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(waitMs * (double)NSEC_PER_MSEC)), queue, ^{
        [self drainOutput];
    });
}

- (void)writeOutputReport:(const uint8_t *)report length:(size_t)length identity:(NSString *)identity
               generation:(uint32_t)generation {
    IOHIDDeviceRef device = NULL;
    [_stateLock lock];
    NSValue *value = _devices[identity];
    if (!_stopping && value != nil) device = (IOHIDDeviceRef)CFRetain([value pointerValue]);
    NSString *transport = [_deviceTransports[identity] copy];
    [_stateLock unlock];
    NSData *data = [NSData dataWithBytes:report length:length];
    BOOL usable = device != NULL;
    // Source ds5-gcsman-bt-audio-20261107 §§2-3: Bluetooth output uses the
    // 0xA2 CRC seed and the complete audio report is already framed here.
    if (usable && [transport caseInsensitiveCompare:@"Bluetooth"] == NSOrderedSame && (length >= 334u || (length == 142u && report[0] == 0x32u))) {
        uint8_t bluetoothAudioReport[DS5_OUTC_CAPACITY] = {0};
        if (length > sizeof(bluetoothAudioReport)) {
            usable = NO;
        } else {
            memcpy(bluetoothAudioReport, report, length);
            bluetoothAudioReport[1] = (uint8_t)((atomic_fetch_add_explicit(&_outputSequence, 1u, memory_order_relaxed) & 0x0fu) << 4u);
            const uint32_t crc = alk_ds5_crc32_seed(0xa2u, bluetoothAudioReport, length - 4u);
            for (size_t index = 0; index < 4u; index++) {
                bluetoothAudioReport[length - 4u + index] = (uint8_t)(crc >> (8u * index));
            }
            data = [NSData dataWithBytes:bluetoothAudioReport length:length];
        }
    } else if (usable && [transport caseInsensitiveCompare:@"Bluetooth"] == NSOrderedSame) {
        uint8_t bluetoothReport[ALK_DS5_BT_OUTPUT_REPORT_BYTES] = {0};
        size_t bluetoothLength = 0;
        if (alk_ds5_wrap_bluetooth_output_report(report, length, bluetoothReport,
                                                  sizeof(bluetoothReport), &bluetoothLength) != ALK_DS5_OK) {
            usable = NO;
        } else {
            // The firmware tracks the sequence nibble and the CRC covers it, so both are stamped per report.
            bluetoothReport[1] = (uint8_t)((atomic_fetch_add_explicit(&_outputSequence, 1u, memory_order_relaxed) & 0x0fu) << 4u);
            const uint32_t crc = alk_ds5_crc32_seed(0xa2u, bluetoothReport, bluetoothLength - 4u);
            for (size_t index = 0; index < 4u; index++) {
                bluetoothReport[bluetoothLength - 4u + index] = (uint8_t)(crc >> (8u * index));
            }
            data = [NSData dataWithBytes:bluetoothReport length:bluetoothLength];
        }
    }
    if (!usable) {
        if (device != NULL) CFRelease(device);
        [_outputLock lock];
        if (generation == _outputGeneration) ds5_outc_abort(&_coalescer);
        [_outputLock unlock];
        [self drainOutput];
        return;
    }
    DS5OutputWrite *write = [DS5OutputWrite new];
    write.bridge = self;
    write.device = device;
    write.data = data;
    write.generation = generation;
    write.enqueuedAt = CFAbsoluteTimeGetCurrent();
    write.startedAt = write.enqueuedAt;
    void *context = (__bridge_retained void *)write;
    __weak DS5RawHIDBridge *weakSelf = self;
    dispatch_block_t issue = ^{
        DS5RawHIDBridge *strongSelf = weakSelf;
        if (strongSelf == nil) {
            CFBridgingRelease(context);
            return;
        }
        [strongSelf->_outputLock lock];
        const BOOL live = write.generation == strongSelf->_outputGeneration;
        [strongSelf->_outputLock unlock];
        if (!live) {
            CFBridgingRelease(context);
            return;
        }
        const uint8_t reportId = ((const uint8_t *)write.data.bytes)[0];
        write.startedAt = CFAbsoluteTimeGetCurrent();
        const IOReturn result = IOHIDDeviceSetReportWithCallback(
            write.device, kIOHIDReportTypeOutput, reportId, write.data.bytes, (CFIndex)write.data.length,
            kDS5HIDReportTimeoutMilliseconds, DS5RawHIDOutputReport, context);
        const double callMs = (CFAbsoluteTimeGetCurrent() - write.startedAt) * 1000.0;
        DS5LogSlowHIDCall([NSString stringWithFormat:@"SetReportWithCallback(0x%02x)", reportId], callMs / 1000.0);
        if (strongSelf->_timingLogs) {
            Log(LOG_I, @"[ds5-hid] timing id=0x%02x len=%ld queue_ms=%.2f call_ms=%.2f",
                reportId, (long)write.data.length, (write.startedAt - write.enqueuedAt) * 1000.0, callMs);
        }
        if (result != kIOReturnSuccess) {
            DS5OutputWrite *ownedWrite = CFBridgingRelease(context);
            [strongSelf finishOutputWrite:ownedWrite result:result];
        }
    };
    CFRunLoopRef loop = _outputRunLoop;
    if (loop != NULL && atomic_load_explicit(&_outputThreadStop, memory_order_acquire) == 0) {
        CFRunLoopPerformBlock(loop, kCFRunLoopDefaultMode, issue);
        CFRunLoopWakeUp(loop);
    } else {
        issue();
    }
}

// Called from the HID callback on _ioQueue, or inline when the write could not be started. It only
// hands the completion to the output queue, so the input callbacks never run the next write.
- (void)finishOutputWrite:(DS5OutputWrite *)write result:(IOReturn)result {
    if (write == nil) return;
    CFAbsoluteTime elapsed = CFAbsoluteTimeGetCurrent() - write.startedAt;
    DS5LogSlowHIDCall(@"SetReport", elapsed);
    if (_timingLogs) {
        const uint8_t reportId = write.data.length > 0 ? ((const uint8_t *)write.data.bytes)[0] : 0;
        Log(LOG_I, @"[ds5-hid] timing id=0x%02x len=%ld complete_ms=%.2f result=0x%x",
            reportId, (long)write.data.length, elapsed * 1000.0, result);
    }
    if (result != kIOReturnSuccess) {
        Log(LOG_W, @"[ds5-hid] output report failed result=0x%x after %.1f ms", result, elapsed * 1000.0);
    }
    const double nowMs = DS5NowMilliseconds();
    const uint32_t generation = write.generation;
    const BOOL success = result == kIOReturnSuccess;
    [_outputLock lock];
    dispatch_queue_t queue = generation == _outputGeneration ? _outputQueue : nil;
    [_outputLock unlock];
    if (queue == nil) return;
    dispatch_async(queue, ^{
        [self->_outputLock lock];
        if (generation == self->_outputGeneration) ds5_outc_complete(&self->_coalescer, nowMs, success);
        [self->_outputLock unlock];
        [self drainOutput];
    });
}

- (void)dealloc {
    [self stop];
}

@end
