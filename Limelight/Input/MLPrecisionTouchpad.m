//
//  MLPrecisionTouchpad.m
//  Moonlight for macOS
//

#import "MLPrecisionTouchpad.h"
#import "Logger.h"

#define MLTouchpadMaxContacts 5
// Pointer and click events derived from a touch arrive a little after the touch itself.
#define MLTouchpadLingerMs 150
// Android's defaults; used when the reported pad size is implausible.
#define MLTouchpadFallbackWidthMm 92
#define MLTouchpadFallbackHeightMm 54
#define MLTouchpadMinMm 40
#define MLTouchpadMaxMm 200

typedef struct {
    uint8_t count;
    uint8_t types[MLTouchpadMaxContacts];
    uint32_t ids[MLTouchpadMaxContacts];
    float x[MLTouchpadMaxContacts];
    float y[MLTouchpadMaxContacts];
    float pressure[MLTouchpadMaxContacts];
    uint16_t widthMm;
    uint16_t heightMm;
    uint8_t buttonState;
} MLTouchpadFrame;

@implementation MLPrecisionTouchpad {
    NSMutableDictionary<id, NSNumber *> *_pointerIds;
    // Last known position of each live pointer id, used for button-only frames.
    float _lastX[MLTouchpadMaxContacts];
    float _lastY[MLTouchpadMaxContacts];
    BOOL _pointerLive[MLTouchpadMaxContacts];
    uint16_t _widthMm;
    uint16_t _heightMm;
    int _liveContacts;
    uint64_t _lastActivityMs;
    uint32_t _consumedButtons;
    BOOL _physicalButtonDown;
    BOOL _supportKnown;
    BOOL _useFrames;
    BOOL _supported;
    BOOL _scrollSequenceSuppressed;
    uint64_t _lastSendErrorLogMs;
    BOOL _enabled;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _pointerIds = [NSMutableDictionary dictionary];
        _widthMm = MLTouchpadFallbackWidthMm;
        _heightMm = MLTouchpadFallbackHeightMm;
    }
    return self;
}

- (BOOL)enabled {
    @synchronized (self) {
        return _enabled;
    }
}

- (void)setEnabled:(BOOL)enabled {
    BOOL needsReset = NO;
    @synchronized (self) {
        if (_enabled == enabled) {
            return;
        }
        _enabled = enabled;
        if (!enabled) {
            needsReset = YES;
        }
    }
    Log(LOG_I, @"[touchpad] precision touchpad %@", enabled ? @"enabled" : @"disabled");
    if (needsReset) {
        [self reset];
    }
}

#pragma mark - Support detection

// Caller holds the lock. Returns whether contacts should be sent to the host.
- (BOOL)refreshSupportLocked {
    if (_supportKnown) {
        return _supported;
    }
    uint32_t flags = self.featureFlagsProvider ? self.featureFlagsProvider() : 0;
    if (flags == 0) {
        // Host flags are not available yet; try again on the next touch.
        return NO;
    }
    _supportKnown = YES;
    _useFrames = (flags & LI_FF_TOUCHPAD_FRAME_EVENTS) != 0;
    _supported = _useFrames || (flags & LI_FF_TOUCHPAD_EVENTS) != 0;
    if (_supported) {
        Log(LOG_I, @"[touchpad] host supports precision touchpad (flags=0x%x, %@)",
            flags, _useFrames ? @"frame events" : @"single contact events");
    } else {
        Log(LOG_W, @"[touchpad] host does not advertise precision touchpad (flags=0x%x), using normal pointer input", flags);
    }
    return _supported;
}

#pragma mark - Touches

- (void)handleTouchesEvent:(NSEvent *)event inView:(NSView *)view {
    MLTouchpadFrame frame;
    memset(&frame, 0, sizeof(frame));
    BOOL send = NO;

    @synchronized (self) {
        if (!_enabled || ![self refreshSupportLocked]) {
            return;
        }

        NSSet<NSTouch *> *touches = [event touchesMatchingPhase:NSTouchPhaseAny inView:view];
        NSMutableArray<NSTouch *> *moves = [NSMutableArray array];
        NSMutableArray<NSTouch *> *downs = [NSMutableArray array];
        NSMutableArray<NSTouch *> *ups = [NSMutableArray array];
        BOOL changed = NO;

        for (NSTouch *touch in touches) {
            if (touch.type != NSTouchTypeIndirect) {
                continue;
            }
            NSSize deviceSize = touch.deviceSize;
            // Magic Mouse touch surfaces are taller than wide; only pad-shaped devices are touchpads.
            if (deviceSize.width <= 0 || deviceSize.height <= 0 || deviceSize.width < deviceSize.height) {
                continue;
            }
            _widthMm = [self millimetersFromPoints:deviceSize.width fallback:MLTouchpadFallbackWidthMm];
            _heightMm = [self millimetersFromPoints:deviceSize.height fallback:MLTouchpadFallbackHeightMm];

            if (touch.phase & NSTouchPhaseBegan) {
                [downs addObject:touch];
                changed = YES;
            } else if (touch.phase & (NSTouchPhaseEnded | NSTouchPhaseCancelled)) {
                [ups addObject:touch];
                changed = YES;
            } else if (touch.phase & NSTouchPhaseMoved) {
                [moves addObject:touch];
                changed = YES;
            } else if (touch.phase & NSTouchPhaseStationary) {
                [moves addObject:touch];
            }
        }

        if (!changed) {
            return;
        }

        // New contacts first, then the ones already down, then the ones leaving.
        for (NSTouch *touch in downs) {
            [self appendTouch:touch type:LI_TOUCH_EVENT_DOWN toFrame:&frame];
        }
        for (NSTouch *touch in moves) {
            [self appendTouch:touch type:LI_TOUCH_EVENT_MOVE toFrame:&frame];
        }
        for (NSTouch *touch in ups) {
            uint8_t type = (touch.phase & NSTouchPhaseCancelled) ? LI_TOUCH_EVENT_CANCEL : LI_TOUCH_EVENT_UP;
            [self appendTouch:touch type:type toFrame:&frame];
        }

        if (frame.count == 0) {
            return;
        }
        frame.widthMm = _widthMm;
        frame.heightMm = _heightMm;
        frame.buttonState = _physicalButtonDown ? LI_TOUCHPAD_BUTTON_PRIMARY : 0;
        _lastActivityMs = LiGetMillis();
        send = YES;
    }

    if (send) {
        [self sendFrame:frame];
    }
}

- (uint16_t)millimetersFromPoints:(CGFloat)points fallback:(uint16_t)fallback {
    // NSTouch.deviceSize is in points, 72 per inch.
    CGFloat mm = points * 25.4 / 72.0;
    if (!isfinite(mm) || mm < MLTouchpadMinMm || mm > MLTouchpadMaxMm) {
        return fallback;
    }
    return (uint16_t)lround(mm);
}

// Caller holds the lock.
- (void)appendTouch:(NSTouch *)touch type:(uint8_t)type toFrame:(MLTouchpadFrame *)frame {
    if (frame->count >= MLTouchpadMaxContacts) {
        return;
    }

    id identity = touch.identity;
    NSNumber *mapped = _pointerIds[identity];
    int pointerId = -1;
    if (mapped != nil) {
        pointerId = mapped.intValue;
    } else if (type != LI_TOUCH_EVENT_UP && type != LI_TOUCH_EVENT_CANCEL) {
        for (int candidate = 0; candidate < MLTouchpadMaxContacts; candidate++) {
            if (!_pointerLive[candidate]) {
                pointerId = candidate;
                break;
            }
        }
        if (pointerId < 0) {
            return;
        }
        _pointerIds[identity] = @(pointerId);
        _pointerLive[pointerId] = YES;
        _liveContacts += 1;
        if (type == LI_TOUCH_EVENT_MOVE) {
            // A contact we never saw begin (for example after a reset): introduce it.
            type = LI_TOUCH_EVENT_DOWN;
        }
    } else {
        return;
    }

    NSPoint position = touch.normalizedPosition;
    // AppKit's origin is the bottom left; the host expects the top left.
    float x = (float)MIN(MAX(position.x, 0.0), 1.0);
    float y = (float)MIN(MAX(1.0 - position.y, 0.0), 1.0);

    int slot = frame->count;
    frame->types[slot] = type;
    frame->ids[slot] = (uint32_t)pointerId;
    frame->x[slot] = x;
    frame->y[slot] = y;
    frame->pressure[slot] = 1.0f;
    frame->count += 1;
    _lastX[pointerId] = x;
    _lastY[pointerId] = y;

    if (type == LI_TOUCH_EVENT_UP || type == LI_TOUCH_EVENT_CANCEL) {
        [_pointerIds removeObjectForKey:identity];
        _pointerLive[pointerId] = NO;
        if (_liveContacts > 0) {
            _liveContacts -= 1;
        }
    }
}

#pragma mark - Sending

- (void)sendFrame:(MLTouchpadFrame)frame {
    BOOL useFrames;
    @synchronized (self) {
        useFrames = _useFrames;
    }
    void (^dispatch)(void (^)(PML_INPUT_STREAM_CONTEXT)) = self.dispatchHandler;
    if (dispatch == nil) {
        return;
    }

    dispatch(^(PML_INPUT_STREAM_CONTEXT ctx) {
        int result = 0;
        if (useFrames) {
            result = LiSendTouchpadFrameEventCtx(ctx, frame.count, frame.types, frame.ids, frame.x, frame.y,
                                                 frame.pressure, LI_ROT_UNKNOWN, frame.widthMm, frame.heightMm,
                                                 frame.buttonState);
        } else {
            for (uint8_t i = 0; i < frame.count && result == 0; i++) {
                result = LiSendTouchpadEventCtx(ctx, frame.types[i], frame.ids[i], frame.x[i], frame.y[i],
                                                frame.pressure[i], 0.0f, 0.0f, LI_ROT_UNKNOWN,
                                                frame.widthMm, frame.heightMm, frame.buttonState);
            }
        }
        if (result != 0) {
            [self noteSendFailure:result];
        }
    });
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
            // The host dropped the capability; fall back to normal pointer input.
            _supported = NO;
        }
    }
    if (log) {
        Log(LOG_W, @"[touchpad] send failed result=%d%@", result,
            result == LI_ERR_UNSUPPORTED ? @" (unsupported, falling back to normal pointer input)" : @"");
    }
}

#pragma mark - Pointer, button and scroll coordination

- (BOOL)engagedLocked {
    return _enabled && _supported;
}

- (BOOL)shouldSuppressPointerMotion {
    @synchronized (self) {
        if (![self engagedLocked]) {
            return NO;
        }
        return _liveContacts > 0 || (LiGetMillis() - _lastActivityMs) < MLTouchpadLingerMs;
    }
}

- (BOOL)consumeMouseButton:(int)button pressed:(BOOL)pressed {
    if (button != BUTTON_LEFT && button != BUTTON_RIGHT) {
        return NO;
    }
    uint32_t bit = button == BUTTON_LEFT ? 0x1 : 0x2;
    MLTouchpadFrame frame;
    memset(&frame, 0, sizeof(frame));
    BOOL send = NO;

    @synchronized (self) {
        if (![self engagedLocked]) {
            return NO;
        }

        if (pressed) {
            BOOL physical = _liveContacts > 0;
            BOOL tapLike = !physical && (LiGetMillis() - _lastActivityMs) < MLTouchpadLingerMs;
            if (!physical && !tapLike) {
                return NO;
            }
            _consumedButtons |= bit;
            // A tap click is produced by Windows from the contacts, so it is only swallowed.
            if (physical && !_physicalButtonDown) {
                _physicalButtonDown = YES;
                send = [self fillButtonFrameLocked:&frame];
            }
            return YES;
        }

        if ((_consumedButtons & bit) == 0) {
            return NO;
        }
        _consumedButtons &= ~bit;
        if (_physicalButtonDown && _consumedButtons == 0) {
            _physicalButtonDown = NO;
            send = [self fillButtonFrameLocked:&frame];
        }
    }

    if (send) {
        [self sendFrame:frame];
    }
    return YES;
}

// Caller holds the lock. A button change rides on a contact that is still on the pad.
- (BOOL)fillButtonFrameLocked:(MLTouchpadFrame *)frame {
    int pointerId = -1;
    for (int candidate = 0; candidate < MLTouchpadMaxContacts; candidate++) {
        if (_pointerLive[candidate]) {
            pointerId = candidate;
            break;
        }
    }
    if (pointerId < 0) {
        // The finger already left; the host releases the button with the contact.
        return NO;
    }
    frame->count = 1;
    frame->types[0] = LI_TOUCH_EVENT_BUTTON_ONLY;
    frame->ids[0] = (uint32_t)pointerId;
    frame->x[0] = _lastX[pointerId];
    frame->y[0] = _lastY[pointerId];
    frame->pressure[0] = 1.0f;
    frame->widthMm = _widthMm;
    frame->heightMm = _heightMm;
    frame->buttonState = _physicalButtonDown ? LI_TOUCHPAD_BUTTON_PRIMARY : 0;
    return YES;
}

- (BOOL)shouldSuppressScrollEvent:(NSEvent *)event {
    // Wheel events have no gesture phase; only trackpad (and Magic Mouse) scrolling does.
    if (!event.hasPreciseScrollingDeltas) {
        return NO;
    }
    @synchronized (self) {
        if (![self engagedLocked]) {
            _scrollSequenceSuppressed = NO;
            return NO;
        }

        NSEventPhase phase = event.phase;
        NSEventPhase momentum = event.momentumPhase;
        BOOL touchDriven = _liveContacts > 0 || (LiGetMillis() - _lastActivityMs) < MLTouchpadLingerMs;
        if ((phase & (NSEventPhaseBegan | NSEventPhaseMayBegin)) != 0) {
            _scrollSequenceSuppressed = touchDriven;
        }
        if (!_scrollSequenceSuppressed && touchDriven && phase != NSEventPhaseNone) {
            _scrollSequenceSuppressed = YES;
        }

        BOOL suppress = _scrollSequenceSuppressed;
        // The sequence ends with the momentum phase, or with the gesture when there is no momentum.
        if ((momentum & (NSEventPhaseEnded | NSEventPhaseCancelled)) != 0 ||
            ((phase & (NSEventPhaseEnded | NSEventPhaseCancelled)) != 0 && momentum == NSEventPhaseNone && !touchDriven)) {
            _scrollSequenceSuppressed = NO;
        }
        return suppress;
    }
}

#pragma mark - Reset

- (void)reset {
    BOOL cancel = NO;
    uint16_t widthMm = 0;
    uint16_t heightMm = 0;

    @synchronized (self) {
        cancel = _liveContacts > 0 || _physicalButtonDown;
        widthMm = _widthMm;
        heightMm = _heightMm;
        [_pointerIds removeAllObjects];
        memset(_pointerLive, 0, sizeof(_pointerLive));
        _liveContacts = 0;
        _consumedButtons = 0;
        _physicalButtonDown = NO;
        _scrollSequenceSuppressed = NO;
        _lastActivityMs = 0;
        // Capabilities are looked up again after a reconnect.
        _supportKnown = NO;
        _supported = NO;
    }

    if (!cancel) {
        return;
    }
    void (^dispatch)(void (^)(PML_INPUT_STREAM_CONTEXT)) = self.dispatchHandler;
    if (dispatch == nil) {
        return;
    }
    dispatch(^(PML_INPUT_STREAM_CONTEXT ctx) {
        int result = LiSendTouchpadEventCtx(ctx, LI_TOUCH_EVENT_CANCEL_ALL, 0, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f,
                                            LI_ROT_UNKNOWN, widthMm, heightMm, 0);
        if (result != 0) {
            Log(LOG_D, @"[touchpad] cancel-all not sent result=%d", result);
        }
    });
}

@end
