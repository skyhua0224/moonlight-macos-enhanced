//
//  StreamViewController_Internal.h
//  Moonlight for macOS
//

#pragma once

#import "StreamViewController.h"
#import "StreamingSessionManager.h"
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

#import <IOKit/pwr_mgt/IOPMLib.h>
#import <Carbon/Carbon.h>
#include <arpa/inet.h>

#define MLString(key, comment) [[LanguageManager shared] localize:key]

#include "Limelight.h"
#include "Limelight-internal.h"

@import VideoToolbox;

typedef NS_ENUM(NSInteger, PendingWindowMode) {
    PendingWindowModeNone,
    PendingWindowModeWindowed,
    PendingWindowModeBorderless
};

typedef NS_ENUM(NSInteger, MLFreeMouseExitEdge) {
    MLFreeMouseExitEdgeNone,
    MLFreeMouseExitEdgeLeft,
    MLFreeMouseExitEdgeRight,
    MLFreeMouseExitEdgeTop,
    MLFreeMouseExitEdgeBottom,
};

static NSString * const MLShortcutActionReleaseMouseCapture = @"releaseMouseCapture";
static NSString * const MLShortcutActionTogglePerformanceOverlay = @"togglePerformanceOverlay";
static NSString * const MLShortcutActionToggleMouseMode = @"toggleMouseMode";
static NSString * const MLShortcutActionToggleFullscreenControlBall = @"toggleFullscreenControlBall";
static NSString * const MLShortcutActionDisconnectStream = @"disconnectStream";
static NSString * const MLShortcutActionCloseAndQuitApp = @"closeAndQuitApp";
static NSString * const MLShortcutActionOpenControlCenter = @"openControlCenter";
static NSString * const MLShortcutActionToggleBorderlessWindowed = @"toggleBorderlessWindowed";

static CGFloat const MLEdgeMenuButtonWidth = 78.0;
static CGFloat const MLEdgeMenuButtonHeight = 78.0;
static CGFloat const MLEdgeMenuButtonInsetY = 88.0;
static CGFloat const MLEdgeMenuButtonVisiblePeek = 30.0;
static CGFloat const MLEdgeMenuInteractionOutwardPadding = 18.0;
static CGFloat const MLEdgeMenuInteractionInwardPadding = 26.0;
static CGFloat const MLEdgeMenuInteractionVerticalPadding = 28.0;
static NSTimeInterval const MLEdgeMenuAutoCollapseDelay = 0.82;
static CGFloat const MLFreeMouseReentryDelayMs = 140.0;
static CGFloat const MLFreeMouseReentryInset = 32.0;
static BOOL const MLUseOnScreenControlCenterEntrypoints = YES;
static BOOL const MLUseFloatingControlOrb = YES;

static inline NSEventModifierFlags MLRelevantShortcutModifiers(NSEventModifierFlags flags) {
    return flags & (NSEventModifierFlagShift | NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagCommand | NSEventModifierFlagFunction);
}

static inline BOOL MLIsPrivateOrLocalIPv4String(NSString *ip) {
    struct in_addr addr;
    if (inet_pton(AF_INET, ip.UTF8String, &addr) != 1) {
        return NO;
    }

    uint32_t host = ntohl(addr.s_addr);
    if ((host & 0xFF000000) == 0x0A000000) return YES;
    if ((host & 0xFFF00000) == 0xAC100000) return YES;
    if ((host & 0xFFFF0000) == 0xC0A80000) return YES;
    if ((host & 0xFFFF0000) == 0xA9FE0000) return YES;
    if ((host & 0xFF000000) == 0x7F000000) return YES;
    return NO;
}

static inline BOOL MLIsPrivateOrLocalIPv6String(NSString *ip) {
    struct in6_addr addr6;
    if (inet_pton(AF_INET6, ip.UTF8String, &addr6) != 1) {
        return NO;
    }

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

    if (addr6.s6_addr[0] == 0xFE && (addr6.s6_addr[1] & 0xC0) == 0x80) {
        return YES;
    }

    if ((addr6.s6_addr[0] & 0xFE) == 0xFC) {
        return YES;
    }

    return NO;
}

static inline BOOL MLIsIpLiteralString(NSString *host) {
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

static inline BOOL MLShouldTreatAsKnownLocalHost(NSString *host) {
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

static inline NSString *MLDisconnectEventSummary(NSEvent *event) {
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

static inline CGFloat MLMeasureMultilineTextHeight(NSString *text, NSFont *font, CGFloat width) {
    if (text.length == 0 || font == nil || width <= 0.0) {
        return 0.0;
    }

    NSDictionary<NSAttributedStringKey, id> *attributes = @{ NSFontAttributeName: font };
    NSRect rect = [text boundingRectWithSize:NSMakeSize(width, CGFLOAT_MAX)
                                     options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                  attributes:attributes];
    return ceil(NSHeight(rect));
}

static inline CGFloat MLOverlayButtonWidth(NSButton *button, CGFloat minWidth, CGFloat maxWidth) {
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

static inline BOOL MLGetUsableRttInfo(PML_CONTROL_STREAM_CONTEXT controlCtx, uint32_t *rtt, uint32_t *rttVar) {
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

static inline NSString *MLRttLogSummary(PML_CONTROL_STREAM_CONTEXT controlCtx) {
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

@interface MLEdgeMenuHandleView : NSView
@property (nonatomic, strong, readonly) NSImageView *iconView;
@property (nonatomic, copy) void (^activationHandler)(NSEvent *event);
@property (nonatomic, copy) void (^dragHandler)(NSGestureRecognizerState state, NSPoint translation);
@property (nonatomic, copy) void (^hoverHandler)(BOOL hovering);
@property (nonatomic) BOOL activeAppearance;
@property (nonatomic) BOOL compactAppearance;
@property (nonatomic) MLFreeMouseExitEdge dockEdge;
@end

@interface MLEdgeMenuPanel : NSPanel
@end

@interface StreamViewController ()

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
@property (nonatomic, strong) id appDidBecomeActiveObserver;
@property (nonatomic, strong) id appDidResignActiveObserver;
@property (nonatomic) int cursorHiddenCounter;
@property (nonatomic) int cgCursorHiddenCounter;

@property (nonatomic) IOPMAssertionID powerAssertionID;

@property (nonatomic, strong) NSVisualEffectView *overlayContainer;
@property (nonatomic, strong) NSTextField *overlayLabel;
@property (nonatomic, strong) NSTimer *statsTimer;
@property (nonatomic, strong) NSTimer *streamHealthTimer;
@property (nonatomic, strong) NSTimer *inputDiagnosticsTimer;
@property (nonatomic) BOOL inputDiagnosticsFinalized;
@property (nonatomic) BOOL inputDiagnosticsDetailActiveForStream;
@property (nonatomic) NSUInteger inputDiagnosticsMouseMoveEvents;
@property (nonatomic) NSUInteger inputDiagnosticsNonZeroRelativeEvents;
@property (nonatomic) NSUInteger inputDiagnosticsRelativeDispatches;
@property (nonatomic) NSUInteger inputDiagnosticsAbsoluteDispatches;
@property (nonatomic) NSUInteger inputDiagnosticsAbsoluteDuplicateSkips;
@property (nonatomic) NSUInteger inputDiagnosticsCoreHIDRawEvents;
@property (nonatomic) NSUInteger inputDiagnosticsCoreHIDDispatches;
@property (nonatomic) NSUInteger inputDiagnosticsSuppressedRelativeEvents;
@property (nonatomic) NSInteger inputDiagnosticsRawRelativeDeltaX;
@property (nonatomic) NSInteger inputDiagnosticsRawRelativeDeltaY;
@property (nonatomic) NSInteger inputDiagnosticsSentRelativeDeltaX;
@property (nonatomic) NSInteger inputDiagnosticsSentRelativeDeltaY;
@property (nonatomic) NSUInteger inputDiagnosticsCaptureArmedCount;
@property (nonatomic) NSUInteger inputDiagnosticsCaptureSkipCount;
@property (nonatomic) NSUInteger inputDiagnosticsRearmCount;
@property (nonatomic) NSUInteger inputDiagnosticsRearmSkippedCount;
@property (nonatomic) NSUInteger inputDiagnosticsRearmDeferredCount;
@property (nonatomic) NSUInteger inputDiagnosticsUncaptureCount;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *inputDiagnosticsCaptureSkipReasons;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *inputDiagnosticsRearmReasons;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *inputDiagnosticsRearmSkipReasons;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *inputDiagnosticsRearmDeferredReasons;
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
@property (nonatomic) MLFreeMouseExitEdge pendingFreeMouseReentryEdge;
@property (nonatomic) uint64_t pendingFreeMouseReentryAtMs;
@property (nonatomic) uint64_t suppressFreeMouseEdgeUncaptureUntilMs;
@property (nonatomic) BOOL pendingMouseExitedRecapture;
@property (atomic) BOOL stopStreamInProgress;

@property (nonatomic) BOOL shouldAttemptReconnect;
@property (nonatomic) NSInteger reconnectAttemptCount;
@property (nonatomic) BOOL reconnectInProgress;
@property (atomic) NSUInteger activeStreamGeneration;

@property (nonatomic) BOOL reconnectPreserveFullscreenStateValid;
@property (nonatomic) NSInteger reconnectPreservedWindowMode;

@property (nonatomic, strong) NSTitlebarAccessoryViewController *menuTitlebarAccessory;
@property (nonatomic, strong) NSButton *menuTitlebarButton;
@property (nonatomic, strong) MLEdgeMenuPanel *edgeMenuPanel;
@property (nonatomic, strong) MLEdgeMenuHandleView *edgeMenuButton;
@property (nonatomic, strong) NSPanGestureRecognizer *edgeMenuButtonPanGesture;
@property (nonatomic) NSPoint edgeMenuButtonPanStartOrigin;
@property (nonatomic) BOOL edgeMenuButtonSuppressNextClick;
@property (nonatomic) MLFreeMouseExitEdge edgeMenuDockEdge;
@property (nonatomic) CGFloat edgeMenuButtonEdgeRatio;
@property (nonatomic, strong) NSTrackingArea *edgeMenuButtonTrackingArea;
@property (nonatomic, strong) NSTimer *edgeMenuAutoCollapseTimer;
@property (nonatomic) BOOL edgeMenuButtonExpanded;
@property (nonatomic) BOOL edgeMenuPointerInside;
@property (nonatomic) BOOL edgeMenuTemporaryReleaseActive;
@property (nonatomic) BOOL edgeMenuDragging;
@property (nonatomic) BOOL edgeMenuMenuVisible;
@property (nonatomic) BOOL suppressNextRightMouseUp;

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
@property (nonatomic, strong) NSSearchField *logOverlaySearchField;
@property (nonatomic, strong) NSPopUpButton *logOverlayModePopup;
@property (nonatomic, strong) NSPopUpButton *logOverlayLevelPopup;
@property (nonatomic, strong) NSPopUpButton *logOverlayCategoryPopup;
@property (nonatomic, strong) id logDidAppendObserver;
@property (nonatomic, strong) NSMutableArray<NSString *> *logOverlayAllRawLines;
@property (nonatomic, strong) NSMutableArray<NSString *> *logOverlayDisplayLines;
@property (nonatomic, strong) NSMutableArray<NSString *> *logOverlayPausedRawLines;
@property (nonatomic, copy) NSString *logOverlayLastFoldKey;
@property (nonatomic, copy) NSString *logOverlayLastFoldBaseLine;
@property (nonatomic, copy) NSString *logOverlayModeKey;
@property (nonatomic, copy) NSString *logOverlayMinimumLevelKey;
@property (nonatomic, copy) NSString *logOverlaySearchText;
@property (nonatomic, copy) NSString *logOverlayCategoryFilterKey;
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
@property (nonatomic, strong) id mouseSettingsDidChangeObserver;
@property (nonatomic, strong) id hostLatencyUpdatedObserver;

@property (nonatomic) PendingWindowMode pendingWindowMode;

@property (nonatomic) BOOL menuTitlebarAccessoryInstalled;

@property (nonatomic, strong) id localKeyDownMonitor;
@property (nonatomic, strong) id localMouseClickMonitor;
@property (nonatomic, strong) id globalMouseMovedMonitor;

@property (nonatomic) BOOL savedPresentationOptionsValid;
@property (nonatomic) NSApplicationPresentationOptions savedPresentationOptions;
@property (nonatomic) BOOL savedStreamWindowChromeValid;
@property (nonatomic, strong) NSToolbar *savedStreamWindowToolbar;
@property (nonatomic) NSWindowTitleVisibility savedStreamWindowTitleVisibility;
@property (nonatomic) BOOL savedStreamWindowTitlebarAppearsTransparent;
@property (nonatomic) BOOL savedStreamWindowMovableByWindowBackground;
@property (nonatomic) BOOL savedStreamWindowFullSizeContentView;

@property (nonatomic) BOOL savedContentAspectRatioValid;
@property (nonatomic) NSSize savedContentAspectRatio;

@property (nonatomic, strong) NSTrackingArea *mouseTrackingArea;
@property (nonatomic) BOOL isMouseInsideView;
@property (nonatomic) BOOL globalInactivePointerInsideStreamView;

@property (nonatomic, strong) id activeSpaceDidChangeObserver;
@property (nonatomic) BOOL spaceTransitionInProgress;
@property (nonatomic) BOOL fullscreenTransitionInProgress;
@property (nonatomic) BOOL streamMenuEntrypointsUpdateScheduled;
@property (nonatomic) BOOL pendingCloseWindowAfterFullscreenExit;
@property (nonatomic) NSUInteger pendingMouseCaptureRetryToken;
@property (nonatomic) BOOL pendingMouseUncaptureAfterButtonsReleased;
@property (nonatomic) BOOL pendingMouseUncaptureRecheckScheduled;
@property (nonatomic) BOOL pendingHybridRemoteCursorSync;
@property (nonatomic) BOOL hasCoreHIDFreeMouseLastTruthPoint;
@property (nonatomic) NSPoint coreHIDFreeMouseLastTruthPoint;
@property (nonatomic, copy) NSString *pendingMouseUncaptureDiagnosticCode;
@property (nonatomic, copy) NSString *pendingMouseUncaptureDiagnosticReason;
@property (nonatomic) uint64_t lastMouseClickDiagnosticsAtMs;
@property (nonatomic, copy) NSString *lastMouseClickDiagnosticsSummary;
@property (nonatomic, copy) NSString *lastMouseClickPhase;
@property (nonatomic) NSPoint lastMouseClickViewPoint;
@property (nonatomic) BOOL lastMouseClickInsideView;
- (BOOL)useSystemControllerDriver;
- (void)viewDidLoad;
- (void)handleSessionDisconnectRequest:(NSNotification *)note;
- (void)beginStopStreamIfNeededWithReason:(NSString *)reason;
- (void)beginStopStreamIfNeededWithReason:(NSString *)reason completion:(void (^)(void))completion;
- (void)tearDownStreamLifecycleObserversAndTimers;
- (void)broadcastHostOnlineStateForExit;
- (void)viewDidAppear;
- (void)updateWindowSubtitle;
- (void)dealloc;
- (BOOL)isWindowBorderlessMode;
- (StreamViewMac *)streamView;
- (void)prepareForStreaming;
- (void)stageStarting:(const char *)stageName;
- (void)stageComplete:(const char *)stageName;
- (void)connectionStarted;
- (void)connectionTerminated:(int)errorCode;
- (void)stageFailed:(const char *)stageName withError:(int)errorCode;
- (void)launchFailed:(NSString *)message;
- (void)rumble:(unsigned short)controllerNumber lowFreqMotor:(unsigned short)lowFreqMotor highFreqMotor:(unsigned short)highFreqMotor;
- (void)connectionStatusUpdate:(int)status;

@end

@interface StreamViewController (MouseCaptureInternal)
- (void)prepareCoreHIDFreeMouseStateForFocusRegainWithReason:(NSString *)reason;
@end
@interface StreamViewController (MenuUI) <MLStreamScopedCallbackOwner>
- (NSString *)mouseModeDisplayNameForMode:(NSString *)mode;
- (NSString *)mouseModeHintForMode:(NSString *)mode;
- (NSString *)shortcutDisplayStringForAction:(NSString *)action;
- (NSString *)releaseMouseHintText;
- (NSString *)openControlCenterHintText;
- (void)updateControlCenterEntrypointHints;
- (NSView *)preferredControlCenterSourceView;
- (void)presentControlCenterFromShortcut;
- (StreamShortcut *)streamShortcutForAction:(NSString *)action;
- (BOOL)event:(NSEvent *)event matchesShortcut:(StreamShortcut *)shortcut;
- (NSArray<NSMenuItem *> *)menuItemsWithAction:(SEL)action inMenu:(NSMenu *)menu;
- (void)applyShortcut:(StreamShortcut *)shortcut toMenuItem:(NSMenuItem *)item;
- (void)updateConfiguredShortcutMenus;
- (BOOL)windowSupportsTitlebarAccessoryControllers:(NSWindow *)window;
- (BOOL)windowAllowsTitlebarAccessories:(NSWindow *)window;
- (BOOL)isMenuTitlebarAccessoryInstalledInWindow:(NSWindow *)window;
- (void)buildMenuTitlebarAccessoryIfNeeded;
- (void)removeMenuTitlebarAccessoryFromWindowIfNeeded;
- (void)ensureMenuTitlebarAccessoryInstalledIfNeeded;
- (void)handleTitlebarControlCenterPressed:(id)sender;
- (NSString *)fullscreenControlBallDefaultsKey;
- (NSString *)fullscreenControlBallDockSideDefaultsKey;
- (NSString *)fullscreenControlBallVerticalRatioDefaultsKey;
- (MLFreeMouseExitEdge)defaultEdgeMenuDockEdge;
- (MLFreeMouseExitEdge)edgeMenuDockEdgeFromStoredValue:(NSString *)value;
- (NSString *)storedValueForEdgeMenuDockEdge:(MLFreeMouseExitEdge)edge;
- (BOOL)edgeMenuDockEdgeUsesVerticalAxis;
- (CGFloat)resolvedEdgeMenuCoordinateInRect:(NSRect)rect;
- (NSRect)edgeMenuFrameInRect:(NSRect)rect expanded:(BOOL)expanded;
- (void)persistFullscreenControlBallPlacement;
- (void)resetEdgeMenuPlacementForNewStreamSession;
- (void)hideEdgeMenuForInactiveSpaceIfNeeded;
- (void)attachEdgeMenuPanelToWindowIfNeeded;
- (NSRect)edgeMenuAnchorRectInScreen;
- (NSRect)collapsedFrameForEdgeMenuPanelInScreenRect:(NSRect)screenRect;
- (NSRect)expandedFrameForEdgeMenuPanelInScreenRect:(NSRect)screenRect;
- (NSRect)frameForCurrentEdgeMenuPanelStateInScreenRect:(NSRect)screenRect;
- (BOOL)edgeMenuMatchesExitEdge:(MLFreeMouseExitEdge)exitEdge;
- (NSRect)collapsedFrameForEdgeMenuButtonInBounds:(NSRect)bounds;
- (NSRect)expandedFrameForEdgeMenuButtonInBounds:(NSRect)bounds;
- (NSRect)edgeMenuInteractionRectInBounds:(NSRect)bounds;
- (BOOL)isPointInsideEdgeMenuInteractionRect:(NSPoint)point;
- (void)updateEdgeMenuPointerInsideForPoint:(NSPoint)point;
- (NSRect)frameForEdgeMenuButtonInBounds:(NSRect)bounds;
- (void)cancelEdgeMenuAutoCollapse;
- (BOOL)edgeMenuShouldBeVisible;
- (void)updateEdgeMenuButtonTrackingArea;
- (void)setEdgeMenuButtonExpanded:(BOOL)expanded animated:(BOOL)animated;
- (void)deactivateEdgeMenuTemporaryReleaseAndRecaptureIfNeeded:(BOOL)shouldRecapture;
- (void)scheduleEdgeMenuAutoCollapse;
- (void)activateEdgeMenuDockForExitEdge:(MLFreeMouseExitEdge)exitEdge;
- (BOOL)handleEdgeMenuTemporaryReleaseForEvent:(NSEvent *)event;
- (void)updateEdgeMenuButtonAppearance;
- (void)handleEdgeMenuButtonDragWithState:(NSGestureRecognizerState)state translation:(NSPoint)translation;
- (void)startControlCenterTimerIfNeeded;
- (void)bringStreamControlsToFront;
- (NSString *)formatElapsed:(NSTimeInterval)seconds;
- (NSString *)currentPreferredAddressForStatus;
- (BOOL)isActiveStreamGeneration:(NSUInteger)generation;
- (NSString *)formattedLatencyTextForDisplay:(NSNumber *)latencyNumber;
- (NSString *)currentLatencyLogSummary;
- (NSInteger)currentLatencyMs;
- (NSString *)currentStreamHealthBadgeText;
- (void)updateControlCenterStatus;
- (void)installStreamMenuEntrypoints;
- (void)layoutStreamMenuEntrypointsIfNeeded;
- (void)requestStreamMenuEntrypointsVisibilityUpdate;
- (void)updateStreamMenuEntrypointsVisibility;
- (void)handleStreamMenuButtonPressed:(id)sender event:(NSEvent *)event;
- (void)presentStreamMenuFromView:(NSView *)sourceView;
- (void)presentStreamMenuFromView:(NSView *)sourceView event:(NSEvent *)event;
- (void)presentStreamMenuAtEvent:(NSEvent *)event;
- (void)rebuildStreamMenu;
- (void)handleToggleFullscreenFromMenu:(id)sender;
- (void)toggleLogOverlayFromMenu:(id)sender;
- (void)copyLogsFromMenu:(id)sender;
- (void)reconnectFromMenu:(id)sender;
- (void)selectConnectionMethodFromMenu:(NSMenuItem *)sender;
- (void)selectFollowHostFromMenu:(id)sender;
- (void)selectCustomResolutionFromMenu:(id)sender;
- (void)selectMatchDisplayFromMenu:(id)sender;
- (void)selectResolutionFromMenu:(NSMenuItem *)sender;
- (void)selectFrameRateFromMenu:(NSMenuItem *)sender;
- (void)selectCustomFpsFromMenu:(id)sender;
- (void)selectBitrateFromMenu:(NSMenuItem *)sender;
- (void)handleVolumeSliderChanged:(NSSlider *)sender;
- (void)updateBitrateSliderPosition:(NSInteger)currentKbps;
- (void)handleBitrateSliderChanged:(NSSlider *)sender;
- (void)handleBitrateInputChanged:(NSTextField *)sender;
- (void)handleBitrateApplyClicked:(NSButton *)sender;
- (void)toggleFullscreenControlBallFromMenu:(NSMenuItem *)sender;
- (void)toggleFullscreenControlBallVisibility;
- (void)toggleMouseMode;
- (void)toggleMouseModeFromMenu:(id)sender;
- (void)selectLockedMouseModeFromMenu:(id)sender;
- (void)selectFreeMouseModeFromMenu:(id)sender;
@end

@interface StreamViewController (MouseCapture) <KeyboardNotifiableDelegate>
- (BOOL)reasonAllowsImmediateCaptureInFreeMouseMode:(NSString *)reason;
- (BOOL)remoteDesktopCaptureReasonRequiresPointerInside:(NSString *)reason;
- (uint64_t)freeMouseEdgeUncaptureSuppressionDurationMsForReason:(NSString *)reason;
- (void)scheduleDeferredMouseCaptureRearmWithReason:(NSString *)reason delay:(NSTimeInterval)delay;
- (NSPoint)currentMouseLocationInViewCoordinates;
- (NSPoint)viewPointForMouseEvent:(NSEvent *)event;
- (NSPoint)screenPointForMouseEvent:(NSEvent *)event;
- (BOOL)isCurrentPointerInsideStreamView;
- (void)logMouseClickDiagnosticsForPhase:(NSString *)phase event:(NSEvent *)event;
- (void)logPointerContextForReason:(NSString *)reason;
- (void)logKeyLossDiagnosticsForStage:(NSString *)stage code:(NSString *)code reason:(NSString *)reason;
- (BOOL)shouldSuppressTransientKeyLossUncaptureForCode:(NSString *)code reason:(NSString *)reason;
- (void)scheduleTransientKeyLossRecoveryWithReason:(NSString *)reason;
- (NSPoint)resolvedAbsoluteSyncViewPointForMouseEvent:(NSEvent *)event
                                        clampToBounds:(BOOL)clampToBounds
                                               reason:(NSString *)reason;
- (void)reassertHiddenLocalCursorIfNeededWithReason:(NSString *)reason;
- (void)syncRemoteCursorToCurrentPointerClamped;
- (void)reconcileHybridFreeMouseAnchorToCurrentPointer;
- (void)syncRemoteCursorToMouseEvent:(NSEvent *)event clampToBounds:(BOOL)clampToBounds;
- (MLFreeMouseExitEdge)freeMouseExitEdgeForEvent:(NSEvent *)event;
- (BOOL)shouldUncaptureFreeMouseForEdgeEvent:(NSEvent *)event;
- (void)beginFreeMouseEdgeReentryForExitEdge:(MLFreeMouseExitEdge)exitEdge;
- (BOOL)shouldRecaptureFreeMouseAfterEdgeUncaptureForEvent:(NSEvent *)event;
- (BOOL)recaptureFreeMouseAfterEdgeUncaptureIfNeededForEvent:(NSEvent *)event;
- (BOOL)attemptPendingMouseExitedRecaptureIfNeededForEvent:(NSEvent *)event;
- (BOOL)captureFreeMouseIfNeededForEvent:(NSEvent *)event;
- (BOOL)hasReadyInputContext;
- (BOOL)canCaptureMouseNow;
- (NSString *)mouseCaptureBlockerReason;
- (void)ensureStreamWindowKeyIfPossible;
- (void)refreshMouseMovedAcceptanceState;
- (void)rearmMouseCaptureIfPossibleWithReason:(NSString *)reason;
- (void)applyMouseModeNamed:(NSString *)newMode showNotification:(BOOL)showNotification;
- (void)applyLiveMouseSettingsRefreshForSetting:(NSString *)setting;
- (void)installLocalKeyMonitorIfNeeded;
- (void)installLocalMouseClickMonitorIfNeeded;
- (void)installGlobalMouseMonitorIfNeeded;
- (void)installMouseTrackingArea;
- (void)mouseEntered:(NSEvent *)event;
- (void)mouseExited:(NSEvent *)event;
- (void)flagsChanged:(NSEvent *)event;
- (void)keyDown:(NSEvent *)event;
- (void)keyUp:(NSEvent *)event;
- (void)mouseDown:(NSEvent *)event;
- (void)mouseUp:(NSEvent *)event;
- (void)rightMouseDown:(NSEvent *)event;
- (void)rightMouseUp:(NSEvent *)event;
- (void)otherMouseDown:(NSEvent *)event;
- (void)otherMouseUp:(NSEvent *)event;
- (void)mouseMoved:(NSEvent *)event;
- (void)mouseDragged:(NSEvent *)event;
- (void)rightMouseDragged:(NSEvent *)event;
- (void)otherMouseDragged:(NSEvent *)event;
- (void)scrollWheel:(NSEvent *)event;
- (int)getMouseButtonFromEvent:(NSEvent *)event;
- (BOOL)onKeyboardEquivalent:(NSEvent *)event;
- (void)captureMouse;
- (void)uncaptureMouse;
- (void)uncaptureMouseWithCode:(NSString *)code reason:(NSString *)reason;
- (void)requestMouseUncaptureWhenSafeWithReason:(NSString *)reason;
- (void)requestMouseUncaptureWhenSafeWithReason:(NSString *)reason code:(NSString *)code;
- (void)completeDeferredMouseUncaptureIfNeeded;
- (void)logMouseUncaptureStage:(NSString *)stage code:(NSString *)code reason:(NSString *)reason;
@end

@interface StreamViewController (WindowModes) <NSWindowDelegate>
- (void)enterBorderlessPresentationOptionsIfNeeded;
- (void)restorePresentationOptionsIfNeeded;
- (void)prepareStreamWindowChromeForStreamingIfNeeded;
- (void)restoreStreamWindowChromeIfNeeded;
- (NSApplicationPresentationOptions)window:(NSWindow *)window willUseFullScreenPresentationOptions:(NSApplicationPresentationOptions)proposedOptions;
- (IBAction)performClose:(id)sender;
- (IBAction)performCloseStreamWindow:(id)sender;
- (IBAction)performCloseAndQuitApp:(id)sender;
- (IBAction)resizeWindowToActualResulution:(id)sender;
- (void)enableMenuItems:(BOOL)enable;
- (NSString *)displayModeDebugName:(NSInteger)displayMode;
- (void)logCurrentWindowStateWithContext:(NSString *)context;
- (void)applyStartupDisplayMode:(NSInteger)displayMode;
- (void)applyWindowedMode;
- (void)switchToWindowedMode:(id)sender;
- (void)switchToFullscreenMode:(id)sender;
- (void)applyBorderlessMode;
- (void)switchToBorderlessMode:(id)sender;
- (void)windowWillEnterFullScreen:(NSNotification *)notification;
- (void)windowWillExitFullScreen:(NSNotification *)notification;
- (BOOL)isWindowInCurrentSpace;
- (BOOL)isWindowFullscreen;
- (BOOL)isOurWindowTheWindowInNotiifcation:(NSNotification *)note;
- (NSMenuItem *)itemWithMenu:(NSMenu *)menu andAction:(SEL)action;
- (void)disallowDisplaySleep;
- (void)allowDisplaySleep;
- (void)prepareStreamWindowForSafeClose:(NSWindow *)window;
- (void)teardownStreamMenuEntrypointsForClosingWindow:(NSWindow *)window;
- (void)requestSafeCloseOfStreamWindow;
- (void)closeWindowFromMainQueueWithMessage:(NSString *)message;
@end

@interface StreamViewController (Diagnostics) <InputPresenceDelegate>
- (BOOL)hasReceivedAnyVideoFrames;
- (void)startConnectWatchdog;
- (void)scheduleConnectWatchdogCheckForToken:(NSInteger)token delay:(NSTimeInterval)delay;
- (void)showErrorOverlayWithTitle:(NSString *)title message:(NSString *)message canWait:(BOOL)canWait;
- (void)hideConnectionTimeoutOverlay;
- (void)handleTimeoutReconnect:(id)sender;
- (void)handleTimeoutWait:(id)sender;
- (void)handleTimeoutExitStream:(id)sender;
- (void)handleTimeoutResolution:(id)sender;
- (void)handleTimeoutBitrate:(id)sender;
- (void)handleTimeoutDisplayMode:(id)sender;
- (void)handleTimeoutConnection:(id)sender;
- (void)handleConnectionSelection:(NSMenuItem *)item;
- (void)handleTimeoutRecommendedProfile:(id)sender;
- (void)handleRecommendedProfileSelection:(NSMenuItem *)item;
- (BOOL)isAutomaticRecoveryModeEnabled;
- (void)presentManualRiskOverlayForReason:(NSString *)reason;
- (void)handleTimeoutViewLogs:(id)sender;
- (uint64_t)nowMs;
- (void)resetInputDiagnosticsState;
- (void)stopInputDiagnosticsTimer;
- (void)refreshInputDiagnosticsPreference;
- (void)accumulateInputDiagnosticsSnapshot:(HIDInputDiagnosticsSnapshot *)snapshot;
- (void)incrementInputDiagnosticsBucket:(NSMutableDictionary<NSString *, NSNumber *> *)bucket key:(NSString *)key;
- (NSString *)inputDiagnosticsTopReasonsFrom:(NSDictionary<NSString *, NSNumber *> *)bucket limit:(NSUInteger)limit;
- (void)noteInputDiagnosticsCaptureArmed;
- (void)noteInputDiagnosticsCaptureSkipped:(NSString *)reason;
- (void)noteInputDiagnosticsRearmRequested:(NSString *)reason;
- (void)noteInputDiagnosticsRearmSkippedWithBlocker:(NSString *)blocker;
- (void)noteInputDiagnosticsRearmDeferred:(NSString *)reason;
- (void)noteInputDiagnosticsUncapture;
- (void)pollInputDiagnostics:(NSTimer *)timer;
- (void)finalizeInputDiagnosticsWithReason:(NSString *)reason;
- (void)resetStreamHealthDiagnostics;
- (void)stopStreamHealthDiagnostics;
- (void)startStreamHealthDiagnostics;
- (void)attemptAdaptiveMitigationForDropRate:(float)dropRate;
- (void)pollStreamHealthDiagnostics:(NSTimer *)timer;
- (void)logStreamHealthSummaryWithReason:(NSString *)reason;
- (void)requestStreamCloseWithSource:(NSString *)source;
- (NSString *)resolvedDisconnectSourceFromSender:(id)sender;
- (BOOL)isRemoteStreamTargetAddress:(NSString *)targetAddress;
- (void)suppressConnectionWarningsForSeconds:(double)seconds reason:(NSString *)reason;
- (void)markUserInitiatedDisconnectAndSuppressWarningsForSeconds:(double)seconds reason:(NSString *)reason;
- (void)cancelPendingReconnectForUserExitWithReason:(NSString *)reason;
- (void)toggleOverlay;
- (void)toggleLogOverlay;
- (void)resetLogOverlayState;
- (NSString *)errorCodeFromLogLine:(NSString *)line;
- (NSDictionary<NSString *, NSString *> *)compactPresentationForLogLine:(NSString *)rawLine;
- (NSString *)foldedDisplayLineWithBase:(NSString *)base count:(NSUInteger)count;
- (void)appendRenderedLineToOverlayTextView:(NSString *)line;
- (void)replaceLastRenderedLineInOverlayTextView:(NSString *)line;
- (void)rebuildOverlayTextFromDisplayLines;
- (void)trimLogOverlayIfNeeded;
- (void)appendRawLogLineToOverlayState:(NSString *)rawLine;
- (void)appendRawLinesToOverlayState:(NSArray<NSString *> *)rawLines;
- (void)scrollLogOverlayToLatest;
- (void)updateLogOverlayToolbarState;
- (NSArray<NSString *> *)compactLinesFromRawLines:(NSArray<NSString *> *)rawLines;
- (void)handleTimeoutCopyLogs:(id)sender;
- (void)showLogOverlay;
- (void)hideLogOverlay;
- (void)handleLogOverlayClose:(id)sender;
- (void)handleLogOverlayPauseToggle:(id)sender;
- (void)handleLogOverlayAutoScrollToggle:(id)sender;
- (void)handleLogOverlayJumpLatest:(id)sender;
- (void)handleLogOverlayCopyCompact:(id)sender;
- (void)handleLogOverlayClearFromNow:(id)sender;
- (void)appendLogLineToOverlay:(NSString *)line;
- (void)copyAllLogsToPasteboard;
- (void)showReconnectOverlayWithMessage:(NSString *)message;
- (void)hideReconnectOverlay;
- (void)attemptReconnectWithReason:(NSString *)reason;
- (void)setupOverlay;
- (void)updateStats;
- (void)showConnectionWarning;
- (void)viewDidLayout;
- (void)layoutConnectionWarning;
- (void)hideConnectionWarning;
- (void)gamepadPresenceChanged;
- (void)mousePresenceChanged;
- (void)mouseModeToggled:(BOOL)enabled;
- (void)showMouseModeIndicator;
- (void)layoutMouseModeIndicator;
- (void)hideMouseModeIndicator;
- (void)handleMouseModeToggledNotification:(NSNotification *)note;
- (void)handleGamepadQuitNotification:(NSNotification *)note;
- (void)showNotification:(NSString *)message;
- (void)showNotification:(NSString *)message forSeconds:(NSTimeInterval)seconds;
- (CGPathRef)CGPathFromNSBezierPath:(NSBezierPath *)bezierPath;
@end
