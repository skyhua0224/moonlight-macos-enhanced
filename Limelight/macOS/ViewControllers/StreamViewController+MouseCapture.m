//
//  StreamViewController+MouseCapture.m
//  Moonlight for macOS
//

#import "StreamViewController_Internal.h"

static inline BOOL MLCGCursorIsVisibleCompat(void) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return CGCursorIsVisible();
#pragma clang diagnostic pop
}

@implementation StreamViewController (MouseCapture)

- (CGDirectDisplayID)cursorDisplayIDForCurrentWindow {
    NSScreen *screen = self.view.window.screen;
    NSNumber *screenNumber = screen.deviceDescription[@"NSScreenNumber"];
    return screenNumber != nil ? (CGDirectDisplayID)screenNumber.unsignedIntValue : CGMainDisplayID();
}

- (void)reassertHiddenLocalCursorIfNeededWithReason:(NSString *)reason {
    if (!self.isMouseCaptured || self.stopStreamInProgress || self.reconnectInProgress) {
        return;
    }

    NSDictionary* prefs = [SettingsClass getSettingsFor:self.app.host.uuid];
    BOOL showLocalCursor = prefs ? [prefs[@"showLocalCursor"] boolValue] : NO;
    if (showLocalCursor) {
        return;
    }

    [self.streamView refreshPreferredLocalCursor];

    BOOL cgVisible = MLCGCursorIsVisibleCompat();
    if (!cgVisible) {
        return;
    }

    CGDirectDisplayID displayID = [self cursorDisplayIDForCurrentWindow];
    CGError error = CGDisplayHideCursor(displayID);
    if (error == kCGErrorSuccess) {
        self.cgCursorHiddenCounter += 1;
        Log(LOG_I, @"[diag] Reasserted hidden local cursor: reason=%@ display=%u cgDepth=%d nsDepth=%d",
            reason ?: @"unknown",
            (unsigned int)displayID,
            self.cgCursorHiddenCounter,
            self.cursorHiddenCounter);
    } else {
        Log(LOG_W, @"[diag] Failed to re-hide local cursor: reason=%@ error=%d",
            reason ?: @"unknown",
            (int)error);
    }
}

- (BOOL)reasonAllowsImmediateCaptureInFreeMouseMode:(NSString *)reason {
    static NSSet<NSString *> *allowedReasons;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        allowedReasons = [NSSet setWithArray:@[
            @"mouse-entered-view",
            @"mouse-exited-view-reentry",
            @"free-mouse-pointer-engaged",
            @"free-mouse-edge-return",
            @"mouse-mode-changed",
            @"window-became-key",
            @"app-became-active",
            @"space-transition-finished",
            @"window-entered-fullscreen",
            @"window-exited-fullscreen",
        ]];
    });

    return reason != nil && [allowedReasons containsObject:reason];
}

- (BOOL)remoteDesktopCaptureReasonRequiresPointerInside:(NSString *)reason {
    if (reason == nil) {
        return NO;
    }

    return [reason isEqualToString:@"window-became-key"] ||
           [reason isEqualToString:@"app-became-active"] ||
           [reason isEqualToString:@"space-transition-finished"] ||
           [reason isEqualToString:@"window-entered-fullscreen"] ||
           [reason isEqualToString:@"window-exited-fullscreen"] ||
           [reason isEqualToString:@"mouse-exited-view-reentry"];
}

- (uint64_t)freeMouseEdgeUncaptureSuppressionDurationMsForReason:(NSString *)reason {
    if (reason == nil) {
        return 0;
    }

    if ([reason isEqualToString:@"space-transition-finished"]) {
        return 1200;
    }

    if ([reason isEqualToString:@"window-became-key"] ||
        [reason isEqualToString:@"app-became-active"]) {
        return 900;
    }

    if ([reason isEqualToString:@"window-entered-fullscreen"] ||
        [reason isEqualToString:@"window-exited-fullscreen"]) {
        return 700;
    }

    return 0;
}

- (void)scheduleDeferredMouseCaptureRearmWithReason:(NSString *)reason delay:(NSTimeInterval)delay {
    if (reason.length == 0) {
        return;
    }

    NSUInteger token = self.pendingMouseCaptureRetryToken;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || token != strongSelf.pendingMouseCaptureRetryToken) {
            return;
        }
        [strongSelf rearmMouseCaptureIfPossibleWithReason:reason];
    });
}

- (NSPoint)currentMouseLocationInViewCoordinates {
    if (!self.view.window) {
        return NSZeroPoint;
    }

    NSPoint mouseLocation = [NSEvent mouseLocation];
    NSPoint windowPoint = [self.view.window convertPointFromScreen:mouseLocation];
    return [self.view convertPoint:windowPoint fromView:nil];
}

- (BOOL)shouldUseCurrentPointerSemanticLocationForMouseEvent:(NSEvent *)event {
    if (event == nil || !self.view.window || !self.isRemoteDesktopMode) {
        return NO;
    }
    if ([self usesAbsoluteRemoteDesktopPointerSync]) {
        return NO;
    }

    return self.isMouseCaptured ||
           self.edgeMenuTemporaryReleaseActive ||
           self.pendingMouseExitedRecapture ||
           self.pendingFreeMouseReentryEdge != MLFreeMouseExitEdgeNone;
}

- (BOOL)shouldPreferCurrentPointerLocationForMouseEvent:(NSEvent *)event
                                             eventPoint:(NSPoint)eventPoint
                                           currentPoint:(NSPoint)currentPoint {
    if (event == nil || event.window != self.view.window || !self.view.window) {
        return NO;
    }
    if (!self.isRemoteDesktopMode || !self.isMouseCaptured) {
        return NO;
    }
    if ([self usesAbsoluteRemoteDesktopPointerSync]) {
        return NO;
    }

    if (!isfinite(eventPoint.x) || !isfinite(eventPoint.y) ||
        !isfinite(currentPoint.x) || !isfinite(currentPoint.y)) {
        return YES;
    }

    NSRect toleranceBounds = NSInsetRect(self.view.bounds, -96.0, -96.0);
    BOOL eventNearView = NSPointInRect(eventPoint, toleranceBounds);
    BOOL currentNearView = NSPointInRect(currentPoint, toleranceBounds);
    if (eventNearView != currentNearView) {
        return YES;
    }

    CGFloat deltaX = fabs(eventPoint.x - currentPoint.x);
    CGFloat deltaY = fabs(eventPoint.y - currentPoint.y);
    return deltaX >= 6.0 || deltaY >= 6.0;
}

- (NSPoint)viewPointForMouseEvent:(NSEvent *)event {
    if ([self shouldUseCurrentPointerSemanticLocationForMouseEvent:event]) {
        return [self currentMouseLocationInViewCoordinates];
    }

    if (event.window == self.view.window) {
        NSPoint eventPoint = [self.view convertPoint:event.locationInWindow fromView:nil];
        NSPoint currentPoint = [self currentMouseLocationInViewCoordinates];
        if ([self shouldPreferCurrentPointerLocationForMouseEvent:event
                                                       eventPoint:eventPoint
                                                     currentPoint:currentPoint]) {
            return currentPoint;
        }
        return eventPoint;
    }

    return [self currentMouseLocationInViewCoordinates];
}

- (NSPoint)screenPointForMouseEvent:(NSEvent *)event {
    if ([self shouldUseCurrentPointerSemanticLocationForMouseEvent:event]) {
        return [NSEvent mouseLocation];
    }

    if (event.window != nil) {
        NSPoint screenPoint = [event.window convertPointToScreen:event.locationInWindow];
        if (event.window == self.view.window) {
            NSPoint eventPoint = [self.view convertPoint:event.locationInWindow fromView:nil];
            NSPoint currentPoint = [self currentMouseLocationInViewCoordinates];
            if ([self shouldPreferCurrentPointerLocationForMouseEvent:event
                                                           eventPoint:eventPoint
                                                         currentPoint:currentPoint]) {
                return [NSEvent mouseLocation];
            }
        }
        return screenPoint;
    }

    return [NSEvent mouseLocation];
}

- (BOOL)isCurrentPointerInsideStreamView {
    if (!self.view.window) {
        return NO;
    }

    return NSPointInRect([self currentMouseLocationInViewCoordinates], self.view.bounds);
}

- (void)logMouseClickDiagnosticsForPhase:(NSString *)phase event:(NSEvent *)event {
    NSPoint windowPoint = event.window == self.view.window ? event.locationInWindow : [self.view.window convertPointFromScreen:[self screenPointForMouseEvent:event]];
    NSPoint viewPoint = [self viewPointForMouseEvent:event];
    NSPoint screenPoint = [self screenPointForMouseEvent:event];
    NSPoint globalPoint = [NSEvent mouseLocation];
    BOOL insideView = NSPointInRect(viewPoint, self.view.bounds);

    short remoteTargetX = 0;
    short remoteTargetY = 0;
    short remoteTargetWidth = 0;
    short remoteTargetHeight = 0;
    BOOL hasRemoteTarget = [self.hidSupport absoluteMousePayloadForViewPoint:viewPoint
                                                               referenceSize:self.view.bounds.size
                                                               clampToBounds:YES
                                                                       hostX:&remoteTargetX
                                                                       hostY:&remoteTargetY
                                                              referenceWidth:&remoteTargetWidth
                                                             referenceHeight:&remoteTargetHeight];

    short remoteLastX = 0;
    short remoteLastY = 0;
    short remoteLastWidth = 0;
    short remoteLastHeight = 0;
    uint64_t remoteLastAgeMs = 0;
    NSString *remoteLastSource = nil;
    BOOL hasRemoteLast = [self.hidSupport getLastAbsolutePointerHostX:&remoteLastX
                                                                hostY:&remoteLastY
                                                       referenceWidth:&remoteLastWidth
                                                      referenceHeight:&remoteLastHeight
                                                                ageMs:&remoteLastAgeMs
                                                               source:&remoteLastSource];

    NSString *remoteTargetSummary = hasRemoteTarget
        ? [NSString stringWithFormat:@"(%d,%d)/%dx%d", remoteTargetX, remoteTargetY, remoteTargetWidth, remoteTargetHeight]
        : @"n/a";
    NSString *remoteLastSummary = hasRemoteLast
        ? [NSString stringWithFormat:@"(%d,%d)/%dx%d age=%llums src=%@",
           remoteLastX,
           remoteLastY,
           remoteLastWidth,
           remoteLastHeight,
           remoteLastAgeMs,
           remoteLastSource ?: @"unknown"]
        : @"n/a";

    NSString *summary = [NSString stringWithFormat:@"phase=%@ btn=%ld clickCount=%ld eventType=%ld localScreen=(%.1f,%.1f) global=(%.1f,%.1f) localWindow=(%.1f,%.1f) localView=(%.1f,%.1f) insideView=%d remoteTarget=%@ remoteLast=%@ captured=%d key=%d fullscreen=%d",
                         phase ?: @"unknown",
                         (long)event.buttonNumber,
                         (long)event.clickCount,
                         (long)event.type,
                         screenPoint.x,
                         screenPoint.y,
                         globalPoint.x,
                         globalPoint.y,
                         windowPoint.x,
                         windowPoint.y,
                         viewPoint.x,
                         viewPoint.y,
                         insideView ? 1 : 0,
                         remoteTargetSummary,
                         remoteLastSummary,
                         self.isMouseCaptured ? 1 : 0,
                         self.view.window.isKeyWindow ? 1 : 0,
                         [self isWindowFullscreen] ? 1 : 0];

    self.lastMouseClickDiagnosticsAtMs = [self nowMs];
    self.lastMouseClickDiagnosticsSummary = summary;
    self.lastMouseClickPhase = phase ?: @"unknown";
    self.lastMouseClickViewPoint = viewPoint;
    self.lastMouseClickInsideView = insideView;
    Log(LOG_D, @"[clickdiag] %@", summary);
}

- (void)logMouseExitDiagnosticsForEvent:(NSEvent *)event stage:(NSString *)stage {
    NSPoint eventPoint = [self viewPointForMouseEvent:event];
    NSPoint currentPoint = [self currentMouseLocationInViewCoordinates];
    NSRect bounds = self.view.bounds;
    uint64_t clickAgeMs = 0;
    if (self.lastMouseClickDiagnosticsAtMs > 0) {
        uint64_t now = [self nowMs];
        clickAgeMs = now >= self.lastMouseClickDiagnosticsAtMs ? (now - self.lastMouseClickDiagnosticsAtMs) : 0;
    }

    Log(LOG_I, @"[diag] Mouse exit event: stage=%@ eventType=%ld eventView=(%.1f,%.1f) currentView=(%.1f,%.1f) insideEvent=%d insideCurrent=%d bounds=%.1fx%.1f clickAge=%llums lastClickPhase=%@ lastClickView=(%.1f,%.1f) lastClickInside=%d captured=%d key=%d main=%d fullscreen=%d",
        stage ?: @"unknown",
        (long)event.type,
        eventPoint.x,
        eventPoint.y,
        currentPoint.x,
        currentPoint.y,
        NSPointInRect(eventPoint, bounds) ? 1 : 0,
        NSPointInRect(currentPoint, bounds) ? 1 : 0,
        bounds.size.width,
        bounds.size.height,
        clickAgeMs,
        self.lastMouseClickPhase ?: @"none",
        self.lastMouseClickViewPoint.x,
        self.lastMouseClickViewPoint.y,
        self.lastMouseClickInsideView ? 1 : 0,
        self.isMouseCaptured ? 1 : 0,
        self.view.window.isKeyWindow ? 1 : 0,
        self.view.window.isMainWindow ? 1 : 0,
        [self isWindowFullscreen] ? 1 : 0);
}

- (BOOL)hasRecentTopEdgeClickWithinMs:(uint64_t)maxAgeMs {
    if (self.lastMouseClickDiagnosticsAtMs == 0) {
        return NO;
    }

    uint64_t now = [self nowMs];
    if (now < self.lastMouseClickDiagnosticsAtMs || (now - self.lastMouseClickDiagnosticsAtMs) > maxAgeMs) {
        return NO;
    }

    NSRect bounds = self.view.bounds;
    if (NSIsEmptyRect(bounds) || !self.lastMouseClickInsideView) {
        return NO;
    }

    CGFloat topBand = MIN(48.0, MAX(24.0, bounds.size.height * 0.06));
    return self.lastMouseClickViewPoint.y >= NSMaxY(bounds) - topBand;
}

- (BOOL)shouldSuppressMouseExitedUncaptureForEvent:(NSEvent *)event {
    if (!self.isRemoteDesktopMode || !self.isMouseCaptured || ![self isWindowFullscreen]) {
        return NO;
    }
    if (![self hasRecentTopEdgeClickWithinMs:450]) {
        return NO;
    }

    NSRect bounds = self.view.bounds;
    NSPoint eventPoint = [self viewPointForMouseEvent:event];
    NSPoint currentPoint = [self currentMouseLocationInViewCoordinates];
    CGFloat topTolerance = 8.0;
    CGFloat sideTolerance = 32.0;
    BOOL eventNearTop = eventPoint.y >= NSMaxY(bounds) - topTolerance;
    BOOL currentNearTop = currentPoint.y >= NSMaxY(bounds) - topTolerance;
    CGFloat deltaX = eventPoint.x - currentPoint.x;
    if (deltaX < 0) {
        deltaX = -deltaX;
    }
    CGFloat deltaY = eventPoint.y - currentPoint.y;
    if (deltaY < 0) {
        deltaY = -deltaY;
    }
    CGFloat bogusDeltaXThreshold = MAX(160.0, bounds.size.width * 0.25);
    CGFloat bogusDeltaYThreshold = MAX(120.0, bounds.size.height * 0.20);
    BOOL eventLooksBogus = deltaX >= bogusDeltaXThreshold || deltaY >= bogusDeltaYThreshold;
    BOOL currentHorizontallyInside =
        currentPoint.x >= NSMinX(bounds) - sideTolerance &&
        currentPoint.x <= NSMaxX(bounds) + sideTolerance;
    BOOL clickHorizontallyInside =
        self.lastMouseClickViewPoint.x >= NSMinX(bounds) - sideTolerance &&
        self.lastMouseClickViewPoint.x <= NSMaxX(bounds) + sideTolerance;

    return (eventNearTop || currentNearTop || eventLooksBogus) &&
           currentHorizontallyInside &&
           clickHorizontallyInside &&
           [NSApp isActive] &&
           self.view.window.isKeyWindow;
}

- (void)logKeyLossDiagnosticsForStage:(NSString *)stage code:(NSString *)code reason:(NSString *)reason {
    NSWindow *window = self.view.window;
    NSPoint currentPoint = [self currentMouseLocationInViewCoordinates];
    NSRect bounds = self.view.bounds;
    BOOL pointerInside = NSPointInRect(currentPoint, bounds);
    BOOL windowInCurrentSpace = [self isWindowInCurrentSpace];

    NSString *clickAgeSummary = @"n/a";
    if (self.lastMouseClickDiagnosticsAtMs > 0) {
        uint64_t now = [self nowMs];
        uint64_t clickAgeMs = now >= self.lastMouseClickDiagnosticsAtMs ? (now - self.lastMouseClickDiagnosticsAtMs) : 0;
        clickAgeSummary = [NSString stringWithFormat:@"%llums", clickAgeMs];
    }

    Log(LOG_I, @"[diag] Key loss event: stage=%@ code=%@ reason=%@ appActive=%d currentSpace=%d key=%d main=%d captured=%d fullscreen=%d fullscreenTransition=%d pointerInside=%d currentView=(%.1f,%.1f) bounds=%.1fx%.1f recentTopEdge=%d clickAge=%@ lastClickPhase=%@ lastClickView=(%.1f,%.1f) lastClickInside=%d",
        stage ?: @"unknown",
        code ?: @"MUC000",
        reason ?: @"unspecified",
        [NSApp isActive] ? 1 : 0,
        windowInCurrentSpace ? 1 : 0,
        window.isKeyWindow ? 1 : 0,
        window.isMainWindow ? 1 : 0,
        self.isMouseCaptured ? 1 : 0,
        [self isWindowFullscreen] ? 1 : 0,
        self.fullscreenTransitionInProgress ? 1 : 0,
        pointerInside ? 1 : 0,
        currentPoint.x,
        currentPoint.y,
        bounds.size.width,
        bounds.size.height,
        [self hasRecentTopEdgeClickWithinMs:450] ? 1 : 0,
        clickAgeSummary,
        self.lastMouseClickPhase ?: @"none",
        self.lastMouseClickViewPoint.x,
        self.lastMouseClickViewPoint.y,
        self.lastMouseClickInsideView ? 1 : 0);
}

- (BOOL)shouldSuppressTransientKeyLossUncaptureForCode:(NSString *)code reason:(__unused NSString *)reason {
    if (!([code isEqualToString:@"MUC003"] || [code isEqualToString:@"MUC005"])) {
        return NO;
    }
    if (!self.isRemoteDesktopMode || !self.isMouseCaptured || ![self isWindowFullscreen]) {
        return NO;
    }
    if (![NSApp isActive]) {
        return NO;
    }
    if (self.stopStreamInProgress || self.reconnectInProgress || self.fullscreenTransitionInProgress) {
        return NO;
    }
    if (![self hasRecentTopEdgeClickWithinMs:450]) {
        return NO;
    }
    return [self isCurrentPointerInsideStreamView];
}

- (void)scheduleTransientKeyLossRecoveryWithReason:(NSString *)reason {
    [self ensureStreamWindowKeyIfPossible];

    __weak typeof(self) weakSelf = self;
    NSArray<NSNumber *> *delays = @[@0.06, @0.18, @0.40];
    for (NSNumber *delayNumber in delays) {
        NSTimeInterval delay = delayNumber.doubleValue;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || !strongSelf.isMouseCaptured) {
                return;
            }
            if (![NSApp isActive] || strongSelf.stopStreamInProgress || strongSelf.reconnectInProgress) {
                return;
            }
            Log(LOG_D, @"[diag] Transient key loss recovery attempt: reason=%@ delay=%.2f key=%d main=%d pointerInside=%d",
                reason ?: @"unknown",
                delay,
                strongSelf.view.window.isKeyWindow ? 1 : 0,
                strongSelf.view.window.isMainWindow ? 1 : 0,
                [strongSelf isCurrentPointerInsideStreamView] ? 1 : 0);
            [strongSelf ensureStreamWindowKeyIfPossible];
        });
    }
}

- (void)logPointerContextForReason:(NSString *)reason {
    NSPoint localViewPoint = [self currentMouseLocationInViewCoordinates];
    NSPoint globalPoint = [NSEvent mouseLocation];

    short remoteLastX = 0;
    short remoteLastY = 0;
    short remoteLastWidth = 0;
    short remoteLastHeight = 0;
    uint64_t remoteLastAgeMs = 0;
    NSString *remoteLastSource = nil;
    BOOL hasRemoteLast = [self.hidSupport getLastAbsolutePointerHostX:&remoteLastX
                                                                hostY:&remoteLastY
                                                       referenceWidth:&remoteLastWidth
                                                      referenceHeight:&remoteLastHeight
                                                                ageMs:&remoteLastAgeMs
                                                               source:&remoteLastSource];

    NSString *lastClickSummary = @"none";
    if (self.lastMouseClickDiagnosticsSummary.length > 0 && self.lastMouseClickDiagnosticsAtMs > 0) {
        uint64_t now = [self nowMs];
        uint64_t ageMs = now >= self.lastMouseClickDiagnosticsAtMs ? (now - self.lastMouseClickDiagnosticsAtMs) : 0;
        lastClickSummary = [NSString stringWithFormat:@"age=%llums %@", ageMs, self.lastMouseClickDiagnosticsSummary];
    }

    Log(LOG_D, @"[clickdiag] trigger=%@ localView=(%.1f,%.1f) global=(%.1f,%.1f) remoteLast=%@ lastClick=%@",
        reason ?: @"unknown",
        localViewPoint.x,
        localViewPoint.y,
        globalPoint.x,
        globalPoint.y,
        hasRemoteLast
            ? [NSString stringWithFormat:@"(%d,%d)/%dx%d age=%llums src=%@",
               remoteLastX,
               remoteLastY,
               remoteLastWidth,
               remoteLastHeight,
               remoteLastAgeMs,
               remoteLastSource ?: @"unknown"]
            : @"n/a",
        lastClickSummary);
}

- (BOOL)hasPressedMouseButtonsForCaptureTransition {
    return [NSEvent pressedMouseButtons] != 0 || [self.hidSupport hasPressedMouseButtons];
}

- (void)requestMouseUncaptureWhenSafeWithReason:(NSString *)reason {
    [self requestMouseUncaptureWhenSafeWithReason:reason code:@"MUC000"];
}

- (void)logMouseUncaptureStage:(NSString *)stage code:(NSString *)code reason:(NSString *)reason {
    NSString *resolvedStage = stage.length > 0 ? stage : @"unknown";
    NSString *resolvedCode = code.length > 0 ? code : @"MUC000";
    NSString *resolvedReason = reason.length > 0 ? reason : @"unspecified";
    NSUInteger pressedButtons = [NSEvent pressedMouseButtons];
    BOOL windowKey = self.view.window != nil && self.view.window.isKeyWindow;
    BOOL windowMain = self.view.window != nil && self.view.window.isMainWindow;
    Log(LOG_I, @"[diag] Mouse uncapture: stage=%@ code=%@ reason=%@ captured=%d hidden=%ld input=%d buttons=%lu key=%d main=%d fullscreen=%d",
        resolvedStage,
        resolvedCode,
        resolvedReason,
        self.isMouseCaptured ? 1 : 0,
        (long)self.cursorHiddenCounter,
        self.hidSupport.shouldSendInputEvents ? 1 : 0,
        (unsigned long)pressedButtons,
        windowKey ? 1 : 0,
        windowMain ? 1 : 0,
        [self isWindowFullscreen] ? 1 : 0);
}

- (void)requestMouseUncaptureWhenSafeWithReason:(NSString *)reason code:(NSString *)code {
    [self logMouseUncaptureStage:@"request-safe" code:code reason:reason];
    if (!self.isMouseCaptured) {
        self.pendingMouseUncaptureAfterButtonsReleased = NO;
        self.pendingMouseUncaptureDiagnosticCode = nil;
        self.pendingMouseUncaptureDiagnosticReason = nil;
        [self logMouseUncaptureStage:@"skip-not-captured" code:code reason:reason];
        return;
    }

    if ([self hasPressedMouseButtonsForCaptureTransition]) {
        self.pendingMouseUncaptureAfterButtonsReleased = YES;
        self.pendingMouseUncaptureDiagnosticCode = code.length > 0 ? code : @"MUC000";
        self.pendingMouseUncaptureDiagnosticReason = reason ?: @"unspecified";
        [self logMouseUncaptureStage:@"deferred" code:self.pendingMouseUncaptureDiagnosticCode reason:self.pendingMouseUncaptureDiagnosticReason];
        return;
    }

    self.pendingMouseUncaptureAfterButtonsReleased = NO;
    self.pendingMouseUncaptureDiagnosticCode = nil;
    self.pendingMouseUncaptureDiagnosticReason = nil;
    [self uncaptureMouseWithCode:code reason:reason];
}

- (void)completeDeferredMouseUncaptureIfNeeded {
    if (!self.pendingMouseUncaptureAfterButtonsReleased) {
        return;
    }
    if ([self hasPressedMouseButtonsForCaptureTransition]) {
        return;
    }

    self.pendingMouseUncaptureAfterButtonsReleased = NO;
    if (!self.isMouseCaptured) {
        [self logMouseUncaptureStage:@"deferred-skip-not-captured"
                                code:self.pendingMouseUncaptureDiagnosticCode
                              reason:self.pendingMouseUncaptureDiagnosticReason];
        self.pendingMouseUncaptureDiagnosticCode = nil;
        self.pendingMouseUncaptureDiagnosticReason = nil;
        return;
    }

    if ([self canCaptureMouseNow]) {
        [self logMouseUncaptureStage:@"deferred-canceled-recovered"
                                code:self.pendingMouseUncaptureDiagnosticCode
                              reason:self.pendingMouseUncaptureDiagnosticReason];
        self.pendingMouseUncaptureDiagnosticCode = nil;
        self.pendingMouseUncaptureDiagnosticReason = nil;
        return;
    }

    NSString *code = self.pendingMouseUncaptureDiagnosticCode;
    NSString *reason = self.pendingMouseUncaptureDiagnosticReason;
    self.pendingMouseUncaptureDiagnosticCode = nil;
    self.pendingMouseUncaptureDiagnosticReason = nil;
    [self logMouseUncaptureStage:@"deferred-commit" code:code reason:reason];
    [self uncaptureMouseWithCode:code reason:reason];
}

- (BOOL)supportsRemoteDesktopCursorSync {
    return self.isRemoteDesktopMode;
}

- (BOOL)usesAbsoluteRemoteDesktopPointerSync {
    if (![self supportsRemoteDesktopCursorSync]) {
        return NO;
    }
    if (self.hidSupport != nil) {
        return [self.hidSupport shouldUseAbsolutePointerPathForCurrentConfiguration];
    }
    return ![SettingsClass shouldUseHybridFreeMouseMotionFor:self.app.host.uuid];
}

- (BOOL)rearmReasonAlreadySyncedRemoteCursorFromEvent:(NSString *)reason {
    static NSSet<NSString *> *eventSyncedReasons;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        eventSyncedReasons = [NSSet setWithArray:@[
            @"mouse-entered-view",
            @"free-mouse-pointer-engaged",
            @"free-mouse-edge-return",
        ]];
    });

    return reason != nil && [eventSyncedReasons containsObject:reason];
}

- (void)syncRemoteCursorToCurrentPointerClamped {
    if (![self supportsRemoteDesktopCursorSync] || ![self hasReadyInputContext] || !self.view.window) {
        return;
    }
    if (self.edgeMenuTemporaryReleaseActive || self.edgeMenuDragging || self.edgeMenuMenuVisible) {
        return;
    }

    NSPoint currentPoint = [self currentMouseLocationInViewCoordinates];
    if (! [self usesAbsoluteRemoteDesktopPointerSync]) {
        NSRect toleranceBounds = NSInsetRect(self.view.bounds, -2.0, -2.0);
        if (!NSPointInRect(currentPoint, toleranceBounds)) {
            return;
        }
    }
    [self.hidSupport updateFreeMouseVirtualCursorAnchorWithViewPoint:currentPoint
                                                      referenceSize:self.view.bounds.size];
    [self.hidSupport sendAbsoluteMousePositionForViewPoint:currentPoint
                                             referenceSize:self.view.bounds.size
                                             clampToBounds:YES];
}

- (NSPoint)resolvedAbsoluteSyncViewPointForMouseEvent:(NSEvent *)event
                                        clampToBounds:(BOOL)clampToBounds
                                               reason:(NSString *)reason {
    NSPoint eventPoint = [self viewPointForMouseEvent:event];
    if (!clampToBounds || !self.isRemoteDesktopMode || !self.isMouseCaptured || ![self isWindowFullscreen]) {
        return eventPoint;
    }

    NSRect bounds = self.view.bounds;
    if (NSIsEmptyRect(bounds)) {
        return eventPoint;
    }

    NSPoint currentPoint = [self currentMouseLocationInViewCoordinates];
    BOOL eventInside = NSPointInRect(eventPoint, bounds);
    BOOL currentInside = NSPointInRect(currentPoint, bounds);
    if (!currentInside) {
        return eventPoint;
    }

    CGFloat deltaX = eventPoint.x - currentPoint.x;
    if (deltaX < 0) {
        deltaX = -deltaX;
    }
    CGFloat deltaY = eventPoint.y - currentPoint.y;
    if (deltaY < 0) {
        deltaY = -deltaY;
    }
    CGFloat bogusDeltaXThreshold = MAX(160.0, bounds.size.width * 0.25);
    CGFloat bogusDeltaYThreshold = MAX(120.0, bounds.size.height * 0.20);
    BOOL eventLooksBogus = !eventInside || deltaX >= bogusDeltaXThreshold || deltaY >= bogusDeltaYThreshold;
    if (!eventLooksBogus) {
        return eventPoint;
    }

    if (![self hasRecentTopEdgeClickWithinMs:1600]) {
        return eventPoint;
    }

    Log(LOG_D, @"[diag] Absolute sync fallback: reason=%@ eventView=(%.1f,%.1f) currentView=(%.1f,%.1f) eventInside=%d currentInside=%d",
        reason ?: @"unknown",
        eventPoint.x,
        eventPoint.y,
        currentPoint.x,
        currentPoint.y,
        eventInside ? 1 : 0,
        currentInside ? 1 : 0);
    return currentPoint;
}

- (void)syncRemoteCursorToMouseEvent:(NSEvent *)event clampToBounds:(BOOL)clampToBounds {
    if (![self supportsRemoteDesktopCursorSync] || ![self hasReadyInputContext] || !self.view.window) {
        return;
    }
    if (self.edgeMenuTemporaryReleaseActive || self.edgeMenuDragging || self.edgeMenuMenuVisible) {
        return;
    }

    NSPoint resolvedPoint = [self resolvedAbsoluteSyncViewPointForMouseEvent:event
                                                               clampToBounds:clampToBounds
                                                                      reason:@"event-sync"];
    [self.hidSupport updateFreeMouseVirtualCursorAnchorWithViewPoint:resolvedPoint
                                                      referenceSize:self.view.bounds.size];
    [self.hidSupport sendAbsoluteMousePositionForViewPoint:resolvedPoint
                                             referenceSize:self.view.bounds.size
                                             clampToBounds:clampToBounds];
}

- (void)syncRemoteCursorBeforeMouseButtonEvent:(NSEvent *)event {
    if (![self supportsRemoteDesktopCursorSync] || ![self hasReadyInputContext]) {
        return;
    }

    NSPoint point = [self viewPointForMouseEvent:event];
    if (!NSPointInRect(point, self.view.bounds)) {
        return;
    }

    [self syncRemoteCursorToMouseEvent:event clampToBounds:YES];
    self.pendingHybridRemoteCursorSync = NO;
}

- (BOOL)consumePendingHybridRemoteCursorSyncForEvent:(NSEvent *)event reason:(NSString *)reason {
    if (!self.pendingHybridRemoteCursorSync ||
        !self.isRemoteDesktopMode ||
        !self.isMouseCaptured ||
        ![self supportsRemoteDesktopCursorSync]) {
        return NO;
    }

    [self reassertHiddenLocalCursorIfNeededWithReason:reason ?: @"hybrid-free-mouse-sync"];
    [self syncRemoteCursorToMouseEvent:event clampToBounds:YES];
    self.pendingHybridRemoteCursorSync = NO;
    Log(LOG_D, @"[diag] Hybrid free mouse cursor sync completed: reason=%@",
        reason ?: @"unknown");
    return YES;
}

- (MLFreeMouseExitEdge)freeMouseExitEdgeForEvent:(NSEvent *)event {
    if (!self.isRemoteDesktopMode || !self.isMouseCaptured) {
        return MLFreeMouseExitEdgeNone;
    }
    if (![self isWindowFullscreen] && ![self isWindowBorderlessMode]) {
        return MLFreeMouseExitEdgeNone;
    }
    if (!self.view.window || !self.view.window.isKeyWindow) {
        return MLFreeMouseExitEdgeNone;
    }

    NSRect bounds = self.view.bounds;
    if (NSIsEmptyRect(bounds)) {
        return MLFreeMouseExitEdgeNone;
    }

    NSPoint point = [self viewPointForMouseEvent:event];
    const CGFloat threshold = 2.0;

    BOOL pushingLeft = point.x <= NSMinX(bounds) + threshold && event.deltaX < 0.0;
    BOOL pushingRight = point.x >= NSMaxX(bounds) - threshold && event.deltaX > 0.0;
    BOOL pushingBottom = point.y <= NSMinY(bounds) + threshold && event.deltaY < 0.0;
    BOOL pushingTop = point.y >= NSMaxY(bounds) - threshold && event.deltaY > 0.0;

    if (pushingLeft) return MLFreeMouseExitEdgeLeft;
    if (pushingRight) return MLFreeMouseExitEdgeRight;
    if (pushingBottom) return MLFreeMouseExitEdgeBottom;
    if (pushingTop) return MLFreeMouseExitEdgeTop;
    return MLFreeMouseExitEdgeNone;
}

- (BOOL)shouldUncaptureFreeMouseForEdgeEvent:(NSEvent *)event {
    uint64_t now = [self nowMs];
    if (self.suppressFreeMouseEdgeUncaptureUntilMs > now) {
        return NO;
    }
    if ([self hasPressedMouseButtonsForCaptureTransition]) {
        return NO;
    }
    MLFreeMouseExitEdge exitEdge = [self freeMouseExitEdgeForEvent:event];
    if (exitEdge == MLFreeMouseExitEdgeNone) {
        return NO;
    }
    return YES;
}

- (void)beginFreeMouseEdgeReentryForExitEdge:(MLFreeMouseExitEdge)exitEdge {
    if (exitEdge == MLFreeMouseExitEdgeNone || !self.view.window || !self.isRemoteDesktopMode || self.isMouseCaptured) {
        return;
    }

    self.pendingFreeMouseReentryEdge = exitEdge;
    self.pendingFreeMouseReentryAtMs = [self nowMs];
    self.view.window.acceptsMouseMovedEvents = YES;
}

- (BOOL)shouldRecaptureFreeMouseAfterEdgeUncaptureForEvent:(NSEvent *)event {
    if (self.pendingFreeMouseReentryEdge == MLFreeMouseExitEdgeNone || self.isMouseCaptured || !self.view.window || !self.isRemoteDesktopMode) {
        return NO;
    }

    uint64_t now = [self nowMs];
    if (now < self.pendingFreeMouseReentryAtMs || (now - self.pendingFreeMouseReentryAtMs) < (uint64_t)MLFreeMouseReentryDelayMs) {
        return NO;
    }

    NSRect bounds = self.view.bounds;
    if (NSIsEmptyRect(bounds)) {
        return NO;
    }

    NSPoint point = [self viewPointForMouseEvent:event];
    switch (self.pendingFreeMouseReentryEdge) {
        case MLFreeMouseExitEdgeLeft:
            return event.deltaX > 0.0 && point.x >= NSMinX(bounds) + MLFreeMouseReentryInset;
        case MLFreeMouseExitEdgeRight:
            return event.deltaX < 0.0 && point.x <= NSMaxX(bounds) - MLFreeMouseReentryInset;
        case MLFreeMouseExitEdgeTop:
            return event.deltaY < 0.0 && point.y <= NSMaxY(bounds) - MLFreeMouseReentryInset;
        case MLFreeMouseExitEdgeBottom:
            return event.deltaY > 0.0 && point.y >= NSMinY(bounds) + MLFreeMouseReentryInset;
        case MLFreeMouseExitEdgeNone:
        default:
            return NO;
    }
}

- (BOOL)recaptureFreeMouseAfterEdgeUncaptureIfNeededForEvent:(NSEvent *)event {
    if (self.edgeMenuTemporaryReleaseActive) {
        return NO;
    }

    if (![self shouldRecaptureFreeMouseAfterEdgeUncaptureForEvent:event]) {
        return NO;
    }

    [self syncRemoteCursorToMouseEvent:event clampToBounds:YES];
    [self rearmMouseCaptureIfPossibleWithReason:@"free-mouse-edge-return"];
    if (self.isMouseCaptured) {
        self.pendingFreeMouseReentryEdge = MLFreeMouseExitEdgeNone;
        self.pendingFreeMouseReentryAtMs = 0;
        return YES;
    }
    return NO;
}

- (BOOL)attemptPendingMouseExitedRecaptureIfNeededForEvent:(NSEvent *)event {
    if (!self.pendingMouseExitedRecapture || self.isMouseCaptured || !self.isRemoteDesktopMode || event == nil) {
        return NO;
    }

    if (!NSPointInRect([self viewPointForMouseEvent:event], self.view.bounds)) {
        return NO;
    }

    self.isMouseInsideView = YES;
    self.globalInactivePointerInsideStreamView = YES;

    if ([self usesAbsoluteRemoteDesktopPointerSync]) {
        [self syncRemoteCursorToMouseEvent:event clampToBounds:YES];
    }

    [self rearmMouseCaptureIfPossibleWithReason:@"mouse-exited-view-reentry"];
    if (self.isMouseCaptured) {
        self.pendingMouseExitedRecapture = NO;
        [self refreshMouseMovedAcceptanceState];
        return YES;
    }

    return NO;
}

- (BOOL)captureFreeMouseIfNeededForEvent:(NSEvent *)event {
    if (self.edgeMenuTemporaryReleaseActive) {
        [self updateEdgeMenuPointerInsideForPoint:[self viewPointForMouseEvent:event]];
        if (self.edgeMenuPointerInside || self.edgeMenuDragging || self.edgeMenuMenuVisible) {
            return NO;
        }

        [self deactivateEdgeMenuTemporaryReleaseAndRecaptureIfNeeded:YES];
        if (self.isMouseCaptured) {
            return YES;
        }
    }

    if (!self.isRemoteDesktopMode || self.isMouseCaptured) {
        return NO;
    }

    [self syncRemoteCursorToMouseEvent:event clampToBounds:YES];
    [self rearmMouseCaptureIfPossibleWithReason:@"free-mouse-pointer-engaged"];
    return self.isMouseCaptured;
}

- (BOOL)hasReadyInputContext {
    void *inputContext = self.hidSupport.inputContext ?: self.controllerSupport.inputContext;
    if (inputContext == NULL) {
        return NO;
    }

    PML_INPUT_STREAM_CONTEXT ctx = (PML_INPUT_STREAM_CONTEXT)inputContext;
    return ctx != NULL && LiInputContextIsInitialized(ctx);
}

- (BOOL)canCaptureMouseNow {
    NSWindow *window = self.view.window;
    if (!window || !window.isKeyWindow) {
        return NO;
    }
    if (![NSApp isActive]) {
        return NO;
    }
    if (self.stopStreamInProgress || self.reconnectInProgress || self.spaceTransitionInProgress) {
        return NO;
    }
    if (![self isWindowInCurrentSpace]) {
        return NO;
    }
    return [self hasReadyInputContext];
}

- (NSString *)mouseCaptureBlockerReason {
    NSWindow *window = self.view.window;
    if (!window) {
        return @"window-nil";
    }
    if (!window.isKeyWindow) {
        return @"window-not-key";
    }
    if (![NSApp isActive]) {
        return @"app-inactive";
    }
    if (self.stopStreamInProgress) {
        return @"stop-in-progress";
    }
    if (self.reconnectInProgress) {
        return @"reconnect-in-progress";
    }
    if (self.spaceTransitionInProgress) {
        return @"space-transition";
    }
    if (![self isWindowInCurrentSpace]) {
        return @"window-not-current-space";
    }
    if (![self hasReadyInputContext]) {
        return @"input-context-unready";
    }
    return @"unknown";
}

- (void)ensureStreamWindowKeyIfPossible {
    NSWindow *window = self.view.window;
    if (!window || window.isKeyWindow) {
        return;
    }
    if (![NSApp isActive] || self.stopStreamInProgress || self.reconnectInProgress || self.spaceTransitionInProgress) {
        return;
    }
    if (![self isWindowInCurrentSpace]) {
        return;
    }
    @try {
        [window makeKeyWindow];
    } @catch (NSException *exception) {
        Log(LOG_W, @"[diag] Failed to make stream window key: %@", exception.reason ?: @"unknown");
    }
}

- (void)refreshMouseMovedAcceptanceState {
    NSWindow *window = self.view.window;
    if (!window) {
        [self.hidSupport setFreeMouseVirtualCursorActive:NO];
        return;
    }

    BOOL shouldAccept = self.isMouseCaptured ||
                        self.edgeMenuTemporaryReleaseActive ||
                        self.edgeMenuDragging ||
                        self.edgeMenuMenuVisible ||
                        (self.pendingMouseExitedRecapture && self.isRemoteDesktopMode);
    window.acceptsMouseMovedEvents = shouldAccept;

    BOOL shouldActivateVirtualCursor = self.isRemoteDesktopMode &&
                                       self.isMouseCaptured &&
                                       !self.stopStreamInProgress &&
                                       !self.reconnectInProgress &&
                                       !self.edgeMenuTemporaryReleaseActive &&
                                       !self.edgeMenuDragging &&
                                       !self.edgeMenuMenuVisible &&
                                       [self hasReadyInputContext];
    [self.hidSupport setFreeMouseVirtualCursorActive:shouldActivateVirtualCursor];
    if (shouldActivateVirtualCursor && [self isCurrentPointerInsideStreamView]) {
        [self.hidSupport updateFreeMouseVirtualCursorAnchorWithViewPoint:[self currentMouseLocationInViewCoordinates]
                                                          referenceSize:self.view.bounds.size];
    }
}

- (void)rearmMouseCaptureIfPossibleWithReason:(NSString *)reason {
    if (self.isRemoteDesktopMode && ![self reasonAllowsImmediateCaptureInFreeMouseMode:reason]) {
        return;
    }

    if (self.edgeMenuTemporaryReleaseActive && self.isRemoteDesktopMode) {
        return;
    }

    if (self.isMouseCaptured) {
        self.pendingMouseCaptureRetryToken += 1;
        return;
    }

    if (![self canCaptureMouseNow]) {
        NSString *blocker = [self mouseCaptureBlockerReason];
        [self noteInputDiagnosticsRearmSkippedWithBlocker:blocker];
        Log(LOG_D, @"[diag] Rearm skipped: reason=%@ blocker=%@",
            reason ?: @"unknown",
            blocker);
        return;
    }

    if (self.isRemoteDesktopMode &&
        [self remoteDesktopCaptureReasonRequiresPointerInside:reason] &&
        ![self isCurrentPointerInsideStreamView]) {
        [self noteInputDiagnosticsRearmDeferred:reason];
        Log(LOG_D, @"[diag] Rearm deferred until pointer re-enters stream view: reason=%@",
            reason ?: @"unknown");
        return;
    }

    self.pendingMouseCaptureRetryToken += 1;
    [self noteInputDiagnosticsRearmRequested:reason];
    Log(LOG_D, @"[diag] Rearming mouse capture: reason=%@", reason ?: @"unknown");
    uint64_t suppressionMs = [self freeMouseEdgeUncaptureSuppressionDurationMsForReason:reason];
    if (suppressionMs > 0) {
        self.suppressFreeMouseEdgeUncaptureUntilMs = [self nowMs] + suppressionMs;
        self.pendingFreeMouseReentryEdge = MLFreeMouseExitEdgeNone;
        self.pendingFreeMouseReentryAtMs = 0;
    }
    if ([self usesAbsoluteRemoteDesktopPointerSync] &&
        ![self rearmReasonAlreadySyncedRemoteCursorFromEvent:reason] &&
        [self isCurrentPointerInsideStreamView]) {
        [self syncRemoteCursorToCurrentPointerClamped];
    }
    [self captureMouse];
}

- (void)applyLiveMouseSettingsRefreshForSetting:(NSString *)setting {
    if (self.stopStreamInProgress || self.reconnectInProgress) {
        return;
    }

    NSString *desiredMode = [SettingsClass mouseModeFor:self.app.host.uuid];
    BOOL wantsRemoteDesktopMode = [desiredMode isEqualToString:@"remote"];
    if (wantsRemoteDesktopMode != self.isRemoteDesktopMode) {
        [self applyMouseModeNamed:desiredMode showNotification:NO];
        return;
    }

    self.pendingHybridRemoteCursorSync = self.isRemoteDesktopMode &&
                                         [SettingsClass shouldUseHybridFreeMouseMotionFor:self.app.host.uuid];
    [self.hidSupport refreshMouseInputConfiguration];
    [self refreshMouseMovedAcceptanceState];

    if (self.isMouseCaptured &&
        [self usesAbsoluteRemoteDesktopPointerSync] &&
        !self.pendingHybridRemoteCursorSync &&
        [self isCurrentPointerInsideStreamView]) {
        [self syncRemoteCursorToCurrentPointerClamped];
    }

    Log(LOG_D, @"[diag] Live mouse setting refresh applied: setting=%@ remoteDesktop=%d hybrid=%d captured=%d",
        setting ?: @"unknown",
        self.isRemoteDesktopMode ? 1 : 0,
        self.pendingHybridRemoteCursorSync ? 1 : 0,
        self.isMouseCaptured ? 1 : 0);
}

- (void)applyMouseModeNamed:(NSString *)newMode showNotification:(BOOL)showNotification {
    NSString *currentMode = [SettingsClass mouseModeFor:self.app.host.uuid];
    BOOL newRemoteDesktopMode = [newMode isEqualToString:@"remote"];
    BOOL storedModeMatches = (currentMode == nil && newMode == nil) || [currentMode isEqualToString:newMode];
    BOOL runtimeModeMatches = self.isRemoteDesktopMode == newRemoteDesktopMode;
    if (storedModeMatches && runtimeModeMatches) {
        [self rebuildStreamMenu];
        return;
    }

    if (!storedModeMatches) {
        [SettingsClass setMouseMode:newMode for:self.app.host.uuid];
    }
    self.isRemoteDesktopMode = newRemoteDesktopMode;
    self.pendingHybridRemoteCursorSync = self.isRemoteDesktopMode &&
                                         [SettingsClass shouldUseHybridFreeMouseMotionFor:self.app.host.uuid];

    BOOL canApplyLiveTransition = self.isMouseCaptured &&
                                  ![self hasPressedMouseButtonsForCaptureTransition] &&
                                  !self.stopStreamInProgress &&
                                  !self.reconnectInProgress &&
                                  !self.spaceTransitionInProgress;

    if (canApplyLiveTransition) {
        self.pendingMouseCaptureRetryToken += 1;
        self.pendingFreeMouseReentryEdge = MLFreeMouseExitEdgeNone;
        self.pendingFreeMouseReentryAtMs = 0;
        self.pendingMouseExitedRecapture = NO;
        self.pendingMouseUncaptureAfterButtonsReleased = NO;
        self.suppressFreeMouseEdgeUncaptureUntilMs = self.isRemoteDesktopMode ? ([self nowMs] + 700) : 0;

        NSDictionary *prefs = [SettingsClass getSettingsFor:self.app.host.uuid];
        BOOL showLocalCursor = prefs ? [prefs[@"showLocalCursor"] boolValue] : NO;

        CGAssociateMouseAndMouseCursorPosition(self.isRemoteDesktopMode ? YES : NO);
        if (!self.isRemoteDesktopMode) {
            NSWindow *window = self.view.window;
            NSScreen *screen = window.screen;
            if (window != nil && screen != nil) {
                CGRect rectInWindow = [self.view convertRect:self.view.bounds toView:nil];
                CGRect rectInScreen = [window convertRectToScreen:rectInWindow];
                CGFloat screenHeight = screen.frame.size.height;
                if (screenHeight > 0) {
                    CGPoint cursorPoint = CGPointMake(CGRectGetMidX(rectInScreen),
                                                      screenHeight - CGRectGetMidY(rectInScreen));
                    CGWarpMouseCursorPosition(cursorPoint);
                }
            }
            [self.hidSupport suppressRelativeMouseMotionForMilliseconds:120];
        } else if (!self.pendingHybridRemoteCursorSync && [self isCurrentPointerInsideStreamView]) {
            [self syncRemoteCursorToCurrentPointerClamped];
        }

        if (!showLocalCursor) {
            [self reassertHiddenLocalCursorIfNeededWithReason:@"mouse-mode-changed"];
        }

        [self.hidSupport refreshMouseInputConfiguration];
        [self refreshMouseMovedAcceptanceState];
    } else {
        [self uncaptureMouseWithCode:@"MUC101" reason:@"mouse-mode-changed"];
        [self.hidSupport refreshMouseInputConfiguration];
        [self rearmMouseCaptureIfPossibleWithReason:@"mouse-mode-changed"];
    }

    if (showNotification) {
        NSString *message = [NSString stringWithFormat:@"🖱️ %@", [NSString stringWithFormat:MLString(@"Switched to %@", nil), [self mouseModeDisplayNameForMode:newMode]]];
        if (![newMode isEqualToString:@"remote"]) {
            NSString *releaseHint = [self releaseMouseHintText];
            if (releaseHint.length > 0) {
                message = [NSString stringWithFormat:@"%@ · %@", message, releaseHint];
            }
        }
        [self showNotification:message];
    }

    [self updateControlCenterEntrypointHints];
    [self rebuildStreamMenu];
}

- (void)installLocalKeyMonitorIfNeeded {
    if (self.localKeyDownMonitor) {
        return;
    }

    __weak typeof(self) weakSelf = self;
    self.localKeyDownMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent * _Nullable(NSEvent * _Nonnull event) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return event;
        }

        NSWindow *window = strongSelf.view.window;
        if (!window) {
            return event;
        }

        // Only intercept events intended for our stream window (or events without an attached window).
        if (event.window && event.window != window) {
            return event;
        }

        StreamShortcut *borderlessShortcut = [strongSelf streamShortcutForAction:MLShortcutActionToggleBorderlessWindowed];
        if ([strongSelf event:event matchesShortcut:borderlessShortcut]) {
            strongSelf.pendingOptionUncaptureToken += 1;
            if ([strongSelf isWindowBorderlessMode]) {
                [strongSelf switchToWindowedMode:nil];
            } else {
                [strongSelf switchToBorderlessMode:nil];
            }
            return nil;
        }

        StreamShortcut *controlCenterShortcut = [strongSelf streamShortcutForAction:MLShortcutActionOpenControlCenter];
        if ([strongSelf event:event matchesShortcut:controlCenterShortcut]) {
            [strongSelf presentControlCenterFromShortcut];
            return nil;
        }

        return event;
    }];
}

- (NSString *)mouseClickDiagnosticPhaseForMonitoredEvent:(NSEvent *)event {
    switch (event.type) {
        case NSEventTypeLeftMouseDown:
            return @"monitor-left-down";
        case NSEventTypeLeftMouseUp:
            return @"monitor-left-up";
        case NSEventTypeRightMouseDown:
            return @"monitor-right-down";
        case NSEventTypeRightMouseUp:
            return @"monitor-right-up";
        case NSEventTypeOtherMouseDown:
            return @"monitor-other-down";
        case NSEventTypeOtherMouseUp:
            return @"monitor-other-up";
        default:
            return @"monitor-mouse";
    }
}

- (void)installLocalMouseClickMonitorIfNeeded {
    if (self.localMouseClickMonitor) {
        return;
    }

    __weak typeof(self) weakSelf = self;
    NSEventMask mask = (NSEventMaskLeftMouseDown |
                        NSEventMaskLeftMouseUp |
                        NSEventMaskRightMouseDown |
                        NSEventMaskRightMouseUp |
                        NSEventMaskOtherMouseDown |
                        NSEventMaskOtherMouseUp);
    self.localMouseClickMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:mask handler:^NSEvent * _Nullable(NSEvent * _Nonnull event) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return event;
        }

        NSWindow *window = strongSelf.view.window;
        if (!window) {
            return event;
        }
        if (event.window != nil && event.window != window) {
            return event;
        }

        NSPoint viewPoint = [strongSelf viewPointForMouseEvent:event];
        if (!NSPointInRect(viewPoint, strongSelf.view.bounds)) {
            [strongSelf logMouseClickDiagnosticsForPhase:[strongSelf mouseClickDiagnosticPhaseForMonitoredEvent:event] event:event];
        }

        return event;
    }];
}

- (void)installGlobalMouseMonitorIfNeeded {
    if (self.globalMouseMovedMonitor) {
        return;
    }

    __weak typeof(self) weakSelf = self;
    self.globalMouseMovedMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:(NSEventMaskMouseMoved |
                                                                                   NSEventMaskLeftMouseDragged |
                                                                                   NSEventMaskRightMouseDragged |
                                                                                   NSEventMaskOtherMouseDragged)
                                                                          handler:^(__unused NSEvent *event) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }

            if (!strongSelf.isRemoteDesktopMode ||
                strongSelf.isMouseCaptured ||
                strongSelf.stopStreamInProgress ||
                strongSelf.reconnectInProgress ||
                strongSelf.spaceTransitionInProgress ||
                strongSelf.edgeMenuTemporaryReleaseActive ||
                strongSelf.edgeMenuDragging ||
                strongSelf.edgeMenuMenuVisible) {
                strongSelf.globalInactivePointerInsideStreamView = NO;
                return;
            }

            if ([NSApp isActive]) {
                strongSelf.globalInactivePointerInsideStreamView = NO;
                return;
            }

            if (![strongSelf isWindowInCurrentSpace]) {
                strongSelf.globalInactivePointerInsideStreamView = NO;
                return;
            }

            BOOL pointerInside = [strongSelf isCurrentPointerInsideStreamView];
            if (!pointerInside) {
                strongSelf.globalInactivePointerInsideStreamView = NO;
                return;
            }

            if (strongSelf.globalInactivePointerInsideStreamView) {
                return;
            }

            strongSelf.globalInactivePointerInsideStreamView = YES;
            Log(LOG_I, @"[diag] Global pointer re-entered visible stream view while inactive; requesting reactivation");
            [NSApp activateIgnoringOtherApps:YES];
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) innerSelf = weakSelf;
                if (!innerSelf || ![NSApp isActive] || ![innerSelf isWindowInCurrentSpace]) {
                    return;
                }
                [innerSelf ensureStreamWindowKeyIfPossible];
                [innerSelf rearmMouseCaptureIfPossibleWithReason:@"mouse-entered-view"];
                [innerSelf scheduleDeferredMouseCaptureRearmWithReason:@"mouse-entered-view" delay:0.10];
                [innerSelf scheduleDeferredMouseCaptureRearmWithReason:@"mouse-entered-view" delay:0.28];
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.06 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) innerSelf = weakSelf;
                if (!innerSelf || ![NSApp isActive] || ![innerSelf isWindowInCurrentSpace]) {
                    return;
                }
                [innerSelf ensureStreamWindowKeyIfPossible];
                [innerSelf rearmMouseCaptureIfPossibleWithReason:@"mouse-entered-view"];
            });
        });
    }];
}

#pragma mark - Mouse Tracking Area

- (void)installMouseTrackingArea {
    if (self.mouseTrackingArea) {
        [self.view removeTrackingArea:self.mouseTrackingArea];
        self.mouseTrackingArea = nil;
    }

    NSTrackingAreaOptions options = NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect;
    self.mouseTrackingArea = [[NSTrackingArea alloc] initWithRect:self.view.bounds
                                                          options:options
                                                            owner:self
                                                         userInfo:nil];
    [self.view addTrackingArea:self.mouseTrackingArea];

    // Check if mouse is currently inside the view
    NSPoint mouseLocation = [NSEvent mouseLocation];
    NSPoint windowPoint = [self.view.window convertPointFromScreen:mouseLocation];
    NSPoint viewPoint = [self.view convertPoint:windowPoint fromView:nil];
    self.isMouseInsideView = NSPointInRect(viewPoint, self.view.bounds);
}

- (void)mouseEntered:(NSEvent *)event {
    if (event.trackingArea == self.edgeMenuButtonTrackingArea) {
        self.edgeMenuPointerInside = YES;
        [self cancelEdgeMenuAutoCollapse];
        [self setEdgeMenuButtonExpanded:YES animated:YES];
        return;
    }

    self.isMouseInsideView = YES;
    self.globalInactivePointerInsideStreamView = YES;
    if (self.edgeMenuTemporaryReleaseActive) {
        return;
    }
    if (self.pendingFreeMouseReentryEdge != MLFreeMouseExitEdgeNone &&
        self.isRemoteDesktopMode &&
        !self.isMouseCaptured) {
        return;
    }
    if (self.isRemoteDesktopMode && !self.isMouseCaptured) {
        [self ensureStreamWindowKeyIfPossible];
        [self syncRemoteCursorToMouseEvent:event clampToBounds:YES];
        [self rearmMouseCaptureIfPossibleWithReason:@"mouse-entered-view"];
    }
}

- (void)mouseExited:(NSEvent *)event {
    if (event.trackingArea == self.edgeMenuButtonTrackingArea) {
        [self updateEdgeMenuPointerInsideForPoint:[self currentMouseLocationInViewCoordinates]];
        if (!self.edgeMenuPointerInside) {
            [self scheduleEdgeMenuAutoCollapse];
        }
        return;
    }

    self.isMouseInsideView = NO;
    self.globalInactivePointerInsideStreamView = NO;
    if (self.isRemoteDesktopMode && self.isMouseCaptured) {
        [self logMouseExitDiagnosticsForEvent:event stage:@"received"];
        NSPoint eventPoint = [self viewPointForMouseEvent:event];
        NSPoint currentPoint = [self currentMouseLocationInViewCoordinates];
        BOOL eventInside = NSPointInRect(eventPoint, self.view.bounds);
        BOOL currentInside = NSPointInRect(currentPoint, self.view.bounds);
        if (eventInside || currentInside) {
            self.isMouseInsideView = YES;
            self.globalInactivePointerInsideStreamView = YES;
            [self logMouseExitDiagnosticsForEvent:event stage:@"skip-still-inside"];
            [self logMouseUncaptureStage:@"skip-still-inside" code:@"MUC102" reason:@"mouse-exited-view"];
            [self reassertHiddenLocalCursorIfNeededWithReason:@"mouse-exited-view-still-inside"];
            return;
        }
        if ([self hasPressedMouseButtonsForCaptureTransition]) {
            [self logMouseExitDiagnosticsForEvent:event stage:@"skip-buttons-down"];
            [self reassertHiddenLocalCursorIfNeededWithReason:@"mouse-exited-view-buttons-down"];
            return;
        }
        if ([self shouldSuppressMouseExitedUncaptureForEvent:event]) {
            self.isMouseInsideView = YES;
            self.globalInactivePointerInsideStreamView = YES;
            [self logMouseExitDiagnosticsForEvent:event stage:@"skip-top-edge-click"];
            [self logMouseUncaptureStage:@"skip-top-edge-click" code:@"MUC102" reason:@"mouse-exited-view"];
            [self reassertHiddenLocalCursorIfNeededWithReason:@"mouse-exited-view-top-edge"];
            return;
        }
        [self syncRemoteCursorToMouseEvent:event clampToBounds:YES];
        [self uncaptureMouseWithCode:@"MUC102" reason:@"mouse-exited-view"];
        self.pendingMouseExitedRecapture = YES;
        [self refreshMouseMovedAcceptanceState];
        [self scheduleDeferredMouseCaptureRearmWithReason:@"mouse-exited-view-reentry" delay:0.12];
        [self scheduleDeferredMouseCaptureRearmWithReason:@"mouse-exited-view-reentry" delay:0.35];
    }
}

- (void)flagsChanged:(NSEvent *)event {
    [self.hidSupport flagsChanged:event];

    StreamShortcut *releaseShortcut = [self streamShortcutForAction:MLShortcutActionReleaseMouseCapture];
    NSEventModifierFlags relevantMods = MLRelevantShortcutModifiers(event.modifierFlags);

    if (releaseShortcut.modifierOnly && relevantMods == releaseShortcut.modifierFlags) {
        NSUInteger token = ++self.pendingOptionUncaptureToken;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (token != self.pendingOptionUncaptureToken) {
                return;
            }

            NSEventModifierFlags currentMods = MLRelevantShortcutModifiers([NSEvent modifierFlags]);
            if (currentMods != releaseShortcut.modifierFlags) {
                return;
            }

            self.lastOptionUncaptureAtMs = [self nowMs];
            [self.hidSupport releaseAllModifierKeys];
            [self suppressConnectionWarningsForSeconds:2.0 reason:@"shortcut-uncapture"];
            [self uncaptureMouseWithCode:@"MUC103" reason:@"modifier-only-release-shortcut"];
        });
        return;
    }

    self.pendingOptionUncaptureToken += 1;
}

- (void)keyDown:(NSEvent *)event {
    [self.hidSupport keyDown:event];
}

- (void)keyUp:(NSEvent *)event {
    [self.hidSupport keyUp:event];
}


- (void)mouseDown:(NSEvent *)event {
    [self reassertHiddenLocalCursorIfNeededWithReason:@"left-down"];
    [self logMouseClickDiagnosticsForPhase:@"left-down" event:event];
    [self captureFreeMouseIfNeededForEvent:event];
    [self syncRemoteCursorBeforeMouseButtonEvent:event];
    [self.hidSupport mouseDown:event withButton:BUTTON_LEFT];
    [self captureMouse];
}

- (void)mouseUp:(NSEvent *)event {
    [self reassertHiddenLocalCursorIfNeededWithReason:@"left-up"];
    [self logMouseClickDiagnosticsForPhase:@"left-up" event:event];
    [self syncRemoteCursorBeforeMouseButtonEvent:event];
    [self.hidSupport mouseUp:event withButton:BUTTON_LEFT];
    [self completeDeferredMouseUncaptureIfNeeded];
}

- (void)rightMouseDown:(NSEvent *)event {
    [self reassertHiddenLocalCursorIfNeededWithReason:@"right-down"];
    [self logMouseClickDiagnosticsForPhase:@"right-down" event:event];
    if (!self.isMouseCaptured) {
        self.suppressNextRightMouseUp = YES;
        [self presentStreamMenuAtEvent:event];
        return;
    }

    int button = (event.buttonNumber == 0) ? BUTTON_LEFT : BUTTON_RIGHT;
    [self syncRemoteCursorBeforeMouseButtonEvent:event];
    [self.hidSupport mouseDown:event withButton:button];
}

- (void)rightMouseUp:(NSEvent *)event {
    [self reassertHiddenLocalCursorIfNeededWithReason:@"right-up"];
    [self logMouseClickDiagnosticsForPhase:@"right-up" event:event];
    if (self.suppressNextRightMouseUp) {
        self.suppressNextRightMouseUp = NO;
        return;
    }

    int button = (event.buttonNumber == 0) ? BUTTON_LEFT : BUTTON_RIGHT;
    [self syncRemoteCursorBeforeMouseButtonEvent:event];
    [self.hidSupport mouseUp:event withButton:button];
    [self completeDeferredMouseUncaptureIfNeeded];
}

- (void)otherMouseDown:(NSEvent *)event {
    [self reassertHiddenLocalCursorIfNeededWithReason:@"other-down"];
    [self logMouseClickDiagnosticsForPhase:@"other-down" event:event];
    int button = [self getMouseButtonFromEvent:event];
    if (button == 0) {
        return;
    }
    [self captureFreeMouseIfNeededForEvent:event];
    [self syncRemoteCursorBeforeMouseButtonEvent:event];
    [self.hidSupport mouseDown:event withButton:button];
}

- (void)otherMouseUp:(NSEvent *)event {
    [self reassertHiddenLocalCursorIfNeededWithReason:@"other-up"];
    [self logMouseClickDiagnosticsForPhase:@"other-up" event:event];
    int button = [self getMouseButtonFromEvent:event];
    if (button == 0) {
        return;
    }
    [self syncRemoteCursorBeforeMouseButtonEvent:event];
    [self.hidSupport mouseUp:event withButton:button];
    [self completeDeferredMouseUncaptureIfNeeded];
}

- (void)mouseMoved:(NSEvent *)event {
    if ([self handleEdgeMenuTemporaryReleaseForEvent:event]) {
        return;
    }

    if ([self attemptPendingMouseExitedRecaptureIfNeededForEvent:event]) {
        return;
    }

    if ([self recaptureFreeMouseAfterEdgeUncaptureIfNeededForEvent:event]) {
        return;
    }

    MLFreeMouseExitEdge exitEdge = [self freeMouseExitEdgeForEvent:event];
    if ([self shouldUncaptureFreeMouseForEdgeEvent:event]) {
        Log(LOG_I, @"[diag] Free mouse uncaptured from fullscreen edge");
        [self syncRemoteCursorToMouseEvent:event clampToBounds:YES];
        [self uncaptureMouseWithCode:@"MUC104" reason:@"free-mouse-edge-mouse-moved"];
        if ([self edgeMenuMatchesExitEdge:exitEdge] && [self edgeMenuShouldBeVisible]) {
            [self activateEdgeMenuDockForExitEdge:exitEdge];
        } else {
            [self beginFreeMouseEdgeReentryForExitEdge:exitEdge];
        }
        return;
    }
    if ([self consumePendingHybridRemoteCursorSyncForEvent:event reason:@"mouse-moved-hybrid-sync"]) {
        return;
    }
    [self.hidSupport mouseMoved:event];
}

- (void)mouseDragged:(NSEvent *)event {
    if ([self handleEdgeMenuTemporaryReleaseForEvent:event]) {
        return;
    }

    if ([self attemptPendingMouseExitedRecaptureIfNeededForEvent:event]) {
        return;
    }

    if ([self recaptureFreeMouseAfterEdgeUncaptureIfNeededForEvent:event]) {
        return;
    }

    MLFreeMouseExitEdge exitEdge = [self freeMouseExitEdgeForEvent:event];
    if ([self shouldUncaptureFreeMouseForEdgeEvent:event]) {
        [self syncRemoteCursorToMouseEvent:event clampToBounds:YES];
        [self uncaptureMouseWithCode:@"MUC105" reason:@"free-mouse-edge-mouse-dragged"];
        if ([self edgeMenuMatchesExitEdge:exitEdge] && [self edgeMenuShouldBeVisible]) {
            [self activateEdgeMenuDockForExitEdge:exitEdge];
        } else {
            [self beginFreeMouseEdgeReentryForExitEdge:exitEdge];
        }
        return;
    }
    if ([self consumePendingHybridRemoteCursorSyncForEvent:event reason:@"mouse-dragged-hybrid-sync"]) {
        return;
    }
    [self.hidSupport mouseMoved:event];
}

- (void)rightMouseDragged:(NSEvent *)event {
    if ([self handleEdgeMenuTemporaryReleaseForEvent:event]) {
        return;
    }

    if ([self attemptPendingMouseExitedRecaptureIfNeededForEvent:event]) {
        return;
    }

    if ([self recaptureFreeMouseAfterEdgeUncaptureIfNeededForEvent:event]) {
        return;
    }

    MLFreeMouseExitEdge exitEdge = [self freeMouseExitEdgeForEvent:event];
    if ([self shouldUncaptureFreeMouseForEdgeEvent:event]) {
        [self syncRemoteCursorToMouseEvent:event clampToBounds:YES];
        [self uncaptureMouseWithCode:@"MUC106" reason:@"free-mouse-edge-right-dragged"];
        if ([self edgeMenuMatchesExitEdge:exitEdge] && [self edgeMenuShouldBeVisible]) {
            [self activateEdgeMenuDockForExitEdge:exitEdge];
        } else {
            [self beginFreeMouseEdgeReentryForExitEdge:exitEdge];
        }
        return;
    }
    if ([self consumePendingHybridRemoteCursorSyncForEvent:event reason:@"right-dragged-hybrid-sync"]) {
        return;
    }
    [self.hidSupport mouseMoved:event];
}

- (void)otherMouseDragged:(NSEvent *)event {
    if ([self handleEdgeMenuTemporaryReleaseForEvent:event]) {
        return;
    }

    if ([self attemptPendingMouseExitedRecaptureIfNeededForEvent:event]) {
        return;
    }

    if ([self recaptureFreeMouseAfterEdgeUncaptureIfNeededForEvent:event]) {
        return;
    }

    MLFreeMouseExitEdge exitEdge = [self freeMouseExitEdgeForEvent:event];
    if ([self shouldUncaptureFreeMouseForEdgeEvent:event]) {
        [self syncRemoteCursorToMouseEvent:event clampToBounds:YES];
        [self uncaptureMouseWithCode:@"MUC107" reason:@"free-mouse-edge-other-dragged"];
        if ([self edgeMenuMatchesExitEdge:exitEdge] && [self edgeMenuShouldBeVisible]) {
            [self activateEdgeMenuDockForExitEdge:exitEdge];
        } else {
            [self beginFreeMouseEdgeReentryForExitEdge:exitEdge];
        }
        return;
    }
    if ([self consumePendingHybridRemoteCursorSyncForEvent:event reason:@"other-dragged-hybrid-sync"]) {
        return;
    }
    [self.hidSupport mouseMoved:event];
}

- (void)scrollWheel:(NSEvent *)event {
    [self attemptPendingMouseExitedRecaptureIfNeededForEvent:event];
    if (!self.isMouseCaptured && self.isRemoteDesktopMode) {
        return;
    }
    [self.hidSupport scrollWheel:event];
}

- (int)getMouseButtonFromEvent:(NSEvent *)event {
    int button;
    switch (event.buttonNumber) {
        case 2:
            button = BUTTON_MIDDLE;
            break;
        case 3:
            button = BUTTON_X1;
            break;
        case 4:
            button = BUTTON_X2;
            break;
        default:
            return 0;
            break;
    }
    
    return button;
}


#pragma mark - KeyboardNotifiable

- (BOOL)onKeyboardEquivalent:(NSEvent *)event {
    const NSEventModifierFlags eventModifierFlags = MLRelevantShortcutModifiers(event.modifierFlags);
    
    if (event.keyCode == kVK_ANSI_1 && eventModifierFlags == NSEventModifierFlagCommand) {
        [self.hidSupport releaseAllModifierKeys];
        return NO;
    }
    
    if ((event.keyCode == kVK_ANSI_Grave && eventModifierFlags == NSEventModifierFlagCommand)
        || (event.keyCode == kVK_ANSI_H && eventModifierFlags == NSEventModifierFlagCommand)
        ) {
        if (![self isWindowFullscreen]) {
            [self.hidSupport releaseAllModifierKeys];
            return NO;
        }
    }
    
    if ((event.keyCode == kVK_ANSI_F && eventModifierFlags == (NSEventModifierFlagControl | NSEventModifierFlagCommand))
        || (event.keyCode == kVK_ANSI_F && eventModifierFlags == NSEventModifierFlagFunction)
        || (event.keyCode == kVK_ANSI_W && eventModifierFlags == NSEventModifierFlagCommand)
        ) {
        [self.hidSupport releaseAllModifierKeys];
        return NO;
    }

    if ([self event:event matchesShortcut:[self streamShortcutForAction:MLShortcutActionDisconnectStream]]) {
        self.pendingOptionUncaptureToken += 1;
        [self.hidSupport releaseAllModifierKeys];
        [self requestStreamCloseWithSource:@"keyboard-custom-disconnect"];
        return YES;
    }

    if ([self event:event matchesShortcut:[self streamShortcutForAction:MLShortcutActionCloseAndQuitApp]]) {
        self.pendingOptionUncaptureToken += 1;
        [self.hidSupport releaseAllModifierKeys];
        [self performCloseAndQuitApp:nil];
        return YES;
    }

    if ([self event:event matchesShortcut:[self streamShortcutForAction:MLShortcutActionTogglePerformanceOverlay]]) {
        self.pendingOptionUncaptureToken += 1;
        [self toggleOverlay];
        return YES;
    }

    if ([self event:event matchesShortcut:[self streamShortcutForAction:MLShortcutActionToggleMouseMode]]) {
        self.pendingOptionUncaptureToken += 1;
        [self toggleMouseMode];
        return YES;
    }

    if ([self event:event matchesShortcut:[self streamShortcutForAction:MLShortcutActionToggleFullscreenControlBall]]) {
        self.pendingOptionUncaptureToken += 1;
        [self toggleFullscreenControlBallVisibility];
        return YES;
    }

    if ([self event:event matchesShortcut:[self streamShortcutForAction:MLShortcutActionOpenControlCenter]]) {
        [self presentControlCenterFromShortcut];
        return YES;
    }
    
    [self.hidSupport keyDown:event];
    [self.hidSupport keyUp:event];
    
    return YES;
}


#pragma mark - Actions

- (void)captureMouse {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self captureMouse];
        });
        return;
    }
    if (self.isMouseCaptured) {
        return;
    }

    if (self.stopStreamInProgress || self.reconnectInProgress) {
        return;
    }

    if (self.spaceTransitionInProgress) {
        [self noteInputDiagnosticsCaptureSkipped:@"space-transition"];
        Log(LOG_D, @"[diag] captureMouse skipped: space transition in progress");
        return;
    }
    if (![NSApp isActive]) {
        [self noteInputDiagnosticsCaptureSkipped:@"app-inactive"];
        Log(LOG_D, @"[diag] captureMouse skipped: app inactive");
        return;
    }

    NSWindow *window = self.view.window;
    if (!window) {
        [self noteInputDiagnosticsCaptureSkipped:@"window-nil"];
        Log(LOG_D, @"[diag] captureMouse skipped: window is nil");
        return;
    }
    if (![self isWindowInCurrentSpace]) {
        [self noteInputDiagnosticsCaptureSkipped:@"window-not-current-space"];
        Log(LOG_D, @"[diag] captureMouse skipped: window not in current space");
        return;
    }
    NSScreen *screen = window.screen;
    if (!screen) {
        [self noteInputDiagnosticsCaptureSkipped:@"screen-nil"];
        Log(LOG_D, @"[diag] captureMouse skipped: screen is nil");
        return;
    }

    NSDictionary* prefs = [SettingsClass getSettingsFor:self.app.host.uuid];
    BOOL showLocalCursor = prefs ? [prefs[@"showLocalCursor"] boolValue] : NO;
    NSString *mouseMode = [SettingsClass mouseModeFor:self.app.host.uuid];
    self.isRemoteDesktopMode = [mouseMode isEqualToString:@"remote"];
    if (![self hasReadyInputContext]) {
        [self noteInputDiagnosticsCaptureSkipped:@"input-context-unavailable"];
        Log(LOG_D, @"[diag] captureMouse skipped: input context unavailable");
        return;
    }

    self.streamView.prefersHiddenLocalCursor = !showLocalCursor;
    [self.streamView refreshPreferredLocalCursor];

    // Hide system cursor in both game mode and remote desktop mode (unless showLocalCursor is enabled)
    if (!showLocalCursor) {
        if (self.cursorHiddenCounter == 0) {
            [NSCursor hide];
            self.cursorHiddenCounter++;
        }
        if (MLCGCursorIsVisibleCompat()) {
            CGDirectDisplayID displayID = [self cursorDisplayIDForCurrentWindow];
            CGError error = CGDisplayHideCursor(displayID);
            if (error == kCGErrorSuccess) {
                self.cgCursorHiddenCounter += 1;
            }
        }
        // In game mode, also disassociate mouse from cursor position
        if (!self.isRemoteDesktopMode) {
            CGAssociateMouseAndMouseCursorPosition(NO);
            CGRect rectInWindow = [self.view convertRect:self.view.bounds toView:nil];
            CGRect rectInScreen = [window convertRectToScreen:rectInWindow];
            CGFloat screenHeight = screen.frame.size.height;
            if (screenHeight <= 0) {
                return;
            }
            CGPoint cursorPoint = CGPointMake(CGRectGetMidX(rectInScreen), screenHeight - CGRectGetMidY(rectInScreen));
            CGWarpMouseCursorPosition(cursorPoint);
            [self.hidSupport suppressRelativeMouseMotionForMilliseconds:120];
        }
    }

    [self enableMenuItems:NO];

    [self disallowDisplaySleep];

    // Always enable input when capture is active to avoid accidental lockout
    self.hidSupport.shouldSendInputEvents = YES;
    self.controllerSupport.shouldSendInputEvents = YES;

    self.pendingFreeMouseReentryEdge = MLFreeMouseExitEdgeNone;
    self.pendingFreeMouseReentryAtMs = 0;
    self.pendingMouseExitedRecapture = NO;
    self.pendingMouseUncaptureAfterButtonsReleased = NO;
    self.pendingHybridRemoteCursorSync = self.isRemoteDesktopMode && ![self usesAbsoluteRemoteDesktopPointerSync];
    self.isMouseCaptured = YES;
    [self refreshMouseMovedAcceptanceState];
    [self updateControlCenterEntrypointHints];
    [self noteInputDiagnosticsCaptureArmed];
    Log(LOG_D, @"[diag] captureMouse armed: key=%d fullscreen=%d remoteDesktop=%d inputCtx=%p",
        window.isKeyWindow ? 1 : 0,
        [self isWindowFullscreen] ? 1 : 0,
        self.isRemoteDesktopMode ? 1 : 0,
        self.hidSupport.inputContext);
}

- (void)uncaptureMouse {
    [self uncaptureMouseWithCode:@"MUC000" reason:@"legacy-direct-call"];
}

- (void)uncaptureMouseWithCode:(NSString *)code reason:(NSString *)reason {
    [self logMouseUncaptureStage:@"requested" code:code reason:reason];
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self uncaptureMouseWithCode:code reason:reason];
        });
        return;
    }
    if (!self.isMouseCaptured && self.cursorHiddenCounter == 0 && !self.hidSupport.shouldSendInputEvents) {
        [self logMouseUncaptureStage:@"skip-already-released" code:code reason:reason];
        return;
    }

    if (!self.view.window) {
        [self logMouseUncaptureStage:@"skip-window-nil" code:code reason:reason];
        return;
    }

    NSDictionary* prefs = [SettingsClass getSettingsFor:self.app.host.uuid];
    BOOL showLocalCursor = prefs ? [prefs[@"showLocalCursor"] boolValue] : NO;
    self.streamView.prefersHiddenLocalCursor = NO;
    [self.streamView refreshPreferredLocalCursor];

    [self.hidSupport releaseAllPressedMouseButtons];
    self.pendingMouseUncaptureAfterButtonsReleased = NO;

    if (!showLocalCursor) {
        CGAssociateMouseAndMouseCursorPosition(YES);
        while (self.cgCursorHiddenCounter > 0) {
            CGDisplayShowCursor([self cursorDisplayIDForCurrentWindow]);
            self.cgCursorHiddenCounter--;
        }
        while (self.cursorHiddenCounter != 0) {
            [NSCursor unhide];
            self.cursorHiddenCounter --;
        }
    }
    
    [self enableMenuItems:YES];
    
    [self allowDisplaySleep];
    
    self.hidSupport.shouldSendInputEvents = NO;
    self.controllerSupport.shouldSendInputEvents = NO;
    self.pendingFreeMouseReentryEdge = MLFreeMouseExitEdgeNone;
    self.pendingFreeMouseReentryAtMs = 0;
    self.pendingMouseExitedRecapture = NO;
    self.isMouseCaptured = NO;
    [self refreshMouseMovedAcceptanceState];
    [self updateControlCenterEntrypointHints];
    [self noteInputDiagnosticsUncapture];
    [self logMouseUncaptureStage:@"commit" code:code reason:reason];
}

@end
