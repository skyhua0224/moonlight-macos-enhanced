//
//  HostsViewController.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 22/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import "HostsViewController.h"
#import "HostCell.h"
#import "MLMenuItemImage.h"
#import "HostCellView.h"
#import "HostsViewControllerDelegate.h"
#import "AppsViewController.h"
#import "AppsWorkspaceViewController.h" // Import Workspace VC
#import "AlertPresenter.h"
#import "NSWindow+Moonlight.h"
#import "NSCollectionView+Moonlight.h"
#import "Helpers.h"
#import "NavigatableAlertView.h"
#import "AppDelegateForAppKit.h"
#import "ConnectionEditorViewController.h"

#import "TemporaryHost.h"
#import "MoonlightEnhanced-Swift.h"
#import "Utils.h"
#import "MLLaunchTrace.h"

#import "CryptoManager.h"
#import "IdManager.h"
#import "DiscoveryManager.h"
#import "DataManager.h"
#import "PairManager.h"
#import "WakeOnLanManager.h"
#import "HttpManager.h"
#import "HttpRequest.h"
#import "ServerInfoResponse.h"

#undef NSLocalizedString
#define NSLocalizedString(key, comment) [[LanguageManager shared] localize:key]

@interface HostsViewController ()
/// The window this controller works for: its own view's, or its container's while its view is off-screen.
@property (nonatomic, readonly) NSWindow *hostWindow;
@end

@interface HostsViewController () <NSCollectionViewDataSource, NSCollectionViewDelegate, NSSearchFieldDelegate, NSControlTextEditingDelegate, HostsViewControllerDelegate, DiscoveryCallback, PairCallback, NSMenuItemValidation>
@property (nonatomic, strong) NSArray<TemporaryHost *> *hosts;
@property (nonatomic, strong) TemporaryHost *selectedHost;
@property (nonatomic, strong) NSAlert *pairAlert;
@property (nonatomic, strong) NSAlert *addHostManuallyAlert;

@property (nonatomic, strong) NSArray *hostList;
@property (nonatomic) NSSearchField *getSearchField;
@property (nonatomic, strong) NSSearchField *contentSearchField;

@property (nonatomic, strong) NSOperationQueue *opQueue;
@property (nonatomic, strong) DiscoveryManager *discMan;
@property (nonatomic, copy) NSString *pairingAddressInFlight;
@property (nonatomic, copy) NSString *pairingFallbackAddress;
@property (nonatomic, assign) BOOL pairingFallbackAttempted;
@property (nonatomic, assign) BOOL pairingInProgress;
@property (nonatomic, strong) id deckController;
@property (nonatomic, copy) NSString *pendingLaunchAppId;
@property (nonatomic) BOOL deckDidAutoOpen;
@property (nonatomic, weak) AppsWorkspaceViewController *deckWorkspace;
@property (nonatomic, strong) NSViewController *deckFirstRun;
@property (nonatomic, strong) id deckFirstRunObserver;
@property (nonatomic) BOOL logicStarted;

@end

@implementation HostsViewController

#pragma mark - Lifecycle

- (NSWindow *)hostWindow {
    return self.isViewLoaded && self.view.window != nil ? self.view.window : self.parentViewController.view.window;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    MLLaunchTrace(@"HostsViewController viewDidLoad (classic page: its view is shown)");

    [self installContentSearchField];

    self.collectionView.dataSource = self;
    self.collectionView.delegate = self;
    [self.collectionView registerNib:[[NSNib alloc] initWithNibNamed:@"HostCell" bundle:nil] forItemWithIdentifier:@"HostCell"];

    [self deckStartLogic];
}

/// The logic of the old controller (saved hosts, discovery, pairing, wake, the commands the sidebar
/// forwards). In the sidebar home this is all that runs: the controller is created without its view, so
/// the old page's views are never loaded, let alone shown.
- (void)deckStartLogic {
    if (self.logicStarted) {
        return;
    }
    self.logicStarted = YES;
    self.hosts = [NSArray array];

    [self prepareDiscovery];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(languageChanged:) name:@"LanguageChanged" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(mainSearchTextChanged:) name:@"MoonlightMainSearchTextChanged" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refreshHostDiscovery:) name:@"MoonlightRequestHostDiscovery" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleDiscoveryPreferencesChanged:) name:@"MoonlightDiscoveryPreferencesChanged" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleHostAutoAddressSwitched:) name:@"HostAutoAddressSwitched" object:nil];

    [self deckInstallIfNeeded];
}

- (void)installContentSearchField {
    // Search is rendered by the SwiftUI toolbar view.
}

- (void)mainSearchTextChanged:(NSNotification *)note {
    NSString *text = note.userInfo[@"text"] ?: @"";
    if (@available(macOS 14.0, *)) {
        [(MLDeckHostsController *)self.deckController setFilter:text];
    }
    [self filterHostsByString:text];
    [self.collectionView reloadData];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)languageChanged:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.getSearchField.placeholderString = NSLocalizedString(@"Search Hosts", @"Search Hosts");
        [self.collectionView reloadData];
    });
}

- (void)refreshHostDiscovery:(NSNotification *)note {
    NSString *uuid = note.userInfo[@"uuid"];
    if (uuid) {
        TemporaryHost *targetHost = nil;
        @synchronized(self.hosts) {
            for (TemporaryHost *host in self.hosts) {
                if ([host.uuid isEqualToString:uuid]) {
                    targetHost = host;
                    break;
                }
            }
        }
        
        if (targetHost) {
            [self.discMan resumeDiscoveryForHost:targetHost];
            // Force immediate check
            [self.discMan startDiscovery];
        }
    }
}

- (void)handleDiscoveryPreferencesChanged:(NSNotification *)note {
    if (self.pairingInProgress) {
        return;
    }

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self.discMan stopDiscoveryBlocking];

        dispatch_async(dispatch_get_main_queue(), ^{
            [self retrieveSavedHosts];
            self.discMan = [[DiscoveryManager alloc] initWithHosts:self.hosts andCallback:self];
            [self updateHosts];

            if (self.hostWindow != nil && self.hostWindow.isVisible) {
                [self.discMan startDiscovery];
            }
        });
    });
}

- (void)handleHostAutoAddressSwitched:(NSNotification *)note {
    // No alert, no toast: an automatic switch of address shows only on the host page, where the 线路 chip's
    // 使用中 mark moves and the status line follows (DeckPathChips listens to this notification too).
    MLLaunchTrace(@"address switched automatically: %@ -> %@", note.userInfo[@"oldAddress"] ?: @"?", note.userInfo[@"newAddress"] ?: @"?");
}

- (void)viewWillAppear {
    [super viewWillAppear];
    MLLaunchTrace(@"OLD HOST PAGE viewWillAppear");

    [SettingsWindowObjCBridge syncSelectedProfileWithHostId:nil];
    
    self.parentViewController.title = @"Moonlight";
    self.parentViewController.view.window.subtitle = [Helpers versionNumberString];

    [self.parentViewController.view.window moonlight_toolbarItemForAction:@selector(addHostButtonClicked:)].enabled = YES;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wundeclared-selector"
    [self.parentViewController.view.window moonlight_toolbarItemForAction:@selector(backButtonClicked:)].enabled = NO;
#pragma clang diagnostic pop
    [self.parentViewController.view.window moonlight_toolbarItemForIdentifier:@"SidebarToggleToolbarItem"].enabled = NO;
    
    [self installContentSearchField];
    self.contentSearchField.delegate = self;
    self.contentSearchField.placeholderString = NSLocalizedString(@"Search Hosts", @"Search Hosts");
    NSSearchField *toolbarSearchField = [self.parentViewController.view.window moonlight_searchFieldInToolbar];
    toolbarSearchField.delegate = self;
    toolbarSearchField.placeholderString = self.contentSearchField.placeholderString;
}

- (void)viewDidAppear {
    [super viewDidAppear];
    MLLaunchTrace(@"OLD HOST PAGE viewDidAppear");
    
    [self.discMan startDiscovery];
    [self deckOpenPreferredHostIfNeeded];
}

- (void)viewDidDisappear {
    [super viewDidDisappear];
    
    if (![MLDeckVariant isSidebarVariant]) {
        [self.discMan stopDiscovery];
    }
}

- (BOOL)becomeFirstResponder {
    if (!self.isViewLoaded) {
        return [super becomeFirstResponder];
    }
    [self.hostWindow makeFirstResponder:self.collectionView];
    return [super becomeFirstResponder];
}

- (AppsWorkspaceViewController *)deckMakeWorkspaceForHost:(TemporaryHost *)host {
    [SettingsWindowObjCBridge syncSelectedProfileWithHostId:host.uuid];

    NSArray<TemporaryHost *> *hostsSnapshot = self.hosts ?: @[];
    AppsWorkspaceViewController *workspaceVC = [[AppsWorkspaceViewController alloc] initWithHost:host hostsSnapshot:hostsSnapshot];
    workspaceVC.pendingLaunchAppId = self.pendingLaunchAppId;
    self.pendingLaunchAppId = nil;
    __weak typeof(self) weakSelf = self;
    workspaceVC.hostsProvider = ^NSArray<TemporaryHost *> * {
        return weakSelf.hostList.count > 0 ? weakSelf.hostList : weakSelf.hosts;
    };
    self.deckWorkspace = workspaceVC;
    [SettingsClass loadMoonlightSettingsFor:host.uuid];
    return workspaceVC;
}

- (void)transitionToAppsVCWithHost:(TemporaryHost *)host {
    if ([MLDeckVariant isSidebarVariant]) {
        // the home is already on screen: selecting a host is a change of selection, never an animated hop
        MLLaunchTrace(@"transitionToAppsVCWithHost ignored in the sidebar home; selecting %@", host.displayName);
        [[NSNotificationCenter defaultCenter] postNotificationName:@"MLDeckSelectHost" object:nil userInfo:@{@"uuid": host.uuid ?: @""}];
        return;
    }
    MLLaunchTrace(@"transitionToAppsVCWithHost (animated, old list -> workspace)");
    AppsWorkspaceViewController *workspaceVC = [self deckMakeWorkspaceForHost:host];

    [self.parentViewController addChildViewController:workspaceVC];
    [self.parentViewController.view addSubview:workspaceVC.view];

    workspaceVC.view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    workspaceVC.view.frame = self.view.bounds;

    [self.parentViewController.view.window makeFirstResponder:nil];

    [self.parentViewController transitionFromViewController:self toViewController:workspaceVC options:NSViewControllerTransitionSlideLeft completionHandler:^{
        [self.parentViewController.view.window makeFirstResponder:workspaceVC];
    }];
}

#pragma mark - Sidebar home without the old page

- (void)deckInstallHomeIntoContainer:(NSViewController *)container {
    [self deckStartLogic];   // saved hosts and discovery; this controller has no view loaded
    self.deckDidAutoOpen = YES;
    [self.discMan startDiscovery];
    if (@available(macOS 14.0, *)) {
        TemporaryHost *host = [MLDeckHostPicker preferredFrom:self.hosts];
        if (host != nil) {
            [self deckEmbedWorkspaceForHost:host intoContainer:container];
            return;
        }
        [self deckEmbedFirstRunIntoContainer:container];
    }
}

- (void)deckEmbedWorkspaceForHost:(TemporaryHost *)host intoContainer:(NSViewController *)container {
    AppsWorkspaceViewController *workspaceVC = [self deckMakeWorkspaceForHost:host];
    MLLaunchTrace(@"install AppsWorkspaceViewController (home) host=%@ firstRunReplaced=%d", host.displayName, self.deckFirstRun != nil);
    [container addChildViewController:workspaceVC];
    workspaceVC.view.frame = container.view.bounds;
    workspaceVC.view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    NSViewController *firstRun = self.deckFirstRun;
    if (self.deckFirstRunObserver != nil) {
        [[NSNotificationCenter defaultCenter] removeObserver:self.deckFirstRunObserver];
        self.deckFirstRunObserver = nil;
    }
    if (firstRun != nil) {
        // the first-run page gives way to the home of the chosen host
        [container.view addSubview:workspaceVC.view positioned:NSWindowBelow relativeTo:firstRun.view];
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = 0.2;
            firstRun.view.animator.alphaValue = 0;
        } completionHandler:^{
            [firstRun.view removeFromSuperview];
            [firstRun removeFromParentViewController];
        }];
        self.deckFirstRun = nil;
    } else {
        [container.view addSubview:workspaceVC.view];
    }
    [container.view.window makeFirstResponder:workspaceVC];
}

- (void)deckEmbedFirstRunIntoContainer:(NSViewController *)container {
    if (@available(macOS 14.0, *)) {
        __weak typeof(self) weakSelf = self;
        __weak NSViewController *weakContainer = container;
        NSViewController *firstRun = [MLDeckFirstRun makeWithProvider:^NSArray<TemporaryHost *> * {
            return weakSelf.hostList.count > 0 ? weakSelf.hostList : weakSelf.hosts;
        } onAdd:^{
            [weakSelf addHostButtonClicked:nil];
        } onSelect:^(TemporaryHost *host) {
            weakSelf.selectedHost = host;
            if (weakContainer != nil) {
                [weakSelf deckEmbedWorkspaceForHost:host intoContainer:weakContainer];
            }
        }];
        // a computer added by address is opened at once (its home, with 配对 in the card)
        self.deckFirstRunObserver = [[NSNotificationCenter defaultCenter] addObserverForName:@"MLDeckSelectHost" object:nil
                                                                                     queue:NSOperationQueue.mainQueue
                                                                                usingBlock:^(NSNotification *note) {
            NSString *uuid = note.userInfo[@"uuid"];
            for (TemporaryHost *candidate in weakSelf.hosts) {
                if ([candidate.uuid isEqualToString:uuid] && weakContainer != nil) {
                    [weakSelf deckEmbedWorkspaceForHost:candidate intoContainer:weakContainer];
                    break;
                }
            }
        }];
        MLLaunchTrace(@"install first-run page (no saved host)");
        [container addChildViewController:firstRun];
        firstRun.view.frame = container.view.bounds;
        firstRun.view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [container.view addSubview:firstRun.view];
        self.deckFirstRun = firstRun;
    }
}


#pragma mark - NSResponder

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    // Forward validate to collectionView, because for some reason it doesn't get called
    // automatically by the system when expected (even though it's firstResponder).
    return [self.collectionView validateMenuItem:menuItem];
}


#pragma mark - Actions

- (IBAction)wakeMenuItemClicked:(NSMenuItem *)sender {
    TemporaryHost *host = [self getHostFromMenuItem:sender];
    if (host != nil) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [WakeOnLanManager wakeHost:host];
        });
    }
}

- (IBAction)removeHostMenuItemClicked:(NSMenuItem *)sender {
    TemporaryHost *host = [self getHostFromMenuItem:sender];
    if (host != nil) {
        [self.discMan removeHostFromDiscovery:host];
        DataManager* dataMan = [[DataManager alloc] init];
        [dataMan removeHost:host];
        self.hosts = [self.hosts filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id  _Nullable evaluatedObject, NSDictionary<NSString *,id> * _Nullable bindings) {
            return evaluatedObject != host;
        }]];
        [self updateHosts];
    }
}

- (IBAction)showHiddenAppsMenuItemClicked:(NSMenuItem *)sender {
    TemporaryHost *host = [self getHostFromMenuItem:sender];
    if (host != nil) {
        if (sender.state == NSControlStateValueOn) {
            sender.state = NSControlStateValueOff;
            host.showHiddenApps = NO;
        } else {
            sender.state = NSControlStateValueOn;
            host.showHiddenApps = YES;
        }
    }
}

- (IBAction)open:(NSMenuItem *)sender {
    TemporaryHost *host = [self getHostFromMenuItem:sender];
    if (host == nil) {
        if (self.collectionView.selectionIndexes.count != 0) {
            host = self.hosts[self.collectionView.selectionIndexes.firstIndex];
        }
    }
    [self openHost:host];
}

- (IBAction)addHostButtonClicked:(id)sender {
    if ([MLDeckVariant isSidebarVariant]) {
        [self deckPresentAddHost];
        return;
    }
    NSAlert *alert = [[NSAlert alloc] init];
    
    alert.alertStyle = NSAlertStyleInformational;
    alert.messageText = NSLocalizedString(@"Add Host Manually", @"Add Host Manually");
    alert.informativeText = NSLocalizedString(@"Add Host Info", @"Add Host Info");

    NSTextField *inputField = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 200, 24)];
    inputField.identifier = @"addHostField";
    inputField.placeholderString = NSLocalizedString(@"IP address", @"IP address");
    inputField.delegate = self;
    [alert setAccessoryView:inputField];

    [alert addButtonWithTitle:NSLocalizedString(@"Add", @"Add")];
    [alert addButtonWithTitle:NSLocalizedString(@"Cancel", @"Cancel")];
    
    alert.buttons.firstObject.enabled = NO;
    
    [alert beginSheetModalForWindow:self.hostWindow completionHandler:^(NSModalResponse returnCode) {
        if (returnCode == NSAlertFirstButtonReturn) {
            [self addHostManuallyHandlerWithInputValue:inputField.stringValue];
        }
        self.addHostManuallyAlert = nil;
        [self.hostWindow endSheet:alert.window];
    }];
    [alert.accessoryView becomeFirstResponder];
    
    self.addHostManuallyAlert = alert;
}

- (void)addHostManuallyHandlerWithInputValue:(NSString *)inputValue {
    __weak typeof(self) weakSelf = self;
    [self addHostWithAddress:inputValue completion:^(NSString *error, TemporaryHost *host) {
        if (host != nil) {
            [weakSelf deckAddedHost:host];
        } else {
            [AlertPresenter displayAlert:NSAlertStyleWarning title:NSLocalizedString(@"Add Host Manually", @"Add Host Manually") message:error window:weakSelf.hostWindow completionHandler:nil];
        }
    }];
}

/// Asks the address for its serverinfo and, if it answers, saves it as a computer. The completion runs on
/// the main thread with an error message, or the host (an already known one comes back as it is).
- (void)addHostWithAddress:(NSString *)address completion:(void (^)(NSString *_Nullable error, TemporaryHost *_Nullable host))completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        [self.discMan discoverHost:address withCallback:^(TemporaryHost *host, NSString *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (host == nil) {
                    completion(error ?: @"", nil);
                    return;
                }
                for (TemporaryHost *known in self.hosts) {
                    if ([known.uuid isEqualToString:host.uuid]) {
                        completion(nil, known);
                        return;
                    }
                }
                DataManager *dataMan = [[DataManager alloc] init];
                [dataMan updateHost:host];
                self.hosts = [self.hosts arrayByAddingObject:host];
                [self updateHosts];
                completion(nil, host);
            });
        }];
    });
}

- (void)deckPresentAddHost {
    if (@available(macOS 14.0, *)) {
        __weak typeof(self) weakSelf = self;
        MLLaunchTrace(@"add computer: sheet");
        [MLDeckAddHost presentIn:self.hostWindow provider:^NSArray<TemporaryHost *> * {
            return weakSelf.hostList.count > 0 ? weakSelf.hostList : (weakSelf.hosts ?: @[]);
        } onSubmit:^(NSString *address, void (^done)(NSString *_Nullable, TemporaryHost *_Nullable)) {
            [weakSelf addHostWithAddress:address completion:done];
        } onChosen:^(TemporaryHost *host) {
            [weakSelf deckAddedHost:host];
        }];
    }
}

/// A computer was added or picked: show it, and for one that is not paired go straight into pairing (the
/// PIN appears in its card).
- (void)deckAddedHost:(TemporaryHost *)host {
    if (host.uuid.length == 0) {
        return;
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:@"MLDeckSelectHost" object:nil userInfo:@{@"uuid": host.uuid}];
    if (host.pairState != PairStatePaired) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            self.selectedHost = host;
            [self setupPairing:host];
        });
    }
}


#pragma mark - NSCollectionViewDataSource

- (nonnull NSCollectionViewItem *)collectionView:(nonnull NSCollectionView *)collectionView itemForRepresentedObjectAtIndexPath:(nonnull NSIndexPath *)indexPath {
    HostCell *item = [collectionView makeItemWithIdentifier:@"HostCell" forIndexPath:indexPath];
    
    TemporaryHost *host = self.hosts[indexPath.item];
    item.hostName.stringValue = host.displayName;
    item.host = host;
    item.delegate = self;
    
    [item updateHostState];
    
    return item;
}

- (NSInteger)collectionView:(nonnull NSCollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return self.hosts.count;
}


#pragma mark - NSCollectionViewDelegate

- (void)collectionView:(NSCollectionView *)collectionView didSelectItemsAtIndexPaths:(NSSet<NSIndexPath *> *)indexPaths {
}


#pragma mark - NSSearchFieldDelegate, NSControlTextEditingDelegate

- (void)controlTextDidChange:(NSNotification *)obj {
    NSControl *control = (NSControl *)(obj.object);
    if ([control.identifier isEqualToString:@"addHostField"]) {
        self.addHostManuallyAlert.buttons.firstObject.enabled = control.stringValue.length != 0;
    } else {
        [self filterHostsByString:((NSTextField *)obj.object).stringValue];
    }
}


#pragma mark - HostsViewControllerDelegate

- (void)openHost:(TemporaryHost *)host {
    self.selectedHost = host;
    
    if (host.state == StateOnline) {
        if (host.pairState == PairStatePaired) {
            [self transitionToAppsVCWithHost:host];
        } else {
            [self setupPairing:host];
        }
    } else {
        [self handleOfflineHost:host];
    }
}

- (void)didOpenContextMenu:(NSMenu *)menu forHost:(TemporaryHost *)host {
    NSMenuItem *wakeMenuItem = [HostsViewController getMenuItemForIdentifier:@"wakeMenuItem" inMenu:menu];
    NSMenuItem *showHiddenAppsMenuItem = [HostsViewController getMenuItemForIdentifier:@"showHiddenAppsMenuItem" inMenu:menu];
    NSMenuItem *removeHostMenuItem = [HostsViewController getMenuItemForIdentifier:@"removeHostMenuItem" inMenu:menu];
    wakeMenuItem.title = NSLocalizedString(@"Wake PC", @"Wake PC");
    showHiddenAppsMenuItem.title = NSLocalizedString(@"Show Hidden Apps", @"Show Hidden Apps");
    removeHostMenuItem.title = NSLocalizedString(@"Remove Host", @"Remove Host");

    if (wakeMenuItem != nil) {
        wakeMenuItem.enabled = (host.state != StateOnline);
    }
    showHiddenAppsMenuItem.state = host.showHiddenApps ? NSControlStateValueOn : NSControlStateValueOff;

    for (NSString *identifier in @[ @"sleepHostItem", @"renameItem", @"advancedSeparator", @"settingsItem", @"detailsItem", @"connectionsItem" ]) {
        NSMenuItem *existingItem = [HostsViewController getMenuItemForIdentifier:identifier inMenu:menu];
        if (existingItem != nil) {
            [menu removeItem:existingItem];
        }
    }

    if (wakeMenuItem != nil) {
        NSMenuItem *sleepItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Sleep Host", @"Sleep Host")
                                                           action:@selector(sleepHostMenuItemClicked:)
                                                    keyEquivalent:@""];
        sleepItem.target = self;
        sleepItem.identifier = @"sleepHostItem";
        sleepItem.enabled = (host.state == StateOnline && host.pairState == PairStatePaired);
        MLSetMenuItemImage(sleepItem, [NSImage imageWithSystemSymbolName:@"moon.zzz" accessibilityDescription:nil]);
        [menu insertItem:sleepItem atIndex:[menu indexOfItem:wakeMenuItem] + 1];
    }

    NSInteger removeHostIndex = removeHostMenuItem ? [menu indexOfItem:removeHostMenuItem] : menu.numberOfItems;

    NSMenuItem *renameItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Rename Host…", @"Rename Host…")
                                                        action:@selector(renameHostMenuItemClicked:)
                                                 keyEquivalent:@""];
    renameItem.target = self;
    renameItem.identifier = @"renameItem";
    [menu insertItem:renameItem atIndex:removeHostIndex];

    NSInteger insertionIndex = removeHostMenuItem ? [menu indexOfItem:removeHostMenuItem] + 1 : menu.numberOfItems;
    NSMenuItem *advancedSeparator = [NSMenuItem separatorItem];
    advancedSeparator.identifier = @"advancedSeparator";
    [menu insertItem:advancedSeparator atIndex:insertionIndex++];

    NSMenuItem *settingsItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Settings", @"Settings") action:@selector(openHostSettings:) keyEquivalent:@""];
    [settingsItem setTarget:self];
    settingsItem.identifier = @"settingsItem";
    [menu insertItem:settingsItem atIndex:insertionIndex++];

    NSMenuItem *detailsItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Connection Details", @"Connection Details") action:@selector(showConnectionDetails:) keyEquivalent:@""];
    [detailsItem setTarget:self];
    detailsItem.identifier = @"detailsItem";
    [menu insertItem:detailsItem atIndex:insertionIndex++];

    NSMenuItem *connectionsItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Edit Connections", @"Edit Connections") action:@selector(showConnectionEditor:) keyEquivalent:@""];
    [connectionsItem setTarget:self];
    connectionsItem.identifier = @"connectionsItem";
    [menu insertItem:connectionsItem atIndex:insertionIndex];
}

- (void)sleepHostMenuItemClicked:(NSMenuItem *)sender {
    TemporaryHost *host = [self getHostFromMenuItem:sender];
    if (host == nil || self.hostWindow == nil) {
        return;
    }

    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = [NSString stringWithFormat:NSLocalizedString(@"Sleep Host Title", @"Sleep Host Title"), host.displayName];
    alert.informativeText = NSLocalizedString(@"Sleep Host Info", @"Sleep Host Info");
    [alert addButtonWithTitle:NSLocalizedString(@"Sleep Host", @"Sleep Host")];
    [alert addButtonWithTitle:NSLocalizedString(@"Cancel", @"Cancel")];

    [alert beginSheetModalForWindow:self.hostWindow completionHandler:^(NSModalResponse returnCode) {
        if (returnCode != NSAlertFirstButtonReturn) {
            return;
        }

        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            if (!host.canUseHttps) {
                return;
            }
            HttpManager *hMan = [[HttpManager alloc] initWithHost:host.activeAddress uniqueId:[IdManager getUniqueId] serverCert:host.serverCert];
            if ([hMan requestHostSleep]) {
                return;
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                [AlertPresenter displayAlert:NSAlertStyleWarning
                                       title:NSLocalizedString(@"Sleep Host Failed", @"Sleep Host Failed")
                                     message:NSLocalizedString(@"Sleep Host Failed Info", @"Sleep Host Failed Info")
                                      window:self.hostWindow
                           completionHandler:nil];
            });
        });
    }];
}

- (void)renameHostMenuItemClicked:(NSMenuItem *)sender {
    TemporaryHost *host = [self getHostFromMenuItem:sender];
    if (host == nil) {
        return;
    }

    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleInformational;
    alert.messageText = NSLocalizedString(@"Rename Host", @"Rename Host");
    alert.informativeText = NSLocalizedString(@"Rename Host Info", @"Rename Host Info");

    NSTextField *inputField = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 320, 24)];
    inputField.placeholderString = NSLocalizedString(@"Custom Host Name", @"Custom Host Name");
    inputField.stringValue = host.customName.length > 0 ? host.customName : host.displayName;
    alert.accessoryView = inputField;
    [alert addButtonWithTitle:NSLocalizedString(@"Save", @"Save")];
    [alert addButtonWithTitle:NSLocalizedString(@"Cancel", @"Cancel")];

    [alert beginSheetModalForWindow:self.hostWindow completionHandler:^(NSModalResponse returnCode) {
        if (returnCode == NSAlertFirstButtonReturn) {
            NSString *trimmedName = [inputField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            host.customName = trimmedName.length > 0 ? trimmedName : nil;

            DataManager *dataManager = [[DataManager alloc] init];
            [dataManager updateHost:host];
            [self updateHosts];
        }
    }];

    dispatch_async(dispatch_get_main_queue(), ^{
        [alert.window makeFirstResponder:inputField];
        [inputField selectText:nil];
    });
}

- (void)openHostSettings:(NSMenuItem *)sender {
    TemporaryHost *host = [self getHostFromMenuItem:sender];
    if (host != nil) {
        AppDelegateForAppKit *appDelegate = (AppDelegateForAppKit *)[NSApplication sharedApplication].delegate;
        [appDelegate showPreferencesForHost:host.uuid];
    }
}

- (void)showConnectionDetails:(NSMenuItem *)sender {
    TemporaryHost *host = [self getHostFromMenuItem:sender];
    if (host == nil) {
        return;
    }

    ConnectionDetailsViewController *detailsVC = [[ConnectionDetailsViewController alloc] initWithHost:host];
    [self deckPresentSheet:detailsVC];
}

/// A sheet from the window that is on screen. The sidebar variant's commands land here while this page is NOT the one on
/// screen (the apps page is); a sheet presented by a view controller that is not in the visible hierarchy is dropped without
/// a word, which is why 编辑连接 did nothing from the apps page. The window's own content controller presents it, one run
/// loop later so a menu that is still closing does not swallow it.
- (void)deckPresentSheet:(NSViewController *)sheet {
    NSWindow *window = NSApp.keyWindow ?: NSApp.mainWindow ?: self.view.window;
    if (window == nil) {
        // an app with no key window (it was started in the background, or another app has the focus) still has its window on screen
        for (NSWindow *candidate in NSApp.windows) {
            if (candidate.isVisible && candidate.contentViewController != nil && candidate.canBecomeMainWindow) { window = candidate; break; }
        }
    }
    NSViewController *presenter = window.contentViewController ?: self;
    if (presenter.view.window == nil) {
        // presenting from a view controller that is not in a window throws (NSViewControllerSheetTransition)
        Log(LOG_W, @"[ui] no window to present %@ from", NSStringFromClass([sheet class]));
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (window.attachedSheet != nil) {
            Log(LOG_W, @"[ui] a sheet is already open on this window; %@ not presented", NSStringFromClass([sheet class]));
            return;
        }
        [presenter presentViewControllerAsSheet:sheet];
        Log(LOG_I, @"[ui] presented %@ from %@ (window %@)", NSStringFromClass([sheet class]), NSStringFromClass([presenter class]), window.title ?: @"");
    });
}

- (void)showConnectionEditor:(NSMenuItem *)sender {
    TemporaryHost *host = [self getHostFromMenuItem:sender];
    if (host == nil) {
        return;
    }

    ConnectionEditorViewController *editorVC = [[ConnectionEditorViewController alloc] initWithHost:host];
    [self deckPresentSheet:editorVC];
}


#pragma mark - Helpers

- (NSSearchField *)getSearchField {
    return self.contentSearchField ?: [self.parentViewController.view.window moonlight_searchFieldInToolbar];
}

- (TemporaryHost *)getHostFromMenuItem:(NSMenuItem *)item {
    if ([item.representedObject isKindOfClass:[TemporaryHost class]]) {
        return item.representedObject;
    }
    HostCellView *hostCellView = (HostCellView *)(item.menu.delegate);
    HostCell *hostCell = (HostCell *)(hostCellView.delegate);
    
    return hostCell.host;
}

+ (NSMenuItem *)getMenuItemForIdentifier:(NSString *)id inMenu:(NSMenu *)menu {
    for (NSMenuItem *item in menu.itemArray) {
        if ([item.identifier isEqualToString:id]) {
            return item;
        }
    }
    
    return nil;
}


#pragma mark - Host Discovery

- (void)prepareDiscovery {
    // Set up crypto
    [CryptoManager generateKeyPairUsingSSL];
    
    self.opQueue = [[NSOperationQueue alloc] init];
    
    [self retrieveSavedHosts];
    self.discMan = [[DiscoveryManager alloc] initWithHosts:self.hosts andCallback:self];
}

- (void)retrieveSavedHosts {
    DataManager* dataMan = [[DataManager alloc] init];
    [dataMan removeHostsWithEmptyUuid];
    NSArray* hosts = [dataMan getHosts];
    @synchronized(self.hosts) {
        // Sort the host list in alphabetical order
        self.hosts = [hosts sortedArrayUsingSelector:@selector(compareName:)];
        
        // Initialize the non-persistent host state
        for (TemporaryHost* host in self.hosts) {
            if (host.activeAddress == nil) {
                host.activeAddress = host.localAddress;
            }
            if (host.activeAddress == nil) {
                host.activeAddress = host.externalAddress;
            }
            if (host.activeAddress == nil) {
                host.activeAddress = host.address;
            }
        }
    }
}

- (void)updateHosts {
    Log(LOG_I, @"Updating hosts...");
    @synchronized (self.hosts) {
        // Sort the host list in alphabetical order
        self.hosts = [self.hosts sortedArrayUsingSelector:@selector(compareName:)];
        self.hostList = self.hosts;
        [self.collectionView moonlight_reloadDataKeepingSelection];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"MLDeckHostsChanged" object:nil];
        if (@available(macOS 14.0, *)) {
            [(MLDeckHostsController *)self.deckController reload];
        }
    }
}

- (void)filterHostsByString:(NSString *)filterString {
    NSPredicate *predicate;
    if (filterString.length != 0) {
        predicate = [NSPredicate predicateWithBlock:^BOOL(TemporaryHost *evaluatedHost, NSDictionary<NSString *,id> * _Nullable bindings) {
            return [evaluatedHost.displayName rangeOfString:filterString options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch].location != NSNotFound ||
                   [evaluatedHost.name rangeOfString:filterString options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch].location != NSNotFound;
        }];
    } else {
        predicate = [NSPredicate predicateWithValue:YES];
    }
    NSArray<TemporaryHost *> *filteredHosts = [self.hostList filteredArrayUsingPredicate:predicate];
    self.hosts = [filteredHosts sortedArrayUsingSelector:@selector(compareName:)];

    [self.collectionView reloadData];
}


#pragma mark - Host Operations

- (BOOL)isStandardGameStreamPort:(NSString *)port {
    return [port isEqualToString:@"47989"] || [port isEqualToString:@"47984"];
}

- (BOOL)isDecimalPortString:(NSString *)port {
    if (port.length == 0 || port.length > 5) {
        return NO;
    }
    NSCharacterSet *digits = [NSCharacterSet decimalDigitCharacterSet];
    return [port rangeOfCharacterFromSet:[digits invertedSet]].location == NSNotFound;
}

- (NSString *)joinHost:(NSString *)host withPort:(NSInteger)port {
    if (host.length == 0 || port <= 0) {
        return nil;
    }
    if ([host containsString:@":"] && ![host hasPrefix:@"["]) {
        return [NSString stringWithFormat:@"[%@]:%ld", host, (long)port];
    }
    return [NSString stringWithFormat:@"%@:%ld", host, (long)port];
}

- (NSString *)hostOnlyAddress:(NSString *)address {
    if (address.length == 0) {
        return nil;
    }
    NSString *hostPart = nil;
    [Utils parseAddress:address intoHost:&hostPart andPort:nil];
    return hostPart.length > 0 ? hostPart : address;
}

- (BOOL)isValidPairingEndpoint:(NSString *)candidate forHost:(TemporaryHost *)host {
    if (candidate.length == 0) {
        return NO;
    }

    HttpManager *probeManager = [[HttpManager alloc] initWithHost:candidate
                                                          uniqueId:[IdManager getUniqueId]
                                                        serverCert:host.serverCert];
    ServerInfoResponse *resp = [[ServerInfoResponse alloc] init];
    [probeManager executeRequestSynchronously:[HttpRequest requestForResponse:resp
                                                               withUrlRequest:[probeManager newServerInfoRequest:true]
                                                                 fallbackError:401
                                                               fallbackRequest:[probeManager newHttpServerInfoRequest:true]]];
    if (![resp isStatusOk]) {
        return NO;
    }

    if (host.uuid.length == 0) {
        return YES;
    }
    NSString *respUuid = [resp getStringTag:TAG_UNIQUE_ID];
    return respUuid.length > 0 && [respUuid isEqualToString:host.uuid];
}

- (NSString *)resolvePairingAddressForHost:(TemporaryHost *)host {
    NSString *active = host.activeAddress ?: @"";
    NSString *activeHost = nil;
    NSString *activePort = nil;
    [Utils parseAddress:active intoHost:&activeHost andPort:&activePort];

    NSMutableOrderedSet<NSString *> *candidates = [[NSMutableOrderedSet alloc] init];
    BOOL addedActive = NO;
    // If active endpoint accidentally points to WebUI (e.g. 47990/49990/57990),
    // prioritize the previous port for pairing because Sunshine GameStream APIs
    // are commonly exposed on that port.
    if (activeHost.length > 0 && [self isDecimalPortString:activePort]) {
        NSInteger p = [activePort integerValue];
        BOOL likelyWebUiPort = [activePort hasSuffix:@"90"];
        if (likelyWebUiPort && p > 1) {
            NSString *previousPortCandidate = [self joinHost:activeHost withPort:(p - 1)];
            if (previousPortCandidate.length > 0) {
                [candidates addObject:previousPortCandidate];
            }
        }
        if (active.length > 0) {
            [candidates addObject:active];
            addedActive = YES;
        }
        if (!likelyWebUiPort && p > 1) {
            NSString *previousPortCandidate = [self joinHost:activeHost withPort:(p - 1)];
            if (previousPortCandidate.length > 0) {
                [candidates addObject:previousPortCandidate];
            }
        }
        if ([self isStandardGameStreamPort:activePort]) {
            [candidates addObject:activeHost];
        }
    }
    if (!addedActive && active.length > 0) {
        [candidates addObject:active];
    }

    NSString *localHost = [self hostOnlyAddress:host.localAddress];
    if (localHost.length > 0) {
        [candidates addObject:localHost];
    }
    NSString *primaryHost = [self hostOnlyAddress:host.address];
    if (primaryHost.length > 0) {
        [candidates addObject:primaryHost];
    }
    if (activeHost.length > 0) {
        [candidates addObject:activeHost];
    }
    NSString *externalHost = [self hostOnlyAddress:host.externalAddress];
    if (externalHost.length > 0) {
        [candidates addObject:externalHost];
    }

    Log(LOG_I, @"Pairing candidates for %@: %@", host.name ?: @"", candidates.array ?: @[]);
    for (NSString *candidate in candidates) {
        if ([self isValidPairingEndpoint:candidate forHost:host]) {
            return candidate;
        }
    }

    // Last resort: keep previous behavior if probes all failed.
    if (active.length > 0) {
        return active;
    }
    return localHost ?: primaryHost ?: externalHost;
}

- (NSString *)previousPortAddressIfLikelyWebUi:(NSString *)address {
    NSString *pairHost = nil;
    NSString *pairPort = nil;
    [Utils parseAddress:address intoHost:&pairHost andPort:&pairPort];
    if (pairHost.length == 0 || ![self isDecimalPortString:pairPort] || ![pairPort hasSuffix:@"90"]) {
        return nil;
    }

    NSInteger p = [pairPort integerValue];
    if (p <= 1) {
        return nil;
    }
    return [self joinHost:pairHost withPort:(p - 1)];
}

- (BOOL)isTransientNetworkPairFailureMessage:(NSString *)message {
    NSString *msg = message.lowercaseString ?: @"";
    NSArray<NSString *> *tokens = @[
        @"timeout", @"timed out", @"network", @"disconnected", @"connection",
        @"请求超时", @"网络连接已中断", @"无法连接"
    ];
    for (NSString *token in tokens) {
        if ([msg containsString:token]) {
            return YES;
        }
    }
    return NO;
}

- (void)startPairingForHost:(TemporaryHost *)host atAddress:(NSString *)pairingAddress {
    self.pairingAddressInFlight = pairingAddress;
    Log(LOG_I, @"Pairing target resolved: host=%@ active=%@ local=%@ address=%@ external=%@ selected=%@ fallback=%@",
        host.name ?: @"",
        host.activeAddress ?: @"",
        host.localAddress ?: @"",
        host.address ?: @"",
        host.externalAddress ?: @"",
        pairingAddress ?: @"",
        self.pairingFallbackAddress ?: @"");

    NSString *uniqueId = [IdManager getUniqueId];
    NSData *cert = [CryptoManager readCertFromFile];
    HttpManager* hMan = [[HttpManager alloc] initWithHost:pairingAddress uniqueId:uniqueId serverCert:host.serverCert];
    PairManager* pMan = [[PairManager alloc] initWithManager:hMan clientCert:cert callback:self];
    [self.opQueue addOperation:pMan];
}

- (void)setupPairing:(TemporaryHost *)host {
    if (self.pairingInProgress) {
        Log(LOG_W, @"Ignoring duplicate pairing request for %@ while pairing is already in progress", host.name ?: @"");
        return;
    }
    self.pairingInProgress = YES;

    // Run setup asynchronously to avoid blocking the main thread while waiting for discovery to stop
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Polling the server while pairing causes the server to screw up
        [self.discMan stopDiscoveryBlocking];

        NSString *pairingAddress = [self resolvePairingAddressForHost:host];
        NSString *fallback = [self previousPortAddressIfLikelyWebUi:pairingAddress];
        self.pairingFallbackAddress = fallback;
        self.pairingFallbackAttempted = NO;
        [self startPairingForHost:host atAddress:pairingAddress];
    });
}

- (void)handleOfflineHost:(TemporaryHost *)host {
    NSAlert *alert = [[NSAlert alloc] init];

    alert.alertStyle = NSAlertStyleInformational;
    alert.messageText = [NSString stringWithFormat:NSLocalizedString(@"Host Offline Alert", @"Host Offline Alert"), host.displayName];
    [alert addButtonWithTitle:NSLocalizedString(@"Wake", @"Wake")];
    [alert addButtonWithTitle:NSLocalizedString(@"Cancel", @"Cancel")];

    NavigatableAlertView *alertView = [[NavigatableAlertView alloc] init];
    alertView.responder = alert.window;
    [self.view addSubview:alertView];
    [self.hostWindow makeFirstResponder:alertView];
    
    [alert beginSheetModalForWindow:self.hostWindow completionHandler:^(NSModalResponse returnCode) {
        switch (returnCode) {
            case NSAlertFirstButtonReturn:
                [WakeOnLanManager wakeHost:host];
    
                [alertView removeFromSuperview];
                [self.hostWindow makeFirstResponder:self];
                break;
            case NSAlertSecondButtonReturn:
                [self.hostWindow endSheet:alert.window];

                [alertView removeFromSuperview];
                [self.hostWindow makeFirstResponder:self];
                break;
        }
    }];
}


#pragma mark - DiscoveryCallback

- (void)updateAllHosts:(NSArray<TemporaryHost *> *)hosts {
    dispatch_async(dispatch_get_main_queue(), ^{
        Log(LOG_D, @"New host list:");
        for (TemporaryHost* host in hosts) {
            Log(LOG_D, @"Host: \n{\n\t name:%@ \n\t address:%@ \n\t localAddress:%@ \n\t externalAddress:%@ \n\t uuid:%@ \n\t mac:%@ \n\t pairState:%d \n\t online:%d \n\t activeAddress:%@ \n}", host.name, host.address, host.localAddress, host.externalAddress, host.uuid, host.mac, host.pairState, host.state, host.activeAddress);
        }
        @synchronized(self.hosts) {
            self.hosts = hosts;
        }
        
        [self updateHosts];
    });
}


#pragma mark - PairCallback

- (void)startPairing:(NSString *)PIN {
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([MLDeckVariant isDeck]) {
            [[NSNotificationCenter defaultCenter] postNotificationName:@"MLDeckPairingPIN" object:nil
                                                              userInfo:@{@"uuid": self.selectedHost.uuid ?: @"", @"pin": PIN ?: @""}];
            return;
        }
        self.pairAlert = [AlertPresenter displayAlert:NSAlertStyleInformational title:[NSString stringWithFormat:NSLocalizedString(@"Enter PIN", @"Enter PIN"), self.selectedHost.displayName, PIN] message:nil window:self.hostWindow completionHandler:nil];
    });
}

- (void)pairSuccessful:(NSData *)serverCert {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.pairingInProgress = NO;
        self.pairingAddressInFlight = nil;
        self.pairingFallbackAddress = nil;
        self.pairingFallbackAttempted = NO;

        if (self.selectedHost == nil) {
            [self.discMan startDiscovery];
            return;
        }

        // Pairing succeeded. Persist cert + paired state immediately to avoid
        // transient discovery responses reverting UI to Unpaired.
        self.selectedHost.serverCert = serverCert;
        self.selectedHost.pairState = PairStatePaired;
        self.selectedHost.state = StateOnline;

        NSString *selectedUuid = self.selectedHost.uuid;
        if (selectedUuid.length > 0) {
            @synchronized (self.hosts) {
                for (TemporaryHost *host in self.hosts) {
                    if ([host.uuid isEqualToString:selectedUuid]) {
                        host.serverCert = serverCert;
                        host.pairState = PairStatePaired;
                        host.state = StateOnline;
                    }
                }
            }
        }

        DataManager *dataManager = [[DataManager alloc] init];
        [dataManager updateHost:self.selectedHost];
        Log(LOG_I, @"Pairing persisted for %@ (%@): pairState=%d certLen=%lu",
            self.selectedHost.displayName ?: @"",
            self.selectedHost.uuid ?: @"",
            self.selectedHost.pairState,
            (unsigned long)serverCert.length);
        
        if (self.pairAlert != nil) {
            [self.hostWindow endSheet:self.pairAlert.window];
        }
        self.pairAlert = nil;
        [self deckPostPIN:nil forHost:self.selectedHost];
        [self.discMan startDiscovery];
        [self updateHosts];
        [self alreadyPaired];
    });
}

- (void)pairFailed:(NSString*)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.pairingFallbackAttempted &&
            self.pairingFallbackAddress.length > 0 &&
            [self isTransientNetworkPairFailureMessage:message]) {
            self.pairingFallbackAttempted = YES;
            NSString *retryAddress = self.pairingFallbackAddress;
            Log(LOG_W, @"Pairing failed at %@ with transient error (%@). Retrying once at %@",
                self.pairingAddressInFlight ?: @"",
                message ?: @"",
                retryAddress);

            if (self.pairAlert != nil) {
                [self.hostWindow endSheet:self.pairAlert.window];
                self.pairAlert = nil;
            }

            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                [self.discMan stopDiscoveryBlocking];
                if (self.selectedHost != nil) {
                    [self startPairingForHost:self.selectedHost atAddress:retryAddress];
                }
            });
            return;
        }

        self.pairingInProgress = NO;
        self.pairingAddressInFlight = nil;
        self.pairingFallbackAddress = nil;
        self.pairingFallbackAttempted = NO;

        if (self.pairAlert != nil) {
            [self.hostWindow endSheet:self.pairAlert.window];
            self.pairAlert = nil;
        }
        [self deckPostPIN:nil forHost:self.selectedHost];
        if ([MLDeckVariant isComputerPage]) {
            // shown inline in the host's card, not as an alert
            [[NSNotificationCenter defaultCenter] postNotificationName:@"MLDeckPairingFailed" object:nil
                                                              userInfo:@{@"uuid": self.selectedHost.uuid ?: @"", @"message": message ?: @""}];
            [self->_discMan startDiscovery];
            return;
        }
        [AlertPresenter displayAlert:NSAlertStyleWarning title:NSLocalizedString(@"Pairing Failed", @"Pairing Failed") message:message window:self.hostWindow completionHandler:nil];
        [self->_discMan startDiscovery];
    });
}

- (void)alreadyPaired {
    self.pairingInProgress = NO;
    self.pairingAddressInFlight = nil;
    self.pairingFallbackAddress = nil;
    self.pairingFallbackAttempted = NO;
    if ([MLDeckVariant isSidebarVariant] && self.deckWorkspace != nil) {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"MLDeckSelectHost" object:nil
                                                          userInfo:@{@"uuid": self.selectedHost.uuid ?: @""}];
        return;
    }
    [self transitionToAppsVCWithHost:self.selectedHost];
}

@end
