//
//  StreamViewController.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 25/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import "StreamViewController.h"
#import "StreamingSessionManager.h" // Import Session Manager
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
#include "Limelight-internal.h"

@import VideoToolbox;

#import <IOKit/pwr_mgt/IOPMLib.h>
#import <Carbon/Carbon.h>
#include <arpa/inet.h>

typedef NS_ENUM(NSInteger, PendingWindowMode) {
    PendingWindowModeNone,
    PendingWindowModeWindowed,
    PendingWindowModeBorderless
};

static BOOL MLIsPrivateOrLocalIPv4String(NSString *ip) {
    struct in_addr addr;
    if (inet_pton(AF_INET, ip.UTF8String, &addr) != 1) {
        return NO;
    }

    uint32_t host = ntohl(addr.s_addr);
    if ((host & 0xFF000000) == 0x0A000000) return YES;        // 10.0.0.0/8
    if ((host & 0xFFF00000) == 0xAC100000) return YES;        // 172.16.0.0/12
    if ((host & 0xFFFF0000) == 0xC0A80000) return YES;        // 192.168.0.0/16
    if ((host & 0xFFFF0000) == 0xA9FE0000) return YES;        // 169.254.0.0/16
    if ((host & 0xFF000000) == 0x7F000000) return YES;        // 127.0.0.0/8
    return NO;
}

static BOOL MLIsPrivateOrLocalIPv6String(NSString *ip) {
    struct in6_addr addr6;
    if (inet_pton(AF_INET6, ip.UTF8String, &addr6) != 1) {
        return NO;
    }

    // ::1 loopback
    BOOL isLoopback = YES;
    for (int i = 0; i < 15; i++) {
        if (addr6.s6_addr[i] != 0) {
            isLoopback = NO;
            break;
        }
    }
    if (isLoopback && addr6.s6_addr[15] == 1) {
        return YES;
    }

    // fe80::/10 link-local
    if (addr6.s6_addr[0] == 0xFE && (addr6.s6_addr[1] & 0xC0) == 0x80) {
        return YES;
    }

    // fc00::/7 unique local
    if ((addr6.s6_addr[0] & 0xFE) == 0xFC) {
        return YES;
    }

    return NO;
}

static BOOL MLIsIpLiteralString(NSString *host) {
    if (host.length == 0) {
        return NO;
    }
    struct in_addr addr4;
    if (inet_pton(AF_INET, host.UTF8String, &addr4) == 1) {
        return YES;
    }
    struct in6_addr addr6;
    return inet_pton(AF_INET6, host.UTF8String, &addr6) == 1;
}

static BOOL MLShouldTreatAsKnownLocalHost(NSString *host) {
    if (host.length == 0) {
        return NO;
    }
    NSString *lower = host.lowercaseString;
    if ([lower isEqualToString:@"localhost"] || [lower hasSuffix:@".local"]) {
        return YES;
    }
    if (!MLIsIpLiteralString(host)) {
        return NO;
    }
    return MLIsPrivateOrLocalIPv4String(host) || MLIsPrivateOrLocalIPv6String(host);
}

static NSString *MLDisconnectEventSummary(NSEvent *event) {
    if (event == nil) {
        return @"(null)";
    }
    NSString *chars = event.charactersIgnoringModifiers ?: @"";
    NSEventModifierFlags mods = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    return [NSString stringWithFormat:@"type=%ld keyCode=%hu mods=0x%llx chars=%@ win=%ld",
            (long)event.type,
            event.keyCode,
            (unsigned long long)mods,
            chars,
            (long)event.window.windowNumber];
}

static CGFloat MLMeasureMultilineTextHeight(NSString *text, NSFont *font, CGFloat width) {
    if (text.length == 0 || font == nil || width <= 0.0) {
        return 0.0;
    }

    NSDictionary<NSAttributedStringKey, id> *attributes = @{ NSFontAttributeName: font };
    NSRect rect = [text boundingRectWithSize:NSMakeSize(width, CGFLOAT_MAX)
                                     options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                  attributes:attributes];
    return ceil(NSHeight(rect));
}

static CGFloat MLOverlayButtonWidth(NSButton *button, CGFloat minWidth, CGFloat maxWidth) {
    if (button == nil) {
        return minWidth;
    }

    NSDictionary<NSAttributedStringKey, id> *attributes = @{
        NSFontAttributeName: button.font ?: [NSFont systemFontOfSize:[NSFont systemFontSize]]
    };
    CGFloat titleWidth = ceil([button.title sizeWithAttributes:attributes].width);
    CGFloat imageWidth = button.image != nil ? MAX(14.0, button.image.size.width) + 8.0 : 0.0;
    CGFloat width = titleWidth + imageWidth + 24.0;
    return MIN(maxWidth, MAX(minWidth, width));
}

static BOOL MLGetUsableRttInfo(PML_CONTROL_STREAM_CONTEXT controlCtx, uint32_t *rtt, uint32_t *rttVar) {
    uint32_t currentRtt = 0;
    uint32_t currentRttVar = 0;
    if (controlCtx == NULL || !LiGetEstimatedRttInfoCtx(controlCtx, &currentRtt, &currentRttVar)) {
        return NO;
    }

    if (currentRtt == 0 && currentRttVar == 0) {
        return NO;
    }

    if (rtt != NULL) {
        *rtt = currentRtt;
    }
    if (rttVar != NULL) {
        *rttVar = currentRttVar;
    }
    return YES;
}

static NSString *MLRttLogSummary(PML_CONTROL_STREAM_CONTEXT controlCtx) {
    uint32_t rtt = 0;
    uint32_t rttVar = 0;
    if (!MLGetUsableRttInfo(controlCtx, &rtt, &rttVar)) {
        return @"n/a";
    }

    NSString *rttText = rtt == 0 ? @"<1" : [NSString stringWithFormat:@"%u", rtt];
    NSString *rttVarText = rttVar == 0 ? @"<1" : [NSString stringWithFormat:@"%u", rttVar];
    return [NSString stringWithFormat:@"%@/%@", rttText, rttVarText];
}

static const NSTimeInterval MLControlCenterRefreshIntervalSec = 0.5;
static const NSTimeInterval MLStatsOverlayRefreshIntervalSec = 0.5;

@protocol MLStreamScopedCallbackOwner <ConnectionCallbacks>
- (BOOL)isActiveStreamGeneration:(NSUInteger)generation;
@end

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

@interface StreamViewController () <MLStreamScopedCallbackOwner, KeyboardNotifiableDelegate, InputPresenceDelegate>

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
@property (nonatomic, strong) NSTimer *streamHealthTimer;
@property (nonatomic) BOOL streamHealthSawPayload;
@property (nonatomic) NSUInteger streamHealthNoPayloadStreak;
@property (nonatomic) NSUInteger streamHealthNoDecodeStreak;
@property (nonatomic) NSUInteger streamHealthNoRenderStreak;
@property (nonatomic) NSUInteger streamHealthHighDropStreak;
@property (nonatomic) NSUInteger streamHealthFrozenStatsStreak;
@property (nonatomic) uint32_t streamHealthLastReceivedFrames;
@property (nonatomic) uint32_t streamHealthLastDecodedFrames;
@property (nonatomic) uint32_t streamHealthLastRenderedFrames;
@property (nonatomic) uint32_t streamHealthLastTotalFrames;
@property (nonatomic) uint64_t streamHealthLastReceivedBytes;
@property (nonatomic) uint64_t streamHealthLastMitigationMs;
@property (nonatomic) uint64_t streamHealthLastPayloadReconnectMs;
@property (nonatomic) uint64_t streamHealthConnectionStartedMs;
@property (nonatomic) NSInteger streamHealthMitigationStep;
@property (nonatomic) int lastConnectionStatus;
@property (nonatomic) NSUInteger connectionPoorStatusBurstCount;
@property (nonatomic) uint64_t connectionPoorStatusBurstWindowStartMs;
@property (nonatomic) uint64_t connectionLastIdrRequestMs;
@property (nonatomic) NSInteger runtimeAutoBitrateCapKbps;
@property (nonatomic) NSInteger runtimeAutoBitrateBaselineKbps;
@property (nonatomic) NSUInteger runtimeAutoBitrateStableStreak;
@property (nonatomic) uint64_t runtimeAutoBitrateLastRaiseMs;

@property (nonatomic, strong) NSVisualEffectView *connectionWarningContainer;
@property (nonatomic, strong) NSTextField *connectionWarningLabel;

@property (nonatomic, strong) NSVisualEffectView *notificationContainer;
@property (nonatomic, strong) NSTextField *notificationLabel;
@property (nonatomic, strong) NSTimer *notificationTimer;

@property (nonatomic, strong) NSVisualEffectView *mouseModeContainer;
@property (nonatomic, strong) NSTextField *mouseModeLabel;

@property (nonatomic) BOOL disconnectWasUserInitiated;
@property (nonatomic) uint64_t suppressConnectionWarningsUntilMs;
@property (nonatomic, copy) NSString *pendingDisconnectSource;
@property (nonatomic) uint64_t lastOptionUncaptureAtMs;
@property (nonatomic) NSUInteger pendingOptionUncaptureToken;
@property (nonatomic) BOOL isMouseCaptured;
@property (nonatomic) BOOL isRemoteDesktopMode;
@property (atomic) BOOL stopStreamInProgress;

@property (nonatomic) BOOL shouldAttemptReconnect;
@property (nonatomic) NSInteger reconnectAttemptCount;
@property (nonatomic) BOOL reconnectInProgress;
@property (atomic) NSUInteger activeStreamGeneration;

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
@property (nonatomic, strong) NSMutableArray<NSString *> *logOverlayDisplayLines;
@property (nonatomic, strong) NSMutableArray<NSString *> *logOverlayPausedRawLines;
@property (nonatomic, copy) NSString *logOverlayLastFoldKey;
@property (nonatomic, copy) NSString *logOverlayLastFoldBaseLine;
@property (nonatomic) NSUInteger logOverlayLastFoldCount;
@property (nonatomic) NSRange logOverlayLastRenderedRange;
@property (nonatomic) BOOL logOverlayHasLastRenderedRange;
@property (nonatomic) BOOL logOverlayPauseUpdates;
@property (nonatomic) BOOL logOverlayAutoScrollEnabled;
@property (nonatomic) NSUInteger logOverlaySoftMaxLines;
@property (nonatomic) NSUInteger logOverlayTrimToLines;

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
@property (nonatomic, strong) NSButton *timeoutRecommendedProfileButton;
@property (nonatomic, strong) NSButton *timeoutViewLogsButton;
@property (nonatomic, strong) NSButton *timeoutCopyLogsButton;
@property (nonatomic, strong) StreamRiskAssessment *currentStreamRiskAssessment;

@property (nonatomic) NSInteger connectWatchdogToken;
@property (nonatomic) uint64_t connectWatchdogStartMs;
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

@property (nonatomic, strong) NSTrackingArea *mouseTrackingArea;
@property (nonatomic) BOOL isMouseInsideView;

@property (nonatomic, strong) id activeSpaceDidChangeObserver;
@property (nonatomic) BOOL spaceTransitionInProgress;

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
                if ([weakSelf.view.window isKeyWindow]) {
                    Log(LOG_I, @"[diag] Window became key; rearming input capture (fullscreen=%d style=%llu level=%ld)",
                        [weakSelf isWindowFullscreen] ? 1 : 0,
                        (unsigned long long)weakSelf.view.window.styleMask,
                        (long)weakSelf.view.window.level);
                    [weakSelf uncaptureMouse];
                    [weakSelf captureMouse];
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

    self.activeSpaceDidChangeObserver = [[[NSWorkspace sharedWorkspace] notificationCenter]
        addObserverForName:NSWorkspaceActiveSpaceDidChangeNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        __strong typeof(self) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        if (strongSelf.stopStreamInProgress || strongSelf.reconnectInProgress) {
            return;
        }
        strongSelf.spaceTransitionInProgress = YES;
        [strongSelf uncaptureMouse];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!strongSelf) {
                return;
            }
            strongSelf.spaceTransitionInProgress = NO;
            if (strongSelf.stopStreamInProgress || strongSelf.reconnectInProgress) {
                return;
            }
            if ([strongSelf isWindowInCurrentSpace] && strongSelf.view.window.isKeyWindow) {
                [strongSelf captureMouse];
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
    [self uncaptureMouse];

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
    [self.view.window makeFirstResponder:self];

    [self installLocalKeyMonitorIfNeeded];
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
    [[NSNotificationCenter defaultCenter] removeObserver:self.windowDidExitFullScreenNotification];
    [[NSNotificationCenter defaultCenter] removeObserver:self.windowDidEnterFullScreenNotification];
    [[NSNotificationCenter defaultCenter] removeObserver:self.windowDidResignKeyNotification];
    [[NSNotificationCenter defaultCenter] removeObserver:self.windowDidBecomeKeyNotification];
    [[NSNotificationCenter defaultCenter] removeObserver:self.windowWillCloseNotification];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:HIDMouseModeToggledNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:HIDGamepadQuitNotification object:nil];

    if (self.activeSpaceDidChangeObserver) {
        [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self.activeSpaceDidChangeObserver];
        self.activeSpaceDidChangeObserver = nil;
    }

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

    if (self.streamHealthTimer) {
        [self.streamHealthTimer invalidate];
        self.streamHealthTimer = nil;
    }

    if (self.localKeyDownMonitor) {
        [NSEvent removeMonitor:self.localKeyDownMonitor];
        self.localKeyDownMonitor = nil;
    }

    if (self.mouseTrackingArea) {
        [self.view removeTrackingArea:self.mouseTrackingArea];
        self.mouseTrackingArea = nil;
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
            strongSelf.pendingOptionUncaptureToken += 1;
            if ([strongSelf isWindowBorderlessMode]) {
                [strongSelf switchToWindowedMode:nil];
            } else {
                [strongSelf switchToBorderlessMode:nil];
            }
            return nil;
        }

        // Ctrl+Option+C opens the control center in borderless/fullscreen mode
        if (event.keyCode == kVK_ANSI_C && mods == (NSEventModifierFlagControl | NSEventModifierFlagOption)) {
            if ([strongSelf isWindowBorderlessMode] || [strongSelf isWindowFullscreen]) {
                strongSelf.pendingOptionUncaptureToken += 1;
                [strongSelf presentStreamMenuFromView:strongSelf.view];
                return nil;
            }
        }

        return event;
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
    self.isMouseInsideView = YES;
    // In remote desktop mode, re-enable input when mouse enters the view
    if (self.isRemoteDesktopMode && !self.isMouseCaptured) {
        self.hidSupport.shouldSendInputEvents = YES;
    }
}

- (void)mouseExited:(NSEvent *)event {
    self.isMouseInsideView = NO;
    // In remote desktop mode, disable input when mouse leaves the view
    if (self.isRemoteDesktopMode && !self.isMouseCaptured) {
        self.hidSupport.shouldSendInputEvents = NO;
    }
}

- (void)flagsChanged:(NSEvent *)event {
    [self.hidSupport flagsChanged:event];

    if ((event.keyCode == kVK_Option || event.keyCode == kVK_RightOption) &&
        (event.modifierFlags & NSEventModifierFlagOption)) {
        NSEventModifierFlags relevantMods = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
        BOOL hasControl = (relevantMods & NSEventModifierFlagControl) != 0;

        if (hasControl) {
            NSUInteger token = ++self.pendingOptionUncaptureToken;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (token != self.pendingOptionUncaptureToken) {
                    return;
                }

                NSEventModifierFlags currentMods = [NSEvent modifierFlags] & NSEventModifierFlagDeviceIndependentFlagsMask;
                BOOL optionStillHeld = (currentMods & NSEventModifierFlagOption) != 0;
                BOOL controlStillHeld = (currentMods & NSEventModifierFlagControl) != 0;
                if (!optionStillHeld || !controlStillHeld) {
                    return;
                }

                self.lastOptionUncaptureAtMs = [self nowMs];
                [self.hidSupport releaseAllModifierKeys];
                [self suppressConnectionWarningsForSeconds:2.0 reason:@"option-uncapture"];
                [self uncaptureMouse];
            });
            return;
        }

        self.pendingOptionUncaptureToken += 1;
        self.lastOptionUncaptureAtMs = [self nowMs];
        [self.hidSupport releaseAllModifierKeys];
        // User is intentionally detaching local input/cursor; suppress transient connection warnings.
        [self suppressConnectionWarningsForSeconds:2.0 reason:@"option-uncapture"];
        [self uncaptureMouse];
    } else if (!(event.modifierFlags & NSEventModifierFlagOption)) {
        self.pendingOptionUncaptureToken += 1;
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
        || (event.keyCode == kVK_ANSI_W && eventModifierFlags == NSEventModifierFlagCommand)
        ) {
        [self.hidSupport releaseAllModifierKeys];
        return NO;
    }

    if (event.keyCode == kVK_ANSI_W && eventModifierFlags == (NSEventModifierFlagOption | NSEventModifierFlagControl)) {
        self.pendingOptionUncaptureToken += 1;
        [self.hidSupport releaseAllModifierKeys];
        [self requestStreamCloseWithSource:@"keyboard-ctrl-option-w"];
        return YES;
    }
    
    if (event.keyCode == kVK_ANSI_S && eventModifierFlags == (NSEventModifierFlagControl | NSEventModifierFlagOption)) {
        self.pendingOptionUncaptureToken += 1;
        [self toggleOverlay];
        return YES;
    }

    if (event.keyCode == kVK_ANSI_M && eventModifierFlags == (NSEventModifierFlagControl | NSEventModifierFlagOption)) {
        self.pendingOptionUncaptureToken += 1;
        [self toggleMouseMode];
        return YES;
    }

    // Ctrl+Alt+G: toggle fullscreen floating control ball
    if (event.keyCode == kVK_ANSI_G && eventModifierFlags == (NSEventModifierFlagControl | NSEventModifierFlagOption)) {
        self.pendingOptionUncaptureToken += 1;
        [self toggleFullscreenControlBallVisibility];
        return YES;
    }
    
    [self.hidSupport keyDown:event];
    [self.hidSupport keyUp:event];
    
    return YES;
}


#pragma mark - Actions


- (IBAction)performClose:(id)sender {
    Log(LOG_I, @"[diag] performClose invoked: sender=%@ event=%@",
        sender ? NSStringFromClass([sender class]) : @"(null)",
        MLDisconnectEventSummary(NSApp.currentEvent));
    [self uncaptureMouse];
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
        if (!w) {
            return;
        }

        Log(LOG_I, @"performCloseStreamWindow: immediate close while reconnecting/stopping (style=%llu level=%ld)",
            (unsigned long long)w.styleMask,
            (long)w.level);

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

        [w close];
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
        if (!w) {
            return;
        }

        Log(LOG_I, @"performCloseStreamWindow: closing window (style=%llu level=%ld)", (unsigned long long)w.styleMask, (long)w.level);

        [strongSelf restorePresentationOptionsIfNeeded];

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

#pragma mark - Stream Menu Entrypoints

- (NSString *)fullscreenControlBallDefaultsKey {
    NSString *uuid = self.app.host.uuid ?: @"global";
    return [NSString stringWithFormat:@"%@-hideFullscreenControlBall", uuid];
}

- (void)startControlCenterTimerIfNeeded {
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
    return @"控制中心";
}

- (void)updateControlCenterStatus {
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
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateStreamMenuEntrypointsVisibility];
        });
        return;
    }
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

    // 一级顶部：鼠标模式切换
    NSDictionary *prefs = [SettingsClass getSettingsFor:self.app.host.uuid];
    NSString *mouseMode = [SettingsClass mouseModeFor:self.app.host.uuid];
    BOOL isRemoteMode = [mouseMode isEqualToString:@"remote"];

    NSMenuItem *mouseModeItem = [[NSMenuItem alloc] initWithTitle:isRemoteMode ? @"远控模式" : @"游戏模式"
                                                           action:@selector(toggleMouseModeFromMenu:)
                                                    keyEquivalent:@"m"];
    mouseModeItem.keyEquivalentModifierMask = NSEventModifierFlagControl | NSEventModifierFlagOption;
    mouseModeItem.target = self;
    setSymbol(mouseModeItem, isRemoteMode ? @"desktopcomputer" : @"gamecontroller");
    [self.streamMenu addItem:mouseModeItem];

    // 一级顶部：重连
    NSMenuItem *reconnectItem = [[NSMenuItem alloc] initWithTitle:@"重连" action:@selector(reconnectFromMenu:) keyEquivalent:@""];
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
    toggleBallItem.target = self;
    toggleBallItem.state = self.hideFullscreenControlBall ? NSControlStateValueOff : NSControlStateValueOn;
    setSymbol(toggleBallItem, @"dot.circle.and.hand.point.up.left.fill");
    [windowMenu addItem:toggleBallItem];

    [windowMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *detailsItem = [[NSMenuItem alloc] initWithTitle:@"连接详情" action:@selector(toggleOverlay) keyEquivalent:@"s"];
    detailsItem.keyEquivalentModifierMask = NSEventModifierFlagControl | NSEventModifierFlagOption;
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
    NSMenuItem *disconnectItem = [[NSMenuItem alloc] initWithTitle:@"退出串流" action:@selector(performCloseStreamWindow:) keyEquivalent:@"w"];
    disconnectItem.keyEquivalentModifierMask = NSEventModifierFlagCommand;
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

- (void)toggleMouseMode {
    NSString *currentMode = [SettingsClass mouseModeFor:self.app.host.uuid];
    NSString *newMode = [currentMode isEqualToString:@"game"] ? @"remote" : @"game";

    [SettingsClass setMouseMode:newMode for:self.app.host.uuid];

    // 重新应用鼠标状态
    [self uncaptureMouse];
    [self captureMouse];

    // 显示通知
    NSString *message = [newMode isEqualToString:@"remote"]
        ? [NSString stringWithFormat:@"🖥️ %@", MLString(@"Remote Desktop Mode", @"Notification")]
        : [NSString stringWithFormat:@"🎮 %@", MLString(@"Game Mode", @"Notification")];

    // 如果没有本地化字符串，使用硬编码回退
    if ([message containsString:@"Remote Desktop Mode"]) message = @"🖥️ 远控模式";
    if ([message containsString:@"Game Mode"]) message = @"🎮 游戏模式";

    [self showNotification:message];

    // 重建菜单更新状态
    [self rebuildStreamMenu];
}

- (void)toggleMouseModeFromMenu:(id)sender {
    [self toggleMouseMode];
}

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
        Log(LOG_I, @"[diag] captureMouse skipped: space transition in progress");
        return;
    }

    NSWindow *window = self.view.window;
    if (!window) {
        Log(LOG_I, @"[diag] captureMouse skipped: window is nil");
        return;
    }
    if (![self isWindowInCurrentSpace]) {
        Log(LOG_I, @"[diag] captureMouse skipped: window not in current space");
        return;
    }
    NSScreen *screen = window.screen;
    if (!screen) {
        Log(LOG_I, @"[diag] captureMouse skipped: screen is nil");
        return;
    }

    NSDictionary* prefs = [SettingsClass getSettingsFor:self.app.host.uuid];
    BOOL showLocalCursor = prefs ? [prefs[@"showLocalCursor"] boolValue] : NO;
    NSString *mouseMode = [SettingsClass mouseModeFor:self.app.host.uuid];
    self.isRemoteDesktopMode = [mouseMode isEqualToString:@"remote"];

    // Hide system cursor in both game mode and remote desktop mode (unless showLocalCursor is enabled)
    if (!showLocalCursor) {
        if (self.cursorHiddenCounter == 0) {
            [NSCursor hide];
            self.cursorHiddenCounter++;
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
    self.view.window.acceptsMouseMovedEvents = YES;

    self.isMouseCaptured = YES;
    Log(LOG_I, @"[diag] captureMouse armed: key=%d fullscreen=%d remoteDesktop=%d inputCtx=%p",
        window.isKeyWindow ? 1 : 0,
        [self isWindowFullscreen] ? 1 : 0,
        self.isRemoteDesktopMode ? 1 : 0,
        self.hidSupport.inputContext);
}

- (void)uncaptureMouse {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self uncaptureMouse];
        });
        return;
    }
    if (!self.isMouseCaptured && self.cursorHiddenCounter == 0 && !self.hidSupport.shouldSendInputEvents) {
        return;
    }

    if (!self.view.window) {
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
    streamConfig.allowHevc = streamSettings.useHevc;
    streamConfig.enableHdr = streamSettings.useHevc && VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) ? streamSettings.enableHdr : NO;

    NSString *codecName = streamConfig.allowHevc ? @"H.265" : @"H.264";
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
    if ((self.app.host.serverCodecModeSupport & SCM_MASK_AV1) != 0) {
        Log(LOG_I, @"[diag] Server advertises AV1, but macOS client UI does not expose AV1 selection yet");
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
    self.logOverlayDisplayLines = [[NSMutableArray alloc] init];
    self.logOverlayPausedRawLines = [[NSMutableArray alloc] init];
    self.logOverlayLastFoldKey = nil;
    self.logOverlayLastFoldBaseLine = nil;
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

- (NSDictionary<NSString *, NSString *> *)compactPresentationForLogLine:(NSString *)rawLine {
    NSString *line = [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (line.length == 0) {
        return @{ @"key": @"empty", @"line": @"" };
    }

    NSString *errorCode = [self errorCodeFromLogLine:line];

    if ([line localizedCaseInsensitiveContainsString:@"Internal inconsistency in menus"]) {
        return @{
            @"key": @"noise.appkit.menu",
            @"line": @"<WARN> [系统噪音] AppKit 菜单一致性日志（已折叠）"
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
            @"line": [NSString stringWithFormat:@"<INFO> [发现] %@（%@，已折叠）", host, state]
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
            @"line": [NSString stringWithFormat:@"<INFO> [发现] 地址解析 %@（已折叠）", host]
        };
    }

    if ([line localizedCaseInsensitiveContainsString:@"[curated]"]
        && [line localizedCaseInsensitiveContainsString:@"内重复"]) {
        return @{
            @"key": @"noise.curated.repeat",
            @"line": @"<WARN> [日志] 重复抑制摘要（已折叠）"
        };
    }

    if ([line localizedCaseInsensitiveContainsString:@"Request failed with error"]) {
        NSString *code = errorCode ?: @"unknown";
        return @{
            @"key": [NSString stringWithFormat:@"noise.net.%@", code],
            @"line": [NSString stringWithFormat:@"<WARN> [网络] 请求失败 %@（自动回退，已折叠）", code]
        };
    }

    if ([line localizedCaseInsensitiveContainsString:@"NSURLErrorDomain"]) {
        NSString *code = errorCode ?: @"unknown";
        return @{
            @"key": [NSString stringWithFormat:@"noise.net.%@", code],
            @"line": [NSString stringWithFormat:@"<WARN> [网络] NSURLError %@（已折叠）", code]
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
            @"line": [NSString stringWithFormat:@"<WARN> [网络栈] 连接层噪音 %@（已折叠）", code]
        };
    }

    if ([line localizedCaseInsensitiveContainsString:@"Recovered 1 audio data shards from block"]) {
        return @{
            @"key": @"stream.audio.fec.recovered",
            @"line": @"<INFO> [音频] FEC 分片恢复（已折叠）"
        };
    }

    if ([line localizedCaseInsensitiveContainsString:@"Recovered 1 video data shards from frame"]) {
        return @{
            @"key": @"stream.video.fec.recovered",
            @"line": @"<INFO> [视频] FEC 分片恢复（已折叠）"
        };
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
    NSDictionary<NSString *, NSString *> *presentation = [self compactPresentationForLogLine:rawLine];
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
    NSButton *clearBtn = [self.logOverlayContainer viewWithTag:1006];
    NSTextField *statusLabel = [self.logOverlayContainer viewWithTag:1005];

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
        clearBtn.enabled = (self.logOverlayDisplayLines.count > 0 || self.logOverlayPausedRawLines.count > 0);
    }
    if (statusLabel) {
        if (self.logOverlayPauseUpdates && self.logOverlayPausedRawLines.count > 0) {
            statusLabel.stringValue = [NSString stringWithFormat:@"显示 %lu 行 | 暂停中，待处理 %lu 条",
                                       (unsigned long)self.logOverlayDisplayLines.count,
                                       (unsigned long)self.logOverlayPausedRawLines.count];
        } else {
            statusLabel.stringValue = [NSString stringWithFormat:@"显示 %lu 行",
                                       (unsigned long)self.logOverlayDisplayLines.count];
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

    NSButton *copyBtn = [NSButton buttonWithTitle:@"复制精简日志" target:self action:@selector(handleLogOverlayCopyCompact:)];
    copyBtn.bezelStyle = NSBezelStyleRounded;
    copyBtn.controlSize = NSControlSizeSmall;
    copyBtn.tag = 1004;
    [self.logOverlayContainer addSubview:copyBtn];

    NSButton *clearBtn = [NSButton buttonWithTitle:@"清空显示" target:self action:@selector(handleLogOverlayClearFromNow:)];
    clearBtn.bezelStyle = NSBezelStyleRounded;
    clearBtn.controlSize = NSControlSizeSmall;
    clearBtn.tag = 1006;
    [self.logOverlayContainer addSubview:clearBtn];

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
        [self appendRawLinesToOverlayState:lines];
        [self scrollLogOverlayToLatest];
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
    self.logOverlayDisplayLines = nil;
    self.logOverlayPausedRawLines = nil;
    self.logOverlayLastFoldKey = nil;
    self.logOverlayLastFoldBaseLine = nil;
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
        [self appendRawLinesToOverlayState:pending];
        [self scrollLogOverlayToLatest];
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

    [self appendRawLinesToOverlayState:@[ line ]];
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
            __strong typeof(self) strongSelf = weakSelf;
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
            }
        });
    }
}

- (void)connectionStarted {
    Connection *callbackConn = [Connection currentConnection];
    void *callbackInputContext = callbackConn ? [callbackConn inputStreamContext] : NULL;
    dispatch_async(dispatch_get_main_queue(), ^{
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
    Log(LOG_I, @"Connection terminated: %ld (0x%08x)", (long)errorCode, (unsigned int)errorCode);
    [self stopStreamHealthDiagnostics];
    self.streamHealthConnectionStartedMs = 0;
    [self logStreamHealthSummaryWithReason:[NSString stringWithFormat:@"connection-terminated:%d", errorCode]];

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
    self.connectWatchdogToken += 1;
    [self stopStreamHealthDiagnostics];
    self.streamHealthConnectionStartedMs = 0;
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
    self.streamHealthConnectionStartedMs = 0;
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
        CGFloat width = MIN(860.0, self.view.bounds.size.width - padding * 2);
        CGFloat height = MIN(520.0, self.view.bounds.size.height - padding * 2);
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
        NSTextField *statusLabel = [self.logOverlayContainer viewWithTag:1005];

        CGFloat topY = height - 38.0;
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
            CGFloat statusX = x;
            CGFloat statusW = MAX(120.0, width - statusX - closeW - 24.0);
            statusLabel.frame = NSMakeRect(statusX, topY + 4.0, statusW, 16.0);
        }

        CGFloat topMargin = 46.0;
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
