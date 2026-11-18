//
//  HIDSupport+Pointer.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 26/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//
#import "HIDSupport_Internal.h"

static CGFloat const HIDGCMouseRelativeSpeedDivisor = 2.5;
static CGFloat const HIDCoreHIDFreeMouseBaselineScale = 0.75;

// GCMouse instances are shared across streams. A previous support instance may
// finish tearing down after another one has replaced its callbacks.
static NSMapTable<GCMouse *, HIDSupport *> *HIDGCMouseCallbackOwners(void) {
    static NSMapTable<GCMouse *, HIDSupport *> *owners;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        owners = [NSMapTable weakToWeakObjectsMapTable];
    });
    return owners;
}

static inline BOOL HIDAbsoluteMousePayloadForEvent(NSEvent *event,
                                                   BOOL clampToBounds,
                                                   short *hostX,
                                                   short *hostY,
                                                   short *referenceWidth,
                                                   short *referenceHeight) {
    NSPoint viewPoint;
    NSSize referenceSize;
    if (!HIDAbsoluteMouseReferenceForEvent(event, &viewPoint, &referenceSize)) {
        return NO;
    }

    return HIDAbsoluteMousePositionForViewPoint(viewPoint,
                                                referenceSize,
                                                clampToBounds,
                                                hostX,
                                                hostY,
                                                referenceWidth,
                                                referenceHeight);
}

static inline NSPoint HIDClampFreeMousePoint(NSPoint point, NSSize referenceSize) {
    MLFreeMousePoint clamped = MLFreeMouseClampPoint((MLFreeMousePoint){point.x, point.y},
                                                     referenceSize.width, referenceSize.height);
    return NSMakePoint(clamped.x, clamped.y);
}

@implementation HIDSupport (Pointer)

- (void)suppressRelativeMouseMotionForMilliseconds:(uint64_t)durationMs {
    if (durationMs == 0) {
        self.suppressRelativeMouseUntilMs = 0;
        return;
    }
    self.suppressRelativeMouseUntilMs = LiGetMillis() + durationMs;
}

- (void)setFreeMouseVirtualCursorActive:(BOOL)active {
    self.freeMouseVirtualCursorRequestedActive = active;
    if (active) {
        return;
    }

    HIDInvalidateCoreHIDFreeMouseAbsoluteSync(self);
    [self resetFreeMouseVirtualCursorState];
}

- (void)resetFreeMouseVirtualCursorState {
    @synchronized (self.freeMouseVirtualCursorLock) {
        MLFreeMouseVirtualCursorReset([self freeMouseVirtualCursorState]);
        self.freeMouseVirtualCursorReferenceSize = NSZeroSize;
    }
}

- (void)updateFreeMouseVirtualCursorAnchorWithViewPoint:(NSPoint)viewPoint
                                          referenceSize:(NSSize)referenceSize {
    if (!self.freeMouseVirtualCursorRequestedActive) {
        return;
    }

    if (!isfinite(viewPoint.x) || !isfinite(viewPoint.y) ||
        !isfinite(referenceSize.width) || !isfinite(referenceSize.height) ||
        referenceSize.width <= 0.0 || referenceSize.height <= 0.0) {
        return;
    }

    BOOL shouldBlendGain = ![self hasPressedMouseButtons];

    @synchronized (self.freeMouseVirtualCursorLock) {
        MLFreeMouseVirtualCursorAnchor([self freeMouseVirtualCursorState],
                                       (MLFreeMousePoint){viewPoint.x, viewPoint.y},
                                       referenceSize.width, referenceSize.height, shouldBlendGain);
        self.freeMouseVirtualCursorReferenceSize = referenceSize;
    }
}

- (BOOL)reconcileFreeMouseVirtualCursorToViewPoint:(NSPoint)viewPoint
                                     referenceSize:(NSSize)referenceSize
                               correctionThreshold:(CGFloat)correctionThreshold {
    return [self reconcileFreeMouseVirtualCursorToViewPoint:viewPoint
                                              referenceSize:referenceSize
                                        correctionThreshold:correctionThreshold
                                                  driftOut:NULL];
}

- (BOOL)reconcileFreeMouseVirtualCursorToViewPoint:(NSPoint)viewPoint
                                     referenceSize:(NSSize)referenceSize
                               correctionThreshold:(CGFloat)correctionThreshold
                                          driftOut:(double *)driftOut {
    if (!self.freeMouseVirtualCursorRequestedActive) {
        return NO;
    }

    if (!isfinite(viewPoint.x) || !isfinite(viewPoint.y) ||
        !isfinite(referenceSize.width) || !isfinite(referenceSize.height) ||
        referenceSize.width <= 0.0 || referenceSize.height <= 0.0) {
        return NO;
    }

    NSPoint clampedPoint = HIDClampFreeMousePoint(viewPoint, referenceSize);
    BOOL shouldBlendGain = ![self hasPressedMouseButtons];
    BOOL shouldSendCorrection = NO;

    @synchronized (self.freeMouseVirtualCursorLock) {
        shouldSendCorrection = MLFreeMouseVirtualCursorReconcile([self freeMouseVirtualCursorState],
                                                                 (MLFreeMousePoint){viewPoint.x, viewPoint.y},
                                                                 referenceSize.width, referenceSize.height,
                                                                 shouldBlendGain, (double)MAX(0.0, correctionThreshold),
                                                                 driftOut);
        self.freeMouseVirtualCursorReferenceSize = referenceSize;
    }

    if (shouldSendCorrection) {
        [self sendAbsoluteMousePositionForViewPoint:clampedPoint
                                      referenceSize:referenceSize
                                      clampToBounds:YES];
    }

    return shouldSendCorrection;
}

- (BOOL)getFreeMouseVirtualCursorPoint:(NSPoint *)viewPoint
                         referenceSize:(NSSize *)referenceSize {
    BOOL hasAnchor = NO;
    NSPoint currentPoint = NSZeroPoint;
    NSSize currentReferenceSize = NSZeroSize;

    @synchronized (self.freeMouseVirtualCursorLock) {
        MLFreeMouseVirtualCursor *cursor = [self freeMouseVirtualCursorState];
        hasAnchor = cursor->hasAnchor &&
                    self.freeMouseVirtualCursorReferenceSize.width > 0.0 &&
                    self.freeMouseVirtualCursorReferenceSize.height > 0.0;
        if (hasAnchor) {
            currentPoint = NSMakePoint(cursor->point.x, cursor->point.y);
            currentReferenceSize = self.freeMouseVirtualCursorReferenceSize;
        }
    }

    if (!hasAnchor) {
        return NO;
    }

    if (viewPoint != NULL) {
        *viewPoint = currentPoint;
    }
    if (referenceSize != NULL) {
        *referenceSize = currentReferenceSize;
    }
    return YES;
}

- (void)dispatchPendingCoalescedAbsolutePointerPosition {
    __block short hostX = 0;
    __block short hostY = 0;
    __block short referenceWidth = 0;
    __block short referenceHeight = 0;
    __block NSString *source = nil;
    __block BOOL hasPending = NO;

    @synchronized (self.inputDiagnosticsLock) {
        if (self.pendingCoalescedAbsolutePointerValid) {
            hostX = self.pendingCoalescedAbsolutePointerHostX;
            hostY = self.pendingCoalescedAbsolutePointerHostY;
            referenceWidth = self.pendingCoalescedAbsolutePointerReferenceWidth;
            referenceHeight = self.pendingCoalescedAbsolutePointerReferenceHeight;
            source = [self.pendingCoalescedAbsolutePointerSource copy];
            self.pendingCoalescedAbsolutePointerValid = NO;
            hasPending = YES;
        } else {
            self.pendingCoalescedAbsolutePointerDispatch = NO;
        }
    }

    if (!hasPending) {
        return;
    }

    PML_INPUT_STREAM_CONTEXT inputCtx = HIDInputContext(self);
    if (HIDValidateInputContext(inputCtx, "dispatchPendingCoalescedAbsolutePointerPosition") &&
        self.shouldSendInputEvents) {
        if (source.length > 0) {
            [self recordAbsoluteInputDiagnosticsFrom:source
                                                   x:hostX
                                                   y:hostY
                                               width:referenceWidth
                                              height:referenceHeight];
        }
        LiSendMousePositionEventCtx(inputCtx, hostX, hostY, referenceWidth, referenceHeight);
    }

    BOOL shouldScheduleNext = NO;
    @synchronized (self.inputDiagnosticsLock) {
        self.pendingCoalescedAbsolutePointerDispatch = NO;
        if (self.pendingCoalescedAbsolutePointerValid) {
            self.pendingCoalescedAbsolutePointerDispatch = YES;
            shouldScheduleNext = YES;
        }
    }

    if (shouldScheduleNext) {
        PML_CONNECTION_CONTEXT connCtx = inputCtx != NULL ? inputCtx->connectionContext : NULL;
        dispatch_async(self.inputQueue, ^{
            if (connCtx != NULL) {
                LiSetThreadConnectionContext(connCtx);
            }
            [self dispatchPendingCoalescedAbsolutePointerPosition];
        });
    }
}

- (void)sendCoalescedAbsoluteMousePositionForViewPoint:(NSPoint)viewPoint
                                         referenceSize:(NSSize)referenceSize
                                         clampToBounds:(BOOL)clampToBounds
                                             sourceTag:(NSString *)sourceTag {
    if ([self.precisionTouchpad shouldSuppressPointerMotion]) {
        return;
    }

    PML_INPUT_STREAM_CONTEXT inputCtx = HIDInputContext(self);
    if (!HIDValidateInputContext(inputCtx, "sendCoalescedAbsoluteMousePosition")) {
        return;
    }

    short hostX = 0;
    short hostY = 0;
    short referenceWidth = 0;
    short referenceHeight = 0;
    if (!HIDAbsoluteMousePositionForViewPoint(viewPoint,
                                              referenceSize,
                                              clampToBounds,
                                              &hostX,
                                              &hostY,
                                              &referenceWidth,
                                              &referenceHeight)) {
        return;
    }

    BOOL shouldSchedule = NO;
    BOOL isDuplicate = NO;
    @synchronized (self.inputDiagnosticsLock) {
        BOOL matchesLastKnown = hostX == self.lastAbsolutePointerHostX &&
                                hostY == self.lastAbsolutePointerHostY &&
                                referenceWidth == self.lastAbsolutePointerReferenceWidth &&
                                referenceHeight == self.lastAbsolutePointerReferenceHeight;
        BOOL matchesPending = self.pendingCoalescedAbsolutePointerValid &&
                              hostX == self.pendingCoalescedAbsolutePointerHostX &&
                              hostY == self.pendingCoalescedAbsolutePointerHostY &&
                              referenceWidth == self.pendingCoalescedAbsolutePointerReferenceWidth &&
                              referenceHeight == self.pendingCoalescedAbsolutePointerReferenceHeight;
        if (matchesLastKnown || matchesPending) {
            isDuplicate = YES;
            if (self.inputDiagnosticsEnabled) {
                self.inputDiagnosticsAbsoluteDuplicateSkips += 1;
            }
        } else {
            self.lastAbsolutePointerHostX = hostX;
            self.lastAbsolutePointerHostY = hostY;
            self.lastAbsolutePointerReferenceWidth = referenceWidth;
            self.lastAbsolutePointerReferenceHeight = referenceHeight;
            self.lastAbsolutePointerAtMs = LiGetMillis();
            self.lastAbsolutePointerSource = [sourceTag copy];
            self.pendingCoalescedAbsolutePointerHostX = hostX;
            self.pendingCoalescedAbsolutePointerHostY = hostY;
            self.pendingCoalescedAbsolutePointerReferenceWidth = referenceWidth;
            self.pendingCoalescedAbsolutePointerReferenceHeight = referenceHeight;
            self.pendingCoalescedAbsolutePointerSource = [sourceTag copy];
            self.pendingCoalescedAbsolutePointerValid = YES;
            if (!self.pendingCoalescedAbsolutePointerDispatch) {
                self.pendingCoalescedAbsolutePointerDispatch = YES;
                shouldSchedule = YES;
            }
        }
    }

    if (isDuplicate || !shouldSchedule) {
        return;
    }

    PML_CONNECTION_CONTEXT connCtx = inputCtx->connectionContext;
    dispatch_async(self.inputQueue, ^{
        if (connCtx != NULL) {
            LiSetThreadConnectionContext(connCtx);
        }
        [self dispatchPendingCoalescedAbsolutePointerPosition];
    });
}

- (BOOL)dispatchVirtualFreeMouseDeltaX:(double)deltaX
                                deltaY:(double)deltaY
                             sourceTag:(NSString *)sourceTag {
    (void)sourceTag;
    if (!self.freeMouseVirtualCursorRequestedActive ||
        !HIDShouldUseCoreHIDFreeMouseAbsoluteSync(self) ||
        !self.shouldSendInputEvents ||
        !isfinite(deltaX) ||
        !isfinite(deltaY) ||
        (deltaX == 0.0 && deltaY == 0.0)) {
        return NO;
    }

    if ([self.precisionTouchpad shouldSuppressPointerMotion]) {
        // The trackpad is driving the host; report the motion as handled so it is not re-sent as relative motion.
        return YES;
    }

    CGFloat sensitivity = HIDPointerSensitivityForHost(self.host);
    double calibratedSensitivity = sensitivity * HIDCoreHIDFreeMouseBaselineScale;
    double viewDeltaX = deltaX * calibratedSensitivity;
    double viewDeltaY = -deltaY * calibratedSensitivity;

    NSPoint predictedPoint = NSZeroPoint;
    NSSize referenceSize = NSZeroSize;

    @synchronized (self.freeMouseVirtualCursorLock) {
        MLFreeMouseVirtualCursor *cursor = [self freeMouseVirtualCursorState];
        if (!cursor->hasAnchor ||
            self.freeMouseVirtualCursorReferenceSize.width <= 0.0 ||
            self.freeMouseVirtualCursorReferenceSize.height <= 0.0) {
            return NO;
        }

        referenceSize = self.freeMouseVirtualCursorReferenceSize;
        MLFreeMousePoint predicted = MLFreeMouseVirtualCursorAdvance(cursor, viewDeltaX, viewDeltaY,
                                                                     referenceSize.width, referenceSize.height);
        predictedPoint = NSMakePoint(predicted.x, predicted.y);
    }

    [self sendCoalescedAbsoluteMousePositionForViewPoint:predictedPoint
                                           referenceSize:referenceSize
                                           clampToBounds:YES
                                               sourceTag:@"sendAbsoluteMousePosition"];
    return YES;
}

-(void)registerMouseCallbacks:(GCMouse *)mouse API_AVAILABLE(macos(11.0)) {
    NSMapTable<GCMouse *, HIDSupport *> *owners = HIDGCMouseCallbackOwners();
    @synchronized (owners) {
        [owners setObject:self forKey:mouse];
        if (self.useGCMouse) {
            mouse.mouseInput.mouseMovedHandler = ^(GCMouseInput * _Nonnull mouse, float deltaX, float deltaY) {
                self.mouseDeltaX += deltaX;
                self.mouseDeltaY -= deltaY;
            };
        
            mouse.mouseInput.leftButton.pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
                if ([self.precisionTouchpad consumeMouseButton:BUTTON_LEFT pressed:pressed]) {
                    return;
                }
                if (self.directTouchGCMouseButtonGate != nil &&
                    self.directTouchGCMouseButtonGate(BUTTON_LEFT, pressed, NSProcessInfo.processInfo.systemUptime)) {
                    return;
                }
                if (self.shouldSendInputEvents) {
                    PML_INPUT_STREAM_CONTEXT inputCtx = HIDInputContext(self);
                    if (!inputCtx) {
                        return;
                    }
                    LiSendMouseButtonEventCtx(inputCtx, pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE, BUTTON_LEFT);
                }
            };
            mouse.mouseInput.middleButton.pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
                if (self.directTouchGCMouseButtonGate != nil &&
                    self.directTouchGCMouseButtonGate(BUTTON_MIDDLE, pressed, NSProcessInfo.processInfo.systemUptime)) {
                    return;
                }
                if (self.shouldSendInputEvents) {
                    PML_INPUT_STREAM_CONTEXT inputCtx = HIDInputContext(self);
                    if (!inputCtx) {
                        return;
                    }
                    LiSendMouseButtonEventCtx(inputCtx, pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE, BUTTON_MIDDLE);
                }
            };
            mouse.mouseInput.rightButton.pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
                if ([self.precisionTouchpad consumeMouseButton:BUTTON_RIGHT pressed:pressed]) {
                    return;
                }
                if (self.directTouchGCMouseButtonGate != nil &&
                    self.directTouchGCMouseButtonGate(BUTTON_RIGHT, pressed, NSProcessInfo.processInfo.systemUptime)) {
                    return;
                }
                if (self.shouldSendInputEvents) {
                    PML_INPUT_STREAM_CONTEXT inputCtx = HIDInputContext(self);
                    if (!inputCtx) {
                        return;
                    }
                    LiSendMouseButtonEventCtx(inputCtx, pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE, BUTTON_RIGHT);
                }
            };
        
            mouse.mouseInput.auxiliaryButtons[0].pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
                if (self.directTouchGCMouseButtonGate != nil &&
                    self.directTouchGCMouseButtonGate(BUTTON_X1, pressed, NSProcessInfo.processInfo.systemUptime)) {
                    return;
                }
                if (self.shouldSendInputEvents) {
                    PML_INPUT_STREAM_CONTEXT inputCtx = HIDInputContext(self);
                    if (!inputCtx) {
                        return;
                    }
                    LiSendMouseButtonEventCtx(inputCtx, pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE, BUTTON_X1);
                }
            };
            mouse.mouseInput.auxiliaryButtons[1].pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
                if (self.directTouchGCMouseButtonGate != nil &&
                    self.directTouchGCMouseButtonGate(BUTTON_X2, pressed, NSProcessInfo.processInfo.systemUptime)) {
                    return;
                }
                if (self.shouldSendInputEvents) {
                    PML_INPUT_STREAM_CONTEXT inputCtx = HIDInputContext(self);
                    if (!inputCtx) {
                        return;
                    }
                    LiSendMouseButtonEventCtx(inputCtx, pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE, BUTTON_X2);
                }
            };
        } else {
            mouse.mouseInput.mouseMovedHandler = nil;
            mouse.mouseInput.leftButton.pressedChangedHandler = nil;
            mouse.mouseInput.middleButton.pressedChangedHandler = nil;
            mouse.mouseInput.rightButton.pressedChangedHandler = nil;
            for (GCControllerButtonInput *auxButton in mouse.mouseInput.auxiliaryButtons) {
                auxButton.pressedChangedHandler = nil;
            }
        }

        if (mouse.mouseInput.scroll != nil) {
            if (self.useGCMouse) {
                mouse.mouseInput.scroll.valueChangedHandler = nil;
                mouse.mouseInput.scroll.yAxis.valueChangedHandler = ^(GCControllerAxisInput * _Nonnull axis, float value) {
                    (void)axis;
                    [self handleGCMouseScrollValueY:value];
                };
            } else {
                mouse.mouseInput.scroll.valueChangedHandler = nil;
                mouse.mouseInput.scroll.yAxis.valueChangedHandler = nil;
            }
        }
    }
}

-(void)unregisterMouseCallbacks:(GCMouse*)mouse API_AVAILABLE(macos(11.0)) {
    NSMapTable<GCMouse *, HIDSupport *> *owners = HIDGCMouseCallbackOwners();
    @synchronized (owners) {
        if ([owners objectForKey:mouse] != self) {
            return;
        }
        [owners removeObjectForKey:mouse];
        mouse.mouseInput.mouseMovedHandler = nil;
    
        mouse.mouseInput.leftButton.pressedChangedHandler = nil;
        mouse.mouseInput.middleButton.pressedChangedHandler = nil;
        mouse.mouseInput.rightButton.pressedChangedHandler = nil;
    
        for (GCControllerButtonInput* auxButton in mouse.mouseInput.auxiliaryButtons) {
            auxButton.pressedChangedHandler = nil;
        }

        if (mouse.mouseInput.scroll != nil) {
            mouse.mouseInput.scroll.valueChangedHandler = nil;
            mouse.mouseInput.scroll.yAxis.valueChangedHandler = nil;
        }
    }
}

static CVReturn displayLinkOutputCallback(CVDisplayLinkRef displayLink,
                                          const CVTimeStamp *now,
                                          const CVTimeStamp *vsyncTime,
                                          CVOptionFlags flagsIn,
                                          CVOptionFlags *flagsOut,
                                          void *displayLinkContext)
{
    HIDSupport *me = (__bridge HIDSupport *)displayLinkContext;
    if (me == nil) {
        return kCVReturnError;
    }

    CGFloat deltaX, deltaY;
    deltaX = me.mouseDeltaX;
    deltaY = me.mouseDeltaY;
    if (deltaX != 0 || deltaY != 0) {
        me.mouseDeltaX = 0;
        me.mouseDeltaY = 0;
        if (me.shouldSendInputEvents) {
            PML_INPUT_STREAM_CONTEXT inputCtx = HIDInputContext(me);
            if (!inputCtx) {
                return kCVReturnSuccess;
            }
            NSInteger touchscreenMode = [SettingsClass touchscreenModeFor:me.host.uuid];
            BOOL useAbsolutePointerPath = HIDShouldUseAbsolutePointerPath(me, touchscreenMode);
            if (!useAbsolutePointerPath) {
                BOOL suppressed = HIDShouldSuppressRelativeMouse(me);
                if (suppressed) {
                    [me recordRelativeInputDiagnosticsFrom:@"gcMouse"
                                                 rawDeltaX:deltaX
                                                 rawDeltaY:deltaY
                                                sentDeltaX:0
                                                sentDeltaY:0
                                                suppressed:YES];
                    return kCVReturnSuccess;
                }
                CGFloat normalizedDeltaX = deltaX / HIDGCMouseRelativeSpeedDivisor;
                CGFloat normalizedDeltaY = deltaY / HIDGCMouseRelativeSpeedDivisor;
                CGFloat sensitivity = HIDPointerSensitivityForHost(me.host);
                short moveX = HIDScaledRelativeDelta(normalizedDeltaX, sensitivity);
                short moveY = HIDScaledRelativeDelta(normalizedDeltaY, sensitivity);
                [me recordRelativeInputDiagnosticsFrom:@"gcMouse"
                                             rawDeltaX:deltaX
                                             rawDeltaY:deltaY
                                            sentDeltaX:moveX
                                            sentDeltaY:moveY
                                            suppressed:NO];
                HIDDispatchInput(me, inputCtx, ^{
                    LiSendMouseMoveEventCtx(inputCtx, moveX, moveY);
                });
                [SettingsClass updateMouseInputRuntimeStatusFor:me.host.uuid
                                                    summaryKey:@"Mouse Runtime Path GameController Active"
                                                     detailKey:@"Mouse Runtime Detail GameController Active"];
            }
        }
    }
    
    // Mouse Emulation Movement
    if (me.controller.isMouseMode && me.shouldSendInputEvents) {
        PML_INPUT_STREAM_CONTEXT inputCtx = HIDInputContext(me);
        if (!inputCtx) {
            return kCVReturnSuccess;
        }
        short rx = me.controller.lastRightStickX;
        short ry = me.controller.lastRightStickY;
        short deadzone = 4000;
        float sensitivity = 15.0f; // Approx match to Qt/ControllerSupport
        
        if (abs(rx) > deadzone || abs(ry) > deadzone) {
            float dx = (float)(abs(rx) > deadzone ? rx : 0) / 32767.0f * sensitivity;
            float dy = (float)(abs(ry) > deadzone ? ry : 0) / 32767.0f * sensitivity;
            
            // Invert Y? Usually stick Y is up=negative or positive depending on driver.
            // HID usage: Y min is top (-32768), max is bottom (32767).
            // Mouse move: +Y is down.
            // So +StickY should be +MouseY.
            // ControllerSupport uses -dy. Let's try direct map first.
            // ControllerSupport: dy = -dy * sens.
            // Let's use -dy for now.
            
            short moveX = (short)dx;
            short moveY = (short)dy; // Try positive first based on HID mapping logic above (MIN(-(val), ...)) inverted already?
            
            // Wait, updateButtonFlags logic:
            // kHIDUsage_GD_Y: self.controller.lastLeftStickY = MIN(-(intValue - 32768), 32767);
            // It inverts it. So Up is Positive?
            // Standard XInput: Up is Positive.
            // Mouse Move: +Y is Down.
            // So Up (+Stick) -> Up (-Mouse).
            // So we need to invert Y.
            
            moveY = (short)(-dy);
            
            [me recordRelativeInputDiagnosticsFrom:@"controllerMouse"
                                         rawDeltaX:dx
                                         rawDeltaY:-dy
                                        sentDeltaX:moveX
                                        sentDeltaY:moveY
                                        suppressed:NO];
            if (moveX != 0 || moveY != 0) {
                HIDDispatchInput(me, inputCtx, ^{
                    LiSendMouseMoveEventCtx(inputCtx, moveX, moveY);
                });
            }
        }
    }

    return kCVReturnSuccess;
}

- (BOOL)initializeDisplayLink
{
    NSNumber *screenNumber = [[NSScreen mainScreen] deviceDescription][@"NSScreenNumber"];

    CGDirectDisplayID displayId = [screenNumber unsignedIntValue];
    CVDisplayLinkRef displayLink;
    CVReturn status = CVDisplayLinkCreateWithCGDisplay(displayId, &displayLink);
    if (status != kCVReturnSuccess) {
        Log(LOG_E, @"Failed to create CVDisplayLink: %d", status);
        return NO;
    }
    self.displayLink = displayLink;
    
    __weak typeof(self) weakSelf = self;
    status = CVDisplayLinkSetOutputCallback(self.displayLink, displayLinkOutputCallback, (__bridge void * _Nullable)(weakSelf));
    if (status != kCVReturnSuccess) {
        Log(LOG_E, @"CVDisplayLinkSetOutputCallback() failed: %d", status);
        return NO;
    }
    
    status = CVDisplayLinkStart(self.displayLink);
    if (status != kCVReturnSuccess) {
        Log(LOG_E, @"CVDisplayLinkStart() failed: %d", status);
        return NO;
    }
    
    return YES;
}


- (BOOL)hasPressedMouseButtons {
    return self.pressedMouseButtonsMask != 0;
}

- (void)releaseAllPressedMouseButtons {
    uint32_t pressedMask = self.pressedMouseButtonsMask;
    if (pressedMask == 0) {
        return;
    }

    self.pressedMouseButtonsMask = 0;

    PML_INPUT_STREAM_CONTEXT inputCtx = HIDInputContext(self);
    if (self.shouldSendInputEvents && HIDValidateInputContext(inputCtx, "releaseAllPressedMouseButtons")) {
        static const int buttons[] = {
            BUTTON_LEFT,
            BUTTON_MIDDLE,
            BUTTON_RIGHT,
            BUTTON_X1,
            BUTTON_X2,
        };

        for (NSUInteger index = 0; index < sizeof(buttons) / sizeof(buttons[0]); index++) {
            int button = buttons[index];
            if ((pressedMask & HIDMouseButtonBitForButton(button)) == 0) {
                continue;
            }

            LiSendMouseButtonEventCtx(inputCtx, BUTTON_ACTION_RELEASE, button);
            [self recordMouseButtonDiagnosticsAction:@"release"
                                              button:button
                                                mask:self.pressedMouseButtonsMask
                                           synthetic:YES];
        }
    }
}

- (void)mouseDown:(NSEvent *)event withButton:(int)button {
    if (self.useGCMouse) {
        return;
    }
    
    if ([SettingsClass swapMouseButtonsFor:self.host.uuid]) {
        if (button == BUTTON_LEFT) {
            button = BUTTON_RIGHT;
        } else if (button == BUTTON_RIGHT) {
            button = BUTTON_LEFT;
        }
    }
    
    if (!self.shouldSendInputEvents) {
        return;
    }

    if ([self.precisionTouchpad consumeMouseButton:button pressed:YES]) {
        return;
    }

    PML_INPUT_STREAM_CONTEXT inputCtx = HIDInputContext(self);
    if (!HIDValidateInputContext(inputCtx, "mouseDown")) {
        return;
    }

    self.pressedMouseButtonsMask |= HIDMouseButtonBitForButton(button);
    [self recordMouseButtonDiagnosticsAction:@"press"
                                      button:button
                                        mask:self.pressedMouseButtonsMask
                                   synthetic:NO];
    HIDDispatchInput(self, inputCtx, ^{
        LiSendMouseButtonEventCtx(inputCtx, BUTTON_ACTION_PRESS, button);
    });
}

- (void)mouseUp:(NSEvent *)event withButton:(int)button {
    if (self.useGCMouse) {
        return;
    }
    
    if ([SettingsClass swapMouseButtonsFor:self.host.uuid]) {
        if (button == BUTTON_LEFT) {
            button = BUTTON_RIGHT;
        } else if (button == BUTTON_RIGHT) {
            button = BUTTON_LEFT;
        }
    }
    
    if ([self.precisionTouchpad consumeMouseButton:button pressed:NO]) {
        return;
    }

    if (self.shouldSendInputEvents) {
        PML_INPUT_STREAM_CONTEXT inputCtx = HIDInputContext(self);
        if (HIDValidateInputContext(inputCtx, "mouseUp")) {
            HIDDispatchInput(self, inputCtx, ^{
                LiSendMouseButtonEventCtx(inputCtx, BUTTON_ACTION_RELEASE, button);
            });
        }
    }

    self.pressedMouseButtonsMask &= ~HIDMouseButtonBitForButton(button);
    [self recordMouseButtonDiagnosticsAction:@"release"
                                      button:button
                                        mask:self.pressedMouseButtonsMask
                                   synthetic:NO];
}

- (void)mouseMoved:(NSEvent *)event {
    if (!self.shouldSendInputEvents) {
        return;
    }

    if ([self.precisionTouchpad shouldSuppressPointerMotion]) {
        return;
    }

    PML_INPUT_STREAM_CONTEXT inputCtx = HIDInputContext(self);
    if (!HIDValidateInputContext(inputCtx, "mouseMoved")) {
        return;
    }

    NSInteger touchscreenMode = [SettingsClass touchscreenModeFor:self.host.uuid];
    BOOL useAbsolutePointerPath = HIDShouldUseAbsolutePointerPath(self, touchscreenMode);

    if (self.useGCMouse && !useAbsolutePointerPath) {
        return;
    }

    BOOL hybridAppKitMove = NO;
    if (!useAbsolutePointerPath && HIDShouldUseCoreHIDFreeMouseAbsoluteSync(self)) {
        // Hybrid free mouse. Apple documents mouseMoved as an AppKit event stream and CoreHID as the raw device
        // stream. While CoreHID is delivering movement (the same quarter-second window the relative path uses),
        // AppKit's copy is only a second representation of the same physical motion, and sending both can pull the
        // host cursor back and forth. When CoreHID is not delivering (a pointer it does not carry, a trackpad;
        // Input Monitoring not allowed; no device matched), AppKit is the only source, and the one thing sent for the
        // event is its position: not also a relative move, and no correction of the virtual cursor for it (the
        // anchor follows the pointer instead). After about a quarter second of this with no CoreHID motion at all,
        // CoreHID is taken as unavailable and the absolute path is used for good.
        // (Sources: macos-apple-corehid-20261116, macos-apple-nsevent-mousemoved-20261116,
        // macos-apple-nsresponder-mousemoved-20261116.)
        MLCoreHIDAppKitMoveAction action;
        @synchronized (self.freeMouseVirtualCursorLock) {
            action = MLCoreHIDDecideAppKitMove([self coreHIDSilenceState],
                                               [self hasRecentCoreHIDMouseMovementForAppKitEvent:event],
                                               LiGetMillis());
        }
        if (action.markSilent) {
            [self markCoreHIDMouseSilent];
        }
        if (!action.sendAbsolute) {
            return;
        }
        hybridAppKitMove = YES;
        useAbsolutePointerPath = YES;
    }

    if (useAbsolutePointerPath) {
        short hostX = 0;
        short hostY = 0;
        short referenceWidth = 0;
        short referenceHeight = 0;
        if (!HIDAbsoluteMousePayloadForEvent(event,
                                             YES,
                                             &hostX,
                                             &hostY,
                                             &referenceWidth,
                                             &referenceHeight)) {
            return;
        }
        [self recordAbsoluteInputDiagnosticsFrom:@"mouseMoved"
                                               x:hostX
                                               y:hostY
                                           width:referenceWidth
                                          height:referenceHeight];
        if (!self.coreHIDMouseRuntimeFailed) {
            // While CoreHID is marked failed the status keeps the reason it was recorded with.
            [SettingsClass updateMouseInputRuntimeStatusFor:self.host.uuid
                                                summaryKey:@"Mouse Runtime Path Absolute Active"
                                                 detailKey:@"Mouse Runtime Detail Absolute Active"];
        }
        // Hybrid free mouse configured, CoreHID found silent: the absolute path is used, and the anchor keeps following
        // the pointer on every event, so CoreHID motion that resumes later starts from where the pointer is.
        BOOL hybridConfiguredCoreHIDSilent = self.coreHIDMouseRuntimeFailed &&
                                             touchscreenMode != 1 &&
                                             self.useCoreHIDMouse &&
                                             !self.useGCMouse &&
                                             HIDShouldUseHybridFreeMouseMotion(self) &&
                                             [[SettingsClass mouseModeFor:self.host.uuid] isEqualToString:@"remote"];
        if (hybridAppKitMove || hybridConfiguredCoreHIDSilent) {
            // The virtual cursor follows the pointer, so that CoreHID motion that starts later continues from here.
            NSPoint eventPoint = NSZeroPoint;
            NSSize eventReference = NSZeroSize;
            if (HIDAbsoluteMouseReferenceForEvent(event, &eventPoint, &eventReference)) {
                [self updateFreeMouseVirtualCursorAnchorWithViewPoint:eventPoint referenceSize:eventReference];
            }
        }
        HIDDispatchInput(self, inputCtx, ^{
            LiSendMousePositionEventCtx(inputCtx, hostX, hostY, referenceWidth, referenceHeight);
        });
    } else {
        if (self.useCoreHIDMouse &&
            self.coreHIDMouseDriver != nil &&
            self.coreHIDMouseDriver.secondsSinceLastMovementEvent < 0.25) {
            return;
        }
        [SettingsClass updateMouseInputRuntimeStatusFor:self.host.uuid
                                            summaryKey:@"Mouse Runtime Path AppKit Active"
                                             detailKey:@"Mouse Runtime Detail AppKit Active"];
        [self dispatchRelativeMouseDeltaX:event.deltaX
                                   deltaY:event.deltaY
                                sourceTag:@"mouseMoved"];
    }
}

- (void)sendAbsoluteMousePositionForViewPoint:(NSPoint)viewPoint
                                referenceSize:(NSSize)referenceSize
                                clampToBounds:(BOOL)clampToBounds {
    if ([self.precisionTouchpad shouldSuppressPointerMotion]) {
        return;
    }

    PML_INPUT_STREAM_CONTEXT inputCtx = HIDInputContext(self);
    if (!HIDValidateInputContext(inputCtx, "sendAbsoluteMousePosition")) {
        return;
    }

    short hostX = 0;
    short hostY = 0;
    short referenceWidth = 0;
    short referenceHeight = 0;
    if (!HIDAbsoluteMousePositionForViewPoint(viewPoint,
                                              referenceSize,
                                              clampToBounds,
                                              &hostX,
                                              &hostY,
                                              &referenceWidth,
                                              &referenceHeight)) {
        return;
    }

    if (hostX == self.lastAbsolutePointerHostX &&
        hostY == self.lastAbsolutePointerHostY &&
        referenceWidth == self.lastAbsolutePointerReferenceWidth &&
        referenceHeight == self.lastAbsolutePointerReferenceHeight) {
        if (self.inputDiagnosticsEnabled) {
            @synchronized (self.inputDiagnosticsLock) {
                self.inputDiagnosticsAbsoluteDuplicateSkips += 1;
            }
        }
        return;
    }

    [self recordAbsoluteInputDiagnosticsFrom:@"sendAbsoluteMousePosition"
                                           x:hostX
                                           y:hostY
                                       width:referenceWidth
                                      height:referenceHeight];
    HIDDispatchInput(self, inputCtx, ^{
        LiSendMousePositionEventCtx(inputCtx, hostX, hostY, referenceWidth, referenceHeight);
    });
}

- (void)sendMouseButton:(int)button
                pressed:(BOOL)pressed
      syncedToViewPoint:(NSPoint)viewPoint
          referenceSize:(NSSize)referenceSize
          clampToBounds:(BOOL)clampToBounds {
    if (self.useGCMouse) {
        return;
    }

    if ([SettingsClass swapMouseButtonsFor:self.host.uuid]) {
        if (button == BUTTON_LEFT) {
            button = BUTTON_RIGHT;
        } else if (button == BUTTON_RIGHT) {
            button = BUTTON_LEFT;
        }
    }

    if (!self.shouldSendInputEvents) {
        return;
    }

    if ([self.precisionTouchpad consumeMouseButton:button pressed:pressed]) {
        return;
    }

    PML_INPUT_STREAM_CONTEXT inputCtx = HIDInputContext(self);
    if (!HIDValidateInputContext(inputCtx, pressed ? "sendMouseButtonPressSynced" : "sendMouseButtonReleaseSynced")) {
        return;
    }

    short hostX = 0;
    short hostY = 0;
    short referenceWidth = 0;
    short referenceHeight = 0;
    BOOL shouldSendAbsolute = HIDAbsoluteMousePositionForViewPoint(viewPoint,
                                                                   referenceSize,
                                                                   clampToBounds,
                                                                   &hostX,
                                                                   &hostY,
                                                                   &referenceWidth,
                                                                   &referenceHeight);
    if (shouldSendAbsolute &&
        hostX == self.lastAbsolutePointerHostX &&
        hostY == self.lastAbsolutePointerHostY &&
        referenceWidth == self.lastAbsolutePointerReferenceWidth &&
        referenceHeight == self.lastAbsolutePointerReferenceHeight) {
        if (self.inputDiagnosticsEnabled) {
            @synchronized (self.inputDiagnosticsLock) {
                self.inputDiagnosticsAbsoluteDuplicateSkips += 1;
            }
        }
        shouldSendAbsolute = NO;
    }

    if (pressed) {
        self.pressedMouseButtonsMask |= HIDMouseButtonBitForButton(button);
        [self recordMouseButtonDiagnosticsAction:@"press"
                                          button:button
                                            mask:self.pressedMouseButtonsMask
                                       synthetic:NO];
    }

    if (shouldSendAbsolute) {
        [self recordAbsoluteInputDiagnosticsFrom:@"sendAbsoluteMouseButtonSync"
                                               x:hostX
                                               y:hostY
                                           width:referenceWidth
                                          height:referenceHeight];
    }

    HIDDispatchInput(self, inputCtx, ^{
        if (shouldSendAbsolute) {
            LiSendMousePositionEventCtx(inputCtx, hostX, hostY, referenceWidth, referenceHeight);
        }
        LiSendMouseButtonEventCtx(inputCtx,
                                  pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE,
                                  button);
    });

    if (!pressed) {
        self.pressedMouseButtonsMask &= ~HIDMouseButtonBitForButton(button);
        [self recordMouseButtonDiagnosticsAction:@"release"
                                          button:button
                                            mask:self.pressedMouseButtonsMask
                                       synthetic:NO];
    }
}

- (BOOL)absoluteMousePayloadForViewPoint:(NSPoint)viewPoint
                           referenceSize:(NSSize)referenceSize
                           clampToBounds:(BOOL)clampToBounds
                                   hostX:(short *)hostX
                                   hostY:(short *)hostY
                          referenceWidth:(short *)referenceWidth
                         referenceHeight:(short *)referenceHeight {
    return HIDAbsoluteMousePositionForViewPoint(viewPoint,
                                                referenceSize,
                                                clampToBounds,
                                                hostX,
                                                hostY,
                                                referenceWidth,
                                                referenceHeight);
}


@end

@implementation HIDSupport (PrecisionTouchpad)

- (void)setUpPrecisionTouchpad {
    MLPrecisionTouchpad *touchpad = [[MLPrecisionTouchpad alloc] init];
    __weak HIDSupport *weakSelf = self;
    touchpad.dispatchHandler = ^(void (^work)(PML_INPUT_STREAM_CONTEXT ctx)) {
        HIDSupport *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        PML_INPUT_STREAM_CONTEXT inputCtx = HIDInputContext(strongSelf);
        if (!HIDValidateInputContext(inputCtx, "precisionTouchpad")) {
            return;
        }
        HIDDispatchInput(strongSelf, inputCtx, ^{
            work(inputCtx);
        });
    };
    touchpad.featureFlagsProvider = ^uint32_t{
        HIDSupport *strongSelf = weakSelf;
        PML_INPUT_STREAM_CONTEXT inputCtx = strongSelf != nil ? (PML_INPUT_STREAM_CONTEXT)strongSelf.inputContext : NULL;
        if (inputCtx == NULL || inputCtx->connectionContext == NULL) {
            return 0;
        }
        return LiGetHostFeatureFlagsCtx(inputCtx->connectionContext);
    };
    self.precisionTouchpad = touchpad;
    [self refreshPrecisionTouchpadConfiguration];
}

- (void)refreshPrecisionTouchpadConfiguration {
    MLPrecisionTouchpadMode mode = MLPrecisionTouchpadModeOff;
    if (self.host.uuid != nil) {
        NSInteger stored = [SettingsClass hostPrecisionTouchpadModeFor:self.host.uuid];
        mode = (stored == MLPrecisionTouchpadModeBlock || stored == MLPrecisionTouchpadModeBoth)
            ? (MLPrecisionTouchpadMode)stored : MLPrecisionTouchpadModeOff;
    }
    self.precisionTouchpad.mode = mode;
}

- (void)handleTrackpadTouchesEvent:(NSEvent *)event inView:(NSView *)view {
    if (!self.shouldSendInputEvents) {
        [self.precisionTouchpad reset];
        return;
    }
    [self.precisionTouchpad handleTouchesEvent:event inView:view];
}

@end
