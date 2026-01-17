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
@property (nonatomic, strong) TemporaryHost *host;
@property (nonatomic, weak) id<AppsViewControllerNavigationDelegate> navigationDelegate;
@property (weak) IBOutlet CollectionView *collectionView;

- (void)switchToHost:(TemporaryHost *)newHost;

@end

extern BOOL usesNewAppCoverArtAspectRatio(void);
