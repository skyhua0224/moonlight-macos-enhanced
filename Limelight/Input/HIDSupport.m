//
//  HIDSupport.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 26/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//
#import "HIDSupport_Internal.h"

#import <IOKit/hid/IOHIDElement.h>
#import <IOKit/hidsystem/IOLLEvent.h>


NSString *const HIDMouseModeToggledNotification = @"HIDMouseModeToggledNotification";
NSString *const HIDGamepadQuitNotification = @"HIDGamepadQuitNotification";

// Factory-calibrated DS4 gyros can retain roughly 1-2 dps of thermal noise
// after a movement. Requiring every axis vector to stay below 1 dps caused
// the stationary counter to be reset repeatedly, producing several seconds
// of visible drift. Hysteresis preserves deliberate low-speed motion while
// allowing a genuinely stationary controller to settle promptly.
static const float kHIDGyroRestEnterDps = 2.0f;
static const float kHIDGyroRestExitDps = 3.0f;
static const float kHIDGyroImmediateRestExitDps = 8.0f;
static const uint64_t kHIDGyroRestEnterDurationUs = 30000;
static const uint64_t kHIDGyroRestExitDurationUs = 25000;
static const float kHIDGyroFilterDiagnosticDeltaDps = 80.0f;

/**
 * Returns the median of five samples without changing the input array.
 * @param values Non-NULL array containing five floating-point samples.
 * @return Middle value of a sorted local copy.
 */
static inline float HIDMedianOfFive(const float values[5]) {
    float sorted[5];
    memcpy(sorted, values, sizeof(sorted));
    for (NSUInteger i = 1; i < 5; i++) {
        float value = sorted[i];
        NSInteger j = (NSInteger)i - 1;
        while (j >= 0 && sorted[j] > value) {
            sorted[j + 1] = sorted[j];
            j -= 1;
        }
        sorted[j + 1] = value;
    }
    return sorted[2];
}

/**
 * Updates each gyro axis through a five-sample rolling median.
 *
 * The first four samples pass through unchanged. Mutates filter history and replaces the three
 * axis values once the window is full; callers must serialize access to the filter.
 * @param filter Non-NULL mutable filter state, initially zeroed.
 * @param x Non-NULL input/output X sample in degrees/s.
 * @param y Non-NULL input/output Y sample in degrees/s.
 * @param z Non-NULL input/output Z sample in degrees/s.
 */
static inline void HIDApplyPS4GyroMedianFilter(PS4GyroMedianFilter *filter,
                                               float *x, float *y, float *z) {
    NSUInteger index = filter->nextIndex;
    filter->x[index] = *x;
    filter->y[index] = *y;
    filter->z[index] = *z;
    filter->nextIndex = (index + 1) % 5;
    if (filter->count < 5) {
        filter->count += 1;
    }

    // At the measured native rate of roughly 260 Hz, five samples cover about
    // 19 ms. This rejects bursts lasting up to two HID reports while keeping
    // the temporal delay comparable to the former 3-sample/100 Hz filter.
    if (filter->count == 5) {
        *x = HIDMedianOfFive(filter->x);
        *y = HIDMedianOfFive(filter->y);
        *z = HIDMedianOfFive(filter->z);
    }
}


struct KeyMapping {
    unsigned short mac;
    short windows;
};

static struct KeyMapping keys[] = {
    {kVK_ANSI_A, 'A'},
    {kVK_ANSI_B, 'B'},
    {kVK_ANSI_C, 'C'},
    {kVK_ANSI_D, 'D'},
    {kVK_ANSI_E, 'E'},
    {kVK_ANSI_F, 'F'},
    {kVK_ANSI_G, 'G'},
    {kVK_ANSI_H, 'H'},
    {kVK_ANSI_I, 'I'},
    {kVK_ANSI_J, 'J'},
    {kVK_ANSI_K, 'K'},
    {kVK_ANSI_L, 'L'},
    {kVK_ANSI_M, 'M'},
    {kVK_ANSI_N, 'N'},
    {kVK_ANSI_O, 'O'},
    {kVK_ANSI_P, 'P'},
    {kVK_ANSI_Q, 'Q'},
    {kVK_ANSI_R, 'R'},
    {kVK_ANSI_S, 'S'},
    {kVK_ANSI_T, 'T'},
    {kVK_ANSI_U, 'U'},
    {kVK_ANSI_V, 'V'},
    {kVK_ANSI_W, 'W'},
    {kVK_ANSI_X, 'X'},
    {kVK_ANSI_Y, 'Y'},
    {kVK_ANSI_Z, 'Z'},

    {kVK_ANSI_0, '0'},
    {kVK_ANSI_1, '1'},
    {kVK_ANSI_2, '2'},
    {kVK_ANSI_3, '3'},
    {kVK_ANSI_4, '4'},
    {kVK_ANSI_5, '5'},
    {kVK_ANSI_6, '6'},
    {kVK_ANSI_7, '7'},
    {kVK_ANSI_8, '8'},
    {kVK_ANSI_9, '9'},
    
    {kVK_ANSI_Equal, 0xBB},
    {kVK_ANSI_Minus, 0xBD},
    {kVK_ANSI_RightBracket, 0xDD},
    {kVK_ANSI_LeftBracket, 0xDB},
    {kVK_ANSI_Quote, 0xDE},
    {kVK_ANSI_Semicolon, 0xBA},
    {kVK_ANSI_Backslash, 0xDC},
    {kVK_ANSI_Comma, 0xBC},
    {kVK_ANSI_Slash, 0xBF},
    {kVK_ANSI_Period, 0xBE},
    {kVK_ANSI_Grave, 0xC0},
    {kVK_ANSI_KeypadDecimal, 0x6E},
    {kVK_ANSI_KeypadMultiply, 0x6A},
    {kVK_ANSI_KeypadPlus, 0x6B},
    {kVK_ANSI_KeypadClear, 0xFE},
    {kVK_ANSI_KeypadDivide, 0x6F},
    {kVK_ANSI_KeypadEnter, 0x0D},
    {kVK_ANSI_KeypadMinus, 0x6D},
    {kVK_ANSI_KeypadEquals, 0xBB},
    {kVK_ANSI_Keypad0, 0x60},
    {kVK_ANSI_Keypad1, 0x61},
    {kVK_ANSI_Keypad2, 0x62},
    {kVK_ANSI_Keypad3, 0x63},
    {kVK_ANSI_Keypad4, 0x64},
    {kVK_ANSI_Keypad5, 0x65},
    {kVK_ANSI_Keypad6, 0x66},
    {kVK_ANSI_Keypad7, 0x67},
    {kVK_ANSI_Keypad8, 0x68},
    {kVK_ANSI_Keypad9, 0x69},
    
    {kVK_Delete, 0x08},
    {kVK_Tab, 0x09},
    {kVK_Return, 0x0D},
    {kVK_Shift, 0xA0},
    {kVK_Control, 0xA2},
    {kVK_Option, 0xA4},
    {kVK_CapsLock, 0x14},
    {kVK_Escape, 0x1B},
    {kVK_Space, 0x20},
    {kVK_PageUp, 0x21},
    {kVK_PageDown, 0x22},
    {kVK_End, 0x23},
    {kVK_Home, 0x24},
    {kVK_LeftArrow, 0x25},
    {kVK_UpArrow, 0x26},
    {kVK_RightArrow, 0x27},
    {kVK_DownArrow, 0x28},
    {kVK_ForwardDelete, 0x2E},
    {kVK_Help, 0x2F},
    {kVK_Command, 0x5B},
    {kVK_RightCommand, 0x5C},
    {kVK_RightShift, 0xA1},
    {kVK_RightOption, 0xA5},
    {kVK_RightControl, 0xA3},
    {kVK_Mute, 0xAD},
    {kVK_VolumeDown, 0xAE},
    {kVK_VolumeUp, 0xAF},

    {kVK_F1, 0x70},
    {kVK_F2, 0x71},
    {kVK_F3, 0x72},
    {kVK_F4, 0x73},
    {kVK_F5, 0x74},
    {kVK_F6, 0x75},
    {kVK_F7, 0x76},
    {kVK_F8, 0x77},
    {kVK_F9, 0x78},
    {kVK_F10, 0x79},
    {kVK_F11, 0x7A},
    {kVK_F12, 0x7B},
    {kVK_F13, 0x7C},
    {kVK_F14, 0x7D},
    {kVK_F15, 0x7E},
    {kVK_F16, 0x7F},
    {kVK_F17, 0x80},
    {kVK_F18, 0x81},
    {kVK_F19, 0x82},
    {kVK_F20, 0x83},
};

typedef NS_OPTIONS(NSUInteger, HIDKeyboardPhysicalModifierMask) {
    HIDKeyboardPhysicalModifierMaskLeftShift = 1 << 0,
    HIDKeyboardPhysicalModifierMaskRightShift = 1 << 1,
    HIDKeyboardPhysicalModifierMaskLeftControl = 1 << 2,
    HIDKeyboardPhysicalModifierMaskRightControl = 1 << 3,
    HIDKeyboardPhysicalModifierMaskLeftOption = 1 << 4,
    HIDKeyboardPhysicalModifierMaskRightOption = 1 << 5,
    HIDKeyboardPhysicalModifierMaskLeftCommand = 1 << 6,
    HIDKeyboardPhysicalModifierMaskRightCommand = 1 << 7,
};

typedef NS_OPTIONS(NSUInteger, HIDKeyboardRemoteModifierMask) {
    HIDKeyboardRemoteModifierMaskLeftShift = 1 << 0,
    HIDKeyboardRemoteModifierMaskRightShift = 1 << 1,
    HIDKeyboardRemoteModifierMaskLeftControl = 1 << 2,
    HIDKeyboardRemoteModifierMaskRightControl = 1 << 3,
    HIDKeyboardRemoteModifierMaskLeftAlt = 1 << 4,
    HIDKeyboardRemoteModifierMaskRightAlt = 1 << 5,
    HIDKeyboardRemoteModifierMaskLeftMeta = 1 << 6,
    HIDKeyboardRemoteModifierMaskRightMeta = 1 << 7,
};

static HIDKeyboardPhysicalModifierMask HIDPhysicalModifierMaskForKeyCode(unsigned short keyCode) {
    switch (keyCode) {
        case kVK_Shift:
            return HIDKeyboardPhysicalModifierMaskLeftShift;
        case kVK_RightShift:
            return HIDKeyboardPhysicalModifierMaskRightShift;
        case kVK_Control:
            return HIDKeyboardPhysicalModifierMaskLeftControl;
        case kVK_RightControl:
            return HIDKeyboardPhysicalModifierMaskRightControl;
        case kVK_Option:
            return HIDKeyboardPhysicalModifierMaskLeftOption;
        case kVK_RightOption:
            return HIDKeyboardPhysicalModifierMaskRightOption;
        case kVK_Command:
            return HIDKeyboardPhysicalModifierMaskLeftCommand;
        case kVK_RightCommand:
            return HIDKeyboardPhysicalModifierMaskRightCommand;
        default:
            return 0;
    }
}

static NSEventModifierFlags HIDModifierFlagForKeyCode(unsigned short keyCode) {
    switch (keyCode) {
        case kVK_Shift:
        case kVK_RightShift:
            return NSEventModifierFlagShift;
        case kVK_Control:
        case kVK_RightControl:
            return NSEventModifierFlagControl;
        case kVK_Option:
        case kVK_RightOption:
            return NSEventModifierFlagOption;
        case kVK_Command:
        case kVK_RightCommand:
            return NSEventModifierFlagCommand;
        default:
            return 0;
    }
}

static NSEventModifierFlags HIDDeviceModifierMaskForKeyCode(unsigned short keyCode) {
    switch (keyCode) {
        case kVK_Shift:        return NX_DEVICELSHIFTKEYMASK;
        case kVK_RightShift:   return NX_DEVICERSHIFTKEYMASK;
        case kVK_Control:      return NX_DEVICELCTLKEYMASK;
        case kVK_RightControl: return NX_DEVICERCTLKEYMASK;
        case kVK_Option:       return NX_DEVICELALTKEYMASK;
        case kVK_RightOption:  return NX_DEVICERALTKEYMASK;
        case kVK_Command:      return NX_DEVICELCMDKEYMASK;
        case kVK_RightCommand: return NX_DEVICERCMDKEYMASK;
        default:               return 0;
    }
}

static BOOL HIDEventCarriesDeviceModifierState(NSEventModifierFlags flags) {
    static const NSEventModifierFlags deviceModifiers =
        NX_DEVICELCTLKEYMASK | NX_DEVICERCTLKEYMASK |
        NX_DEVICELSHIFTKEYMASK | NX_DEVICERSHIFTKEYMASK |
        NX_DEVICELALTKEYMASK | NX_DEVICERALTKEYMASK |
        NX_DEVICELCMDKEYMASK | NX_DEVICERCMDKEYMASK;
    return (flags & deviceModifiers) != 0;
}

static HIDKeyboardPhysicalModifierMask HIDEffectivePhysicalModifierMaskForEvent(HIDKeyboardPhysicalModifierMask physicalMask,
                                                                                NSEvent *event) {
    if (event == nil) {
        return physicalMask;
    }

    NSEventModifierFlags modifierFlags = event.modifierFlags;

    if ((modifierFlags & NSEventModifierFlagShift) != 0 &&
        (physicalMask & (HIDKeyboardPhysicalModifierMaskLeftShift | HIDKeyboardPhysicalModifierMaskRightShift)) == 0) {
        physicalMask |= HIDKeyboardPhysicalModifierMaskLeftShift;
    }
    if ((modifierFlags & NSEventModifierFlagControl) != 0 &&
        (physicalMask & (HIDKeyboardPhysicalModifierMaskLeftControl | HIDKeyboardPhysicalModifierMaskRightControl)) == 0) {
        physicalMask |= HIDKeyboardPhysicalModifierMaskLeftControl;
    }
    if ((modifierFlags & NSEventModifierFlagOption) != 0 &&
        (physicalMask & (HIDKeyboardPhysicalModifierMaskLeftOption | HIDKeyboardPhysicalModifierMaskRightOption)) == 0) {
        physicalMask |= HIDKeyboardPhysicalModifierMaskLeftOption;
    }
    if ((modifierFlags & NSEventModifierFlagCommand) != 0 &&
        (physicalMask & (HIDKeyboardPhysicalModifierMaskLeftCommand | HIDKeyboardPhysicalModifierMaskRightCommand)) == 0) {
        physicalMask |= HIDKeyboardPhysicalModifierMaskLeftCommand;
    }

    return physicalMask;
}

static unsigned short HIDRemoteModifierKeyCode(HIDKeyboardRemoteModifierMask mask) {
    switch (mask) {
        case HIDKeyboardRemoteModifierMaskLeftShift:
            return 0xA0;
        case HIDKeyboardRemoteModifierMaskRightShift:
            return 0xA1;
        case HIDKeyboardRemoteModifierMaskLeftControl:
            return 0xA2;
        case HIDKeyboardRemoteModifierMaskRightControl:
            return 0xA3;
        case HIDKeyboardRemoteModifierMaskLeftAlt:
            return 0xA4;
        case HIDKeyboardRemoteModifierMaskRightAlt:
            return 0xA5;
        case HIDKeyboardRemoteModifierMaskLeftMeta:
            return 0x5B;
        case HIDKeyboardRemoteModifierMaskRightMeta:
            return 0x5C;
        default:
            return 0;
    }
}

static BOOL HIDIsModifierKeyCode(unsigned short keyCode) {
    return HIDPhysicalModifierMaskForKeyCode(keyCode) != 0;
}

static char HIDRemoteModifierFlagsToGenericFlags(NSUInteger remoteMask) {
    char modifiers = 0;

    if (remoteMask & (HIDKeyboardRemoteModifierMaskLeftShift | HIDKeyboardRemoteModifierMaskRightShift)) {
        modifiers |= MODIFIER_SHIFT;
    }
    if (remoteMask & (HIDKeyboardRemoteModifierMaskLeftControl | HIDKeyboardRemoteModifierMaskRightControl)) {
        modifiers |= MODIFIER_CTRL;
    }
    if (remoteMask & (HIDKeyboardRemoteModifierMaskLeftAlt | HIDKeyboardRemoteModifierMaskRightAlt)) {
        modifiers |= MODIFIER_ALT;
    }
    if (remoteMask & (HIDKeyboardRemoteModifierMaskLeftMeta | HIDKeyboardRemoteModifierMaskRightMeta)) {
        modifiers |= MODIFIER_META;
    }

    return modifiers;
}

static NSUInteger HIDSyntheticRemoteModifierMaskForKeyCode(HIDSupport *support,
                                                           unsigned short keyCode,
                                                           BOOL preferShortcutTranslationCommandMapping) {
    BOOL swapLeftControlAndWin = [support usesKeyboardLeftControlWinSwapCompatibility];
    BOOL hardMapCommandToControl = [support usesKeyboardCommandToControlCompatibility];
    BOOL shortcutTranslationCommandToControl =
        preferShortcutTranslationCommandMapping && [support usesKeyboardShortcutTranslationCompatibility];

    switch (keyCode) {
        case kVK_Shift:
            return HIDKeyboardRemoteModifierMaskLeftShift;
        case kVK_RightShift:
            return HIDKeyboardRemoteModifierMaskRightShift;
        case kVK_Control:
            return swapLeftControlAndWin ? HIDKeyboardRemoteModifierMaskLeftMeta : HIDKeyboardRemoteModifierMaskLeftControl;
        case kVK_RightControl:
            return HIDKeyboardRemoteModifierMaskRightControl;
        case kVK_Option:
            return HIDKeyboardRemoteModifierMaskLeftAlt;
        case kVK_RightOption:
            return HIDKeyboardRemoteModifierMaskRightAlt;
        case kVK_Command:
            return (hardMapCommandToControl || swapLeftControlAndWin || shortcutTranslationCommandToControl)
                ? HIDKeyboardRemoteModifierMaskLeftControl
                : HIDKeyboardRemoteModifierMaskLeftMeta;
        case kVK_RightCommand:
            return (hardMapCommandToControl || shortcutTranslationCommandToControl)
                ? HIDKeyboardRemoteModifierMaskRightControl
                : HIDKeyboardRemoteModifierMaskRightMeta;
        default:
            return 0;
    }
}

static void HIDDispatchSyntheticRemoteModifierTap(HIDSupport *support,
                                                  NSUInteger remoteModifierMask,
                                                  const char *op) {
    if (remoteModifierMask == 0) {
        return;
    }

    PML_INPUT_STREAM_CONTEXT inputCtx = HIDInputContext(support);
    if (!HIDValidateInputContext(inputCtx, op)) {
        return;
    }

    static const HIDKeyboardRemoteModifierMask remoteOrder[] = {
        HIDKeyboardRemoteModifierMaskLeftShift,
        HIDKeyboardRemoteModifierMaskRightShift,
        HIDKeyboardRemoteModifierMaskLeftControl,
        HIDKeyboardRemoteModifierMaskRightControl,
        HIDKeyboardRemoteModifierMaskLeftAlt,
        HIDKeyboardRemoteModifierMaskRightAlt,
        HIDKeyboardRemoteModifierMaskLeftMeta,
        HIDKeyboardRemoteModifierMaskRightMeta,
    };

    char translatedModifiers = HIDRemoteModifierFlagsToGenericFlags(remoteModifierMask);
    HIDDispatchInput(support, inputCtx, ^{
        for (NSUInteger i = 0; i < sizeof(remoteOrder) / sizeof(remoteOrder[0]); i++) {
            HIDKeyboardRemoteModifierMask mask = remoteOrder[i];
            if ((remoteModifierMask & mask) == 0) {
                continue;
            }

            unsigned short modifierKeyCode = HIDRemoteModifierKeyCode(mask);
            if (modifierKeyCode != 0) {
                LiSendKeyboardEventCtx(inputCtx, modifierKeyCode, KEY_ACTION_DOWN, translatedModifiers);
                LiSendKeyboardEventCtx(inputCtx, modifierKeyCode, KEY_ACTION_UP, 0);
            }
        }
    });
}

@implementation HIDInputDiagnosticsSnapshot
@end

@implementation HIDSupport

@synthesize shouldSendControllerEvents = _shouldSendControllerEvents;

/**
 * Reads the controller-delivery gate under the HID object's monitor.
 * @return Whether controller events may be sent independently of keyboard/mouse capture.
 */
- (BOOL)shouldSendControllerEvents {
    @synchronized (self) {
        return _shouldSendControllerEvents;
    }
}

/**
 * Changes the HID controller-delivery gate and resets motion filters and touchpad gestures.
 *
 * Pausing synchronously drains the input queue and sends neutral gamepad, touch, gyro and mouse
 * releases when a direct-HID context is initialized. Resuming advertises PlayStation capabilities before
 * resending physical state. Host motion rates survive this transition. Call on main for menu
 * timers, never from inputQueue because disabling performs dispatch_sync onto that queue.
 * @param enabled Whether controller input may be delivered to the current stream.
 */
- (void)setShouldSendControllerEvents:(BOOL)enabled {
    @synchronized (self) {
        if (_shouldSendControllerEvents == enabled) return;
        _shouldSendControllerEvents = enabled;
        self.ps4GyroMedianFilter = (PS4GyroMedianFilter){};
        self.ps4GyroRateWindowStartUs = 0;
        self.ps4GyroRateWindowSamples = 0;
        self.hasLastPS4GyroSample = NO;
        self.ps4GyroAtRest = YES;
        self.ps4GyroStationarySinceUs = 0;
        self.ps4GyroMovingSinceUs = 0;
        if (!enabled) {
            ControllerMenuGesture gesture = self.controller.menuGesture;
            ControllerMenuGestureInterrupt(&gesture, self.gamepadMenuPressed);
            self.controller.menuGesture = gesture;
            [self.gamepadMenuTimer invalidate];
            self.gamepadMenuTimer = nil;

            int heldMouseButtons = self.controller.lastMouseModeButtonFlags;
            int trackpadButton = self.controller.trackpadMouseButton;
            PML_INPUT_STREAM_CONTEXT input = HIDInputContext(self);
            if (self.controllerDriver == 0 && input && LiInputContextIsInitialized(input)) {
                int player = self.controller.playerIndex;
                BOOL stopGyro = self.reportedPlayStationArrival && self.requestedGyroRateHz > 0;
                BOOL primaryTouchActive = self.ps4PrimaryTouchActive;
                BOOL secondaryTouchActive = self.ps4SecondaryTouchActive;
                float primaryX = self.ps4PrimaryTouchX, primaryY = self.ps4PrimaryTouchY;
                float secondaryX = self.ps4SecondaryTouchX, secondaryY = self.ps4SecondaryTouchY;
                // Finish queued input and release state before teardown can clear the context.
                dispatch_sync(self.inputQueue, ^{
                    LiSetThreadConnectionContext(input->connectionContext);
                    LiSendMultiControllerEventCtx(input, player, 1, 0, 0, 0, 0, 0, 0, 0);
                    if (primaryTouchActive)
                        LiSendControllerTouchEventCtx(input, player, LI_TOUCH_EVENT_UP, 0, primaryX, primaryY, 0.0f);
                    if (secondaryTouchActive)
                        LiSendControllerTouchEventCtx(input, player, LI_TOUCH_EVENT_UP, 1, secondaryX, secondaryY, 0.0f);
                    if (stopGyro) {
                        LiSendControllerMotionEventCtx(input, player, LI_MOTION_TYPE_GYRO, 0.0f, 0.0f, 0.0f);
                    }
                    if (trackpadButton && !(heldMouseButtons & (trackpadButton == BUTTON_LEFT ? A_FLAG : B_FLAG)))
                        LiSendMouseButtonEventCtx(input, BUTTON_ACTION_RELEASE, trackpadButton);
                    if (heldMouseButtons & A_FLAG)
                        LiSendMouseButtonEventCtx(input, BUTTON_ACTION_RELEASE, BUTTON_LEFT);
                    if (heldMouseButtons & B_FLAG)
                        LiSendMouseButtonEventCtx(input, BUTTON_ACTION_RELEASE, BUTTON_RIGHT);
                });
            }
            self.controller.lastMouseModeButtonFlags = 0;
            self.ps4PrimaryTouchActive = NO;
            self.ps4SecondaryTouchActive = NO;
            [self resetTrackpadState];
        } else if (self.controllerDriver == 0) {
            // Physical gamepad state continues to update while delivery is paused.
            // A replacement PlayStation session must advertise its extensions first.
            IOHIDDeviceRef device = [self getFirstDevice];
            if (device != NULL && isPlayStation(device) && ![self reportPlayStationControllerArrival]) {
                return;
            }
            [self sendControllerEvent];
        }
    }
}

/**
 * Replaces the borrowed stream context and resets session-specific PlayStation input state.
 *
 * A changed pointer clears arrival, requested motion rates, filter history, mode overrides and gestures,
 * then synchronizes scroll diagnostics. The HID monitor serializes this reset with motion
 * processing and requests, including context invalidation on the connection callback thread.
 * @param inputContext Native input context, or NULL to detach; the pointer is not retained or freed.
 */
- (void)setInputContext:(void *)inputContext {
    @synchronized (self) {
        if (_inputContext == inputContext) {
            return;
        }

        _inputContext = inputContext;
        self.reportedPlayStationArrival = NO;
        self.requestedGyroRateHz = 0;
        self.requestedAccelRateHz = 0;
        self.lastGyroReportUs = 0;
        self.lastAccelReportUs = 0;
        self.ps4GyroMedianFilter = (PS4GyroMedianFilter){};
        self.ps4GyroRateWindowStartUs = 0;
        self.ps4GyroRateWindowSamples = 0;
        self.hasLastPS4GyroSample = NO;
        self.ps4GyroAtRest = YES;
        self.ps4GyroStationarySinceUs = 0;
        self.ps4GyroMovingSinceUs = 0;
        self.remainingPS4MotionDiagnosticSamples = 0;
        self.remainingPS4GyroFilterDiagnosticLogs = 0;
        self.remainingPS4GyroRestDiagnosticLogs = 0;
        self.ps4PrimaryTouchActive = NO;
        self.ps4SecondaryTouchActive = NO;
        [self resetTrackpadState];
        self.controller.hasTouchpadModeOverride = NO;
        [self syncScrollTraceDiagnosticsPreferenceToInputContext];
    }
}

- (void)refreshInputDiagnosticsPreference {
    self.inputDiagnosticsEnabled = [SettingsClass inputDiagnosticsEnabled];
    [self syncScrollTraceDiagnosticsPreferenceToInputContext];
}

- (void)resetInputDiagnostics {
    [self refreshInputDiagnosticsPreference];

    @synchronized (self.inputDiagnosticsLock) {
        self.inputDiagnosticsDetailedLogSequence = 0;
        self.inputDiagnosticsRemainingDetailedLogs = self.inputDiagnosticsEnabled ? 24 : 0;
        self.inputDiagnosticsRemainingScrollDetailedLogs = self.inputDiagnosticsEnabled ? 256 : 0;
        self.scrollTraceSequence = 0;
        self.activeScrollTraceId = 0;
        self.activeScrollTraceStartedMs = 0;
        self.activeScrollTraceLastEventMs = 0;
        self.activeScrollTraceLockedToPrecise = NO;
        self.activeScrollTraceSource = nil;
        self.inputDiagnosticsMouseMoveEvents = 0;
        self.inputDiagnosticsNonZeroRelativeEvents = 0;
        self.inputDiagnosticsRelativeDispatches = 0;
        self.inputDiagnosticsAbsoluteDispatches = 0;
        self.inputDiagnosticsAbsoluteDuplicateSkips = 0;
        self.inputDiagnosticsCoreHIDRawEvents = 0;
        self.inputDiagnosticsCoreHIDDispatches = 0;
        self.inputDiagnosticsSuppressedRelativeEvents = 0;
        self.inputDiagnosticsRawRelativeDeltaX = 0;
        self.inputDiagnosticsRawRelativeDeltaY = 0;
        self.inputDiagnosticsSentRelativeDeltaX = 0;
        self.inputDiagnosticsSentRelativeDeltaY = 0;
    }
}

- (HIDInputDiagnosticsSnapshot *)consumeInputDiagnosticsSnapshot {
    HIDInputDiagnosticsSnapshot *snapshot = [[HIDInputDiagnosticsSnapshot alloc] init];

    @synchronized (self.inputDiagnosticsLock) {
        snapshot.mouseMoveEvents = self.inputDiagnosticsMouseMoveEvents;
        snapshot.nonZeroRelativeEvents = self.inputDiagnosticsNonZeroRelativeEvents;
        snapshot.relativeDispatches = self.inputDiagnosticsRelativeDispatches;
        snapshot.absoluteDispatches = self.inputDiagnosticsAbsoluteDispatches;
        snapshot.absoluteDuplicateSkips = self.inputDiagnosticsAbsoluteDuplicateSkips;
        snapshot.coreHIDRawEvents = self.inputDiagnosticsCoreHIDRawEvents;
        snapshot.coreHIDDispatches = self.inputDiagnosticsCoreHIDDispatches;
        snapshot.suppressedRelativeEvents = self.inputDiagnosticsSuppressedRelativeEvents;
        snapshot.rawRelativeDeltaX = self.inputDiagnosticsRawRelativeDeltaX;
        snapshot.rawRelativeDeltaY = self.inputDiagnosticsRawRelativeDeltaY;
        snapshot.sentRelativeDeltaX = self.inputDiagnosticsSentRelativeDeltaX;
        snapshot.sentRelativeDeltaY = self.inputDiagnosticsSentRelativeDeltaY;

        self.inputDiagnosticsMouseMoveEvents = 0;
        self.inputDiagnosticsNonZeroRelativeEvents = 0;
        self.inputDiagnosticsRelativeDispatches = 0;
        self.inputDiagnosticsAbsoluteDispatches = 0;
        self.inputDiagnosticsAbsoluteDuplicateSkips = 0;
        self.inputDiagnosticsCoreHIDRawEvents = 0;
        self.inputDiagnosticsCoreHIDDispatches = 0;
        self.inputDiagnosticsSuppressedRelativeEvents = 0;
        self.inputDiagnosticsRawRelativeDeltaX = 0;
        self.inputDiagnosticsRawRelativeDeltaY = 0;
        self.inputDiagnosticsSentRelativeDeltaX = 0;
        self.inputDiagnosticsSentRelativeDeltaY = 0;
    }

    return snapshot;
}

- (BOOL)reserveDetailedInputDiagnosticsLogSequence:(NSUInteger *)sequence {
    BOOL shouldLog = NO;

    @synchronized (self.inputDiagnosticsLock) {
        if (!self.inputDiagnosticsEnabled || self.inputDiagnosticsRemainingDetailedLogs == 0) {
            return NO;
        }

        self.inputDiagnosticsDetailedLogSequence += 1;
        self.inputDiagnosticsRemainingDetailedLogs -= 1;
        shouldLog = YES;
        if (sequence != NULL) {
            *sequence = self.inputDiagnosticsDetailedLogSequence;
        }
    }

    return shouldLog;
}

- (void)syncScrollTraceDiagnosticsPreferenceToInputContext {
    PML_INPUT_STREAM_CONTEXT inputCtx = HIDInputContext(self);
    LiSetScrollTraceDiagnosticsEnabledCtx(inputCtx, self.inputDiagnosticsEnabled ? true : false);
}

- (uint64_t)prepareScrollTraceFromSource:(NSString *)source
                               rawDeltaX:(CGFloat)rawDeltaX
                               rawDeltaY:(CGFloat)rawDeltaY
                                   phase:(NSEventPhase)phase
                           momentumPhase:(NSEventPhase)momentumPhase
                        hasPreciseDeltas:(BOOL)hasPreciseDeltas {
    [self syncScrollTraceDiagnosticsPreferenceToInputContext];
    if (!self.inputDiagnosticsEnabled) {
        return 0;
    }

    uint64_t nowMs = LiGetMillis();
    __block BOOL startsNewTrace = NO;
    __block uint64_t traceId = 0;

    @synchronized (self.inputDiagnosticsLock) {
        BOOL idleExpired = self.activeScrollTraceLastEventMs == 0 ||
                           nowMs < self.activeScrollTraceLastEventMs ||
                           nowMs - self.activeScrollTraceLastEventMs > 180;
        BOOL explicitBegin = phase == NSEventPhaseBegan || momentumPhase == NSEventPhaseBegan;
        BOOL sourceChanged = (self.activeScrollTraceSource == nil && source != nil) ||
                             (self.activeScrollTraceSource != nil && source == nil) ||
                             (self.activeScrollTraceSource != nil && source != nil &&
                              ![self.activeScrollTraceSource isEqualToString:source]);
        if (self.activeScrollTraceId == 0 || explicitBegin || idleExpired || sourceChanged) {
            self.scrollTraceSequence += 1;
            if (self.scrollTraceSequence == 0) {
                self.scrollTraceSequence = 1;
            }
            self.activeScrollTraceId = self.scrollTraceSequence;
            self.activeScrollTraceStartedMs = nowMs;
            self.activeScrollTraceLockedToPrecise = NO;
            self.activeScrollTraceSource = [source copy];
            startsNewTrace = YES;
        } else if (source != nil) {
            self.activeScrollTraceSource = [source copy];
        }

        self.activeScrollTraceLastEventMs = nowMs;
        traceId = self.activeScrollTraceId;
    }

    if (startsNewTrace) {
        PML_INPUT_STREAM_CONTEXT inputCtx = HIDInputContext(self);
        LiStartScrollTraceCtx(inputCtx, traceId, nowMs);
        Log(LOG_D, @"[inputdiag] scroll-trace start trace=%llu source=%@ raw=(%.3f,%.3f) phase=%lu momentum=%lu precise=%d",
            (unsigned long long)traceId,
            source ?: @"unknown",
            rawDeltaX,
            rawDeltaY,
            (unsigned long)phase,
            (unsigned long)momentumPhase,
            hasPreciseDeltas ? 1 : 0);
    }

    return traceId;
}

- (void)recordRelativeInputDiagnosticsFrom:(NSString *)source
                                 rawDeltaX:(CGFloat)rawDeltaX
                                 rawDeltaY:(CGFloat)rawDeltaY
                                sentDeltaX:(short)sentDeltaX
                                sentDeltaY:(short)sentDeltaY
                                suppressed:(BOOL)suppressed {
    if (!self.inputDiagnosticsEnabled) {
        return;
    }

    BOOL rawNonZero = (rawDeltaX != 0.0 || rawDeltaY != 0.0);
    NSUInteger sequence = 0;

    @synchronized (self.inputDiagnosticsLock) {
        self.inputDiagnosticsMouseMoveEvents += 1;
        if (rawNonZero) {
            self.inputDiagnosticsNonZeroRelativeEvents += 1;
            self.inputDiagnosticsRawRelativeDeltaX += (NSInteger)llround(rawDeltaX);
            self.inputDiagnosticsRawRelativeDeltaY += (NSInteger)llround(rawDeltaY);
        }
        if (suppressed) {
            self.inputDiagnosticsSuppressedRelativeEvents += 1;
        } else if (sentDeltaX != 0 || sentDeltaY != 0) {
            self.inputDiagnosticsRelativeDispatches += 1;
            self.inputDiagnosticsSentRelativeDeltaX += sentDeltaX;
            self.inputDiagnosticsSentRelativeDeltaY += sentDeltaY;
        }
    }

    if ([self reserveDetailedInputDiagnosticsLogSequence:&sequence]) {
        Log(LOG_D, @"[inputdiag] #%lu %@ relative raw=(%.3f,%.3f) sent=(%d,%d) suppressed=%d ctx=%p",
            (unsigned long)sequence,
            source ?: @"unknown",
            rawDeltaX,
            rawDeltaY,
            sentDeltaX,
            sentDeltaY,
            suppressed ? 1 : 0,
            self.inputContext);
    }
}

- (void)recordAbsoluteInputDiagnosticsFrom:(NSString *)source
                                         x:(short)x
                                         y:(short)y
                                     width:(short)width
                                    height:(short)height {
    NSUInteger sequence = 0;
    BOOL diagnosticsEnabled = self.inputDiagnosticsEnabled;
    @synchronized (self.inputDiagnosticsLock) {
        self.lastAbsolutePointerHostX = x;
        self.lastAbsolutePointerHostY = y;
        self.lastAbsolutePointerReferenceWidth = width;
        self.lastAbsolutePointerReferenceHeight = height;
        self.lastAbsolutePointerAtMs = LiGetMillis();
        self.lastAbsolutePointerSource = [source copy];
        if (diagnosticsEnabled) {
            self.inputDiagnosticsMouseMoveEvents += 1;
            self.inputDiagnosticsAbsoluteDispatches += 1;
        }
    }

    if (diagnosticsEnabled && [self reserveDetailedInputDiagnosticsLogSequence:&sequence]) {
        Log(LOG_D, @"[inputdiag] #%lu %@ absolute pos=(%d,%d) ref=%dx%d ctx=%p",
            (unsigned long)sequence,
            source ?: @"unknown",
            x,
            y,
            width,
            height,
            self.inputContext);
    }
}

- (BOOL)getLastAbsolutePointerHostX:(short *)hostX
                              hostY:(short *)hostY
                     referenceWidth:(short *)referenceWidth
                    referenceHeight:(short *)referenceHeight
                              ageMs:(uint64_t *)ageMs
                             source:(NSString * __autoreleasing *)source {
    @synchronized (self.inputDiagnosticsLock) {
        if (self.lastAbsolutePointerAtMs == 0) {
            return NO;
        }

        if (hostX != NULL) {
            *hostX = self.lastAbsolutePointerHostX;
        }
        if (hostY != NULL) {
            *hostY = self.lastAbsolutePointerHostY;
        }
        if (referenceWidth != NULL) {
            *referenceWidth = self.lastAbsolutePointerReferenceWidth;
        }
        if (referenceHeight != NULL) {
            *referenceHeight = self.lastAbsolutePointerReferenceHeight;
        }
        if (ageMs != NULL) {
            uint64_t nowMs = LiGetMillis();
            *ageMs = nowMs >= self.lastAbsolutePointerAtMs ? (nowMs - self.lastAbsolutePointerAtMs) : 0;
        }
        if (source != NULL) {
            *source = [self.lastAbsolutePointerSource copy];
        }
        return YES;
    }
}

- (void)recordMouseButtonDiagnosticsAction:(NSString *)action
                                    button:(int)button
                                      mask:(uint32_t)mask
                                 synthetic:(BOOL)synthetic {
    if (!self.inputDiagnosticsEnabled) {
        return;
    }

    NSUInteger sequence = 0;
    if ([self reserveDetailedInputDiagnosticsLogSequence:&sequence]) {
        Log(LOG_D, @"[inputdiag] #%lu mouse-button action=%@ button=%d mask=0x%02X synthetic=%d ctx=%p",
            (unsigned long)sequence,
            action ?: @"unknown",
            button,
            (unsigned int)mask,
            synthetic ? 1 : 0,
            self.inputContext);
    }
}

- (void)recordScrollInputDiagnosticsMode:(NSString *)mode
                                 traceId:(uint64_t)traceId
                               rawDeltaX:(CGFloat)rawDeltaX
                               rawDeltaY:(CGFloat)rawDeltaY
                            rawWheelDeltaX:(NSInteger)rawWheelDeltaX
                            rawWheelDeltaY:(NSInteger)rawWheelDeltaY
                        normalizedDeltaX:(CGFloat)normalizedDeltaX
                        normalizedDeltaY:(CGFloat)normalizedDeltaY
                              continuous:(BOOL)continuous
                        hasPreciseDeltas:(BOOL)hasPreciseDeltas
                             lineDeltaX:(NSInteger)lineDeltaX
                             lineDeltaY:(NSInteger)lineDeltaY
                            pointDeltaX:(NSInteger)pointDeltaX
                            pointDeltaY:(NSInteger)pointDeltaY
                          fixedDeltaXRaw:(NSInteger)fixedDeltaXRaw
                          fixedDeltaYRaw:(NSInteger)fixedDeltaYRaw
                                   phase:(NSEventPhase)phase
                           momentumPhase:(NSEventPhase)momentumPhase
                              dispatchedX:(short)dispatchedX
                              dispatchedY:(short)dispatchedY {
    if (!self.inputDiagnosticsEnabled) {
        return;
    }

    uint64_t nowMs = LiGetMillis();
    PML_INPUT_STREAM_CONTEXT inputCtx = HIDInputContext(self);

    NSUInteger sequence = 0;
    BOOL shouldLog = NO;
    @synchronized (self.inputDiagnosticsLock) {
        if (self.inputDiagnosticsRemainingScrollDetailedLogs > 0) {
            self.inputDiagnosticsDetailedLogSequence += 1;
            self.inputDiagnosticsRemainingScrollDetailedLogs -= 1;
            sequence = self.inputDiagnosticsDetailedLogSequence;
            shouldLog = YES;
        }
    }

    if (shouldLog) {
        uint64_t traceStartMs = LiGetScrollTraceStartMsCtx(inputCtx);
        uint64_t traceAgeMs = traceStartMs != 0 && nowMs >= traceStartMs ? nowMs - traceStartMs : 0;
        Log(LOG_D, @"[inputdiag] #%lu scroll trace=%llu ageMs=%llu mode=%@ raw=(%.3f,%.3f) rawWheel=(%ld,%ld) normalized=(%.3f,%.3f) dispatched=(%d,%d) continuous=%d precise=%d line=(%ld,%ld) point=(%ld,%ld) fixedRaw=(%ld,%ld) phase=%lu momentum=%lu ctx=%p",
            (unsigned long)sequence,
            (unsigned long long)traceId,
            (unsigned long long)traceAgeMs,
            mode ?: @"unknown",
            rawDeltaX,
            rawDeltaY,
            (long)rawWheelDeltaX,
            (long)rawWheelDeltaY,
            normalizedDeltaX,
            normalizedDeltaY,
            dispatchedX,
            dispatchedY,
            continuous ? 1 : 0,
            hasPreciseDeltas ? 1 : 0,
            (long)lineDeltaX,
            (long)lineDeltaY,
            (long)pointDeltaX,
            (long)pointDeltaY,
            (long)fixedDeltaXRaw,
            (long)fixedDeltaYRaw,
            (unsigned long)phase,
            (unsigned long)momentumPhase,
            self.inputContext);
    }
}

/**
 * Creates the HID backend and snapshots effective host/global motion and touchpad preferences.
 * Registers device/preference observers and input queues on main; cleanup must unregister them.
 * Live touchpad preferences resend controller state only when the direct-HID driver is active.
 * @param host Host profile whose input settings apply to this stream.
 * @return Initialized input backend.
 */
- (instancetype)init:(TemporaryHost *)host {
    self = [super init];
    if (self) {
        self.host = host;
        self.controllerMotionMode = [SettingsClass controllerMotionModeFor:host.uuid];
        self.inputQueue = dispatch_queue_create("com.moonlight.input", DISPATCH_QUEUE_SERIAL);
        self.freeMouseVirtualCursorLock = [[NSObject alloc] init];
        self.freeMouseVirtualCursorGainX = 1.0;
        self.freeMouseVirtualCursorGainY = 1.0;
        self.inputDiagnosticsLock = [[NSObject alloc] init];
        self.pressedMouseButtonsMask = 0;
        [self resetInputDiagnostics];
        
        [self setupHidManager];
        
        self.ticks = [[Ticks alloc] init];
        self.switchUsingBluetooth = YES;
        
        self.previousLowFreqMotor = 0xFF;
        self.previousHighFreqMotor = 0xFF;

        [self rumbleSync];

        self.controller = [[Controller alloc] init];
        self.nativeTouchpadEnabled = [SettingsClass nativeTouchpadFor:host.uuid];
        self.trackpadPointerSensitivity = [SettingsClass pointerSensitivityFor:host.uuid];
        self.trackpadScrollSpeed = [SettingsClass gestureScrollSpeedFor:host.uuid];
        self.trackpadReverseScroll = [SettingsClass reverseScrollDirectionFor:host.uuid];
        [self refreshGamepadMouseModeConfiguration];
        __weak HIDSupport *weakSelf = self;
        self.touchpadSettingsObserver = [[NSNotificationCenter defaultCenter]
            addObserverForName:@"ControllerTouchpadModeDidChange" object:nil queue:NSOperationQueue.mainQueue
            usingBlock:^(NSNotification *note) {
                HIDSupport *me = weakSelf;
                NSString *changedHost = note.userInfo[@"hostId"];
                if (!me || (![changedHost isEqualToString:me.host.uuid] && ![changedHost isEqualToString:@"__global__"])) return;
                @synchronized (me) {
                    [me releaseTrackpadState];
                    me.controller.hasTouchpadModeOverride = NO;
                    me.nativeTouchpadEnabled = [SettingsClass nativeTouchpadFor:me.host.uuid];
                    if (me.controllerDriver == 0) [me sendControllerEvent];
                }
            }];
        
        for (GCMouse *mouse in GCMouse.mice) {
            [self registerMouseCallbacks:mouse];
        }
        
        self.mouseConnectObserver = [[NSNotificationCenter defaultCenter] addObserverForName:GCMouseDidConnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification * _Nonnull note) {
            [self registerMouseCallbacks:note.object];
        }];
        self.mouseDisconnectObserver = [[NSNotificationCenter defaultCenter] addObserverForName:GCMouseDidDisconnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification * _Nonnull note) {
            [self unregisterMouseCallbacks:note.object];
        }];
        
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        for (size_t i = 0; i < sizeof(keys) / sizeof(struct KeyMapping); i++) {
            struct KeyMapping m = keys[i];
            [d setObject:@(m.windows) forKey:@(m.mac)];
        }
        _mappings = [NSDictionary dictionaryWithDictionary:d];
        
        [self initializeDisplayLink];
        [self setupCoreHIDMouseDriverIfNeeded];
    }
    return self;
}

- (void)dealloc {
    [self.gamepadMenuTimer invalidate];
    [self tearDownCoreHIDMouseDriver];
    NSLog(@"HIDSupport dealloc");
}


/**
 * Queues the current physical gamepad state when controller delivery is enabled.
 *
 * Skips mouse mode or a missing context and translates Start+Select to the Guide button.
 * Captures state before dispatching to the serial input queue; call from the serialized HID
 * state-update path.
 */
- (void)sendControllerEvent {
    if (self.shouldSendControllerEvents) {
        // Capture state
        int playerIndex = self.controller.playerIndex;
        int lastButtonFlags = self.controller.lastButtonFlags;
        
        // Guide Button Emulation (Start + Select)
        // If both Start and Select are pressed, convert to Guide
        if ((lastButtonFlags & (PLAY_FLAG | BACK_FLAG)) == (PLAY_FLAG | BACK_FLAG)) {
            lastButtonFlags &= ~(PLAY_FLAG | BACK_FLAG);
            lastButtonFlags |= SPECIAL_FLAG;
        }
        
        unsigned char lastLeftTrigger = self.controller.lastLeftTrigger;
        unsigned char lastRightTrigger = self.controller.lastRightTrigger;
        short lastLeftStickX = self.controller.lastLeftStickX;
        short lastLeftStickY = self.controller.lastLeftStickY;
        short lastRightStickX = self.controller.lastRightStickX;
        short lastRightStickY = self.controller.lastRightStickY;
        
        if (self.controller.isMouseMode) {
            return;
        }

        PML_INPUT_STREAM_CONTEXT inputCtx = HIDInputContext(self);
        if (!inputCtx) {
            return;
        }
        HIDDispatchInput(self, inputCtx, ^{
            LiSendMultiControllerEventCtx(inputCtx, playerIndex, 1, lastButtonFlags, lastLeftTrigger, lastRightTrigger, lastLeftStickX, lastLeftStickY, lastRightStickX, lastRightStickY);
        });
    }
}

/**
 * Advertises direct-HID PlayStation buttons and motion/touch capabilities once per session.
 *
 * Requires the direct driver, enabled controller delivery and a valid context. Marks arrival
 * only after a successful protocol call so failures may be retried. Call from the serialized
 * HID controller path before sending extended input. Only DS4 advertises motion; Disabled motion omits sensor capabilities.
 * @return YES if arrival was already advertised or was successfully sent; otherwise NO.
 */
- (BOOL)reportPlayStationControllerArrival {
    if (self.controllerDriver != 0) {
        return NO;
    }
    if (!self.shouldSendControllerEvents) {
        return NO;
    }
    if (self.reportedPlayStationArrival) {
        return YES;
    }

    PML_INPUT_STREAM_CONTEXT inputCtx = HIDInputContext(self);
    if (!inputCtx) {
        return NO;
    }

    uint32_t buttons = PLAY_FLAG | BACK_FLAG | UP_FLAG | DOWN_FLAG | LEFT_FLAG | RIGHT_FLAG |
                       LB_FLAG | RB_FLAG | LS_CLK_FLAG | RS_CLK_FLAG | SPECIAL_FLAG |
                       A_FLAG | B_FLAG | X_FLAG | Y_FLAG | TOUCHPAD_FLAG;
    uint16_t capabilities = LI_CCAP_ANALOG_TRIGGERS | LI_CCAP_RUMBLE | LI_CCAP_TOUCHPAD;
    if (self.playStationHasMotion && self.controllerMotionMode != 2) {
        capabilities |= LI_CCAP_ACCEL | LI_CCAP_GYRO;
    }
    int err = LiSendControllerArrivalEventCtx(inputCtx, 0, 1, LI_CTYPE_PS, buttons, capabilities);
    if (err != 0) {
        return NO;
    }

    self.reportedPlayStationArrival = YES;
    Log(LOG_I, @"HID PlayStation controller arrival: buttons=0x%x capabilities=0x%x", buttons, capabilities);
    return YES;
}

/**
 * Queues a host motion request on main and rejects requests for a replaced stream context.
 *
 * Only slot zero is supported. Under the HID monitor, updates sensor rates even while delivery
 * is paused and resets gyro filters when its rate changes. Stopping an active gyro sends a
 * zero only when controller arrival and delivery permit it. Disabled motion ignores requests.
 * May be called from a native callback.
 * @param controllerNumber Host controller slot; nonzero slots are ignored.
 * @param motionType LI_MOTION_TYPE_GYRO or LI_MOTION_TYPE_ACCEL.
 * @param reportRateHz Requested maximum outgoing frequency in Hz, or zero to stop that sensor.
 */
- (void)setMotionEventState:(uint16_t)controllerNumber
                 motionType:(uint8_t)motionType
               reportRateHz:(uint16_t)reportRateHz {
    void *requestedInputContext;
    @synchronized (self) {
        requestedInputContext = _inputContext;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        // Context replacement also resets motion state. Reject queued old requests.
        @synchronized (self) {
            if (self.controllerMotionMode == 2 || controllerNumber != 0 || requestedInputContext == NULL ||
                self.inputContext != requestedInputContext) {
                return;
            }

            if (motionType == LI_MOTION_TYPE_GYRO) {
                BOOL wasReporting = self.requestedGyroRateHz > 0;
                self.requestedGyroRateHz = reportRateHz;
                self.lastGyroReportUs = 0;
                self.ps4GyroMedianFilter = (PS4GyroMedianFilter){};
                self.ps4GyroRateWindowStartUs = 0;
                self.ps4GyroRateWindowSamples = 0;
                self.hasLastPS4GyroSample = NO;
                self.ps4GyroAtRest = YES;
                self.ps4GyroStationarySinceUs = 0;
                self.ps4GyroMovingSinceUs = 0;
                self.remainingPS4MotionDiagnosticSamples = reportRateHz > 0 ? 3 : 0;
                self.remainingPS4GyroFilterDiagnosticLogs = reportRateHz > 0 ? 8 : 0;
                self.remainingPS4GyroRestDiagnosticLogs = reportRateHz > 0 ? 12 : 0;
                if (wasReporting && reportRateHz == 0) {
                    PML_INPUT_STREAM_CONTEXT inputCtx = HIDInputContext(self);
                    if (inputCtx && [self reportPlayStationControllerArrival]) {
                        LiSendControllerMotionEventCtx(inputCtx, 0, LI_MOTION_TYPE_GYRO,
                                                       0.0f, 0.0f, 0.0f);
                    }
                }
            } else if (motionType == LI_MOTION_TYPE_ACCEL) {
                self.requestedAccelRateHz = reportRateHz;
                self.lastAccelReportUs = 0;
            }

            Log(LOG_I, @"HID controller motion request: type=%u rate=%u Hz", motionType, reportRateHz);
        }
    });
}

/**
 * Decodes a signed little-endian 16-bit DS4 sensor or calibration value.
 * @param bytes Non-NULL buffer containing at least two bytes.
 * @return Signed value represented by the two bytes.
 */
static inline int16_t PS4ReadS16(const UInt8 bytes[2]) {
    return (int16_t)((uint16_t)bytes[0] | ((uint16_t)bytes[1] << 8));
}

/**
 * Maps an unsigned DS4 stick sample to the protocol's signed 16-bit axis range.
 *
 * Applies a three-count center deadzone and rescales the remaining travel before optional
 * inversion and saturation. Does not alter trigger values.
 * @param value Raw stick sample in the range 0 through 255.
 * @param inverted Whether to negate the mapped axis.
 * @return Normalized and saturated stick value.
 */
static inline short PS4NormalizeStickAxis(UInt8 value, BOOL inverted) {
    // DualShock 4 sticks commonly fluctuate by one or two raw counts while
    // untouched. Comparing the raw bytes causes a reliable controller packet
    // for every fluctuation, which can delay trigger updates on a poor link.
    // Keep this deadzone local to the sticks: trigger values remain untouched.
    static const int center = 128;
    static const int deadzone = 3;
    int delta = (int)value - center;
    int output;

    if (abs(delta) <= deadzone) {
        output = 0;
    } else if (delta > 0) {
        output = (delta - deadzone) * INT16_MAX / (127 - deadzone);
    } else {
        output = (delta + deadzone) * -INT16_MIN / (128 - deadzone);
    }

    if (inverted) {
        output = -output;
    }
    return (short)MAX(MIN(output, INT16_MAX), INT16_MIN);
}

/**
 * Loads and validates factory gyro and accelerometer calibration for a DS4 device.
 *
 * Reads the transport-specific USB/Bluetooth feature report synchronously; truncated, empty or
 * implausible calibration clears validity so motion processing uses nominal scaling. Non-DS4
 * devices are ignored. Call during device matching on the HID manager's main run loop.
 * @param device Connected HID device from which calibration is read.
 */
- (void)loadPS4MotionCalibrationForDevice:(IOHIDDeviceRef)device {
    if (!isPS4(device)) {
        return;
    }

    UInt8 data[64] = {};
    data[0] = k_ePS4FeatureReportIdGyroCalibration_USB;
    int size = [self hidGetFeatureReport:device data:data length:sizeof(data)];

    CFTypeRef transportValue = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDTransportKey));
    NSString *transport = (__bridge NSString *)transportValue;
    BOOL isBluetooth = [transport caseInsensitiveCompare:@"Bluetooth"] == NSOrderedSame;
    if (isBluetooth) {
        memset(data, 0, sizeof(data));
        data[0] = k_ePS4FeatureReportIdGyroCalibration_BT;
        size = [self hidGetFeatureReport:device data:data length:sizeof(data)];
    }

    if (size < 35) {
        Log(LOG_W, @"Unable to read DualShock 4 motion calibration (transport=%@ size=%d)",
            transport ?: @"unknown", size);
        self.ps4MotionCalibration = (PS4MotionCalibration){};
        return;
    }

    BOOL hasData = NO;
    for (int i = 1; i < size; i++) {
        if (data[i] != 0) {
            hasData = YES;
            break;
        }
    }
    if (!hasData) {
        Log(LOG_W, @"DualShock 4 returned empty motion calibration data");
        self.ps4MotionCalibration = (PS4MotionCalibration){};
        return;
    }

    int16_t gyroBias[3] = {
        PS4ReadS16(&data[1]), PS4ReadS16(&data[3]), PS4ReadS16(&data[5])
    };
    int16_t gyroPlus[3];
    int16_t gyroMinus[3];
    if (isBluetooth) {
        gyroPlus[0] = PS4ReadS16(&data[7]);
        gyroPlus[1] = PS4ReadS16(&data[9]);
        gyroPlus[2] = PS4ReadS16(&data[11]);
        gyroMinus[0] = PS4ReadS16(&data[13]);
        gyroMinus[1] = PS4ReadS16(&data[15]);
        gyroMinus[2] = PS4ReadS16(&data[17]);
    } else {
        gyroPlus[0] = PS4ReadS16(&data[7]);
        gyroMinus[0] = PS4ReadS16(&data[9]);
        gyroPlus[1] = PS4ReadS16(&data[11]);
        gyroMinus[1] = PS4ReadS16(&data[13]);
        gyroPlus[2] = PS4ReadS16(&data[15]);
        gyroMinus[2] = PS4ReadS16(&data[17]);
    }

    int16_t gyroSpeedPlus = PS4ReadS16(&data[19]);
    int16_t gyroSpeedMinus = PS4ReadS16(&data[21]);
    float gyroNumerator = (float)(gyroSpeedPlus + gyroSpeedMinus) * 16.0f;

    PS4MotionCalibration calibration = {};
    calibration.valid = YES;
    for (int axis = 0; axis < 3; axis++) {
        float denominator = (float)(abs(gyroPlus[axis] - gyroBias[axis]) +
                                    abs(gyroMinus[axis] - gyroBias[axis]));
        calibration.bias[axis] = gyroBias[axis];
        calibration.scale[axis] = denominator != 0.0f ? gyroNumerator / denominator : 0.0f;
        if (abs(calibration.bias[axis]) > 1024 ||
            fabsf(1.0f - calibration.scale[axis]) > 0.5f) {
            calibration.valid = NO;
        }
    }

    for (int axis = 0; axis < 3; axis++) {
        int offset = 23 + axis * 4;
        int16_t plus = PS4ReadS16(&data[offset]);
        int16_t minus = PS4ReadS16(&data[offset + 2]);
        int range = plus - minus;
        calibration.bias[axis + 3] = plus - range / 2;
        calibration.scale[axis + 3] = range != 0 ? 16384.0f / range : 0.0f;
        if (abs(calibration.bias[axis + 3]) > 1024 ||
            fabsf(1.0f - calibration.scale[axis + 3]) > 0.5f) {
            calibration.valid = NO;
        }
    }

    self.ps4MotionCalibration = calibration.valid ? calibration : (PS4MotionCalibration){};
    Log(calibration.valid ? LOG_I : LOG_W,
        calibration.valid ? @"Loaded DualShock 4 motion calibration" :
                            @"Ignoring invalid DualShock 4 motion calibration");
}

/**
 * Sends a native PlayStation contact transition after advertising controller arrival.
 *
 * Unchanged contacts generate no packet; releases use the last delivered position. Requires a
 * valid context and permitted arrival/delivery. Call from serialized HID touch processing.
 * @param active Whether the current contact is down.
 * @param x Current normalized horizontal coordinate.
 * @param y Current normalized vertical coordinate.
 * @param wasActive Whether the previous contact was down.
 * @param lastX Previous normalized horizontal coordinate, used for release.
 * @param lastY Previous normalized vertical coordinate, used for release.
 * @param pointerId Stable protocol contact identifier, zero or one for DS4 fingers.
 */
- (void)sendPS4TouchWithActive:(BOOL)active
                             x:(float)x
                             y:(float)y
                     wasActive:(BOOL)wasActive
                         lastX:(float)lastX
                         lastY:(float)lastY
                     pointerId:(uint32_t)pointerId {
    PML_INPUT_STREAM_CONTEXT inputCtx = HIDInputContext(self);
    if (!inputCtx || ![self reportPlayStationControllerArrival]) {
        return;
    }

    uint8_t eventType;
    if (active && !wasActive) eventType = LI_TOUCH_EVENT_DOWN;
    else if (!active && wasActive) eventType = LI_TOUCH_EVENT_UP;
    else if (active && (x != lastX || y != lastY)) eventType = LI_TOUCH_EVENT_MOVE;
    else return;

    float eventX = active ? x : lastX;
    float eventY = active ? y : lastY;
    LiSendControllerTouchEventCtx(inputCtx, 0, eventType, pointerId, eventX, eventY, active ? 1.0f : 0.0f);
}

/**
 * Resolves the touch surface mode independently of ordinary gamepad controls.
 * @return YES for legacy whole-gamepad mouse mode, a local override or Mac-style Trackpad.
 */
- (BOOL)touchpadUsesMouse {
    return self.controller.isMouseMode || (self.controller.hasTouchpadModeOverride
        ? self.controller.touchpadMouseMode : !self.nativeTouchpadEnabled);
}

/**
 * Clears gesture anchors, fractional deltas and delivered contacts without sending events.
 * Caller holds the HID monitor; used after releases or stream-context replacement.
 */
- (void)resetTrackpadState {
    self.trackpadOwnsPointer = NO;
    self.controller.trackpadGesture = (ControllerTrackpadGesture){0};
    self.controller.primaryTouchActive = self.controller.secondaryTouchActive = NO;
    self.controller.trackpadMouseAccumulatedX = self.controller.trackpadMouseAccumulatedY = 0;
    self.controller.trackpadScrollAccumulatedX = self.controller.trackpadScrollAccumulatedY = 0;
    self.controller.trackpadMouseButton = 0;
    self.controller.trackpadTouchBegan = 0;
    self.controller.trackpadPhysicalClickConsumed = NO;
    self.controller.trackpadClickMovementSuppressedUntil = 0;
    self.ps4PrimaryTouchActive = self.ps4SecondaryTouchActive = NO;
}

/**
 * Releases native contacts or a touchpad mouse click before resetting local gestures.
 * Runs on main under the HID monitor, never inputQueue; synchronously drains queued input.
 * A/B mouse sources are preserved when releasing the mechanical touchpad button.
 */
- (void)releaseTrackpadState {
    PML_INPUT_STREAM_CONTEXT input = HIDInputContext(self);
    if (self.controllerDriver == 0 && self.shouldSendControllerEvents && input && LiInputContextIsInitialized(input)) {
        BOOL primary = self.ps4PrimaryTouchActive, secondary = self.ps4SecondaryTouchActive;
        float px = self.ps4PrimaryTouchX, py = self.ps4PrimaryTouchY;
        float sx = self.ps4SecondaryTouchX, sy = self.ps4SecondaryTouchY;
        int click = self.controller.trackpadMouseButton;
        int held = self.controller.lastMouseModeButtonFlags;
        dispatch_sync(self.inputQueue, ^{
            LiSetThreadConnectionContext(input->connectionContext);
            if (primary) LiSendControllerTouchEventCtx(input, 0, LI_TOUCH_EVENT_UP, 0, px, py, 0);
            if (secondary) LiSendControllerTouchEventCtx(input, 0, LI_TOUCH_EVENT_UP, 1, sx, sy, 0);
            if (click && !(held & (click == BUTTON_LEFT ? A_FLAG : B_FLAG)))
                LiSendMouseButtonEventCtx(input, BUTTON_ACTION_RELEASE, click);
        });
    }
    self.controller.lastButtonFlags &= ~TOUCHPAD_FLAG;
    [self resetTrackpadState];
}

/**
 * Updates the mechanical mouse-button source without releasing a held A/B source.
 * @param button BUTTON_LEFT, BUTTON_RIGHT or zero on release; caller holds the HID monitor.
 */
- (void)setTrackpadMouseButton:(int)button {
    int previous = self.controller.trackpadMouseButton;
    if (previous == button) return;
    PML_INPUT_STREAM_CONTEXT input = HIDInputContext(self);
    int held = self.controller.lastMouseModeButtonFlags;
    if (input && self.shouldSendControllerEvents) {
        HIDDispatchInput(self, input, ^{
            if (previous && !(held & (previous == BUTTON_LEFT ? A_FLAG : B_FLAG)))
                LiSendMouseButtonEventCtx(input, BUTTON_ACTION_RELEASE, previous);
            if (button && !(held & (button == BUTTON_LEFT ? A_FLAG : B_FLAG)))
                LiSendMouseButtonEventCtx(input, BUTTON_ACTION_PRESS, button);
        });
    }
    self.controller.trackpadMouseButton = button;
}

/**
 * Consumes a complete DS4/DS5 contact pair on the main HID callback run loop.
 * Reuses the shared gesture engine for pointer, two-finger scroll and tap clicks. Native mode
 * preserves normalized controller-touch events. Both contacts are updated before consuming
 * their centroid; contact transitions reanchor to the final pair to prevent pointer/scroll jumps.
 * @param primary Four bytes containing the primary activity/ID byte and packed X/Y coordinates.
 * @param secondary Four bytes for the secondary contact; both arrays are borrowed for this call.
 * @param height Device touch surface height (DS4: 920, DS5: 1070); width is 1920.
 * @param pressed Current mechanical touchpad-button state.
 */
- (void)handlePlayStationTouchpad:(const UInt8 *)primary secondary:(const UInt8 *)secondary
                         height:(float)height pressed:(BOOL)pressed {
    @synchronized (self) {
        PML_INPUT_STREAM_CONTEXT input = HIDInputContext(self);
        if (self.controllerDriver != 0 || !self.shouldSendControllerEvents || !input ||
            !LiInputContextIsInitialized(input)) return;
        BOOL active[2] = {(primary[0] & 0x80) == 0, (secondary[0] & 0x80) == 0};
        const UInt8 *contacts[2] = {primary, secondary};
        float x[2], y[2];
        for (unsigned i = 0; i < 2; i++) {
            const UInt8 *c = contacts[i];
            x[i] = MIN(1.0f, (c[1] | ((c[2] & 0x0F) << 8)) / 1920.0f);
            y[i] = MIN(1.0f, ((c[2] >> 4) | (c[3] << 4)) / height);
        }
        if (![self touchpadUsesMouse]) {
            if (![self reportPlayStationControllerArrival]) return;
            [self sendPS4TouchWithActive:active[0] x:x[0] y:y[0]
                wasActive:self.ps4PrimaryTouchActive lastX:self.ps4PrimaryTouchX lastY:self.ps4PrimaryTouchY pointerId:0];
            [self sendPS4TouchWithActive:active[1] x:x[1] y:y[1]
                wasActive:self.ps4SecondaryTouchActive lastX:self.ps4SecondaryTouchX lastY:self.ps4SecondaryTouchY pointerId:1];
            self.ps4PrimaryTouchActive = active[0]; self.ps4SecondaryTouchActive = active[1];
            self.ps4PrimaryTouchX = x[0]; self.ps4PrimaryTouchY = y[0];
            self.ps4SecondaryTouchX = x[1]; self.ps4SecondaryTouchY = y[1];
            return;
        }
        Controller *controller = self.controller;
        ControllerTrackpadGesture state = controller.trackpadGesture;
        unsigned previousContacts = state.contacts;
        BOOL changed = NO;
        for (unsigned i = 0; i < 2; i++)
            changed |= ControllerTrackpadUpdate(&state, i, active[i], x[i], y[i]);
        if (changed && state.contacts != 0) {
            // Contact transitions can occur before the other finger's coordinate update.
            // Anchor against the complete report, never an intermediate centroid.
            unsigned finger = state.contacts == 2 ? 1 : 0;
            state.anchorX = state.contacts == 3 ? (state.x[0] + state.x[1]) * 0.5f : state.x[finger];
            state.anchorY = state.contacts == 3 ? (state.y[0] + state.y[1]) * 0.5f : state.y[finger];
        }
        controller.trackpadGesture = state;
        self.trackpadOwnsPointer = state.contacts != 0;
        controller.primaryTouchActive = active[0]; controller.secondaryTouchActive = active[1];
        NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
        if (previousContacts == 0 && state.contacts != 0) {
            controller.trackpadTouchBegan = now;
            controller.trackpadPhysicalClickConsumed = pressed || controller.trackpadMouseButton != 0;
        }
        if (pressed) {
            controller.trackpadPhysicalClickConsumed = YES;
            if (!controller.trackpadMouseButton) {
                controller.trackpadClickMovementSuppressedUntil = now + 0.05;
                [self setTrackpadMouseButton:active[1] ? BUTTON_RIGHT : BUTTON_LEFT];
            }
        } else [self setTrackpadMouseButton:0];
        if (previousContacts != 0 && state.contacts == 0) {
            BOOL tap = now - controller.trackpadTouchBegan <= 0.25 &&
                state.maximumTravelSquared <= 0.000064f && !controller.trackpadPhysicalClickConsumed;
            int button = state.maximumContacts == 2 ? BUTTON_RIGHT : BUTTON_LEFT;
            int held = controller.lastMouseModeButtonFlags;
            if (tap && !(held & (button == BUTTON_LEFT ? A_FLAG : B_FLAG))) {
                HIDDispatchInput(self, input, ^{
                    LiSendMouseButtonEventCtx(input, BUTTON_ACTION_PRESS, button);
                    LiSendMouseButtonEventCtx(input, BUTTON_ACTION_RELEASE, button);
                });
            }
            controller.trackpadTouchBegan = 0;
        }
        if (changed) {
            controller.trackpadMouseAccumulatedX = controller.trackpadMouseAccumulatedY = 0;
            controller.trackpadScrollAccumulatedX = controller.trackpadScrollAccumulatedY = 0;
        }
        ControllerTrackpadDelta delta = ControllerTrackpadConsume(&state);
        controller.trackpadGesture = state;
        if (now < controller.trackpadClickMovementSuppressedUntil) return;
        if (delta.scroll) {
            float scale = 2400.0f * fminf(4, fmaxf(0.1f, self.trackpadScrollSpeed));
            id preference = [[NSUserDefaults standardUserDefaults] objectForKey:@"com.apple.swipescrolldirection"];
            BOOL natural = preference == nil || [preference boolValue];
            BOOL inverted = natural != self.trackpadReverseScroll;
            controller.trackpadScrollAccumulatedX += (inverted ? -delta.dx : delta.dx) * scale;
            controller.trackpadScrollAccumulatedY += (inverted ? delta.dy : -delta.dy) * scale;
            short dx = (short)controller.trackpadScrollAccumulatedX, dy = (short)controller.trackpadScrollAccumulatedY;
            controller.trackpadScrollAccumulatedX -= dx; controller.trackpadScrollAccumulatedY -= dy;
            HIDDispatchInput(self, input, ^{
                if (dx) LiSendHighResHScrollEventCtx(input, dx);
                if (dy) LiSendHighResScrollEventCtx(input, dy);
            });
        } else {
            float scale = 1200.0f * fminf(4, fmaxf(0.1f, self.trackpadPointerSensitivity));
            controller.trackpadMouseAccumulatedX += delta.dx * scale;
            controller.trackpadMouseAccumulatedY += delta.dy * scale;
            short dx = (short)controller.trackpadMouseAccumulatedX, dy = (short)controller.trackpadMouseAccumulatedY;
            controller.trackpadMouseAccumulatedX -= dx; controller.trackpadMouseAccumulatedY -= dy;
            if (dx || dy) HIDDispatchInput(self, input, ^{ LiSendMouseMoveEventCtx(input, dx, dy); });
        }
    }
}

/**
 * Adapts a validated DS4 report to the shared HID touchpad path on main.
 * @param state Borrowed complete DS4 state; consumed synchronously.
 */
- (void)handlePS4TouchpadState:(PS4StatePacket_t *)state {
    [self handlePlayStationTouchpad:&state->ucTouchpadCounter1 secondary:&state->ucTouchpadCounter2
        height:920.0f pressed:(state->rgucButtonsHatAndCounter[2] & 0x02) != 0];
}

/**
 * Processes a DS4 motion report while holding the HID object's monitor.
 *
 * Serializes filtering and outgoing samples with host requests, gate resets and context
 * invalidation, which can occur on the native connection callback thread.
 * @param state Non-NULL validated DS4 state packet; consumed synchronously and not retained.
 */
- (void)handlePS4MotionState:(PS4StatePacket_t *)state {
    // Context invalidation may run on the connection callback thread.
    @synchronized (self) {
        [self processPS4MotionState:state];
    }
}

/**
 * Calibrates, filters and sends requested DS4 gyro and accelerometer samples.
 *
 * Processes gyro filtering and rest hysteresis at native report rate while limiting outgoing
 * samples to host-requested rates. Converts axes to protocol coordinates, gyro to degrees/s and
 * acceleration to m/s²; uses nominal scaling if factory calibration is invalid. Requires permitted
 * controller arrival, enabled motion and a valid context. Caller must hold the HID object's monitor.
 * @param state Non-NULL complete DS4 state packet whose motion bytes are read synchronously.
 */
- (void)processPS4MotionState:(PS4StatePacket_t *)state {
    if (self.controllerMotionMode == 2) {
        return;
    }
    PML_INPUT_STREAM_CONTEXT inputCtx = HIDInputContext(self);
    if (!inputCtx || ![self reportPlayStationControllerArrival]) {
        return;
    }

    uint64_t nowUs = PltGetMicroseconds();
    uint16_t gyroRate = self.requestedGyroRateHz;
    if (gyroRate > 0) {
        // Process every native HID report. Only transmission is rate-limited
        // to Sunshine's requested frequency below.
        if (self.ps4GyroRateWindowStartUs != UINT64_MAX) {
            if (self.ps4GyroRateWindowStartUs == 0) {
                self.ps4GyroRateWindowStartUs = nowUs;
            }
            self.ps4GyroRateWindowSamples += 1;
            uint64_t rateWindowUs = nowUs - self.ps4GyroRateWindowStartUs;
            if (rateWindowUs >= 1000000ULL) {
                double nativeRate = self.ps4GyroRateWindowSamples * 1000000.0 / rateWindowUs;
                Log(LOG_I, @"HID gyro rates: native=%.1f Hz requested=%u Hz", nativeRate, gyroRate);
                self.ps4GyroRateWindowStartUs = UINT64_MAX;
            }
        }
        BOOL gyroReportDue = self.lastGyroReportUs == 0 ||
                             nowUs - self.lastGyroReportUs >= 1000000ULL / gyroRate;
        PS4MotionCalibration calibration = self.ps4MotionCalibration;
        float calibrationScaleX = calibration.valid ? calibration.scale[0] : 1.0f;
        float calibrationScaleY = calibration.valid ? calibration.scale[1] : 1.0f;
        float calibrationScaleZ = calibration.valid ? calibration.scale[2] : 1.0f;
        int calibrationBiasX = calibration.valid ? calibration.bias[0] : 0;
        int calibrationBiasY = calibration.valid ? calibration.bias[1] : 0;
        int calibrationBiasZ = calibration.valid ? calibration.bias[2] : 0;
        float x = (PS4ReadS16(state->rgucGyroX) - calibrationBiasX) * calibrationScaleX / 16.0f;
        float y = (PS4ReadS16(state->rgucGyroY) - calibrationBiasY) * calibrationScaleY / 16.0f;
        float z = (PS4ReadS16(state->rgucGyroZ) - calibrationBiasZ) * calibrationScaleZ / 16.0f;
        float unfilteredX = x;
        float unfilteredY = y;
        float unfilteredZ = z;
        PS4GyroMedianFilter medianFilter = self.ps4GyroMedianFilter;
        HIDApplyPS4GyroMedianFilter(&medianFilter, &x, &y, &z);
        self.ps4GyroMedianFilter = medianFilter;
        float filterDeltaX = unfilteredX - x;
        float filterDeltaY = unfilteredY - y;
        float filterDeltaZ = unfilteredZ - z;
        float filterDelta = sqrtf(filterDeltaX * filterDeltaX +
                                  filterDeltaY * filterDeltaY +
                                  filterDeltaZ * filterDeltaZ);
        if (filterDelta >= kHIDGyroFilterDiagnosticDeltaDps &&
            self.remainingPS4GyroFilterDiagnosticLogs > 0) {
            self.remainingPS4GyroFilterDiagnosticLogs -= 1;
            Log(LOG_I, @"HID gyro median correction: input=(%.1f,%.1f,%.1f) output=(%.1f,%.1f,%.1f) delta=%.1f dps",
                unfilteredX, unfilteredY, unfilteredZ, x, y, z, filterDelta);
        }
        float magnitude = sqrtf(x * x + y * y + z * z);
        float restInputX = x;
        float restInputY = y;
        float restInputZ = z;
        BOOL wasAtRest = self.ps4GyroAtRest;
        if (self.ps4GyroAtRest) {
            if (magnitude >= kHIDGyroImmediateRestExitDps) {
                self.ps4GyroAtRest = NO;
                self.ps4GyroMovingSinceUs = 0;
            } else if (magnitude > kHIDGyroRestExitDps) {
                if (self.ps4GyroMovingSinceUs == 0) {
                    self.ps4GyroMovingSinceUs = nowUs;
                } else if (nowUs - self.ps4GyroMovingSinceUs >= kHIDGyroRestExitDurationUs) {
                    self.ps4GyroAtRest = NO;
                    self.ps4GyroMovingSinceUs = 0;
                }
            } else {
                self.ps4GyroMovingSinceUs = 0;
            }

            // Suppress short sensor-noise bursts while waiting for enough
            // evidence of real motion. A deliberate movement above 8 dps is
            // still forwarded immediately; slower motion adds about 30 ms.
            if (self.ps4GyroAtRest) {
                x = y = z = 0.0f;
            }
        } else if (magnitude <= kHIDGyroRestEnterDps) {
            if (self.ps4GyroStationarySinceUs == 0) {
                self.ps4GyroStationarySinceUs = nowUs;
            } else if (nowUs - self.ps4GyroStationarySinceUs >= kHIDGyroRestEnterDurationUs) {
                self.ps4GyroAtRest = YES;
                self.ps4GyroStationarySinceUs = 0;
                self.ps4GyroMovingSinceUs = 0;
                x = y = z = 0.0f;
            }
        } else {
            self.ps4GyroStationarySinceUs = 0;
            self.ps4GyroMovingSinceUs = 0;
        }
        if (wasAtRest != self.ps4GyroAtRest &&
            self.remainingPS4GyroRestDiagnosticLogs > 0) {
            self.remainingPS4GyroRestDiagnosticLogs -= 1;
            Log(LOG_I, @"HID gyro %@ rest: rate=(%.2f,%.2f,%.2f) magnitude=%.2f dps",
                self.ps4GyroAtRest ? @"entered" : @"left",
                restInputX, restInputY, restInputZ, magnitude);
        }
        // Send a newly detected neutral state immediately. Other values stay
        // within the report rate requested by Sunshine.
        gyroReportDue |= !wasAtRest && self.ps4GyroAtRest;
        if (gyroReportDue) {
            self.lastGyroReportUs = nowUs;
            if (self.remainingPS4MotionDiagnosticSamples > 0) {
                self.remainingPS4MotionDiagnosticSamples -= 1;
                Log(LOG_I, @"HID gyro sample: raw=(%d,%d,%d) filtered=(%.3f,%.3f,%.3f) calibrated=%d",
                    PS4ReadS16(state->rgucGyroX), PS4ReadS16(state->rgucGyroY),
                    PS4ReadS16(state->rgucGyroZ), x, y, z, calibration.valid);
            }
            if (!self.hasLastPS4GyroSample || x != self.lastPS4GyroX ||
                y != self.lastPS4GyroY || z != self.lastPS4GyroZ) {
                self.hasLastPS4GyroSample = YES;
                self.lastPS4GyroX = x;
                self.lastPS4GyroY = y;
                self.lastPS4GyroZ = z;
                LiSendControllerMotionEventCtx(inputCtx, 0, LI_MOTION_TYPE_GYRO, x, y, z);
            }
        }
    }

    uint16_t accelRate = self.requestedAccelRateHz;
    if (accelRate > 0 && (self.lastAccelReportUs == 0 || nowUs - self.lastAccelReportUs >= 1000000ULL / accelRate)) {
        self.lastAccelReportUs = nowUs;
        PS4MotionCalibration calibration = self.ps4MotionCalibration;
        float scaleX = (calibration.valid ? calibration.scale[3] : 1.0f) * 9.80665f / 8192.0f;
        float scaleY = (calibration.valid ? calibration.scale[4] : 1.0f) * 9.80665f / 8192.0f;
        float scaleZ = (calibration.valid ? calibration.scale[5] : 1.0f) * 9.80665f / 8192.0f;
        int biasX = calibration.valid ? calibration.bias[3] : 0;
        int biasY = calibration.valid ? calibration.bias[4] : 0;
        int biasZ = calibration.valid ? calibration.bias[5] : 0;
        LiSendControllerMotionEventCtx(inputCtx, 0, LI_MOTION_TYPE_ACCEL,
                                       (PS4ReadS16(state->rgucAccelX) - biasX) * scaleX,
                                       (PS4ReadS16(state->rgucAccelY) - biasY) * scaleY,
                                       (PS4ReadS16(state->rgucAccelZ) - biasZ) * scaleZ);
    }
}

- (KeyboardCompatibilityMode)keyboardCompatibilityMode {
    return (KeyboardCompatibilityMode)[SettingsClass keyboardCompatibilityModeFor:self.host.uuid];
}

- (BOOL)usesKeyboardCommandToControlCompatibility {
    KeyboardCompatibilityMode mode = [self keyboardCompatibilityMode];
    return mode == KeyboardCompatibilityModeCommandToControl;
}

- (BOOL)usesKeyboardLeftControlWinSwapCompatibility {
    KeyboardCompatibilityMode mode = [self keyboardCompatibilityMode];
    return mode == KeyboardCompatibilityModeSwapLeftControlAndWin ||
           mode == KeyboardCompatibilityModeHybrid;
}

- (BOOL)usesKeyboardShortcutTranslationCompatibility {
    KeyboardCompatibilityMode mode = [self keyboardCompatibilityMode];
    return mode == KeyboardCompatibilityModeShortcutTranslation ||
           mode == KeyboardCompatibilityModeHybrid;
}

- (void)updateKeyboardPhysicalModifierStateFromEvent:(NSEvent *)event {
    HIDKeyboardPhysicalModifierMask mask = HIDPhysicalModifierMaskForKeyCode(event.keyCode);
    NSEventModifierFlags modifierFlag = HIDModifierFlagForKeyCode(event.keyCode);
    if (mask == 0 || modifierFlag == 0) {
        return;
    }

    NSEventModifierFlags deviceMask = HIDDeviceModifierMaskForKeyCode(event.keyCode);
    BOOL pressed = (deviceMask != 0 && HIDEventCarriesDeviceModifierState(event.modifierFlags))
        ? ((event.modifierFlags & deviceMask) != 0)
        : ((event.modifierFlags & modifierFlag) != 0);
    if (pressed) {
        self.keyboardPhysicalModifierSourceMask |= mask;
    } else {
        self.keyboardPhysicalModifierSourceMask &= ~mask;
        self.keyboardDeferredShortcutTranslationCommandMask &= ~mask;
    }
}

- (BOOL)shouldApplyKeyboardShortcutTranslationForEvent:(NSEvent *)event {
    if (![self usesKeyboardShortcutTranslationCompatibility] || event == nil) {
        return NO;
    }

    if ((event.modifierFlags & NSEventModifierFlagCommand) == 0) {
        return NO;
    }

    if (event.type != NSEventTypeKeyDown && event.type != NSEventTypeKeyUp) {
        return NO;
    }

    if (HIDIsModifierKeyCode(event.keyCode)) {
        return NO;
    }

    return YES;
}

- (NSUInteger)desiredRemoteKeyboardModifierMaskForEvent:(NSEvent *)event {
    NSUInteger desired = 0;
    NSUInteger physical = HIDEffectivePhysicalModifierMaskForEvent(self.keyboardPhysicalModifierSourceMask, event);
    BOOL swapLeftControlAndWin = [self usesKeyboardLeftControlWinSwapCompatibility];
    BOOL hardMapCommandToControl = [self usesKeyboardCommandToControlCompatibility];
    BOOL translateShortcutCommandToControl = [self shouldApplyKeyboardShortcutTranslationForEvent:event];
    BOOL deferredLeftCommandToControl =
        (self.keyboardDeferredShortcutTranslationCommandMask & HIDKeyboardPhysicalModifierMaskLeftCommand) != 0;
    BOOL deferredRightCommandToControl =
        (self.keyboardDeferredShortcutTranslationCommandMask & HIDKeyboardPhysicalModifierMaskRightCommand) != 0;

    if (physical & HIDKeyboardPhysicalModifierMaskLeftShift) {
        desired |= HIDKeyboardRemoteModifierMaskLeftShift;
    }
    if (physical & HIDKeyboardPhysicalModifierMaskRightShift) {
        desired |= HIDKeyboardRemoteModifierMaskRightShift;
    }
    if (physical & HIDKeyboardPhysicalModifierMaskLeftControl) {
        desired |= swapLeftControlAndWin
        ? HIDKeyboardRemoteModifierMaskLeftMeta
        : HIDKeyboardRemoteModifierMaskLeftControl;
    }
    if (physical & HIDKeyboardPhysicalModifierMaskRightControl) {
        desired |= HIDKeyboardRemoteModifierMaskRightControl;
    }
    if (physical & HIDKeyboardPhysicalModifierMaskLeftOption) {
        desired |= HIDKeyboardRemoteModifierMaskLeftAlt;
    }
    if (physical & HIDKeyboardPhysicalModifierMaskRightOption) {
        desired |= HIDKeyboardRemoteModifierMaskRightAlt;
    }

    if (physical & HIDKeyboardPhysicalModifierMaskLeftCommand) {
        if (hardMapCommandToControl ||
            swapLeftControlAndWin ||
            translateShortcutCommandToControl ||
            deferredLeftCommandToControl) {
            desired |= HIDKeyboardRemoteModifierMaskLeftControl;
        } else {
            desired |= HIDKeyboardRemoteModifierMaskLeftMeta;
        }
    }
    if (physical & HIDKeyboardPhysicalModifierMaskRightCommand) {
        if (hardMapCommandToControl ||
            translateShortcutCommandToControl ||
            deferredRightCommandToControl) {
            desired |= HIDKeyboardRemoteModifierMaskRightControl;
        } else {
            desired |= HIDKeyboardRemoteModifierMaskRightMeta;
        }
    }

    return desired;
}

- (void)syncKeyboardModifierStateForEvent:(NSEvent *)event {
    NSUInteger previous = self.keyboardRemoteModifierMask;
    NSUInteger desired = [self desiredRemoteKeyboardModifierMaskForEvent:event];
    NSUInteger changed = previous ^ desired;
    if (changed == 0) {
        return;
    }

    char modifiers = HIDRemoteModifierFlagsToGenericFlags(desired);
    PML_INPUT_STREAM_CONTEXT inputCtx = HIDInputContext(self);
    if (!inputCtx) {
        self.keyboardRemoteModifierMask = desired;
        return;
    }

    static const HIDKeyboardRemoteModifierMask remoteOrder[] = {
        HIDKeyboardRemoteModifierMaskLeftShift,
        HIDKeyboardRemoteModifierMaskRightShift,
        HIDKeyboardRemoteModifierMaskLeftControl,
        HIDKeyboardRemoteModifierMaskRightControl,
        HIDKeyboardRemoteModifierMaskLeftAlt,
        HIDKeyboardRemoteModifierMaskRightAlt,
        HIDKeyboardRemoteModifierMaskLeftMeta,
        HIDKeyboardRemoteModifierMaskRightMeta,
    };

    self.keyboardRemoteModifierMask = desired;
    HIDDispatchInput(self, inputCtx, ^{
        for (NSUInteger i = 0; i < sizeof(remoteOrder) / sizeof(remoteOrder[0]); i++) {
            HIDKeyboardRemoteModifierMask mask = remoteOrder[i];
            if ((changed & mask) == 0) {
                continue;
            }

            unsigned short keyCode = HIDRemoteModifierKeyCode(mask);
            if (keyCode == 0) {
                continue;
            }

            char action = (desired & mask) != 0 ? KEY_ACTION_DOWN : KEY_ACTION_UP;
            LiSendKeyboardEventCtx(inputCtx, keyCode, action, modifiers);
        }
    });
}

- (void)flagsChanged:(NSEvent *)event {
    if (!self.shouldSendInputEvents) {
        return;
    }

    [self updateKeyboardPhysicalModifierStateFromEvent:event];
    [self syncKeyboardModifierStateForEvent:event];
}

- (void)keyDown:(NSEvent *)event {
    if (self.shouldSendInputEvents) {
        [self syncKeyboardModifierStateForEvent:event];
        short keyCode = 0x8000 | [self translateKeyCodeWithEvent:event];
        char modifiers = [self translateKeyModifierWithEvent:event];
        PML_INPUT_STREAM_CONTEXT inputCtx = HIDInputContext(self);
        if (!HIDValidateInputContext(inputCtx, "keyDown")) {
            return;
        }
        HIDDispatchInput(self, inputCtx, ^{
            LiSendKeyboardEventCtx(inputCtx, keyCode, KEY_ACTION_DOWN, modifiers);
        });
    }
}

- (void)keyUp:(NSEvent *)event {
    if (self.shouldSendInputEvents) {
        [self syncKeyboardModifierStateForEvent:event];
        short keyCode = 0x8000 | [self translateKeyCodeWithEvent:event];
        char modifiers = [self translateKeyModifierWithEvent:event];
        PML_INPUT_STREAM_CONTEXT inputCtx = HIDInputContext(self);
        if (!HIDValidateInputContext(inputCtx, "keyUp")) {
            return;
        }
        HIDDispatchInput(self, inputCtx, ^{
            LiSendKeyboardEventCtx(inputCtx, keyCode, KEY_ACTION_UP, modifiers);
        });
    }
}

- (void)releaseAllModifierKeys {
    // Send asynchronously to avoid blocking the main thread if the connection is dead
    self.keyboardPhysicalModifierSourceMask = 0;
    self.keyboardRemoteModifierMask = 0;
    self.keyboardDeferredShortcutTranslationCommandMask = 0;
    PML_INPUT_STREAM_CONTEXT inputCtx = HIDInputContext(self);
    if (!inputCtx) {
        return;
    }
    HIDDispatchInput(self, inputCtx, ^{
        LiSendKeyboardEventCtx(inputCtx, 0x5B, KEY_ACTION_UP, 0);
        LiSendKeyboardEventCtx(inputCtx, 0x5C, KEY_ACTION_UP, 0);
        LiSendKeyboardEventCtx(inputCtx, 0xA0, KEY_ACTION_UP, 0);
        LiSendKeyboardEventCtx(inputCtx, 0xA1, KEY_ACTION_UP, 0);
        LiSendKeyboardEventCtx(inputCtx, 0xA2, KEY_ACTION_UP, 0);
        LiSendKeyboardEventCtx(inputCtx, 0xA3, KEY_ACTION_UP, 0);
        LiSendKeyboardEventCtx(inputCtx, 0xA4, KEY_ACTION_UP, 0);
        LiSendKeyboardEventCtx(inputCtx, 0xA5, KEY_ACTION_UP, 0);
    });
}

- (void)beginDeferredShortcutTranslationCommandHoldForKeyCode:(unsigned short)keyCode {
    HIDKeyboardPhysicalModifierMask mask = HIDPhysicalModifierMaskForKeyCode(keyCode);
    mask &= (HIDKeyboardPhysicalModifierMaskLeftCommand | HIDKeyboardPhysicalModifierMaskRightCommand);
    if (mask == 0) {
        return;
    }

    self.keyboardPhysicalModifierSourceMask |= mask;
    self.keyboardDeferredShortcutTranslationCommandMask |= mask;
    [self syncKeyboardModifierStateForEvent:nil];
}

- (void)endDeferredShortcutTranslationCommandHoldForKeyCode:(unsigned short)keyCode {
    HIDKeyboardPhysicalModifierMask mask = HIDPhysicalModifierMaskForKeyCode(keyCode);
    mask &= (HIDKeyboardPhysicalModifierMaskLeftCommand | HIDKeyboardPhysicalModifierMaskRightCommand);
    if (mask == 0) {
        return;
    }

    self.keyboardPhysicalModifierSourceMask &= ~mask;
    self.keyboardDeferredShortcutTranslationCommandMask &= ~mask;
    [self syncKeyboardModifierStateForEvent:nil];
}

- (void)sendSyntheticRemoteModifierTapForFlags:(NSEventModifierFlags)modifierFlags {
    NSEventModifierFlags relevantFlags = [StreamShortcutProfile relevantModifierFlags:modifierFlags];
    NSUInteger remoteModifierMask = 0;
    if (relevantFlags & NSEventModifierFlagShift) {
        remoteModifierMask |= HIDKeyboardRemoteModifierMaskLeftShift;
    }
    if (relevantFlags & NSEventModifierFlagControl) {
        remoteModifierMask |= HIDKeyboardRemoteModifierMaskLeftControl;
    }
    if (relevantFlags & NSEventModifierFlagOption) {
        remoteModifierMask |= HIDKeyboardRemoteModifierMaskLeftAlt;
    }
    if (relevantFlags & NSEventModifierFlagCommand) {
        remoteModifierMask |= HIDKeyboardRemoteModifierMaskLeftMeta;
    }

    HIDDispatchSyntheticRemoteModifierTap(self, remoteModifierMask, "sendSyntheticRemoteModifierTapForFlags");
}

- (void)sendSyntheticRemoteModifierTapForKeyCode:(unsigned short)keyCode
            preferShortcutTranslationCommandMapping:(BOOL)preferShortcutTranslationCommandMapping {
    NSUInteger remoteModifierMask =
        HIDSyntheticRemoteModifierMaskForKeyCode(self, keyCode, preferShortcutTranslationCommandMapping);
    HIDDispatchSyntheticRemoteModifierTap(self,
                                          remoteModifierMask,
                                          "sendSyntheticRemoteModifierTapForKeyCode");
}

- (void)sendSyntheticRemoteShortcut:(StreamShortcut *)shortcut {
    if (shortcut == nil || shortcut.modifierOnly || shortcut.keyCode == StreamShortcut.noKeyCode) {
        return;
    }

    NSNumber *mappedKey = [self.mappings objectForKey:@(shortcut.keyCode)];
    if (mappedKey == nil) {
        return;
    }

    NSEventModifierFlags modifierFlags = [StreamShortcutProfile relevantModifierFlags:shortcut.modifierFlags];
    NSUInteger remoteModifierMask = 0;
    if (modifierFlags & NSEventModifierFlagShift) {
        remoteModifierMask |= HIDKeyboardRemoteModifierMaskLeftShift;
    }
    if (modifierFlags & NSEventModifierFlagControl) {
        remoteModifierMask |= HIDKeyboardRemoteModifierMaskLeftControl;
    }
    if (modifierFlags & NSEventModifierFlagOption) {
        remoteModifierMask |= HIDKeyboardRemoteModifierMaskLeftAlt;
    }
    if (modifierFlags & NSEventModifierFlagCommand) {
        remoteModifierMask |= HIDKeyboardRemoteModifierMaskLeftMeta;
    }

    char translatedModifiers = HIDRemoteModifierFlagsToGenericFlags(remoteModifierMask);
    short translatedKeyCode = (short)(0x8000 | [mappedKey shortValue]);

    PML_INPUT_STREAM_CONTEXT inputCtx = HIDInputContext(self);
    if (!HIDValidateInputContext(inputCtx, "sendSyntheticRemoteShortcut")) {
        return;
    }

    static const HIDKeyboardRemoteModifierMask remoteOrder[] = {
        HIDKeyboardRemoteModifierMaskLeftShift,
        HIDKeyboardRemoteModifierMaskRightShift,
        HIDKeyboardRemoteModifierMaskLeftControl,
        HIDKeyboardRemoteModifierMaskRightControl,
        HIDKeyboardRemoteModifierMaskLeftAlt,
        HIDKeyboardRemoteModifierMaskRightAlt,
        HIDKeyboardRemoteModifierMaskLeftMeta,
        HIDKeyboardRemoteModifierMaskRightMeta,
    };

    HIDDispatchInput(self, inputCtx, ^{
        for (NSUInteger i = 0; i < sizeof(remoteOrder) / sizeof(remoteOrder[0]); i++) {
            HIDKeyboardRemoteModifierMask mask = remoteOrder[i];
            if ((remoteModifierMask & mask) == 0) {
                continue;
            }

            unsigned short modifierKeyCode = HIDRemoteModifierKeyCode(mask);
            if (modifierKeyCode != 0) {
                LiSendKeyboardEventCtx(inputCtx, modifierKeyCode, KEY_ACTION_DOWN, translatedModifiers);
            }
        }

        LiSendKeyboardEventCtx(inputCtx, translatedKeyCode, KEY_ACTION_DOWN, translatedModifiers);
        LiSendKeyboardEventCtx(inputCtx, translatedKeyCode, KEY_ACTION_UP, translatedModifiers);

        for (NSInteger i = (NSInteger)(sizeof(remoteOrder) / sizeof(remoteOrder[0])) - 1; i >= 0; i--) {
            HIDKeyboardRemoteModifierMask mask = remoteOrder[(NSUInteger)i];
            if ((remoteModifierMask & mask) == 0) {
                continue;
            }

            unsigned short modifierKeyCode = HIDRemoteModifierKeyCode(mask);
            if (modifierKeyCode != 0) {
                LiSendKeyboardEventCtx(inputCtx, modifierKeyCode, KEY_ACTION_UP, 0);
            }
        }
    });
}

- (short)translateKeyCodeWithEvent:(NSEvent *)event {
    if (![self.mappings objectForKey:@(event.keyCode)]) {
        return 0;
    }
    return [self.mappings[@(event.keyCode)] shortValue];
}

- (char)translatedModifierFlagsForEvent:(NSEvent *)event {
    return HIDRemoteModifierFlagsToGenericFlags([self desiredRemoteKeyboardModifierMaskForEvent:event]);
}

- (char)translateKeyModifierWithEvent:(NSEvent *)event {
    return [self translatedModifierFlagsForEvent:event];
}

- (BOOL)useGCMouse {
    return [SettingsClass shouldUseGameControllerMouseFor:self.host.uuid];
}

- (BOOL)useCoreHIDMouse {
    return [SettingsClass shouldAllowCoreHIDMouseFor:self.host.uuid];
}

- (BOOL)shouldUseAbsolutePointerPathForCurrentConfiguration {
    NSInteger touchscreenMode = [SettingsClass touchscreenModeFor:self.host.uuid];
    return HIDShouldUseAbsolutePointerPath(self, touchscreenMode);
}

- (BOOL)shouldUseCoreHIDFreeMouseAbsoluteSyncForCurrentConfiguration {
    return HIDShouldUseCoreHIDFreeMouseAbsoluteSync(self);
}

- (BOOL)hasRecentCoreHIDMouseMovement {
    return self.coreHIDMouseDriver != nil &&
           self.coreHIDMouseDriver.secondsSinceLastMovementEvent < 0.25;
}

/**
 * Resolves the effective host/global controller backend, including for recognized DualSense pads.
 * Call on the main HID run loop; direct HID owns input only when this preference is zero.
 * @return The configured backend (zero for HID, one for GameController).
 */
- (NSInteger)controllerDriver {
    return [SettingsClass controllerDriverFor:self.host.uuid];
}

- (void)refreshMouseInputConfiguration {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self refreshMouseInputConfiguration];
        });
        return;
    }

    for (GCMouse *mouse in GCMouse.mice) {
        [self unregisterMouseCallbacks:mouse];
        [self registerMouseCallbacks:mouse];
    }

    [self tearDownCoreHIDMouseDriver];
    [self setupCoreHIDMouseDriverIfNeeded];
}

- (void)setupCoreHIDMouseDriverIfNeeded {
    if (!self.useCoreHIDMouse) {
        return;
    }

    NSInteger touchscreenMode = [SettingsClass touchscreenModeFor:self.host.uuid];
    BOOL useAbsolutePointerPath = HIDShouldUseAbsolutePointerPath(self, touchscreenMode);
    if (useAbsolutePointerPath) {
        Log(LOG_I, @"CoreHID mouse skipped: absolute pointer path active (mouseMode=%@ touchscreenMode=%ld strategy=%ld)",
            [SettingsClass mouseModeFor:self.host.uuid],
            (long)touchscreenMode,
            (long)[SettingsClass mouseDriverFor:self.host.uuid]);
        return;
    }

    if (self.coreHIDMouseDriver != nil) {
        return;
    }

    self.coreHIDMouseRuntimeFailed = NO;
    self.coreHIDMouseDidDeliverMovement = NO;
    self.coreHIDMouseDriver = [[CoreHIDMouseDriver alloc] init];
    self.coreHIDMouseDriver.delegate = self;
    self.coreHIDMouseDriver.maximumReportRate = [SettingsClass coreHIDMaxMouseReportRateFor:self.host.uuid];
    self.coreHIDMouseDriver.requestsListenAccessIfNeeded = NO;
    [SettingsClass updateMouseInputRuntimeStatusFor:self.host.uuid
                                        summaryKey:@"Mouse Runtime Path CoreHID Pending"
                                         detailKey:@"Mouse Runtime Detail CoreHID Pending"];
    Log(LOG_I, @"CoreHID mouse setup: strategy=%ld maxRate=%d requestAccess=%d",
        (long)[SettingsClass mouseDriverFor:self.host.uuid],
        self.coreHIDMouseDriver.maximumReportRate,
        self.coreHIDMouseDriver.requestsListenAccessIfNeeded ? 1 : 0);
    [self.coreHIDMouseDriver start];
}

- (void)tearDownCoreHIDMouseDriver {
    if (self.coreHIDMouseDriver == nil) {
        return;
    }

    [self.coreHIDMouseDriver stop];
    self.coreHIDMouseDriver.delegate = nil;
    self.coreHIDMouseDriver = nil;
    self.coreHIDMouseDidDeliverMovement = NO;
    HIDInvalidateCoreHIDFreeMouseAbsoluteSync(self);
}

- (void)dispatchRelativeMouseDeltaX:(CGFloat)deltaX
                             deltaY:(CGFloat)deltaY
                          sourceTag:(NSString *)sourceTag {
    if (deltaX == 0.0 && deltaY == 0.0) {
        return;
    }

    if (!self.shouldSendInputEvents) {
        return;
    }

    PML_INPUT_STREAM_CONTEXT inputCtx = HIDInputContext(self);
    if (!HIDValidateInputContext(inputCtx, "dispatchRelativeMouseDelta")) {
        return;
    }

    NSInteger touchscreenMode = [SettingsClass touchscreenModeFor:self.host.uuid];
    if (HIDShouldUseAbsolutePointerPath(self, touchscreenMode)) {
        return;
    }

    BOOL suppressed = HIDShouldSuppressRelativeMouse(self);
    CGFloat sensitivity = HIDPointerSensitivityForHost(self.host);
    short moveX = HIDScaledRelativeDelta(deltaX, sensitivity);
    short moveY = HIDScaledRelativeDelta(deltaY, sensitivity);
    [self recordRelativeInputDiagnosticsFrom:sourceTag
                                   rawDeltaX:deltaX
                                   rawDeltaY:deltaY
                                  sentDeltaX:(suppressed ? 0 : moveX)
                                  sentDeltaY:(suppressed ? 0 : moveY)
                                  suppressed:suppressed];
    if (suppressed || (moveX == 0 && moveY == 0)) {
        return;
    }

    HIDDispatchInput(self, inputCtx, ^{
        LiSendMouseMoveEventCtx(inputCtx, moveX, moveY);
    });
}

- (void)coreHIDMouseDriver:(CoreHIDMouseDriver *)driver
            didObserveRawDeltaX:(double)deltaX
                      deltaY:(double)deltaY {
    (void)driver;
    if (!self.inputDiagnosticsEnabled || (!isfinite(deltaX) && !isfinite(deltaY))) {
        return;
    }

    @synchronized (self.inputDiagnosticsLock) {
        self.inputDiagnosticsCoreHIDRawEvents += 1;
    }
}

- (void)coreHIDMouseDriver:(CoreHIDMouseDriver *)driver
             didReceiveDeltaX:(double)deltaX
                       deltaY:(double)deltaY {
    (void)driver;
    if (!self.useCoreHIDMouse) {
        return;
    }

    if (!self.coreHIDMouseDidDeliverMovement) {
        self.coreHIDMouseDidDeliverMovement = YES;
        Log(LOG_I, @"CoreHID mouse active: first movement received");
        [[InputMonitoringPermissionManager sharedManager] noteCoreHIDDidBecomeActive];
        [SettingsClass updateMouseInputRuntimeStatusFor:self.host.uuid
                                            summaryKey:@"Mouse Runtime Path CoreHID Active"
                                             detailKey:@"Mouse Runtime Detail CoreHID Active"];
    }
    if (self.inputDiagnosticsEnabled) {
        @synchronized (self.inputDiagnosticsLock) {
            self.inputDiagnosticsCoreHIDDispatches += 1;
        }
    }
    self.coreHIDMouseRuntimeFailed = NO;
    BOOL dispatchedVirtualFreeMouse = [self dispatchVirtualFreeMouseDeltaX:deltaX
                                                                    deltaY:deltaY
                                                                 sourceTag:@"coreHIDVirtualFreeMouse"];
    if (dispatchedVirtualFreeMouse) {
        HIDInvalidateCoreHIDFreeMouseAbsoluteSync(self);
        return;
    }
    if (HIDShouldUseCoreHIDFreeMouseAbsoluteSync(self) && self.freeMouseAbsoluteSyncHandler != nil) {
        if (!self.coreHIDFreeMouseAbsoluteSyncScheduled) {
            self.coreHIDFreeMouseAbsoluteSyncScheduled = YES;
            uint64_t scheduleToken = ++self.coreHIDFreeMouseAbsoluteSyncToken;
            HIDFreeMouseAbsoluteSyncHandler handler = self.freeMouseAbsoluteSyncHandler;
            __weak typeof(self) weakSelf = self;
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (strongSelf == nil ||
                    !strongSelf.coreHIDFreeMouseAbsoluteSyncScheduled ||
                    strongSelf.coreHIDFreeMouseAbsoluteSyncToken != scheduleToken) {
                    return;
                }
                strongSelf.coreHIDFreeMouseAbsoluteSyncScheduled = NO;
                handler();
            });
        }
        return;
    }
    HIDInvalidateCoreHIDFreeMouseAbsoluteSync(self);
    [self dispatchRelativeMouseDeltaX:(CGFloat)deltaX
                               deltaY:(CGFloat)deltaY
                            sourceTag:@"coreHIDMouse"];
}

- (void)coreHIDMouseDriver:(CoreHIDMouseDriver *)driver
         didFailWithReason:(NSString *)reason
                messageKey:(NSString *)messageKey {
    (void)driver;
    NSString *safeReason = reason.length > 0 ? reason : @"unknown";
    NSString *safeMessage = messageKey.length > 0 ? messageKey : @"CoreHID Mouse input failed.";
    NSInteger configuredStrategy = [SettingsClass mouseDriverFor:self.host.uuid];
    self.coreHIDMouseRuntimeFailed = YES;
    if ([safeReason isEqualToString:@"permission-denied"]) {
        [[InputMonitoringPermissionManager sharedManager] noteCoreHIDPermissionFailureWithMessage:safeMessage];
    }
    LogLevel level = (configuredStrategy == 3 && [safeReason isEqualToString:@"permission-denied"]) ? LOG_I : LOG_W;
    Log(level, @"CoreHID mouse fallback: reason=%@ message=%@", safeReason, safeMessage);
    NSString *detailKey = @"Mouse Runtime Detail AppKit Fallback Runtime";
    if ([safeReason isEqualToString:@"permission-denied"]) {
        detailKey = @"Mouse Runtime Detail AppKit Fallback Permission";
    } else if ([safeReason isEqualToString:@"unsupported-os"]) {
        detailKey = @"Mouse Runtime Detail AppKit Fallback UnsupportedOS";
    }
    [SettingsClass updateMouseInputRuntimeStatusFor:self.host.uuid
                                        summaryKey:@"Mouse Runtime Path AppKit Fallback"
                                         detailKey:detailKey];
}

- (void)handleDpad:(NSInteger)intValue {
    switch (intValue) {
        case 0:
            [self updateButtonFlags:UP_FLAG state:YES];
            break;
        case 1:
            [self updateButtonFlags:UP_FLAG | RIGHT_FLAG state:YES];
            break;
        case 2:
            [self updateButtonFlags:RIGHT_FLAG state:YES];
            break;
        case 3:
            [self updateButtonFlags:DOWN_FLAG | RIGHT_FLAG state:YES];
            break;
        case 4:
            [self updateButtonFlags:DOWN_FLAG state:YES];
            break;
        case 5:
            [self updateButtonFlags:DOWN_FLAG | LEFT_FLAG state:YES];
            break;
        case 6:
            [self updateButtonFlags:LEFT_FLAG state:YES];
            break;
        case 7:
            [self updateButtonFlags:UP_FLAG | LEFT_FLAG state:YES];
            break;

        case 8:
            [self updateButtonFlags:UP_FLAG | RIGHT_FLAG | DOWN_FLAG | LEFT_FLAG state:NO];
            break;

        default:
            break;
    }
}

void myHIDCallback(void* context, IOReturn result, void* sender, IOHIDValueRef value) {
    IOHIDElementRef elem = IOHIDValueGetElement(value);
    uint32_t usagePage = IOHIDElementGetUsagePage(elem);
    uint32_t usage = IOHIDElementGetUsage(elem);
    CFIndex intValue = IOHIDValueGetIntegerValue(value);
    
    HIDSupport *self = (__bridge HIDSupport *)context;
    
    IOHIDDeviceRef device = (IOHIDDeviceRef)sender;
    
    if (isXbox(device)) {
        switch (usagePage) {
            case kHIDPage_GenericDesktop:
                switch (usage) {
                    case kHIDUsage_GD_X:
                        self.controller.lastLeftStickX = MIN((intValue - 32768), 32767);
                        break;
                    case kHIDUsage_GD_Y:
                        self.controller.lastLeftStickY = MIN(-(intValue - 32768), 32767);
                        break;
                    case kHIDUsage_GD_Z:
                        self.controller.lastRightStickX = MIN((intValue - 32768), 32767);
                        break;
                    case kHIDUsage_GD_Rz:
                        self.controller.lastRightStickY = MIN(-(intValue - 32768), 32767);
                        break;
                        
                    case kHIDUsage_GD_Hatswitch:
                        switch (intValue) {
                            case 1:
                                [self updateButtonFlags:UP_FLAG state:YES];
                                break;
                            case 2:
                                [self updateButtonFlags:UP_FLAG | RIGHT_FLAG state:YES];
                                break;
                            case 3:
                                [self updateButtonFlags:RIGHT_FLAG state:YES];
                                break;
                            case 4:
                                [self updateButtonFlags:DOWN_FLAG | RIGHT_FLAG state:YES];
                                break;
                            case 5:
                                [self updateButtonFlags:DOWN_FLAG state:YES];
                                break;
                            case 6:
                                [self updateButtonFlags:DOWN_FLAG | LEFT_FLAG state:YES];
                                break;
                            case 7:
                                [self updateButtonFlags:LEFT_FLAG state:YES];
                                break;
                            case 8:
                                [self updateButtonFlags:UP_FLAG | LEFT_FLAG state:YES];
                                break;

                            case 0:
                                [self updateButtonFlags:UP_FLAG | RIGHT_FLAG | DOWN_FLAG | LEFT_FLAG state:NO];
                                break;

                            default:
                                break;
                        }

                    default:
                        break;
                }
            case kHIDPage_Simulation:
                switch (usage) {
                    case kHIDUsage_Sim_Brake:
                        self.controller.lastLeftTrigger = intValue;
                        break;
                    case kHIDUsage_Sim_Accelerator:
                        self.controller.lastRightTrigger = intValue;
                        break;

                    default:
                        break;
                }

            case kHIDPage_Button:
                switch (usage) {
                    case 1:
                        [self updateButtonFlags:A_FLAG state:intValue];
                        break;
                    case 2:
                        [self updateButtonFlags:B_FLAG state:intValue];
                        break;
                    case 4:
                        [self updateButtonFlags:X_FLAG state:intValue];
                        break;
                    case 5:
                        [self updateButtonFlags:Y_FLAG state:intValue];
                        break;
                    case 7:
                        [self updateButtonFlags:LB_FLAG state:intValue];
                        break;
                    case 8:
                        [self updateButtonFlags:RB_FLAG state:intValue];
                        break;
                    case 11:
                        [self updateButtonFlags:BACK_FLAG state:intValue];
                        break;
                    case 12:
                        [self updateButtonFlags:PLAY_FLAG state:intValue];
                        break;
                    case 13:
                        [self updateButtonFlags:SPECIAL_FLAG state:intValue];
                        break;

                        
                    default:
                        break;
                }
                
            case kHIDPage_Consumer:
                switch (usage) {
                    case kHIDUsage_Csmr_ACBack:
                        [self updateButtonFlags:BACK_FLAG state:intValue];
                        break;
                    case kHIDUsage_Csmr_ACHome:
                        [self updateButtonFlags:SPECIAL_FLAG state:intValue];
                        break;
                    case 14:
                        [self updateButtonFlags:LS_CLK_FLAG state:intValue];
                        break;
                    case 15:
                        [self updateButtonFlags:RS_CLK_FLAG state:intValue];
                        break;

                    default:
                        break;
                }
                
            default:
                break;
        }
    } else if (isKingKong(device)) {
        switch (usagePage) {
            case kHIDPage_GenericDesktop:
                switch (usage) {
                    case kHIDUsage_GD_X:
                        self.controller.lastLeftStickX = MAX(MIN((intValue - 32768), 32767), -32768);
                        break;
                    case kHIDUsage_GD_Y:
                        self.controller.lastLeftStickY = MAX(MIN(-(intValue - 32768), 32767), -32768);
                        break;
                    case kHIDUsage_GD_Rx:
                        self.controller.lastRightStickX = MAX(MIN((intValue - 32768), 32767), -32768);
                        break;
                    case kHIDUsage_GD_Ry:
                        self.controller.lastRightStickY = MAX(MIN(-(intValue - 32768), 32767), -32768);
                        break;
                    case kHIDUsage_GD_Z:
                        self.controller.lastLeftTrigger = (unsigned char)((int)intValue / 4);
                        break;
                    case kHIDUsage_GD_Rz:
                        self.controller.lastRightTrigger = (unsigned char)((int)intValue / 4);
                        break;
                        
                    case kHIDUsage_GD_Hatswitch:
                        switch (intValue) {
                            case 1:
                                [self updateButtonFlags:UP_FLAG state:YES];
                                break;
                            case 2:
                                [self updateButtonFlags:UP_FLAG | RIGHT_FLAG state:YES];
                                break;
                            case 3:
                                [self updateButtonFlags:RIGHT_FLAG state:YES];
                                break;
                            case 4:
                                [self updateButtonFlags:DOWN_FLAG | RIGHT_FLAG state:YES];
                                break;
                            case 5:
                                [self updateButtonFlags:DOWN_FLAG state:YES];
                                break;
                            case 6:
                                [self updateButtonFlags:DOWN_FLAG | LEFT_FLAG state:YES];
                                break;
                            case 7:
                                [self updateButtonFlags:LEFT_FLAG state:YES];
                                break;
                            case 8:
                                [self updateButtonFlags:UP_FLAG | LEFT_FLAG state:YES];
                                break;

                            case 0:
                                [self updateButtonFlags:UP_FLAG | RIGHT_FLAG | DOWN_FLAG | LEFT_FLAG state:NO];
                                break;

                            default:
                                break;
                        }

                    default:
                        break;
                }

            case kHIDPage_Button:
                switch (usage) {
                    case 1:
                        [self updateButtonFlags:A_FLAG state:intValue];
                        break;
                    case 2:
                        [self updateButtonFlags:B_FLAG state:intValue];
                        break;
                    case 3:
                        [self updateButtonFlags:X_FLAG state:intValue];
                        break;
                    case 4:
                        [self updateButtonFlags:Y_FLAG state:intValue];
                        break;
                    case 5:
                        [self updateButtonFlags:LB_FLAG state:intValue];
                        break;
                    case 6:
                        [self updateButtonFlags:RB_FLAG state:intValue];
                        break;
                    case 7:
                        [self updateButtonFlags:BACK_FLAG state:intValue];
                        break;
                    case 8:
                        [self updateButtonFlags:PLAY_FLAG state:intValue];
                        break;
                    case 9:
                        [self updateButtonFlags:LS_CLK_FLAG state:intValue];
                        break;
                    case 10:
                        [self updateButtonFlags:RS_CLK_FLAG state:intValue];
                        break;
                    case 133:
                        [self updateButtonFlags:SPECIAL_FLAG state:intValue];
                        break;

                        
                    default:
                        break;
                }
                
            default:
                break;
        }
    }

    if (self.controllerDriver == 0) {
        [self sendControllerEvent];
    }
}

/**
 * Parses supported PlayStation/Nintendo HID reports and updates controller input state.
 *
 * Rejects missing, truncated and unsupported PlayStation reports before accessing their fields.
 * DS5 simple Bluetooth keeps its compact control layout; complete reports also deliver touch.
 * DS5 advertises touch capabilities before ordinary or extended input, retrying failed arrival.
 * DS4 processing normalizes sticks, ignores report-counter-only changes and forwards touch/motion
 * through their delivery gates. Runs on the HID manager's main run loop; ordinary state is queued
 * on the serial input queue.
 * @param context Borrowed HIDSupport callback context.
 * @param result IOKit report status; not inspected by this callback.
 * @param sender HID device that produced the report.
 * @param type IOKit report type; parsing uses the report's first byte instead.
 * @param reportID IOKit report identifier; parsing uses the report's first byte instead.
 * @param report Borrowed report bytes, valid only for this callback.
 * @param reportLength Number of available bytes in report.
 */
void myHIDReportCallback (
                          void * _Nullable        context,
                          IOReturn                result,
                          void * _Nullable        sender,
                          IOHIDReportType         type,
                          uint32_t                reportID,
                          uint8_t *               report,
                          CFIndex                 reportLength) {
    HIDSupport *self = (__bridge HIDSupport *)context;

    if (report == NULL || reportLength < 1) {
        return;
    }
    
    IOHIDDeviceRef device = (IOHIDDeviceRef)sender;
    if (!isPlayStation(device) && !isNintendo(device)) {
        return;
    };
    
    if (isPS4(device)) {
        self.playStationHasMotion = YES;
        NSUInteger stateOffset;
        switch (report[0]) {
            case k_EPS4ReportIdUsbState:
                stateOffset = 1;
                break;
            case k_EPS4ReportIdBluetoothState1:
            case k_EPS4ReportIdBluetoothState2:
            case k_EPS4ReportIdBluetoothState3:
            case k_EPS4ReportIdBluetoothState4:
            case k_EPS4ReportIdBluetoothState5:
            case k_EPS4ReportIdBluetoothState6:
            case k_EPS4ReportIdBluetoothState7:
            case k_EPS4ReportIdBluetoothState8:
            case k_EPS4ReportIdBluetoothState9:
                // Bluetooth state packets have two additional bytes at the beginning, the first notes if HID is present.
                if (reportLength < 3 || !(report[1] & 0x80)) {
                    return;
                }
                stateOffset = 3;
                break;
            case k_EPS4ReportIdDisconnectMessage:
                return;
            default:
                NSLog(@"Unknown PS4 packet: 0x%hhu", report[0]);
                return;
        }

        if (reportLength < 0 || (NSUInteger)reportLength < stateOffset + sizeof(PS4StatePacket_t)) {
            Log(LOG_W, @"Ignoring truncated PS4 input report: id=0x%02x length=%ld",
                report[0], (long)reportLength);
            return;
        }

        PS4StatePacket_t *state = (PS4StatePacket_t *)(report + stateOffset);
                
        
        UInt8 abxy = state->rgucButtonsHatAndCounter[0] >> 4;
        [self updateButtonFlags:X_FLAG state:(abxy & 0x01) != 0];
        [self updateButtonFlags:A_FLAG state:(abxy & 0x02) != 0];
        [self updateButtonFlags:B_FLAG state:(abxy & 0x04) != 0];
        [self updateButtonFlags:Y_FLAG state:(abxy & 0x08) != 0];
        
        [self handleDpad:state->rgucButtonsHatAndCounter[0] & 0x0F];

        UInt8 otherButtons = state->rgucButtonsHatAndCounter[1];
        [self updateButtonFlags:LB_FLAG state:(otherButtons & 0x01) != 0];
        [self updateButtonFlags:RB_FLAG state:(otherButtons & 0x02) != 0];
        [self updateButtonFlags:BACK_FLAG state:(otherButtons & 0x10) != 0];
        [self updateButtonFlags:PLAY_FLAG state:(otherButtons & 0x20) != 0];
        [self updateButtonFlags:LS_CLK_FLAG state:(otherButtons & 0x40) != 0];
        [self updateButtonFlags:RS_CLK_FLAG state:(otherButtons & 0x80) != 0];

        [self updateButtonFlags:SPECIAL_FLAG state:(state->rgucButtonsHatAndCounter[2] & 0x01) != 0];
        [self updateButtonFlags:TOUCHPAD_FLAG state:(state->rgucButtonsHatAndCounter[2] & 0x02) != 0];
        
        self.controller.lastLeftTrigger = state->ucTriggerLeft;
        self.controller.lastRightTrigger = state->ucTriggerRight;

        self.controller.lastLeftStickX = PS4NormalizeStickAxis(state->ucLeftJoystickX, NO);
        self.controller.lastLeftStickY = PS4NormalizeStickAxis(state->ucLeftJoystickY, YES);
        self.controller.lastRightStickX = PS4NormalizeStickAxis(state->ucRightJoystickX, NO);
        self.controller.lastRightStickY = PS4NormalizeStickAxis(state->ucRightJoystickY, YES);

        BOOL leftTriggerPressed = (otherButtons & 0x04) != 0;
        BOOL rightTriggerPressed = (otherButtons & 0x08) != 0;
        BOOL previousLeftTriggerPressed = (self.lastPS4State.rgucButtonsHatAndCounter[1] & 0x04) != 0;
        BOOL previousRightTriggerPressed = (self.lastPS4State.rgucButtonsHatAndCounter[1] & 0x08) != 0;
        BOOL playStationReady = self.controllerDriver == 0 && [self reportPlayStationControllerArrival];
        if (playStationReady && leftTriggerPressed != previousLeftTriggerPressed) {
            Log(LOG_I, @"HID L2 %@ (analog=%u)",
                leftTriggerPressed ? @"pressed" : @"released", state->ucTriggerLeft);
        }
        if (playStationReady && rightTriggerPressed != previousRightTriggerPressed) {
            Log(LOG_I, @"HID R2 %@ (analog=%u)",
                rightTriggerPressed ? @"pressed" : @"released", state->ucTriggerRight);
        }

        if (playStationReady) {
            if (self.lastPS4State.rgucButtonsHatAndCounter[0] != state->rgucButtonsHatAndCounter[0] ||
                self.lastPS4State.rgucButtonsHatAndCounter[1] != state->rgucButtonsHatAndCounter[1] ||
                // Bits 2-7 are a rolling hardware report counter. Comparing
                // the whole byte queues a reliable controller packet for
                // every ~260 Hz HID report even when no control has changed.
                (self.lastPS4State.rgucButtonsHatAndCounter[2] & 0x03) !=
                    (state->rgucButtonsHatAndCounter[2] & 0x03) ||
                self.lastPS4State.ucTriggerLeft != state->ucTriggerLeft ||
                self.lastPS4State.ucTriggerRight != state->ucTriggerRight ||
                PS4NormalizeStickAxis(self.lastPS4State.ucLeftJoystickX, NO) != self.controller.lastLeftStickX ||
                PS4NormalizeStickAxis(self.lastPS4State.ucLeftJoystickY, YES) != self.controller.lastLeftStickY ||
                PS4NormalizeStickAxis(self.lastPS4State.ucRightJoystickX, NO) != self.controller.lastRightStickX ||
                PS4NormalizeStickAxis(self.lastPS4State.ucRightJoystickY, YES) != self.controller.lastRightStickY ||
                0)
            {
                // Queue buttons, triggers, and sticks before high-rate sensor
                // data so gameplay controls win when network capacity is low.
                [self sendControllerEvent];
                self.lastPS4State = *state;
            }
        }

        if (playStationReady) {
            [self handlePS4TouchpadState:state];
            [self handlePS4MotionState:state];
        }
    } else if (isPS5(device)) {
        self.playStationHasMotion = NO;
        NSUInteger stateOffset;
        BOOL simple = report[0] == k_EPS5ReportIdState && reportLength == 10;
        switch (report[0]) {
            case k_EPS5ReportIdState:
                stateOffset = 1;
                self.isPS5Bluetooth = simple;
                break;
            case k_EPS5ReportIdBluetoothState:
                stateOffset = 2;
                self.isPS5Bluetooth = YES;
                break;
            default:
                return;
        }
        NSUInteger required = simple ? 9 : offsetof(PS5StatePacket_t, ucZero);
        if ((NSUInteger)reportLength < stateOffset + required) {
            Log(LOG_W, @"Ignoring truncated DS5 input report: id=0x%02x length=%ld", report[0], (long)reportLength);
            return;
        }
        // Simple Bluetooth places buttons before triggers and has no touch contacts.
        PS5StatePacket_t decoded = {0};
        if (simple) {
            memcpy(&decoded, report + stateOffset, 4);
            memcpy(decoded.rgucButtonsAndHat, report + stateOffset + 4, 3);
            decoded.ucTriggerLeft = report[stateOffset + 7];
            decoded.ucTriggerRight = report[stateOffset + 8];
        } else {
            memcpy(&decoded, report + stateOffset, MIN(sizeof(decoded), (NSUInteger)reportLength - stateOffset));
        }
        PS5StatePacket_t *state = &decoded;
        BOOL hasTouchpad = !simple && (NSUInteger)reportLength >=
            stateOffset + offsetof(PS5StatePacket_t, rgucUnknown1);

        UInt8 abxy = state->rgucButtonsAndHat[0] >> 4;
        [self updateButtonFlags:X_FLAG state:(abxy & 0x01) != 0];
        [self updateButtonFlags:A_FLAG state:(abxy & 0x02) != 0];
        [self updateButtonFlags:B_FLAG state:(abxy & 0x04) != 0];
        [self updateButtonFlags:Y_FLAG state:(abxy & 0x08) != 0];
        
        [self handleDpad:state->rgucButtonsAndHat[0] & 0x0F];

        UInt8 otherButtons = state->rgucButtonsAndHat[1];
        [self updateButtonFlags:LB_FLAG state:(otherButtons & 0x01) != 0];
        [self updateButtonFlags:RB_FLAG state:(otherButtons & 0x02) != 0];
        [self updateButtonFlags:BACK_FLAG state:(otherButtons & 0x10) != 0];
        [self updateButtonFlags:PLAY_FLAG state:(otherButtons & 0x20) != 0];
        [self updateButtonFlags:LS_CLK_FLAG state:(otherButtons & 0x40) != 0];
        [self updateButtonFlags:RS_CLK_FLAG state:(otherButtons & 0x80) != 0];

        [self updateButtonFlags:SPECIAL_FLAG state:(state->rgucButtonsAndHat[2] & 0x01) != 0];
        
        if (hasTouchpad) [self updateButtonFlags:TOUCHPAD_FLAG state:(state->rgucButtonsAndHat[2] & 0x02) != 0];
        self.controller.lastLeftTrigger = state->ucTriggerLeft;
        self.controller.lastRightTrigger = state->ucTriggerRight;

        self.controller.lastLeftStickX = (state->ucLeftJoystickX - 128) * 255 + 1;
        self.controller.lastLeftStickY = (state->ucLeftJoystickY - 128) * -255;
        self.controller.lastRightStickX = (state->ucRightJoystickX - 128) * 255 + 1;
        self.controller.lastRightStickY = (state->ucRightJoystickY - 128) * -255;
        
        if (self.controllerDriver == 0 && [self reportPlayStationControllerArrival]) {

            if (self.lastPS5State.rgucButtonsAndHat[0] != state->rgucButtonsAndHat[0] ||
                self.lastPS5State.rgucButtonsAndHat[1] != state->rgucButtonsAndHat[1] ||
                self.lastPS5State.rgucButtonsAndHat[2] != state->rgucButtonsAndHat[2] ||
                self.lastPS5State.ucTriggerLeft != state->ucTriggerLeft ||
                self.lastPS5State.ucTriggerRight != state->ucTriggerRight ||
                self.lastPS5State.ucLeftJoystickX != state->ucLeftJoystickX ||
                self.lastPS5State.ucLeftJoystickY != state->ucLeftJoystickY ||
                self.lastPS5State.ucRightJoystickX != state->ucRightJoystickX ||
                self.lastPS5State.ucRightJoystickY != state->ucRightJoystickY ||
                0)
            {
                [self sendControllerEvent];
                self.lastPS5State = *state;
            }
            if (hasTouchpad) [self handlePlayStationTouchpad:&state->ucTouchpadCounter1
                secondary:&state->ucTouchpadCounter2 height:1070.0f pressed:(state->rgucButtonsAndHat[2] & 0x02) != 0];
        }
    } else if (isNintendo(device)) {
        if (self.waitingForVibrationEnable) {
            if (TICKS_PASSED([self.ticks getTicks], self.startedWaitingForVibrationEnable + 100)) {
                self.vibrationEnableResponded = NO;
                self.waitingForVibrationEnable = NO;
                dispatch_semaphore_signal(self.hidReadSemaphore);
            }
            if (report[0] == k_eSwitchInputReportIDs_SubcommandReply) {
                SwitchSubcommandInputPacket_t *reply = (SwitchSubcommandInputPacket_t *)&report[1];
                if (reply->ucSubcommandID == k_eSwitchSubcommandIDs_EnableVibration && (reply->ucSubcommandAck & 0x80)) {
                    self.vibrationEnableResponded = YES;
                    self.waitingForVibrationEnable = NO;
                    dispatch_semaphore_signal(self.hidReadSemaphore);
                }
            }
        } else {
            if (report[0] == k_eSwitchInputReportIDs_SimpleControllerState) {
                SwitchSimpleStatePacket_t *packet = (SwitchSimpleStatePacket_t *)&report[1];
                
                SInt16 axis;
                
                UInt8 buttons = packet->rgucButtons[0];
                [self updateButtonFlags:Y_FLAG state:(buttons & 0x08) != 0];
                [self updateButtonFlags:B_FLAG state:(buttons & 0x02) != 0];
                [self updateButtonFlags:A_FLAG state:(buttons & 0x01) != 0];
                [self updateButtonFlags:X_FLAG state:(buttons & 0x04) != 0];
                [self updateButtonFlags:LB_FLAG state:(buttons & 0x10) != 0];
                [self updateButtonFlags:RB_FLAG state:(buttons & 0x20) != 0];
                axis = (buttons & 0x40) ? 32767 : -32768;
                self.controller.lastLeftTrigger = axis;
                axis = (buttons & 0x80) ? 32767 : -32768;
                self.controller.lastRightTrigger = axis;
                
                UInt8 otherButtons = packet->rgucButtons[1];
                [self updateButtonFlags:BACK_FLAG state:(otherButtons & 0x01) != 0];
                [self updateButtonFlags:PLAY_FLAG state:(otherButtons & 0x02) != 0];
                [self updateButtonFlags:LS_CLK_FLAG state:(otherButtons & 0x04) != 0];
                [self updateButtonFlags:RS_CLK_FLAG state:(otherButtons & 0x08) != 0];
                
                [self updateButtonFlags:SPECIAL_FLAG state:(otherButtons & 0x10) != 0];
                
                [self handleDpad:packet->ucStickHat];

                axis = (short)(packet->sJoystickLeft[0] - INT_MAX);
                self.controller.lastLeftStickX = axis;
                axis = (short)(packet->sJoystickLeft[1] - INT_MAX);
                self.controller.lastLeftStickY = axis;
                axis = (short)(packet->sJoystickRight[0] - INT_MAX);
                self.controller.lastRightStickX = axis;
                axis = (short)(packet->sJoystickRight[1] - INT_MAX);
                self.controller.lastRightStickY = axis;
                
                if (self.controllerDriver == 0) {
                    
                    if (self.lastSimpleSwitchState.rgucButtons[0] != packet->rgucButtons[0] ||
                        self.lastSimpleSwitchState.rgucButtons[1] != packet->rgucButtons[1] ||
                        self.lastSimpleSwitchState.ucStickHat != packet->ucStickHat ||
                        self.lastSimpleSwitchState.sJoystickLeft[0] != packet->sJoystickLeft[0] ||
                        self.lastSimpleSwitchState.sJoystickLeft[1] != packet->sJoystickLeft[1] ||
                        self.lastSimpleSwitchState.sJoystickRight[0] != packet->sJoystickRight[0] ||
                        self.lastSimpleSwitchState.sJoystickRight[1] != packet->sJoystickRight[1] ||
                        0)
                    {
                        [self sendControllerEvent];
                        self.lastSimpleSwitchState = *packet;
                    }
                }
            } else if (report[0] == k_eSwitchInputReportIDs_FullControllerState) {
                SwitchStatePacket_t *packet = (SwitchStatePacket_t *)&report[1];
                
                SInt16 axis;
                
                UInt8 buttons = packet->controllerState.rgucButtons[0];
                [self updateButtonFlags:Y_FLAG state:(buttons & 0x02) != 0];
                [self updateButtonFlags:B_FLAG state:(buttons & 0x08) != 0];
                [self updateButtonFlags:A_FLAG state:(buttons & 0x04) != 0];
                [self updateButtonFlags:X_FLAG state:(buttons & 0x01) != 0];
                [self updateButtonFlags:RB_FLAG state:(buttons & 0x40) != 0];
                axis = (buttons & 0x80) ? 32767 : -32768;
                self.controller.lastRightTrigger = axis;
                
                UInt8 otherButtons = packet->controllerState.rgucButtons[1];
                [self updateButtonFlags:BACK_FLAG state:(otherButtons & 0x01) != 0];
                [self updateButtonFlags:PLAY_FLAG state:(otherButtons & 0x02) != 0];
                [self updateButtonFlags:LS_CLK_FLAG state:(otherButtons & 0x08) != 0];
                [self updateButtonFlags:RS_CLK_FLAG state:(otherButtons & 0x04) != 0];
                
                [self updateButtonFlags:SPECIAL_FLAG state:(otherButtons & 0x10) != 0];
                
                UInt8 otherOtherButtons = packet->controllerState.rgucButtons[2];
                [self updateButtonFlags:DOWN_FLAG state:(otherOtherButtons & 0x01) != 0];
                [self updateButtonFlags:UP_FLAG state:(otherOtherButtons & 0x02) != 0];
                [self updateButtonFlags:RIGHT_FLAG state:(otherOtherButtons & 0x04) != 0];
                [self updateButtonFlags:LEFT_FLAG state:(otherOtherButtons & 0x08) != 0];
                [self updateButtonFlags:LB_FLAG state:(otherOtherButtons & 0x40) != 0];
                axis = (otherOtherButtons & 0x80) ? 32767 : -32768;
                self.controller.lastLeftTrigger = axis;
                
                axis = packet->controllerState.rgucJoystickLeft[0] | ((packet->controllerState.rgucJoystickLeft[1] & 0xF) << 8);
                self.controller.lastLeftStickX = MAX(MIN((axis - 2048) * 24, INT16_MAX), INT16_MIN);
                axis = ((packet->controllerState.rgucJoystickLeft[1] & 0xF0) >> 4) | (packet->controllerState.rgucJoystickLeft[2] << 4);
                self.controller.lastLeftStickY = MAX(MIN((axis - 2048) * 24, INT16_MAX), INT16_MIN);
                axis = packet->controllerState.rgucJoystickRight[0] | ((packet->controllerState.rgucJoystickRight[1] & 0xF) << 8);
                self.controller.lastRightStickX = MAX(MIN((axis - 2048) * 24, INT16_MAX), INT16_MIN);
                axis = ((packet->controllerState.rgucJoystickRight[1] & 0xF0) >> 4) | (packet->controllerState.rgucJoystickRight[2] << 4);
                self.controller.lastRightStickY = MAX(MIN((axis - 2048) * 24, INT16_MAX), INT16_MIN);
                
                if (self.controllerDriver == 0) {
                    
                    if (self.lastSwitchState.controllerState.rgucButtons[0] != packet->controllerState.rgucButtons[0] ||
                        self.lastSwitchState.controllerState.rgucButtons[1] != packet->controllerState.rgucButtons[1] ||
                        self.lastSwitchState.controllerState.rgucButtons[2] != packet->controllerState.rgucButtons[2] ||
                        self.lastSwitchState.controllerState.rgucJoystickLeft[0] != packet->controllerState.rgucJoystickLeft[0] ||
                        self.lastSwitchState.controllerState.rgucJoystickLeft[1] != packet->controllerState.rgucJoystickLeft[1] ||
                        self.lastSwitchState.controllerState.rgucJoystickRight[0] != packet->controllerState.rgucJoystickRight[0] ||
                        self.lastSwitchState.controllerState.rgucJoystickRight[1] != packet->controllerState.rgucJoystickRight[1] ||
                        0)
                    {
                        [self sendControllerEvent];
                        self.lastSwitchState = *packet;
                    }
                }
            }
        }
    }
}

/**
 * Initializes DS4 motion calibration, enables direct-HID DS5 extended reports and syncs rumble.
 *
 * Called on the HID manager's main run loop; calibration feature-report reads are synchronous.
 * @param context Borrowed HIDSupport callback context.
 * @param result IOKit matching status; unused.
 * @param sender IOKit callback sender; unused.
 * @param device Newly matched HID device.
 */
void myHIDDeviceMatchingCallback(void * _Nullable        context,
                                IOReturn                result,
                                void * _Nullable        sender,
                                IOHIDDeviceRef          device) {
    HIDSupport *self = (__bridge HIDSupport *)context;

    self.playStationHasMotion = isPS4(device);
    if (self.controllerDriver == 0 && isPS5(device)) {
        // Reading Sony's serial-number feature report enables Bluetooth reports with touch data.
        UInt8 feature[64] = {0x09};
        CFIndex length = sizeof(feature);
        IOReturn status = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, feature[0], feature, &length);
        if (status != kIOReturnSuccess)
            Log(LOG_W, @"Unable to enable DS5 extended HID reports: result=0x%x", status);
    }
    [self loadPS4MotionCalibrationForDevice:device];
    [self rumbleSync];
}

/**
 * Clears physical direct-HID controller state when a device is removed.
 *
 * Cancels menu tracking and resets arrival, calibration, filters and contacts under the HID
 * monitor, preserving host motion rates across physical reconnects. Drains queued input and
 * releases delivered gamepad, mouse, touch and gyro state before clearing local caches.
 * Runs on the HID manager's main run loop, never on inputQueue.
 * @param context Borrowed HIDSupport callback context.
 * @param result IOKit removal status; unused.
 * @param sender IOKit callback sender; unused.
 * @param device Removed HID device; state reset is backend-wide rather than device-specific.
 */
void myHIDDeviceRemovalCallback(void * _Nullable        context,
                                IOReturn                result,
                                void * _Nullable        sender,
                                IOHIDDeviceRef          device) {
    HIDSupport *self = (__bridge HIDSupport *)context;

    [self.gamepadMenuTimer invalidate];
    self.gamepadMenuTimer = nil;
    self.gamepadMenuPressed = NO;
    self.controller.menuGesture = (ControllerMenuGesture){0};
    @synchronized (self) {
        if (self.controllerDriver == 0) {
            PML_INPUT_STREAM_CONTEXT input = HIDInputContext(self);
            if (self.shouldSendControllerEvents && input && LiInputContextIsInitialized(input)) {
                int player = self.controller.playerIndex;
                BOOL primary = self.ps4PrimaryTouchActive, secondary = self.ps4SecondaryTouchActive;
                float primaryX = self.ps4PrimaryTouchX, primaryY = self.ps4PrimaryTouchY;
                float secondaryX = self.ps4SecondaryTouchX, secondaryY = self.ps4SecondaryTouchY;
                BOOL stopGyro = self.reportedPlayStationArrival && self.requestedGyroRateHz > 0;
                int mouseButtons = self.controller.lastMouseModeButtonFlags;
                int trackpadButton = self.controller.trackpadMouseButton;
                dispatch_sync(self.inputQueue, ^{
                    LiSetThreadConnectionContext(input->connectionContext);
                    LiSendMultiControllerEventCtx(input, player, 1, 0, 0, 0, 0, 0, 0, 0);
                    if (primary)
                        LiSendControllerTouchEventCtx(input, player, LI_TOUCH_EVENT_UP, 0, primaryX, primaryY, 0);
                    if (secondary)
                        LiSendControllerTouchEventCtx(input, player, LI_TOUCH_EVENT_UP, 1, secondaryX, secondaryY, 0);
                    if (stopGyro)
                        LiSendControllerMotionEventCtx(input, player, LI_MOTION_TYPE_GYRO, 0, 0, 0);
                    if (trackpadButton && !(mouseButtons & (trackpadButton == BUTTON_LEFT ? A_FLAG : B_FLAG)))
                        LiSendMouseButtonEventCtx(input, BUTTON_ACTION_RELEASE, trackpadButton);
                    if (mouseButtons & A_FLAG)
                        LiSendMouseButtonEventCtx(input, BUTTON_ACTION_RELEASE, BUTTON_LEFT);
                    if (mouseButtons & B_FLAG)
                        LiSendMouseButtonEventCtx(input, BUTTON_ACTION_RELEASE, BUTTON_RIGHT);
                });
            }
            self.reportedPlayStationArrival = NO;
            // Sunshine generally sends motion report rates only once per virtual
            // controller session. Preserve them across a physical HID reconnect;
            // setInputContext resets them when the streaming session changes.
            self.lastGyroReportUs = 0;
            self.lastAccelReportUs = 0;
            self.ps4MotionCalibration = (PS4MotionCalibration){};
            self.ps4GyroMedianFilter = (PS4GyroMedianFilter){};
            self.ps4GyroRateWindowStartUs = 0;
            self.ps4GyroRateWindowSamples = 0;
            self.hasLastPS4GyroSample = NO;
            self.ps4GyroAtRest = YES;
            self.ps4GyroStationarySinceUs = 0;
            self.ps4GyroMovingSinceUs = 0;
            self.remainingPS4MotionDiagnosticSamples = self.requestedGyroRateHz > 0 ? 3 : 0;
            self.remainingPS4GyroFilterDiagnosticLogs = self.requestedGyroRateHz > 0 ? 8 : 0;
            self.remainingPS4GyroRestDiagnosticLogs = self.requestedGyroRateHz > 0 ? 12 : 0;
            self.ps4PrimaryTouchActive = NO;
            self.ps4SecondaryTouchActive = NO;
            self.controller.lastMouseModeButtonFlags = 0;
            [self resetTrackpadState];
            self.controller.hasTouchpadModeOverride = NO;
            self.lastPS5State = (PS5StatePacket_t){};
            self.lastPS4State = (PS4StatePacket_t){};
            self.controller.lastButtonFlags = 0;
            self.controller.lastLeftTrigger = 0;
            self.controller.lastRightTrigger = 0;
            self.controller.lastLeftStickX = 0;
            self.controller.lastLeftStickY = 0;
            self.controller.lastRightStickX = 0;
            self.controller.lastRightStickY = 0;

        }
    }
}


/**
 * Refreshes legacy mouse/menu preferences for the current host on main.
 * Cancels an in-progress hold when preferences change and exits disabled legacy mouse mode.
 */
- (void)refreshGamepadMouseModeConfiguration {
    BOOL mouseEnabled = [SettingsClass gamepadMouseModeFor:self.host.uuid];
    BOOL gestureEnabled = [SettingsClass gamepadMouseModeLongPressMenuFor:self.host.uuid];
    if (mouseEnabled != self.gamepadMouseModeEnabled ||
        gestureEnabled != self.gamepadMouseModeLongPressMenuEnabled) {
        ControllerMenuGesture gesture = self.controller.menuGesture;
        ControllerMenuGestureInterrupt(&gesture, self.gamepadMenuPressed);
        self.controller.menuGesture = gesture;
        [self.gamepadMenuTimer invalidate];
        self.gamepadMenuTimer = nil;
    }
    self.gamepadMouseModeEnabled = mouseEnabled;
    self.gamepadMouseModeLongPressMenuEnabled = gestureEnabled;
    if (!mouseEnabled) [self setGamepadMouseModeActive:NO];
}

/**
 * Switches direct-HID gamepad mouse mode, releasing delivered mouse buttons as needed.
 *
 * Entering mouse mode sends neutral gamepad state; leaving restores held A/B bits and flushes
 * ordinary state. Releases the touch surface and resets gestures under the HID monitor.
 * Posts HIDMouseModeToggledNotification after the transition.
 * Call on main, where mode and menu gesture state are managed.
 * @param active Whether stick/button mouse emulation should be active.
 */
- (void)setGamepadMouseModeActive:(BOOL)active {
    @synchronized (self) {
        if (self.controller.isMouseMode == active) return;
        [self releaseTrackpadState];
        PML_INPUT_STREAM_CONTEXT input = HIDInputContext(self);
        int heldMouseButtons = self.controller.lastMouseModeButtonFlags;
        if (input && self.shouldSendControllerEvents) {
            int player = self.controller.playerIndex;
            HIDDispatchInput(self, input, ^{
                if (heldMouseButtons & A_FLAG)
                    LiSendMouseButtonEventCtx(input, BUTTON_ACTION_RELEASE, BUTTON_LEFT);
                if (heldMouseButtons & B_FLAG)
                    LiSendMouseButtonEventCtx(input, BUTTON_ACTION_RELEASE, BUTTON_RIGHT);
                if (active)
                    LiSendMultiControllerEventCtx(input, player, 1, 0, 0, 0, 0, 0, 0, 0);
            });
        }
        self.controller.isMouseMode = active;
        self.controller.lastMouseModeButtonFlags = 0;
        if (!active) self.controller.lastButtonFlags |= heldMouseButtons & (A_FLAG | B_FLAG);
        self.controller.primaryTouchActive = NO;
        self.controller.secondaryTouchActive = NO;
        self.controller.trackpadMouseAccumulatedX = 0;
        self.controller.trackpadMouseAccumulatedY = 0;
        self.controller.trackpadScrollAccumulatedY = 0;
        self.controller.trackpadMouseButton = 0;
        [[NSNotificationCenter defaultCenter] postNotificationName:HIDMouseModeToggledNotification
            object:nil userInfo:@{@"enabled": @(active)}];
        if (!active && self.controllerDriver == 0) [self sendControllerEvent];
    }
}

/**
 * Advances the direct-HID menu hold and toggles the touchpad or legacy mouse mode.
 *
 * Requires the direct driver, hold setting and enabled controller delivery. Sony pads switch
 * only their touch surface; other pads require the legacy mouse setting. Installs a
 * one-shot main-run-loop timer for devices that report only button edges; cancellation clears
 * the timer and a consumed hold removes the menu bit. Call on the main thread.
 */
- (void)updateGamepadMenuGesture {
    IOHIDDeviceRef device = [self getFirstDevice];
    BOOL hasTouchpad = device && isPlayStation(device);
    BOOL enabled = (hasTouchpad || self.gamepadMouseModeEnabled) && self.gamepadMouseModeLongPressMenuEnabled &&
        self.controllerDriver == 0 && self.shouldSendControllerEvents;
    ControllerMenuGesture gesture = self.controller.menuGesture;
    double now = NSProcessInfo.processInfo.systemUptime;
    BOOL toggle = ControllerMenuGestureUpdate(&gesture, enabled, self.gamepadMenuPressed, now);
    self.controller.menuGesture = gesture;
    if (!gesture.tracking || gesture.consumed || gesture.blockedUntilRelease) {
        [self.gamepadMenuTimer invalidate];
        self.gamepadMenuTimer = nil;
    } else if (self.gamepadMenuTimer == nil) {
        // Some HID devices send only button edges. A one-shot timer also
        // completes their hold without requiring another device report.
        __weak HIDSupport *weakSelf = self;
        self.gamepadMenuTimer = [NSTimer timerWithTimeInterval:MAX(0.001, 2.0 - (now - gesture.began))
            repeats:NO block:^(NSTimer *timer) {
                HIDSupport *strongSelf = weakSelf;
                strongSelf.gamepadMenuTimer = nil;
                [strongSelf updateGamepadMenuGesture];
            }];
        [[NSRunLoop mainRunLoop] addTimer:self.gamepadMenuTimer forMode:NSRunLoopCommonModes];
    }
    if (toggle) {
        self.controller.lastButtonFlags &= ~PLAY_FLAG;
        if (hasTouchpad) {
            @synchronized (self) {
                BOOL wasMouse = [self touchpadUsesMouse];
                [self releaseTrackpadState];
                self.controller.hasTouchpadModeOverride = YES;
                self.controller.touchpadMouseMode = !wasMouse;
                [self sendControllerEvent];
            }
            [[NSNotificationCenter defaultCenter] postNotificationName:HIDMouseModeToggledNotification
                object:nil userInfo:@{@"enabled": @([self touchpadUsesMouse])}];
        } else [self setGamepadMouseModeActive:!self.controller.isMouseMode];
    }
}

/**
 * Updates a direct-HID button or sends its mouse-mode equivalent through the controller gate.
 *
 * Consumes touchpad buttons in pointer mode; preserves their click source across A/B transitions.
 * Tracks menu-hold consumption and deduplicates A/B mouse-button transitions while mouse mode
 * is active. Physical gamepad state can still update while remote delivery is paused. Call from
 * the main-run-loop HID input path; remote mouse events are queued on inputQueue.
 * @param flag Button flag being updated.
 * @param set YES for a press, NO for a release.
 */
- (void)updateButtonFlags:(int)flag state:(BOOL)set {
    if (flag == TOUCHPAD_FLAG && [self touchpadUsesMouse]) {
        self.controller.lastButtonFlags &= ~TOUCHPAD_FLAG;
        return;
    }
    if (flag == PLAY_FLAG) {
        self.gamepadMenuPressed = set;
        [self updateGamepadMenuGesture];
        set = set && !self.controller.menuGesture.consumed;
    }
    
    // Mouse Click Logic
    if (self.controller.isMouseMode && self.shouldSendControllerEvents) {
        if (flag == A_FLAG) {
            // Left Click
            BOOL wasPressed = (self.controller.lastMouseModeButtonFlags & A_FLAG) != 0;
            if (set == wasPressed) return;
            if (set) self.controller.lastMouseModeButtonFlags |= A_FLAG;
            else self.controller.lastMouseModeButtonFlags &= ~A_FLAG;
            if (self.controller.trackpadMouseButton == BUTTON_LEFT) return;
            if (set) {
                 PML_INPUT_STREAM_CONTEXT inputCtx = HIDInputContext(self);
                 if (!inputCtx) {
                     return;
                 }
                HIDDispatchInput(self, inputCtx, ^{ LiSendMouseButtonEventCtx(inputCtx, BUTTON_ACTION_PRESS, BUTTON_LEFT); });
            } else {
                 PML_INPUT_STREAM_CONTEXT inputCtx = HIDInputContext(self);
                 if (!inputCtx) {
                     return;
                 }
                 HIDDispatchInput(self, inputCtx, ^{ LiSendMouseButtonEventCtx(inputCtx, BUTTON_ACTION_RELEASE, BUTTON_LEFT); });
            }
            return; // Don't set flag
        }
        if (flag == B_FLAG) {
            // Right Click
            BOOL wasPressed = (self.controller.lastMouseModeButtonFlags & B_FLAG) != 0;
            if (set == wasPressed) return;
            if (set) self.controller.lastMouseModeButtonFlags |= B_FLAG;
            else self.controller.lastMouseModeButtonFlags &= ~B_FLAG;
            if (self.controller.trackpadMouseButton == BUTTON_RIGHT) return;
            if (set) {
                 PML_INPUT_STREAM_CONTEXT inputCtx = HIDInputContext(self);
                 if (!inputCtx) {
                     return;
                 }
                 HIDDispatchInput(self, inputCtx, ^{ LiSendMouseButtonEventCtx(inputCtx, BUTTON_ACTION_PRESS, BUTTON_RIGHT); });
            } else {
                 PML_INPUT_STREAM_CONTEXT inputCtx = HIDInputContext(self);
                 if (!inputCtx) {
                     return;
                 }
                 HIDDispatchInput(self, inputCtx, ^{ LiSendMouseButtonEventCtx(inputCtx, BUTTON_ACTION_RELEASE, BUTTON_RIGHT); });
            }
            return; // Don't set flag
        }
    }

    if (set) {
        self.controller.lastButtonFlags |= flag;
    } else {
        self.controller.lastButtonFlags &= ~flag;
    }
    
    // Gamepad Quit Combo (Start + Select + LB + RB)
    int quitCombo = PLAY_FLAG | BACK_FLAG | LB_FLAG | RB_FLAG;
    if ((self.controller.lastButtonFlags & quitCombo) == quitCombo) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:HIDGamepadQuitNotification object:nil];
        });
        self.controller.lastButtonFlags = 0;
    }
}

- (void)setupHidManager {
    self.hidManager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    IOHIDManagerOpen(self.hidManager, kIOHIDOptionsTypeNone);
    
    NSArray *matches = @[
                         @{@kIOHIDDeviceUsagePageKey: @(kHIDPage_GenericDesktop), @kIOHIDDeviceUsageKey: @(kHIDUsage_GD_Joystick)},
                         @{@kIOHIDDeviceUsagePageKey: @(kHIDPage_GenericDesktop), @kIOHIDDeviceUsageKey: @(kHIDUsage_GD_GamePad)},
                         @{@kIOHIDDeviceUsagePageKey: @(kHIDPage_GenericDesktop), @kIOHIDDeviceUsageKey: @(kHIDUsage_GD_MultiAxisController)},
                         ];
    IOHIDManagerSetDeviceMatchingMultiple(self.hidManager, (__bridge CFArrayRef)matches);
    
    IOHIDManagerRegisterInputValueCallback(self.hidManager, myHIDCallback, (__bridge void * _Nullable)(self));
    IOHIDManagerRegisterInputReportCallback(self.hidManager, myHIDReportCallback, (__bridge void * _Nullable)(self));
    IOHIDManagerRegisterDeviceMatchingCallback(self.hidManager, myHIDDeviceMatchingCallback, (__bridge void * _Nullable)(self));
    IOHIDManagerRegisterDeviceRemovalCallback(self.hidManager, myHIDDeviceRemovalCallback, (__bridge void * _Nullable)(self));
    
    IOHIDManagerScheduleWithRunLoop(self.hidManager, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    
    self.rumbleSemaphore = dispatch_semaphore_create(0);
    self.rumbleQueue = dispatch_queue_create("rumbleQueue", nil);
    
    self.enableVibrationQueue = dispatch_queue_create("enableVibrationQueue", nil);

    self.hidReadSemaphore = dispatch_semaphore_create(0);

    __weak typeof(self) weakSelf = self;
    dispatch_async(self.rumbleQueue, ^{
        [weakSelf runRumbleLoop];
    });

    IOHIDDeviceRef device = [self getFirstDevice];
    if (device != nil) {
        if (isNintendo(device)) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), self.enableVibrationQueue, ^{
                if (![self setVibrationEnabled:1]) {
                    NSLog(@"Couldn't enable vibration");
                }
            });
        }
    }
}

- (void)tearDownHidManager {
    // Ensure we're on the main thread for RunLoop operations
    if (![NSThread isMainThread]) {
        dispatch_sync(dispatch_get_main_queue(), ^{
            [self tearDownHidManagerOnMainThread];
        });
    } else {
        [self tearDownHidManagerOnMainThread];
    }
}

/**
 * Removes HID and touchpad preference observers, stops timers and closes devices on main.
 * Controller delivery must be disabled before teardown to release remote touch/mouse state.
 */
- (void)tearDownHidManagerOnMainThread {
    [self.gamepadMenuTimer invalidate];
    self.gamepadMenuTimer = nil;
    self.gamepadMenuPressed = NO;
    self.controller.menuGesture = (ControllerMenuGesture){0};
    [self tearDownCoreHIDMouseDriver];

    [[NSNotificationCenter defaultCenter] removeObserver:self.touchpadSettingsObserver];
    self.touchpadSettingsObserver = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self.mouseConnectObserver];
    [[NSNotificationCenter defaultCenter] removeObserver:self.mouseDisconnectObserver];
    self.mouseConnectObserver = nil;
    self.mouseDisconnectObserver = nil;

    for (GCMouse *mouse in GCMouse.mice) {
        [self unregisterMouseCallbacks:mouse];
    }

    if (self.displayLink != NULL) {
        CVDisplayLinkStop(self.displayLink);
        CVDisplayLinkRelease(self.displayLink);
        self.displayLink = NULL;
    }

    self.closeRumble = YES;
    self.isRumbleTimer = NO;
    dispatch_semaphore_signal(self.rumbleSemaphore);

    self.rumbleQueue = nil;

    if (self.hidManager != NULL) {
        IOHIDManagerUnscheduleFromRunLoop(self.hidManager, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
        IOHIDManagerClose(self.hidManager, kIOHIDOptionsTypeNone);
        CFRelease(self.hidManager);
        self.hidManager = NULL;
    }
}


@end
