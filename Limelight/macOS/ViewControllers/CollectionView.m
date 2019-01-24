//
//  CollectionView.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 22/1/19.
//  Copyright © 2019 Moonlight Game Streaming Project. All rights reserved.
//

#import "CollectionView.h"
#import "HostsViewController.h"

#include <Carbon/Carbon.h>

@implementation CollectionView

- (void)keyDown:(NSEvent *)event {
    if (event.keyCode == kVK_Return || event.keyCode == kVK_Delete) {
        [self.nextResponder keyDown:event];
    } else {
        [super keyDown:event];
    }
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    if (menuItem.action == @selector(open:)) {
        return self.selectionIndexes.count == 1;
    }

    return YES;
}

@end
