//
//  AppsWorkspaceViewController.m
//  Limelight
//
//  Created by SkyHua on 2025-01-20.
//

#import "AppsWorkspaceViewController.h"
#import "AppsViewController.h"
#import "MoonlightEnhanced-Swift.h" // Import Swift bridge for HostSidebarViewFactory
#import "DataManager.h"
#import "TemporaryHost.h"
#import "WakeOnLanManager.h"
#import "AppsViewControllerDelegate.h"
#import "MLLaunchTrace.h"

@interface AppsWorkspaceViewController () <AppsViewControllerNavigationDelegate>

@property (nonatomic, strong) AppsViewController *appsViewController;
@property (nonatomic, strong) NSArray<TemporaryHost *> *initialHostsSnapshot;
@property (nonatomic, strong) NSSplitViewItem *hostSidebarItem;
@property (nonatomic, strong) id deckSidebar;
@property (nonatomic, strong) NSViewController *deckStatePane;
@property (nonatomic, copy) NSString *deckStatePaneUUID;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *deckPins;
@property (nonatomic, strong) NSTimer *deckTimer;

@end

@implementation AppsWorkspaceViewController

- (NSString *)currentHostUUID {
    if (self.appsViewController.host.uuid.length > 0) {
        return self.appsViewController.host.uuid;
    }
    return self.initialHost.uuid;
}

- (instancetype)initWithHost:(TemporaryHost *)host {
    return [self initWithHost:host hostsSnapshot:@[]];
}

- (instancetype)initWithHost:(TemporaryHost *)host hostsSnapshot:(NSArray<TemporaryHost *> *)hostsSnapshot {
    self = [super init];
    if (self) {
        _initialHost = host;
        _initialHostsSnapshot = hostsSnapshot ?: @[];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    MLLaunchTrace(@"workspace viewDidLoad host=%@", self.initialHost.displayName);

    // The apps page, instantiated from the Main storyboard as before so its connections stay valid.
    NSStoryboard *storyboard = [NSStoryboard storyboardWithName:@"Main" bundle:nil];
    self.appsViewController = [storyboard instantiateControllerWithIdentifier:@"appsVC"];
    self.appsViewController.host = self.initialHost;
    self.appsViewController.navigationDelegate = self;
    self.appsViewController.pendingLaunchAppId = self.pendingLaunchAppId;

    // Variant B shows the apps page alone; variant A puts the redesigned host list beside it.
    if (![MLDeckVariant isCardsVariant]) {
        __weak typeof(self) weakSelf = self;
        NSViewController *sidebarVC = [self deckSidebarViewController];
        if (sidebarVC == nil) {
            sidebarVC = [HostSidebarViewFactory createSidebarWithSelectedHostUUID:self.initialHost.uuid
                                                                      initialHost:self.initialHost
                                                                     initialHosts:self.initialHostsSnapshot
                                                                   onHostSelected:^(NSString * _Nonnull uuid, NSInteger stateRaw) {
                [weakSelf handleHostSelection:uuid stateRaw:stateRaw];
            }];
        }
        NSSplitViewItem *sidebarItem = [NSSplitViewItem sidebarWithViewController:sidebarVC];
        sidebarItem.minimumThickness = [MLDeckVariant isSidebarVariant] ? 240 : 200;
        sidebarItem.maximumThickness = 300;
        sidebarItem.canCollapse = YES;
        self.hostSidebarItem = sidebarItem;
        [self addSplitViewItem:sidebarItem];
    }

    NSSplitViewItem *contentItem = [NSSplitViewItem splitViewItemWithViewController:self.appsViewController];
    if (@available(macOS 26.0, *)) {
        if ([MLDeckVariant isPolished]) {
            // macOS 26 floats the sidebar over the content; the hero extends under it, so the
            // content gets the sidebar as a safe-area inset. Earlier systems have no floating
            // sidebar: the content sits beside it and needs no inset, so there is nothing to set.
            // The property does not exist before macOS 26; setting it unguarded raised
            // "unrecognized selector" while the main window was loading.
            contentItem.automaticallyAdjustsSafeAreaInsets = YES;
        }
    }
    [self addSplitViewItem:contentItem];

    self.splitView.autosaveName = @"AppsWorkspaceSplitView";
}

- (void)handleHostSelection:(NSString *)hostUUID stateRaw:(NSInteger)stateRaw {
    // Prevent reloading if it's the same host
    if ([self.appsViewController.host.uuid isEqualToString:hostUUID]) {
        return;
    }

    // We need to find the TemporaryHost object for this UUID
    // Since we don't have direct access to the DataManager's list here easily without fetching,
    // let's fetch it. AppsViewController likely has helpers or we can use DataManager.

    // Using DataManager (assuming it's available via bridging or imports in AppsVC context)
    // For now, let's assume we can get it or let AppsViewController handle the lookup if we pass UUID.
    // But AppsVC expects a TemporaryHost object.

    // Let's rely on the fact that we can get hosts from DataManager
    DataManager *dataManager = [[DataManager alloc] init];
    NSArray *hosts = [dataManager getHosts];
    TemporaryHost *selectedHost = nil;

    for (TemporaryHost *h in hosts) {
        if ([h.uuid isEqualToString:hostUUID]) {
            selectedHost = h;
            break;
        }
    }

    if (selectedHost) {
        switch (stateRaw) {
            case 2:
                selectedHost.state = StateOnline;
                break;
            case 1:
                selectedHost.state = StateOffline;
                break;
            default:
                selectedHost.state = StateUnknown;
                break;
        }
        [self.appsViewController switchToHost:selectedHost];
    }
}

#pragma mark - AppsViewControllerDelegate

- (void)appsViewControllerDidRequestBack:(AppsViewController *)controller {
    if ([MLDeckVariant isSidebarVariant]) {
        return;   // the host list is the sidebar; there is no old page to go back to
    }
    // Pass the back request up to the parent (ContainerViewController)
    // We are the child of ContainerViewController (added via transitionToAppsVCWithHost)
    // So we can trigger the transition back to hostsVC here, OR delegate it further up.

    // ContainerViewController expects to transition FROM the current top VC.
    // Currently, `self` (AppsWorkspaceViewController) is the top VC.
    // We need to find the HostsVC to transition TO.

    // Try to find existing HostsViewController in parent's children
    NSViewController *hostsVC = nil;
    for (NSViewController *child in self.parentViewController.childViewControllers) {
        if ([child isKindOfClass:[HostsViewController class]]) {
            hostsVC = child;
            break;
        }
    }

    if (!hostsVC) {
        // Fallback: instantiate a new one if not found (e.g. if it was removed for some reason)
        NSStoryboard *storyboard = [NSStoryboard storyboardWithName:@"Main" bundle:nil];
        hostsVC = [storyboard instantiateControllerWithIdentifier:@"hostsVC"];

        // Adjust frame for new VC
        hostsVC.view.frame = self.view.bounds;
        hostsVC.view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

        [self.parentViewController addChildViewController:hostsVC];
        [self.parentViewController.view addSubview:hostsVC.view];
    } else {
        // Existing VC might need frame adjustment if it was hidden/resized?
        // Usually transitionFromViewController handles the view frame, but safe to set.
        hostsVC.view.frame = self.view.bounds;
        // Ensure it's in view hierarchy if it was removed (transitionFrom removes it)
        // Actually transitionFrom REMOVES the FROM view. It ADDS the TO view.
        // So we don't need to manually addSubview if we use the transition API?
        // The API says "adds toViewController's view to the view hierarchy".
        // So we just need to ensure the VC is a child VC.
    }

    [self.parentViewController transitionFromViewController:self
                                            toViewController:hostsVC
                                                     options:NSViewControllerTransitionSlideRight
                                           completionHandler:^{
        [hostsVC.view.window makeFirstResponder:hostsVC];
        [self removeFromParentViewController];
    }];
}

#pragma mark - Actions

- (IBAction)backButtonClicked:(id)sender {
    // Handle back button from Toolbar when Sidebar or other view is focused
    [self appsViewControllerDidRequestBack:self.appsViewController];
}

- (IBAction)toggleSidebar:(id)sender {
    if (self.hostSidebarItem == nil || !self.hostSidebarItem.canCollapse) {
        return;
    }

    self.hostSidebarItem.animator.collapsed = !self.hostSidebarItem.isCollapsed;
}

// Forward title changes to the window, as ContainerViewController expects
- (void)setTitle:(NSString *)title {
    [super setTitle:title];
    self.view.window.title = title;
}

- (BOOL)becomeFirstResponder {
    if (self.appsViewController) {
        return [self.view.window makeFirstResponder:self.appsViewController];
    }
    return [super becomeFirstResponder];
}

#pragma mark - Redesigned sidebar (concept, variant A)

- (NSViewController *)deckSidebarViewController {
    if (![MLDeckVariant isSidebarVariant]) {
        return nil;
    }
    if (@available(macOS 14.0, *)) {
        __weak typeof(self) weakSelf = self;
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        void (^post)(NSDictionary *) = ^(NSDictionary *info) {
            [center postNotificationName:@"MLDeckHostCommand" object:nil userInfo:info];
        };
        MLDeckHostsActions *actions = [[MLDeckHostsActions alloc] init];
        actions.select = ^(TemporaryHost *host) { [weakSelf deckSelectHost:host]; };
        actions.wake = ^(TemporaryHost *host) {
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{ [WakeOnLanManager wakeHost:host]; });
        };
        actions.pair = ^(TemporaryHost *host) { post(@{@"command": @"pair", @"host": host}); };
        actions.menu = ^(TemporaryHost *host, NSString *action) { post(@{@"command": @"menu", @"host": host, @"action": action}); };
        actions.cleanup = ^(NSArray<TemporaryHost *> *hosts) { post(@{@"command": @"cleanup", @"hosts": hosts}); };
        actions.add = ^{ post(@{@"command": @"add"}); };
        actions.resumeApp = ^(TemporaryHost *host, TemporaryApp *app) {
            [weakSelf deckSelectHost:host];
            [(id<AppsViewControllerDelegate>)weakSelf.appsViewController openApp:app];
        };
        actions.quitApp = ^(TemporaryHost *host, TemporaryApp *app) {
            [weakSelf deckSelectHost:host];
            [(id<AppsViewControllerDelegate>)weakSelf.appsViewController quitApp:app completion:nil];
        };
        MLDeckHostsController *deck = [[MLDeckHostsController alloc] initWithStyle:@"sidebar" actions:actions provider:^NSArray<TemporaryHost *> * {
            NSArray<TemporaryHost *> *live = weakSelf.hostsProvider ? weakSelf.hostsProvider() : nil;
            return live.count > 0 ? live : weakSelf.initialHostsSnapshot;
        }];
        self.deckSidebar = deck;
        self.deckPins = [NSMutableDictionary dictionary];
        [deck selectWithHostUUID:self.initialHost.uuid];
        [center addObserver:self selector:@selector(deckHandlePIN:) name:@"MLDeckPairingPIN" object:nil];
        [center addObserver:self selector:@selector(deckHandleSelect:) name:@"MLDeckSelectHost" object:nil];
        [center addObserver:self selector:@selector(deckReload) name:@"HostLatencyUpdated" object:nil];
        [center addObserver:self selector:@selector(deckReload) name:@"MLDeckHostsChanged" object:nil];
        self.deckTimer = [NSTimer scheduledTimerWithTimeInterval:3.0 target:self selector:@selector(deckReload) userInfo:nil repeats:YES];
        return deck.viewController;
    }
    return nil;
}

- (void)deckReload {
    if (@available(macOS 14.0, *)) {
        [(MLDeckHostsController *)self.deckSidebar reload];
    }
}

- (TemporaryHost *)deckHostForUUID:(NSString *)uuid {
    NSArray<TemporaryHost *> *hosts = self.hostsProvider ? self.hostsProvider() : self.initialHostsSnapshot;
    for (TemporaryHost *host in hosts) {
        if ([host.uuid isEqualToString:uuid]) {
            return host;
        }
    }
    return nil;
}

- (void)deckSelectHost:(TemporaryHost *)host {
    if (@available(macOS 14.0, *)) {
        NSInteger state = [(MLDeckHostsController *)self.deckSidebar hostStateForUUID:host.uuid];
        [self deckHideStatePane];
        if (state == 2 || [MLDeckVariant isComputerPage]) {
            // the computer-first page draws offline and unpaired hosts itself, in the card
            [self.appsViewController switchToHost:host];
        } else {
            [self deckShowStatePaneForHost:host];
        }
    }
}

- (void)deckHandleSelect:(NSNotification *)note {
    if (@available(macOS 14.0, *)) {
        NSString *uuid = note.userInfo[@"uuid"];
        [self deckReload];
        [(MLDeckHostsController *)self.deckSidebar selectWithHostUUID:uuid];
        TemporaryHost *host = [self deckHostForUUID:uuid];
        if (host != nil) {
            [self deckSelectHost:host];
        }
    }
}

- (void)deckHandlePIN:(NSNotification *)note {
    if (@available(macOS 14.0, *)) {
        NSString *uuid = note.userInfo[@"uuid"];
        NSString *pin = note.userInfo[@"pin"];
        if (pin.length > 0) {
            self.deckPins[uuid] = pin;
        } else {
            [self.deckPins removeObjectForKey:uuid];
        }
        [(MLDeckHostsController *)self.deckSidebar setPairingPIN:pin forHostUUID:uuid];
        if (![MLDeckVariant isComputerPage] && [self.deckStatePaneUUID isEqualToString:uuid]) {
            TemporaryHost *host = [self deckHostForUUID:uuid];
            if (host != nil) {
                [self deckShowStatePaneForHost:host];
            }
        }
    }
}

- (void)deckShowStatePaneForHost:(TemporaryHost *)host {
    if (@available(macOS 14.0, *)) {
        [self deckHideStatePane];
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        NSViewController *pane = [MLDeckStatePaneFactory makeWithHost:host pin:self.deckPins[host.uuid] onPair:^{
            [center postNotificationName:@"MLDeckHostCommand" object:nil userInfo:@{@"command": @"pair", @"host": host}];
        } onWake:^{
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{ [WakeOnLanManager wakeHost:host]; });
        }];
        NSView *content = self.appsViewController.view;
        pane.view.frame = content.bounds;
        pane.view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [content addSubview:pane.view];
        [self.appsViewController addChildViewController:pane];
        self.deckStatePane = pane;
        self.deckStatePaneUUID = host.uuid;
        // The window title follows the host shown, also while the apps page sits underneath.
        self.title = host.displayName;
        self.view.window.subtitle = @"";
    }
}

- (void)deckHideStatePane {
    [self.deckStatePane.view removeFromSuperview];
    [self.deckStatePane removeFromParentViewController];
    self.deckStatePane = nil;
    self.deckStatePaneUUID = nil;
}

@end
