//
//  ControllerSupport.h
//  Moonlight
//
//  Created by Cameron Gutman on 10/20/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "Controller.h"
#import "Limelight.h"
#import "StreamConfiguration.h"

@class OnScreenControls;
@class MLDualSenseTouchpad;

@protocol InputPresenceDelegate <NSObject>

- (void)gamepadPresenceChanged;
- (void)mousePresenceChanged;
- (void)mouseModeToggled:(BOOL)enabled;
@optional
- (void)controllerRumbleFallback:(unsigned short)number low:(unsigned short)low high:(unsigned short)high;

@end

@interface ControllerSupport : NSObject
@property(nonatomic) BOOL shouldSendInputEvents;
@property(nonatomic, copy) uint64_t (^controllerShortcutHandler)(unsigned short, uint32_t);
- (void)refreshControllerShortcutOutputForPlayer:(unsigned short)player;
- (void)toggleControllerMouseModeForPlayer:(unsigned short)player;
@property(nonatomic) BOOL gamepadMouseModeEnabled;
@property(nonatomic) BOOL gamepadMouseModeLongPressMenuEnabled;
@property(nonatomic) BOOL nativeTouchpadEnabled;
// Sends DualSense touchpads to the host as a Windows precision touchpad when the host supports it.
@property(nonatomic, readonly) MLDualSenseTouchpad *dualSenseTouchpad;
@property(nonatomic) CGFloat gamepadTrackpadPointerSensitivity;
@property(nonatomic) CGFloat gamepadTrackpadScrollSpeed;
@property(nonatomic) BOOL gamepadTrackpadReverseScroll;
@property(nonatomic) CGFloat gamepadDeadzone;
@property(nonatomic) NSInteger controllerHapticsMode;
@property(nonatomic) NSInteger controllerMotionMode;
@property(nonatomic) NSInteger controllerFeedbackTarget;
@property(nonatomic) NSInteger controllerVirtualType;
// Controller family declared to the host on launch/resume (x360, ds4, ds5), or nil.
@property(nonatomic, copy) NSString *clientGamepad;
// A shortcut maps buttons to the touchpad, so controllers without one still
// announce it and the host emulates a pad that has a touchpad.
@property(nonatomic) BOOL advertiseTouchpadForShortcut;
@property(nonatomic) CGFloat controllerLeftCenterX;
@property(nonatomic) CGFloat controllerLeftCenterY;
@property(nonatomic) CGFloat controllerRightCenterX;
@property(nonatomic) CGFloat controllerRightCenterY;
@property(nonatomic) CGFloat controllerLeftGain;
@property(nonatomic) CGFloat controllerRightGain;
@property(nonatomic, assign) void *inputContext;

- (id)initWithConfig:(StreamConfiguration *)streamConfig
    presenceDelegate:(id<InputPresenceDelegate>)delegate;

#if TARGET_OS_IPHONE
- (void)initAutoOnScreenControlMode:(OnScreenControls *)osc;
- (Controller *)getOscController;
#endif
- (void)cleanup;
- (void)setGamepadMouseModeLongPressMenuEnabled:(BOOL)enabled;

- (void)updateLeftStick:(Controller *)controller x:(short)x y:(short)y;
- (void)updateRightStick:(Controller *)controller x:(short)x y:(short)y;

- (void)updateLeftTrigger:(Controller *)controller left:(unsigned char)left;
- (void)updateRightTrigger:(Controller *)controller right:(unsigned char)right;
- (void)updateTriggers:(Controller *)controller
                  left:(unsigned char)left
                 right:(unsigned char)right;

- (void)updateButtonFlags:(Controller *)controller flags:(int)flags;
- (void)setButtonFlag:(Controller *)controller flags:(int)flags;
- (void)clearButtonFlag:(Controller *)controller flags:(int)flags;

- (void)updateFinished:(Controller *)controller;

- (void)rumble:(unsigned short)controllerNumber
     lowFreqMotor:(unsigned short)lowFreqMotor
   highFreqMotor:(unsigned short)highFreqMotor;
- (void)rumbleTriggers:(unsigned short)controllerNumber
      leftTriggerMotor:(unsigned short)leftTriggerMotor
     rightTriggerMotor:(unsigned short)rightTriggerMotor;
- (void)setControllerLED:(unsigned short)controllerNumber
                       red:(unsigned char)red
                     green:(unsigned char)green
                      blue:(unsigned char)blue;
- (void)setAdaptiveTriggers:(unsigned short)controllerNumber
                 eventFlags:(unsigned char)eventFlags
                   typeLeft:(unsigned char)typeLeft
                  typeRight:(unsigned char)typeRight
                       left:(const unsigned char *)left
                      right:(const unsigned char *)right;
- (void)setMotionEventState:(unsigned short)controllerNumber
                  motionType:(unsigned char)motionType
                reportRateHz:(unsigned short)reportRateHz;
- (void)ds5HapticsPcm:(const LI_DS5_HAPTICS_PCM_FRAME *)frame;
- (void)ds5HapticsIrV2:(const LI_DS5_HAPTICS_IR_FRAME_V2 *)frame;

+ (int)getConnectedGamepadMask:(StreamConfiguration *)streamConfig;
+ (BOOL)hasDualSenseController;

- (NSUInteger)getConnectedGamepadCount;

@end
