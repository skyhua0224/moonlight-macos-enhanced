//
//  ControllerSupport.m
//  Moonlight
//
//  Created by Cameron Gutman on 10/20/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "ControllerSupport.h"
#import "Controller.h"

#import "OnScreenControls.h"

#import "DataManager.h"
#import "HIDSupport.h"
#import "Ds5HapticsAudioRenderer.h"
#import "Ds5BluetoothAudioRenderer.h"
#import "MLDualSenseTouchpad.h"
#include "../../modules/controller-feedback/ControllerFeedbackEnvelope.h"
#include "Limelight.h"
#include "Limelight-internal.h"
#include "ControllerShortcutAdapter.h"
#include "../../core/interaction/ds5-core/include/alkaidlab/ds5_core/ds5_core.h"
#import "DS5RawHIDBridge.h"
#import "DS5MotionMapping.h"
#import "DS5OutputMapping.h"
#include "DS5PadPresence.h"
#import "DS5ButtonMerge.h"
#import "DS5BluetoothPolicy.h"
#import "DS5RumbleScheduler.h"
#import "DS5IrPlayback.h"
#import "DS5PadTwin.h"

@import GameController;
@import AudioToolbox;
@import CoreHaptics;

#import <math.h>
#import <os/lock.h>

@interface ControllerSupport (DS5CoreRouting)
- (AlkDs5Core *)ds5CoreForPlayer:(NSUInteger)player;
- (AlkDs5Error)withDS5CoreForPlayer:(NSUInteger)player call:(AlkDs5Error (NS_NOESCAPE ^)(AlkDs5Core *core))call;
- (NSString *)rawHIDIdentityForPlayer:(NSUInteger)player;
- (void)writeDualSenseFeedback:(unsigned short)controllerNumber
                         flag0:(uint8_t)flag0 flag1:(uint8_t)flag1 flag2:(uint8_t)flag2
                        update:(void (^)(AlkDs5Feedback *feedback))update;
@end

// Foundation controller-arrival extension: unlike LI_CCAP_DS5_HAPTICS_PCM,
// this bit identifies a DualSense even when no physical audio endpoint exists.
// The host keeps older clients on the legacy PS fallback when this bit is absent.
static const uint16_t LI_CCAP_DUALSENSE_IDENTITY = 0x0400;

static inline PML_INPUT_STREAM_CONTEXT ControllerInputContext(ControllerSupport *support) {
    PML_INPUT_STREAM_CONTEXT ctx = (PML_INPUT_STREAM_CONTEXT)support.inputContext;
    if (ctx != NULL && ctx->connectionContext != NULL) {
        LiSetThreadConnectionContext(ctx->connectionContext);
    }
    return ctx;
}

static short ApplyStickCalibration(short rawX, short rawY, CGFloat deadzone,
                                   CGFloat centerX, CGFloat centerY, CGFloat gain) {
    float x = (float)rawX / 32767.0f - (float)centerX;
    float y = (float)rawY / 32767.0f - (float)centerY;
    float magnitude = sqrtf(x * x + y * y);
    float threshold = fminf(0.30f, fmaxf(0.0f, (float)deadzone));
    if (magnitude <= threshold) {
        return 0;
    }

    // Radial deadzone preserves direction and remaps the remaining travel to
    // the full range, matching SDL's calibrated axis semantics.
    float remappedMagnitude = (magnitude - threshold) / (1.0f - threshold);
    remappedMagnitude = fminf(1.0f, fmaxf(0.0f, remappedMagnitude));
    if (magnitude > 0.0001f) {
        x = (x / magnitude) * remappedMagnitude;
        y = (y / magnitude) * remappedMagnitude;
    }
    float calibratedGain = fminf(2.0f, fmaxf(0.25f, (float)gain));
    x = fminf(1.0f, fmaxf(-1.0f, x * calibratedGain));
    y = fminf(1.0f, fmaxf(-1.0f, y * calibratedGain));
    return (short)lrintf(x * 32767.0f);
}

static short ApplyStickCalibrationY(short rawX, short rawY, CGFloat deadzone,
                                    CGFloat centerX, CGFloat centerY, CGFloat gain) {
    float x = (float)rawX / 32767.0f - (float)centerX;
    float y = (float)rawY / 32767.0f - (float)centerY;
    float magnitude = sqrtf(x * x + y * y);
    float threshold = fminf(0.30f, fmaxf(0.0f, (float)deadzone));
    if (magnitude <= threshold) {
        return 0;
    }
    float remappedMagnitude = (magnitude - threshold) / (1.0f - threshold);
    remappedMagnitude = fminf(1.0f, fmaxf(0.0f, remappedMagnitude));
    if (magnitude > 0.0001f) {
        y = (y / magnitude) * remappedMagnitude;
    }
    float calibratedGain = fminf(2.0f, fmaxf(0.25f, (float)gain));
    return (short)lrintf(fminf(1.0f, fmaxf(-1.0f, y * calibratedGain)) * 32767.0f);
}

typedef struct { float v[3]; } DS5Vec3;

static BOOL ControllerIsFeedbackTarget(ControllerSupport *support, unsigned short number) {
    return support.controllerFeedbackTarget < 0 || support.controllerFeedbackTarget == number;
}

static void ResetControllerTrackpadMouseState(Controller *controller) {
    controller.primaryTouchActive = NO;
    controller.secondaryTouchActive = NO;
    controller.lastPrimaryTouchX = 0.0f;
    controller.lastPrimaryTouchY = 0.0f;
    controller.lastSecondaryTouchX = 0.0f;
    controller.lastSecondaryTouchY = 0.0f;
    controller.trackpadMouseAccumulatedX = 0.0f;
    controller.trackpadMouseAccumulatedY = 0.0f;
    controller.trackpadScrollAccumulatedY = 0.0f;
    controller.trackpadScrollAccumulatedX = 0.0f;
    controller.trackpadMouseButton = 0;
    controller.trackpadGesture = (ControllerTrackpadGesture){0};
    controller.trackpadFlushPending = NO;
    controller.legacyTouchSnapshotPending = NO;
    controller.trackpadGestureGeneration++;
    controller.trackpadTouchBegan = 0;
    controller.trackpadTouchEnded = 0;
    controller.trackpadLastTapEnded = 0;
    controller.trackpadRepeatedTapCandidate = NO;
    controller.trackpadPhysicalClickConsumed = NO;
    controller.trackpadClickMovementSuppressedUntil = 0;
}

static void LogControllerMappingDiagnostics(Controller *controller,
                                            uint8_t controllerType,
                                            uint32_t supportedButtonFlags,
                                            uint16_t capabilities,
                                            ControllerSupport *support) {
    NSDictionary *mapping = @{
        @"schema": @"ds5-mapping-v1",
        @"player": @(controller.playerIndex),
        @"controllerType": @(controllerType),
        @"buttonFlags": @(supportedButtonFlags),
        @"capabilities": @(capabilities),
        @"buttons": @{
            @"south": @"A/Cross",
            @"east": @"B/Circle",
            @"west": @"X/Square",
            @"north": @"Y/Triangle",
            @"leftShoulder": @"L1",
            @"rightShoulder": @"R1",
            @"menu": @"Options",
            @"back": @"Create",
            @"guide": @"PS",
            @"touchpadButton": @"Touchpad"
        },
        @"dpad": @"8-way-hat",
        @"triggers": @{
            @"encoding": @"analog-uint8",
            @"digitalThreshold": @30
        },
        @"sticks": @{
            @"encoding": @"signed-int16",
            @"range": @[@(-32768), @32767]
        },
        @"touchpad": @{
            @"native": @"Foundation controller-touch",
            @"mouseMode": @"single-finger-relative-pointer-two-finger-high-res-scroll",
            @"secondaryClick": @"two-finger-touchpad-click"
        },
        @"settings": @{
            @"deadzone": @(support.gamepadDeadzone),
            @"hapticsMode": @(support.controllerHapticsMode),
            @"motionMode": @(support.controllerMotionMode),
            @"feedbackTarget": @(support.controllerFeedbackTarget),
            @"virtualType": @(support.controllerVirtualType),
            @"declaredGamepad": support.clientGamepad ?: @"",
            @"leftCalibration": @{
                @"centerX": @(support.controllerLeftCenterX),
                @"centerY": @(support.controllerLeftCenterY),
                @"gain": @(support.controllerLeftGain)
            },
            @"rightCalibration": @{
                @"centerX": @(support.controllerRightCenterX),
                @"centerY": @(support.controllerRightCenterY),
                @"gain": @(support.controllerRightGain)
            },
            @"outputPath": @"Foundation authored PCM; GameController RMS fallback; USB physical PCM backend capability-gated"
        }
    };
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:mapping options:0 error:&error];
    NSString *json = data != nil ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
    Log(LOG_I, @"[controller-mapping] %@", json ?: [NSString stringWithFormat:@"{\"error\":\"%@\"}", error]);
}

static GCControllerTouchpad *PhysicalControllerTouchpadForSurface(GCController *controller,
                                                                  GCControllerDirectionPad *surface) {
    for (GCControllerTouchpad *touchpad in controller.physicalInputProfile.allTouchpads) {
        if (surface != nil && touchpad.touchSurface == surface) return touchpad;
    }
    return nil;
}

static BOOL ControllerTouchpadUsesMouse(ControllerSupport *support, Controller *controller) {
    return controller.isMouseMode || (controller.hasTouchpadModeOverride
        ? controller.touchpadMouseMode : !support.nativeTouchpadEnabled);
}

static uint32_t ControllerShortcutPhysicalButtons(GCExtendedGamepad *pad) {
    if (pad == nil) return 0;
    GCControllerButtonInput *touch = [pad isKindOfClass:GCDualSenseGamepad.class] ? [(GCDualSenseGamepad *)pad touchpadButton] :
        ([pad isKindOfClass:GCDualShockGamepad.class] ? [(GCDualShockGamepad *)pad touchpadButton] : nil);
    return (touch.pressed ? TOUCHPAD_FLAG : 0) |
        (pad.leftTrigger.value >= 30.0f / 255.0f ? CONTROLLER_SHORTCUT_LEFT_TRIGGER_MARKER : 0) |
        (pad.rightTrigger.value >= 30.0f / 255.0f ? CONTROLLER_SHORTCUT_RIGHT_TRIGGER_MARKER : 0) | (pad.buttonOptions.pressed ? BACK_FLAG : 0) | (pad.buttonMenu.pressed ? PLAY_FLAG : 0) |
        (pad.leftThumbstickButton.pressed ? LS_CLK_FLAG : 0) | (pad.rightThumbstickButton.pressed ? RS_CLK_FLAG : 0) |
        (pad.leftShoulder.pressed ? LB_FLAG : 0) | (pad.rightShoulder.pressed ? RB_FLAG : 0) |
        (pad.buttonA.pressed ? A_FLAG : 0) | (pad.buttonB.pressed ? B_FLAG : 0) |
        (pad.buttonX.pressed ? X_FLAG : 0) | (pad.buttonY.pressed ? Y_FLAG : 0) |
        (pad.dpad.up.pressed ? UP_FLAG : 0) | (pad.dpad.down.pressed ? DOWN_FLAG : 0) |
        (pad.dpad.left.pressed ? LEFT_FLAG : 0) | (pad.dpad.right.pressed ? RIGHT_FLAG : 0);
}

static void UpdateControllerTrackpadTap(ControllerSupport *support, Controller *controller,
                                        unsigned previousContacts, ControllerTrackpadGesture state) {
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (previousContacts == 0 && state.contacts != 0) {
        controller.trackpadTouchBegan = now;
        controller.trackpadPhysicalClickConsumed = controller.trackpadMouseButton != 0;
        unsigned finger = state.contacts == 2 ? 1 : 0;
        float dx = state.x[finger] - controller.trackpadLastTapX;
        float dy = state.y[finger] - controller.trackpadLastTapY;
        controller.trackpadRepeatedTapCandidate = controller.trackpadLastTapEnded > 0 &&
            now - controller.trackpadLastTapEnded <= NSEvent.doubleClickInterval &&
            dx * dx + dy * dy <= 0.0025f;
    }
    if (previousContacts != 0 && state.contacts == 0) {
        controller.trackpadTouchEnded = now;
        BOOL tap = controller.trackpadTouchBegan > 0 &&
            now - controller.trackpadTouchBegan <= 0.35 &&
            state.maximumTravelSquared <= 0.000225f &&
            !state.scrollMotionStarted &&
            !controller.trackpadPhysicalClickConsumed;
        PML_INPUT_STREAM_CONTEXT input = ControllerInputContext(support);
        if (tap && support.shouldSendInputEvents && input != NULL) {
            int button = state.maximumContacts == 2 ? BUTTON_RIGHT : BUTTON_LEFT;
            LiSendMouseButtonEventCtx(input, BUTTON_ACTION_PRESS, button);
            LiSendMouseButtonEventCtx(input, BUTTON_ACTION_RELEASE, button);
            unsigned finger = previousContacts == 2 ? 1 : 0;
            controller.trackpadLastTapEnded = button == BUTTON_LEFT ? now : 0;
            controller.trackpadLastTapX = state.x[finger];
            controller.trackpadLastTapY = state.y[finger];
        } else {
            controller.trackpadLastTapEnded = 0;
        }
        controller.trackpadTouchBegan = 0;
        controller.trackpadRepeatedTapCandidate = NO;
    }
}

static void FlushControllerTrackpad(ControllerSupport *support, Controller *controller) {
    PML_INPUT_STREAM_CONTEXT ctx = ControllerInputContext(support);
    ControllerTrackpadGesture state = controller.trackpadGesture;
    ControllerTrackpadDelta delta = ControllerTrackpadConsume(&state);
    controller.trackpadGesture = state;
    if (ctx == NULL || !support.shouldSendInputEvents || !ControllerTouchpadUsesMouse(support, controller)) {
        controller.trackpadMouseAccumulatedX = controller.trackpadMouseAccumulatedY = 0;
        controller.trackpadScrollAccumulatedX = controller.trackpadScrollAccumulatedY = 0;
        return;
    }
    if (NSProcessInfo.processInfo.systemUptime < controller.trackpadClickMovementSuppressedUntil) return;
    if (!delta.scroll && controller.trackpadRepeatedTapCandidate &&
        state.maximumTravelSquared <= 0.000225f) return;
    if (delta.scroll) {
        float scale = 2400.0f * fminf(4.0f, fmaxf(0.1f, (float)support.gamepadTrackpadScrollSpeed));
        id preference = [[NSUserDefaults standardUserDefaults] objectForKey:@"com.apple.swipescrolldirection"];
        BOOL natural = preference == nil || [preference boolValue];
        BOOL inverted = natural != support.gamepadTrackpadReverseScroll;
        controller.trackpadScrollAccumulatedY += (inverted ? delta.dy : -delta.dy) * scale;
        controller.trackpadScrollAccumulatedX += (inverted ? -delta.dx : delta.dx) * scale;
        short horizontal = (short)controller.trackpadScrollAccumulatedX;
        short vertical = (short)controller.trackpadScrollAccumulatedY;
        if (horizontal) {
            LiSendHighResHScrollEventCtx(ctx, horizontal);
            controller.trackpadScrollAccumulatedX -= horizontal;
        }
        if (vertical) {
            LiSendHighResScrollEventCtx(ctx, vertical);
            controller.trackpadScrollAccumulatedY -= vertical;
        }
    } else {
        float scale = 1200.0f * fminf(4.0f, fmaxf(0.1f, (float)support.gamepadTrackpadPointerSensitivity));
        controller.trackpadMouseAccumulatedX += delta.dx * scale;
        controller.trackpadMouseAccumulatedY += delta.dy * scale;
        short dx = (short)controller.trackpadMouseAccumulatedX;
        short dy = (short)controller.trackpadMouseAccumulatedY;
        if (dx || dy) {
            LiSendMouseMoveEventCtx(ctx, dx, dy);
            controller.trackpadMouseAccumulatedX -= dx;
            controller.trackpadMouseAccumulatedY -= dy;
        }
    }
}

static BOOL SendControllerTouchWithContact(ControllerSupport *support, Controller *controller,
                                           uint32_t pointerId, BOOL active,
                                           float x, float y, BOOL hasContact) {
    if (controller != nil) {
        AlkDs5TouchObservation touch = {
            .struct_size = sizeof(touch), .abi = ALK_DS5_CORE_ABI_VERSION,
            .device_index = 0, .sequence = (uint64_t)controller.playerIndex + 1u,
            .contact_id = (uint8_t)(pointerId & 1u), .active = hasContact ? 1u : 0u,
            .x = (uint16_t)fminf(1919.0f, fmaxf(0.0f, x * 1920.0f)),
            .y = (uint16_t)fminf(1079.0f, fmaxf(0.0f, y * 1080.0f)), .pressure = 0};
        (void)[support withDS5CoreForPlayer:(NSUInteger)controller.playerIndex call:^AlkDs5Error(AlkDs5Core *core) { return alk_ds5_core_submit_touch(core, &touch); }];
    }
    if (controller != nil && [support.dualSenseTouchpad claimsTouchpad]) {
        // Windows precision touchpad: no controller touch events, no pointer or scroll output.
        if (support.shouldSendInputEvents) {
            [support.dualSenseTouchpad setContact:(pointerId & 1u) active:hasContact x:x y:y player:controller.playerIndex];
        }
        return hasContact;
    }
    PML_INPUT_STREAM_CONTEXT inputCtx = ControllerInputContext(support);
    if (controller == nil || !support.shouldSendInputEvents || inputCtx == NULL) {
        return active;
    }

    // GameController reports DualSense touchpad axes as a normalized direction
    // pad. Sunshine expects normalized top-left origin coordinates.
    float normalizedX = fminf(1.0f, fmaxf(0.0f, (x + 1.0f) * 0.5f));
    float normalizedY = fminf(1.0f, fmaxf(0.0f, (1.0f - y) * 0.5f));

    // GameController exposes each DualSense contact as a direction pad. In
    // mouse mode, turn the contact position deltas into relative pointer or
    // high-resolution scroll events. Native controller-touch events remain
    // unchanged while controller mode is active.
    if (ControllerTouchpadUsesMouse(support, controller)) {
        ControllerTrackpadGesture state = controller.trackpadGesture;
        unsigned previousContacts = state.contacts;
        BOOL transitioned = ControllerTrackpadUpdate(&state, pointerId & 1u, hasContact, normalizedX, normalizedY);
        controller.trackpadGesture = state;
        UpdateControllerTrackpadTap(support, controller, previousContacts, state);
        if (transitioned) {
            controller.trackpadMouseAccumulatedX = controller.trackpadMouseAccumulatedY = 0;
            controller.trackpadScrollAccumulatedX = controller.trackpadScrollAccumulatedY = 0;
        }
        if (state.scrollGesture) {
            // GC delivers contacts separately on the main handler queue.
            // Consume their final centroid once per callback batch, avoiding
            // equal-and-opposite half-report scroll events.
            if (!controller.trackpadFlushPending) {
                controller.trackpadFlushPending = YES;
                NSUInteger generation = controller.trackpadGestureGeneration;
                __weak ControllerSupport *weakSupport = support;
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (controller.trackpadGestureGeneration != generation) return;
                    controller.trackpadFlushPending = NO;
                    ControllerSupport *currentSupport = weakSupport;
                    if (currentSupport != nil) FlushControllerTrackpad(currentSupport, controller);
                });
            }
        } else {
            FlushControllerTrackpad(support, controller);
        }
        return hasContact;
    }
    if (hasContact) {
        if (pointerId & 1U) { controller.lastSecondaryTouchX = normalizedX; controller.lastSecondaryTouchY = normalizedY; }
        else { controller.lastPrimaryTouchX = normalizedX; controller.lastPrimaryTouchY = normalizedY; }
    }
    uint8_t eventType;
    if (hasContact && !active) {
        eventType = LI_TOUCH_EVENT_DOWN;
    } else if (hasContact && active) {
        eventType = LI_TOUCH_EVENT_MOVE;
    } else if (!hasContact && active) {
        eventType = LI_TOUCH_EVENT_UP;
    } else {
        return active;
    }

    int result = LiSendControllerTouchEventCtx(inputCtx, (uint8_t)controller.playerIndex, eventType,
                                  pointerId, normalizedX, normalizedY, hasContact ? 1.0f : 0.0f);
    if (eventType != LI_TOUCH_EVENT_MOVE)
        Log(LOG_I, @"[controller-touch] Host event player=%d contact=%u kind=%u result=%d", controller.playerIndex, pointerId, eventType, result);
    return hasContact;
}

static BOOL SendControllerTouch(ControllerSupport *support, Controller *controller,
                                uint32_t pointerId, BOOL active, float x, float y) {
    BOOL hasContact = fabsf(x) > 0.001f || fabsf(y) > 0.001f;
    return SendControllerTouchWithContact(support, controller, pointerId, active,
                                          x, y, hasContact);
}

static void QueueControllerTouchSnapshot(ControllerSupport *support, Controller *controller,
                                         GCControllerDirectionPad *primary,
                                         GCControllerDirectionPad *secondary) {
    if (controller.legacyTouchSnapshotPending) return;
    controller.legacyTouchSnapshotPending = YES;
    NSUInteger generation = controller.trackpadGestureGeneration;
    __weak ControllerSupport *weakSupport = support;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (controller.trackpadGestureGeneration != generation) return;
        controller.legacyTouchSnapshotPending = NO;
        ControllerSupport *current = weakSupport;
        if (current == nil) return;
        float x[2] = {primary.xAxis.value, secondary.xAxis.value};
        float y[2] = {primary.yAxis.value, secondary.yAxis.value};
        BOOL touching[2] = {fabsf(x[0]) > 0.001f || fabsf(y[0]) > 0.001f,
                            fabsf(x[1]) > 0.001f || fabsf(y[1]) > 0.001f};
        if ([current.dualSenseTouchpad claimsTouchpad]) {
            if (current.shouldSendInputEvents) {
                for (NSUInteger finger = 0; finger < 2; finger++) {
                    [current.dualSenseTouchpad setContact:finger active:touching[finger]
                                                        x:x[finger] y:y[finger] player:controller.playerIndex];
                }
            }
            return;
        }
        if (ControllerTouchpadUsesMouse(current, controller)) {
            // Axis handlers can fire between the X and Y resets on release.
            // Sample the complete profile after that batch, then update both
            // contacts before deriving any cursor or scroll displacement.
            ControllerTrackpadGesture state = controller.trackpadGesture;
            unsigned previousContacts = state.contacts;
            BOOL changed = NO;
            for (unsigned i = 0; i < 2; i++) {
                changed |= ControllerTrackpadUpdate(&state, i, touching[i],
                    fminf(1, fmaxf(0, (x[i] + 1) * 0.5f)),
                    fminf(1, fmaxf(0, (1 - y[i]) * 0.5f)));
            }
            controller.trackpadGesture = state;
            controller.primaryTouchActive = touching[0];
            controller.secondaryTouchActive = touching[1];
            UpdateControllerTrackpadTap(current, controller, previousContacts, state);
            if (changed) {
                controller.trackpadMouseAccumulatedX = controller.trackpadMouseAccumulatedY = 0;
                controller.trackpadScrollAccumulatedX = controller.trackpadScrollAccumulatedY = 0;
            }
            FlushControllerTrackpad(current, controller);
        } else {
            controller.primaryTouchActive = SendControllerTouch(current, controller,
                controller.playerIndex * 2, controller.primaryTouchActive, x[0], y[0]);
            controller.secondaryTouchActive = SendControllerTouch(current, controller,
                controller.playerIndex * 2 + 1, controller.secondaryTouchActive, x[1], y[1]);
        }
    });
}

static void RegisterPhysicalTouchpad(ControllerSupport *support, Controller *controller,
                                     GCControllerTouchpad *touchpad, BOOL secondary) {
    touchpad.reportsAbsoluteTouchSurfaceValues = YES;
    GCControllerTouchpadHandler down = ^(GCControllerTouchpad *pad, float x, float y, float button, BOOL pressed) {
        (void)pad; (void)button; (void)pressed;
        BOOL active = secondary ? controller.secondaryTouchActive : controller.primaryTouchActive;
        BOOL current = SendControllerTouchWithContact(support, controller, controller.playerIndex * 2 + (secondary ? 1 : 0), active, x, y, YES);
        if (secondary) controller.secondaryTouchActive = current; else controller.primaryTouchActive = current;
    };
    touchpad.touchDown = down;
    touchpad.touchMoved = down;
    touchpad.touchUp = ^(GCControllerTouchpad *pad, float x, float y, float button, BOOL pressed) {
        (void)pad; (void)button; (void)pressed;
        BOOL active = secondary ? controller.secondaryTouchActive : controller.primaryTouchActive;
        BOOL current = SendControllerTouchWithContact(support, controller, controller.playerIndex * 2 + (secondary ? 1 : 0), active, x, y, NO);
        if (secondary) controller.secondaryTouchActive = current; else controller.primaryTouchActive = current;
    };
}

enum ButtonDebouncerState {
    BDS_none,
    BDS_initialPress,
    BDS_down,
    BDS_replicatedPress,
    BDS_chord
};

@interface ButtonDebouncer : NSObject
@property (nonatomic) unsigned int button;
@property (nonatomic, strong) GCControllerButtonInput *input;
@property (nonatomic, strong) ControllerSupport *support;
@property (nonatomic) unsigned int chordButton;

@property (nonatomic, weak) ButtonDebouncer *other;

@property (nonatomic) enum ButtonDebouncerState state;
@property (nonatomic, strong) NSDate *buttonDownTime;
@property (nonatomic, strong) NSTimer *buttonDebounceTimer;
@property (nonatomic, strong) NSTimer *replicatedButtonTimeTimer;

@end

@implementation ButtonDebouncer

- (instancetype)initWithButton:(unsigned int)button input:(GCControllerButtonInput *)input controllerSupport:(ControllerSupport *)support chordButton:(unsigned int)chordButton {
    self = [super init];
    if (self) {
        self.button = button;
        self.input = input;
        self.support = support;
        self.chordButton = chordButton;
    }
    return self;
}

- (void)handlePress:(Controller *)controller pressedButtons:(int)pressedButtons {
    if (controller.lastButtonFlags & self.button) {
        if (self.state == BDS_none) {

            // If we are 2nd button and 1st button is in initialPress state, then:
            //   turn on chord button
            //   put 1st and 2nd buttons into special chord state
            if (self.other.state == BDS_initialPress) {

                [self transitionToChordState];
                [self.other transitionToChordState];

                [self updateLastButtonFlagsForChordState:controller];
            } else {

                self.state = BDS_initialPress;
                self.buttonDownTime = [[NSDate alloc] init];
                controller.lastButtonFlags &= ~self.button;

                [self.buttonDebounceTimer invalidate];
                self.buttonDebounceTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:NO block:^(NSTimer * _Nonnull timer) {
                    [self initialPressTimeout:controller];
                }];
            }
        } else if (self.state == BDS_initialPress) {
            controller.lastButtonFlags &= ~self.button;
        } else if (self.state == BDS_chord) {
            [self updateLastButtonFlagsForChordState:controller];
        }
    }
}

- (void)handleRelease:(Controller *)controller releasedButtons:(int)releasedButtons {
    if (releasedButtons & self.button) {

        if (self.state == BDS_down && !self.input.pressed) {
            self.state = BDS_none;

        } else if (self.state == BDS_initialPress && !self.input.pressed) {

            controller.lastButtonFlags |= self.button;
            [self.support updateFinished:controller];

            self.state = BDS_replicatedPress;

            NSTimeInterval pressDuration = -[self.buttonDownTime timeIntervalSinceNow];

            [self.buttonDebounceTimer invalidate];
            [self.replicatedButtonTimeTimer invalidate];
            self.replicatedButtonTimeTimer = [NSTimer scheduledTimerWithTimeInterval:pressDuration repeats:NO block:^(NSTimer * _Nonnull timer) {

                controller.lastButtonFlags &= ~self.button;
                [self.support updateFinished:controller];

                self.state = BDS_none;
            }];

        } else if (self.state == BDS_chord && !self.input.pressed) {
            if (self.other.state == BDS_chord && !self.other.input.pressed) {

                controller.lastButtonFlags &= ~self.chordButton;

                [self transitionToNoneState];
                [self.other transitionToNoneState];
            } else if (self.other.state == BDS_chord && self.other.input.pressed) {

                [self updateLastButtonFlagsForChordState:controller];
            }
        }
    }
}

- (void)initialPressTimeout:(Controller *)controller {
    if (self.state == BDS_initialPress) {
        if (self.input.pressed) {
            self.state = BDS_down;
            controller.lastButtonFlags |= self.button;
            [self.support updateFinished:controller];
        }
    }
}

- (void)transitionToChordState {
    self.state = BDS_chord;
}

- (void)transitionToNoneState {
    self.state = BDS_none;
}

- (void)updateLastButtonFlagsForChordState:(Controller *)controller {
    controller.lastButtonFlags |= self.chordButton;

    controller.lastButtonFlags &= ~self.button;
    controller.lastButtonFlags &= ~self.other.button;
}

@end

#if TARGET_OS_IPHONE
static const double MOUSE_SPEED_DIVISOR = 2.5;
#endif

@implementation ControllerSupport {
    id _controllerConnectObserver;
    id _controllerDisconnectObserver;
#if TARGET_OS_IPHONE
    id _mouseConnectObserver;
    id _mouseDisconnectObserver;
    id _keyboardConnectObserver;
    id _keyboardDisconnectObserver;
#endif

    NSLock *_controllerStreamLock;
    NSMutableDictionary *_controllers;
    id<InputPresenceDelegate> _presenceDelegate;

#if TARGET_OS_IPHONE
    float accumulatedDeltaX;
    float accumulatedDeltaY;
    float accumulatedScrollY;
#endif

    OnScreenControls *_osc;

    // This controller object is shared between on-screen controls
    // and player 0
    Controller *_player0osc;

#define EMULATING_SELECT     0x1
#define EMULATING_SPECIAL    0x2

    bool _oscEnabled;
    char _controllerNumbers;
    bool _multiController;
    BOOL _gamepadMouseModeEnabled;
    BOOL _gamepadMouseModeLongPressMenuEnabled;
    bool _isMouseModeActive;
    NSDate *_startPressTime;
    float _accumulatedMouseX;
    float _accumulatedMouseY;
    NSTimer *_mouseTimer;

    NSMutableDictionary<NSNumber * /* key flag */, NSMutableDictionary<NSNumber * /* player index */, ButtonDebouncer *> *> *_debouncers;
    Ds5HapticsAudioRenderer *_ds5HapticsAudioRenderer;
    Ds5BluetoothAudioRenderer *_ds5BluetoothAudioRenderer;
    DS5RawHIDBridge *_rawHID;
    NSString *_rawHIDIdentity[16];
    // Raw devices that are the Bluetooth twin of a USB device of the same pad: no player, no input (DS5PadTwin.h).
    NSMutableDictionary<NSString *, NSNumber *> *_rawTwinIgnored;
    // The pad address each raw device reported in feature 0x09 (twelve hex digits); two devices with one address are one pad.
    NSMutableDictionary<NSString *, NSString *> *_rawAddressKey;
    os_unfair_lock _ds5CoreLock;
    CFAbsoluteTime _diagRawChangedAt;
    CFAbsoluteTime _diagLastLog;
    uint64_t _diagRawButtons;
    uint8_t _diagRawSticks[4];
    double _diagLagSum;
    double _diagLagMax;
    uint32_t _diagLagCount;
    double _diagRawGyroPeak;
    double _diagGCGyroPeak;
    uint8_t _diagRawBatterySteps;
    uint8_t _diagRawCharging;
    uint8_t _diagGCBatteryPercent;
    AlkDs5Feedback _lastDS5Feedback[16];
    BOOL _hasDS5Feedback[16];
    NSObject *_hapticsMailboxLock;
    BOOL _hapticsDrainScheduled;
    // Analysed haptics (IR v2): every frame of the stream in order, played with no tick lost (DS5IrPlayback.h).
    // Guarded by _hapticsMailboxLock.
    DS5IrPlayback _irPlayback[16];
    double _irWakeAt[16];
    CFAbsoluteTime _irStatsLast;
    // Every host rumble value waits here in order (a ring per player), so a pulse is never merged into its stop.
    struct { unsigned short low, high; BOOL direct; } _rumbleEvents[16][32];
    unsigned _rumbleEventCount[16];
    BOOL _rumbleDrainScheduled;
    DS5RumbleScheduler _rumbleSched[16];
    unsigned _rumbleTimerGeneration[16];
    unsigned _rumbleDropped, _rumbleWindowReceived;
    CFAbsoluteTime _rumbleLastLog;
    id _touchpadSettingsObserver;
    id _dualSensePrecisionObserver;
    MLDualSenseTouchpad *_dualSenseTouchpad;
    NSTimer *_controllerMaintenanceTimer;
    NSTimer *_controllerScanTimer;
    BOOL _dualSenseOnly;
    NSUInteger _lastScanSignature;
    CFAbsoluteTime _lastScanLog;
    NSUInteger _maintenanceTicks;
    AlkDs5Core *_ds5Core[16];
    uint64_t _ds5Sequence[16];
    // Motion: rates the host asked for, the raw source's pacing, and the per-second sample counts the
    // automatic source choice and the [ds5-diag] line use. Guarded by _ds5CoreLock.
    DS5ImuCalibration _imuCalibration[16];
    unsigned short _motionGyroRate[16];
    unsigned short _motionAccelRate[16];
    double _rawLastGyroSent[16];
    double _rawLastAccelSent[16];
    double _motionWindowStart;
    unsigned _rawImuWindow, _gcMotionWindow, _gyroSentWindow;
    unsigned _rawImuRate, _gcMotionRate, _gyroSentRate;
    DS5MotionSource _motionSourceEffective;
    // The [ds5-motion] line: the strongest raw sample of the last second beside what was sent, and the latest
    // GameController sample with its mapping. Raw fields are guarded by _ds5CoreLock; the GC ones are written
    // from the motion handler and only read for this log.
    double _motionLogLast;
    double _motionLogIdleLast;
    double _mlRawPeak;
    int16_t _mlRawGyro[3], _mlRawAccel[3];
    float _mlWireGyro[3], _mlWireAccel[3], _mlCalGyro[3];
    double _mlGCRot[3], _mlGCAcc[3];
    float _mlGCProto[3];
    BOOL _mlGCValid;
    // Headset and microphone facts last sent to the host (0x5516).
    struct { BOOL valid; uint8_t headset, microphone, muted; CFAbsoluteTime sentAt; } _sentJack[16];
    // Who writes the player LEDs: 0 nobody yet, 1 GameController (playerIndex), 2 raw output report.
    int _playerLEDWriter[16];
    // The pattern a game asked for, so a later empty message does not clear it and a reconnect restores it.
    BOOL _gameLEDSet[16];
    uint8_t _gameLEDMask[16];
    NSInteger _originalGCPlayerIndex[16];
    BOOL _hasOriginalGCPlayerIndex[16];
    NSMutableDictionary<NSString *, NSNumber *> *_lastPlayerForKey;
    BOOL _loggedMissingRawIdentity;
    BOOL _rawMute[16];
    uint8_t _gameMuteLED[16];  // the mute LED value the game last asked for; 0 until it asks
    id _originalLightColor[16];  // GCColor, kept as id so the ivar needs no availability guard
    BOOL _loggedBluetoothAudioSkipped;
    // Pad audio (the "pad-audio" extension, offered with ds5PadAudioOffer): a four-channel frame was seen for
    // this pad, the pad's audio bytes were written, and whether the real pad reports a headset (-1 unknown).
    BOOL _padAudioSeen[16];
    BOOL _padAudioConfigured[16];
    int _padHeadset[16];
    BOOL _padAudioSelfTestRan;
    BOOL _padAudioSelfTestFlag, _padAudioSelfTestFlagRead;
    BOOL _padSpeakerStream;  // this stream plays the host's speaker pair on a pad (decided at stream start)
    BOOL _loggedIrUnavailable;

}

@synthesize shouldSendInputEvents = _shouldSendInputEvents;
@synthesize dualSenseTouchpad = _dualSenseTouchpad;

- (AlkDs5Core *)ds5CoreForPlayer:(NSUInteger)player {
    if (player >= 16) return NULL;
    if (_ds5Core[player] == NULL) {
        AlkDs5BackendEvidence evidence = {
            .struct_size = sizeof(evidence), .abi = ALK_DS5_CORE_ABI_VERSION,
            .proven_capabilities = ALK_DS5_CAP_AUDIO_PCM | ALK_DS5_CAP_AUDIO_RENDER,
            .audio = {sizeof(AlkDs5AudioFacts), ALK_DS5_CORE_ABI_VERSION, 48000u, 16u, 4u,
                      {1u, 2u, 3u, 4u}, 2400u, 1u, 1u, 0u}};
        AlkDs5Profile profile = {
            .struct_size = sizeof(profile), .abi = ALK_DS5_CORE_ABI_VERSION,
            .vendor_id = 0x054c, .product_id = 0x0ce6,
            .transport = ALK_DS5_TRANSPORT_USB, .max_devices = 1,
            .product_string = "DualSense", .manufacturer = "Sony",
            .backend_evidence = &evidence};
        if (alk_ds5_core_create(&profile, &_ds5Core[player]) != ALK_DS5_OK) return NULL;
        AlkDs5Event event = {.struct_size = sizeof(event), .abi = ALK_DS5_CORE_ABI_VERSION};
        if (alk_ds5_core_arrive(_ds5Core[player], 0, &event) != ALK_DS5_OK) {
            alk_ds5_core_destroy(_ds5Core[player]);
            _ds5Core[player] = NULL;
            return NULL;
        }
        _ds5Sequence[player] = event.sequence;
        (void)alk_ds5_core_begin_session(_ds5Core[player], 1u);
    }
    return _ds5Core[player];
}

// The core is not thread safe: raw HID input arrives on the HID queue, feedback on the
// main queue, IR and PCM on the control thread. Nothing on this client reads core events,
// so they are discarded here to keep the bounded queue from rejecting later submissions.
- (AlkDs5Error)withDS5CoreForPlayer:(NSUInteger)player call:(AlkDs5Error (NS_NOESCAPE ^)(AlkDs5Core *core))call {
    AlkDs5Error result = ALK_DS5_ERROR_NOT_FOUND;
    os_unfair_lock_lock(&_ds5CoreLock);
    AlkDs5Core *core = [self ds5CoreForPlayer:player];
    if (core != NULL) {
        result = call(core);
        AlkDs5Event discarded = {.struct_size = sizeof(discarded), .abi = ALK_DS5_CORE_ABI_VERSION};
        while (alk_ds5_core_poll_event(core, &discarded) == ALK_DS5_OK) {}
    }
    os_unfair_lock_unlock(&_ds5CoreLock);
    return result;
}

// TEMPORARY, for test builds: remove the [ds5-diag] lines (this function, noteDS5InputSent,
// noteDS5GCGyroPeak and the _diag* state) once the DualSense options are settled.
// Test-build measurement: how long a raw report's change takes to reach the send path, and
// the gyro scale GameController delivers against the report's nominal 1024 counts per deg/s.
- (void)flushDS5DiagLockedAt:(CFAbsoluteTime)now {
    if (now - _diagLastLog < 1.0) {
        os_unfair_lock_unlock(&_ds5CoreLock);
        return;
    }
    const BOOL inputActive = _diagLagCount != 0 || _diagRawGyroPeak >= 5.0 || _diagGCGyroPeak >= 5.0 ||
                             _rawImuRate != 0 || _gcMotionRate != 0;
    double avg = _diagLagCount != 0 ? _diagLagSum / _diagLagCount : 0.0, max = _diagLagMax;
    uint32_t count = _diagLagCount;
    double rawPeak = _diagRawGyroPeak, gcPeak = _diagGCGyroPeak;
    uint8_t steps = _diagRawBatterySteps, charging = _diagRawCharging, percent = _diagGCBatteryPercent;
    unsigned rawRate = _rawImuRate, gcRate = _gcMotionRate, sentRate = _gyroSentRate;
    unsigned hostGyro = _motionGyroRate[0], hostAccel = _motionAccelRate[0];
    int source = (int)_motionSourceEffective;
    DS5RawHIDBridge *bridge = _rawHID;
    NSString *transportIdentity = _rawHIDIdentity[0];
    _diagLagSum = _diagLagMax = _diagRawGyroPeak = _diagGCGyroPeak = 0.0;
    _diagLagCount = 0;
    _diagLastLog = now;
    os_unfair_lock_unlock(&_ds5CoreLock);
    // The output counters of the same second, so one log shows the input and the output rates side by side.
    const DS5OutputStats out = bridge != nil ? [bridge takeOutputStats] : (DS5OutputStats){0};
    const BOOL outputActive = out.requested != 0 || out.written != 0 || out.failed != 0;
    if (!inputActive && !outputActive) return;
    Log(LOG_I, @"[ds5-diag] rawToSend avgMs=%.1f maxMs=%.1f n=%u gyroPeakDegS raw=%.0f gc=%.0f battery raw=%u/10 charging=%u gc=%u%% out req=%u wr=%u merged=%u same=%u fail=%u pulsesWritten=%u kept=%u dropped=%u maxWriteMs=%.1f",
        avg * 1000.0, max * 1000.0, count, rawPeak, gcPeak, steps, charging, percent,
        out.requested, out.written, out.merged, out.identical, out.failed, out.pulses, out.kept, out.dropped, out.maxWriteMs);
    if (rawRate != 0 || gcRate != 0 || sentRate != 0) {
        Log(LOG_I, @"[ds5-diag] motion rawImu/s=%u gcMotion/s=%u gyroSent/s=%u source=%@ transport=%@ hostAsks gyro=%uHz accel=%uHz",
            rawRate, gcRate, sentRate, source == DS5_MOTION_SOURCE_RAW ? @"raw" : @"gamecontroller",
            [bridge transportNameForIdentity:transportIdentity], hostGyro, hostAccel);
    }
}

- (void)noteDS5InputSent {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    os_unfair_lock_lock(&_ds5CoreLock);
    if (_diagRawChangedAt != 0) {
        double lag = now - _diagRawChangedAt;
        _diagRawChangedAt = 0;
        if (lag >= 0 && lag < 2.0) {
            _diagLagSum += lag;
            _diagLagMax = MAX(_diagLagMax, lag);
            _diagLagCount++;
        }
    }
    [self flushDS5DiagLockedAt:now];
}

- (void)noteDS5GCGyroPeak:(double)degreesPerSecond {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    os_unfair_lock_lock(&_ds5CoreLock);
    _diagGCGyroPeak = MAX(_diagGCGyroPeak, degreesPerSecond);
    [self flushDS5DiagLockedAt:now];
}

// The pad address of a raw device: from its feature 0x09 when that was read, else from a serial that is an address.
- (NSString *)padKeyForIdentity:(NSString *)identity {
    if (identity.length == 0) return nil;
    os_unfair_lock_lock(&_ds5CoreLock);
    NSString *known = _rawAddressKey[identity];
    os_unfair_lock_unlock(&_ds5CoreLock);
    if (known != nil) return known;
    char key[13];
    return ds5_serial_key(identity.UTF8String, key) ? [NSString stringWithUTF8String:key] : nil;
}

// Feature 0x09 of a raw device arrived with the pad's address: when another device of the same address is already a raw pad,
// only one of them stays, the USB one (in the lower player number of the two).
- (void)noteRawPadAddress:(NSString *)key forIdentity:(NSString *)identity {
    NSString *snapshot[16] = {nil};
    os_unfair_lock_lock(&_ds5CoreLock);
    if (_rawAddressKey == nil) _rawAddressKey = [NSMutableDictionary dictionary];
    _rawAddressKey[identity] = key;
    for (NSUInteger index = 0; index < 16; index++) snapshot[index] = _rawHIDIdentity[index];
    os_unfair_lock_unlock(&_ds5CoreLock);
    NSUInteger mine = NSNotFound, other = NSNotFound;
    for (NSUInteger index = 0; index < 16; index++) {
        if (snapshot[index] == nil) continue;
        if ([snapshot[index] isEqualToString:identity]) { mine = index; continue; }
        NSString *otherKey = [self padKeyForIdentity:snapshot[index]];
        if ([otherKey isEqualToString:key] && other == NSNotFound) other = index;
    }
    if (mine == NSNotFound || other == NSNotFound) return;
    const BOOL mineUSB = [_rawHID isUSBDeviceForIdentity:identity];
    const BOOL otherUSB = [_rawHID isUSBDeviceForIdentity:snapshot[other]];
    const BOOL keepMine = mineUSB && !otherUSB;                 // the USB device wins; ties keep the older one
    NSString *keeper = keepMine ? identity : snapshot[other];
    NSString *loser = keepMine ? snapshot[other] : identity;
    const NSUInteger keeperSlot = keepMine ? mine : other, loserSlot = keepMine ? other : mine;
    const NSUInteger lowSlot = MIN(keeperSlot, loserSlot), highSlot = MAX(keeperSlot, loserSlot);
    const double now = [NSProcessInfo processInfo].systemUptime;
    os_unfair_lock_lock(&_ds5CoreLock);
    if ([_rawHIDIdentity[mine] isEqualToString:identity] && [_rawHIDIdentity[other] isEqualToString:snapshot[other]]) {
        if (_rawTwinIgnored == nil) _rawTwinIgnored = [NSMutableDictionary dictionary];
        _rawTwinIgnored[loser] = @(now);
        _rawHIDIdentity[lowSlot] = [keeper copy];
        _rawHIDIdentity[highSlot] = nil;
    }
    os_unfair_lock_unlock(&_ds5CoreLock);
    Log(LOG_I, @"[ds5-hid] the raw devices %@ (%@) and %@ (%@) are one pad (address %@): %@ is kept as player %lu, the other is ignored",
        identity, mineUSB ? @"USB" : @"not USB", snapshot[other], otherUSB ? @"USB" : @"not USB", key, keeper, (unsigned long)lowSlot);
}

- (NSUInteger)rawHIDPlayerForIdentity:(NSString *)identity {
    NSUInteger player = NSNotFound;
    NSString *assigned[16] = {nil};
    BOOL ignoredRecently = NO;
    const double now = [NSProcessInfo processInfo].systemUptime;
    os_unfair_lock_lock(&_ds5CoreLock);
    for (NSUInteger index = 0; index < 16; index++) {
        assigned[index] = _rawHIDIdentity[index];
        if ([_rawHIDIdentity[index] isEqualToString:identity]) player = index;
    }
    if (player == NSNotFound) {
        NSNumber *checked = _rawTwinIgnored[identity];
        ignoredRecently = checked != nil && now - checked.doubleValue < 1.0;
    }
    os_unfair_lock_unlock(&_ds5CoreLock);
    if (player != NSNotFound) return player;
    if (ignoredRecently) return NSNotFound;

    // Is this the other transport of a pad that already has a raw device?
    NSString *key = [self padKeyForIdentity:identity];
    NSUInteger twin = NSNotFound;
    if (key != nil) {
        for (NSUInteger index = 0; index < 16; index++) {
            if (assigned[index] != nil && ![assigned[index] isEqualToString:identity] && [[self padKeyForIdentity:assigned[index]] isEqualToString:key]) { twin = index; break; }
        }
    }
    DS5TwinDecision decision = DS5_TWIN_NONE;
    if (twin != NSNotFound) {
        decision = ds5_twin_decide(true, [_rawHID hasDeviceForIdentity:assigned[twin]],
                                   [_rawHID isUSBDeviceForIdentity:identity], [_rawHID isUSBDeviceForIdentity:assigned[twin]]);
    }
    os_unfair_lock_lock(&_ds5CoreLock);
    if (_rawTwinIgnored == nil) _rawTwinIgnored = [NSMutableDictionary dictionary];
    if (decision == DS5_TWIN_IGNORE_NEW) {
        const BOOL first = _rawTwinIgnored[identity] == nil;
        _rawTwinIgnored[identity] = @(now);
        os_unfair_lock_unlock(&_ds5CoreLock);
        if (first) Log(LOG_I, @"[ds5-hid] %@ is the other transport of the pad already served as player %lu (same address %@): its reports are ignored",
                       identity, (unsigned long)twin, key);
        return NSNotFound;
    }
    if (decision == DS5_TWIN_REPLACE_OLD && [_rawHIDIdentity[twin] isEqualToString:assigned[twin]]) {
        _rawTwinIgnored[assigned[twin]] = @(now);
        _rawHIDIdentity[twin] = [identity copy];
        [_rawTwinIgnored removeObjectForKey:identity];
        player = twin;
        os_unfair_lock_unlock(&_ds5CoreLock);
        Log(LOG_I, @"[ds5-hid] %@ (USB) takes the place of its Bluetooth twin %@ as player %lu (same address %@)",
            identity, assigned[twin], (unsigned long)twin, key);
        return player;
    }
    [_rawTwinIgnored removeObjectForKey:identity];
    for (NSUInteger index = 0; index < 16; index++) {
        if ([_rawHIDIdentity[index] isEqualToString:identity]) { player = index; break; }
    }
    if (player == NSNotFound) {
        for (NSUInteger index = 0; index < 16; index++) {
            if (_rawHIDIdentity[index] == nil) { _rawHIDIdentity[index] = [identity copy]; player = index; break; }
        }
    }
    os_unfair_lock_unlock(&_ds5CoreLock);
    return player;
}

- (NSString *)rawHIDIdentityForPlayer:(NSUInteger)player {
    if (player >= 16) return nil;
    os_unfair_lock_lock(&_ds5CoreLock);
    NSString *identity = _rawHIDIdentity[player];
    os_unfair_lock_unlock(&_ds5CoreLock);
    return identity;
}

// Closes the one-second sample window and chooses the motion source for the next one. Called with
// _ds5CoreLock held, from whichever source delivers a sample first.
- (void)rollMotionWindowLockedAt:(double)now {
    if (_motionWindowStart == 0.0) {
        _motionWindowStart = now;
        return;
    }
    if (now - _motionWindowStart < 1.0) return;
    _rawImuRate = _rawImuWindow;
    _gcMotionRate = _gcMotionWindow;
    _gyroSentRate = _gyroSentWindow;
    _rawImuWindow = _gcMotionWindow = _gyroSentWindow = 0;
    _motionWindowStart = now;
    NSUInteger rawDevices = 0;
    for (NSUInteger index = 0; index < 16; index++) {
        if (_rawHIDIdentity[index] != nil) rawDevices++;
    }
    // The raw report is tied to a player only by arrival order, so it is used for one controller only.
    const unsigned minimum = 60;
    if (rawDevices != 1) {
        _motionSourceEffective = DS5_MOTION_SOURCE_GAMECONTROLLER;
    } else if (self.controllerMotionSource == 1) {
        _motionSourceEffective = DS5_MOTION_SOURCE_GAMECONTROLLER;
    } else if (self.controllerMotionSource == 2) {
        _motionSourceEffective = _rawImuRate >= minimum ? DS5_MOTION_SOURCE_RAW : DS5_MOTION_SOURCE_GAMECONTROLLER;
    } else {
        _motionSourceEffective = ds5_motion_select_source(_motionSourceEffective, _rawImuRate, _gcMotionRate, minimum);
    }
}

// A GameController motion sample arrived. Returns whether it is the source that should be sent.
- (BOOL)noteGCMotionSampleShouldSend {
    const double now = [NSProcessInfo processInfo].systemUptime;
    os_unfair_lock_lock(&_ds5CoreLock);
    _gcMotionWindow++;
    [self rollMotionWindowLockedAt:now];
    BOOL send = _motionSourceEffective == DS5_MOTION_SOURCE_GAMECONTROLLER;
    os_unfair_lock_unlock(&_ds5CoreLock);
    return send;
}

- (void)noteGyroSent {
    os_unfair_lock_lock(&_ds5CoreLock);
    _gyroSentWindow++;
    os_unfair_lock_unlock(&_ds5CoreLock);
}

- (PML_CONTROL_STREAM_CONTEXT)ds5ControlContext {
    PML_INPUT_STREAM_CONTEXT input = ControllerInputContext(self);
    if (input == NULL || !LiInputContextIsInitialized(input) || input->connectionContext == NULL) return NULL;
    return &input->connectionContext->controlContext;
}

- (void)handleRawHIDInput:(NSString *)identity input:(const AlkDs5ExtendedInput *)input {
    if (input == NULL) return;
    NSUInteger player = [self rawHIDPlayerForIdentity:identity];
    if (player == NSNotFound) return;
    const double uptime = [NSProcessInfo processInfo].systemUptime;
    __block BOOL sendGyro = NO, sendAccel = NO, sendJack = NO, muteChanged = NO, muteNow = NO;
    __block DS5Vec3 gyroDps = {{0, 0, 0}}, accelMs2 = {{0, 0, 0}};
    __block NSString *motionLog = nil;
    __block uint8_t jackHeadset = 0, jackMicrophone = 0, jackMuted = 0;
    __block BOOL padAudioReconfigure = NO;
    (void)[self withDS5CoreForPlayer:player call:^AlkDs5Error(AlkDs5Core *core) {
        AlkDs5State state = input->state;
        const uint8_t sticks[4] = {state.left_x, state.left_y, state.right_x, state.right_y};
        BOOL changed = state.buttons != self->_diagRawButtons;
        for (int axis = 0; axis < 4; axis++) changed = changed || abs((int)sticks[axis] - (int)self->_diagRawSticks[axis]) >= 4;
        if (changed) {
            memcpy(self->_diagRawSticks, sticks, sizeof(sticks));
            self->_diagRawButtons = state.buttons;
            if (self->_diagRawChangedAt == 0) self->_diagRawChangedAt = CFAbsoluteTimeGetCurrent();
        }
        for (int axis = 0; axis < 3; axis++) {
            self->_diagRawGyroPeak = MAX(self->_diagRawGyroPeak,
                                         fabs((double)ds5_raw_gyro_dps(&self->_imuCalibration[player], axis, input->motion.gyro[axis])));
        }
        self->_diagRawBatterySteps = input->battery.level_steps;
        self->_diagRawCharging = input->battery.charging_state;
        state.struct_size = sizeof(state);
        state.abi = ALK_DS5_CORE_ABI_VERSION;
        state.device_index = 0;
        state.sequence = ++self->_ds5Sequence[player];
        AlkDs5Event event = {.struct_size = sizeof(event), .abi = ALK_DS5_CORE_ABI_VERSION};
        (void)alk_ds5_core_submit_state(core, &state, &event);
        for (NSUInteger index = 0; index < 2; index++) {
            AlkDs5TouchObservation touch = {
                .struct_size = sizeof(touch), .abi = ALK_DS5_CORE_ABI_VERSION,
                .device_index = 0, .sequence = state.sequence,
                .contact_id = input->touch[index].contact_id,
                .active = input->touch[index].active,
                .x = input->touch[index].x, .y = input->touch[index].y,
                .pressure = input->touch[index].pressure};
            (void)alk_ds5_core_submit_touch(core, &touch);
        }
        AlkDs5MotionObservation motion = {
            .struct_size = sizeof(motion), .abi = ALK_DS5_CORE_ABI_VERSION,
            .device_index = 0, .sequence = state.sequence,
            .gyro = {input->motion.gyro[0], input->motion.gyro[1], input->motion.gyro[2]},
            .accelerometer = {input->motion.accelerometer[0], input->motion.accelerometer[1], input->motion.accelerometer[2]},
            .sensor_timestamp = input->motion.sensor_timestamp};
        (void)alk_ds5_core_submit_motion(core, &motion);
        AlkDs5BatteryObservation battery = {
            .struct_size = sizeof(battery), .abi = ALK_DS5_CORE_ABI_VERSION,
            .device_index = 0, .sequence = state.sequence,
            .level_steps = input->battery.level_steps, .charging_state = input->battery.charging_state,
            .full = input->battery.full};
        (void)alk_ds5_core_submit_battery(core, &battery);
        AlkDs5JackObservation jack = {
            .struct_size = sizeof(jack), .abi = ALK_DS5_CORE_ABI_VERSION,
            .device_index = 0, .sequence = state.sequence,
            .headset_present = input->jack.headset_present,
            .microphone_present = input->jack.microphone_present,
            .microphone_muted = input->jack.microphone_muted};
        (void)alk_ds5_core_submit_jack(core, &jack);

        // The Mute button exists only in the raw report. A change is handed to the main queue below.
        muteNow = ds5_raw_mute_pressed(input->state.buttons);
        if (ds5_mute_changed(self->_rawMute[player], muteNow)) {
            self->_rawMute[player] = muteNow;
            muteChanged = YES;
        }

        // The headset the real pad reports decides the output path of pad audio; a change rewrites the pad's audio bytes.
        {
            const int headsetNow = input->jack.headset_present ? 1 : 0;
            const BOOL wanted = self->_padAudioSeen[player] || self->_padSpeakerStream || [self padAudioSelfTestWanted];
            if (self->_padHeadset[player] != headsetNow) {
                self->_padHeadset[player] = headsetNow;
                if (wanted) padAudioReconfigure = YES;
            } else if (wanted && !self->_padAudioConfigured[player]) {
                padAudioReconfigure = YES;
            }
            if (padAudioReconfigure) self->_padAudioConfigured[player] = YES;  // queued once, not once per report
        }

        // Raw sensor path: the sample is converted on the spot and sent after the lock is released.
        self->_rawImuWindow++;
        [self rollMotionWindowLockedAt:uptime];
        if (self->_motionSourceEffective == DS5_MOTION_SOURCE_RAW) {
            const DS5ImuCalibration *calibration = &self->_imuCalibration[player];
            if (ds5_motion_due(uptime, self->_rawLastGyroSent[player], self->_motionGyroRate[player])) {
                self->_rawLastGyroSent[player] = uptime;
                for (int axis = 0; axis < 3; axis++) gyroDps.v[axis] = ds5_raw_gyro_wire_dps(input->motion.gyro[axis]);
                sendGyro = YES;
                self->_gyroSentWindow++;
            }
            if (ds5_motion_due(uptime, self->_rawLastAccelSent[player], self->_motionAccelRate[player])) {
                self->_rawLastAccelSent[player] = uptime;
                for (int axis = 0; axis < 3; axis++) accelMs2.v[axis] = ds5_raw_accel_wire_ms2(input->motion.accelerometer[axis]);
                sendAccel = YES;
            }
        }

        // Low-rate log of the raw report next to what goes on the wire (once a second while the pad moves,
        // every five seconds at rest).
        {
            const double magnitude = sqrt((double)input->motion.gyro[0] * input->motion.gyro[0] +
                                          (double)input->motion.gyro[1] * input->motion.gyro[1] +
                                          (double)input->motion.gyro[2] * input->motion.gyro[2]);
            if (magnitude >= self->_mlRawPeak) {
                self->_mlRawPeak = magnitude;
                for (int axis = 0; axis < 3; axis++) {
                    self->_mlRawGyro[axis] = input->motion.gyro[axis];
                    self->_mlRawAccel[axis] = input->motion.accelerometer[axis];
                    self->_mlWireGyro[axis] = ds5_raw_gyro_wire_dps(input->motion.gyro[axis]);
                    self->_mlWireAccel[axis] = ds5_raw_accel_wire_ms2(input->motion.accelerometer[axis]);
                    self->_mlCalGyro[axis] = ds5_raw_gyro_dps(&self->_imuCalibration[player], axis, input->motion.gyro[axis]);
                }
            }
            const BOOL moving = self->_mlRawPeak >= 3.0 * DS5_WIRE_GYRO_COUNTS_PER_DPS;
            if (uptime - self->_motionLogLast >= 1.0 && (moving || uptime - self->_motionLogIdleLast >= 5.0)) {
                const float gain = (float)self.gyroSensitivity;
                motionLog = [NSString stringWithFormat:
                    @"[ds5-motion] source=%@ rates raw=%u gc=%u sent=%u | real report gyro counts %d %d %d accel counts %d %d %d"
                    @" | wire gyro deg/s %.2f %.2f %.2f x client gain %.2f -> host counts %ld %ld %ld (calibrated deg/s would be %.2f %.2f %.2f)"
                    @" | wire accel m/s2 %.2f %.2f %.2f"
                    @" | latest GameController rotation rad/s %.3f %.3f %.3f accel g %.3f %.3f %.3f -> wire deg/s %.2f %.2f %.2f",
                    self->_motionSourceEffective == DS5_MOTION_SOURCE_RAW ? @"raw" : @"gamecontroller",
                    self->_rawImuRate, self->_gcMotionRate, self->_gyroSentRate,
                    self->_mlRawGyro[0], self->_mlRawGyro[1], self->_mlRawGyro[2],
                    self->_mlRawAccel[0], self->_mlRawAccel[1], self->_mlRawAccel[2],
                    self->_mlWireGyro[0], self->_mlWireGyro[1], self->_mlWireGyro[2], gain,
                    lrintf(self->_mlWireGyro[0] * gain * 16.4f), lrintf(self->_mlWireGyro[1] * gain * 16.4f), lrintf(self->_mlWireGyro[2] * gain * 16.4f),
                    self->_mlCalGyro[0], self->_mlCalGyro[1], self->_mlCalGyro[2],
                    self->_mlWireAccel[0], self->_mlWireAccel[1], self->_mlWireAccel[2],
                    self->_mlGCRot[0], self->_mlGCRot[1], self->_mlGCRot[2], self->_mlGCAcc[0], self->_mlGCAcc[1], self->_mlGCAcc[2],
                    self->_mlGCProto[0], self->_mlGCProto[1], self->_mlGCProto[2]];
                self->_motionLogLast = uptime;
                if (!moving) self->_motionLogIdleLast = uptime;
                self->_mlRawPeak = 0.0;
            }
        }

        // Headset and microphone facts go to the host when they change, and again every few seconds so a
        // host that created the virtual controller later still learns them.
        if (self.ds5ReportHeadset) {
            const CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            const BOOL stale = !self->_sentJack[player].valid || now - self->_sentJack[player].sentAt > 5.0;
            if (stale || self->_sentJack[player].headset != input->jack.headset_present ||
                self->_sentJack[player].microphone != input->jack.microphone_present ||
                self->_sentJack[player].muted != input->jack.microphone_muted) {
                sendJack = YES;
                jackHeadset = input->jack.headset_present;
                jackMicrophone = input->jack.microphone_present;
                jackMuted = input->jack.microphone_muted;
            }
        }
        return ALK_DS5_OK;
    }];

    if (motionLog != nil) Log(LOG_I, @"%@", motionLog);
    if (padAudioReconfigure) {
        __weak typeof(self) weakSelf = self;
        const NSUInteger audioPlayer = player;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf configurePadAudioForPlayer:audioPlayer]; });
    }
    if (muteChanged) {
        const BOOL pressed = muteNow;
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            ControllerSupport *strongSelf = weakSelf;
            Controller *controller = strongSelf != nil ? [strongSelf->_controllers objectForKey:@(player)] : nil;
            if (controller == nil) return;
            controller.rawMuteButton = pressed;
            [strongSelf updateFinished:controller];
            // The pad's firmware flips its own mute LED on the button. The LED follows the virtual device:
            // what the game last asked for, off when it never asked.
            if (pressed && strongSelf.ds5ApplyHostLights) [strongSelf assertMuteLEDForPlayer:(unsigned short)player];
        });
    }
    if (sendGyro || sendAccel) {
        PML_INPUT_STREAM_CONTEXT inputCtx = ControllerInputContext(self);
        if (inputCtx != NULL && self->_shouldSendInputEvents && LiInputContextIsInitialized(inputCtx)) {
            if (sendAccel) LiSendControllerMotionEventCtx(inputCtx, (uint8_t)player, LI_MOTION_TYPE_ACCEL,
                                                          accelMs2.v[0], accelMs2.v[1], accelMs2.v[2]);
            if (sendGyro) {
                const float gyroGain = (float)self.gyroSensitivity;
                LiSendControllerMotionEventCtx(inputCtx, (uint8_t)player, LI_MOTION_TYPE_GYRO,
                                               gyroDps.v[0] * gyroGain, gyroDps.v[1] * gyroGain, gyroDps.v[2] * gyroGain);
            }
        }
    }
    if (sendJack) {
        PML_CONTROL_STREAM_CONTEXT control = [self ds5ControlContext];
        // The library refuses (LI_ERR_UNSUPPORTED) until the host has declared input-status=1, so a host
        // that never did sees nothing and the next report asks again.
        if (control != NULL && LiSendDs5InputStatusCtx(control, (uint16_t)player,
                LI_DS5_IN_HEADSET | LI_DS5_IN_MICROPHONE | LI_DS5_IN_MIC_MUTED,
                jackHeadset, jackMicrophone, jackMuted) == 0) {
            os_unfair_lock_lock(&_ds5CoreLock);
            _sentJack[player].valid = YES;
            _sentJack[player].headset = jackHeadset;
            _sentJack[player].microphone = jackMicrophone;
            _sentJack[player].muted = jackMuted;
            _sentJack[player].sentAt = CFAbsoluteTimeGetCurrent();
            os_unfair_lock_unlock(&_ds5CoreLock);
            Log(LOG_I, @"[ds5-ext] input status sent player=%lu headset=%u microphone=%u muted=%u",
                (unsigned long)player, jackHeadset, jackMicrophone, jackMuted);
        }
    }
}

- (void)handleRawHIDFeature:(NSString *)identity reportID:(uint8_t)reportID
                     report:(const uint8_t *)report length:(size_t)length {
    // The bytes the real pad answers to a read-only GET_REPORT, once per attach. The virtual pad on the host
    // takes its default answers from these.
    {
        NSMutableString *dump = [NSMutableString stringWithCapacity:length * 2];
        for (size_t index = 0; index < length && index < 96; index++) [dump appendFormat:@"%02x", report[index]];
        Log(LOG_I, @"[ds5-feature] real pad report 0x%02x length %zu: %@", reportID, length, dump);
    }
    if (reportID == 0x09 && length >= 7) {
        char text[13];
        snprintf(text, sizeof text, "%02x%02x%02x%02x%02x%02x", report[1], report[2], report[3], report[4], report[5], report[6]);
        [self noteRawPadAddress:[NSString stringWithUTF8String:text] forIdentity:identity];
    }
    NSUInteger player = [self rawHIDPlayerForIdentity:identity];
    if (player == NSNotFound) return;
    if (reportID == ALK_DS5_FEATURE_CALIBRATION_ID) {
        DS5ImuCalibration calibration;
        const bool factory = ds5_imu_calibration_from_report(report, length, &calibration);
        os_unfair_lock_lock(&_ds5CoreLock);
        _imuCalibration[player] = calibration;
        os_unfair_lock_unlock(&_ds5CoreLock);
        Log(LOG_I, @"[ds5-ext] imu calibration player=%lu factory=%d gyroSensitivity=%.1f,%.1f,%.1f", (unsigned long)player,
            factory, calibration.sensitivity[0], calibration.sensitivity[1], calibration.sensitivity[2]);
    }
    (void)[self withDS5CoreForPlayer:player call:^AlkDs5Error(AlkDs5Core *core) {
        return alk_ds5_core_set_feature_report_for_device(core, 0, reportID, report, length);
    }];
}

- (void)setShouldSendInputEvents:(BOOL)enabled {
    BOOL wasEnabled = _shouldSendInputEvents;
    _shouldSendInputEvents = enabled;
    if (wasEnabled && !enabled) {
        [_dualSenseTouchpad releaseAll];
        for (Controller *controller in _controllers.allValues) {
            ControllerMenuGesture gesture = controller.menuGesture;
            ControllerMenuGestureInterrupt(&gesture, controller.gamepad.extendedGamepad.buttonMenu.pressed);
            controller.menuGesture = gesture;
        }
        PML_INPUT_STREAM_CONTEXT input = ControllerInputContext(self);
        if (input != NULL && LiInputContextIsInitialized(input)) {
            [_controllerStreamLock lock];
            for (Controller *controller in _controllers.allValues) {
                // A pad that is gone, or that the host never heard of, gets nothing: a neutral event would
                // create it on the host.
                if (!ds5_pad_may_send(controller.gamepad != nil, controller.controllerAnnounced)) continue;
                // The host holds the last rotation rate it was given. GameController stops reporting
                // while the app is not active, so without this a game keeps turning on its own.
                BOOL gyroRequested = NO;
                @synchronized (controller) {
                    gyroRequested = controller.gyroReportRateHz > 0;
                }
                if (gyroRequested) {
                    LiSendControllerMotionEventCtx(input, (uint8_t)(_multiController ? controller.playerIndex : 0),
                                                   LI_MOTION_TYPE_GYRO, 0.0f, 0.0f, 0.0f);
                }
                LiSendMultiControllerEventCtx(input, _multiController ? controller.playerIndex : 0,
                    _multiController ? (unsigned char)_controllerNumbers : 1, 0, 0, 0, 0, 0, 0, 0);
                if (controller.trackpadMouseButton != 0)
                    LiSendMouseButtonEventCtx(input, BUTTON_ACTION_RELEASE, controller.trackpadMouseButton);
                controller.hasSentGamepadState = NO;
                ResetControllerTrackpadMouseState(controller);
            }
            [_controllerStreamLock unlock];
            Log(LOG_I, @"[controller] Neutral input sent before pausing controller delivery");
        }
    } else if (!wasEnabled && enabled) {
        for (Controller *controller in _controllers.allValues) {
            controller.hasSentGamepadState = NO;
            [self updateFinished:controller];
        }
    }
}

+ (BOOL)hasDualSenseController
{
    if (@available(macOS 11.0, *)) {
        for (GCController *controller in GCController.controllers) {
            if ([controller.extendedGamepad isKindOfClass:[GCDualSenseGamepad class]]) {
                return YES;
            }
        }
    }
    return NO;
}

- (void)setGamepadMouseModeLongPressMenuEnabled:(BOOL)enabled {
    if (_gamepadMouseModeLongPressMenuEnabled == enabled) return;
    _gamepadMouseModeLongPressMenuEnabled = enabled;
    for (Controller *controller in [_controllers allValues]) {
        ControllerMenuGesture gesture = controller.menuGesture;
        ControllerMenuGestureInterrupt(&gesture, controller.gamepad.extendedGamepad.buttonMenu.pressed);
        controller.menuGesture = gesture;
    }
}

- (void)setGamepadMouseModeActive:(BOOL)active forController:(Controller *)controller {
    if (controller.isMouseMode == active) return;
    PML_INPUT_STREAM_CONTEXT input = ControllerInputContext(self);
    if (input) {
        if (controller.lastMouseModeButtonFlags & A_FLAG)
            LiSendMouseButtonEventCtx(input, BUTTON_ACTION_RELEASE, BUTTON_LEFT);
        if (controller.lastMouseModeButtonFlags & B_FLAG)
            LiSendMouseButtonEventCtx(input, BUTTON_ACTION_RELEASE, BUTTON_RIGHT);
    }
    controller.lastMouseModeButtonFlags = 0;
    controller.isMouseMode = active;
    _accumulatedMouseX = 0;
    _accumulatedMouseY = 0;
    GCExtendedGamepad *gamepad = controller.gamepad.extendedGamepad;
    // Restore only controls affected by mouse emulation. Calling the complete
    // input handler here would also feed a held Menu into its debouncer.
    @synchronized(controller) {
        controller.lastButtonFlags &= ~(A_FLAG | B_FLAG);
        if (!active && gamepad.buttonA.pressed) controller.lastButtonFlags |= A_FLAG;
        if (!active && gamepad.buttonB.pressed) controller.lastButtonFlags |= B_FLAG;
    }
    [self updateRightStick:controller
        x:active ? 0 : (short)(gamepad.rightThumbstick.xAxis.value * 0x7FFE)
        y:active ? 0 : (short)(gamepad.rightThumbstick.yAxis.value * 0x7FFE)];
    [self updateFinished:controller];
}

- (void)setGamepadMouseModeEnabled:(BOOL)enabled {
    if (_gamepadMouseModeEnabled == enabled) return;
    _gamepadMouseModeEnabled = enabled;
    for (Controller *controller in [_controllers allValues]) {
        if (![controller.gamepad.extendedGamepad isKindOfClass:GCDualSenseGamepad.class]) {
            ControllerMenuGesture gesture = controller.menuGesture;
            ControllerMenuGestureInterrupt(&gesture, controller.gamepad.extendedGamepad.buttonMenu.pressed);
            controller.menuGesture = gesture;
        }
        if (!enabled && controller.isMouseMode) {
            [self setGamepadMouseModeActive:NO forController:controller];
            if ([_presenceDelegate respondsToSelector:@selector(mouseModeToggled:)])
                [_presenceDelegate mouseModeToggled:NO];
        }
    }
}

// UPDATE_BUTTON_FLAG(controller, flag, pressed)
#define UPDATE_BUTTON_FLAG(controller, x, y) \
((y) ? [self setButtonFlag:controller flags:x] : [self clearButtonFlag:controller flags:x])

- (DS5BluetoothMode)bluetoothHapticsMode {
    return ds5_resolve_bluetooth_mode((int)_ds5BtHapticsFallback, (int)_ds5BtOutput, NULL);
}

// Whether rumble may be played on this pad: key 10/100 "off" silences a DualSense that is not on USB.
- (BOOL)bluetoothPolicyAllowsRumbleForPlayer:(unsigned short)controllerNumber {
    if (ds5_bluetooth_allows_rumble([self bluetoothHapticsMode])) return YES;
    Controller *controller = [_controllers objectForKey:@(controllerNumber)];
    if (![controller.gamepad.extendedGamepad isKindOfClass:[GCDualSenseGamepad class]]) return YES;
    return [_rawHID isUSBDeviceForIdentity:[self rawHIDIdentityForPlayer:controllerNumber]];
}

static double RumbleNowMs(void) { return CFAbsoluteTimeGetCurrent() * 1000.0; }

// Host rumble arrives on the control thread and is played on the main queue, which also delivers the GameController
// input. Input never waits for it: the control thread only appends to a bounded ring and schedules one drain.
// The drain feeds every value, in order, to the pulse scheduler (DS5RumbleScheduler.h), which applies a start at
// once and holds it for a minimum length, defers an early stop to the end of the hold and keeps the louder value
// of each motor inside the hold. So a menu tick that starts and stops between two drains is still played.
- (void)drainPendingRumble {
    unsigned short low[16][32], high[16][32];
    BOOL direct[16][32];
    unsigned count[16];
    @synchronized(_hapticsMailboxLock) {
        for (NSUInteger index = 0; index < 16; index++) {
            count[index] = _rumbleEventCount[index];
            for (unsigned item = 0; item < count[index]; item++) {
                low[index][item] = _rumbleEvents[index][item].low;
                high[index][item] = _rumbleEvents[index][item].high;
                direct[index][item] = _rumbleEvents[index][item].direct;
            }
            _rumbleEventCount[index] = 0;
        }
        _rumbleDrainScheduled = NO;
    }
    if (!self.shouldSendInputEvents) return;
    for (NSUInteger index = 0; index < 16; index++) {
        for (unsigned item = 0; item < count[index]; item++) {
            if (direct[index][item]) {
                // A value computed on the client (the PCM fallback): played as it is, and the pulse state starts over.
                ds5_rs_reset(&_rumbleSched[index]);
                [self applyRumbleNow:(unsigned short)index lowFreqMotor:low[index][item] highFreqMotor:high[index][item]];
                continue;
            }
            const DS5RumbleAction action = ds5_rs_event(&_rumbleSched[index], RumbleNowMs(), low[index][item], high[index][item]);
            if (action.apply) [self applyRumbleNow:(unsigned short)index lowFreqMotor:action.low highFreqMotor:action.high];
        }
        [self scheduleRumbleTickForPlayer:index];
    }
    [self logRumbleWindow];
}

// One timer per player at most: it fires when a held pulse may end.
- (void)scheduleRumbleTickForPlayer:(NSUInteger)player {
    const double due = ds5_rs_next_due(&_rumbleSched[player]);
    if (due < 0.0) return;
    const unsigned generation = ++_rumbleTimerGeneration[player];
    const double wait = due - RumbleNowMs();
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(fmax(0.0, wait) * (double)NSEC_PER_MSEC) + 500000), dispatch_get_main_queue(), ^{
        ControllerSupport *strongSelf = weakSelf;
        if (strongSelf == nil || strongSelf->_rumbleTimerGeneration[player] != generation) return;
        const DS5RumbleAction action = ds5_rs_tick(&strongSelf->_rumbleSched[player], RumbleNowMs());
        if (action.apply) [strongSelf applyRumbleNow:(unsigned short)player lowFreqMotor:action.low highFreqMotor:action.high];
        [strongSelf scheduleRumbleTickForPlayer:player];
    });
}

// Every five seconds while rumble flows: how many host values arrived, how many were played, what the pulses looked like.
- (void)logRumbleWindow {
    const CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (_rumbleLastLog == 0) _rumbleLastLog = now;
    if (now - _rumbleLastLog < 5.0) return;
    _rumbleLastLog = now;
    DS5RumbleStats total = {0};
    for (NSUInteger index = 0; index < 16; index++) {
        const DS5RumbleStats stats = ds5_rs_take_stats(&_rumbleSched[index]);
        total.received += stats.received;
        total.applied += stats.applied;
        total.pulses += stats.pulses;
        total.deferred += stats.deferred;
        total.merged += stats.merged;
        if (stats.shortestPulseMs != 0.0 && (total.shortestPulseMs == 0.0 || stats.shortestPulseMs < total.shortestPulseMs)) total.shortestPulseMs = stats.shortestPulseMs;
        if (stats.longestPulseMs > total.longestPulseMs) total.longestPulseMs = stats.longestPulseMs;
    }
    unsigned dropped = 0;
    @synchronized(_hapticsMailboxLock) { dropped = _rumbleDropped; _rumbleDropped = 0; }
    if (total.received == 0 && dropped == 0) return;
    Log(LOG_I, @"[controller-rumble] 5 s window: host values received=%u, pulses started=%u, applied=%u, stops deferred to the end of a pulse=%u, merged into a running pulse=%u, dropped (ring full)=%u, host pulse length shortest=%.1f ms longest=%.1f ms",
        total.received, total.pulses, total.applied, total.deferred, total.merged, dropped, total.shortestPulseMs, total.longestPulseMs);
}

// Host rumble from the control thread (or anywhere): queued, never played on the caller's thread.
-(void) rumble:(unsigned short)controllerNumber lowFreqMotor:(unsigned short)lowFreqMotor highFreqMotor:(unsigned short)highFreqMotor
{
    [self queueRumble:controllerNumber low:lowFreqMotor high:highFreqMotor direct:NO];
}

- (void)queueRumble:(unsigned short)controllerNumber low:(unsigned short)low high:(unsigned short)high direct:(BOOL)direct {
    if (controllerNumber >= 16) return;
    BOOL schedule = NO;
    @synchronized(_hapticsMailboxLock) {
        unsigned *count = &_rumbleEventCount[controllerNumber];
        if (*count >= 32) {
            // The main queue is far behind: keep the newest value in the last slot so the final state is right.
            _rumbleEvents[controllerNumber][31].low = low;
            _rumbleEvents[controllerNumber][31].high = high;
            _rumbleEvents[controllerNumber][31].direct = direct;
            _rumbleDropped++;
        } else {
            _rumbleEvents[controllerNumber][*count].low = low;
            _rumbleEvents[controllerNumber][*count].high = high;
            _rumbleEvents[controllerNumber][*count].direct = direct;
            (*count)++;
        }
        if (!_rumbleDrainScheduled) { _rumbleDrainScheduled = YES; schedule = YES; }
    }
    if (schedule) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf drainPendingRumble]; });
    }
}

// Plays one value on the pad now (main queue): CoreHaptics first, a raw output report when CoreHaptics refuses.
-(void) applyRumbleNow:(unsigned short)controllerNumber lowFreqMotor:(unsigned short)lowFreqMotor highFreqMotor:(unsigned short)highFreqMotor
{
    if (!ControllerIsFeedbackTarget(self, controllerNumber)) return;
    if (![self bluetoothPolicyAllowsRumbleForPlayer:controllerNumber]) return;
    // The strength option scales the amplitude the host asked for (host tuning key ds5.rumble.strength).
    if (self.rumbleStrength != 1.0) {
        lowFreqMotor = (unsigned short)lrint(fmin(65535.0, (double)lowFreqMotor * self.rumbleStrength));
        highFreqMotor = (unsigned short)lrint(fmin(65535.0, (double)highFreqMotor * self.rumbleStrength));
    }
    AlkDs5Feedback coreFeedback = _hasDS5Feedback[controllerNumber] ? _lastDS5Feedback[controllerNumber] :
        (AlkDs5Feedback){.struct_size = sizeof(coreFeedback), .abi = ALK_DS5_CORE_ABI_VERSION, .device_index = 0};
    // Rumble emulation needs both enable bits; valid_flag2 bit 2 selects the current firmware's curve.
    coreFeedback.valid_flag0 = 0x03u;
    coreFeedback.valid_flag1 = 0u;
    coreFeedback.valid_flag2 = 0x04u;
    coreFeedback.motor_left = (uint8_t)(lowFreqMotor >> 8);
    coreFeedback.motor_right = (uint8_t)(highFreqMotor >> 8);
    uint8_t coreReport[ALK_DS5_USB_OUTPUT_REPORT_BYTES] = {0};
    size_t coreReportLength = 0;
    (void)alk_ds5_build_output_report(&coreFeedback, coreReport, sizeof(coreReport), &coreReportLength);
    (void)[self withDS5CoreForPlayer:controllerNumber call:^AlkDs5Error(AlkDs5Core *core) { return alk_ds5_core_submit_feedback(core, &coreFeedback); }];
    _lastDS5Feedback[controllerNumber] = coreFeedback; _hasDS5Feedback[controllerNumber] = YES;
    Controller* controller = [_controllers objectForKey:[NSNumber numberWithInteger:controllerNumber]];
    if (controller == nil && controllerNumber == 0 && _oscEnabled) {
        // No physical controller, but we have on-screen controls
        controller = _player0osc;
    }
    if (controller == nil) {
        // No connected controller for this player
        return;
    }
    if (controller.lastAuthoredHapticsTime != 0 &&
        CFAbsoluteTimeGetCurrent() - controller.lastAuthoredHapticsTime < 0.25) return;
    BOOL left = [controller.lowFreqMotor setIntensity:lowFreqMotor / 65535.0f sharpness:0.5f];
    BOOL right = [controller.highFreqMotor setIntensity:highFreqMotor / 65535.0f sharpness:0.5f];
    if (!(left && right) && [controller.gamepad.extendedGamepad isKindOfClass:[GCDualSenseGamepad class]]) {
        // A raw write is only for when CoreHaptics refused: gamecontrollerd writes this device too.
        [_rawHID sendOutputReport:coreReport length:coreReportLength playerIdentity:[self rawHIDIdentityForPlayer:controllerNumber]];
        return;
    }
    if (!(left && right) && [_presenceDelegate respondsToSelector:@selector(controllerRumbleFallback:low:high:)]) {
        [_presenceDelegate controllerRumbleFallback:controllerNumber low:lowFreqMotor high:highFreqMotor];
    }
}

// How many authored-haptics frames the stream delivered, and how many reached a pad: one line every five
// seconds while the numbers change, so a game that never produces haptics is visible in the log.
typedef enum { Ds5FrameIR = 0, Ds5FramePCM = 1 } Ds5FrameKind;
static void NoteHapticsFrame(Ds5FrameKind kind, BOOL accepted) {
    static _Atomic unsigned long sReceived[2], sAccepted[2], sLoggedTotal;
    static _Atomic CFAbsoluteTime sLastLog;
    atomic_fetch_add(&sReceived[kind], 1);
    if (accepted) atomic_fetch_add(&sAccepted[kind], 1);
    const CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    const unsigned long total = atomic_load(&sReceived[0]) + atomic_load(&sReceived[1]);
    if (now - atomic_load(&sLastLog) >= 5.0 && total != atomic_load(&sLoggedTotal)) {
        atomic_store(&sLastLog, now);
        atomic_store(&sLoggedTotal, total);
        Log(LOG_I, @"[controller-haptics] frames from the host: IR received=%lu used=%lu, PCM received=%lu used=%lu",
            atomic_load(&sReceived[0]), atomic_load(&sAccepted[0]), atomic_load(&sReceived[1]), atomic_load(&sAccepted[1]));
    }
}

// The control receive thread only copies into a bounded, per-player mailbox.
// Controller ownership, engines and light state remain on the main queue.
- (void)ds5HapticsIrV2:(const LI_DS5_HAPTICS_IR_FRAME_V2 *)frame {
    if (!frame || !self.shouldSendInputEvents || frame->controllerNumber >= 16) {
        NoteHapticsFrame(Ds5FrameIR, NO);
        return;
    }
    NoteHapticsFrame(Ds5FrameIR, YES);
    AlkDs5IrHaptics coreFrame = {
        .struct_size = sizeof(coreFrame), .abi = ALK_DS5_CORE_ABI_VERSION,
        .device_index = 0,
        .left_intensity = (uint16_t)lrintf(fminf(1.0f, fmaxf(0.0f, frame->lanes[0].rmsAmplitude)) * 65535.0f),
        .right_intensity = (uint16_t)lrintf(fminf(1.0f, fmaxf(0.0f, frame->lanes[1].rmsAmplitude)) * 65535.0f),
        .left_sharpness = (uint16_t)lrintf(fminf(1.0f, fmaxf(0.0f, frame->lanes[0].lowBandRatio)) * 65535.0f),
        .right_sharpness = (uint16_t)lrintf(fminf(1.0f, fmaxf(0.0f, frame->lanes[1].lowBandRatio)) * 65535.0f),
        .pts_ns = frame->timestampUs * 1000ull};
    if ([self withDS5CoreForPlayer:frame->controllerNumber call:^AlkDs5Error(AlkDs5Core *core) { return alk_ds5_core_submit_ir_haptics(core, &coreFrame); }] != ALK_DS5_OK) return;
    DS5IrFrame irFrame;
    memset(&irFrame, 0, sizeof(irFrame));
    for (int lane = 0; lane < 2; ++lane) {
        irFrame.rms[lane] = frame->lanes[lane].rmsAmplitude;
        irFrame.peak[lane] = frame->lanes[lane].peakAmplitude;
        irFrame.transient[lane] = frame->lanes[lane].transientStrength;
        irFrame.lowBand[lane] = frame->lanes[lane].lowBandRatio;
    }
    irFrame.silent = (frame->flags & (LI_DS5_HAPTICS_IR_FLAG_SILENT | LI_DS5_HAPTICS_IR_FLAG_STREAM_END)) != 0;
    irFrame.flags = frame->flags;
    irFrame.seq = frame->sourceSequenceNumber;
    BOOL schedule = NO;
    @synchronized(_hapticsMailboxLock) {
        DS5IrPlayback *playback = &_irPlayback[frame->controllerNumber];
        if (frame->flags & LI_DS5_HAPTICS_IR_FLAG_DISCONTINUITY) {
            // A new stream: what is queued or deferred belongs to the old one.
            playback->count = 0;
            playback->hasPending = false;
        }
        ds5_irp_push(playback, &irFrame);
        if (!_hapticsDrainScheduled) { _hapticsDrainScheduled = YES; schedule = YES; }
    }
    if (schedule) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf drainAuthoredHaptics]; });
    }
}

- (void)drainAuthoredHaptics {
    // Every player's queue is stepped: the frames that arrived since the last drain, in order, and the value
    // deferred by the minimum hold of a pulse.
    const double now = CFAbsoluteTimeGetCurrent();
    DS5IrFrame chosen[16];
    BOOL apply[16], rising[16];
    double wake[16];
    @synchronized(_hapticsMailboxLock) {
        _hapticsDrainScheduled = NO;
        for (unsigned player = 0; player < 16; player++) {
            wake[player] = 0.0;
            apply[player] = ds5_irp_step(&_irPlayback[player], now, &chosen[player], &wake[player]);
            rising[player] = _irPlayback[player].lastRising;
            _irWakeAt[player] = wake[player];
        }
    }
    double earliestWake = 0.0;
    for (unsigned player = 0; player < 16; player++) {
        if (wake[player] != 0.0 && (earliestWake == 0.0 || wake[player] < earliestWake)) earliestWake = wake[player];
    }
    if (earliestWake != 0.0) {
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(fmax(0.0, earliestWake - now) * NSEC_PER_SEC) + 500 * NSEC_PER_USEC),
                       dispatch_get_main_queue(), ^{ [weakSelf drainAuthoredHaptics]; });
    }
    if (!self.shouldSendInputEvents) return;
    for (unsigned number = 0; number < 16; number++) {
        if (!apply[number]) continue;
        LI_DS5_HAPTICS_IR_FRAME_V2 frame;
        memset(&frame, 0, sizeof(frame));
        frame.controllerNumber = (uint16_t)number;
        frame.flags = chosen[number].flags;
        frame.sourceSequenceNumber = chosen[number].seq;
        for (int lane = 0; lane < 2; ++lane) {
            frame.lanes[lane].rmsAmplitude = chosen[number].rms[lane];
            frame.lanes[lane].peakAmplitude = chosen[number].peak[lane];
            frame.lanes[lane].transientStrength = chosen[number].transient[lane];
            frame.lanes[lane].lowBandRatio = chosen[number].lowBand[lane];
        }
        if (chosen[number].silent) frame.flags |= LI_DS5_HAPTICS_IR_FLAG_SILENT;
        if (!ControllerIsFeedbackTarget(self, frame.controllerNumber)) continue;
        Controller *controller = _controllers[@(number)];
        if (!controller) continue;
        if (!(frame.flags & LI_DS5_HAPTICS_IR_FLAG_DISCONTINUITY) &&
            controller.hasHapticsSequence &&
            (int32_t)(frame.sourceSequenceNumber - controller.lastHapticsSequence) <= 0) continue;
        controller.hasHapticsSequence = YES;
        controller.lastHapticsSequence = frame.sourceSequenceNumber;
        const BOOL silent = (frame.flags & (LI_DS5_HAPTICS_IR_FLAG_SILENT | LI_DS5_HAPTICS_IR_FLAG_STREAM_END)) != 0;
        controller.lastAuthoredHapticsTime = silent ? 0 : CFAbsoluteTimeGetCurrent();
        const BOOL compatibility = self.controllerHapticsMode == 2;
        if (frame.flags & LI_DS5_HAPTICS_IR_FLAG_DISCONTINUITY) controller.authoredHapticsFallback = NO;
        BOOL native = !compatibility && !controller.authoredHapticsFallback && controller.lowFreqMotor.available && controller.highFreqMotor.available;
        // GPL integration adapter: unpack the Foundation wire fields here.
        // The standalone policy accepts scalars and never imports this type.
        ControllerActuatorEnvelope envelopes[2];
        for (int lane = 0; lane < 2; ++lane) {
            envelopes[lane] = (ControllerActuatorEnvelope){
                frame.lanes[lane].rmsAmplitude, frame.lanes[lane].peakAmplitude,
                frame.lanes[lane].transientStrength, frame.lanes[lane].lowBandRatio};
        }
        if (native) {
            ControllerActuatorParameters left = ControllerFeedbackProject(envelopes[0], silent);
            ControllerActuatorParameters right = ControllerFeedbackProject(envelopes[1], silent);
            BOOL leftAccepted = [controller.lowFreqMotor setIntensity:left.intensity sharpness:left.sharpness];
            BOOL rightAccepted = [controller.highFreqMotor setIntensity:right.intensity sharpness:right.sharpness];
            native = leftAccepted && rightAccepted;
            if (native && rising[number]) {
                @synchronized(_hapticsMailboxLock) { ds5_irp_note_issued(&_irPlayback[number], true); }
            }
        }
        if (!native && !ds5_bluetooth_allows_motor_fallback([self bluetoothHapticsMode])) {
            // An explicit "ir" choice does not fall back to plain rumble: the haptics are unavailable.
            [controller.lowFreqMotor setMotorAmplitude:0];
            [controller.highFreqMotor setMotorAmplitude:0];
            if (!_loggedIrUnavailable) {
                _loggedIrUnavailable = YES;
                Log(LOG_W, @"[controller-haptics] UNAVAILABLE: analysed haptics are selected for Bluetooth but this pad cannot render them; no rumble fallback by choice");
            }
        } else if (!native) {
            [controller.lowFreqMotor setMotorAmplitude:0];
            [controller.highFreqMotor setMotorAmplitude:0];
            float low, high;
            ControllerFeedbackReduceBands(envelopes, silent, &low, &high);
            if ([_presenceDelegate respondsToSelector:@selector(controllerRumbleFallback:low:high:)]) {
                [_presenceDelegate controllerRumbleFallback:frame.controllerNumber
                    low:(unsigned short)lrintf(low * 65535.0f)
                    high:(unsigned short)lrintf(high * 65535.0f)];
            }
        }
        if (!controller.authoredHapticsLogged || controller.authoredHapticsFallback == native) {
            Log(LOG_I, @"[controller-haptics] Foundation IR v2 player=%hu path=%@ sequence=%u",
                frame.controllerNumber, native ? @"CoreHaptics-stereo-intensity-sharpness" : @"HID-spectral-fallback",
                frame.sourceSequenceNumber);
            controller.authoredHapticsLogged = YES;
        }
        controller.authoredHapticsFallback = !native;
    }
    [self logIrPlaybackWindow];
}

// One line every five seconds while analysed haptics flow: how many ticks (energy after silence) the stream
// delivered and how many were issued to the actuators. A difference is a tick lost between the two.
- (void)logIrPlaybackWindow {
    const CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (_irStatsLast == 0) _irStatsLast = now;
    if (now - _irStatsLast < 5.0) return;
    _irStatsLast = now;
    DS5IrStats total = {0};
    @synchronized(_hapticsMailboxLock) {
        for (unsigned player = 0; player < 16; player++) {
            const DS5IrStats stats = ds5_irp_take_stats(&_irPlayback[player]);
            total.framesIn += stats.framesIn; total.batches += stats.batches; total.overflows += stats.overflows;
            total.ticksSeen += stats.ticksSeen; total.risingApplied += stats.risingApplied; total.issued += stats.issued;
            total.applies += stats.applies;
            if (stats.maxBatch > total.maxBatch) total.maxBatch = stats.maxBatch;
        }
    }
    if (total.framesIn == 0) return;
    Log(LOG_I, @"[controller-haptics] IR 5 s window: frames=%u in %u drains (largest %u), ticks seen=%u, ticks played=%u, issued to the actuators=%u, lost=%d, queue overflows=%u",
        total.framesIn, total.batches, total.maxBatch, total.ticksSeen, total.risingApplied, total.issued,
        (int)total.ticksSeen - (int)total.issued, total.overflows);
}

- (void)controllerMaintenance:(NSTimer *)timer {
    (void)timer;
    if (!self.shouldSendInputEvents) return;
    const CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    BOOL batteryTick = (++_maintenanceTicks % 50) == 0;
    for (Controller *controller in _controllers.allValues) {
        if (!controller.controllerAnnounced) [self updateFinished:controller];
        if (controller.lastAuthoredHapticsTime != 0 && now - controller.lastAuthoredHapticsTime >= 0.25) {
            [controller.lowFreqMotor setMotorAmplitude:0];
            [controller.highFreqMotor setMotorAmplitude:0];
            if (controller.authoredHapticsFallback &&
                [_presenceDelegate respondsToSelector:@selector(controllerRumbleFallback:low:high:)]) {
                [_presenceDelegate controllerRumbleFallback:(unsigned short)controller.playerIndex low:0 high:0];
            }
            controller.lastAuthoredHapticsTime = 0;
            Log(LOG_I, @"[controller-haptics] Lost-frame watchdog stopped player=%d", controller.playerIndex);
        }
        if (batteryTick && controller.controllerAnnounced && controller.gamepad.battery != nil) {
            GCDeviceBattery *battery = controller.gamepad.battery;
            uint8_t state = LI_BATTERY_STATE_UNKNOWN;
            switch (battery.batteryState) {
                case GCDeviceBatteryStateDischarging: state = LI_BATTERY_STATE_DISCHARGING; break;
                case GCDeviceBatteryStateCharging: state = LI_BATTERY_STATE_CHARGING; break;
                case GCDeviceBatteryStateFull: state = LI_BATTERY_STATE_FULL; break;
                default: break;
            }
            uint8_t percent = battery.batteryLevel >= 0 && battery.batteryLevel <= 1
                ? (uint8_t)lrintf(battery.batteryLevel * 100) : LI_BATTERY_PERCENTAGE_UNKNOWN;
            _diagGCBatteryPercent = percent;
            AlkDs5BatteryObservation batteryObservation = {
                .struct_size = sizeof(batteryObservation), .abi = ALK_DS5_CORE_ABI_VERSION,
                .device_index = 0, .sequence = (uint64_t)_maintenanceTicks,
                .level_steps = (uint8_t)fminf(10.0f, floorf(percent / 10.0f)),
                .charging_state = state, .full = state == LI_BATTERY_STATE_FULL ? 1u : 0u};
            (void)[self withDS5CoreForPlayer:(NSUInteger)controller.playerIndex call:^AlkDs5Error(AlkDs5Core *core) { return alk_ds5_core_submit_battery(core, &batteryObservation); }];
            PML_INPUT_STREAM_CONTEXT input = ControllerInputContext(self);
            if (input) LiSendControllerBatteryEventCtx(input, (uint8_t)controller.playerIndex, state, percent);
        }
    }
}

- (void)ds5HapticsPcm:(const LI_DS5_HAPTICS_PCM_FRAME *)frame
{
    NoteHapticsFrame(Ds5FramePCM, frame != NULL && ControllerIsFeedbackTarget(self, frame->controllerNumber));
    if (frame == NULL || !ControllerIsFeedbackTarget(self, frame->controllerNumber) ||
        frame->sampleRate != 48000 || (frame->channelCount != 2 && frame->channelCount != 4) ||
        frame->bitsPerSample != 16 || frame->frameCount > 480 ||
        frame->pcmDataLength != (uint32_t)frame->frameCount * frame->channelCount * 2u ||
        (frame->pcmDataLength != 0 && frame->pcmData == NULL)) {
        return;
    }

    Controller *controller = [_controllers objectForKey:@(frame->controllerNumber)];
    if (controller != nil) {
        if (@available(macOS 11.0, *)) {
            if ([controller.gamepad.extendedGamepad isKindOfClass:[GCDualSenseGamepad class]] &&
                [_ds5HapticsAudioRenderer submitPCMFrame:frame]) {
                return;
            }
        }
    }

    // Apple Game Controller does not expose authored PCM. When macOS does not
    // expose the physical four-channel DualSense endpoint, preserve useful
    // feedback with an RMS reduction into the public haptics localities.
    if ((frame->flags & LI_DS5_HAPTICS_PCM_FLAG_STREAM_END) != 0 ||
        frame->frameCount == 0) {
        [self rumble:frame->controllerNumber lowFreqMotor:0 highFreqMotor:0];
        return;
    }

    double leftEnergy = 0.0;
    double rightEnergy = 0.0;
    const int16_t *samples = (const int16_t *)frame->pcmData;
    for (uint16_t index = 0; index < frame->frameCount; index++) {
        const double left = (double)samples[index * 2] / 32768.0;
        const double right = (double)samples[index * 2 + 1] / 32768.0;
        leftEnergy += left * left;
        rightEnergy += right * right;
    }

    const double divisor = (double)MAX(frame->frameCount, 1);
    const double leftAmplitude = MIN(1.0, sqrt(leftEnergy / divisor) * 1.5);
    const double rightAmplitude = MIN(1.0, sqrt(rightEnergy / divisor) * 1.5);
    [self rumble:frame->controllerNumber
      lowFreqMotor:(unsigned short)lrint(leftAmplitude * 65535.0)
     highFreqMotor:(unsigned short)lrint(rightAmplitude * 65535.0)];
}

-(void) rumbleTriggers:(unsigned short)controllerNumber
      leftTriggerMotor:(unsigned short)leftTriggerMotor
     rightTriggerMotor:(unsigned short)rightTriggerMotor
{
    if (!ControllerIsFeedbackTarget(self, controllerNumber)) {
        return;
    }
    Controller *controller = [_controllers objectForKey:@(controllerNumber)];
    if (controller == nil) {
        return;
    }

    // GameController exposes left/right haptic localities, but macOS has no
    // public trigger-motor API. Mapping the two trigger channels to those
    // localities preserves independent feedback on DualSense and provides a
    // documented fallback on other controllers.
    [controller.lowFreqMotor setMotorAmplitude:leftTriggerMotor];
    [controller.highFreqMotor setMotorAmplitude:rightTriggerMotor];
}

-(void) setControllerLED:(unsigned short)controllerNumber
                       red:(unsigned char)red
                     green:(unsigned char)green
                      blue:(unsigned char)blue
{
    if (![NSThread isMainThread]) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (weakSelf.shouldSendInputEvents) [weakSelf setControllerLED:controllerNumber red:red green:green blue:blue];
        });
        return;
    }
    if (!ControllerIsFeedbackTarget(self, controllerNumber)) return;
    Controller *controller = [_controllers objectForKey:@(controllerNumber)];
    GCController *gamepad = controller.gamepad;
    if (gamepad == nil) {
        return;
    }

    if (@available(macOS 11.0, *)) {
        if (gamepad.light != nil) {
            Log(LOG_I, @"[controller-led] Output player=%hu rgb=%u,%u,%u path=GameController", controllerNumber, red, green, blue);
            gamepad.light.color = [[GCColor alloc] initWithRed:red / 255.0
                                                         green:green / 255.0
                                                          blue:blue / 255.0];
            return;
        }
    }

    Log(LOG_I, @"Controller %hu does not expose a public RGB LED API on this macOS driver", controllerNumber);
}

-(void) setAdaptiveTriggers:(unsigned short)controllerNumber
                 eventFlags:(unsigned char)eventFlags
                   typeLeft:(unsigned char)typeLeft
                  typeRight:(unsigned char)typeRight
                       left:(const unsigned char *)left
                      right:(const unsigned char *)right
{
    if (!ControllerIsFeedbackTarget(self, controllerNumber)) {
        return;
    }
    Controller *controller = [_controllers objectForKey:@(controllerNumber)];
    GCController *gamepad = controller.gamepad;
    if (gamepad == nil || ![gamepad.extendedGamepad isKindOfClass:[GCDualSenseGamepad class]]) {
        return;
    }

    if (@available(macOS 11.3, *)) {
        GCDualSenseGamepad *dualSense = (GCDualSenseGamepad *)gamepad.extendedGamepad;
        if ((eventFlags & DS_EFFECT_LEFT_TRIGGER) != 0) {
            ApplyDualSenseTriggerEffect(dualSense.leftTrigger, typeLeft, left);
        }
        if ((eventFlags & DS_EFFECT_RIGHT_TRIGGER) != 0) {
            ApplyDualSenseTriggerEffect(dualSense.rightTrigger, typeRight, right);
        }
    }
}

-(void) setMotionEventState:(unsigned short)controllerNumber
                  motionType:(unsigned char)motionType
                reportRateHz:(unsigned short)reportRateHz
{
    if (self.controllerMotionMode == 2 || !ControllerIsFeedbackTarget(self, controllerNumber)) {
        return;
    }
    Controller *controller = [_controllers objectForKey:@(controllerNumber)];
    GCController *gamepad = controller.gamepad;
    if (gamepad == nil) {
        return;
    }
    GCMotion *motion = gamepad.motion;
    if (motion == nil) {
        return;
    }

    // The host asks for the accelerometer and the gyro separately, so both requests are kept
    // and one handler serves them; a handler per request would replace the other one.
    BOOL anyRequested = NO;
    @synchronized (controller) {
        if (motionType == LI_MOTION_TYPE_ACCEL) {
            controller.accelReportRateHz = reportRateHz;
            controller.lastAccelReportTime = 0;
        } else if (motionType == LI_MOTION_TYPE_GYRO) {
            controller.gyroReportRateHz = reportRateHz;
            controller.lastGyroReportTime = 0;
        } else {
            return;
        }
        anyRequested = controller.accelReportRateHz > 0 || controller.gyroReportRateHz > 0;
    }

    if (!anyRequested) {
        motion.valueChangedHandler = nil;
        motion.sensorsActive = NO;
        return;
    }

    __weak typeof(self) weakSelf = self;
    __weak Controller *weakController = controller;
    motion.valueChangedHandler = ^(GCMotion *sample) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        Controller *strongController = weakController;
        if (strongSelf == nil || strongController == nil) {
            return;
        }
        PML_INPUT_STREAM_CONTEXT inputCtx = ControllerInputContext(strongSelf);
        // Nothing is sent while controller delivery is paused; the pause itself sends a zero
        // rotation so the host does not keep turning at the last rate.
        if (inputCtx == NULL || !strongSelf->_shouldSendInputEvents) {
            return;
        }

        // Send at about the rate the host asked for. A sample is due once half the interval has
        // passed: a DualSense over Bluetooth reports every 7.7 ms with some jitter, and anything
        // stricter skips samples and sends at an uneven rate.
        NSTimeInterval now = [NSProcessInfo processInfo].systemUptime;
        BOOL sendAccel = NO;
        BOOL sendGyro = NO;
        @synchronized (strongController) {
            unsigned short accelRate = strongController.accelReportRateHz;
            if (accelRate > 0 && now - strongController.lastAccelReportTime >= 0.5 / accelRate) {
                strongController.lastAccelReportTime = now;
                sendAccel = YES;
            }
            unsigned short gyroRate = strongController.gyroReportRateHz;
            if (gyroRate > 0 && now - strongController.lastGyroReportTime >= 0.5 / gyroRate) {
                strongController.lastGyroReportTime = now;
                sendGyro = YES;
            }
        }

        // The protocol wants what SDL reports: acceleration in m/s² as the force holding the
        // controller up (+g on Y when it lies flat) and rotation in deg/s, on SDL's gamepad axes
        // (X right, Y out of the face, Z toward the player).
        // GameController reports both sensors on one right-handed frame with X right, Y toward
        // the top edge and Z out of the face, acceleration as the direction of gravity in g and
        // rotation in rad/s. Measured on a DualSense: lying flat reads (0, 0, -1), standing on its
        // grips reads (0, -1, 0), and integrating the rotation rate on these axes reproduces how
        // the gravity reading moves. So both vectors take the same change of axes, (x, z, -y),
        // and the acceleration is negated on top of it.
        if (sendAccel) {
            GCAcceleration acceleration = sample.acceleration;
            LiSendControllerMotionEventCtx(inputCtx, (uint8_t)controllerNumber, LI_MOTION_TYPE_ACCEL,
                                           (float)(-acceleration.x * 9.80665),
                                           (float)(-acceleration.z * 9.80665),
                                           (float)(acceleration.y * 9.80665));
        }
        if (sendGyro && sample.hasRotationRate) {
            static const double kRadiansToDegrees = 57.29577951308232;
            GCRotationRate rotation = sample.rotationRate;
            LiSendControllerMotionEventCtx(inputCtx, (uint8_t)controllerNumber, LI_MOTION_TYPE_GYRO,
                                           (float)(rotation.x * kRadiansToDegrees),
                                           (float)(rotation.z * kRadiansToDegrees),
                                           (float)(-rotation.y * kRadiansToDegrees));
        }
    };
    motion.sensorsActive = YES;
}

-(void) updateLeftStick:(Controller*)controller x:(short)x y:(short)y
{
    @synchronized(controller) {
        controller.lastLeftStickX = ApplyStickCalibration(
            x, y, self.gamepadDeadzone, self.controllerLeftCenterX,
            self.controllerLeftCenterY, self.controllerLeftGain);
        controller.lastLeftStickY = ApplyStickCalibrationY(
            x, y, self.gamepadDeadzone, self.controllerLeftCenterX,
            self.controllerLeftCenterY, self.controllerLeftGain);
    }
}

-(void) updateRightStick:(Controller*)controller x:(short)x y:(short)y
{
    @synchronized(controller) {
        controller.lastRightStickX = ApplyStickCalibration(
            x, y, self.gamepadDeadzone, self.controllerRightCenterX,
            self.controllerRightCenterY, self.controllerRightGain);
        controller.lastRightStickY = ApplyStickCalibrationY(
            x, y, self.gamepadDeadzone, self.controllerRightCenterX,
            self.controllerRightCenterY, self.controllerRightGain);
    }
}

-(void) updateLeftTrigger:(Controller*)controller left:(unsigned char)left
{
    @synchronized(controller) {
        controller.lastLeftTrigger = left;
    }
}

-(void) updateRightTrigger:(Controller*)controller right:(unsigned char)right
{
    @synchronized(controller) {
        controller.lastRightTrigger = right;
    }
}

-(void) updateTriggers:(Controller*) controller left:(unsigned char)left right:(unsigned char)right
{
    @synchronized(controller) {
        controller.lastLeftTrigger = left;
        controller.lastRightTrigger = right;
    }
}

-(void) handleSpecialCombosReleased:(Controller*)controller releasedButtons:(int)releasedButtons
{
    [self->_debouncers enumerateKeysAndObjectsUsingBlock:^(NSNumber * _Nonnull keyFlag, NSMutableDictionary<NSNumber *,ButtonDebouncer *> * _Nonnull debouncers, BOOL * _Nonnull stop) {
        ButtonDebouncer *debouncer = debouncers[@(controller.playerIndex)];
        [debouncer handleRelease:controller releasedButtons:releasedButtons];
    }];
}

-(void) handleSpecialCombosPressed:(Controller*)controller pressedButtons:(int)pressedButtons
{
    [self->_debouncers enumerateKeysAndObjectsUsingBlock:^(NSNumber * _Nonnull keyFlag, NSMutableDictionary<NSNumber *,ButtonDebouncer *> * _Nonnull debouncers, BOOL * _Nonnull stop) {
        ButtonDebouncer *debouncer = debouncers[@(controller.playerIndex)];
        [debouncer handlePress:controller pressedButtons:pressedButtons];
    }];
}

-(void) updateButtonFlags:(Controller*)controller flags:(int)flags
{
    @synchronized(controller) {
        controller.lastButtonFlags = flags;

        // This must be called before handleSpecialCombosPressed
        // because we clear the original button flags there
        int releasedButtons = (controller.lastButtonFlags ^ flags) & ~flags;
        int pressedButtons = (controller.lastButtonFlags ^ flags) & flags;

        [self handleSpecialCombosReleased:controller releasedButtons:releasedButtons];

        [self handleSpecialCombosPressed:controller pressedButtons:pressedButtons];
    }
}

-(void) setButtonFlag:(Controller*)controller flags:(int)flags
{
    @synchronized(controller) {
        controller.lastButtonFlags |= flags;
        [self handleSpecialCombosPressed:controller pressedButtons:flags];
    }
}

-(void) clearButtonFlag:(Controller*)controller flags:(int)flags
{
    @synchronized(controller) {
        controller.lastButtonFlags &= ~flags;
        [self handleSpecialCombosReleased:controller releasedButtons:flags];
    }
}

-(void) updateFinished:(Controller*)controller
{
    if (!_shouldSendInputEvents) {
        return;
    }

    @synchronized(controller) {
        // Quit Combo: Start+Select+L1+R1
        // Note: ButtonDebouncer converts Start+Select to SPECIAL_FLAG (Guide)
        // So we check for Guide + L1 + R1
        int quitFlags = SPECIAL_FLAG | LB_FLAG | RB_FLAG;
        if (self.controllerShortcutHandler == nil && (controller.lastButtonFlags & quitFlags) == quitFlags) {
             dispatch_async(dispatch_get_main_queue(), ^{
                 [[NSNotificationCenter defaultCenter] postNotificationName:HIDGamepadQuitNotification object:nil];
             });
            // Clear flags to avoid sending
            controller.lastButtonFlags = 0;
        }

        if (controller.isMouseMode) {
            // Don't send controller events while in mouse mode
            return;
        }

        // Standard Controller Mode
        [_controllerStreamLock lock];

        PML_INPUT_STREAM_CONTEXT inputCtx = ControllerInputContext(self);
        if (!inputCtx) {
            [_controllerStreamLock unlock];
            return;
        }

        if (!controller.controllerAnnounced) {
            uint8_t controllerType = LI_CTYPE_UNKNOWN;
            uint16_t capabilities = LI_CCAP_ANALOG_TRIGGERS | LI_CCAP_RUMBLE;
            uint32_t supportedButtonFlags = A_FLAG | B_FLAG | X_FLAG | Y_FLAG |
                                             UP_FLAG | DOWN_FLAG | LEFT_FLAG | RIGHT_FLAG |
                                             LB_FLAG | RB_FLAG | PLAY_FLAG | BACK_FLAG |
                                             LS_CLK_FLAG | RS_CLK_FLAG | SPECIAL_FLAG;
            GCExtendedGamepad *extended = controller.gamepad.extendedGamepad;
            BOOL hasTouchpad = [extended isKindOfClass:[GCDualSenseGamepad class]] ||
                               [extended isKindOfClass:[GCDualShockGamepad class]];
            // Keep the arrival type in the same family as the gamepad= value
            // declared on launch/resume, so the host never sees two answers.
            if ([self.clientGamepad isEqualToString:@"x360"]) {
                controllerType = LI_CTYPE_XBOX;
            } else if ([self.clientGamepad isEqualToString:@"ds4"] ||
                       [self.clientGamepad isEqualToString:@"ds5"]) {
                controllerType = LI_CTYPE_PS;
            } else if (self.controllerVirtualType == 1) {
                controllerType = LI_CTYPE_XBOX;
            } else if (self.controllerVirtualType == 2) {
                controllerType = LI_CTYPE_PS;
            } else if (hasTouchpad) {
                controllerType = LI_CTYPE_PS;
            }
            BOOL allowsPlayStationExtensions = controllerType != LI_CTYPE_XBOX;
            if (!hasTouchpad) supportedButtonFlags |= TOUCHPAD_FLAG;
            if (hasTouchpad && allowsPlayStationExtensions) {
                capabilities |= LI_CCAP_TOUCHPAD;
                if ([extended isKindOfClass:GCDualSenseGamepad.class] &&
                    self.controllerHapticsMode == 0 && [Ds5HapticsAudioRenderer hasPhysicalEndpoint]) {
                    capabilities |= LI_CCAP_DS5_HAPTICS_PCM;
                }
                supportedButtonFlags |= TOUCHPAD_FLAG;
            } else if (!hasTouchpad && allowsPlayStationExtensions && self.advertiseTouchpadForShortcut) {
                capabilities |= LI_CCAP_TOUCHPAD;
            }
            if (controller.gamepad.motion != nil && allowsPlayStationExtensions) {
                capabilities |= LI_CCAP_ACCEL | LI_CCAP_GYRO;
            }
            if (controller.gamepad.battery != nil) {
                capabilities |= LI_CCAP_BATTERY_STATE;
            }
            if (controller.gamepad.light != nil && allowsPlayStationExtensions) {
                capabilities |= LI_CCAP_RGB_LED;
            }
            LiSendControllerArrivalEventCtx(inputCtx, (uint8_t)controller.playerIndex,
                                            (uint16_t)[ControllerSupport getConnectedGamepadMask:nil],
                                            controllerType, supportedButtonFlags, capabilities);
            LogControllerMappingDiagnostics(controller, controllerType, supportedButtonFlags, capabilities, self);
            controller.controllerAnnounced = YES;

            if (controller.gamepad.battery != nil) {
                GCDeviceBattery *battery = controller.gamepad.battery;
                uint8_t batteryState = LI_BATTERY_STATE_UNKNOWN;
                switch (battery.batteryState) {
                    case GCDeviceBatteryStateDischarging: batteryState = LI_BATTERY_STATE_DISCHARGING; break;
                    case GCDeviceBatteryStateCharging: batteryState = LI_BATTERY_STATE_CHARGING; break;
                    case GCDeviceBatteryStateFull: batteryState = LI_BATTERY_STATE_FULL; break;
                    default: break;
                }
                uint8_t percentage = battery.batteryLevel >= 0.0f && battery.batteryLevel <= 1.0f
                    ? (uint8_t)lrintf(battery.batteryLevel * 100.0f)
                    : LI_BATTERY_PERCENTAGE_UNKNOWN;
                LiSendControllerBatteryEventCtx(inputCtx, (uint8_t)controller.playerIndex,
                                                batteryState, percentage);
            }
        }

        ControllerGamepadState state = {
            .buttons = (uint32_t)controller.lastButtonFlags,
            .leftTrigger = controller.lastLeftTrigger, .rightTrigger = controller.lastRightTrigger,
            .leftX = controller.lastLeftStickX, .leftY = controller.lastLeftStickY,
            .rightX = controller.lastRightStickX, .rightY = controller.lastRightStickY
        };
        uint64_t routing = [self evaluateControllerShortcuts:controller];
        uint32_t consumed = ControllerShortcutProtocolMask(ControllerShortcutRouteConsumed(routing));
        uint32_t replayed = ControllerShortcutProtocolMask(ControllerShortcutRouteReplay(routing));
        state.buttons &= ~consumed;
        state.buttons |= replayed & ~(CONTROLLER_SHORTCUT_LEFT_TRIGGER_MARKER | CONTROLLER_SHORTCUT_RIGHT_TRIGGER_MARKER);
        if (ControllerShortcutRouteTouchpad(routing)) state.buttons |= TOUCHPAD_FLAG;
        if (consumed & CONTROLLER_SHORTCUT_LEFT_TRIGGER_MARKER) state.leftTrigger = 0;
        if (consumed & CONTROLLER_SHORTCUT_RIGHT_TRIGGER_MARKER) state.rightTrigger = 0;
        if (replayed & CONTROLLER_SHORTCUT_LEFT_TRIGGER_MARKER) state.leftTrigger = 0xFF;
        if (replayed & CONTROLLER_SHORTCUT_RIGHT_TRIGGER_MARKER) state.rightTrigger = 0xFF;
        if (controller.hasSentGamepadState && ControllerGamepadStateEqual(controller.sentGamepadState, state)) {
            [_controllerStreamLock unlock];
            return;
        }
        if (!_shouldSendInputEvents) { [_controllerStreamLock unlock]; return; }
        controller.sentGamepadState = state;
        controller.hasSentGamepadState = YES;
        if (_multiController) {
            LiSendMultiControllerEventCtx(inputCtx,
                                          controller.playerIndex,
                                          [ControllerSupport getConnectedGamepadMask:nil],
                                          state.buttons,
                                          state.leftTrigger,
                                          state.rightTrigger,
                                          controller.lastLeftStickX,
                                          controller.lastLeftStickY,
                                          controller.lastRightStickX,
                                          controller.lastRightStickY);
        }
        else {
            LiSendControllerEventCtx(inputCtx,
                                     state.buttons,
                                     state.leftTrigger,
                                     state.rightTrigger,
                                     controller.lastLeftStickX,
                                     controller.lastLeftStickY,
                                     controller.lastRightStickX,
                                     controller.lastRightStickY);
        }

        [_controllerStreamLock unlock];
    }
}

#if TARGET_OS_IPHONE
+(BOOL) hasKeyboardOrMouse {
    if (@available(iOS 14.0, tvOS 14.0, *)) {
        return GCMouse.mice.count > 0 || GCKeyboard.coalescedKeyboard != nil;
    }
    else {
        return NO;
    }
}
#endif

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

-(void) unregisterControllerCallbacks:(GCController*) controller
{
    if (controller != NULL) {
        controller.controllerPausedHandler = NULL;

        if (controller.extendedGamepad != NULL) {
            controller.extendedGamepad.valueChangedHandler = NULL;
            if (@available(macOS 11.0, *)) {
                if ([controller.extendedGamepad isKindOfClass:[GCDualSenseGamepad class]]) {
                    GCDualSenseGamepad *dualSense = (GCDualSenseGamepad *)controller.extendedGamepad;
                    dualSense.touchpadPrimary.valueChangedHandler = nil;
                    dualSense.touchpadSecondary.valueChangedHandler = nil;
                    dualSense.touchpadButton.pressedChangedHandler = nil;
                } else if ([controller.extendedGamepad isKindOfClass:[GCDualShockGamepad class]]) {
                    GCDualShockGamepad *dualShock = (GCDualShockGamepad *)controller.extendedGamepad;
                    dualShock.touchpadPrimary.valueChangedHandler = nil;
                    dualShock.touchpadSecondary.valueChangedHandler = nil;
                    dualShock.touchpadButton.pressedChangedHandler = nil;
                }
                for (GCControllerTouchpad *touchpad in controller.physicalInputProfile.allTouchpads) {
                    touchpad.touchDown = nil;
                    touchpad.touchMoved = nil;
                    touchpad.touchUp = nil;
                }
            }
        }
        else if (controller.gamepad != NULL) {
            controller.gamepad.valueChangedHandler = NULL;
        }
        if (@available(iOS 13.0, tvOS 13.0, macOS 10.15, *)) {
            controller.motion.valueChangedHandler = nil;
            controller.motion.sensorsActive = NO;
        }
    }
}

-(void) initializeControllerHaptics:(Controller*) controller
{
    controller.lowFreqMotor = [HapticContext createContextForLowFreqMotor:controller.gamepad];
    controller.highFreqMotor = [HapticContext createContextForHighFreqMotor:controller.gamepad];
}

-(void) cleanupControllerHaptics:(Controller*) controller
{
    [controller.lowFreqMotor cleanup];
    [controller.highFreqMotor cleanup];
}

-(void) registerControllerCallbacks:(GCController*) controller
{
    if (controller != NULL) {
        // iOS 13 allows the Start button to behave like a normal button, however
        // older MFi controllers can send an instant down+up event for the start button
        // which means the button will not be down long enough to register on the PC.
        // To work around this issue, use the old controllerPausedHandler if the controller
        // doesn't have a Select button (which indicates it probably doesn't have a proper
        // Start button either).
        BOOL useLegacyPausedHandler = YES;
        if (@available(iOS 13.0, tvOS 13.0, macOS 10.15, *)) {
            if (controller.extendedGamepad != nil &&
                controller.extendedGamepad.buttonOptions != nil) {
                useLegacyPausedHandler = NO;
            }
        }

        if (useLegacyPausedHandler) {
            controller.controllerPausedHandler = ^(GCController *controller) {
                Controller* limeController = [self->_controllers objectForKey:[NSNumber numberWithInteger:controller.playerIndex]];

                // Get off the main thread
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
                    [self setButtonFlag:limeController flags:PLAY_FLAG];
                    [self updateFinished:limeController];

                    // Pause for 100 ms
                    usleep(100 * 1000);

                    [self clearButtonFlag:limeController flags:PLAY_FLAG];
                    [self updateFinished:limeController];
                });
            };
        }

        __weak typeof(controller) weakController = controller;
        if (controller.extendedGamepad != NULL) {
            controller.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *gamepad, GCControllerElement *element) {
                Controller* limeController = [self->_controllers objectForKey:[NSNumber numberWithInteger:weakController.playerIndex]];
                [self evaluateControllerShortcuts:limeController];
                short leftStickX, leftStickY;
                short rightStickX, rightStickY;
                unsigned char leftTrigger, rightTrigger;

                if (limeController.isMouseMode) {
                    // Mouse Toggle and Movement are handled by timer

                    // Mouse Clicks (A = Left, B = Right)
                    BOOL currentA = gamepad.buttonA.pressed && !(ControllerShortcutProtocolMask(ControllerShortcutRouteConsumed(limeController.clientShortcutRouting)) & A_FLAG);
                    BOOL currentB = gamepad.buttonB.pressed && !(ControllerShortcutProtocolMask(ControllerShortcutRouteConsumed(limeController.clientShortcutRouting)) & B_FLAG);
                    BOOL lastA = (limeController.lastMouseModeButtonFlags & A_FLAG) != 0;
                    BOOL lastB = (limeController.lastMouseModeButtonFlags & B_FLAG) != 0;
                    PML_INPUT_STREAM_CONTEXT inputCtx = ControllerInputContext(self);

                    if (currentA != lastA) {
                        if (inputCtx) {
                            LiSendMouseButtonEventCtx(inputCtx, currentA ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE, BUTTON_LEFT);
                        }
                        if (currentA) limeController.lastMouseModeButtonFlags |= A_FLAG;
                        else limeController.lastMouseModeButtonFlags &= ~A_FLAG;
                    }
                    if (currentB != lastB) {
                        if (inputCtx) {
                            LiSendMouseButtonEventCtx(inputCtx, currentB ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE, BUTTON_RIGHT);
                        }
                        if (currentB) limeController.lastMouseModeButtonFlags |= B_FLAG;
                        else limeController.lastMouseModeButtonFlags &= ~B_FLAG;
                    }
                }

                BOOL suppress = limeController.isMouseMode;

                UPDATE_BUTTON_FLAG(limeController, A_FLAG, suppress ? NO : gamepad.buttonA.pressed);
                UPDATE_BUTTON_FLAG(limeController, B_FLAG, suppress ? NO : gamepad.buttonB.pressed);
                UPDATE_BUTTON_FLAG(limeController, X_FLAG, gamepad.buttonX.pressed);
                UPDATE_BUTTON_FLAG(limeController, Y_FLAG, gamepad.buttonY.pressed);

                UPDATE_BUTTON_FLAG(limeController, UP_FLAG, gamepad.dpad.up.pressed);
                UPDATE_BUTTON_FLAG(limeController, DOWN_FLAG, gamepad.dpad.down.pressed);
                UPDATE_BUTTON_FLAG(limeController, LEFT_FLAG, gamepad.dpad.left.pressed);
                UPDATE_BUTTON_FLAG(limeController, RIGHT_FLAG, gamepad.dpad.right.pressed);

                UPDATE_BUTTON_FLAG(limeController, LB_FLAG, gamepad.leftShoulder.pressed);
                UPDATE_BUTTON_FLAG(limeController, RB_FLAG, gamepad.rightShoulder.pressed);

                // Yay, iOS 12.1 now supports analog stick buttons
                if (@available(iOS 12.1, tvOS 12.1, macOS 10.14.1, *)) {
                    if (gamepad.leftThumbstickButton != nil) {
                        UPDATE_BUTTON_FLAG(limeController, LS_CLK_FLAG, gamepad.leftThumbstickButton.pressed);
                    }
                    if (gamepad.rightThumbstickButton != nil) {
                        UPDATE_BUTTON_FLAG(limeController, RS_CLK_FLAG, gamepad.rightThumbstickButton.pressed);
                    }
                }

                if (@available(iOS 13.0, tvOS 13.0, macOS 10.15, *)) {
                    // For older MFi gamepads, the menu button will already be handled by
                    // the controllerPausedHandler.
                    UPDATE_BUTTON_FLAG(limeController, PLAY_FLAG, gamepad.buttonMenu.pressed && !limeController.menuGesture.consumed);

                    // Options button is optional (only present on Xbox One S and PS4 gamepads)
                    if (gamepad.buttonOptions != nil) {
                        UPDATE_BUTTON_FLAG(limeController, BACK_FLAG, gamepad.buttonOptions.pressed);
                    }
                }

                if (@available(iOS 14.0, tvOS 14.0, macOS 11.0, *)) {
                    if (gamepad.buttonHome != nil) {
                        UPDATE_BUTTON_FLAG(limeController, SPECIAL_FLAG, gamepad.buttonHome.pressed);
                    }
                }

                leftStickX = gamepad.leftThumbstick.xAxis.value * 0x7FFE;
                leftStickY = gamepad.leftThumbstick.yAxis.value * 0x7FFE;

                rightStickX = suppress ? 0 : (gamepad.rightThumbstick.xAxis.value * 0x7FFE);
                rightStickY = suppress ? 0 : (gamepad.rightThumbstick.yAxis.value * 0x7FFE);

                leftTrigger = gamepad.leftTrigger.value * 0xFF;
                rightTrigger = gamepad.rightTrigger.value * 0xFF;

                [self updateLeftStick:limeController x:leftStickX y:leftStickY];
                [self updateRightStick:limeController x:rightStickX y:rightStickY];
                [self updateTriggers:limeController left:leftTrigger right:rightTrigger];
                [self updateFinished:limeController];
            };

            if (@available(macOS 11.0, *)) {
                GCControllerDirectionPad *primary = nil;
                GCControllerDirectionPad *secondary = nil;
                if ([controller.extendedGamepad isKindOfClass:[GCDualSenseGamepad class]]) {
                    GCDualSenseGamepad *dualSense = (GCDualSenseGamepad *)controller.extendedGamepad;
                    primary = dualSense.touchpadPrimary;
                    secondary = dualSense.touchpadSecondary;
                } else if ([controller.extendedGamepad isKindOfClass:[GCDualShockGamepad class]]) {
                    GCDualShockGamepad *dualShock = (GCDualShockGamepad *)controller.extendedGamepad;
                    primary = dualShock.touchpadPrimary;
                    secondary = dualShock.touchpadSecondary;
                }
                GCControllerTouchpad *physicalTouchpad = PhysicalControllerTouchpadForSurface(controller, primary);
                GCControllerTouchpad *secondaryTouchpad = PhysicalControllerTouchpadForSurface(controller, secondary);
                Log(LOG_I, @"[controller] Touchpad callbacks: player=%ld physical=%d primary=%d secondary=%d native=%d",
                    (long)controller.playerIndex,
                    physicalTouchpad != nil,
                    primary != nil,
                    secondary != nil,
                    self.nativeTouchpadEnabled);
                if (physicalTouchpad != nil) {
                    primary.valueChangedHandler = nil;
                    RegisterPhysicalTouchpad(self, _controllers[@(controller.playerIndex)], physicalTouchpad, NO);
                } else if (primary != nil) {
                    Controller *touchController = [_controllers objectForKey:@(controller.playerIndex)];
                    primary.valueChangedHandler = ^(GCControllerDirectionPad *pad, float xValue, float yValue) {
                        (void)pad; (void)xValue; (void)yValue;
                        QueueControllerTouchSnapshot(self, touchController, primary, secondary);
                    };
                }
                if (secondaryTouchpad != nil) {
                    secondary.valueChangedHandler = nil;
                    RegisterPhysicalTouchpad(self, _controllers[@(controller.playerIndex)], secondaryTouchpad, YES);
                } else if (secondary != nil) {
                    Controller *touchController = [_controllers objectForKey:@(controller.playerIndex)];
                    secondary.valueChangedHandler = ^(GCControllerDirectionPad *pad, float xValue, float yValue) {
                        (void)pad; (void)xValue; (void)yValue;
                        QueueControllerTouchSnapshot(self, touchController, primary, secondary);
                    };
                }

                GCControllerButtonInput *touchButton = nil;
                if ([controller.extendedGamepad isKindOfClass:[GCDualSenseGamepad class]]) {
                    touchButton = [(GCDualSenseGamepad *)controller.extendedGamepad touchpadButton];
                } else if ([controller.extendedGamepad isKindOfClass:[GCDualShockGamepad class]]) {
                    touchButton = [(GCDualShockGamepad *)controller.extendedGamepad touchpadButton];
                }
                if (touchButton != nil) {
                    Controller *touchController = [_controllers objectForKey:@(controller.playerIndex)];
                    touchButton.pressedChangedHandler = ^(GCControllerButtonInput *button, float value, BOOL pressed) {
                        (void)button;
                        (void)value;
                        [self evaluateControllerShortcuts:touchController];
                        if (ControllerShortcutProtocolMask(ControllerShortcutRouteConsumed(touchController.clientShortcutRouting)) & TOUCHPAD_FLAG)
                            pressed = NO;
                        if ([self.dualSenseTouchpad claimsTouchpad]) {
                            // The physical click rides on the precision touchpad contacts instead of a controller button.
                            if (self.shouldSendInputEvents) {
                                [self.dualSenseTouchpad setButtonPressed:pressed player:touchController.playerIndex];
                            }
                            return;
                        }
                        PML_INPUT_STREAM_CONTEXT inputCtx = ControllerInputContext(self);
                        if (inputCtx != NULL) {
                            if (ControllerTouchpadUsesMouse(self, touchController)) {
                                if (pressed) {
                                    touchController.trackpadPhysicalClickConsumed = YES;
                                    // Mechanical press deflection must not move the
                                    // cursor away from the button being clicked.
                                    touchController.trackpadClickMovementSuppressedUntil = NSProcessInfo.processInfo.systemUptime + 0.05;
                                    // A physical click with the second
                                    // contact down behaves like a secondary
                                    // click, matching the usual trackpad
                                    // convention. Remember the selected
                                    // button until release in case the
                                    // contact is lifted first.
                                }
                                // GC reports the button and touch axes in separate
                                // callbacks. Decide the click after their queued
                                // snapshot, rather than reading a stale contact bit.
                                if (physicalTouchpad == nil && primary != nil)
                                    QueueControllerTouchSnapshot(self, touchController, primary, secondary);
                                NSUInteger generation = touchController.trackpadGestureGeneration;
                                dispatch_async(dispatch_get_main_queue(), ^{
                                    if (generation != touchController.trackpadGestureGeneration ||
                                        !self.shouldSendInputEvents ||
                                        !ControllerTouchpadUsesMouse(self, touchController)) return;
                                    PML_INPUT_STREAM_CONTEXT input = ControllerInputContext(self);
                                    if (input == NULL) return;
                                    if (pressed) {
                                        ControllerTrackpadGesture state = touchController.trackpadGesture;
                                        BOOL twoFingers = ControllerTrackpadSecondaryClick(state,
                                            NSProcessInfo.processInfo.systemUptime, touchController.trackpadTouchEnded);
                                        touchController.trackpadMouseButton = twoFingers ? BUTTON_RIGHT : BUTTON_LEFT;
                                        Log(LOG_I, @"[controller-touch] Physical click player=%d contacts=%u button=%d",
                                            touchController.playerIndex, state.contacts, touchController.trackpadMouseButton);
                                    }
                                    int buttonCode = touchController.trackpadMouseButton;
                                    if (buttonCode == 0) return;
                                    LiSendMouseButtonEventCtx(input,
                                        pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE, buttonCode);
                                    if (!pressed) {
                                        touchController.trackpadMouseButton = 0;
                                        touchController.trackpadClickMovementSuppressedUntil = NSProcessInfo.processInfo.systemUptime + 0.10;
                                    }
                                });
                            } else {
                                UPDATE_BUTTON_FLAG(touchController, TOUCHPAD_FLAG, pressed);
                                [self updateFinished:touchController];
                            }
                        }
                    };
                }
            }
        }
        else if (controller.gamepad != NULL) {
            controller.gamepad.valueChangedHandler = ^(GCGamepad *gamepad, GCControllerElement *element) {
                Controller* limeController = [self->_controllers objectForKey:[NSNumber numberWithInteger:weakController.playerIndex]];
                UPDATE_BUTTON_FLAG(limeController, A_FLAG, gamepad.buttonA.pressed);
                UPDATE_BUTTON_FLAG(limeController, B_FLAG, gamepad.buttonB.pressed);
                UPDATE_BUTTON_FLAG(limeController, X_FLAG, gamepad.buttonX.pressed);
                UPDATE_BUTTON_FLAG(limeController, Y_FLAG, gamepad.buttonY.pressed);

                UPDATE_BUTTON_FLAG(limeController, UP_FLAG, gamepad.dpad.up.pressed);
                UPDATE_BUTTON_FLAG(limeController, DOWN_FLAG, gamepad.dpad.down.pressed);
                UPDATE_BUTTON_FLAG(limeController, LEFT_FLAG, gamepad.dpad.left.pressed);
                UPDATE_BUTTON_FLAG(limeController, RIGHT_FLAG, gamepad.dpad.right.pressed);

                UPDATE_BUTTON_FLAG(limeController, LB_FLAG, gamepad.leftShoulder.pressed);
                UPDATE_BUTTON_FLAG(limeController, RB_FLAG, gamepad.rightShoulder.pressed);

                [self updateFinished:limeController];
            };
        }
    } else {
        Log(LOG_W, @"Tried to register controller callbacks on NULL controller");
    }
}

#if TARGET_OS_IPHONE
-(void) unregisterMouseCallbacks:(GCMouse*)mouse API_AVAILABLE(ios(14.0)) {
    mouse.mouseInput.mouseMovedHandler = nil;

    mouse.mouseInput.leftButton.pressedChangedHandler = nil;
    mouse.mouseInput.middleButton.pressedChangedHandler = nil;
    mouse.mouseInput.rightButton.pressedChangedHandler = nil;

    for (GCControllerButtonInput* auxButton in mouse.mouseInput.auxiliaryButtons) {
        auxButton.pressedChangedHandler = nil;
    }
}

-(void) registerMouseCallbacks:(GCMouse*) mouse API_AVAILABLE(ios(14.0)) {
    mouse.mouseInput.mouseMovedHandler = ^(GCMouseInput * _Nonnull mouse, float deltaX, float deltaY) {
        self->accumulatedDeltaX += deltaX / MOUSE_SPEED_DIVISOR;
        self->accumulatedDeltaY += -deltaY / MOUSE_SPEED_DIVISOR;

        short truncatedDeltaX = (short)self->accumulatedDeltaX;
        short truncatedDeltaY = (short)self->accumulatedDeltaY;

        if (truncatedDeltaX != 0 || truncatedDeltaY != 0) {
            PML_INPUT_STREAM_CONTEXT inputCtx = ControllerInputContext(self);
            if (inputCtx) {
                LiSendMouseMoveEventCtx(inputCtx, truncatedDeltaX, truncatedDeltaY);
            }

            self->accumulatedDeltaX -= truncatedDeltaX;
            self->accumulatedDeltaY -= truncatedDeltaY;
        }
    };

    mouse.mouseInput.leftButton.pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
        PML_INPUT_STREAM_CONTEXT inputCtx = ControllerInputContext(self);
        if (inputCtx) {
            LiSendMouseButtonEventCtx(inputCtx, pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE, BUTTON_LEFT);
        }
    };
    mouse.mouseInput.middleButton.pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
        PML_INPUT_STREAM_CONTEXT inputCtx = ControllerInputContext(self);
        if (inputCtx) {
            LiSendMouseButtonEventCtx(inputCtx, pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE, BUTTON_MIDDLE);
        }
    };
    mouse.mouseInput.rightButton.pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
        PML_INPUT_STREAM_CONTEXT inputCtx = ControllerInputContext(self);
        if (inputCtx) {
            LiSendMouseButtonEventCtx(inputCtx, pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE, BUTTON_RIGHT);
        }
    };

    if (mouse.mouseInput.auxiliaryButtons != nil) {
        if (mouse.mouseInput.auxiliaryButtons.count >= 1) {
            mouse.mouseInput.auxiliaryButtons[0].pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
                PML_INPUT_STREAM_CONTEXT inputCtx = ControllerInputContext(self);
                if (inputCtx) {
                    LiSendMouseButtonEventCtx(inputCtx, pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE, BUTTON_X1);
                }
            };
        }
        if (mouse.mouseInput.auxiliaryButtons.count >= 2) {
            mouse.mouseInput.auxiliaryButtons[1].pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
                PML_INPUT_STREAM_CONTEXT inputCtx = ControllerInputContext(self);
                if (inputCtx) {
                    LiSendMouseButtonEventCtx(inputCtx, pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE, BUTTON_X2);
                }
            };
        }
    }

    // TODO: Confirm scroll direction
    mouse.mouseInput.scroll.yAxis.valueChangedHandler = ^(GCControllerAxisInput * _Nonnull axis, float value) {
        self->accumulatedScrollY += -value;

        short truncatedScrollY = (short)self->accumulatedScrollY;

        if (truncatedScrollY != 0) {
            PML_INPUT_STREAM_CONTEXT inputCtx = ControllerInputContext(self);
            if (inputCtx) {
                LiSendHighResScrollEventCtx(inputCtx, truncatedScrollY);
            }

            self->accumulatedScrollY -= truncatedScrollY;
        }
    };
}
#endif

-(void) updateAutoOnScreenControlMode
{
    // Auto on-screen control support may not be enabled
    if (_osc == NULL) {
        return;
    }

    OnScreenControlsLevel level = OnScreenControlsLevelFull;

    // We currently stop after the first controller we find.
    // Maybe we'll want to change that logic later.
    for (int i = 0; i < [[GCController controllers] count]; i++) {
        GCController *controller = [GCController controllers][i];

        if (controller != NULL) {
            if (controller.extendedGamepad != NULL) {
                level = OnScreenControlsLevelAutoGCExtendedGamepad;
                if (@available(iOS 12.1, tvOS 12.1, macOS 10.14.1, *)) {
                    if (controller.extendedGamepad.leftThumbstickButton != nil &&
                        controller.extendedGamepad.rightThumbstickButton != nil) {
                        level = OnScreenControlsLevelAutoGCExtendedGamepadWithStickButtons;
                        if (@available(iOS 13.0, tvOS 13.0, macOS 10.15, *)) {
                            if (controller.extendedGamepad.buttonOptions != nil) {
                                // Has L3/R3 and Select, so we can show nothing :)
                                level = OnScreenControlsLevelOff;
                            }
                        }
                    }
                }
                break;
            }
            else if (controller.gamepad != NULL) {
                level = OnScreenControlsLevelAutoGCGamepad;
                break;
            }
        }
    }

#if TARGET_OS_IPHONE
    // If we didn't find a gamepad present and we have a keyboard or mouse, turn
    // the on-screen controls off to get the overlays out of the way.
    if (level == OnScreenControlsLevelFull && [ControllerSupport hasKeyboardOrMouse]) {
        level = OnScreenControlsLevelOff;

        // Ensure the virtual gamepad disappears to avoid confusing some games.
        // If the mouse and keyboard disconnect later, it will reappear when the
        // first OSC input is received.
        PML_INPUT_STREAM_CONTEXT inputCtx = ControllerInputContext(self);
        if (inputCtx) {
            LiSendMultiControllerEventCtx(inputCtx, 0, 0, 0, 0, 0, 0, 0, 0, 0);
        }
    }

    [_osc setLevel:level];
#endif
}

-(void) initAutoOnScreenControlMode:(OnScreenControls*)osc
{
    _osc = osc;

    [self updateAutoOnScreenControlMode];
}

-(void) assignController:(GCController*)controller {
    for (int i = 0; i < 4; i++) {
        if (!(_controllerNumbers & (1 << i))) {
            _controllerNumbers |= (1 << i);
            controller.playerIndex = i;

            Controller* limeController;

            if (i == 0) {
                // Player 0 shares a controller object with the on-screen controls
                limeController = _player0osc;
            } else {
                limeController = [[Controller alloc] init];
                limeController.playerIndex = i;
            }

            controller.handlerQueue = dispatch_get_main_queue();
            limeController.gamepad = controller;
            limeController.controllerAnnounced = NO;
            limeController.primaryTouchActive = NO;
            limeController.secondaryTouchActive = NO;

            // Prepare controller haptics for use
            [self initializeControllerHaptics:limeController];

            [_controllers setObject:limeController forKey:[NSNumber numberWithInteger:controller.playerIndex]];

            Log(LOG_I, @"Assigning controller index: %d", i);
            break;
        }
    }
}

#if TARGET_OS_IPHONE
-(Controller*) getOscController {
    return _player0osc;
}
#endif

+(bool) isSupportedGamepad:(GCController*) controller {
    return controller.extendedGamepad != nil || controller.gamepad != nil;
}

#pragma clang diagnostic pop

+(int) getGamepadCount {
    int count = 0;

    for (GCController* controller in [GCController controllers]) {
        if ([ControllerSupport isSupportedGamepad:controller]) {
            count++;
        }
    }

    return count;
}

+(int) getConnectedGamepadMask:(StreamConfiguration*)streamConfig {
    int mask = 0;

    if (streamConfig.multiController) {
        int i = 0;
        for (GCController* controller in [GCController controllers]) {
            if ([ControllerSupport isSupportedGamepad:controller]) {
                mask |= 1 << i++;
            }
        }
    }
    else {
        // Some games don't deal with having controller reconnected
        // properly so always report controller 1 if not in MC mode
        mask = 0x1;
    }

#if TARGET_OS_IPHONE
    DataManager* dataMan = [[DataManager alloc] init];
    TemporarySettings* settings = [dataMan getSettings];
    OnScreenControlsLevel level = (OnScreenControlsLevel)[settings.onscreenControls integerValue];

    // Even if no gamepads are present, we will always count one if OSC is enabled,
    // or it's set to auto and no keyboard or mouse is present. Absolute touch mode
    // disables the OSC.
    if (level != OnScreenControlsLevelOff && (![ControllerSupport hasKeyboardOrMouse] || level != OnScreenControlsLevelAuto) && !settings.absoluteTouchMode) {
        mask |= 0x1;
    }
#endif

    return mask;
}

-(NSUInteger) getConnectedGamepadCount
{
    return _controllers.count;
}

-(id) initWithConfig:(StreamConfiguration*)streamConfig presenceDelegate:(id<InputPresenceDelegate>)delegate
{
    self = [super init];

    _controllerStreamLock = [[NSLock alloc] init];
    _hapticsMailboxLock = [[NSObject alloc] init];
    _pendingHaptics = [[NSMutableDictionary alloc] init];

    _ds5HapticsAudioRenderer = [[Ds5HapticsAudioRenderer alloc] init];
    _controllers = [[NSMutableDictionary alloc] init];
    _controllerNumbers = 0;
    _multiController = streamConfig.multiController;
    _gamepadMouseModeEnabled = streamConfig.gamepadMouseMode;
    _nativeTouchpadEnabled = streamConfig.nativeTouchpad;
    _gamepadMouseModeLongPressMenuEnabled = streamConfig.gamepadMouseModeLongPressMenu;
    _gamepadTrackpadPointerSensitivity = streamConfig.gamepadTrackpadPointerSensitivity > 0.0
        ? streamConfig.gamepadTrackpadPointerSensitivity : 1.0;
    _gamepadTrackpadScrollSpeed = streamConfig.gamepadTrackpadScrollSpeed > 0.0
        ? streamConfig.gamepadTrackpadScrollSpeed : 1.0;
    _gamepadTrackpadReverseScroll = streamConfig.gamepadTrackpadReverseScroll;
    _gamepadDeadzone = MIN(0.30, MAX(0.0, streamConfig.gamepadDeadzone));
    _controllerHapticsMode = streamConfig.controllerHapticsMode;
    _controllerMotionMode = streamConfig.controllerMotionMode;
    _controllerFeedbackTarget = streamConfig.controllerFeedbackTarget;
    _controllerVirtualType = streamConfig.controllerVirtualType;
    _clientGamepad = [streamConfig.clientGamepad copy];
    _controllerLeftCenterX = MIN(1.0, MAX(-1.0, streamConfig.controllerLeftCenterX));
    _controllerLeftCenterY = MIN(1.0, MAX(-1.0, streamConfig.controllerLeftCenterY));
    _controllerRightCenterX = MIN(1.0, MAX(-1.0, streamConfig.controllerRightCenterX));
    _controllerRightCenterY = MIN(1.0, MAX(-1.0, streamConfig.controllerRightCenterY));
    _controllerLeftGain = MIN(2.0, MAX(0.25, streamConfig.controllerLeftGain > 0.0 ? streamConfig.controllerLeftGain : 1.0));
    _controllerRightGain = MIN(2.0, MAX(0.25, streamConfig.controllerRightGain > 0.0 ? streamConfig.controllerRightGain : 1.0));
    Log(LOG_I, @"[controller-settings] deadzone=%.3f haptics=%ld motion=%ld feedbackTarget=%ld calibration=(%.3f,%.3f)/(%.3f,%.3f) gain=(%.3f,%.3f)",
        (double)_gamepadDeadzone, (long)_controllerHapticsMode, (long)_controllerMotionMode,
        (long)_controllerFeedbackTarget, (double)_controllerLeftCenterX, (double)_controllerLeftCenterY,
        (double)_controllerRightCenterX, (double)_controllerRightCenterY,
        (double)_controllerLeftGain, (double)_controllerRightGain);
    _presenceDelegate = delegate;
    __weak typeof(self) weakSettingsSelf = self;
    NSString *sessionHostId = [streamConfig.hostUUID copy];
    _touchpadSettingsObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:@"ControllerTouchpadModeDidChange" object:nil queue:NSOperationQueue.mainQueue
        usingBlock:^(NSNotification *note) {
            ControllerSupport *me = weakSettingsSelf;
            NSString *host = note.userInfo[@"hostId"];
            if (!me || (![host isEqualToString:sessionHostId] && ![host isEqualToString:@"__global__"])) return;
            PML_INPUT_STREAM_CONTEXT input = ControllerInputContext(me);
            for (Controller *controller in me->_controllers.allValues) {
                if (input && ControllerTouchpadUsesMouse(me, controller) && controller.trackpadMouseButton)
                    LiSendMouseButtonEventCtx(input, BUTTON_ACTION_RELEASE, controller.trackpadMouseButton);
                if (input && !ControllerTouchpadUsesMouse(me, controller)) {
                    if (controller.primaryTouchActive) LiSendControllerTouchEventCtx(input, controller.playerIndex,
                        LI_TOUCH_EVENT_UP, controller.playerIndex * 2, controller.lastPrimaryTouchX, controller.lastPrimaryTouchY, 0);
                    if (controller.secondaryTouchActive) LiSendControllerTouchEventCtx(input, controller.playerIndex,
                        LI_TOUCH_EVENT_UP, controller.playerIndex * 2 + 1, controller.lastSecondaryTouchX, controller.lastSecondaryTouchY, 0);
                    [me clearButtonFlag:controller flags:TOUCHPAD_FLAG];
                    [me updateFinished:controller];
                }
                controller.hasTouchpadModeOverride = NO;
                ResetControllerTrackpadMouseState(controller);
            }
            me.nativeTouchpadEnabled = [note.userInfo[@"native"] boolValue];
            Log(LOG_I, @"[controller-touch] Live setting native=%d", me.nativeTouchpadEnabled);
        }];

    _dualSenseTouchpad = [[MLDualSenseTouchpad alloc] init];
    _dualSenseTouchpad.contextProvider = ^PML_INPUT_STREAM_CONTEXT {
        ControllerSupport *me = weakSettingsSelf;
        PML_INPUT_STREAM_CONTEXT ctx = me != nil ? ControllerInputContext(me) : NULL;
        return (ctx != NULL && LiInputContextIsInitialized(ctx)) ? ctx : NULL;
    };
    _dualSenseTouchpad.enabled = streamConfig.dualSensePrecisionTouchpad;
    Log(LOG_I, @"[touchpad] ds5 output=%@", streamConfig.dualSensePrecisionTouchpad ? @"precision" : @"controller");
    _dualSensePrecisionObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:@"ControllerDualSensePrecisionTouchpadDidChange" object:nil queue:NSOperationQueue.mainQueue
        usingBlock:^(NSNotification *note) {
            ControllerSupport *me = weakSettingsSelf;
            NSString *host = note.userInfo[@"hostId"];
            if (!me || (![host isEqualToString:sessionHostId] && ![host isEqualToString:@"__global__"])) return;
            BOOL precision = [note.userInfo[@"precision"] boolValue];
            PML_INPUT_STREAM_CONTEXT input = ControllerInputContext(me);
            // Whatever the previous output still holds on the host is let go before the switch.
            for (Controller *controller in me->_controllers.allValues) {
                if (input && controller.trackpadMouseButton)
                    LiSendMouseButtonEventCtx(input, BUTTON_ACTION_RELEASE, controller.trackpadMouseButton);
                if (input && controller.primaryTouchActive) LiSendControllerTouchEventCtx(input, controller.playerIndex,
                    LI_TOUCH_EVENT_UP, controller.playerIndex * 2, controller.lastPrimaryTouchX, controller.lastPrimaryTouchY, 0);
                if (input && controller.secondaryTouchActive) LiSendControllerTouchEventCtx(input, controller.playerIndex,
                    LI_TOUCH_EVENT_UP, controller.playerIndex * 2 + 1, controller.lastSecondaryTouchX, controller.lastSecondaryTouchY, 0);
                if (input && (controller.lastButtonFlags & TOUCHPAD_FLAG) != 0) {
                    [me clearButtonFlag:controller flags:TOUCHPAD_FLAG];
                    [me updateFinished:controller];
                }
                ResetControllerTrackpadMouseState(controller);
            }
            me->_dualSenseTouchpad.enabled = precision;
            Log(LOG_I, @"[touchpad] ds5 output=%@ (live setting)", precision ? @"precision" : @"controller");
        }];

    _controllerMaintenanceTimer = [NSTimer timerWithTimeInterval:0.1 target:self
        selector:@selector(controllerMaintenance:) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_controllerMaintenanceTimer forMode:NSRunLoopCommonModes];


    _debouncers = [[NSMutableDictionary alloc] init];
    _debouncers[@(PLAY_FLAG)] = [[NSMutableDictionary alloc] init];
    _debouncers[@(BACK_FLAG)] = [[NSMutableDictionary alloc] init];

    _mouseTimer = [NSTimer timerWithTimeInterval:0.016 target:self selector:@selector(mouseTimerCallback:) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_mouseTimer forMode:NSRunLoopCommonModes];

    _player0osc = [[Controller alloc] init];
    _player0osc.playerIndex = 0;

#if TARGET_OS_IPHONE
    DataManager* dataMan = [[DataManager alloc] init];
    _oscEnabled = (OnScreenControlsLevel)[[dataMan getSettings].onscreenControls integerValue] != OnScreenControlsLevelOff;
#endif

    Log(LOG_I, @"Number of supported controllers connected: %d", [ControllerSupport getGamepadCount]);
    Log(LOG_I, @"Multi-controller: %d", _multiController);

    for (GCController* controller in [GCController controllers]) {
        if ([ControllerSupport isSupportedGamepad:controller]) {
            [self assignController:controller];
            [self registerControllerCallbacks:controller];
            [self setupDebouncersForController:[_controllers objectForKey:@(controller.playerIndex)]];
        }
    }

#if TARGET_OS_IPHONE
    if (@available(iOS 14.0, tvOS 14.0, *)) {
        for (GCMouse* mouse in [GCMouse mice]) {
            [self registerMouseCallbacks:mouse];
        }
    }
#endif

    _controllerConnectObserver = [[NSNotificationCenter defaultCenter] addObserverForName:GCControllerDidConnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        Log(LOG_I, @"Controller connected!");

        GCController* controller = note.object;

        if (![ControllerSupport isSupportedGamepad:controller]) {
            // Ignore micro gamepads and motion controllers
            return;
        }

        [self assignController:controller];

        // Register callbacks on the new controller
        [self registerControllerCallbacks:controller];

        [self setupDebouncersForController:[self->_controllers objectForKey:@(controller.playerIndex)]];

        // Re-evaluate the on-screen control mode
        [self updateAutoOnScreenControlMode];

        // Notify the delegate
        [self->_presenceDelegate gamepadPresenceChanged];
    }];
    _controllerDisconnectObserver = [[NSNotificationCenter defaultCenter] addObserverForName:GCControllerDidDisconnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        Log(LOG_I, @"Controller disconnected!");

        GCController* controller = note.object;

        if (![ControllerSupport isSupportedGamepad:controller]) {
            // Ignore micro gamepads and motion controllers
            return;
        }

        [self unregisterControllerCallbacks:controller];
        self->_controllerNumbers &= ~(1 << controller.playerIndex);
        Log(LOG_I, @"Unassigning controller index: %ld", (long)controller.playerIndex);

        // Unset the GCController on this object (in case it is the OSC, which will persist)
        Controller* limeController = [self->_controllers objectForKey:[NSNumber numberWithInteger:controller.playerIndex]];

        // Lift the pad's fingers on the host before the controller goes away
        [self->_dualSenseTouchpad releasePlayer:controller.playerIndex];

        // Stop haptics on this controller
        [self cleanupControllerHaptics:limeController];

        limeController.gamepad = nil;

        // Inform the server of the updated active gamepads before removing this controller
        [self updateFinished:limeController];
        [self->_controllers removeObjectForKey:[NSNumber numberWithInteger:controller.playerIndex]];

        // Re-evaluate the on-screen control mode
        [self updateAutoOnScreenControlMode];

        // Notify the delegate
        [self->_presenceDelegate gamepadPresenceChanged];
    }];

#if TARGET_OS_IPHONE
    if (@available(iOS 14.0, tvOS 14.0, *)) {
        _mouseConnectObserver = [[NSNotificationCenter defaultCenter] addObserverForName:GCMouseDidConnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            Log(LOG_I, @"Mouse connected!");

            GCMouse* mouse = note.object;

            // Register for mouse events
            [self registerMouseCallbacks: mouse];

            // Re-evaluate the on-screen control mode
            [self updateAutoOnScreenControlMode];

            // Notify the delegate
            [self->_presenceDelegate mousePresenceChanged];
        }];
        _mouseDisconnectObserver = [[NSNotificationCenter defaultCenter] addObserverForName:GCMouseDidDisconnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            Log(LOG_I, @"Mouse disconnected!");

            GCMouse* mouse = note.object;

            // Unregister for mouse events
            [self unregisterMouseCallbacks: mouse];

            // Re-evaluate the on-screen control mode
            [self updateAutoOnScreenControlMode];

            // Notify the delegate
            [self->_presenceDelegate mousePresenceChanged];
        }];
        _keyboardConnectObserver = [[NSNotificationCenter defaultCenter] addObserverForName:GCKeyboardDidConnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            Log(LOG_I, @"Keyboard connected!");

            // Re-evaluate the on-screen control mode
            [self updateAutoOnScreenControlMode];
        }];
        _keyboardDisconnectObserver = [[NSNotificationCenter defaultCenter] addObserverForName:GCKeyboardDidDisconnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            Log(LOG_I, @"Keyboard disconnected!");

            // Re-evaluate the on-screen control mode
            [self updateAutoOnScreenControlMode];
        }];
    }
#endif

    return self;
}

-(void) setupDebouncersForController:(Controller*)controller {
    if (@available(iOS 13.0, macOS 10.15, *)) {
        if (controller.gamepad.extendedGamepad == nil) return;

        ButtonDebouncer *play = [[ButtonDebouncer alloc] initWithButton:PLAY_FLAG input:controller.gamepad.extendedGamepad.buttonMenu controllerSupport:self chordButton:SPECIAL_FLAG];
        ButtonDebouncer *back = [[ButtonDebouncer alloc] initWithButton:BACK_FLAG input:controller.gamepad.extendedGamepad.buttonOptions controllerSupport:self chordButton:SPECIAL_FLAG];
        play.other = back;
        back.other = play;

        _debouncers[@(PLAY_FLAG)][@(controller.playerIndex)] = play;
        _debouncers[@(BACK_FLAG)][@(controller.playerIndex)] = back;
    }
}

-(void) cleanup
{
    [_dualSenseTouchpad releaseAll];
    _dualSenseTouchpad.enabled = NO;
    [[NSNotificationCenter defaultCenter] removeObserver:_dualSensePrecisionObserver];
    _dualSensePrecisionObserver = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:_touchpadSettingsObserver];
    _touchpadSettingsObserver = nil;
    [_controllerMaintenanceTimer invalidate];
    _controllerMaintenanceTimer = nil;
    @synchronized(_hapticsMailboxLock) { [_pendingHaptics removeAllObjects]; }

    [[NSNotificationCenter defaultCenter] removeObserver:_controllerConnectObserver];
    [[NSNotificationCenter defaultCenter] removeObserver:_controllerDisconnectObserver];
#if TARGET_OS_IPHONE
    [[NSNotificationCenter defaultCenter] removeObserver:_mouseConnectObserver];
    [[NSNotificationCenter defaultCenter] removeObserver:_mouseDisconnectObserver];
    [[NSNotificationCenter defaultCenter] removeObserver:_keyboardConnectObserver];
    [[NSNotificationCenter defaultCenter] removeObserver:_keyboardDisconnectObserver];
#endif

    _controllerConnectObserver = nil;
    _controllerDisconnectObserver = nil;
#if TARGET_OS_IPHONE
    _mouseConnectObserver = nil;
    _mouseDisconnectObserver = nil;
    _keyboardConnectObserver = nil;
    _keyboardDisconnectObserver = nil;
#endif

    _controllerNumbers = 0;

    for (Controller* controller in [_controllers allValues]) {
        [self cleanupControllerHaptics:controller];
    }
    [_ds5HapticsAudioRenderer reset];
    _ds5HapticsAudioRenderer = nil;
    [_controllers removeAllObjects];

    for (GCController* controller in [GCController controllers]) {
        if ([ControllerSupport isSupportedGamepad:controller]) {
            [self unregisterControllerCallbacks:controller];
        }
    }

#if TARGET_OS_IPHONE
    if (@available(iOS 14.0, tvOS 14.0, *)) {
        for (GCMouse* mouse in [GCMouse mice]) {
            [self unregisterMouseCallbacks:mouse];
        }
    }
#endif

    if (_mouseTimer) {
        [_mouseTimer invalidate];
        _mouseTimer = nil;
    }
}

- (void)toggleControllerMouseModeForPlayer:(unsigned short)player {
    Controller *controller = _controllers[@(player)];
    if (!controller) return;
    GCExtendedGamepad *gamepad = controller.gamepad.extendedGamepad;
    BOOL dualSense = [gamepad isKindOfClass:GCDualSenseGamepad.class];

            PML_INPUT_STREAM_CONTEXT input = ControllerInputContext(self);
            BOOL wasMouse = ControllerTouchpadUsesMouse(self, controller);
            if (input) {
                if (!wasMouse) {
                    if (controller.primaryTouchActive) LiSendControllerTouchEventCtx(input, (uint8_t)controller.playerIndex,
                        LI_TOUCH_EVENT_UP, controller.playerIndex * 2, controller.lastPrimaryTouchX, controller.lastPrimaryTouchY, 0);
                    if (controller.secondaryTouchActive) LiSendControllerTouchEventCtx(input, (uint8_t)controller.playerIndex,
                        LI_TOUCH_EVENT_UP, controller.playerIndex * 2 + 1, controller.lastSecondaryTouchX, controller.lastSecondaryTouchY, 0);
                    if ((controller.lastButtonFlags & TOUCHPAD_FLAG) != 0) [self clearButtonFlag:controller flags:TOUCHPAD_FLAG];
                } else if (controller.trackpadMouseButton) {
                    LiSendMouseButtonEventCtx(input, BUTTON_ACTION_RELEASE, controller.trackpadMouseButton);
                }
            }
            if (dualSense) {
                controller.touchpadMouseMode = !wasMouse;
                controller.hasTouchpadModeOverride = YES;
            } else [self setGamepadMouseModeActive:!controller.isMouseMode forController:controller];
            ResetControllerTrackpadMouseState(controller);
            [self clearButtonFlag:controller flags:PLAY_FLAG];
            [self updateFinished:controller];
            BOOL nowMouse = ControllerTouchpadUsesMouse(self, controller);
            Log(LOG_I, @"[controller-touch] Options held player=%d mode=%@", controller.playerIndex,
                nowMouse ? @"trackpad-pointer-scroll" : @"host-controller-touch");
            if ([_presenceDelegate respondsToSelector:@selector(mouseModeToggled:)])
                [_presenceDelegate mouseModeToggled:nowMouse];

}
- (uint64_t)evaluateControllerShortcuts:(Controller *)controller {
    if (self.controllerShortcutHandler == nil) return 0;
    uint32_t physical = ControllerShortcutNeutralMask(ControllerShortcutPhysicalButtons(controller.gamepad.extendedGamepad));
    controller.clientShortcutRouting = self.controllerShortcutHandler((unsigned short)controller.playerIndex, physical);
    return controller.clientShortcutRouting;
}
- (void)refreshControllerShortcutOutputForPlayer:(unsigned short)player {
    Controller *controller = _controllers[@(player)];
    if (controller) { [self evaluateControllerShortcuts:controller]; [self updateFinished:controller]; }
}

-(void) mouseTimerCallback:(NSTimer*)timer {
    for (Controller *controller in _controllers.allValues) [self evaluateControllerShortcuts:controller];
    if (!self.shouldSendInputEvents || !ControllerInputContext(self)) return;
    for (Controller* controller in [_controllers allValues]) {
        if (controller.gamepad == nil) continue;

        GCController *gcController = controller.gamepad;
        GCExtendedGamepad *gamepad = gcController.extendedGamepad;

        // The long-press shortcut has its own switch. As in 1.3.8, it can
        // enter mouse mode from the normal default gamepad configuration.
        // With the shortcut runtime attached, Menu long-press is one of its bindings.
        BOOL enabled = self.controllerShortcutHandler == nil && _gamepadMouseModeLongPressMenuEnabled;
        BOOL pressed = gamepad.buttonMenu.pressed;
        ControllerMenuGesture gesture = controller.menuGesture;
        BOOL toggle = ControllerMenuGestureUpdate(&gesture, enabled, pressed, NSProcessInfo.processInfo.systemUptime);
        controller.menuGesture = gesture;
        if (toggle) [self toggleControllerMouseModeForPlayer:(unsigned short)controller.playerIndex];

        // 2. Mouse Movement Logic
        if (controller.isMouseMode) {
            float deltaX = 0;
            float deltaY = 0;

            // The right stick remains a compatibility fallback, but a live
            // touch contact owns the pointer until it is lifted. This avoids
            // mixing stick motion into a precise touchpad gesture.
            if (gamepad && !controller.primaryTouchActive && !controller.secondaryTouchActive) {
                deltaX = gamepad.rightThumbstick.xAxis.value;
                deltaY = gamepad.rightThumbstick.yAxis.value;
            }

            // Apply deadzone and sensitivity
            if (fabs(deltaX) > 0.1 || fabs(deltaY) > 0.1) {
                // Sensitivity 15.0 per frame (approx 900px/sec at 60Hz)
                float sensitivity = 15.0;

                self->_accumulatedMouseX += deltaX * sensitivity;
                self->_accumulatedMouseY += -deltaY * sensitivity;

                short truncX = (short)self->_accumulatedMouseX;
                short truncY = (short)self->_accumulatedMouseY;

                if (truncX != 0 || truncY != 0) {
                    PML_INPUT_STREAM_CONTEXT inputCtx = ControllerInputContext(self);
                    if (inputCtx) {
                        LiSendMouseMoveEventCtx(inputCtx, truncX, truncY);
                    }
                    self->_accumulatedMouseX -= truncX;
                    self->_accumulatedMouseY -= truncY;
                }
            }
        }
    }
}

@end
