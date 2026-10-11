//
//  StreamConfiguration.h
//  Moonlight
//
//  Created by Diego Waxemberg on 10/20/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface StreamConfiguration : NSObject

@property(nonatomic, copy) NSString *host;
@property(nonatomic, copy) NSString *appVersion;
@property(nonatomic, copy) NSString *gfeVersion;
@property(nonatomic, copy) NSString *appID;
@property(nonatomic, copy) NSString *appName;
@property(nonatomic) int width;
@property(nonatomic) int height;
@property(nonatomic) int frameRate;
@property(nonatomic) int bitRate;
@property(nonatomic) BOOL autoAdjustBitrate;
// Foundation Sunshine only: probe bandwidth before launch and let the host adapt the bitrate.
@property(nonatomic) BOOL enableAdaptiveBitrate;
// Set by the pre-stream probe; 0 when no usable measurement exists.
@property(nonatomic) int probedBitrateCeilingKbps;
@property(nonatomic) int riKeyId;
@property(nonatomic) BOOL streamingRemotely;
@property(nonatomic, copy) NSData *riKey;
@property(nonatomic) int gamepadMask;
@property(nonatomic) BOOL optimizeGameSettings;
@property(nonatomic) BOOL playAudioOnPC;
@property(nonatomic) int audioConfiguration;
/// Audio codec the user asked for (AUDIO_CODEC_*: 0 Opus, 1 AC3, 2 E-AC3, 3 PCM),
/// already reduced to Opus where the channel layout or an earlier failure rules it
/// out. The connection still falls back to Opus when the host is not Foundation Sunshine.
@property(nonatomic) int audioCodec;
/// Ask the host to keep sending (silent) audio while nothing plays.
@property(nonatomic) BOOL continuousAudio;
/// Audio bandwidth on top of what the host already reserves from the video bitrate (kbps).
@property(nonatomic) int audioExcessBitrateKbps;
@property(nonatomic) BOOL disableHighQualitySurround;
@property(nonatomic) int audioOutputMode;
@property(nonatomic) int enhancedAudioOutputTarget;
@property(nonatomic) int enhancedAudioPreset;
@property(nonatomic) CGFloat enhancedAudioSpatialIntensity;
@property(nonatomic) CGFloat enhancedAudioSoundstageWidth;
@property(nonatomic) CGFloat enhancedAudioReverbAmount;
// The equalizer as the settings resolved it: "enabled", "preamp" (dB), "autoHeadroom" and
// "bands" (dictionaries of "type" (AVAudioUnitEQFilterType), "frequency", "gain" and "q").
@property(nonatomic, copy) NSDictionary *enhancedAudioEQState;
// 0: binaural for headphones on surround streams, widened stereo otherwise; 1: always widened
// stereo; 2: plain downmix.
@property(nonatomic) int enhancedAudioSpatialMode;
@property(nonatomic) BOOL enableHdr;
@property(nonatomic) BOOL enable10BitSdr;
@property(nonatomic) int videoRendererMode;
@property(nonatomic) int hdrTransferFunction;
@property(nonatomic) int hdrMetadataSource;
@property(nonatomic) int hdrClientDisplayProfile;
@property(nonatomic) CGFloat hdrManualMaxBrightness;
@property(nonatomic) CGFloat hdrManualMinBrightness;
@property(nonatomic) CGFloat hdrManualMaxAverageBrightness;
@property(nonatomic) CGFloat hdrOpticalOutputScale;
@property(nonatomic) int hdrHlgViewingEnvironment;
@property(nonatomic) int hdrEdrStrategy;
@property(nonatomic) int hdrToneMappingPolicy;
@property(nonatomic) int dynamicHdrCaps;
@property(nonatomic) int dolbyVisionDirectSurface;
@property(nonatomic) int dynamicHdrPreference;
// Session chroma decision (StreamChromaDecision), resolved once by the stream
// start path. enableYuv444 is what this session requests from the host;
// requestedYuv444 is the stored setting. suppressDolbyVision withholds the
// Dolby Vision capability bits (Automatic keeps 4:4:4).
@property(nonatomic) BOOL enableYuv444;
@property(nonatomic) BOOL requestedYuv444;
@property(nonatomic) BOOL suppressDolbyVision;
@property(nonatomic, copy) NSString *sunshineTargetDisplayName;
@property(nonatomic) BOOL sunshineUseVirtualDisplay;
@property(nonatomic) int sunshineScreenMode;
@property(nonatomic) BOOL sunshineTouchKeyboardAutoInvoke;
@property(nonatomic) BOOL sunshineHdrBrightnessOverride;
@property(nonatomic) CGFloat sunshineMaxBrightness;
@property(nonatomic) CGFloat sunshineMinBrightness;
@property(nonatomic) CGFloat sunshineMaxAverageBrightness;
// Display luminance estimated from the target screen's EDR capability. Only
// sent when HDR is on and the manual override above is off.
// CGDirectDisplayID of the screen showing the stream window; 0 when unknown.
@property(nonatomic) unsigned int hdrTargetDisplayID;
@property(nonatomic) BOOL hdrAutoLuminanceAvailable;
@property(nonatomic) CGFloat hdrAutoMaxBrightness;
@property(nonatomic) CGFloat hdrAutoMinBrightness;
@property(nonatomic) CGFloat hdrAutoMaxAverageBrightness;
@property(nonatomic) BOOL enableVsync;
@property(nonatomic) int framePacingMode;
@property(nonatomic) int smoothnessLatencyMode;
@property(nonatomic) int timingBufferLevel;
@property(nonatomic) BOOL timingPrioritizeResponsiveness;
@property(nonatomic) int displaySyncMode;
@property(nonatomic) int frameQueueTarget;
// RS FEC preference: -2 host default, -1 automatic, 0...100 fixed percentage.
// Only takes effect when the host advertises FEC control.
@property(nonatomic) int videoFecPercentage;
@property(nonatomic) int timingResponsivenessBias;
@property(nonatomic) int allowDrawableTimeoutMode;
@property(nonatomic) BOOL timingCompatibilityMode;
@property(nonatomic) BOOL timingSdrCompatibilityWorkaround;
@property(nonatomic) BOOL showPerformanceOverlay;
@property(nonatomic) BOOL multiController;
@property(nonatomic) BOOL allowHevc;
@property(nonatomic) int videoCodecPreference;
@property(nonatomic, copy) NSData *serverCert;
/// The host is a Foundation Sunshine build (reports Foundation-only serverinfo tags).
@property(nonatomic) BOOL foundationHost;
/// Ask the host for remote text context updates (caret position for the local input method).
@property(nonatomic) BOOL wantsRemoteTextContext;
@property(nonatomic) int serverCodecModeSupport;
@property(nonatomic, copy) NSString *sessionUrl;
@property(nonatomic, copy) NSString *hostUUID;
/// Client-declared Foundation controller type. Empty uses the standard arrival path.
@property(nonatomic, copy) NSString *clientGamepad;
@property(nonatomic) BOOL gamepadMouseMode;
@property(nonatomic) BOOL gamepadMouseModeLongPressMenu;
@property(nonatomic) BOOL nativeTouchpad;
// Send the DualSense touchpad to the host as a Windows precision touchpad.
@property(nonatomic) BOOL dualSensePrecisionTouchpad;
@property(nonatomic) CGFloat gamepadTrackpadPointerSensitivity;
@property(nonatomic) CGFloat gamepadTrackpadScrollSpeed;
@property(nonatomic) BOOL gamepadTrackpadReverseScroll;
@property(nonatomic) CGFloat gamepadDeadzone;
@property(nonatomic) NSInteger controllerHapticsMode;
@property(nonatomic) NSInteger controllerMotionMode;
@property(nonatomic) NSInteger controllerFeedbackTarget;
@property(nonatomic) NSInteger controllerVirtualType;
@property(nonatomic) CGFloat controllerLeftCenterX;
@property(nonatomic) CGFloat controllerLeftCenterY;
@property(nonatomic) CGFloat controllerRightCenterX;
@property(nonatomic) CGFloat controllerRightCenterY;
@property(nonatomic) CGFloat controllerLeftGain;
@property(nonatomic) CGFloat controllerRightGain;
@property(nonatomic) int upscalingMode;
@property(nonatomic) int frameInterpolationMode;

// Startup timeline for the "[startup] first frame" summary, as LiGetMillis() values; 0 = not
// reached. Each mark is written once, by the stage that owns it, on that stage's thread.
/// The stream view started preparing this stream (the user's click, as far as the client sees it).
@property(nonatomic) uint64_t startupBeginMs;
/// The launch/resume request was about to go out / the host answered it.
@property(nonatomic) uint64_t startupRequestMs;
@property(nonatomic) uint64_t startupReplyMs;
/// The protocol library was started (RTSP handshake begins).
@property(nonatomic) uint64_t startupConnectMs;

@end
