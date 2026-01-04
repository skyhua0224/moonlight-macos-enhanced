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
#import "AlertPresenter.h"
#import "NSWindow+Moonlight.h"
#import "NSCollectionView+Moonlight.h"
#import "Helpers.h"
#import "NavigatableAlertView.h"
#import "AppDelegateForAppKit.h"

#import "Moonlight-Swift.h"

#import "CryptoManager.h"
#import "IdManager.h"
#import "DiscoveryManager.h"
#import "TemporaryHost.h"
#import "DataManager.h"
#import "PairManager.h"
#import "WakeOnLanManager.h"

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
    AppsViewController *appsVC = [self.storyboard instantiateControllerWithIdentifier:@"appsVC"];
    appsVC.host = host;
    appsVC.hostsVC = self;
    
    [self.parentViewController addChildViewController:appsVC];
    [self.parentViewController.view addSubview:appsVC.view];
    
    appsVC.view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    appsVC.view.frame = self.view.bounds;
    
    [SettingsClass loadMoonlightSettingsFor:host.uuid];
    
    [self.parentViewController.view.window makeFirstResponder:nil];

    [self.parentViewController transitionFromViewController:self toViewController:appsVC options:NSViewControllerTransitionSlideLeft completionHandler:^{
        [self.parentViewController.view.window makeFirstResponder:appsVC];
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
                    [AlertPresenter displayAlert:NSAlertStyleWarning title:@"Add Host Manually" message:error window:self.view.window completionHandler:nil];
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

    NSMenuItem *settingsItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Settings", @"Settings") action:@selector(openHostSettings:) keyEquivalent:@""];
    [settingsItem setTarget:self];
    [menu addItem:settingsItem];

    NSMenuItem *detailsItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Connection Details", @"Connection Details") action:@selector(showConnectionDetails:) keyEquivalent:@""];
    [detailsItem setTarget:self];
    [menu addItem:detailsItem];
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

    if (@available(macOS 10.12, *)) {
        NSGridView *gridView = [NSGridView gridViewWithViews:@[]];
        gridView.columnSpacing = 10;
        gridView.rowSpacing = 5;
        
        // Helper block to add row
        void (^addRow)(NSString *, NSString *) = ^(NSString *label, NSString *value) {
            NSTextField *labelField = [NSTextField labelWithString:[label stringByAppendingString:@":"]];
            labelField.font = [NSFont boldSystemFontOfSize:12];
            labelField.alignment = NSTextAlignmentRight;
            
            NSTextField *valueField = [NSTextField labelWithString:value ?: @"-"];
            valueField.selectable = YES; // Allow copying
            
            [gridView addRowWithViews:@[labelField, valueField]];
        };

        NSString *statusString;
        if (host.state == StateOnline) {
            statusString = NSLocalizedString(@"Online", nil);
        } else if (host.state == StateOffline) {
            statusString = NSLocalizedString(@"Offline", nil);
        } else {
            statusString = NSLocalizedString(@"Unknown", nil);
        }
        
        NSString *pairStateString = host.pairState == PairStatePaired ? NSLocalizedString(@"Paired", nil) : NSLocalizedString(@"Unpaired", nil);

        addRow(NSLocalizedString(@"Host Name", nil), host.name);
        addRow(NSLocalizedString(@"Status", nil), statusString);
        addRow(NSLocalizedString(@"Active Address", nil), host.activeAddress);
        addRow(NSLocalizedString(@"UUID", nil), host.uuid);
        addRow(NSLocalizedString(@"Pair Name", nil), deviceName);
        addRow(NSLocalizedString(@"Local Address", nil), host.localAddress);
        addRow(NSLocalizedString(@"External Address", nil), host.externalAddress);
        addRow(NSLocalizedString(@"IPv6 Address", nil), host.ipv6Address);
        addRow(NSLocalizedString(@"Manual Address", nil), host.address);
        addRow(NSLocalizedString(@"MAC Address", nil), host.mac);
        addRow(NSLocalizedString(@"Pair State", nil), pairStateString);
        addRow(NSLocalizedString(@"Running Game ID", nil), host.currentGame);
        
        if (host.addressLatencies.count > 0) {
            NSTextField *spacer = [NSTextField labelWithString:@""];
            [gridView addRowWithViews:@[spacer, spacer]];
            
            NSTextField *header = [NSTextField labelWithString:NSLocalizedString(@"Addresses", nil)];
            header.font = [NSFont boldSystemFontOfSize:12];
            [gridView addRowWithViews:@[header, [NSGridCell emptyContentView]]];
            
            for (NSString *addr in host.addressLatencies) {
                NSNumber *latency = host.addressLatencies[addr];
                NSNumber *state = host.addressStates[addr];
                NSString *addrStatus = [state boolValue] ? NSLocalizedString(@"Online", nil) : NSLocalizedString(@"Offline", nil);
                NSString *detail = [NSString stringWithFormat:@"%@ (%@ms)", addrStatus, latency];
                
                NSTextField *addrLabel = [NSTextField labelWithString:[addr stringByAppendingString:@":"]];
                addrLabel.alignment = NSTextAlignmentRight;
                NSTextField *detailLabel = [NSTextField labelWithString:detail];
                
                [gridView addRowWithViews:@[addrLabel, detailLabel]];
            }
        }
        
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = NSLocalizedString(@"Connection Details", @"Connection Details");
        alert.accessoryView = gridView;
        [alert runModal];
    } else {
        // Fallback for older macOS if needed, but 10.12 is very old.
        // Assuming min target is decent.
        NSMutableString *details = [NSMutableString string];
        [details appendFormat:@"%@: %@\n", NSLocalizedString(@"Host Name", nil), host.name];
        // ... simplified fallback
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = NSLocalizedString(@"Connection Details", @"Connection Details");
        alert.informativeText = details;
        [alert runModal];
    }
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

- (void)setupPairing:(TemporaryHost *)host {
    // Run setup asynchronously to avoid blocking the main thread while waiting for discovery to stop
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Polling the server while pairing causes the server to screw up
        [self.discMan stopDiscoveryBlocking];
        
        NSString *uniqueId = [IdManager getUniqueId];
        NSData *cert = [CryptoManager readCertFromFile];

        HttpManager* hMan = [[HttpManager alloc] initWithHost:host.activeAddress uniqueId:uniqueId serverCert:host.serverCert];
        PairManager* pMan = [[PairManager alloc] initWithManager:hMan clientCert:cert callback:self];
        [self.opQueue addOperation:pMan];
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
        self.selectedHost.serverCert = serverCert;
        
        [self.view.window endSheet:self.pairAlert.window];
        [self.discMan startDiscovery];
        [self alreadyPaired];
    });
}

- (void)pairFailed:(NSString*)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.pairAlert != nil) {
            [self.view.window endSheet:self.pairAlert.window];
            self.pairAlert = nil;
        }
        [AlertPresenter displayAlert:NSAlertStyleWarning title:NSLocalizedString(@"Pairing Failed", @"Pairing Failed") message:message window:self.view.window completionHandler:nil];
        [self->_discMan startDiscovery];
    });
}

- (void)alreadyPaired {
    [self transitionToAppsVCWithHost:self.selectedHost];
}

@end
