//
//  AppsViewController.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 23/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import "AppsViewController.h"
#import "AppsViewControllerDelegate.h"
#import "AppCell.h"
#import "AppCellView.h"
#import "AlertPresenter.h"
#import "StreamViewController.h"
#import "NSWindow+Moonlight.h"
#import "NSCollectionView+Moonlight.h"
#import "NSApplication+Moonlight.h"
#import "ImageFader.h"
#import "NSView+Moonlight.h"

#import "Moonlight-Swift.h"

#import "F.h"

#import "HttpManager.h"
#import "IdManager.h"
#import "CryptoManager.h"
#import "AppListResponse.h"
#import "AppAssetManager.h"
#import "DataManager.h"
#import "ServerInfoResponse.h"
#import "DiscoveryWorker.h"
#import "ConnectionHelper.h"

@interface AppsViewController () <NSCollectionViewDataSource, AppsViewControllerDelegate, AppAssetCallback, NSSearchFieldDelegate, NSMenuItemValidation>
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *cmsIdToId;
@property (nonatomic, strong) NSArray<TemporaryApp *> *apps;
@property (nonatomic, strong) TemporaryApp *runningApp;

@property (nonatomic, strong) NSString *filterText;
@property (nonatomic) NSSearchField *getSearchField;

@property (nonatomic, strong) NSDictionary<NSString *, NSString *> *appNameToId;

@property (nonatomic, strong) AppAssetManager *appManager;
@property (nonatomic, strong) NSCache *boxArtCache;
@property (nonatomic) CGFloat itemScale;

@property (nonatomic) id windowDidBecomeKeyObserver;

@property (nonatomic, strong) TemporaryApp *currentlyHoveredApp;

@end

const CGFloat scaleBase = 1.125;

@implementation AppsViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    
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
}

- (void)viewWillAppear {
    [super viewWillAppear];
    
    self.parentViewController.title = self.host.name;
    self.parentViewController.view.window.subtitle = self.host.activeAddress;
    
    [self.parentViewController.view.window moonlight_toolbarItemForAction:@selector(backButtonClicked:)].enabled = YES;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wundeclared-selector"
    [self.parentViewController.view.window moonlight_toolbarItemForAction:@selector(addHostButtonClicked:)].enabled = NO;
#pragma clang diagnostic pop


    self.getSearchField.delegate = self;
    self.getSearchField.placeholderString = @"Search Apps";
}

- (void)viewDidAppear {
    [super viewDidAppear];
    
    __weak typeof(self) weakSelf = self;
    self.windowDidBecomeKeyObserver = [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidBecomeKeyNotification object:self.view.window queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        [weakSelf updateRunningAppState];
        
        [SettingsClass loadMoonlightSettingsFor:self.host.uuid];
    }];
}

- (BOOL)becomeFirstResponder {
    [self.view.window makeFirstResponder:self.collectionView];
    return [super becomeFirstResponder];
}

- (void)transitionToHostsVC {
    [[NSNotificationCenter defaultCenter] removeObserver:self.windowDidBecomeKeyObserver];
    
    [self.parentViewController.view.window makeFirstResponder:nil];
    
    [self.parentViewController transitionFromViewController:self toViewController:self.hostsVC options:NSViewControllerTransitionSlideRight completionHandler:^{
        [self.parentViewController.view.window makeFirstResponder:self.hostsVC];
        
        [self.view removeFromSuperview];
        [self removeFromParentViewController];
        
        self.appManager = nil;
        self.apps = @[];
        [self.collectionView reloadData];
    }];
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
    [self quitApp:self.runningApp completion:nil];
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
    [flowLayout invalidateLayout];
    
    [[NSUserDefaults standardUserDefaults] setFloat:self.itemScale forKey:@"itemScale"];
    
    for (AppCell *item in self.collectionView.visibleItems) {
        [item updateShadowPath];
    }
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
    TemporaryApp *app = [self itemsForSection:indexPath.section][indexPath.item];
    item.appName.stringValue = app.name;
    item.app = app;
    
    item.runningIconContainer.alphaValue = app != self.runningApp ? 0.0 : 1.0;
    item.runningIconContainer.hidden = app != self.runningApp;
    
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
    return [self filteredItems:self.apps forSection:section];
}

- (NSArray<TemporaryApp *> *)filteredItems:(NSArray<TemporaryApp *> *)rawItems forSection:(NSInteger)section {
    if (section == 0) {
        return [F filterArray:rawItems withBlock:^BOOL(TemporaryApp *obj) {
            return obj.pinned;
        }];
    } else {
        return [F filterArray:rawItems withBlock:^BOOL(TemporaryApp *obj) {
            return !obj.pinned;
        }];
    }
}


#pragma mark - NSSearchFieldDelegate

- (void)controlTextDidChange:(NSNotification *)obj {
    self.filterText = ((NSTextField *)obj.object).stringValue;
    [self displayApps];
    [self.collectionView reloadData];
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

        HttpManager *hMan = [[HttpManager alloc] initWithHost:app.host.activeAddress uniqueId:uniqueId serverCert:app.host.serverCert];
        HttpResponse *quitResponse = [[HttpResponse alloc] init];
        HttpRequest *quitRequest = [HttpRequest requestForResponse:quitResponse withUrlRequest:[hMan newQuitAppRequest]];
        
        [hMan executeRequestSynchronously:quitRequest];
        if (quitResponse.statusCode == 200) {
            ServerInfoResponse *serverInfoResp = [[ServerInfoResponse alloc] init];
            [hMan executeRequestSynchronously:[HttpRequest requestForResponse:serverInfoResp withUrlRequest:[hMan newServerInfoRequest:NO] fallbackError:401 fallbackRequest:[hMan newHttpServerInfoRequest]]];
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
                [AlertPresenter displayAlert:NSAlertStyleWarning title:@"Failed to quit app" message:@"If this app was started by another device, you'll need to quit from that device." window:self.view.window completionHandler:nil];
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
    NSMenuItem *quitAppMenuItem = [HostsViewController getMenuItemForIdentifier:@"quitAppMenuItem" inMenu:menu];
    NSMenuItem *hideAppMenuItem = [HostsViewController getMenuItemForIdentifier:@"hideAppMenuItem" inMenu:menu];
    NSMenuItem *pinAppMenuItem = [HostsViewController getMenuItemForIdentifier:@"pinAppMenuItem" inMenu:menu];
    if (app.pinned) {
        pinAppMenuItem.title = @"Unpin App";
        pinAppMenuItem.image = [NSImage imageWithSystemSymbolName:@"pin.slash" accessibilityDescription:nil];
    } else {
        pinAppMenuItem.title = @"Pin App";
        pinAppMenuItem.image = [NSImage imageWithSystemSymbolName:@"pin" accessibilityDescription:nil];
    }
    if (app.hidden) {
        hideAppMenuItem.title = @"Show App";
        hideAppMenuItem.image = [NSImage imageWithSystemSymbolName:@"eye" accessibilityDescription:nil];
    } else {
        hideAppMenuItem.title = @"Hide App";
        hideAppMenuItem.image = [NSImage imageWithSystemSymbolName:@"eye.slash" accessibilityDescription:nil];
    }

    quitAppMenuItem.image = [NSImage imageWithSystemSymbolName:@"xmark.circle" accessibilityDescription:nil];
    if (self.runningApp == nil || app != self.runningApp) {
        quitAppMenuItem.hidden = YES;
    }
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

- (void)updateRunningAppState {
    __weak typeof(self) weakSelf = self;
    NSOperation *operation = [NSBlockOperation blockOperationWithBlock:^{
        DiscoveryWorker *worker = [[DiscoveryWorker alloc] initWithHost:weakSelf.host uniqueId:[IdManager getUniqueId]];
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
    return [self.parentViewController.view.window moonlight_searchFieldInToolbar];
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
    alert.messageText = [NSString stringWithFormat:@"%@ is still running.\n\nDo you want to quit %@ and start %@?", currentApp.name, currentApp.name, newApp.name];
    
    [alert addButtonWithTitle:@"Yes"];
    [alert addButtonWithTitle:@"Cancel"];
    
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
    NSDictionary *updates = [self calculateUpateIndexPathsFromOld:old toNew:new];
    NSSet<NSIndexPath *> *deletions = updates[@"deletions"];
    NSSet<NSIndexPath *> *insertions = updates[@"insertions"];
    
    if (deletions.count != 0 || insertions.count != 0) {
        self.apps = [self fetchApps];
        
        [self.collectionView.animator performBatchUpdates:^{
            [self.collectionView deleteItemsAtIndexPaths:deletions];
            [self.collectionView insertItemsAtIndexPaths:insertions];
        } completionHandler:^(BOOL finished) {
            
        }];
    }
}

- (void)updateCollectionViewWithNewPinnedChangedApp:(TemporaryApp *)app newPinnedState:(BOOL)newPinnedState previousIndex:(NSInteger)previousIndex {
    NSArray<TemporaryApp *> *apps = [[self itemsForSection:newPinnedState == YES ? 0 : 1] sortedArrayUsingSelector:@selector(compareName:)];
    NSArray<NSString *> *appNames = [F mapArray:apps withBlock:^id(TemporaryApp *obj) {
        return obj.name;
    }];
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
        
    if (self.host.appList.count > 0) {
        [self displayApps];
    }
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
    
    NSArray<TemporaryApp *> *hiddenAwareApps = [F filterArray:filteredApps withBlock:^BOOL(TemporaryApp *obj) {
        if (self.host.showHiddenApps) {
            return YES;
        } else {
            return obj.hidden == NO;
        }
    }];
    
    return [hiddenAwareApps sortedArrayUsingSelector:@selector(compare:)];
}

- (void)displayApps {
    self.apps = [self fetchApps];
}

- (void)discoverAppsForHost:(TemporaryHost *)host {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *uniqueId = [IdManager getUniqueId];
        
        AppListResponse* appListResp = [ConnectionHelper getAppListForHostWithHostIP:host.activeAddress serverCert:host.serverCert uniqueID:uniqueId];
        
        if (appListResp == nil || ![appListResp isStatusOk] || [appListResp getAppList] == nil) {
            Log(LOG_W, @"Failed to get applist: %@", appListResp.statusMessage);
            dispatch_async(dispatch_get_main_queue(), ^{
                [AlertPresenter displayAlert:NSAlertStyleWarning title:@"Fetching App List Failed" message:@"The connection to the PC was interrupted." window:self.view.window completionHandler:^(NSModalResponse returnCode) {
                    host.state = StateOffline;
                    [self transitionToHostsVC];
                }];
            });
        } else {
            NSArray<TemporaryApp *> *oldItems = [self fetchApps];

            [self updateApplist:[appListResp getAppList] forHost:host];
            
            [self.appManager stopRetrieving];
            [self.appManager retrieveAssetsFromHost:self.host];
            
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
}

@end
