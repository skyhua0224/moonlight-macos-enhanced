//
//  MLDualSenseTouchpad.m
//  Moonlight for macOS
//

#import "MLDualSenseTouchpad.h"
#import "MLPrecisionTouchpad.h"
#import "Logger.h"

#define MLDualSenseFingers 2
// The host tracks one touchpad, so the controller uses the two lowest contact ids.
#define MLDualSenseFirstPointerId 0
// The DualSense pad is about 62 x 30 mm (1920 x 943 units, the aspect ViGEm uses for a DS4 pad); Windows scales
// pointer travel with the physical size.
#define MLDualSenseWidthMm 62
#define MLDualSenseHeightMm 30

@implementation MLDualSenseTouchpad {
    BOOL _enabled;
    BOOL _supportKnown;
    BOOL _supported;
    BOOL _useFrames;
    // What the controller reports now.
    BOOL _target[MLDualSenseFingers];
    float _x[MLDualSenseFingers];
    float _y[MLDualSenseFingers];
    // What the host has been told.
    BOOL _sent[MLDualSenseFingers];
    BOOL _buttonDown;
    // Only one controller drives the host's touchpad at a time.
    NSInteger _owner;
    BOOL _flushPending;
    BOOL _loggedFirstContact;
    uint64_t _lastSendErrorLogMs;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _owner = -1;
    }
    return self;
}

- (BOOL)enabled {
    @synchronized (self) {
        return _enabled;
    }
}

- (void)setEnabled:(BOOL)enabled {
    @synchronized (self) {
        if (_enabled == enabled) {
            return;
        }
        _enabled = enabled;
    }
    if (!enabled) {
        [self releaseAll];
    }
}

#pragma mark - Support

// Caller holds the lock.
- (BOOL)supportedLocked {
    if (_supportKnown) {
        return _supported;
    }
    PML_INPUT_STREAM_CONTEXT ctx = self.contextProvider ? self.contextProvider() : NULL;
    if (ctx == NULL || ctx->connectionContext == NULL) {
        return NO;
    }
    uint32_t flags = LiGetHostFeatureFlagsCtx(ctx->connectionContext);
    if (flags == 0) {
        // Host flags are not available yet; look again on the next contact.
        return NO;
    }
    _supportKnown = YES;
    _supported = MLTouchpadHostSupport(flags, &_useFrames);
    if (_supported) {
        Log(LOG_I, @"[touchpad] ds5 precision touchpad available (flags=0x%x, %@)",
            flags, _useFrames ? @"frame events" : @"single contact events");
    } else {
        Log(LOG_W, @"[touchpad] ds5 precision touchpad requested but the host does not advertise it (flags=0x%x), using controller touchpad", flags);
    }
    return _supported;
}

- (BOOL)claimsTouchpad {
    @synchronized (self) {
        return _enabled && [self supportedLocked];
    }
}

#pragma mark - Input

- (void)setContact:(NSUInteger)finger active:(BOOL)active x:(float)x y:(float)y player:(NSInteger)player {
    if (finger >= MLDualSenseFingers) {
        return;
    }
    BOOL schedule = NO;
    @synchronized (self) {
        if (!_enabled || ![self supportedLocked]) {
            return;
        }
        if (_owner >= 0 && _owner != player) {
            return;
        }
        if (active) {
            _owner = player;
            // GameController reports -1...1 with y up; the host expects 0...1 with a top-left origin.
            _x[finger] = fminf(1.0f, fmaxf(0.0f, (x + 1.0f) * 0.5f));
            _y[finger] = fminf(1.0f, fmaxf(0.0f, (1.0f - y) * 0.5f));
            if (!_loggedFirstContact) {
                _loggedFirstContact = YES;
                Log(LOG_I, @"[touchpad] ds5 precision first contact: player=%ld finger=%lu raw=(%.3f,%.3f) mapped=(%.3f,%.3f) pad=%dx%dmm %@",
                    (long)player, (unsigned long)finger, x, y, _x[finger], _y[finger],
                    MLDualSenseWidthMm, MLDualSenseHeightMm, _useFrames ? @"frames" : @"single events");
            }
        } else if (!_target[finger] && !_sent[finger]) {
            return;
        }
        // The release position is whatever the pad reset to; the last real position is kept.
        _target[finger] = active;
        schedule = [self scheduleFlushLocked];
    }
    if (schedule) {
        [self scheduleFlush];
    }
}

- (void)setButtonPressed:(BOOL)pressed player:(NSInteger)player {
    BOOL schedule = NO;
    @synchronized (self) {
        if (!_enabled || ![self supportedLocked]) {
            return;
        }
        if (_owner >= 0 && _owner != player) {
            return;
        }
        if (_buttonDown == pressed) {
            return;
        }
        _buttonDown = pressed;
        if (pressed && _owner < 0) {
            _owner = player;
        }
        schedule = [self scheduleFlushLocked];
    }
    if (schedule) {
        [self scheduleFlush];
    }
}

// Caller holds the lock. Returns whether a flush still has to be queued.
- (BOOL)scheduleFlushLocked {
    if (_flushPending) {
        return NO;
    }
    _flushPending = YES;
    return YES;
}

// The controller reports its two fingers in separate callbacks; send them as one frame.
- (void)scheduleFlush {
    __weak MLDualSenseTouchpad *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf flush];
    });
}

- (void)flush {
    MLTouchpadFrame frame;
    memset(&frame, 0, sizeof(frame));
    BOOL useFrames = NO;
    PML_INPUT_STREAM_CONTEXT ctx = self.contextProvider ? self.contextProvider() : NULL;

    @synchronized (self) {
        _flushPending = NO;
        if (ctx == NULL) {
            [self clearLocked];
            return;
        }
        useFrames = _useFrames;
        BOOL introduced[MLDualSenseFingers] = {NO};
        int remaining = 0;
        for (int i = 0; i < MLDualSenseFingers; i++) {
            if (_target[i]) {
                remaining += 1;
            }
        }
        for (int i = 0; i < MLDualSenseFingers; i++) {
            if (_target[i] && !_sent[i]) {
                [self appendLocked:&frame type:LI_TOUCH_EVENT_DOWN finger:i];
                _sent[i] = YES;
                introduced[i] = YES;
            }
        }
        for (int i = 0; i < MLDualSenseFingers; i++) {
            if (_target[i] && _sent[i] && !introduced[i]) {
                [self appendLocked:&frame type:LI_TOUCH_EVENT_MOVE finger:i];
            }
        }
        for (int i = 0; i < MLDualSenseFingers; i++) {
            if (!_target[i] && _sent[i]) {
                [self appendLocked:&frame type:LI_TOUCH_EVENT_UP finger:i];
                _sent[i] = NO;
            }
        }
        // A click only means something while a finger is on the pad; it ends with the last finger.
        frame.buttonState = (_buttonDown && remaining > 0) ? LI_TOUCHPAD_BUTTON_PRIMARY : 0;
        frame.widthMm = MLDualSenseWidthMm;
        frame.heightMm = MLDualSenseHeightMm;
        if (remaining == 0 && !_buttonDown) {
            _owner = -1;
        }
    }

    if (frame.count == 0) {
        return;
    }
    int result = MLTouchpadSendFrame(ctx, &frame, useFrames);
    if (result != 0) {
        [self noteSendFailure:result];
    }
}

// Caller holds the lock.
- (void)appendLocked:(MLTouchpadFrame *)frame type:(uint8_t)type finger:(int)finger {
    int slot = frame->count;
    if (slot >= MLTouchpadMaxContacts) {
        return;
    }
    frame->types[slot] = type;
    frame->ids[slot] = (uint32_t)(MLDualSenseFirstPointerId + finger);
    frame->x[slot] = _x[finger];
    frame->y[slot] = _y[finger];
    frame->pressure[slot] = 1.0f;
    frame->count += 1;
}

// Caller holds the lock.
- (void)clearLocked {
    memset(_target, 0, sizeof(_target));
    memset(_sent, 0, sizeof(_sent));
    _buttonDown = NO;
    _owner = -1;
}

- (void)noteSendFailure:(int)result {
    BOOL log = NO;
    @synchronized (self) {
        uint64_t now = LiGetMillis();
        if (now - _lastSendErrorLogMs > 5000) {
            _lastSendErrorLogMs = now;
            log = YES;
        }
        if (result == LI_ERR_UNSUPPORTED) {
            // The host dropped the capability; the controller touchpad takes over again.
            _supported = NO;
        }
    }
    if (log) {
        Log(LOG_W, @"[touchpad] ds5 precision send failed result=%d%@", result,
            result == LI_ERR_UNSUPPORTED ? @" (unsupported, falling back to controller touchpad)" : @"");
    }
}

#pragma mark - Release

- (void)releasePlayer:(NSInteger)player {
    @synchronized (self) {
        if (_owner != player) {
            return;
        }
    }
    [self releaseAll];
}

- (void)releaseAll {
    MLTouchpadFrame frame;
    memset(&frame, 0, sizeof(frame));
    BOOL useFrames = NO;
    PML_INPUT_STREAM_CONTEXT ctx = self.contextProvider ? self.contextProvider() : NULL;

    @synchronized (self) {
        useFrames = _useFrames;
        for (int i = 0; i < MLDualSenseFingers; i++) {
            if (_sent[i]) {
                [self appendLocked:&frame type:LI_TOUCH_EVENT_CANCEL finger:i];
            }
        }
        frame.widthMm = MLDualSenseWidthMm;
        frame.heightMm = MLDualSenseHeightMm;
        [self clearLocked];
        // Capabilities are looked up again after a reconnect.
        _supportKnown = NO;
        _supported = NO;
    }

    if (frame.count == 0 || ctx == NULL) {
        return;
    }
    int result = MLTouchpadSendFrame(ctx, &frame, useFrames);
    if (result != 0) {
        Log(LOG_D, @"[touchpad] ds5 precision release not sent result=%d", result);
    }
}

@end
