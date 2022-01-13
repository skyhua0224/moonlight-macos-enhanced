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

@interface CollectionView ()
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

- (void)selectItemAtIndex:(NSInteger)index atPosition:(NSCollectionViewScrollPosition)position {
    if ([self numberOfItemsInSection:0] == 0) {
        return;
    }
    NSIndexPath *path = [NSIndexPath indexPathForItem:index inSection:0];
    NSSet<NSIndexPath *> *set = [NSSet setWithObject:path];
    [self selectItemsAtIndexPaths:set scrollPosition:position];
}

- (void)performNavigationForControllerEvent:(MoonlightControllerEvent)event {
    if (self.selectionIndexPaths.count == 0) {
        switch (event.button) {
            case kMCE_UpDpad:
            case kMCE_LeftDpad: {
                NSCollectionViewScrollPosition scrollPosition;
                if (self.enclosingScrollView.contentView.bounds.origin.y <= 29) {
                    scrollPosition = NSCollectionViewScrollPositionBottom;
                } else {
                    scrollPosition = NSCollectionViewScrollPositionNone;
                }
                [self selectItemAtIndex:[self numberOfItemsInSection:0] - 1 atPosition:scrollPosition];
            }
                break;
            case kMCE_DownDpad:
            case kMCE_RightDpad: {
                NSCollectionViewScrollPosition scrollPosition;
                if (self.enclosingScrollView.contentView.bounds.origin.y >= -10) {
                    scrollPosition = NSCollectionViewScrollPositionTop;
                } else {
                    scrollPosition = NSCollectionViewScrollPositionNone;
                }
                [self selectItemAtIndex:0 atPosition:scrollPosition];
            }
                break;
            case kMCE_BButton:
                [self sendKeyDown:kVK_Delete];
                break;
                
            case kMCE_Unknown:
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

            case kMCE_Unknown:
                break;
        }
    }
}

- (void)sendKeyDown:(CGKeyCode)keyCode {
    CGEventRef cgEvent = CGEventCreateKeyboardEvent(NULL, keyCode, true);
    NSEvent *event = [NSEvent eventWithCGEvent:cgEvent];
    [self keyDown:event];
}

- (void)performIntialSelectionIfNeededForEvent:(NSEvent *)event {
    if (self.selectionIndexPaths.count == 0) {
        switch (event.keyCode) {
            case kVK_UpArrow:
            case kVK_LeftArrow: {
                NSCollectionViewScrollPosition scrollPosition;
                if (self.enclosingScrollView.contentView.bounds.origin.y <= 29) {
                    scrollPosition = NSCollectionViewScrollPositionBottom;
                } else {
                    scrollPosition = NSCollectionViewScrollPositionNone;
                }
                [self selectItemAtIndex:[self numberOfItemsInSection:0] - 1 atPosition:scrollPosition];
            }
                break;
                
            case kVK_DownArrow:
            case kVK_RightArrow: {
                NSCollectionViewScrollPosition scrollPosition;
                if (self.enclosingScrollView.contentView.bounds.origin.y >= -10) {
                    scrollPosition = NSCollectionViewScrollPositionTop;
                } else {
                    scrollPosition = NSCollectionViewScrollPositionNone;
                }
                [self selectItemAtIndex:0 atPosition:scrollPosition];
            }
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
