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

- (id)initWithConfig:(StreamConfiguration *)streamConfig
    presenceDelegate:(id<InputPresenceDelegate>)delegate;

#if TARGET_OS_IPHONE
- (void)initAutoOnScreenControlMode:(OnScreenControls *)osc;
- (Controller *)getOscController;
#endif
- (void)cleanup;

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

+ (int)getConnectedGamepadMask:(StreamConfiguration *)streamConfig;

- (NSUInteger)getConnectedGamepadCount;

@end
