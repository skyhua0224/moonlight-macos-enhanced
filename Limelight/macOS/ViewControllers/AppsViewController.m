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
#import "StreamViewController.h"
#import "NSWindow+Moonlight.h"
#import "NSCollectionView+Moonlight.h"
#import "NSApplication+Moonlight.h"
#import "BackgroundColorView.h"

#import "HttpManager.h"
#import "IdManager.h"
#import "CryptoManager.h"
#import "AppListResponse.h"
#import "AppAssetManager.h"
#import "DataManager.h"
#import "ServerInfoResponse.h"
#import "DiscoveryWorker.h"

@interface AppsViewController () <NSCollectionViewDataSource, AppsViewControllerDelegate, AppAssetCallback, NSSearchFieldDelegate>
@property (weak) IBOutlet NSCollectionView *collectionView;
@property (nonatomic, strong) NSArray<TemporaryApp *> *apps;
@property (nonatomic, strong) NSString *filterText;
@property (nonatomic, strong) TemporaryApp *runningApp;

@property (nonatomic) NSSearchField *getSearchField;

@property (nonatomic, strong) AppAssetManager *appManager;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSImage *> *boxArtCache;
@property (nonatomic, strong) NSLock *boxArtCacheLock;
@property (nonatomic) CGFloat itemScale;

@property (nonatomic) id windowDidBecomeKeyObserver;

@end

const CGFloat scaleBase = 1.125;

@implementation AppsViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.collectionView.dataSource = self;

    [self updateColors];
    
    self.itemScale = [[NSUserDefaults standardUserDefaults] floatForKey:@"itemScale"];
    if (self.itemScale == 0) {
        self.itemScale = pow(scaleBase, 2);
    }
    [self updateCollectionViewItemSize];

    self.apps = [NSArray array];
    [self loadApps];
    
    self.runningApp = [self findRunningApp:self.host];
    
    self.boxArtCache = [[NSMutableDictionary alloc] init];
    self.boxArtCacheLock = [[NSLock alloc] init];
    
    __weak typeof(self) weakSelf = self;
    self.windowDidBecomeKeyObserver = [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidBecomeKeyNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        [weakSelf updateRunningAppState];
    }];
    
    if (@available(macOS 10.14, *)) {
        [[NSApplication sharedApplication] addObserver:self forKeyPath:@"effectiveAppearance" options:(NSKeyValueObservingOptionNew | NSKeyValueObservingOptionInitial) context:nil];
    }
}

- (void)viewDidAppear {
    [super viewDidAppear];
    
    self.parentViewController.title = self.host.name;
    [self.view.window makeFirstResponder:self.collectionView];
    
    [self.view.window moonlight_toolbarItemForAction:@selector(backButtonClicked:)].enabled = YES;
    self.getSearchField.delegate = self;
}

- (void)viewWillDisappear {
    [super viewWillDisappear];
    
    self.appManager = nil;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
    if ([keyPath isEqualToString:@"effectiveAppearance"]) {
        [self updateColors];
        
        for (int i = 0; i < self.apps.count; i++) {
            AppCell *cell = (AppCell *)[self.collectionView itemAtIndex:i];
            [cell updateSelectedState:cell.selected];
        }
    }
}

- (void)transitionToHostsVC {
    [[NSNotificationCenter defaultCenter] removeObserver:self.windowDidBecomeKeyObserver];
    if (@available(macOS 10.14, *)) {
        [[NSApplication sharedApplication] removeObserver:self forKeyPath:@"effectiveAppearance"];
    }
    
    [self.parentViewController transitionFromViewController:self toViewController:self.hostsVC options:NSViewControllerTransitionCrossfade completionHandler:nil];
    [self.view.window makeFirstResponder:self.hostsVC.view.subviews.firstObject];
    [self removeFromParentViewController];
}

- (void)prepareForSegue:(NSStoryboardSegue *)segue sender:(id)sender {
    StreamViewController *streamVC = segue.destinationController;
    streamVC.app = self.runningApp;
    streamVC.delegate = self;
}


#pragma mark - NSResponder

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    // Forward validate to collectionView, because for some reason it doesn't get called
    // automatically by the system when expected (even though it's firstResponder).
    return [self.collectionView validateMenuItem:menuItem];
}


#pragma mark - Actions

- (IBAction)filterList:(id)sender {
    [self.view.window makeFirstResponder:self.getSearchField];
}

- (IBAction)backButtonClicked:(id)sender {
    [self transitionToHostsVC];
}

- (IBAction)quitAppMenuItemClicked:(id)sender {
    [self quitApp:self.runningApp completion:nil];
}

- (IBAction)open:(id)sender {
    if (self.collectionView.selectionIndexes.count != 0) {
        TemporaryApp *app = self.apps[self.collectionView.selectionIndexes.firstIndex];
        [self openApp:app];
    }
}

- (void)updateCollectionViewItemSize {
    NSCollectionViewFlowLayout *flowLayout = (NSCollectionViewFlowLayout *)self.collectionView.collectionViewLayout;

    flowLayout.itemSize = NSMakeSize((int)(90 * self.itemScale + 6 + 2), (int)(128 * self.itemScale + 6 + 2));
    [flowLayout invalidateLayout];
    
    [[NSUserDefaults standardUserDefaults] setFloat:self.itemScale forKey:@"itemScale"];
}

- (IBAction)increaseItemSize:(id)sender {
    if (self.itemScale > pow(scaleBase, 7)) {
        return;
    }
    self.itemScale *= scaleBase;
    [self updateCollectionViewItemSize];
}

- (IBAction)decreaseItemSize:(id)sender {
    if (self.itemScale < pow(scaleBase, 0)) {
        return;
    }
    self.itemScale /= scaleBase;
    [self updateCollectionViewItemSize];
}


#pragma mark - NSCollectionViewDataSource

- (void)configureItem:(AppCell *)item atIndexPath:(NSIndexPath * _Nonnull)indexPath {
    TemporaryApp *app = self.apps[indexPath.item];
    item.appName.stringValue = app.name;
    item.app = app;
    
    item.runningIcon.hidden = app != self.runningApp;

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


#pragma mark - NSSearchFieldDelegate

- (void)controlTextDidChange:(NSNotification *)obj {
    self.filterText = ((NSTextField *)obj.object).stringValue;
    [self displayApps];
}


#pragma mark - AppsViewControllerDelegate

- (void)openApp:(TemporaryApp *)app {
    if (self.runningApp != nil && app != self.runningApp) {
        if ([self askWhetherToStopRunningApp:self.runningApp andStartNewApp:app]) {
            [self quitApp:self.runningApp completion:^(BOOL success) {
                if (success) {
                    self.runningApp = app;
                    [self performSegueWithIdentifier:@"streamSegue" sender:nil];
                }
            }];
        }
    } else {
        self.runningApp = app;
        [self performSegueWithIdentifier:@"streamSegue" sender:nil];
    }
}

- (void)quitApp:(TemporaryApp *)app completion:(void (^)(BOOL success))completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *uniqueId = [IdManager getUniqueId];
        NSData *cert = [CryptoManager readCertFromFile];

        HttpManager *hMan = [[HttpManager alloc] initWithHost:app.host.activeAddress uniqueId:uniqueId deviceName:deviceName cert:cert];
        HttpResponse *quitResponse = [[HttpResponse alloc] init];
        HttpRequest *quitRequest = [HttpRequest requestForResponse:quitResponse withUrlRequest:[hMan newQuitAppRequest]];
        
        [hMan executeRequestSynchronously:quitRequest];
        if (quitResponse.statusCode == 200) {
            ServerInfoResponse *serverInfoResp = [[ServerInfoResponse alloc] init];
            [hMan executeRequestSynchronously:[HttpRequest requestForResponse:serverInfoResp withUrlRequest:[hMan newServerInfoRequest] fallbackError:401 fallbackRequest:[hMan newHttpServerInfoRequest]]];
            if (![serverInfoResp isStatusOk] || [[serverInfoResp getStringTag:@"state"] hasSuffix:@"_SERVER_BUSY"]) {
                // On newer GFE versions, the quit request succeeds even though the app doesn't
                // really quit if another client tries to kill your app. We'll patch the response
                // to look like the old error in that case, so the UI behaves.
                quitResponse.statusCode = 599;
            }
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            // If it fails, display an error and stop the current operation
            if (quitResponse.statusCode != 200) {
                [AlertPresenter displayAlert:NSAlertStyleWarning message:@"Failed to quit app. If this app was started by another device, you'll need to quit from that device." window:self.view.window completionHandler:nil];
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

- (void)appDidQuit:(TemporaryApp *)app {
    self.runningApp = nil;
    [self updateRunningAppState];
}

- (void)didOpenContextMenu:(NSMenu *)menu forApp:(TemporaryApp *)app {
    if (self.runningApp == nil) {
        [menu cancelTrackingWithoutAnimation];
        return;
    }
    if (app != self.runningApp) {
        [menu cancelTrackingWithoutAnimation];
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
    
    if (runningApp == nil) {
        self.host.currentGame = @"0";
    } else {
        self.host.currentGame = self.runningApp.id;
    }
    
    [self redrawCellAtIndexPath:[self indexPathForApp:oldApp]];
    [self redrawCellAtIndexPath:[self indexPathForApp:runningApp]];
}

- (void)redrawCellAtIndexPath:(NSIndexPath *)path {
    if (path == nil) {
        return;
    }
    
    AppCell *item = (AppCell *)[self.collectionView itemAtIndexPath:path];
    [self configureItem:item atIndexPath:path];
}

- (void)updateRunningAppState {
    __weak typeof(self) weakSelf = self;
    NSOperation *operation = [NSBlockOperation blockOperationWithBlock:^{
        DiscoveryWorker *worker = [[DiscoveryWorker alloc] initWithHost:weakSelf.host uniqueId:[IdManager getUniqueId] cert:[CryptoManager readCertFromFile]];
        [worker discoverHost];
        dispatch_async(dispatch_get_main_queue(), ^{
            TemporaryApp *runningApp = [weakSelf findRunningApp:weakSelf.host];
            [weakSelf setRunningApp:runningApp];
        });
    }];
    NSOperationQueue *queue = [[NSOperationQueue alloc] init];
    [queue addOperation:operation];
}


#pragma mark - Helpers

- (NSSearchField *)getSearchField {
    return ((NSSearchField *)[self.view.window moonlight_toolbarItemForTag:42].view);
}

- (void)updateColors {
    NSColor *backgroundColor = [NSColor textBackgroundColor];
    if (@available(macOS 10.14, *)) {
        if ([NSApplication moonlight_isDarkAppearance]) {
            backgroundColor = [NSColor windowBackgroundColor];
        }
    }

    // Set containerView subclass's background color, because collectionView's backgroundColors property is unreliable.
    // In the storyboard, collectionView's first backgroundColors item is set to 0 alpha.
    ((BackgroundColorView *)self.parentViewController.view).backgroundColor = backgroundColor;
}

- (NSIndexPath *)indexPathForApp:(TemporaryApp *)app {
    if (app != nil) {
        NSInteger appIndex = [self.apps indexOfObject:app];
        if (appIndex >= 0) {
            return [NSIndexPath indexPathForItem:appIndex inSection:0];
        }
    }
    
    return nil;
}

- (BOOL)askWhetherToStopRunningApp:(TemporaryApp *)currentApp andStartNewApp:(TemporaryApp *)newApp {
    NSAlert *alert = [[NSAlert alloc] init];
    
    alert.alertStyle = NSAlertStyleInformational;
    alert.messageText = [NSString stringWithFormat:@"%@ is still running.\n\nDo you want to quit %@ and start %@?", currentApp.name, currentApp.name, newApp.name];
    
    [alert addButtonWithTitle:@"Yes"];
    [alert addButtonWithTitle:@"Cancel"];
    
    NSModalResponse response = [alert runModal];
    
    return response == NSAlertFirstButtonReturn;
}


#pragma mark - App Discovery

- (void)loadApps {
    self.appManager = [[AppAssetManager alloc] initWithCallback:self];
    
    if (self.host.appList.count > 0) {
        [self displayApps];
        [self updateBoxArtForAllApps];
    }
    [self discoverAppsForHost:self.host];
}

- (void)updateBoxArtForAllApps {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        for (TemporaryApp* app in self.apps) {
            [self updateBoxArtCacheForApp:app];
        }
    });
}

- (void)displayApps {
    NSPredicate *predicate;
    if (self.filterText.length != 0) {
        predicate = [NSPredicate predicateWithFormat:@"name CONTAINS[cd] %@", self.filterText];
    } else {
        predicate = [NSPredicate predicateWithValue:YES];
    }
    NSArray<TemporaryApp *> *filteredApps = [self.host.appList.allObjects filteredArrayUsingPredicate:predicate];
    self.apps = [filteredApps sortedArrayUsingSelector:@selector(compareName:)];
    [self.collectionView moonlight_reloadDataKeepingSelection];
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
