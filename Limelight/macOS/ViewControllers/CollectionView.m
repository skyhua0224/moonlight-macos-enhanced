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

const NSEventModifierFlags modifierFlagsMask = NSEventModifierFlagShift | NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagCommand;

- (void)keyDown:(NSEvent *)event {
    if ((event.modifierFlags & modifierFlagsMask) == 0) {
        switch (event.keyCode) {
            case kVK_Return:
            case kVK_Delete:
                [self.nextResponder keyDown:event];
                break;
            case kVK_UpArrow:
            case kVK_DownArrow:
            case kVK_LeftArrow:
            case kVK_RightArrow:
                [self performIntialSelectionIfNeededForEvent:event];
                break;
                
            default:
                [super keyDown:event];
                break;
        }
    } else {
        [super keyDown:event];
    }
}

- (void)selectItemAtIndex:(NSInteger)index atPosition:(NSCollectionViewScrollPosition)position {
    if ([self numberOfItemsInSection:0] == 0) {
        return;
    }
    NSIndexPath *path = [NSIndexPath indexPathForItem:index inSection:0];
    NSSet<NSIndexPath *> *set = [NSSet setWithObject:path];
    [self selectItemsAtIndexPaths:set scrollPosition:position];
}

- (void)performIntialSelectionIfNeededForEvent:(NSEvent *)event {
    if (self.selectionIndexes.count == 0) {
        switch (event.keyCode) {
            case kVK_UpArrow:
            case kVK_LeftArrow:
                [self selectItemAtIndex:[self numberOfItemsInSection:0] - 1 atPosition:NSCollectionViewScrollPositionBottom];
                break;
                
            case kVK_DownArrow:
            case kVK_RightArrow:
                [self selectItemAtIndex:0 atPosition:NSCollectionViewScrollPositionTop];
                break;
                
            default:
                break;
        }
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
