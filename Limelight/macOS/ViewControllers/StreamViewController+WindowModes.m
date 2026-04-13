//
//  StreamViewController+WindowModes.m
//  Moonlight for macOS
//

#import "StreamViewController_Internal.h"

@implementation StreamViewController (WindowModes)

- (BOOL)handleKeyboardTranslationForCurrentCloseEventAllowingLocalAction:(NSString *)allowedLocalAction {
    NSEvent *event = NSApp.currentEvent;
    if (event == nil || event.type != NSEventTypeKeyDown) {
        return NO;
    }

    if (allowedLocalAction.length > 0) {
        StreamShortcut *localShortcut = [self streamShortcutForAction:allowedLocalAction];
        if (localShortcut != nil && [self event:event matchesShortcut:localShortcut]) {
            Log(LOG_D, @"[diag] performClose preserved local shortcut action=%@ event=%@",
                allowedLocalAction,
                MLDisconnectEventSummary(event));
            return NO;
        }
    }

    KeyboardTranslationRule *rule = [self keyboardTranslationRuleMatchingEvent:event];
    if (rule == nil) {
        if (event.keyCode == kVK_ANSI_W) {
            Log(LOG_D, @"[diag] performClose saw W without translation match: %@", MLDisconnectEventSummary(event));
        }
        return NO;
    }

    if (rule.outputKind == KeyboardTranslationOutputKindLocalAction &&
        allowedLocalAction.length > 0 &&
        [rule.localAction isEqualToString:allowedLocalAction]) {
        return NO;
    }

    Log(LOG_I, @"[diag] performClose rerouted to keyboard translation: %@", MLDisconnectEventSummary(event));
    return [self handleKeyboardTranslationRuleForEvent:event];
}

- (void)prepareStreamWindowChromeForStreamingIfNeeded {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self prepareStreamWindowChromeForStreamingIfNeeded];
        });
        return;
    }
}

- (void)restoreStreamWindowChromeIfNeeded {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self restoreStreamWindowChromeIfNeeded];
        });
        return;
    }
}

- (void)enterBorderlessPresentationOptionsIfNeeded {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self enterBorderlessPresentationOptionsIfNeeded];
        });
        return;
    }
    if (!self.savedPresentationOptionsValid) {
        self.savedPresentationOptions = [NSApp presentationOptions];
        self.savedPresentationOptionsValid = YES;
    }

    NSApplicationPresentationOptions opts = [NSApp presentationOptions];
    opts |= (NSApplicationPresentationHideDock | NSApplicationPresentationHideMenuBar);
    [NSApp setPresentationOptions:opts];
}

- (void)restorePresentationOptionsIfNeeded {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self restorePresentationOptionsIfNeeded];
        });
        return;
    }
    if (!self.savedPresentationOptionsValid) {
        return;
    }
    [NSApp setPresentationOptions:self.savedPresentationOptions];
    self.savedPresentationOptionsValid = NO;
}

- (NSApplicationPresentationOptions)window:(NSWindow *)window willUseFullScreenPresentationOptions:(NSApplicationPresentationOptions)proposedOptions {
    NSApplicationPresentationOptions options = proposedOptions;
    options &= ~(NSApplicationPresentationAutoHideDock | NSApplicationPresentationAutoHideMenuBar);
    options |= (NSApplicationPresentationHideDock | NSApplicationPresentationHideMenuBar);
    return options;
}

- (IBAction)performClose:(id)sender {
    if ([self handleKeyboardTranslationForCurrentCloseEventAllowingLocalAction:KeyboardTranslationProfile.localActionShowDisconnectOptions]) {
        return;
    }

    Log(LOG_I, @"[diag] performClose invoked: sender=%@ event=%@",
        sender ? NSStringFromClass([sender class]) : @"(null)",
        MLDisconnectEventSummary(NSApp.currentEvent));
    [self uncaptureMouseWithCode:@"MUC301" reason:@"perform-close"];
    if (self.reconnectInProgress || self.stopStreamInProgress) {
        self.pendingDisconnectSource = self.reconnectInProgress ? @"disconnect-while-reconnecting" : @"disconnect-while-stopping";
        [self performCloseStreamWindow:nil];
        return;
    }
    
    NSAlert *alert = [[NSAlert alloc] init];
    
    alert.alertStyle = NSAlertStyleInformational;
    alert.messageText = MLString(@"Disconnect Alert", @"Disconnect Alert");

    [alert addButtonWithTitle:MLString(@"Disconnect from Stream", @"Disconnect from Stream")];
    [alert addButtonWithTitle:MLString(@"Close and Quit App", @"Close and Quit App")];
    [alert addButtonWithTitle:MLString(@"Cancel", @"Cancel")];

    [alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse returnCode) {
        switch (returnCode) {
            case NSAlertFirstButtonReturn:
                self.pendingDisconnectSource = @"disconnect-alert-confirmed";
                [self doCommandBySelector:@selector(performCloseStreamWindow:)];
                break;
                
            case NSAlertSecondButtonReturn:
                [self doCommandBySelector:@selector(performCloseAndQuitApp:)];
                break;

            default:
                [self captureMouse];
                break;
        }
    }];
}

- (IBAction)performCloseStreamWindow:(id)sender {
    [self.hidSupport releaseAllModifierKeys];
    NSString *disconnectSource = [self resolvedDisconnectSourceFromSender:sender];
    BOOL shouldCloseWindowImmediately = self.reconnectInProgress || self.stopStreamInProgress;
    Log(LOG_W, @"[diag] Disconnect requested: source=%@ sender=%@ captured=%d reconnect=%d stopInProgress=%d",
        disconnectSource,
        sender ? NSStringFromClass([sender class]) : @"(null)",
        self.isMouseCaptured ? 1 : 0,
        self.reconnectInProgress ? 1 : 0,
        self.stopStreamInProgress ? 1 : 0);
    [self logStreamHealthSummaryWithReason:[NSString stringWithFormat:@"disconnect-request:%@", disconnectSource]];
    [self cancelPendingReconnectForUserExitWithReason:disconnectSource];

    if (shouldCloseWindowImmediately) {
        [self beginStopStreamIfNeededWithReason:@"disconnect-from-stream"];
        NSWindow *w = self.view.window;
        Log(LOG_I, @"performCloseStreamWindow: immediate safe close (style=%llu level=%ld)",
            (unsigned long long)w.styleMask,
            (long)w.level);
        [self requestSafeCloseOfStreamWindow];
        return;
    }

    // In borderless/floating mode, relying on the responder chain can fail to close the window,
    // leaving the last frame stuck. Restore a normal window style and close explicitly.
    // Wait for stream stop to complete before closing window to avoid deadlock.
    __weak typeof(self) weakSelf = self;
    [self beginStopStreamIfNeededWithReason:@"disconnect-from-stream" completion:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }

        NSWindow *w = strongSelf.view.window;
        Log(LOG_I, @"performCloseStreamWindow: safe close (style=%llu level=%ld)", (unsigned long long)w.styleMask, (long)w.level);
        [strongSelf requestSafeCloseOfStreamWindow];
    }];
}

- (IBAction)performCloseAndQuitApp:(id)sender {
    [self.hidSupport releaseAllModifierKeys];
    [self markUserInitiatedDisconnectAndSuppressWarningsForSeconds:5.0 reason:@"close-and-quit"];
    [self cancelPendingReconnectForUserExitWithReason:@"close-and-quit"];

    // First stop the stream, then quit app, then close window and terminate
    __weak typeof(self) weakSelf = self;
    [self beginStopStreamIfNeededWithReason:@"close-and-quit" completion:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }

        // Quit the remote app
        [strongSelf.delegate quitApp:strongSelf.app completion:^(BOOL success) {
            dispatch_async(dispatch_get_main_queue(), ^{
                // Close window and terminate regardless of quit success
                NSWindow *w = strongSelf.view.window;
                if (w) {
                    [strongSelf restorePresentationOptionsIfNeeded];
                    [w close];
                }
            });
        }];
    }];
}

- (IBAction)resizeWindowToActualResulution:(id)sender {
    CGFloat screenScale = [NSScreen mainScreen].backingScaleFactor;
    CGFloat width = (CGFloat)[self.class getResolution].width / screenScale;
    CGFloat height = (CGFloat)[self.class getResolution].height / screenScale;
    [self.view.window setContentSize:NSMakeSize(width, height)];
}


#pragma mark - Helpers

- (void)enableMenuItems:(BOOL)enable {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self enableMenuItems:enable];
        });
        return;
    }

    NSMenu *mainMenu = [NSApplication sharedApplication].mainMenu;
    if (!mainMenu) {
        return;
    }
    NSMenuItem *appMenuItem = [mainMenu itemWithTag:1000];
    NSMenu *appMenu = appMenuItem.submenu;
    if (!appMenu) {
        return;
    }
    appMenu.autoenablesItems = enable;
    NSMenuItem *terminateItem = [self itemWithMenu:appMenu andAction:@selector(terminate:)];
    if (terminateItem) {
        terminateItem.enabled = enable;
    }
}

- (NSString *)displayModeDebugName:(NSInteger)displayMode {
    switch (displayMode) {
        case 1:
            return @"fullscreen";
        case 2:
            return @"borderless";
        default:
            return @"windowed";
    }
}

- (void)logCurrentWindowStateWithContext:(NSString *)context {
    NSWindow *window = self.view.window;
    NSString *screenFrame = window.screen ? NSStringFromRect(window.screen.frame) : @"(nil)";
    NSString *windowFrame = window ? NSStringFromRect(window.frame) : @"(nil)";
    Log(LOG_D, @"[diag] %@: window=%p key=%d main=%d visible=%d occlusion=%lu fullscreen=%d borderless=%d style=%llu level=%ld pending=%ld screenFrame=%@ windowFrame=%@",
        context ?: @"window-state",
        window,
        window.isKeyWindow ? 1 : 0,
        window.isMainWindow ? 1 : 0,
        window.isVisible ? 1 : 0,
        window ? (unsigned long)window.occlusionState : 0,
        [self isWindowFullscreen] ? 1 : 0,
        [self isWindowBorderlessMode] ? 1 : 0,
        window ? (unsigned long long)window.styleMask : 0,
        window ? (long)window.level : 0,
        (long)self.pendingWindowMode,
        screenFrame,
        windowFrame);
}

- (void)applyStartupDisplayMode:(NSInteger)displayMode {
    NSWindow *window = self.view.window;
    if (!window) {
        Log(LOG_W, @"[diag] Startup display mode skipped: window is nil");
        return;
    }

    NSString *modeName = [self displayModeDebugName:displayMode];
    Log(LOG_I, @"[diag] Startup display mode apply begin: mode=%ld (%@)",
        (long)displayMode,
        modeName);
    [self logCurrentWindowStateWithContext:@"startup-display-before"];

    if (displayMode == 1) {
        if (!(window.styleMask & NSWindowStyleMaskFullScreen)) {
            Log(LOG_I, @"[diag] Startup display mode requesting fullscreen toggle");
            [window toggleFullScreen:self];
        } else {
            Log(LOG_I, @"[diag] Startup display mode already fullscreen");
        }
    } else if (displayMode == 2) {
        Log(LOG_I, @"[diag] Startup display mode requesting borderless transition");
        [self switchToBorderlessMode:nil];
    } else {
        if (window.styleMask & NSWindowStyleMaskFullScreen) {
            Log(LOG_I, @"[diag] Startup display mode requesting exit from fullscreen");
            [window toggleFullScreen:self];
        } else {
            Log(LOG_I, @"[diag] Startup display mode stays windowed");
        }
    }

    [self logCurrentWindowStateWithContext:@"startup-display-after-request"];
}

- (void)applyWindowedMode {
    NSWindow *window = self.view.window;
    Log(LOG_I, @"[diag] applyWindowedMode begin");
    [self logCurrentWindowStateWithContext:@"apply-windowed-begin"];
    [self restorePresentationOptionsIfNeeded];

    if (self.savedContentAspectRatioValid) {
        @try {
            window.contentAspectRatio = self.savedContentAspectRatio;
        } @catch (NSException *exception) {
            // ignore
        }
        self.savedContentAspectRatioValid = NO;
    }

    BOOL wasBorderless = (window.styleMask & NSWindowStyleMaskBorderless) != 0;

    NSWindowStyleMask newMask = window.styleMask;
    newMask &= ~NSWindowStyleMaskBorderless;
    newMask |= (NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable);
    [window setStyleMask:newMask];
    [window setLevel:NSNormalWindowLevel];

    [window.contentView setNeedsLayout:YES];
    [self.view setNeedsLayout:YES];
    [window makeFirstResponder:self];
    
    // Restore a reasonable frame. When leaving borderless, don't keep a fullscreen-sized window
    // (it looks like "real fullscreen" and can confuse the responder chain).
    struct Resolution res = [self.class getResolution];
    CGFloat aspectRatio = (res.height > 0) ? ((CGFloat)res.width / (CGFloat)res.height) : (16.0 / 9.0);

    if (wasBorderless) {
        NSScreen *screen = window.screen ?: [NSScreen mainScreen];
        NSRect visible = screen ? screen.visibleFrame : window.frame;
        
        CGFloat targetW = MIN(1280.0, visible.size.width * 0.9);
        CGFloat targetH = targetW / aspectRatio;
        
        if (targetH > visible.size.height * 0.9) {
            targetH = visible.size.height * 0.9;
            targetW = targetH * aspectRatio;
        }

        NSRect target = NSMakeRect(
            NSMidX(visible) - targetW / 2.0,
            NSMidY(visible) - targetH / 2.0,
            targetW,
            targetH
        );
        [window setFrame:target display:YES animate:YES];
    } else {
        CGFloat w = 1280.0;
        CGFloat h = w / aspectRatio;
        [window moonlight_centerWindowOnFirstRunWithSize:CGSizeMake(w, h)];
    }
    
    [self captureMouse];
    [self requestStreamMenuEntrypointsVisibilityUpdate];

    // If AppKit was mid-transition, try again on next runloop to restore the titlebar control center.
    dispatch_async(dispatch_get_main_queue(), ^{
        [self requestStreamMenuEntrypointsVisibilityUpdate];
    });
    [self logCurrentWindowStateWithContext:@"apply-windowed-end"];
}

- (void)switchToWindowedMode:(id)sender {
    NSWindow *window = self.view.window;
    Log(LOG_I, @"[diag] switchToWindowedMode requested");
    [self logCurrentWindowStateWithContext:@"switch-windowed-begin"];
    if (window.styleMask & NSWindowStyleMaskFullScreen) {
        self.pendingWindowMode = PendingWindowModeWindowed;
        Log(LOG_I, @"[diag] switchToWindowedMode toggling fullscreen off before apply");
        [window toggleFullScreen:self];
        return;
    }
    
    [self applyWindowedMode];
}

- (void)switchToFullscreenMode:(id)sender {
    NSWindow *window = self.view.window;
    Log(LOG_I, @"[diag] switchToFullscreenMode requested");
    [self logCurrentWindowStateWithContext:@"switch-fullscreen-begin"];
    // NSWindowStyleMaskBorderless is 0, so we must check for equality
    if (window.styleMask == NSWindowStyleMaskBorderless) {
        [self restorePresentationOptionsIfNeeded];

        if (self.savedContentAspectRatioValid) {
            @try {
                window.contentAspectRatio = self.savedContentAspectRatio;
            } @catch (NSException *exception) {
                // ignore
            }
            self.savedContentAspectRatioValid = NO;
        }

        window.styleMask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
        window.level = NSNormalWindowLevel;
    }
    
    if ((window.styleMask & NSWindowStyleMaskFullScreen) == 0) {
        Log(LOG_I, @"[diag] switchToFullscreenMode toggling fullscreen on");
        [window toggleFullScreen:self];
    } else {
        Log(LOG_I, @"[diag] switchToFullscreenMode no-op: already fullscreen");
    }
}

- (void)applyBorderlessMode {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSWindow *window = self.view.window;
        if (!window) {
            Log(LOG_W, @"[diag] applyBorderlessMode skipped: window is nil");
            return;
        }
        Log(LOG_I, @"[diag] applyBorderlessMode begin");
        [self logCurrentWindowStateWithContext:@"apply-borderless-begin"];

        // Ensure we are not in fullscreen before applying borderless
        if (window.styleMask & NSWindowStyleMaskFullScreen) {
             Log(LOG_I, @"[diag] applyBorderlessMode toggling fullscreen off first");
             [window toggleFullScreen:self];
             return;
        }

        [self enterBorderlessPresentationOptionsIfNeeded];

        // Borderless should cover the full screen frame. If the stream window has a fixed
        // contentAspectRatio (e.g., 16:9), AppKit will refuse a 16:10 screen-sized frame and
        // we end up with a visible blank strip. Temporarily set the aspect ratio to the screen.
        NSScreen *screen = window.screen ?: [NSScreen mainScreen];
        NSRect screenFrame = screen ? screen.frame : window.frame;
        if (!self.savedContentAspectRatioValid) {
            self.savedContentAspectRatio = window.contentAspectRatio;
            self.savedContentAspectRatioValid = YES;
        }
        @try {
            if (screenFrame.size.width > 0 && screenFrame.size.height > 0) {
                window.contentAspectRatio = screenFrame.size;
            }
        } @catch (NSException *exception) {
            // ignore
        }

        // Titlebar accessories can cause AppKit assertions when switching to borderless.
        [self removeMenuTitlebarAccessoryFromWindowIfNeeded];

        NSWindowStyleMask newMask = window.styleMask;
        newMask &= ~(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable);
        newMask |= NSWindowStyleMaskBorderless;
        [window setStyleMask:newMask];
        // Using NSMainMenuWindowLevel + 1 to ensure it covers the menu bar area
        [window setLevel:NSMainMenuWindowLevel + 1];

        NSRect targetFrame = screenFrame;
        [window setFrame:targetFrame display:YES];

        // Some configurations (space transitions / Stage Manager / presentationOptions updates)
        // can cause the first setFrame to be adjusted. Re-apply shortly after to eliminate
        // a persistent bottom gap.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NSWindow *w = self.view.window;
            if (!w) {
                return;
            }
            NSScreen *s = w.screen ?: [NSScreen mainScreen];
            NSRect tf = s ? s.frame : w.frame;
            // Fix for positioning issue where window is shifted up
            if (s) {
                 tf = s.frame;
            }
            [w setFrame:tf display:YES];
            [w.contentView setNeedsLayout:YES];
            [self.view setNeedsLayout:YES];
        });

        // Force a layout pass after styleMask/frame changes to avoid transient blank bars.
        [window.contentView setNeedsLayout:YES];
        [self.view setNeedsLayout:YES];

        // Ensure our overlay/menu buttons don't steal key focus (which breaks key equivalents).
        if (self.menuTitlebarButton && [self.menuTitlebarButton respondsToSelector:@selector(setRefusesFirstResponder:)]) {
            self.menuTitlebarButton.refusesFirstResponder = YES;
        }
        [window makeFirstResponder:self];

        [self captureMouse];
        [self requestStreamMenuEntrypointsVisibilityUpdate];
        [self logCurrentWindowStateWithContext:@"apply-borderless-end"];
    });
}

- (void)switchToBorderlessMode:(id)sender {
    NSWindow *window = self.view.window;
    Log(LOG_I, @"[diag] switchToBorderlessMode requested");
    [self logCurrentWindowStateWithContext:@"switch-borderless-begin"];
    if (window.styleMask & NSWindowStyleMaskFullScreen) {
        self.pendingWindowMode = PendingWindowModeBorderless;
        Log(LOG_I, @"[diag] switchToBorderlessMode toggling fullscreen off before apply");
        [window toggleFullScreen:self];
        return;
    }
    
    [self applyBorderlessMode];
}

- (BOOL)isWindowInCurrentSpace {
    if (!self.view.window) {
        return NO;
    }
    BOOL found = NO;
    CFArrayRef windowsInSpace = CGWindowListCopyWindowInfo(kCGWindowListOptionAll | kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
    if (windowsInSpace == NULL) {
        return NO;
    }
    for (NSDictionary *thisWindow in (__bridge NSArray *)windowsInSpace) {
        NSNumber *thisWindowNumber = (NSNumber *)thisWindow[(__bridge NSString *)kCGWindowNumber];
        if (self.view.window.windowNumber == thisWindowNumber.integerValue) {
            found = YES;
            break;
        }
    }
    CFRelease(windowsInSpace);
    return found;
}

- (BOOL)isWindowFullscreen {
    return [self.view.window styleMask] & NSWindowStyleMaskFullScreen;
}

- (BOOL)isOurWindowTheWindowInNotiifcation:(NSNotification *)note {
    return ((NSWindow *)note.object) == self.view.window;
}

- (NSMenuItem *)itemWithMenu:(NSMenu *)menu andAction:(SEL)action {
    return [menu itemAtIndex:[menu indexOfItemWithTarget:nil andAction:action]];
}


- (void)disallowDisplaySleep {
    if (self.powerAssertionID != 0) {
        return;
    }
    
    CFStringRef reasonForActivity= CFSTR("Moonlight streaming");
    
    IOPMAssertionID assertionID;
    IOReturn success = IOPMAssertionCreateWithName(kIOPMAssertionTypeNoDisplaySleep, kIOPMAssertionLevelOn, reasonForActivity, &assertionID);
    
    if (success == kIOReturnSuccess) {
        self.powerAssertionID = assertionID;
    } else {
        self.powerAssertionID = 0;
    }
}

- (void)allowDisplaySleep {
    if (self.powerAssertionID != 0) {
        IOPMAssertionRelease(self.powerAssertionID);
        self.powerAssertionID = 0;
    }
}

- (void)prepareStreamWindowForSafeClose:(NSWindow *)window {
    if (!window) {
        return;
    }

    [self restoreStreamWindowChromeIfNeeded];
    [self restorePresentationOptionsIfNeeded];

    [self teardownStreamMenuEntrypointsForClosingWindow:window];

    if ((window.styleMask & NSWindowStyleMaskTitled) == 0 || [self isWindowBorderlessMode]) {
        NSWindowStyleMask mask = window.styleMask;
        mask &= ~NSWindowStyleMaskBorderless;
        mask |= (NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable);
        @try {
            [window setStyleMask:mask];
            [window setLevel:NSNormalWindowLevel];
        } @catch (NSException *exception) {
            // ignore
        }
    }
}

- (void)teardownStreamMenuEntrypointsForClosingWindow:(NSWindow *)window {
    if (self.edgeMenuPanel.parentWindow == window) {
        [window removeChildWindow:self.edgeMenuPanel];
    }
    [self.edgeMenuAutoCollapseTimer invalidate];
    self.edgeMenuAutoCollapseTimer = nil;
    self.edgeMenuButtonTrackingArea = nil;
    [self.edgeMenuPanel orderOut:nil];
    [self.edgeMenuButton removeFromSuperview];
    [self.edgeMenuPanel close];
    self.edgeMenuButton = nil;
    self.edgeMenuPanel = nil;
    self.edgeMenuTemporaryReleaseActive = NO;
    self.edgeMenuDragging = NO;
    self.edgeMenuMenuVisible = NO;
    self.edgeMenuPointerInside = NO;
}

- (void)requestSafeCloseOfStreamWindow {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.hidSupport releaseAllModifierKeys];
        [self uncaptureMouseWithCode:@"MUC302" reason:@"request-safe-close-window"];

        NSWindow *window = self.view.window;
        if (!window) {
            return;
        }

        window.ignoresMouseEvents = YES;
        window.alphaValue = 0.0;
        [self teardownStreamMenuEntrypointsForClosingWindow:window];

        if ([self isWindowFullscreen]) {
            if (!self.pendingCloseWindowAfterFullscreenExit) {
                self.pendingCloseWindowAfterFullscreenExit = YES;
                [window toggleFullScreen:self];
            }
            return;
        }

        self.pendingCloseWindowAfterFullscreenExit = NO;
        [self prepareStreamWindowForSafeClose:window];
        [window close];
    });
}

- (void)closeWindowFromMainQueueWithMessage:(NSString *)message {
    [self.hidSupport releaseAllModifierKeys];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [self tearDownControllerSupportOnMainThreadIfNeeded];
        [self uncaptureMouseWithCode:@"MUC303" reason:@"close-window-from-main-queue"];

        if (message != nil) {
            // Show the error overlay and keep window open for retry/options
            [self showErrorOverlayWithTitle:@"连接失败" message:message canWait:NO];
        } else {
            [self.delegate appDidQuit:self.app];
            [self requestSafeCloseOfStreamWindow];
        }
    });
}

- (void)windowWillEnterFullScreen:(NSNotification *)notification {
    if ([self isOurWindowTheWindowInNotiifcation:notification]) {
        self.fullscreenTransitionInProgress = YES;
        [self logCurrentWindowStateWithContext:@"window-will-enter-fullscreen"];
    }
}

- (void)windowWillExitFullScreen:(NSNotification *)notification {
    if ([self isOurWindowTheWindowInNotiifcation:notification]) {
        self.fullscreenTransitionInProgress = YES;
        [self logCurrentWindowStateWithContext:@"window-will-exit-fullscreen"];
    }
}

@end
