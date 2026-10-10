//
//  StreamViewMac.h
//  Moonlight for macOS
//
//  Created by Michael Kenny on 27/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "StreamViewController.h"

@interface StreamViewMac : NSView
@property (nonatomic, strong) NSString *statusText;
@property (nonatomic, strong) NSString *appName;
@property (nonatomic, weak) id<KeyboardNotifiableDelegate> keyboardNotifiable;
@property (nonatomic) BOOL prefersHiddenLocalCursor;
// Receives trackpad touch events while indirect touches are enabled.
@property (nonatomic, copy) void (^touchHandler)(NSEvent *event, NSView *view);

// Opts the view in or out of raw trackpad contacts (needed for the precision touchpad).
- (void)setIndirectTouchesEnabled:(BOOL)enabled;

- (void)refreshPreferredLocalCursor;

@end
