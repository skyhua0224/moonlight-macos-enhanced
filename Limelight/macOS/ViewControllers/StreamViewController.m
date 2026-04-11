//
//  StreamViewController.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 25/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import "StreamViewController_Internal.h"

static NSScreen *MLScreenContainingMouseLocation(void) {
    NSPoint mouseLocation = [NSEvent mouseLocation];
    for (NSScreen *screen in [NSScreen screens]) {
        if (NSPointInRect(mouseLocation, screen.frame)) {
            return screen;
        }
    }
    return [NSScreen mainScreen];
}

@interface MLStreamScopedConnectionCallbacks : NSObject <ConnectionCallbacks>

- (instancetype)initWithOwner:(id<MLStreamScopedCallbackOwner>)owner generation:(NSUInteger)generation;

@end

@implementation MLStreamScopedConnectionCallbacks {
    __weak id<MLStreamScopedCallbackOwner> _owner;
    NSUInteger _generation;
}

- (instancetype)initWithOwner:(id<MLStreamScopedCallbackOwner>)owner generation:(NSUInteger)generation {
    self = [super init];
    if (self) {
        _owner = owner;
        _generation = generation;
    }
    return self;
}

- (BOOL)forwardIfCurrentNamed:(NSString *)name block:(void (^)(id<MLStreamScopedCallbackOwner> owner))block {
    id<MLStreamScopedCallbackOwner> owner = _owner;
    if (!owner) {
        Log(LOG_W, @"[diag] Dropping stream callback with no owner: %@ gen=%lu",
            name ?: @"unknown",
            (unsigned long)_generation);
        return NO;
    }
    if (![owner isActiveStreamGeneration:_generation]) {
        Log(LOG_I, @"[diag] Ignoring stale stream callback: %@ gen=%lu",
            name ?: @"unknown",
            (unsigned long)_generation);
        return NO;
    }
    if (block) {
        block(owner);
    }
    return YES;
}

- (void)connectionStarted {
    [self forwardIfCurrentNamed:@"connectionStarted" block:^(id<MLStreamScopedCallbackOwner> owner) {
        [owner connectionStarted];
    }];
}

- (void)connectionTerminated:(int)errorCode {
    [self forwardIfCurrentNamed:@"connectionTerminated" block:^(id<MLStreamScopedCallbackOwner> owner) {
        [owner connectionTerminated:errorCode];
    }];
}

- (void)stageStarting:(const char *)stageName {
    [self forwardIfCurrentNamed:@"stageStarting" block:^(id<MLStreamScopedCallbackOwner> owner) {
        [owner stageStarting:stageName];
    }];
}

- (void)stageComplete:(const char *)stageName {
    [self forwardIfCurrentNamed:@"stageComplete" block:^(id<MLStreamScopedCallbackOwner> owner) {
        [owner stageComplete:stageName];
    }];
}

- (void)stageFailed:(const char *)stageName withError:(int)errorCode {
    [self forwardIfCurrentNamed:@"stageFailed" block:^(id<MLStreamScopedCallbackOwner> owner) {
        [owner stageFailed:stageName withError:errorCode];
    }];
}

- (void)launchFailed:(NSString *)message {
    [self forwardIfCurrentNamed:@"launchFailed" block:^(id<MLStreamScopedCallbackOwner> owner) {
        [owner launchFailed:message];
    }];
}

- (void)rumble:(unsigned short)controllerNumber
 lowFreqMotor:(unsigned short)lowFreqMotor
highFreqMotor:(unsigned short)highFreqMotor {
    [self forwardIfCurrentNamed:@"rumble" block:^(id<MLStreamScopedCallbackOwner> owner) {
        [owner rumble:controllerNumber lowFreqMotor:lowFreqMotor highFreqMotor:highFreqMotor];
    }];
}

- (void)connectionStatusUpdate:(int)status {
    [self forwardIfCurrentNamed:@"connectionStatusUpdate" block:^(id<MLStreamScopedCallbackOwner> owner) {
        [owner connectionStatusUpdate:status];
    }];
}

@end

@implementation StreamViewController

- (BOOL)useSystemControllerDriver {
    return [SettingsClass controllerDriverFor:self.app.host.uuid] == 1;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.cursorHiddenCounter = 0;
    self.isMouseCaptured = NO;
    self.disconnectWasUserInitiated = NO;
    self.suppressConnectionWarningsUntilMs = 0;
    self.pendingDisconnectSource = nil;
    self.currentStreamRiskAssessment = nil;
    self.lastOptionUncaptureAtMs = 0;
    self.stopStreamInProgress = NO;
    self.shouldAttemptReconnect = YES;
    self.reconnectAttemptCount = 0;
    self.reconnectInProgress = NO;
    self.connectWatchdogToken = 0;
    self.didAutoReconnectAfterTimeout = NO;
    self.streamOpQueue = [[NSOperationQueue alloc] init];
    self.streamOpQueue.maxConcurrentOperationCount = 1;
    self.streamHealthSawPayload = NO;
    self.streamHealthNoPayloadStreak = 0;
    self.streamHealthNoDecodeStreak = 0;
    self.streamHealthNoRenderStreak = 0;
    self.streamHealthHighDropStreak = 0;
    self.streamHealthLastPayloadReconnectMs = 0;
    self.streamHealthConnectionStartedMs = 0;
    self.lastConnectionStatus = -1;
    self.connectionPoorStatusBurstCount = 0;
    self.connectionPoorStatusBurstWindowStartMs = 0;
    self.connectionLastIdrRequestMs = 0;
    self.runtimeAutoBitrateCapKbps = 0;
    self.runtimeAutoBitrateBaselineKbps = 0;
    self.runtimeAutoBitrateStableStreak = 0;
    self.runtimeAutoBitrateLastRaiseMs = 0;
    self.isRemoteDesktopMode = [[SettingsClass mouseModeFor:self.app.host.uuid] isEqualToString:@"remote"];
    self.pendingFreeMouseReentryEdge = MLFreeMouseExitEdgeNone;
    self.pendingFreeMouseReentryAtMs = 0;
    self.suppressFreeMouseEdgeUncaptureUntilMs = 0;

    self.hideFullscreenControlBall = [[NSUserDefaults standardUserDefaults] boolForKey:[self fullscreenControlBallDefaultsKey]];
    self.edgeMenuDockEdge = [self defaultEdgeMenuDockEdge];
    self.edgeMenuButtonEdgeRatio = 0.5;
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:[self fullscreenControlBallDockSideDefaultsKey]];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:[self fullscreenControlBallVerticalRatioDefaultsKey]];
    
    [self prepareForStreaming];

    __weak typeof(self) weakSelf = self;

    self.windowDidExitFullScreenNotification = [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidExitFullScreenNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        if ([weakSelf isOurWindowTheWindowInNotiifcation:note]) {
            weakSelf.fullscreenTransitionInProgress = NO;
            [weakSelf logCurrentWindowStateWithContext:@"window-did-exit-fullscreen"];
            if (weakSelf.pendingWindowMode == PendingWindowModeBorderless) {
                weakSelf.pendingWindowMode = PendingWindowModeNone;
                [weakSelf applyBorderlessMode];
            } else if (weakSelf.pendingWindowMode == PendingWindowModeWindowed) {
                weakSelf.pendingWindowMode = PendingWindowModeNone;
                [weakSelf applyWindowedMode];
            }

            [weakSelf requestStreamMenuEntrypointsVisibilityUpdate];
            if ([weakSelf.view.window isKeyWindow]) {
                [weakSelf uncaptureMouseWithCode:@"MUC001" reason:@"window-exited-fullscreen"];
                [weakSelf rearmMouseCaptureIfPossibleWithReason:@"window-exited-fullscreen"];
                [weakSelf scheduleDeferredMouseCaptureRearmWithReason:@"window-exited-fullscreen" delay:0.12];
                [weakSelf scheduleDeferredMouseCaptureRearmWithReason:@"window-exited-fullscreen" delay:0.35];
                [weakSelf scheduleDeferredMouseCaptureRearmWithReason:@"window-exited-fullscreen" delay:0.70];
            }
            if (weakSelf.pendingCloseWindowAfterFullscreenExit) {
                weakSelf.pendingCloseWindowAfterFullscreenExit = NO;
                [weakSelf requestSafeCloseOfStreamWindow];
            }
        }
    }];

    self.windowDidEnterFullScreenNotification = [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidEnterFullScreenNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        if ([weakSelf isOurWindowTheWindowInNotiifcation:note]) {
            weakSelf.fullscreenTransitionInProgress = NO;
            [weakSelf logCurrentWindowStateWithContext:@"window-did-enter-fullscreen"];
            [weakSelf requestStreamMenuEntrypointsVisibilityUpdate];
            if ([weakSelf isWindowInCurrentSpace]) {
                if ([weakSelf isWindowFullscreen]) {
                    if ([weakSelf.view.window isKeyWindow]) {
                        [weakSelf uncaptureMouseWithCode:@"MUC002" reason:@"window-entered-fullscreen"];
                        [weakSelf rearmMouseCaptureIfPossibleWithReason:@"window-entered-fullscreen"];
                        [weakSelf scheduleDeferredMouseCaptureRearmWithReason:@"window-entered-fullscreen" delay:0.12];
                        [weakSelf scheduleDeferredMouseCaptureRearmWithReason:@"window-entered-fullscreen" delay:0.35];
                        [weakSelf scheduleDeferredMouseCaptureRearmWithReason:@"window-entered-fullscreen" delay:0.70];
                    }
                }
            }
        }
    }];
    
    self.windowDidResignKeyNotification = [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidResignKeyNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        if ([weakSelf isOurWindowTheWindowInNotiifcation:note]) {
            [weakSelf logKeyLossDiagnosticsForStage:@"received" code:@"MUC003" reason:@"window-resigned-key"];
            if ([weakSelf shouldSuppressTransientKeyLossUncaptureForCode:@"MUC003" reason:@"window-resigned-key"]) {
                [weakSelf logKeyLossDiagnosticsForStage:@"skip-top-edge-click" code:@"MUC003" reason:@"window-resigned-key"];
                [weakSelf logMouseUncaptureStage:@"skip-top-edge-click" code:@"MUC003" reason:@"window-resigned-key"];
                [weakSelf scheduleTransientKeyLossRecoveryWithReason:@"window-resigned-key"];
                return;
            }
            [weakSelf requestMouseUncaptureWhenSafeWithReason:@"window-resigned-key" code:@"MUC003"];
        }
    }];
    self.windowDidBecomeKeyNotification = [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidBecomeKeyNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        if ([weakSelf isOurWindowTheWindowInNotiifcation:note]) {
            if ([weakSelf isWindowInCurrentSpace]) {
                if ([weakSelf.view.window isKeyWindow]) {
                    Log(LOG_D, @"[diag] Window became key; rearming input capture (fullscreen=%d style=%llu level=%ld)",
                        [weakSelf isWindowFullscreen] ? 1 : 0,
                        (unsigned long long)weakSelf.view.window.styleMask,
                        (long)weakSelf.view.window.level);
                    [weakSelf prepareCoreHIDFreeMouseStateForFocusRegainWithReason:@"window-became-key"];
                    [weakSelf uncaptureMouseWithCode:@"MUC004" reason:@"window-became-key"];
                    [weakSelf rearmMouseCaptureIfPossibleWithReason:@"window-became-key"];
                    [weakSelf scheduleDeferredMouseCaptureRearmWithReason:@"window-became-key" delay:0.10];
                    [weakSelf scheduleDeferredMouseCaptureRearmWithReason:@"window-became-key" delay:0.28];
                    [weakSelf scheduleDeferredMouseCaptureRearmWithReason:@"window-became-key" delay:0.60];
                }
            }
        } else {
            [weakSelf logKeyLossDiagnosticsForStage:@"received" code:@"MUC005" reason:@"other-window-became-key"];
            if ([weakSelf shouldSuppressTransientKeyLossUncaptureForCode:@"MUC005" reason:@"other-window-became-key"]) {
                [weakSelf logKeyLossDiagnosticsForStage:@"skip-top-edge-click" code:@"MUC005" reason:@"other-window-became-key"];
                [weakSelf logMouseUncaptureStage:@"skip-top-edge-click" code:@"MUC005" reason:@"other-window-became-key"];
                [weakSelf scheduleTransientKeyLossRecoveryWithReason:@"other-window-became-key"];
                return;
            }
            [weakSelf requestMouseUncaptureWhenSafeWithReason:@"other-window-became-key" code:@"MUC005"];
        }
    }];
    
    self.windowWillCloseNotification = [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowWillCloseNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        if ([weakSelf isOurWindowTheWindowInNotiifcation:note]) {
            [weakSelf beginStopStreamIfNeededWithReason:@"window-will-close"]; 
        }
    }];

    self.appDidResignActiveObserver = [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationDidResignActiveNotification object:NSApp queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        weakSelf.globalInactivePointerInsideStreamView = NO;
        [weakSelf requestMouseUncaptureWhenSafeWithReason:@"app-resigned-active" code:@"MUC006"];
    }];
    self.appDidBecomeActiveObserver = [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationDidBecomeActiveNotification object:NSApp queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        weakSelf.globalInactivePointerInsideStreamView = NO;
        if ([weakSelf isWindowInCurrentSpace] && [weakSelf isCurrentPointerInsideStreamView]) {
            [weakSelf ensureStreamWindowKeyIfPossible];
        }
        [weakSelf prepareCoreHIDFreeMouseStateForFocusRegainWithReason:@"app-became-active"];
        [weakSelf rearmMouseCaptureIfPossibleWithReason:@"app-became-active"];
        [weakSelf scheduleDeferredMouseCaptureRearmWithReason:@"app-became-active" delay:0.10];
        [weakSelf scheduleDeferredMouseCaptureRearmWithReason:@"app-became-active" delay:0.28];
        [weakSelf scheduleDeferredMouseCaptureRearmWithReason:@"app-became-active" delay:0.60];
    }];

    self.activeSpaceDidChangeObserver = [[[NSWorkspace sharedWorkspace] notificationCenter]
        addObserverForName:NSWorkspaceActiveSpaceDidChangeNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        if (strongSelf.stopStreamInProgress || strongSelf.reconnectInProgress) {
            return;
        }
        NSWindow *window = strongSelf.view.window;
        BOOL appActive = [NSApp isActive];
        BOOL windowInCurrentSpace = [strongSelf isWindowInCurrentSpace];
        BOOL windowKey = window != nil && window.isKeyWindow;
        BOOL windowMain = window != nil && window.isMainWindow;
        BOOL shouldReleaseForActiveSpaceChange = !appActive || !windowKey || !windowMain ||
            (!windowInCurrentSpace && !strongSelf.fullscreenTransitionInProgress);
        strongSelf.spaceTransitionInProgress = YES;
        [strongSelf logPointerContextForReason:@"active-space-changed"];
        Log(LOG_I, @"[diag] Active space change decision: release=%d appActive=%d currentSpace=%d key=%d main=%d captured=%d fullscreen=%d fullscreenTransition=%d remoteDesktop=%d",
            shouldReleaseForActiveSpaceChange ? 1 : 0,
            appActive ? 1 : 0,
            windowInCurrentSpace ? 1 : 0,
            windowKey ? 1 : 0,
            windowMain ? 1 : 0,
            strongSelf.isMouseCaptured ? 1 : 0,
            [strongSelf isWindowFullscreen] ? 1 : 0,
            strongSelf.fullscreenTransitionInProgress ? 1 : 0,
            strongSelf.isRemoteDesktopMode ? 1 : 0);
        if (shouldReleaseForActiveSpaceChange) {
            [strongSelf requestMouseUncaptureWhenSafeWithReason:@"active-space-changed" code:@"MUC007"];
        } else {
            [strongSelf logMouseUncaptureStage:@"skip-still-active" code:@"MUC007" reason:@"active-space-changed"];
        }
        if (!windowInCurrentSpace) {
            [strongSelf hideEdgeMenuForInactiveSpaceIfNeeded];
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!strongSelf) {
                return;
            }
            strongSelf.spaceTransitionInProgress = NO;
            if (strongSelf.stopStreamInProgress || strongSelf.reconnectInProgress) {
                return;
            }
            if (![strongSelf isWindowInCurrentSpace]) {
                [strongSelf hideEdgeMenuForInactiveSpaceIfNeeded];
                return;
            }
            [strongSelf requestStreamMenuEntrypointsVisibilityUpdate];
            if ([strongSelf isWindowInCurrentSpace] && strongSelf.view.window.isKeyWindow) {
                    [strongSelf rearmMouseCaptureIfPossibleWithReason:@"space-transition-finished"];
                    [strongSelf scheduleDeferredMouseCaptureRearmWithReason:@"space-transition-finished" delay:0.12];
                    [strongSelf scheduleDeferredMouseCaptureRearmWithReason:@"space-transition-finished" delay:0.35];
                    [strongSelf scheduleDeferredMouseCaptureRearmWithReason:@"space-transition-finished" delay:0.75];
            }
        });
    }];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleMouseModeToggledNotification:) name:HIDMouseModeToggledNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleGamepadQuitNotification:) name:HIDGamepadQuitNotification object:nil];

    // Listen for disconnect requests from the session manager
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleSessionDisconnectRequest:) name:@"StreamingSessionRequestDisconnect" object:nil];

    [self installStreamMenuEntrypoints];
}

- (void)handleSessionDisconnectRequest:(NSNotification *)note {
    NSString *hostUUID = note.userInfo[@"hostUUID"];
    NSNumber *quitApp = note.userInfo[@"quitApp"];
    Log(LOG_I, @"[diag] Session disconnect request received: requestHost=%@ currentHost=%@ quitApp=%@ userInfo=%@",
        hostUUID ?: @"(nil)",
        self.app.host.uuid ?: @"(nil)",
        quitApp != nil ? (quitApp.boolValue ? @"1" : @"0") : @"(nil)",
        note.userInfo ?: @{});

    if (hostUUID && self.app.host.uuid && ![hostUUID isEqualToString:self.app.host.uuid]) {
        return;
    }

    if (quitApp != nil) {
        if (quitApp.boolValue) {
            [self performCloseAndQuitApp:nil];
        } else {
            [self requestStreamCloseWithSource:@"session-manager-request"];
        }
        return;
    }

    // Programmatic disconnect requests should not show a confirmation alert.
    [self requestStreamCloseWithSource:@"session-manager-request-legacy"];
}

- (void)beginStopStreamIfNeededWithReason:(NSString *)reason {
    [self beginStopStreamIfNeededWithReason:reason completion:nil];
}

- (void)beginStopStreamIfNeededWithReason:(NSString *)reason completion:(void (^)(void))completion {
    @synchronized (self) {
        if (self.stopStreamInProgress) {
            if (completion) {
                dispatch_async(dispatch_get_main_queue(), completion);
            }
            return;
        }
        self.stopStreamInProgress = YES;
        self.activeStreamGeneration += 1;
    }

    [self stopStreamHealthDiagnostics];
    [self logStreamHealthSummaryWithReason:[NSString stringWithFormat:@"begin-stop:%@", reason ?: @"unknown"]];
    [self finalizeInputDiagnosticsWithReason:reason];
    [[AwdlHelperManager sharedManager] endStreamSessionWithReason:reason ?: @"begin-stop"];
    [self tearDownStreamLifecycleObserversAndTimers];

    self.hidSupport.shouldSendInputEvents = NO;
    self.controllerSupport.shouldSendInputEvents = NO;
    self.hidSupport.inputContext = NULL;
    self.controllerSupport.inputContext = NULL;

    [self broadcastHostOnlineStateForExit];

    // If we are closing while in borderless, ensure we restore system UI state and window constraints.
    dispatch_async(dispatch_get_main_queue(), ^{
        [self restorePresentationOptionsIfNeeded];
        if (self.savedContentAspectRatioValid && self.view.window) {
            @try {
                self.view.window.contentAspectRatio = self.savedContentAspectRatio;
            } @catch (NSException *exception) {
                // ignore
            }
            self.savedContentAspectRatioValid = NO;
        }
    });

    // If we are intentionally stopping, don't attempt auto-reconnect.
    self.shouldAttemptReconnect = NO;
    self.reconnectInProgress = NO;

    // Treat window close / quit shortcuts as a user-initiated disconnect to avoid
    // showing transient "connection is slow" warnings during teardown.
    [self markUserInitiatedDisconnectAndSuppressWarningsForSeconds:2.0 reason:reason];

    // Stopping the stream can block while common-c tears down sockets/ENet.
    // Do cleanup/stop off the main thread so window close doesn't feel like a hang.
    __strong typeof(self) strongSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        double start = CACurrentMediaTime();
        if (strongSelf.useSystemControllerDriver) {
            double cleanupStart = CACurrentMediaTime();
            [strongSelf.controllerSupport cleanup];
            Log(LOG_I, @"Controller cleanup took %.3fs", CACurrentMediaTime() - cleanupStart);
        }

        double stopStart = CACurrentMediaTime();
        [strongSelf.streamMan stopStream];
        Log(LOG_I, @"Stream stop took %.3fs (total %.3fs)", CACurrentMediaTime() - stopStart, CACurrentMediaTime() - start);

        // Ensure streaming state is cleared for this host even if we don't receive a termination callback
        if (self.app.host.uuid) {
            [[StreamingSessionManager shared] didDisconnectForHost:self.app.host.uuid];
        }

        if (completion) {
            dispatch_async(dispatch_get_main_queue(), completion);
        }
    });
}

- (void)broadcastHostOnlineStateForExit {
    if (!self.app.host.uuid) {
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        self.app.host.state = StateOnline;

        NSMutableDictionary *states = [NSMutableDictionary dictionaryWithDictionary:self.app.host.addressStates ?: @{}];
        if (self.app.host.activeAddress) {
            states[self.app.host.activeAddress] = @(1);
        }
        self.app.host.addressStates = states;

        [[NSNotificationCenter defaultCenter] postNotificationName:@"HostLatencyUpdated"
                                                            object:nil
                                                          userInfo:@{
                                                              @"uuid": self.app.host.uuid,
                                                              @"latencies": self.app.host.addressLatencies ?: @{},
                                                              @"states": states
                                                          }];
    });
}

- (void)viewDidAppear {
    [super viewDidAppear];
    
    self.streamView.keyboardNotifiable = self;
    self.streamView.appName = self.app.name;
    self.streamView.statusText = @"Starting";
    self.view.window.tabbingMode = NSWindowTabbingModeDisallowed;
    self.view.window.delegate = self;
    [self prepareStreamWindowChromeForStreamingIfNeeded];
    [self.view.window makeFirstResponder:self];

    [self installLocalKeyMonitorIfNeeded];
    [self installLocalMouseClickMonitorIfNeeded];
    [self installGlobalMouseMonitorIfNeeded];
    [self installMouseTrackingArea];
    
    NSDictionary *prefs = [SettingsClass getSettingsFor:self.app.host.uuid];
    BOOL ignoreAspectRatio = prefs ? [prefs[@"ignoreAspectRatio"] boolValue] : NO;

    if (!ignoreAspectRatio) {
        int width = [self.class getResolution].width;
        int height = [self.class getResolution].height;

        BOOL scaleEnabled = prefs ? [prefs[@"streamResolutionScale"] boolValue] : NO;
        int ratio = prefs ? [prefs[@"streamResolutionScaleRatio"] intValue] : 100;
        if (scaleEnabled && ratio > 0 && ratio != 100) {
            int scaledWidth = width * ratio / 100;
            int scaledHeight = height * ratio / 100;
            width = (scaledWidth / 8) * 8;
            height = (scaledHeight / 8) * 8;
        }

        self.view.window.contentAspectRatio = NSMakeSize(width, height);
    }
    self.view.window.frameAutosaveName = @"Stream Window";
    
    struct Resolution res = [self.class getResolution];
    CGFloat aspectRatio = (res.height > 0) ? ((CGFloat)res.width / (CGFloat)res.height) : (16.0 / 9.0);
    CGFloat initialW = 1280.0;
    CGFloat initialH = initialW / aspectRatio;

    // Sanity check for portrait streams or extreme aspect ratios to avoid huge windows
    if (initialH > 900.0) {
        initialH = 900.0;
        initialW = initialH * aspectRatio;
    }

    NSScreen *preferredScreen = MLScreenContainingMouseLocation();
    NSString *autosaveKey = [NSString stringWithFormat:@"NSWindow Frame %@", self.view.window.frameAutosaveName];
    BOOL hasSavedFrame = [[NSUserDefaults standardUserDefaults] stringForKey:autosaveKey].length > 0;
    if (hasSavedFrame) {
        [self.view.window moonlight_centerWindowOnScreen:preferredScreen];
    } else {
        [self.view.window setFrame:NSMakeRect(0, 0, initialW, initialH) display:NO];
        [self.view.window moonlight_centerWindowOnScreen:preferredScreen];
    }
    
    self.view.window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameVibrantDark];

    [self updateWindowSubtitle];
    [self updateConfiguredShortcutMenus];

    [self requestStreamMenuEntrypointsVisibilityUpdate];

    if (!self.streamStartDate) {
        self.streamStartDate = [NSDate date];
    }
    [self startControlCenterTimerIfNeeded];

    __weak typeof(self) weakSelf = self;
    self.settingsDidChangeObserver = [[NSNotificationCenter defaultCenter] addObserverForName:NSUserDefaultsDidChangeNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        [weakSelf updateWindowSubtitle];
        [weakSelf updateConfiguredShortcutMenus];
        [weakSelf refreshInputDiagnosticsPreference];
    }];
    self.mouseSettingsDidChangeObserver = [[NSNotificationCenter defaultCenter] addObserverForName:@"MoonlightMouseSettingsDidChange" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }

        NSString *hostId = note.userInfo[@"hostId"];
        if (hostId.length > 0 &&
            ![hostId isEqualToString:@"__global__"] &&
            ![hostId isEqualToString:strongSelf.app.host.uuid]) {
            return;
        }

        NSString *setting = note.userInfo[@"setting"];
        [strongSelf applyLiveMouseSettingsRefreshForSetting:setting];
    }];
    self.hostLatencyUpdatedObserver = [[NSNotificationCenter defaultCenter] addObserverForName:@"HostLatencyUpdated" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        [weakSelf updateWindowSubtitle];
    }];

    self.logDidAppendObserver = [[NSNotificationCenter defaultCenter] addObserverForName:MoonlightLogDidAppendNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        NSString *line = note.userInfo[MoonlightLogNotificationLineKey];
        if (line) {
            [weakSelf appendLogLineToOverlay:line];
        }
    }];
}

- (void)updateWindowSubtitle {
    NSDictionary *prefs = [SettingsClass getSettingsFor:self.app.host.uuid];
    NSString *method = prefs[@"connectionMethod"];

    NSString* (^addressLabel)(NSString*) = ^NSString* (NSString* addr) {
        if (!addr) {
            return MLString(@"Unknown", nil);
        }

        NSNumber *state = self.app.host.addressStates[addr];
        NSNumber *latency = self.app.host.addressLatencies[addr];
        BOOL online = state ? (state.intValue == 1) : YES;

        if (!online) {
            return [NSString stringWithFormat:@"%@ (%@)", addr, MLString(@"Offline", nil)];
        }
        if (latency && latency.intValue >= 0) {
            NSString *latencyText = [self formattedLatencyTextForDisplay:latency];
            return [NSString stringWithFormat:@"%@ (%@)", addr, latencyText ?: MLString(@"Online", nil)];
        }
        return addr;
    };

    NSString *subtitle = nil;
    if (method && ![method isEqualToString:@"Auto"]) {
        subtitle = [NSString stringWithFormat:@"%@ (%@)", MLString(@"Manual", nil), addressLabel(method)];
    } else {
        subtitle = [NSString stringWithFormat:@"%@ (%@)", MLString(@"Auto", nil), addressLabel(self.app.host.activeAddress)];
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        self.view.window.subtitle = subtitle;
    });
}

- (void)dealloc {
    [[AwdlHelperManager sharedManager] endStreamSessionWithReason:@"stream-view-controller-dealloc"];
    [self restoreStreamWindowChromeIfNeeded];
    [self tearDownStreamLifecycleObserversAndTimers];

    [self removeMenuTitlebarAccessoryFromWindowIfNeeded];
    self.menuTitlebarAccessory = nil;
    self.menuTitlebarButton = nil;
    self.controlCenterPill = nil;
    self.controlCenterSignalImageView = nil;
    self.controlCenterTimeLabel = nil;
    self.controlCenterTitleLabel = nil;

    [self.edgeMenuAutoCollapseTimer invalidate];
    self.edgeMenuAutoCollapseTimer = nil;

    if (self.streamHealthTimer) {
        [self.streamHealthTimer invalidate];
        self.streamHealthTimer = nil;
    }

    if (self.localKeyDownMonitor) {
        [NSEvent removeMonitor:self.localKeyDownMonitor];
        self.localKeyDownMonitor = nil;
    }
    if (self.localMouseClickMonitor) {
        [NSEvent removeMonitor:self.localMouseClickMonitor];
        self.localMouseClickMonitor = nil;
    }
    if (self.globalMouseMovedMonitor) {
        [NSEvent removeMonitor:self.globalMouseMovedMonitor];
        self.globalMouseMovedMonitor = nil;
    }
    self.globalInactivePointerInsideStreamView = NO;

    if (self.mouseTrackingArea) {
        [self.view removeTrackingArea:self.mouseTrackingArea];
        self.mouseTrackingArea = nil;
    }

    if (self.edgeMenuButtonTrackingArea && self.edgeMenuButton) {
        [self.edgeMenuButton removeTrackingArea:self.edgeMenuButtonTrackingArea];
        self.edgeMenuButtonTrackingArea = nil;
    }

    if (self.edgeMenuPanel.parentWindow) {
        [self.edgeMenuPanel.parentWindow removeChildWindow:self.edgeMenuPanel];
    }
    [self.edgeMenuPanel orderOut:nil];
    [self.edgeMenuPanel close];
    self.edgeMenuPanel = nil;

    [self stopInputDiagnosticsTimer];
    [self.hidSupport tearDownHidManager];
    self.hidSupport = nil;
}

- (void)tearDownStreamLifecycleObserversAndTimers {
    NSNotificationCenter *defaultCenter = [NSNotificationCenter defaultCenter];

    if (self.windowDidExitFullScreenNotification != nil) {
        [defaultCenter removeObserver:self.windowDidExitFullScreenNotification];
        self.windowDidExitFullScreenNotification = nil;
    }
    if (self.windowDidEnterFullScreenNotification != nil) {
        [defaultCenter removeObserver:self.windowDidEnterFullScreenNotification];
        self.windowDidEnterFullScreenNotification = nil;
    }
    if (self.windowDidResignKeyNotification != nil) {
        [defaultCenter removeObserver:self.windowDidResignKeyNotification];
        self.windowDidResignKeyNotification = nil;
    }
    if (self.windowDidBecomeKeyNotification != nil) {
        [defaultCenter removeObserver:self.windowDidBecomeKeyNotification];
        self.windowDidBecomeKeyNotification = nil;
    }
    if (self.windowWillCloseNotification != nil) {
        [defaultCenter removeObserver:self.windowWillCloseNotification];
        self.windowWillCloseNotification = nil;
    }
    if (self.appDidBecomeActiveObserver != nil) {
        [defaultCenter removeObserver:self.appDidBecomeActiveObserver];
        self.appDidBecomeActiveObserver = nil;
    }
    if (self.appDidResignActiveObserver != nil) {
        [defaultCenter removeObserver:self.appDidResignActiveObserver];
        self.appDidResignActiveObserver = nil;
    }
    if (self.settingsDidChangeObserver != nil) {
        [defaultCenter removeObserver:self.settingsDidChangeObserver];
        self.settingsDidChangeObserver = nil;
    }
    if (self.mouseSettingsDidChangeObserver != nil) {
        [defaultCenter removeObserver:self.mouseSettingsDidChangeObserver];
        self.mouseSettingsDidChangeObserver = nil;
    }
    if (self.hostLatencyUpdatedObserver != nil) {
        [defaultCenter removeObserver:self.hostLatencyUpdatedObserver];
        self.hostLatencyUpdatedObserver = nil;
    }
    if (self.logDidAppendObserver != nil) {
        [defaultCenter removeObserver:self.logDidAppendObserver];
        self.logDidAppendObserver = nil;
    }

    [defaultCenter removeObserver:self name:HIDMouseModeToggledNotification object:nil];
    [defaultCenter removeObserver:self name:HIDGamepadQuitNotification object:nil];
    [defaultCenter removeObserver:self name:@"StreamingSessionRequestDisconnect" object:nil];

    if (self.activeSpaceDidChangeObserver != nil) {
        [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self.activeSpaceDidChangeObserver];
        self.activeSpaceDidChangeObserver = nil;
    }

    if (self.controlCenterTimer != nil) {
        [self.controlCenterTimer invalidate];
        self.controlCenterTimer = nil;
    }
    if (self.notificationTimer != nil) {
        [self.notificationTimer invalidate];
        self.notificationTimer = nil;
    }
    if (self.statsTimer != nil) {
        [self.statsTimer invalidate];
        self.statsTimer = nil;
    }
    if (self.streamHealthTimer != nil) {
        [self.streamHealthTimer invalidate];
        self.streamHealthTimer = nil;
    }
    if (self.inputDiagnosticsTimer != nil) {
        [self.inputDiagnosticsTimer invalidate];
        self.inputDiagnosticsTimer = nil;
    }
    if (self.edgeMenuAutoCollapseTimer != nil) {
        [self.edgeMenuAutoCollapseTimer invalidate];
        self.edgeMenuAutoCollapseTimer = nil;
    }

    if (self.localKeyDownMonitor != nil) {
        [NSEvent removeMonitor:self.localKeyDownMonitor];
        self.localKeyDownMonitor = nil;
    }
    if (self.localMouseClickMonitor != nil) {
        [NSEvent removeMonitor:self.localMouseClickMonitor];
        self.localMouseClickMonitor = nil;
    }
    if (self.globalMouseMovedMonitor != nil) {
        [NSEvent removeMonitor:self.globalMouseMovedMonitor];
        self.globalMouseMovedMonitor = nil;
    }
    self.globalInactivePointerInsideStreamView = NO;

    if (self.hidSupport != nil) {
        [self.hidSupport setFreeMouseVirtualCursorActive:NO];
        [self.hidSupport resetFreeMouseVirtualCursorState];
        self.hidSupport.freeMouseAbsoluteSyncHandler = nil;
    }
}

- (BOOL)isWindowBorderlessMode {
    if (!self.view.window) {
        return NO;
    }
    BOOL isFullscreen = [self isWindowFullscreen];
    return ((self.view.window.styleMask & NSWindowStyleMaskTitled) == 0) && !isFullscreen;
}

- (StreamViewMac *)streamView {
    return (StreamViewMac *)self.view;
}


#pragma mark - Streaming Operations

- (void)prepareForStreaming {
    [self stopStreamHealthDiagnostics];
    [self resetStreamHealthDiagnostics];
    self.pendingDisconnectSource = nil;
    self.activeStreamGeneration += 1;
    NSUInteger streamGeneration = self.activeStreamGeneration;

    // Defensive cleanup: avoid overlapping stream operations when a previous attempt
    // hasn't fully quiesced yet.
    StreamManager *previousStreamMan = self.streamMan;
    self.streamMan = nil;
    if (self.streamOpQueue) {
        [self.streamOpQueue cancelAllOperations];
    }
    if (previousStreamMan) {
        [previousStreamMan stopStream];
    }

    StreamConfiguration *streamConfig = [[StreamConfiguration alloc] init];
    
    streamConfig.host = self.app.host.activeAddress;
    streamConfig.hostUUID = self.app.host.uuid;
    
    NSDictionary* prefs = [SettingsClass getSettingsFor:self.app.host.uuid];
    NSString *selectedConnectionMethod = nil;
    if (prefs) {
        selectedConnectionMethod = prefs[@"connectionMethod"];
        if (selectedConnectionMethod && ![selectedConnectionMethod isEqualToString:@"Auto"]) {
            streamConfig.host = selectedConnectionMethod;
        }
    }
    Log(LOG_I, @"[diag] Stream target selection: method=%@ active=%@ local=%@ address=%@ external=%@ ipv6=%@",
        selectedConnectionMethod ?: @"Auto",
        self.app.host.activeAddress ?: @"",
        self.app.host.localAddress ?: @"",
        self.app.host.address ?: @"",
        self.app.host.externalAddress ?: @"",
        self.app.host.ipv6Address ?: @"");

    BOOL vpnActive = [Utils isActiveNetworkVPN];
    BOOL remoteByAddress = [self isRemoteStreamTargetAddress:streamConfig.host];
    NSString *egressSource = nil;
    NSString *egressIf = [Utils outboundInterfaceNameForAddress:streamConfig.host sourceAddress:&egressSource];
    BOOL routeKnown = egressIf.length > 0;
    BOOL remoteByRoute = routeKnown && [Utils isTunnelInterfaceName:egressIf];
    BOOL remoteByVpnFallback = vpnActive && !routeKnown;
    streamConfig.streamingRemotely = remoteByAddress || remoteByRoute || remoteByVpnFallback;

    NSMutableArray<NSString *> *reasonParts = [NSMutableArray array];
    if (streamConfig.streamingRemotely) {
        if (remoteByRoute) {
            [reasonParts addObject:[NSString stringWithFormat:@"route-via-%@", egressIf]];
        }
        if (remoteByAddress) {
            [reasonParts addObject:@"address-public-or-external"];
        }
        if (remoteByVpnFallback) {
            [reasonParts addObject:@"vpn-fallback-no-route"];
        }
    } else {
        if (routeKnown) {
            [reasonParts addObject:[NSString stringWithFormat:@"route-via-%@", egressIf]];
        } else {
            [reasonParts addObject:@"route-unknown-no-vpn"];
        }
        if (!remoteByAddress) {
            [reasonParts addObject:@"address-private-or-local"];
        }
    }
    NSString *classifyReason = reasonParts.count > 0 ? [reasonParts componentsJoinedByString:@","] : @"n/a";

    Log(LOG_I, @"[diag] Stream target classification: host=%@ remote=%d local=%d vpn=%d byAddress=%d byRoute=%d byVpnFallback=%d egressIf=%@ source=%@ main=%@ ipv6=%@ external=%@ reason=%@",
        streamConfig.host ?: @"(null)",
        streamConfig.streamingRemotely ? 1 : 0,
        streamConfig.streamingRemotely ? 0 : 1,
        vpnActive ? 1 : 0,
        remoteByAddress ? 1 : 0,
        remoteByRoute ? 1 : 0,
        remoteByVpnFallback ? 1 : 0,
        egressIf ?: @"(unknown)",
        egressSource ?: @"",
        self.app.host.localAddress ?: @"",
        self.app.host.ipv6Address ?: @"",
        self.app.host.externalAddress ?: @"",
        classifyReason);
    
    streamConfig.appID = self.app.id;
    streamConfig.appName = self.app.name;
    streamConfig.serverCert = self.app.host.serverCert;
    streamConfig.serverCodecModeSupport = self.app.host.serverCodecModeSupport;
    
    DataManager* dataMan = [[DataManager alloc] init];
    TemporarySettings* streamSettings = [dataMan getSettings];
    
    streamConfig.width = [self.class getResolution].width;
    streamConfig.height = [self.class getResolution].height;

    streamConfig.frameRate = [streamSettings.framerate intValue];

    // Apply resolution scaling (mirrors moonlight-qt behavior)
    BOOL scaleEnabled = prefs ? [prefs[@"streamResolutionScale"] boolValue] : NO;
    int scaleRatio = prefs ? [prefs[@"streamResolutionScaleRatio"] intValue] : 100;
    if (scaleEnabled && scaleRatio > 0 && scaleRatio != 100) {
        int scaledWidth = streamConfig.width * scaleRatio / 100;
        int scaledHeight = streamConfig.height * scaleRatio / 100;
        streamConfig.width = (scaledWidth / 8) * 8;
        streamConfig.height = (scaledHeight / 8) * 8;
    }

    // Default bitrate (may be overridden by auto-adjust below)
    streamConfig.bitRate = [streamSettings.bitrate intValue];

    BOOL enableYuv444 = prefs ? [prefs[@"yuv444"] boolValue] : NO;
    int modeWidth = streamConfig.width;
    int modeHeight = streamConfig.height;
    int modeFps = streamConfig.frameRate;

    // Incorporate remote overrides (host render mode) for bitrate calculation and risk assessment
    if (prefs != nil) {
        if ([prefs[@"remoteResolution"] boolValue]) {
            int rw = [prefs[@"remoteResolutionWidth"] intValue];
            int rh = [prefs[@"remoteResolutionHeight"] intValue];
            if (rw > 0 && rh > 0) {
                modeWidth = rw;
                modeHeight = rh;
            }
        }
        if ([prefs[@"remoteFps"] boolValue]) {
            int rfps = [prefs[@"remoteFpsRate"] intValue];
            if (rfps > 0) {
                modeFps = rfps;
            }
        }
    }

    // Keep even dimensions
    modeWidth &= ~1;
    modeHeight &= ~1;

    // Auto-adjust bitrate (mirrors moonlight-qt default algorithm)
    BOOL autoAdjustBitrate = prefs ? [prefs[@"autoAdjustBitrate"] boolValue] : NO;
    streamConfig.autoAdjustBitrate = autoAdjustBitrate;
    if (!autoAdjustBitrate) {
        self.runtimeAutoBitrateCapKbps = 0;
        self.runtimeAutoBitrateBaselineKbps = 0;
        self.runtimeAutoBitrateStableStreak = 0;
        self.runtimeAutoBitrateLastRaiseMs = 0;
    }
    if (autoAdjustBitrate) {
        // Copied from moonlight-qt (StreamingPreferences::getDefaultBitrate)
        float frameRateFactor = (modeFps <= 60 ? (float)modeFps : (sqrtf((float)modeFps / 60.f) * 60.f)) / 30.f;

        struct ResEntry { int pixels; int factor; };
        static const struct ResEntry resTable[] = {
            { 640 * 360, 1 },
            { 854 * 480, 2 },
            { 1280 * 720, 5 },
            { 1920 * 1080, 10 },
            { 2560 * 1440, 20 },
            { 3840 * 2160, 40 },
            { -1, -1 },
        };

        int pixels = modeWidth * modeHeight;
        float resolutionFactor = 10.f;
        for (int i = 0;; i++) {
            if (pixels == resTable[i].pixels) {
                resolutionFactor = (float)resTable[i].factor;
                break;
            } else if (pixels < resTable[i].pixels) {
                if (i == 0) {
                    resolutionFactor = (float)resTable[i].factor;
                } else {
                    resolutionFactor = ((float)(pixels - resTable[i-1].pixels) / (resTable[i].pixels - resTable[i-1].pixels)) * (resTable[i].factor - resTable[i-1].factor) + resTable[i-1].factor;
                }
                break;
            } else if (resTable[i].pixels == -1) {
                resolutionFactor = (float)resTable[i-1].factor;
                break;
            }
        }

        if (enableYuv444) {
            resolutionFactor *= 2.f;
        }

        int defaultKbps = (int)lroundf(resolutionFactor * frameRateFactor) * 1000;
        streamConfig.bitRate = defaultKbps;
        self.runtimeAutoBitrateBaselineKbps = streamConfig.bitRate;
        if (self.runtimeAutoBitrateCapKbps > 0 && self.runtimeAutoBitrateCapKbps > streamConfig.bitRate) {
            self.runtimeAutoBitrateCapKbps = streamConfig.bitRate;
        }
        if (self.runtimeAutoBitrateCapKbps > 0 && streamConfig.bitRate > self.runtimeAutoBitrateCapKbps) {
            Log(LOG_I, @"[diag] Runtime auto bitrate cap applied: %d -> %ld kbps",
                streamConfig.bitRate,
                (long)self.runtimeAutoBitrateCapKbps);
            streamConfig.bitRate = (int)self.runtimeAutoBitrateCapKbps;
        }
    }
    streamConfig.optimizeGameSettings = streamSettings.optimizeGames;
    streamConfig.playAudioOnPC = streamSettings.playAudioOnPC;
    NSInteger codecPreference = [SettingsClass videoCodecFor:self.app.host.uuid];
    streamConfig.videoCodecPreference = (int)MAX(0, MIN(codecPreference, 2));

    BOOL hevcDecodeSupported = NO;
    if (@available(iOS 11.3, tvOS 11.3, macOS 10.14, *)) {
        hevcDecodeSupported = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC);
    }
    BOOL av1DecodeSupported = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1);

    streamConfig.allowHevc = streamConfig.videoCodecPreference != 0;
    if (streamConfig.videoCodecPreference == 2) {
        streamConfig.enableHdr = streamSettings.enableHdr && av1DecodeSupported;
    } else if (streamConfig.videoCodecPreference == 1) {
        streamConfig.enableHdr = streamSettings.enableHdr && hevcDecodeSupported;
    } else {
        streamConfig.enableHdr = NO;
    }

    NSString *codecName = @"H.264";
    if (streamConfig.videoCodecPreference == 2) {
        codecName = @"AV1";
    } else if (streamConfig.videoCodecPreference == 1) {
        codecName = @"H.265";
    }
    self.currentStreamRiskAssessment = [StreamRiskAssessor assessWithHost:self.app.host
                                                            targetAddress:streamConfig.host
                                                         connectionMethod:selectedConnectionMethod
                                                                    width:modeWidth
                                                                   height:modeHeight
                                                                      fps:modeFps
                                                              bitrateKbps:streamConfig.bitRate
                                                                codecName:codecName
                                                             enableYUV444:enableYuv444
                                                                 autoMode:autoAdjustBitrate];
    Log(LOG_I, @"[diag] Stream risk assessment: %@ codec=%@ chroma=%@ decode=%d target=%@",
        self.currentStreamRiskAssessment.summaryLine ?: @"(none)",
        self.currentStreamRiskAssessment.codecName ?: codecName,
        self.currentStreamRiskAssessment.chromaName ?: (enableYuv444 ? @"4:4:4" : @"4:2:0"),
        self.currentStreamRiskAssessment.decodeSupported ? 1 : 0,
        self.currentStreamRiskAssessment.targetAddress ?: streamConfig.host ?: @"(null)");
    if (self.currentStreamRiskAssessment.recommendedFallbacks.count > 0) {
        StreamRiskRecommendation *firstRecommendation = self.currentStreamRiskAssessment.recommendedFallbacks.firstObject;
        Log(LOG_I, @"[diag] Recommended fallback: %@", firstRecommendation.summaryLine ?: @"(none)");
    }
    if (streamConfig.videoCodecPreference == 2) {
        Log(LOG_I, @"[diag] AV1 preference: serverAdvertises=%d localDecode=%d hdr=%d yuv444=%d",
            (self.app.host.serverCodecModeSupport & SCM_MASK_AV1) != 0 ? 1 : 0,
            av1DecodeSupported ? 1 : 0,
            streamConfig.enableHdr ? 1 : 0,
            enableYuv444 ? 1 : 0);
    }

    streamConfig.multiController = streamSettings.multiController;
    streamConfig.gamepadMask = self.useSystemControllerDriver ? (int)[ControllerSupport getConnectedGamepadMask:streamConfig] : 1;
    
    NSInteger audioConfigSelection = [SettingsClass audioConfigurationFor:self.app.host.uuid];
    int audioConfig = AUDIO_CONFIGURATION_STEREO;
    if (audioConfigSelection == 1) {
        audioConfig = AUDIO_CONFIGURATION_51_SURROUND;
    } else if (audioConfigSelection == 2) {
        audioConfig = AUDIO_CONFIGURATION_71_SURROUND;
    }
    streamConfig.audioConfiguration = audioConfig;
    
    streamConfig.framePacingMode = (int)[SettingsClass framePacingFor:self.app.host.uuid];
    streamConfig.smoothnessLatencyMode = (int)[SettingsClass smoothnessLatencyModeFor:self.app.host.uuid];
    streamConfig.timingBufferLevel = (int)[SettingsClass timingBufferLevelFor:self.app.host.uuid];
    streamConfig.timingPrioritizeResponsiveness = [SettingsClass timingPrioritizeResponsivenessFor:self.app.host.uuid];
    streamConfig.timingCompatibilityMode = [SettingsClass timingCompatibilityModeFor:self.app.host.uuid];
    streamConfig.timingSdrCompatibilityWorkaround = [SettingsClass timingSdrCompatibilityWorkaroundFor:self.app.host.uuid];
    streamConfig.enableVsync = [SettingsClass enableVsyncFor:self.app.host.uuid];
    streamConfig.showPerformanceOverlay = [SettingsClass showPerformanceOverlayFor:self.app.host.uuid];
    streamConfig.gamepadMouseMode = [SettingsClass gamepadMouseModeFor:self.app.host.uuid];
    streamConfig.upscalingMode = (int)[SettingsClass upscalingModeFor:self.app.host.uuid];
    Log(LOG_I, @"[diag] Stream timing config: preset=%d framePacing=%d buffer=%d responsiveness=%d compatibility=%d vsync=%d sdrCompat=%d",
        (int)streamConfig.smoothnessLatencyMode,
        (int)streamConfig.framePacingMode,
        (int)streamConfig.timingBufferLevel,
        streamConfig.timingPrioritizeResponsiveness ? 1 : 0,
        streamConfig.timingCompatibilityMode ? 1 : 0,
        streamConfig.enableVsync ? 1 : 0,
        streamConfig.timingSdrCompatibilityWorkaround ? 1 : 0);
    [[AwdlHelperManager sharedManager] beginStreamSessionIfEnabled:[SettingsClass awdlStabilityHelperEnabled]
                                                        generation:streamGeneration];

    if (self.useSystemControllerDriver) {

        if (@available(iOS 13, tvOS 13, macOS 10.15, *)) {
            self.controllerSupport = [[ControllerSupport alloc] initWithConfig:streamConfig presenceDelegate:self];
        }
    }
    self.hidSupport = [[HIDSupport alloc] init:self.app.host];
    __weak typeof(self) weakSelf = self;
    self.hidSupport.freeMouseAbsoluteSyncHandler = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.isRemoteDesktopMode || !strongSelf.isMouseCaptured) {
            return;
        }
        strongSelf.pendingHybridRemoteCursorSync = NO;
        [strongSelf reconcileHybridFreeMouseAnchorToCurrentPointer];
    };
    [self resetInputDiagnosticsState];
    [self refreshInputDiagnosticsPreference];
    
    id<ConnectionCallbacks> scopedCallbacks = [[MLStreamScopedConnectionCallbacks alloc] initWithOwner:self generation:streamGeneration];
    self.streamMan = [[StreamManager alloc] initWithConfig:streamConfig renderView:self.view connectionCallbacks:scopedCallbacks];
    if (!self.streamOpQueue) {
        self.streamOpQueue = [[NSOperationQueue alloc] init];
        self.streamOpQueue.maxConcurrentOperationCount = 1;
    }
    [self.streamOpQueue addOperation:self.streamMan];

    [self startConnectWatchdog];
    
    // Don’t create the overlay before streaming starts. The video view may be inserted later
    // and would otherwise cover the overlay.
}

+ (struct Resolution)getResolution {
    DataManager* dataMan = [[DataManager alloc] init];
    TemporarySettings* streamSettings = [dataMan getSettings];

    struct Resolution resolution;
    
    resolution.width = [streamSettings.width intValue];
    resolution.height = [streamSettings.height intValue];

    return resolution;
}


#pragma mark - ConnectionCallbacks

- (void)stageStarting:(const char *)stageName {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *lowerCase = [NSString stringWithFormat:@"%s in progress...", stageName];
        NSString *titleCase = [[[lowerCase substringToIndex:1] uppercaseString] stringByAppendingString:[lowerCase substringFromIndex:1]];
        self.streamView.statusText = titleCase;
    });
}

- (void)stageComplete:(const char *)stageName {
    if (stageName == NULL) {
        return;
    }

    // Ensure input context is bound as soon as input stream establishment completes.
    if (strcmp(stageName, "input stream establishment") == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            void *inputContext = self.streamMan.connection ? [self.streamMan.connection inputStreamContext] : NULL;
            if (inputContext == NULL) {
                Log(LOG_W, @"Input stream established but inputContext is NULL");
                return;
            }
            PML_INPUT_STREAM_CONTEXT ctx = (PML_INPUT_STREAM_CONTEXT)inputContext;
            Log(LOG_I, @"Input stream established: ctx=%p initialized=%d libInit=%d libConn=%p", ctx, ctx->initialized, LiInputContextIsInitialized(ctx), LiInputContextGetConnectionCtx(ctx));
            if (ctx->initialized) {
                self.hidSupport.inputContext = inputContext;
                self.controllerSupport.inputContext = inputContext;
                self.hidSupport.shouldSendInputEvents = YES;
                self.controllerSupport.shouldSendInputEvents = YES;
                [self rearmMouseCaptureIfPossibleWithReason:@"input-stream-established"];
            }
        });
    }
}

- (void)connectionStarted {
    Log(LOG_I, @"[diag] StreamViewController connectionStarted received: main=%d activeGen=%lu",
        [NSThread isMainThread] ? 1 : 0,
        (unsigned long)self.activeStreamGeneration);
    Connection *callbackConn = [Connection currentConnection];
    void *callbackInputContext = callbackConn ? [callbackConn inputStreamContext] : NULL;
    dispatch_async(dispatch_get_main_queue(), ^{
        Log(LOG_I, @"[diag] StreamViewController connectionStarted main block begin: window=%p callbackConn=%p callbackInput=%p streamConn=%p",
            self.view.window,
            callbackConn,
            callbackInputContext,
            self.streamMan.connection);
        @try {
                // Notify session manager (main-thread only for window access)
                [[StreamingSessionManager shared] startStreamingWithHost:self.app.host.uuid
                                                                                                                     appId:self.app.id
                                                                                                                 appName:self.app.name
                                                                                                windowController:self.view.window.windowController];

                void *inputContext = callbackInputContext;
                if (!inputContext && self.streamMan.connection) {
                    inputContext = [self.streamMan.connection inputStreamContext];
                }
                if (inputContext) {
                    PML_INPUT_STREAM_CONTEXT ctx = (PML_INPUT_STREAM_CONTEXT)inputContext;
                    Log(LOG_I, @"Input ABI: size=%u off_init=%u off_conn=%u", LiGetInputContextStructSize(), LiGetInputContextOffsetInitialized(), LiGetInputContextOffsetConnectionContext());
                    Log(LOG_I, @"Binding input context on connection start: ctx=%p initialized=%d libInit=%d libConn=%p", ctx, ctx->initialized, LiInputContextIsInitialized(ctx), LiInputContextGetConnectionCtx(ctx));
                    self.hidSupport.inputContext = inputContext;
                    self.controllerSupport.inputContext = inputContext;
                    // Ensure input is enabled immediately after stream start
                    self.hidSupport.shouldSendInputEvents = YES;
                    self.controllerSupport.shouldSendInputEvents = YES;

                    // If input stream isn't initialized yet, retry briefly to bind after start
                    __block int remainingAttempts = 20;
                    __weak typeof(self) weakSelf = self;
                    __block void (^retryBind)(void) = nil;
                    __weak void (^weakRetryBind)(void) = nil;
                    retryBind = ^{
                        __strong typeof(weakSelf) strongSelf = weakSelf;
                        if (!strongSelf) {
                            return;
                        }
                        PML_INPUT_STREAM_CONTEXT ctx = (PML_INPUT_STREAM_CONTEXT)inputContext;
                        if (ctx != NULL && LiInputContextIsInitialized(ctx)) {
                            strongSelf.hidSupport.inputContext = inputContext;
                            strongSelf.controllerSupport.inputContext = inputContext;
                            [strongSelf rearmMouseCaptureIfPossibleWithReason:@"input-context-retry-bound"];
                            return;
                        }
                        if (remainingAttempts-- <= 0) {
                            Log(LOG_W, @"Input context still not initialized after retries");
                            return;
                        }
                        void (^strongRetryBind)(void) = weakRetryBind;
                        if (!strongRetryBind) {
                            return;
                        }
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), strongRetryBind);
                    };
                    weakRetryBind = retryBind;
                    retryBind();
                }

        self.streamView.statusText = nil;
        self.pendingDisconnectSource = nil;
        [self startStreamHealthDiagnostics];
        self.streamHealthConnectionStartedMs = [self nowMs];
        [self refreshInputDiagnosticsPreference];

        Log(LOG_I, @"connectionStarted (t=%.0fms) window style=%llu level=%ld", CACurrentMediaTime() * 1000.0, (unsigned long long)self.view.window.styleMask, (long)self.view.window.level);

        BOOL wasReconnect = self.reconnectInProgress;
        if (self.reconnectInProgress) {
            self.reconnectInProgress = NO;
            [self hideReconnectOverlay];
        }

        // Create overlay after streaming starts so it stays on top of the video view.
        if ([SettingsClass showPerformanceOverlayFor:self.app.host.uuid] && !self.overlayContainer) {
            [self setupOverlay];
        }
        
        NSInteger displayMode = [SettingsClass displayModeFor:self.app.host.uuid];
        // 0: Windowed, 1: Fullscreen, 2: Borderless Windowed
        
        if (wasReconnect && self.reconnectPreserveFullscreenStateValid) {
            // If we were reconnecting, try to preserve state
            displayMode = self.reconnectPreservedWindowMode;
        }
        self.reconnectPreserveFullscreenStateValid = NO;
        NSString *displayModeName = [self displayModeDebugName:displayMode];
        Log(LOG_I, @"[diag] connectionStarted display mode=%ld (%@) wasReconnect=%d",
            (long)displayMode,
            displayModeName,
            wasReconnect ? 1 : 0);
        [self resetEdgeMenuPlacementForNewStreamSession];
        [self logCurrentWindowStateWithContext:@"connection-started-before-capture"];

        // Make the stream interactive as soon as we have video.
        // Without this, fullscreen transitions can leave input disabled until AppKit
        // finishes space/key-window transitions, which can take several seconds.
        [self captureMouse];
        [self logCurrentWindowStateWithContext:@"connection-started-after-capture"];

        NSInteger startupDisplayMode = displayMode;
        NSTimeInterval startupDisplayDelay = (startupDisplayMode == 0) ? 0.0 : 0.12;
        Log(LOG_I, @"[diag] Scheduling startup display mode apply: mode=%ld (%@) delay=%.2fs",
            (long)startupDisplayMode,
            displayModeName,
            startupDisplayDelay);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(startupDisplayDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self applyStartupDisplayMode:startupDisplayMode];
        });

        // Re-assert capture shortly after mode switches in case AppKit temporarily steals focus.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((startupDisplayDelay + 0.35) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!self.isMouseCaptured) {
                [self captureMouse];
            }
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            VideoStats stats = (VideoStats){0};
            if (self.streamMan.connection && self.streamMan.connection.renderer) {
                stats = self.streamMan.connection.renderer.videoStats;
            }
            [self logCurrentWindowStateWithContext:@"post-start-checkpoint-1s"];
            Log(LOG_D, @"[diag] Post-start checkpoint: rf=%u df=%u ren=%u total=%u bytes=%llu captured=%d input=%d",
                stats.receivedFrames,
                stats.decodedFrames,
                stats.renderedFrames,
                stats.totalFrames,
                (unsigned long long)stats.receivedBytes,
                self.isMouseCaptured ? 1 : 0,
                self.hidSupport.shouldSendInputEvents ? 1 : 0);
        });
        } @catch (NSException *exception) {
            Log(LOG_E, @"[diag] connectionStarted main block exception: %@ - %@",
                exception.name ?: @"(unknown)",
                exception.reason ?: @"(no reason)");
        }
    });
}

- (void)connectionTerminated:(int)errorCode {
    Log(LOG_I, @"Connection terminated: %ld (0x%08x)", (long)errorCode, (unsigned int)errorCode);
    [self stopStreamHealthDiagnostics];
    [self finalizeInputDiagnosticsWithReason:[NSString stringWithFormat:@"connection-terminated:%d", errorCode]];
    self.streamHealthConnectionStartedMs = 0;
    [self logStreamHealthSummaryWithReason:[NSString stringWithFormat:@"connection-terminated:%d", errorCode]];
    [[AwdlHelperManager sharedManager] endStreamSessionWithReason:[NSString stringWithFormat:@"connection-terminated:%d", errorCode]];

    // Notify session manager
    if (self.app.host.uuid) {
        [[StreamingSessionManager shared] didDisconnectForHost:self.app.host.uuid];
    }

    self.hidSupport.inputContext = NULL;
    self.controllerSupport.inputContext = NULL;

    dispatch_async(dispatch_get_main_queue(), ^{
        [self hideConnectionTimeoutOverlay];
        if (self.statsTimer) {
            [self.statsTimer invalidate];
            self.statsTimer = nil;
        }
        if (self.overlayContainer) {
            [self.overlayContainer removeFromSuperview];
            self.overlayContainer = nil;
            self.overlayLabel = nil;
        }
        if (self.mouseModeContainer) {
            [self.mouseModeContainer removeFromSuperview];
            self.mouseModeContainer = nil;
            self.mouseModeLabel = nil;
        }
        if (self.edgeMenuPanel) {
            [self.edgeMenuPanel orderOut:nil];
        }

        if (self.reconnectInProgress) {
            return;
        }
        
        // If it was user initiated, just close normally.
        if (self.disconnectWasUserInitiated) {
             if ([SettingsClass quitAppAfterStreamFor:self.app.host.uuid]) {
                 [self.delegate quitApp:self.app completion:nil];
             } else {
                 [self closeWindowFromMainQueueWithMessage:nil];
             }
             return;
        }
        
        // Once a stream has been established, any termination here should close the stream window
        // instead of leaving the last frame or an error page behind. Launch/setup failures are
        // handled separately by stageFailed/launchFailed.
        if (errorCode != 0) {
            Log(LOG_W, @"[diag] Closing stream window after non-zero termination code: %d", errorCode);
        }

        if ([SettingsClass quitAppAfterStreamFor:self.app.host.uuid]) {
            [self.delegate quitApp:self.app completion:nil];
        } else {
            [self closeWindowFromMainQueueWithMessage:nil];
        }
    });
}

- (void)stageFailed:(const char *)stageName withError:(int)errorCode {
    Log(LOG_I, @"Stage %s failed: %ld", stageName, errorCode);
    self.connectWatchdogToken += 1;
    [self stopStreamHealthDiagnostics];
    [self finalizeInputDiagnosticsWithReason:[NSString stringWithFormat:@"stage-failed:%s", stageName ?: "unknown"]];
    self.streamHealthConnectionStartedMs = 0;
    [[AwdlHelperManager sharedManager] endStreamSessionWithReason:[NSString stringWithFormat:@"stage-failed:%s", stageName ?: "unknown"]];
    if (self.streamMan) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [weakSelf.streamMan stopStream];
        });
    }
    [self closeWindowFromMainQueueWithMessage:[NSString stringWithFormat:@"%s failed with error %d", stageName, errorCode]];
}

- (void)launchFailed:(NSString *)message {
    self.connectWatchdogToken += 1;
    [self stopStreamHealthDiagnostics];
    [self finalizeInputDiagnosticsWithReason:@"launch-failed"];
    self.streamHealthConnectionStartedMs = 0;
    [[AwdlHelperManager sharedManager] endStreamSessionWithReason:@"launch-failed"];
    if (self.streamMan) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [weakSelf.streamMan stopStream];
        });
    }
    [self closeWindowFromMainQueueWithMessage:message];
}

- (void)rumble:(unsigned short)controllerNumber lowFreqMotor:(unsigned short)lowFreqMotor highFreqMotor:(unsigned short)highFreqMotor {
    if ([SettingsClass rumbleFor:self.app.host.uuid]) {
        if (self.hidSupport.shouldSendInputEvents) {
            if (self.controllerSupport != nil) {
                [self.controllerSupport rumble:controllerNumber lowFreqMotor:lowFreqMotor highFreqMotor:highFreqMotor];
            } else {
                [self.hidSupport rumbleLowFreqMotor:lowFreqMotor highFreqMotor:highFreqMotor];
            }
        }
    }
}

- (void)connectionStatusUpdate:(int)status {
    dispatch_async(dispatch_get_main_queue(), ^{
        Log(LOG_I, @"[diag] Connection status update: status=%d captured=%d input=%d reconnect=%d stopInProgress=%d",
            status,
            self.isMouseCaptured ? 1 : 0,
            self.hidSupport.shouldSendInputEvents ? 1 : 0,
            self.reconnectInProgress ? 1 : 0,
            self.stopStreamInProgress ? 1 : 0);
        uint64_t now = [self nowMs];
        if (status == CONN_STATUS_POOR) {
            if (self.lastConnectionStatus != CONN_STATUS_POOR) {
                if (self.connectionPoorStatusBurstWindowStartMs == 0 ||
                    now - self.connectionPoorStatusBurstWindowStartMs > 25000) {
                    self.connectionPoorStatusBurstWindowStartMs = now;
                    self.connectionPoorStatusBurstCount = 1;
                } else {
                    self.connectionPoorStatusBurstCount += 1;
                }
            }

            if (self.connectionPoorStatusBurstCount >= 2) {
                Log(LOG_W, @"[diag] Connection status flap detected (poor bursts=%lu in %.1fs), attempting adaptive mitigation",
                    (unsigned long)self.connectionPoorStatusBurstCount,
                    (now - self.connectionPoorStatusBurstWindowStartMs) / 1000.0);
                self.connectionPoorStatusBurstCount = 0;
                self.connectionPoorStatusBurstWindowStartMs = now;
                [self attemptAdaptiveMitigationForDropRate:100.0f];
            }

            if (self.disconnectWasUserInitiated || now < self.suppressConnectionWarningsUntilMs) {
                // Avoid showing a misleading warning during intentional teardown/detach.
                [self hideConnectionWarning];
            } else if ([SettingsClass showConnectionWarningsFor:self.app.host.uuid]) {
                [self showConnectionWarning];
            }
        } else if (status == CONN_STATUS_OKAY) {
            [self hideConnectionWarning];
            if (self.lastConnectionStatus == CONN_STATUS_POOR &&
                (self.connectionLastIdrRequestMs == 0 || now - self.connectionLastIdrRequestMs > 3000)) {
                LiRequestIdrFrame();
                self.connectionLastIdrRequestMs = now;
                Log(LOG_I, @"[diag] Requested IDR on POOR->OKAY transition");
            }
        }
        self.lastConnectionStatus = status;
    });
}

@end
