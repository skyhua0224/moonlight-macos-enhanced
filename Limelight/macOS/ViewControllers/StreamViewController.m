//
//  StreamViewController.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 25/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import "StreamViewController.h"
#import <QuartzCore/QuartzCore.h>
#import "StreamViewMac.h"
#import "AppsViewController.h"
#import "NSWindow+Moonlight.h"
#import "AlertPresenter.h"

#import "Connection.h"
#import "StreamConfiguration.h"
#import "DataManager.h"
#import "ControllerSupport.h"
#import "StreamManager.h"
#import "VideoDecoderRenderer.h"
#import "HIDSupport.h"

#import "Moonlight-Swift.h"

#import "LogBuffer.h"

#define MLString(key, comment) [[LanguageManager shared] localize:key]

#include "Limelight.h"

@import VideoToolbox;

#import <IOKit/pwr_mgt/IOPMLib.h>
#import <Carbon/Carbon.h>

typedef NS_ENUM(NSInteger, PendingWindowMode) {
    PendingWindowModeNone,
    PendingWindowModeWindowed,
    PendingWindowModeBorderless
};

@interface StreamViewController () <ConnectionCallbacks, KeyboardNotifiableDelegate, InputPresenceDelegate>

@property (nonatomic, strong) ControllerSupport *controllerSupport;
@property (nonatomic, strong) HIDSupport *hidSupport;
@property (nonatomic) BOOL useSystemControllerDriver;
@property (nonatomic, strong) StreamManager *streamMan;
@property (nonatomic, strong) NSOperationQueue *streamOpQueue;
@property (nonatomic, readonly) StreamViewMac *streamView;
@property (nonatomic, strong) id windowDidExitFullScreenNotification;
@property (nonatomic, strong) id windowDidEnterFullScreenNotification;
@property (nonatomic, strong) id windowDidResignKeyNotification;
@property (nonatomic, strong) id windowDidBecomeKeyNotification;
@property (nonatomic, strong) id windowWillCloseNotification;
@property (nonatomic) int cursorHiddenCounter;

@property (nonatomic) IOPMAssertionID powerAssertionID;

@property (nonatomic, strong) NSVisualEffectView *overlayContainer;
@property (nonatomic, strong) NSTextField *overlayLabel;
@property (nonatomic, strong) NSTimer *statsTimer;

@property (nonatomic, strong) NSVisualEffectView *connectionWarningContainer;
@property (nonatomic, strong) NSTextField *connectionWarningLabel;

@property (nonatomic, strong) NSVisualEffectView *notificationContainer;
@property (nonatomic, strong) NSTextField *notificationLabel;
@property (nonatomic, strong) NSTimer *notificationTimer;

@property (nonatomic, strong) NSVisualEffectView *mouseModeContainer;
@property (nonatomic, strong) NSTextField *mouseModeLabel;

@property (nonatomic) BOOL disconnectWasUserInitiated;
@property (nonatomic) uint64_t suppressConnectionWarningsUntilMs;
@property (nonatomic) BOOL isMouseCaptured;
@property (atomic) BOOL stopStreamInProgress;

@property (nonatomic) BOOL shouldAttemptReconnect;
@property (nonatomic) NSInteger reconnectAttemptCount;
@property (nonatomic) BOOL reconnectInProgress;

@property (nonatomic) BOOL reconnectPreserveFullscreenStateValid;
@property (nonatomic) NSInteger reconnectPreservedWindowMode;

@property (nonatomic, strong) NSTitlebarAccessoryViewController *menuTitlebarAccessory;
@property (nonatomic, strong) NSButton *menuTitlebarButton;
@property (nonatomic, strong) NSButton *edgeMenuButton;

@property (nonatomic, strong) NSMenu *streamMenu;

@property (nonatomic, strong) NSVisualEffectView *controlCenterPill;
@property (nonatomic, strong) NSImageView *controlCenterSignalImageView;
@property (nonatomic, strong) NSTextField *controlCenterTimeLabel;
@property (nonatomic, strong) NSTextField *controlCenterTitleLabel;
@property (nonatomic, strong) NSTimer *controlCenterTimer;
@property (nonatomic, strong) NSDate *streamStartDate;

@property (nonatomic) BOOL hideFullscreenControlBall;
@property (nonatomic, strong) NSSlider *menuVolumeSlider;
@property (nonatomic, strong) NSSlider *menuBitrateSlider;
@property (nonatomic, strong) NSTextField *menuBitrateValueLabel;

@property (nonatomic, strong) NSVisualEffectView *logOverlayContainer;
@property (nonatomic, strong) NSScrollView *logOverlayScrollView;
@property (nonatomic, strong) NSTextView *logOverlayTextView;
@property (nonatomic, strong) id logDidAppendObserver;

@property (nonatomic, strong) NSVisualEffectView *reconnectOverlayContainer;
@property (nonatomic, strong) NSProgressIndicator *reconnectSpinner;
@property (nonatomic, strong) NSTextField *reconnectLabel;

@property (nonatomic, strong) NSVisualEffectView *timeoutOverlayContainer;
@property (nonatomic, strong) NSTextField *timeoutIconLabel;
@property (nonatomic, strong) NSTextField *timeoutTitleLabel;
@property (nonatomic, strong) NSTextField *timeoutLabel;
@property (nonatomic, strong) NSButton *timeoutReconnectButton;
@property (nonatomic, strong) NSButton *timeoutWaitButton;
@property (nonatomic, strong) NSButton *timeoutExitButton;
@property (nonatomic, strong) NSButton *timeoutResolutionButton;
@property (nonatomic, strong) NSButton *timeoutBitrateButton;
@property (nonatomic, strong) NSButton *timeoutDisplayModeButton;
@property (nonatomic, strong) NSButton *timeoutConnectionButton;
@property (nonatomic, strong) NSButton *timeoutViewLogsButton;
@property (nonatomic, strong) NSButton *timeoutCopyLogsButton;

@property (nonatomic) NSInteger connectWatchdogToken;
@property (nonatomic) BOOL didAutoReconnectAfterTimeout;

@property (nonatomic, strong) id settingsDidChangeObserver;
@property (nonatomic, strong) id hostLatencyUpdatedObserver;

@property (nonatomic) PendingWindowMode pendingWindowMode;
- (void)applyBorderlessMode;
- (void)applyWindowedMode;

@property (nonatomic) BOOL menuTitlebarAccessoryInstalled;

@property (nonatomic, strong) id localKeyDownMonitor;

@property (nonatomic) BOOL savedPresentationOptionsValid;
@property (nonatomic) NSApplicationPresentationOptions savedPresentationOptions;

@property (nonatomic) BOOL savedContentAspectRatioValid;
@property (nonatomic) NSSize savedContentAspectRatio;

@end

@implementation StreamViewController

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

- (void)enterBorderlessPresentationOptionsIfNeeded {
    if (!self.savedPresentationOptionsValid) {
        self.savedPresentationOptions = [NSApp presentationOptions];
        self.savedPresentationOptionsValid = YES;
    }

    NSApplicationPresentationOptions opts = [NSApp presentationOptions];
    opts |= (NSApplicationPresentationHideDock | NSApplicationPresentationHideMenuBar);
    [NSApp setPresentationOptions:opts];
}

- (void)restorePresentationOptionsIfNeeded {
    if (!self.savedPresentationOptionsValid) {
        return;
    }
    [NSApp setPresentationOptions:self.savedPresentationOptions];
    self.savedPresentationOptionsValid = NO;
}

#pragma mark - Lifecycle

- (BOOL)useSystemControllerDriver {
    return [SettingsClass controllerDriverFor:self.app.host.uuid] == 1;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.cursorHiddenCounter = 0;
    self.isMouseCaptured = NO;
    self.disconnectWasUserInitiated = NO;
    self.suppressConnectionWarningsUntilMs = 0;
    self.stopStreamInProgress = NO;
    self.shouldAttemptReconnect = YES;
    self.reconnectAttemptCount = 0;
    self.reconnectInProgress = NO;
    self.connectWatchdogToken = 0;
    self.didAutoReconnectAfterTimeout = NO;
    self.streamOpQueue = [[NSOperationQueue alloc] init];

    self.hideFullscreenControlBall = [[NSUserDefaults standardUserDefaults] boolForKey:[self fullscreenControlBallDefaultsKey]];
    
    [self prepareForStreaming];

    __weak typeof(self) weakSelf = self;

    self.windowDidExitFullScreenNotification = [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidExitFullScreenNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        if ([weakSelf isOurWindowTheWindowInNotiifcation:note]) {
            if (weakSelf.pendingWindowMode == PendingWindowModeBorderless) {
                weakSelf.pendingWindowMode = PendingWindowModeNone;
                [weakSelf applyBorderlessMode];
            } else if (weakSelf.pendingWindowMode == PendingWindowModeWindowed) {
                weakSelf.pendingWindowMode = PendingWindowModeNone;
                [weakSelf applyWindowedMode];
            }

            [weakSelf updateStreamMenuEntrypointsVisibility];
            if ([weakSelf.view.window isKeyWindow]) {
                [weakSelf uncaptureMouse];
                [weakSelf captureMouse];
            }
        }
    }];

    self.windowDidEnterFullScreenNotification = [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidEnterFullScreenNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        if ([weakSelf isOurWindowTheWindowInNotiifcation:note]) {
            [weakSelf updateStreamMenuEntrypointsVisibility];
            if ([weakSelf isWindowInCurrentSpace]) {
                if ([weakSelf isWindowFullscreen]) {
                    if ([weakSelf.view.window isKeyWindow]) {
                        [weakSelf uncaptureMouse];
                        [weakSelf captureMouse];
                    }
                }
            }
        }
    }];
    
    self.windowDidResignKeyNotification = [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidResignKeyNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        if ([weakSelf isOurWindowTheWindowInNotiifcation:note]) {
            if (![weakSelf isWindowInCurrentSpace] || ![weakSelf isWindowFullscreen]) {
                [weakSelf uncaptureMouse];
            }
        }
    }];
    self.windowDidBecomeKeyNotification = [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidBecomeKeyNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        if ([weakSelf isOurWindowTheWindowInNotiifcation:note]) {
            if ([weakSelf isWindowInCurrentSpace]) {
                if ([weakSelf isWindowFullscreen]) {
                    if ([weakSelf.view.window isKeyWindow]) {
                        [weakSelf uncaptureMouse];
                        [weakSelf captureMouse];
                    }
                }
            }
        } else {
            [weakSelf uncaptureMouse];
        }
    }];
    
    self.windowWillCloseNotification = [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowWillCloseNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        if ([weakSelf isOurWindowTheWindowInNotiifcation:note]) {
            [weakSelf beginStopStreamIfNeededWithReason:@"window-will-close"]; 
        }
    }];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleMouseModeToggledNotification:) name:HIDMouseModeToggledNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleGamepadQuitNotification:) name:HIDGamepadQuitNotification object:nil];

    [self installStreamMenuEntrypoints];
}

- (BOOL)hasReceivedAnyVideoFrames {
    @try {
        if (!self.streamMan) {
            return NO;
        }
        return self.streamMan.connection.renderer.videoStats.receivedFrames > 0;
    } @catch (NSException *ex) {
        return NO;
    }
}

- (void)startConnectWatchdog {
    self.connectWatchdogToken += 1;
    NSInteger token = self.connectWatchdogToken;

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
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
        
        // If we are stuck in reconnecting state for > 10s, force error overlay
        if (strongSelf.reconnectInProgress) {
            [strongSelf hideReconnectOverlay];
            strongSelf.reconnectInProgress = NO;
            [strongSelf showErrorOverlayWithTitle:@"重连超时"
                                          message:@"重连过程耗时过长，连接可能已断开。\n请检查网络环境或调整设置。"
                                          canWait:NO];
            return;
        }

        // 10s with no frames: attempt a single auto-reconnect (once per stream VC lifetime), then show timeout UI.
        if (!strongSelf.didAutoReconnectAfterTimeout && strongSelf.shouldAttemptReconnect) {
            strongSelf.didAutoReconnectAfterTimeout = YES;
            [strongSelf showReconnectOverlayWithMessage:@"网络无响应，正在尝试重连…"]; 
            [strongSelf attemptReconnectWithReason:@"connect-timeout-auto"]; 
            return;
        }

        [strongSelf showErrorOverlayWithTitle:@"连接不稳定或无画面"
                                      message:@"已持续 10 秒未接收到视频数据。\n请检查网络连接或尝试以下操作。"
                                      canWait:YES];
    });
}

- (void)showErrorOverlayWithTitle:(NSString *)title message:(NSString *)message canWait:(BOOL)canWait {
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
    [self hideConnectionTimeoutOverlay];
    [self attemptReconnectWithReason:@"timeout-overlay-manual"];
}

- (void)handleTimeoutWait:(id)sender {
    [self hideConnectionTimeoutOverlay];
}

- (void)handleTimeoutExitStream:(id)sender {
    [self performCloseStreamWindow:sender];
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

- (void)handleTimeoutViewLogs:(id)sender {
    [self toggleLogOverlay];
}

- (void)beginStopStreamIfNeededWithReason:(NSString *)reason {
    @synchronized (self) {
        if (self.stopStreamInProgress) {
            return;
        }
        self.stopStreamInProgress = YES;
    }

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
    });
}

- (void)viewDidAppear {
    [super viewDidAppear];
    
    self.streamView.keyboardNotifiable = self;
    self.streamView.appName = self.app.name;
    self.streamView.statusText = @"Starting";
    self.view.window.tabbingMode = NSWindowTabbingModeDisallowed;
    [self.view.window makeFirstResponder:self];

    [self installLocalKeyMonitorIfNeeded];
    
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
    
    [self.view.window moonlight_centerWindowOnFirstRunWithSize:CGSizeMake(initialW, initialH)];
    
    self.view.window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameVibrantDark];

    [self updateWindowSubtitle];

    [self updateStreamMenuEntrypointsVisibility];

    if (!self.streamStartDate) {
        self.streamStartDate = [NSDate date];
    }
    [self startControlCenterTimerIfNeeded];

    __weak typeof(self) weakSelf = self;
    self.settingsDidChangeObserver = [[NSNotificationCenter defaultCenter] addObserverForName:NSUserDefaultsDidChangeNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        [weakSelf updateWindowSubtitle];
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
            return [NSString stringWithFormat:@"%@ (%dms)", addr, latency.intValue];
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
    [[NSNotificationCenter defaultCenter] removeObserver:self.windowDidExitFullScreenNotification];
    [[NSNotificationCenter defaultCenter] removeObserver:self.windowDidEnterFullScreenNotification];
    [[NSNotificationCenter defaultCenter] removeObserver:self.windowDidResignKeyNotification];
    [[NSNotificationCenter defaultCenter] removeObserver:self.windowDidBecomeKeyNotification];
    [[NSNotificationCenter defaultCenter] removeObserver:self.windowWillCloseNotification];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:HIDMouseModeToggledNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:HIDGamepadQuitNotification object:nil];

    if (self.settingsDidChangeObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:self.settingsDidChangeObserver];
        self.settingsDidChangeObserver = nil;
    }
    if (self.hostLatencyUpdatedObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:self.hostLatencyUpdatedObserver];
        self.hostLatencyUpdatedObserver = nil;
    }

    if (self.logDidAppendObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:self.logDidAppendObserver];
        self.logDidAppendObserver = nil;
    }

    if (self.controlCenterTimer) {
        [self.controlCenterTimer invalidate];
        self.controlCenterTimer = nil;
    }

    if (self.localKeyDownMonitor) {
        [NSEvent removeMonitor:self.localKeyDownMonitor];
        self.localKeyDownMonitor = nil;
    }

    [self.hidSupport tearDownHidManager];
    self.hidSupport = nil;
}

- (BOOL)isWindowBorderlessMode {
    if (!self.view.window) {
        return NO;
    }
    BOOL isFullscreen = [self isWindowFullscreen];
    return ((self.view.window.styleMask & NSWindowStyleMaskTitled) == 0) && !isFullscreen;
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

        const NSEventModifierFlags allowed = (NSEventModifierFlagShift | NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagCommand | NSEventModifierFlagFunction);
        const NSEventModifierFlags mods = event.modifierFlags & allowed;

        // Escape hatch: Ctrl+Alt+Cmd+B toggles borderless <-> windowed.
        if (event.keyCode == kVK_ANSI_B && mods == (NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagCommand)) {
            if ([strongSelf isWindowBorderlessMode]) {
                [strongSelf switchToWindowedMode:nil];
            } else {
                [strongSelf switchToBorderlessMode:nil];
            }
            return nil;
        }

        // In borderless mode, Esc opens the local stream menu.
        if (event.keyCode == kVK_Escape && [strongSelf isWindowBorderlessMode]) {
            [strongSelf presentStreamMenuFromView:strongSelf.view];
            return nil;
        }

        return event;
    }];
}

- (void)flagsChanged:(NSEvent *)event {
    [self.hidSupport flagsChanged:event];
    
    // Uncapture mouse when Option key is pressed
    if ((event.keyCode == kVK_Option || event.keyCode == kVK_RightOption) &&
        (event.modifierFlags & NSEventModifierFlagOption)) {
        [self.hidSupport releaseAllModifierKeys];
        // User is intentionally detaching local input/cursor; suppress transient connection warnings.
        [self suppressConnectionWarningsForSeconds:2.0 reason:@"option-uncapture"]; 
        [self uncaptureMouse];
    }
}

- (void)keyDown:(NSEvent *)event {
    [self.hidSupport keyDown:event];
}

- (void)keyUp:(NSEvent *)event {
    [self.hidSupport keyUp:event];
}


- (void)mouseDown:(NSEvent *)event {
    [self.hidSupport mouseDown:event withButton:BUTTON_LEFT];
    [self captureMouse];
}

- (void)mouseUp:(NSEvent *)event {
    [self.hidSupport mouseUp:event withButton:BUTTON_LEFT];
}

- (void)rightMouseDown:(NSEvent *)event {
    // When mouse isn't captured (or user holds Control), treat right-click as local control center.
    // Otherwise forward to the remote host.
    BOOL forceLocalMenu = (event.modifierFlags & NSEventModifierFlagControl) != 0;
    if (!self.isMouseCaptured || forceLocalMenu) {
        [self presentStreamMenuAtEvent:event];
        return;
    }

    [self.hidSupport mouseDown:event withButton:BUTTON_RIGHT];
}

- (void)rightMouseUp:(NSEvent *)event {
    [self.hidSupport mouseUp:event withButton:BUTTON_RIGHT];
}

- (void)otherMouseDown:(NSEvent *)event {
    int button = [self getMouseButtonFromEvent:event];
    if (button == 0) {
        return;
    }
    [self.hidSupport mouseDown:event withButton:button];
}

- (void)otherMouseUp:(NSEvent *)event {
    int button = [self getMouseButtonFromEvent:event];
    if (button == 0) {
        return;
    }
    [self.hidSupport mouseUp:event withButton:button];
}

- (void)mouseMoved:(NSEvent *)event {
    [self.hidSupport mouseMoved:event];
}

- (void)mouseDragged:(NSEvent *)event {
    [self.hidSupport mouseMoved:event];
}

- (void)rightMouseDragged:(NSEvent *)event {
    [self.hidSupport mouseMoved:event];
}

- (void)otherMouseDragged:(NSEvent *)event {
    [self.hidSupport mouseMoved:event];
}

- (void)scrollWheel:(NSEvent *)event {
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
    const NSEventModifierFlags modifierFlags = NSEventModifierFlagShift | NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagCommand | NSEventModifierFlagFunction;
    const NSEventModifierFlags eventModifierFlags = event.modifierFlags & modifierFlags;
    
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
        || (event.keyCode == kVK_ANSI_W && eventModifierFlags == (NSEventModifierFlagOption | NSEventModifierFlagControl))
        || (event.keyCode == kVK_ANSI_W && eventModifierFlags == (NSEventModifierFlagShift | NSEventModifierFlagControl))
        || (event.keyCode == kVK_ANSI_W && eventModifierFlags == NSEventModifierFlagCommand)
        ) {
        [self.hidSupport releaseAllModifierKeys];
        return NO;
    }
    
    if (event.keyCode == kVK_ANSI_S && eventModifierFlags == (NSEventModifierFlagControl | NSEventModifierFlagOption)) {
        [self toggleOverlay];
        return YES;
    }

    // Ctrl+Alt+G: toggle fullscreen floating control ball
    if (event.keyCode == kVK_ANSI_G && eventModifierFlags == (NSEventModifierFlagControl | NSEventModifierFlagOption)) {
        [self toggleFullscreenControlBallVisibility];
        return YES;
    }
    
    [self.hidSupport keyDown:event];
    [self.hidSupport keyUp:event];
    
    return YES;
}


#pragma mark - Actions


- (IBAction)performClose:(id)sender {
    [self uncaptureMouse];
    
    NSAlert *alert = [[NSAlert alloc] init];
    
    alert.alertStyle = NSAlertStyleInformational;
    alert.messageText = MLString(@"Disconnect Alert", @"Disconnect Alert");

    [alert addButtonWithTitle:MLString(@"Disconnect from Stream", @"Disconnect from Stream")];
    [alert addButtonWithTitle:MLString(@"Close and Quit App", @"Close and Quit App")];
    [alert addButtonWithTitle:MLString(@"Cancel", @"Cancel")];

    [alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse returnCode) {
        switch (returnCode) {
            case NSAlertFirstButtonReturn:
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
    [self beginStopStreamIfNeededWithReason:@"disconnect-from-stream"]; 

    // In borderless/floating mode, relying on the responder chain can fail to close the window,
    // leaving the last frame stuck. Restore a normal window style and close explicitly.
    dispatch_async(dispatch_get_main_queue(), ^{
        NSWindow *w = self.view.window;
        if (!w) {
            return;
        }

        Log(LOG_I, @"performCloseStreamWindow: closing window (style=%llu level=%ld)", (unsigned long long)w.styleMask, (long)w.level);

        [self restorePresentationOptionsIfNeeded];

        if ((w.styleMask & NSWindowStyleMaskTitled) == 0) {
            NSWindowStyleMask mask = w.styleMask;
            mask &= ~NSWindowStyleMaskBorderless;
            mask |= (NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable);
            @try {
                [w setStyleMask:mask];
                [w setLevel:NSNormalWindowLevel];
            } @catch (NSException *exception) {
                // ignore
            }
        }

        [w performClose:nil];
    });
}

- (IBAction)performCloseAndQuitApp:(id)sender {
    [self markUserInitiatedDisconnectAndSuppressWarningsForSeconds:2.0 reason:@"close-and-quit"]; 
    [self.delegate quitApp:self.app completion:nil];
}

- (IBAction)resizeWindowToActualResulution:(id)sender {
    CGFloat screenScale = [NSScreen mainScreen].backingScaleFactor;
    CGFloat width = (CGFloat)[self.class getResolution].width / screenScale;
    CGFloat height = (CGFloat)[self.class getResolution].height / screenScale;
    [self.view.window setContentSize:NSMakeSize(width, height)];
}


#pragma mark - Helpers

- (void)enableMenuItems:(BOOL)enable {
    NSMenu *appMenu = [[NSApplication sharedApplication].mainMenu itemWithTag:1000].submenu;
    appMenu.autoenablesItems = enable;
    [self itemWithMenu:appMenu andAction:@selector(terminate:)].enabled = enable;
}

#pragma mark - Stream Menu Entrypoints

- (NSString *)fullscreenControlBallDefaultsKey {
    NSString *uuid = self.app.host.uuid ?: @"global";
    return [NSString stringWithFormat:@"%@-hideFullscreenControlBall", uuid];
}

- (void)startControlCenterTimerIfNeeded {
    if (self.controlCenterTimer) {
        return;
    }
    self.controlCenterTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(updateControlCenterStatus) userInfo:nil repeats:YES];
    [self updateControlCenterStatus];
}

- (void)bringStreamControlsToFront {
    if (self.edgeMenuButton) {
        [self.view addSubview:self.edgeMenuButton positioned:NSWindowAbove relativeTo:nil];
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
    return self.app.host.activeAddress;
}

- (NSInteger)currentLatencyMs {
    // If we are actively streaming, use the real-time RTT.
    if ([self hasReceivedAnyVideoFrames]) {
        uint32_t rtt = 0;
        uint32_t rttVar = 0;
        if (LiGetEstimatedRttInfo(&rtt, &rttVar) == 0) {
            return (NSInteger)rtt;
        }
    }

    NSString *addr = [self currentPreferredAddressForStatus];
    NSNumber *latency = addr ? self.app.host.addressLatencies[addr] : nil;
    if (!latency) {
        return -1;
    }
    return latency.integerValue;
}

- (void)updateControlCenterStatus {
    if (!self.controlCenterTimeLabel || !self.controlCenterSignalImageView) {
        return;
    }

    NSTimeInterval elapsed = self.streamStartDate ? [[NSDate date] timeIntervalSinceDate:self.streamStartDate] : 0;
    self.controlCenterTimeLabel.stringValue = [self formatElapsed:elapsed];

    NSInteger latency = [self currentLatencyMs];
    NSString *symbol = @"wifi";
    if (latency < 0) {
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
}

- (void)installStreamMenuEntrypoints {
    // Titlebar control center pill (windowed mode)
    CGFloat pillWidth = 240;
    CGFloat pillHeight = 28;
    NSView *titlebarContainer = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, pillWidth, pillHeight)];

    self.controlCenterPill = [[NSVisualEffectView alloc] initWithFrame:titlebarContainer.bounds];
    self.controlCenterPill.material = NSVisualEffectMaterialHUDWindow;
    self.controlCenterPill.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    self.controlCenterPill.state = NSVisualEffectStateActive;
    self.controlCenterPill.wantsLayer = YES;
    self.controlCenterPill.layer.cornerRadius = pillHeight / 2.0;
    self.controlCenterPill.layer.masksToBounds = YES;
    [titlebarContainer addSubview:self.controlCenterPill];

    NSView *content = [[NSView alloc] initWithFrame:self.controlCenterPill.bounds];
    content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self.controlCenterPill addSubview:content];

    self.controlCenterSignalImageView = [[NSImageView alloc] initWithFrame:NSMakeRect(10, 6, 16, 16)];
    self.controlCenterSignalImageView.contentTintColor = [NSColor whiteColor];
    [content addSubview:self.controlCenterSignalImageView];

    self.controlCenterTimeLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(32, 6, 70, 16)];
    self.controlCenterTimeLabel.bezeled = NO;
    self.controlCenterTimeLabel.drawsBackground = NO;
    self.controlCenterTimeLabel.editable = NO;
    self.controlCenterTimeLabel.selectable = NO;
    self.controlCenterTimeLabel.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightRegular];
    self.controlCenterTimeLabel.textColor = [NSColor whiteColor];
    self.controlCenterTimeLabel.stringValue = @"00:00";
    [content addSubview:self.controlCenterTimeLabel];

    self.controlCenterTitleLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(pillWidth - 88, 6, 78, 16)];
    self.controlCenterTitleLabel.bezeled = NO;
    self.controlCenterTitleLabel.drawsBackground = NO;
    self.controlCenterTitleLabel.editable = NO;
    self.controlCenterTitleLabel.selectable = NO;
    self.controlCenterTitleLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    self.controlCenterTitleLabel.textColor = [NSColor whiteColor];
    self.controlCenterTitleLabel.alignment = NSTextAlignmentRight;
    self.controlCenterTitleLabel.stringValue = @"控制中心";
    [content addSubview:self.controlCenterTitleLabel];

    self.menuTitlebarButton = [NSButton buttonWithTitle:@"" target:self action:@selector(handleStreamMenuButtonPressed:)];
    self.menuTitlebarButton.bordered = NO;
    self.menuTitlebarButton.frame = titlebarContainer.bounds;
    self.menuTitlebarButton.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [titlebarContainer addSubview:self.menuTitlebarButton];

    self.menuTitlebarAccessory = [[NSTitlebarAccessoryViewController alloc] init];
    self.menuTitlebarAccessory.view = titlebarContainer;
    self.menuTitlebarAccessory.layoutAttribute = NSLayoutAttributeRight;

    // Edge button for fullscreen mode
    self.edgeMenuButton = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"slider.horizontal.3" accessibilityDescription:nil]
                                             target:self
                                             action:@selector(handleStreamMenuButtonPressed:)];
    self.edgeMenuButton.bordered = NO;
    self.edgeMenuButton.bezelStyle = NSBezelStyleTexturedRounded;
    self.edgeMenuButton.controlSize = NSControlSizeRegular;
    self.edgeMenuButton.contentTintColor = [NSColor whiteColor];
    self.edgeMenuButton.wantsLayer = YES;
    self.edgeMenuButton.layer.cornerRadius = 10.0;
    self.edgeMenuButton.layer.backgroundColor = [[NSColor colorWithWhite:0 alpha:0.35] CGColor];
    self.edgeMenuButton.layer.masksToBounds = YES;

    self.edgeMenuButton.alphaValue = 0.85;
    self.edgeMenuButton.hidden = YES;
    [self.view addSubview:self.edgeMenuButton positioned:NSWindowAbove relativeTo:nil];

    [self startControlCenterTimerIfNeeded];
}

- (void)updateStreamMenuEntrypointsVisibility {
    if (!self.view.window) {
        return;
    }

    BOOL isFullscreen = [self isWindowFullscreen];
    // During/after switching to borderless, AppKit can call layout while the style mask is in flux.
    // Any call that touches the titlebarViewController (including addTitlebarAccessoryViewController:)
    // can assert if the current style doesn't support a titlebar.
    BOOL hasTitlebar = (self.view.window.styleMask & NSWindowStyleMaskTitled) != 0;
    BOOL isBorderless = (!hasTitlebar) || (((self.view.window.styleMask & NSWindowStyleMaskTitled) == 0) && !isFullscreen);

    if (isFullscreen || isBorderless) {
        // NSWindow doesn't expose a public removeTitlebarAccessoryViewController: selector.
        // Keep the accessory installed but hide it in fullscreen.
        if (self.menuTitlebarAccessory) {
            self.menuTitlebarAccessory.view.hidden = YES;
        }

        // Important: do NOT add/remove titlebar accessories when there's no titlebar.
        // applyBorderlessMode already removes the accessory before stripping NSWindowStyleMaskTitled.

        // Borderless should always have the floating button.
        if (isBorderless) {
            self.edgeMenuButton.hidden = NO;
        } else {
            self.edgeMenuButton.hidden = self.hideFullscreenControlBall;
        }

        CGFloat buttonWidth = 40;
        CGFloat buttonHeight = 56;
        CGFloat insetY = 100;
        CGFloat x = self.view.bounds.size.width - (buttonWidth / 2.0); // half-hidden
        CGFloat y = (self.view.bounds.size.height - buttonHeight) / 2.0;
        y = MAX(insetY, MIN(y, self.view.bounds.size.height - buttonHeight - insetY));

        self.edgeMenuButton.frame = NSMakeRect(x, y, buttonWidth, buttonHeight);
        [self bringStreamControlsToFront];
    } else {
        self.edgeMenuButton.hidden = YES;

        if (self.menuTitlebarAccessory) {
            self.menuTitlebarAccessory.view.hidden = NO;
            // Only install the titlebar accessory when the current style supports a titlebar.
            // Do NOT rely on setTitlebarAccessoryViewControllers: (not available on some windows).
            if (hasTitlebar && [self windowAllowsTitlebarAccessories:self.view.window]) {
                BOOL alreadyInstalled = [self isMenuTitlebarAccessoryInstalledInWindow:self.view.window];
                if (!alreadyInstalled) {
                    @try {
                        [self.view.window addTitlebarAccessoryViewController:self.menuTitlebarAccessory];
                        self.menuTitlebarAccessoryInstalled = YES;
                    } @catch (NSException *exception) {
                        // Ignore; AppKit may still be transitioning styles.
                    }
                }
            }
        }
    }
}

- (void)handleStreamMenuButtonPressed:(id)sender {
    NSView *sourceView = nil;
    if ([sender isKindOfClass:[NSView class]]) {
        sourceView = (NSView *)sender;
    } else {
        sourceView = self.view;
    }

    [self presentStreamMenuFromView:sourceView];
}

- (void)presentStreamMenuFromView:(NSView *)sourceView {
    [self rebuildStreamMenu];
    NSMenu *menu = self.streamMenu;

    NSRect bounds = sourceView.bounds;
    NSPoint p = NSMakePoint(NSMidX(bounds), NSMinY(bounds));
    if (sourceView == self.edgeMenuButton) {
        // Edge button: open to the left
        p = NSMakePoint(NSMinX(bounds), NSMidY(bounds));
    }

    [menu popUpMenuPositioningItem:nil atLocation:p inView:sourceView];
}

- (void)presentStreamMenuAtEvent:(NSEvent *)event {
    [self rebuildStreamMenu];
    NSPoint p = [self.view convertPoint:event.locationInWindow fromView:nil];
    [self.streamMenu popUpMenuPositioningItem:nil atLocation:p inView:self.view];
}

- (void)applyWindowedMode {
    NSWindow *window = self.view.window;
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

    [window layoutIfNeeded];
    [window.contentView layoutSubtreeIfNeeded];
    [self.view setNeedsLayout:YES];
    [self.view layoutSubtreeIfNeeded];
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
    [self updateStreamMenuEntrypointsVisibility];

    // If AppKit was mid-transition, try again on next runloop to restore the titlebar control center.
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateStreamMenuEntrypointsVisibility];
    });
}

- (void)switchToWindowedMode:(id)sender {
    NSWindow *window = self.view.window;
    if (window.styleMask & NSWindowStyleMaskFullScreen) {
        self.pendingWindowMode = PendingWindowModeWindowed;
        [window toggleFullScreen:self];
        return;
    }
    
    [self applyWindowedMode];
}

- (void)switchToFullscreenMode:(id)sender {
    NSWindow *window = self.view.window;
    if (window.styleMask & NSWindowStyleMaskBorderless) {
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
        [window toggleFullScreen:self];
    }
}

- (void)applyBorderlessMode {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSWindow *window = self.view.window;
        if (!window) return;

        // Ensure we are not in fullscreen before applying borderless
        if (window.styleMask & NSWindowStyleMaskFullScreen) {
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
        if (self.menuTitlebarAccessory) {
            self.menuTitlebarAccessory.view.hidden = YES;
        }

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
            [w layoutIfNeeded];
            [w.contentView layoutSubtreeIfNeeded];
            [self.view setNeedsLayout:YES];
            [self.view layoutSubtreeIfNeeded];
        });

        // Force a layout pass after styleMask/frame changes to avoid transient blank bars.
        [window layoutIfNeeded];
        [window.contentView layoutSubtreeIfNeeded];
        [self.view setNeedsLayout:YES];
        [self.view layoutSubtreeIfNeeded];

        // Ensure our overlay/menu buttons don't steal key focus (which breaks key equivalents).
        if (self.edgeMenuButton && [self.edgeMenuButton respondsToSelector:@selector(setRefusesFirstResponder:)]) {
            self.edgeMenuButton.refusesFirstResponder = YES;
        }
        if (self.menuTitlebarButton && [self.menuTitlebarButton respondsToSelector:@selector(setRefusesFirstResponder:)]) {
            self.menuTitlebarButton.refusesFirstResponder = YES;
        }
        [window makeFirstResponder:self];

        [self captureMouse];
        [self updateStreamMenuEntrypointsVisibility];
    });
}

- (void)switchToBorderlessMode:(id)sender {
    NSWindow *window = self.view.window;
    if (window.styleMask & NSWindowStyleMaskFullScreen) {
        self.pendingWindowMode = PendingWindowModeBorderless;
        [window toggleFullScreen:self];
        return;
    }
    
    [self applyBorderlessMode];
}

- (void)rebuildStreamMenu {
    if (!self.streamMenu) {
        self.streamMenu = [[NSMenu alloc] initWithTitle:@"StreamMenu"];
    }
    [self.streamMenu removeAllItems];

    void (^setSymbol)(NSMenuItem *, NSString *) = ^(NSMenuItem *item, NSString *symbolName) {
        if (@available(macOS 11.0, *)) {
            item.image = [NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:nil];
        }
    };

    // 一级顶部：重连
    NSMenuItem *reconnectItem = [[NSMenuItem alloc] initWithTitle:@"重连" action:@selector(reconnectFromMenu:) keyEquivalent:@""];
    reconnectItem.target = self;
    setSymbol(reconnectItem, @"arrow.triangle.2.circlepath");
    [self.streamMenu addItem:reconnectItem];

    [self.streamMenu addItem:[NSMenuItem separatorItem]];

    NSDictionary *prefs = [SettingsClass getSettingsFor:self.app.host.uuid];

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

    NSMenuItem *fullscreenItem = [[NSMenuItem alloc] initWithTitle:@"全屏模式" action:@selector(switchToFullscreenMode:) keyEquivalent:@""];
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
    toggleBallItem.target = self;
    toggleBallItem.state = self.hideFullscreenControlBall ? NSControlStateValueOff : NSControlStateValueOn;
    setSymbol(toggleBallItem, @"dot.circle.and.hand.point.up.left.fill");
    [windowMenu addItem:toggleBallItem];

    [windowMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *detailsItem = [[NSMenuItem alloc] initWithTitle:@"连接详情" action:@selector(toggleOverlay) keyEquivalent:@""];
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
    quitItem.target = self;
    setSymbol(quitItem, @"power");
    [moreMenu addItem:quitItem];

    moreItem.submenu = moreMenu;
    [self.streamMenu addItem:moreItem];

    // 一级底部：退出
    [self.streamMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *disconnectItem = [[NSMenuItem alloc] initWithTitle:@"退出串流" action:@selector(performCloseStreamWindow:) keyEquivalent:@""];
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
    [self updateStreamMenuEntrypointsVisibility];
}

- (void)captureMouse {
    if (self.isMouseCaptured) {
        return;
    }

    NSDictionary* prefs = [SettingsClass getSettingsFor:self.app.host.uuid];
    BOOL showLocalCursor = prefs ? [prefs[@"showLocalCursor"] boolValue] : NO;

    if (!showLocalCursor) {
        CGAssociateMouseAndMouseCursorPosition(NO);
        if (self.cursorHiddenCounter == 0) {
            [NSCursor hide];
            self.cursorHiddenCounter ++;
        }
    }
    
    if (!showLocalCursor) {
        CGRect rectInWindow = [self.view convertRect:self.view.bounds toView:nil];
        CGRect rectInScreen = [self.view.window convertRectToScreen:rectInWindow];
        CGFloat screenHeight = self.view.window.screen.frame.size.height;
        CGPoint cursorPoint = CGPointMake(CGRectGetMidX(rectInScreen), screenHeight - CGRectGetMidY(rectInScreen));
        CGWarpMouseCursorPosition(cursorPoint);
    }
    
    [self enableMenuItems:NO];
    
    [self disallowDisplaySleep];
    
    self.hidSupport.shouldSendInputEvents = YES;
    self.controllerSupport.shouldSendInputEvents = YES;
    self.view.window.acceptsMouseMovedEvents = YES;

    self.isMouseCaptured = YES;
}

- (void)uncaptureMouse {
    if (!self.isMouseCaptured && self.cursorHiddenCounter == 0 && !self.hidSupport.shouldSendInputEvents) {
        return;
    }

    NSDictionary* prefs = [SettingsClass getSettingsFor:self.app.host.uuid];
    BOOL showLocalCursor = prefs ? [prefs[@"showLocalCursor"] boolValue] : NO;

    if (!showLocalCursor) {
        CGAssociateMouseAndMouseCursorPosition(YES);
        if (self.cursorHiddenCounter != 0) {
            [NSCursor unhide];
            self.cursorHiddenCounter --;
        }
    }
    
    [self enableMenuItems:YES];
    
    [self allowDisplaySleep];
    
    self.hidSupport.shouldSendInputEvents = NO;
    self.controllerSupport.shouldSendInputEvents = NO;
    self.view.window.acceptsMouseMovedEvents = NO;

    self.isMouseCaptured = NO;
}

- (uint64_t)nowMs {
    return (uint64_t)(CACurrentMediaTime() * 1000.0);
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

- (BOOL)isWindowInCurrentSpace {
    BOOL found = NO;
    CFArrayRef windowsInSpace = CGWindowListCopyWindowInfo(kCGWindowListOptionAll | kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
    for (NSDictionary *thisWindow in (__bridge NSArray *)windowsInSpace) {
        NSNumber *thisWindowNumber = (NSNumber *)thisWindow[(__bridge NSString *)kCGWindowNumber];
        if (self.view.window.windowNumber == thisWindowNumber.integerValue) {
            found = YES;
            break;
        }
    }
    if (windowsInSpace != NULL) {
        CFRelease(windowsInSpace);
    }
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

- (void)closeWindowFromMainQueueWithMessage:(NSString *)message {
    [self.hidSupport releaseAllModifierKeys];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [self uncaptureMouse];

        if (message != nil) {
            // Show the error overlay and keep window open for retry/options
            [self showErrorOverlayWithTitle:@"连接失败" message:message canWait:NO];
        } else {
            [self.delegate appDidQuit:self.app];
            [self.view.window close];
        }
    });
}

- (StreamViewMac *)streamView {
    return (StreamViewMac *)self.view;
}


#pragma mark - Streaming Operations

- (void)prepareForStreaming {
    StreamConfiguration *streamConfig = [[StreamConfiguration alloc] init];
    
    streamConfig.host = self.app.host.activeAddress;
    
    NSDictionary* prefs = [SettingsClass getSettingsFor:self.app.host.uuid];
    if (prefs) {
        NSString *connectionMethod = prefs[@"connectionMethod"];
        if (connectionMethod && ![connectionMethod isEqualToString:@"Auto"]) {
            streamConfig.host = connectionMethod;
        }
    }
    
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

    // Auto-adjust bitrate (mirrors moonlight-qt default algorithm)
    BOOL autoAdjustBitrate = prefs ? [prefs[@"autoAdjustBitrate"] boolValue] : NO;
    if (autoAdjustBitrate) {
        BOOL enableYuv444 = prefs ? [prefs[@"yuv444"] boolValue] : NO;
        int modeWidth = streamConfig.width;
        int modeHeight = streamConfig.height;
        int modeFps = streamConfig.frameRate;

        // Incorporate remote overrides (host render mode) for bitrate calculation
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
    }
    streamConfig.optimizeGameSettings = streamSettings.optimizeGames;
    streamConfig.playAudioOnPC = streamSettings.playAudioOnPC;
    streamConfig.allowHevc = streamSettings.useHevc;
    streamConfig.enableHdr = streamSettings.useHevc && VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) ? streamSettings.enableHdr : NO;

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
    
    streamConfig.enableVsync = [SettingsClass enableVsyncFor:self.app.host.uuid];
    streamConfig.showPerformanceOverlay = [SettingsClass showPerformanceOverlayFor:self.app.host.uuid];
    streamConfig.gamepadMouseMode = [SettingsClass gamepadMouseModeFor:self.app.host.uuid];
    streamConfig.upscalingMode = (int)[SettingsClass upscalingModeFor:self.app.host.uuid];

    if (self.useSystemControllerDriver) {

        if (@available(iOS 13, tvOS 13, macOS 10.15, *)) {
            self.controllerSupport = [[ControllerSupport alloc] initWithConfig:streamConfig presenceDelegate:self];
        }
    }
    self.hidSupport = [[HIDSupport alloc] init:self.app.host];
    
    self.streamMan = [[StreamManager alloc] initWithConfig:streamConfig renderView:self.view connectionCallbacks:self];
    if (!self.streamOpQueue) {
        self.streamOpQueue = [[NSOperationQueue alloc] init];
    }
    [self.streamOpQueue addOperation:self.streamMan];

    [self startConnectWatchdog];
    
    // Don’t create the overlay before streaming starts. The video view may be inserted later
    // and would otherwise cover the overlay.
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

- (void)handleTimeoutCopyLogs:(id)sender {
    NSArray *lines = [[LogBuffer shared] allLines];
    NSString *fullLog = [lines componentsJoinedByString:@"\n"];
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    [pb setString:fullLog forType:NSPasteboardTypeString];

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
        NSString *joined = [lines componentsJoinedByString:@"\n"];
        self.logOverlayTextView.string = joined;
        [self.logOverlayTextView scrollRangeToVisible:NSMakeRange(self.logOverlayTextView.string.length, 0)];
    }

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

- (void)appendLogLineToOverlay:(NSString *)line {
    if (!self.logOverlayTextView || !line) {
        return;
    }

    // Append while preserving scrolling if user is looking at history
    // But default to auto-scroll if at bottom
    
    // Check if we are scrolled to the bottom (with some tolerance)
    NSRect visible = self.logOverlayScrollView.contentView.documentVisibleRect;
    NSRect docRect = self.logOverlayTextView.frame;
    BOOL wasAtBottom = (NSMaxY(visible) >= NSMaxY(docRect) - 20.0);

    NSString *existing = self.logOverlayTextView.string ?: @"";
    NSString *newText = existing.length == 0 ? line : [existing stringByAppendingFormat:@"\n%@", line];
    self.logOverlayTextView.string = newText;
    
    if (wasAtBottom) {
        [self.logOverlayTextView scrollRangeToVisible:NSMakeRange(self.logOverlayTextView.string.length, 0)];
    }
}

- (void)copyAllLogsToPasteboard {
    NSArray<NSString *> *lines = [[LogBuffer shared] allLines];
    NSString *joined = [lines componentsJoinedByString:@"\n"];
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

    // Preserve fullscreen/windowed state across reconnects.
    self.reconnectPreserveFullscreenStateValid = YES;
    if ([self isWindowFullscreen]) {
        self.reconnectPreservedWindowMode = 1;
    } else if ([self isWindowBorderlessMode]) {
        self.reconnectPreservedWindowMode = 2;
    } else {
        self.reconnectPreservedWindowMode = 0;
    }

    @synchronized (self) {
        if (self.stopStreamInProgress) {
            return;
        }
        self.stopStreamInProgress = YES;
    }

    self.reconnectInProgress = YES;
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
            __strong typeof(self) strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }

            @synchronized (strongSelf) {
                strongSelf.stopStreamInProgress = NO;
            }

            if (strongSelf.useSystemControllerDriver) {
                [strongSelf.controllerSupport cleanup];
            }
            [strongSelf.hidSupport tearDownHidManager];
            strongSelf.hidSupport = nil;
            strongSelf.controllerSupport = nil;

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
    
    self.statsTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(updateStats) userInfo:nil repeats:YES];
    [self updateStats]; // Initial update
}

- (void)updateStats {
    if (!self.overlayContainer) return;

    VideoStats stats = self.streamMan.connection.renderer.videoStats;
    int videoFormat = self.streamMan.connection.renderer.videoFormat;

    if (stats.receivedFrames == 0) {
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
    }

    NSString *chromaString = (videoFormat & VIDEO_FORMAT_MASK_YUV444) ? @"4:4:4" : @"4:2:0";
    
    DataManager* dataMan = [[DataManager alloc] init];
    TemporarySettings* streamSettings = [dataMan getSettings];

    struct Resolution res = [self.class getResolution];
    int configuredFps = streamSettings.framerate != nil ? [streamSettings.framerate intValue] : 0;
    
    uint32_t rtt = 0;
    uint32_t rttVar = 0;
    LiGetEstimatedRttInfo(&rtt, &rttVar);
    
    float loss = stats.totalFrames > 0 ? (float)stats.networkDroppedFrames / stats.totalFrames * 100.0f : 0;
    float jitter = stats.jitterMs;

    // Approximate current video bitrate over the last measurement window (≈1s)
    double bitrateMbps = (double)stats.receivedBytes * 8.0 / 1000.0 / 1000.0;
    
    float renderTime = stats.renderedFrames > 0 ? (float)stats.totalRenderTime / stats.renderedFrames : 0;
    float decodeTime = stats.decodedFrames > 0 ? (float)stats.totalDecodeTime / stats.decodedFrames : 0;
    float encodeTime = stats.framesWithHostProcessingLatency > 0 ? (float)stats.totalHostProcessingLatency / 10.0f / stats.framesWithHostProcessingLatency : 0;
    
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
    append([NSString stringWithFormat:@"%.1f", stats.receivedFps], valueAttrs);
    append(@" Rx · ", labelAttrs);
    append([NSString stringWithFormat:@"%.1f", stats.decodedFps], valueAttrs);
    append(@" De · ", labelAttrs);
    append([NSString stringWithFormat:@"%.1f", stats.renderedFps], valueAttrs);
    append(@" Rd", labelAttrs);
    
    // Network
    append(@"  Network ", labelAttrs);
    append([NSString stringWithFormat:@"%u", rtt], valueAttrs);
    append(@" ± ", labelAttrs);
    append([NSString stringWithFormat:@"%u", rttVar], valueAttrs);
    append(@" ms  Loss ", labelAttrs);
    append([NSString stringWithFormat:@"%.2f%%", loss], valueAttrs);

    append(@"  Jit ", labelAttrs);
    append([NSString stringWithFormat:@"%.1f", jitter], valueAttrs);
    append(@" ms  Br ", labelAttrs);
    append([NSString stringWithFormat:@"%.1f", bitrateMbps], valueAttrs);
    append(@" Mbps", labelAttrs);
    
    // Latency
    append(@"  |  Queue ", labelAttrs);
    append([NSString stringWithFormat:@"%.2f", renderTime], valueAttrs);
    append(@" ms · Decode ", labelAttrs);
    append([NSString stringWithFormat:@"%.2f", decodeTime], valueAttrs);
    append(@" ms · Encode ", labelAttrs);
    append([NSString stringWithFormat:@"%.1f", encodeTime], valueAttrs);
    append(@" ms", labelAttrs);

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
}

- (void)connectionStarted {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.streamView.statusText = nil;

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

        // Make the stream interactive as soon as we have video.
        // Without this, fullscreen transitions can leave input disabled until AppKit
        // finishes space/key-window transitions, which can take several seconds.
        [self captureMouse];

        if (displayMode == 1) {
            if (!(self.view.window.styleMask & NSWindowStyleMaskFullScreen)) {
                [self.view.window toggleFullScreen:self];
            }
        } else if (displayMode == 2) {
            [self switchToBorderlessMode:nil];
        } else {
            // Avoid forcing fullscreen during reconnect if the user was windowed.
            if (self.view.window.styleMask & NSWindowStyleMaskFullScreen) {
                [self.view.window toggleFullScreen:self];
            }
        }

        // Re-assert capture shortly after mode switches in case AppKit temporarily steals focus.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!self.isMouseCaptured) {
                [self captureMouse];
            }
        });
    });
}

- (void)connectionTerminated:(int)errorCode {
    Log(LOG_I, @"Connection terminated: %ld", (long)errorCode);
    
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
        
        // If error code is non-zero, treat as error.
        if (errorCode != 0) {
             // Try to be more specific if possible. (12345 = Special user request?? No, usually standard errnos)
             NSString *msg = [NSString stringWithFormat:@"连接意外终止 (错误代码: %d)", errorCode];
             if (errorCode == -1) {
                 msg = @"连接已断开，请检查网络设置。";
             }
             [self closeWindowFromMainQueueWithMessage:msg];
        } else {
             // errorCode == 0 means normal termination from host side or successful end.
             if ([SettingsClass quitAppAfterStreamFor:self.app.host.uuid]) {
                 [self.delegate quitApp:self.app completion:nil];
             } else {
                 [self closeWindowFromMainQueueWithMessage:nil];
             }
        }
    });
}

- (void)stageFailed:(const char *)stageName withError:(int)errorCode {
    Log(LOG_I, @"Stage %s failed: %ld", stageName, errorCode);
    [self closeWindowFromMainQueueWithMessage:[NSString stringWithFormat:@"%s failed with error %d", stageName, errorCode]];
}

- (void)launchFailed:(NSString *)message {
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
        if (status == CONN_STATUS_POOR) {
            uint64_t now = [self nowMs];
            if (self.disconnectWasUserInitiated || now < self.suppressConnectionWarningsUntilMs) {
                // Avoid showing a misleading warning during intentional teardown/detach.
                [self hideConnectionWarning];
                return;
            }
            if ([SettingsClass showConnectionWarningsFor:self.app.host.uuid]) {
                [self showConnectionWarning];
            }
        } else if (status == CONN_STATUS_OKAY) {
            [self hideConnectionWarning];
        }
    });
}

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

    [self updateStreamMenuEntrypointsVisibility];

    if (self.logOverlayContainer) {
        CGFloat padding = 16.0;
        CGFloat width = MIN(720.0, self.view.bounds.size.width - padding * 2);
        CGFloat height = MIN(420.0, self.view.bounds.size.height - padding * 2);
        self.logOverlayContainer.frame = NSMakeRect((self.view.bounds.size.width - width) / 2.0,
                                                   (self.view.bounds.size.height - height) / 2.0,
                                                   width,
                                                   height);
        
        // Position Close Button (Tag 999)
        NSButton *closeBtn = [self.logOverlayContainer viewWithTag:999];
        CGFloat topMargin = 0;
        if (closeBtn) {
            [closeBtn sizeToFit];
            CGFloat btnW = closeBtn.frame.size.width + 20; // Some extra padding for hit area
            if (btnW < 60) btnW = 60;
            CGFloat btnH = closeBtn.frame.size.height;
            closeBtn.frame = NSMakeRect(width - btnW - 12, height - btnH - 12, btnW, btnH);
            topMargin = btnH + 20;
        } else {
             topMargin = 12;
        }

        self.logOverlayScrollView.frame = NSMakeRect(12, 12, width - 24, height - 12 - topMargin);
        // Do not force height, only width. Let layout manager handle it.
        // Or if using manual frame, ensure it's at least the content width.
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
        CGFloat width = 480.0;  // 增加宽度
        CGFloat height = 460.0;  // 增加高度以容纳更好的间距
        NSRect bounds = self.view.bounds;
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
        CGFloat paddingTop = 30.0;  // 顶部内边距
        CGFloat paddingSide = 30.0; // 左右内边距

        // 图标和文本 - 从顶部开始布局
        self.timeoutIconLabel.frame = NSMakeRect(0, height - paddingTop - 60, width, 60);
        self.timeoutTitleLabel.frame = NSMakeRect(0, height - paddingTop - 96, width, 26);
        self.timeoutLabel.frame = NSMakeRect(paddingSide, height - paddingTop - 150, width - paddingSide * 2, 44);

        CGFloat largeBtnWidth = 140;
        CGFloat largeBtnHeight = 32;
        CGFloat mainBtnY = 220;  // 主按钮Y位置
        
        // Primary Action: Reconnect and Wait
        if (self.timeoutWaitButton.hidden) {
            // Reconnect centered
            self.timeoutReconnectButton.frame = NSMakeRect(centerX - largeBtnWidth/2, mainBtnY, largeBtnWidth, largeBtnHeight);
        } else {
            // Reconnect | Wait
            CGFloat gap = 16;
            self.timeoutReconnectButton.frame = NSMakeRect(centerX - largeBtnWidth - gap/2, mainBtnY, largeBtnWidth, largeBtnHeight);
            self.timeoutWaitButton.frame = NSMakeRect(centerX + gap/2, mainBtnY, largeBtnWidth, largeBtnHeight);
        }
        
        // Exit Action
        self.timeoutExitButton.frame = NSMakeRect(centerX - largeBtnWidth/2, mainBtnY - largeBtnHeight - 14, largeBtnWidth, largeBtnHeight);
        
        // Settings Row - 增加间距
        CGFloat settingsY = 130;
        CGFloat settingBtnWidth = 102; 
        CGFloat settingBtnHeight = 30;
        CGFloat gap = 10;
        
        // Row 1: Resolution, Bitrate, Display, Connection
        NSButton *buttons[] = {self.timeoutResolutionButton, self.timeoutBitrateButton, self.timeoutDisplayModeButton, self.timeoutConnectionButton};
        size_t count = sizeof(buttons) / sizeof(buttons[0]);
        CGFloat totalSettingsW = settingBtnWidth * count + gap * (count - 1);
        CGFloat startX = (width - totalSettingsW) / 2.0;

        for (size_t i = 0; i < count; i++) {
            buttons[i].frame = NSMakeRect(startX + (settingBtnWidth + gap) * i, settingsY, settingBtnWidth, settingBtnHeight);
        }
        
        // Logs Row - 改进样式，调整位置和尺寸
        CGFloat logsY = 80;  // 稍微往上移一点，给底部更多空间
        CGFloat logsBtnWidth = 90;  // 使用新的宽度
        CGFloat logsBtnHeight = 28; // 新的高度
        CGFloat logsGap = 12;  // 缩小间距，更紧凑
        CGFloat totalLogsW = logsBtnWidth * 2 + logsGap;
        CGFloat logsStartX = (width - totalLogsW) / 2.0;
        
        self.timeoutViewLogsButton.frame = NSMakeRect(logsStartX, logsY, logsBtnWidth, logsBtnHeight);
        self.timeoutCopyLogsButton.frame = NSMakeRect(logsStartX + logsBtnWidth + logsGap, logsY, logsBtnWidth, logsBtnHeight);
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
    [self performCloseStreamWindow:nil];
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
            case NSBezierPathElementClosePath:
                CGPathCloseSubpath(path);
                break;
        }
    }
    
    return path;
}

@end
