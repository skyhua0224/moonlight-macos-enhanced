//
//  HostsViewController.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 22/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import "HostsViewController.h"
#import "HostCell.h"
#import "HostsViewControllerDelegate.h"
#import "AppsViewController.h"
#import "AlertPresenter.h"
#import "NSWindow+Moonlight.h"

#import "CryptoManager.h"
#import "IdManager.h"
#import "DiscoveryManager.h"
#import "TemporaryHost.h"
#import "DataManager.h"
#import "PairManager.h"

@interface HostsViewController () <NSCollectionViewDataSource, NSCollectionViewDelegate, HostsViewControllerDelegate, DiscoveryCallback, PairCallback>

@property (weak) IBOutlet NSCollectionView *collectionView;
@property (nonatomic, strong) NSArray<TemporaryHost *> *hosts;
@property (nonatomic, strong) TemporaryHost *selectedHost;
@property (nonatomic, strong) NSAlert *pairAlert;

@property (nonatomic, strong) NSOperationQueue *opQueue;
@property (nonatomic, strong) DiscoveryManager *discMan;

@end

@implementation HostsViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.collectionView.dataSource = self;
    self.collectionView.delegate = self;
    
    self.hosts = [NSArray array];
    
    [self prepareDiscovery];
}

- (void)viewDidAppear {
    [super viewDidAppear];
    
    self.view.window.title = @"Moonlight";
    [self.view.window makeFirstResponder:self.collectionView];
    
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wundeclared-selector"
    [self.view.window moonlight_toolbarItemForAction:@selector(backButtonClicked:)].enabled = NO;
#pragma clang diagnostic pop
    
    [self.discMan startDiscovery];
}

- (void)viewDidDisappear {
    [super viewDidDisappear];
    
    [self.discMan stopDiscovery];
}

- (void)transitionToAppsVCWithHost:(TemporaryHost *)host {
    AppsViewController *appsVC = [self.storyboard instantiateControllerWithIdentifier:@"appsVC"];
    appsVC.host = host;
    appsVC.hostsVC = self;
    [self.parentViewController addChildViewController:appsVC];
    [self.parentViewController.view addSubview:appsVC.view];
    [self.parentViewController transitionFromViewController:self toViewController:appsVC options:NSViewControllerTransitionNone completionHandler:nil];
    
    appsVC.view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    appsVC.view.frame = self.view.bounds;
}

#pragma mark - Actions

- (IBAction)open:(id)sender {
    if (self.collectionView.selectionIndexes.count != 0) {
        TemporaryHost *host = self.hosts[self.collectionView.selectionIndexes.firstIndex];
        [self openHost:host];
    }
}


#pragma mark - NSCollectionViewDataSource

- (nonnull NSCollectionViewItem *)collectionView:(nonnull NSCollectionView *)collectionView itemForRepresentedObjectAtIndexPath:(nonnull NSIndexPath *)indexPath {
    HostCell *item = [collectionView makeItemWithIdentifier:@"HostCell" forIndexPath:indexPath];
    
    TemporaryHost *host = self.hosts[indexPath.item];
    item.hostName.stringValue = [host.name capitalizedString];
    item.host = host;
    item.delegate = self;
    
    return item;
}

- (NSInteger)collectionView:(nonnull NSCollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return self.hosts.count;
}


#pragma mark - NSCollectionViewDelegate

- (void)collectionView:(NSCollectionView *)collectionView didSelectItemsAtIndexPaths:(NSSet<NSIndexPath *> *)indexPaths {
}


#pragma mark - HostsViewControllerDelegate

- (void)openHost:(TemporaryHost *)host {
    self.selectedHost = host;
    
    if (host.online) {
        if (host.pairState == PairStatePaired) {
            [self transitionToAppsVCWithHost:host];
        } else {
            [self setupPairing:host];
        }
    } else {
        [self handleOfflineHost:host];
    }
}

#pragma mark - Host Discovery

- (void)prepareDiscovery {
    // Set up crypto
    [CryptoManager generateKeyPairUsingSSl];
    
    self.opQueue = [[NSOperationQueue alloc] init];
    
    [self retrieveSavedHosts];
    self.discMan = [[DiscoveryManager alloc] initWithHosts:self.hosts andCallback:self];
}

- (void)retrieveSavedHosts {
    DataManager* dataMan = [[DataManager alloc] init];
    NSArray* hosts = [dataMan getHosts];
    @synchronized(self.hosts) {
        self.hosts = hosts;
        
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
        [self.collectionView reloadData];
    }
}


#pragma mark - Host Operations

- (void)setupPairing:(TemporaryHost *)host {
    // Polling the server while pairing causes the server to screw up
    [self.discMan stopDiscoveryBlocking];
    
    NSString *uniqueId = [IdManager getUniqueId];
    NSData *cert = [CryptoManager readCertFromFile];

    HttpManager* hMan = [[HttpManager alloc] initWithHost:host.activeAddress uniqueId:uniqueId deviceName:deviceName cert:cert];
    PairManager* pMan = [[PairManager alloc] initWithManager:hMan andCert:cert callback:self];
    [self.opQueue addOperation:pMan];
}

- (void)handleOfflineHost:(TemporaryHost *)host {
}


#pragma mark - DiscoveryCallback

- (void)updateAllHosts:(NSArray<TemporaryHost *> *)hosts {
    dispatch_async(dispatch_get_main_queue(), ^{
        Log(LOG_D, @"New host list:");
        for (TemporaryHost* host in hosts) {
            Log(LOG_D, @"Host: \n{\n\t name:%@ \n\t address:%@ \n\t localAddress:%@ \n\t externalAddress:%@ \n\t uuid:%@ \n\t mac:%@ \n\t pairState:%d \n\t online:%d \n\t activeAddress:%@ \n}", host.name, host.address, host.localAddress, host.externalAddress, host.uuid, host.mac, host.pairState, host.online, host.activeAddress);
        }
        @synchronized(self.hosts) {
            self.hosts = hosts;
        }
        [self updateHosts];
    });
}


#pragma mark - PairCallback

- (void)showPIN:(NSString *)PIN {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.pairAlert = [AlertPresenter displayAlert:NSAlertStyleInformational message:[NSString stringWithFormat:@"Enter the following PIN on %@: %@", self.selectedHost.name, PIN] window:self.view.window completionHandler:nil];
    });
}

- (void)pairSuccessful {
    dispatch_async(dispatch_get_main_queue(), ^{
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
        [AlertPresenter displayAlert:NSAlertStyleWarning message:[NSString stringWithFormat:@"Pairing Failed: %@", message] window:self.view.window completionHandler:nil];
        [_discMan startDiscovery];
    });
}

- (void)alreadyPaired {
    [self transitionToAppsVCWithHost:self.selectedHost];
}

@end
