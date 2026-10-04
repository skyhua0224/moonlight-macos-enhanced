//
//  Controller.h
//  Moonlight
//
//  Created by Cameron Gutman on 2/11/19.
//  Copyright © 2019 Moonlight Game Streaming Project. All rights reserved.
//

#import "HapticContext.h"

@import GameController;
@import CoreHaptics;

@interface Controller : NSObject

@property(nullable, nonatomic, retain) GCController *gamepad;
@property(nonatomic) int playerIndex;
@property(nonatomic) int lastButtonFlags;
@property(nonatomic) int emulatingButtonFlags;
@property(nonatomic) int supportedEmulationFlags;
@property(nonatomic) unsigned char lastLeftTrigger;
@property(nonatomic) unsigned char lastRightTrigger;
@property(nonatomic) short lastLeftStickX;
@property(nonatomic) short lastLeftStickY;
@property(nonatomic) short lastRightStickX;
@property(nonatomic) short lastRightStickY;

// Enhanced Sunshine controller state.
@property(nonatomic) BOOL controllerAnnounced;
@property(nonatomic) BOOL primaryTouchActive;
@property(nonatomic) BOOL secondaryTouchActive;
@property(nonatomic) float lastPrimaryTouchX;
@property(nonatomic) float lastPrimaryTouchY;
@property(nonatomic) float lastSecondaryTouchX;
@property(nonatomic) float lastSecondaryTouchY;
@property(nonatomic) float trackpadMouseAccumulatedX;
@property(nonatomic) float trackpadMouseAccumulatedY;
@property(nonatomic) float trackpadScrollAccumulatedY;
@property(nonatomic) int trackpadMouseButton;

@property(nonatomic) HapticContext *_Nullable lowFreqMotor;
@property(nonatomic) HapticContext *_Nullable highFreqMotor;

// Gamepad Mouse Emulation State
@property(nonatomic) BOOL isMouseMode;
@property(nonatomic) int lastMouseModeButtonFlags;
@property(nonatomic, strong) NSDate *_Nullable startButtonDownTime;

@end
