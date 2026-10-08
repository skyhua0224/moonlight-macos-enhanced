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
#include "../../modules/controller-feedback/ControllerFeedbackEnvelope.h"
#include "Limelight.h"
#include "Limelight-internal.h"

@import GameController;
@import AudioToolbox;
@import CoreHaptics;

#import <math.h>

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
        BOOL transitioned = ControllerTrackpadUpdate(&state, pointerId & 1u, hasContact, normalizedX, normalizedY);
        controller.trackpadGesture = state;
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
            NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
            if (previousContacts == 0 && state.contacts != 0) {
                controller.trackpadTouchBegan = now;
                controller.trackpadPhysicalClickConsumed = controller.trackpadMouseButton != 0;
            }
            if (previousContacts != 0 && state.contacts == 0) {
                BOOL tap = controller.trackpadTouchBegan > 0 &&
                    now - controller.trackpadTouchBegan <= 0.25 &&
                    state.maximumTravelSquared <= 0.000064f &&
                    !controller.trackpadPhysicalClickConsumed;
                if (tap && current.shouldSendInputEvents) {
                    PML_INPUT_STREAM_CONTEXT input = ControllerInputContext(current);
                    if (input != NULL) {
                        int button = state.maximumContacts == 2 ? BUTTON_RIGHT : BUTTON_LEFT;
                        LiSendMouseButtonEventCtx(input, BUTTON_ACTION_PRESS, button);
                        LiSendMouseButtonEventCtx(input, BUTTON_ACTION_RELEASE, button);
                    }
                }
                controller.trackpadTouchBegan = 0;
            }
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

static void ApplyDualSenseTriggerEffect(GCDualSenseAdaptiveTrigger *trigger,
                                        uint8_t type, const uint8_t *effect) {
    if (trigger == nil) {
        return;
    }
    if (type == 0 || effect == NULL) {
        [trigger setModeOff];
        return;
    }

    float p0 = effect[0] / 255.0f;
    float p1 = effect[1] / 255.0f;
    float p2 = effect[2] / 255.0f;
    if (@available(macOS 11.3, *)) {
        switch (type) {
            case 0x01: // Feedback: start position + resistive strength.
                [trigger setModeFeedbackWithStartPosition:p0 resistiveStrength:p1];
                break;
            case 0x02: // Weapon: start position + end position + strength.
                [trigger setModeWeaponWithStartPosition:p0 endPosition:MAX(p0 + 0.001f, p1)
                                    resistiveStrength:p2];
                break;
            case 0x06: // Vibration: start position + amplitude + frequency.
                [trigger setModeVibrationWithStartPosition:p0 amplitude:p1 frequency:p2];
                break;
            default:
                // The macOS public API has no equivalent for the remaining
                // vendor effect encodings; fail closed instead of guessing.
                [trigger setModeOff];
                break;
        }
    }
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
    NSObject *_hapticsMailboxLock;
    NSMutableDictionary<NSNumber *, NSData *> *_pendingHaptics;
    BOOL _hapticsDrainScheduled;
    id _touchpadSettingsObserver;
    NSTimer *_controllerMaintenanceTimer;
    NSUInteger _maintenanceTicks;

}

@synthesize shouldSendInputEvents = _shouldSendInputEvents;

- (void)setShouldSendInputEvents:(BOOL)enabled {
    BOOL wasEnabled = _shouldSendInputEvents;
    _shouldSendInputEvents = enabled;
    if (wasEnabled && !enabled) {
        for (Controller *controller in _controllers.allValues) {
            ControllerMenuGesture gesture = controller.menuGesture;
            ControllerMenuGestureInterrupt(&gesture, controller.gamepad.extendedGamepad.buttonMenu.pressed);
            controller.menuGesture = gesture;
        }
        PML_INPUT_STREAM_CONTEXT input = ControllerInputContext(self);
        if (input != NULL && LiInputContextIsInitialized(input)) {
            [_controllerStreamLock lock];
            for (Controller *controller in _controllers.allValues) {
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
    // Rebuild A/B and stick state through our existing input handler so held
    // controls resume immediately when mouse emulation is switched off.
    if (gamepad.valueChangedHandler) {
        gamepad.valueChangedHandler(gamepad, gamepad.buttonMenu);
    }
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

-(void) rumble:(unsigned short)controllerNumber lowFreqMotor:(unsigned short)lowFreqMotor highFreqMotor:(unsigned short)highFreqMotor
{
    if (![NSThread isMainThread]) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (weakSelf.shouldSendInputEvents) [weakSelf rumble:controllerNumber lowFreqMotor:lowFreqMotor highFreqMotor:highFreqMotor];
        });
        return;
    }
    if (!ControllerIsFeedbackTarget(self, controllerNumber)) return;
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
    if (!(left && right) && [_presenceDelegate respondsToSelector:@selector(controllerRumbleFallback:low:high:)]) {
        [_presenceDelegate controllerRumbleFallback:controllerNumber low:lowFreqMotor high:highFreqMotor];
    }
}

// The control receive thread only copies into a bounded, per-player mailbox.
// Controller ownership, engines and light state remain on the main queue.
- (void)ds5HapticsIrV2:(const LI_DS5_HAPTICS_IR_FRAME_V2 *)frame {
    if (!frame || !self.shouldSendInputEvents || frame->controllerNumber >= 16) return;
    BOOL schedule = NO;
    @synchronized(_hapticsMailboxLock) {
        _pendingHaptics[@(frame->controllerNumber)] = [NSData dataWithBytes:frame length:sizeof(*frame)];
        if (!_hapticsDrainScheduled) { _hapticsDrainScheduled = YES; schedule = YES; }
    }
    if (schedule) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf drainAuthoredHaptics]; });
    }
}

- (void)drainAuthoredHaptics {
    NSDictionary<NSNumber *, NSData *> *frames;
    @synchronized(_hapticsMailboxLock) {
        frames = [_pendingHaptics copy];
        [_pendingHaptics removeAllObjects];
        _hapticsDrainScheduled = NO;
    }
    if (!self.shouldSendInputEvents) return;
    for (NSNumber *number in frames) {
        LI_DS5_HAPTICS_IR_FRAME_V2 frame;
        [frames[number] getBytes:&frame length:sizeof(frame)];
        if (!ControllerIsFeedbackTarget(self, frame.controllerNumber)) continue;
        Controller *controller = _controllers[number];
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
        }
        if (!native) {
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
            PML_INPUT_STREAM_CONTEXT input = ControllerInputContext(self);
            if (input) LiSendControllerBatteryEventCtx(input, (uint8_t)controller.playerIndex, state, percent);
        }
    }
}

- (void)ds5HapticsPcm:(const LI_DS5_HAPTICS_PCM_FRAME *)frame
{
    if (frame == NULL || !ControllerIsFeedbackTarget(self, frame->controllerNumber) ||
        frame->sampleRate != 48000 || frame->channelCount != 2 ||
        frame->bitsPerSample != 16 || frame->frameCount > 480 ||
        frame->pcmDataLength != (uint32_t)frame->frameCount * 4 ||
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
    if (@available(macOS 10.15, *)) {
        if (gamepad.motion == nil) {
            return;
        }
    } else {
        return;
    }

    if (reportRateHz == 0) {
        gamepad.motion.valueChangedHandler = nil;
        return;
    }

    __weak typeof(self) weakSelf = self;
    gamepad.motion.valueChangedHandler = ^(GCMotion *motion) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        PML_INPUT_STREAM_CONTEXT inputCtx = ControllerInputContext(strongSelf);
        if (inputCtx == NULL) {
            return;
        }

        if (motionType == LI_MOTION_TYPE_ACCEL) {
            GCAcceleration acceleration = motion.userAcceleration;
            LiSendControllerMotionEventCtx(inputCtx, (uint8_t)controllerNumber, motionType,
                                           acceleration.x * 9.80665f,
                                           acceleration.y * 9.80665f,
                                           acceleration.z * 9.80665f);
        } else if (motionType == LI_MOTION_TYPE_GYRO) {
            GCRotationRate rotation = motion.rotationRate;
            LiSendControllerMotionEventCtx(inputCtx, (uint8_t)controllerNumber, motionType,
                                           rotation.x, rotation.y, rotation.z);
        }
    };
    gamepad.motion.sensorsActive = YES;
    (void)reportRateHz;
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
        if ((controller.lastButtonFlags & quitFlags) == quitFlags) {
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
            if (self.controllerVirtualType == 1) {
                controllerType = LI_CTYPE_XBOX;
            } else if (self.controllerVirtualType == 2) {
                controllerType = LI_CTYPE_PS;
            } else if (hasTouchpad) {
                controllerType = LI_CTYPE_PS;
            }
            BOOL allowsPlayStationExtensions = controllerType != LI_CTYPE_XBOX;
            if (hasTouchpad && allowsPlayStationExtensions) {
                capabilities |= LI_CCAP_TOUCHPAD;
                if ([extended isKindOfClass:GCDualSenseGamepad.class] &&
                    self.controllerHapticsMode == 0 && [Ds5HapticsAudioRenderer hasPhysicalEndpoint]) {
                    capabilities |= LI_CCAP_DS5_HAPTICS_PCM;
                }
                supportedButtonFlags |= TOUCHPAD_FLAG;
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
                                          controller.lastButtonFlags,
                                          controller.lastLeftTrigger,
                                          controller.lastRightTrigger,
                                          controller.lastLeftStickX,
                                          controller.lastLeftStickY,
                                          controller.lastRightStickX,
                                          controller.lastRightStickY);
        }
        else {
            LiSendControllerEventCtx(inputCtx,
                                     controller.lastButtonFlags,
                                     controller.lastLeftTrigger,
                                     controller.lastRightTrigger,
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
                short leftStickX, leftStickY;
                short rightStickX, rightStickY;
                unsigned char leftTrigger, rightTrigger;

                if (limeController.isMouseMode) {
                    // Mouse Toggle and Movement are handled by timer
                    
                    // Mouse Clicks (A = Left, B = Right)
                    BOOL currentA = gamepad.buttonA.pressed;
                    BOOL currentB = gamepad.buttonB.pressed;
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
                                    BOOL secondaryContact = secondary != nil &&
                                        (fabsf(secondary.xAxis.value) > 0.001f || fabsf(secondary.yAxis.value) > 0.001f);
                                    touchController.trackpadMouseButton =
                                        (touchController.secondaryTouchActive || secondaryContact) ? BUTTON_RIGHT : BUTTON_LEFT;
                                }
                                int buttonCode = touchController.trackpadMouseButton != 0
                                    ? touchController.trackpadMouseButton : BUTTON_LEFT;
                                LiSendMouseButtonEventCtx(inputCtx,
                                                          pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE,
                                                          buttonCode);
                                if (!pressed) {
                                    touchController.trackpadMouseButton = 0;
                                }
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

-(void) mouseTimerCallback:(NSTimer*)timer {
    if (!self.shouldSendInputEvents || !ControllerInputContext(self)) return;
    for (Controller* controller in [_controllers allValues]) {
        if (controller.gamepad == nil) continue;
        
        GCController *gcController = controller.gamepad;
        GCExtendedGamepad *gamepad = gcController.extendedGamepad;
        
        // DualSense Options toggles only the touch surface. Game controls keep
        // streaming, including while Windows is receiving trackpad gestures.
        BOOL dualSense = [gamepad isKindOfClass:GCDualSenseGamepad.class];
        BOOL enabled = _gamepadMouseModeLongPressMenuEnabled && (dualSense || _gamepadMouseModeEnabled);
        BOOL pressed = gamepad.buttonMenu.pressed;
        ControllerMenuGesture gesture = controller.menuGesture;
        BOOL toggle = ControllerMenuGestureUpdate(&gesture, enabled, pressed, NSProcessInfo.processInfo.systemUptime);
        controller.menuGesture = gesture;
        if (toggle) {
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
