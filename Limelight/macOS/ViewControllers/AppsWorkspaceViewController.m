//
//  AppsWorkspaceViewController.m
//  Limelight
//
//  Created by SkyHua on 2025-01-20.
//

#import "AppsWorkspaceViewController.h"
#import "AppsViewController.h"
#import "Moonlight-Swift.h" // Import Swift bridge for HostSidebarViewFactory
#import "DataManager.h"
#import "TemporaryHost.h"

@interface AppsWorkspaceViewController () <AppsViewControllerNavigationDelegate>

@property (nonatomic, strong) AppsViewController *appsViewController;
@property (nonatomic, strong) NSArray<TemporaryHost *> *initialHostsSnapshot;

@end

@implementation AppsWorkspaceViewController

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

    // 1. Create Left Sidebar (SwiftUI)
    // We use the Factory method we created in the Swift file to get an NSHostingController
    __weak typeof(self) weakSelf = self;
                NSViewController *sidebarVC = [HostSidebarViewFactory createSidebarWithSelectedHostUUID:self.initialHost.uuid
                                                                                                                                                                         initialHost:self.initialHost
                                                                                                                                                                     initialHosts:self.initialHostsSnapshot
                                                                                                                                                                 onHostSelected:^(NSString * _Nonnull uuid, NSInteger stateRaw) {
                [weakSelf handleHostSelection:uuid stateRaw:stateRaw];
    }];

    NSSplitViewItem *sidebarItem = [NSSplitViewItem sidebarWithViewController:sidebarVC];
    sidebarItem.minimumThickness = 200;
    sidebarItem.maximumThickness = 300;
    sidebarItem.canCollapse = YES;

    // 2. Create Right Content (AppsViewController)
    // We instantiate from the Main storyboard as before to keep all existing connections valid
    NSStoryboard *storyboard = [NSStoryboard storyboardWithName:@"Main" bundle:nil];
    self.appsViewController = [storyboard instantiateControllerWithIdentifier:@"appsVC"];

    // Configure the appsVC
    self.appsViewController.host = self.initialHost;
    self.appsViewController.navigationDelegate = self; // Set delegate instead of hostsVC reference

    NSSplitViewItem *contentItem = [NSSplitViewItem splitViewItemWithViewController:self.appsViewController];

    // 3. Add items to split view
    [self addSplitViewItem:sidebarItem];
    [self addSplitViewItem:contentItem];

    // Enable state persistence
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

@end
