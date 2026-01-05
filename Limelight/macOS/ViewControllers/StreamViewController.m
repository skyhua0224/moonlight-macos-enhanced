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
@property (nonatomic) BOOL reconnectPreservedWasFullscreen;

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

@property (nonatomic, strong) NSVisualEffectView *logOverlayContainer;
@property (nonatomic, strong) NSScrollView *logOverlayScrollView;
@property (nonatomic, strong) NSTextView *logOverlayTextView;
@property (nonatomic, strong) id logDidAppendObserver;

@property (nonatomic, strong) NSVisualEffectView *reconnectOverlayContainer;
@property (nonatomic, strong) NSProgressIndicator *reconnectSpinner;
@property (nonatomic, strong) NSTextField *reconnectLabel;

@property (nonatomic, strong) NSVisualEffectView *timeoutOverlayContainer;
@property (nonatomic, strong) NSTextField *timeoutLabel;
@property (nonatomic, strong) NSButton *timeoutSwitchMethodButton;
@property (nonatomic, strong) NSButton *timeoutExitButton;

@property (nonatomic) NSInteger connectWatchdogToken;
@property (nonatomic) BOOL didAutoReconnectAfterTimeout;

@property (nonatomic, strong) id settingsDidChangeObserver;
@property (nonatomic, strong) id hostLatencyUpdatedObserver;

@end

@implementation StreamViewController

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

        // 10s with no frames: attempt a single auto-reconnect (once per stream VC lifetime), then show timeout UI.
        if (!strongSelf.reconnectInProgress && !strongSelf.didAutoReconnectAfterTimeout && strongSelf.shouldAttemptReconnect) {
            strongSelf.didAutoReconnectAfterTimeout = YES;
            [strongSelf showReconnectOverlayWithMessage:@"网络无响应，正在尝试重连…"]; 
            [strongSelf attemptReconnectWithReason:@"connect-timeout-auto"]; 
            return;
        }

        [strongSelf showConnectionTimeoutOverlay];
    });
}

- (void)showConnectionTimeoutOverlay {
    if (self.timeoutOverlayContainer) {
        return;
    }

    NSVisualEffectView *container = [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
    container.material = NSVisualEffectMaterialHUDWindow;
    container.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    container.state = NSVisualEffectStateActive;
    container.wantsLayer = YES;
    container.layer.cornerRadius = 12.0;
    container.layer.masksToBounds = YES;
    container.alphaValue = 0.0;

    NSTextField *label = [[NSTextField alloc] initWithFrame:NSZeroRect];
    label.bezeled = NO;
    label.drawsBackground = NO;
    label.editable = NO;
    label.selectable = NO;
    label.alignment = NSTextAlignmentCenter;
    label.font = [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold];
    label.textColor = [NSColor whiteColor];
    label.stringValue = @"连接超时（10 秒无画面）";

    NSButton *switchBtn = [NSButton buttonWithTitle:@"切换连接方式" target:self action:@selector(handleTimeoutSwitchConnectionMethod:)];
    switchBtn.bezelStyle = NSBezelStyleRounded;

    NSButton *exitBtn = [NSButton buttonWithTitle:@"退出串流" target:self action:@selector(handleTimeoutExitStream:)];
    exitBtn.bezelStyle = NSBezelStyleRounded;

    self.timeoutOverlayContainer = container;
    self.timeoutLabel = label;
    self.timeoutSwitchMethodButton = switchBtn;
    self.timeoutExitButton = exitBtn;

    [container addSubview:label];
    [container addSubview:switchBtn];
    [container addSubview:exitBtn];

    [self.view addSubview:container positioned:NSWindowAbove relativeTo:nil];
    [self viewDidLayout];

    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.12;
        container.animator.alphaValue = 1.0;
    } completionHandler:nil];
}

- (void)hideConnectionTimeoutOverlay {
    if (!self.timeoutOverlayContainer) {
        return;
    }

    NSVisualEffectView *container = self.timeoutOverlayContainer;
    self.timeoutOverlayContainer = nil;
    self.timeoutLabel = nil;
    self.timeoutSwitchMethodButton = nil;
    self.timeoutExitButton = nil;

    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.15;
        container.animator.alphaValue = 0.0;
    } completionHandler:^{
        [container removeFromSuperview];
    }];
}

- (void)handleTimeoutExitStream:(id)sender {
    [self performCloseStreamWindow:sender];
}

- (void)handleTimeoutSwitchConnectionMethod:(id)sender {
    // Present a small menu with connection method options at window center.
    NSDictionary *prefs = [SettingsClass getSettingsFor:self.app.host.uuid];
    NSString *method = prefs[@"connectionMethod"] ?: @"Auto";

    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"连接方式"]; 
    void (^setSymbol)(NSMenuItem *, NSString *) = ^(NSMenuItem *item, NSString *symbolName) {
        if (@available(macOS 11.0, *)) {
            item.image = [NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:nil];
        }
    };

    NSMenuItem *autoItem = [[NSMenuItem alloc] initWithTitle:@"自动" action:@selector(selectConnectionMethodFromMenu:) keyEquivalent:@""];
    autoItem.target = self;
    autoItem.representedObject = @"Auto";
    autoItem.state = [method isEqualToString:@"Auto"] ? NSControlStateValueOn : NSControlStateValueOff;
    setSymbol(autoItem, @"wand.and.stars");
    [menu addItem:autoItem];

    NSArray<NSString *> *candidates = @[ self.app.host.localAddress ?: @"", self.app.host.address ?: @"", self.app.host.externalAddress ?: @"", self.app.host.ipv6Address ?: @"" ];
    NSMutableOrderedSet<NSString *> *unique = [[NSMutableOrderedSet alloc] init];
    for (NSString *addr in candidates) {
        if (addr.length > 0) {
            [unique addObject:addr];
        }
    }
    if (unique.count > 0) {
        [menu addItem:[NSMenuItem separatorItem]];
        for (NSString *addr in unique) {
            NSMenuItem *addrItem = [[NSMenuItem alloc] initWithTitle:addr action:@selector(selectConnectionMethodFromMenu:) keyEquivalent:@""];
            addrItem.target = self;
            addrItem.representedObject = addr;
            addrItem.state = [method isEqualToString:addr] ? NSControlStateValueOn : NSControlStateValueOff;
            setSymbol(addrItem, @"link");
            [menu addItem:addrItem];
        }
    }

    NSRect bounds = self.view.bounds;
    NSPoint p = NSMakePoint(NSMidX(bounds), NSMidY(bounds));
    [menu popUpMenuPositioningItem:nil atLocation:p inView:self.view];
}

- (void)beginStopStreamIfNeededWithReason:(NSString *)reason {
    @synchronized (self) {
        if (self.stopStreamInProgress) {
            return;
        }
        self.stopStreamInProgress = YES;
    }

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
    [self.view.window moonlight_centerWindowOnFirstRunWithSize:CGSizeMake(1008, 595)];
    
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

    [self.hidSupport tearDownHidManager];
    self.hidSupport = nil;
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
    [self.nextResponder doCommandBySelector:@selector(performClose:)];
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

    if (isFullscreen) {
        // NSWindow doesn't expose a public removeTitlebarAccessoryViewController: selector.
        // Keep the accessory installed but hide it in fullscreen.
        if (self.menuTitlebarAccessory) {
            self.menuTitlebarAccessory.view.hidden = YES;
        }

        self.edgeMenuButton.hidden = self.hideFullscreenControlBall;

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
            // Avoid duplicates
            if (![self.view.window.titlebarAccessoryViewControllers containsObject:self.menuTitlebarAccessory]) {
                [self.view.window addTitlebarAccessoryViewController:self.menuTitlebarAccessory];
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

    NSString *fullscreenTitle = [self isWindowFullscreen] ? @"退出全屏" : @"进入全屏";
    NSMenuItem *fullscreenItem = [[NSMenuItem alloc] initWithTitle:fullscreenTitle action:@selector(handleToggleFullscreenFromMenu:) keyEquivalent:@""];
    fullscreenItem.target = self;
    setSymbol(fullscreenItem, @"arrow.up.left.and.arrow.down.right");
    [windowMenu addItem:fullscreenItem];

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
    for (NSNumber *mbps in bitrateMbpsChoices) {
        NSInteger kbps = mbps.integerValue * 1000;
        NSString *title = [NSString stringWithFormat:@"%@ Mbps", mbps];
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:@selector(selectBitrateFromMenu:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = @(kbps);
        item.state = (!autoAdjust && selectedKbps == kbps) ? NSControlStateValueOn : NSControlStateValueOff;
        setSymbol(item, @"speedometer");
        [qualityMenu addItem:item];
    }

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

        [self.delegate appDidQuit:self.app];
        if (message != nil) {
            [AlertPresenter displayAlert:NSAlertStyleWarning title:@"Connection Failed" message:message window:self.view.window completionHandler:^(NSModalResponse returnCode) {
                [self.view.window close];
            }];
        } else {
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

    self.logOverlayScrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    self.logOverlayScrollView.hasVerticalScroller = YES;
    self.logOverlayScrollView.drawsBackground = NO;

    self.logOverlayTextView = [[NSTextView alloc] initWithFrame:NSZeroRect];
    self.logOverlayTextView.editable = NO;
    self.logOverlayTextView.selectable = YES;
    self.logOverlayTextView.drawsBackground = NO;
    self.logOverlayTextView.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    self.logOverlayTextView.textColor = [NSColor whiteColor];
    self.logOverlayTextView.insertionPointColor = [NSColor whiteColor];

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

- (void)appendLogLineToOverlay:(NSString *)line {
    if (!self.logOverlayTextView || !line) {
        return;
    }

    // Append while preserving selection
    BOOL atEnd = NSMaxRange(self.logOverlayTextView.selectedRange) == self.logOverlayTextView.string.length;
    NSString *existing = self.logOverlayTextView.string ?: @"";
    NSString *newText = existing.length == 0 ? line : [existing stringByAppendingFormat:@"\n%@", line];
    self.logOverlayTextView.string = newText;
    if (atEnd) {
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
    self.reconnectPreservedWasFullscreen = [self isWindowFullscreen];

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

        BOOL wasReconnect = self.reconnectInProgress;
        if (self.reconnectInProgress) {
            self.reconnectInProgress = NO;
            [self hideReconnectOverlay];
        }

        // Create overlay after streaming starts so it stays on top of the video view.
        if ([SettingsClass showPerformanceOverlayFor:self.app.host.uuid] && !self.overlayContainer) {
            [self setupOverlay];
        }
        
        BOOL desiredFullscreen = [SettingsClass autoFullscreenFor:self.app.host.uuid];
        if (wasReconnect && self.reconnectPreserveFullscreenStateValid) {
            desiredFullscreen = self.reconnectPreservedWasFullscreen;
        }
        self.reconnectPreserveFullscreenStateValid = NO;

        if (desiredFullscreen) {
            if (!(self.view.window.styleMask & NSWindowStyleMaskFullScreen)) {
                [self.view.window toggleFullScreen:self];
            }
        } else {
            // Avoid forcing fullscreen during reconnect if the user was windowed.
            if (self.view.window.styleMask & NSWindowStyleMaskFullScreen) {
                [self.view.window toggleFullScreen:self];
            }
            [self captureMouse];
        }
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
        
        if (errorCode == 0 && [SettingsClass quitAppAfterStreamFor:self.app.host.uuid]) {
            [self.delegate quitApp:self.app completion:nil];
        } else {
            [self closeWindowFromMainQueueWithMessage:nil];
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
        self.logOverlayScrollView.frame = NSMakeRect(12, 12, width - 24, height - 24);
        self.logOverlayTextView.frame = self.logOverlayScrollView.bounds;
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
        CGFloat width = 360.0;
        CGFloat height = 140.0;
        NSRect bounds = self.view.bounds;
        self.timeoutOverlayContainer.frame = NSMakeRect((NSWidth(bounds) - width) / 2.0,
                                                       (NSHeight(bounds) - height) / 2.0,
                                                       width,
                                                       height);

        self.timeoutLabel.frame = NSMakeRect(16, height - 56, width - 32, 28);
        self.timeoutSwitchMethodButton.frame = NSMakeRect(22, 26, (width - 54) / 2.0, 32);
        self.timeoutExitButton.frame = NSMakeRect(22 + (width - 54) / 2.0 + 10, 26, (width - 54) / 2.0, 32);
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

@end
