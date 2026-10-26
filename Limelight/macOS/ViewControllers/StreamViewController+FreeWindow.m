//
//  StreamViewController+FreeWindow.m
//  Moonlight for macOS
//
//  Free Window: the host resolution follows the stream view, in a window of any shape and
//  in fullscreen. A size is sent once the window has stopped changing for a moment, one
//  request at a time; while one is under way the window may keep changing, and the size it
//  has when the host answers is sent next. Until then the old picture is stretched to fit.
//

#import "StreamViewController_Internal.h"
#import "NSView+Moonlight.h"

// While the window is being dragged, wait for it to rest this long before asking.
static const NSTimeInterval MLFreeWindowLiveResizeDelay = 0.3;
// Other size changes (zoom, tiling, fullscreen) are complete when they are reported.
static const NSTimeInterval MLFreeWindowSettleDelay = 0.05;
// A host that never answers must not stop later sizes from being sent.
static const uint64_t MLFreeWindowRequestTimeoutMs = 5000;

// The cover comes on at once when a drag starts (the stretched picture is already wrong), gently
// for a size change that happens in one step, and fades out once a frame of the new size is decoded.
static const NSTimeInterval MLFreeWindowFrostFadeIn = 0.15;
static const NSTimeInterval MLFreeWindowFrostFadeOut = 0.3;
// A decoded frame is on screen a frame or two later; the cover waits for it.
static const NSTimeInterval MLFreeWindowFrostPresentDelay = 0.08;
static const NSTimeInterval MLFreeWindowFrostTimeout = 5.0;

static const NSInteger MLDisplayModeFixedWindow = 0;
static const NSInteger MLDisplayModeFreeWindow = 3;

@implementation StreamViewController (FreeWindow)

- (BOOL)shouldStartAsFreeWindow {
    NSString *uuid = self.app.host.uuid;
    return [SettingsClass displayModeFor:uuid] == MLDisplayModeFreeWindow &&
           ![SettingsClass hostKnownNotFoundationFor:uuid];
}

#pragma mark - Geometry

- (void)unlockWindowShape:(NSWindow *)window {
    // contentResizeIncrements and contentAspectRatio replace each other.
    window.contentResizeIncrements = NSMakeSize(1.0, 1.0);
    window.contentMinSize = NSMakeSize(480.0, 270.0);
}

- (void)applyFreeWindowGeometryOnScreen:(NSScreen *)screen {
    NSWindow *window = self.view.window;
    if (window == nil) {
        return;
    }
    [self unlockWindowShape:window];
    NSSize content = [SettingsClass freeWindowInitialContentSizeFor:self.app.host.uuid screen:screen];
    [window setContentSize:content];
    [window moonlight_centerWindowOnScreen:screen ?: window.screen];
    Log(LOG_I, @"[free-window] window opens at %.0fx%.0f pt", content.width, content.height);
}

- (void)restoreFreeWindowFrame {
    NSWindow *window = self.view.window;
    if (window == nil) {
        return;
    }
    [self unlockWindowShape:window];
    NSScreen *screen = window.screen ?: [NSScreen mainScreen];
    NSSize content = [SettingsClass freeWindowInitialContentSizeFor:self.app.host.uuid screen:screen];
    [window setContentSize:content];
    [window moonlight_centerWindowOnScreen:screen];
}

- (NSSize)freeWindowTargetStreamSize {
    NSWindow *window = self.view.window;
    CGFloat scale = [SettingsClass freeWindowUsesPixelsFor:self.app.host.uuid]
        ? MAX(1.0, window.backingScaleFactor) : 1.0;
    return [SettingsClass freeWindowStreamSizeForContentSize:self.view.bounds.size pixelsPerPoint:scale];
}

- (void)noteFreeWindowContentSizeIfWindowed {
    if ([self isWindowFullscreen] || [self isWindowBorderlessMode]) {
        return;
    }
    [SettingsClass noteFreeWindowContentSize:self.view.bounds.size];
}

#pragma mark - Frost

- (void)showFreeWindowFrostAnimated:(BOOL)animated {
    NSVisualEffectView *frost = self.freeWindowFrostView;
    if (frost == nil) {
        frost = [[NSVisualEffectView alloc] initWithFrame:self.view.bounds];
        frost.material = NSVisualEffectMaterialFullScreenUI;
        frost.blendingMode = NSVisualEffectBlendingModeWithinWindow;
        frost.state = NSVisualEffectStateActive;
        frost.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        frost.alphaValue = 0.0;
        self.freeWindowFrostView = frost;
    }
    if (frost.superview != self.view) {
        frost.frame = self.view.bounds;
        [self.view addSubview:frost positioned:NSWindowAbove relativeTo:nil];
    }

    self.freeWindowFrostGeneration += 1;
    NSUInteger generation = self.freeWindowFrostGeneration;
    [frost moonlight_fadeToAlpha:1.0 duration:animated ? MLFreeWindowFrostFadeIn : 0.0 completion:nil];

    // A host that never streams the new size must not leave the picture covered.
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MLFreeWindowFrostTimeout * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf != nil && strongSelf.freeWindowFrostGeneration == generation &&
            !strongSelf.view.window.inLiveResize) {
            [strongSelf hideFreeWindowFrost];
        }
    });
}

- (void)hideFreeWindowFrost {
    NSVisualEffectView *frost = self.freeWindowFrostView;
    if (frost == nil || frost.superview == nil) {
        return;
    }
    self.freeWindowFrostGeneration += 1;
    NSUInteger generation = self.freeWindowFrostGeneration;
    __weak typeof(self) weakSelf = self;
    [frost moonlight_fadeToAlpha:0.0 duration:MLFreeWindowFrostFadeOut completion:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf != nil && strongSelf.freeWindowFrostGeneration == generation) {
            [frost removeFromSuperview];
        }
    }];
}

- (BOOL)freeWindowStreamMatchesSize:(CGSize)size {
    NSSize target = [self freeWindowTargetStreamSize];
    return fabs(size.width - target.width) <= 2.0 && fabs(size.height - target.height) <= 2.0;
}

- (void)freeWindowDecodedSizeChanged:(CGSize)size {
    self.freeWindowDecodedSize = size;
    [self hideFreeWindowFrostIfPictureFits];
}

// The cover goes only once a frame of the window's size has been decoded: the host's notice
// that it switched comes about 150 ms before that frame, and the old one is still stretched.
- (void)hideFreeWindowFrostIfPictureFits {
    if (self.freeWindowFrostView.superview == nil || self.view.window.inLiveResize ||
        ![self freeWindowStreamMatchesSize:self.freeWindowDecodedSize]) {
        return;
    }
    NSUInteger generation = self.freeWindowFrostGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MLFreeWindowFrostPresentDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf != nil && strongSelf.freeWindowFrostGeneration == generation &&
            !strongSelf.view.window.inLiveResize) {
            [strongSelf hideFreeWindowFrost];
        }
    });
}

#pragma mark - NSWindowDelegate

- (void)windowWillStartLiveResize:(NSNotification *)notification {
    if (!self.freeWindowActive || notification.object != self.view.window) {
        return;
    }
    [self showFreeWindowFrostAnimated:NO];
}

- (void)windowDidResize:(NSNotification *)notification {
    if (!self.freeWindowActive || notification.object != self.view.window) {
        return;
    }
    BOOL live = self.view.window.inLiveResize;
    if (!live && self.freeWindowFrostView.superview == nil) {
        struct Resolution current = [self effectiveStreamResolution];
        if (![self freeWindowStreamMatchesSize:CGSizeMake(current.width, current.height)]) {
            [self showFreeWindowFrostAnimated:YES];
        }
    }
    [self scheduleFreeWindowResolutionUpdateAfter:live ? MLFreeWindowLiveResizeDelay : MLFreeWindowSettleDelay];
}

- (void)windowDidEndLiveResize:(NSNotification *)notification {
    if (!self.freeWindowActive || notification.object != self.view.window) {
        return;
    }
    [self noteFreeWindowContentSizeIfWindowed];
    [self scheduleFreeWindowResolutionUpdateAfter:0];
}

- (void)windowDidChangeBackingProperties:(NSNotification *)notification {
    if (!self.freeWindowActive || notification.object != self.view.window) {
        return;
    }
    // A screen with another scale: Every Pixel means another size, and another host scale.
    self.freeWindowHostScaleApplied = NO;
    [self freeWindowRemoteScaleOptionsChanged];
    [self scheduleFreeWindowResolutionUpdateAfter:MLFreeWindowSettleDelay];
}

#pragma mark - Requests

- (void)scheduleFreeWindowResolutionUpdateAfter:(NSTimeInterval)delay {
    self.freeWindowResizeGeneration += 1;
    NSUInteger generation = self.freeWindowResizeGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil || strongSelf.freeWindowResizeGeneration != generation) {
            return;
        }
        [strongSelf sendFreeWindowResolutionIfNeeded];
    });
}

- (void)sendFreeWindowResolutionIfNeeded {
    if (!self.freeWindowActive || self.view.window == nil) {
        return;
    }
    uint64_t now = LiGetMillis();
    if (self.freeWindowRequestInFlight && now - self.freeWindowRequestStartMs < MLFreeWindowRequestTimeoutMs) {
        // The host's answer sends whatever size the window has by then.
        return;
    }
    self.freeWindowRequestInFlight = NO;

    NSSize target = [self freeWindowTargetStreamSize];
    struct Resolution current = [self effectiveStreamResolution];
    if ((int)target.width == current.width && (int)target.height == current.height) {
        [self hideFreeWindowFrostIfPictureFits];
        return;
    }
    Connection *connection = [self liveStreamConnectionIfSupported];
    if (connection == nil) {
        [self hideFreeWindowFrost];
        return;
    }
    int result = [connection sendLiveStreamResolutionWidth:(int)target.width height:(int)target.height];
    if (result != 0) {
        Log(LOG_W, @"[free-window] %.0fx%.0f not sent (result=%d)", target.width, target.height, result);
        return;
    }
    self.freeWindowRequestInFlight = YES;
    self.freeWindowRequestStartMs = now;
    Log(LOG_I, @"[free-window] asked for %.0fx%.0f (view %.0fx%.0f pt, stream %dx%d)",
        target.width, target.height, NSWidth(self.view.bounds), NSHeight(self.view.bounds),
        current.width, current.height);

    NSUInteger generation = self.activeStreamGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MLFreeWindowRequestTimeoutMs * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil || strongSelf.activeStreamGeneration != generation ||
            !strongSelf.freeWindowRequestInFlight ||
            LiGetMillis() - strongSelf.freeWindowRequestStartMs < MLFreeWindowRequestTimeoutMs) {
            return;
        }
        Log(LOG_W, @"[free-window] no answer from the host; sending the current size again");
        [strongSelf sendFreeWindowResolutionIfNeeded];
    });
}

- (void)freeWindowHostResolutionChanged {
    if (!self.freeWindowActive) {
        return;
    }
    self.freeWindowRequestInFlight = NO;
    NSTimeInterval delay = self.view.window.inLiveResize ? MLFreeWindowLiveResizeDelay : 0;
    [self scheduleFreeWindowResolutionUpdateAfter:delay];
}

#pragma mark - Session

- (void)watchDecodedSizeOfConnection:(Connection *)connection {
    __weak typeof(self) weakSelf = self;
    connection.renderer.decodedSizeChangedHandler = ^(CGSize size) {
        [weakSelf freeWindowDecodedSizeChanged:size];
    };
}

- (void)freeWindowConnectionStarted:(Connection *)connection {
    if (!self.freeWindowActive) {
        return;
    }
    if (![connection supportsLiveStreamChanges]) {
        [self leaveFreeWindowKeepingStreamShape];
        [self showNotification:MLString(@"Free Window fallback notice", nil) forSeconds:6.0];
        Log(LOG_W, @"[free-window] host cannot change resolution live; using a fixed aspect window");
        return;
    }
    self.freeWindowHostScaleApplied = NO;
    [self watchDecodedSizeOfConnection:connection];
    [self freeWindowRemoteScaleOptionsChanged];
    // The window may have been resized while connecting.
    [self scheduleFreeWindowResolutionUpdateAfter:MLFreeWindowSettleDelay];
}

// Every Pixel gives the host as many pixels as the Mac shows, so Windows scales by the same
// factor as macOS, or text would be half the size. Once per session and screen scale.
- (void)freeWindowRemoteScaleOptionsChanged {
    if (!self.freeWindowActive || self.freeWindowHostScaleApplied ||
        ![SettingsClass freeWindowUsesPixelsFor:self.app.host.uuid]) {
        return;
    }
    MLRemoteDisplayScale *scale = self.remoteDisplayScale;
    if (scale == nil || scale.awaitingFirstQuery || scale.support != MLRemoteDisplayScaleSupportAvailable) {
        return;
    }
    self.freeWindowHostScaleApplied = YES;

    NSInteger wanted = lround(MAX(1.0, self.view.window.backingScaleFactor) * 100.0);
    NSInteger best = 0;
    for (NSNumber *percent in scale.supportedPercents) {
        if (best == 0 || labs(percent.integerValue - wanted) < labs(best - wanted)) {
            best = percent.integerValue;
        }
    }
    if (best <= 0 || best == scale.currentPercent) {
        return;
    }
    Log(LOG_I, @"[free-window] host display scale %ld%% -> %ld%%", (long)scale.currentPercent, (long)best);
    [scale applyManualPercent:best completion:^(NSDictionary<NSString *, id> *outcome) {
        Log(LOG_I, @"[free-window] host display scale result: %@", outcome);
    }];
}

- (void)leaveFreeWindowKeepingStreamShape {
    [self hideFreeWindowFrost];
    self.freeWindowActive = NO;
    self.freeWindowRequestInFlight = NO;
    NSDictionary *prefs = [SettingsClass getSettingsFor:self.app.host.uuid];
    self.streamMan.connection.renderer.stretchToFill = [prefs[@"ignoreAspectRatio"] boolValue];

    NSWindow *window = self.view.window;
    struct Resolution res = [self effectiveStreamResolution];
    if (window == nil || res.width <= 0 || res.height <= 0) {
        return;
    }
    NSSize aspect = NSMakeSize(res.width, res.height);
    if (self.savedContentAspectRatioValid) {
        // Borderless restores this when it ends.
        self.savedContentAspectRatio = aspect;
        return;
    }
    if ([self isWindowFullscreen]) {
        return;
    }
    window.contentAspectRatio = aspect;
    NSSize content = window.contentView.bounds.size;
    [window setContentSize:NSMakeSize(content.width, round(content.width * res.height / (CGFloat)res.width))];
}

#pragma mark - Menu

- (void)switchToFreeWindowMode:(id)sender {
    [SettingsClass setDisplayMode:MLDisplayModeFreeWindow for:self.app.host.uuid];
    Connection *connection = self.streamMan.connection;
    if (connection != nil && ![connection supportsLiveStreamChanges]) {
        [self showNotification:MLString(@"Free Window fallback notice", nil) forSeconds:6.0];
        return;
    }
    self.freeWindowActive = YES;
    self.freeWindowHostScaleApplied = NO;
    self.streamMan.connection.renderer.stretchToFill = YES;
    if (connection != nil) {
        struct Resolution current = [self effectiveStreamResolution];
        self.freeWindowDecodedSize = CGSizeMake(current.width, current.height);
        [self watchDecodedSizeOfConnection:connection];
    }
    if ([self isWindowFullscreen] || [self isWindowBorderlessMode]) {
        // The window comes back through applyWindowedMode, which restores a free window.
        [self switchToWindowedMode:sender];
    } else {
        [self unlockWindowShape:self.view.window];
    }
    [self freeWindowRemoteScaleOptionsChanged];
    [self scheduleFreeWindowResolutionUpdateAfter:MLFreeWindowSettleDelay];
}

- (void)switchToFixedAspectWindowMode:(id)sender {
    [SettingsClass setDisplayMode:MLDisplayModeFixedWindow for:self.app.host.uuid];
    BOOL wasFree = self.freeWindowActive;
    if (wasFree) {
        [self leaveFreeWindowKeepingStreamShape];
    }
    if ([self isWindowFullscreen] || [self isWindowBorderlessMode]) {
        [self switchToWindowedMode:sender];
    }
}

@end
