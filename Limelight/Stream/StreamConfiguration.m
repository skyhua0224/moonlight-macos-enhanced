//
//  StreamConfiguration.m
//  Moonlight
//
//  Created by Diego Waxemberg on 10/20/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "StreamConfiguration.h"

@implementation StreamConfiguration
@synthesize host, appVersion, gfeVersion, appID, appName, width, height, frameRate, bitRate, autoAdjustBitrate, enableAdaptiveBitrate, probedBitrateCeilingKbps, riKeyId, riKey, gamepadMask, streamingRemotely, optimizeGameSettings, playAudioOnPC, audioConfiguration, disableHighQualitySurround, audioOutputMode, enhancedAudioOutputTarget, enhancedAudioPreset, enhancedAudioSpatialIntensity, enhancedAudioSoundstageWidth, enhancedAudioReverbAmount, enhancedAudioEQGains, enableHdr, enable10BitSdr, videoRendererMode, hdrTransferFunction, hdrMetadataSource, hdrClientDisplayProfile, hdrManualMaxBrightness, hdrManualMinBrightness, hdrManualMaxAverageBrightness, hdrOpticalOutputScale, hdrHlgViewingEnvironment, hdrEdrStrategy, hdrToneMappingPolicy, dynamicHdrCaps, dolbyVisionDirectSurface, dynamicHdrPreference, sunshineTargetDisplayName, sunshineUseVirtualDisplay, sunshineScreenMode, sunshineTouchKeyboardAutoInvoke, sunshineHdrBrightnessOverride, sunshineMaxBrightness, sunshineMinBrightness, sunshineMaxAverageBrightness, hdrAutoLuminanceAvailable, hdrAutoMaxBrightness, hdrAutoMinBrightness, hdrAutoMaxAverageBrightness, enableVsync, framePacingMode, smoothnessLatencyMode, timingBufferLevel, timingPrioritizeResponsiveness, displaySyncMode, frameQueueTarget, videoFecPercentage, timingResponsivenessBias, allowDrawableTimeoutMode, timingCompatibilityMode, timingSdrCompatibilityWorkaround, showPerformanceOverlay, multiController, allowHevc, videoCodecPreference, serverCert, serverCodecModeSupport, frameInterpolationMode, clientGamepad, gamepadMouseMode, gamepadMouseModeLongPressMenu, nativeTouchpad, gamepadTrackpadPointerSensitivity, gamepadTrackpadScrollSpeed, gamepadTrackpadReverseScroll, gamepadDeadzone, controllerHapticsMode, controllerMotionMode, controllerFeedbackTarget, controllerVirtualType, controllerLeftCenterX, controllerLeftCenterY, controllerRightCenterY, controllerRightCenterX, controllerLeftGain, controllerRightGain;

- (instancetype)init
{
    self = [super init];
    if (self) {
        videoFecPercentage = -2;
    }
    return self;
}, controllerRightGain;
@end
