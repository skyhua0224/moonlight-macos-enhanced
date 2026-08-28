//
//  Controller.h
//  Moonlight
//
//  Created by Cameron Gutman on 2/11/19.
//  Copyright © 2019 Moonlight Game Streaming Project. All rights reserved.
//

#import "HapticContext.h"
#include "ControllerTrackpadGesture.h"
#include "ControllerMenuGesture.h"

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

// Motion sampling state.
@property(nonatomic, strong, nullable) NSTimer *gyroTimer;
@property(nonatomic, strong, nullable) NSTimer *accelTimer;
@property(nonatomic) GCRotationRate lastGyroSample;
@property(nonatomic) GCAcceleration lastAccelSample;
@property(nonatomic) BOOL gyroAtRest;
@property(nonatomic) NSUInteger gyroStationarySampleCount;

// Enhanced Sunshine controller state.
@property(nonatomic) BOOL controllerAnnounced;
@property(nonatomic) uint32_t lastHapticsSequence;
@property(nonatomic) BOOL hasHapticsSequence;
@property(nonatomic) CFAbsoluteTime lastAuthoredHapticsTime;
@property(nonatomic) BOOL authoredHapticsLogged;
@property(nonatomic) BOOL authoredHapticsFallback;

@property(nonatomic) BOOL hasTouchpadModeOverride;
@property(nonatomic) BOOL touchpadMouseMode;
@property(nonatomic) ControllerMenuGesture menuGesture;
@property(nonatomic) BOOL primaryTouchActive;
@property(nonatomic) BOOL secondaryTouchActive;
@property(nonatomic) float lastPrimaryTouchX;
@property(nonatomic) float lastPrimaryTouchY;
@property(nonatomic) float lastSecondaryTouchX;
@property(nonatomic) float lastSecondaryTouchY;
@property(nonatomic) float trackpadMouseAccumulatedX;
@property(nonatomic) float trackpadMouseAccumulatedY;
@property(nonatomic) float trackpadScrollAccumulatedY;
@property(nonatomic) float trackpadScrollAccumulatedX;
@property(nonatomic) ControllerTrackpadGesture trackpadGesture;
@property(nonatomic) BOOL trackpadFlushPending;
@property(nonatomic) BOOL legacyTouchSnapshotPending;
@property(nonatomic) NSUInteger trackpadGestureGeneration;
@property(nonatomic) NSTimeInterval trackpadTouchBegan;
@property(nonatomic) BOOL trackpadPhysicalClickConsumed;
@property(nonatomic) NSTimeInterval trackpadClickMovementSuppressedUntil;
@property(nonatomic) BOOL hasSentGamepadState;
@property(nonatomic) ControllerGamepadState sentGamepadState;
@property(nonatomic) int trackpadMouseButton;

@property(nonatomic) HapticContext *_Nullable lowFreqMotor;
@property(nonatomic) HapticContext *_Nullable highFreqMotor;

// Gamepad Mouse Emulation State
@property(nonatomic) BOOL isMouseMode;
@property(nonatomic) int lastMouseModeButtonFlags;

@end
