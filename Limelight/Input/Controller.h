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
// Physical transitions are independent of the debounce/chord output mask.
@property(nonatomic) int physicalButtonFlags;
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
@property(nonatomic) uint32_t lastHapticsSequence;
@property(nonatomic) BOOL hasHapticsSequence;
@property(nonatomic) CFAbsoluteTime lastAuthoredHapticsTime;
@property(nonatomic) BOOL authoredHapticsLogged;
@property(nonatomic) BOOL authoredHapticsFallback;

@property(nonatomic) BOOL hasTouchpadModeOverride;
@property(nonatomic) BOOL touchpadMouseMode;
@property(nonatomic) ControllerMenuGesture menuGesture;
@property(nonatomic) uint64_t clientShortcutRouting;
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
@property(nonatomic) NSTimeInterval trackpadTouchEnded;
@property(nonatomic) NSTimeInterval trackpadLastTapEnded;
@property(nonatomic) float trackpadLastTapX;
@property(nonatomic) float trackpadLastTapY;
@property(nonatomic) BOOL trackpadRepeatedTapCandidate;
@property(nonatomic) BOOL trackpadPhysicalClickConsumed;
@property(nonatomic) NSTimeInterval trackpadClickMovementSuppressedUntil;
@property(nonatomic) BOOL hasSentGamepadState;
@property(nonatomic) ControllerGamepadState sentGamepadState;
// Selected mechanical click while physically held; independent of shortcut consumption/output.
@property(nonatomic) int trackpadPhysicalMouseButton;
// Delivered aggregate mouse source, cleared on consumption/suspension.
@property(nonatomic) int trackpadMouseButton;

@property(nonatomic) HapticContext *_Nullable lowFreqMotor;
@property(nonatomic) HapticContext *_Nullable highFreqMotor;

// Gamepad Mouse Emulation State
@property(nonatomic) BOOL isMouseMode;
@property(nonatomic) int lastMouseModeButtonFlags;

// Motion state is guarded by ControllerSupport's stream lock.
// Invalidates handlers detached by cleanup, reconfiguration or physical owner reuse.
@property(nonatomic) NSUInteger motionGeneration;
// Sensor requests (0 = off) and monotonic callback/delivery times of the last reports.
@property(nonatomic) unsigned short accelReportRateHz;
@property(nonatomic) unsigned short gyroReportRateHz;
@property(nonatomic) NSTimeInterval lastAccelReportTime;
@property(nonatomic) NSTimeInterval lastGyroReportTime;

@end
