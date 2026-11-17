//
//  StreamViewController+Touch.m
//  Moonlight for macOS
//
//  Wires direct touch (touchscreen Mac, Sidecar iPad) into the stream window: see MLTouchRuntime.
//

#import "StreamViewController_Internal.h"
#import "MLTouchRuntime.h"

@implementation StreamViewController (DirectTouch)

- (void)configureDirectTouchInputWithVideoWidth:(int)width height:(int)height stretch:(BOOL)stretch {
    StreamViewMac *streamView = self.streamView;
    HIDSupport *hid = self.hidSupport;
    if (streamView == nil || hid == nil) {
        return;
    }
    if (streamView.touchRuntime == nil) {
        MLTouchRuntime *runtime = [[MLTouchRuntime alloc] initWithStreamView:streamView hid:hid hostUUID:self.app.host.uuid];
        streamView.touchRuntime = runtime;
        __weak MLTouchRuntime *weakRuntime = runtime;
        __weak typeof(self) weakSelf = self;
        // Touch does not wait for the pointer to be captured: it is taken while the stream is live and its window is
        // on screen and no menu of the stream is open. (Input being paused for the mouse and keyboard is not that.)
        runtime.touchAllowedHandler = ^BOOL {
            StreamViewController *strongSelf = weakSelf;
            NSWindow *window = strongSelf.view.window;
            return strongSelf != nil && !strongSelf.stopStreamInProgress && !strongSelf.reconnectInProgress &&
                   !strongSelf.edgeMenuMenuVisible && !strongSelf.controllerControlCenterVisible && window != nil && window.isVisible && !window.isMiniaturized;
        };
        // Five touches held still open the Control Center the controller opens.
        runtime.openControlCenterHandler = ^{
            StreamViewController *strongSelf = weakSelf;
            if (strongSelf == nil || strongSelf.stopStreamInProgress) return;
            [strongSelf presentControllerControlCenter];
        };
        // The window moved to another screen (Sidecar): the control ball is placed again for that screen.
        runtime.screenChangedHandler = ^{
            StreamViewController *strongSelf = weakSelf;
            [strongSelf requestStreamMenuEntrypointsVisibilityUpdate];
        };
        // A touch on the picture engages the stream the way a click does.
        runtime.touchEngageHandler = ^{
            StreamViewController *strongSelf = weakSelf;
            if (strongSelf == nil) return;
            [strongSelf ensureStreamWindowKeyIfPossible];
            [strongSelf.view.window makeFirstResponder:strongSelf];
        };
        hid.directTouchGCMouseButtonGate = ^BOOL(int button, BOOL pressed, NSTimeInterval time) {
            return [weakRuntime shouldDropGCMouseButton:button pressed:pressed time:time];
        };
        // Input pauses when the menu opens or the pointer is released: touches the stream may no longer take are let go.
        hid.touchSuspendHandler = ^{
            StreamViewController *strongSelf = weakSelf;
            if (strongSelf != nil && weakRuntime.touchAllowedHandler != nil && weakRuntime.touchAllowedHandler()) return;
            [weakRuntime cancelLiveTouches];
        };
    }
    [streamView.touchRuntime setVideoWidth:width height:height stretch:stretch];
    [streamView.touchRuntime refresh];
}

- (void)refreshDirectTouchInput {
    [self.streamView.touchRuntime refresh];
    // The first stream on a touch screen says how to open the Control Center, once.
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf.streamView.touchRuntime showFiveFingerHintIfNeeded];
    });
}

- (void)updateDirectTouchVideoWidth:(int)width height:(int)height {
    [self.streamView.touchRuntime setVideoWidth:width height:height];
}

- (void)updateDirectTouchStretch:(BOOL)stretch {
    [self.streamView.touchRuntime setStretch:stretch];
}

- (void)tearDownDirectTouchInput {
    StreamViewMac *streamView = self.streamView;
    self.hidSupport.touchSuspendHandler = nil;
    self.hidSupport.directTouchGCMouseButtonGate = nil;
    [streamView.touchRuntime tearDown];
    streamView.touchRuntime = nil;
}

@end
