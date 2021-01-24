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

@end
