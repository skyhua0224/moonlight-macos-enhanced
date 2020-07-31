//
//  NSWindow+Moonlight.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 29/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import "NSWindow+Moonlight.h"

@implementation NSWindow (Moonlight)

- (void)moonlight_centerWindowOnFirstRun {
    NSString *key = [NSString stringWithFormat:@"NSWindow Frame %@", self.frameAutosaveName];
    if ([[NSUserDefaults standardUserDefaults] stringForKey:key].length == 0) {
        [self moonlight_centerWindow];
    }
}

- (void)moonlight_centerWindow {
    CGFloat xPos = NSWidth(self.screen.frame) / 2 - NSWidth(self.frame) / 2;
    CGFloat yPos = NSHeight(self.screen.frame) / 2 - NSHeight(self.frame) / 2;
    [self setFrame:NSMakeRect(xPos, yPos, NSWidth(self.frame), NSHeight(self.frame)) display:YES];
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
        if (@available(macOS 11.0, *)) {
            if ([item isKindOfClass:NSSearchToolbarItem.class]) {
                return ((NSSearchToolbarItem *)item).searchField;
            }
        } else {
            return ((NSSearchField *)[self moonlight_toolbarItemForIdentifier:@"OldSearchToolbarItem"].view);
        }
    }
    return nil;
}

@end
