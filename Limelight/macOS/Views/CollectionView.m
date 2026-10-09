//
//  CollectionView.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 22/1/19.
//  Copyright © 2019 Moonlight Game Streaming Project. All rights reserved.
//

#import "CollectionView.h"
#import "HostsViewController.h"
#import "NSResponder+Moonlight.h"

#include <Carbon/Carbon.h>

@import GameController;

@interface CollectionView () <NSMenuItemValidation>
@end

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

- (void)controllerEvent:(MoonlightControllerEvent)event {
    [self performNavigationForControllerEvent:event];
}

- (nullable NSIndexPath *)edgeItemIndexPathFirst:(BOOL)first {
    // Apps are split into pinned and unpinned sections; either can be empty.
    NSInteger sections = self.numberOfSections;
    for (NSInteger i = 0; i < sections; i++) {
        NSInteger section = first ? i : sections - 1 - i;
        NSInteger count = [self numberOfItemsInSection:section];
        if (count > 0) {
            return [NSIndexPath indexPathForItem:first ? 0 : count - 1 inSection:section];
        }
    }
    return nil;
}

- (void)selectEdgeItemFirst:(BOOL)first {
    NSIndexPath *path = [self edgeItemIndexPathFirst:first];
    if (path == nil) {
        return;
    }
    NSCollectionViewScrollPosition position;
    if (first) {
        position = self.enclosingScrollView.contentView.bounds.origin.y >= -10
            ? NSCollectionViewScrollPositionTop : NSCollectionViewScrollPositionNone;
    } else {
        position = self.enclosingScrollView.contentView.bounds.origin.y <= 29
            ? NSCollectionViewScrollPositionBottom : NSCollectionViewScrollPositionNone;
    }
    [self selectItemsAtIndexPaths:[NSSet setWithObject:path] scrollPosition:position];
}

- (void)selectFirstItemForControllerIfNeeded {
    if (self.selectionIndexPaths.count == 0 && GCController.controllers.count > 0 &&
        self.window.isKeyWindow) {
        [self selectEdgeItemFirst:YES];
    }
}

- (void)reloadData {
    [super reloadData];
    // A controller has no pointer: keep one item selected so A can open it.
    dispatch_async(dispatch_get_main_queue(), ^{
        [self selectFirstItemForControllerIfNeeded];
    });
}

- (void)performNavigationForControllerEvent:(MoonlightControllerEvent)event {
    if (self.selectionIndexPaths.count == 0) {
        switch (event.button) {
            case kMCE_UpDpad:
            case kMCE_LeftDpad:
                [self selectEdgeItemFirst:NO];
                break;
            case kMCE_DownDpad:
            case kMCE_RightDpad:
            case kMCE_AButton:
                [self selectEdgeItemFirst:YES];
                break;
            case kMCE_BButton:
                [self sendKeyDown:kVK_Delete];
                break;
                
            default:
                break;
        }
    } else {
        switch (event.button) {
            case kMCE_UpDpad:
                [self sendKeyDown:kVK_UpArrow];
                break;
            case kMCE_LeftDpad:
                [self sendKeyDown:kVK_LeftArrow];
                break;
            case kMCE_DownDpad:
                [self sendKeyDown:kVK_DownArrow];
                break;
            case kMCE_RightDpad:
                [self sendKeyDown:kVK_RightArrow];
                break;
            case kMCE_AButton:
                [self sendKeyDown:kVK_Return];
                break;
            case kMCE_BButton:
                [self sendKeyDown:kVK_Delete];
                break;

            default:
                break;
        }
    }
}

- (void)sendKeyDown:(CGKeyCode)keyCode {
    CGEventRef cgEvent = CGEventCreateKeyboardEvent(NULL, keyCode, true);
    CGEventSetFlags(cgEvent, 0);
    NSEvent *event = [NSEvent eventWithCGEvent:cgEvent];
    [self keyDown:event];
}

- (void)performIntialSelectionIfNeededForEvent:(NSEvent *)event {
    if (self.selectionIndexPaths.count == 0) {
        switch (event.keyCode) {
            case kVK_UpArrow:
            case kVK_LeftArrow:
                [self selectEdgeItemFirst:NO];
                break;
                
            case kVK_DownArrow:
            case kVK_RightArrow:
                [self selectEdgeItemFirst:YES];
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
        return self.selectionIndexPaths.count == 1;
    }

    return YES;
}

@end
