//
//  AppCell.h
//  Moonlight for macOS
//
//  Created by Michael Kenny on 24/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "AppsViewControllerDelegate.h"

@interface AppCell : NSCollectionViewItem
@property (weak) IBOutlet NSTextField *appName;
@property (weak) IBOutlet NSImageView *appCoverArt;
@property (weak) IBOutlet NSImageView *runningIcon;
@property (nonatomic, strong) TemporaryApp *app;
@property (nonatomic, weak) id<AppsViewControllerDelegate> delegate;

- (void)updateSelectedState:(BOOL)selected;

@end
