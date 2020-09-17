//
//  HostCell.h
//  Moonlight for macOS
//
//  Created by Michael Kenny on 22/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "HostsViewControllerDelegate.h"
#import "BackgroundColorView.h"

@interface HostCell : NSCollectionViewItem
@property (weak) IBOutlet NSImageView *hostImageView;
@property (weak) IBOutlet NSTextField *hostName;
@property (weak) IBOutlet BackgroundColorView *statusLightView;
@property (weak) IBOutlet NSTextField *statusLabel;
@property (nonatomic, strong) TemporaryHost *host;
@property (nonatomic, weak) id<HostsViewControllerDelegate> delegate;

- (void)updateSelectedState:(BOOL)selected;

- (void)updateHostState;

@end
