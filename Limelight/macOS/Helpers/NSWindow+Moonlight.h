//
//  NSWindow+Moonlight.h
//  Moonlight for macOS
//
//  Created by Michael Kenny on 29/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import <Cocoa/Cocoa.h>

@interface NSWindow (Moonlight)

- (void)moonlight_centerWindowOnFirstRun;
- (NSToolbarItem *)moonlight_toolbarItemForAction:(SEL)action;

@end
