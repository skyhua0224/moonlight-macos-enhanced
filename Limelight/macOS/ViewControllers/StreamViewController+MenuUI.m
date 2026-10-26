//
//  StreamViewController+MenuUI.m
//  Moonlight for macOS
//

#import "StreamViewController_Internal.h"
#import "MLMenuItemImage.h"
#import "MLAudioBitstreamOutput.h"
#import <CoreAudio/CoreAudio.h>

// Same icon mechanism the control center items use (see the setSymbol block in -rebuildStreamMenu).
static void MLStreamMenuSetSymbol(NSMenuItem *item, NSString *symbolName) {
    if (@available(macOS 11.0, *)) {
        MLSetMenuItemImage(item, [NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:nil]);
    }
}

// Brings the items of a menu in line with specs: dictionaries with title, optional action (a selector
// name), rep (represented object), state and enabled. When the items already have that shape only
// titles, states and enabled flags are touched. The menu can be on screen, shown by the controller
// panel or under the pointer, and replacing its items there moves the user; items are only replaced
// when the set of choices really differs. Returns YES when it had to replace them. Main thread.
static BOOL MLSyncMenuItems(NSMenu *menu, NSArray<NSDictionary<NSString *, id> *> *specs, id target) {
    BOOL sameShape = menu.numberOfItems == (NSInteger)specs.count;
    for (NSUInteger i = 0; sameShape && i < specs.count; i++) {
        NSMenuItem *item = [menu itemAtIndex:(NSInteger)i];
        NSString *actionName = specs[i][@"action"];
        SEL action = actionName != nil ? NSSelectorFromString(actionName) : NULL;
        id representedObject = specs[i][@"rep"];
        sameShape = item.action == action &&
                    (item.representedObject == representedObject || [item.representedObject isEqual:representedObject]);
    }
    if (!sameShape) {
        [menu removeAllItems];
        for (NSDictionary<NSString *, id> *spec in specs) {
            NSString *actionName = spec[@"action"];
            SEL action = actionName != nil ? NSSelectorFromString(actionName) : NULL;
            NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:spec[@"title"] action:action keyEquivalent:@""];
            item.target = action != NULL ? target : nil;
            item.representedObject = spec[@"rep"];
            [menu addItem:item];
        }
    }
    for (NSUInteger i = 0; i < specs.count; i++) {
        NSMenuItem *item = [menu itemAtIndex:(NSInteger)i];
        NSDictionary<NSString *, id> *spec = specs[i];
        if (![item.title isEqualToString:spec[@"title"]]) {
            item.title = spec[@"title"];
        }
        NSControlStateValue state = [spec[@"state"] integerValue];
        if (item.state != state) {
            item.state = state;
        }
        BOOL enabled = spec[@"enabled"] != nil ? [spec[@"enabled"] boolValue] : YES;
        if (item.enabled != enabled) {
            item.enabled = enabled;
        }
    }
    return !sameShape;
}

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
}

- (NSView *)preferredControlCenterSourceView {
    if (([self isWindowFullscreen] || [self isWindowBorderlessMode]) &&
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

// Controller version of the control center: the same menu, as a list the
// D-pad drives. Game input pauses while it is open.
- (void)presentControllerControlCenter {
    NSWindow *window = self.view.window;
    if (window == nil || self.stopStreamInProgress || ControllerMenuPanel.shared.isPresented) {
        return;
    }

    BOOL wasCaptured = self.isMouseCaptured;
    if (wasCaptured) {
        self.pendingOptionUncaptureToken += 1;
        self.lastOptionUncaptureAtMs = [self nowMs];
        [self.hidSupport releaseAllModifierKeys];
        [self suppressConnectionWarningsForSeconds:2.0 reason:@"shortcut-uncapture"];
        [self uncaptureMouseWithCode:@"MUC203" reason:@"controller-control-center"];
    }
    BOOL hidWasSending = self.hidSupport.shouldSendInputEvents;
    BOOL controllerWasSending = self.controllerSupport.shouldSendInputEvents;
    self.hidSupport.shouldSendInputEvents = NO;
    self.controllerSupport.shouldSendInputEvents = NO;
    self.controllerControlCenterVisible = YES;
    [self refreshControllerShortcutContext];
    [self rebuildStreamMenu];

    __weak typeof(self) weakSelf = self;
    [ControllerMenuPanel.shared presentMenu:self.streamMenu
                                      title:MLString(@"Control Center", nil)
                                   inWindow:window
                              selectedIndex:-1
                                 firstIndex:0
                                    onClose:^(BOOL performed) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        strongSelf.controllerControlCenterVisible = NO;
        strongSelf.hidSupport.shouldSendInputEvents = hidWasSending;
        strongSelf.controllerSupport.shouldSendInputEvents = controllerWasSending;
        [strongSelf refreshControllerShortcutContext];
        if (!wasCaptured) {
            return;
        }
        // Runs after the chosen item; skip if it ended the stream or opened a window.
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!strongSelf.stopStreamInProgress && strongSelf.view.window.isKeyWindow &&
                NSApp.modalWindow == nil && !strongSelf.isMouseCaptured) {
                [strongSelf captureMouse];
            }
        });
    }];
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
    // The ball is a subview of the stream view. Expanded, its plate docks a
    // few points from the edge; idle, it slides out so only a sliver remains.
    CGFloat coordinate = [self resolvedEdgeMenuCoordinateInRect:rect];
    CGFloat plateSize = MLEdgeMenuButtonWidth * MLEdgeMenuPlateRatio;
    CGFloat platePadding = (MLEdgeMenuButtonWidth - plateSize) / 2.0;
    // Offset by the transparent margin around the plate so the plate itself docks.
    CGFloat inset = expanded
        ? MLEdgeMenuPlateEdgeGap - platePadding
        : plateSize * MLEdgeMenuCollapsedPlateFraction - plateSize - platePadding;
    switch (self.edgeMenuDockEdge) {
        case MLFreeMouseExitEdgeLeft:
            return NSMakeRect(NSMinX(rect) + inset, coordinate, MLEdgeMenuButtonWidth, MLEdgeMenuButtonHeight);
        case MLFreeMouseExitEdgeTop:
            return NSMakeRect(coordinate, NSMaxY(rect) - MLEdgeMenuButtonHeight - inset,
                              MLEdgeMenuButtonWidth, MLEdgeMenuButtonHeight);
        case MLFreeMouseExitEdgeBottom:
            return NSMakeRect(coordinate, NSMinY(rect) + inset, MLEdgeMenuButtonWidth, MLEdgeMenuButtonHeight);
        case MLFreeMouseExitEdgeRight:
        case MLFreeMouseExitEdgeNone:
        default:
            return NSMakeRect(NSMaxX(rect) - MLEdgeMenuButtonWidth - inset, coordinate,
                              MLEdgeMenuButtonWidth, MLEdgeMenuButtonHeight);
    }
}

- (void)persistFullscreenControlBallPlacement {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:[self storedValueForEdgeMenuDockEdge:self.edgeMenuDockEdge]
                 forKey:[self fullscreenControlBallDockSideDefaultsKey]];
    [defaults setDouble:self.edgeMenuButtonEdgeRatio forKey:[self fullscreenControlBallVerticalRatioDefaultsKey]];
}

- (void)loadPersistedFullscreenControlBallPlacement {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    self.edgeMenuDockEdge = [self edgeMenuDockEdgeFromStoredValue:
        [defaults stringForKey:[self fullscreenControlBallDockSideDefaultsKey]]];
    NSNumber *ratio = [defaults objectForKey:[self fullscreenControlBallVerticalRatioDefaultsKey]];
    self.edgeMenuButtonEdgeRatio = [ratio isKindOfClass:NSNumber.class]
        ? MIN(MAX(ratio.doubleValue, 0.0), 1.0) : 0.5;
}

- (void)resetEdgeMenuPlacementForNewStreamSession {
    [self loadPersistedFullscreenControlBallPlacement];
    self.globalInactivePointerInsideStreamView = NO;
    self.edgeMenuButtonExpanded = NO;
    self.edgeMenuPointerInside = NO;
    self.edgeMenuTemporaryReleaseActive = NO;
    self.edgeMenuDragging = NO;
    self.edgeMenuMenuVisible = NO;
    [self cancelEdgeMenuAutoCollapse];
    [self updateEdgeMenuButtonAppearance];
    [self refreshMouseMovedAcceptanceState];
    [self requestStreamMenuEntrypointsVisibilityUpdate];
}

- (void)hideEdgeMenuForInactiveSpaceIfNeeded {
    // The ball moves with the stream view across Spaces; only drop transient
    // interaction state so it does not stay expanded or hold a released pointer.
    if (!self.edgeMenuButton) {
        return;
    }
    self.globalInactivePointerInsideStreamView = NO;
    self.edgeMenuPointerInside = NO;
    self.edgeMenuTemporaryReleaseActive = NO;
    self.edgeMenuDragging = NO;
    self.edgeMenuMenuVisible = NO;
    self.edgeMenuButtonExpanded = NO;
    [self cancelEdgeMenuAutoCollapse];
    [self updateEdgeMenuButtonAppearance];
    [self refreshMouseMovedAcceptanceState];
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
    BOOL expanded = self.edgeMenuButtonExpanded || self.edgeMenuDragging || self.edgeMenuMenuVisible;
    return [self edgeMenuFrameInRect:bounds expanded:expanded];
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
    if (!self.edgeMenuButton) {
        return;
    }
    self.edgeMenuButtonExpanded = expanded;
    [self cancelEdgeMenuAutoCollapse];
    [self updateEdgeMenuButtonAppearance];
    if (self.edgeMenuButton.hidden || self.edgeMenuDragging) {
        return;
    }

    NSRect target = [self frameForEdgeMenuButtonInBounds:self.view.bounds];
    [self setEdgeMenuButtonFrame:target
                        animated:animated
                          reason:expanded ? @"expand" : @"collapse"];
}

// Every frame the ball receives goes through here so an animation still in
// flight can never leave the layer showing a position the frame no longer has.
- (void)setEdgeMenuButtonFrame:(NSRect)frame animated:(BOOL)animated reason:(NSString *)reason {
    MLEdgeMenuHandleView *button = self.edgeMenuButton;
    if (!button) {
        return;
    }

    CFTimeInterval now = CACurrentMediaTime();
    BOOL animationInFlight = now < self.edgeMenuFrameAnimationDeadline;
    NSRect from = button.frame;
    NSRect shown = from;
    CALayer *presentation = button.layer.presentationLayer;
    if (animationInFlight && presentation != nil) {
        shown = NSRectFromCGRect(presentation.frame);
    }
    if (NSEqualRects(frame, from)) {
        // Already at (or animating toward) this frame; layout passes land here often.
        return;
    }

    [self logEdgeMenuFrameChangeWithReason:reason from:shown to:frame animated:animated];

    // Retarget from where the ball is drawn, not from where the last animation
    // was heading, then drop whatever is still running.
    [button.layer removeAllAnimations];
    self.edgeMenuFrameAnimationDeadline = 0;
    if (!NSEqualRects(shown, from)) {
        button.frame = shown;
    }
    if (animated && !NSEqualRects(frame, button.frame)) {
        self.edgeMenuFrameAnimationDeadline = now + MLEdgeMenuSnapDuration + 0.05;
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = MLEdgeMenuSnapDuration;
            context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
            button.animator.frame = frame;
        } completionHandler:nil];
    } else {
        button.frame = frame;
    }
    [self updateEdgeMenuButtonTrackingArea];
}

- (void)logEdgeMenuFrameChangeWithReason:(NSString *)reason
                                    from:(NSRect)from
                                      to:(NSRect)to
                                animated:(BOOL)animated {
    // Dragging moves the ball on every mouse event; keep one line per burst.
    CFTimeInterval now = CACurrentMediaTime();
    BOOL sameReason = [reason isEqualToString:self.edgeMenuFrameLogLastReason];
    if (sameReason && now - self.edgeMenuFrameLogLastTime < 0.25) {
        self.edgeMenuFrameLogSuppressed++;
        return;
    }
    NSUInteger suppressed = self.edgeMenuFrameLogSuppressed;
    self.edgeMenuFrameLogSuppressed = 0;
    self.edgeMenuFrameLogLastTime = now;
    self.edgeMenuFrameLogLastReason = reason;
    Log(LOG_I, @"[diag] control-orb frame reason=%@ from=%@ to=%@ animated=%d dock=%@ ratio=%.3f bounds=%@ expanded=%d dragging=%d menu=%d%@",
        reason ?: @"unspecified",
        NSStringFromRect(from),
        NSStringFromRect(to),
        animated ? 1 : 0,
        [self storedValueForEdgeMenuDockEdge:self.edgeMenuDockEdge],
        self.edgeMenuButtonEdgeRatio,
        NSStringFromRect(self.view.bounds),
        self.edgeMenuButtonExpanded ? 1 : 0,
        self.edgeMenuDragging ? 1 : 0,
        self.edgeMenuMenuVisible ? 1 : 0,
        suppressed > 0 ? [NSString stringWithFormat:@" (+%lu similar)", (unsigned long)suppressed] : @"");
}

- (void)validateEdgeMenuButtonFrameWithReason:(NSString *)reason {
    MLEdgeMenuHandleView *button = self.edgeMenuButton;
    if (!MLUseFloatingControlOrb || !button || button.hidden || !self.view.window ||
        self.edgeMenuDragging || self.edgeMenuMenuVisible || self.fullscreenTransitionInProgress) {
        return;
    }
    if (CACurrentMediaTime() < self.edgeMenuFrameAnimationDeadline) {
        return;
    }

    NSRect expected = [self frameForEdgeMenuButtonInBounds:self.view.bounds];
    NSRect actual = button.frame;
    BOOL frameOff = fabs(expected.origin.x - actual.origin.x) > 0.5 ||
                    fabs(expected.origin.y - actual.origin.y) > 0.5 ||
                    fabs(expected.size.width - actual.size.width) > 0.5 ||
                    fabs(expected.size.height - actual.size.height) > 0.5;
    if (frameOff) {
        [self setEdgeMenuButtonFrame:expected animated:NO reason:[@"revalidate-" stringByAppendingString:reason ?: @""]];
        return;
    }

    CALayer *presentation = button.layer.presentationLayer;
    if (presentation != nil) {
        NSRect shown = NSRectFromCGRect(presentation.frame);
        if (fabs(shown.origin.x - actual.origin.x) > 1.0 || fabs(shown.origin.y - actual.origin.y) > 1.0) {
            [self logEdgeMenuFrameChangeWithReason:[@"presentation-stale-" stringByAppendingString:reason ?: @""]
                                              from:shown
                                                to:actual
                                          animated:NO];
            [button.layer removeAllAnimations];
        }
    }
}

- (void)endStaleEdgeMenuDragIfNeeded {
    if (!self.edgeMenuDragging) {
        self.edgeMenuStaleDragSince = 0;
        return;
    }
    if (NSEvent.pressedMouseButtons & 1) {
        self.edgeMenuStaleDragSince = 0;
        return;
    }
    CFTimeInterval now = CACurrentMediaTime();
    if (self.edgeMenuStaleDragSince == 0) {
        self.edgeMenuStaleDragSince = now;
        return;
    }
    if (now - self.edgeMenuStaleDragSince < 0.3) {
        return;
    }
    // The mouse-up that should have ended this drag never arrived.
    self.edgeMenuStaleDragSince = 0;
    Log(LOG_W, @"[diag] control-orb drag ended by watchdog: button released without mouse-up");
    if (self.edgeMenuButton.dragInProgress) {
        [self.edgeMenuButton cancelPendingInteraction];
    } else {
        [self handleEdgeMenuButtonDragWithState:NSGestureRecognizerStateEnded translation:NSZeroPoint];
    }
}

- (void)startEdgeMenuFrameWatchdogIfNeeded {
    if (self.edgeMenuFrameWatchdogTimer != nil) {
        return;
    }
    __weak typeof(self) weakSelf = self;
    self.edgeMenuFrameWatchdogTimer = [NSTimer timerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil || strongSelf.edgeMenuButton == nil) {
            [timer invalidate];
            return;
        }
        [strongSelf endStaleEdgeMenuDragIfNeeded];
        [strongSelf validateEdgeMenuButtonFrameWithReason:@"watchdog"];
        // An expanded ball with nothing keeping it open and no collapse
        // pending would otherwise stay on screen indefinitely.
        if (strongSelf.edgeMenuButtonExpanded && !strongSelf.edgeMenuButton.hidden &&
            strongSelf.edgeMenuAutoCollapseTimer == nil && !strongSelf.edgeMenuPointerInside &&
            !strongSelf.edgeMenuTemporaryReleaseActive && !strongSelf.edgeMenuDragging &&
            !strongSelf.edgeMenuMenuVisible) {
            [strongSelf scheduleEdgeMenuAutoCollapse];
        }
    }];
    self.edgeMenuFrameWatchdogTimer.tolerance = 0.2;
    [[NSRunLoop mainRunLoop] addTimer:self.edgeMenuFrameWatchdogTimer forMode:NSRunLoopCommonModes];
}

- (void)stopEdgeMenuFrameWatchdog {
    [self.edgeMenuFrameWatchdogTimer invalidate];
    self.edgeMenuFrameWatchdogTimer = nil;
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
    [self scheduleEdgeMenuAutoCollapseAfterDelay:MLEdgeMenuAutoCollapseDelay];
}

// One line each time the orb's hover / capture state changes (menu open and close always log).
// When the orb "does not react", the last line shows which flag was holding it: a hover that
// never reached the orb leaves no line at all, one that did shows whether the mouse was released.
- (void)logControlOrbStateWithReason:(NSString *)reason {
    NSRect frame = self.edgeMenuButton.frame;
    NSString *state = [NSString stringWithFormat:@"expanded=%d inside=%d release=%d menu=%d dragging=%d captured=%d remote=%d hidden=%d key=%d active=%d y=%.0f-%.0f",
                       self.edgeMenuButtonExpanded ? 1 : 0, self.edgeMenuPointerInside ? 1 : 0,
                       self.edgeMenuTemporaryReleaseActive ? 1 : 0, self.edgeMenuMenuVisible ? 1 : 0,
                       self.edgeMenuDragging ? 1 : 0, self.isMouseCaptured ? 1 : 0,
                       self.isRemoteDesktopMode ? 1 : 0, self.edgeMenuButton.hidden ? 1 : 0,
                       self.view.window.isKeyWindow ? 1 : 0, NSApp.isActive ? 1 : 0,
                       NSMinY(frame), NSMaxY(frame)];
    if (![reason hasPrefix:@"menu-"] && [state isEqualToString:self.edgeMenuStateLogLast]) {
        return;
    }
    self.edgeMenuStateLogLast = state;
    Log(LOG_I, @"[diag] control-orb state reason=%@ %@", reason, state);
}

// Shows the whole ball for a moment, then lets it slide back to the edge.
// The collapse is skipped while the pointer is on it; leaving reschedules it.
- (void)revealEdgeMenuTemporarilyAnimated:(BOOL)animated {
    [self setEdgeMenuButtonExpanded:YES animated:animated];
    [self scheduleEdgeMenuAutoCollapseAfterDelay:MLEdgeMenuRevealDuration];
}

- (void)scheduleEdgeMenuAutoCollapseAfterDelay:(NSTimeInterval)delay {
    [self cancelEdgeMenuAutoCollapse];

    __weak typeof(self) weakSelf = self;
    self.edgeMenuAutoCollapseTimer = [NSTimer scheduledTimerWithTimeInterval:delay
                                                                     repeats:NO
                                                                       block:^(__unused NSTimer *timer) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.edgeMenuPointerInside || strongSelf.edgeMenuDragging || strongSelf.edgeMenuMenuVisible) {
            [strongSelf logControlOrbStateWithReason:@"collapse-skipped"];
            return;
        }

        [strongSelf deactivateEdgeMenuTemporaryReleaseAndRecaptureIfNeeded:strongSelf.edgeMenuTemporaryReleaseActive];
    }];
}

- (BOOL)handleEdgeMenuTemporaryReleaseForEvent:(NSEvent *)event {
    if (!self.edgeMenuTemporaryReleaseActive || self.edgeMenuDragging || self.edgeMenuMenuVisible) {
        return NO;
    }

    NSPoint point = [self.hidSupport shouldUseCoreHIDFreeMouseAbsoluteSyncForCurrentConfiguration]
        ? [self currentMouseLocationInViewCoordinates]
        : [self viewPointForMouseEvent:event];
    [self updateEdgeMenuPointerInsideForPoint:point];
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
    if (!self.edgeMenuButton || self.edgeMenuButton.hidden) {
        return;
    }

    // Screen and stream-view coordinates share orientation (neither is flipped).
    NSRect bounds = self.view.bounds;
    switch (state) {
        case NSGestureRecognizerStateBegan:
            [self cancelEdgeMenuAutoCollapse];
            // Settle on the expanded frame before the drag flag freezes frame updates.
            [self setEdgeMenuButtonExpanded:YES animated:NO];
            self.edgeMenuDragging = YES;
            self.edgeMenuPointerInside = YES;
            self.edgeMenuStaleDragSince = 0;
            self.edgeMenuButtonPanStartOrigin = self.edgeMenuButton.frame.origin;
            self.edgeMenuButtonSuppressNextClick = NO;
            [self refreshMouseMovedAcceptanceState];
            break;
        case NSGestureRecognizerStateChanged: {
            if (fabs(translation.x) > 3.0 || fabs(translation.y) > 3.0) {
                self.edgeMenuButtonSuppressNextClick = YES;
            }
            NSRect frame = self.edgeMenuButton.frame;
            frame.origin.x = MIN(MAX(self.edgeMenuButtonPanStartOrigin.x + translation.x, NSMinX(bounds)),
                                 NSMaxX(bounds) - NSWidth(frame));
            frame.origin.y = MIN(MAX(self.edgeMenuButtonPanStartOrigin.y + translation.y, NSMinY(bounds)),
                                 NSMaxY(bounds) - NSHeight(frame));
            [self setEdgeMenuButtonFrame:frame animated:NO reason:@"drag-move"];
            break;
        }
        case NSGestureRecognizerStateEnded:
        case NSGestureRecognizerStateCancelled: {
            self.edgeMenuDragging = NO;
            NSRect frame = self.edgeMenuButton.frame;
            CGFloat centerX = NSMidX(frame);
            CGFloat centerY = NSMidY(frame);
            CGFloat distances[] = {
                centerX - NSMinX(bounds), NSMaxX(bounds) - centerX,
                NSMaxY(bounds) - centerY, centerY - NSMinY(bounds),
            };
            MLFreeMouseExitEdge edges[] = {
                MLFreeMouseExitEdgeLeft, MLFreeMouseExitEdgeRight,
                MLFreeMouseExitEdgeTop, MLFreeMouseExitEdgeBottom,
            };
            NSUInteger best = 0;
            for (NSUInteger i = 1; i < 4; i++) {
                if (distances[i] < distances[best]) {
                    best = i;
                }
            }
            self.edgeMenuDockEdge = edges[best];

            CGFloat inset = MLEdgeMenuButtonInsetY;
            if ([self edgeMenuDockEdgeUsesVerticalAxis]) {
                CGFloat minY = NSMinY(bounds) + inset;
                CGFloat available = MAX(NSMaxY(bounds) - MLEdgeMenuButtonHeight - inset - minY, 1.0);
                self.edgeMenuButtonEdgeRatio = MIN(MAX((NSMinY(frame) - minY) / available, 0.0), 1.0);
            } else {
                CGFloat minX = NSMinX(bounds) + inset;
                CGFloat available = MAX(NSMaxX(bounds) - MLEdgeMenuButtonWidth - inset - minX, 1.0);
                self.edgeMenuButtonEdgeRatio = MIN(MAX((NSMinX(frame) - minX) / available, 0.0), 1.0);
            }
            [self persistFullscreenControlBallPlacement];

            NSRect target = [self frameForEdgeMenuButtonInBounds:bounds];
            [self setEdgeMenuButtonFrame:target animated:YES reason:@"drag-snap"];

            [self updateEdgeMenuPointerInsideForPoint:[self currentMouseLocationInViewCoordinates]];
            [self cancelEdgeMenuAutoCollapse];
            [self scheduleEdgeMenuAutoCollapseAfterDelay:MLEdgeMenuDropRevealDuration];
            [self updateEdgeMenuButtonTrackingArea];
            [self refreshMouseMovedAcceptanceState];
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
    if (self.streamViewLayoutInProgress) {
        if (!self.streamControlsFrontUpdateScheduled) {
            self.streamControlsFrontUpdateScheduled = YES;
            __weak typeof(self) weakSelf = self;
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (strongSelf == nil) {
                    return;
                }
                strongSelf.streamControlsFrontUpdateScheduled = NO;
                [strongSelf bringStreamControlsToFront];
            });
        }
        return;
    }
    if (self.edgeMenuButton && self.edgeMenuButton.superview == self.view) {
        [self.streamView raiseSubviewAboveContent:self.edgeMenuButton];
    }
    if (self.overlayContainer) {
        [self.streamView raiseSubviewAboveContent:self.overlayContainer];
    }
    if (self.logOverlayContainer) {
        [self.streamView raiseSubviewAboveContent:self.logOverlayContainer];
    }
    if (self.reconnectOverlayContainer) {
        [self.streamView raiseSubviewAboveContent:self.reconnectOverlayContainer];
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
        return [NSString stringWithFormat:MLString(@"Stalled %lus", nil), (unsigned long)self.streamHealthNoPayloadStreak];
    }
    if (self.streamHealthHighDropStreak >= 2) {
        return MLString(@"High Packet Loss", nil);
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

    if (self.edgeMenuButton) {
        if (self.edgeMenuButton.superview != self.view) {
            [self.streamView raiseSubviewAboveContent:self.edgeMenuButton];
        }
        [self requestStreamMenuEntrypointsVisibilityUpdate];
        return;
    }

    NSImage *edgeMenuImage = [NSImage imageWithSystemSymbolName:@"slider.horizontal.3" accessibilityDescription:nil];
    if (@available(macOS 11.0, *)) {
        NSImageSymbolConfiguration *config = [NSImageSymbolConfiguration configurationWithPointSize:18
                                                                                             weight:NSFontWeightSemibold
                                                                                              scale:NSImageSymbolScaleLarge];
        edgeMenuImage = [edgeMenuImage imageWithSymbolConfiguration:config];
    }

    // The ball is a subview of the stream view, above the renderer's views, so
    // it follows the window through full screen, borderless and Space changes.
    self.edgeMenuButton = [[MLEdgeMenuHandleView alloc] initWithFrame:NSMakeRect(0, 0, MLEdgeMenuButtonWidth, MLEdgeMenuButtonHeight)];
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
            [strongSelf setEdgeMenuButtonExpanded:YES animated:YES];
        } else if (!strongSelf.edgeMenuDragging && !strongSelf.edgeMenuMenuVisible) {
            [strongSelf scheduleEdgeMenuAutoCollapse];
        }
        [strongSelf refreshMouseMovedAcceptanceState];
        [strongSelf updateEdgeMenuButtonAppearance];
        [strongSelf logControlOrbStateWithReason:hovering ? @"hover-enter" : @"hover-exit"];
    };
    [self.streamView raiseSubviewAboveContent:self.edgeMenuButton];
    [self startEdgeMenuFrameWatchdogIfNeeded];

    [self updateEdgeMenuButtonAppearance];
    [self updateControlCenterEntrypointHints];
    [self requestStreamMenuEntrypointsVisibilityUpdate];
}

- (void)layoutStreamMenuEntrypointsIfNeeded {
    if (!MLUseFloatingControlOrb || !self.edgeMenuButton || self.edgeMenuButton.hidden || self.edgeMenuDragging) {
        return;
    }
    NSRect frame = [self frameForEdgeMenuButtonInBounds:self.view.bounds];
    // A resize while the ball is mid-animation must retarget it too.
    [self setEdgeMenuButtonFrame:frame animated:NO reason:@"layout"];
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
    if (self.fullscreenTransitionInProgress) {
        [self removeMenuTitlebarAccessoryFromWindowIfNeeded];
    } else {
        [self ensureMenuTitlebarAccessoryInstalledIfNeeded];
    }

    if (!MLUseFloatingControlOrb || !self.edgeMenuButton) {
        return;
    }

    // Visibility is a function of the window mode alone; the view hierarchy
    // carries the ball through Space and full-screen transitions.
    BOOL visible = [self edgeMenuShouldBeVisible];
    BOOL changed = self.edgeMenuButton.hidden == visible;
    self.edgeMenuButton.hidden = !visible;
    if (visible) {
        if (changed) {
            // Appear expanded so the ball is noticed, then tuck it away.
            [self revealEdgeMenuTemporarilyAnimated:NO];
        }
        [self layoutStreamMenuEntrypointsIfNeeded];
        [self updateEdgeMenuButtonAppearance];
        [self bringStreamControlsToFront];
    } else {
        if (self.edgeMenuDragging) {
            [self.edgeMenuButton cancelPendingInteraction];
            self.edgeMenuDragging = NO;
        }
        self.edgeMenuButtonExpanded = NO;
        self.edgeMenuTemporaryReleaseActive = NO;
        [self cancelEdgeMenuAutoCollapse];
    }
    if (changed) {
        Log(LOG_I, @"[diag] control-orb visible=%d fullscreen=%d borderless=%d dock=%@ frame=%@",
            visible ? 1 : 0, [self isWindowFullscreen] ? 1 : 0, [self isWindowBorderlessMode] ? 1 : 0,
            [self storedValueForEdgeMenuDockEdge:self.edgeMenuDockEdge], NSStringFromRect(self.edgeMenuButton.frame));
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
    [self logControlOrbStateWithReason:@"menu-open"];
    [self refreshMouseMovedAcceptanceState];
    if (sourceView == self.edgeMenuButton && event != nil) {
        [NSMenu popUpContextMenu:menu withEvent:event forView:sourceView];
    } else {
        [menu popUpMenuPositioningItem:nil atLocation:p inView:sourceView];
    }
    self.edgeMenuMenuVisible = NO;
    [self logControlOrbStateWithReason:@"menu-closed"];
    // Mouse events that were delivered around the menu's modal tracking belong
    // to the menu, not to the ball: forget the press that opened it.
    [self.edgeMenuButton cancelPendingInteraction];
    self.edgeMenuDragging = NO;
    [self validateEdgeMenuButtonFrameWithReason:@"menu-dismissed"];
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
    // The controller panel shows this menu's items (and submenus) in its own window. Emptying
    // and refilling them under it would leave it on orphaned levels, and the panel rebuilds
    // the menu itself every time it opens.
    if (ControllerMenuPanel.shared.isPresented) {
        return;
    }
    if (!self.streamMenu) {
        self.streamMenu = [[NSMenu alloc] initWithTitle:@"StreamMenu"];
    }
    [self.streamMenu removeAllItems];

    void (^setSymbol)(NSMenuItem *, NSString *) = ^(NSMenuItem *item, NSString *symbolName) {
        if (@available(macOS 11.0, *)) {
            MLSetMenuItemImage(item, [NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:nil]);
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
    NSMenuItem *reconnectItem = [[NSMenuItem alloc] initWithTitle:MLString(@"Reconnect", nil) action:@selector(reconnectFromMenu:) keyEquivalent:@""];
    [self applyShortcut:[self streamShortcutForAction:MLShortcutActionReconnectStream] toMenuItem:reconnectItem];
    reconnectItem.target = self;
    setSymbol(reconnectItem, @"arrow.triangle.2.circlepath");
    [self.streamMenu addItem:reconnectItem];

    NSMenuItem *typeClipboardItem = [[NSMenuItem alloc] initWithTitle:MLString(@"Type Clipboard Text", nil) action:@selector(typeClipboardTextFromMenu:) keyEquivalent:@""];
    [self applyShortcut:[self streamShortcutForAction:MLShortcutActionTypeClipboardText] toMenuItem:typeClipboardItem];
    typeClipboardItem.target = self;
    setSymbol(typeClipboardItem, @"doc.on.clipboard");
    [self.streamMenu addItem:typeClipboardItem];

    [self.streamMenu addItem:[NSMenuItem separatorItem]];

    // NSDictionary *prefs = [SettingsClass getSettingsFor:self.app.host.uuid]; // Already defined above

    // 二级：窗口
    NSMenuItem *windowItem = [[NSMenuItem alloc] initWithTitle:MLString(@"Window", nil) action:nil keyEquivalent:@""];
    setSymbol(windowItem, @"macwindow");
    NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:MLString(@"Window", nil)];

    BOOL isFullscreen = [self isWindowFullscreen];
    BOOL isBorderless = ((self.view.window.styleMask & NSWindowStyleMaskTitled) == 0) && !isFullscreen;
    BOOL isWindowed = !isFullscreen && !isBorderless;

    NSMenuItem *windowedItem = [[NSMenuItem alloc] initWithTitle:MLString(@"Windowed", nil) action:@selector(switchToWindowedMode:) keyEquivalent:@""];
    windowedItem.target = self;
    windowedItem.state = isWindowed ? NSControlStateValueOn : NSControlStateValueOff;
    setSymbol(windowedItem, @"macwindow");
    [windowMenu addItem:windowedItem];

    NSMenuItem *fullscreenItem = [[NSMenuItem alloc] initWithTitle:MLString(@"Fullscreen", nil) action:@selector(switchToFullscreenMode:) keyEquivalent:@"f"];
    fullscreenItem.keyEquivalentModifierMask = NSEventModifierFlagControl | NSEventModifierFlagCommand;
    fullscreenItem.target = self;
    fullscreenItem.state = isFullscreen ? NSControlStateValueOn : NSControlStateValueOff;
    setSymbol(fullscreenItem, @"arrow.up.left.and.arrow.down.right");
    [windowMenu addItem:fullscreenItem];

    NSMenuItem *borderlessItem = [[NSMenuItem alloc] initWithTitle:MLString(@"Borderless Windowed", nil) action:@selector(switchToBorderlessMode:) keyEquivalent:@""];
    borderlessItem.target = self;
    borderlessItem.state = isBorderless ? NSControlStateValueOn : NSControlStateValueOff;
    setSymbol(borderlessItem, @"rectangle.dashed");
    [windowMenu addItem:borderlessItem];

    [windowMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *toggleBallItem = [[NSMenuItem alloc] initWithTitle:MLString(@"Show Fullscreen Control Ball", nil) action:@selector(toggleFullscreenControlBallFromMenu:) keyEquivalent:@""];
    [self applyShortcut:[self streamShortcutForAction:MLShortcutActionToggleFullscreenControlBall] toMenuItem:toggleBallItem];
    toggleBallItem.target = self;
    toggleBallItem.state = self.hideFullscreenControlBall ? NSControlStateValueOff : NSControlStateValueOn;
    setSymbol(toggleBallItem, @"dot.circle.and.hand.point.up.left.fill");
    [windowMenu addItem:toggleBallItem];

    [windowMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *detailsItem = [[NSMenuItem alloc] initWithTitle:MLString(@"Connection Details", nil) action:@selector(toggleOverlay) keyEquivalent:@""];
    [self applyShortcut:[self streamShortcutForAction:MLShortcutActionTogglePerformanceOverlay] toMenuItem:detailsItem];
    detailsItem.target = self;
    detailsItem.state = self.overlayContainer ? NSControlStateValueOn : NSControlStateValueOff;
    setSymbol(detailsItem, @"gauge.with.dots.needle.33percent");
    [windowMenu addItem:detailsItem];

    windowItem.submenu = windowMenu;
    [self.streamMenu addItem:windowItem];

    // 二级：屏幕（分辨率/帧率）
    NSMenuItem *monitorItem = [[NSMenuItem alloc] initWithTitle:MLString(@"Display", nil) action:nil keyEquivalent:@""];
    setSymbol(monitorItem, @"display");
    NSMenu *monitorMenu = [[NSMenu alloc] initWithTitle:MLString(@"Display", nil)];

    // 1. Follow Monitor
    CGSize refreshLocalSize = CGSizeZero;
    if ([self.view.window screen]) {
        NSRect screenFrame = [self.view.window screen].frame;
        CGFloat scale = [self.view.window screen].backingScaleFactor;
        refreshLocalSize = CGSizeMake(screenFrame.size.width * scale, screenFrame.size.height * scale);
    }
    
    NSString *matchDisplayTitle = MLString(@"Match Display", nil);
    if (refreshLocalSize.width > 0 && refreshLocalSize.height > 0) {
        matchDisplayTitle = [NSString stringWithFormat:MLString(@"Match Display (%.0fx%.0f)", nil), refreshLocalSize.width, refreshLocalSize.height];
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
    NSMenuItem *customItem = [[NSMenuItem alloc] initWithTitle:MLString(@"Custom…", nil) action:@selector(selectCustomResolutionFromMenu:) keyEquivalent:@""];
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
        NSString *customTitle = [NSString stringWithFormat:MLString(@"Current (Custom): %dx%d", nil), currentRes.width, currentRes.height];
        NSMenuItem *currentItem = [[NSMenuItem alloc] initWithTitle:customTitle action:nil keyEquivalent:@""];
        currentItem.state = NSControlStateValueOn;
        [monitorMenu addItem:currentItem];
    }

    [monitorMenu addItem:[NSMenuItem separatorItem]];

    // 5. Frame Rate Submenu
    NSMenuItem *fpsSubItem = [[NSMenuItem alloc] initWithTitle:MLString(@"Frame Rate", nil) action:nil keyEquivalent:@""];
    NSMenu *fpsSubMenu = [[NSMenu alloc] initWithTitle:MLString(@"Frame Rate", nil)];
    
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
         NSString *title = [NSString stringWithFormat:MLString(@"Current: %d FPS", nil), currentFps];
         NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
         item.state = NSControlStateValueOn;
         [fpsSubMenu addItem:item];
    }

    [fpsSubMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *customFpsItem = [[NSMenuItem alloc] initWithTitle:MLString(@"Custom…", nil) action:@selector(selectCustomFpsFromMenu:) keyEquivalent:@""];
    customFpsItem.target = self;
    [fpsSubMenu addItem:customFpsItem];
    
    fpsSubItem.submenu = fpsSubMenu;
    [monitorMenu addItem:fpsSubItem];

    NSMenuItem *displayScaleItem = [self remoteDisplayScaleMenuItem];
    if (displayScaleItem != nil) {
        [monitorMenu addItem:displayScaleItem];
    }

    monitorItem.submenu = monitorMenu;
    [self.streamMenu addItem:monitorItem];

    // 二级：画质（码率）
    NSMenuItem *qualityItem = [[NSMenuItem alloc] initWithTitle:MLString(@"Quality", nil) action:nil keyEquivalent:@""];
    setSymbol(qualityItem, @"sparkles");
    NSMenu *qualityMenu = [[NSMenu alloc] initWithTitle:MLString(@"Quality", nil)];

    NSMenuItem *bitrateHeader = [[NSMenuItem alloc] initWithTitle:MLString(@"Bitrate", nil) action:nil keyEquivalent:@""];
    bitrateHeader.enabled = NO;
    [qualityMenu addItem:bitrateHeader];

    BOOL autoAdjust = prefs ? [prefs[@"autoAdjustBitrate"] boolValue] : YES;
    NSNumber *customBitrate = prefs[@"customBitrate"]; // Kbps
    NSNumber *fallbackBitrate = prefs[@"bitrate"]; // Kbps
    NSInteger selectedKbps = customBitrate ? customBitrate.integerValue : (fallbackBitrate ? fallbackBitrate.integerValue : 0);

    NSMenuItem *autoBitrateItem = [[NSMenuItem alloc] initWithTitle:MLString(@"Automatic", nil) action:@selector(selectBitrateFromMenu:) keyEquivalent:@""];
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

    NSMenuItem *customBitrateItem = [[NSMenuItem alloc] initWithTitle:MLString(@"Custom", nil) action:nil keyEquivalent:@""];
    customBitrateItem.state = isCustomMode ? NSControlStateValueOn : NSControlStateValueOff;
    setSymbol(customBitrateItem, @"slider.horizontal.3");

    // 三级菜单：自定义码率
    NSMenu *customMenu = [[NSMenu alloc] initWithTitle:MLString(@"Custom", nil)];

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
    bitrateLabel.stringValue = MLString(@"Bitrate", nil);
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
    applyButton.title = MLString(@"Apply", nil);
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
    NSMenuItem *audioItem = [[NSMenuItem alloc] initWithTitle:MLString(@"Audio", nil) action:nil keyEquivalent:@""];
    setSymbol(audioItem, @"speaker.wave.2");
    NSMenu *audioMenu = [[NSMenu alloc] initWithTitle:MLString(@"Audio", nil)];

    NSView *volView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 240, 28)];
    NSTextField *volLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(10, 6, 42, 16)];
    volLabel.bezeled = NO;
    volLabel.drawsBackground = NO;
    volLabel.editable = NO;
    volLabel.selectable = NO;
    volLabel.font = [NSFont systemFontOfSize:12 weight:NSFontWeightRegular];
    volLabel.textColor = [NSColor labelColor];
    volLabel.stringValue = MLString(@"Volume", nil);
    [volView addSubview:volLabel];

    // A new slider for every menu build: the old one belongs to a menu that may still be on screen
    // (the controller panel keeps the levels it opened), and moving one view between menus took its
    // tracking state and its place in that menu with it.
    NSSlider *volumeSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(58, 4, 170, 20)];
    volumeSlider.minValue = 0.0;
    volumeSlider.maxValue = 1.0;
    volumeSlider.target = self;
    volumeSlider.action = @selector(handleVolumeSliderChanged:);
    volumeSlider.continuous = YES;
    // A level from a drag that is still waiting to be saved must not be read back as the old one.
    [self flushPendingVolumeLevel];
    volumeSlider.doubleValue = [SettingsClass volumeLevelFor:self.app.host.uuid];
    self.menuVolumeSlider = volumeSlider;
    [volView addSubview:volumeSlider];

    NSMenuItem *volSliderItem = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    volSliderItem.view = volView;
    [audioMenu addItem:volSliderItem];

    // Bitstream passthrough: the output device applies the volume, the slider only mutes at 0.
    // Decided when the menu is built (it is rebuilt every time it is opened) instead of hiding and
    // showing an item while the menu is up.
    if ([self.streamMan.connection audioPassthroughActive]) {
        NSMenuItem *passthroughVolumeNote = [[NSMenuItem alloc] initWithTitle:MLString(@"Volume is controlled on the output device", nil)
                                                                       action:nil
                                                                keyEquivalent:@""];
        passthroughVolumeNote.enabled = NO;
        [audioMenu addItem:passthroughVolumeNote];
    }

    [audioMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *audioOutputItem = [[NSMenuItem alloc] initWithTitle:MLString(@"Audio Output", nil) action:nil keyEquivalent:@""];
    setSymbol(audioOutputItem, @"hifispeaker");
    NSMenu *audioOutputMenu = [[NSMenu alloc] initWithTitle:MLString(@"Audio Output", nil)];
    audioOutputMenu.autoenablesItems = NO;
    audioOutputMenu.delegate = self;
    self.audioOutputMenu = audioOutputMenu;
    [self populateAudioOutputMenu:audioOutputMenu];
    audioOutputItem.submenu = audioOutputMenu;
    [audioMenu addItem:audioOutputItem];

    audioItem.submenu = audioMenu;
    [self.streamMenu addItem:audioItem];

    // 二级：网络（连接方式）
    NSMenuItem *networkItem = [[NSMenuItem alloc] initWithTitle:MLString(@"Network", nil) action:nil keyEquivalent:@""];
    setSymbol(networkItem, @"network");
    NSMenu *networkMenu = [[NSMenu alloc] initWithTitle:MLString(@"Network", nil)];

    NSString *method = prefs[@"connectionMethod"] ?: @"Auto";
    NSMenuItem *autoItem = [[NSMenuItem alloc] initWithTitle:MLString(@"Automatic", nil) action:@selector(selectConnectionMethodFromMenu:) keyEquivalent:@""];
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

    // 二级：主机命令（/applist SuperCmds，由主机对当前运行的应用解析）
    if (self.app.superCommands.count > 0) {
        NSMenuItem *hostCommandsItem = [[NSMenuItem alloc] initWithTitle:MLString(@"Host Commands", nil) action:nil keyEquivalent:@""];
        setSymbol(hostCommandsItem, @"terminal");
        NSMenu *hostCommandsMenu = [[NSMenu alloc] initWithTitle:MLString(@"Host Commands", nil)];
        for (MLAppSuperCommand *command in self.app.superCommands) {
            NSMenuItem *commandItem = [[NSMenuItem alloc] initWithTitle:command.name action:@selector(runSuperCommandFromMenu:) keyEquivalent:@""];
            commandItem.target = self;
            commandItem.representedObject = command;
            [hostCommandsMenu addItem:commandItem];
        }
        hostCommandsItem.submenu = hostCommandsMenu;
        [self.streamMenu addItem:hostCommandsItem];
    }

    // 二级：日志（显示/复制）
    NSMenuItem *logsItem = [[NSMenuItem alloc] initWithTitle:MLString(@"Logs", nil) action:nil keyEquivalent:@""];
    setSymbol(logsItem, @"text.justify.left");
    NSMenu *logsMenu = [[NSMenu alloc] initWithTitle:MLString(@"Logs", nil)];

    NSMenuItem *toggleLogsItem = [[NSMenuItem alloc] initWithTitle:MLString(@"Show Logs", nil) action:@selector(toggleLogOverlayFromMenu:) keyEquivalent:@""];
    toggleLogsItem.target = self;
    toggleLogsItem.state = self.logOverlayContainer ? NSControlStateValueOn : NSControlStateValueOff;
    setSymbol(toggleLogsItem, @"text.justify.left");
    [logsMenu addItem:toggleLogsItem];

    NSMenuItem *copyLogsItem = [[NSMenuItem alloc] initWithTitle:MLString(@"Copy Log", nil) action:@selector(copyLogsFromMenu:) keyEquivalent:@""];
    copyLogsItem.target = self;
    setSymbol(copyLogsItem, @"doc.on.doc");
    [logsMenu addItem:copyLogsItem];

    logsItem.submenu = logsMenu;
    [self.streamMenu addItem:logsItem];

    // 二级：更多（把重连/退出放底部）
    NSMenuItem *moreItem = [[NSMenuItem alloc] initWithTitle:MLString(@"More", nil) action:nil keyEquivalent:@""];
    setSymbol(moreItem, @"ellipsis.circle");
    NSMenu *moreMenu = [[NSMenu alloc] initWithTitle:MLString(@"More", nil)];

    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:MLString(@"Close and Quit App", nil) action:@selector(performCloseAndQuitApp:) keyEquivalent:@""];
    [self applyShortcut:[self streamShortcutForAction:MLShortcutActionCloseAndQuitApp] toMenuItem:quitItem];
    quitItem.target = self;
    setSymbol(quitItem, @"power");
    [moreMenu addItem:quitItem];

    moreItem.submenu = moreMenu;
    [self.streamMenu addItem:moreItem];

    // 一级底部：退出
    [self.streamMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *disconnectItem = [[NSMenuItem alloc] initWithTitle:MLString(@"Exit Stream", nil) action:@selector(performCloseStreamWindow:) keyEquivalent:@""];
    [self applyShortcut:[self streamShortcutForAction:MLShortcutActionDisconnectStream] toMenuItem:disconnectItem];
    disconnectItem.target = self;
    setSymbol(disconnectItem, @"xmark.circle");
    [self.streamMenu addItem:disconnectItem];
}

#pragma mark - Remote display scale

// Asks the host which display scales it offers once the stream is up, for the control center.
// The host's scale is not changed here. Runs in the background; the stream never waits for it.
- (void)startRemoteDisplayScaleForCurrentSession {
    StreamConfiguration *config = self.streamMan.streamConfiguration;
    // Only Foundation Sunshine offers the display scale routes.
    if (config == nil || !config.foundationHost || config.host.length == 0) {
        return;
    }

    MLRemoteDisplayScale *scale = self.remoteDisplayScale;
    if (scale == nil) {
        scale = [[MLRemoteDisplayScale alloc] initWithHostAddress:config.host
                                                       serverCert:config.serverCert];
        self.remoteDisplayScale = scale;
    } else {
        [scale updateHostAddress:config.host serverCert:config.serverCert];
    }

    NSUInteger generation = self.activeStreamGeneration;
    __weak typeof(self) weakSelf = self;
    scale.optionsDidChangeHandler = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf != nil && strongSelf.activeStreamGeneration == generation) {
            [strongSelf remoteDisplayScaleOptionsDidChange];
        }
    };
    [scale beginSessionWithTargetDisplay:config.sunshineTargetDisplayName ?: @""];
}

// Stream over: the control center has nothing left to ask the host. The host keeps its scale.
- (void)endRemoteDisplayScaleSession {
    MLRemoteDisplayScale *scale = nil;
    @synchronized (self) {
        scale = self.remoteDisplayScale;
        self.remoteDisplayScale = nil;
    }
    if (scale == nil) {
        return;
    }
    [scale endSession];
}

- (void)presentRemoteDisplayScaleOutcome:(NSDictionary<NSString *, id> *)outcome {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self presentRemoteDisplayScaleOutcome:outcome];
        });
        return;
    }
    if ([outcome[@"ok"] boolValue]) {
        NSString *message = [NSString stringWithFormat:MLString(@"Display scale set to %d%%", nil),
                             [outcome[@"percent"] intValue]];
        if ([outcome[@"restartRequired"] boolValue]) {
            message = [NSString stringWithFormat:@"%@. %@", message,
                       MLString(@"Some apps may need to restart to pick up the new scale", nil)];
            [self showNotification:message forSeconds:4.5];
        } else {
            [self showNotification:message];
        }
        return;
    }

    NSString *errorCode = [outcome[@"errorCode"] isKindOfClass:[NSString class]] ? outcome[@"errorCode"] : @"";
    NSString *key = @"Couldn't change the display scale";
    if ([errorCode isEqualToString:@"unsupported_scale"]) {
        key = @"The host does not support that display scale";
    } else if ([errorCode isEqualToString:@"permission_denied"]) {
        key = @"The host refused to change the display scale";
    } else if ([errorCode isEqualToString:@"display_not_found"]) {
        key = @"The host display for the scale was not found";
    }
    [self showNotification:MLString(key, nil) forSeconds:3.0];
}

// "Display Scale" submenu of the Display menu. Built from what the host reported when the
// stream started and refilled in place (see -menuNeedsUpdate: and the options handler) when
// a newer answer arrives, so an open menu never stays on a stale placeholder.
- (NSMenuItem *)remoteDisplayScaleMenuItem {
    MLRemoteDisplayScale *scale = self.remoteDisplayScale;
    if (scale == nil) {
        return nil;
    }

    NSString *title = MLString(@"Display Scale", nil);
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
    MLStreamMenuSetSymbol(item, @"textformat.size");
    NSMenu *submenu = [[NSMenu alloc] initWithTitle:title];
    submenu.autoenablesItems = NO;
    submenu.delegate = self;
    self.displayScaleMenu = submenu;
    [self populateRemoteDisplayScaleMenu:submenu];
    [scale refreshOptionsIfStale];

    item.submenu = submenu;
    return item;
}

// Brings the Display Scale submenu in line with the current snapshot, in place when the choices
// are the same (see MLSyncMenuItems). Main thread.
- (void)populateRemoteDisplayScaleMenu:(NSMenu *)submenu {
    NSMutableArray<NSDictionary<NSString *, id> *> *specs = [NSMutableArray array];
    void (^addNote)(NSString *) = ^(NSString *text) {
        [specs addObject:@{ @"title": text, @"enabled": @NO, @"state": @(NSControlStateValueOff) }];
    };

    MLRemoteDisplayScale *scale = self.remoteDisplayScale;
    if (scale == nil) {
        addNote(MLString(@"Display scale is unavailable", nil));
    } else {
        // Read the "still asking" flag before the support state: the query clears the flag only
        // after it has stored its result, so a NO here means the support value below is final.
        BOOL awaiting = scale.awaitingFirstQuery;
        MLRemoteDisplayScaleSupport support = scale.support;

        if (support == MLRemoteDisplayScaleSupportAvailable) {
            NSInteger current = scale.currentPercent;
            NSInteger recommended = scale.recommendedPercent;
            for (NSNumber *percent in scale.supportedPercents) {
                BOOL isRecommended = recommended > 0 && percent.integerValue == recommended;
                NSString *percentTitle = isRecommended
                    ? [NSString stringWithFormat:MLString(@"%d%% (Recommended)", nil), (int)percent.integerValue]
                    : [NSString stringWithFormat:@"%ld%%", (long)percent.integerValue];
                [specs addObject:@{
                    @"title": percentTitle,
                    @"action": NSStringFromSelector(@selector(selectRemoteDisplayScaleFromMenu:)),
                    @"rep": percent,
                    @"state": @(percent.integerValue == current ? NSControlStateValueOn : NSControlStateValueOff),
                }];
            }
            if (specs.count == 0) {
                addNote(MLString(@"Display scale is unavailable", nil));
            }
        } else if (support == MLRemoteDisplayScaleSupportUnavailable) {
            addNote(MLString(@"This host does not support display scaling", nil));
        } else if (awaiting) {
            addNote(MLString(@"Loading…", nil));
        } else {
            // The last query failed in a way that may pass; the next refresh retries.
            addNote(MLString(@"Display scale is unavailable", nil));
        }
    }
    MLSyncMenuItems(submenu, specs, self);
}

- (void)remoteDisplayScaleOptionsDidChange {
    NSMenu *menu = self.displayScaleMenu;
    if (menu != nil && !self.stopStreamInProgress) {
        [self populateRemoteDisplayScaleMenu:menu];
    }
}

#pragma mark - NSMenuDelegate

// Called when one of the control center submenus below is about to open (and by the
// controller panel through -update): refill it so it never shows what it knew when the
// whole menu was built.
- (void)menuNeedsUpdate:(NSMenu *)menu {
    if (menu == self.displayScaleMenu) {
        [self populateRemoteDisplayScaleMenu:menu];
        [self.remoteDisplayScale refreshOptionsIfStale];
    } else if (menu == self.audioOutputMenu) {
        [self populateAudioOutputMenu:menu];
    }
}

// A choice here is the user changing the host's scale by hand: it is applied now and stays on the
// host after the stream. It is not saved anywhere and not put back at the end of the stream.
- (void)selectRemoteDisplayScaleFromMenu:(NSMenuItem *)sender {
    NSNumber *percent = [sender.representedObject isKindOfClass:[NSNumber class]] ? sender.representedObject : nil;
    MLRemoteDisplayScale *scale = self.remoteDisplayScale;
    if (percent == nil || scale == nil || percent.integerValue <= 0) {
        return;
    }
    __weak typeof(self) weakSelf = self;
    [scale applyManualPercent:percent.integerValue completion:^(NSDictionary<NSString *, id> *outcome) {
        [weakSelf presentRemoteDisplayScaleOutcome:outcome];
    }];
}

- (void)handleToggleFullscreenFromMenu:(id)sender {
    [self.view.window toggleFullScreen:self];
}

- (void)runSuperCommandFromMenu:(NSMenuItem *)sender {
    MLAppSuperCommand *command = sender.representedObject;
    if (![command isKindOfClass:[MLAppSuperCommand class]]) {
        return;
    }

    TemporaryHost *host = self.app.host;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        HttpManager *hMan = [[HttpManager alloc] initWithHost:host.activeAddress uniqueId:[IdManager getUniqueId] serverCert:host.serverCert];
        BOOL ok = [hMan executeSuperCommandWithId:command.commandId];
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *format = ok ? MLString(@"Host Command Sent: %@", nil) : MLString(@"Host Command Failed: %@", nil);
            [self showNotification:[NSString stringWithFormat:format, command.name]];
        });
    });
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
    alert.messageText = MLString(@"Custom Resolution and Frame Rate", nil);
    alert.informativeText = MLString(@"Enter the resolution (width x height) and frame rate (FPS).\nA value of 0 lets the host decide and is not recommended.", nil);
    [alert addButtonWithTitle:MLString(@"OK", nil)];
    [alert addButtonWithTitle:MLString(@"Cancel", nil)];
    
    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 200, 100)];
    
    // Width
    NSTextField *widthLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 75, 50, 20)];
    widthLabel.stringValue = MLString(@"Width:", nil);
    widthLabel.bezeled = NO;
    widthLabel.drawsBackground = NO;
    widthLabel.alignment = NSTextAlignmentRight;
    [container addSubview:widthLabel];
    
    NSTextField *widthField = [[NSTextField alloc] initWithFrame:NSMakeRect(55, 75, 60, 22)];
    widthField.placeholderString = @"1920";
    [container addSubview:widthField];
    
    // Height
    NSTextField *heightLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 45, 50, 20)];
    heightLabel.stringValue = MLString(@"Height:", nil);
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
            // Zero means "let the host decide", which only a new session can do.
            BOOL appliedLive = w > 0 && h > 0 && f > 0;
            if (appliedLive && (w != res.width || h != res.height)) {
                appliedLive = [self applyLiveResolutionWidth:w height:h];
            }
            if (appliedLive && f != currentFps) {
                appliedLive = [self applyLiveFramerate:f];
            }
            if (appliedLive) {
                [self rebuildStreamMenu];
                return;
            }
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
    if ([self applyLiveResolutionWidth:(int)size.width height:(int)size.height]) {
        [self rebuildStreamMenu];
        return;
    }
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
    if ([self applyLiveFramerate:newFps]) {
        [self rebuildStreamMenu];
        return;
    }
    [self attemptReconnectWithReason:@"framerate-changed"];
}

- (void)selectCustomFpsFromMenu:(id)sender {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = MLString(@"Custom Frame Rate", nil);
    alert.informativeText = MLString(@"Enter the desired frame rate (FPS).", nil);
    [alert addButtonWithTitle:MLString(@"OK", nil)];
    [alert addButtonWithTitle:MLString(@"Cancel", nil)];
    
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
            if (f > 0 && [self applyLiveFramerate:f]) {
                [self rebuildStreamMenu];
                return;
            }
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
    NSInteger liveKbps = [rep isKindOfClass:[NSNumber class]] ? [(NSNumber *)rep integerValue]
                                                                : [self automaticBitrateKbpsForRunningStream];
    if ([self applyLiveBitrateKbps:liveKbps]) {
        [self rebuildStreamMenu];
        return;
    }
    [self attemptReconnectWithReason:@"bitrate-changed"]; 
}

// Runs for every event of a drag. Only the cheap part happens here: the new gain goes straight
// to the running stream. Saving it (a settings encode and write, then a notification that makes
// the stream re-read its settings and look up the host) waits until the drag ends, or until the
// slider has been still for a moment (keyboard and controller steps never send a mouse-up).
- (void)handleVolumeSliderChanged:(NSSlider *)sender {
    double level = MIN(1.0, MAX(0.0, sender.doubleValue));
    [self.streamMan.connection setAudioVolumeLevel:(float)level];
    self.menuVolumePendingLevel = level;
    self.menuVolumeHasPendingLevel = YES;

    if (NSApp.currentEvent.type == NSEventTypeLeftMouseUp) {
        // After the slider's own tracking loop has finished, not inside it.
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf flushPendingVolumeLevel];
        });
        return;
    }

    [self.menuVolumePersistTimer invalidate];
    // Common modes: an open menu tracks in the event-tracking mode, where default-mode timers do not fire.
    NSTimer *timer = [NSTimer timerWithTimeInterval:0.2 target:self selector:@selector(flushPendingVolumeLevel) userInfo:nil repeats:NO];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    self.menuVolumePersistTimer = timer;
}

- (void)flushPendingVolumeLevel {
    [self.menuVolumePersistTimer invalidate];
    self.menuVolumePersistTimer = nil;
    if (!self.menuVolumeHasPendingLevel) {
        return;
    }
    self.menuVolumeHasPendingLevel = NO;
    NSString *hostUUID = self.app.host.uuid;
    if (hostUUID.length > 0) {
        [SettingsClass setVolumeLevel:(CGFloat)self.menuVolumePendingLevel for:hostUUID];
    }
}

#pragma mark - Audio output device

static NSString *MLAudioDeviceString(AudioDeviceID device, AudioObjectPropertySelector selector) {
    CFStringRef value = NULL;
    UInt32 size = sizeof(value);
    AudioObjectPropertyAddress address = { selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &value) != noErr || value == NULL) {
        return nil;
    }
    return CFBridgingRelease(value);
}

static BOOL MLAudioDeviceFlag(AudioDeviceID device, AudioObjectPropertySelector selector, BOOL fallback) {
    UInt32 value = 0;
    UInt32 size = sizeof(value);
    AudioObjectPropertyAddress address = { selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &value) != noErr) {
        return fallback;
    }
    return value != 0;
}

static UInt32 MLAudioDeviceOutputChannels(AudioDeviceID device) {
    AudioObjectPropertyAddress address = { kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(device, &address, 0, NULL, &size) != noErr || size < sizeof(AudioBufferList)) {
        return 0;
    }
    AudioBufferList *list = (AudioBufferList *)malloc(size);
    if (list == NULL) {
        return 0;
    }
    UInt32 channels = 0;
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, list) == noErr) {
        for (UInt32 i = 0; i < list->mNumberBuffers; i++) {
            channels += list->mBuffers[i].mNumberChannels;
        }
    }
    free(list);
    return channels;
}

// Live output devices (output channels, alive, not hidden) as @{ @"id": AudioDeviceID, @"name": NSString }.
static NSArray<NSDictionary<NSString *, id> *> *MLAudioOutputDevices(void) {
    AudioObjectPropertyAddress address = { kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address, 0, NULL, &size) != noErr || size < sizeof(AudioDeviceID)) {
        return @[];
    }
    NSMutableData *data = [NSMutableData dataWithLength:size];
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, data.mutableBytes) != noErr) {
        return @[];
    }
    const AudioDeviceID *devices = (const AudioDeviceID *)data.bytes;
    NSUInteger count = size / sizeof(AudioDeviceID);
    NSMutableArray<NSDictionary<NSString *, id> *> *result = [NSMutableArray array];
    for (NSUInteger i = 0; i < count; i++) {
        AudioDeviceID device = devices[i];
        if (MLAudioDeviceOutputChannels(device) == 0 ||
            !MLAudioDeviceFlag(device, kAudioDevicePropertyDeviceIsAlive, NO) ||
            MLAudioDeviceFlag(device, kAudioDevicePropertyIsHidden, NO)) {
            continue;
        }
        NSString *name = MLAudioDeviceString(device, kAudioObjectPropertyName) ?: MLString(@"Unknown Output", nil);
        [result addObject:@{ @"id": @(device), @"name": name }];
    }
    return result;
}

// Fills the Audio Output submenu from the devices that exist right now. Main thread.
// The choice is the app's own (the same setting as Output Device in the audio settings): the
// stream plays on that device and the system output stays as it is.
- (void)populateAudioOutputMenu:(NSMenu *)menu {
    NSString *chosenUID = [SettingsClass audioOutputDeviceUID];
    const BOOL chosenAlive = chosenUID.length > 0 &&
        [MLAudioBitstreamOutput deviceForUID:chosenUID] != kAudioObjectUnknown;
    NSMutableArray<NSDictionary<NSString *, id> *> *specs = [NSMutableArray array];
    [specs addObject:@{
        @"title": MLString(@"Output Device Follow System", nil),
        @"action": NSStringFromSelector(@selector(selectAudioOutputFromMenu:)),
        @"rep": @"",
        @"state": @(chosenAlive ? NSControlStateValueOff : NSControlStateValueOn),
    }];
    for (NSDictionary<NSString *, id> *entry in MLAudioOutputDevices()) {
        NSString *uid = MLAudioDeviceString((AudioDeviceID)[entry[@"id"] unsignedIntValue], kAudioDevicePropertyDeviceUID);
        if (uid.length == 0) {
            continue;
        }
        [specs addObject:@{
            @"title": entry[@"name"],
            @"action": NSStringFromSelector(@selector(selectAudioOutputFromMenu:)),
            @"rep": uid,
            @"state": @((chosenAlive && [uid isEqualToString:chosenUID]) ? NSControlStateValueOn : NSControlStateValueOff),
        }];
    }
    MLSyncMenuItems(menu, specs, self);
}

// Sets the device the stream plays on and starts its output again there (which may also try
// passthrough again). An empty UID is the system output.
- (void)selectAudioOutputFromMenu:(NSMenuItem *)sender {
    NSString *uid = [sender.representedObject isKindOfClass:[NSString class]] ? sender.representedObject : nil;
    if (uid == nil) {
        return;
    }
    [SettingsClass setAudioOutputDeviceUID:uid];
    Log(LOG_I, @"[audio] Output device chosen from the control center: %@", sender.title);
    [self.streamMan.connection restartAudioOutputForDeviceChange];
    [self showNotification:[NSString stringWithFormat:MLString(@"Audio output: %@", nil), sender.title]];
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
    [self scheduleLiveBitrateApplyKbps:kbps];
}

// Dragging the slider emits many values; only the last one is sent to the host.
- (void)scheduleLiveBitrateApplyKbps:(NSInteger)kbps {
    NSUInteger token = ++self.liveBitrateDebounceToken;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (token != self.liveBitrateDebounceToken) {
            return;
        }
        [self applyLiveBitrateKbps:kbps];
    });
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
    [self scheduleLiveBitrateApplyKbps:kbps];
}

- (void)handleBitrateApplyClicked:(NSButton *)sender {
    // 优先在线调整，主机不支持时再重连以应用新码率
    ++self.liveBitrateDebounceToken;
    NSDictionary *prefs = [SettingsClass getSettingsFor:self.app.host.uuid];
    NSInteger customKbps = [prefs[@"customBitrate"] integerValue];
    if (customKbps > 0 && [self applyLiveBitrateKbps:customKbps]) {
        [self rebuildStreamMenu];
        return;
    }
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
