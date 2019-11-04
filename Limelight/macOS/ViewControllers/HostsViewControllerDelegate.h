//
//  HostsViewControllerDelegate.h
//  Moonlight for macOS
//
//  Created by Michael Kenny on 23/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "TemporaryHost.h"

@protocol HostsViewControllerDelegate <NSObject>

- (void)openHost:(TemporaryHost *)host;

- (void)didOpenContextMenu:(NSMenu *)menu forHost:(TemporaryHost *)host;

@end
