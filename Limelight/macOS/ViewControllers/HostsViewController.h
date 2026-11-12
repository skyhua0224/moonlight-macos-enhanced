//
//  HostsViewController.h
//  Moonlight for macOS
//
//  Created by Michael Kenny on 22/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "CollectionView.h"

@class TemporaryHost;

@interface HostsViewController : NSViewController
@property (weak) IBOutlet CollectionView *collectionView;
+ (NSMenuItem *)getMenuItemForIdentifier:(NSString *)id inMenu:(NSMenu *)menu;
/// Sidebar home: this controller never puts its own view on screen. It loads the saved hosts, runs
/// discovery, pairing, wake and the forwarded host commands, and the window gets the new home directly
/// (a first-run page when there is no host yet).
- (void)deckInstallHomeIntoContainer:(NSViewController *)container;
/// Shows the workspace for a host in the container (first run: a discovered or added host was chosen).
- (void)deckEmbedWorkspaceForHost:(TemporaryHost *)host intoContainer:(NSViewController *)container;
@end
