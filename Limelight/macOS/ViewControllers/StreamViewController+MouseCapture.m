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

static NSTimeInterval const MLDeferredMouseUncaptureRecoveryDelay = 0.12;
static CGFloat const MLCoreHIDFreeMouseCorrectionThreshold = 1.5;
static CGFloat const MLCoreHIDFreeMouseExitHandoffNudge = 1.5;
static CGFloat const MLCoreHIDFreeMouseExitHandoffMaxProjectedOvershoot = 12.0;
static CGFloat const MLCoreHIDFreeMouseExitThreshold = 1.0;
static CGFloat const MLCoreHIDFreeMouseReentryDelayMs = 0.0;
static CGFloat const MLCoreHIDFreeMouseReentryInset = 0.0;

static inline CGFloat MLClampCGFloat(CGFloat value, CGFloat minValue, CGFloat maxValue) {
    return MIN(MAX(value, minValue), maxValue);
}

static inline CGFloat MLSquaredDistanceToRect(NSPoint point, NSRect rect) {
    CGFloat clampedX = MLClampCGFloat(point.x, NSMinX(rect), NSMaxX(rect));
    CGFloat clampedY = MLClampCGFloat(point.y, NSMinY(rect), NSMaxY(rect));
    CGFloat deltaX = point.x - clampedX;
    CGFloat deltaY = point.y - clampedY;
    return (deltaX * deltaX) + (deltaY * deltaY);
}

static inline NSPoint MLClampFreeMousePointToExitEdge(NSPoint point,
                                                      NSRect bounds,
                                                      MLFreeMouseExitEdge edge) {
    NSPoint clampedPoint = point;
    switch (edge) {
        case MLFreeMouseExitEdgeLeft:
            clampedPoint.x = NSMinX(bounds);
            clampedPoint.y = MLClampCGFloat(point.y, NSMinY(bounds), NSMaxY(bounds));
            break;
        case MLFreeMouseExitEdgeRight:
            clampedPoint.x = NSMaxX(bounds);
            clampedPoint.y = MLClampCGFloat(point.y, NSMinY(bounds), NSMaxY(bounds));
            break;
        case MLFreeMouseExitEdgeTop:
            clampedPoint.x = MLClampCGFloat(point.x, NSMinX(bounds), NSMaxX(bounds));
            clampedPoint.y = NSMaxY(bounds);
            break;
        case MLFreeMouseExitEdgeBottom:
            clampedPoint.x = MLClampCGFloat(point.x, NSMinX(bounds), NSMaxX(bounds));
            clampedPoint.y = NSMinY(bounds);
            break;
        case MLFreeMouseExitEdgeNone:
        default:
            break;
    }
    return clampedPoint;
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

    if ([self.hidSupport shouldUseCoreHIDFreeMouseAbsoluteSyncForCurrentConfiguration] &&
        ![self shouldUseCoreHIDVirtualSemanticLocation]) {
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

- (BOOL)shouldUseCoreHIDVirtualSemanticLocation {
    NSWindow *window = self.view.window;
    return self.isRemoteDesktopMode &&
           self.isMouseCaptured &&
           [self.hidSupport shouldUseCoreHIDFreeMouseAbsoluteSyncForCurrentConfiguration] &&
           window != nil &&
           window.isKeyWindow &&
           window.isMainWindow &&
           [NSApp isActive] &&
           [self isWindowInCurrentSpace] &&
           !self.pendingMouseUncaptureAfterButtonsReleased &&
           !self.edgeMenuTemporaryReleaseActive &&
           !self.edgeMenuDragging &&
           !self.edgeMenuMenuVisible;
}

- (BOOL)shouldPreferAppKitSystemPointerForBoundaryOrGestureEvent:(NSEvent *)event {
    if (event == nil ||
        !self.isRemoteDesktopMode ||
        !self.isMouseCaptured ||
        ![self.hidSupport shouldUseCoreHIDFreeMouseAbsoluteSyncForCurrentConfiguration]) {
        return NO;
    }

    if (![self.hidSupport hasRecentCoreHIDMouseMovement]) {
        return YES;
    }

    if (event.type == NSEventTypeScrollWheel &&
        event.hasPreciseScrollingDeltas &&
        (event.phase != NSEventPhaseNone || event.momentumPhase != NSEventPhaseNone)) {
        return YES;
    }

    return NO;
}

- (NSPoint)actualAppKitViewPointForBoundaryOrGestureEvent:(NSEvent *)event {
    NSPoint point = NSZeroPoint;
    if ([self rawViewPointForMouseEvent:event outPoint:&point]) {
        return point;
    }

    return [self currentMouseLocationInViewCoordinates];
}

- (void)prepareCoreHIDFreeMouseStateForFocusRegainWithReason:(NSString *)reason {
    if (!self.isRemoteDesktopMode ||
        ![self.hidSupport shouldUseCoreHIDFreeMouseAbsoluteSyncForCurrentConfiguration]) {
        return;
    }

    self.pendingFreeMouseReentryEdge = MLFreeMouseExitEdgeNone;
    self.pendingFreeMouseReentryAtMs = 0;
    self.pendingMouseExitedRecapture = NO;
    [self prepareCoreHIDVirtualCursorForSystemPointerSyncIfNeeded];

    BOOL pointerInside = [self isCurrentPointerInsideStreamView];
    Log(LOG_D, @"[diag] CoreHID free mouse focus regain prep: reason=%@ key=%d active=%d pointerInside=%d",
        reason ?: @"unknown",
        self.view.window.isKeyWindow ? 1 : 0,
        [NSApp isActive] ? 1 : 0,
        pointerInside ? 1 : 0);

    if (pointerInside && [self hasReadyInputContext]) {
        [self syncRemoteCursorToCurrentPointerClamped];
    }
}

- (BOOL)currentCoreHIDVirtualCursorPoint:(NSPoint *)point referenceSize:(NSSize *)referenceSize {
    if (![self shouldUseCoreHIDVirtualSemanticLocation]) {
        return NO;
    }

    return [self.hidSupport getFreeMouseVirtualCursorPoint:point referenceSize:referenceSize];
}

- (NSString *)freeMouseSemanticOwnerLabel {
    if (![self.hidSupport shouldUseCoreHIDFreeMouseAbsoluteSyncForCurrentConfiguration]) {
        return @"legacy-appkit";
    }
    if ([self shouldUseCoreHIDVirtualSemanticLocation]) {
        return @"captured-virtual";
    }
    return @"released-system";
}

- (NSString *)freeMouseSemanticSourceLabel {
    if ([self shouldUseCoreHIDVirtualSemanticLocation]) {
        return @"corehid-virtual";
    }
    return @"appkit-system";
}

- (BOOL)rawViewPointForMouseEvent:(NSEvent *)event outPoint:(NSPoint *)outPoint {
    if (event == nil || event.window != self.view.window || !self.view.window) {
        return NO;
    }

    NSPoint point = [self.view convertPoint:event.locationInWindow fromView:nil];
    if (!isfinite(point.x) || !isfinite(point.y)) {
        return NO;
    }

    if (outPoint != NULL) {
        *outPoint = point;
    }

    return YES;
}

- (void)updateCoreHIDFreeMouseTruthPointFromEvent:(NSEvent *)event {
    if (!self.isRemoteDesktopMode ||
        !self.isMouseCaptured ||
        ![self.hidSupport shouldUseCoreHIDFreeMouseAbsoluteSyncForCurrentConfiguration]) {
        return;
    }

    NSPoint point = NSZeroPoint;
    if (![self rawViewPointForMouseEvent:event outPoint:&point]) {
        return;
    }

    self.coreHIDFreeMouseLastTruthPoint = point;
    self.hasCoreHIDFreeMouseLastTruthPoint = YES;
}

- (NSPoint)appKitSemanticViewPointForMouseEvent:(NSEvent *)event {
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

- (NSPoint)appKitSemanticScreenPointForMouseEvent:(NSEvent *)event {
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

- (BOOL)shouldUseCurrentPointerSemanticLocationForMouseEvent:(NSEvent *)event {
    if (event == nil || !self.view.window || !self.isRemoteDesktopMode) {
        return NO;
    }
    if ([self.hidSupport shouldUseCoreHIDFreeMouseAbsoluteSyncForCurrentConfiguration]) {
        return ![self shouldUseCoreHIDVirtualSemanticLocation];
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
    NSPoint virtualPoint = NSZeroPoint;
    NSSize referenceSize = NSZeroSize;
    if ([self currentCoreHIDVirtualCursorPoint:&virtualPoint referenceSize:&referenceSize]) {
        if (referenceSize.width > 0.0 && referenceSize.height > 0.0) {
            return virtualPoint;
        }
    }

    return [self appKitSemanticViewPointForMouseEvent:event];
}

- (NSPoint)boundaryInteractionViewPointForMouseEvent:(NSEvent *)event {
    if ([self.hidSupport shouldUseCoreHIDFreeMouseAbsoluteSyncForCurrentConfiguration]) {
        return [self currentMouseLocationInViewCoordinates];
    }

    return [self viewPointForMouseEvent:event];
}

- (NSPoint)screenPointForMouseEvent:(NSEvent *)event {
    NSPoint virtualPoint = NSZeroPoint;
    NSSize referenceSize = NSZeroSize;
    if ([self currentCoreHIDVirtualCursorPoint:&virtualPoint referenceSize:&referenceSize] &&
        self.view.window != nil) {
        NSPoint windowPoint = [self.view convertPoint:virtualPoint toView:nil];
        return [self.view.window convertPointToScreen:windowPoint];
    }

    return [self appKitSemanticScreenPointForMouseEvent:event];
}

- (void)prepareCoreHIDVirtualCursorForSystemPointerSyncIfNeeded {
    if (![self.hidSupport shouldUseCoreHIDFreeMouseAbsoluteSyncForCurrentConfiguration]) {
        return;
    }

    NSPoint currentPoint = [self currentMouseLocationInViewCoordinates];
    Log(LOG_D, @"[diag] CoreHID free mouse handoff: stage=reseed owner=%@ source=%@ currentView=(%.1f,%.1f) pendingEdge=%ld pendingExited=%d",
        [self freeMouseSemanticOwnerLabel],
        [self freeMouseSemanticSourceLabel],
        currentPoint.x,
        currentPoint.y,
        (long)self.pendingFreeMouseReentryEdge,
        self.pendingMouseExitedRecapture ? 1 : 0);
    [self.hidSupport resetFreeMouseVirtualCursorState];
    self.hasCoreHIDFreeMouseLastTruthPoint = NO;
}

- (BOOL)bestCoreHIDHandoffTruthViewPointForEvent:(NSEvent *)event outPoint:(NSPoint *)outPoint {
    NSPoint point = NSZeroPoint;
    if ([self rawViewPointForMouseEvent:event outPoint:&point]) {
        if (outPoint != NULL) {
            *outPoint = point;
        }
        return YES;
    }

    if (self.hasCoreHIDFreeMouseLastTruthPoint) {
        if (outPoint != NULL) {
            *outPoint = self.coreHIDFreeMouseLastTruthPoint;
        }
        return YES;
    }

    return NO;
}

- (BOOL)shouldUseCoreHIDTightFreeMouseHandoff {
    return [self.hidSupport shouldUseCoreHIDFreeMouseAbsoluteSyncForCurrentConfiguration];
}

- (CGFloat)freeMouseReentryDelayMsForCurrentConfiguration {
    if ([self shouldUseCoreHIDTightFreeMouseHandoff]) {
        return MLCoreHIDFreeMouseReentryDelayMs;
    }

    return MLFreeMouseReentryDelayMs;
}

- (CGFloat)freeMouseReentryInsetForCurrentConfiguration {
    if ([self shouldUseCoreHIDTightFreeMouseHandoff]) {
        return MLCoreHIDFreeMouseReentryInset;
    }

    return MLFreeMouseReentryInset;
}

- (NSScreen *)bestScreenForAppKitScreenPoint:(NSPoint)screenPoint fallback:(NSScreen *)fallbackScreen {
    NSScreen *containingScreen = nil;
    NSScreen *nearestScreen = fallbackScreen ?: [NSScreen mainScreen];
    CGFloat nearestDistance = CGFLOAT_MAX;

    for (NSScreen *screen in [NSScreen screens]) {
        if (NSPointInRect(screenPoint, screen.frame)) {
            containingScreen = screen;
            break;
        }

        CGFloat distance = MLSquaredDistanceToRect(screenPoint, screen.frame);
        if (distance < nearestDistance) {
            nearestDistance = distance;
            nearestScreen = screen;
        }
    }

    return containingScreen ?: nearestScreen;
}

- (NSPoint)resolvedCoreHIDExitHandoffViewPointForEvent:(NSEvent *)event
                                              exitEdge:(MLFreeMouseExitEdge)exitEdge
                                     semanticViewPoint:(NSPoint)semanticViewPoint {
    NSRect bounds = self.view.bounds;
    NSPoint basisPoint = semanticViewPoint;
    if (!isfinite(basisPoint.x) || !isfinite(basisPoint.y)) {
        if (![self bestCoreHIDHandoffTruthViewPointForEvent:event outPoint:&basisPoint]) {
            basisPoint = NSMakePoint(NSMidX(bounds), NSMidY(bounds));
        }
    }

    CGFloat sensitivity = [SettingsClass pointerSensitivityFor:self.app.host.uuid];
    if (!isfinite(sensitivity) || sensitivity <= 0.0) {
        sensitivity = 1.0;
    }
    sensitivity = MIN(MAX(sensitivity, 0.25), 3.0);

    CGFloat projectedOvershoot = MLCoreHIDFreeMouseExitHandoffNudge;
    switch (exitEdge) {
        case MLFreeMouseExitEdgeLeft:
        case MLFreeMouseExitEdgeRight:
            projectedOvershoot = fabs(event.deltaX) * sensitivity;
            break;
        case MLFreeMouseExitEdgeTop:
        case MLFreeMouseExitEdgeBottom:
            projectedOvershoot = fabs(event.deltaY) * sensitivity;
            break;
        case MLFreeMouseExitEdgeNone:
        default:
            break;
    }
    projectedOvershoot = MIN(MAX(projectedOvershoot, MLCoreHIDFreeMouseExitHandoffNudge),
                             MLCoreHIDFreeMouseExitHandoffMaxProjectedOvershoot);

    NSPoint handoffPoint = semanticViewPoint;
    switch (exitEdge) {
        case MLFreeMouseExitEdgeLeft:
            handoffPoint.x = MIN(basisPoint.x, NSMinX(bounds) - projectedOvershoot);
            handoffPoint.y = MLClampCGFloat(basisPoint.y, NSMinY(bounds), NSMaxY(bounds));
            break;
        case MLFreeMouseExitEdgeRight:
            handoffPoint.x = MAX(basisPoint.x, NSMaxX(bounds) + projectedOvershoot);
            handoffPoint.y = MLClampCGFloat(basisPoint.y, NSMinY(bounds), NSMaxY(bounds));
            break;
        case MLFreeMouseExitEdgeTop:
            handoffPoint.x = MLClampCGFloat(basisPoint.x, NSMinX(bounds), NSMaxX(bounds));
            handoffPoint.y = MAX(basisPoint.y, NSMaxY(bounds) + projectedOvershoot);
            break;
        case MLFreeMouseExitEdgeBottom:
            handoffPoint.x = MLClampCGFloat(basisPoint.x, NSMinX(bounds), NSMaxX(bounds));
            handoffPoint.y = MIN(basisPoint.y, NSMinY(bounds) - projectedOvershoot);
            break;
        case MLFreeMouseExitEdgeNone:
        default:
            break;
    }

    return handoffPoint;
}

- (BOOL)coreGraphicsCursorPointForViewPoint:(NSPoint)viewPoint
                                      event:(NSEvent *)event
                                   exitEdge:(MLFreeMouseExitEdge)exitEdge
                               outDisplayID:(CGDirectDisplayID *)displayID
                                   outPoint:(CGPoint *)outPoint {
    if (outPoint == NULL || displayID == NULL || self.view.window == nil) {
        return NO;
    }

    NSScreen *fallbackScreen = self.view.window.screen ?: [NSScreen mainScreen];
    NSRect bounds = self.view.bounds;
    if (NSIsEmptyRect(bounds)) {
        return NO;
    }

    NSPoint handoffPoint = [self resolvedCoreHIDExitHandoffViewPointForEvent:event
                                                                    exitEdge:exitEdge
                                                           semanticViewPoint:viewPoint];
    NSPoint windowPoint = [self.view convertPoint:handoffPoint toView:nil];
    NSPoint screenPoint = [self.view.window convertPointToScreen:windowPoint];

    NSScreen *targetScreen = [self bestScreenForAppKitScreenPoint:screenPoint fallback:fallbackScreen];
    if (targetScreen == nil) {
        return NO;
    }

    NSRect targetFrame = targetScreen.frame;
    NSPoint clampedScreenPoint = screenPoint;
    switch (exitEdge) {
        case MLFreeMouseExitEdgeLeft:
            clampedScreenPoint.x = MAX(screenPoint.x, NSMinX(targetFrame));
            break;
        case MLFreeMouseExitEdgeRight:
            clampedScreenPoint.x = MIN(screenPoint.x, NSMaxX(targetFrame) - 1.0);
            break;
        case MLFreeMouseExitEdgeTop:
            clampedScreenPoint.y = MIN(screenPoint.y, NSMaxY(targetFrame) - 1.0);
            break;
        case MLFreeMouseExitEdgeBottom:
            clampedScreenPoint.y = MAX(screenPoint.y, NSMinY(targetFrame));
            break;
        case MLFreeMouseExitEdgeNone:
        default:
            break;
    }

    CGFloat displayLocalX = clampedScreenPoint.x - NSMinX(targetFrame);
    CGFloat displayLocalY = NSMaxY(targetFrame) - clampedScreenPoint.y;
    displayLocalX = MLClampCGFloat(displayLocalX, 0.0, MAX(NSWidth(targetFrame) - 1.0, 0.0));
    displayLocalY = MLClampCGFloat(displayLocalY, 0.0, MAX(NSHeight(targetFrame) - 1.0, 0.0));
    NSNumber *screenNumber = targetScreen.deviceDescription[@"NSScreenNumber"];
    *displayID = screenNumber != nil ? (CGDirectDisplayID)screenNumber.unsignedIntValue : CGMainDisplayID();
    outPoint->x = displayLocalX;
    outPoint->y = displayLocalY;
    return isfinite(outPoint->x) && isfinite(outPoint->y);
}

- (void)applyCoreHIDReleasedWarpIfNeededForExitEdge:(MLFreeMouseExitEdge)exitEdge
                                              event:(NSEvent *)event
                                  semanticViewPoint:(NSPoint)semanticViewPoint
                                             reason:(NSString *)reason {
    if (![self.hidSupport shouldUseCoreHIDFreeMouseAbsoluteSyncForCurrentConfiguration] ||
        self.view.window == nil ||
        exitEdge == MLFreeMouseExitEdgeNone) {
        return;
    }

    CGDirectDisplayID displayID = CGMainDisplayID();
    CGPoint cursorPoint = CGPointZero;
    if (![self coreGraphicsCursorPointForViewPoint:semanticViewPoint
                                             event:event
                                          exitEdge:exitEdge
                                      outDisplayID:&displayID
                                          outPoint:&cursorPoint]) {
        return;
    }

    Log(LOG_I, @"[diag] CoreHID free mouse handoff: stage=exit reason=%@ owner=%@ source=%@ edge=%ld display=%u warp=(%.1f,%.1f) semanticView=(%.1f,%.1f)",
        reason ?: @"unknown",
        [self freeMouseSemanticOwnerLabel],
        [self freeMouseSemanticSourceLabel],
        (long)exitEdge,
        (unsigned int)displayID,
        cursorPoint.x,
        cursorPoint.y,
        semanticViewPoint.x,
        semanticViewPoint.y);
    CGDisplayMoveCursorToPoint(displayID, cursorPoint);
}

- (void)syncRemoteCursorToViewPoint:(NSPoint)viewPoint clampToBounds:(BOOL)clampToBounds {
    if (![self supportsRemoteDesktopCursorSync] || ![self hasReadyInputContext] || !self.view.window) {
        return;
    }
    if (!isfinite(viewPoint.x) || !isfinite(viewPoint.y)) {
        return;
    }
    if (self.edgeMenuTemporaryReleaseActive || self.edgeMenuDragging || self.edgeMenuMenuVisible) {
        return;
    }

    [self.hidSupport updateFreeMouseVirtualCursorAnchorWithViewPoint:viewPoint
                                                      referenceSize:self.view.bounds.size];
    [self.hidSupport sendAbsoluteMousePositionForViewPoint:viewPoint
                                             referenceSize:self.view.bounds.size
                                             clampToBounds:clampToBounds];
}

- (void)uncaptureFreeMouseForExitEdge:(MLFreeMouseExitEdge)exitEdge
                                event:(NSEvent *)event
                        syncViewPoint:(NSPoint)syncViewPoint
                                 code:(NSString *)code
                               reason:(NSString *)reason {
    NSPoint semanticViewPoint = syncViewPoint;
    if (!isfinite(semanticViewPoint.x) || !isfinite(semanticViewPoint.y)) {
        semanticViewPoint = [self viewPointForMouseEvent:event];
    }

    [self syncRemoteCursorToViewPoint:semanticViewPoint clampToBounds:YES];
    [self applyCoreHIDReleasedWarpIfNeededForExitEdge:exitEdge
                                                event:event
                                    semanticViewPoint:semanticViewPoint
                                               reason:reason];
    [self uncaptureMouseWithCode:code reason:reason];

    if ([self edgeMenuMatchesExitEdge:exitEdge] &&
        [self edgeMenuShouldBeVisible] &&
        [self edgeMenuReleaseExitEdgeForEvent:event point:semanticViewPoint] == exitEdge) {
        [self activateEdgeMenuDockForExitEdge:exitEdge];
    } else {
        [self beginFreeMouseEdgeReentryForExitEdge:exitEdge];
    }
}

- (void)uncaptureFreeMouseForExitEdge:(MLFreeMouseExitEdge)exitEdge
                                event:(NSEvent *)event
                                 code:(NSString *)code
                               reason:(NSString *)reason {
    [self uncaptureFreeMouseForExitEdge:exitEdge
                                  event:event
                          syncViewPoint:[self preferredFreeMouseExitSyncViewPointForEvent:event exitEdge:exitEdge]
                                   code:code
                                 reason:reason];
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

    Log(LOG_I, @"[diag] Mouse exit event: stage=%@ owner=%@ source=%@ eventType=%ld eventView=(%.1f,%.1f) currentView=(%.1f,%.1f) insideEvent=%d insideCurrent=%d bounds=%.1fx%.1f clickAge=%llums lastClickPhase=%@ lastClickView=(%.1f,%.1f) lastClickInside=%d captured=%d key=%d main=%d fullscreen=%d",
        stage ?: @"unknown",
        [self freeMouseSemanticOwnerLabel],
        [self freeMouseSemanticSourceLabel],
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

    Log(LOG_D, @"[clickdiag] trigger=%@ owner=%@ source=%@ localView=(%.1f,%.1f) global=(%.1f,%.1f) remoteLast=%@ lastClick=%@",
        reason ?: @"unknown",
        [self freeMouseSemanticOwnerLabel],
        [self freeMouseSemanticSourceLabel],
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
    Log(LOG_I, @"[diag] Mouse uncapture: stage=%@ code=%@ reason=%@ owner=%@ source=%@ captured=%d hidden=%ld input=%d buttons=%lu key=%d main=%d fullscreen=%d",
        resolvedStage,
        resolvedCode,
        resolvedReason,
        [self freeMouseSemanticOwnerLabel],
        [self freeMouseSemanticSourceLabel],
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
        self.pendingMouseUncaptureRecheckScheduled = NO;
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
    self.pendingMouseUncaptureRecheckScheduled = NO;
    self.pendingMouseUncaptureDiagnosticCode = nil;
    self.pendingMouseUncaptureDiagnosticReason = nil;
    [self uncaptureMouseWithCode:code reason:reason];
}

- (BOOL)shouldDelayDeferredMouseUncaptureCommit {
    NSString *code = self.pendingMouseUncaptureDiagnosticCode;
    if (!([code isEqualToString:@"MUC003"] ||
          [code isEqualToString:@"MUC005"] ||
          [code isEqualToString:@"MUC006"])) {
        return NO;
    }
    if (!self.isRemoteDesktopMode || ![self isWindowFullscreen]) {
        return NO;
    }
    if (self.stopStreamInProgress || self.reconnectInProgress || self.fullscreenTransitionInProgress) {
        return NO;
    }
    if (![self isCurrentPointerInsideStreamView]) {
        return NO;
    }
    return YES;
}

- (void)scheduleDeferredMouseUncaptureRecheckIfNeeded {
    if (self.pendingMouseUncaptureRecheckScheduled ||
        !self.pendingMouseUncaptureAfterButtonsReleased) {
        return;
    }

    self.pendingMouseUncaptureRecheckScheduled = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(MLDeferredMouseUncaptureRecoveryDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        strongSelf.pendingMouseUncaptureRecheckScheduled = NO;
        [strongSelf completeDeferredMouseUncaptureIfNeeded];
    });
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
        self.pendingMouseUncaptureRecheckScheduled = NO;
        self.pendingMouseUncaptureDiagnosticCode = nil;
        self.pendingMouseUncaptureDiagnosticReason = nil;
        return;
    }

    if ([self canCaptureMouseNow]) {
        [self logMouseUncaptureStage:@"deferred-canceled-recovered"
                                code:self.pendingMouseUncaptureDiagnosticCode
                              reason:self.pendingMouseUncaptureDiagnosticReason];
        self.pendingMouseUncaptureRecheckScheduled = NO;
        self.pendingMouseUncaptureDiagnosticCode = nil;
        self.pendingMouseUncaptureDiagnosticReason = nil;
        return;
    }

    if ([self shouldDelayDeferredMouseUncaptureCommit]) {
        self.pendingMouseUncaptureAfterButtonsReleased = YES;
        [self logMouseUncaptureStage:@"deferred-wait-recovery"
                                code:self.pendingMouseUncaptureDiagnosticCode
                              reason:self.pendingMouseUncaptureDiagnosticReason];
        [self scheduleDeferredMouseUncaptureRecheckIfNeeded];
        return;
    }

    NSString *code = self.pendingMouseUncaptureDiagnosticCode;
    NSString *reason = self.pendingMouseUncaptureDiagnosticReason;
    self.pendingMouseUncaptureRecheckScheduled = NO;
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

- (void)reconcileHybridFreeMouseAnchorToCurrentPointer {
    if (![self supportsRemoteDesktopCursorSync] || ![self hasReadyInputContext] || !self.view.window) {
        return;
    }
    if (self.edgeMenuTemporaryReleaseActive || self.edgeMenuDragging || self.edgeMenuMenuVisible) {
        return;
    }
    if (![self.hidSupport shouldUseCoreHIDFreeMouseAbsoluteSyncForCurrentConfiguration]) {
        return;
    }

    if (!self.hasCoreHIDFreeMouseLastTruthPoint) {
        return;
    }

    NSPoint currentPoint = self.coreHIDFreeMouseLastTruthPoint;
    NSRect toleranceBounds = NSInsetRect(self.view.bounds, -2.0, -2.0);
    if (!NSPointInRect(currentPoint, toleranceBounds)) {
        return;
    }

    [self.hidSupport reconcileFreeMouseVirtualCursorToViewPoint:currentPoint
                                                  referenceSize:self.view.bounds.size
                                            correctionThreshold:MLCoreHIDFreeMouseCorrectionThreshold];
}

- (NSPoint)resolvedAbsoluteSyncViewPointForMouseEvent:(NSEvent *)event
                                        clampToBounds:(BOOL)clampToBounds
                                               reason:(NSString *)reason {
    NSPoint eventPoint = [self viewPointForMouseEvent:event];
    if ([self.hidSupport shouldUseCoreHIDFreeMouseAbsoluteSyncForCurrentConfiguration]) {
        return eventPoint;
    }
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

- (void)dispatchMouseButton:(int)button pressed:(BOOL)pressed event:(NSEvent *)event {
    if (![self supportsRemoteDesktopCursorSync] || ![self hasReadyInputContext]) {
        if (pressed) {
            [self.hidSupport mouseDown:event withButton:button];
        } else {
            [self.hidSupport mouseUp:event withButton:button];
        }
        return;
    }

    if ([self.hidSupport shouldUseCoreHIDFreeMouseAbsoluteSyncForCurrentConfiguration] &&
        ![self shouldUseCoreHIDVirtualSemanticLocation]) {
        if (pressed) {
            [self.hidSupport mouseDown:event withButton:button];
        } else {
            [self.hidSupport mouseUp:event withButton:button];
        }
        return;
    }

    NSPoint point = [self viewPointForMouseEvent:event];
    if (!NSPointInRect(point, self.view.bounds)) {
        if (pressed) {
            [self.hidSupport mouseDown:event withButton:button];
        } else {
            [self.hidSupport mouseUp:event withButton:button];
        }
        return;
    }

    NSPoint resolvedPoint = [self resolvedAbsoluteSyncViewPointForMouseEvent:event
                                                               clampToBounds:YES
                                                                      reason:@"button-sync"];
    [self.hidSupport updateFreeMouseVirtualCursorAnchorWithViewPoint:resolvedPoint
                                                      referenceSize:self.view.bounds.size];
    [self.hidSupport sendMouseButton:button
                             pressed:pressed
                   syncedToViewPoint:resolvedPoint
                       referenceSize:self.view.bounds.size
                       clampToBounds:YES];
    self.pendingHybridRemoteCursorSync = NO;
}

- (BOOL)consumePendingHybridRemoteCursorSyncForEvent:(NSEvent *)event reason:(NSString *)reason {
    if (!self.pendingHybridRemoteCursorSync ||
        !self.isRemoteDesktopMode ||
        !self.isMouseCaptured ||
        ![self supportsRemoteDesktopCursorSync]) {
        return NO;
    }

    if ([self.hidSupport shouldUseCoreHIDFreeMouseAbsoluteSyncForCurrentConfiguration] &&
        ![self shouldUseCoreHIDVirtualSemanticLocation]) {
        return NO;
    }

    [self reassertHiddenLocalCursorIfNeededWithReason:reason ?: @"hybrid-free-mouse-sync"];
    [self syncRemoteCursorToMouseEvent:event clampToBounds:YES];
    self.pendingHybridRemoteCursorSync = NO;
    Log(LOG_D, @"[diag] Hybrid free mouse cursor sync completed: reason=%@",
        reason ?: @"unknown");
    return YES;
}

- (MLFreeMouseExitEdge)edgeMenuReleaseExitEdgeForEvent:(NSEvent *)event point:(NSPoint)point {
    if (![self edgeMenuShouldBeVisible] ||
        self.edgeMenuButton == nil ||
        self.edgeMenuButton.hidden ||
        event == nil) {
        return MLFreeMouseExitEdgeNone;
    }

    if ([self shouldUseCoreHIDTightFreeMouseHandoff]) {
        point = [self boundaryInteractionViewPointForMouseEvent:event];
    }

    NSRect triggerRect = [self edgeMenuInteractionRectInBounds:self.view.bounds];
    if (!NSPointInRect(point, triggerRect)) {
        return MLFreeMouseExitEdgeNone;
    }

    switch (self.edgeMenuDockEdge) {
        case MLFreeMouseExitEdgeLeft:
            return event.deltaX < 0.0 ? MLFreeMouseExitEdgeLeft : MLFreeMouseExitEdgeNone;
        case MLFreeMouseExitEdgeRight:
            return event.deltaX > 0.0 ? MLFreeMouseExitEdgeRight : MLFreeMouseExitEdgeNone;
        case MLFreeMouseExitEdgeTop:
            return event.deltaY > 0.0 ? MLFreeMouseExitEdgeTop : MLFreeMouseExitEdgeNone;
        case MLFreeMouseExitEdgeBottom:
            return event.deltaY < 0.0 ? MLFreeMouseExitEdgeBottom : MLFreeMouseExitEdgeNone;
        case MLFreeMouseExitEdgeNone:
        default:
            return MLFreeMouseExitEdgeNone;
    }
}

- (MLFreeMouseExitEdge)freeMouseExitEdgeForOutsideViewPoint:(NSPoint)point {
    NSRect bounds = self.view.bounds;
    if (NSIsEmptyRect(bounds) || NSPointInRect(point, bounds)) {
        return MLFreeMouseExitEdgeNone;
    }

    CGFloat leftOverflow = point.x < NSMinX(bounds) ? (NSMinX(bounds) - point.x) : 0.0;
    CGFloat rightOverflow = point.x > NSMaxX(bounds) ? (point.x - NSMaxX(bounds)) : 0.0;
    CGFloat bottomOverflow = point.y < NSMinY(bounds) ? (NSMinY(bounds) - point.y) : 0.0;
    CGFloat topOverflow = point.y > NSMaxY(bounds) ? (point.y - NSMaxY(bounds)) : 0.0;

    CGFloat bestOverflow = 0.0;
    MLFreeMouseExitEdge bestEdge = MLFreeMouseExitEdgeNone;
    if (leftOverflow > bestOverflow) {
        bestOverflow = leftOverflow;
        bestEdge = MLFreeMouseExitEdgeLeft;
    }
    if (rightOverflow > bestOverflow) {
        bestOverflow = rightOverflow;
        bestEdge = MLFreeMouseExitEdgeRight;
    }
    if (bottomOverflow > bestOverflow) {
        bestOverflow = bottomOverflow;
        bestEdge = MLFreeMouseExitEdgeBottom;
    }
    if (topOverflow > bestOverflow) {
        bestOverflow = topOverflow;
        bestEdge = MLFreeMouseExitEdgeTop;
    }

    return bestEdge;
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

    BOOL tightHandoff = [self shouldUseCoreHIDTightFreeMouseHandoff];
    NSPoint currentPoint = [self currentMouseLocationInViewCoordinates];
    NSPoint point = tightHandoff
        ? currentPoint
        : [self boundaryInteractionViewPointForMouseEvent:event];
    CGFloat threshold = tightHandoff ? MLCoreHIDFreeMouseExitThreshold : 2.0;
    MLFreeMouseExitEdge edgeMenuExitEdge = [self edgeMenuReleaseExitEdgeForEvent:event point:point];
    if (edgeMenuExitEdge != MLFreeMouseExitEdgeNone) {
        return edgeMenuExitEdge;
    }

    MLFreeMouseExitEdge currentPointerExitEdge = [self freeMouseExitEdgeForOutsideViewPoint:currentPoint];
    if (currentPointerExitEdge != MLFreeMouseExitEdgeNone) {
        return currentPointerExitEdge;
    }

    MLFreeMouseExitEdge semanticExitEdge = [self freeMouseExitEdgeForOutsideViewPoint:point];
    if (tightHandoff && semanticExitEdge != MLFreeMouseExitEdgeNone) {
        return semanticExitEdge;
    }
    if (!tightHandoff && semanticExitEdge != MLFreeMouseExitEdgeNone) {
        return semanticExitEdge;
    }

    BOOL pushingLeft = point.x <= NSMinX(bounds) + threshold && event.deltaX < 0.0;
    BOOL pushingRight = point.x >= NSMaxX(bounds) - threshold && event.deltaX > 0.0;
    BOOL pushingBottom = point.y <= NSMinY(bounds) + threshold && event.deltaY < 0.0;
    BOOL pushingTop = point.y >= NSMaxY(bounds) - threshold && event.deltaY > 0.0;

    MLFreeMouseExitEdge candidateEdge = semanticExitEdge;
    if (candidateEdge == MLFreeMouseExitEdgeNone) {
        if (pushingLeft) {
            candidateEdge = MLFreeMouseExitEdgeLeft;
        } else if (pushingRight) {
            candidateEdge = MLFreeMouseExitEdgeRight;
        } else if (pushingBottom) {
            candidateEdge = MLFreeMouseExitEdgeBottom;
        } else if (pushingTop) {
            candidateEdge = MLFreeMouseExitEdgeTop;
        }
    }

    if (tightHandoff && candidateEdge != MLFreeMouseExitEdgeNone) {
        return candidateEdge;
    }

    if (pushingLeft) return MLFreeMouseExitEdgeLeft;
    if (pushingRight) return MLFreeMouseExitEdgeRight;
    if (pushingBottom) return MLFreeMouseExitEdgeBottom;
    if (pushingTop) return MLFreeMouseExitEdgeTop;
    return MLFreeMouseExitEdgeNone;
}

- (BOOL)shouldUncaptureFreeMouseForComputedExitEdge:(MLFreeMouseExitEdge)exitEdge {
    if (exitEdge == MLFreeMouseExitEdgeNone) {
        return NO;
    }

    uint64_t now = [self nowMs];
    if (self.suppressFreeMouseEdgeUncaptureUntilMs > now) {
        return NO;
    }
    if ([self hasPressedMouseButtonsForCaptureTransition]) {
        return NO;
    }
    return YES;
}

- (NSPoint)preferredFreeMouseExitSyncViewPointForEvent:(NSEvent *)event
                                              exitEdge:(MLFreeMouseExitEdge)exitEdge {
    NSPoint semanticPoint = [self boundaryInteractionViewPointForMouseEvent:event];
    if (![self shouldUseCoreHIDTightFreeMouseHandoff] || exitEdge == MLFreeMouseExitEdgeNone) {
        return semanticPoint;
    }

    return MLClampFreeMousePointToExitEdge(semanticPoint, self.view.bounds, exitEdge);
}

- (BOOL)shouldUncaptureFreeMouseForEdgeEvent:(NSEvent *)event {
    return [self shouldUncaptureFreeMouseForComputedExitEdge:[self freeMouseExitEdgeForEvent:event]];
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
    CGFloat reentryDelayMs = [self freeMouseReentryDelayMsForCurrentConfiguration];
    if (now < self.pendingFreeMouseReentryAtMs || (now - self.pendingFreeMouseReentryAtMs) < (uint64_t)reentryDelayMs) {
        return NO;
    }

    NSRect bounds = self.view.bounds;
    if (NSIsEmptyRect(bounds)) {
        return NO;
    }

    NSPoint point = [self shouldUseCoreHIDTightFreeMouseHandoff]
        ? [self currentMouseLocationInViewCoordinates]
        : [self viewPointForMouseEvent:event];
    CGFloat reentryInset = [self freeMouseReentryInsetForCurrentConfiguration];
    switch (self.pendingFreeMouseReentryEdge) {
        case MLFreeMouseExitEdgeLeft:
            return event.deltaX > 0.0 && point.x >= NSMinX(bounds) + reentryInset;
        case MLFreeMouseExitEdgeRight:
            return event.deltaX < 0.0 && point.x <= NSMaxX(bounds) - reentryInset;
        case MLFreeMouseExitEdgeTop:
            return event.deltaY < 0.0 && point.y <= NSMaxY(bounds) - reentryInset;
        case MLFreeMouseExitEdgeBottom:
            return event.deltaY > 0.0 && point.y >= NSMinY(bounds) + reentryInset;
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

    NSPoint syncPoint = [self shouldUseCoreHIDTightFreeMouseHandoff]
        ? [self currentMouseLocationInViewCoordinates]
        : [self viewPointForMouseEvent:event];
    [self prepareCoreHIDVirtualCursorForSystemPointerSyncIfNeeded];
    [self syncRemoteCursorToViewPoint:syncPoint clampToBounds:YES];
    [self ensureStreamWindowKeyIfPossible];
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

    if ([self usesAbsoluteRemoteDesktopPointerSync] ||
        [self.hidSupport shouldUseCoreHIDFreeMouseAbsoluteSyncForCurrentConfiguration]) {
        [self prepareCoreHIDVirtualCursorForSystemPointerSyncIfNeeded];
        [self syncRemoteCursorToMouseEvent:event clampToBounds:YES];
    }

    [self ensureStreamWindowKeyIfPossible];
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
        [self updateEdgeMenuPointerInsideForPoint:[self boundaryInteractionViewPointForMouseEvent:event]];
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

    if ([self.hidSupport shouldUseCoreHIDFreeMouseAbsoluteSyncForCurrentConfiguration]) {
        if (self.pendingFreeMouseReentryEdge != MLFreeMouseExitEdgeNone ||
            self.pendingMouseExitedRecapture ||
            ![self isCurrentPointerInsideStreamView]) {
            return NO;
        }
    }

    [self prepareCoreHIDVirtualCursorForSystemPointerSyncIfNeeded];
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
        BOOL hasVirtualAnchor = NO;
        if ([self.hidSupport shouldUseCoreHIDFreeMouseAbsoluteSyncForCurrentConfiguration]) {
            hasVirtualAnchor = [self.hidSupport getFreeMouseVirtualCursorPoint:NULL referenceSize:NULL];
        }
        if (![self.hidSupport shouldUseCoreHIDFreeMouseAbsoluteSyncForCurrentConfiguration] || !hasVirtualAnchor) {
            [self.hidSupport updateFreeMouseVirtualCursorAnchorWithViewPoint:[self currentMouseLocationInViewCoordinates]
                                                              referenceSize:self.view.bounds.size];
        }
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

        if ([strongSelf handleKeyboardTranslationRuleForEvent:event]) {
            return nil;
        }

        StreamShortcut *borderlessShortcut = [strongSelf streamShortcutForAction:MLShortcutActionToggleBorderlessWindowed];
        if ([strongSelf event:event matchesShortcut:borderlessShortcut]) {
            [strongSelf resolveDeferredCommandModifierWithoutRemoteTapWithReason:@"local-monitor-borderless-shortcut" event:event];
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
            [strongSelf resolveDeferredCommandModifierWithoutRemoteTapWithReason:@"local-monitor-control-center-shortcut" event:event];
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
    [self updateCoreHIDFreeMouseTruthPointFromEvent:event];
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
        [self prepareCoreHIDVirtualCursorForSystemPointerSyncIfNeeded];
        [self syncRemoteCursorToMouseEvent:event clampToBounds:YES];
        [self rearmMouseCaptureIfPossibleWithReason:@"mouse-entered-view"];
    }
}

- (void)mouseExited:(NSEvent *)event {
    [self updateCoreHIDFreeMouseTruthPointFromEvent:event];
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
        NSPoint eventPoint = [self shouldPreferAppKitSystemPointerForBoundaryOrGestureEvent:event]
            ? [self actualAppKitViewPointForBoundaryOrGestureEvent:event]
            : [self viewPointForMouseEvent:event];
        NSPoint currentPoint = [self currentMouseLocationInViewCoordinates];
        MLFreeMouseExitEdge currentExitEdge = [self freeMouseExitEdgeForOutsideViewPoint:currentPoint];
        BOOL eventInside = NSPointInRect(eventPoint, self.view.bounds);
        BOOL currentInside = NSPointInRect(currentPoint, self.view.bounds);
        BOOL shouldHonorCurrentOutsideForCoreHID = [self shouldUseCoreHIDTightFreeMouseHandoff] &&
            currentExitEdge != MLFreeMouseExitEdgeNone &&
            !currentInside;
        if ((eventInside || currentInside) && !shouldHonorCurrentOutsideForCoreHID) {
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
        if (currentExitEdge != MLFreeMouseExitEdgeNone) {
            [self uncaptureFreeMouseForExitEdge:currentExitEdge
                                          event:event
                                  syncViewPoint:[self preferredFreeMouseExitSyncViewPointForEvent:event exitEdge:currentExitEdge]
                                           code:@"MUC102"
                                         reason:@"mouse-exited-view"];
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
    NSEventModifierFlags relevantModifiers = MLRelevantShortcutModifiers(event.modifierFlags);
    if ([self shouldDeferCommandModifierForShortcutHandlingWithEvent:event]) {
        self.deferredCommandModifierPendingForShortcutTranslation = YES;
        self.deferredCommandModifierForwardedAsHeld = NO;
        NSUInteger dispatchToken = ++self.deferredCommandModifierDispatchToken;
        Log(LOG_D, @"[diag] deferring command modifier for shortcut translation: %@",
            MLDisconnectEventSummary(event));
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf ||
                !strongSelf.deferredCommandModifierPendingForShortcutTranslation ||
                strongSelf.deferredCommandModifierForwardedAsHeld ||
                strongSelf.deferredCommandModifierDispatchToken != dispatchToken) {
                return;
            }

            NSEventModifierFlags currentModifiers = MLRelevantShortcutModifiers([NSEvent modifierFlags]);
            if (currentModifiers != NSEventModifierFlagCommand) {
                return;
            }

            strongSelf.deferredCommandModifierForwardedAsHeld = YES;
            Log(LOG_I, @"[diag] deferred command forwarded as held mapped modifier: %@",
                MLDisconnectEventSummary(event));
            [strongSelf.hidSupport beginDeferredShortcutTranslationCommandHoldForKeyCode:event.keyCode];
        });
        return;
    }

    if (self.deferredCommandModifierPendingForShortcutTranslation) {
        if ((relevantModifiers & NSEventModifierFlagCommand) == 0) {
            self.deferredCommandModifierDispatchToken += 1;
            self.deferredCommandModifierPendingForShortcutTranslation = NO;

            if (self.deferredCommandModifierForwardedAsHeld) {
                self.deferredCommandModifierForwardedAsHeld = NO;
                Log(LOG_I, @"[diag] deferred command released after held forwarding: %@",
                    MLDisconnectEventSummary(event));
                [self.hidSupport endDeferredShortcutTranslationCommandHoldForKeyCode:event.keyCode];
            } else {
                Log(LOG_I, @"[diag] deferred command resolved as standalone mapped tap: %@",
                    MLDisconnectEventSummary(event));
                [self.hidSupport sendSyntheticRemoteModifierTapForKeyCode:event.keyCode
                            preferShortcutTranslationCommandMapping:YES];
            }
            return;
        }

        if (self.deferredCommandModifierForwardedAsHeld) {
            [self.hidSupport flagsChanged:event];
        } else {
            Log(LOG_D, @"[diag] keeping command modifier deferred while awaiting shortcut resolution: %@",
                MLDisconnectEventSummary(event));
        }
        return;
    }

    [self.hidSupport flagsChanged:event];

    StreamShortcut *releaseShortcut = [self streamShortcutForAction:MLShortcutActionReleaseMouseCapture];
    NSEventModifierFlags relevantMods = relevantModifiers;

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
    [self resolveDeferredCommandModifierWithoutRemoteTapWithReason:@"plain-keydown" event:event];
    [self.hidSupport keyDown:event];
}

- (void)keyUp:(NSEvent *)event {
    [self.hidSupport keyUp:event];
}


- (void)mouseDown:(NSEvent *)event {
    [self updateCoreHIDFreeMouseTruthPointFromEvent:event];
    [self reassertHiddenLocalCursorIfNeededWithReason:@"left-down"];
    [self logMouseClickDiagnosticsForPhase:@"left-down" event:event];
    [self captureFreeMouseIfNeededForEvent:event];
    [self dispatchMouseButton:BUTTON_LEFT pressed:YES event:event];
    if (!self.isRemoteDesktopMode) {
        [self captureMouse];
    }
}

- (void)mouseUp:(NSEvent *)event {
    [self updateCoreHIDFreeMouseTruthPointFromEvent:event];
    [self reassertHiddenLocalCursorIfNeededWithReason:@"left-up"];
    [self logMouseClickDiagnosticsForPhase:@"left-up" event:event];
    [self dispatchMouseButton:BUTTON_LEFT pressed:NO event:event];
    [self completeDeferredMouseUncaptureIfNeeded];
}

- (void)rightMouseDown:(NSEvent *)event {
    [self updateCoreHIDFreeMouseTruthPointFromEvent:event];
    [self reassertHiddenLocalCursorIfNeededWithReason:@"right-down"];
    [self logMouseClickDiagnosticsForPhase:@"right-down" event:event];
    if (!self.isMouseCaptured) {
        self.suppressNextRightMouseUp = YES;
        [self presentStreamMenuAtEvent:event];
        return;
    }

    int button = (event.buttonNumber == 0) ? BUTTON_LEFT : BUTTON_RIGHT;
    [self dispatchMouseButton:button pressed:YES event:event];
}

- (void)rightMouseUp:(NSEvent *)event {
    [self updateCoreHIDFreeMouseTruthPointFromEvent:event];
    [self reassertHiddenLocalCursorIfNeededWithReason:@"right-up"];
    [self logMouseClickDiagnosticsForPhase:@"right-up" event:event];
    if (self.suppressNextRightMouseUp) {
        self.suppressNextRightMouseUp = NO;
        return;
    }

    int button = (event.buttonNumber == 0) ? BUTTON_LEFT : BUTTON_RIGHT;
    [self dispatchMouseButton:button pressed:NO event:event];
    [self completeDeferredMouseUncaptureIfNeeded];
}

- (void)otherMouseDown:(NSEvent *)event {
    [self updateCoreHIDFreeMouseTruthPointFromEvent:event];
    [self reassertHiddenLocalCursorIfNeededWithReason:@"other-down"];
    [self logMouseClickDiagnosticsForPhase:@"other-down" event:event];
    int button = [self getMouseButtonFromEvent:event];
    if (button == 0) {
        return;
    }
    [self captureFreeMouseIfNeededForEvent:event];
    [self dispatchMouseButton:button pressed:YES event:event];
}

- (void)otherMouseUp:(NSEvent *)event {
    [self updateCoreHIDFreeMouseTruthPointFromEvent:event];
    [self reassertHiddenLocalCursorIfNeededWithReason:@"other-up"];
    [self logMouseClickDiagnosticsForPhase:@"other-up" event:event];
    int button = [self getMouseButtonFromEvent:event];
    if (button == 0) {
        return;
    }
    [self dispatchMouseButton:button pressed:NO event:event];
    [self completeDeferredMouseUncaptureIfNeeded];
}

- (void)mouseMoved:(NSEvent *)event {
    [self updateCoreHIDFreeMouseTruthPointFromEvent:event];
    [self reconcileHybridFreeMouseAnchorToCurrentPointer];
    if ([self handleEdgeMenuTemporaryReleaseForEvent:event]) {
        return;
    }

    if ([self attemptPendingMouseExitedRecaptureIfNeededForEvent:event]) {
        return;
    }

    if ([self recaptureFreeMouseAfterEdgeUncaptureIfNeededForEvent:event]) {
        return;
    }

    if ([self consumePendingHybridRemoteCursorSyncForEvent:event reason:@"mouse-moved-hybrid-sync"]) {
        return;
    }

    MLFreeMouseExitEdge exitEdge = [self freeMouseExitEdgeForEvent:event];
    if ([self shouldUncaptureFreeMouseForComputedExitEdge:exitEdge]) {
        Log(LOG_I, @"[diag] Free mouse uncaptured from fullscreen edge");
        [self uncaptureFreeMouseForExitEdge:exitEdge
                                      event:event
                                       code:@"MUC104"
                                     reason:@"free-mouse-edge-mouse-moved"];
        return;
    }
    [self.hidSupport mouseMoved:event];
}

- (void)mouseDragged:(NSEvent *)event {
    [self updateCoreHIDFreeMouseTruthPointFromEvent:event];
    [self reconcileHybridFreeMouseAnchorToCurrentPointer];
    if ([self handleEdgeMenuTemporaryReleaseForEvent:event]) {
        return;
    }

    if ([self attemptPendingMouseExitedRecaptureIfNeededForEvent:event]) {
        return;
    }

    if ([self recaptureFreeMouseAfterEdgeUncaptureIfNeededForEvent:event]) {
        return;
    }

    if ([self consumePendingHybridRemoteCursorSyncForEvent:event reason:@"mouse-dragged-hybrid-sync"]) {
        return;
    }

    MLFreeMouseExitEdge exitEdge = [self freeMouseExitEdgeForEvent:event];
    if ([self shouldUncaptureFreeMouseForComputedExitEdge:exitEdge]) {
        [self uncaptureFreeMouseForExitEdge:exitEdge
                                      event:event
                                       code:@"MUC105"
                                     reason:@"free-mouse-edge-mouse-dragged"];
        return;
    }
    [self.hidSupport mouseMoved:event];
}

- (void)rightMouseDragged:(NSEvent *)event {
    [self updateCoreHIDFreeMouseTruthPointFromEvent:event];
    [self reconcileHybridFreeMouseAnchorToCurrentPointer];
    if ([self handleEdgeMenuTemporaryReleaseForEvent:event]) {
        return;
    }

    if ([self attemptPendingMouseExitedRecaptureIfNeededForEvent:event]) {
        return;
    }

    if ([self recaptureFreeMouseAfterEdgeUncaptureIfNeededForEvent:event]) {
        return;
    }

    if ([self consumePendingHybridRemoteCursorSyncForEvent:event reason:@"right-dragged-hybrid-sync"]) {
        return;
    }

    MLFreeMouseExitEdge exitEdge = [self freeMouseExitEdgeForEvent:event];
    if ([self shouldUncaptureFreeMouseForComputedExitEdge:exitEdge]) {
        [self uncaptureFreeMouseForExitEdge:exitEdge
                                      event:event
                                       code:@"MUC106"
                                     reason:@"free-mouse-edge-right-dragged"];
        return;
    }
    [self.hidSupport mouseMoved:event];
}

- (void)otherMouseDragged:(NSEvent *)event {
    [self updateCoreHIDFreeMouseTruthPointFromEvent:event];
    [self reconcileHybridFreeMouseAnchorToCurrentPointer];
    if ([self handleEdgeMenuTemporaryReleaseForEvent:event]) {
        return;
    }

    if ([self attemptPendingMouseExitedRecaptureIfNeededForEvent:event]) {
        return;
    }

    if ([self recaptureFreeMouseAfterEdgeUncaptureIfNeededForEvent:event]) {
        return;
    }

    if ([self consumePendingHybridRemoteCursorSyncForEvent:event reason:@"other-dragged-hybrid-sync"]) {
        return;
    }

    MLFreeMouseExitEdge exitEdge = [self freeMouseExitEdgeForEvent:event];
    if ([self shouldUncaptureFreeMouseForComputedExitEdge:exitEdge]) {
        [self uncaptureFreeMouseForExitEdge:exitEdge
                                      event:event
                                       code:@"MUC107"
                                     reason:@"free-mouse-edge-other-dragged"];
        return;
    }
    [self.hidSupport mouseMoved:event];
}

- (void)scrollWheel:(NSEvent *)event {
    [self attemptPendingMouseExitedRecaptureIfNeededForEvent:event];
    if (!self.isMouseCaptured && self.isRemoteDesktopMode) {
        return;
    }

    if ([self shouldPreferAppKitSystemPointerForBoundaryOrGestureEvent:event]) {
        NSPoint currentPoint = [self currentMouseLocationInViewCoordinates];
        BOOL pointerInside = NSPointInRect(currentPoint, self.view.bounds);
        if (!pointerInside || !self.view.window.isKeyWindow || ![NSApp isActive]) {
            [self uncaptureMouseWithCode:@"MUC108" reason:@"free-mouse-trackpad-scroll-outside"];
            return;
        }
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

- (KeyboardTranslationRule *)keyboardTranslationRuleMatchingEvent:(NSEvent *)event {
    if (event == nil || self.app.host.uuid.length == 0) {
        return nil;
    }

    NSEventModifierFlags relevantModifiers = MLRelevantShortcutModifiers(event.modifierFlags);
    NSArray<KeyboardTranslationRule *> *rules = [SettingsClass keyboardTranslationRulesFor:self.app.host.uuid];
    for (KeyboardTranslationRule *rule in rules) {
        StreamShortcut *trigger = rule.trigger;
        if (trigger == nil || trigger.modifierOnly || !trigger.hasKeyCode) {
            continue;
        }

        if (event.keyCode == trigger.keyCode && relevantModifiers == trigger.modifierFlags) {
            Log(LOG_I, @"[diag] keyboard translation trigger matched: event=%@ outputKind=%ld",
                MLDisconnectEventSummary(event),
                (long)rule.outputKind);
            return rule;
        }
    }

    if (event.keyCode == kVK_ANSI_W) {
        Log(LOG_D, @"[diag] keyboard translation no match for W: event=%@ ruleCount=%lu",
            MLDisconnectEventSummary(event),
            (unsigned long)rules.count);
    }

    return nil;
}

- (BOOL)shouldDeferCommandModifierForShortcutHandlingWithEvent:(NSEvent *)event {
    if (event == nil || self.app.host.uuid.length == 0) {
        return NO;
    }

    BOOL isCommandKeyEvent = (event.keyCode == kVK_Command || event.keyCode == kVK_RightCommand);
    NSEventModifierFlags relevantModifiers = MLRelevantShortcutModifiers(event.modifierFlags);
    if (!isCommandKeyEvent || relevantModifiers != NSEventModifierFlagCommand) {
        return NO;
    }

    NSArray<KeyboardTranslationRule *> *rules = [SettingsClass keyboardTranslationRulesFor:self.app.host.uuid];
    for (KeyboardTranslationRule *rule in rules) {
        StreamShortcut *trigger = rule.trigger;
        if (trigger != nil &&
            !trigger.modifierOnly &&
            trigger.hasKeyCode &&
            (trigger.modifierFlags & NSEventModifierFlagCommand) != 0) {
            return YES;
        }
    }

    NSArray<NSString *> *actions = @[
        MLShortcutActionShowDisconnectOptions,
        MLShortcutActionDisconnectStream,
        MLShortcutActionCloseAndQuitApp,
        MLShortcutActionReconnectStream,
        MLShortcutActionOpenControlCenter,
        MLShortcutActionTogglePerformanceOverlay,
        MLShortcutActionToggleMouseMode,
        MLShortcutActionToggleFullscreenControlBall,
        MLShortcutActionToggleBorderlessWindowed
    ];
    for (NSString *action in actions) {
        StreamShortcut *shortcut = [self streamShortcutForAction:action];
        if (shortcut != nil &&
            !shortcut.modifierOnly &&
            shortcut.hasKeyCode &&
            (shortcut.modifierFlags & NSEventModifierFlagCommand) != 0) {
            return YES;
        }
    }

    return NO;
}

- (void)resolveDeferredCommandModifierWithoutRemoteTapWithReason:(NSString *)reason event:(NSEvent *)event {
    if (!self.deferredCommandModifierPendingForShortcutTranslation) {
        return;
    }

    self.deferredCommandModifierPendingForShortcutTranslation = NO;
    self.deferredCommandModifierForwardedAsHeld = NO;
    self.deferredCommandModifierDispatchToken += 1;
    Log(LOG_D, @"[diag] deferred command consumed without standalone Win tap: reason=%@ event=%@",
        reason ?: @"(nil)",
        MLDisconnectEventSummary(event));
}

- (BOOL)performKeyboardTranslationLocalAction:(NSString *)action {
    if (action.length == 0) {
        return NO;
    }

    BOOL recognizedAction =
        [action isEqualToString:KeyboardTranslationProfile.localActionShowDisconnectOptions] ||
        [action isEqualToString:KeyboardTranslationProfile.localActionDisconnectStream] ||
        [action isEqualToString:KeyboardTranslationProfile.localActionCloseAndQuitApp] ||
        [action isEqualToString:KeyboardTranslationProfile.localActionReconnectStream] ||
        [action isEqualToString:KeyboardTranslationProfile.localActionTogglePerformanceOverlay] ||
        [action isEqualToString:KeyboardTranslationProfile.localActionToggleMouseMode] ||
        [action isEqualToString:KeyboardTranslationProfile.localActionToggleFullscreenControlBall] ||
        [action isEqualToString:KeyboardTranslationProfile.localActionOpenControlCenter] ||
        [action isEqualToString:KeyboardTranslationProfile.localActionReleaseMouseCapture] ||
        [action isEqualToString:KeyboardTranslationProfile.localActionToggleBorderlessWindowed];
    if (!recognizedAction) {
        return NO;
    }

    __weak typeof(self) weakSelf = self;
    void (^performAction)(void) = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }

        if ([action isEqualToString:KeyboardTranslationProfile.localActionDisconnectStream]) {
            strongSelf.pendingOptionUncaptureToken += 1;
            [strongSelf requestStreamCloseWithSource:@"keyboard-translation-disconnect"];
            return;
        }

        if ([action isEqualToString:KeyboardTranslationProfile.localActionShowDisconnectOptions]) {
            strongSelf.pendingOptionUncaptureToken += 1;
            [strongSelf performClose:nil];
            return;
        }

        if ([action isEqualToString:KeyboardTranslationProfile.localActionCloseAndQuitApp]) {
            strongSelf.pendingOptionUncaptureToken += 1;
            [strongSelf performCloseAndQuitApp:nil];
            return;
        }

        if ([action isEqualToString:KeyboardTranslationProfile.localActionReconnectStream]) {
            [strongSelf reconnectFromMenu:nil];
            return;
        }

        if ([action isEqualToString:KeyboardTranslationProfile.localActionTogglePerformanceOverlay]) {
            strongSelf.pendingOptionUncaptureToken += 1;
            [strongSelf toggleOverlay];
            return;
        }

        if ([action isEqualToString:KeyboardTranslationProfile.localActionToggleMouseMode]) {
            strongSelf.pendingOptionUncaptureToken += 1;
            [strongSelf toggleMouseMode];
            return;
        }

        if ([action isEqualToString:KeyboardTranslationProfile.localActionToggleFullscreenControlBall]) {
            strongSelf.pendingOptionUncaptureToken += 1;
            [strongSelf toggleFullscreenControlBallVisibility];
            return;
        }

        if ([action isEqualToString:KeyboardTranslationProfile.localActionOpenControlCenter]) {
            [strongSelf presentControlCenterFromShortcut];
            return;
        }

        if ([action isEqualToString:KeyboardTranslationProfile.localActionReleaseMouseCapture]) {
            strongSelf.pendingOptionUncaptureToken += 1;
            strongSelf.lastOptionUncaptureAtMs = [strongSelf nowMs];
            [strongSelf suppressConnectionWarningsForSeconds:2.0 reason:@"keyboard-translation-release"];
            [strongSelf uncaptureMouseWithCode:@"MUC104" reason:@"keyboard-translation-release-shortcut"];
            return;
        }

        if ([action isEqualToString:KeyboardTranslationProfile.localActionToggleBorderlessWindowed]) {
            strongSelf.pendingOptionUncaptureToken += 1;
            if ([strongSelf isWindowBorderlessMode]) {
                [strongSelf switchToWindowedMode:nil];
            } else {
                [strongSelf switchToBorderlessMode:nil];
            }
        }
    };

    dispatch_async(dispatch_get_main_queue(), performAction);
    return YES;
}

- (BOOL)handleKeyboardTranslationRuleForEvent:(NSEvent *)event {
    KeyboardTranslationRule *rule = [self keyboardTranslationRuleMatchingEvent:event];
    if (rule == nil) {
        return NO;
    }

    [self resolveDeferredCommandModifierWithoutRemoteTapWithReason:@"keyboard-translation" event:event];
    [self.hidSupport releaseAllModifierKeys];

    if (rule.outputKind == KeyboardTranslationOutputKindRemoteShortcut) {
        if (rule.outputShortcut != nil) {
            Log(LOG_I, @"[diag] keyboard translation dispatching remote shortcut: event=%@ remoteKey=%ld remoteMods=0x%llx",
                MLDisconnectEventSummary(event),
                (long)rule.outputShortcut.keyCode,
                (unsigned long long)rule.outputShortcut.modifierFlagsRaw);
            [self.hidSupport sendSyntheticRemoteShortcut:rule.outputShortcut];
            return YES;
        }
        return NO;
    }

    return [self performKeyboardTranslationLocalAction:rule.localAction];
}


#pragma mark - KeyboardNotifiable

- (BOOL)onKeyboardEquivalent:(NSEvent *)event {
    StreamShortcut *disconnectOptionsShortcut = [self streamShortcutForAction:MLShortcutActionShowDisconnectOptions];
    const NSEventModifierFlags eventModifierFlags = MLRelevantShortcutModifiers(event.modifierFlags);
    StreamShortcut *disconnectShortcut = [self streamShortcutForAction:MLShortcutActionDisconnectStream];
    StreamShortcut *quitShortcut = [self streamShortcutForAction:MLShortcutActionCloseAndQuitApp];
    StreamShortcut *reconnectShortcut = [self streamShortcutForAction:MLShortcutActionReconnectStream];

    [self resolveDeferredCommandModifierWithoutRemoteTapWithReason:@"keyboard-equivalent" event:event];

    if ([self handleKeyboardTranslationRuleForEvent:event]) {
        return YES;
    }
    
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
        || (event.keyCode == kVK_ANSI_F && eventModifierFlags == NSEventModifierFlagFunction)) {
        [self.hidSupport releaseAllModifierKeys];
        return NO;
    }

    if ([self event:event matchesShortcut:disconnectOptionsShortcut]) {
        [self resolveDeferredCommandModifierWithoutRemoteTapWithReason:@"disconnect-options-shortcut" event:event];
        self.pendingOptionUncaptureToken += 1;
        [self.hidSupport releaseAllModifierKeys];
        [self performClose:nil];
        return YES;
    }

    if ([self event:event matchesShortcut:disconnectShortcut]) {
        [self resolveDeferredCommandModifierWithoutRemoteTapWithReason:@"disconnect-shortcut" event:event];
        self.pendingOptionUncaptureToken += 1;
        [self.hidSupport releaseAllModifierKeys];
        [self requestStreamCloseWithSource:@"keyboard-custom-disconnect"];
        return YES;
    }

    if ([self event:event matchesShortcut:quitShortcut]) {
        [self resolveDeferredCommandModifierWithoutRemoteTapWithReason:@"quit-shortcut" event:event];
        self.pendingOptionUncaptureToken += 1;
        [self.hidSupport releaseAllModifierKeys];
        [self performCloseAndQuitApp:nil];
        return YES;
    }

    if ([self event:event matchesShortcut:reconnectShortcut]) {
        [self resolveDeferredCommandModifierWithoutRemoteTapWithReason:@"reconnect-shortcut" event:event];
        [self.hidSupport releaseAllModifierKeys];
        [self reconnectFromMenu:nil];
        return YES;
    }

    if (event.keyCode == kVK_ANSI_W && eventModifierFlags == NSEventModifierFlagCommand) {
        [self resolveDeferredCommandModifierWithoutRemoteTapWithReason:@"cmd-w-swallow" event:event];
        Log(LOG_D, @"[diag] cmd+w swallowed after custom handlers: %@", MLDisconnectEventSummary(event));
        [self.hidSupport releaseAllModifierKeys];
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
    
    [self resolveDeferredCommandModifierWithoutRemoteTapWithReason:@"keyboard-equivalent-pass-through" event:event];
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
    self.hasCoreHIDFreeMouseLastTruthPoint = NO;
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
    self.pendingMouseUncaptureRecheckScheduled = NO;
    self.hasCoreHIDFreeMouseLastTruthPoint = NO;

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
