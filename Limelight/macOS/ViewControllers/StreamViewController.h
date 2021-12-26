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

@protocol KeyboardNotifiableDelegate <NSObject>

- (BOOL)onKeyboardEquivalent:(NSEvent *)event;

@end

@interface StreamViewController : NSViewController
@property (nonatomic, strong) TemporaryApp *app;
@property (nonatomic, strong) TemporaryApp *privateApp;
@property (nonatomic, strong) NSString *privateAppId;
@property (nonatomic, strong) NSString *appName;
@property (nonatomic, weak) id<AppsViewControllerDelegate> delegate;
@end
