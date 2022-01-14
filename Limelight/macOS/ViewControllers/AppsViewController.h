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

@interface AppsViewController : NSViewController
@property (nonatomic, strong) TemporaryHost *host;
@property (nonatomic, strong) HostsViewController *hostsVC;
@property (weak) IBOutlet CollectionView *collectionView;

+ (BOOL)isWhitelistedGFEApp:(TemporaryApp *)app;
+ (CGSize)getAppCoverArtSize;

@end

extern BOOL hasFeaturePrivateAppListing(void);
extern BOOL hasFeaturePrivateAppOptimalSettings(void);
extern BOOL usesNewAppCoverArtAspectRatio(void);
