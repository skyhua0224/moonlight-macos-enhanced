#import <Foundation/Foundation.h>

#include "../../core/interaction/ds5-core/include/alkaidlab/ds5_core/ds5_core.h"
#include "DS5OutputCoalescer.h"

typedef void (^DS5RawHIDInputHandler)(NSString *identity, const AlkDs5ExtendedInput *input, BOOL bluetooth);
typedef void (^DS5RawHIDFeatureHandler)(NSString *identity, uint8_t reportID, const uint8_t *report, size_t length);

@interface DS5RawHIDBridge : NSObject
- (void)startWithInputHandler:(DS5RawHIDInputHandler)handler
               featureHandler:(DS5RawHIDFeatureHandler)featureHandler;
- (void)stop;
// YES unless the device is known to be on USB. Audio output fields of the output report are written
// to a USB pad only: no Bluetooth audio path of the pad is known to work, and an unknown transport is
// treated like Bluetooth.
- (BOOL)isUSBDeviceForIdentity:(NSString *)identity;
// YES while a raw device for that identity is attached.
- (BOOL)hasDeviceForIdentity:(NSString *)identity;
// "usb", "bluetooth" or "unknown" (no raw device for that identity), for the diagnostics.
- (NSString *)transportNameForIdentity:(NSString *)identity;
// Snapshot of attached DualSense gamepads (vendor 0x054c, product 0x0ce6 or 0x0df2,
// usage page 1 usage 5). Returns DS5_LINK_* from DS5BluetoothPolicy.h. Counts may be NULL.
+ (int)connectedPadLinkUsb:(int *)usb bluetooth:(int *)bluetooth other:(int *)other;
// Hands a report to the output queue and returns at once; it never waits for the write. Pending
// reports are merged, and a Bluetooth pad is written at most every 30 ms (DS5OutputCoalescer.h).
- (BOOL)sendOutputReport:(const uint8_t *)report length:(size_t)length playerIdentity:(NSString *)identity;
// Sends a complete Bluetooth audio HID report. The bridge stamps its sequence
// nibble and CRC immediately before IOHID writes it; the caller supplies only
// the report layout and encoded payload.
- (BOOL)sendBluetoothAudioReport:(const uint8_t *)report length:(size_t)length playerIdentity:(NSString *)identity;
// Waits until every queued output report has been written (or the timeout passes). Called before stop, which drops what is queued.
- (void)flushOutputWithTimeout:(NSTimeInterval)timeout;
// The output counters since the last call, for the [ds5-diag] line.
- (DS5OutputStats)takeOutputStats;
@property(nonatomic, readonly) BOOL hasDevice;
@end
