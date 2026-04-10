//
//  HIDSupport+Pointer.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 26/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//
#import "HIDSupport_Internal.h"

static CGFloat const HIDGCMouseRelativeSpeedDivisor = 2.5;

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

static inline CGFloat HIDClampFreeMouseCoordinate(CGFloat value, CGFloat upperBound) {
    if (!isfinite(value)) {
        return 0.0;
    }
    if (!isfinite(upperBound) || upperBound <= 0.0) {
        return 0.0;
    }
    if (value < 0.0) {
        return 0.0;
    }
    if (value > upperBound) {
        return upperBound;
    }
    return value;
}

static inline NSPoint HIDClampFreeMousePoint(NSPoint point, NSSize referenceSize) {
    CGFloat maxX = MAX(0.0, referenceSize.width);
    CGFloat maxY = MAX(0.0, referenceSize.height);
    return NSMakePoint(HIDClampFreeMouseCoordinate(point.x, maxX),
                       HIDClampFreeMouseCoordinate(point.y, maxY));
}

static inline double HIDClampFreeMouseGain(double value) {
    if (!isfinite(value)) {
        return 1.0;
    }
    if (value < 0.25) {
        return 0.25;
    }
    if (value > 4.0) {
        return 4.0;
    }
    return value;
}

static inline double HIDBlendFreeMouseGain(double currentGain, double rawDelta, double observedDelta) {
    if (!isfinite(rawDelta) || !isfinite(observedDelta)) {
        return currentGain;
    }
    if (fabs(rawDelta) < 0.5 || fabs(observedDelta) < 0.25) {
        return currentGain;
    }
    if ((rawDelta > 0.0 && observedDelta < 0.0) || (rawDelta < 0.0 && observedDelta > 0.0)) {
        return currentGain;
    }

    double sample = fabs(observedDelta / rawDelta);
    sample = HIDClampFreeMouseGain(sample);
    if (!isfinite(currentGain) || currentGain <= 0.0) {
        return sample;
    }

    return HIDClampFreeMouseGain((currentGain * 0.82) + (sample * 0.18));
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
        self.freeMouseVirtualCursorHasAnchor = NO;
        self.freeMouseVirtualCursorPoint = NSZeroPoint;
        self.freeMouseVirtualCursorLastAnchorPoint = NSZeroPoint;
        self.freeMouseVirtualCursorReferenceSize = NSZeroSize;
        self.freeMouseVirtualCursorGainX = 1.0;
        self.freeMouseVirtualCursorGainY = 1.0;
        self.freeMouseVirtualCursorRawSinceAnchorX = 0.0;
        self.freeMouseVirtualCursorRawSinceAnchorY = 0.0;
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

    NSPoint clampedPoint = HIDClampFreeMousePoint(viewPoint, referenceSize);

    @synchronized (self.freeMouseVirtualCursorLock) {
        if (self.freeMouseVirtualCursorHasAnchor) {
            double observedDeltaX = clampedPoint.x - self.freeMouseVirtualCursorLastAnchorPoint.x;
            double observedDeltaY = clampedPoint.y - self.freeMouseVirtualCursorLastAnchorPoint.y;
            self.freeMouseVirtualCursorGainX = HIDBlendFreeMouseGain(self.freeMouseVirtualCursorGainX,
                                                                     self.freeMouseVirtualCursorRawSinceAnchorX,
                                                                     observedDeltaX);
            self.freeMouseVirtualCursorGainY = HIDBlendFreeMouseGain(self.freeMouseVirtualCursorGainY,
                                                                     self.freeMouseVirtualCursorRawSinceAnchorY,
                                                                     observedDeltaY);
        }

        self.freeMouseVirtualCursorPoint = clampedPoint;
        self.freeMouseVirtualCursorLastAnchorPoint = clampedPoint;
        self.freeMouseVirtualCursorReferenceSize = referenceSize;
        self.freeMouseVirtualCursorRawSinceAnchorX = 0.0;
        self.freeMouseVirtualCursorRawSinceAnchorY = 0.0;
        self.freeMouseVirtualCursorHasAnchor = YES;
    }
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

    CGFloat sensitivity = HIDPointerSensitivityForHost(self.host);
    double viewDeltaX = deltaX * sensitivity;
    double viewDeltaY = -deltaY * sensitivity;

    NSPoint predictedPoint = NSZeroPoint;
    NSSize referenceSize = NSZeroSize;

    @synchronized (self.freeMouseVirtualCursorLock) {
        if (!self.freeMouseVirtualCursorHasAnchor ||
            self.freeMouseVirtualCursorReferenceSize.width <= 0.0 ||
            self.freeMouseVirtualCursorReferenceSize.height <= 0.0) {
            return NO;
        }

        self.freeMouseVirtualCursorRawSinceAnchorX += viewDeltaX;
        self.freeMouseVirtualCursorRawSinceAnchorY += viewDeltaY;

        predictedPoint = self.freeMouseVirtualCursorPoint;
        predictedPoint.x += viewDeltaX * self.freeMouseVirtualCursorGainX;
        predictedPoint.y += viewDeltaY * self.freeMouseVirtualCursorGainY;
        predictedPoint = HIDClampFreeMousePoint(predictedPoint, self.freeMouseVirtualCursorReferenceSize);

        self.freeMouseVirtualCursorPoint = predictedPoint;
        referenceSize = self.freeMouseVirtualCursorReferenceSize;
    }

    [self sendAbsoluteMousePositionForViewPoint:predictedPoint
                                  referenceSize:referenceSize
                                  clampToBounds:YES];
    return YES;
}

-(void)registerMouseCallbacks:(GCMouse *)mouse API_AVAILABLE(macos(11.0)) {
    if (self.useGCMouse) {
        mouse.mouseInput.mouseMovedHandler = ^(GCMouseInput * _Nonnull mouse, float deltaX, float deltaY) {
            self.mouseDeltaX += deltaX;
            self.mouseDeltaY -= deltaY;
        };
        
        mouse.mouseInput.leftButton.pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
            if (self.shouldSendInputEvents) {
                PML_INPUT_STREAM_CONTEXT inputCtx = HIDInputContext(self);
                if (!inputCtx) {
                    return;
                }
                LiSendMouseButtonEventCtx(inputCtx, pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE, BUTTON_LEFT);
            }
        };
        mouse.mouseInput.middleButton.pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
            if (self.shouldSendInputEvents) {
                PML_INPUT_STREAM_CONTEXT inputCtx = HIDInputContext(self);
                if (!inputCtx) {
                    return;
                }
                LiSendMouseButtonEventCtx(inputCtx, pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE, BUTTON_MIDDLE);
            }
        };
        mouse.mouseInput.rightButton.pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
            if (self.shouldSendInputEvents) {
                PML_INPUT_STREAM_CONTEXT inputCtx = HIDInputContext(self);
                if (!inputCtx) {
                    return;
                }
                LiSendMouseButtonEventCtx(inputCtx, pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE, BUTTON_RIGHT);
            }
        };
        
        mouse.mouseInput.auxiliaryButtons[0].pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
            if (self.shouldSendInputEvents) {
                PML_INPUT_STREAM_CONTEXT inputCtx = HIDInputContext(self);
                if (!inputCtx) {
                    return;
                }
                LiSendMouseButtonEventCtx(inputCtx, pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE, BUTTON_X1);
            }
        };
        mouse.mouseInput.auxiliaryButtons[1].pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
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

-(void)unregisterMouseCallbacks:(GCMouse*)mouse API_AVAILABLE(macos(11.0)) {
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

    PML_INPUT_STREAM_CONTEXT inputCtx = HIDInputContext(self);
    if (!HIDValidateInputContext(inputCtx, "mouseMoved")) {
        return;
    }

    NSInteger touchscreenMode = [SettingsClass touchscreenModeFor:self.host.uuid];
    BOOL useAbsolutePointerPath = HIDShouldUseAbsolutePointerPath(self, touchscreenMode);

    if (self.useGCMouse && !useAbsolutePointerPath) {
        return;
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
        [SettingsClass updateMouseInputRuntimeStatusFor:self.host.uuid
                                            summaryKey:@"Mouse Runtime Path Absolute Active"
                                             detailKey:@"Mouse Runtime Detail Absolute Active"];
        HIDDispatchInput(self, inputCtx, ^{
            LiSendMousePositionEventCtx(inputCtx, hostX, hostY, referenceWidth, referenceHeight);
        });
    } else {
        BOOL shouldUseCoreHIDHybridAnchor = HIDShouldUseCoreHIDFreeMouseAbsoluteSync(self);
        if (shouldUseCoreHIDHybridAnchor) {
            NSPoint anchorPoint = NSZeroPoint;
            NSSize anchorReferenceSize = NSZeroSize;
            if (HIDAbsoluteMouseReferenceForCurrentPointer(event.window,
                                                           &anchorPoint,
                                                           &anchorReferenceSize)) {
                [self updateFreeMouseVirtualCursorAnchorWithViewPoint:anchorPoint
                                                         referenceSize:anchorReferenceSize];
            }
        }
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
