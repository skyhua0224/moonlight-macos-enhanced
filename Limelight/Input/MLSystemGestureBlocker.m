//
//  MLSystemGestureBlocker.m
//  Moonlight for macOS
//

#import "MLSystemGestureBlocker.h"
#import "Logger.h"
#import <ApplicationServices/ApplicationServices.h>

// CGEventType 30 is the Dock control (dock swipe) event WindowServer/the trackpad driver emits
// for Mission Control, App Exposé, Spaces swipes and the Launchpad/Show Desktop pinches. It is
// private, so it has no kCGEvent constant. Touch data reaches AppKit as type 29 (gesture)
// events, which this tap deliberately does not subscribe to.
static const CGEventType MLCGEventTypeDockControl = (CGEventType)30;

// Private CGEvent field holding the HID event subtype; only read for the first-drop diagnostic.
static const CGEventField MLCGEventFieldGestureSubtype = (CGEventField)110;

static const CFTimeInterval MLGestureDropLogIntervalSeconds = 2.0;

typedef struct {
    CFMachPortRef tap;
    uint64_t droppedTotal;
    uint64_t droppedSinceLog;
    uint64_t reenabled;
    CFTimeInterval lastLogTime;
    BOOL loggedFirstDrop;
} MLGestureTapState;

static CGEventRef MLSystemGestureTapCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *userInfo) {
    (void)proxy;
    MLGestureTapState *state = (MLGestureTapState *)userInfo;
    if (state == NULL) {
        return event;
    }

    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        state->reenabled++;
        if (state->tap != NULL) {
            CGEventTapEnable(state->tap, true);
        }
        Log(LOG_W, @"[gesture] block tap was disabled by %@, re-enabled (count=%llu)",
            type == kCGEventTapDisabledByTimeout ? @"timeout" : @"user input", state->reenabled);
        return event;
    }

    if (type != MLCGEventTypeDockControl) {
        return event;
    }

    state->droppedTotal++;
    state->droppedSinceLog++;
    if (!state->loggedFirstDrop) {
        state->loggedFirstDrop = YES;
        Log(LOG_I, @"[gesture] first system gesture event dropped (type=%d subtype=%lld)",
            (int)type, CGEventGetIntegerValueField(event, MLCGEventFieldGestureSubtype));
    }
    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (now - state->lastLogTime >= MLGestureDropLogIntervalSeconds) {
        // A gesture produces dozens of events per second; summarize instead of logging each.
        Log(LOG_D, @"[gesture] dropped %llu system gesture events (total=%llu)", state->droppedSinceLog, state->droppedTotal);
        state->droppedSinceLog = 0;
        state->lastLogTime = now;
    }
    return NULL;
}

@implementation MLSystemGestureBlocker {
    MLGestureTapState *_state;
    CFRunLoopSourceRef _source;
}

+ (BOOL)isAccessibilityTrusted {
    return AXIsProcessTrusted();
}

+ (BOOL)requestAccessibilityPermission {
    NSDictionary *options = @{ (__bridge NSString *)kAXTrustedCheckOptionPrompt : @YES };
    return AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
}

+ (void)openAccessibilitySettings {
    NSURL *url = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"];
    if (url == nil || ![[NSWorkspace sharedWorkspace] openURL:url]) {
        [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security"]];
    }
}

- (BOOL)installed {
    return _state != NULL;
}

- (BOOL)installWithReason:(NSString *)reason {
    if (_state != NULL) {
        return YES;
    }
    BOOL trusted = [MLSystemGestureBlocker isAccessibilityTrusted];
    if (!trusted) {
        Log(LOG_I, @"[gesture] block tap not installed reason=%@ accessibility=0", reason);
        return NO;
    }

    MLGestureTapState *state = calloc(1, sizeof(MLGestureTapState));
    if (state == NULL) {
        return NO;
    }
    // Active tap at the HID entry point, first in line, subscribed to the Dock control type only.
    CFMachPortRef tap = CGEventTapCreate(kCGHIDEventTap,
                                         kCGHeadInsertEventTap,
                                         kCGEventTapOptionDefault,
                                         CGEventMaskBit(MLCGEventTypeDockControl),
                                         MLSystemGestureTapCallback,
                                         state);
    if (tap == NULL) {
        free(state);
        Log(LOG_W, @"[gesture] block tap could not be created reason=%@ accessibility=%d", reason, trusted ? 1 : 0);
        return NO;
    }
    CFRunLoopSourceRef source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0);
    if (source == NULL) {
        CFMachPortInvalidate(tap);
        CFRelease(tap);
        free(state);
        return NO;
    }
    state->tap = tap;
    state->lastLogTime = CFAbsoluteTimeGetCurrent();
    CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
    CGEventTapEnable(tap, true);
    _state = state;
    _source = source;
    Log(LOG_I, @"[gesture] block tap installed reason=%@ accessibility=%d", reason, trusted ? 1 : 0);
    return YES;
}

- (void)removeWithReason:(NSString *)reason {
    MLGestureTapState *state = _state;
    if (state == NULL) {
        return;
    }
    _state = NULL;
    CGEventTapEnable(state->tap, false);
    if (_source != NULL) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), _source, kCFRunLoopCommonModes);
        CFRelease(_source);
        _source = NULL;
    }
    CFMachPortInvalidate(state->tap);
    CFRelease(state->tap);
    Log(LOG_I, @"[gesture] block tap removed reason=%@ accessibility=%d dropped=%llu reenabled=%llu",
        reason, [MLSystemGestureBlocker isAccessibilityTrusted] ? 1 : 0, state->droppedTotal, state->reenabled);
    free(state);
}

- (void)dealloc {
    [self removeWithReason:@"dealloc"];
}

@end
