//
//  StreamViewController+Diagnostics.m
//  Moonlight for macOS
//

#import "StreamViewController_Internal.h"

@implementation StreamViewController (Diagnostics)

- (BOOL)hasReceivedAnyVideoFrames {
    @try {
        if (!self.streamMan) {
            return NO;
        }
        VideoStats stats = self.streamMan.connection.renderer.videoStats;
        uint64_t nowStatsMs = LiGetMillis();
        BOOL statsTimestampValid = (stats.lastUpdatedTimestamp > 0 && nowStatsMs >= stats.lastUpdatedTimestamp);
        uint64_t statsAgeMs = statsTimestampValid ? (nowStatsMs - stats.lastUpdatedTimestamp) : UINT64_MAX;
        BOOL statsFresh = statsTimestampValid && statsAgeMs <= 2000;
        BOOL hasPayloadInWindow = (stats.receivedFrames > 0 || stats.receivedBytes > 0 || stats.receivedFps > 0.1f);
        BOOL hasFreshPayload = (statsFresh || !statsTimestampValid) && hasPayloadInWindow;

        if (hasFreshPayload) {
            return YES;
        }
        if (self.streamHealthSawPayload) {
            return YES;
        }
        if (self.streamHealthLastReceivedFrames > 0 || self.streamHealthLastReceivedBytes > 0) {
            return YES;
        }
        return NO;
    } @catch (NSException *ex) {
        return NO;
    }
}

- (void)startConnectWatchdog {
    self.connectWatchdogToken += 1;
    self.connectWatchdogStartMs = [self nowMs];
    NSInteger token = self.connectWatchdogToken;
    [self scheduleConnectWatchdogCheckForToken:token delay:15.0];
}

- (void)scheduleConnectWatchdogCheckForToken:(NSInteger)token delay:(NSTimeInterval)delay {
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(self) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        if (token != strongSelf.connectWatchdogToken) {
            return;
        }

        // If we have video frames, the connection is alive.
        if ([strongSelf hasReceivedAnyVideoFrames]) {
            return;
        }

        if (strongSelf.timeoutOverlayContainer) {
            return;
        }

        uint64_t nowMs = [strongSelf nowMs];
        uint64_t elapsedMs = (strongSelf.connectWatchdogStartMs > 0 && nowMs >= strongSelf.connectWatchdogStartMs)
            ? (nowMs - strongSelf.connectWatchdogStartMs)
            : 0;
        BOOL connectionObjectReady = strongSelf.streamMan != nil && strongSelf.streamMan.connection != nil;

        // Don't treat a slow /launch or /resume as a dead stream. Until the Connection
        // object exists, we haven't even entered RTSP/video startup yet, so reconnecting
        // here just kills a still-starting session and often makes the second attempt fail.
        static const uint64_t kPreConnectionGraceMs = 45000;
        static const NSTimeInterval kPreConnectionPollIntervalSec = 5.0;
        if (!connectionObjectReady) {
            if (elapsedMs < kPreConnectionGraceMs) {
                Log(LOG_I, @"[diag] Connect watchdog deferred: still waiting for host launch/resume (elapsed=%.1fs)",
                    elapsedMs / 1000.0);
                [strongSelf scheduleConnectWatchdogCheckForToken:token delay:kPreConnectionPollIntervalSec];
                return;
            }

            NSString *timeoutMessage = @"主机仍在启动或恢复串流，会比视频阶段慢很多。\n可继续等待，或手动重连 / 返回后重新进入。";
            [strongSelf showErrorOverlayWithTitle:@"主机启动较慢"
                                          message:timeoutMessage
                                          canWait:YES];
            return;
        }
        
        // If we are stuck in reconnecting state for > 10s, force error overlay
        if (strongSelf.reconnectInProgress) {
            [strongSelf hideReconnectOverlay];
            strongSelf.reconnectInProgress = NO;
            [strongSelf showErrorOverlayWithTitle:@"重连超时"
                                          message:@"重连过程耗时过长，连接可能已断开。\n请检查网络环境或调整设置。"
                                          canWait:NO];
            return;
        }

        // 15s with no frames: auto mode attempts a single reconnect; manual expert mode surfaces diagnostics only.
        if (!strongSelf.didAutoReconnectAfterTimeout &&
            strongSelf.shouldAttemptReconnect &&
            [strongSelf isAutomaticRecoveryModeEnabled]) {
            strongSelf.didAutoReconnectAfterTimeout = YES;
            [strongSelf showReconnectOverlayWithMessage:@"网络无响应，正在尝试重连…"]; 
            [strongSelf attemptReconnectWithReason:@"connect-timeout-auto"]; 
            return;
        }

        NSString *timeoutMessage = [strongSelf isAutomaticRecoveryModeEnabled]
            ? @"已持续 15 秒未接收到视频数据。\n请检查网络连接或尝试以下操作。"
            : [NSString stringWithFormat:@"%@\n%@\n%@",
                MLString(@"No new video frame has arrived for 15 seconds.", @"Manual timeout lead message"),
                MLString(@"Manual mode won't change your resolution, frame rate, codec, or chroma automatically.", @"Manual timeout manual mode explanation"),
                MLString(@"You can keep waiting, reconnect manually, or apply a recommended profile.", @"Manual timeout actions")];
        [strongSelf showErrorOverlayWithTitle:@"连接不稳定或无画面"
                                      message:timeoutMessage
                                      canWait:YES];
    });
}

- (void)showErrorOverlayWithTitle:(NSString *)title message:(NSString *)message canWait:(BOOL)canWait {
    // 显示弹窗时释放键鼠捕获，让用户可以自由移动鼠标点击按钮
    [self uncaptureMouseWithCode:@"MUC401" reason:@"show-error-overlay"];

    if (!self.timeoutOverlayContainer) {
        NSVisualEffectView *container = [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
        container.material = NSVisualEffectMaterialHUDWindow;
        container.blendingMode = NSVisualEffectBlendingModeWithinWindow;
        container.state = NSVisualEffectStateActive;
        container.wantsLayer = YES;
        container.alphaValue = 0.0;
        
        // 为 NSVisualEffectView 设置圆角需要使用 maskedCorners
        container.layer.cornerRadius = 24.0;
        if (@available(macOS 10.13, *)) {
            container.layer.cornerCurve = kCACornerCurveContinuous;
            container.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner | kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
        }
        container.layer.masksToBounds = YES;
        
        // Shadow for better visibility
        NSShadow *shadow = [[NSShadow alloc] init];
        shadow.shadowBlurRadius = 20.0;
        shadow.shadowColor = [NSColor colorWithWhite:0.0 alpha:0.3];
        shadow.shadowOffset = NSMakeSize(0, -5);
        container.shadow = shadow;

        // Icon
        NSTextField *iconLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
        iconLabel.bezeled = NO;
        iconLabel.drawsBackground = NO;
        iconLabel.editable = NO;
        iconLabel.selectable = NO;
        iconLabel.alignment = NSTextAlignmentCenter;
        iconLabel.font = [NSFont systemFontOfSize:56 weight:NSFontWeightRegular];
        iconLabel.textColor = [NSColor systemYellowColor];
        iconLabel.stringValue = @"⚠️";

        // Title
        NSTextField *titleLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
        titleLabel.bezeled = NO;
        titleLabel.drawsBackground = NO;
        titleLabel.editable = NO;
        titleLabel.selectable = NO;
        titleLabel.alignment = NSTextAlignmentCenter;
        titleLabel.font = [NSFont systemFontOfSize:22 weight:NSFontWeightBold];
        titleLabel.textColor = [NSColor whiteColor];

        // Message
        NSTextField *label = [[NSTextField alloc] initWithFrame:NSZeroRect];
        label.bezeled = NO;
        label.drawsBackground = NO;
        label.editable = NO;
        label.selectable = YES; // Allow copying error message
        label.alignment = NSTextAlignmentCenter;
        label.font = [NSFont systemFontOfSize:14 weight:NSFontWeightMedium];
        label.textColor = [NSColor colorWithWhite:0.9 alpha:1.0];
        if ([label.cell isKindOfClass:[NSTextFieldCell class]]) {
            NSTextFieldCell *cell = (NSTextFieldCell *)label.cell;
            cell.wraps = YES;
            cell.scrollable = NO;
            cell.usesSingleLineMode = NO;
            cell.lineBreakMode = NSLineBreakByWordWrapping;
            cell.truncatesLastVisibleLine = NO;
        }

        // --- Core Actions ---
        
        NSButton *reconnectBtn = [NSButton buttonWithTitle:@"尝试重连" target:self action:@selector(handleTimeoutReconnect:)];
        reconnectBtn.bezelStyle = NSBezelStyleRounded; // Standard pill style
        reconnectBtn.controlSize = NSControlSizeLarge; 
        reconnectBtn.font = [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold];
        reconnectBtn.keyEquivalent = @"\r";
        // To make it look "filled" on HUD, rely on bezelStyle or use layer
        // Standard macOS dark HUD usually handles rounded buttons well.

        NSButton *waitBtn = [NSButton buttonWithTitle:@"继续等待" target:self action:@selector(handleTimeoutWait:)];
        waitBtn.bezelStyle = NSBezelStyleRounded;
        waitBtn.controlSize = NSControlSizeLarge;

        NSButton *exitBtn = [NSButton buttonWithTitle:@"退出串流" target:self action:@selector(handleTimeoutExitStream:)];
        exitBtn.bezelStyle = NSBezelStyleRounded;
        exitBtn.controlSize = NSControlSizeLarge;

        // --- Settings Strip ---
        // Create custom "card" buttons to match screenshot design:
        // Dark background, rounded corners (6pt), Icon + Text
        
        NSButton *(^createSettingsBtn)(NSString *, NSString *, SEL) = ^(NSString *title, NSString *iconName, SEL selector) {
            NSButton *btn = [[NSButton alloc] initWithFrame:NSMakeRect(0, 0, 100, 28)];
            btn.target = self;
            btn.action = selector;
            btn.bezelStyle = NSBezelStyleRegularSquare;
            btn.bordered = NO; // We draw our own background
            btn.wantsLayer = YES;
            btn.layer.backgroundColor = [[NSColor colorWithWhite:1.0 alpha:0.1] CGColor]; // Semi-transparent white => looks like lighter dark grey on dark background
            btn.layer.cornerRadius = 6.0;
            btn.layer.masksToBounds = YES;
            
            btn.title = title;
            btn.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
            if ([btn.cell isKindOfClass:[NSButtonCell class]]) {
                ((NSButtonCell *)btn.cell).lineBreakMode = NSLineBreakByTruncatingTail;
            }
            if (@available(macOS 11.0, *)) {
                btn.image = [NSImage imageWithSystemSymbolName:iconName accessibilityDescription:nil];
                btn.imagePosition = NSImageLeading;
                btn.contentTintColor = [NSColor whiteColor];
                // 设置图标和文字的间距
                btn.imageHugsTitle = YES;
                // 调整按钮对齐方式为居中
                btn.alignment = NSTextAlignmentCenter;
            } else {
                btn.imagePosition = NSImageLeft;
            }
            return btn;
        };

        NSButton *resBtn = createSettingsBtn(@"分辨率", @"display", @selector(handleTimeoutResolution:));
        NSButton *bitrateBtn = createSettingsBtn(@"码率", @"speedometer", @selector(handleTimeoutBitrate:));
        NSButton *displayModeBtn = createSettingsBtn(@"显示模式", @"macwindow", @selector(handleTimeoutDisplayMode:));
        NSButton *connBtn = createSettingsBtn(@"连接方式", @"network", @selector(handleTimeoutConnection:));
        NSButton *recommendedBtn = createSettingsBtn(@"推荐档位", @"sparkles", @selector(handleTimeoutRecommendedProfile:));

        // --- Log Tools - 改进样式，使用图标按钮 ---
        
        NSButton *(^createLogBtn)(NSString *, NSString *, SEL) = ^(NSString *title, NSString *iconName, SEL selector) {
            NSButton *btn = [[NSButton alloc] initWithFrame:NSMakeRect(0, 0, 90, 28)];
            btn.target = self;
            btn.action = selector;
            btn.bezelStyle = NSBezelStyleRegularSquare;
            btn.bordered = NO;
            btn.wantsLayer = YES;
            // 使用更浅的背景色，区别于设置按钮
            btn.layer.backgroundColor = [[NSColor colorWithWhite:1.0 alpha:0.06] CGColor];
            btn.layer.cornerRadius = 6.0;
            btn.layer.borderWidth = 0.5;
            btn.layer.borderColor = [[NSColor colorWithWhite:1.0 alpha:0.15] CGColor];
            btn.layer.masksToBounds = YES;
            
            btn.title = title;
            btn.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
            if ([btn.cell isKindOfClass:[NSButtonCell class]]) {
                ((NSButtonCell *)btn.cell).lineBreakMode = NSLineBreakByTruncatingTail;
            }
            if (@available(macOS 11.0, *)) {
                btn.image = [NSImage imageWithSystemSymbolName:iconName accessibilityDescription:nil];
                btn.imagePosition = NSImageLeading;
                btn.contentTintColor = [NSColor colorWithWhite:0.75 alpha:1.0];
                btn.imageHugsTitle = YES;
                btn.alignment = NSTextAlignmentCenter;
            } else {
                btn.imagePosition = NSImageLeft;
            }
            return btn;
        };
        
        NSButton *viewLogBtn = createLogBtn(@"查看日志", @"doc.text.magnifyingglass", @selector(handleTimeoutViewLogs:));
        NSButton *copyLogBtn = createLogBtn(@"复制日志", @"doc.on.doc", @selector(handleTimeoutCopyLogs:));

        // --- Hierarchy ---

        self.timeoutOverlayContainer = container;
        self.timeoutIconLabel = iconLabel;
        self.timeoutTitleLabel = titleLabel;
        self.timeoutLabel = label;
        self.timeoutReconnectButton = reconnectBtn;
        self.timeoutWaitButton = waitBtn;
        self.timeoutExitButton = exitBtn;
        self.timeoutResolutionButton = resBtn;
        self.timeoutBitrateButton = bitrateBtn;
        self.timeoutDisplayModeButton = displayModeBtn;
        self.timeoutConnectionButton = connBtn;
        self.timeoutRecommendedProfileButton = recommendedBtn;
        self.timeoutViewLogsButton = viewLogBtn;
        self.timeoutCopyLogsButton = copyLogBtn;

        [container addSubview:iconLabel];
        [container addSubview:titleLabel];
        [container addSubview:label];
        [container addSubview:reconnectBtn];
        [container addSubview:waitBtn];
        [container addSubview:exitBtn];
        [container addSubview:resBtn];
        [container addSubview:bitrateBtn];
        [container addSubview:displayModeBtn];
        [container addSubview:connBtn];
        [container addSubview:recommendedBtn];
        [container addSubview:viewLogBtn];
        [container addSubview:copyLogBtn];

        [self.view addSubview:container positioned:NSWindowAbove relativeTo:nil];
        
        container.alphaValue = 0.0;
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = 0.25;
            container.animator.alphaValue = 1.0;
        } completionHandler:nil];
    }
    
    // Update content
    self.timeoutTitleLabel.stringValue = title ?: @"连接异常";
    self.timeoutLabel.stringValue = message ?: @"未知错误";
    self.timeoutWaitButton.hidden = !canWait;
    BOOL showRecommendedProfile = self.currentStreamRiskAssessment != nil &&
                                  self.currentStreamRiskAssessment.manualExpertMode &&
                                  self.currentStreamRiskAssessment.recommendedFallbacks.count > 0;
    self.timeoutRecommendedProfileButton.hidden = !showRecommendedProfile;

    [self viewDidLayout];
}

- (void)hideConnectionTimeoutOverlay {
    if (!self.timeoutOverlayContainer) {
        return;
    }

    NSVisualEffectView *container = self.timeoutOverlayContainer;
    self.timeoutOverlayContainer = nil;
    self.timeoutIconLabel = nil;
    self.timeoutTitleLabel = nil;
    self.timeoutLabel = nil;
    self.timeoutReconnectButton = nil;
    self.timeoutWaitButton = nil;
    self.timeoutExitButton = nil;
    self.timeoutResolutionButton = nil;
    self.timeoutBitrateButton = nil;
    self.timeoutDisplayModeButton = nil;
    self.timeoutConnectionButton = nil;
    self.timeoutRecommendedProfileButton = nil;
    self.timeoutViewLogsButton = nil;
    self.timeoutCopyLogsButton = nil;

    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.2;
        container.animator.alphaValue = 0.0;
    } completionHandler:^{
        [container removeFromSuperview];
    }];
}

- (void)handleTimeoutReconnect:(id)sender {
    if (self.reconnectInProgress || self.stopStreamInProgress) {
        Log(LOG_W, @"[diag] Reconnect button ignored: reconnectInProgress=%d stopInProgress=%d",
            self.reconnectInProgress ? 1 : 0,
            self.stopStreamInProgress ? 1 : 0);
        return;
    }
    [self hideConnectionTimeoutOverlay];
    [self attemptReconnectWithReason:@"timeout-overlay-manual"];
}

- (void)handleTimeoutWait:(id)sender {
    [self hideConnectionTimeoutOverlay];
}

- (void)handleTimeoutExitStream:(id)sender {
    [self requestStreamCloseWithSource:@"timeout-overlay-exit"];
}

- (void)handleTimeoutResolution:(id)sender {
    [self rebuildStreamMenu];
    NSMenuItem *monitorItem = nil;
    for (NSMenuItem *item in self.streamMenu.itemArray) {
        if ([item.title isEqualToString:@"屏幕"]) {
            monitorItem = item;
            break;
        }
    }
    if (monitorItem && monitorItem.submenu) {
        NSButton *btn = (NSButton *)sender;
        NSPoint p = NSMakePoint(0, btn.bounds.size.height + 5);
        [monitorItem.submenu popUpMenuPositioningItem:nil atLocation:p inView:btn];
    }
}

- (void)handleTimeoutBitrate:(id)sender {
    [self rebuildStreamMenu];
    NSMenuItem *qualityItem = nil;
    for (NSMenuItem *item in self.streamMenu.itemArray) {
        if ([item.title isEqualToString:@"画质"]) {
            qualityItem = item;
            break;
        }
    }
    if (qualityItem && qualityItem.submenu) {
        NSButton *btn = (NSButton *)sender;
        NSPoint p = NSMakePoint(0, btn.bounds.size.height + 5);
        [qualityItem.submenu popUpMenuPositioningItem:nil atLocation:p inView:btn];
    }
}

- (void)handleTimeoutDisplayMode:(id)sender {
    [self rebuildStreamMenu];
    NSMenuItem *windowItem = nil;
    for (NSMenuItem *item in self.streamMenu.itemArray) {
        if ([item.title isEqualToString:@"窗口"]) {
            windowItem = item;
            break;
        }
    }
    if (windowItem && windowItem.submenu) {
        NSButton *btn = (NSButton *)sender;
        NSPoint p = NSMakePoint(0, btn.bounds.size.height + 5);
        [windowItem.submenu popUpMenuPositioningItem:nil atLocation:p inView:btn];
    }
}

- (void)handleTimeoutConnection:(id)sender {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Connections"];
    TemporaryHost *host = self.app.host;
    
    NSMutableSet *seen = [NSMutableSet set];
    
    void (^addItem)(NSString *, NSString *) = ^(NSString *title, NSString *addr) {
        if (!addr || [seen containsObject:addr]) return;
        [seen addObject:addr];
        
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"%@: %@", title, addr] action:@selector(handleConnectionSelection:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = addr;
        if ([addr isEqualToString:host.activeAddress]) {
            item.state = NSControlStateValueOn;
        }
        [menu addItem:item];
    };

    addItem(@"当前", host.activeAddress); // Ensure current is always first if valid
    addItem(@"Local", host.localAddress);
    addItem(@"IPv6", host.ipv6Address);
    addItem(@"Public", host.externalAddress);
    addItem(@"Manual", host.address);
    
    if (menu.itemArray.count == 0 && host.activeAddress) {
        addItem(@"Default", host.activeAddress);
    }
    
    if (menu.itemArray.count == 0) {
        [menu addItemWithTitle:@"无可用地址" action:nil keyEquivalent:@""];
    }

    NSButton *btn = (NSButton *)sender;
    NSPoint p = NSMakePoint(0, btn.bounds.size.height + 5);
    [menu popUpMenuPositioningItem:nil atLocation:p inView:btn];
}

- (void)handleConnectionSelection:(NSMenuItem *)item {
    NSString *addr = item.representedObject;
    if (addr) {
        self.app.host.activeAddress = addr;
        [self attemptReconnectWithReason:@"manual-address-change"];
    }
}

- (void)handleTimeoutRecommendedProfile:(id)sender {
    NSArray<StreamRiskRecommendation *> *recommendations = self.currentStreamRiskAssessment.recommendedFallbacks;
    if (recommendations.count == 0) {
        return;
    }

    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"RecommendedProfiles"];
    for (StreamRiskRecommendation *recommendation in recommendations) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:recommendation.summaryLine action:@selector(handleRecommendedProfileSelection:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = recommendation;
        [menu addItem:item];
    }

    NSButton *btn = (NSButton *)sender;
    NSPoint p = NSMakePoint(0, btn.bounds.size.height + 5);
    [menu popUpMenuPositioningItem:nil atLocation:p inView:btn];
}

- (void)handleRecommendedProfileSelection:(NSMenuItem *)item {
    StreamRiskRecommendation *recommendation = item.representedObject;
    if (recommendation == nil) {
        return;
    }

    [SettingsClass applyStreamRecommendation:recommendation for:self.app.host.uuid];
    [SettingsClass loadMoonlightSettingsFor:self.app.host.uuid];
    [self hideConnectionTimeoutOverlay];
    [self attemptReconnectWithReason:@"risk-recommended-profile"];
}

- (BOOL)isAutomaticRecoveryModeEnabled {
    NSDictionary *prefs = [SettingsClass getSettingsFor:self.app.host.uuid];
    return prefs ? [prefs[@"autoAdjustBitrate"] boolValue] : YES;
}

- (void)presentManualRiskOverlayForReason:(NSString *)reason {
    if (self.timeoutOverlayContainer || self.reconnectInProgress || self.stopStreamInProgress) {
        return;
    }

    StreamRiskAssessment *assessment = self.currentStreamRiskAssessment;
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    [lines addObject:MLString(@"No new frame has arrived for a while.", @"Manual risk overlay lead message")];
    [lines addObject:MLString(@"Manual mode won't change your resolution, frame rate, codec, or chroma automatically.", @"Manual risk overlay manual mode explanation")];
    if (assessment.recommendedFallbacks.count > 0) {
        [lines addObject:MLString(@"You can keep waiting, reconnect manually, or apply a recommended profile.", @"Manual risk overlay actions with recommendations")];
    } else {
        [lines addObject:MLString(@"You can keep waiting or reconnect manually.", @"Manual risk overlay actions without recommendations")];
    }

    Log(LOG_W, @"[diag] Manual expert mode holds parameters on %@", reason ?: @"(unknown)");
    [self showErrorOverlayWithTitle:MLString(@"Frame updates paused", @"Manual risk overlay title")
                            message:[lines componentsJoinedByString:@"\n"]
                            canWait:YES];
}

- (void)handleTimeoutViewLogs:(id)sender {
    [self toggleLogOverlay];
}

- (uint64_t)nowMs {
    return (uint64_t)(CACurrentMediaTime() * 1000.0);
}

- (void)resetInputDiagnosticsState {
    self.inputDiagnosticsFinalized = NO;
    self.inputDiagnosticsDetailActiveForStream = [SettingsClass inputDiagnosticsEnabled];
    self.inputDiagnosticsMouseMoveEvents = 0;
    self.inputDiagnosticsNonZeroRelativeEvents = 0;
    self.inputDiagnosticsRelativeDispatches = 0;
    self.inputDiagnosticsAbsoluteDispatches = 0;
    self.inputDiagnosticsAbsoluteDuplicateSkips = 0;
    self.inputDiagnosticsCoreHIDRawEvents = 0;
    self.inputDiagnosticsCoreHIDDispatches = 0;
    self.inputDiagnosticsSuppressedRelativeEvents = 0;
    self.inputDiagnosticsRawRelativeDeltaX = 0;
    self.inputDiagnosticsRawRelativeDeltaY = 0;
    self.inputDiagnosticsSentRelativeDeltaX = 0;
    self.inputDiagnosticsSentRelativeDeltaY = 0;
    self.inputDiagnosticsCaptureArmedCount = 0;
    self.inputDiagnosticsCaptureSkipCount = 0;
    self.inputDiagnosticsRearmCount = 0;
    self.inputDiagnosticsRearmSkippedCount = 0;
    self.inputDiagnosticsRearmDeferredCount = 0;
    self.inputDiagnosticsUncaptureCount = 0;
    self.inputDiagnosticsCaptureSkipReasons = [NSMutableDictionary dictionary];
    self.inputDiagnosticsRearmReasons = [NSMutableDictionary dictionary];
    self.inputDiagnosticsRearmSkipReasons = [NSMutableDictionary dictionary];
    self.inputDiagnosticsRearmDeferredReasons = [NSMutableDictionary dictionary];
    [self stopInputDiagnosticsTimer];
    [self.hidSupport resetInputDiagnostics];
}

- (void)stopInputDiagnosticsTimer {
    if (self.inputDiagnosticsTimer) {
        [self.inputDiagnosticsTimer invalidate];
        self.inputDiagnosticsTimer = nil;
    }
}

- (void)refreshInputDiagnosticsPreference {
    [self.hidSupport refreshInputDiagnosticsPreference];

    BOOL enabled = [SettingsClass inputDiagnosticsEnabled];
    if (enabled) {
        self.inputDiagnosticsDetailActiveForStream = YES;
    }

    if (!enabled) {
        [self stopInputDiagnosticsTimer];
        return;
    }

    if (!self.inputDiagnosticsTimer && !self.inputDiagnosticsFinalized && self.streamHealthConnectionStartedMs > 0) {
        self.inputDiagnosticsTimer = [NSTimer timerWithTimeInterval:1.0
                                                             target:self
                                                           selector:@selector(pollInputDiagnostics:)
                                                           userInfo:nil
                                                            repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:self.inputDiagnosticsTimer forMode:NSRunLoopCommonModes];
    }
}

- (void)accumulateInputDiagnosticsSnapshot:(HIDInputDiagnosticsSnapshot *)snapshot {
    if (snapshot == nil) {
        return;
    }

    self.inputDiagnosticsMouseMoveEvents += snapshot.mouseMoveEvents;
    self.inputDiagnosticsNonZeroRelativeEvents += snapshot.nonZeroRelativeEvents;
    self.inputDiagnosticsRelativeDispatches += snapshot.relativeDispatches;
    self.inputDiagnosticsAbsoluteDispatches += snapshot.absoluteDispatches;
    self.inputDiagnosticsAbsoluteDuplicateSkips += snapshot.absoluteDuplicateSkips;
    self.inputDiagnosticsCoreHIDRawEvents += snapshot.coreHIDRawEvents;
    self.inputDiagnosticsCoreHIDDispatches += snapshot.coreHIDDispatches;
    self.inputDiagnosticsSuppressedRelativeEvents += snapshot.suppressedRelativeEvents;
    self.inputDiagnosticsRawRelativeDeltaX += snapshot.rawRelativeDeltaX;
    self.inputDiagnosticsRawRelativeDeltaY += snapshot.rawRelativeDeltaY;
    self.inputDiagnosticsSentRelativeDeltaX += snapshot.sentRelativeDeltaX;
    self.inputDiagnosticsSentRelativeDeltaY += snapshot.sentRelativeDeltaY;
}

- (void)incrementInputDiagnosticsBucket:(NSMutableDictionary<NSString *, NSNumber *> *)bucket key:(NSString *)key {
    NSString *normalizedKey = key.length > 0 ? key : @"unknown";
    NSInteger count = [bucket[normalizedKey] integerValue];
    bucket[normalizedKey] = @(count + 1);
}

- (NSString *)inputDiagnosticsTopReasonsFrom:(NSDictionary<NSString *, NSNumber *> *)bucket limit:(NSUInteger)limit {
    if (bucket.count == 0 || limit == 0) {
        return nil;
    }

    NSArray<NSString *> *sortedKeys = [bucket keysSortedByValueUsingComparator:^NSComparisonResult(NSNumber *lhs, NSNumber *rhs) {
        return [rhs compare:lhs];
    }];

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *key in sortedKeys) {
        if (parts.count >= limit) {
            break;
        }
        [parts addObject:[NSString stringWithFormat:@"%@×%@", key, bucket[key]]];
    }

    return parts.count > 0 ? [parts componentsJoinedByString:@","] : nil;
}

- (void)noteInputDiagnosticsCaptureArmed {
    self.inputDiagnosticsCaptureArmedCount += 1;
}

- (void)noteInputDiagnosticsCaptureSkipped:(NSString *)reason {
    self.inputDiagnosticsCaptureSkipCount += 1;
    [self incrementInputDiagnosticsBucket:self.inputDiagnosticsCaptureSkipReasons key:reason];
}

- (void)noteInputDiagnosticsRearmRequested:(NSString *)reason {
    self.inputDiagnosticsRearmCount += 1;
    [self incrementInputDiagnosticsBucket:self.inputDiagnosticsRearmReasons key:reason];
}

- (void)noteInputDiagnosticsRearmSkippedWithBlocker:(NSString *)blocker {
    self.inputDiagnosticsRearmSkippedCount += 1;
    [self incrementInputDiagnosticsBucket:self.inputDiagnosticsRearmSkipReasons key:blocker];
}

- (void)noteInputDiagnosticsRearmDeferred:(NSString *)reason {
    self.inputDiagnosticsRearmDeferredCount += 1;
    [self incrementInputDiagnosticsBucket:self.inputDiagnosticsRearmDeferredReasons key:reason];
}

- (void)noteInputDiagnosticsUncapture {
    self.inputDiagnosticsUncaptureCount += 1;
}

- (void)pollInputDiagnostics:(NSTimer *)timer {
    (void)timer;

    HIDInputDiagnosticsSnapshot *snapshot = [self.hidSupport consumeInputDiagnosticsSnapshot];
    [self accumulateInputDiagnosticsSnapshot:snapshot];

    if (snapshot.mouseMoveEvents == 0 &&
        snapshot.relativeDispatches == 0 &&
        snapshot.absoluteDispatches == 0 &&
        snapshot.absoluteDuplicateSkips == 0 &&
        snapshot.coreHIDRawEvents == 0 &&
        snapshot.coreHIDDispatches == 0 &&
        snapshot.suppressedRelativeEvents == 0) {
        return;
    }

    Log(LOG_D, @"[inputdiag] 1s sample: moves=%lu rel=%lu abs=%lu absDup=%lu coreRaw=%lu coreOut=%lu suppressed=%lu rawΔ=(%ld,%ld) sentΔ=(%ld,%ld) capture=%lu uncapture=%lu rearm=%lu rearmSkip=%lu",
        (unsigned long)snapshot.mouseMoveEvents,
        (unsigned long)snapshot.relativeDispatches,
        (unsigned long)snapshot.absoluteDispatches,
        (unsigned long)snapshot.absoluteDuplicateSkips,
        (unsigned long)snapshot.coreHIDRawEvents,
        (unsigned long)snapshot.coreHIDDispatches,
        (unsigned long)snapshot.suppressedRelativeEvents,
        (long)snapshot.rawRelativeDeltaX,
        (long)snapshot.rawRelativeDeltaY,
        (long)snapshot.sentRelativeDeltaX,
        (long)snapshot.sentRelativeDeltaY,
        (unsigned long)self.inputDiagnosticsCaptureArmedCount,
        (unsigned long)self.inputDiagnosticsUncaptureCount,
        (unsigned long)self.inputDiagnosticsRearmCount,
        (unsigned long)self.inputDiagnosticsRearmSkippedCount);
}

- (void)finalizeInputDiagnosticsWithReason:(NSString *)reason {
    if (self.inputDiagnosticsFinalized) {
        return;
    }
    self.inputDiagnosticsFinalized = YES;

    [self stopInputDiagnosticsTimer];
    [self.hidSupport refreshInputDiagnosticsPreference];
    [self accumulateInputDiagnosticsSnapshot:[self.hidSupport consumeInputDiagnosticsSnapshot]];

    NSString *captureSkipTop = [self inputDiagnosticsTopReasonsFrom:self.inputDiagnosticsCaptureSkipReasons limit:2];
    NSString *rearmTop = [self inputDiagnosticsTopReasonsFrom:self.inputDiagnosticsRearmReasons limit:2];
    NSString *rearmSkipTop = [self inputDiagnosticsTopReasonsFrom:self.inputDiagnosticsRearmSkipReasons limit:2];
    NSString *rearmDeferredTop = [self inputDiagnosticsTopReasonsFrom:self.inputDiagnosticsRearmDeferredReasons limit:2];

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    [parts addObject:[NSString stringWithFormat:@"detail=%@", self.inputDiagnosticsDetailActiveForStream ? @"on" : @"off"]];
    [parts addObject:[NSString stringWithFormat:@"moves=%lu", (unsigned long)self.inputDiagnosticsMouseMoveEvents]];
    [parts addObject:[NSString stringWithFormat:@"rel=%lu", (unsigned long)self.inputDiagnosticsRelativeDispatches]];
    [parts addObject:[NSString stringWithFormat:@"abs=%lu", (unsigned long)self.inputDiagnosticsAbsoluteDispatches]];
    [parts addObject:[NSString stringWithFormat:@"absDup=%lu", (unsigned long)self.inputDiagnosticsAbsoluteDuplicateSkips]];
    [parts addObject:[NSString stringWithFormat:@"coreRaw=%lu", (unsigned long)self.inputDiagnosticsCoreHIDRawEvents]];
    [parts addObject:[NSString stringWithFormat:@"coreOut=%lu", (unsigned long)self.inputDiagnosticsCoreHIDDispatches]];
    [parts addObject:[NSString stringWithFormat:@"suppressed=%lu", (unsigned long)self.inputDiagnosticsSuppressedRelativeEvents]];
    [parts addObject:[NSString stringWithFormat:@"rawΔ=(%ld,%ld)", (long)self.inputDiagnosticsRawRelativeDeltaX, (long)self.inputDiagnosticsRawRelativeDeltaY]];
    [parts addObject:[NSString stringWithFormat:@"sentΔ=(%ld,%ld)", (long)self.inputDiagnosticsSentRelativeDeltaX, (long)self.inputDiagnosticsSentRelativeDeltaY]];
    [parts addObject:[NSString stringWithFormat:@"capture=%lu", (unsigned long)self.inputDiagnosticsCaptureArmedCount]];
    [parts addObject:[NSString stringWithFormat:@"captureSkip=%lu", (unsigned long)self.inputDiagnosticsCaptureSkipCount]];
    [parts addObject:[NSString stringWithFormat:@"uncapture=%lu", (unsigned long)self.inputDiagnosticsUncaptureCount]];
    [parts addObject:[NSString stringWithFormat:@"rearm=%lu", (unsigned long)self.inputDiagnosticsRearmCount]];
    [parts addObject:[NSString stringWithFormat:@"rearmSkip=%lu", (unsigned long)self.inputDiagnosticsRearmSkippedCount]];
    [parts addObject:[NSString stringWithFormat:@"rearmDeferred=%lu", (unsigned long)self.inputDiagnosticsRearmDeferredCount]];
    if (captureSkipTop.length > 0) {
        [parts addObject:[NSString stringWithFormat:@"captureSkipTop=%@", captureSkipTop]];
    }
    if (rearmTop.length > 0) {
        [parts addObject:[NSString stringWithFormat:@"rearmTop=%@", rearmTop]];
    }
    if (rearmSkipTop.length > 0) {
        [parts addObject:[NSString stringWithFormat:@"rearmSkipTop=%@", rearmSkipTop]];
    }
    if (rearmDeferredTop.length > 0) {
        [parts addObject:[NSString stringWithFormat:@"rearmDeferredTop=%@", rearmDeferredTop]];
    }

    Log(LOG_I, @"[diag] Input summary (%@): %@",
        reason.length > 0 ? reason : @"unknown",
        [parts componentsJoinedByString:@" · "]);
}

- (void)resetStreamHealthDiagnostics {
    self.streamHealthSawPayload = NO;
    self.streamHealthNoPayloadStreak = 0;
    self.streamHealthNoDecodeStreak = 0;
    self.streamHealthNoRenderStreak = 0;
    self.streamHealthHighDropStreak = 0;
    self.streamHealthFrozenStatsStreak = 0;
    self.streamHealthLastReceivedFrames = 0;
    self.streamHealthLastDecodedFrames = 0;
    self.streamHealthLastRenderedFrames = 0;
    self.streamHealthLastTotalFrames = 0;
    self.streamHealthLastReceivedBytes = 0;
    self.streamHealthLastMitigationMs = 0;
    self.streamHealthLastPayloadReconnectMs = 0;
    self.streamHealthConnectionStartedMs = 0;
    self.streamHealthMitigationStep = 0;
    self.runtimeAutoBitrateStableStreak = 0;
}

- (void)stopStreamHealthDiagnostics {
    if (self.streamHealthTimer) {
        [self.streamHealthTimer invalidate];
        self.streamHealthTimer = nil;
    }
}

- (void)startStreamHealthDiagnostics {
    [self stopStreamHealthDiagnostics];
    [self resetStreamHealthDiagnostics];
    Log(LOG_I, @"[diag] Stream health diagnostics started");
    self.streamHealthTimer = [NSTimer timerWithTimeInterval:1.0
                                                     target:self
                                                   selector:@selector(pollStreamHealthDiagnostics:)
                                                   userInfo:nil
                                                    repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.streamHealthTimer forMode:NSRunLoopCommonModes];
}

- (void)attemptAdaptiveMitigationForDropRate:(float)dropRate {
    if (self.stopStreamInProgress || self.reconnectInProgress || !self.shouldAttemptReconnect) {
        return;
    }

    uint64_t nowMs = [self nowMs];
    // Avoid repeatedly restarting in short intervals during unstable tunnels.
    if (self.streamHealthLastMitigationMs > 0 && nowMs - self.streamHealthLastMitigationMs < 20000) {
        return;
    }

    NSDictionary *prefs = [SettingsClass getSettingsFor:self.app.host.uuid];
    BOOL autoAdjustBitrate = prefs ? [prefs[@"autoAdjustBitrate"] boolValue] : NO;
    if (!autoAdjustBitrate) {
        Log(LOG_I, @"[diag] Adaptive mitigation skipped: auto bitrate disabled (drop=%.1f%%)", dropRate);
        return;
    }

    BOOL routeIsTunnel = NO;
    if (self.app.host.activeAddress.length > 0) {
        routeIsTunnel = [Utils isTunnelInterfaceName:[Utils outboundInterfaceNameForAddress:self.app.host.activeAddress sourceAddress:nil]];
    }
    if (!routeIsTunnel) {
        return;
    }

    DataManager *dataMan = [[DataManager alloc] init];
    TemporarySettings *tempSettings = [dataMan getSettings];
    int currentBitrate = [tempSettings.bitrate intValue];
    if (self.runtimeAutoBitrateBaselineKbps > 0 && currentBitrate <= 0) {
        currentBitrate = (int)self.runtimeAutoBitrateBaselineKbps;
    }
    if (currentBitrate <= 0) {
        currentBitrate = 10000;
    }
    if (self.runtimeAutoBitrateCapKbps > 0 && self.runtimeAutoBitrateCapKbps < currentBitrate) {
        currentBitrate = (int)self.runtimeAutoBitrateCapKbps;
    }

    int newBitrate = MAX(6000, (int)((double)currentBitrate * 0.80 + 0.5));

    // If we're already at the floor, avoid reconnect loops.
    if (newBitrate >= currentBitrate) {
        return;
    }

    self.runtimeAutoBitrateCapKbps = newBitrate;
    self.runtimeAutoBitrateStableStreak = 0;
    self.streamHealthLastMitigationMs = nowMs;
    self.streamHealthMitigationStep += 1;

    Log(LOG_W, @"[diag] Adaptive mitigation #%ld applied for tunnel drop=%.1f%%: bitrate %d->%d kbps (fps unchanged by design)",
        (long)self.streamHealthMitigationStep,
        dropRate,
        currentBitrate,
        newBitrate);

    [self attemptReconnectWithReason:@"adaptive-drop-mitigation"];
}

- (void)pollStreamHealthDiagnostics:(NSTimer *)timer {
    (void)timer;
    if (!self.streamMan || !self.streamMan.connection || !self.streamMan.connection.renderer) {
        return;
    }

    VideoStats stats = self.streamMan.connection.renderer.videoStats;
    uint64_t nowMs = [self nowMs];
    uint64_t nowStatsMs = LiGetMillis();
    BOOL statsTimestampValid = (stats.lastUpdatedTimestamp > 0 && nowStatsMs >= stats.lastUpdatedTimestamp);
    uint64_t statsAgeMs = statsTimestampValid ? (nowStatsMs - stats.lastUpdatedTimestamp) : UINT64_MAX;
    BOOL statsFresh = statsTimestampValid && statsAgeMs <= 1500;
    BOOL hasPayloadInWindow = (stats.receivedBytes > 0 || stats.receivedFrames > 0 || stats.receivedFps > 0.1f);
    BOOL hasProgressSinceLast = (stats.receivedFrames != self.streamHealthLastReceivedFrames ||
                                 stats.decodedFrames != self.streamHealthLastDecodedFrames ||
                                 stats.renderedFrames != self.streamHealthLastRenderedFrames ||
                                 stats.totalFrames != self.streamHealthLastTotalFrames ||
                                 stats.receivedBytes != self.streamHealthLastReceivedBytes);
    BOOL hasPayloadInFreshWindow = (statsFresh || !statsTimestampValid) && hasPayloadInWindow;

    if (self.waitingForFirstRenderedFrame && stats.renderedFrames > 0) {
        self.waitingForFirstRenderedFrame = NO;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.streamView.statusText = nil;
        });
        Log(LOG_I, @"[diag] First rendered frame observed; clearing startup loading indicator");
    }

    if (hasPayloadInFreshWindow || hasProgressSinceLast) {
        self.streamHealthSawPayload = YES;
    }

    BOOL shouldTreatAsPayloadStall = NO;
    if (self.streamHealthSawPayload) {
        if (statsTimestampValid) {
            shouldTreatAsPayloadStall = !statsFresh;
        } else {
            shouldTreatAsPayloadStall = !hasProgressSinceLast;
        }
    }

    if (shouldTreatAsPayloadStall) {
        self.streamHealthNoPayloadStreak += 1;
    } else {
        self.streamHealthNoPayloadStreak = 0;
    }

    BOOL staleByTimestamp = statsTimestampValid && !statsFresh;
    BOOL staleByNoProgress = !statsTimestampValid && self.streamHealthSawPayload && !hasProgressSinceLast;
    if (staleByTimestamp || staleByNoProgress) {
        self.streamHealthFrozenStatsStreak += 1;
    } else {
        self.streamHealthFrozenStatsStreak = 0;
    }

    if ((hasPayloadInWindow || hasProgressSinceLast) && stats.decodedFrames == 0) {
        self.streamHealthNoDecodeStreak += 1;
    } else {
        self.streamHealthNoDecodeStreak = 0;
    }

    if (stats.decodedFrames > 0 && stats.renderedFrames == 0) {
        self.streamHealthNoRenderStreak += 1;
    } else {
        self.streamHealthNoRenderStreak = 0;
    }

    float dropRate = 0.0f;
    if (stats.totalFrames > 0) {
        dropRate = (float)stats.networkDroppedFrames * 100.0f / (float)stats.totalFrames;
    }
    if (stats.totalFrames >= 30 && dropRate >= 25.0f) {
        self.streamHealthHighDropStreak += 1;
    } else {
        self.streamHealthHighDropStreak = 0;
    }

    NSString *rttLogText = [self currentLatencyLogSummary];

    BOOL autoRecoveryMode = [self isAutomaticRecoveryModeEnabled];

    if (self.streamHealthNoPayloadStreak == 3 || (self.streamHealthNoPayloadStreak > 3 && self.streamHealthNoPayloadStreak % 5 == 0)) {
        Log(LOG_W, @"[diag] Video payload stalled for %lus (possible freeze/static/no-input). rf=%u df=%u ren=%u bytes=%llu jitter=%.2fms rtt=%@ ageMs=%llu fresh=%d captured=%d input=%d",
            (unsigned long)self.streamHealthNoPayloadStreak,
            stats.receivedFrames,
            stats.decodedFrames,
            stats.renderedFrames,
            (unsigned long long)stats.receivedBytes,
            stats.jitterMs,
            rttLogText,
            (unsigned long long)(statsTimestampValid ? statsAgeMs : 0),
            statsFresh ? 1 : 0,
            self.isMouseCaptured ? 1 : 0,
            self.hidSupport.shouldSendInputEvents ? 1 : 0);

        if (self.streamMan.connection) {
            MLVideoDiagnosticSnapshot snapshot;
            if ([self.streamMan.connection getVideoDiagnosticSnapshot:&snapshot]) {
                Log(LOG_W, @"[diag] Low-level video snapshot: app=%d.%d.%d vPeer=%d vFull=%d vSock=%d vFrame=%u vData=%u/%u vParity=%u/%u vMissing=%u vSeq=%u->%u vPend=%u vDone=%u",
                    snapshot.appVersionMajor,
                    snapshot.appVersionMinor,
                    snapshot.appVersionPatch,
                    snapshot.videoReceivedDataFromPeer ? 1 : 0,
                    snapshot.videoReceivedFullFrame ? 1 : 0,
                    snapshot.videoRtpSocketValid,
                    snapshot.videoCurrentFrameNumber,
                    snapshot.videoReceivedDataPackets,
                    snapshot.videoBufferDataPackets,
                    snapshot.videoReceivedParityPackets,
                    snapshot.videoBufferParityPackets,
                    snapshot.videoMissingPackets,
                    snapshot.videoNextContiguousSequenceNumber,
                    snapshot.videoReceivedHighestSequenceNumber,
                    snapshot.videoPendingFecBlocks,
                    snapshot.videoCompletedFecBlocks);
            }
        }
    }

    static const NSUInteger kPayloadStallIdrThreshold = 2;
    static const uint64_t kPayloadStallIdrIntervalMs = 2000;
    static const NSUInteger kPayloadStallReconnectThreshold = 5;
    static const uint64_t kPayloadStallReconnectCooldownMs = 10000;
    static const uint64_t kStartupNoPayloadReconnectThresholdMs = 6000;

    if (!self.streamHealthSawPayload &&
        self.streamHealthConnectionStartedMs > 0 &&
        nowMs >= self.streamHealthConnectionStartedMs) {
        uint64_t startupNoPayloadMs = nowMs - self.streamHealthConnectionStartedMs;
        if (startupNoPayloadMs >= kStartupNoPayloadReconnectThresholdMs &&
            self.shouldAttemptReconnect &&
            !self.reconnectInProgress &&
            !self.stopStreamInProgress &&
            (self.streamHealthLastPayloadReconnectMs == 0 || nowMs - self.streamHealthLastPayloadReconnectMs >= kPayloadStallReconnectCooldownMs)) {
            if (autoRecoveryMode) {
                self.streamHealthLastPayloadReconnectMs = nowMs;
                Log(LOG_W, @"[diag] No video payload %.1fs after connection start, attempting reconnect",
                    startupNoPayloadMs / 1000.0);
                [self attemptReconnectWithReason:@"startup-no-payload-reconnect"];
            } else {
                Log(LOG_W, @"[diag] No video payload %.1fs after connection start, manual expert mode keeps stream parameters",
                    startupNoPayloadMs / 1000.0);
                [self presentManualRiskOverlayForReason:@"startup-no-payload"];
            }
        }
    }

    if (self.streamHealthNoPayloadStreak >= kPayloadStallIdrThreshold &&
        (self.connectionLastIdrRequestMs == 0 || nowMs - self.connectionLastIdrRequestMs > kPayloadStallIdrIntervalMs)) {
        LiRequestIdrFrame();
        self.connectionLastIdrRequestMs = nowMs;
        Log(LOG_I, @"[diag] Requested IDR on payload-stall streak=%lu", (unsigned long)self.streamHealthNoPayloadStreak);
    }

    if (self.streamHealthNoPayloadStreak >= kPayloadStallReconnectThreshold &&
        self.shouldAttemptReconnect &&
        !self.reconnectInProgress &&
        !self.stopStreamInProgress &&
        (self.streamHealthLastPayloadReconnectMs == 0 || nowMs - self.streamHealthLastPayloadReconnectMs >= kPayloadStallReconnectCooldownMs)) {
        if (autoRecoveryMode) {
            self.streamHealthLastPayloadReconnectMs = nowMs;
            Log(LOG_W, @"[diag] Persistent payload stall (%lus >= %lu) detected, attempting reconnect",
                (unsigned long)self.streamHealthNoPayloadStreak,
                (unsigned long)kPayloadStallReconnectThreshold);
            [self attemptReconnectWithReason:@"payload-stall-reconnect"];
        } else {
            Log(LOG_W, @"[diag] Persistent payload stall (%lus >= %lu) detected, manual expert mode holds parameters",
                (unsigned long)self.streamHealthNoPayloadStreak,
                (unsigned long)kPayloadStallReconnectThreshold);
            [self presentManualRiskOverlayForReason:@"payload-stall"];
        }
    }

    if (self.streamHealthNoDecodeStreak == 2 || (self.streamHealthNoDecodeStreak > 2 && self.streamHealthNoDecodeStreak % 4 == 0)) {
        Log(LOG_W, @"[diag] Decode stall suspected for %lus (payload present but decodedFrames==0). rf=%u df=%u ren=%u bytes=%llu jitter=%.2fms rtt=%@",
            (unsigned long)self.streamHealthNoDecodeStreak,
            stats.receivedFrames,
            stats.decodedFrames,
            stats.renderedFrames,
            (unsigned long long)stats.receivedBytes,
            stats.jitterMs,
            rttLogText);
    }

    if (self.streamHealthNoRenderStreak == 2 || (self.streamHealthNoRenderStreak > 2 && self.streamHealthNoRenderStreak % 4 == 0)) {
        Log(LOG_W, @"[diag] Render stall suspected for %lus (decodedFrames>0 but renderedFrames==0). rf=%u df=%u ren=%u bytes=%llu jitter=%.2fms rtt=%@",
            (unsigned long)self.streamHealthNoRenderStreak,
            stats.receivedFrames,
            stats.decodedFrames,
            stats.renderedFrames,
            (unsigned long long)stats.receivedBytes,
            stats.jitterMs,
            rttLogText);
    }

    if (self.streamHealthHighDropStreak == 2 || (self.streamHealthHighDropStreak > 2 && self.streamHealthHighDropStreak % 4 == 0)) {
        Log(LOG_W, @"[diag] Heavy network drop for %lus windows (drop=%.1f%%). total=%u dropped=%u rf=%u df=%u ren=%u bytes=%llu rtt=%@",
            (unsigned long)self.streamHealthHighDropStreak,
            dropRate,
            stats.totalFrames,
            stats.networkDroppedFrames,
            stats.receivedFrames,
            stats.decodedFrames,
            stats.renderedFrames,
            (unsigned long long)stats.receivedBytes,
            rttLogText);
    }

    // Proactively step down stream settings on persistent severe tunnel loss.
    // This targets freeze/recover oscillation where status toggles 1->0->1 repeatedly.
    if (self.streamHealthHighDropStreak >= 4 && dropRate >= 55.0f) {
        [self attemptAdaptiveMitigationForDropRate:dropRate];
    }

    // Auto-bitrate ladder (AIMD-like):
    // - sustained instability: handled by attemptAdaptiveMitigationForDropRate() above (decrease step)
    // - sustained stability: increase one step toward baseline bitrate cap
    NSDictionary *prefs = [SettingsClass getSettingsFor:self.app.host.uuid];
    BOOL autoAdjustBitrate = prefs ? [prefs[@"autoAdjustBitrate"] boolValue] : NO;
    BOOL routeIsTunnel = NO;
    if (self.app.host.activeAddress.length > 0) {
        routeIsTunnel = [Utils isTunnelInterfaceName:[Utils outboundInterfaceNameForAddress:self.app.host.activeAddress sourceAddress:nil]];
    }

    if (autoAdjustBitrate && routeIsTunnel && self.runtimeAutoBitrateCapKbps > 0 && self.runtimeAutoBitrateBaselineKbps > self.runtimeAutoBitrateCapKbps) {
        BOOL stableWindow = (statsFresh || hasProgressSinceLast) &&
                            stats.totalFrames >= 120 &&
                            dropRate < 3.0f &&
                            self.streamHealthNoPayloadStreak == 0 &&
                            self.streamHealthNoDecodeStreak == 0 &&
                            self.streamHealthNoRenderStreak == 0 &&
                            self.lastConnectionStatus != CONN_STATUS_POOR;

        if (stableWindow) {
            self.runtimeAutoBitrateStableStreak += 1;
        } else {
            self.runtimeAutoBitrateStableStreak = 0;
        }

        if (self.runtimeAutoBitrateStableStreak >= 12 &&
            (self.runtimeAutoBitrateLastRaiseMs == 0 || nowMs - self.runtimeAutoBitrateLastRaiseMs >= 30000)) {
            int currentCap = (int)self.runtimeAutoBitrateCapKbps;
            int baseline = (int)self.runtimeAutoBitrateBaselineKbps;
            int step = MAX(1000, (int)lround((double)currentCap * 0.12));
            int newCap = MIN(baseline, currentCap + step);
            if (newCap > currentCap) {
                self.runtimeAutoBitrateCapKbps = newCap;
                self.runtimeAutoBitrateLastRaiseMs = nowMs;
                self.runtimeAutoBitrateStableStreak = 0;
                Log(LOG_I, @"[diag] Adaptive bitrate raise applied: %d -> %d kbps (stable windows reached, effective on next reconnect/restart)",
                    currentCap,
                    newCap);
            }
        }
    } else {
        self.runtimeAutoBitrateStableStreak = 0;
    }

    if (self.streamHealthFrozenStatsStreak == 3 || (self.streamHealthFrozenStatsStreak > 3 && self.streamHealthFrozenStatsStreak % 5 == 0)) {
        Log(LOG_W, @"[diag] Stream stats window stale for %lus (no new video window). rf=%u df=%u ren=%u total=%u bytes=%llu jitter=%.2fms rtt=%@ ageMs=%llu captured=%d input=%d",
            (unsigned long)self.streamHealthFrozenStatsStreak,
            stats.receivedFrames,
            stats.decodedFrames,
            stats.renderedFrames,
            stats.totalFrames,
            (unsigned long long)stats.receivedBytes,
            stats.jitterMs,
            rttLogText,
            (unsigned long long)(statsTimestampValid ? statsAgeMs : 0),
            self.isMouseCaptured ? 1 : 0,
            self.hidSupport.shouldSendInputEvents ? 1 : 0);
    }

    self.streamHealthLastReceivedFrames = stats.receivedFrames;
    self.streamHealthLastDecodedFrames = stats.decodedFrames;
    self.streamHealthLastRenderedFrames = stats.renderedFrames;
    self.streamHealthLastTotalFrames = stats.totalFrames;
    self.streamHealthLastReceivedBytes = stats.receivedBytes;
}

- (void)logStreamHealthSummaryWithReason:(NSString *)reason {
    if (!self.streamMan || !self.streamMan.connection || !self.streamMan.connection.renderer) {
        Log(LOG_I, @"[diag] Stream health summary (%@): connection unavailable", reason ?: @"unknown");
        return;
    }

    VideoStats stats = self.streamMan.connection.renderer.videoStats;
    uint64_t nowStatsMs = LiGetMillis();
    BOOL statsTimestampValid = (stats.lastUpdatedTimestamp > 0 && nowStatsMs >= stats.lastUpdatedTimestamp);
    uint64_t statsAgeMs = statsTimestampValid ? (nowStatsMs - stats.lastUpdatedTimestamp) : 0;
    BOOL statsFresh = statsTimestampValid && statsAgeMs <= 1500;
    NSString *rttLogText = [self currentLatencyLogSummary];

    Log(LOG_I, @"[diag] Stream health summary (%@): payloadSeen=%d noPayloadStreak=%lu noDecodeStreak=%lu noRenderStreak=%lu highDropStreak=%lu rf=%u df=%u ren=%u total=%u dropped=%u bytes=%llu jitter=%.2fms rtt=%@ ageMs=%llu fresh=%d captured=%d input=%d",
        reason ?: @"unknown",
        self.streamHealthSawPayload ? 1 : 0,
        (unsigned long)self.streamHealthNoPayloadStreak,
        (unsigned long)self.streamHealthNoDecodeStreak,
        (unsigned long)self.streamHealthNoRenderStreak,
        (unsigned long)self.streamHealthHighDropStreak,
        stats.receivedFrames,
        stats.decodedFrames,
        stats.renderedFrames,
        stats.totalFrames,
        stats.networkDroppedFrames,
        (unsigned long long)stats.receivedBytes,
        stats.jitterMs,
        rttLogText,
        (unsigned long long)statsAgeMs,
        statsFresh ? 1 : 0,
        self.isMouseCaptured ? 1 : 0,
        self.hidSupport.shouldSendInputEvents ? 1 : 0);
}

- (void)requestStreamCloseWithSource:(NSString *)source {
    if (![NSThread isMainThread]) {
        NSString *copied = [source copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self requestStreamCloseWithSource:copied];
        });
        return;
    }
    self.pendingDisconnectSource = source.length > 0 ? source : @"unknown";
    [self performCloseStreamWindow:nil];
}

- (NSString *)resolvedDisconnectSourceFromSender:(id)sender {
    NSString *source = self.pendingDisconnectSource;
    self.pendingDisconnectSource = nil;

    if (source.length == 0) {
        if ([sender isKindOfClass:[NSMenuItem class]]) {
            source = @"menu-disconnect";
        } else if ([sender isKindOfClass:[NSButton class]]) {
            source = @"button-disconnect";
        } else {
            NSEvent *event = NSApp.currentEvent;
            if (event.type == NSEventTypeKeyDown) {
                NSString *chars = event.charactersIgnoringModifiers.lowercaseString ?: @"";
                NSEventModifierFlags mods = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
                BOOL hasCommand = (mods & NSEventModifierFlagCommand) != 0;
                if (hasCommand && [chars isEqualToString:@"w"]) {
                    source = @"keyboard-cmd-w";
                }
            }
            if (source.length == 0) {
                source = @"unknown";
            }
        }
    }

    uint64_t now = [self nowMs];
    if (self.lastOptionUncaptureAtMs > 0 && now >= self.lastOptionUncaptureAtMs && (now - self.lastOptionUncaptureAtMs) <= 2500) {
        source = [source stringByAppendingString:@"+after-option-uncapture"];
    }

    return source;
}

- (BOOL)isRemoteStreamTargetAddress:(NSString *)targetAddress {
    if (targetAddress.length == 0) {
        return NO;
    }

    NSString *targetHost = nil;
    [Utils parseAddress:targetAddress intoHost:&targetHost andPort:nil];
    NSString *host = targetHost.length > 0 ? targetHost : targetAddress;
    NSString *hostLower = host.lowercaseString;

    NSString *localAddr = nil;
    NSString *mainAddr = nil;
    NSString *ipv6Addr = nil;
    NSString *externalAddr = nil;
    if (self.app.host.localAddress.length > 0) {
        [Utils parseAddress:self.app.host.localAddress intoHost:&localAddr andPort:nil];
    }
    if (self.app.host.address.length > 0) {
        [Utils parseAddress:self.app.host.address intoHost:&mainAddr andPort:nil];
    }
    if (self.app.host.ipv6Address.length > 0) {
        [Utils parseAddress:self.app.host.ipv6Address intoHost:&ipv6Addr andPort:nil];
    }
    if (self.app.host.externalAddress.length > 0) {
        [Utils parseAddress:self.app.host.externalAddress intoHost:&externalAddr andPort:nil];
    }

    NSMutableSet<NSString *> *knownLocalHosts = [NSMutableSet setWithCapacity:3];
    for (NSString *candidate in @[ localAddr ?: @"", mainAddr ?: @"", ipv6Addr ?: @"" ]) {
        if (MLShouldTreatAsKnownLocalHost(candidate)) {
            [knownLocalHosts addObject:candidate.lowercaseString];
        }
    }
    if ([knownLocalHosts containsObject:hostLower]) {
        return NO;
    }

    if (externalAddr.length > 0 && [externalAddr.lowercaseString isEqualToString:hostLower]) {
        return YES;
    }

    if ([hostLower isEqualToString:@"localhost"] || [hostLower hasSuffix:@".local"]) {
        return NO;
    }

    if (MLIsPrivateOrLocalIPv4String(host) || MLIsPrivateOrLocalIPv6String(host)) {
        return NO;
    }

    // Public IPv4/IPv6 or regular DNS hostname => treat as remote streaming.
    return YES;
}

- (void)suppressConnectionWarningsForSeconds:(double)seconds reason:(NSString *)reason {
    uint64_t now = [self nowMs];
    uint64_t until = now + (uint64_t)(seconds * 1000.0);
    if (until > self.suppressConnectionWarningsUntilMs) {
        self.suppressConnectionWarningsUntilMs = until;
    }
    Log(LOG_I, @"Suppressing connection warnings for %.2fs (%@)", seconds, reason);
    [self hideConnectionWarning];
}

- (void)markUserInitiatedDisconnectAndSuppressWarningsForSeconds:(double)seconds reason:(NSString *)reason {
    self.disconnectWasUserInitiated = YES;
    [self suppressConnectionWarningsForSeconds:seconds reason:reason];
}

- (void)cancelPendingReconnectForUserExitWithReason:(NSString *)reason {
    BOOL hadReconnect = self.reconnectInProgress;
    BOOL hadStopInProgress = self.stopStreamInProgress;

    self.shouldAttemptReconnect = NO;
    self.reconnectInProgress = NO;
    self.connectWatchdogToken += 1;
    self.activeStreamGeneration += 1;

    Log(LOG_I, @"[diag] Cancel pending reconnect for user exit: reason=%@ reconnect=%d stopInProgress=%d gen=%lu",
        reason ?: @"unknown",
        hadReconnect ? 1 : 0,
        hadStopInProgress ? 1 : 0,
        (unsigned long)self.activeStreamGeneration);

    [self hideReconnectOverlay];
}

- (void)toggleOverlay {
    if (self.overlayContainer) {
        [self.overlayContainer removeFromSuperview];
        self.overlayContainer = nil;
        self.overlayLabel = nil;
        [self.statsTimer invalidate];
        self.statsTimer = nil;
    } else {
        [self setupOverlay];
    }
}

#pragma mark - Log Overlay

- (void)toggleLogOverlay {
    if (self.logOverlayContainer) {
        [self hideLogOverlay];
    } else {
        [self showLogOverlay];
    }
}

- (void)resetLogOverlayState {
    self.logOverlayAllRawLines = [[NSMutableArray alloc] init];
    self.logOverlayDisplayLines = [[NSMutableArray alloc] init];
    self.logOverlayPausedRawLines = [[NSMutableArray alloc] init];
    self.logOverlayLastFoldKey = nil;
    self.logOverlayLastFoldBaseLine = nil;
    self.logOverlayModeKey = @"default";
    self.logOverlayMinimumLevelKey = @"all";
    self.logOverlaySearchText = @"";
    self.logOverlayCategoryFilterKey = @"all";
    self.logOverlayLastFoldCount = 0;
    self.logOverlayLastRenderedRange = NSMakeRange(0, 0);
    self.logOverlayHasLastRenderedRange = NO;
    self.logOverlayPauseUpdates = NO;
    self.logOverlayAutoScrollEnabled = YES;
    self.logOverlaySoftMaxLines = 3000;
    self.logOverlayTrimToLines = 2400;
}

- (NSString *)errorCodeFromLogLine:(NSString *)line {
    if (!line.length) {
        return nil;
    }
    NSRange codeEqRange = [line rangeOfString:@"Code="];
    if (codeEqRange.location != NSNotFound) {
        NSUInteger start = codeEqRange.location + codeEqRange.length;
        NSUInteger len = 0;
        while (start + len < line.length) {
            unichar c = [line characterAtIndex:start + len];
            if ((c >= '0' && c <= '9') || c == '-') {
                len++;
            } else {
                break;
            }
        }
        if (len > 0) {
            return [line substringWithRange:NSMakeRange(start, len)];
        }
    }
    for (NSString *known in @[ @"-1001", @"-1004", @"-1005" ]) {
        if ([line containsString:known]) {
            return known;
        }
    }
    return nil;
}

- (NSInteger)logOverlayLevelRankForRawLine:(NSString *)rawLine {
    if (!rawLine.length) {
        return 0;
    }
    if ([rawLine containsString:@"<ERROR>"]) {
        return 3;
    }
    if ([rawLine containsString:@"<WARN>"]) {
        return 2;
    }
    if ([rawLine containsString:@"<INFO>"]) {
        return 1;
    }
    if ([rawLine containsString:@"<DEBUG>"]) {
        return 0;
    }
    return 0;
}

- (NSInteger)requiredLogOverlayLevelRank {
    NSString *key = self.logOverlayMinimumLevelKey ?: @"all";
    if ([key isEqualToString:@"error"]) {
        return 3;
    }
    if ([key isEqualToString:@"warn"]) {
        return 2;
    }
    if ([key isEqualToString:@"info"]) {
        return 1;
    }
    if ([key isEqualToString:@"debug"]) {
        return 0;
    }
    return NSIntegerMin;
}

- (NSDictionary<NSString *, NSString *> *)compactPresentationForLogLine:(NSString *)rawLine {
    NSString *line = [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (line.length == 0) {
        return @{ @"key": @"empty", @"line": @"" };
    }

    NSString *errorCode = [self errorCodeFromLogLine:line];

    if ([line localizedCaseInsensitiveContainsString:@"Internal inconsistency in menus"]) {
        return @{
            @"key": @"noise.appkit.menu",
            @"line": @"<WARN> [系统] AppKit 菜单一致性异常"
        };
    }

    if ([line localizedCaseInsensitiveContainsString:@"Discovery summary for "]) {
        NSString *host = @"unknown";
        NSRange hostPrefix = [line rangeOfString:@"Discovery summary for " options:NSCaseInsensitiveSearch];
        if (hostPrefix.location != NSNotFound) {
            NSUInteger start = NSMaxRange(hostPrefix);
            NSRange hostRange = [line rangeOfString:@":" options:0 range:NSMakeRange(start, line.length - start)];
            if (hostRange.location != NSNotFound && hostRange.location > start) {
                host = [[line substringWithRange:NSMakeRange(start, hostRange.location - start)] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            }
        }
        NSString *state = @"state unknown";
        NSRange stateRange = [line rangeOfString:@":\\s*\\d+\\s+online,\\s*\\d+\\s+offline"
                                         options:NSRegularExpressionSearch];
        if (stateRange.location != NSNotFound) {
            state = [[line substringWithRange:stateRange] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if ([state hasPrefix:@":"]) {
                state = [[state substringFromIndex:1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            }
        }
        return @{
            @"key": [NSString stringWithFormat:@"noise.discovery.summary.%@.%@", host, state],
            @"line": [NSString stringWithFormat:@"<INFO> [发现] %@：%@", host, state]
        };
    }

    if ([line localizedCaseInsensitiveContainsString:@"Resolved address:"]) {
        NSString *host = @"unknown";
        NSRange hostPrefix = [line rangeOfString:@"Resolved address:" options:NSCaseInsensitiveSearch];
        if (hostPrefix.location != NSNotFound) {
            NSUInteger start = NSMaxRange(hostPrefix);
            NSRange arrowRange = [line rangeOfString:@"->" options:0 range:NSMakeRange(start, line.length - start)];
            if (arrowRange.location != NSNotFound && arrowRange.location > start) {
                host = [[line substringWithRange:NSMakeRange(start, arrowRange.location - start)] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            }
        }
        return @{
            @"key": [NSString stringWithFormat:@"noise.discovery.resolved.%@", host],
            @"line": [NSString stringWithFormat:@"<INFO> [发现] 地址解析 %@", host]
        };
    }

    if ([line localizedCaseInsensitiveContainsString:@"[curated]"]
        && [line localizedCaseInsensitiveContainsString:@"内重复"]) {
        return @{
            @"key": @"noise.curated.repeat",
            @"line": @"<WARN> [日志] 重复日志抑制摘要"
        };
    }

    if ([line localizedCaseInsensitiveContainsString:@"Request failed with error"]) {
        NSString *code = errorCode ?: @"unknown";
        return @{
            @"key": [NSString stringWithFormat:@"noise.net.%@", code],
            @"line": [NSString stringWithFormat:@"<WARN> [网络] 请求失败 %@，正在自动回退", code]
        };
    }

    if ([line localizedCaseInsensitiveContainsString:@"NSURLErrorDomain"]) {
        NSString *code = errorCode ?: @"unknown";
        return @{
            @"key": [NSString stringWithFormat:@"noise.net.%@", code],
            @"line": [NSString stringWithFormat:@"<WARN> [网络] NSURLError %@", code]
        };
    }

    if (([line localizedCaseInsensitiveContainsString:@"Task <"]
        && [line localizedCaseInsensitiveContainsString:@"finished with error"])
        || ([line localizedCaseInsensitiveContainsString:@"Connection "]
            && [line localizedCaseInsensitiveContainsString:@"failed to connect"])
        || [line localizedCaseInsensitiveContainsString:@"nw_"]
        || [line localizedCaseInsensitiveContainsString:@"tcp_input"])
    {
        NSString *code = errorCode ?: @"unknown";
        return @{
            @"key": [NSString stringWithFormat:@"noise.net.%@", code],
            @"line": [NSString stringWithFormat:@"<WARN> [网络栈] 连接层异常 %@", code]
        };
    }

    if ([line localizedCaseInsensitiveContainsString:@"Recovered 1 audio data shards from block"]) {
        return @{
            @"key": @"stream.audio.fec.recovered",
            @"line": @"<INFO> [音频] FEC 分片已恢复"
        };
    }

    if ([line localizedCaseInsensitiveContainsString:@"Recovered 1 video data shards from frame"]) {
        return @{
            @"key": @"stream.video.fec.recovered",
            @"line": @"<INFO> [视频] FEC 分片已恢复"
        };
    }

    if ([line localizedCaseInsensitiveContainsString:@"Starting discovery"]) {
        return @{ @"key": @"default.discovery.start", @"line": @"<INFO> [发现] 开始扫描主机" };
    }

    if ([line localizedCaseInsensitiveContainsString:@"Starting mDNS discovery"]) {
        return @{ @"key": @"default.discovery.mdns.start", @"line": @"<INFO> [发现] 开始 mDNS 发现" };
    }

    if ([line localizedCaseInsensitiveContainsString:@"Stopping discovery"]) {
        return @{ @"key": @"default.discovery.stop", @"line": @"<INFO> [发现] 停止扫描主机" };
    }

    if ([line localizedCaseInsensitiveContainsString:@"Stopping mDNS discovery"]) {
        return @{ @"key": @"default.discovery.mdns.stop", @"line": @"<INFO> [发现] 停止 mDNS 发现" };
    }

    if ([line localizedCaseInsensitiveContainsString:@"Found new host:"]) {
        NSString *host = [[line componentsSeparatedByString:@"Found new host:"] lastObject];
        host = [host stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        return @{
            @"key": [NSString stringWithFormat:@"default.discovery.host.%@", host ?: @"unknown"],
            @"line": [NSString stringWithFormat:@"<INFO> [发现] 新主机 %@", host.length > 0 ? host : @"unknown"]
        };
    }

    if ([line localizedCaseInsensitiveContainsString:@"Server certificate mismatch"]) {
        return @{ @"key": @"default.identity.cert", @"line": @"<WARN> [身份] 服务器证书与已保存身份不匹配" };
    }

    if ([line localizedCaseInsensitiveContainsString:@"Received response from incorrect host:"]) {
        return @{ @"key": @"default.identity.host", @"line": @"<WARN> [身份] 收到错误主机的响应" };
    }

    if ([line localizedCaseInsensitiveContainsString:@"App list successfully retreived"]
        || [line localizedCaseInsensitiveContainsString:@"App list successfully retrieved"]) {
        return @{ @"key": @"default.applist.success", @"line": @"<INFO> [主机] 应用列表获取成功" };
    }

    if ([line localizedCaseInsensitiveContainsString:@"Stream target selection:"]) {
        return @{ @"key": @"default.stream.target", @"line": @"<INFO> [串流] 已选择串流目标" };
    }

    if ([line localizedCaseInsensitiveContainsString:@"Stream target classification:"]) {
        return @{ @"key": @"default.stream.classification", @"line": @"<INFO> [串流] 已完成路径判定" };
    }

    if ([line localizedCaseInsensitiveContainsString:@"Input summary ("]) {
        return @{ @"key": @"default.input.summary", @"line": @"<INFO> [输入] 输入统计摘要" };
    }

    return @{
        @"key": line,
        @"line": line
    };
}

- (NSString *)foldedDisplayLineWithBase:(NSString *)base count:(NSUInteger)count {
    if (count <= 1) {
        return base ?: @"";
    }
    return [NSString stringWithFormat:@"%@  ×%lu", base ?: @"", (unsigned long)count];
}

- (void)appendRenderedLineToOverlayTextView:(NSString *)line {
    if (!self.logOverlayTextView || !line) {
        return;
    }

    NSTextStorage *storage = self.logOverlayTextView.textStorage;
    if (!storage) {
        return;
    }

    BOOL needsNewline = storage.length > 0;
    if (needsNewline) {
        [storage appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"]];
    }

    NSUInteger start = storage.length;
    [storage appendAttributedString:[[NSAttributedString alloc] initWithString:line]];
    self.logOverlayLastRenderedRange = NSMakeRange(start, line.length);
    self.logOverlayHasLastRenderedRange = YES;
}

- (void)replaceLastRenderedLineInOverlayTextView:(NSString *)line {
    if (!self.logOverlayTextView || !line || !self.logOverlayHasLastRenderedRange) {
        return;
    }
    NSTextStorage *storage = self.logOverlayTextView.textStorage;
    if (!storage) {
        return;
    }
    if (NSMaxRange(self.logOverlayLastRenderedRange) > storage.length) {
        return;
    }
    [storage replaceCharactersInRange:self.logOverlayLastRenderedRange withString:line];
    self.logOverlayLastRenderedRange = NSMakeRange(self.logOverlayLastRenderedRange.location, line.length);
}

- (void)rebuildOverlayTextFromDisplayLines {
    if (!self.logOverlayTextView) {
        return;
    }
    NSString *joined = self.logOverlayDisplayLines.count > 0 ? [self.logOverlayDisplayLines componentsJoinedByString:@"\n"] : @"";
    self.logOverlayTextView.string = joined;
    if (self.logOverlayDisplayLines.count > 0) {
        NSString *last = self.logOverlayDisplayLines.lastObject ?: @"";
        self.logOverlayLastRenderedRange = NSMakeRange(joined.length - last.length, last.length);
        self.logOverlayHasLastRenderedRange = YES;
    } else {
        self.logOverlayHasLastRenderedRange = NO;
        self.logOverlayLastRenderedRange = NSMakeRange(0, 0);
    }
}

- (void)trimLogOverlayIfNeeded {
    if (self.logOverlayDisplayLines.count <= self.logOverlaySoftMaxLines) {
        return;
    }
    NSUInteger trimTo = self.logOverlayTrimToLines > 0 ? self.logOverlayTrimToLines : self.logOverlaySoftMaxLines;
    if (trimTo >= self.logOverlayDisplayLines.count) {
        return;
    }
    NSUInteger removeCount = self.logOverlayDisplayLines.count - trimTo;
    [self.logOverlayDisplayLines removeObjectsInRange:NSMakeRange(0, removeCount)];
    [self rebuildOverlayTextFromDisplayLines];
}

- (void)appendRawLogLineToOverlayState:(NSString *)rawLine {
    NSDictionary<NSString *, NSString *> *presentation =
        [self.logOverlayModeKey isEqualToString:@"raw"] ? nil : [self compactPresentationForLogLine:rawLine];
    NSString *foldKey = presentation[@"key"] ?: rawLine;
    NSString *baseLine = presentation[@"line"] ?: rawLine;
    if (!foldKey.length) {
        foldKey = rawLine ?: @"";
    }
    if (!baseLine.length) {
        baseLine = rawLine ?: @"";
    }

    if (self.logOverlayLastFoldKey && [self.logOverlayLastFoldKey isEqualToString:foldKey] && self.logOverlayDisplayLines.count > 0) {
        self.logOverlayLastFoldCount += 1;
        NSString *merged = [self foldedDisplayLineWithBase:self.logOverlayLastFoldBaseLine count:self.logOverlayLastFoldCount];
        self.logOverlayDisplayLines[self.logOverlayDisplayLines.count - 1] = merged;
        [self replaceLastRenderedLineInOverlayTextView:merged];
        return;
    }

    self.logOverlayLastFoldKey = foldKey;
    self.logOverlayLastFoldBaseLine = baseLine;
    self.logOverlayLastFoldCount = 1;
    [self.logOverlayDisplayLines addObject:baseLine];
    [self appendRenderedLineToOverlayTextView:baseLine];
    [self trimLogOverlayIfNeeded];
}

- (void)appendRawLinesToOverlayState:(NSArray<NSString *> *)rawLines {
    for (NSString *line in rawLines) {
        [self appendRawLogLineToOverlayState:line];
    }
}

- (BOOL)rawLogLineMatchesOverlayFilters:(NSString *)rawLine {
    if (!rawLine.length) {
        return NO;
    }

    NSInteger requiredLevelRank = [self requiredLogOverlayLevelRank];
    if (requiredLevelRank != NSIntegerMin &&
        [self logOverlayLevelRankForRawLine:rawLine] < requiredLevelRank) {
        return NO;
    }

    MLLogCategoryDescriptor *descriptor = [MLLogCategoryClassifier descriptorForLine:rawLine];
    if (![descriptor matchesFilterKey:self.logOverlayCategoryFilterKey]) {
        return NO;
    }

    NSString *keyword = [[self.logOverlaySearchText ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    if (keyword.length == 0) {
        return YES;
    }

    NSDictionary<NSString *, NSString *> *presentation =
        [self.logOverlayModeKey isEqualToString:@"raw"] ? nil : [self compactPresentationForLogLine:rawLine];
    NSString *searchable = [NSString stringWithFormat:@"%@\n%@\n%@",
                            rawLine ?: @"",
                            descriptor.searchableText ?: @"",
                            presentation[@"line"] ?: @""].lowercaseString;
    return [searchable containsString:keyword];
}

- (void)rebuildLogOverlayDisplayFromAllRawLines {
    [self.logOverlayDisplayLines removeAllObjects];
    self.logOverlayLastFoldKey = nil;
    self.logOverlayLastFoldBaseLine = nil;
    self.logOverlayLastFoldCount = 0;
    self.logOverlayHasLastRenderedRange = NO;
    self.logOverlayLastRenderedRange = NSMakeRange(0, 0);
    self.logOverlayTextView.string = @"";

    for (NSString *rawLine in self.logOverlayAllRawLines) {
        if ([self rawLogLineMatchesOverlayFilters:rawLine]) {
            [self appendRawLogLineToOverlayState:rawLine];
        }
    }

    if (self.logOverlayAutoScrollEnabled) {
        [self scrollLogOverlayToLatest];
    }
    [self updateLogOverlayToolbarState];
}

- (void)ingestRawLogLinesToOverlay:(NSArray<NSString *> *)rawLines {
    if (rawLines.count == 0) {
        return;
    }

    for (NSString *rawLine in rawLines) {
        if (!rawLine.length) {
            continue;
        }
        [self.logOverlayAllRawLines addObject:rawLine];
    }

    if (self.logOverlayAllRawLines.count > 5000) {
        [self.logOverlayAllRawLines removeObjectsInRange:NSMakeRange(0, self.logOverlayAllRawLines.count - 5000)];
    }

    for (NSString *rawLine in rawLines) {
        if ([self rawLogLineMatchesOverlayFilters:rawLine]) {
            [self appendRawLogLineToOverlayState:rawLine];
        }
    }
}

- (void)populateLogOverlayCategoryPopup:(NSPopUpButton *)popup {
    if (!popup) {
        return;
    }

    [popup removeAllItems];
    [popup addItemWithTitle:@"全部 / All"];
    popup.itemArray.lastObject.representedObject = @"all";

    for (MLLogCategoryDescriptor *descriptor in [MLLogCategoryClassifier filterOptions]) {
        [popup addItemWithTitle:descriptor.displayName ?: descriptor.categoryKey];
        popup.itemArray.lastObject.representedObject = descriptor.categoryKey;
    }

    NSInteger matchIndex = NSNotFound;
    for (NSInteger index = 0; index < (NSInteger)popup.itemArray.count; index++) {
        NSMenuItem *item = popup.itemArray[index];
        if ([item.representedObject isKindOfClass:[NSString class]] &&
            [item.representedObject isEqualToString:self.logOverlayCategoryFilterKey ?: @"all"]) {
            matchIndex = index;
            break;
        }
    }
    if (matchIndex != NSNotFound) {
        [popup selectItemAtIndex:matchIndex];
    } else {
        [popup selectItemAtIndex:0];
    }
}

- (void)populateLogOverlayModePopup:(NSPopUpButton *)popup {
    if (!popup) {
        return;
    }

    [popup removeAllItems];
    [popup addItemWithTitle:@"默认日志"];
    popup.itemArray.lastObject.representedObject = @"default";
    [popup addItemWithTitle:@"原始日志"];
    popup.itemArray.lastObject.representedObject = @"raw";

    NSInteger matchIndex = 0;
    for (NSInteger index = 0; index < (NSInteger)popup.itemArray.count; index++) {
        NSMenuItem *item = popup.itemArray[index];
        if ([item.representedObject isKindOfClass:[NSString class]] &&
            [item.representedObject isEqualToString:self.logOverlayModeKey ?: @"default"]) {
            matchIndex = index;
            break;
        }
    }
    [popup selectItemAtIndex:matchIndex];
}

- (void)populateLogOverlayLevelPopup:(NSPopUpButton *)popup {
    if (!popup) {
        return;
    }

    [popup removeAllItems];
    NSArray<NSArray<NSString *> *> *items = @[
        @[ @"全部级别", @"all" ],
        @[ @"Debug+", @"debug" ],
        @[ @"Info+", @"info" ],
        @[ @"Warn+", @"warn" ],
        @[ @"Error", @"error" ],
    ];
    for (NSArray<NSString *> *item in items) {
        [popup addItemWithTitle:item[0]];
        popup.itemArray.lastObject.representedObject = item[1];
    }

    NSInteger matchIndex = 0;
    for (NSInteger index = 0; index < (NSInteger)popup.itemArray.count; index++) {
        NSMenuItem *item = popup.itemArray[index];
        if ([item.representedObject isKindOfClass:[NSString class]] &&
            [item.representedObject isEqualToString:self.logOverlayMinimumLevelKey ?: @"all"]) {
            matchIndex = index;
            break;
        }
    }
    [popup selectItemAtIndex:matchIndex];
}

- (void)scrollLogOverlayToLatest {
    if (!self.logOverlayTextView) {
        return;
    }
    [self.logOverlayTextView scrollRangeToVisible:NSMakeRange(self.logOverlayTextView.string.length, 0)];
}

- (void)updateLogOverlayToolbarState {
    if (!self.logOverlayContainer) {
        return;
    }
    NSButton *pauseBtn = [self.logOverlayContainer viewWithTag:1001];
    NSButton *autoScrollBtn = [self.logOverlayContainer viewWithTag:1002];
    NSButton *jumpBtn = [self.logOverlayContainer viewWithTag:1003];
    NSButton *copyBtn = [self.logOverlayContainer viewWithTag:1004];
    NSButton *clearBtn = [self.logOverlayContainer viewWithTag:1006];
    NSSearchField *searchField = [self.logOverlayContainer viewWithTag:1007];
    NSTextField *statusLabel = [self.logOverlayContainer viewWithTag:1005];
    NSPopUpButton *categoryPopup = [self.logOverlayContainer viewWithTag:1008];
    NSPopUpButton *modePopup = [self.logOverlayContainer viewWithTag:1009];
    NSPopUpButton *levelPopup = [self.logOverlayContainer viewWithTag:1010];

    if (pauseBtn) {
        pauseBtn.title = self.logOverlayPauseUpdates ? @"继续更新" : @"暂停更新";
    }
    if (autoScrollBtn) {
        autoScrollBtn.title = self.logOverlayAutoScrollEnabled ? @"暂停滚动" : @"开启滚动";
    }
    if (jumpBtn) {
        jumpBtn.enabled = self.logOverlayDisplayLines.count > 0;
    }
    if (clearBtn) {
        clearBtn.enabled = (self.logOverlayDisplayLines.count > 0 ||
                            self.logOverlayPausedRawLines.count > 0 ||
                            self.logOverlayAllRawLines.count > 0);
    }
    if (copyBtn) {
        copyBtn.title = [self.logOverlayModeKey isEqualToString:@"raw"] ? @"复制原始日志" : @"复制默认日志";
        copyBtn.enabled = self.logOverlayDisplayLines.count > 0;
    }
    if (searchField && ![searchField.stringValue isEqualToString:self.logOverlaySearchText ?: @""]) {
        searchField.stringValue = self.logOverlaySearchText ?: @"";
    }
    if (modePopup) {
        NSInteger matchIndex = NSNotFound;
        for (NSInteger index = 0; index < (NSInteger)modePopup.itemArray.count; index++) {
            NSMenuItem *item = modePopup.itemArray[index];
            if ([item.representedObject isKindOfClass:[NSString class]] &&
                [item.representedObject isEqualToString:self.logOverlayModeKey ?: @"default"]) {
                matchIndex = index;
                break;
            }
        }
        if (matchIndex != NSNotFound) {
            [modePopup selectItemAtIndex:matchIndex];
        }
    }
    if (levelPopup) {
        NSInteger matchIndex = NSNotFound;
        for (NSInteger index = 0; index < (NSInteger)levelPopup.itemArray.count; index++) {
            NSMenuItem *item = levelPopup.itemArray[index];
            if ([item.representedObject isKindOfClass:[NSString class]] &&
                [item.representedObject isEqualToString:self.logOverlayMinimumLevelKey ?: @"all"]) {
                matchIndex = index;
                break;
            }
        }
        if (matchIndex != NSNotFound) {
            [levelPopup selectItemAtIndex:matchIndex];
        }
    }
    if (categoryPopup) {
        NSInteger matchIndex = NSNotFound;
        for (NSInteger index = 0; index < (NSInteger)categoryPopup.itemArray.count; index++) {
            NSMenuItem *item = categoryPopup.itemArray[index];
            if ([item.representedObject isKindOfClass:[NSString class]] &&
                [item.representedObject isEqualToString:self.logOverlayCategoryFilterKey ?: @"all"]) {
                matchIndex = index;
                break;
            }
        }
        if (matchIndex != NSNotFound) {
            [categoryPopup selectItemAtIndex:matchIndex];
        }
    }
    if (statusLabel) {
        NSMutableArray<NSString *> *parts = [[NSMutableArray alloc] init];
        NSString *modeSummary = [self.logOverlayModeKey isEqualToString:@"raw"] ? @"原始日志" : @"默认日志";
        [parts addObject:modeSummary];

        NSString *levelSummary = @"全部级别";
        if ([self.logOverlayMinimumLevelKey isEqualToString:@"debug"]) {
            levelSummary = @"Debug+";
        } else if ([self.logOverlayMinimumLevelKey isEqualToString:@"info"]) {
            levelSummary = @"Info+";
        } else if ([self.logOverlayMinimumLevelKey isEqualToString:@"warn"]) {
            levelSummary = @"Warn+";
        } else if ([self.logOverlayMinimumLevelKey isEqualToString:@"error"]) {
            levelSummary = @"Error";
        }
        [parts addObject:levelSummary];

        NSString *categorySummary = [MLLogCategoryClassifier displayNameForFilterKey:self.logOverlayCategoryFilterKey];
        if (categorySummary.length > 0 && ![self.logOverlayCategoryFilterKey isEqualToString:@"all"]) {
            [parts addObject:categorySummary];
        }

        NSString *keyword = [self.logOverlaySearchText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (keyword.length > 0) {
            [parts addObject:[NSString stringWithFormat:@"搜索=%@", keyword]];
        }

        [parts addObject:[NSString stringWithFormat:@"显示 %lu 行 / 原始 %lu 条",
                          (unsigned long)self.logOverlayDisplayLines.count,
                          (unsigned long)self.logOverlayAllRawLines.count]];

        if (self.logOverlayPauseUpdates && self.logOverlayPausedRawLines.count > 0) {
            [parts addObject:[NSString stringWithFormat:@"暂停中，待处理 %lu 条",
                              (unsigned long)self.logOverlayPausedRawLines.count]];
            statusLabel.stringValue = [parts componentsJoinedByString:@" | "];
        } else {
            statusLabel.stringValue = [parts componentsJoinedByString:@" | "];
        }
    }
}

- (NSArray<NSString *> *)compactLinesFromRawLines:(NSArray<NSString *> *)rawLines {
    NSMutableArray<NSString *> *result = [[NSMutableArray alloc] init];
    NSString *lastKey = nil;
    NSString *lastBase = nil;
    NSUInteger lastCount = 0;

    for (NSString *rawLine in rawLines) {
        NSDictionary<NSString *, NSString *> *presentation = [self compactPresentationForLogLine:rawLine];
        NSString *foldKey = presentation[@"key"] ?: rawLine;
        NSString *baseLine = presentation[@"line"] ?: rawLine;
        if (!foldKey.length) {
            foldKey = rawLine ?: @"";
        }
        if (!baseLine.length) {
            baseLine = rawLine ?: @"";
        }

        if (lastKey && [lastKey isEqualToString:foldKey] && result.count > 0) {
            lastCount += 1;
            result[result.count - 1] = [self foldedDisplayLineWithBase:lastBase count:lastCount];
            continue;
        }

        lastKey = foldKey;
        lastBase = baseLine;
        lastCount = 1;
        [result addObject:baseLine];
    }

    return result;
}

- (void)handleTimeoutCopyLogs:(id)sender {
    [self copyAllLogsToPasteboard];

    if ([sender isKindOfClass:[NSButton class]]) {
        NSButton *btn = (NSButton *)sender;
        NSString *origTitle = btn.title;
        btn.title = @"已复制";
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if ([btn.title isEqualToString:@"已复制"]) {
                btn.title = origTitle;
            }
        });
    }
}

- (void)showLogOverlay {
    if (self.logOverlayContainer) {
        return;
    }

    [self resetLogOverlayState];

    self.logOverlayContainer = [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
    self.logOverlayContainer.material = NSVisualEffectMaterialHUDWindow;
    self.logOverlayContainer.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    self.logOverlayContainer.state = NSVisualEffectStateActive;
    self.logOverlayContainer.wantsLayer = YES;
    self.logOverlayContainer.layer.cornerRadius = 12.0;
    self.logOverlayContainer.layer.masksToBounds = YES;
    
    // Close Button
    NSButton *closeBtn = [NSButton buttonWithTitle:@"关闭" target:self action:@selector(handleLogOverlayClose:)];
    closeBtn.bezelStyle = NSBezelStyleRounded;
    closeBtn.controlSize = NSControlSizeRegular;
    closeBtn.tag = 999;
    [self.logOverlayContainer addSubview:closeBtn];

    NSButton *pauseBtn = [NSButton buttonWithTitle:@"暂停更新" target:self action:@selector(handleLogOverlayPauseToggle:)];
    pauseBtn.bezelStyle = NSBezelStyleRounded;
    pauseBtn.controlSize = NSControlSizeSmall;
    pauseBtn.tag = 1001;
    [self.logOverlayContainer addSubview:pauseBtn];

    NSButton *autoScrollBtn = [NSButton buttonWithTitle:@"暂停滚动" target:self action:@selector(handleLogOverlayAutoScrollToggle:)];
    autoScrollBtn.bezelStyle = NSBezelStyleRounded;
    autoScrollBtn.controlSize = NSControlSizeSmall;
    autoScrollBtn.tag = 1002;
    [self.logOverlayContainer addSubview:autoScrollBtn];

    NSButton *jumpLatestBtn = [NSButton buttonWithTitle:@"最新" target:self action:@selector(handleLogOverlayJumpLatest:)];
    jumpLatestBtn.bezelStyle = NSBezelStyleRounded;
    jumpLatestBtn.controlSize = NSControlSizeSmall;
    jumpLatestBtn.tag = 1003;
    [self.logOverlayContainer addSubview:jumpLatestBtn];

    NSButton *copyBtn = [NSButton buttonWithTitle:@"复制默认日志" target:self action:@selector(handleLogOverlayCopyCompact:)];
    copyBtn.bezelStyle = NSBezelStyleRounded;
    copyBtn.controlSize = NSControlSizeSmall;
    copyBtn.tag = 1004;
    [self.logOverlayContainer addSubview:copyBtn];

    NSButton *clearBtn = [NSButton buttonWithTitle:@"从现在开始" target:self action:@selector(handleLogOverlayClearFromNow:)];
    clearBtn.bezelStyle = NSBezelStyleRounded;
    clearBtn.controlSize = NSControlSizeSmall;
    clearBtn.tag = 1006;
    [self.logOverlayContainer addSubview:clearBtn];

    self.logOverlayModePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.logOverlayModePopup.font = [NSFont systemFontOfSize:12 weight:NSFontWeightRegular];
    self.logOverlayModePopup.target = self;
    self.logOverlayModePopup.action = @selector(handleLogOverlayModeChanged:);
    self.logOverlayModePopup.tag = 1009;
    [self populateLogOverlayModePopup:self.logOverlayModePopup];
    [self.logOverlayContainer addSubview:self.logOverlayModePopup];

    self.logOverlayLevelPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.logOverlayLevelPopup.font = [NSFont systemFontOfSize:12 weight:NSFontWeightRegular];
    self.logOverlayLevelPopup.target = self;
    self.logOverlayLevelPopup.action = @selector(handleLogOverlayLevelChanged:);
    self.logOverlayLevelPopup.tag = 1010;
    [self populateLogOverlayLevelPopup:self.logOverlayLevelPopup];
    [self.logOverlayContainer addSubview:self.logOverlayLevelPopup];

    self.logOverlaySearchField = [[NSSearchField alloc] initWithFrame:NSZeroRect];
    self.logOverlaySearchField.placeholderString = @"搜索关键词 / 主机 / 错误码";
    self.logOverlaySearchField.font = [NSFont systemFontOfSize:12 weight:NSFontWeightRegular];
    self.logOverlaySearchField.sendsWholeSearchString = NO;
    self.logOverlaySearchField.sendsSearchStringImmediately = YES;
    self.logOverlaySearchField.target = self;
    self.logOverlaySearchField.action = @selector(handleLogOverlaySearchChanged:);
    self.logOverlaySearchField.tag = 1007;
    [self.logOverlayContainer addSubview:self.logOverlaySearchField];

    self.logOverlayCategoryPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.logOverlayCategoryPopup.font = [NSFont systemFontOfSize:12 weight:NSFontWeightRegular];
    self.logOverlayCategoryPopup.target = self;
    self.logOverlayCategoryPopup.action = @selector(handleLogOverlayCategoryChanged:);
    self.logOverlayCategoryPopup.tag = 1008;
    [self populateLogOverlayCategoryPopup:self.logOverlayCategoryPopup];
    [self.logOverlayContainer addSubview:self.logOverlayCategoryPopup];

    NSTextField *statusLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
    statusLabel.bezeled = NO;
    statusLabel.drawsBackground = NO;
    statusLabel.editable = NO;
    statusLabel.selectable = NO;
    statusLabel.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    statusLabel.textColor = [NSColor colorWithWhite:0.85 alpha:1.0];
    statusLabel.tag = 1005;
    statusLabel.stringValue = @"显示 0 行";
    [self.logOverlayContainer addSubview:statusLabel];

    self.logOverlayScrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    self.logOverlayScrollView.hasVerticalScroller = YES;
    self.logOverlayScrollView.drawsBackground = NO;

    self.logOverlayTextView = [[NSTextView alloc] initWithFrame:NSZeroRect];
    self.logOverlayTextView.editable = NO;
    self.logOverlayTextView.selectable = YES;
    self.logOverlayTextView.drawsBackground = NO;
    self.logOverlayTextView.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    self.logOverlayTextView.textColor = [NSColor whiteColor];
    
    self.logOverlayTextView.minSize = NSMakeSize(0.0, 0.0);
    self.logOverlayTextView.maxSize = NSMakeSize(FLT_MAX, FLT_MAX);
    self.logOverlayTextView.verticallyResizable = YES;
    self.logOverlayTextView.horizontallyResizable = NO;
    self.logOverlayTextView.textContainer.widthTracksTextView = YES;
    self.logOverlayTextView.textContainer.containerSize = NSMakeSize(FLT_MAX, FLT_MAX);

    self.logOverlayScrollView.documentView = self.logOverlayTextView;
    [self.logOverlayContainer addSubview:self.logOverlayScrollView];

    [self.view addSubview:self.logOverlayContainer positioned:NSWindowAbove relativeTo:nil];
    [self viewDidLayout];

    // Seed with existing buffered logs
    NSArray<NSString *> *lines = [[LogBuffer shared] allLines];
    if (lines.count > 0) {
        [self ingestRawLogLinesToOverlay:lines];
    }
    [self updateLogOverlayToolbarState];

    self.logOverlayContainer.alphaValue = 0.0;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.18;
        self.logOverlayContainer.animator.alphaValue = 1.0;
    } completionHandler:nil];
}

- (void)hideLogOverlay {
    if (!self.logOverlayContainer) {
        return;
    }
    
    // If opened from timeout menu (not stream menu), we allow closing it
    // without closing the underlying timeout menu.
    
    NSVisualEffectView *container = self.logOverlayContainer;
    self.logOverlayContainer = nil;
    self.logOverlayScrollView = nil;
    self.logOverlayTextView = nil;
    self.logOverlaySearchField = nil;
    self.logOverlayModePopup = nil;
    self.logOverlayLevelPopup = nil;
    self.logOverlayCategoryPopup = nil;
    self.logOverlayAllRawLines = nil;
    self.logOverlayDisplayLines = nil;
    self.logOverlayPausedRawLines = nil;
    self.logOverlayLastFoldKey = nil;
    self.logOverlayLastFoldBaseLine = nil;
    self.logOverlayModeKey = nil;
    self.logOverlayMinimumLevelKey = nil;
    self.logOverlaySearchText = nil;
    self.logOverlayCategoryFilterKey = nil;
    self.logOverlayLastFoldCount = 0;
    self.logOverlayHasLastRenderedRange = NO;

    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.15;
        container.animator.alphaValue = 0.0;
    } completionHandler:^{
        [container removeFromSuperview];
    }];
}

- (void)handleLogOverlayClose:(id)sender {
    [self hideLogOverlay];
}

- (void)handleLogOverlayPauseToggle:(id)sender {
    self.logOverlayPauseUpdates = !self.logOverlayPauseUpdates;
    if (!self.logOverlayPauseUpdates && self.logOverlayPausedRawLines.count > 0) {
        NSArray<NSString *> *pending = [self.logOverlayPausedRawLines copy];
        [self.logOverlayPausedRawLines removeAllObjects];
        [self ingestRawLogLinesToOverlay:pending];
        if (self.logOverlayAutoScrollEnabled) {
            [self scrollLogOverlayToLatest];
        }
    }
    [self updateLogOverlayToolbarState];
}

- (void)handleLogOverlayAutoScrollToggle:(id)sender {
    self.logOverlayAutoScrollEnabled = !self.logOverlayAutoScrollEnabled;
    if (self.logOverlayAutoScrollEnabled) {
        [self scrollLogOverlayToLatest];
    }
    [self updateLogOverlayToolbarState];
}

- (void)handleLogOverlayJumpLatest:(id)sender {
    [self scrollLogOverlayToLatest];
}

- (void)handleLogOverlayCopyCompact:(id)sender {
    [self copyAllLogsToPasteboard];
}

- (void)handleLogOverlayClearFromNow:(id)sender {
    [self.logOverlayAllRawLines removeAllObjects];
    [self.logOverlayDisplayLines removeAllObjects];
    [self.logOverlayPausedRawLines removeAllObjects];
    self.logOverlayLastFoldKey = nil;
    self.logOverlayLastFoldBaseLine = nil;
    self.logOverlayLastFoldCount = 0;
    self.logOverlayHasLastRenderedRange = NO;
    self.logOverlayLastRenderedRange = NSMakeRange(0, 0);
    self.logOverlayTextView.string = @"";
    [self updateLogOverlayToolbarState];
}

- (void)handleLogOverlaySearchChanged:(id)sender {
    NSSearchField *searchField = [sender isKindOfClass:[NSSearchField class]] ? (NSSearchField *)sender : self.logOverlaySearchField;
    self.logOverlaySearchText = searchField.stringValue ?: @"";
    [self rebuildLogOverlayDisplayFromAllRawLines];
}

- (void)handleLogOverlayCategoryChanged:(id)sender {
    NSPopUpButton *popup = [sender isKindOfClass:[NSPopUpButton class]] ? (NSPopUpButton *)sender : self.logOverlayCategoryPopup;
    NSString *selectedKey = [popup.selectedItem.representedObject isKindOfClass:[NSString class]] ? popup.selectedItem.representedObject : @"all";
    self.logOverlayCategoryFilterKey = selectedKey ?: @"all";
    [self rebuildLogOverlayDisplayFromAllRawLines];
}

- (void)handleLogOverlayModeChanged:(id)sender {
    NSPopUpButton *popup = [sender isKindOfClass:[NSPopUpButton class]] ? (NSPopUpButton *)sender : self.logOverlayModePopup;
    NSString *selectedKey = [popup.selectedItem.representedObject isKindOfClass:[NSString class]] ? popup.selectedItem.representedObject : @"default";
    self.logOverlayModeKey = selectedKey ?: @"default";
    [self rebuildLogOverlayDisplayFromAllRawLines];
}

- (void)handleLogOverlayLevelChanged:(id)sender {
    NSPopUpButton *popup = [sender isKindOfClass:[NSPopUpButton class]] ? (NSPopUpButton *)sender : self.logOverlayLevelPopup;
    NSString *selectedKey = [popup.selectedItem.representedObject isKindOfClass:[NSString class]] ? popup.selectedItem.representedObject : @"all";
    self.logOverlayMinimumLevelKey = selectedKey ?: @"all";
    [self rebuildLogOverlayDisplayFromAllRawLines];
}

- (void)appendLogLineToOverlay:(NSString *)line {
    if (!self.logOverlayTextView || !line) {
        return;
    }

    if (self.logOverlayPauseUpdates) {
        [self.logOverlayPausedRawLines addObject:line];
        if (self.logOverlayPausedRawLines.count > 4000) {
            [self.logOverlayPausedRawLines removeObjectsInRange:NSMakeRange(0, self.logOverlayPausedRawLines.count - 4000)];
        }
        [self updateLogOverlayToolbarState];
        return;
    }

    [self ingestRawLogLinesToOverlay:@[ line ]];
    if (self.logOverlayAutoScrollEnabled) {
        [self scrollLogOverlayToLatest];
    }
    [self updateLogOverlayToolbarState];
}

- (void)copyAllLogsToPasteboard {
    NSString *joined = nil;
    if (self.logOverlayContainer && self.logOverlayDisplayLines != nil) {
        joined = [self.logOverlayDisplayLines componentsJoinedByString:@"\n"];
    } else {
        NSArray<NSString *> *lines = [[LogBuffer shared] allLines];
        NSArray<NSString *> *compact = [self compactLinesFromRawLines:lines];
        joined = [compact componentsJoinedByString:@"\n"];
    }
    if (joined.length == 0) {
        return;
    }

    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    [pb setString:joined forType:NSPasteboardTypeString];

    [self showNotification:MLString(@"Logs copied", nil) forSeconds:1.2];
}

#pragma mark - Reconnect Overlay

- (void)showReconnectOverlayWithMessage:(NSString *)message {
    if (!self.reconnectOverlayContainer) {
        self.reconnectOverlayContainer = [[NSVisualEffectView alloc] initWithFrame:self.view.bounds];
        self.reconnectOverlayContainer.material = NSVisualEffectMaterialHUDWindow;
        self.reconnectOverlayContainer.blendingMode = NSVisualEffectBlendingModeWithinWindow;
        self.reconnectOverlayContainer.state = NSVisualEffectStateActive;
        self.reconnectOverlayContainer.wantsLayer = YES;
        self.reconnectOverlayContainer.layer.backgroundColor = [[NSColor colorWithWhite:0 alpha:0.55] CGColor];

        self.reconnectSpinner = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
        self.reconnectSpinner.style = NSProgressIndicatorStyleSpinning;
        self.reconnectSpinner.controlSize = NSControlSizeRegular;
        [self.reconnectSpinner startAnimation:nil];

        self.reconnectLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
        self.reconnectLabel.bezeled = NO;
        self.reconnectLabel.drawsBackground = NO;
        self.reconnectLabel.editable = NO;
        self.reconnectLabel.selectable = NO;
        self.reconnectLabel.font = [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold];
        self.reconnectLabel.textColor = [NSColor whiteColor];
        self.reconnectLabel.alignment = NSTextAlignmentCenter;

        [self.reconnectOverlayContainer addSubview:self.reconnectSpinner];
        [self.reconnectOverlayContainer addSubview:self.reconnectLabel];
        [self.view addSubview:self.reconnectOverlayContainer positioned:NSWindowAbove relativeTo:nil];

        self.reconnectOverlayContainer.alphaValue = 0.0;
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = 0.12;
            self.reconnectOverlayContainer.animator.alphaValue = 1.0;
        } completionHandler:nil];
    }

    self.reconnectLabel.stringValue = message ?: MLString(@"Reconnecting…", nil);
    [self viewDidLayout];
}

- (void)hideReconnectOverlay {
    if (!self.reconnectOverlayContainer) {
        return;
    }

    NSVisualEffectView *container = self.reconnectOverlayContainer;
    self.reconnectOverlayContainer = nil;
    self.reconnectSpinner = nil;
    self.reconnectLabel = nil;

    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.15;
        container.animator.alphaValue = 0.0;
    } completionHandler:^{
        [container removeFromSuperview];
    }];
}

- (void)attemptReconnectWithReason:(NSString *)reason {
    if (!self.shouldAttemptReconnect) {
        return;
    }
    if (self.reconnectInProgress) {
        Log(LOG_W, @"[diag] Reconnect request ignored: already reconnecting (reason=%@)", reason ?: @"unknown");
        return;
    }

    // Preserve fullscreen/windowed state across reconnects.
    self.reconnectPreserveFullscreenStateValid = YES;
    if ([self isWindowFullscreen]) {
        self.reconnectPreservedWindowMode = 1;
    } else if ([self isWindowBorderlessMode]) {
        self.reconnectPreservedWindowMode = 2;
    } else {
        self.reconnectPreservedWindowMode = 0;
    }

    NSUInteger reconnectGeneration = 0;
    @synchronized (self) {
        if (self.stopStreamInProgress || self.reconnectInProgress) {
            Log(LOG_W, @"[diag] Reconnect request ignored by guard: reconnectInProgress=%d stopInProgress=%d reason=%@",
                self.reconnectInProgress ? 1 : 0,
                self.stopStreamInProgress ? 1 : 0,
                reason ?: @"unknown");
            return;
        }
        self.stopStreamInProgress = YES;
        self.reconnectInProgress = YES;
        self.activeStreamGeneration += 1;
        reconnectGeneration = self.activeStreamGeneration;
    }

    Log(LOG_I, @"[diag] Reconnect requested: reason=%@", reason ?: @"unknown");
    self.reconnectAttemptCount += 1;
    NSString *msg = [NSString stringWithFormat:MLString(@"Reconnecting… (%ld)", nil), (long)self.reconnectAttemptCount];
    [self showReconnectOverlayWithMessage:msg];

    // Suppress transient warnings while we tear down/restart.
    [self suppressConnectionWarningsForSeconds:5.0 reason:[NSString stringWithFormat:@"reconnect-%@", reason ?: @"unknown"]];

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        double stopStart = CACurrentMediaTime();
        [weakSelf.streamMan stopStream];
        Log(LOG_I, @"Reconnect stop took %.3fs", CACurrentMediaTime() - stopStart);

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }

            @synchronized (strongSelf) {
                strongSelf.stopStreamInProgress = NO;
            }

            if (![strongSelf isActiveStreamGeneration:reconnectGeneration] ||
                !strongSelf.reconnectInProgress ||
                !strongSelf.shouldAttemptReconnect ||
                strongSelf.disconnectWasUserInitiated) {
                Log(LOG_I, @"[diag] Reconnect aborted after stop: reason=%@ gen=%lu activeGen=%lu reconnect=%d shouldAttempt=%d userDisconnect=%d",
                    reason ?: @"unknown",
                    (unsigned long)reconnectGeneration,
                    (unsigned long)strongSelf.activeStreamGeneration,
                    strongSelf.reconnectInProgress ? 1 : 0,
                    strongSelf.shouldAttemptReconnect ? 1 : 0,
                    strongSelf.disconnectWasUserInitiated ? 1 : 0);
                [strongSelf hideReconnectOverlay];
                return;
            }

            if (strongSelf.useSystemControllerDriver) {
                [strongSelf tearDownControllerSupportOnMainThreadIfNeeded];
            }
            [strongSelf.hidSupport tearDownHidManager];
            strongSelf.hidSupport = nil;

            // Restart streaming without leaving the page.
            [strongSelf prepareForStreaming];
        });
    });
}

- (void)setupOverlay {
    if (self.overlayContainer) {
        [self.overlayContainer removeFromSuperview];
    }
    
    self.overlayContainer = [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
    self.overlayContainer.material = NSVisualEffectMaterialHUDWindow;
    self.overlayContainer.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    self.overlayContainer.state = NSVisualEffectStateActive;
    self.overlayContainer.wantsLayer = YES;
    self.overlayContainer.layer.cornerRadius = 10.0;
    self.overlayContainer.layer.masksToBounds = YES;
    
    self.overlayLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.overlayLabel.bezeled = NO;
    self.overlayLabel.drawsBackground = NO;
    self.overlayLabel.editable = NO;
    self.overlayLabel.selectable = NO;
    self.overlayLabel.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightRegular];
    
    [self.overlayContainer addSubview:self.overlayLabel];

    // Ensure overlay is always above the video render view.
    [self.view addSubview:self.overlayContainer positioned:NSWindowAbove relativeTo:nil];

    // Hide until we have at least one received frame (avoid showing a black HUD during RTSP handshake).
    self.overlayContainer.hidden = YES;

    if (self.statsTimer) {
        [self.statsTimer invalidate];
        self.statsTimer = nil;
    }
    self.statsTimer = [NSTimer timerWithTimeInterval:MLStatsOverlayRefreshIntervalSec
                                              target:self
                                            selector:@selector(updateStats)
                                            userInfo:nil
                                             repeats:YES];
    self.statsTimer.tolerance = 0.1;
    [[NSRunLoop mainRunLoop] addTimer:self.statsTimer forMode:NSRunLoopCommonModes];
    [self updateStats]; // Initial update
}

- (void)updateStats {
    if (!self.overlayContainer) return;

    VideoStats stats = self.streamMan.connection.renderer.videoStats;
    int videoFormat = self.streamMan.connection.renderer.videoFormat;

    BOOL hasVideoData = (stats.receivedFrames > 0 ||
                         stats.decodedFrames > 0 ||
                         stats.renderedFrames > 0 ||
                         stats.receivedBytes > 0);
    BOOL shouldShowForHealth = (self.streamHealthNoPayloadStreak > 0 || self.streamHealthFrozenStatsStreak > 0);
    if (!hasVideoData && !shouldShowForHealth) {
        self.overlayContainer.hidden = YES;
        return;
    }
    self.overlayContainer.hidden = NO;
    
    NSString *codecString = @"Unknown";
    if (videoFormat & VIDEO_FORMAT_MASK_H264) {
        codecString = @"H.264";
    } else if (videoFormat & VIDEO_FORMAT_MASK_H265) {
        if (videoFormat & VIDEO_FORMAT_MASK_10BIT) {
            codecString = @"HEVC 10-bit";
        } else {
            codecString = @"HEVC";
        }
    } else if (videoFormat & VIDEO_FORMAT_MASK_AV1) {
        if (videoFormat & VIDEO_FORMAT_MASK_10BIT) {
            codecString = @"AV1 10-bit";
        } else {
            codecString = @"AV1";
        }
    }

    NSString *chromaString = (videoFormat & VIDEO_FORMAT_MASK_YUV444) ? @"4:4:4" : @"4:2:0";
    
    DataManager* dataMan = [[DataManager alloc] init];
    TemporarySettings* streamSettings = [dataMan getSettings];

    struct Resolution res = [self.class getResolution];
    int configuredFps = streamSettings.framerate != nil ? [streamSettings.framerate intValue] : 0;
    uint64_t nowStatsMs = LiGetMillis();
    uint64_t measurementElapsedMs = 0;
    if (stats.measurementStartTimestamp > 0 && nowStatsMs >= stats.measurementStartTimestamp) {
        measurementElapsedMs = MAX(1ULL, nowStatsMs - stats.measurementStartTimestamp);
    }

    float (^displayedFps)(float, uint32_t) = ^float(float completedFps, uint32_t frameCount) {
        if (completedFps > 0.05f) {
            return completedFps;
        }
        if (measurementElapsedMs == 0 || frameCount == 0) {
            return 0.0f;
        }
        double elapsedSeconds = MAX(0.001, (double)measurementElapsedMs / 1000.0);
        return (float)((double)frameCount / elapsedSeconds);
    };
    float receivedFps = displayedFps(stats.receivedFps, stats.receivedFrames);
    float decodedFps = displayedFps(stats.decodedFps, stats.decodedFrames);
    float renderedFps = displayedFps(stats.renderedFps, stats.renderedFrames);
    
    uint32_t rtt = 0;
    BOOL rttAvailable = NO;
    BOOL usingPathProbeLatency = NO;
    NSInteger pathProbeMs = -1;
    PML_CONTROL_STREAM_CONTEXT controlCtx = self.streamMan.connection ? (PML_CONTROL_STREAM_CONTEXT)[self.streamMan.connection controlStreamContext] : NULL;
    rttAvailable = MLGetUsableRttInfo(controlCtx, &rtt, NULL);
    if (!rttAvailable) {
        NSString *preferredAddr = [self currentPreferredAddressForStatus];
        NSNumber *latency = preferredAddr ? self.app.host.addressLatencies[preferredAddr] : nil;
        if (latency != nil && latency.integerValue >= 0) {
            pathProbeMs = MAX(1, latency.integerValue);
            usingPathProbeLatency = YES;
        }
    }
    
    float loss = stats.totalFrames > 0 ? (float)stats.networkDroppedFrames / stats.totalFrames * 100.0f : 0;
    float jitter = stats.jitterMs;
    float onePercentLowFps = stats.renderedFpsOnePercentLow;

    // Approximate current video bitrate over the last measurement window (≈1s)
    double bitrateMbps = (double)stats.receivedBytes * 8.0 / 1000.0 / 1000.0;
    
    float renderTime = stats.renderedFrames > 0 ? (float)stats.totalRenderTime / stats.renderedFrames : 0;
    float decodeTime = stats.decodedFrames > 0 ? (float)stats.totalDecodeTime / stats.decodedFrames : 0;
    float encodeTime = stats.framesWithHostProcessingLatency > 0 ? (float)stats.totalHostProcessingLatency / 10.0f / stats.framesWithHostProcessingLatency : 0;
    float pipelineTime = encodeTime + decodeTime + renderTime;
    BOOL hasTransportEstimate = NO;
    BOOL streamLatencyApproximate = NO;
    float transportOneWayMs = 0.0f;
    if (rttAvailable) {
        transportOneWayMs = MAX(0.5f, (float)rtt / 2.0f);
        hasTransportEstimate = YES;
    } else if (usingPathProbeLatency) {
        transportOneWayMs = MAX(0.5f, (float)pathProbeMs / 2.0f);
        hasTransportEstimate = YES;
        streamLatencyApproximate = YES;
    }
    float streamLatencyMs = pipelineTime + transportOneWayMs;
    BOOL streamLatencyAvailable = (pipelineTime > 0.0f) || hasTransportEstimate;
    
    NSMutableAttributedString *attrString = [[NSMutableAttributedString alloc] init];
    
    NSDictionary *labelAttrs = @{
        NSForegroundColorAttributeName: [NSColor whiteColor],
        NSFontAttributeName: [NSFont systemFontOfSize:13 weight:NSFontWeightRegular]
    };
    
    NSDictionary *valueAttrs = @{
        NSForegroundColorAttributeName: [NSColor colorWithRed:1.0 green:1.0 blue:0.5 alpha:1.0], // Light Yellow
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightBold]
    };
    void (^append)(NSString *, NSDictionary *) = ^(NSString *str, NSDictionary *attrs) {
        [attrString appendAttributedString:[[NSAttributedString alloc] initWithString:str attributes:attrs]];
    };
    
    // Resolution & FPS (use configured FPS for the left-side value)
    append([NSString stringWithFormat:@"%dx%d@%d", res.width, res.height, configuredFps], valueAttrs);
    append(@"  ", labelAttrs);
    append(codecString, valueAttrs);
    append(@"  ", labelAttrs);
    append(chromaString, valueAttrs);
    append(@"  FPS ", labelAttrs);
    append([NSString stringWithFormat:@"%.1f", receivedFps], valueAttrs);
    append(@" Rx · ", labelAttrs);
    append([NSString stringWithFormat:@"%.1f", decodedFps], valueAttrs);
    append(@" De · ", labelAttrs);
    append([NSString stringWithFormat:@"%.1f", renderedFps], valueAttrs);
    append(@" Rd", labelAttrs);
    append(@"  ", labelAttrs);
    append(MLString(@"1% Low", nil), labelAttrs);
    append(@" ", labelAttrs);
    if (onePercentLowFps > 0.0f) {
        append([NSString stringWithFormat:@"%.1f", onePercentLowFps], valueAttrs);
    } else {
        append(@"--", valueAttrs);
    }
    
    // Network
    append(@"  ", labelAttrs);
    append(MLString(@"Stream Latency", nil), labelAttrs);
    append(@" ", labelAttrs);
    if (streamLatencyAvailable) {
        if (streamLatencyApproximate) {
            append(@"~", labelAttrs);
        }
        append([NSString stringWithFormat:@"%.1f", streamLatencyMs], valueAttrs);
        append(@" ms", labelAttrs);
    } else {
        append(MLString(@"Not Available", nil), valueAttrs);
    }
    append(@"  Loss ", labelAttrs);
    append([NSString stringWithFormat:@"%.2f%%", loss], valueAttrs);

    append(@"  Jit ", labelAttrs);
    append([NSString stringWithFormat:@"%.1f", jitter], valueAttrs);
    append(@" ms  Br ", labelAttrs);
    append([NSString stringWithFormat:@"%.1f", bitrateMbps], valueAttrs);
    append(@" Mbps", labelAttrs);
    
    // Latency
    append(@"  |  ", labelAttrs);
    append(MLString(@"Pipeline", nil), labelAttrs);
    append(@" ", labelAttrs);
    append([NSString stringWithFormat:@"%.2f", pipelineTime], valueAttrs);
    append(@" ms · ", labelAttrs);
    append(MLString(@"Host", nil), labelAttrs);
    append(@" ", labelAttrs);
    append([NSString stringWithFormat:@"%.1f", encodeTime], valueAttrs);
    append(@" ms · Decode ", labelAttrs);
    append([NSString stringWithFormat:@"%.2f", decodeTime], valueAttrs);
    append(@" ms · Queue ", labelAttrs);
    append([NSString stringWithFormat:@"%.2f", renderTime], valueAttrs);
    append(@" ms", labelAttrs);

    if (self.streamHealthNoPayloadStreak > 0) {
        append(@"  |  Stall ", labelAttrs);
        append([NSString stringWithFormat:@"%lus", (unsigned long)self.streamHealthNoPayloadStreak], valueAttrs);
    } else if (self.streamHealthFrozenStatsStreak > 0) {
        append(@"  |  Stale ", labelAttrs);
        append([NSString stringWithFormat:@"%lus", (unsigned long)self.streamHealthFrozenStatsStreak], valueAttrs);
    }

    self.overlayLabel.attributedStringValue = attrString;
    [self.overlayLabel sizeToFit];
    
    // Layout
    CGFloat padding = 10.0;
    NSRect labelFrame = self.overlayLabel.frame;
    NSRect containerFrame = NSMakeRect(0, 0, labelFrame.size.width + padding * 2, labelFrame.size.height + padding * 2);
    
    // Center top
    CGFloat x = (self.view.bounds.size.width - containerFrame.size.width) / 2;
    CGFloat y = self.view.bounds.size.height - containerFrame.size.height - 20; // 20px from top
    
    containerFrame.origin = NSMakePoint(x, y);
    self.overlayContainer.frame = containerFrame;
    
    self.overlayLabel.frame = NSMakeRect(padding, padding, labelFrame.size.width, labelFrame.size.height);
}


#pragma mark - Resolution

- (void)showConnectionWarning {
    if (self.connectionWarningContainer) {
        return;
    }

    self.connectionWarningContainer = [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
    self.connectionWarningContainer.material = NSVisualEffectMaterialHUDWindow;
    self.connectionWarningContainer.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    self.connectionWarningContainer.state = NSVisualEffectStateActive;
    self.connectionWarningContainer.wantsLayer = YES;
    self.connectionWarningContainer.layer.cornerRadius = 10.0;
    self.connectionWarningContainer.layer.masksToBounds = YES;

    self.connectionWarningLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.connectionWarningLabel.bezeled = NO;
    self.connectionWarningLabel.drawsBackground = NO;
    self.connectionWarningLabel.editable = NO;
    self.connectionWarningLabel.selectable = NO;
    self.connectionWarningLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    self.connectionWarningLabel.textColor = [NSColor whiteColor];
    
    // Use a warning symbol if possible, or just text
    NSString *warningText = MLString(@"Poor Connection", @"Connection warning overlay");
    self.connectionWarningLabel.stringValue = warningText;
    [self.connectionWarningLabel sizeToFit];

    [self.connectionWarningContainer addSubview:self.connectionWarningLabel];
    [self.view addSubview:self.connectionWarningContainer positioned:NSWindowAbove relativeTo:nil];

    [self layoutConnectionWarning];
    
    // Fade in animation
    self.connectionWarningContainer.alphaValue = 0.0;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.5;
        self.connectionWarningContainer.animator.alphaValue = 1.0;
    } completionHandler:nil];
}

- (void)viewDidLayout {
    [super viewDidLayout];
    [self layoutConnectionWarning];
    [self layoutMouseModeIndicator];
    [self layoutStreamMenuEntrypointsIfNeeded];

    if (self.logOverlayContainer) {
        CGFloat padding = 16.0;
        CGFloat width = MIN(940.0, self.view.bounds.size.width - padding * 2);
        CGFloat height = MIN(560.0, self.view.bounds.size.height - padding * 2);
        self.logOverlayContainer.frame = NSMakeRect((self.view.bounds.size.width - width) / 2.0,
                                                   (self.view.bounds.size.height - height) / 2.0,
                                                   width,
                                                   height);

        NSButton *closeBtn = [self.logOverlayContainer viewWithTag:999];
        NSButton *pauseBtn = [self.logOverlayContainer viewWithTag:1001];
        NSButton *autoScrollBtn = [self.logOverlayContainer viewWithTag:1002];
        NSButton *jumpBtn = [self.logOverlayContainer viewWithTag:1003];
        NSButton *copyBtn = [self.logOverlayContainer viewWithTag:1004];
        NSButton *clearBtn = [self.logOverlayContainer viewWithTag:1006];
        NSSearchField *searchField = [self.logOverlayContainer viewWithTag:1007];
        NSPopUpButton *categoryPopup = [self.logOverlayContainer viewWithTag:1008];
        NSPopUpButton *modePopup = [self.logOverlayContainer viewWithTag:1009];
        NSPopUpButton *levelPopup = [self.logOverlayContainer viewWithTag:1010];
        NSTextField *statusLabel = [self.logOverlayContainer viewWithTag:1005];

        CGFloat topY = height - 38.0;
        CGFloat filterY = height - 70.0;
        CGFloat statusY = height - 96.0;
        CGFloat x = 12.0;
        if (pauseBtn && pauseBtn.superview == self.logOverlayContainer) {
            [pauseBtn sizeToFit];
            CGFloat btnW = MAX(74.0, pauseBtn.frame.size.width + 16.0);
            pauseBtn.frame = NSMakeRect(x, topY, btnW, 24.0);
            x += btnW + 8.0;
        }
        if (autoScrollBtn && autoScrollBtn.superview == self.logOverlayContainer) {
            [autoScrollBtn sizeToFit];
            CGFloat btnW = MAX(74.0, autoScrollBtn.frame.size.width + 16.0);
            autoScrollBtn.frame = NSMakeRect(x, topY, btnW, 24.0);
            x += btnW + 8.0;
        }
        if (jumpBtn && jumpBtn.superview == self.logOverlayContainer) {
            [jumpBtn sizeToFit];
            CGFloat btnW = MAX(74.0, jumpBtn.frame.size.width + 16.0);
            jumpBtn.frame = NSMakeRect(x, topY, btnW, 24.0);
            x += btnW + 8.0;
        }
        if (copyBtn && copyBtn.superview == self.logOverlayContainer) {
            [copyBtn sizeToFit];
            CGFloat btnW = MAX(74.0, copyBtn.frame.size.width + 16.0);
            copyBtn.frame = NSMakeRect(x, topY, btnW, 24.0);
            x += btnW + 8.0;
        }
        if (clearBtn && clearBtn.superview == self.logOverlayContainer) {
            [clearBtn sizeToFit];
            CGFloat btnW = MAX(74.0, clearBtn.frame.size.width + 16.0);
            clearBtn.frame = NSMakeRect(x, topY, btnW, 24.0);
            x += btnW + 8.0;
        }

        CGFloat closeW = 64.0;
        if (closeBtn && closeBtn.superview == self.logOverlayContainer) {
            [closeBtn sizeToFit];
            closeW = MAX(60.0, closeBtn.frame.size.width + 16.0);
            closeBtn.frame = NSMakeRect(width - closeW - 12.0, topY, closeW, 24.0);
        }

        if (statusLabel && statusLabel.superview == self.logOverlayContainer) {
            CGFloat statusX = 12.0;
            CGFloat statusW = MAX(120.0, width - statusX - 24.0);
            statusLabel.frame = NSMakeRect(statusX, statusY, statusW, 16.0);
        }

        CGFloat filterX = 12.0;
        CGFloat filterGap = 8.0;
        CGFloat modeW = 118.0;
        CGFloat levelW = 98.0;
        CGFloat categoryW = MIN(220.0, MAX(150.0, width * 0.24));

        if (modePopup && modePopup.superview == self.logOverlayContainer) {
            modePopup.frame = NSMakeRect(filterX, filterY, modeW, 26.0);
            filterX += modeW + filterGap;
        }
        if (levelPopup && levelPopup.superview == self.logOverlayContainer) {
            levelPopup.frame = NSMakeRect(filterX, filterY, levelW, 26.0);
            filterX += levelW + filterGap;
        }
        if (categoryPopup && categoryPopup.superview == self.logOverlayContainer) {
            categoryPopup.frame = NSMakeRect(filterX, filterY, categoryW, 26.0);
            filterX += categoryW + filterGap;
        }
        if (searchField && searchField.superview == self.logOverlayContainer) {
            CGFloat searchW = MAX(160.0, width - filterX - 12.0);
            searchField.frame = NSMakeRect(filterX, filterY, searchW, 26.0);
        }

        CGFloat topMargin = 122.0;
        self.logOverlayScrollView.frame = NSMakeRect(12.0, 12.0, width - 24.0, height - 12.0 - topMargin);
        [self.logOverlayTextView setFrameSize:NSMakeSize(self.logOverlayScrollView.contentSize.width, self.logOverlayTextView.frame.size.height)];
    }

    if (self.reconnectOverlayContainer) {
        self.reconnectOverlayContainer.frame = self.view.bounds;

        CGFloat centerX = NSMidX(self.view.bounds);
        CGFloat centerY = NSMidY(self.view.bounds);
        self.reconnectSpinner.frame = NSMakeRect(centerX - 10, centerY + 6, 20, 20);
        [self.reconnectLabel sizeToFit];
        self.reconnectLabel.frame = NSMakeRect(centerX - self.reconnectLabel.frame.size.width / 2.0,
                                               centerY - 24,
                                               self.reconnectLabel.frame.size.width,
                                               self.reconnectLabel.frame.size.height);
    }

    if (self.timeoutOverlayContainer) {
        NSRect bounds = self.view.bounds;
        CGFloat maxOverlayWidth = MAX(320.0, NSWidth(bounds) - 24.0);
        CGFloat width = MIN(620.0, MAX(360.0, NSWidth(bounds) - 64.0));
        width = MIN(width, maxOverlayWidth);

        CGFloat paddingTop = 30.0;
        CGFloat paddingBottom = 26.0;
        CGFloat paddingSide = 28.0;
        CGFloat iconHeight = 60.0;
        CGFloat titleHeight = 28.0;
        CGFloat messageWidth = width - paddingSide * 2.0;
        CGFloat messageHeight = MAX(44.0, MLMeasureMultilineTextHeight(self.timeoutLabel.stringValue, self.timeoutLabel.font, messageWidth));

        CGFloat largeBtnWidth = 148.0;
        CGFloat largeBtnHeight = 34.0;
        CGFloat primaryButtonsGap = 16.0;

        CGFloat settingBtnHeight = 30.0;
        CGFloat settingBtnGap = 10.0;
        CGFloat settingsSectionTopGap = 24.0;
        CGFloat settingsRowGap = 10.0;
        CGFloat maxSettingsRowWidth = width - paddingSide * 2.0;

        NSArray<NSButton *> *settingsButtons = @[
            self.timeoutResolutionButton,
            self.timeoutBitrateButton,
            self.timeoutDisplayModeButton,
            self.timeoutConnectionButton,
            self.timeoutRecommendedProfileButton,
        ];
        NSMutableArray<NSArray<NSButton *> *> *settingsRows = [NSMutableArray array];
        NSMutableArray<NSArray<NSNumber *> *> *settingsWidthRows = [NSMutableArray array];
        NSMutableArray<NSButton *> *currentSettingsRow = [NSMutableArray array];
        NSMutableArray<NSNumber *> *currentSettingsWidthRow = [NSMutableArray array];
        CGFloat currentSettingsRowWidth = 0.0;

        for (NSButton *button in settingsButtons) {
            if (button == nil || button.hidden) {
                continue;
            }

            CGFloat buttonWidth = MLOverlayButtonWidth(button, 100.0, 132.0);
            CGFloat proposedRowWidth = currentSettingsRow.count == 0 ? buttonWidth : currentSettingsRowWidth + settingBtnGap + buttonWidth;
            if (currentSettingsRow.count > 0 && proposedRowWidth > maxSettingsRowWidth) {
                [settingsRows addObject:[currentSettingsRow copy]];
                [settingsWidthRows addObject:[currentSettingsWidthRow copy]];
                [currentSettingsRow removeAllObjects];
                [currentSettingsWidthRow removeAllObjects];
                currentSettingsRowWidth = 0.0;
            }

            [currentSettingsRow addObject:button];
            [currentSettingsWidthRow addObject:@(buttonWidth)];
            currentSettingsRowWidth = currentSettingsRow.count == 1 ? buttonWidth : currentSettingsRowWidth + settingBtnGap + buttonWidth;
        }

        if (currentSettingsRow.count > 0) {
            [settingsRows addObject:[currentSettingsRow copy]];
            [settingsWidthRows addObject:[currentSettingsWidthRow copy]];
        }

        CGFloat settingsRowsHeight = settingsRows.count > 0
            ? settingsRows.count * settingBtnHeight + (settingsRows.count - 1) * settingsRowGap
            : 0.0;

        CGFloat logsBtnHeight = 28.0;
        CGFloat logsGap = 12.0;
        CGFloat viewLogsWidth = MLOverlayButtonWidth(self.timeoutViewLogsButton, 98.0, 128.0);
        CGFloat copyLogsWidth = MLOverlayButtonWidth(self.timeoutCopyLogsButton, 98.0, 128.0);
        CGFloat logsRowWidth = viewLogsWidth + logsGap + copyLogsWidth;

        CGFloat height = paddingTop + iconHeight + 12.0 + titleHeight + 14.0 + messageHeight +
                         24.0 + largeBtnHeight + 12.0 + largeBtnHeight +
                         (settingsRows.count > 0 ? settingsSectionTopGap + settingsRowsHeight : 0.0) +
                         18.0 + logsBtnHeight + paddingBottom;
        CGFloat maxOverlayHeight = MAX(360.0, NSHeight(bounds) - 24.0);
        height = MAX(460.0, height);
        height = MIN(height, maxOverlayHeight);

        self.timeoutOverlayContainer.frame = NSMakeRect((NSWidth(bounds) - width) / 2.0,
                                                       (NSHeight(bounds) - height) / 2.0,
                                                       width,
                                                       height);
        
        // 为 NSVisualEffectView 应用圆角遮罩
        CAShapeLayer *maskLayer = [CAShapeLayer layer];
        NSBezierPath *roundedPath = [NSBezierPath bezierPathWithRoundedRect:self.timeoutOverlayContainer.bounds 
                                                                    xRadius:24.0 
                                                                    yRadius:24.0];
        CGPathRef cgPath = [self CGPathFromNSBezierPath:roundedPath];
        maskLayer.path = cgPath;
        CGPathRelease(cgPath);
        self.timeoutOverlayContainer.layer.mask = maskLayer;

        CGFloat centerX = width / 2.0;
        CGFloat currentY = height - paddingTop;

        self.timeoutIconLabel.frame = NSMakeRect(0, currentY - iconHeight, width, iconHeight);
        currentY -= iconHeight + 12.0;
        self.timeoutTitleLabel.frame = NSMakeRect(paddingSide, currentY - titleHeight, width - paddingSide * 2.0, titleHeight);
        currentY -= titleHeight + 14.0;
        self.timeoutLabel.frame = NSMakeRect(paddingSide, currentY - messageHeight, width - paddingSide * 2.0, messageHeight);
        currentY -= messageHeight + 24.0;

        CGFloat mainBtnY = currentY - largeBtnHeight;
        
        // Primary Action: Reconnect and Wait
        if (self.timeoutWaitButton.hidden) {
            // Reconnect centered
            self.timeoutReconnectButton.frame = NSMakeRect(centerX - largeBtnWidth / 2.0, mainBtnY, largeBtnWidth, largeBtnHeight);
            self.timeoutWaitButton.frame = NSZeroRect;
        } else {
            // Reconnect | Wait
            self.timeoutReconnectButton.frame = NSMakeRect(centerX - largeBtnWidth - primaryButtonsGap / 2.0, mainBtnY, largeBtnWidth, largeBtnHeight);
            self.timeoutWaitButton.frame = NSMakeRect(centerX + primaryButtonsGap / 2.0, mainBtnY, largeBtnWidth, largeBtnHeight);
        }
        
        // Exit Action
        CGFloat exitBtnY = mainBtnY - largeBtnHeight - 12.0;
        self.timeoutExitButton.frame = NSMakeRect(centerX - largeBtnWidth / 2.0, exitBtnY, largeBtnWidth, largeBtnHeight);

        CGFloat nextSectionTop = exitBtnY - settingsSectionTopGap;
        for (NSUInteger rowIndex = 0; rowIndex < settingsRows.count; rowIndex++) {
            NSArray<NSButton *> *rowButtons = settingsRows[rowIndex];
            NSArray<NSNumber *> *rowWidths = settingsWidthRows[rowIndex];
            CGFloat rowWidth = 0.0;
            for (NSNumber *widthNumber in rowWidths) {
                rowWidth += widthNumber.doubleValue;
            }
            if (rowButtons.count > 1) {
                rowWidth += settingBtnGap * (rowButtons.count - 1);
            }

            CGFloat rowY = nextSectionTop - settingBtnHeight - rowIndex * (settingBtnHeight + settingsRowGap);
            CGFloat rowX = (width - rowWidth) / 2.0;
            CGFloat xCursor = rowX;
            for (NSUInteger buttonIndex = 0; buttonIndex < rowButtons.count; buttonIndex++) {
                NSButton *button = rowButtons[buttonIndex];
                CGFloat buttonWidth = rowWidths[buttonIndex].doubleValue;
                button.frame = NSMakeRect(xCursor, rowY, buttonWidth, settingBtnHeight);
                xCursor += buttonWidth + settingBtnGap;
            }
        }

        CGFloat logsY = (settingsRows.count > 0 ? nextSectionTop - settingsRowsHeight - 18.0 : exitBtnY - 18.0) - logsBtnHeight;
        CGFloat logsStartX = (width - logsRowWidth) / 2.0;
        self.timeoutViewLogsButton.frame = NSMakeRect(logsStartX, logsY, viewLogsWidth, logsBtnHeight);
        self.timeoutCopyLogsButton.frame = NSMakeRect(logsStartX + viewLogsWidth + logsGap, logsY, copyLogsWidth, logsBtnHeight);
    }

    [self bringStreamControlsToFront];
}

- (void)layoutConnectionWarning {
    if (!self.connectionWarningContainer) return;
    
    CGFloat padding = 10.0;
    NSRect labelFrame = self.connectionWarningLabel.frame;
    NSRect containerFrame = NSMakeRect(0, 0, labelFrame.size.width + padding * 2, labelFrame.size.height + padding * 2);

    // Position top right
    CGFloat x = self.view.bounds.size.width - containerFrame.size.width - 20;
    CGFloat y = self.view.bounds.size.height - containerFrame.size.height - 20;

    containerFrame.origin = NSMakePoint(x, y);
    self.connectionWarningContainer.frame = containerFrame;
    self.connectionWarningLabel.frame = NSMakeRect(padding, padding, labelFrame.size.width, labelFrame.size.height);
}

- (void)hideConnectionWarning {
    if (!self.connectionWarningContainer) {
        return;
    }
    
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.5;
        self.connectionWarningContainer.animator.alphaValue = 0.0;
    } completionHandler:^{
        [self.connectionWarningContainer removeFromSuperview];
        self.connectionWarningContainer = nil;
        self.connectionWarningLabel = nil;
    }];
}



#pragma mark - InputPresenceDelegate

- (void)gamepadPresenceChanged {
}

- (void)mousePresenceChanged {
}

- (void)mouseModeToggled:(BOOL)enabled {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *message = enabled ? @"🖱️ Mouse Mode On" : @"🎮 Mouse Mode Off";
        // Localize if possible, but icons help universally
        if (enabled) {
               message = [NSString stringWithFormat:@"🖱️ %@", MLString(@"Mouse Mode On", @"Notification")];
             [self showMouseModeIndicator];
        } else {
               message = [NSString stringWithFormat:@"🎮 %@", MLString(@"Mouse Mode Off", @"Notification")];
             [self hideMouseModeIndicator];
        }
        [self showNotification:message];
    });
}

- (void)showMouseModeIndicator {
    if (self.mouseModeContainer) {
        return;
    }

    self.mouseModeContainer = [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
    self.mouseModeContainer.material = NSVisualEffectMaterialHUDWindow;
    self.mouseModeContainer.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    self.mouseModeContainer.state = NSVisualEffectStateActive;
    self.mouseModeContainer.wantsLayer = YES;
    self.mouseModeContainer.layer.cornerRadius = 10.0;
    self.mouseModeContainer.layer.masksToBounds = YES;

    self.mouseModeLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.mouseModeLabel.bezeled = NO;
    self.mouseModeLabel.drawsBackground = NO;
    self.mouseModeLabel.editable = NO;
    self.mouseModeLabel.selectable = NO;
    self.mouseModeLabel.font = [NSFont systemFontOfSize:24 weight:NSFontWeightRegular]; // Larger font for icon
    self.mouseModeLabel.textColor = [NSColor whiteColor];
    self.mouseModeLabel.stringValue = @"🖱️";
    [self.mouseModeLabel sizeToFit];

    [self.mouseModeContainer addSubview:self.mouseModeLabel];
    [self.view addSubview:self.mouseModeContainer positioned:NSWindowAbove relativeTo:nil];

    [self layoutMouseModeIndicator];
    
    // Fade in animation
    self.mouseModeContainer.alphaValue = 0.0;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.5;
        self.mouseModeContainer.animator.alphaValue = 1.0;
    } completionHandler:nil];
}

- (void)layoutMouseModeIndicator {
    if (!self.mouseModeContainer) return;
    
    CGFloat padding = 10.0;
    NSRect labelFrame = self.mouseModeLabel.frame;
    NSRect containerFrame = NSMakeRect(0, 0, labelFrame.size.width + padding * 2, labelFrame.size.height + padding * 2);

    // Position bottom left to avoid traffic lights
    CGFloat x = 20;
    CGFloat y = 20;

    containerFrame.origin = NSMakePoint(x, y);
    self.mouseModeContainer.frame = containerFrame;
    self.mouseModeLabel.frame = NSMakeRect(padding, padding, labelFrame.size.width, labelFrame.size.height);
}

- (void)hideMouseModeIndicator {
    if (!self.mouseModeContainer) {
        return;
    }
    
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.5;
        self.mouseModeContainer.animator.alphaValue = 0.0;
    } completionHandler:^{
        [self.mouseModeContainer removeFromSuperview];
        self.mouseModeContainer = nil;
        self.mouseModeLabel = nil;
    }];
}

- (void)handleMouseModeToggledNotification:(NSNotification *)note {
    BOOL enabled = [note.userInfo[@"enabled"] boolValue];
    [self mouseModeToggled:enabled];
}

- (void)handleGamepadQuitNotification:(NSNotification *)note {
    [self requestStreamCloseWithSource:@"gamepad-quit-combo"];
}

- (void)showNotification:(NSString *)message {
    [self showNotification:message forSeconds:2.0];
}

- (void)showNotification:(NSString *)message forSeconds:(NSTimeInterval)seconds {
    [self.notificationTimer invalidate];
    if (self.notificationContainer) {
        [self.notificationContainer removeFromSuperview];
    }

    self.notificationContainer = [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
    self.notificationContainer.material = NSVisualEffectMaterialHUDWindow;
    self.notificationContainer.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    self.notificationContainer.state = NSVisualEffectStateActive;
    self.notificationContainer.wantsLayer = YES;
    self.notificationContainer.layer.cornerRadius = 10.0;
    self.notificationContainer.layer.masksToBounds = YES;

    self.notificationLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.notificationLabel.bezeled = NO;
    self.notificationLabel.drawsBackground = NO;
    self.notificationLabel.editable = NO;
    self.notificationLabel.selectable = NO;
    self.notificationLabel.font = [NSFont systemFontOfSize:16 weight:NSFontWeightBold];
    self.notificationLabel.textColor = [NSColor whiteColor];
    self.notificationLabel.stringValue = message;
    [self.notificationLabel sizeToFit];

    [self.notificationContainer addSubview:self.notificationLabel];
    [self.view addSubview:self.notificationContainer positioned:NSWindowAbove relativeTo:nil];

    CGFloat padding = 15.0;
    NSRect labelFrame = self.notificationLabel.frame;
    NSRect containerFrame = NSMakeRect(0, 0, labelFrame.size.width + padding * 2, labelFrame.size.height + padding * 2);

    // Center of screen
    CGFloat x = (self.view.bounds.size.width - containerFrame.size.width) / 2;
    CGFloat y = (self.view.bounds.size.height - containerFrame.size.height) / 2;

    containerFrame.origin = NSMakePoint(x, y);
    self.notificationContainer.frame = containerFrame;
    self.notificationLabel.frame = NSMakeRect(padding, padding, labelFrame.size.width, labelFrame.size.height);

    // Animation
    self.notificationContainer.alphaValue = 0.0;
    self.notificationContainer.layer.transform = CATransform3DMakeScale(0.8, 0.8, 1.0);
    
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.2;
        self.notificationContainer.animator.alphaValue = 1.0;
    } completionHandler:nil];

    CABasicAnimation *scaleAnim = [CABasicAnimation animationWithKeyPath:@"transform"];
    scaleAnim.fromValue = [NSValue valueWithCATransform3D:CATransform3DMakeScale(0.8, 0.8, 1.0)];
    scaleAnim.toValue = [NSValue valueWithCATransform3D:CATransform3DIdentity];
    scaleAnim.duration = 0.2;
    self.notificationContainer.layer.transform = CATransform3DIdentity;
    [self.notificationContainer.layer addAnimation:scaleAnim forKey:@"scale"];

    // Auto hide
    NSTimeInterval interval = seconds > 0 ? seconds : 2.0;
    self.notificationTimer = [NSTimer scheduledTimerWithTimeInterval:interval repeats:NO block:^(NSTimer * _Nonnull timer) {
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = 0.5;
            self.notificationContainer.animator.alphaValue = 0.0;
        } completionHandler:^{
            [self.notificationContainer removeFromSuperview];
            self.notificationContainer = nil;
        }];
    }];
}

// 辅助方法：将 NSBezierPath 转换为 CGPath
- (CGPathRef)CGPathFromNSBezierPath:(NSBezierPath *)bezierPath {
    CGMutablePathRef path = CGPathCreateMutable();
    NSInteger count = [bezierPath elementCount];
    
    for (NSInteger i = 0; i < count; i++) {
        NSPoint points[3];
        NSBezierPathElement element = [bezierPath elementAtIndex:i associatedPoints:points];
        
        switch (element) {
            case NSBezierPathElementMoveTo:
                CGPathMoveToPoint(path, NULL, points[0].x, points[0].y);
                break;
            case NSBezierPathElementLineTo:
                CGPathAddLineToPoint(path, NULL, points[0].x, points[0].y);
                break;
            case NSBezierPathElementCurveTo:
                CGPathAddCurveToPoint(path, NULL, points[0].x, points[0].y,
                                    points[1].x, points[1].y,
                                    points[2].x, points[2].y);
                break;
            case NSBezierPathElementQuadraticCurveTo:
                CGPathAddQuadCurveToPoint(path, NULL, points[0].x, points[0].y, points[1].x, points[1].y);
                break;
            case NSBezierPathElementClosePath:
                CGPathCloseSubpath(path);
                break;
        }
    }
    
    return path;
}

@end
