//
//  StreamViewController+MenuUI.m
//  Moonlight for macOS
//

#import "StreamViewController_Internal.h"

@implementation StreamViewController (MenuUI)

- (NSString *)mouseModeDisplayNameForMode:(NSString *)mode {
    return [mode isEqualToString:@"remote"] ? MLString(@"Free Mouse", nil) : MLString(@"Locked Mouse", nil);
}

- (NSString *)mouseModeHintForMode:(NSString *)mode {
    return [mode isEqualToString:@"remote"] ? MLString(@"Free Mouse hint", nil) : MLString(@"Locked Mouse hint", nil);
}

- (NSString *)shortcutDisplayStringForAction:(NSString *)action {
    StreamShortcut *shortcut = [self streamShortcutForAction:action];
    NSArray<NSString *> *tokens = [StreamShortcutProfile displayTokensFor:shortcut];
    return tokens.count > 0 ? [tokens componentsJoinedByString:@""] : @"";
}

- (NSString *)releaseMouseHintText {
    NSString *shortcut = [self shortcutDisplayStringForAction:MLShortcutActionReleaseMouseCapture];
    if (shortcut.length == 0) {
        return @"";
    }
    return [NSString stringWithFormat:MLString(@"Release mouse: %@", nil), shortcut];
}

- (NSString *)openControlCenterHintText {
    NSString *shortcut = [self shortcutDisplayStringForAction:MLShortcutActionOpenControlCenter];
    if (shortcut.length == 0) {
        return MLString(@"Control Center", nil);
    }
    return [NSString stringWithFormat:MLString(@"Open Control Center: %@", nil), shortcut];
}

- (void)updateControlCenterEntrypointHints {
    NSString *openHint = [self openControlCenterHintText];
    NSString *releaseHint = (!self.isRemoteDesktopMode && self.isMouseCaptured) ? [self releaseMouseHintText] : @"";
    NSString *tooltip = releaseHint.length > 0
        ? [@[openHint, releaseHint] componentsJoinedByString:@"\n"]
        : openHint;

    self.menuTitlebarButton.toolTip = tooltip;
    self.edgeMenuButton.toolTip = tooltip;
    self.edgeMenuPanel.contentView.toolTip = tooltip;
}

- (NSView *)preferredControlCenterSourceView {
    if (([self isWindowFullscreen] || [self isWindowBorderlessMode]) &&
        self.edgeMenuPanel.isVisible &&
        self.edgeMenuButton &&
        !self.edgeMenuButton.hidden) {
        return self.edgeMenuButton;
    }
    if (self.menuTitlebarButton && self.menuTitlebarAccessory.view && !self.menuTitlebarAccessory.view.hidden) {
        return self.menuTitlebarButton;
    }
    return self.view;
}

- (void)presentControlCenterFromShortcut {
    if (self.isMouseCaptured) {
        self.pendingOptionUncaptureToken += 1;
        self.lastOptionUncaptureAtMs = [self nowMs];
        [self.hidSupport releaseAllModifierKeys];
        [self suppressConnectionWarningsForSeconds:2.0 reason:@"shortcut-uncapture"];
        [self uncaptureMouseWithCode:@"MUC201" reason:@"control-center-shortcut"];
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [self presentStreamMenuFromView:[self preferredControlCenterSourceView]];
    });
}

- (StreamShortcut *)streamShortcutForAction:(NSString *)action {
    NSDictionary *shortcuts = [SettingsClass streamShortcutsFor:self.app.host.uuid];
    StreamShortcut *shortcut = shortcuts[action];
    return shortcut ?: [StreamShortcutProfile defaultShortcutFor:action];
}

- (BOOL)event:(NSEvent *)event matchesShortcut:(StreamShortcut *)shortcut {
    if (!shortcut || shortcut.modifierOnly || shortcut.keyCode == StreamShortcut.noKeyCode) {
        return NO;
    }

    return event.keyCode == shortcut.keyCode
        && MLRelevantShortcutModifiers(event.modifierFlags) == shortcut.modifierFlags;
}

- (void)applyShortcut:(StreamShortcut *)shortcut toMenuItem:(NSMenuItem *)item {
    if (!item) {
        return;
    }

    item.keyEquivalent = [StreamShortcutProfile menuKeyEquivalentFor:shortcut];
    item.keyEquivalentModifierMask = [StreamShortcutProfile menuModifierMaskFor:shortcut];
}

- (void)updateConfiguredShortcutMenus {
    if (self.streamMenu) {
        [self rebuildStreamMenu];
    }

    [self updateControlCenterEntrypointHints];
}

- (BOOL)windowSupportsTitlebarAccessoryControllers:(NSWindow *)window {
    // Some NSWindow subclasses (and older macOS) don't implement the setter even if the getter exists.
    // Never require setTitlebarAccessoryViewControllers:, because we can operate without it.
    return window != nil
        && [window respondsToSelector:@selector(titlebarAccessoryViewControllers)];
}

- (BOOL)windowAllowsTitlebarAccessories:(NSWindow *)window {
    if (!window) {
        return NO;
    }
    if ((window.styleMask & NSWindowStyleMaskTitled) == 0) {
        return NO;
    }
    if ((window.styleMask & NSWindowStyleMaskBorderless) != 0) {
        return NO;
    }
    if (![window respondsToSelector:@selector(addTitlebarAccessoryViewController:)]) {
        return NO;
    }
    return YES;
}

- (BOOL)isMenuTitlebarAccessoryInstalledInWindow:(NSWindow *)window {
    if (!window || !self.menuTitlebarAccessory) {
        return NO;
    }

    if ([self windowSupportsTitlebarAccessoryControllers:window]) {
        @try {
            return [window.titlebarAccessoryViewControllers containsObject:self.menuTitlebarAccessory];
        } @catch (NSException *exception) {
            // If AppKit asserts for this style/transition, fall back to our local flag.
        }
    }

    return self.menuTitlebarAccessoryInstalled;
}

- (void)buildMenuTitlebarAccessoryIfNeeded {
    if (self.menuTitlebarAccessory != nil) {
        return;
    }

    const CGFloat containerWidth = 240.0;
    const CGFloat containerHeight = 28.0;

    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, containerWidth, containerHeight)];
    container.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    container.autoresizesSubviews = YES;

    NSVisualEffectView *pill = [[NSVisualEffectView alloc] initWithFrame:container.bounds];
    pill.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    pill.material = NSVisualEffectMaterialHUDWindow;
    pill.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    pill.state = NSVisualEffectStateActive;
    pill.wantsLayer = YES;
    pill.layer.cornerRadius = containerHeight * 0.5;
    pill.layer.masksToBounds = YES;
    [container addSubview:pill];

    NSView *content = [[NSView alloc] initWithFrame:pill.bounds];
    content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [pill addSubview:content];

    NSImageView *signalImageView = [[NSImageView alloc] initWithFrame:NSMakeRect(10.0, 6.0, 16.0, 16.0)];
    signalImageView.imageScaling = NSImageScaleProportionallyUpOrDown;
    signalImageView.contentTintColor = [NSColor whiteColor];
    [content addSubview:signalImageView];

    NSTextField *timeLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(32.0, 6.0, 70.0, 16.0)];
    timeLabel.bezeled = NO;
    timeLabel.drawsBackground = NO;
    timeLabel.editable = NO;
    timeLabel.selectable = NO;
    timeLabel.alignment = NSTextAlignmentLeft;
    timeLabel.font = [NSFont monospacedDigitSystemFontOfSize:13.0 weight:NSFontWeightRegular];
    timeLabel.textColor = [NSColor whiteColor];
    timeLabel.stringValue = @"00:00";
    [content addSubview:timeLabel];

    NSTextField *titleLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(containerWidth - 88.0, 6.0, 78.0, 16.0)];
    titleLabel.bezeled = NO;
    titleLabel.drawsBackground = NO;
    titleLabel.editable = NO;
    titleLabel.selectable = NO;
    titleLabel.alignment = NSTextAlignmentRight;
    titleLabel.font = [NSFont systemFontOfSize:13.0 weight:NSFontWeightSemibold];
    titleLabel.textColor = [NSColor whiteColor];
    titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    titleLabel.stringValue = [self currentStreamHealthBadgeText];
    [content addSubview:titleLabel];

    NSButton *button = [NSButton buttonWithTitle:@"" target:self action:@selector(handleTitlebarControlCenterPressed:)];
    button.frame = container.bounds;
    button.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    button.bordered = NO;
    button.imagePosition = NSNoImage;
    button.title = @"";
    button.focusRingType = NSFocusRingTypeNone;
    if ([button respondsToSelector:@selector(setRefusesFirstResponder:)]) {
        button.refusesFirstResponder = YES;
    }

    [container addSubview:button];

    NSTitlebarAccessoryViewController *accessory = [[NSTitlebarAccessoryViewController alloc] init];
    accessory.layoutAttribute = NSLayoutAttributeRight;
    accessory.view = container;

    self.menuTitlebarAccessory = accessory;
    self.menuTitlebarButton = button;
    self.controlCenterPill = pill;
    self.controlCenterSignalImageView = signalImageView;
    self.controlCenterTimeLabel = timeLabel;
    self.controlCenterTitleLabel = titleLabel;
}

- (void)removeMenuTitlebarAccessoryFromWindowIfNeeded {
    if (!self.menuTitlebarAccessory) {
        return;
    }

    NSWindow *window = self.view.window;
    if (window &&
        [self isMenuTitlebarAccessoryInstalledInWindow:window] &&
        [window respondsToSelector:@selector(setTitlebarAccessoryViewControllers:)]) {
        @try {
            NSMutableArray *controllers = [[window titlebarAccessoryViewControllers] mutableCopy];
            [controllers removeObject:self.menuTitlebarAccessory];
            [window setValue:[controllers copy] forKey:@"titlebarAccessoryViewControllers"];
        } @catch (NSException *exception) {
        }
    }

    self.menuTitlebarAccessory.view.hidden = YES;
    self.menuTitlebarAccessoryInstalled = window ? [self isMenuTitlebarAccessoryInstalledInWindow:window] : NO;
}

- (void)ensureMenuTitlebarAccessoryInstalledIfNeeded {
    if (!MLUseOnScreenControlCenterEntrypoints) {
        return;
    }

    NSWindow *window = self.view.window;
    if (![self windowAllowsTitlebarAccessories:window] ||
        [self isWindowFullscreen] ||
        [self isWindowBorderlessMode] ||
        ![self isWindowInCurrentSpace]) {
        [self removeMenuTitlebarAccessoryFromWindowIfNeeded];
        return;
    }

    [self buildMenuTitlebarAccessoryIfNeeded];

    if (![self isMenuTitlebarAccessoryInstalledInWindow:window]) {
        @try {
            [window addTitlebarAccessoryViewController:self.menuTitlebarAccessory];
            self.menuTitlebarAccessoryInstalled = YES;
        } @catch (NSException *exception) {
            self.menuTitlebarAccessoryInstalled = NO;
            return;
        }
    }

    self.menuTitlebarAccessory.view.hidden = NO;
    [self updateControlCenterStatus];
    [self updateControlCenterEntrypointHints];
}

- (void)handleTitlebarControlCenterPressed:(id)sender {
    if (self.menuTitlebarButton) {
        [self presentStreamMenuFromView:self.menuTitlebarButton event:nil];
    } else {
        [self presentStreamMenuFromView:self.view event:nil];
    }
}

- (NSString *)fullscreenControlBallDefaultsKey {
    NSString *uuid = self.app.host.uuid ?: @"global";
    return [NSString stringWithFormat:@"%@-hideFullscreenControlBall", uuid];
}

- (NSString *)fullscreenControlBallDockSideDefaultsKey {
    NSString *uuid = self.app.host.uuid ?: @"global";
    return [NSString stringWithFormat:@"%@-fullscreenControlBallDockSide", uuid];
}

- (NSString *)fullscreenControlBallVerticalRatioDefaultsKey {
    NSString *uuid = self.app.host.uuid ?: @"global";
    return [NSString stringWithFormat:@"%@-fullscreenControlBallVerticalRatio", uuid];
}

- (MLFreeMouseExitEdge)defaultEdgeMenuDockEdge {
    return MLFreeMouseExitEdgeRight;
}

- (MLFreeMouseExitEdge)edgeMenuDockEdgeFromStoredValue:(NSString *)value {
    if ([value isEqualToString:@"left"]) {
        return MLFreeMouseExitEdgeLeft;
    }
    if ([value isEqualToString:@"top"]) {
        return MLFreeMouseExitEdgeTop;
    }
    if ([value isEqualToString:@"bottom"]) {
        return MLFreeMouseExitEdgeBottom;
    }
    if ([value isEqualToString:@"right"]) {
        return MLFreeMouseExitEdgeRight;
    }
    return [self defaultEdgeMenuDockEdge];
}

- (NSString *)storedValueForEdgeMenuDockEdge:(MLFreeMouseExitEdge)edge {
    switch (edge) {
        case MLFreeMouseExitEdgeLeft:
            return @"left";
        case MLFreeMouseExitEdgeTop:
            return @"top";
        case MLFreeMouseExitEdgeBottom:
            return @"bottom";
        case MLFreeMouseExitEdgeRight:
            return @"right";
        case MLFreeMouseExitEdgeNone:
        default:
            return @"right";
    }
}

- (BOOL)edgeMenuDockEdgeUsesVerticalAxis {
    return self.edgeMenuDockEdge == MLFreeMouseExitEdgeLeft || self.edgeMenuDockEdge == MLFreeMouseExitEdgeRight;
}

- (CGFloat)resolvedEdgeMenuCoordinateInRect:(NSRect)rect {
    CGFloat inset = MLEdgeMenuButtonInsetY;
    if ([self edgeMenuDockEdgeUsesVerticalAxis]) {
        CGFloat minValue = NSMinY(rect) + inset;
        CGFloat maxValue = MAX(minValue, NSMaxY(rect) - MLEdgeMenuButtonHeight - inset);
        CGFloat available = MAX(maxValue - minValue, 0.0);
        return minValue + available * MIN(MAX(self.edgeMenuButtonEdgeRatio, 0.0), 1.0);
    }

    CGFloat minValue = NSMinX(rect) + inset;
    CGFloat maxValue = MAX(minValue, NSMaxX(rect) - MLEdgeMenuButtonWidth - inset);
    CGFloat available = MAX(maxValue - minValue, 0.0);
    return minValue + available * MIN(MAX(self.edgeMenuButtonEdgeRatio, 0.0), 1.0);
}

- (NSRect)edgeMenuFrameInRect:(NSRect)rect expanded:(BOOL)expanded {
    CGFloat coordinate = [self resolvedEdgeMenuCoordinateInRect:rect];
    switch (self.edgeMenuDockEdge) {
        case MLFreeMouseExitEdgeLeft:
            return NSMakeRect(expanded ? NSMinX(rect) : NSMinX(rect) - MLEdgeMenuButtonWidth + MLEdgeMenuButtonVisiblePeek,
                              coordinate,
                              MLEdgeMenuButtonWidth,
                              MLEdgeMenuButtonHeight);
        case MLFreeMouseExitEdgeTop:
            return NSMakeRect(coordinate,
                              expanded ? NSMaxY(rect) - MLEdgeMenuButtonHeight : NSMaxY(rect) - MLEdgeMenuButtonVisiblePeek,
                              MLEdgeMenuButtonWidth,
                              MLEdgeMenuButtonHeight);
        case MLFreeMouseExitEdgeBottom:
            return NSMakeRect(coordinate,
                              expanded ? NSMinY(rect) : NSMinY(rect) - MLEdgeMenuButtonHeight + MLEdgeMenuButtonVisiblePeek,
                              MLEdgeMenuButtonWidth,
                              MLEdgeMenuButtonHeight);
        case MLFreeMouseExitEdgeRight:
        case MLFreeMouseExitEdgeNone:
        default:
            return NSMakeRect(expanded ? NSMaxX(rect) - MLEdgeMenuButtonWidth : NSMaxX(rect) - MLEdgeMenuButtonVisiblePeek,
                              coordinate,
                              MLEdgeMenuButtonWidth,
                              MLEdgeMenuButtonHeight);
    }
}

- (void)persistFullscreenControlBallPlacement {
    // Intentionally keep placement session-scoped only.
}

- (void)resetEdgeMenuPlacementForNewStreamSession {
    self.edgeMenuDockEdge = [self defaultEdgeMenuDockEdge];
    self.edgeMenuButtonEdgeRatio = 0.5;
    self.globalInactivePointerInsideStreamView = NO;
    self.edgeMenuButtonExpanded = NO;
    self.edgeMenuPointerInside = NO;
    self.edgeMenuTemporaryReleaseActive = NO;
    self.edgeMenuDragging = NO;
    self.edgeMenuMenuVisible = NO;
    [self cancelEdgeMenuAutoCollapse];
    self.edgeMenuButton.hidden = YES;
    if (self.edgeMenuPanel.parentWindow) {
        [self.edgeMenuPanel.parentWindow removeChildWindow:self.edgeMenuPanel];
    }
    [self.edgeMenuPanel orderOut:nil];
    [self updateEdgeMenuButtonAppearance];
    [self refreshMouseMovedAcceptanceState];
}

- (void)hideEdgeMenuForInactiveSpaceIfNeeded {
    if (!self.edgeMenuPanel) {
        return;
    }

    self.globalInactivePointerInsideStreamView = NO;
    self.edgeMenuPointerInside = NO;
    self.edgeMenuTemporaryReleaseActive = NO;
    self.edgeMenuDragging = NO;
    self.edgeMenuMenuVisible = NO;
    self.edgeMenuButtonExpanded = NO;
    [self cancelEdgeMenuAutoCollapse];
    self.edgeMenuButton.hidden = YES;
    if (self.edgeMenuPanel.parentWindow) {
        [self.edgeMenuPanel.parentWindow removeChildWindow:self.edgeMenuPanel];
    }
    [self.edgeMenuPanel orderOut:nil];
    [self updateEdgeMenuButtonAppearance];
    [self refreshMouseMovedAcceptanceState];
}

- (void)attachEdgeMenuPanelToWindowIfNeeded {
    if (!MLUseFloatingControlOrb || !self.edgeMenuPanel || !self.view.window) {
        return;
    }
    if (![self isWindowInCurrentSpace]) {
        return;
    }

    self.edgeMenuPanel.collectionBehavior = NSWindowCollectionBehaviorFullScreenAuxiliary;

    if (self.edgeMenuPanel.parentWindow == self.view.window) {
        return;
    }

    if (self.edgeMenuPanel.parentWindow) {
        [self.edgeMenuPanel.parentWindow removeChildWindow:self.edgeMenuPanel];
    }

    [self.view.window addChildWindow:self.edgeMenuPanel ordered:NSWindowAbove];
}

- (NSRect)edgeMenuAnchorRectInScreen {
    if (!self.view.window) {
        return NSZeroRect;
    }

    if ([self isWindowFullscreen] || [self isWindowBorderlessMode]) {
        return self.view.window.frame;
    }

    NSRect rectInWindow = [self.view convertRect:self.view.bounds toView:nil];
    return [self.view.window convertRectToScreen:rectInWindow];
}

- (NSRect)collapsedFrameForEdgeMenuPanelInScreenRect:(NSRect)screenRect {
    return [self edgeMenuFrameInRect:screenRect expanded:NO];
}

- (NSRect)expandedFrameForEdgeMenuPanelInScreenRect:(NSRect)screenRect {
    return [self edgeMenuFrameInRect:screenRect expanded:YES];
}

- (NSRect)frameForCurrentEdgeMenuPanelStateInScreenRect:(NSRect)screenRect {
    return self.edgeMenuButtonExpanded
        ? [self expandedFrameForEdgeMenuPanelInScreenRect:screenRect]
        : [self collapsedFrameForEdgeMenuPanelInScreenRect:screenRect];
}

- (BOOL)edgeMenuMatchesExitEdge:(MLFreeMouseExitEdge)exitEdge {
    return exitEdge != MLFreeMouseExitEdgeNone && exitEdge == self.edgeMenuDockEdge;
}

- (NSRect)collapsedFrameForEdgeMenuButtonInBounds:(NSRect)bounds {
    return [self edgeMenuFrameInRect:bounds expanded:NO];
}

- (NSRect)expandedFrameForEdgeMenuButtonInBounds:(NSRect)bounds {
    return [self edgeMenuFrameInRect:bounds expanded:YES];
}

- (NSRect)edgeMenuInteractionRectInBounds:(NSRect)bounds {
    NSRect frame = [self expandedFrameForEdgeMenuButtonInBounds:bounds];
    switch (self.edgeMenuDockEdge) {
        case MLFreeMouseExitEdgeLeft:
            frame.origin.y -= MLEdgeMenuInteractionVerticalPadding;
            frame.size.height += MLEdgeMenuInteractionVerticalPadding * 2.0;
            frame.origin.x -= MLEdgeMenuInteractionOutwardPadding;
            frame.size.width += MLEdgeMenuInteractionOutwardPadding + MLEdgeMenuInteractionInwardPadding;
            break;
        case MLFreeMouseExitEdgeRight:
            frame.origin.y -= MLEdgeMenuInteractionVerticalPadding;
            frame.size.height += MLEdgeMenuInteractionVerticalPadding * 2.0;
            frame.origin.x -= MLEdgeMenuInteractionInwardPadding;
            frame.size.width += MLEdgeMenuInteractionOutwardPadding + MLEdgeMenuInteractionInwardPadding;
            break;
        case MLFreeMouseExitEdgeTop:
            frame.origin.x -= MLEdgeMenuInteractionVerticalPadding;
            frame.size.width += MLEdgeMenuInteractionVerticalPadding * 2.0;
            frame.origin.y -= MLEdgeMenuInteractionInwardPadding;
            frame.size.height += MLEdgeMenuInteractionOutwardPadding + MLEdgeMenuInteractionInwardPadding;
            break;
        case MLFreeMouseExitEdgeBottom:
            frame.origin.x -= MLEdgeMenuInteractionVerticalPadding;
            frame.size.width += MLEdgeMenuInteractionVerticalPadding * 2.0;
            frame.origin.y -= MLEdgeMenuInteractionOutwardPadding;
            frame.size.height += MLEdgeMenuInteractionOutwardPadding + MLEdgeMenuInteractionInwardPadding;
            break;
        case MLFreeMouseExitEdgeNone:
        default:
            break;
    }
    return frame;
}

- (BOOL)isPointInsideEdgeMenuInteractionRect:(NSPoint)point {
    if (!self.edgeMenuButton || self.edgeMenuButton.hidden) {
        return NO;
    }

    return NSPointInRect(point, [self edgeMenuInteractionRectInBounds:self.view.bounds]);
}

- (void)updateEdgeMenuPointerInsideForPoint:(NSPoint)point {
    self.edgeMenuPointerInside = [self isPointInsideEdgeMenuInteractionRect:point];
}

- (NSRect)frameForEdgeMenuButtonInBounds:(NSRect)bounds {
    return self.edgeMenuButtonExpanded
        ? [self expandedFrameForEdgeMenuButtonInBounds:bounds]
        : [self collapsedFrameForEdgeMenuButtonInBounds:bounds];
}

- (void)cancelEdgeMenuAutoCollapse {
    [self.edgeMenuAutoCollapseTimer invalidate];
    self.edgeMenuAutoCollapseTimer = nil;
}

- (BOOL)edgeMenuShouldBeVisible {
    if (![self isWindowFullscreen] && ![self isWindowBorderlessMode]) {
        return NO;
    }
    if ([self isWindowFullscreen] && self.hideFullscreenControlBall) {
        return NO;
    }
    return YES;
}

- (void)updateEdgeMenuButtonTrackingArea {
    if (!self.edgeMenuButton) {
        return;
    }
    [self.edgeMenuButton updateTrackingAreas];
}

- (void)setEdgeMenuButtonExpanded:(BOOL)expanded animated:(BOOL)animated {
    if (!self.edgeMenuButton || !self.edgeMenuPanel) {
        return;
    }

    self.edgeMenuButtonExpanded = expanded;
    [self cancelEdgeMenuAutoCollapse];

    if (![self edgeMenuShouldBeVisible]) {
        self.edgeMenuButton.hidden = YES;
        return;
    }

    self.edgeMenuButton.hidden = NO;
    [self attachEdgeMenuPanelToWindowIfNeeded];
    NSRect anchorRect = [self edgeMenuAnchorRectInScreen];
    if (NSIsEmptyRect(anchorRect)) {
        return;
    }

    NSRect targetFrame = [self frameForCurrentEdgeMenuPanelStateInScreenRect:anchorRect];
    [self updateEdgeMenuButtonAppearance];

    if (!self.edgeMenuPanel.isVisible) {
        [self.edgeMenuPanel setFrame:targetFrame display:NO];
        self.edgeMenuPanel.alphaValue = 1.0;
        [self.edgeMenuPanel orderFront:nil];
        return;
    }

    if (animated) {
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = 0.22;
            context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
            [[self.edgeMenuPanel animator] setFrame:targetFrame display:YES];
        } completionHandler:^{
            if (self.edgeMenuPanel) {
                [self.edgeMenuPanel setFrame:targetFrame display:YES];
            }
        }];
    } else {
        [self.edgeMenuPanel setFrame:targetFrame display:YES];
    }
}

- (void)deactivateEdgeMenuTemporaryReleaseAndRecaptureIfNeeded:(BOOL)shouldRecapture {
    BOOL wasTemporary = self.edgeMenuTemporaryReleaseActive;
    self.edgeMenuTemporaryReleaseActive = NO;
    self.edgeMenuPointerInside = NO;
    self.edgeMenuMenuVisible = NO;

    [self setEdgeMenuButtonExpanded:NO animated:YES];

    if (wasTemporary && shouldRecapture && [self canCaptureMouseNow]) {
        if ([self.hidSupport shouldUseCoreHIDFreeMouseAbsoluteSyncForCurrentConfiguration] &&
            self.isRemoteDesktopMode &&
            self.view.window != nil) {
            NSPoint currentPoint = [self currentMouseLocationInViewCoordinates];
            NSPoint reseedPoint = NSMakePoint(
                MIN(MAX(currentPoint.x, NSMinX(self.view.bounds)), NSMaxX(self.view.bounds)),
                MIN(MAX(currentPoint.y, NSMinY(self.view.bounds)), NSMaxY(self.view.bounds))
            );
            [self prepareCoreHIDVirtualCursorForSystemPointerSyncIfNeeded];
            [self syncRemoteCursorToViewPoint:reseedPoint clampToBounds:YES];
        }
        [self captureMouse];
    } else {
        [self refreshMouseMovedAcceptanceState];
    }
}

- (void)scheduleEdgeMenuAutoCollapse {
    [self cancelEdgeMenuAutoCollapse];

    __weak typeof(self) weakSelf = self;
    self.edgeMenuAutoCollapseTimer = [NSTimer scheduledTimerWithTimeInterval:MLEdgeMenuAutoCollapseDelay
                                                                     repeats:NO
                                                                       block:^(__unused NSTimer *timer) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.edgeMenuPointerInside || strongSelf.edgeMenuDragging || strongSelf.edgeMenuMenuVisible) {
            return;
        }

        [strongSelf deactivateEdgeMenuTemporaryReleaseAndRecaptureIfNeeded:strongSelf.edgeMenuTemporaryReleaseActive];
    }];
}

- (void)activateEdgeMenuDockForExitEdge:(MLFreeMouseExitEdge)exitEdge {
    if (![self edgeMenuMatchesExitEdge:exitEdge] || ![self edgeMenuShouldBeVisible]) {
        return;
    }

    self.pendingFreeMouseReentryEdge = MLFreeMouseExitEdgeNone;
    self.pendingFreeMouseReentryAtMs = 0;
    self.edgeMenuTemporaryReleaseActive = YES;
    [self setEdgeMenuButtonExpanded:YES animated:YES];
    [self refreshMouseMovedAcceptanceState];
    [self updateEdgeMenuPointerInsideForPoint:[self currentMouseLocationInViewCoordinates]];
    [self updateControlCenterEntrypointHints];
}

- (BOOL)handleEdgeMenuTemporaryReleaseForEvent:(NSEvent *)event {
    if (!self.edgeMenuTemporaryReleaseActive || self.edgeMenuDragging || self.edgeMenuMenuVisible) {
        return NO;
    }

    [self updateEdgeMenuPointerInsideForPoint:[self viewPointForMouseEvent:event]];
    if (self.edgeMenuPointerInside) {
        return NO;
    }

    [self deactivateEdgeMenuTemporaryReleaseAndRecaptureIfNeeded:YES];
    return YES;
}

- (void)updateEdgeMenuButtonAppearance {
    if (!self.edgeMenuButton) {
        return;
    }

    BOOL active = self.edgeMenuButtonExpanded || self.edgeMenuPointerInside || self.edgeMenuTemporaryReleaseActive || self.edgeMenuDragging || self.edgeMenuMenuVisible;
    self.edgeMenuButton.activeAppearance = active;
    self.edgeMenuButton.compactAppearance = !self.edgeMenuButtonExpanded && !self.edgeMenuTemporaryReleaseActive && !self.edgeMenuDragging && !self.edgeMenuMenuVisible;
    self.edgeMenuButton.dockEdge = self.edgeMenuDockEdge;
}

- (void)handleEdgeMenuButtonDragWithState:(NSGestureRecognizerState)state translation:(NSPoint)translation {
    if (!self.edgeMenuButton || self.edgeMenuButton.hidden || !self.edgeMenuPanel) {
        return;
    }

    switch (state) {
        case NSGestureRecognizerStateBegan:
            self.edgeMenuDragging = YES;
            self.edgeMenuPointerInside = YES;
            [self cancelEdgeMenuAutoCollapse];
            [self setEdgeMenuButtonExpanded:YES animated:NO];
            self.edgeMenuButtonPanStartOrigin = self.edgeMenuPanel.frame.origin;
            self.edgeMenuButtonSuppressNextClick = NO;
            [self refreshMouseMovedAcceptanceState];
            [self updateEdgeMenuButtonAppearance];
            break;
        case NSGestureRecognizerStateChanged: {
            if (fabs(translation.x) > 3.0 || fabs(translation.y) > 3.0) {
                self.edgeMenuButtonSuppressNextClick = YES;
            }

            NSRect anchorRect = [self edgeMenuAnchorRectInScreen];
            if (NSIsEmptyRect(anchorRect)) {
                break;
            }

            NSRect frame = self.edgeMenuPanel.frame;
            frame.origin.x = self.edgeMenuButtonPanStartOrigin.x + translation.x;
            frame.origin.y = self.edgeMenuButtonPanStartOrigin.y + translation.y;

            CGFloat minX = NSMinX(anchorRect);
            CGFloat maxX = NSMaxX(anchorRect) - MLEdgeMenuButtonWidth;
            CGFloat minY = NSMinY(anchorRect);
            CGFloat maxY = NSMaxY(anchorRect) - MLEdgeMenuButtonHeight;
            frame.origin.x = MIN(MAX(frame.origin.x, minX), maxX);
            frame.origin.y = MIN(MAX(frame.origin.y, minY), maxY);
            [self.edgeMenuPanel setFrame:frame display:YES];
            break;
        }
        case NSGestureRecognizerStateEnded:
        case NSGestureRecognizerStateCancelled: {
            self.edgeMenuDragging = NO;
            NSRect anchorRect = [self edgeMenuAnchorRectInScreen];
            if (NSIsEmptyRect(anchorRect)) {
                self.edgeMenuDragging = NO;
                break;
            }

            NSRect frame = self.edgeMenuPanel.frame;
            CGFloat centerX = NSMidX(frame);
            CGFloat centerY = NSMidY(frame);
            CGFloat leftDistance = fabs(centerX - NSMinX(anchorRect));
            CGFloat rightDistance = fabs(NSMaxX(anchorRect) - centerX);
            CGFloat topDistance = fabs(NSMaxY(anchorRect) - centerY);
            CGFloat bottomDistance = fabs(centerY - NSMinY(anchorRect));

            self.edgeMenuDockEdge = MLFreeMouseExitEdgeLeft;
            CGFloat bestDistance = leftDistance;
            if (rightDistance < bestDistance) {
                bestDistance = rightDistance;
                self.edgeMenuDockEdge = MLFreeMouseExitEdgeRight;
            }
            if (topDistance < bestDistance) {
                bestDistance = topDistance;
                self.edgeMenuDockEdge = MLFreeMouseExitEdgeTop;
            }
            if (bottomDistance < bestDistance) {
                self.edgeMenuDockEdge = MLFreeMouseExitEdgeBottom;
            }

            if ([self edgeMenuDockEdgeUsesVerticalAxis]) {
                CGFloat minY = NSMinY(anchorRect) + MLEdgeMenuButtonInsetY;
                CGFloat maxY = MAX(minY, NSMaxY(anchorRect) - MLEdgeMenuButtonHeight - MLEdgeMenuButtonInsetY);
                CGFloat availableHeight = MAX(maxY - minY, 1.0);
                self.edgeMenuButtonEdgeRatio = MIN(MAX((frame.origin.y - minY) / availableHeight, 0.0), 1.0);
            } else {
                CGFloat minX = NSMinX(anchorRect) + MLEdgeMenuButtonInsetY;
                CGFloat maxX = MAX(minX, NSMaxX(anchorRect) - MLEdgeMenuButtonWidth - MLEdgeMenuButtonInsetY);
                CGFloat availableWidth = MAX(maxX - minX, 1.0);
                self.edgeMenuButtonEdgeRatio = MIN(MAX((frame.origin.x - minX) / availableWidth, 0.0), 1.0);
            }
            [self persistFullscreenControlBallPlacement];

            [self updateEdgeMenuPointerInsideForPoint:[self currentMouseLocationInViewCoordinates]];
            [self setEdgeMenuButtonExpanded:self.edgeMenuPointerInside animated:YES];
            [self updateEdgeMenuButtonTrackingArea];
            [self refreshMouseMovedAcceptanceState];
            [self updateEdgeMenuButtonAppearance];
            break;
        }
        default:
            break;
    }
}

- (void)startControlCenterTimerIfNeeded {
    if (!MLUseOnScreenControlCenterEntrypoints) {
        return;
    }
    if (self.controlCenterTimer) {
        return;
    }
    self.controlCenterTimer = [NSTimer timerWithTimeInterval:MLControlCenterRefreshIntervalSec
                                                      target:self
                                                    selector:@selector(updateControlCenterStatus)
                                                    userInfo:nil
                                                     repeats:YES];
    self.controlCenterTimer.tolerance = 0.1;
    [[NSRunLoop mainRunLoop] addTimer:self.controlCenterTimer forMode:NSRunLoopCommonModes];
    [self updateControlCenterStatus];
}

- (void)bringStreamControlsToFront {
    if (![self isWindowInCurrentSpace]) {
        return;
    }
    if (self.edgeMenuPanel && self.edgeMenuPanel.isVisible) {
        [self.edgeMenuPanel orderFront:nil];
    }
    if (self.edgeMenuButton) {
        [self.edgeMenuButton.superview addSubview:self.edgeMenuButton positioned:NSWindowAbove relativeTo:nil];
    }
    if (self.overlayContainer) {
        [self.view addSubview:self.overlayContainer positioned:NSWindowAbove relativeTo:nil];
    }
    if (self.logOverlayContainer) {
        [self.view addSubview:self.logOverlayContainer positioned:NSWindowAbove relativeTo:nil];
    }
    if (self.reconnectOverlayContainer) {
        [self.view addSubview:self.reconnectOverlayContainer positioned:NSWindowAbove relativeTo:nil];
    }
}

- (NSString *)formatElapsed:(NSTimeInterval)seconds {
    NSInteger total = MAX(0, (NSInteger)llround(seconds));
    NSInteger h = total / 3600;
    NSInteger m = (total % 3600) / 60;
    NSInteger s = total % 60;
    if (h > 0) {
        return [NSString stringWithFormat:@"%02ld:%02ld:%02ld", (long)h, (long)m, (long)s];
    }
    return [NSString stringWithFormat:@"%02ld:%02ld", (long)m, (long)s];
}

- (NSString *)currentPreferredAddressForStatus {
    NSDictionary *prefs = [SettingsClass getSettingsFor:self.app.host.uuid];
    NSString *method = prefs[@"connectionMethod"];
    if (method && ![method isEqualToString:@"Auto"]) {
        return method;
    }
    if (self.app.host.activeAddress.length > 0) {
        return self.app.host.activeAddress;
    }

    NSArray<NSString *> *candidates = @[ self.app.host.localAddress ?: @"",
                                         self.app.host.address ?: @"",
                                         self.app.host.externalAddress ?: @"",
                                         self.app.host.ipv6Address ?: @"" ];
    NSString *bestAddr = nil;
    NSInteger bestLatency = NSIntegerMax;

    for (NSString *addr in candidates) {
        if (addr.length == 0) continue;
        NSNumber *state = self.app.host.addressStates[addr];
        BOOL online = state ? (state.intValue == 1) : YES;
        if (!online) continue;

        NSNumber *latency = self.app.host.addressLatencies[addr];
        if (latency != nil && latency.intValue >= 0) {
            if (latency.intValue < bestLatency) {
                bestLatency = latency.intValue;
                bestAddr = addr;
            }
        } else if (bestAddr == nil) {
            bestAddr = addr;
        }
    }

    return bestAddr;
}

- (BOOL)isActiveStreamGeneration:(NSUInteger)generation {
    return generation != 0 && generation == self.activeStreamGeneration;
}

- (NSString *)formattedLatencyTextForDisplay:(NSNumber *)latencyNumber {
    if (latencyNumber == nil || latencyNumber.integerValue < 0) {
        return nil;
    }

    NSInteger latencyMs = MAX(1, latencyNumber.integerValue);
    return [NSString stringWithFormat:@"%ldms", (long)latencyMs];
}

- (NSString *)currentLatencyLogSummary {
    PML_CONTROL_STREAM_CONTEXT controlCtx = self.streamMan.connection ? (PML_CONTROL_STREAM_CONTEXT)[self.streamMan.connection controlStreamContext] : NULL;
    NSString *controlSummary = MLRttLogSummary(controlCtx);
    if (![controlSummary isEqualToString:@"n/a"]) {
        return controlSummary;
    }

    NSString *addr = [self currentPreferredAddressForStatus];
    NSNumber *latency = addr ? self.app.host.addressLatencies[addr] : nil;
    if (latency != nil && latency.integerValue >= 0) {
        NSInteger pathProbeMs = MAX(1, latency.integerValue);
        NSString *pathText = [NSString stringWithFormat:@"%ld", (long)pathProbeMs];
        return [NSString stringWithFormat:@"probe~%@", pathText];
    }

    return @"n/a";
}

- (NSInteger)currentLatencyMs {
    // If we are actively streaming, use the real-time RTT.
    if ([self hasReceivedAnyVideoFrames]) {
        uint32_t rtt = 0;
        uint32_t rttVar = 0;
        PML_CONTROL_STREAM_CONTEXT controlCtx = self.streamMan.connection ? (PML_CONTROL_STREAM_CONTEXT)[self.streamMan.connection controlStreamContext] : NULL;
        if (MLGetUsableRttInfo(controlCtx, &rtt, &rttVar)) {
            return (NSInteger)MAX((uint32_t)1, rtt);
        }
    }

    NSString *addr = [self currentPreferredAddressForStatus];
    NSNumber *latency = addr ? self.app.host.addressLatencies[addr] : nil;
    if (!latency) {
        return -1;
    }
    return MAX(1, latency.integerValue);
}

- (NSString *)currentStreamHealthBadgeText {
    if (self.streamHealthNoPayloadStreak > 0) {
        return [NSString stringWithFormat:@"卡住%lus", (unsigned long)self.streamHealthNoPayloadStreak];
    }
    if (self.streamHealthHighDropStreak >= 2) {
        return @"高丢包";
    }
    return MLString(@"Control Center", nil);
}

- (void)updateControlCenterStatus {
    if (!MLUseOnScreenControlCenterEntrypoints) {
        return;
    }
    if (!self.controlCenterTimeLabel || !self.controlCenterSignalImageView) {
        return;
    }

    NSTimeInterval elapsed = self.streamStartDate ? [[NSDate date] timeIntervalSinceDate:self.streamStartDate] : 0;
    self.controlCenterTimeLabel.stringValue = [self formatElapsed:elapsed];

    NSInteger latency = [self currentLatencyMs];
    NSString *symbol = @"wifi";
    if (self.streamHealthNoPayloadStreak >= 2 || self.streamHealthFrozenStatsStreak >= 2) {
        symbol = @"wifi.exclamationmark";
    } else if (latency < 0) {
        symbol = @"wifi.slash";
    } else if (latency <= 30) {
        symbol = @"cellularbars";
    } else if (latency <= 60) {
        symbol = @"cellularbars.3";
    } else if (latency <= 100) {
        symbol = @"cellularbars.2";
    } else {
        symbol = @"cellularbars.1";
    }

    if (@available(macOS 11.0, *)) {
        NSImage *img = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil];
        if (!img) {
            img = [NSImage imageWithSystemSymbolName:@"wifi" accessibilityDescription:nil];
        }
        self.controlCenterSignalImageView.image = img;
    }

    if (self.controlCenterTitleLabel) {
        self.controlCenterTitleLabel.stringValue = [self currentStreamHealthBadgeText];
    }
}

- (void)installStreamMenuEntrypoints {
    if (!MLUseFloatingControlOrb) {
        return;
    }

    if (self.edgeMenuPanel && self.edgeMenuButton) {
        [self attachEdgeMenuPanelToWindowIfNeeded];
        [self requestStreamMenuEntrypointsVisibilityUpdate];
        return;
    }

    self.edgeMenuPanel = [[MLEdgeMenuPanel alloc] initWithContentRect:NSMakeRect(0, 0, MLEdgeMenuButtonWidth, MLEdgeMenuButtonHeight)
                                                            styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                                              backing:NSBackingStoreBuffered
                                                                defer:NO];
    self.edgeMenuPanel.opaque = NO;
    self.edgeMenuPanel.backgroundColor = NSColor.clearColor;
    self.edgeMenuPanel.hasShadow = NO;
    self.edgeMenuPanel.hidesOnDeactivate = NO;
    self.edgeMenuPanel.level = NSStatusWindowLevel;
    self.edgeMenuPanel.releasedWhenClosed = NO;
    self.edgeMenuPanel.acceptsMouseMovedEvents = YES;
    self.edgeMenuPanel.ignoresMouseEvents = NO;

    NSView *panelContentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, MLEdgeMenuButtonWidth, MLEdgeMenuButtonHeight)];
    panelContentView.wantsLayer = YES;
    panelContentView.layer.backgroundColor = NSColor.clearColor.CGColor;
    self.edgeMenuPanel.contentView = panelContentView;

    NSImage *edgeMenuImage = [NSImage imageWithSystemSymbolName:@"slider.horizontal.3" accessibilityDescription:nil];
    if (@available(macOS 11.0, *)) {
        NSImageSymbolConfiguration *config = [NSImageSymbolConfiguration configurationWithPointSize:18
                                                                                             weight:NSFontWeightSemibold
                                                                                              scale:NSImageSymbolScaleLarge];
        edgeMenuImage = [edgeMenuImage imageWithSymbolConfiguration:config];
    }

    self.edgeMenuButton = [[MLEdgeMenuHandleView alloc] initWithFrame:panelContentView.bounds];
    self.edgeMenuButton.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.edgeMenuButton.iconView.image = edgeMenuImage;
    self.edgeMenuButton.hidden = YES;
    __weak typeof(self) weakSelf = self;
    self.edgeMenuButton.activationHandler = ^(NSEvent *event) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        [strongSelf handleStreamMenuButtonPressed:strongSelf.edgeMenuButton event:event];
    };
    self.edgeMenuButton.dragHandler = ^(NSGestureRecognizerState state, NSPoint translation) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        [strongSelf handleEdgeMenuButtonDragWithState:state translation:translation];
    };
    self.edgeMenuButton.hoverHandler = ^(BOOL hovering) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        if (strongSelf.edgeMenuDragging) {
            strongSelf.edgeMenuPointerInside = YES;
            [strongSelf updateEdgeMenuButtonAppearance];
            return;
        }
        strongSelf.edgeMenuPointerInside = hovering;
        if (hovering) {
            [strongSelf cancelEdgeMenuAutoCollapse];
            if (strongSelf.isRemoteDesktopMode && strongSelf.isMouseCaptured) {
                strongSelf.edgeMenuTemporaryReleaseActive = YES;
                [strongSelf uncaptureMouseWithCode:@"MUC202" reason:@"edge-menu-hover-temporary-release"];
            }
            [strongSelf setEdgeMenuButtonExpanded:YES animated:!(strongSelf.isRemoteDesktopMode && strongSelf.isMouseCaptured)];
        } else if (!strongSelf.edgeMenuDragging && !strongSelf.edgeMenuMenuVisible) {
            [strongSelf scheduleEdgeMenuAutoCollapse];
        }
        [strongSelf refreshMouseMovedAcceptanceState];
        [strongSelf updateEdgeMenuButtonAppearance];
    };
    [panelContentView addSubview:self.edgeMenuButton];

    [self attachEdgeMenuPanelToWindowIfNeeded];
    [self updateEdgeMenuButtonAppearance];
    [self updateControlCenterEntrypointHints];
    [self requestStreamMenuEntrypointsVisibilityUpdate];
}

- (void)layoutStreamMenuEntrypointsIfNeeded {
    if (!MLUseFloatingControlOrb) {
        return;
    }
    if (![self isWindowInCurrentSpace]) {
        [self hideEdgeMenuForInactiveSpaceIfNeeded];
        return;
    }
    if (!self.edgeMenuButton || self.edgeMenuButton.hidden || !self.edgeMenuPanel) {
        return;
    }
    if (self.edgeMenuDragging) {
        [self.edgeMenuPanel orderFront:nil];
        return;
    }

    NSRect anchorRect = [self edgeMenuAnchorRectInScreen];
    if (NSIsEmptyRect(anchorRect)) {
        return;
    }

    [self attachEdgeMenuPanelToWindowIfNeeded];
    [self.edgeMenuPanel setFrame:[self frameForCurrentEdgeMenuPanelStateInScreenRect:anchorRect] display:YES];
    [self.edgeMenuPanel orderFront:nil];
    [self updateEdgeMenuButtonTrackingArea];
}

- (void)requestStreamMenuEntrypointsVisibilityUpdate {
    if (!MLUseFloatingControlOrb) {
        return;
    }
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self requestStreamMenuEntrypointsVisibilityUpdate];
        });
        return;
    }

    if (self.streamMenuEntrypointsUpdateScheduled) {
        return;
    }

    self.streamMenuEntrypointsUpdateScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.streamMenuEntrypointsUpdateScheduled = NO;
        [self updateStreamMenuEntrypointsVisibility];
    });
}

- (void)scheduleDeferredStreamMenuEntrypointsVisibilityRetries {
    if (!MLUseFloatingControlOrb) {
        return;
    }

    __weak typeof(self) weakSelf = self;
    static const NSTimeInterval retryDelays[] = { 0.10, 0.28, 0.55 };
    for (NSUInteger i = 0; i < sizeof(retryDelays) / sizeof(retryDelays[0]); i++) {
        NSTimeInterval delay = retryDelays[i];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || !strongSelf.view.window || strongSelf.stopStreamInProgress || strongSelf.reconnectInProgress) {
                return;
            }

            [strongSelf requestStreamMenuEntrypointsVisibilityUpdate];
            if ([strongSelf isWindowInCurrentSpace]) {
                [strongSelf bringStreamControlsToFront];
            }
        });
    }
}

- (void)updateStreamMenuEntrypointsVisibility {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateStreamMenuEntrypointsVisibility];
        });
        return;
    }
    if (!self.view.window) {
        return;
    }
    if (![self isWindowInCurrentSpace]) {
        [self removeMenuTitlebarAccessoryFromWindowIfNeeded];
        [self hideEdgeMenuForInactiveSpaceIfNeeded];
        return;
    }
    if (self.fullscreenTransitionInProgress) {
        [self removeMenuTitlebarAccessoryFromWindowIfNeeded];
        self.edgeMenuButton.hidden = YES;
        [self.edgeMenuPanel orderOut:nil];
        return;
    }
    if (self.edgeMenuDragging) {
        [self ensureMenuTitlebarAccessoryInstalledIfNeeded];
        if (MLUseFloatingControlOrb) {
            [self.edgeMenuPanel orderFront:nil];
        }
        return;
    }

    [self ensureMenuTitlebarAccessoryInstalledIfNeeded];

    if (!MLUseFloatingControlOrb) {
        return;
    }

    [self attachEdgeMenuPanelToWindowIfNeeded];
    if ([self edgeMenuShouldBeVisible]) {
        self.edgeMenuButton.hidden = NO;
        [self layoutStreamMenuEntrypointsIfNeeded];
        [self updateEdgeMenuButtonAppearance];
        [self bringStreamControlsToFront];
    } else {
        self.edgeMenuButton.hidden = YES;
        self.edgeMenuButtonExpanded = NO;
        self.edgeMenuTemporaryReleaseActive = NO;
        [self cancelEdgeMenuAutoCollapse];
        [self.edgeMenuPanel orderOut:nil];
    }

    [self updateControlCenterEntrypointHints];
}

- (void)handleStreamMenuButtonPressed:(id)sender event:(NSEvent *)event {
    NSView *sourceView = nil;
    if ([sender isKindOfClass:[NSView class]]) {
        sourceView = (NSView *)sender;
    } else {
        sourceView = self.view;
    }

    [self presentStreamMenuFromView:sourceView event:event];
}

- (void)presentStreamMenuFromView:(NSView *)sourceView {
    [self presentStreamMenuFromView:sourceView event:nil];
}

- (void)presentStreamMenuFromView:(NSView *)sourceView event:(NSEvent *)event {
    [self rebuildStreamMenu];
    NSMenu *menu = self.streamMenu;

    NSRect bounds = sourceView.bounds;
    NSPoint p = NSMakePoint(NSMidX(bounds), NSMinY(bounds));
    if (sourceView == self.edgeMenuButton) {
        switch (self.edgeMenuDockEdge) {
            case MLFreeMouseExitEdgeLeft:
                p = NSMakePoint(NSMaxX(bounds), NSMidY(bounds));
                break;
            case MLFreeMouseExitEdgeTop:
                p = NSMakePoint(NSMidX(bounds), NSMinY(bounds));
                break;
            case MLFreeMouseExitEdgeBottom:
                p = NSMakePoint(NSMidX(bounds), NSMaxY(bounds));
                break;
            case MLFreeMouseExitEdgeRight:
            case MLFreeMouseExitEdgeNone:
            default:
                p = NSMakePoint(NSMinX(bounds), NSMidY(bounds));
                break;
        }
    }

    self.edgeMenuMenuVisible = YES;
    [self refreshMouseMovedAcceptanceState];
    if (sourceView == self.edgeMenuButton && event != nil) {
        [NSMenu popUpContextMenu:menu withEvent:event forView:sourceView];
    } else {
        [menu popUpMenuPositioningItem:nil atLocation:p inView:sourceView];
    }
    self.edgeMenuMenuVisible = NO;
    [self refreshMouseMovedAcceptanceState];

    if (self.edgeMenuTemporaryReleaseActive && !self.edgeMenuPointerInside && !self.edgeMenuDragging) {
        [self deactivateEdgeMenuTemporaryReleaseAndRecaptureIfNeeded:YES];
    } else if (!self.edgeMenuPointerInside && !self.edgeMenuDragging) {
        [self scheduleEdgeMenuAutoCollapse];
    }
}

- (void)presentStreamMenuAtEvent:(NSEvent *)event {
    [self rebuildStreamMenu];
    NSPoint p = [self.view convertPoint:event.locationInWindow fromView:nil];
    [self.streamMenu popUpMenuPositioningItem:nil atLocation:p inView:self.view];
}

- (void)rebuildStreamMenu {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self rebuildStreamMenu];
        });
        return;
    }
    if (!self.streamMenu) {
        self.streamMenu = [[NSMenu alloc] initWithTitle:@"StreamMenu"];
    }
    [self.streamMenu removeAllItems];

    void (^setSymbol)(NSMenuItem *, NSString *) = ^(NSMenuItem *item, NSString *symbolName) {
        if (@available(macOS 11.0, *)) {
            item.image = [NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:nil];
        }
    };

    // 一级顶部：鼠标模式
    NSDictionary *prefs = [SettingsClass getSettingsFor:self.app.host.uuid];
    NSString *mouseMode = [SettingsClass mouseModeFor:self.app.host.uuid];
    BOOL isRemoteMode = [mouseMode isEqualToString:@"remote"];

    NSMenuItem *mouseModeItem = [[NSMenuItem alloc] initWithTitle:MLString(@"Mouse and Cursor", nil)
                                                           action:nil
                                                    keyEquivalent:@""];
    setSymbol(mouseModeItem, @"cursorarrow.motionlines");
    NSMenu *mouseModeMenu = [[NSMenu alloc] initWithTitle:MLString(@"Mouse and Cursor", nil)];

    NSMenuItem *currentModeItem = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:MLString(@"Current: %@", nil), [self mouseModeDisplayNameForMode:mouseMode]]
                                                             action:nil
                                                      keyEquivalent:@""];
    currentModeItem.enabled = NO;
    [mouseModeMenu addItem:currentModeItem];

    NSMenuItem *currentHintItem = [[NSMenuItem alloc] initWithTitle:[self mouseModeHintForMode:mouseMode]
                                                             action:nil
                                                      keyEquivalent:@""];
    currentHintItem.enabled = NO;
    [mouseModeMenu addItem:currentHintItem];

    [mouseModeMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *lockedMouseItem = [[NSMenuItem alloc] initWithTitle:MLString(@"Locked Mouse", nil)
                                                             action:@selector(selectLockedMouseModeFromMenu:)
                                                      keyEquivalent:@""];
    lockedMouseItem.target = self;
    lockedMouseItem.state = isRemoteMode ? NSControlStateValueOff : NSControlStateValueOn;
    setSymbol(lockedMouseItem, @"gamecontroller");
    [mouseModeMenu addItem:lockedMouseItem];

    NSMenuItem *freeMouseItem = [[NSMenuItem alloc] initWithTitle:MLString(@"Free Mouse", nil)
                                                           action:@selector(selectFreeMouseModeFromMenu:)
                                                    keyEquivalent:@""];
    freeMouseItem.target = self;
    freeMouseItem.state = isRemoteMode ? NSControlStateValueOn : NSControlStateValueOff;
    setSymbol(freeMouseItem, @"desktopcomputer");
    [mouseModeMenu addItem:freeMouseItem];

    NSString *releaseHint = [self releaseMouseHintText];
    NSString *controlCenterHint = [self openControlCenterHintText];
    if (releaseHint.length > 0 || controlCenterHint.length > 0) {
        [mouseModeMenu addItem:[NSMenuItem separatorItem]];
    }

    if (releaseHint.length > 0) {
        NSMenuItem *releaseHintItem = [[NSMenuItem alloc] initWithTitle:releaseHint action:nil keyEquivalent:@""];
        releaseHintItem.enabled = NO;
        [mouseModeMenu addItem:releaseHintItem];
    }

    if (controlCenterHint.length > 0) {
        NSMenuItem *controlCenterHintItem = [[NSMenuItem alloc] initWithTitle:controlCenterHint action:nil keyEquivalent:@""];
        controlCenterHintItem.enabled = NO;
        [mouseModeMenu addItem:controlCenterHintItem];
    }

    mouseModeItem.submenu = mouseModeMenu;
    [self.streamMenu addItem:mouseModeItem];

    // 一级顶部：重连
    NSMenuItem *reconnectItem = [[NSMenuItem alloc] initWithTitle:@"重连" action:@selector(reconnectFromMenu:) keyEquivalent:@""];
    [self applyShortcut:[self streamShortcutForAction:MLShortcutActionReconnectStream] toMenuItem:reconnectItem];
    reconnectItem.target = self;
    setSymbol(reconnectItem, @"arrow.triangle.2.circlepath");
    [self.streamMenu addItem:reconnectItem];

    [self.streamMenu addItem:[NSMenuItem separatorItem]];

    // NSDictionary *prefs = [SettingsClass getSettingsFor:self.app.host.uuid]; // Already defined above

    // 二级：窗口
    NSMenuItem *windowItem = [[NSMenuItem alloc] initWithTitle:@"窗口" action:nil keyEquivalent:@""];
    setSymbol(windowItem, @"macwindow");
    NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:@"窗口"]; 

    BOOL isFullscreen = [self isWindowFullscreen];
    BOOL isBorderless = ((self.view.window.styleMask & NSWindowStyleMaskTitled) == 0) && !isFullscreen;
    BOOL isWindowed = !isFullscreen && !isBorderless;

    NSMenuItem *windowedItem = [[NSMenuItem alloc] initWithTitle:@"窗口模式" action:@selector(switchToWindowedMode:) keyEquivalent:@""];
    windowedItem.target = self;
    windowedItem.state = isWindowed ? NSControlStateValueOn : NSControlStateValueOff;
    setSymbol(windowedItem, @"macwindow");
    [windowMenu addItem:windowedItem];

    NSMenuItem *fullscreenItem = [[NSMenuItem alloc] initWithTitle:@"全屏模式" action:@selector(switchToFullscreenMode:) keyEquivalent:@"f"];
    fullscreenItem.keyEquivalentModifierMask = NSEventModifierFlagControl | NSEventModifierFlagCommand;
    fullscreenItem.target = self;
    fullscreenItem.state = isFullscreen ? NSControlStateValueOn : NSControlStateValueOff;
    setSymbol(fullscreenItem, @"arrow.up.left.and.arrow.down.right");
    [windowMenu addItem:fullscreenItem];

    NSMenuItem *borderlessItem = [[NSMenuItem alloc] initWithTitle:@"无边框窗口" action:@selector(switchToBorderlessMode:) keyEquivalent:@""];
    borderlessItem.target = self;
    borderlessItem.state = isBorderless ? NSControlStateValueOn : NSControlStateValueOff;
    setSymbol(borderlessItem, @"rectangle.dashed");
    [windowMenu addItem:borderlessItem];

    [windowMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *toggleBallItem = [[NSMenuItem alloc] initWithTitle:@"全屏显示悬浮球" action:@selector(toggleFullscreenControlBallFromMenu:) keyEquivalent:@""];
    [self applyShortcut:[self streamShortcutForAction:MLShortcutActionToggleFullscreenControlBall] toMenuItem:toggleBallItem];
    toggleBallItem.target = self;
    toggleBallItem.state = self.hideFullscreenControlBall ? NSControlStateValueOff : NSControlStateValueOn;
    setSymbol(toggleBallItem, @"dot.circle.and.hand.point.up.left.fill");
    [windowMenu addItem:toggleBallItem];

    [windowMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *detailsItem = [[NSMenuItem alloc] initWithTitle:@"连接详情" action:@selector(toggleOverlay) keyEquivalent:@""];
    [self applyShortcut:[self streamShortcutForAction:MLShortcutActionTogglePerformanceOverlay] toMenuItem:detailsItem];
    detailsItem.target = self;
    detailsItem.state = self.overlayContainer ? NSControlStateValueOn : NSControlStateValueOff;
    setSymbol(detailsItem, @"gauge.with.dots.needle.33percent");
    [windowMenu addItem:detailsItem];

    windowItem.submenu = windowMenu;
    [self.streamMenu addItem:windowItem];

    // 二级：屏幕（分辨率/帧率）
    NSMenuItem *monitorItem = [[NSMenuItem alloc] initWithTitle:@"屏幕" action:nil keyEquivalent:@""];
    setSymbol(monitorItem, @"display");
    NSMenu *monitorMenu = [[NSMenu alloc] initWithTitle:@"屏幕"];

    // 1. Follow Monitor
    CGSize refreshLocalSize = CGSizeZero;
    if ([self.view.window screen]) {
        NSRect screenFrame = [self.view.window screen].frame;
        CGFloat scale = [self.view.window screen].backingScaleFactor;
        refreshLocalSize = CGSizeMake(screenFrame.size.width * scale, screenFrame.size.height * scale);
    }
    
    NSString *matchDisplayTitle = @"跟随显示器";
    if (refreshLocalSize.width > 0 && refreshLocalSize.height > 0) {
        matchDisplayTitle = [NSString stringWithFormat:@"跟随显示器 (%.0fx%.0f)", refreshLocalSize.width, refreshLocalSize.height];
    }

    NSMenuItem *matchDisplayItem = [[NSMenuItem alloc] initWithTitle:matchDisplayTitle action:@selector(selectMatchDisplayFromMenu:) keyEquivalent:@""];
    matchDisplayItem.target = self;
    
    NSDictionary *currentPrefs = [SettingsClass getSettingsFor:self.app.host.uuid];
    BOOL isMatchDisplay = currentPrefs ? [currentPrefs[@"matchDisplayResolution"] boolValue] : NO;
    matchDisplayItem.state = isMatchDisplay ? NSControlStateValueOn : NSControlStateValueOff;

    setSymbol(matchDisplayItem, @"macwindow.badge.plus");
    [monitorMenu addItem:matchDisplayItem];

    struct Resolution currentRes = [self.class getResolution];
    
    int currentFps = 0;
    if (prefs) {
        int rawFps = [prefs[@"fps"] intValue];
        if (rawFps == 0) {
            currentFps = [prefs[@"customFps"] intValue];
        } else {
            currentFps = rawFps;
        }
    }
    if (currentFps == 0) {
        TemporarySettings *tempSettings = [[DataManager alloc] getSettings];
        currentFps = [tempSettings.framerate intValue];
    }

    // Check if effective config is 0x0 (which we interpret as Host Native)
    BOOL isMatchHost = (!isMatchDisplay && currentRes.width == 0 && currentRes.height == 0);

    [monitorMenu addItem:[NSMenuItem separatorItem]];
    
    // 3. Custom
    NSMenuItem *customItem = [[NSMenuItem alloc] initWithTitle:@"自定义..." action:@selector(selectCustomResolutionFromMenu:) keyEquivalent:@""];
    customItem.target = self;
    setSymbol(customItem, @"slider.horizontal.below.rectangle");
    [monitorMenu addItem:customItem];

    [monitorMenu addItem:[NSMenuItem separatorItem]];

    // 4. Resolutions Submenu
    // Determine if we should show "Current Resolution" or if it is covered by standard list / custom.
    BOOL currentIsStandard = NO;

    NSArray<NSValue *> *resolutions = @[
        [NSValue valueWithSize:NSMakeSize(3840, 2160)],
        [NSValue valueWithSize:NSMakeSize(2560, 1440)],
        [NSValue valueWithSize:NSMakeSize(1920, 1080)],
        [NSValue valueWithSize:NSMakeSize(1280, 720)]
    ];

    for (NSValue *val in resolutions) {
        NSSize size = val.sizeValue;
        if ((int)size.width == currentRes.width && (int)size.height == currentRes.height) {
            currentIsStandard = YES;
        }
        
        NSString *title = [NSString stringWithFormat:@"%.0f x %.0f", size.width, size.height];
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:@selector(selectResolutionFromMenu:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = val;
        
        BOOL selected = (!isMatchDisplay && !isMatchHost && currentRes.width == (int)size.width && currentRes.height == (int)size.height);
        item.state = selected ? NSControlStateValueOn : NSControlStateValueOff;
        
        [monitorMenu addItem:item];
    }
    
    // If current is NOT Follow Monitor, NOT Follow Host, and NOT Standard, we display it as "Effective Custom"
    if (!isMatchDisplay && !isMatchHost && !currentIsStandard) {
        NSString *customTitle = [NSString stringWithFormat:@"当前 (自定义): %dx%d", currentRes.width, currentRes.height];
        NSMenuItem *currentItem = [[NSMenuItem alloc] initWithTitle:customTitle action:nil keyEquivalent:@""];
        currentItem.state = NSControlStateValueOn;
        [monitorMenu addItem:currentItem];
    }

    [monitorMenu addItem:[NSMenuItem separatorItem]];

    // 5. Frame Rate Submenu
    NSMenuItem *fpsSubItem = [[NSMenuItem alloc] initWithTitle:@"帧率" action:nil keyEquivalent:@""];
    NSMenu *fpsSubMenu = [[NSMenu alloc] initWithTitle:@"帧率"];
    
    NSArray<NSNumber *> *fpsOptions = @[ @30, @60, @90, @120, @144 ];
    BOOL currentFpsIsStandard = NO;
    for (NSNumber *fps in fpsOptions) {
        if (currentFps == fps.intValue) currentFpsIsStandard = YES;
        
        NSString *title = [NSString stringWithFormat:@"%@ FPS", fps];
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:@selector(selectFrameRateFromMenu:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = fps;
        
        BOOL selected = (currentFps == fps.intValue);
        item.state = selected ? NSControlStateValueOn : NSControlStateValueOff;
        
        [fpsSubMenu addItem:item];
    }
    
    // If FPS is weird (custom), show it
    if (!currentFpsIsStandard) {
         NSString *title = [NSString stringWithFormat:@"当前: %d FPS", currentFps];
         NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
         item.state = NSControlStateValueOn;
         [fpsSubMenu addItem:item];
    }

    [fpsSubMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *customFpsItem = [[NSMenuItem alloc] initWithTitle:@"自定义..." action:@selector(selectCustomFpsFromMenu:) keyEquivalent:@""];
    customFpsItem.target = self;
    [fpsSubMenu addItem:customFpsItem];
    
    fpsSubItem.submenu = fpsSubMenu;
    [monitorMenu addItem:fpsSubItem];

    monitorItem.submenu = monitorMenu;
    [self.streamMenu addItem:monitorItem];

    // 二级：画质（码率）
    NSMenuItem *qualityItem = [[NSMenuItem alloc] initWithTitle:@"画质" action:nil keyEquivalent:@""];
    setSymbol(qualityItem, @"sparkles");
    NSMenu *qualityMenu = [[NSMenu alloc] initWithTitle:@"画质"];

    NSMenuItem *bitrateHeader = [[NSMenuItem alloc] initWithTitle:@"码率" action:nil keyEquivalent:@""];
    bitrateHeader.enabled = NO;
    [qualityMenu addItem:bitrateHeader];

    BOOL autoAdjust = prefs ? [prefs[@"autoAdjustBitrate"] boolValue] : YES;
    NSNumber *customBitrate = prefs[@"customBitrate"]; // Kbps
    NSNumber *fallbackBitrate = prefs[@"bitrate"]; // Kbps
    NSInteger selectedKbps = customBitrate ? customBitrate.integerValue : (fallbackBitrate ? fallbackBitrate.integerValue : 0);

    NSMenuItem *autoBitrateItem = [[NSMenuItem alloc] initWithTitle:@"自动" action:@selector(selectBitrateFromMenu:) keyEquivalent:@""];
    autoBitrateItem.target = self;
    autoBitrateItem.representedObject = @"auto";
    autoBitrateItem.state = autoAdjust ? NSControlStateValueOn : NSControlStateValueOff;
    setSymbol(autoBitrateItem, @"wand.and.stars");
    [qualityMenu addItem:autoBitrateItem];

    NSArray<NSNumber *> *bitrateMbpsChoices = @[ @5, @10, @20, @40, @80, @120, @200 ];
    BOOL isPresetSelected = NO;
    for (NSNumber *mbps in bitrateMbpsChoices) {
        NSInteger kbps = mbps.integerValue * 1000;
        NSString *title = [NSString stringWithFormat:@"%@ Mbps", mbps];
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:@selector(selectBitrateFromMenu:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = @(kbps);
        BOOL selected = (!autoAdjust && selectedKbps == kbps);
        if (selected) isPresetSelected = YES;
        item.state = selected ? NSControlStateValueOn : NSControlStateValueOff;
        setSymbol(item, @"speedometer");
        [qualityMenu addItem:item];
    }

    [qualityMenu addItem:[NSMenuItem separatorItem]];

    // 自定义选项（三级菜单，悬停展开滑块和输入框）
    BOOL isCustomMode = !autoAdjust && !isPresetSelected && selectedKbps > 0;

    NSMenuItem *customBitrateItem = [[NSMenuItem alloc] initWithTitle:@"自定义" action:nil keyEquivalent:@""];
    customBitrateItem.state = isCustomMode ? NSControlStateValueOn : NSControlStateValueOff;
    setSymbol(customBitrateItem, @"slider.horizontal.3");

    // 三级菜单：自定义码率
    NSMenu *customMenu = [[NSMenu alloc] initWithTitle:@"自定义"];

    // 滑块视图
    NSView *bitrateView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 280, 70)];

    // 标题行
    NSTextField *bitrateLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(16, 46, 60, 16)];
    bitrateLabel.bezeled = NO;
    bitrateLabel.drawsBackground = NO;
    bitrateLabel.editable = NO;
    bitrateLabel.selectable = NO;
    bitrateLabel.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    bitrateLabel.textColor = [NSColor labelColor];
    bitrateLabel.stringValue = @"码率";
    [bitrateView addSubview:bitrateLabel];

    // 当前码率值显示（右侧）
    self.menuBitrateValueLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(200, 46, 64, 16)];
    self.menuBitrateValueLabel.bezeled = NO;
    self.menuBitrateValueLabel.drawsBackground = NO;
    self.menuBitrateValueLabel.editable = NO;
    self.menuBitrateValueLabel.selectable = NO;
    self.menuBitrateValueLabel.alignment = NSTextAlignmentRight;
    self.menuBitrateValueLabel.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightSemibold];
    self.menuBitrateValueLabel.textColor = [NSColor secondaryLabelColor];
    NSInteger displayKbps = isCustomMode ? selectedKbps : (fallbackBitrate ? fallbackBitrate.integerValue : 20000);
    CGFloat mbpsValue = displayKbps / 1000.0;
    if (mbpsValue < 1.0) {
        self.menuBitrateValueLabel.stringValue = [NSString stringWithFormat:@"%.1f Mbps", mbpsValue];
    } else {
        self.menuBitrateValueLabel.stringValue = [NSString stringWithFormat:@"%.0f Mbps", mbpsValue];
    }
    [bitrateView addSubview:self.menuBitrateValueLabel];

    // 码率滑杆
    self.menuBitrateSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(16, 24, 248, 20)];
    self.menuBitrateSlider.minValue = 0.0;
    self.menuBitrateSlider.maxValue = 27.0; // bitrateSteps 数组长度 - 1
    self.menuBitrateSlider.target = self;
    self.menuBitrateSlider.action = @selector(handleBitrateSliderChanged:);
    self.menuBitrateSlider.continuous = YES;
    [self updateBitrateSliderPosition:displayKbps];
    [bitrateView addSubview:self.menuBitrateSlider];

    // 手动输入框
    NSTextField *inputField = [[NSTextField alloc] initWithFrame:NSMakeRect(16, 2, 60, 20)];
    inputField.bezeled = YES;
    inputField.bezelStyle = NSTextFieldRoundedBezel;
    inputField.editable = YES;
    inputField.selectable = YES;
    inputField.alignment = NSTextAlignmentCenter;
    inputField.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    inputField.placeholderString = @"Mbps";
    inputField.stringValue = [NSString stringWithFormat:@"%.0f", mbpsValue];
    inputField.target = self;
    inputField.action = @selector(handleBitrateInputChanged:);
    inputField.tag = 1001; // 用于识别
    [bitrateView addSubview:inputField];

    NSTextField *inputSuffix = [[NSTextField alloc] initWithFrame:NSMakeRect(80, 4, 40, 16)];
    inputSuffix.bezeled = NO;
    inputSuffix.drawsBackground = NO;
    inputSuffix.editable = NO;
    inputSuffix.selectable = NO;
    inputSuffix.font = [NSFont systemFontOfSize:11 weight:NSFontWeightRegular];
    inputSuffix.textColor = [NSColor secondaryLabelColor];
    inputSuffix.stringValue = @"Mbps";
    [bitrateView addSubview:inputSuffix];

    // 应用按钮
    NSButton *applyButton = [[NSButton alloc] initWithFrame:NSMakeRect(200, 2, 64, 20)];
    applyButton.bezelStyle = NSBezelStyleRecessed;
    applyButton.title = @"应用";
    applyButton.target = self;
    applyButton.action = @selector(handleBitrateApplyClicked:);
    applyButton.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    [bitrateView addSubview:applyButton];

    NSMenuItem *bitrateSliderItem = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    bitrateSliderItem.view = bitrateView;
    [customMenu addItem:bitrateSliderItem];

    customBitrateItem.submenu = customMenu;
    [qualityMenu addItem:customBitrateItem];

    qualityItem.submenu = qualityMenu;
    [self.streamMenu addItem:qualityItem];

    // 二级：声音（音量滑杆）
    NSMenuItem *audioItem = [[NSMenuItem alloc] initWithTitle:@"声音" action:nil keyEquivalent:@""];
    setSymbol(audioItem, @"speaker.wave.2");
    NSMenu *audioMenu = [[NSMenu alloc] initWithTitle:@"声音"]; 

    NSView *volView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 240, 28)];
    NSTextField *volLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(10, 6, 42, 16)];
    volLabel.bezeled = NO;
    volLabel.drawsBackground = NO;
    volLabel.editable = NO;
    volLabel.selectable = NO;
    volLabel.font = [NSFont systemFontOfSize:12 weight:NSFontWeightRegular];
    volLabel.textColor = [NSColor labelColor];
    volLabel.stringValue = @"音量";
    [volView addSubview:volLabel];

    if (!self.menuVolumeSlider) {
        self.menuVolumeSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(58, 4, 170, 20)];
        self.menuVolumeSlider.minValue = 0.0;
        self.menuVolumeSlider.maxValue = 1.0;
        self.menuVolumeSlider.target = self;
        self.menuVolumeSlider.action = @selector(handleVolumeSliderChanged:);
        self.menuVolumeSlider.continuous = YES;
    }
    self.menuVolumeSlider.doubleValue = [SettingsClass volumeLevelFor:self.app.host.uuid];
    [volView addSubview:self.menuVolumeSlider];

    NSMenuItem *volSliderItem = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    volSliderItem.view = volView;
    [audioMenu addItem:volSliderItem];

    audioItem.submenu = audioMenu;
    [self.streamMenu addItem:audioItem];

    // 二级：网络（连接方式）
    NSMenuItem *networkItem = [[NSMenuItem alloc] initWithTitle:@"网络" action:nil keyEquivalent:@""];
    setSymbol(networkItem, @"network");
    NSMenu *networkMenu = [[NSMenu alloc] initWithTitle:@"网络"]; 

    NSString *method = prefs[@"connectionMethod"] ?: @"Auto";
    NSMenuItem *autoItem = [[NSMenuItem alloc] initWithTitle:@"自动" action:@selector(selectConnectionMethodFromMenu:) keyEquivalent:@""];
    autoItem.target = self;
    autoItem.representedObject = @"Auto";
    autoItem.state = [method isEqualToString:@"Auto"] ? NSControlStateValueOn : NSControlStateValueOff;
    setSymbol(autoItem, @"wand.and.stars");
    [networkMenu addItem:autoItem];

    NSArray<NSString *> *candidates = @[ self.app.host.localAddress ?: @"", self.app.host.address ?: @"", self.app.host.externalAddress ?: @"", self.app.host.ipv6Address ?: @"" ];
    NSMutableOrderedSet<NSString *> *unique = [[NSMutableOrderedSet alloc] init];
    for (NSString *addr in candidates) {
        if (addr.length > 0) {
            [unique addObject:addr];
        }
    }
    if (unique.count > 0) {
        [networkMenu addItem:[NSMenuItem separatorItem]];
        for (NSString *addr in unique) {
            NSMenuItem *addrItem = [[NSMenuItem alloc] initWithTitle:addr action:@selector(selectConnectionMethodFromMenu:) keyEquivalent:@""];
            addrItem.target = self;
            addrItem.representedObject = addr;
            addrItem.state = [method isEqualToString:addr] ? NSControlStateValueOn : NSControlStateValueOff;
            setSymbol(addrItem, @"link");
            [networkMenu addItem:addrItem];
        }
    }

    networkItem.submenu = networkMenu;
    [self.streamMenu addItem:networkItem];

    // 二级：日志（显示/复制）
    NSMenuItem *logsItem = [[NSMenuItem alloc] initWithTitle:@"日志" action:nil keyEquivalent:@""];
    setSymbol(logsItem, @"text.justify.left");
    NSMenu *logsMenu = [[NSMenu alloc] initWithTitle:@"日志"]; 

    NSMenuItem *toggleLogsItem = [[NSMenuItem alloc] initWithTitle:@"显示日志" action:@selector(toggleLogOverlayFromMenu:) keyEquivalent:@""];
    toggleLogsItem.target = self;
    toggleLogsItem.state = self.logOverlayContainer ? NSControlStateValueOn : NSControlStateValueOff;
    setSymbol(toggleLogsItem, @"text.justify.left");
    [logsMenu addItem:toggleLogsItem];

    NSMenuItem *copyLogsItem = [[NSMenuItem alloc] initWithTitle:@"复制日志" action:@selector(copyLogsFromMenu:) keyEquivalent:@""];
    copyLogsItem.target = self;
    setSymbol(copyLogsItem, @"doc.on.doc");
    [logsMenu addItem:copyLogsItem];

    logsItem.submenu = logsMenu;
    [self.streamMenu addItem:logsItem];

    // 二级：更多（把重连/退出放底部）
    NSMenuItem *moreItem = [[NSMenuItem alloc] initWithTitle:@"更多" action:nil keyEquivalent:@""];
    setSymbol(moreItem, @"ellipsis.circle");
    NSMenu *moreMenu = [[NSMenu alloc] initWithTitle:@"更多"]; 

    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"关闭并退出应用" action:@selector(performCloseAndQuitApp:) keyEquivalent:@""];
    [self applyShortcut:[self streamShortcutForAction:MLShortcutActionCloseAndQuitApp] toMenuItem:quitItem];
    quitItem.target = self;
    setSymbol(quitItem, @"power");
    [moreMenu addItem:quitItem];

    moreItem.submenu = moreMenu;
    [self.streamMenu addItem:moreItem];

    // 一级底部：退出
    [self.streamMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *disconnectItem = [[NSMenuItem alloc] initWithTitle:@"退出串流" action:@selector(performCloseStreamWindow:) keyEquivalent:@""];
    [self applyShortcut:[self streamShortcutForAction:MLShortcutActionDisconnectStream] toMenuItem:disconnectItem];
    disconnectItem.target = self;
    setSymbol(disconnectItem, @"xmark.circle");
    [self.streamMenu addItem:disconnectItem];
}

- (void)handleToggleFullscreenFromMenu:(id)sender {
    [self.view.window toggleFullScreen:self];
}

- (void)toggleLogOverlayFromMenu:(id)sender {
    [self toggleLogOverlay];
}

- (void)copyLogsFromMenu:(id)sender {
    [self copyAllLogsToPasteboard];
}

- (void)reconnectFromMenu:(id)sender {
    [self attemptReconnectWithReason:@"menu"]; 
}

- (void)selectConnectionMethodFromMenu:(NSMenuItem *)sender {
    NSString *method = (NSString *)sender.representedObject;
    if (method.length == 0) {
        return;
    }

    NSDictionary *prefs = [SettingsClass getSettingsFor:self.app.host.uuid];
    NSString *current = prefs[@"connectionMethod"] ?: @"Auto";
    if ([current isEqualToString:method]) {
        return;
    }

    [SettingsClass setConnectionMethod:method for:self.app.host.uuid];
    [self updateWindowSubtitle];
    [SettingsClass loadMoonlightSettingsFor:self.app.host.uuid];
    [self attemptReconnectWithReason:@"connection-method-changed"]; 
}

- (void)selectFollowHostFromMenu:(id)sender {
    // 0x0 resolution and 0 FPS usually signals "Native" or "Default" to the core library.
    // We treat this as "Follow Host".
    [SettingsClass setCustomResolution:0 :0 :0 for:self.app.host.uuid];
    
    [SettingsClass loadMoonlightSettingsFor:self.app.host.uuid];
    [self attemptReconnectWithReason:@"resolution-changed"];
}

- (void)selectCustomResolutionFromMenu:(id)sender {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"自定义分辨率与帧率";
    alert.informativeText = @"请输入期望的分辨率（宽 x 高）和帧率（FPS）。\n设置为 0 代表由服务端决定（不建议）。";
    [alert addButtonWithTitle:@"确定"];
    [alert addButtonWithTitle:@"取消"];
    
    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 200, 100)];
    
    // Width
    NSTextField *widthLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 75, 50, 20)];
    widthLabel.stringValue = @"宽:";
    widthLabel.bezeled = NO;
    widthLabel.drawsBackground = NO;
    widthLabel.alignment = NSTextAlignmentRight;
    [container addSubview:widthLabel];
    
    NSTextField *widthField = [[NSTextField alloc] initWithFrame:NSMakeRect(55, 75, 60, 22)];
    widthField.placeholderString = @"1920";
    [container addSubview:widthField];
    
    // Height
    NSTextField *heightLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 45, 50, 20)];
    heightLabel.stringValue = @"高:";
    heightLabel.bezeled = NO;
    heightLabel.drawsBackground = NO;
    heightLabel.alignment = NSTextAlignmentRight;
    [container addSubview:heightLabel];
    
    NSTextField *heightField = [[NSTextField alloc] initWithFrame:NSMakeRect(55, 45, 60, 22)];
    heightField.placeholderString = @"1080";
    [container addSubview:heightField];
    
    // FPS
    NSTextField *fpsLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 15, 50, 20)];
    fpsLabel.stringValue = @"FPS:";
    fpsLabel.bezeled = NO;
    fpsLabel.drawsBackground = NO;
    fpsLabel.alignment = NSTextAlignmentRight;
    [container addSubview:fpsLabel];
    
    NSTextField *fpsField = [[NSTextField alloc] initWithFrame:NSMakeRect(55, 15, 60, 22)];
    fpsField.placeholderString = @"60";
    [container addSubview:fpsField];
    
    // Pre-fill with current
    struct Resolution res = [self.class getResolution];
    TemporarySettings *tempSettings = [[DataManager alloc] getSettings];
    int currentFps = [tempSettings.framerate intValue];
    
    if (res.width > 0) widthField.intValue = res.width;
    if (res.height > 0) heightField.intValue = res.height;
    if (currentFps > 0) fpsField.intValue = currentFps;
    
    alert.accessoryView = container;
    
    [alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse returnCode) {
        if (returnCode == NSAlertFirstButtonReturn) {
            int w = widthField.intValue;
            int h = heightField.intValue;
            int f = fpsField.intValue;
            
            // Basic validation
            if (w < 0) w = 0;
            if (h < 0) h = 0;
            if (f < 0) f = 0;
            
            [SettingsClass setCustomResolution:w :h :f for:self.app.host.uuid];
            [SettingsClass loadMoonlightSettingsFor:self.app.host.uuid];
            [self attemptReconnectWithReason:@"custom-resolution"];
        }
    }];
}

- (void)selectMatchDisplayFromMenu:(id)sender {
    NSDictionary *prefs = [SettingsClass getSettingsFor:self.app.host.uuid];
    BOOL currentMatch = prefs ? [prefs[@"matchDisplayResolution"] boolValue] : NO;
    if (currentMatch) {
         return;
    }
    
    // Switch to match display
    // We need current FPS because setResolutionAndFps requires it.
    TemporarySettings *tempSettings = [[DataManager alloc] getSettings];
    int currentFps = [tempSettings.framerate intValue];

    [SettingsClass setResolutionAndFps:0 :0 :currentFps matchDisplay:YES for:self.app.host.uuid];
    
    [SettingsClass loadMoonlightSettingsFor:self.app.host.uuid];
    [self attemptReconnectWithReason:@"resolution-changed"];
}

- (void)selectResolutionFromMenu:(NSMenuItem *)sender {
    NSValue *val = sender.representedObject;
    if (!val) return;
    NSSize size = val.sizeValue;
    
    TemporarySettings *tempSettings = [[DataManager alloc] getSettings];
    int currentFps = [tempSettings.framerate intValue];

    // Disable match display, set explicit resolution
    [SettingsClass setResolutionAndFps:(int)size.width :(int)size.height :currentFps matchDisplay:NO for:self.app.host.uuid];

    [SettingsClass loadMoonlightSettingsFor:self.app.host.uuid];
    [self attemptReconnectWithReason:@"resolution-changed"];
}

- (void)selectFrameRateFromMenu:(NSMenuItem *)sender {
    NSNumber *fpsStats = sender.representedObject;
    if (!fpsStats) return;
    int newFps = fpsStats.intValue;

    TemporarySettings *tempSettings = [[DataManager alloc] getSettings];
    int currentFps = [tempSettings.framerate intValue];
    if (newFps == currentFps) return;
    
    // Get current resolution settings to preserve them
    NSDictionary *prefs = [SettingsClass getSettingsFor:self.app.host.uuid];
    BOOL matchDisplay = prefs ? [prefs[@"matchDisplayResolution"] boolValue] : NO;
    
    // If not matching display, we need to know the explicit resolution.
    // getResolution returns the currently streaming config resolution, which is what we want to keep.
    struct Resolution currentRes = [self.class getResolution];
    
    [SettingsClass setResolutionAndFps:currentRes.width :currentRes.height :newFps matchDisplay:matchDisplay for:self.app.host.uuid];
    
    [SettingsClass loadMoonlightSettingsFor:self.app.host.uuid];
    [self attemptReconnectWithReason:@"framerate-changed"];
}

- (void)selectCustomFpsFromMenu:(id)sender {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"自定义帧率";
    alert.informativeText = @"请输入期望的帧率（FPS）。";
    [alert addButtonWithTitle:@"确定"];
    [alert addButtonWithTitle:@"取消"];
    
    NSTextField *fpsField = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 200, 24)];
    fpsField.placeholderString = @"60";
    
    // Pre-fill
    NSDictionary *prefs = [SettingsClass getSettingsFor:self.app.host.uuid];
    int currentFps = 0;
    if (prefs) {
        int rawFps = [prefs[@"fps"] intValue];
        if (rawFps == 0) {
            currentFps = [prefs[@"customFps"] intValue];
        } else {
            currentFps = rawFps;
        }
    }
    if (currentFps == 0) {
        TemporarySettings *tempSettings = [[DataManager alloc] getSettings];
        currentFps = [tempSettings.framerate intValue];
    }
    
    if (currentFps > 0) fpsField.intValue = currentFps;
    
    alert.accessoryView = fpsField;
    
    [alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse returnCode) {
        if (returnCode == NSAlertFirstButtonReturn) {
            int f = fpsField.intValue;
            if (f < 0) f = 0;
            
            NSDictionary *prefs = [SettingsClass getSettingsFor:self.app.host.uuid];
            BOOL matchDisplay = prefs ? [prefs[@"matchDisplayResolution"] boolValue] : NO;
            struct Resolution currentRes = [self.class getResolution];
            
            [SettingsClass setResolutionAndFps:currentRes.width :currentRes.height :f matchDisplay:matchDisplay for:self.app.host.uuid];
            
            [SettingsClass loadMoonlightSettingsFor:self.app.host.uuid];
            [self attemptReconnectWithReason:@"framerate-changed"];
        }
    }];
}


- (void)selectBitrateFromMenu:(NSMenuItem *)sender {
    id rep = sender.representedObject;
    NSDictionary *prefs = [SettingsClass getSettingsFor:self.app.host.uuid];
    BOOL currentAuto = prefs ? [prefs[@"autoAdjustBitrate"] boolValue] : YES;
    NSNumber *currentCustom = prefs[@"customBitrate"]; // Kbps

    if ([rep isKindOfClass:[NSString class]] && [(NSString *)rep isEqualToString:@"auto"]) {
        if (currentAuto) {
            return;
        }
        [SettingsClass setBitrateMode:YES customBitrateKbps:nil for:self.app.host.uuid];
    } else if ([rep isKindOfClass:[NSNumber class]]) {
        NSNumber *kbps = (NSNumber *)rep;
        if (!currentAuto && currentCustom && currentCustom.integerValue == kbps.integerValue) {
            return;
        }
        [SettingsClass setBitrateMode:NO customBitrateKbps:kbps for:self.app.host.uuid];
    } else {
        return;
    }

    [SettingsClass loadMoonlightSettingsFor:self.app.host.uuid];
    [self attemptReconnectWithReason:@"bitrate-changed"]; 
}

- (void)handleVolumeSliderChanged:(NSSlider *)sender {
    [SettingsClass setVolumeLevel:(CGFloat)sender.doubleValue for:self.app.host.uuid];
}

#pragma mark - Bitrate Slider

static NSArray<NSNumber *> *bitrateStepsArray(void) {
    return @[@0.5, @1, @1.5, @2, @2.5, @3, @4, @5, @6, @7, @8, @9, @10,
             @12, @15, @18, @20, @25, @30, @40, @50, @60, @70, @80, @90, @100, @120, @150];
}

- (void)updateBitrateSliderPosition:(NSInteger)currentKbps {
    NSArray *steps = bitrateStepsArray();
    NSInteger index = 0;
    CGFloat currentMbps = currentKbps / 1000.0;
    for (NSInteger i = 0; i < (NSInteger)steps.count; i++) {
        if (currentMbps <= [steps[i] floatValue]) {
            index = i;
            break;
        }
        if (i == (NSInteger)steps.count - 1) {
            index = i;
        }
    }
    self.menuBitrateSlider.doubleValue = index;
}

- (void)handleBitrateSliderChanged:(NSSlider *)sender {
    NSArray *steps = bitrateStepsArray();
    NSInteger index = (NSInteger)round(sender.doubleValue);
    index = MAX(0, MIN(index, (NSInteger)steps.count - 1));

    CGFloat mbps = [steps[index] floatValue];
    NSInteger kbps = (NSInteger)(mbps * 1000);

    // 更新显示
    if (mbps < 1.0) {
        self.menuBitrateValueLabel.stringValue = [NSString stringWithFormat:@"%.1f Mbps", mbps];
    } else {
        self.menuBitrateValueLabel.stringValue = [NSString stringWithFormat:@"%.0f Mbps", mbps];
    }

    // 同步更新输入框
    NSView *bitrateView = sender.superview;
    for (NSView *subview in bitrateView.subviews) {
        if ([subview isKindOfClass:[NSTextField class]] && subview.tag == 1001) {
            NSTextField *inputField = (NSTextField *)subview;
            if (mbps < 1.0) {
                inputField.stringValue = [NSString stringWithFormat:@"%.1f", mbps];
            } else {
                inputField.stringValue = [NSString stringWithFormat:@"%.0f", mbps];
            }
            break;
        }
    }

    // 保存设置（关闭自动模式，设置自定义码率）
    [SettingsClass setBitrateMode:NO customBitrateKbps:@(kbps) for:self.app.host.uuid];
    [SettingsClass loadMoonlightSettingsFor:self.app.host.uuid];
}

- (void)handleBitrateInputChanged:(NSTextField *)sender {
    CGFloat mbps = sender.doubleValue;
    if (mbps < 0.5) mbps = 0.5;
    if (mbps > 150) mbps = 150;

    NSInteger kbps = (NSInteger)(mbps * 1000);

    // 更新显示
    if (mbps < 1.0) {
        self.menuBitrateValueLabel.stringValue = [NSString stringWithFormat:@"%.1f Mbps", mbps];
    } else {
        self.menuBitrateValueLabel.stringValue = [NSString stringWithFormat:@"%.0f Mbps", mbps];
    }

    // 更新滑块位置
    [self updateBitrateSliderPosition:kbps];

    // 保存设置
    [SettingsClass setBitrateMode:NO customBitrateKbps:@(kbps) for:self.app.host.uuid];
    [SettingsClass loadMoonlightSettingsFor:self.app.host.uuid];
}

- (void)handleBitrateApplyClicked:(NSButton *)sender {
    // 触发重连以应用新码率
    [self rebuildStreamMenu];
    [self attemptReconnectWithReason:@"bitrate-changed"];
}

- (void)toggleFullscreenControlBallFromMenu:(NSMenuItem *)sender {
    [self toggleFullscreenControlBallVisibility];
}

- (void)toggleFullscreenControlBallVisibility {
    self.hideFullscreenControlBall = !self.hideFullscreenControlBall;
    [[NSUserDefaults standardUserDefaults] setBool:self.hideFullscreenControlBall forKey:[self fullscreenControlBallDefaultsKey]];
    [self requestStreamMenuEntrypointsVisibilityUpdate];
}

- (void)toggleMouseMode {
    NSString *currentMode = [SettingsClass mouseModeFor:self.app.host.uuid];
    NSString *newMode = [currentMode isEqualToString:@"game"] ? @"remote" : @"game";
    [self applyMouseModeNamed:newMode showNotification:YES];
}

- (void)toggleMouseModeFromMenu:(id)sender {
    [self toggleMouseMode];
}

- (void)selectLockedMouseModeFromMenu:(id)sender {
    [self applyMouseModeNamed:@"game" showNotification:YES];
}

- (void)selectFreeMouseModeFromMenu:(id)sender {
    [self applyMouseModeNamed:@"remote" showNotification:YES];
}

@end
