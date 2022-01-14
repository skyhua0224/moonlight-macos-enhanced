//
//  HostsViewController.h
//  Moonlight for macOS
//
//  Created by Michael Kenny on 22/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "CollectionView.h"

@interface HostsViewController : NSViewController
@property (weak) IBOutlet CollectionView *collectionView;
+ (NSMenuItem *)getMenuItemForIdentifier:(NSString *)id inMenu:(NSMenu *)menu;
@end
