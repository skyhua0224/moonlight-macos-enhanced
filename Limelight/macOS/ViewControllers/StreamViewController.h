//
//  StreamViewController.h
//  Moonlight for macOS
//
//  Created by Michael Kenny on 25/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "TemporaryApp.h"
#import "AppsViewControllerDelegate.h"

@interface StreamViewController : NSViewController
@property (nonatomic, strong) TemporaryApp *app;
@property (nonatomic, weak) id<AppsViewControllerDelegate> delegate;
@end
