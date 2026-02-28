//
//  HostsViewController.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 22/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import "HostsViewController.h"
#import "HostCell.h"
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
#import "Moonlight-Swift.h"
#import "Utils.h"

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

@interface HostsViewController () <NSCollectionViewDataSource, NSCollectionViewDelegate, NSSearchFieldDelegate, NSControlTextEditingDelegate, HostsViewControllerDelegate, DiscoveryCallback, PairCallback, NSMenuItemValidation>
@property (nonatomic, strong) NSArray<TemporaryHost *> *hosts;
@property (nonatomic, strong) TemporaryHost *selectedHost;
@property (nonatomic, strong) NSAlert *pairAlert;
@property (nonatomic, strong) NSAlert *addHostManuallyAlert;

@property (nonatomic, strong) NSArray *hostList;
@property (nonatomic) NSSearchField *getSearchField;

@property (nonatomic, strong) NSOperationQueue *opQueue;
@property (nonatomic, strong) DiscoveryManager *discMan;
@property (nonatomic, copy) NSString *pairingAddressInFlight;
@property (nonatomic, copy) NSString *pairingFallbackAddress;
@property (nonatomic, assign) BOOL pairingFallbackAttempted;
@property (nonatomic, assign) BOOL pairingInProgress;

@end

@implementation HostsViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.collectionView.dataSource = self;
    self.collectionView.delegate = self;
    [self.collectionView registerNib:[[NSNib alloc] initWithNibNamed:@"HostCell" bundle:nil] forItemWithIdentifier:@"HostCell"];

    self.hosts = [NSArray array];
    
    [self prepareDiscovery];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(languageChanged:) name:@"LanguageChanged" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refreshHostDiscovery:) name:@"MoonlightRequestHostDiscovery" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleHostAutoAddressSwitched:) name:@"HostAutoAddressSwitched" object:nil];
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

- (void)handleHostAutoAddressSwitched:(NSNotification *)note {
    if (!self.view.window || !self.view.window.isVisible) {
        return;
    }

    NSString *uuid = note.userInfo[@"uuid"];
    if (uuid.length == 0) {
        return;
    }

    TemporaryHost *targetHost = nil;
    @synchronized(self.hosts) {
        for (TemporaryHost *host in self.hosts) {
            if ([host.uuid isEqualToString:uuid]) {
                targetHost = host;
                break;
            }
        }
    }

    if (!targetHost) {
        return;
    }

    NSDictionary *settings = [SettingsClass getSettingsFor:uuid];
    NSString *connectionMethod = settings[@"connectionMethod"];
    if (connectionMethod.length > 0 && ![connectionMethod isEqualToString:@"Auto"]) {
        return;
    }

    NSString *oldAddress = note.userInfo[@"oldAddress"] ?: @"";
    NSString *newAddress = note.userInfo[@"newAddress"] ?: @"";
    NSNumber *oldLatency = note.userInfo[@"oldLatency"] ?: @(-1);
    NSNumber *newLatency = note.userInfo[@"newLatency"] ?: @(-1);

    NSString *title = NSLocalizedString(@"Auto Address Switched Title", @"Auto address switched alert title");
    NSString *format = NSLocalizedString(@"Auto Address Switched Message", @"Auto address switched alert message");
    NSString *message = [NSString stringWithFormat:format,
                         targetHost.name ?: @"",
                         oldAddress,
                         newAddress,
                         oldLatency.doubleValue,
                         newLatency.doubleValue];

    [AlertPresenter displayAlert:NSAlertStyleInformational title:title message:message window:self.view.window completionHandler:nil];
}

- (void)viewWillAppear {
    [super viewWillAppear];
    
    self.parentViewController.title = @"Moonlight";
    self.parentViewController.view.window.subtitle = [Helpers versionNumberString];

    [self.parentViewController.view.window moonlight_toolbarItemForAction:@selector(addHostButtonClicked:)].enabled = YES;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wundeclared-selector"
    [self.parentViewController.view.window moonlight_toolbarItemForAction:@selector(backButtonClicked:)].enabled = NO;
#pragma clang diagnostic pop
    
    self.getSearchField.delegate = self;
    self.getSearchField.placeholderString = NSLocalizedString(@"Search Hosts", @"Search Hosts");
}

- (void)viewDidAppear {
    [super viewDidAppear];
    
    [self.discMan startDiscovery];
}

- (void)viewDidDisappear {
    [super viewDidDisappear];
    
    [self.discMan stopDiscovery];
}

- (BOOL)becomeFirstResponder {
    [self.view.window makeFirstResponder:self.collectionView];
    return [super becomeFirstResponder];
}

- (void)transitionToAppsVCWithHost:(TemporaryHost *)host {
    // Create AppsWorkspaceViewController instead of direct AppsViewController
    NSArray<TemporaryHost *> *hostsSnapshot = self.hosts ?: @[];
    AppsWorkspaceViewController *workspaceVC = [[AppsWorkspaceViewController alloc] initWithHost:host hostsSnapshot:hostsSnapshot];

    [self.parentViewController addChildViewController:workspaceVC];
    [self.parentViewController.view addSubview:workspaceVC.view];

    workspaceVC.view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    workspaceVC.view.frame = self.view.bounds;

    [SettingsClass loadMoonlightSettingsFor:host.uuid];

    [self.parentViewController.view.window makeFirstResponder:nil];

    [self.parentViewController transitionFromViewController:self toViewController:workspaceVC options:NSViewControllerTransitionSlideLeft completionHandler:^{
        [self.parentViewController.view.window makeFirstResponder:workspaceVC];
    }];
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
    
    [alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse returnCode) {
        if (returnCode == NSAlertFirstButtonReturn) {
            [self addHostManuallyHandlerWithInputValue:inputField.stringValue];
        }
        self.addHostManuallyAlert = nil;
        [self.view.window endSheet:alert.window];
    }];
    [alert.accessoryView becomeFirstResponder];
    
    self.addHostManuallyAlert = alert;
}

- (void)addHostManuallyHandlerWithInputValue:(NSString *)inputValue {
    NSString* hostAddress = inputValue;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        [self.discMan discoverHost:hostAddress withCallback:^(TemporaryHost* host, NSString* error){
            if (host != nil) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    DataManager* dataMan = [[DataManager alloc] init];
                    [dataMan updateHost:host];
                    self.hosts = [self.hosts arrayByAddingObject:host];
                    [self updateHosts];
                });
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [AlertPresenter displayAlert:NSAlertStyleWarning title:NSLocalizedString(@"Add Host Manually", @"Add Host Manually") message:error window:self.view.window completionHandler:nil];
                });
            }
        }];
    });
}


#pragma mark - NSCollectionViewDataSource

- (nonnull NSCollectionViewItem *)collectionView:(nonnull NSCollectionView *)collectionView itemForRepresentedObjectAtIndexPath:(nonnull NSIndexPath *)indexPath {
    HostCell *item = [collectionView makeItemWithIdentifier:@"HostCell" forIndexPath:indexPath];
    
    TemporaryHost *host = self.hosts[indexPath.item];
    item.hostName.stringValue = host.name;
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
    if (wakeMenuItem != nil) {
        if (host.state == StateOnline) {
            wakeMenuItem.enabled = NO;
        }
    }
    showHiddenAppsMenuItem.state = host.showHiddenApps ? NSControlStateValueOn : NSControlStateValueOff;

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *settingsItem = [HostsViewController getMenuItemForIdentifier:@"settingsItem" inMenu:menu];
    if (settingsItem == nil) {
        settingsItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Settings", @"Settings") action:@selector(openHostSettings:) keyEquivalent:@""];
        [settingsItem setTarget:self];
        settingsItem.identifier = @"settingsItem";
        [menu addItem:settingsItem];
    }

    NSMenuItem *detailsItem = [HostsViewController getMenuItemForIdentifier:@"detailsItem" inMenu:menu];
    if (detailsItem == nil) {
        detailsItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Connection Details", @"Connection Details") action:@selector(showConnectionDetails:) keyEquivalent:@""];
        [detailsItem setTarget:self];
        detailsItem.identifier = @"detailsItem";
        [menu addItem:detailsItem];
    }

    NSMenuItem *connectionsItem = [HostsViewController getMenuItemForIdentifier:@"connectionsItem" inMenu:menu];
    if (connectionsItem == nil) {
        connectionsItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Edit Connections", @"Edit Connections") action:@selector(showConnectionEditor:) keyEquivalent:@""];
        [connectionsItem setTarget:self];
        connectionsItem.identifier = @"connectionsItem";
        [menu addItem:connectionsItem];
    }
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
    [self presentViewControllerAsSheet:detailsVC];
}

- (void)showConnectionEditor:(NSMenuItem *)sender {
    TemporaryHost *host = [self getHostFromMenuItem:sender];
    if (host == nil) {
        return;
    }

    ConnectionEditorViewController *editorVC = [[ConnectionEditorViewController alloc] initWithHost:host];
    [self presentViewControllerAsSheet:editorVC];
}


#pragma mark - Helpers

- (NSSearchField *)getSearchField {
    return [self.parentViewController.view.window moonlight_searchFieldInToolbar];
}

- (TemporaryHost *)getHostFromMenuItem:(NSMenuItem *)item {
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
    }
}

- (void)filterHostsByString:(NSString *)filterString {
    NSPredicate *predicate;
    if (filterString.length != 0) {
        predicate = [NSPredicate predicateWithFormat:@"name CONTAINS[cd] %@", filterString];
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
    alert.messageText = [NSString stringWithFormat:NSLocalizedString(@"Host Offline Alert", @"Host Offline Alert"), host.name];
    [alert addButtonWithTitle:NSLocalizedString(@"Wake", @"Wake")];
    [alert addButtonWithTitle:NSLocalizedString(@"Cancel", @"Cancel")];

    NavigatableAlertView *alertView = [[NavigatableAlertView alloc] init];
    alertView.responder = alert.window;
    [self.view addSubview:alertView];
    [self.view.window makeFirstResponder:alertView];
    
    [alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse returnCode) {
        switch (returnCode) {
            case NSAlertFirstButtonReturn:
                [WakeOnLanManager wakeHost:host];
    
                [alertView removeFromSuperview];
                [self.view.window makeFirstResponder:self];
                break;
            case NSAlertSecondButtonReturn:
                [self.view.window endSheet:alert.window];

                [alertView removeFromSuperview];
                [self.view.window makeFirstResponder:self];
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
        self.pairAlert = [AlertPresenter displayAlert:NSAlertStyleInformational title:[NSString stringWithFormat:NSLocalizedString(@"Enter PIN", @"Enter PIN"), self.selectedHost.name, PIN] message:nil window:self.view.window completionHandler:nil];
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
            self.selectedHost.name ?: @"",
            self.selectedHost.uuid ?: @"",
            self.selectedHost.pairState,
            (unsigned long)serverCert.length);
        
        [self.view.window endSheet:self.pairAlert.window];
        self.pairAlert = nil;
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
                [self.view.window endSheet:self.pairAlert.window];
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
            [self.view.window endSheet:self.pairAlert.window];
            self.pairAlert = nil;
        }
        [AlertPresenter displayAlert:NSAlertStyleWarning title:NSLocalizedString(@"Pairing Failed", @"Pairing Failed") message:message window:self.view.window completionHandler:nil];
        [self->_discMan startDiscovery];
    });
}

- (void)alreadyPaired {
    self.pairingInProgress = NO;
    self.pairingAddressInFlight = nil;
    self.pairingFallbackAddress = nil;
    self.pairingFallbackAttempted = NO;
    [self transitionToAppsVCWithHost:self.selectedHost];
}

@end
