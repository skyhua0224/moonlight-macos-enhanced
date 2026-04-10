//
//  NSWindow+Moonlight.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 29/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import "NSWindow+Moonlight.h"

@implementation NSWindow (Moonlight)

- (void)moonlight_centerWindowOnFirstRunWithSize:(CGSize)size {
    NSString *key = [NSString stringWithFormat:@"NSWindow Frame %@", self.frameAutosaveName];
    if ([[NSUserDefaults standardUserDefaults] stringForKey:key].length == 0) {
        if (!CGSizeEqualToSize(size, CGSizeZero)) {
            [self setFrame:NSMakeRect(0, 0, size.width, size.height) display:NO];
        }
        [self moonlight_centerWindow];
    }
}

- (void)moonlight_centerWindow {
    [self moonlight_centerWindowOnScreen:self.screen];
}

- (void)moonlight_centerWindowOnScreen:(NSScreen *)screen {
    NSScreen *targetScreen = screen ?: self.screen ?: [NSScreen mainScreen];
    NSRect visibleFrame = targetScreen ? targetScreen.visibleFrame : self.frame;
    CGFloat width = MIN(NSWidth(self.frame), NSWidth(visibleFrame));
    CGFloat height = MIN(NSHeight(self.frame), NSHeight(visibleFrame));
    CGFloat xPos = NSMidX(visibleFrame) - width / 2.0;
    CGFloat yPos = NSMidY(visibleFrame) - height / 2.0;
    [self setFrame:NSMakeRect(xPos, yPos, width, height) display:YES];
}

- (NSToolbarItem *)moonlight_toolbarItemForAction:(SEL)action {
    for (NSToolbarItem *item in self.toolbar.items) {
        if (item.action == action) {
            return item;
        }
    }
    return nil;
}

- (NSToolbarItem *)moonlight_toolbarItemForIdentifier:(NSToolbarItemIdentifier)identifier {
    for (NSToolbarItem *item in self.toolbar.items) {
        if ([identifier isEqualToString:item.itemIdentifier]) {
            return item;
        }
    }
    return nil;
}

- (NSSearchField *)moonlight_searchFieldInToolbar {
    for (NSToolbarItem *item in self.toolbar.items) {
        if ([item isKindOfClass:NSSearchToolbarItem.class]) {
            return ((NSSearchToolbarItem *)item).searchField;
        }
    }
    return nil;
}

@end
