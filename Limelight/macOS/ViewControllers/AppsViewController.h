//
//  AppsViewController.h
//  Moonlight for macOS
//
//  Created by Michael Kenny on 23/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "TemporaryApp.h"
#import "TemporaryHost.h"
#import "HostsViewController.h"
#import "CollectionView.h"

#define CUSTOM_PRIVATE_GFE_PORT (49999)

@class AppsViewController;

@protocol AppsViewControllerNavigationDelegate <NSObject>
- (void)appsViewControllerDidRequestBack:(AppsViewController *)controller;
@end

@interface AppsViewController : NSViewController
// atomic: background tasks (app list, assets) read it while the main thread switches computers
@property (atomic, strong) TemporaryHost *host;
@property (nonatomic, weak) id<AppsViewControllerNavigationDelegate> navigationDelegate;
@property (weak) IBOutlet CollectionView *collectionView;
/// An app to start as soon as the page has loaded (resume from the host page).
@property (nonatomic, copy, nullable) NSString *pendingLaunchAppId;

- (void)switchToHost:(TemporaryHost *)newHost;

@end

extern BOOL usesNewAppCoverArtAspectRatio(void);
