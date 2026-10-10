//
//  MLPrecisionTouchpad.m
//  Moonlight for macOS
//

#import "MLPrecisionTouchpad.h"
#import "Logger.h"

// Pointer and click events derived from a touch arrive a little after the touch itself.
#define MLTouchpadLingerMs 150
// Android's defaults; used when the reported pad size is implausible.
#define MLTouchpadFallbackWidthMm 92
#define MLTouchpadFallbackHeightMm 54
#define MLTouchpadMinMm 40
#define MLTouchpadMaxMm 200

#pragma mark - Shared wire helpers

BOOL MLTouchpadHostSupport(uint32_t featureFlags, BOOL *useFrames) {
    BOOL frames = (featureFlags & LI_FF_TOUCHPAD_FRAME_EVENTS) != 0;
    if (useFrames != NULL) {
        *useFrames = frames;
    }
    return frames || (featureFlags & LI_FF_TOUCHPAD_EVENTS) != 0;
}

int MLTouchpadSendFrame(PML_INPUT_STREAM_CONTEXT ctx, const MLTouchpadFrame *frame, BOOL useFrames) {
    if (useFrames) {
        return LiSendTouchpadFrameEventCtx(ctx, frame->count, frame->types, frame->ids, frame->x, frame->y,
                                           frame->pressure, LI_ROT_UNKNOWN, frame->widthMm, frame->heightMm,
                                           frame->buttonState);
    }
    int result = 0;
    for (uint8_t i = 0; i < frame->count && result == 0; i++) {
        result = LiSendTouchpadEventCtx(ctx, frame->types[i], frame->ids[i], frame->x[i], frame->y[i],
                                        frame->pressure[i], 0.0f, 0.0f, LI_ROT_UNKNOWN,
                                        frame->widthMm, frame->heightMm, frame->buttonState);
    }
    return result;
}

int MLTouchpadSendCancelAll(PML_INPUT_STREAM_CONTEXT ctx, uint16_t widthMm, uint16_t heightMm) {
    return LiSendTouchpadEventCtx(ctx, LI_TOUCH_EVENT_CANCEL_ALL, 0, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f,
                                  LI_ROT_UNKNOWN, widthMm, heightMm, 0);
}

static NSString *MLPrecisionTouchpadModeName(MLPrecisionTouchpadMode mode) {
    switch (mode) {
        case MLPrecisionTouchpadModeBlock: return @"block";
        case MLPrecisionTouchpadModeBoth: return @"both";
        case MLPrecisionTouchpadModeOff: break;
    }
    return @"off";
}

@implementation MLPrecisionTouchpad {
    NSMutableDictionary<id, NSNumber *> *_pointerIds;
    // Last known position of each live pointer id, used for button-only frames.
    float _lastX[MLTouchpadMaxContacts];
    float _lastY[MLTouchpadMaxContacts];
    // Slot is taken (finger on the pad, or leaving in the event being processed).
    BOOL _pointerLive[MLTouchpadMaxContacts];
    // The host knows about this contact.
    BOOL _pointerSent[MLTouchpadMaxContacts];
    uint16_t _widthMm;
    uint16_t _heightMm;
    // Fingers on the pad, whether or not the host sees them.
    int _liveContacts;
    // The host is receiving this gesture's contacts, so the Mac pointer path stays quiet.
    BOOL _sessionActive;
    uint64_t _lastActivityMs;
    uint32_t _consumedButtons;
    // Buttons that went down on the normal pointer path (single finger in "both" mode).
    uint32_t _localButtons;
    BOOL _physicalButtonDown;
    BOOL _supportKnown;
    BOOL _useFrames;
    BOOL _supported;
    BOOL _scrollSequenceSuppressed;
    uint64_t _lastSendErrorLogMs;
    MLPrecisionTouchpadMode _mode;
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

- (MLPrecisionTouchpadMode)mode {
    @synchronized (self) {
        return _mode;
    }
}

- (void)setMode:(MLPrecisionTouchpadMode)mode {
    @synchronized (self) {
        if (_mode == mode) {
            return;
        }
        _mode = mode;
    }
    Log(LOG_I, @"[touchpad] trackpad mode changed to %@", MLPrecisionTouchpadModeName(mode));
    [self reset];
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
    _supported = MLTouchpadHostSupport(flags, &_useFrames);
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
        if (_mode == MLPrecisionTouchpadModeOff || ![self refreshSupportLocked]) {
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

        // Follow every finger first; whether the host sees them is decided afterwards.
        int endedPointers[MLTouchpadMaxContacts];
        uint8_t endedTypes[MLTouchpadMaxContacts];
        int endedCount = 0;
        for (NSTouch *touch in ups) {
            NSNumber *mapped = _pointerIds[touch.identity];
            if (mapped == nil || endedCount >= MLTouchpadMaxContacts) {
                continue;
            }
            [_pointerIds removeObjectForKey:touch.identity];
            if (_liveContacts > 0) {
                _liveContacts -= 1;
            }
            endedPointers[endedCount] = mapped.intValue;
            endedTypes[endedCount] = (touch.phase & NSTouchPhaseCancelled) ? LI_TOUCH_EVENT_CANCEL : LI_TOUCH_EVENT_UP;
            endedCount += 1;
        }
        for (NSTouch *touch in downs) {
            [self trackTouchLocked:touch];
        }
        for (NSTouch *touch in moves) {
            [self trackTouchLocked:touch];
        }

        [self updateSessionLocked];

        if (_sessionActive || endedCount > 0) {
            [self fillFrameLocked:&frame endedPointers:endedPointers endedTypes:endedTypes endedCount:endedCount];
        }
        // Slots of the fingers that just left can be reused from the next event on.
        for (int i = 0; i < endedCount; i++) {
            _pointerLive[endedPointers[i]] = NO;
            _pointerSent[endedPointers[i]] = NO;
        }

        if (_liveContacts == 0 && _sessionActive) {
            _sessionActive = NO;
            _lastActivityMs = LiGetMillis();
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

// Caller holds the lock. Maps the touch to a pointer id (introducing it when new) and remembers its position.
- (void)trackTouchLocked:(NSTouch *)touch {
    id identity = touch.identity;
    NSNumber *mapped = _pointerIds[identity];
    int pointerId = -1;
    if (mapped != nil) {
        pointerId = mapped.intValue;
    } else {
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
        _pointerSent[pointerId] = NO;
        _liveContacts += 1;
    }

    NSPoint position = touch.normalizedPosition;
    // AppKit's origin is the bottom left; the host expects the top left.
    _lastX[pointerId] = (float)MIN(MAX(position.x, 0.0), 1.0);
    _lastY[pointerId] = (float)MIN(MAX(1.0 - position.y, 0.0), 1.0);
}

// Caller holds the lock. Decides when the host starts receiving the gesture.
- (void)updateSessionLocked {
    if (_sessionActive || _liveContacts == 0) {
        return;
    }
    if (_mode == MLPrecisionTouchpadModeBlock) {
        _sessionActive = YES;
    } else if (_mode == MLPrecisionTouchpadModeBoth && _liveContacts >= 2 && _localButtons == 0) {
        // A second finger turns the gesture over to Windows. With a button held on the normal path
        // (dragging with a second finger) the gesture stays local so the drag keeps working.
        _sessionActive = YES;
    }
}

// Caller holds the lock. New contacts first, then the ones already down, then the ones leaving.
- (void)fillFrameLocked:(MLTouchpadFrame *)frame
          endedPointers:(const int *)endedPointers
             endedTypes:(const uint8_t *)endedTypes
             endedCount:(int)endedCount {
    BOOL introduced[MLTouchpadMaxContacts] = {NO};
    if (_sessionActive) {
        for (int pid = 0; pid < MLTouchpadMaxContacts; pid++) {
            if (_pointerLive[pid] && !_pointerSent[pid] && ![self isEndedPointer:pid in:endedPointers count:endedCount]) {
                [self appendContact:frame type:LI_TOUCH_EVENT_DOWN pointerId:pid];
                _pointerSent[pid] = YES;
                introduced[pid] = YES;
            }
        }
        for (int pid = 0; pid < MLTouchpadMaxContacts; pid++) {
            if (_pointerLive[pid] && _pointerSent[pid] && !introduced[pid] &&
                ![self isEndedPointer:pid in:endedPointers count:endedCount]) {
                [self appendContact:frame type:LI_TOUCH_EVENT_MOVE pointerId:pid];
            }
        }
    }
    for (int i = 0; i < endedCount; i++) {
        int pid = endedPointers[i];
        if (_pointerSent[pid]) {
            [self appendContact:frame type:endedTypes[i] pointerId:pid];
        }
    }
}

- (BOOL)isEndedPointer:(int)pointerId in:(const int *)ended count:(int)count {
    for (int i = 0; i < count; i++) {
        if (ended[i] == pointerId) {
            return YES;
        }
    }
    return NO;
}

- (void)appendContact:(MLTouchpadFrame *)frame type:(uint8_t)type pointerId:(int)pointerId {
    if (frame->count >= MLTouchpadMaxContacts) {
        return;
    }
    int slot = frame->count;
    frame->types[slot] = type;
    frame->ids[slot] = (uint32_t)pointerId;
    frame->x[slot] = _lastX[pointerId];
    frame->y[slot] = _lastY[pointerId];
    frame->pressure[slot] = 1.0f;
    frame->count += 1;
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
        int result = MLTouchpadSendFrame(ctx, &frame, useFrames);
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
    return _mode != MLPrecisionTouchpadModeOff && _supported;
}

// Caller holds the lock. YES while the host is being driven by the trackpad (or just was).
- (BOOL)hostDrivenLocked {
    return _sessionActive || (LiGetMillis() - _lastActivityMs) < MLTouchpadLingerMs;
}

- (BOOL)shouldSuppressPointerMotion {
    @synchronized (self) {
        if (![self engagedLocked]) {
            return NO;
        }
        return [self hostDrivenLocked];
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
            BOOL physical = _sessionActive && _liveContacts > 0;
            BOOL tapLike = !_sessionActive && (LiGetMillis() - _lastActivityMs) < MLTouchpadLingerMs;
            if (!physical && !tapLike) {
                // A single finger in "both" mode: an ordinary Mac click that Windows sees as a mouse button.
                _localButtons |= bit;
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
            _localButtons &= ~bit;
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
        if (_pointerLive[candidate] && _pointerSent[candidate]) {
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
        BOOL touchDriven = [self hostDrivenLocked];
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
    MLTouchpadFrame cancel;
    memset(&cancel, 0, sizeof(cancel));
    BOOL needsCancel = NO;
    BOOL useFrames = NO;

    @synchronized (self) {
        for (int i = 0; i < MLTouchpadMaxContacts; i++) {
            if (_pointerSent[i]) {
                [self appendContact:&cancel type:LI_TOUCH_EVENT_CANCEL pointerId:i];
            }
        }
        needsCancel = cancel.count > 0 || _physicalButtonDown;
        useFrames = _useFrames;
        cancel.widthMm = _widthMm;
        cancel.heightMm = _heightMm;
        [_pointerIds removeAllObjects];
        memset(_pointerLive, 0, sizeof(_pointerLive));
        memset(_pointerSent, 0, sizeof(_pointerSent));
        _liveContacts = 0;
        _sessionActive = NO;
        _consumedButtons = 0;
        _localButtons = 0;
        _physicalButtonDown = NO;
        _scrollSequenceSuppressed = NO;
        _lastActivityMs = 0;
        // Capabilities are looked up again after a reconnect.
        _supportKnown = NO;
        _supported = NO;
    }

    if (!needsCancel) {
        return;
    }
    void (^dispatch)(void (^)(PML_INPUT_STREAM_CONTEXT)) = self.dispatchHandler;
    if (dispatch == nil) {
        return;
    }
    dispatch(^(PML_INPUT_STREAM_CONTEXT ctx) {
        // Frame-only hosts reject the single-event cancel-all, so release the known contacts in a frame.
        int result = useFrames ? MLTouchpadSendFrame(ctx, &cancel, YES)
                               : MLTouchpadSendCancelAll(ctx, cancel.widthMm, cancel.heightMm);
        if (result != 0) {
            Log(LOG_D, @"[touchpad] cancel not sent result=%d", result);
        }
    });
}

@end
