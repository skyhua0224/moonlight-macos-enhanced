//
//  AppsViewController.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 23/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import "AppsViewController.h"
#import "ConceptHarness.h"
#import "MLMenuItemImage.h"
#import "AppsViewControllerDelegate.h" // Restore this import
#import "AppCell.h"
#import "AppCellView.h"
#import "AlertPresenter.h"
#import "StreamViewController.h"
#import "NSWindow+Moonlight.h"
#import "NSCollectionView+Moonlight.h"
#import "NSApplication+Moonlight.h"
#import "ImageFader.h"
#import "NSView+Moonlight.h"

#import "MoonlightEnhanced-Swift.h"
#import "LatencyProbe.h"
#import "StreamingSessionManager.h"


#import "HttpManager.h"
#import "HttpRequest.h"
#import "MLLaunchTrace.h"
#import "IdManager.h"
#import "CryptoManager.h"
#import "AppListResponse.h"
#import "AppAssetManager.h"
#import "DataManager.h"
#import "ServerInfoResponse.h"
#import "DiscoveryWorker.h"
#import "ConnectionHelper.h"
#import "ConnectionEndpointStore.h"
#import "ConnectionEditorViewController.h"
#import "WakeOnLanManager.h"

#undef NSLocalizedString
#define NSLocalizedString(key, comment) [[LanguageManager shared] localize:key]

@interface AppsViewController () <NSCollectionViewDataSource, AppsViewControllerDelegate, AppAssetCallback, NSSearchFieldDelegate, NSMenuItemValidation>
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *cmsIdToId;
@property (nonatomic, strong) NSArray<TemporaryApp *> *apps;
/// Re-fetching the app list while the page is visible (DeckAppListRules): a tick every 3 s decides.
@property (nonatomic, strong) NSTimer *appListTimer;
/// Bumped when a launch is cancelled: the answer of a check that was asked before is dropped.
@property (nonatomic) NSUInteger launchToken;
@property (atomic, strong) NSDate *lastAppListFetch;
/// One fetch at a time: a host whose list cannot be fetched is not asked again before the first attempt is over.
@property (nonatomic) BOOL appListFetchInFlight;
@property (nonatomic) BOOL appListWasOnline;
@property (nonatomic, strong) TemporaryApp *runningApp;
@property (nonatomic, assign) BOOL runningProbeInFlight;

@property (nonatomic, strong) NSString *filterText;
@property (nonatomic) NSSearchField *getSearchField;
@property (nonatomic, strong) NSSearchField *contentSearchField;

@property (nonatomic, strong) NSDictionary<NSString *, NSString *> *appNameToId;

// atomic: loadApps replaces it on the main thread while the app-list task reads it on a background queue
@property (atomic, strong) AppAssetManager *appManager;
@property (nonatomic, strong) NSCache *boxArtCache;
@property (nonatomic) CGFloat itemScale;

@property (nonatomic) id windowDidBecomeKeyObserver;

@property (nonatomic, strong) TemporaryApp *currentlyHoveredApp;

@property (nonatomic, strong) NSViewController *lockOverlayHostingController;
@property (nonatomic, strong) NSViewController *offlineOverlayHostingController;
@property (nonatomic, strong) id streamingStateObserver;
@property (nonatomic, strong) id hostLatencyObserver;
@property (nonatomic, copy) NSString *currentHostUUID;
@property (nonatomic, copy) NSString *offlineOverlayHostUUID;
@property (nonatomic, copy) NSString *pendingSessionSunshineTargetDisplayNameOverride;
@property (nonatomic) BOOL hasPendingSessionSunshineTargetDisplayOverride;
@property (nonatomic, strong) NSNumber *pendingSessionSunshineScreenModeOverride;
@property (nonatomic, strong) NSNumber *pendingSessionSunshineUseVirtualDisplayOverride;
@property (nonatomic, strong) TemporaryApp *sunshineOverrideApp;
@property (nonatomic, copy) NSArray<NSDictionary<NSString *, id> *> *cachedSunshineDisplays;
@property (nonatomic, copy) NSString *cachedSunshineDisplaysHostUUID;
@property (nonatomic) BOOL refreshingSunshineDisplays;
@property (nonatomic, strong) id deckApps;

@end

const CGFloat scaleBase = 1.125;
static NSUserInterfaceItemIdentifier const MLSunshineOverridesSeparatorMenuItemIdentifier = @"sunshineOverridesSeparatorMenuItem";
static NSUserInterfaceItemIdentifier const MLSunshineThisStreamDisplayMenuItemIdentifier = @"sunshineThisStreamDisplayMenuItem";
static NSUserInterfaceItemIdentifier const MLSunshineThisStreamModeMenuItemIdentifier = @"sunshineThisStreamModeMenuItem";
static NSUserInterfaceItemIdentifier const MLSunshineThisAppVirtualDisplayMenuItemIdentifier = @"sunshineThisAppVirtualDisplayMenuItem";
static NSUserInterfaceItemIdentifier const MLSunshineRefreshDisplaysMenuItemIdentifier = @"sunshineRefreshDisplaysMenuItem";

static NSUserInterfaceItemIdentifier const MLAppSuperCmdSeparatorMenuItemIdentifier = @"appSuperCmdSeparatorMenuItem";
static NSString * const MLAppSuperCmdMenuItemIdentifierPrefix = @"appSuperCmdMenuItem.";

static NSString * const MLSunshinePerAppTopologyDefaultsPrefix = @"Moonlight.SunshinePerAppTopology.";

@implementation AppsViewController

#pragma mark - Lifecycle

- (void)loadView {
    @try {
        [super loadView];
    } @catch (NSException *exception) {
        Log(LOG_W, @"[diag] AppsViewController storyboard view load failed: %@. Falling back to programmatic view.", exception.reason ?: @"(unknown)");

        NSView *rootView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 450, 300)];
        rootView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

        NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
        scrollView.translatesAutoresizingMaskIntoConstraints = NO;
        scrollView.borderType = NSNoBorder;
        scrollView.hasVerticalScroller = YES;
        scrollView.hasHorizontalScroller = NO;
        scrollView.autohidesScrollers = YES;
        scrollView.drawsBackground = YES;
        scrollView.backgroundColor = [NSColor controlBackgroundColor];

        CollectionView *collectionView = [[CollectionView alloc] initWithFrame:NSMakeRect(0, 0, 450, 300)];
        collectionView.selectable = YES;
        collectionView.autoresizingMask = NSViewWidthSizable;

        NSCollectionViewFlowLayout *layout = [[NSCollectionViewFlowLayout alloc] init];
        layout.minimumInteritemSpacing = 10.0;
        layout.minimumLineSpacing = 24.0;
        layout.itemSize = NSMakeSize(96.0, 144.0);
        layout.sectionInset = NSEdgeInsetsMake(28.0, 16.0, 28.0, 16.0);
        collectionView.collectionViewLayout = layout;
        collectionView.backgroundColors = @[[NSColor controlBackgroundColor]];

        scrollView.documentView = collectionView;
        [rootView addSubview:scrollView];
        [NSLayoutConstraint activateConstraints:@[
            [scrollView.leadingAnchor constraintEqualToAnchor:rootView.leadingAnchor],
            [scrollView.trailingAnchor constraintEqualToAnchor:rootView.trailingAnchor],
            [scrollView.topAnchor constraintEqualToAnchor:rootView.topAnchor],
            [scrollView.bottomAnchor constraintEqualToAnchor:rootView.bottomAnchor],
        ]];

        self.collectionView = collectionView;
        self.view = rootView;
    }
}

- (void)viewDidLoad {
    [super viewDidLoad];

    [self installContentSearchField];
    
    self.collectionView.dataSource = self;
    [self.collectionView registerNib:[[NSNib alloc] initWithNibNamed:@"AppCell" bundle:nil] forItemWithIdentifier:@"AppCell"];

    self.apps = @[];
    self.cmsIdToId = [NSMutableDictionary dictionary];

    self.itemScale = [[NSUserDefaults standardUserDefaults] floatForKey:@"itemScale"];
    if (self.itemScale == 0) {
        self.itemScale = pow(scaleBase, 2);
    }
    [self updateCollectionViewItemSize];

    [self loadApps];
    
    self.runningApp = [self findRunningApp:self.host];
    
    self.boxArtCache = [[NSCache alloc] init];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(languageChanged:) name:@"LanguageChanged" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(mainSearchTextChanged:) name:@"MoonlightMainSearchTextChanged" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleHostAutoAddressSwitched:) name:@"HostAutoAddressSwitched" object:nil];

    // Subscribe to streaming state changes
    __weak typeof(self) weakSelf = self;
    self.streamingStateObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:@"StreamingStateChanged"
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        [weakSelf handleStreamingStateChange:note];
    }];

    [self deckInstallIfNeeded];
}

- (void)installContentSearchField {
    // Search is rendered by the SwiftUI toolbar view.
}

- (void)mainSearchTextChanged:(NSNotification *)note {
    self.filterText = note.userInfo[@"text"] ?: @"";
    [self displayApps];
    [self.collectionView reloadData];
}

- (void)dealloc {
    [self.appListTimer invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (self.streamingStateObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:self.streamingStateObserver];
    }
}

- (void)languageChanged:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.getSearchField.placeholderString = NSLocalizedString(@"Search Apps", @"Search Apps");
        [self.collectionView reloadData];
    });
}

- (void)viewWillAppear {
    [super viewWillAppear];
    
    self.parentViewController.title = self.host.displayName;
    [self updateWindowSubtitle];
    
    [self.parentViewController.view.window moonlight_toolbarItemForAction:@selector(backButtonClicked:)].enabled = YES;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wundeclared-selector"
    // the host list is the sidebar of this window, so adding a computer stays available on every page
    [self.parentViewController.view.window moonlight_toolbarItemForAction:@selector(addHostButtonClicked:)].enabled = [MLDeckVariant isSidebarVariant];
#pragma clang diagnostic pop
    [self.parentViewController.view.window moonlight_toolbarItemForIdentifier:@"SidebarToggleToolbarItem"].enabled = ![MLDeckVariant isCardsVariant];
    if ([MLDeckVariant isSidebarVariant]) {
        // The host list is the sidebar of this window, there is no page to go back to.
        [self.parentViewController.view.window moonlight_toolbarItemForAction:@selector(backButtonClicked:)].enabled = NO;
    }


    [self deckInstallToolbarItemIfNeeded];
    [self installContentSearchField];
    self.contentSearchField.delegate = self;
    self.contentSearchField.placeholderString = NSLocalizedString(@"Search Apps", @"Search Apps");
    NSSearchField *toolbarSearchField = [self.parentViewController.view.window moonlight_searchFieldInToolbar];
    toolbarSearchField.delegate = self;
    toolbarSearchField.placeholderString = self.contentSearchField.placeholderString;
}

- (void)viewWillDisappear {
    [super viewWillDisappear];
    [self deckRemoveToolbarItem];
    [self.appListTimer invalidate];
    self.appListTimer = nil;
}

/// While the page is visible: fetch the list again when the computer comes online, when its serverinfo says the list changed, and
/// every 60 s for a host that sends no etag. Each fetch logs `[applist] fetch reason=... count=N`.
- (void)startAppListTimer {
    [self.appListTimer invalidate];
    self.appListWasOnline = self.host.state == StateOnline;
    __weak typeof(self) weakSelf = self;
    self.appListTimer = [NSTimer scheduledTimerWithTimeInterval:3.0 repeats:YES block:^(NSTimer *timer) {
        AppsViewController *strongSelf = weakSelf;
        if (strongSelf == nil || strongSelf.host == nil) { [timer invalidate]; return; }
        // a launch is pending or a stream is open: the list and the running mark are asked for after it (MLNetworkQuiet)
        if ([MLNetworkQuiet isQuiet]) return;
        TemporaryHost *host = strongSelf.host;
        BOOL online = host.state == StateOnline && host.canUseHttps;
        NSString *reason = [MLDeckAppListTick reasonWithOnline:online
                                                     wasOnline:strongSelf.appListWasOnline
                                                      seenEtag:[MLDeckActivity appListEtagSeenWithHostUUID:host.uuid ?: @""]
                                                   fetchedEtag:[MLDeckActivity appListEtagFetchedWithHostUUID:host.uuid ?: @""]
                                                     lastFetch:strongSelf.lastAppListFetch];
        strongSelf.appListWasOnline = online;
        if (online) {
            [strongSelf refreshRunningAppFromServerInfo];
        }
        if (reason.length > 0 && ![[StreamingSessionManager shared] isStreamingHost:host.uuid]) {
            [strongSelf discoverAppsForHost:host reason:reason];
        }
    }];
}

- (void)viewDidAppear {
    [super viewDidAppear];
    
    [[MLHostPathSignals shared] noteAttention];
    [self syncHostStateFromDatabase];
    self.currentHostUUID = self.host.uuid;
    [self startAppListTimer];
    [self refreshRunningAppFromServerInfo];

    __weak typeof(self) weakSelf = self;
    self.windowDidBecomeKeyObserver = [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidBecomeKeyNotification object:self.view.window queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        [[MLHostPathSignals shared] noteAttention];
        [weakSelf updateRunningAppState];
        
        [SettingsClass loadMoonlightSettingsFor:self.host.uuid];
        [weakSelf updateWindowSubtitle];
    }];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updateWindowSubtitle) name:NSUserDefaultsDidChangeNotification object:nil];
    // Also listen for latency updates to update the IP in Auto mode
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleHostLatencyUpdate:) name:@"HostLatencyUpdated" object:nil];

    // Check initial streaming state
    [self handleStreamingStateChange:nil];

    [self updateOfflineOverlayForCurrentHost];
    [self refreshSunshineDisplaysIfNeededForce:NO];
    [self.collectionView selectFirstItemForControllerIfNeeded];

    NSString *launchId = self.pendingLaunchAppId;
    self.pendingLaunchAppId = nil;
    if (launchId.length > 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            for (TemporaryApp *candidate in self.apps) {
                if ([candidate.id isEqualToString:launchId]) {
                    [self openApp:candidate];
                    break;
                }
            }
        });
    }
}

- (void)updateOfflineOverlayForCurrentHost {
    StreamingSessionManager *manager = [StreamingSessionManager shared];
    BOOL isStreamingThisHost = (self.host.uuid != nil) && [manager isStreamingHost:self.host.uuid];

    if (self.host.state == StateOffline && !isStreamingThisHost) {
        [self showOfflineOverlayIfCurrentHost];
    } else {
        [self hideOfflineOverlay];
    }
}

- (void)syncHostStateFromDatabase {
    if (!self.host.uuid) {
        return;
    }

    DataManager *dataManager = [[DataManager alloc] init];
    NSArray *hosts = [dataManager getHosts];
    for (TemporaryHost *h in hosts) {
        if ([h.uuid isEqualToString:self.host.uuid]) {
            if (h.state != StateUnknown) {
                self.host.state = h.state;
            }
            self.host.pairState = h.pairState;
            self.host.addressLatencies = h.addressLatencies;
            self.host.addressStates = h.addressStates;
            if (h.activeAddress) {
                self.host.activeAddress = h.activeAddress;
            }
            break;
        }
    }

    [self updateWindowSubtitle];
}

- (void)handleHostLatencyUpdate:(NSNotification *)note {
    NSString *uuid = note.userInfo[@"uuid"];
    if (uuid == nil || ![uuid isEqualToString:self.host.uuid]) {
        return;
    }

    NSDictionary *latencies = note.userInfo[@"latencies"];
    NSDictionary *states = note.userInfo[@"states"];
    if (latencies) {
        self.host.addressLatencies = latencies;
    }
    if (states) {
        self.host.addressStates = states;
    }

    [self syncHostStateFromDatabase];

    [self updateOfflineOverlayForCurrentHost];

    // If we were offline and now online, try to refresh apps
    if (self.host.state != StateOffline && self.apps.count == 0) {
        [self discoverAppsForHost:self.host];
    }
}

- (void)handleHostAutoAddressSwitched:(NSNotification *)note {
    // No alert, no toast: an automatic switch of address shows only on the host page, where the 线路 chip's
    // 使用中 mark moves and the status line follows (DeckPathChips listens to this notification too).
    MLLaunchTrace(@"address switched automatically: %@ -> %@", note.userInfo[@"oldAddress"] ?: @"?", note.userInfo[@"newAddress"] ?: @"?");
}

- (void)requestHostRefresh {
    if (!self.host.uuid) {
        return;
    }
    // A failed request must not become a loop of discovery workers (each probes every address).
    static NSMutableDictionary<NSString *, NSDate *> *lastRefresh;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lastRefresh = [NSMutableDictionary dictionary]; });
    NSDate *previous = lastRefresh[self.host.uuid];
    if (previous != nil && [[NSDate date] timeIntervalSinceDate:previous] < 5.0) {
        return;
    }
    lastRefresh[self.host.uuid] = [NSDate date];

    [[NSNotificationCenter defaultCenter] postNotificationName:@"MoonlightRequestHostDiscovery"
                                                        object:nil
                                                      userInfo:@{ @"uuid": self.host.uuid }];
}

- (void)handleStreamingStateChange:(NSNotification *)notification {
    if (notification) {
        NSString *hostUUID = notification.userInfo[@"hostUUID"];
        if (hostUUID && self.host.uuid && ![hostUUID isEqualToString:self.host.uuid]) {
            return;
        }
    }

    StreamingSessionManager *manager = [StreamingSessionManager shared];

    // Check if THIS host is streaming
    BOOL shouldShowOverlay = (self.host.uuid != nil) && [manager isStreamingHost:self.host.uuid];

    if (shouldShowOverlay) {
        [self showLockOverlay];
    } else {
        [self hideLockOverlay];
    }
}

- (void)showLockOverlay {
    if (self.lockOverlayHostingController) return;

    StreamingSessionManager *manager = [StreamingSessionManager shared];

    NSString *hostName = self.host.displayName.length > 0 ? self.host.displayName : NSLocalizedString(@"Unknown", @"Unknown");
    NSString *appName = (self.host.uuid != nil ? [manager appNameForHost:self.host.uuid] : nil) ?: @"Unknown App";

    __weak typeof(self) weakSelf = self;
    self.lockOverlayHostingController = [StreamingLockOverlayViewFactory createOverlayWithHostName:hostName
                                                                                          appName:appName
                                                                                     onShowWindow:^{
        if (self.host.uuid) {
            [[StreamingSessionManager shared] focusStreamWindowForHost:self.host.uuid];
        }
    } onDisconnect:^{
        [weakSelf presentStreamingDisconnectOptions];
    }];

    NSView *overlayView = self.lockOverlayHostingController.view;
    overlayView.frame = self.view.bounds;
    overlayView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    [self.view addSubview:overlayView];
    [self addChildViewController:self.lockOverlayHostingController];

    // Animate in
    overlayView.alphaValue = 0.0;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.25;
        overlayView.animator.alphaValue = 1.0;
    } completionHandler:nil];
}

- (void)presentStreamingDisconnectOptions {
    StreamingSessionManager *manager = [StreamingSessionManager shared];
    if (!self.host.uuid || ![manager isStreamingHost:self.host.uuid]) {
        return;
    }

    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleInformational;
    alert.messageText = NSLocalizedString(@"Disconnect Alert", @"Disconnect Alert");
    [alert addButtonWithTitle:NSLocalizedString(@"Disconnect from Stream", @"Disconnect from Stream")];
    [alert addButtonWithTitle:NSLocalizedString(@"Close and Quit App", @"Close and Quit App")];
    [alert addButtonWithTitle:NSLocalizedString(@"Cancel", @"Cancel")];

    NSWindow *window = self.view.window;
    if (!window) {
        return;
    }

    [alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse returnCode) {
        if (returnCode == NSAlertFirstButtonReturn) {
            [[StreamingSessionManager shared] requestDisconnectWithQuitApp:NO hostUUID:self.host.uuid];
        } else if (returnCode == NSAlertSecondButtonReturn) {
            [[StreamingSessionManager shared] requestDisconnectWithQuitApp:YES hostUUID:self.host.uuid];
        }
    }];
}

- (void)hideLockOverlay {
    if (!self.lockOverlayHostingController) return;

    NSViewController *overlayVC = self.lockOverlayHostingController;
    self.lockOverlayHostingController = nil; // Clear reference first

    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.2;
        overlayVC.view.animator.alphaValue = 0.0;
    } completionHandler:^{
        [overlayVC.view removeFromSuperview];
        [overlayVC removeFromParentViewController];
    }];
}

- (void)showOfflineOverlay {
    if (self.offlineOverlayHostingController) return;

    // Ensure we don't have the lock overlay on top (though unlikely to be streaming if offline)
    [self hideLockOverlay];

    NSString *hostName = self.host.displayName.length > 0 ? self.host.displayName : NSLocalizedString(@"Unknown", @"Unknown");
    self.offlineOverlayHostUUID = self.host.uuid;

    __weak typeof(self) weakSelf = self;
    self.offlineOverlayHostingController = [OfflineHostOverlayViewFactory createOverlayWithHostName:hostName
                                                                                            onWake:^{
        [WakeOnLanManager wakeHost:weakSelf.host];
        [weakSelf requestHostRefresh];
        // The UI handles the waiting state visually
        // We rely on handleHostLatencyUpdate to detect when it comes online
    } onRefresh:^{
        [weakSelf requestHostRefresh];
    } onCancel:^{
        [weakSelf transitionToHostsVC];
    }];

    NSView *overlayView = self.offlineOverlayHostingController.view;
    overlayView.frame = self.view.bounds;
    overlayView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    [self.view addSubview:overlayView];
    [self addChildViewController:self.offlineOverlayHostingController];

    // Animate in
    overlayView.alphaValue = 0.0;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.25;
        overlayView.animator.alphaValue = 1.0;
    } completionHandler:nil];
}

- (void)showOfflineOverlayIfCurrentHost {
    if ([MLDeckVariant isDeck]) {
        // The host pages show a host's state themselves.
        return;
    }
    if (self.offlineOverlayHostingController && self.offlineOverlayHostUUID && ![self.offlineOverlayHostUUID isEqualToString:self.host.uuid]) {
        [self hideOfflineOverlay];
    }
    if (!self.currentHostUUID || ![self.currentHostUUID isEqualToString:self.host.uuid]) {
        return;
    }
    if (self.host.state != StateOffline) {
        return;
    }
    [self showOfflineOverlay];
}

- (void)hideOfflineOverlay {
    if (!self.offlineOverlayHostingController) return;

    NSViewController *overlayVC = self.offlineOverlayHostingController;
    self.offlineOverlayHostingController = nil;
    self.offlineOverlayHostUUID = nil;

    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.2;
        overlayVC.view.animator.alphaValue = 0.0;
    } completionHandler:^{
        [overlayVC.view removeFromSuperview];
        [overlayVC removeFromParentViewController];
    }];
}

- (void)switchToHost:(TemporaryHost *)newHost {
    if ([self.host.uuid isEqualToString:newHost.uuid]) {
        return;
    }

    [SettingsWindowObjCBridge syncSelectedProfileWithHostId:newHost.uuid];

    self.host = newHost;
    self.currentHostUUID = newHost.uuid;
    [self hideOfflineOverlay];

    // Sync latest state/address info for the selected host
    [self syncHostStateFromDatabase];

    // Clear current state
    self.apps = @[];
    self.runningApp = nil;
    [self.collectionView reloadData];
    [self.boxArtCache removeAllObjects];

    // Update window title/subtitle
    self.parentViewController.title = newHost.displayName;
    [self updateWindowSubtitle];

    // Load settings
    [SettingsClass loadMoonlightSettingsFor:newHost.uuid];

    // Reload apps
    [self loadApps];
    // Clearing the running app above also cleared the host's current game; in the concept
    // there is no discovery to bring it back, so the mock state is applied again.
    [ConceptHarness applyMockRuntimeStateToHost:newHost];
    self.runningApp = [self findRunningApp:newHost];
    [self refreshDeckApps];
    [self clearPendingSunshineStreamOverrides];
    self.cachedSunshineDisplays = @[];
    self.cachedSunshineDisplaysHostUUID = nil;
    [self refreshSunshineDisplaysIfNeededForce:NO];

    // Check streaming state for new host
    [self handleStreamingStateChange:nil];

    [self updateOfflineOverlayForCurrentHost];
}

- (void)updateWindowSubtitle {
    if ([MLDeckVariant isPolished] && self.host != nil) {
        // Like Music and TV: the title is the host, the subtitle says where it is. The page
        // does not repeat either.
        NSString *text = [MLDeckWindowText subtitleForHost:self.host];
        dispatch_async(dispatch_get_main_queue(), ^{
            NSWindow *window = self.parentViewController.view.window;
            NSString *subtitle = [MLDeckVariant titleHidden] ? @"" : text;
            NSWindowTitleVisibility wanted = [MLDeckVariant titleHidden] ? NSWindowTitleHidden : NSWindowTitleVisible;
            // only when it differs: setting the same value still redraws the titlebar
            if (![window.subtitle isEqualToString:subtitle]) {
                window.subtitle = subtitle;
            }
            if (window.titleVisibility != wanted) {
                window.titleVisibility = wanted;
            }
        });
        return;
    }
    NSDictionary *settings = [SettingsClass getSettingsFor:self.host.uuid];
    NSString *method = settings[@"connectionMethod"];

    NSString* (^bestKnownAddress)(void) = ^NSString* {
        if (self.host.activeAddress.length > 0) {
            return self.host.activeAddress;
        }

        NSArray<NSString *> *candidates = @[ self.host.localAddress ?: @"",
                                             self.host.address ?: @"",
                                             self.host.externalAddress ?: @"",
                                             self.host.ipv6Address ?: @"" ];
        NSString *bestAddr = nil;
        NSInteger bestLatency = NSIntegerMax;

        for (NSString *addr in candidates) {
            if (addr.length == 0) continue;
            NSNumber *state = self.host.addressStates[addr];
            BOOL online = state ? (state.intValue == 1) : YES;
            if (!online) continue;

            NSNumber *latency = self.host.addressLatencies[addr];
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
    };

    NSString* (^addressLabel)(NSString*) = ^NSString* (NSString* addr) {
        if (!addr) {
            return NSLocalizedString(@"Unknown", nil);
        }

        NSNumber *state = self.host.addressStates[addr];
        NSNumber *latency = self.host.addressLatencies[addr];
        BOOL online = state ? (state.intValue == 1) : YES;

        if (!online) {
            return [NSString stringWithFormat:@"%@ (%@)", addr, NSLocalizedString(@"Offline", nil)];
        }
        if (latency && latency.intValue >= 0) {
            return [NSString stringWithFormat:@"%@ (%dms)", addr, latency.intValue];
        }
        return addr;
    };

    NSString *displaySubtitle = nil;
    if (method && ![method isEqualToString:@"Auto"]) {
        // Manual route: method holds the target address
        displaySubtitle = [NSString stringWithFormat:@"%@ (%@)", NSLocalizedString(@"Manual", nil), addressLabel(method)];
    } else {
        // Auto route: show activeAddress chosen by routing
        NSString *autoAddr = bestKnownAddress();
        displaySubtitle = [NSString stringWithFormat:@"%@ (%@)", NSLocalizedString(@"Auto", nil), addressLabel(autoAddr)];
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        self.parentViewController.view.window.subtitle = displaySubtitle;
    });
}

- (BOOL)becomeFirstResponder {
    if (self.deckApps != nil) {
        [self.view.window makeFirstResponder:((MLDeckAppsController *)self.deckApps).viewController.view];
        return YES;
    }
    [self.view.window makeFirstResponder:self.collectionView];
    return [super becomeFirstResponder];
}

- (void)transitionToHostsVC {
    // Notify delegate to handle back navigation
    if ([self.navigationDelegate respondsToSelector:@selector(appsViewControllerDidRequestBack:)]) {
        [self.navigationDelegate appsViewControllerDidRequestBack:self];
    }
}

- (void)prepareForSegue:(NSStoryboardSegue *)segue sender:(id)sender {
    StreamViewController *streamVC = segue.destinationController;
    [[StreamingSessionManager shared] noteStreamViewController:streamVC forHost:self.host.uuid ?: @""];
    // Cached apps can retain a database snapshot without the current route.
    if ([self.runningApp.host.uuid isEqualToString:self.host.uuid]) {
        self.runningApp.host = self.host;
    }
    streamVC.app = self.runningApp;
    streamVC.delegate = self;
    // Pending overrides belong to whichever app's context menu opened last;
    // every launch must use the launched app's own saved display choice.
    self.sunshineOverrideApp = self.runningApp;
    [self loadPersistedSunshineTopologyForCurrentApp];
    Log(LOG_I, @"[sunshine] Launch display topology: app=%@ display=%@ useVdd=%@ screenMode=%@",
        self.runningApp.id ?: @"(unknown)",
        self.hasPendingSessionSunshineTargetDisplayOverride
            ? (self.pendingSessionSunshineTargetDisplayNameOverride ?: @"(host default)") : @"(follow settings)",
        self.pendingSessionSunshineUseVirtualDisplayOverride ?: @"(follow settings)",
        self.pendingSessionSunshineScreenModeOverride ?: @"(follow settings)");
    streamVC.hasSessionSunshineTargetDisplayOverride = self.hasPendingSessionSunshineTargetDisplayOverride;
    streamVC.sessionSunshineTargetDisplayNameOverride = self.pendingSessionSunshineTargetDisplayNameOverride;
    streamVC.sessionSunshineScreenModeOverride = self.pendingSessionSunshineScreenModeOverride;
    streamVC.sessionSunshineUseVirtualDisplayOverride = self.pendingSessionSunshineUseVirtualDisplayOverride;
    [self clearPendingSunshineStreamOverrides];
}


#pragma mark - NSResponder

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    // Forward validate to collectionView, because for some reason it doesn't get called
    // automatically by the system when expected (even though it's firstResponder).
    return [self.collectionView validateMenuItem:menuItem];
}


#pragma mark - Actions

- (IBAction)backButtonClicked:(id)sender {
    [self transitionToHostsVC];
}

- (IBAction)pinAppMenuItemClicked:(NSMenuItem *)item {
    AppCellView *appCellView = (AppCellView *)(item.menu.delegate);
    AppCell *appCell = (AppCell *)(appCellView.delegate);

    NSInteger previousIndex = [self indexPathForApp:appCell.app].item;
    
    appCell.app.pinned = !appCell.app.pinned;
    [self updateCollectionViewWithNewPinnedChangedApp:appCell.app newPinnedState:appCell.app.pinned previousIndex:previousIndex];
    
    [[[DataManager alloc] init] updateAppsForExistingHost:self.host];
}

- (IBAction)hideAppMenuItemClicked:(NSMenuItem *)item {
    AppCellView *appCellView = (AppCellView *)(item.menu.delegate);
    AppCell *appCell = (AppCell *)(appCellView.delegate);
    
    appCell.app.hidden = !appCell.app.hidden;
    [appCell updateAlphaStateWithShouldAnimate:YES];
    
    [[[DataManager alloc] init] updateAppsForExistingHost:self.host];
}

- (IBAction)quitAppMenuItemClicked:(id)sender {
    if (![self hostCanStreamNow]) {
        NSBeep();
        return;
    }
    TemporaryApp *app = [sender representedObject];
    if (![app isKindOfClass:[TemporaryApp class]]) {
        app = self.runningApp;
    }
    if (app == nil) {
        return;
    }
    [self quitApp:app completion:nil];
}

- (IBAction)open:(id)sender {
    if (self.collectionView.selectionIndexPaths.count != 0) {
        NSIndexPath *selectedIndex = self.collectionView.selectionIndexPaths.anyObject;
        TemporaryApp *app = [self itemsForSection:selectedIndex.section][selectedIndex.item];
        [self openApp:app];
    }
}

- (void)updateCollectionViewItemSize {
    NSCollectionViewFlowLayout *flowLayout = (NSCollectionViewFlowLayout *)self.collectionView.collectionViewLayout;

    flowLayout.minimumInteritemSpacing = 0;
    flowLayout.itemSize = NSMakeSize((int)(90 * self.itemScale + 6 + 2), (int)(128 * self.itemScale + 6 + 2));
    
    CGSize appArtworkDimensions = [SettingsClass appArtworkDimensionsFor:self.host.uuid];
    CGFloat artworkAspectRatio = appArtworkDimensions.width / appArtworkDimensions.height;

    CGFloat baseHeight = 128.0 * self.itemScale + 6 + 2;
    CGFloat baseWidth = baseHeight * artworkAspectRatio;

    NSSize itemSize = NSMakeSize((int)baseWidth, (int)baseHeight);
    flowLayout.itemSize = itemSize;
    
    [flowLayout invalidateLayout];
    
    [[NSUserDefaults standardUserDefaults] setFloat:self.itemScale forKey:@"itemScale"];
    
    for (AppCell *item in self.collectionView.visibleItems) {
        [item updateShadowPath];
    }
}

- (IBAction)increaseItemSize:(id)sender {
    if ([MLDeckVariant isComputerPage]) {
        [MLDeckZoom stepTiles:1];
        return;
    }
    if (self.itemScale > pow(scaleBase, 7)) {
        return;
    }
    self.itemScale *= scaleBase;
    [self updateCollectionViewItemSize];
}

- (IBAction)decreaseItemSize:(id)sender {
    if ([MLDeckVariant isComputerPage]) {
        [MLDeckZoom stepTiles:-1];
        return;
    }
    if (self.itemScale < pow(scaleBase, 0)) {
        return;
    }
    self.itemScale /= scaleBase;
    [self updateCollectionViewItemSize];
}


#pragma mark - NSCollectionViewDataSource

- (void)configureItem:(AppCell *)item atIndexPath:(NSIndexPath * _Nonnull)indexPath {
    TemporaryApp *app = [self itemsForSection:indexPath.section][indexPath.item];
    item.appName.stringValue = app.name;
    item.app = app;
    
    BOOL isRunning = [self isAppRunning:app];
    item.runningIconContainer.alphaValue = isRunning ? 1.0 : 0.0;
    item.runningIconContainer.hidden = !isRunning;
    
    CGSize appArtworkDimensions = [SettingsClass appArtworkDimensionsFor:app.host.uuid];
    CGFloat aspectRatio = appArtworkDimensions.width / appArtworkDimensions.height;
    item.appCoverArt.superview.translatesAutoresizingMaskIntoConstraints = NO;
    [item.appCoverArt.superview.widthAnchor constraintEqualToAnchor:item.appCoverArt.superview.heightAnchor multiplier:aspectRatio].active = YES;

    [item updateSelectedState:NO];
    
    NSImage *fastCacheImage = [self.boxArtCache objectForKey:app.id];
    if (fastCacheImage != nil) {
        item.appCoverArt.image = fastCacheImage;
        item.placeholderView.hidden = YES;
    } else {
        item.appCoverArt.image = nil;
        
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
            NSImage* cacheImage = [AppsViewController loadBoxArtForCaching:app];
            if (cacheImage != nil) {
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    AppCell *currentItem = (AppCell *)[self.collectionView itemAtIndexPath:indexPath];
                    if ([item.app.id isEqualToString:currentItem.app.id]) {
                        if (item.appCoverArt != nil) {
                            [ImageFader transitionImageViewWithOldImageView:item.appCoverArt newImageViewBlock:^NSImageView * _Nonnull {
                                NSImageView *newImageView = [[NSImageView alloc] init];
                                [newImageView smoothRoundCornersWithCornerRadius:APP_CELL_CORNER_RADIUS];

                                return newImageView;
                            } duration:0.3 image:cacheImage completionBlock:^(NSImageView * _Nonnull newImageView) {
                                item.appCoverArt = newImageView;
                                item.placeholderView.hidden = YES;
                            }];
                        }
                    }
                    [self.boxArtCache setObject:cacheImage forKey:app.id];
                });
            }
        });
    }
}

- (nonnull NSCollectionViewItem *)collectionView:(nonnull NSCollectionView *)collectionView itemForRepresentedObjectAtIndexPath:(nonnull NSIndexPath *)indexPath {
    AppCell *item = [collectionView makeItemWithIdentifier:@"AppCell" forIndexPath:indexPath];
    item.delegate = self;

    [self configureItem:item atIndexPath:indexPath];

    return item;
}

- (NSInteger)collectionView:(nonnull NSCollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return [self itemsForSection:section].count;
}

- (NSInteger)numberOfSectionsInCollectionView:(NSCollectionView *)collectionView {
    return 2;
}

- (NSArray<TemporaryApp *> *)itemsForSection:(NSInteger)section {
    return [[self filteredItems:self.apps forSection:section] sortedArrayUsingSelector:@selector(compareName:)];
}

- (NSArray<TemporaryApp *> *)filteredItems:(NSArray<TemporaryApp *> *)rawItems forSection:(NSInteger)section {
    return [rawItems filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:section == 0 ? @"pinned == YES" : @"pinned == NO"]];
}


#pragma mark - NSSearchFieldDelegate

- (void)controlTextDidChange:(NSNotification *)obj {
    self.filterText = ((NSTextField *)obj.object).stringValue;
    [self displayApps];
    [self.collectionView reloadData];
}


#pragma mark - AppsViewControllerDelegate

/// A stream starts only on a computer that is on and paired: whatever asked (a tile, a card, a menu, the
/// keyboard, the sidebar), an off computer is not connected to.
- (BOOL)hostCanStreamNow {
    return self.host.state == StateOnline && self.host.pairState == PairStatePaired && self.host.canUseHttps;
}

- (void)openApp:(TemporaryApp *)app {
    if (![self hostCanStreamNow]) {
        Log(LOG_W, @"[apps] Not starting %@: %@ is %@", app.name ?: @"?", self.host.displayName ?: @"?",
            self.host.state != StateOnline ? @"off" : @"not paired");
        MLLaunchTrace(@"blocked start of %@ on %@ (not on or not paired)", app.name ?: @"?", self.host.displayName ?: @"?");
        NSBeep();
        return;
    }
    if (!self.host.canUseHttps) {
        // launching needs the paired HTTPS channel; an unpaired host shows 配对 instead
        Log(LOG_W, @"[apps] Not starting %@: host is not paired", app.name ?: @"?");
        return;
    }
    if (![self confirmConnectionRouteForStreaming]) {
        return;
    }

    // Check if this host is already streaming
    if (![[StreamingSessionManager shared] canStartStreamForHost:self.host.uuid]) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = NSLocalizedString(@"Host Busy", @"Host Busy");
        alert.informativeText = NSLocalizedString(@"This host is already streaming. Please disconnect first.", @"This host is already streaming. Please disconnect first.");
        [alert addButtonWithTitle:NSLocalizedString(@"OK", @"OK")];
        [alert runModal];
        return;
    }

    // One launch per computer and one window per computer (seven clicks while the first check hung opened
    // seven windows). A click while a launch is pending is part of it; a stream window that is open is shown.
    NSString *hostUUID = self.host.uuid ?: @"";
    NSWindow *existing = [[StreamingSessionManager shared] liveStreamWindowForHost:hostUUID];
    if (existing != nil) {
        Log(LOG_I, @"[connect] %@ has a stream window already; showing it instead of a second one", self.host.displayName ?: @"?");
        [existing makeKeyAndOrderFront:nil];
        return;
    }
    if (![MLLaunchGate claim:hostUUID]) {
        Log(LOG_I, @"[connect] a launch of %@ is pending already; this click is part of it", self.host.displayName ?: @"?");
        MLLaunchTrace(@"click absorbed by the pending launch of %@", self.host.displayName ?: @"?");
        return;
    }
    // From the click on, nothing else uses the link (art, probes, events), and the page shows the progress now.
    [MLNetworkQuiet begin:[@"launch:" stringByAppendingString:hostUUID]];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"MLLaunchStateChanged" object:nil userInfo:@{@"hostUUID": hostUUID}];
    NSUInteger token = ++self.launchToken;
    __weak typeof(self) weakSelf = self;
    // What runs on the host is asked first: an app another client started (or quit) is not in runningApp yet, and
    // starting 大屏模式 over it would have been taken for resuming it. The question is bounded (2.5 s) and its answer
    // is dropped when the launch was cancelled meanwhile.
    [self refreshRunningAppFromServerInfoThen:^{
        AppsViewController *strongSelf = weakSelf;
        if (strongSelf == nil || strongSelf.launchToken != token) return;
        [strongSelf openAppAfterRunningCheck:app];
    }];
}

/// 取消 on the connect button, and the end of a launch that did not get to a window.
- (void)cancelPendingLaunch {
    NSString *hostUUID = self.host.uuid ?: @"";
    if (![MLLaunchGate isPending:hostUUID]) return;
    self.launchToken++;
    NSWindow *window = [[StreamingSessionManager shared] liveStreamWindowForHost:hostUUID];
    Log(LOG_I, @"[connect] launch of %@ cancelled by the user (window %@)", self.host.displayName ?: @"?", window != nil ? @"closed" : @"not opened yet");
    if (window != nil) {
        [window performClose:nil];   // the stream stops through windowWillClose, which ends the launch
    } else {
        [self abandonLaunch];
    }
}

- (void)abandonLaunch {
    NSString *hostUUID = self.host.uuid ?: @"";
    [MLNetworkQuiet end:[@"launch:" stringByAppendingString:hostUUID]];
    [MLLaunchGate release:hostUUID];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"MLLaunchStateChanged" object:nil userInfo:@{@"hostUUID": hostUUID}];
}

- (void)openAppAfterRunningCheck:(TemporaryApp *)app {
    if (self.runningApp != nil && ![self isSameApp:app asApp:self.runningApp]) {
        if ([self askWhetherToStopRunningApp:self.runningApp andStartNewApp:app]) {
            NSUInteger token = self.launchToken;
            [self quitApp:self.runningApp completion:^(BOOL success) {
                if (success && self.launchToken == token) {
                    self.runningApp = app;
                    [MLDeckActivity recordConnectedWithHostUUID:self.host.uuid ?: @"" appId:app.id ?: @"" appName:app.name ?: @""];
                    [self openStreamWindowAfterAwdlSetupForApp:app];
                } else {
                    [self abandonLaunch];
                }
            }];
        } else {
            [self abandonLaunch];
        }
    } else {
        self.runningApp = app;
        [MLDeckActivity recordConnectedWithHostUUID:self.host.uuid ?: @"" appId:app.id ?: @"" appName:app.name ?: @""];
        [self openStreamWindowAfterAwdlSetupForApp:app];
    }
}

/// The stream window opens once the AWDL helper has been dealt with: with the helper missing or out of date the user is
/// asked, here and once, for the administrator authorization (never during the stream). Whatever the answer, the stream
/// starts; a launch cancelled meanwhile does not.
- (void)openStreamWindowAfterAwdlSetupForApp:(TemporaryApp *)app {
    NSUInteger token = self.launchToken;
    NSString *hostUUID = self.host.uuid ?: @"";
    __weak typeof(self) weakSelf = self;
    [AwdlHelperSetup prepareForStreamThen:^{
        AppsViewController *strongSelf = weakSelf;
        if (strongSelf == nil || strongSelf.launchToken != token) return;
        // The page may have been switched to another computer while the question was up.
        if (![(strongSelf.host.uuid ?: @"") isEqualToString:hostUUID]) {
            [MLNetworkQuiet end:[@"launch:" stringByAppendingString:hostUUID]];
            [MLLaunchGate release:hostUUID];
            [[NSNotificationCenter defaultCenter] postNotificationName:@"MLLaunchStateChanged" object:nil userInfo:@{@"hostUUID": hostUUID}];
            return;
        }
        // The running-app refresh may have replaced it while the question was up; the stream is for the app that was chosen.
        strongSelf.runningApp = app;
        [strongSelf performSegueWithIdentifier:@"streamSegue" sender:nil];
    }];
}

- (BOOL)confirmConnectionRouteForStreaming {
    NSDictionary *settings = [SettingsClass getSettingsFor:self.host.uuid];
    NSString *selectedMethod = settings[@"connectionMethod"];
    if (selectedMethod.length == 0 || [selectedMethod isEqualToString:@"Auto"]) {
        return YES;
    }

    NSNumber *selectedState = self.host.addressStates[selectedMethod];
    if (selectedState == nil || selectedState.boolValue) {
        return YES;
    }

    NSString *alternate = nil;
    for (NSString *endpoint in [ConnectionEndpointStore allEndpointsForHost:self.host]) {
        if ([endpoint isEqualToString:selectedMethod]) {
            continue;
        }
        if (self.host.addressStates[endpoint].boolValue) {
            alternate = endpoint;
            break;
        }
    }
    if (alternate.length == 0) {
        return YES;
    }

    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = NSLocalizedString(@"Selected Connection Unavailable", @"Selected connection route unavailable");
    alert.informativeText = [NSString stringWithFormat:
        NSLocalizedString(@"Selected Connection Unavailable Detail", @"Selected connection route unavailable detail"),
        selectedMethod, alternate];
    [alert addButtonWithTitle:NSLocalizedString(@"Switch and Continue", @"Switch to the reachable connection route")];
    [alert addButtonWithTitle:NSLocalizedString(@"Try Selected Route", @"Try the selected connection route anyway")];
    [alert addButtonWithTitle:NSLocalizedString(@"Cancel", @"Cancel")];

    NSModalResponse response = [alert runModal];
    if (response == NSAlertFirstButtonReturn) {
        [SettingsClass setConnectionMethod:alternate for:self.host.uuid];
        self.host.activeAddress = alternate;
        [[[DataManager alloc] init] updateHost:self.host];
        [self updateWindowSubtitle];
    }
    return response != NSAlertThirdButtonReturn;
}

- (void)quitApp:(TemporaryApp *)app completion:(void (^)(BOOL success))completion {
    if (!app.host.canUseHttps) {
        if (completion != nil) {
            completion(NO);
        }
        return;
    }
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *uniqueId = [IdManager getUniqueId];

        HttpManager *hMan = [[HttpManager alloc] initWithHost:app.host.activeAddress uniqueId:uniqueId serverCert:app.host.serverCert];
        HttpResponse *quitResponse = [[HttpResponse alloc] init];
        HttpRequest *quitRequest = [HttpRequest requestForResponse:quitResponse withUrlRequest:[hMan newQuitAppRequest]];
        
        [hMan executeRequestSynchronously:quitRequest];
        __block BOOL stillRunning = NO;
        if (quitResponse.statusCode == 200) {
            // /cancel answered 200. GFE then keeps the app when another client started it, so a busy host right
            // after is read as 「quit it from that client」 (599). Sunshine and Foundation Sunshine accept /cancel
            // from any paired client and cancel asynchronously (the encoder and the app can take seconds to go), so
            // a busy host right after means "not yet": serverinfo is asked every 0.3 s for up to 10 s (MLHostSessionPolicy).
            NSString * (^readState)(void) = ^NSString *{
                ServerInfoResponse *serverInfoResp = [[ServerInfoResponse alloc] init];
                [hMan executeRequestSynchronously:[HttpRequest requestForResponse:serverInfoResp withUrlRequest:[hMan newServerInfoRequest:NO] fallbackError:401 fallbackRequest:[hMan newHttpServerInfoRequest]]];
                return [serverInfoResp isStatusOk] ? [[serverInfoResp getStringTag:TAG_STATE] trim] : nil;
            };
            NSString *firstState = readState();
            BOOL waiting = firstState == nil || [MLHostSessionPolicy isBusyWithState:firstState];
            if (waiting) {
                dispatch_async(dispatch_get_main_queue(), ^{ [self showQuittingState:app]; });
            }
            NSInteger outcome = [MLHostSessionPolicy quitOutcomeWithIsFoundation:[MLDeckActivity isFoundationWithHostUUID:app.host.uuid ?: @""]
                                                                      firstState:firstState
                                                                            poll:readState
                                                                            wait:^(double seconds) { [NSThread sleepForTimeInterval:seconds]; }];
            if (outcome == 2) {
                stillRunning = YES;
                quitResponse.statusCode = 598;
            } else if (outcome == 3) {
                quitResponse.statusCode = 599;
            }
            if (waiting) {
                dispatch_async(dispatch_get_main_queue(), ^{ [self updateWindowSubtitle]; });
            }
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            // If it fails, display an error and stop the current operation
            if (quitResponse.statusCode != 200) {
                NSString *message = stillRunning ? NSLocalizedString(@"Quit App Still Running Message", @"Quit App Still Running Message")
                                                 : NSLocalizedString(@"Quit App Error Message", @"Quit App Error Message");
                [AlertPresenter displayAlert:NSAlertStyleWarning title:NSLocalizedString(@"Failed to quit app", @"Failed to quit app") message:message window:self.view.window completionHandler:nil];
                if (stillRunning) {
                    [self refreshRunningAppFromServerInfo];
                }
                if (completion != nil) {
                    completion(NO);
                }
            } else {
                self.runningApp = nil;
                
                if (completion != nil) {
                    completion(YES);
                }
            }
        });
    });
}

/// While a quit is being waited for on a Sunshine-family host: the window says so (the subtitle goes back to the
/// host's address when it ends).
- (void)showQuittingState:(TemporaryApp *)app {
    NSWindow *window = self.view.window;
    if (window == nil || ![window respondsToSelector:@selector(setSubtitle:)]) return;
    window.subtitle = [NSString stringWithFormat:NSLocalizedString(@"Quitting %@…", @"Quit in progress"), app.name ?: @""];
}

- (void)appDidQuit:(TemporaryApp *)app {
    self.runningApp = nil;
    [self updateRunningAppState];
}

- (void)didOpenContextMenu:(NSMenu *)menu forApp:(TemporaryApp *)app {
    NSMenuItem *quitAppMenuItem = [HostsViewController getMenuItemForIdentifier:@"quitAppMenuItem" inMenu:menu];
    NSMenuItem *hideAppMenuItem = [HostsViewController getMenuItemForIdentifier:@"hideAppMenuItem" inMenu:menu];
    NSMenuItem *pinAppMenuItem = [HostsViewController getMenuItemForIdentifier:@"pinAppMenuItem" inMenu:menu];
    if (app.pinned) {
        pinAppMenuItem.title = NSLocalizedString(@"Unpin App", @"Unpin App");
        MLSetMenuItemImage(pinAppMenuItem, [NSImage imageWithSystemSymbolName:@"pin.slash" accessibilityDescription:nil]);
    } else {
        pinAppMenuItem.title = NSLocalizedString(@"Pin App", @"Pin App");
        MLSetMenuItemImage(pinAppMenuItem, [NSImage imageWithSystemSymbolName:@"pin" accessibilityDescription:nil]);
    }
    if (app.hidden) {
        hideAppMenuItem.title = NSLocalizedString(@"Show App", @"Show App");
        MLSetMenuItemImage(hideAppMenuItem, [NSImage imageWithSystemSymbolName:@"eye" accessibilityDescription:nil]);
    } else {
        hideAppMenuItem.title = NSLocalizedString(@"Hide App", @"Hide App");
        MLSetMenuItemImage(hideAppMenuItem, [NSImage imageWithSystemSymbolName:@"eye.slash" accessibilityDescription:nil]);
    }

    quitAppMenuItem.title = NSLocalizedString(@"Quit App", @"Quit App");
    MLSetMenuItemImage(quitAppMenuItem, [NSImage imageWithSystemSymbolName:@"xmark.circle" accessibilityDescription:nil]);
    quitAppMenuItem.representedObject = app;
    quitAppMenuItem.hidden = ![self isAppRunning:app];
    quitAppMenuItem.enabled = [self isAppRunning:app];

    self.sunshineOverrideApp = app;
    [self loadPersistedSunshineTopologyForCurrentApp];
    [self rebuildSunshineOverrideItemsInMenu:menu];
    [self rebuildSuperCommandItemsInMenu:menu forApp:app];
    [self refreshSunshineDisplaysIfNeededForce:NO];
}

#pragma mark - Host menu commands (SuperCmds)

- (void)removeSuperCommandItemsFromMenu:(NSMenu *)menu {
    NSMutableArray<NSMenuItem *> *itemsToRemove = [NSMutableArray array];
    for (NSMenuItem *item in menu.itemArray) {
        NSUserInterfaceItemIdentifier identifier = item.identifier;
        if ([identifier isEqualToString:MLAppSuperCmdSeparatorMenuItemIdentifier] ||
            [identifier hasPrefix:MLAppSuperCmdMenuItemIdentifierPrefix]) {
            [itemsToRemove addObject:item];
        }
    }

    for (NSMenuItem *item in itemsToRemove) {
        [menu removeItem:item];
    }
}

// The host resolves /supercmd ids against the app it is currently running, so the
// commands are only offered for the running app.
- (void)rebuildSuperCommandItemsInMenu:(NSMenu *)menu forApp:(TemporaryApp *)app {
    [self removeSuperCommandItemsFromMenu:menu];

    if (![self isAppRunning:app] || app.superCommands.count == 0) {
        return;
    }

    NSInteger insertionIndex = [self indexForSunshineMenuInsertionInMenu:menu];

    NSMenuItem *separator = [NSMenuItem separatorItem];
    separator.identifier = MLAppSuperCmdSeparatorMenuItemIdentifier;
    [menu insertItem:separator atIndex:insertionIndex++];

    for (MLAppSuperCommand *command in app.superCommands) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:command.name
                                                      action:@selector(superCommandMenuItemClicked:)
                                               keyEquivalent:@""];
        item.target = self;
        item.identifier = [MLAppSuperCmdMenuItemIdentifierPrefix stringByAppendingString:command.commandId];
        item.representedObject = command;
        MLSetMenuItemImage(item, [NSImage imageWithSystemSymbolName:@"terminal" accessibilityDescription:nil]);
        [menu insertItem:item atIndex:insertionIndex++];
    }
}

- (IBAction)superCommandMenuItemClicked:(NSMenuItem *)sender {
    MLAppSuperCommand *command = sender.representedObject;
    if (![command isKindOfClass:[MLAppSuperCommand class]]) {
        return;
    }

    TemporaryHost *host = self.host;
    if (!host.canUseHttps) {
        return;
    }
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        HttpManager *hMan = [[HttpManager alloc] initWithHost:host.activeAddress uniqueId:[IdManager getUniqueId] serverCert:host.serverCert];
        BOOL ok = [hMan executeSuperCommandWithId:command.commandId];
        if (ok) {
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *message = [NSString stringWithFormat:NSLocalizedString(@"Host Command Failed Message", @"Host command failed message"), command.name];
            [AlertPresenter displayAlert:NSAlertStyleWarning
                                   title:NSLocalizedString(@"Host Command Failed", @"Host command failed")
                                 message:message
                                  window:self.view.window
                       completionHandler:nil];
        });
    });
}

- (NSString *)sunshinePerAppTopologyDefaultsKey {
    if (self.host.uuid.length == 0 || self.sunshineOverrideApp.id.length == 0) {
        return nil;
    }
    return [NSString stringWithFormat:@"%@%@.%@",
            MLSunshinePerAppTopologyDefaultsPrefix,
            self.host.uuid,
            self.sunshineOverrideApp.id];
}

- (void)loadPersistedSunshineTopologyForCurrentApp {
    self.hasPendingSessionSunshineTargetDisplayOverride = NO;
    self.pendingSessionSunshineTargetDisplayNameOverride = nil;
    self.pendingSessionSunshineScreenModeOverride = nil;
    self.pendingSessionSunshineUseVirtualDisplayOverride = nil;

    NSString *key = [self sunshinePerAppTopologyDefaultsKey];
    NSDictionary *saved = key.length > 0 ? [[NSUserDefaults standardUserDefaults] dictionaryForKey:key] : nil;
    if (![saved isKindOfClass:[NSDictionary class]]) {
        return;
    }

    if ([saved[@"displayName"] isKindOfClass:[NSString class]]) {
        self.hasPendingSessionSunshineTargetDisplayOverride = YES;
        self.pendingSessionSunshineTargetDisplayNameOverride = saved[@"displayName"];
    }
    if ([saved[@"screenMode"] isKindOfClass:[NSNumber class]]) {
        self.pendingSessionSunshineScreenModeOverride = saved[@"screenMode"];
    }
    if ([saved[@"useVirtualDisplay"] isKindOfClass:[NSNumber class]]) {
        self.pendingSessionSunshineUseVirtualDisplayOverride = saved[@"useVirtualDisplay"];
    }
}

- (void)persistPendingSunshineTopologyForCurrentApp {
    NSString *key = [self sunshinePerAppTopologyDefaultsKey];
    if (key.length == 0) {
        return;
    }

    NSMutableDictionary *saved = [NSMutableDictionary dictionary];
    if (self.hasPendingSessionSunshineTargetDisplayOverride &&
        self.pendingSessionSunshineTargetDisplayNameOverride != nil) {
        saved[@"displayName"] = self.pendingSessionSunshineTargetDisplayNameOverride;
    }
    if (self.pendingSessionSunshineScreenModeOverride != nil) {
        saved[@"screenMode"] = self.pendingSessionSunshineScreenModeOverride;
    }
    if (self.pendingSessionSunshineUseVirtualDisplayOverride != nil) {
        saved[@"useVirtualDisplay"] = self.pendingSessionSunshineUseVirtualDisplayOverride;
    }

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (saved.count > 0) {
        [defaults setObject:saved forKey:key];
    } else {
        [defaults removeObjectForKey:key];
    }
}

- (NSArray<NSDictionary<NSString *, id> *> *)sunshineScreenModeEntries {
    return @[
        @{@"title": @"Host Default", @"value": @(-1)},
        @{@"title": @"Verify Only", @"value": @(0)},
        @{@"title": @"Activate Display", @"value": @(1)},
        @{@"title": @"Make Primary", @"value": @(2)},
        @{@"title": @"Only Stream Display", @"value": @(3)},
        @{@"title": @"Use As Secondary", @"value": @(4)},
    ];
}

- (NSString *)preferredSunshineHostAddress {
    if (self.host.activeAddress.length > 0 &&
        (self.host.addressStates[self.host.activeAddress] == nil ||
         self.host.addressStates[self.host.activeAddress].boolValue)) {
        return self.host.activeAddress;
    }

    for (NSString *endpoint in [ConnectionEndpointStore allEndpointsForHost:self.host]) {
        if (self.host.addressStates[endpoint].boolValue) {
            return endpoint;
        }
    }

    if (self.host.activeAddress.length > 0) {
        return self.host.activeAddress;
    }
    if (self.host.localAddress.length > 0) {
        return self.host.localAddress;
    }
    if (self.host.address.length > 0) {
        return self.host.address;
    }
    if (self.host.externalAddress.length > 0) {
        return self.host.externalAddress;
    }
    if (self.host.ipv6Address.length > 0) {
        return self.host.ipv6Address;
    }
    return nil;
}

- (void)clearPendingSunshineStreamOverrides {
    self.hasPendingSessionSunshineTargetDisplayOverride = NO;
    self.pendingSessionSunshineTargetDisplayNameOverride = nil;
    self.pendingSessionSunshineScreenModeOverride = nil;
    self.pendingSessionSunshineUseVirtualDisplayOverride = nil;
    self.sunshineOverrideApp = nil;
}

/// 连接 on a Foundation Sunshine host with a chosen mode: the Desktop app or the big screen entry, with the
/// display choice carried by the same per-app override the context menu uses (saved, then read when the
/// stream starts). 桌面 asks for the host's own screen, 虚拟显示器 for the virtual display, 指定显示器 for one
/// listed display; 大屏模式 clears the overrides of its own entry.
- (void)deckConnectWithMode:(NSString *)mode displayId:(NSString *)displayId {
    // a launch is pending: this click changes nothing (not the saved display choice either)
    if ([MLLaunchGate isPending:self.host.uuid ?: @""]) {
        Log(LOG_I, @"[connect] a launch of %@ is pending already; this click is part of it", self.host.displayName ?: @"?");
        return;
    }
    TemporaryApp *target = nil;
    for (TemporaryApp *candidate in self.host.appList.allObjects ?: @[]) {
        // FsKind when the host sends it; else the default entries by name (Foundation Sunshine before FsKind)
        NSString *kind = candidate.fsExtras[@"FsKind"];
        if (kind.length == 0) {
            kind = [MLDeckActivity kindForName:candidate.name ?: @""];
        }
        if ([mode isEqualToString:@"bigscreen"]) {
            if ([kind isEqualToString:@"bigscreen"]) { target = candidate; break; }
        } else if ([kind isEqualToString:@"desktop"]) {
            target = candidate; break;
        }
    }
    if (target == nil) {
        Log(LOG_W, @"[connect] No app for mode %@ on %@", mode, self.host.displayName);
        NSBeep();
        return;
    }
    self.sunshineOverrideApp = target;
    [self loadPersistedSunshineTopologyForCurrentApp];
    if ([mode isEqualToString:@"bigscreen"]) {
        self.hasPendingSessionSunshineTargetDisplayOverride = NO;
        self.pendingSessionSunshineTargetDisplayNameOverride = nil;
        self.pendingSessionSunshineUseVirtualDisplayOverride = nil;
    } else if ([mode isEqualToString:@"vdd"]) {
        self.hasPendingSessionSunshineTargetDisplayOverride = NO;
        self.pendingSessionSunshineTargetDisplayNameOverride = nil;
        self.pendingSessionSunshineUseVirtualDisplayOverride = @YES;
    } else if ([mode isEqualToString:@"display"] && displayId.length > 0) {
        self.hasPendingSessionSunshineTargetDisplayOverride = YES;
        self.pendingSessionSunshineTargetDisplayNameOverride = displayId;
        self.pendingSessionSunshineUseVirtualDisplayOverride = @NO;
    } else {
        // 桌面: the host's own screen (explicit host default, no virtual display)
        self.hasPendingSessionSunshineTargetDisplayOverride = YES;
        self.pendingSessionSunshineTargetDisplayNameOverride = @"";
        self.pendingSessionSunshineUseVirtualDisplayOverride = @NO;
    }
    [self persistPendingSunshineTopologyForCurrentApp];
    [self openApp:target];
}

- (void)refreshSunshineDisplaysIfNeededForce:(BOOL)force {
    if (self.host.uuid.length == 0 || !self.host.canUseHttps || [MLNetworkQuiet isQuiet]) {
        return;
    }
    if (self.refreshingSunshineDisplays) {
        return;
    }
    if (!force &&
        self.cachedSunshineDisplaysHostUUID.length > 0 &&
        [self.cachedSunshineDisplaysHostUUID isEqualToString:self.host.uuid]) {
        return;
    }

    NSString *address = [self preferredSunshineHostAddress];
    if (address.length == 0) {
        return;
    }

    self.refreshingSunshineDisplays = YES;
    NSString *hostUUID = [self.host.uuid copy];
    NSData *serverCert = self.host.serverCert;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        HttpManager *httpManager = [[HttpManager alloc] initWithHost:address
                                                            uniqueId:[IdManager getUniqueId]
                                                          serverCert:serverCert];
        NSDictionary<NSString *, id> *snapshot = [httpManager fetchSunshineDisplaySnapshot];
        NSArray<NSDictionary<NSString *, id> *> *displays = snapshot[@"displays"] ?: @[];
        NSDictionary<NSString *, id> *vdd = [snapshot[@"vdd"] isKindOfClass:[NSDictionary class]]
            ? snapshot[@"vdd"] : nil;
        NSNumber *vddCapability = [vdd[@"capability_version"] isKindOfClass:[NSNumber class]]
            ? vdd[@"capability_version"] : nil;
        NSString *vddKey = [NSString stringWithFormat:@"settings.sunshine.vddCapability.%@", hostUUID];
        if (vddCapability != nil) {
            [[NSUserDefaults standardUserDefaults] setObject:vddCapability forKey:vddKey];
        } else {
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:vddKey];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.refreshingSunshineDisplays = NO;
            if (![self.host.uuid isEqualToString:hostUUID]) {
                return;
            }

            self.cachedSunshineDisplaysHostUUID = hostUUID;
            self.cachedSunshineDisplays = displays ?: @[];
            [(MLDeckAppsController *)self.deckApps displaysChanged];
        });
    });
}

- (NSInteger)indexForSunshineMenuInsertionInMenu:(NSMenu *)menu {
    NSMenuItem *quitItem = [HostsViewController getMenuItemForIdentifier:@"quitAppMenuItem" inMenu:menu];
    if (quitItem != nil) {
        NSInteger quitIndex = [menu indexOfItem:quitItem];
        if (quitIndex > 0) {
            return quitIndex;
        }
    }
    return menu.numberOfItems;
}

- (NSString *)sunshineDisplayLabelForValue:(NSString *)value {
    if (value.length == 0) {
        return NSLocalizedString(@"Host Default", @"Host Default");
    }

    for (NSDictionary<NSString *, id> *entry in self.cachedSunshineDisplays ?: @[]) {
        NSString *deviceId = [entry[@"device_id"] isKindOfClass:[NSString class]] ? entry[@"device_id"] : @"";
        if (![deviceId isEqualToString:value]) {
            continue;
        }

        NSString *friendlyName = [entry[@"friendly_name"] isKindOfClass:[NSString class]] ? entry[@"friendly_name"] : deviceId;
        NSString *displayName = [entry[@"display_name"] isKindOfClass:[NSString class]] ? entry[@"display_name"] : deviceId;
        if (friendlyName.length > 0 &&
            ![friendlyName isEqualToString:deviceId] &&
            ![friendlyName isEqualToString:displayName]) {
            return [NSString stringWithFormat:@"%@ (%@)", friendlyName, deviceId];
        }
        return friendlyName.length > 0 ? friendlyName : deviceId;
    }

    return value;
}

- (NSString *)sunshineScreenModeTitleForValue:(NSInteger)value {
    for (NSDictionary<NSString *, id> *entry in [self sunshineScreenModeEntries]) {
        NSNumber *rawValue = entry[@"value"];
        if (rawValue.integerValue == value) {
            return NSLocalizedString(entry[@"title"], nil);
        }
    }
    return NSLocalizedString(@"Host Default", @"Host Default");
}

- (void)removeSunshineOverrideItemsFromMenu:(NSMenu *)menu {
    NSMutableArray<NSMenuItem *> *itemsToRemove = [NSMutableArray array];
    for (NSMenuItem *item in menu.itemArray) {
        NSUserInterfaceItemIdentifier identifier = item.identifier;
        if ([identifier isEqualToString:MLSunshineOverridesSeparatorMenuItemIdentifier] ||
            [identifier isEqualToString:MLSunshineThisStreamDisplayMenuItemIdentifier] ||
            [identifier isEqualToString:MLSunshineThisStreamModeMenuItemIdentifier] ||
            [identifier isEqualToString:MLSunshineThisAppVirtualDisplayMenuItemIdentifier] ||
            [identifier isEqualToString:MLSunshineRefreshDisplaysMenuItemIdentifier]) {
            [itemsToRemove addObject:item];
        }
    }

    for (NSMenuItem *item in itemsToRemove) {
        [menu removeItem:item];
    }
}

- (void)configureSunshineDisplaySubmenu:(NSMenu *)submenu {
    NSMenuItem *followHostSettingItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Follow Host Setting", @"Follow Host Setting")
                                                                   action:@selector(selectPendingSunshineStreamDisplayOverride:)
                                                            keyEquivalent:@""];
    followHostSettingItem.target = self;
    followHostSettingItem.representedObject = [NSNull null];
    followHostSettingItem.state = self.hasPendingSessionSunshineTargetDisplayOverride ? NSControlStateValueOff : NSControlStateValueOn;
    [submenu addItem:followHostSettingItem];

    NSMenuItem *hostDefaultItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Host Default", @"Host Default")
                                                             action:@selector(selectPendingSunshineStreamDisplayOverride:)
                                                      keyEquivalent:@""];
    hostDefaultItem.target = self;
    hostDefaultItem.representedObject = @"";
    hostDefaultItem.state = self.hasPendingSessionSunshineTargetDisplayOverride &&
        self.pendingSessionSunshineTargetDisplayNameOverride.length == 0 ? NSControlStateValueOn : NSControlStateValueOff;
    [submenu addItem:hostDefaultItem];

    NSArray<NSDictionary<NSString *, id> *> *displays = self.cachedSunshineDisplays ?: @[];
    if (displays.count > 0) {
        [submenu addItem:[NSMenuItem separatorItem]];
        for (NSDictionary<NSString *, id> *entry in displays) {
            NSString *deviceId = [entry[@"device_id"] isKindOfClass:[NSString class]] ? entry[@"device_id"] : @"";
            if (deviceId.length == 0) {
                continue;
            }

            NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:[self sunshineDisplayLabelForValue:deviceId]
                                                          action:@selector(selectPendingSunshineStreamDisplayOverride:)
                                                   keyEquivalent:@""];
            item.target = self;
            item.representedObject = deviceId;
            item.state = (self.hasPendingSessionSunshineTargetDisplayOverride &&
                          [self.pendingSessionSunshineTargetDisplayNameOverride isEqualToString:deviceId])
                ? NSControlStateValueOn : NSControlStateValueOff;
            [submenu addItem:item];
        }
    } else {
        [submenu addItem:[NSMenuItem separatorItem]];
        NSString *title = self.refreshingSunshineDisplays
            ? NSLocalizedString(@"Loading…", @"Loading")
            : NSLocalizedString(@"No Host Displays Found", @"No host displays found");
        NSMenuItem *placeholder = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
        placeholder.enabled = NO;
        [submenu addItem:placeholder];
    }

    if (self.hasPendingSessionSunshineTargetDisplayOverride &&
        self.pendingSessionSunshineTargetDisplayNameOverride.length > 0) {
        BOOL found = NO;
        for (NSDictionary<NSString *, id> *entry in displays) {
            NSString *deviceId = [entry[@"device_id"] isKindOfClass:[NSString class]] ? entry[@"device_id"] : @"";
            if ([deviceId isEqualToString:self.pendingSessionSunshineTargetDisplayNameOverride]) {
                found = YES;
                break;
            }
        }
        if (!found) {
            [submenu addItem:[NSMenuItem separatorItem]];
            NSMenuItem *fallbackItem = [[NSMenuItem alloc] initWithTitle:self.pendingSessionSunshineTargetDisplayNameOverride
                                                                  action:@selector(selectPendingSunshineStreamDisplayOverride:)
                                                           keyEquivalent:@""];
            fallbackItem.target = self;
            fallbackItem.representedObject = self.pendingSessionSunshineTargetDisplayNameOverride;
            fallbackItem.state = NSControlStateValueOn;
            [submenu addItem:fallbackItem];
        }
    }
}

- (void)configureSunshineScreenModeSubmenu:(NSMenu *)submenu {
    NSMenuItem *followHostSettingItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Follow Host Setting", @"Follow Host Setting")
                                                                   action:@selector(selectPendingSunshineStreamScreenModeOverride:)
                                                            keyEquivalent:@""];
    followHostSettingItem.target = self;
    followHostSettingItem.representedObject = [NSNull null];
    followHostSettingItem.state = self.pendingSessionSunshineScreenModeOverride == nil ? NSControlStateValueOn : NSControlStateValueOff;
    [submenu addItem:followHostSettingItem];
    [submenu addItem:[NSMenuItem separatorItem]];

    for (NSDictionary<NSString *, id> *entry in [self sunshineScreenModeEntries]) {
        NSString *title = entry[@"title"];
        NSNumber *value = entry[@"value"];
        if (title.length == 0 || value == nil) {
            continue;
        }

        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(title, nil)
                                                      action:@selector(selectPendingSunshineStreamScreenModeOverride:)
                                               keyEquivalent:@""];
        item.target = self;
        item.representedObject = value;
        item.state = (self.pendingSessionSunshineScreenModeOverride != nil &&
                      self.pendingSessionSunshineScreenModeOverride.integerValue == value.integerValue)
            ? NSControlStateValueOn : NSControlStateValueOff;
        [submenu addItem:item];
    }
}

- (void)configureSunshineVirtualDisplaySubmenu:(NSMenu *)submenu {
    NSMenuItem *followHostSettingItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Follow Host Setting", @"Follow Host Setting")
                                                                   action:@selector(selectPendingSunshineUseVirtualDisplayOverride:)
                                                            keyEquivalent:@""];
    followHostSettingItem.target = self;
    followHostSettingItem.representedObject = [NSNull null];
    followHostSettingItem.state = self.pendingSessionSunshineUseVirtualDisplayOverride == nil
        ? NSControlStateValueOn : NSControlStateValueOff;
    [submenu addItem:followHostSettingItem];
    [submenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *enabledItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Use Virtual Display", @"Use Virtual Display")
                                                         action:@selector(selectPendingSunshineUseVirtualDisplayOverride:)
                                                  keyEquivalent:@""];
    enabledItem.target = self;
    enabledItem.representedObject = @YES;
    NSNumber *vddCapability = [[NSUserDefaults standardUserDefaults]
        objectForKey:[NSString stringWithFormat:@"settings.sunshine.vddCapability.%@", self.host.uuid]];
    enabledItem.enabled = vddCapability == nil || vddCapability.integerValue > 0;
    enabledItem.state = self.pendingSessionSunshineUseVirtualDisplayOverride.boolValue
        ? NSControlStateValueOn : NSControlStateValueOff;
    [submenu addItem:enabledItem];

    NSMenuItem *disabledItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Use Physical Display", @"Use Physical Display")
                                                          action:@selector(selectPendingSunshineUseVirtualDisplayOverride:)
                                                   keyEquivalent:@""];
    disabledItem.target = self;
    disabledItem.representedObject = @NO;
    disabledItem.state = self.pendingSessionSunshineUseVirtualDisplayOverride != nil &&
        !self.pendingSessionSunshineUseVirtualDisplayOverride.boolValue
        ? NSControlStateValueOn : NSControlStateValueOff;
    [submenu addItem:disabledItem];
}

- (void)rebuildSunshineOverrideItemsInMenu:(NSMenu *)menu {
    [self removeSunshineOverrideItemsFromMenu:menu];

    NSInteger insertionIndex = [self indexForSunshineMenuInsertionInMenu:menu];

    NSMenuItem *separator = [NSMenuItem separatorItem];
    separator.identifier = MLSunshineOverridesSeparatorMenuItemIdentifier;
    [menu insertItem:separator atIndex:insertionIndex++];

    NSMenu *displaySubmenu = [[NSMenu alloc] initWithTitle:NSLocalizedString(@"This Stream Display", @"This Stream Display")];
    [self configureSunshineDisplaySubmenu:displaySubmenu];
    NSMenuItem *displayMenuItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"This Stream Display", @"This Stream Display")
                                                             action:nil
                                                      keyEquivalent:@""];
    displayMenuItem.identifier = MLSunshineThisStreamDisplayMenuItemIdentifier;
    displayMenuItem.submenu = displaySubmenu;
    [menu insertItem:displayMenuItem atIndex:insertionIndex++];

    NSMenu *modeSubmenu = [[NSMenu alloc] initWithTitle:NSLocalizedString(@"This Stream Screen Mode", @"This Stream Screen Mode")];
    [self configureSunshineScreenModeSubmenu:modeSubmenu];
    NSMenuItem *modeMenuItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"This Stream Screen Mode", @"This Stream Screen Mode")
                                                          action:nil
                                                   keyEquivalent:@""];
    modeMenuItem.identifier = MLSunshineThisStreamModeMenuItemIdentifier;
    modeMenuItem.submenu = modeSubmenu;
    [menu insertItem:modeMenuItem atIndex:insertionIndex++];

    NSMenu *virtualDisplaySubmenu = [[NSMenu alloc] initWithTitle:NSLocalizedString(@"This App Virtual Display", @"This App Virtual Display")];
    [self configureSunshineVirtualDisplaySubmenu:virtualDisplaySubmenu];
    NSMenuItem *virtualDisplayMenuItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"This App Virtual Display", @"This App Virtual Display")
                                                                       action:nil
                                                                keyEquivalent:@""];
    virtualDisplayMenuItem.identifier = MLSunshineThisAppVirtualDisplayMenuItemIdentifier;
    virtualDisplayMenuItem.submenu = virtualDisplaySubmenu;
    [menu insertItem:virtualDisplayMenuItem atIndex:insertionIndex++];

    NSMenuItem *refreshItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Refresh Host Displays", @"Refresh host displays")
                                                         action:@selector(refreshSunshineDisplaysMenuItemClicked:)
                                                  keyEquivalent:@""];
    refreshItem.target = self;
    refreshItem.identifier = MLSunshineRefreshDisplaysMenuItemIdentifier;
    refreshItem.enabled = !self.refreshingSunshineDisplays;
    [menu insertItem:refreshItem atIndex:insertionIndex];
}

- (IBAction)refreshSunshineDisplaysMenuItemClicked:(id)sender {
    self.cachedSunshineDisplaysHostUUID = nil;
    self.cachedSunshineDisplays = @[];
    [self refreshSunshineDisplaysIfNeededForce:YES];
}

- (IBAction)selectPendingSunshineStreamDisplayOverride:(NSMenuItem *)sender {
    if ([sender.representedObject isKindOfClass:[NSNull class]]) {
        self.hasPendingSessionSunshineTargetDisplayOverride = NO;
        self.pendingSessionSunshineTargetDisplayNameOverride = nil;
        [self persistPendingSunshineTopologyForCurrentApp];
        return;
    }

    self.hasPendingSessionSunshineTargetDisplayOverride = YES;
    self.pendingSessionSunshineTargetDisplayNameOverride =
        [sender.representedObject isKindOfClass:[NSString class]] ? sender.representedObject : @"";
    Log(LOG_I, @"[sunshine] Next stream display override=%@",
        [self sunshineDisplayLabelForValue:self.pendingSessionSunshineTargetDisplayNameOverride]);
    [self persistPendingSunshineTopologyForCurrentApp];
}

- (IBAction)selectPendingSunshineStreamScreenModeOverride:(NSMenuItem *)sender {
    if ([sender.representedObject isKindOfClass:[NSNull class]]) {
        self.pendingSessionSunshineScreenModeOverride = nil;
        [self persistPendingSunshineTopologyForCurrentApp];
        return;
    }

    if ([sender.representedObject isKindOfClass:[NSNumber class]]) {
        self.pendingSessionSunshineScreenModeOverride = sender.representedObject;
        Log(LOG_I, @"[sunshine] Next stream screen mode override=%@",
            [self sunshineScreenModeTitleForValue:self.pendingSessionSunshineScreenModeOverride.integerValue]);
        [self persistPendingSunshineTopologyForCurrentApp];
    }
}

- (IBAction)selectPendingSunshineUseVirtualDisplayOverride:(NSMenuItem *)sender {
    if ([sender.representedObject isKindOfClass:[NSNull class]]) {
        self.pendingSessionSunshineUseVirtualDisplayOverride = nil;
    } else if ([sender.representedObject isKindOfClass:[NSNumber class]]) {
        self.pendingSessionSunshineUseVirtualDisplayOverride = sender.representedObject;
    }
    [self persistPendingSunshineTopologyForCurrentApp];
    Log(LOG_I, @"[sunshine] App display topology override: app=%@ useVdd=%@",
        self.sunshineOverrideApp.id ?: @"(unknown)",
        self.pendingSessionSunshineUseVirtualDisplayOverride == nil
            ? @"host-default"
            : (self.pendingSessionSunshineUseVirtualDisplayOverride.boolValue ? @"true" : @"false"));
}

- (void)didHover:(BOOL)hovered forApp:(TemporaryApp *)app {
    AppCell *currentCell = [self cellForApp:self.currentlyHoveredApp];
    AppCell *cell = [self cellForApp:app];
    if (hovered) {
        if (self.currentlyHoveredApp == app) {
            return;
        }

        [currentCell exitHoveredState];
        [cell enterHoveredState];
        
        self.currentlyHoveredApp = app;
    } else {
        [cell exitHoveredState];
        self.currentlyHoveredApp = nil;
    }
}


#pragma mark - Running App State

- (TemporaryApp*)findRunningApp:(TemporaryHost*)host {
    for (TemporaryApp* app in host.appList) {
        if ([app.id isEqualToString:host.currentGame]) {
            return app;
        }
    }
    
    return nil;
}

- (void)setRunningApp:(TemporaryApp *)runningApp {
    TemporaryApp *oldApp = self.runningApp;
    _runningApp = runningApp;
    [self refreshDeckApps];
    
    if (runningApp == nil) {
        self.host.currentGame = @"0";
    } else {
        self.host.currentGame = self.runningApp.id;
    }
    
    if (oldApp == runningApp) {
        return;
    }
    
    [self redrawCellAtOldPath:[self indexPathForApp:oldApp]];
    [self redrawCellAtNewPath:[self indexPathForApp:runningApp]];
}

static const CGFloat runningAnimationDuration = 1.0;

- (void)redrawCellAtOldPath:(NSIndexPath *)oldPath {
    if (oldPath == nil) {
        return;
    }
    
    AppCell *oldItem = (AppCell *)[self.collectionView itemAtIndexPath:oldPath];

    // Create an NSAnimationContext for smoother animations
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        // Set the duration of the animation
        context.duration = runningAnimationDuration;
        
        // Fade out the runningIconContainer
        oldItem.runningIconContainer.animator.alphaValue = 0.0;
    } completionHandler:^{
        // This block is called when the fade out animation completes
        
        // Update the UI or perform any other necessary tasks
        
        // Update the visibility status and alpha value for the runningIconContainer
        oldItem.runningIconContainer.hidden = YES;
    }];
}

- (void)redrawCellAtNewPath:(NSIndexPath *)newPath {
    if (newPath == nil) {
        return;
    }
        
    AppCell *newItem = (AppCell *)[self.collectionView itemAtIndexPath:newPath];

    // Now, if you want to fade in the runningIconContainer
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        // Set the duration of the animation
        context.duration = runningAnimationDuration;
        
        // Fade in the runningIconContainer
        newItem.runningIconContainer.hidden = NO;
        newItem.runningIconContainer.animator.alphaValue = 1.0;
    } completionHandler:nil];
}

/// One /serverinfo, and the running mark follows what the host says: another client started or quit an app.
/// A failed request changes nothing (MLHostSessionPolicy.reconcile). Called on every tick of the app-list timer
/// (3 s) while the page is visible, when the page appears and when the window becomes key.
- (void)refreshRunningAppFromServerInfo {
    [self refreshRunningAppFromServerInfoThen:nil];
}

/// The same, and `then` runs on the main queue when the answer has been applied (also when there is nothing to ask,
/// or the host did not answer). Starting an app waits for it: the host's own word on what runs, not the page's last guess.
- (void)refreshRunningAppFromServerInfoThen:(void (^)(void))then {
    TemporaryHost *host = self.host;
    if (host == nil || !host.canUseHttps || host.activeAddress.length == 0 || [ConceptHarness networkMocked]) {
        if (then) then();
        return;
    }
    if ([[StreamingSessionManager shared] isStreamingHost:host.uuid]) {
        if (then) then();
        return;
    }
    @synchronized (self) {
        if (self.runningProbeInFlight && then == nil) return;
        self.runningProbeInFlight = YES;
    }
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        HttpManager *hMan = [[HttpManager alloc] initWithHost:host.activeAddress uniqueId:[IdManager getUniqueId] serverCert:host.serverCert];
        ServerInfoResponse *resp = [[ServerInfoResponse alloc] init];
        // A click waits for this: bounded, the HTTPS ask and its HTTP fallback together 2.5 s (they were 5 s + 2 s
        // each, 14 s on a congested link, and nothing seemed to happen). The stream's own start asks again.
        NSDate *deadline = then != nil ? [NSDate dateWithTimeIntervalSinceNow:2.5] : nil;
        [hMan executeRequestSynchronously:[HttpRequest requestForResponse:resp withUrlRequest:[hMan newServerInfoRequest:NO] fallbackError:401 fallbackRequest:[hMan newHttpServerInfoRequest]]
                                waitSlack:then != nil ? 0 : 2.0 deadline:deadline];
        BOOL reachable = [resp isStatusOk];
        NSString *state = reachable ? [[resp getStringTag:TAG_STATE] trim] : nil;
        NSString *currentGame = reachable ? [[resp getStringTag:TAG_CURRENT_GAME] trim] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            AppsViewController *strongSelf = weakSelf;
            if (strongSelf == nil) return;
            @synchronized (strongSelf) { strongSelf.runningProbeInFlight = NO; }
            void (^finish)(void) = ^{ if (then) then(); };
            if (![strongSelf.host.uuid isEqualToString:host.uuid]) { finish(); return; }
            // an app this client is starting is not on the host's books yet
            if ([[StreamingSessionManager shared] isStreamingHost:host.uuid]) { finish(); return; }
            BOOL changed = NO;
            NSString *runningId = [MLHostSessionPolicy reconciledRunningIdWithCurrent:strongSelf.runningApp.id reachable:reachable state:state currentGame:currentGame changed:&changed];
            if (changed) {
                Log(LOG_I, @"[running] host reports %@ (was %@)", runningId ?: @"no app", strongSelf.runningApp.id ?: @"none");
                strongSelf.host.currentGame = runningId ?: @"0";
                [strongSelf setRunningApp:[strongSelf findRunningApp:strongSelf.host]];
            }
            finish();
        });
    });
}

- (void)updateRunningAppState {
    [self refreshRunningAppFromServerInfo];
    __weak typeof(self) weakSelf = self;
    NSOperation *operation = [NSBlockOperation blockOperationWithBlock:^{
        DiscoveryWorker *worker = [[DiscoveryWorker alloc] initWithHost:weakSelf.host uniqueId:[IdManager getUniqueId]];
        worker.waitsForCommit = YES;   // the running app is read from the record right after
        [worker discoverHost];
        dispatch_async(dispatch_get_main_queue(), ^{
            TemporaryApp *runningApp = [weakSelf findRunningApp:weakSelf.host];
            [weakSelf setRunningApp:runningApp];
        });
    }];
    NSOperationQueue *queue = [[NSOperationQueue alloc] init];
    [queue addOperation:operation];
}

- (BOOL)isSameApp:(TemporaryApp *)lhs asApp:(TemporaryApp *)rhs {
    if (lhs == rhs) {
        return YES;
    }
    if (lhs == nil || rhs == nil) {
        return NO;
    }
    if (lhs.id.length == 0 || rhs.id.length == 0) {
        return NO;
    }
    return [lhs.id isEqualToString:rhs.id];
}

- (BOOL)isAppRunning:(TemporaryApp *)app {
    if (app == nil || app.id.length == 0) {
        return NO;
    }
    if ([self isSameApp:app asApp:self.runningApp]) {
        return YES;
    }
    return self.host.currentGame.length > 0 && [app.id isEqualToString:self.host.currentGame];
}


#pragma mark - Helpers

- (NSSearchField *)getSearchField {
    return self.contentSearchField ?: [self.parentViewController.view.window moonlight_searchFieldInToolbar];
}

- (NSIndexPath *)indexPathForApp:(TemporaryApp *)app {
    if (app != nil) {
        NSInteger section = app.pinned ? 0 : 1;
        NSInteger appIndex = [[self itemsForSection:section] indexOfObject:app];
        if (appIndex >= 0) {
            return [NSIndexPath indexPathForItem:appIndex inSection:section];
        }
    }
    
    return nil;
}

- (AppCell *)cellForApp:(TemporaryApp *)app {
    if (app == nil) {
        return nil;
    }
    
    NSIndexPath *indexPath = [self indexPathForApp:app];
    return (AppCell *)[self.collectionView itemAtIndexPath:indexPath];
}

- (BOOL)askWhetherToStopRunningApp:(TemporaryApp *)currentApp andStartNewApp:(TemporaryApp *)newApp {
    NSAlert *alert = [[NSAlert alloc] init];
    
    alert.alertStyle = NSAlertStyleInformational;
    alert.messageText = [NSString stringWithFormat:NSLocalizedString(@"App Running Alert", @"App Running Alert"), currentApp.name, currentApp.name, newApp.name];
    
    [alert addButtonWithTitle:NSLocalizedString(@"Yes", @"Yes")];
    [alert addButtonWithTitle:NSLocalizedString(@"Cancel", @"Cancel")];
    
    NSModalResponse response = [alert runModal];
    
    return response == NSAlertFirstButtonReturn;
}

- (NSDictionary *)calculateUpateIndexPathsFromOld:(NSArray<TemporaryApp *> *)old toNew:(NSArray<TemporaryApp *> *)new {
    NSMutableSet<NSIndexPath *> *deletions = [NSMutableSet set];
    NSMutableSet<NSIndexPath *> *insertions = [NSMutableSet set];
    NSMutableSet<NSString *> *alreadyAdded = [NSMutableSet setWithCapacity:new.count];
    
    NSUInteger oldIndex = 0;
    NSUInteger newIndex = 0;
    
    while (oldIndex < old.count || newIndex < new.count) {
        if (oldIndex >= old.count) {
            TemporaryApp *newItem = new[newIndex];
            [insertions addObject:[self indexPathForApp:newItem inApps:new atPos:newIndex]];
            [alreadyAdded addObject:newItem.id];
            newIndex++;
        } else if (newIndex >= new.count) {
            TemporaryApp *oldItem = old[oldIndex];
            [deletions addObject:[self indexPathForApp:oldItem inApps:old atPos:oldIndex]];
            oldIndex++;
        } else {
            TemporaryApp *oldItem = old[oldIndex];
            TemporaryApp *newItem = new[newIndex];
            if ([alreadyAdded containsObject:oldItem.id]) {
                [deletions addObject:[self indexPathForApp:oldItem inApps:old atPos:oldIndex]];
                oldIndex++;
            } else {
                NSComparisonResult comparison = [oldItem compare:newItem];
                if (comparison == NSOrderedSame) {
                    [alreadyAdded addObject:newItem.id];
                    oldIndex++;
                    newIndex++;
                } else if (comparison == NSOrderedAscending) {
                    [deletions addObject:[self indexPathForApp:oldItem inApps:old atPos:oldIndex]];
                    oldIndex++;
                } else if (comparison == NSOrderedDescending) {
                    [insertions addObject:[self indexPathForApp:newItem inApps:new atPos:newIndex]];
                    [alreadyAdded addObject:newItem.id];
                    newIndex++;
                }
            }
        }
    }
    
    return @{@"deletions": deletions, @"insertions": insertions};
}

- (NSIndexPath *)indexPathForApp:(TemporaryApp *)app inApps:(NSArray<TemporaryApp *> *)apps atPos:(NSInteger)pos {
    if (app.pinned) {
        return [NSIndexPath indexPathForItem:pos inSection:0];
    } else {
        NSInteger pinnedAppCount = [apps indexOfObjectPassingTest:^BOOL(TemporaryApp * _Nonnull app, NSUInteger idx, BOOL * _Nonnull stop) {
            if (!app.pinned) {
                *stop = YES;
                return YES;
            } else {
                return NO;
            }
        }];
        return [NSIndexPath indexPathForItem:pos - pinnedAppCount inSection:1];
    }
}

- (void)updateCollectionViewDataWithOld:(NSArray<TemporaryApp *> *)old new:(NSArray<TemporaryApp *> *)new {
    [self refreshDeckApps];
    NSDictionary *updates = [self calculateUpateIndexPathsFromOld:old toNew:new];
    NSSet<NSIndexPath *> *deletions = updates[@"deletions"];
    NSSet<NSIndexPath *> *insertions = updates[@"insertions"];
    
    if (deletions.count != 0 || insertions.count != 0) {
        self.apps = [self fetchApps];
        
        [self.collectionView.animator performBatchUpdates:^{
            [self.collectionView deleteItemsAtIndexPaths:deletions];
            [self.collectionView insertItemsAtIndexPaths:insertions];
        } completionHandler:^(BOOL finished) {
            [self.collectionView selectFirstItemForControllerIfNeeded];
        }];
    }
}

- (void)updateCollectionViewWithNewPinnedChangedApp:(TemporaryApp *)app newPinnedState:(BOOL)newPinnedState previousIndex:(NSInteger)previousIndex {
    NSArray<TemporaryApp *> *apps = [self itemsForSection:newPinnedState == YES ? 0 : 1];
    NSArray<NSString *> *appNames = [apps valueForKey:@"name"];
    NSInteger newIndex = [appNames indexOfObject:app.name inSortedRange:NSMakeRange(0, appNames.count) options:NSBinarySearchingInsertionIndex usingComparator:^NSComparisonResult(NSString * _Nonnull obj1, NSString * _Nonnull obj2) {
        return [obj1 caseInsensitiveCompare:obj2];
    }];

    NSIndexPath *previousIndexPath;
    NSIndexPath *newIndexPath;
    if (newPinnedState == YES) {
        newIndexPath = [NSIndexPath indexPathForItem:newIndex inSection:0];
        previousIndexPath = [NSIndexPath indexPathForItem:previousIndex inSection:1];
    } else {
        previousIndexPath = [NSIndexPath indexPathForItem:previousIndex inSection:0];
        newIndexPath = [NSIndexPath indexPathForItem:newIndex inSection:1];
    }
    
    [self.collectionView.animator performBatchUpdates:^{
        [self.collectionView moveItemAtIndexPath:previousIndexPath toIndexPath:newIndexPath];
    } completionHandler:^(BOOL finished) {
    }];
}


#pragma mark - App Discovery

- (void)loadApps {
    self.appManager = [[AppAssetManager alloc] initWithCallback:self];

    // If definitely offline, show overlay immediately and skip app display
    // (the computer-first page shows the cached list, muted, instead)
    if (self.host.state == StateOffline) {
        if ([MLDeckVariant isComputerPage]) {
            // the page shows the cached list, muted; nothing is requested from an offline host
            [self displayApps];
        } else {
            [self showOfflineOverlayIfCurrentHost];
        }
        return;
    }

    if (self.host.appList.count > 0) {
        [self displayApps];
    }

    // Only discover if not definitely offline
    // But we might want to discover if state is Unknown
    [self discoverAppsForHost:self.host];
}

- (NSArray<TemporaryApp *> *)fetchApps {
    NSPredicate *predicate;
    if (self.filterText.length != 0) {
        predicate = [NSPredicate predicateWithFormat:@"name CONTAINS[cd] %@", self.filterText];
    } else {
        predicate = [NSPredicate predicateWithValue:YES];
    }
    NSArray<TemporaryApp *> *filteredApps = [self.host.appList.allObjects filteredArrayUsingPredicate:predicate];
    
    NSArray<TemporaryApp *> *hiddenAwareApps = self.host.showHiddenApps
        ? filteredApps
        : [filteredApps filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"hidden == NO"]];
    
    return [hiddenAwareApps sortedArrayUsingSelector:@selector(compare:)];
}

- (void)displayApps {
    self.apps = [self fetchApps];
    [self refreshDeckApps];
}

- (void)discoverAppsForHost:(TemporaryHost *)host {
    [self discoverAppsForHost:host reason:@"page-open"];
}

- (void)discoverAppsForHost:(TemporaryHost *)host reason:(NSString *)reason {
    if (!host.canUseHttps) {
        // Unpaired, duplicate and old-record hosts have no certificate: asking for the app list is an
        // HTTPS request that cannot succeed (and used to crash). Their page shows the 配对 state instead.
        Log(LOG_I, @"[apps] Not asking %@ for its app list: not paired or no server certificate", host.name ?: @"?");
        return;
    }
    if ([ConceptHarness networkMocked]) {
        return;
    }
    @synchronized (self) {
        if (self.appListFetchInFlight) {
            Log(LOG_D, @"[applist] fetch reason=%@ skipped: one is already running", reason);
            return;
        }
        self.appListFetchInFlight = YES;
    }
    self.lastAppListFetch = [NSDate date];
    void (^finished)(void) = ^{
        @synchronized (self) { self.appListFetchInFlight = NO; }
    };
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        if (host.activeAddress == nil || host.activeAddress.length == 0) {
            finished();
            dispatch_async(dispatch_get_main_queue(), ^{
                if ([self.host.uuid isEqualToString:host.uuid]) {
                    [self requestHostRefresh];
                }
            });
            return;
        }

        NSString *uniqueId = [IdManager getUniqueId];
        // what the host's serverinfo says now: saved with the fetch, so a change DURING the fetch is still seen as a change
        NSString *etagBefore = [MLDeckActivity appListEtagSeenWithHostUUID:host.uuid ?: @""];
        
        AppListResponse* appListResp = [ConnectionHelper getAppListForHost:host uniqueID:uniqueId];
        
        finished();
        if (appListResp == nil || ![appListResp isStatusOk] || [appListResp getAppList] == nil) {
            Log(LOG_W, @"[applist] fetch reason=%@ failed: %@", reason, appListResp.statusMessage);
            dispatch_async(dispatch_get_main_queue(), ^{
                // Don't override host state based on app list failure. Rely on discovery state.
                if ([self.host.uuid isEqualToString:host.uuid]) {
                    [self requestHostRefresh];
                    [self updateOfflineOverlayForCurrentHost];
                }
            });
        } else {
            NSArray<TemporaryApp *> *oldItems = [self fetchApps];

            [self updateApplist:[appListResp getAppList] forHost:host];
            [MLDeckActivity markAppListFetchedWithHostUUID:host.uuid ?: @"" etag:etagBefore];
            Log(LOG_I, @"[applist] fetch reason=%@ count=%lu etag=%@", reason, (unsigned long)[appListResp getAppList].count, etagBefore.length > 0 ? etagBefore : @"-");
            
            AppAssetManager *assetManager = self.appManager;
            [assetManager stopRetrieving];
            [assetManager retrieveAssetsFromHost:host];
            
            dispatch_async(dispatch_get_main_queue(), ^{
                NSArray<TemporaryApp *> *newItems = [self fetchApps];
                [self updateCollectionViewDataWithOld:oldItems new:newItems];
            });
        }
    });
}

- (void) updateApplist:(NSSet*) newList forHost:(TemporaryHost*)host {
    DataManager *database = [[DataManager alloc] init];
    NSMutableSet *newHostAppList = [NSMutableSet setWithSet:host.appList];
    
    for (TemporaryApp* app in newList) {
        BOOL appAlreadyInList = NO;
        for (TemporaryApp* savedApp in newHostAppList) {
            if ([app.id isEqualToString:savedApp.id]) {
                savedApp.name = app.name;
                savedApp.superCommands = app.superCommands;
                savedApp.fsExtras = app.fsExtras;
                appAlreadyInList = YES;
                break;
            }
        }
        if (!appAlreadyInList) {
            app.host = host;
            [newHostAppList addObject:app];
        }
    }
    
    BOOL appWasRemoved;
    do {
        appWasRemoved = NO;
        
        for (TemporaryApp* app in newHostAppList) {
            appWasRemoved = YES;
            for (TemporaryApp* mergedApp in newList) {
                if ([mergedApp.id isEqualToString:app.id]) {
                    appWasRemoved = NO;
                    break;
                }
            }
            if (appWasRemoved) {
                // Removing the app mutates the list we're iterating (which isn't legal).
                // We need to jump out of this loop and restart enumeration.
                
                [newHostAppList removeObject:app];
                
                // It's important to remove the app record from the database
                // since we'll have a constraint violation now that appList
                // doesn't have this app in it.
                [database removeApp:app];
                
                break;
            }
        }
        
        // Keep looping until the list is no longer being mutated
    } while (appWasRemoved);
    
    host.appList = [newHostAppList copy];
    
    [database updateAppsForExistingHost:host];
}


#pragma mark - Image Loading

- (void)updateCellWithImageForApp:(TemporaryApp *)app {
    dispatch_async(dispatch_get_main_queue(), ^{

        NSIndexPath *path = [self indexPathForApp:app];
        AppCell *item = (AppCell *)[self.collectionView itemAtIndexPath:path];
        if (item != nil) {
            
            NSImage* fastCacheImage = [self.boxArtCache objectForKey:app.id];
            if (fastCacheImage != nil) {
                
                [ImageFader transitionImageViewWithOldImageView:item.appCoverArt newImageViewBlock:^NSImageView * _Nonnull {
                    NSImageView *newImageView = [[NSImageView alloc] init];
                    [newImageView smoothRoundCornersWithCornerRadius:APP_CELL_CORNER_RADIUS];
                    
                    return newImageView;
                } duration:0.3 image:fastCacheImage completionBlock:^(NSImageView * _Nonnull newImageView) {
                    item.appCoverArt = newImageView;
                    item.placeholderView.hidden = YES;
                }];
            }
        }
    });
}

// This function forces immediate decoding of the UIImage, rather
// than the default lazy decoding that results in janky scrolling.
+ (OSImage *)loadBoxArtForCaching:(TemporaryApp *)app {
    OSImage *boxArt;
    
    NSData* imageData = [NSData dataWithContentsOfFile:[AppAssetManager boxArtPathForApp:app]];
    if (imageData == nil) {
        // No box art on disk
        return nil;
    }
    
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)imageData, NULL);
    CGImageRef cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil);
    
    size_t width = CGImageGetWidth(cgImage);
    size_t height = CGImageGetHeight(cgImage);
    
    CGSize appArtworkDimensions = [SettingsClass appArtworkDimensionsFor:app.host.uuid];
    CGFloat targetWidth = appArtworkDimensions.width;
    CGFloat targetHeight = appArtworkDimensions.height;
    CGFloat targetAspect = targetWidth / targetHeight;
    CGFloat drawAspect = (CGFloat)width / (CGFloat)height;
    
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef imageContext =  CGBitmapContextCreate(NULL, targetWidth, targetHeight, 8, targetWidth * 4, colorSpace,
                                                       kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(colorSpace);

    if (targetAspect >= drawAspect) {
        CGFloat drawHeight = targetWidth / drawAspect;
        CGFloat yOffset = (targetHeight - drawHeight) / 2.0;
        CGContextDrawImage(imageContext, CGRectMake(0, yOffset, targetWidth, drawHeight), cgImage);
    } else {
        CGFloat drawWidth = targetHeight * drawAspect;
        CGFloat xOffset = (targetWidth - drawWidth) / 2.0;
        CGContextDrawImage(imageContext, CGRectMake(xOffset, 0, drawWidth, targetHeight), cgImage);
    }
    
    CGImageRef outputImage = CGBitmapContextCreateImage(imageContext);

#if TARGET_OS_IPHONE
    boxArt = [UIImage imageWithCGImage:outputImage];
#else
    boxArt = [[NSImage alloc] initWithCGImage:outputImage size:NSMakeSize(targetWidth, targetHeight)];
#endif

    CGImageRelease(outputImage);
    CGContextRelease(imageContext);
    
    CGImageRelease(cgImage);
    CFRelease(source);
    
    return boxArt;
}

- (void)updateBoxArtCacheForApp:(TemporaryApp *)app {
    if ([self.boxArtCache objectForKey:app] == nil) {
        OSImage *image = [AppsViewController loadBoxArtForCaching:app];
        if (image != nil) {
            // Add the image to our cache if it was present
            [self.boxArtCache setObject:image forKey:app.id];
            
            [self updateCellWithImageForApp:app];
        }
    }
}


#pragma mark - AppAssetCallback

- (void)receivedAssetForApp:(TemporaryApp *)app {
    // Update the box art cache now so we don't have to do it
    // on the main thread
    [self updateBoxArtCacheForApp:app];
    dispatch_async(dispatch_get_main_queue(), ^{
        [(MLDeckAppsController *)self.deckApps artArrivedFor:app];
    });
}

#pragma mark - Redesigned apps page (concept)

- (void)deckInstallIfNeeded {
    if (![MLDeckVariant isDeck]) {
        return;
    }
    __weak typeof(self) weakSelf = self;
    MLDeckAppsActions *actions = [[MLDeckAppsActions alloc] init];
    actions.open = ^(TemporaryApp *app) { [weakSelf openApp:app]; };
    actions.quit = ^(TemporaryApp *app) { [weakSelf quitApp:app completion:nil]; };
    actions.pin = ^(TemporaryApp *app) { [weakSelf deckTogglePin:app]; };
    actions.hide = ^(TemporaryApp *app) { [weakSelf deckToggleHidden:app]; };
    actions.wake = ^{
        TemporaryHost *host = weakSelf.host;
        if (host != nil) {
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{ [WakeOnLanManager wakeHost:host]; });
        }
    };
    actions.pair = ^{
        if (weakSelf.host != nil) {
            [[NSNotificationCenter defaultCenter] postNotificationName:@"MLDeckHostCommand" object:nil
                                                              userInfo:@{@"command": @"pair", @"host": weakSelf.host}];
        }
    };
    actions.cancelPair = ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:@"MLDeckHostCommand" object:nil userInfo:@{@"command": @"cancelPair"}];
    };
    actions.defaultAddress = ^NSString *(NSString *uuid) {
        NSString *method = [SettingsClass getSettingsFor:uuid][@"connectionMethod"];
        return ([method isKindOfClass:[NSString class]] && ![method isEqualToString:@"Auto"]) ? method : @"";
    };
    actions.setDefaultAddress = ^(NSString *uuid, NSString *address) {
        // the client's per-host connection method: the stream uses a pinned address (discovery keeps probing the others)
        [SettingsClass setConnectionMethod:address.length > 0 ? address : @"Auto" for:uuid];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"MoonlightRequestHostDiscovery" object:nil userInfo:@{@"uuid": uuid}];
    };
    actions.probeAddress = ^(NSString *address, double timeout, void (^done)(NSNumber *)) {
        if (address.length == 0) { done(nil); return; }
        // the endpoint the computer is actually reached at: its custom port included (the page's address fields do not carry it)
        NSString *target = address;
        NSString *wantedHost = nil;
        [Utils parseAddress:address intoHost:&wantedHost andPort:nil];
        TemporaryHost *probeHost = weakSelf.host;
        for (NSString *endpoint in [ConnectionEndpointStore allEndpointsForHost:probeHost]) {
            NSString *endpointHost = nil;
            [Utils parseAddress:endpoint intoHost:&endpointHost andPort:nil];
            if (endpointHost.length > 0 && [endpointHost caseInsensitiveCompare:wantedHost ?: @""] == NSOrderedSame) { target = endpoint; break; }
        }
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            __block BOOL answered = NO;
            NSDate *start = [NSDate date];
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                // HTTP serverinfo (no pairing needed), through the same HttpManager the discovery uses; nothing of
                // discovery's own state is touched
                HttpManager *manager = [[HttpManager alloc] initWithHost:target uniqueId:[IdManager getUniqueId] serverCert:nil];
                ServerInfoResponse *response = [[ServerInfoResponse alloc] init];
                NSURLRequest *request = [manager newHttpServerInfoRequest:true];
                if (request != nil) {
                    [manager executeRequestSynchronously:[HttpRequest requestForResponse:response withUrlRequest:request]];
                    answered = response.statusCode == 200;
                }
                dispatch_semaphore_signal(sem);
            });
            BOOL finished = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC))) == 0;
            NSInteger total = (NSInteger)([[NSDate date] timeIntervalSinceDate:start] * 1000.0);
            // reachable = serverinfo answered; the latency is the application round trip, not the time of that request
            NSNumber *appRtt = (finished && answered) ? [LatencyProbe appRttMsForAddress:target probeTotalMs:(int)total] : nil;
            done(finished && answered ? (appRtt ?: @(-1)) : nil);
        });
    };
    actions.hostBecameOnline = ^(NSString *uuid) {
        // discovery (the sidebar's truth) says online: the page follows, and loads the apps if it has none
        if ([weakSelf.host.uuid isEqualToString:uuid]) {
            MLLaunchTrace(@"page: host %@ came online", weakSelf.host.displayName);
            weakSelf.host.state = StateOnline;
            [weakSelf updateOfflineOverlayForCurrentHost];
            if (weakSelf.apps.count == 0 && weakSelf.host.canUseHttps) {
                [weakSelf discoverAppsForHost:weakSelf.host];
            }
        }
    };
    actions.appMenu = ^NSMenu *(TemporaryApp *app) { return [weakSelf deckMenuForApp:app]; };
    actions.hostMenu = ^NSMenu *(TemporaryApp *app) { return [weakSelf deckHostMenuForApp:app]; };
    actions.displays = ^NSArray<NSDictionary<NSString *, id> *> * {
        return weakSelf.cachedSunshineDisplays ?: @[];
    };
    actions.connect = ^(NSString *mode, NSString *displayId) {
        [weakSelf deckConnectWithMode:mode displayId:displayId];
    };
    actions.cancelLaunch = ^{ [weakSelf cancelPendingLaunch]; };
    actions.addConnection = ^{ [weakSelf deckAddConnection]; };
    actions.settings = ^{
        if (weakSelf.host != nil) {
            [[NSNotificationCenter defaultCenter] postNotificationName:@"MLDeckHostCommand" object:nil
                                                              userInfo:@{@"command": @"menu", @"host": weakSelf.host, @"action": @"settings"}];
        }
    };
    MLDeckAppsController *deck = [[MLDeckAppsController alloc] initWithStyle:[self deckStyleName] actions:actions];
    self.deckApps = deck;
    NSView *deckView = deck.viewController.view;
    deckView.frame = self.view.bounds;
    deckView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    // A hero's art runs past the page, under the floating sidebar and the toolbar.
    deckView.clipsToBounds = NO;
    self.view.clipsToBounds = NO;
    [self.view addSubview:deckView];
    [self addChildViewController:deck.viewController];
    self.collectionView.enclosingScrollView.hidden = YES;
    [self refreshDeckApps];
}

- (NSString *)deckStyleName {
    NSString *variant = [MLDeckVariant current];
    if ([variant isEqualToString:@"B"]) return @"standalone";
    if ([variant isEqualToString:@"A1"]) return @"games";
    if ([variant isEqualToString:@"A0"]) return @"computer";
    if ([variant isEqualToString:@"A3"]) return @"quiet";
    return @"embedded";
}

- (void)refreshDeckApps {
    if (self.deckApps == nil || self.host == nil) {
        return;
    }
    [(MLDeckAppsController *)self.deckApps updateWithHost:self.host apps:self.apps ?: @[] running:self.runningApp];
}

#pragma mark - The old context menus on the new page

/// The menu the old app cell showed on right-click, rebuilt for the new page: 启动/继续 (new), 固定 / 取消固定,
/// 隐藏 / 显示, 退出应用 (only while it runs), then, through the old code, the Sunshine overrides for this stream
/// (display, screen mode, virtual display, refresh host displays) and the host's SuperCmds.
- (NSMenu *)deckMenuForApp:(TemporaryApp *)app {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
    menu.autoenablesItems = NO;

    NSMenuItem *open = [[NSMenuItem alloc] initWithTitle:[self isAppRunning:app] ? NSLocalizedString(@"Resume App", @"Resume App") : NSLocalizedString(@"Start App", @"Start App")
                                                  action:@selector(deckMenuOpen:) keyEquivalent:@""];
    open.target = self;
    open.representedObject = app;
    MLSetMenuItemImage(open, [NSImage imageWithSystemSymbolName:@"play.fill" accessibilityDescription:nil]);
    [menu addItem:open];
    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *pin = [[NSMenuItem alloc] initWithTitle:@"Pin App" action:@selector(deckMenuPin:) keyEquivalent:@""];
    pin.identifier = @"pinAppMenuItem";
    NSMenuItem *hide = [[NSMenuItem alloc] initWithTitle:@"Hide App" action:@selector(deckMenuHide:) keyEquivalent:@""];
    hide.identifier = @"hideAppMenuItem";
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"Quit App" action:@selector(quitAppMenuItemClicked:) keyEquivalent:@""];
    quit.identifier = @"quitAppMenuItem";
    for (NSMenuItem *item in @[pin, hide]) {
        item.target = self;
        item.representedObject = app;
        [menu addItem:item];
    }
    [menu addItem:[NSMenuItem separatorItem]];
    quit.target = self;
    [menu addItem:quit];

    // titles, images, quit visibility, Sunshine overrides and SuperCmds: the old code, unchanged
    [self didOpenContextMenu:menu forApp:app];
    // 退出应用 sits right under 隐藏, not below the Sunshine overrides: with display and virtual-display
    // submenus it was the last row and went unnoticed.
    [menu removeItem:quit];
    [menu insertItem:quit atIndex:[menu indexOfItem:hide] + 1];
    for (NSMenuItem *item in menu.itemArray) {
        item.enabled = item.enabled || item.submenu != nil;
    }
    if (![self hostCanStreamNow]) {
        // off or not paired: nothing that starts, quits or sends to the host; pinning and hiding are local and stay
        for (NSMenuItem *item in menu.itemArray) {
            if (item.action == @selector(deckMenuOpen:) || item.action == @selector(quitAppMenuItemClicked:) || item.submenu != nil ||
                [item.identifier hasPrefix:@"appSuperCmd"] || [item.identifier hasPrefix:@"sunshine"]) {
                item.enabled = NO;
            }
        }
    }
    return menu;
}

- (void)deckMenuOpen:(NSMenuItem *)item { [self openApp:item.representedObject]; }
- (void)deckMenuPin:(NSMenuItem *)item { [self deckTogglePin:item.representedObject]; }
- (void)deckMenuHide:(NSMenuItem *)item { [self deckToggleHidden:item.representedObject]; }

/// The menu behind the ⋯ button of a computer: everything the old host right-click menu had (唤醒, 休眠,
/// 显示隐藏应用, 重命名…, 移除主机, 设置, 连接详情, 编辑连接), the Sunshine overrides and SuperCmds of the
/// computer's default app. Swift adds 线路 and the connection modes on top.
- (NSMenu *)deckHostMenuForApp:(TemporaryApp *)app {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
    menu.autoenablesItems = NO;
    TemporaryHost *host = self.host;

    void (^add)(NSString *, NSString *, NSString *, BOOL) = ^(NSString *title, NSString *symbol, NSString *action, BOOL enabled) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:@selector(deckHostMenuAction:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = action;
        item.enabled = enabled;
        if (symbol.length > 0) {
            MLSetMenuItemImage(item, [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil]);
        }
        [menu addItem:item];
    };
    // 唤醒 only with a real MAC (not empty, not all zeros)
    NSString *macDigits = [[host.mac componentsSeparatedByCharactersInSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"] invertedSet]] componentsJoinedByString:@""];
    BOOL macKnown = macDigits.length == 12 && [macDigits stringByReplacingOccurrencesOfString:@"0" withString:@""].length > 0;
    add(NSLocalizedString(@"Wake PC", @"Wake PC"), @"power", @"wake", host.state != StateOnline && macKnown);
    add(NSLocalizedString(@"Sleep Host", @"Sleep Host"), @"moon.zzz", @"sleep", host.state == StateOnline && host.pairState == PairStatePaired);
    add(NSLocalizedString(@"Show Hidden Apps", @"Show Hidden Apps"), @"eye", @"showHidden", YES);
    menu.itemArray.lastObject.state = host.showHiddenApps ? NSControlStateValueOn : NSControlStateValueOff;
    add(NSLocalizedString(@"Rename Host…", @"Rename Host…"), @"pencil", @"rename", YES);
    add(NSLocalizedString(@"Change Icon…", @"Change Icon…"), @"photo.on.rectangle", @"icon", YES);
    add(NSLocalizedString(@"Remove Host", @"Remove Host"), @"trash", @"remove", YES);
    [menu addItem:[NSMenuItem separatorItem]];
    add(NSLocalizedString(@"Settings", @"Settings"), @"slider.horizontal.3", @"settings", YES);
    add(NSLocalizedString(@"Connection Details", @"Connection Details"), @"info.circle", @"details", YES);
    add(NSLocalizedString(@"Edit Connections", @"Edit Connections"), @"point.3.connected.trianglepath.dotted", @"editor", YES);

    if (app != nil && host.canUseHttps) {
        // the per-stream overrides and SuperCmds of the old menu, for the default app
        self.sunshineOverrideApp = app;
        [self loadPersistedSunshineTopologyForCurrentApp];
        [self rebuildSunshineOverrideItemsInMenu:menu];
        [self rebuildSuperCommandItemsInMenu:menu forApp:app];
        [self refreshSunshineDisplaysIfNeededForce:NO];
    }
    return menu;
}

/// 添加连接方式…: the same command as ⋯ > 编辑连接, so there is one path to the sheet.
- (void)deckAddConnection {
    if (self.host == nil) return;
    [[NSNotificationCenter defaultCenter] postNotificationName:@"MLDeckHostCommand" object:nil
                                                      userInfo:@{@"command": @"menu", @"host": self.host, @"action": @"editor"}];
}

- (void)deckHostMenuAction:(NSMenuItem *)item {
    NSString *action = item.representedObject;
    if ([action isEqualToString:@"icon"]) {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"MLDeckPageIcon" object:nil userInfo:@{@"uuid": self.host.uuid ?: @""}];
        return;
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:@"MLDeckHostCommand" object:nil
                                                      userInfo:@{@"command": @"menu", @"host": self.host, @"action": action}];
}

- (void)deckTogglePin:(TemporaryApp *)app {
    app.pinned = !app.pinned;
    [[[DataManager alloc] init] updateAppsForExistingHost:self.host];
    [self displayApps];
}

- (void)deckToggleHidden:(TemporaryApp *)app {
    app.hidden = !app.hidden;
    [[[DataManager alloc] init] updateAppsForExistingHost:self.host];
    [self displayApps];
}

#pragma mark - 自定义主页 toolbar item (concept)

- (void)deckInstallToolbarItemIfNeeded {
    if (![MLDeckVariant isComputerPage]) {
        return;
    }
    NSToolbar *toolbar = self.parentViewController.view.window.toolbar;
    if (toolbar == nil) {
        return;
    }
    NSUInteger insertAt = toolbar.items.count;
    for (NSUInteger i = 0; i < toolbar.items.count; i++) {
        NSString *identifier = toolbar.items[i].itemIdentifier;
        if ([identifier isEqualToString:@"CustomizeHomeToolbarItem"]) {
            return;
        }
        if ([identifier isEqualToString:@"PreferencesToolbarItem"]) {
            insertAt = i;
        }
    }
    [toolbar insertItemWithItemIdentifier:@"CustomizeHomeToolbarItem" atIndex:insertAt];
}

- (void)deckRemoveToolbarItem {
    NSToolbar *toolbar = self.parentViewController.view.window.toolbar;
    for (NSInteger i = (NSInteger)toolbar.items.count - 1; i >= 0; i--) {
        if ([toolbar.items[i].itemIdentifier isEqualToString:@"CustomizeHomeToolbarItem"]) {
            [toolbar removeItemAtIndex:i];
        }
    }
}

@end
