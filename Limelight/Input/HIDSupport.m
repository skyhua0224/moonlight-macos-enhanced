//
//  HIDSupport.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 26/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//
#import "HIDSupport_Internal.h"

#import <IOKit/hid/IOHIDElement.h>


NSString *const HIDMouseModeToggledNotification = @"HIDMouseModeToggledNotification";
NSString *const HIDGamepadQuitNotification = @"HIDGamepadQuitNotification";


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

- (void)setInputContext:(void *)inputContext {
    _inputContext = inputContext;
    [self syncScrollTraceDiagnosticsPreferenceToInputContext];
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

- (instancetype)init:(TemporaryHost *)host {
    self = [super init];
    if (self) {
        self.host = host;
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
    [self tearDownCoreHIDMouseDriver];
    NSLog(@"HIDSupport dealloc");
}


- (void)sendControllerEvent {
    if (self.shouldSendInputEvents) {
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

    BOOL pressed = (event.modifierFlags & modifierFlag) != 0;
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
    self.coreHIDMouseDriver.requestsListenAccessIfNeeded = self.useCoreHIDMouse;
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

void myHIDReportCallback (
                          void * _Nullable        context,
                          IOReturn                result,
                          void * _Nullable        sender,
                          IOHIDReportType         type,
                          uint32_t                reportID,
                          uint8_t *               report,
                          CFIndex                 reportLength) {
    HIDSupport *self = (__bridge HIDSupport *)context;
    
    IOHIDDeviceRef device = (IOHIDDeviceRef)sender;
    if (!isPlayStation(device) && !isNintendo(device)) {
        return;
    };
    
    if (isPS4(device)) {
        PS4StatePacket_t *state = (PS4StatePacket_t *)report;
        switch (report[0]) {
            case k_EPS4ReportIdUsbState:
                state = (PS4StatePacket_t *)(report + 1);
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
                if (report[1] & 0x80) {
                    state = (PS4StatePacket_t *)(report + 3);
                }
                break;
            default:
                NSLog(@"Unknown PS4 packet: 0x%hhu", report[0]);
                break;
        }
                
        
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
        
        self.controller.lastLeftTrigger = state->ucTriggerLeft;
        self.controller.lastRightTrigger = state->ucTriggerRight;

        self.controller.lastLeftStickX = (state->ucLeftJoystickX - 128) * 255 + 1;
        self.controller.lastLeftStickY = (state->ucLeftJoystickY - 128) * -255;
        self.controller.lastRightStickX = (state->ucRightJoystickX - 128) * 255 + 1;
        self.controller.lastRightStickY = (state->ucRightJoystickY - 128) * -255;
        
        if (self.controllerDriver == 0) {

            if (self.lastPS4State.rgucButtonsHatAndCounter[0] != state->rgucButtonsHatAndCounter[0] ||
                self.lastPS4State.rgucButtonsHatAndCounter[1] != state->rgucButtonsHatAndCounter[1] ||
                self.lastPS4State.rgucButtonsHatAndCounter[2] != state->rgucButtonsHatAndCounter[2] ||
                self.lastPS4State.ucTriggerLeft != state->ucTriggerLeft ||
                self.lastPS4State.ucTriggerRight != state->ucTriggerRight ||
                self.lastPS4State.ucLeftJoystickX != state->ucLeftJoystickX ||
                self.lastPS4State.ucLeftJoystickY != state->ucLeftJoystickY ||
                self.lastPS4State.ucRightJoystickX != state->ucRightJoystickX ||
                self.lastPS4State.ucRightJoystickY != state->ucRightJoystickY ||
                0)
            {
                [self sendControllerEvent];
                self.lastPS4State = *state;
            }
        }
    } else if (isPS5(device)) {
        PS5StatePacket_t *state = (PS5StatePacket_t *)report;
        switch (report[0]) {
            case k_EPS5ReportIdState:
                state = (PS5StatePacket_t *)(report + 1);
                self.isPS5Bluetooth = reportLength == 10;
                break;
            case k_EPS5ReportIdBluetoothState:
                state = (PS5StatePacket_t *)(report + 2);
                self.isPS5Bluetooth = YES;
                break;
            default:
                NSLog(@"Unknown PS5 packet: 0x%hhu", report[0]);
                break;
        }
        
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
        
        self.controller.lastLeftTrigger = state->ucTriggerLeft;
        self.controller.lastRightTrigger = state->ucTriggerRight;

        self.controller.lastLeftStickX = (state->ucLeftJoystickX - 128) * 255 + 1;
        self.controller.lastLeftStickY = (state->ucLeftJoystickY - 128) * -255;
        self.controller.lastRightStickX = (state->ucRightJoystickX - 128) * 255 + 1;
        self.controller.lastRightStickY = (state->ucRightJoystickY - 128) * -255;
        
        if (self.controllerDriver == 0) {

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

void myHIDDeviceMatchingCallback(void * _Nullable        context,
                                IOReturn                result,
                                void * _Nullable        sender,
                                IOHIDDeviceRef          device) {
    HIDSupport *self = (__bridge HIDSupport *)context;

    [self rumbleSync];
}

void myHIDDeviceRemovalCallback(void * _Nullable        context,
                                IOReturn                result,
                                void * _Nullable        sender,
                                IOHIDDeviceRef          device) {
    HIDSupport *self = (__bridge HIDSupport *)context;

    if (self.controllerDriver == 0) {
        self.controller.lastButtonFlags = 0;
        self.controller.lastLeftTrigger = 0;
        self.controller.lastRightTrigger = 0;
        self.controller.lastLeftStickX = 0;
        self.controller.lastLeftStickY = 0;
        self.controller.lastRightStickX = 0;
        self.controller.lastRightStickY = 0;
        
        [self sendControllerEvent];
    }
}


- (void)updateButtonFlags:(int)flag state:(BOOL)set {
    // Mouse Mode Toggle Logic (Long Press Start)
    if (flag == PLAY_FLAG) {
        if (set) {
            if (self.controller.startButtonDownTime == nil) {
                self.controller.startButtonDownTime = [NSDate date];
            }
        } else {
            // Released
            if (self.controller.startButtonDownTime != nil) {
                if ([self.controller.startButtonDownTime timeIntervalSinceNow] < -1.0) {
                    // Toggle
                    self.controller.isMouseMode = !self.controller.isMouseMode;
                    
                    // Notify UI
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [[NSNotificationCenter defaultCenter] postNotificationName:HIDMouseModeToggledNotification object:nil userInfo:@{@"enabled": @(self.controller.isMouseMode)}];
                    });
                    
                    // Rumble
                    [self rumbleLowFreqMotor:0xFFFF highFreqMotor:0xFFFF];
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        [self rumbleLowFreqMotor:0 highFreqMotor:0];
                    });
                }
                self.controller.startButtonDownTime = nil;
            }
        }
    }
    
    // Mouse Click Logic
    if (self.controller.isMouseMode) {
        if (flag == A_FLAG) {
            // Left Click
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

- (void)tearDownHidManagerOnMainThread {
    [self tearDownCoreHIDMouseDriver];

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
