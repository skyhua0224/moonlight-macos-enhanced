//
//  ControllerSupport.h
//  Moonlight
//
//  Created by Cameron Gutman on 10/20/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "Controller.h"
#import "StreamConfiguration.h"

@class OnScreenControls;

@protocol InputPresenceDelegate <NSObject>

- (void)gamepadPresenceChanged;
- (void)mousePresenceChanged;
- (void)mouseModeToggled:(BOOL)enabled;

@end

@interface ControllerSupport : NSObject
@property(nonatomic) BOOL shouldSendInputEvents;
@property(nonatomic) BOOL gamepadMouseModeEnabled;
@property(nonatomic) BOOL gamepadMouseModeLongPressMenuEnabled;
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

+ (int)getConnectedGamepadMask:(StreamConfiguration *)streamConfig;

- (NSUInteger)getConnectedGamepadCount;

@end
