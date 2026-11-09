#import <Foundation/Foundation.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

@class DS5RawHIDBridge;

/// Bluetooth DualSense haptics. Speaker PCM is not sent on this path: a
/// 547-byte report does not complete often enough, so the pad speaker stays
/// on USB. Haptic PCM is packed into one 142-byte 0x32 report. The HID writer
/// keeps a single report in flight and replaces a late one with the newest.
@interface Ds5BluetoothAudioRenderer : NSObject

- (instancetype)initWithBridge:(DS5RawHIDBridge *)bridge;
- (BOOL)enqueueSpeaker:(const int16_t * _Nullable)speaker
               haptics:(const int16_t * _Nullable)haptics
                frames:(UInt16)frames
       playerIdentity:(NSString *)identity
         headsetRoute:(BOOL)headsetRoute
               player:(NSUInteger)player;
- (void)resetPlayer:(NSUInteger)player;
- (void)reset;

@end

NS_ASSUME_NONNULL_END
