//
//  AppsViewController.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 23/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import "AppsViewController.h"
#import "TemporaryApp.h"
#import "AppsViewControllerDelegate.h"
#import "AppCell.h"
#import "AlertPresenter.h"

#import "HttpManager.h"
#import "IdManager.h"
#import "CryptoManager.h"
#import "AppListResponse.h"
#import "AppAssetManager.h"
#import "DataManager.h"

@interface AppsViewController () <NSCollectionViewDataSource, AppsViewControllerDelegate, AppAssetCallback>
@property (weak) IBOutlet NSCollectionView *collectionView;
@property (nonatomic, strong) NSArray<TemporaryApp *> *apps;

@property (nonatomic, strong) AppAssetManager *appManager;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSImage *> *boxArtCache;
@property (nonatomic, strong) NSLock *boxArtCacheLock;

@end

@implementation AppsViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.collectionView.dataSource = self;

    self.apps = [NSArray array];
    [self loadApps];
    
    self.boxArtCache = [[NSMutableDictionary alloc] init];
    self.boxArtCacheLock = [[NSLock alloc] init];
}

- (void)transitionToHostsVC {
    [self.parentViewController transitionFromViewController:self toViewController:self.hostsVC options:NSViewControllerTransitionCrossfade completionHandler:nil];
}


#pragma mark - NSCollectionViewDataSource

- (void)configureItem:(AppCell *)item atIndexPath:(NSIndexPath * _Nonnull)indexPath {
    TemporaryApp *app = self.apps[indexPath.item];
    item.appName.stringValue = app.name;
    item.app = app;
    
    [self.boxArtCacheLock lock];
    NSImage* appImage = [self.boxArtCache objectForKey:app.id];
    [self.boxArtCacheLock unlock];
    if (appImage != nil) {
        item.appCoverArt.image = appImage;
    } else {
        item.appCoverArt.image = nil;
        [self asyncRenderAppImage:app];
    }
}

- (nonnull NSCollectionViewItem *)collectionView:(nonnull NSCollectionView *)collectionView itemForRepresentedObjectAtIndexPath:(nonnull NSIndexPath *)indexPath {
    AppCell *item = [collectionView makeItemWithIdentifier:@"AppCell" forIndexPath:indexPath];
    item.delegate = self;

    [self configureItem:item atIndexPath:indexPath];

    return item;
}

- (NSInteger)collectionView:(nonnull NSCollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return self.apps.count;
}

#pragma mark - AppsViewControllerDelegate

- (void)openApp:(TemporaryApp *)app {
}


#pragma mark - App Discovery

- (void)loadApps {
    self.appManager = [[AppAssetManager alloc] initWithCallback:self];
    
    if (self.host.appList.count > 0) {
        [self displayApps];
        [self updateBoxArtForAllApps];
    } else {
        [self discoverAppsForHost:self.host];
    }
}

- (void)updateBoxArtForAllApps {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        for (TemporaryApp* app in self.apps) {
            [self updateBoxArtCacheForApp:app];
        }
    });
}

- (void)displayApps {
    self.apps = [self.host.appList.allObjects sortedArrayUsingSelector:@selector(compareName:)];
    [self.collectionView reloadData];
}

- (void)discoverAppsForHost:(TemporaryHost *)host {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *uniqueId = [IdManager getUniqueId];
        NSData *cert = [CryptoManager readCertFromFile];
        
        HttpManager* hMan = [[HttpManager alloc] initWithHost:host.activeAddress uniqueId:uniqueId deviceName:deviceName cert:cert];
        
        // Try up to 5 times to get the app list
        AppListResponse* appListResp;
        for (int i = 0; i < 5; i++) {
            appListResp = [[AppListResponse alloc] init];
            [hMan executeRequestSynchronously:[HttpRequest requestForResponse:appListResp withUrlRequest:[hMan newAppListRequest]]];
            if (appListResp == nil || ![appListResp isStatusOk] || [appListResp getAppList] == nil) {
                Log(LOG_W, @"Failed to get applist on try %d: %@", i, appListResp.statusMessage);
                
                // Wait for one second then retry
                [NSThread sleepForTimeInterval:1];
            }
            else {
                Log(LOG_I, @"App list successfully retreived - took %d tries", i);
                break;
            }
        }
        
        if (appListResp == nil || ![appListResp isStatusOk] || [appListResp getAppList] == nil) {
            Log(LOG_W, @"Failed to get applist: %@", appListResp.statusMessage);
            dispatch_async(dispatch_get_main_queue(), ^{
                [AlertPresenter displayAlert:NSAlertStyleWarning message:@"Fetching App List Failed\nThe connection to the PC was interrupted." window:self.view.window completionHandler:^(NSModalResponse returnCode) {
                    host.online = NO;
                    [self transitionToHostsVC];
                }];
            });
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self updateApplist:[appListResp getAppList] forHost:host];

                [self.appManager stopRetrieving];
                [self.appManager retrieveAssetsFromHost:self.host];

                [self displayApps];
            });
        }
    });
}

- (void) updateApplist:(NSSet*) newList forHost:(TemporaryHost*)host {
    DataManager *database = [[DataManager alloc] init];
    
    for (TemporaryApp* app in newList) {
        BOOL appAlreadyInList = NO;
        for (TemporaryApp* savedApp in host.appList) {
            if ([app.id isEqualToString:savedApp.id]) {
                savedApp.name = app.name;
                appAlreadyInList = YES;
                break;
            }
        }
        if (!appAlreadyInList) {
            app.host = host;
            [host.appList addObject:app];
        }
    }
    
    BOOL appWasRemoved;
    do {
        appWasRemoved = NO;
        
        for (TemporaryApp* app in host.appList) {
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
                
                [host.appList removeObject:app];
                
                // It's important to remove the app record from the database
                // since we'll have a constraint violation now that appList
                // doesn't have this app in it.
                [database removeApp:app];
                
                break;
            }
        }
        
        // Keep looping until the list is no longer being mutated
    } while (appWasRemoved);
    
    [database updateAppsForExistingHost:host];
}


#pragma mark - Image Loading

- (void)asyncRenderAppImage:(TemporaryApp *)app {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        
        NSImage *appImage = [[NSImage alloc] initWithData:app.image];
        if (appImage != nil) {
            [self.boxArtCacheLock lock];
            [self.boxArtCache setObject:appImage forKey:app.id];
            [self.boxArtCacheLock unlock];
            
            [self updateCellWithImageForApp:app];
        }
    });
}

- (void)updateCellWithImageForApp:(TemporaryApp *)app {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSInteger appIndex = [self.apps indexOfObject:app];
        if (appIndex >= 0) {
            NSIndexPath *path = [NSIndexPath indexPathForItem:appIndex inSection:0];
            AppCell *item = (AppCell *)[self.collectionView itemAtIndexPath:path];
            if (item != nil) {
                [self configureItem:item atIndexPath:path];
            }
        }
    });
}

- (void)updateBoxArtCacheForApp:(TemporaryApp *)app {
    if (app.image == nil) {
        [self.boxArtCacheLock lock];
        [self.boxArtCache removeObjectForKey:app.id];
        [self.boxArtCacheLock unlock];
    } else {
        [self.boxArtCacheLock lock];
        NSImage *image = [self.boxArtCache objectForKey:app.id];
        [self.boxArtCacheLock unlock];
        if (image == nil) {
            NSImage *image = [[NSImage alloc] initWithData:app.image];
            [self.boxArtCacheLock lock];
            [self.boxArtCache setObject:image forKey:app.id];
            [self.boxArtCacheLock unlock];
        }
    }
}


#pragma mark - AppAssetCallback

- (void) receivedAssetForApp:(TemporaryApp*)app {
    // Update the box art cache now so we don't have to do it
    // on the main thread
    [self updateBoxArtCacheForApp:app];
    
    DataManager *dataManager = [[DataManager alloc] init];
    [dataManager updateIconForExistingApp:app];
    
    [self updateCellWithImageForApp:app];
}

@end
