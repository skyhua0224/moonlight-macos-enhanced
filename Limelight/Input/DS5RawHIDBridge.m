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

