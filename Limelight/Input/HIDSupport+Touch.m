//
//  HIDSupport+Touch.m
//  Moonlight for macOS
//
//  What the direct touch layer sends to the host. Native multi-touch is LiSendTouchEvent
//  (moonlight-common-c Limelight.h:1072, gated by LI_FF_PEN_TOUCH_EVENTS, Limelight.h:1548); the
//  fallback modes use the ordinary mouse calls.
//

#import "HIDSupport_Internal.h"
#import "MLTouchCore.h"
#import "MLTouchRuntime.h"

@implementation HIDSupport (DirectTouch)

- (uint32_t)touchHostFeatureFlags {
    PML_INPUT_STREAM_CONTEXT ctx = (PML_INPUT_STREAM_CONTEXT)self.inputContext;
    if (ctx == NULL || ctx->connectionContext == NULL) {
        return 0;
    }
    return LiGetHostFeatureFlagsCtx(ctx->connectionContext);
}

// Touch is the user's own act on the picture, not the capture state of the mouse: it does not wait for
// shouldSendInputEvents (which is off whenever the pointer is not captured, as it is when only a finger is used).
// MLTouchRuntime decides at the start of each touch whether the stream takes it; from then on every event of that
// touch goes out, so the host never sees a touch begin without its DOWN or end without its UP.
- (void)sendTouchWireEvent:(uint8_t)eventType pointerId:(uint32_t)pointerId x:(float)x y:(float)y {
    PML_INPUT_STREAM_CONTEXT inputCtx = HIDInputContext(self);
    if (!HIDValidateInputContext(inputCtx, "touchEvent")) {
        return;
    }
    __weak typeof(self) weakSelf = self;
    HIDDispatchInput(self, inputCtx, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil) return;
        uint32_t bit = pointerId < 32 ? (1u << pointerId) : 0;
        // The input queue is serial: this is the order the host gets. A pointer's MOVE, UP or CANCEL is only sent
        // after its DOWN went out, because Sunshine warns about, and mishandles, a pointer it never saw begin.
        if (eventType == MLTouchWireDown) {
            // a DOWN for an id still down means the earlier UP never went out: say so to the host first
            if (strongSelf.touchDownSentMask & bit) {
                LiSendTouchEventCtx(inputCtx, MLTouchWireCancel, pointerId, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, LI_ROT_UNKNOWN);
                strongSelf.touchDownSentMask &= ~bit;
            }
        } else if (eventType == MLTouchWireCancelAll) {
            // nothing is down on the host, nothing to cancel
            if (strongSelf.touchDownSentMask == 0) return;
        } else if (!(strongSelf.touchDownSentMask & bit)) {
            return;
        }
        // Pressure 0 means unknown (Limelight.h:1030), contact area 0 unknown, rotation unknown:
        // NSTouch carries none of them.
        int result = LiSendTouchEventCtx(inputCtx, eventType, pointerId, x, y, 0.0f, 0.0f, 0.0f, LI_ROT_UNKNOWN);
        if (result != 0) {
            NSUInteger failures = ++strongSelf.touchSendFailures;
            strongSelf.touchLastSendError = result;
            if (failures <= 3 || failures % 100 == 0) {
                os_log_error(MLTouchLog(), "LiSendTouchEvent failed result=%d event=%u pointer=%u failures=%lu (queue full, input not initialised or host without LI_FF_PEN_TOUCH_EVENTS); the touch is not sent",
                             result, eventType, pointerId, (unsigned long)failures);
            }
            return;   // a DOWN that did not go out leaves no state behind: its MOVEs and UP are held back too
        }
        if (eventType == MLTouchWireDown) {
            strongSelf.touchDownSentMask |= bit;
        } else if (eventType == MLTouchWireUp || eventType == MLTouchWireCancel) {
            strongSelf.touchDownSentMask &= ~bit;
        } else if (eventType == MLTouchWireCancelAll) {
            strongSelf.touchDownSentMask = 0;
        }
    });
}

- (void)sendTouchRelativeDeltaX:(short)deltaX deltaY:(short)deltaY {
    if (deltaX == 0 && deltaY == 0) {
        return;
    }
    PML_INPUT_STREAM_CONTEXT inputCtx = HIDInputContext(self);
    if (!HIDValidateInputContext(inputCtx, "touchRelativeMove")) {
        return;
    }
    HIDDispatchInput(self, inputCtx, ^{
        LiSendMouseMoveEventCtx(inputCtx, deltaX, deltaY);
    });
}

- (void)sendTouchAbsoluteX:(float)x y:(float)y referenceSize:(CGSize)referenceSize {
    PML_INPUT_STREAM_CONTEXT inputCtx = HIDInputContext(self);
    if (!HIDValidateInputContext(inputCtx, "touchAbsoluteMove")) {
        return;
    }
    short refW = (short)MIN(MAX(referenceSize.width, 1.0), 32000.0);
    short refH = (short)MIN(MAX(referenceSize.height, 1.0), 32000.0);
    short hostX = (short)lrintf(MIN(MAX(x, 0.0f), 1.0f) * (float)(refW - 1));
    short hostY = (short)lrintf(MIN(MAX(y, 0.0f), 1.0f) * (float)(refH - 1));
    HIDDispatchInput(self, inputCtx, ^{
        LiSendMousePositionEventCtx(inputCtx, hostX, hostY, refW, refH);
    });
}

- (void)sendTouchMouseButton:(int)button pressed:(BOOL)pressed {
    PML_INPUT_STREAM_CONTEXT inputCtx = HIDInputContext(self);
    if (!HIDValidateInputContext(inputCtx, "touchMouseButton")) {
        return;
    }
    int hostButton = button;
    if ([SettingsClass swapMouseButtonsFor:self.host.uuid]) {
        if (hostButton == BUTTON_LEFT) hostButton = BUTTON_RIGHT;
        else if (hostButton == BUTTON_RIGHT) hostButton = BUTTON_LEFT;
    }
    HIDDispatchInput(self, inputCtx, ^{
        LiSendMouseButtonEventCtx(inputCtx, pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE, hostButton);
    });
}

- (void)sendTouchHighResScroll:(short)amount {
    if (amount == 0) {
        return;
    }
    PML_INPUT_STREAM_CONTEXT inputCtx = HIDInputContext(self);
    if (!HIDValidateInputContext(inputCtx, "touchScroll")) {
        return;
    }
    HIDDispatchInput(self, inputCtx, ^{
        LiSendHighResScrollEventCtx(inputCtx, amount);
    });
}

@end
