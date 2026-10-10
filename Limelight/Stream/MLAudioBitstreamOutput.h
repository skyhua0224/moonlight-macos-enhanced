//
//  MLAudioBitstreamOutput.h
//  Moonlight for macOS
//

#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>

NS_ASSUME_NONNULL_BEGIN

// Audio codec ids, the same values as AUDIO_CODEC_* / MLAudioStreamPlan.
typedef NS_ENUM(int, MLAudioBitstreamCodec) {
    MLAudioBitstreamCodecAc3 = 1,
    MLAudioBitstreamCodecEac3 = 2,
};

// Result of asking whether an output device can take a codec as a bitstream.
// Immutable; safe to read from any thread.
@interface MLAudioBitstreamSupport : NSObject
// An output stream of the device lists the matching encoded physical format
// (AC3: 'cac3' at 48 kHz, E-AC3: the 'cec3' carrier at 192 kHz, 16-bit
// little-endian stereo) and the device is alive.
@property(nonatomic, readonly) BOOL available;
@property(nonatomic, readonly) AudioDeviceID deviceID;
@property(nonatomic, readonly, copy) NSString *deviceName;
@property(nonatomic, readonly, copy) NSString *deviceUID;
@end

typedef NS_ENUM(NSInteger, MLAudioBitstreamEvent) {
    // The device disappeared or stopped being alive.
    MLAudioBitstreamEventDeviceLost = 1,
    // The system default output moved to another device.
    MLAudioBitstreamEventDefaultDeviceChanged,
    // Something else switched the stream away from the bitstream format.
    MLAudioBitstreamEventFormatChanged,
    // Another process took hog mode from us.
    MLAudioBitstreamEventHogLost,
};

typedef struct {
    uint64_t burstsEnqueued; // valid bursts built and queued (or collected, E-AC3)
    uint64_t burstsPlayed;   // queued bursts the device started to consume
    uint64_t pauseBursts;    // pause bursts emitted because nothing was queued
    uint64_t droppedBursts;  // bursts discarded to bound latency or because the queue was full
    uint64_t invalidFrames;  // frames the framer rejected
    uint32_t queuedBursts;   // currently waiting
} MLAudioBitstreamStats;

extern NSErrorDomain const MLAudioBitstreamErrorDomain;
// userInfo key of a start error: the OSStatus (NSNumber) of the CoreAudio call that failed, when there was one.
extern NSString * const MLAudioBitstreamErrorStatusKey;

// Sends raw AC3 / E-AC3 syncframes to an HDMI-class device untouched, in
// exclusive (hog) mode with the device switched to its encoded physical format.
//
// Threads:
//  * start / stop: any single control thread (the connection's setup and
//    teardown path). They serialize on an internal lock and never block on
//    the event queue, so stop may also be called from the event handler.
//  * enqueueFrame:length: and the stats getters: exactly one producer thread
//    (the audio decode thread) once start has returned YES.
//  * eventHandler runs on a private serial queue, never on the real-time
//    thread. It is called at most once per start. It should only decide to
//    fall back; this class does not recover by itself.
@interface MLAudioBitstreamOutput : NSObject

// Cheap and free of side effects (property reads only); also used by the
// settings page.
+ (MLAudioBitstreamSupport *)supportForCodec:(int)codec onDevice:(AudioDeviceID)device
    NS_SWIFT_NAME(support(forCodec:onDevice:));
+ (MLAudioBitstreamSupport *)supportForCodecOnDefaultDevice:(int)codec
    NS_SWIFT_NAME(supportOnDefaultDevice(forCodec:));

// A crash or kill while the device is in an encoded format can leave other
// apps without working PCM output. start persists the original format and
// stop clears it; this puts a leftover back. Call at launch and before a
// stream starts. No-op while an instance is running in this process.
+ (void)restoreLeftoverDeviceFormatIfNeeded;

// The user deliberately picked another default output device (the control center's Audio
// Output menu). Sessions running at that moment do not put the default back when they end.
+ (void)noteUserChoseDefaultOutputDevice;

// device == kAudioObjectUnknown selects the current default output device.
- (instancetype)initWithCodec:(int)codec device:(AudioDeviceID)device NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property(nonatomic, readonly) int codec;
@property(nonatomic, readonly) AudioDeviceID deviceID;
@property(nonatomic, readonly, copy) NSString *deviceName;
@property(nonatomic, readonly) BOOL running;
@property(atomic, copy, nullable) void (^eventHandler)(MLAudioBitstreamEvent event, NSString *detail);

// Takes hog mode, switches the stream to the encoded format, creates the
// IOProc and starts the device. On failure everything done so far is undone
// and the error names the failing step (it is also logged).
- (BOOL)start:(NSError **)error;
- (void)stop;

// Producer thread only. frame is one raw syncframe as the host sends it.
// Returns YES when the frame was valid (queued, collected into an E-AC3
// group, or dropped because the queue was full); NO when it was rejected.
- (BOOL)enqueueFrame:(const void *)frame length:(size_t)length;

- (MLAudioBitstreamStats)stats;
// Why the framer rejected the last invalid frame, for the periodic log line.
- (NSString *)lastInvalidReason;

@end

NS_ASSUME_NONNULL_END
