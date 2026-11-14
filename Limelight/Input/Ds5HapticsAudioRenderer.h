// GPL application adapter: this interface depends on the common-c frame type.
// The Core Audio API underneath does not remove that integration dependency.
#import <Foundation/Foundation.h>

#include "Limelight.h"
#include "../../core/interaction/ds5-core/include/alkaidlab/ds5_core/ds5_core.h"

NS_ASSUME_NONNULL_BEGIN

/// Sends Foundation's authored DualSense PCM to the controller's native
/// four-channel Core Audio output endpoint when macOS exposes one.
///
/// Game Controller's public haptics API remains the fallback. This class does
/// not claim success unless a real DualSense endpoint was found and the frame
/// was accepted by its AudioQueue.
@interface Ds5HapticsAudioRenderer : NSObject

/// Looks for the endpoint in the background, now and whenever the audio device list changes.
/// Call early (at launch): +hasPhysicalEndpoint answers from the last lookup.
+ (void)startWatchingPhysicalEndpoint;
/// Never touches CoreAudio; NO until the first lookup has finished.
+ (BOOL)hasPhysicalEndpoint;
/// Whether haptics of a pad on USB go through the pad's four-channel audio endpoint (raw PCM) instead of the analysed
/// frames played with Core Haptics, which work on USB and Bluetooth alike. Off unless `ds5UsbPcmHaptics` or
/// `ds5PadAudioOffer` is set: on this Mac the audio endpoint of a pad on USB took the samples and the actuators stayed
/// silent, while the Core Haptics path was verified on USB.
+ (BOOL)usbPcmRequested;
- (BOOL)drainCoreAudio:(AlkDs5Core *)core;
- (void)reset;

/// True while the pad's output path is the headset (the device's channels 1 and 2 are left and right), false while it is the speaker. The
/// mixdown for each route is in DS5PadMix.h.
@property(nonatomic) BOOL headsetRoute;
/// Puts the macOS volume and mute of the pad's device back as `prepareDeviceForPadAudio` found them. Called when the stream ends.
- (void)restoreDeviceState;
/// Whether a stream with a pad on USB plays the host's speaker pair on the pad ("pad-speaker": IR haptics plus a speaker-only PCM
/// packet). On unless the defaults key `ds5PadAudioOffer` is set to NO.
+ (BOOL)padSpeakerEnabled;
/// Plays `frames` frames (at most 480) of a stereo speaker pair and a stereo haptics pair, for the self test.
- (BOOL)playSpeaker:(const int16_t *)speaker haptics:(const int16_t *)haptics frames:(UInt16)frames;
/// Logs what macOS says about the pad's output device (volume and mute per channel, formats, channel layout) and
/// raises a volume or mute that macOS applies to it to unity. Returns whether the endpoint is open.
- (BOOL)prepareDeviceForPadAudio;

@end

NS_ASSUME_NONNULL_END
