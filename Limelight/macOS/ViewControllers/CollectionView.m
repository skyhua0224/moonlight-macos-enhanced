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

@import GameController;

typedef enum {
    controllerUp,
    controllerDown,
    controllerLeft,
    controllerRight,
    controllerEnter,
    controllerBack,
    controllerUnkwown,
} ControllerEvent;

typedef struct {
    BOOL dpadUp;
    BOOL dpadDown;
    BOOL dpadLeft;
    BOOL dpadRight;
    BOOL buttonA;
    BOOL buttonB;
} ControllerState;

@interface CollectionView ()
@property (nonatomic) id controllerConnectObserver;
@property (nonatomic) id controllerDisconnectObserver;
@property (nonatomic) ControllerState lastGamepadState;
@property (nonatomic) id windowDidResignKeyObserver;
@property (nonatomic) id windowDidBecomeKeyObserver;
@property (nonatomic) id windowDidEndSheetObserver;
@end

@implementation CollectionView

const NSEventModifierFlags modifierFlagsMask = NSEventModifierFlagShift | NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagCommand;

- (void)setShouldAllowNavigation:(BOOL)shouldAllowNavigation {
    if (shouldAllowNavigation == _shouldAllowNavigation) {
        return;
    }

    if (shouldAllowNavigation) {
        for (GCController *controller in GCController.controllers) {
            [self registerControllerCallbacks:controller];
        }
    } else {
        for (GCController *controller in GCController.controllers) {
            [self unregisterControllerCallbacks:controller];
        }
    }
    _shouldAllowNavigation = shouldAllowNavigation;
}

- (void)setShouldWindowObserversBeAround:(BOOL)shouldWindowObserversBeAround {
    if (shouldWindowObserversBeAround == _shouldWindowObserversBeAround) {
        return;
    }
    
    if (shouldWindowObserversBeAround) {
        [self addWindowObservers];
    } else {
        [self removeWindowObservers];
    }
    
    _shouldWindowObserversBeAround = shouldWindowObserversBeAround;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) {
        for (GCController *controller in GCController.controllers) {
            [self registerControllerCallbacks:controller];
        }
        
        __weak typeof(self) weakSelf = self;
        self.controllerConnectObserver = [[NSNotificationCenter defaultCenter] addObserverForName:GCControllerDidConnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification * _Nonnull note) {
            [weakSelf registerControllerCallbacks:note.object];
        }];
        self.controllerDisconnectObserver = [[NSNotificationCenter defaultCenter] addObserverForName:GCControllerDidDisconnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification * _Nonnull note) {
            [weakSelf unregisterControllerCallbacks:note.object];
        }];
    }
    return self;
}

- (void)addWindowObservers {
    NSWindow *mainWindow = NSApplication.sharedApplication.mainWindow;
    
    if (mainWindow != nil) {
        __weak typeof(self) weakSelf = self;
        self.windowDidResignKeyObserver = [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidResignKeyNotification object:mainWindow queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            weakSelf.shouldAllowNavigation = NO;
        }];
        self.windowDidBecomeKeyObserver = [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidBecomeKeyNotification object:mainWindow queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            weakSelf.shouldAllowNavigation = YES;
        }];
        self.windowDidEndSheetObserver = [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidEndSheetNotification object:mainWindow queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            weakSelf.shouldAllowNavigation = YES;
        }];
    }
}

- (void)removeWindowObservers {
    [[NSNotificationCenter defaultCenter] removeObserver:self.windowDidResignKeyObserver];
    [[NSNotificationCenter defaultCenter] removeObserver:self.windowDidBecomeKeyObserver];
    [[NSNotificationCenter defaultCenter] removeObserver:self.windowDidEndSheetObserver];
}

- (void)registerControllerCallbacks:(GCController *)controller {
    controller.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *gamepad, GCControllerElement *element) {
        if (self.shouldAllowNavigation) {
            ControllerEvent event;
            if (gamepad.dpad.up.pressed != self.lastGamepadState.dpadUp && gamepad.dpad.up.pressed) {
                event = controllerUp;
            } else if (gamepad.dpad.down.pressed != self.lastGamepadState.dpadDown && gamepad.dpad.down.pressed) {
                event = controllerDown;
            } else if (gamepad.dpad.left.pressed != self.lastGamepadState.dpadLeft && gamepad.dpad.left.pressed) {
                event = controllerLeft;
            } else if (gamepad.dpad.right.pressed != self.lastGamepadState.dpadRight && gamepad.dpad.right.pressed) {
                event = controllerRight;
            } else if (gamepad.buttonA.pressed != self.lastGamepadState.buttonA && gamepad.buttonA.pressed) {
                event = controllerEnter;
            } else if (gamepad.buttonB.pressed != self.lastGamepadState.buttonB && gamepad.buttonB.pressed) {
                event = controllerBack;
            } else {
                event = controllerUnkwown;
            }
            self.lastGamepadState = [self controllerStateFromGamepad:gamepad];
            
            [self performIntialSelectionIfNeededForControllerEvent:event];
        }
    };
}

- (void)unregisterControllerCallbacks:(GCController *)controller {
    controller.extendedGamepad.valueChangedHandler = nil;
}

- (ControllerState)controllerStateFromGamepad:(GCExtendedGamepad *)gamepad {
    ControllerState state;
    state.dpadUp = gamepad.dpad.up.pressed;
    state.dpadDown = gamepad.dpad.down.pressed;
    state.dpadLeft = gamepad.dpad.left.pressed;
    state.dpadRight = gamepad.dpad.right.pressed;
    
    return state;
}

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

- (void)performIntialSelectionIfNeededForControllerEvent:(ControllerEvent)event {
    if (self.selectionIndexPaths.count == 0) {
        switch (event) {
            case controllerUp:
            case controllerLeft: {
                NSCollectionViewScrollPosition scrollPosition;
                if (self.enclosingScrollView.contentView.bounds.origin.y <= 29) {
                    scrollPosition = NSCollectionViewScrollPositionBottom;
                } else {
                    scrollPosition = NSCollectionViewScrollPositionNone;
                }
                [self selectItemAtIndex:[self numberOfItemsInSection:0] - 1 atPosition:scrollPosition];
            }
                break;
                
            case controllerDown:
            case controllerRight: {
                NSCollectionViewScrollPosition scrollPosition;
                if (self.enclosingScrollView.contentView.bounds.origin.y >= -10) {
                    scrollPosition = NSCollectionViewScrollPositionTop;
                } else {
                    scrollPosition = NSCollectionViewScrollPositionNone;
                }
                [self selectItemAtIndex:0 atPosition:scrollPosition];
            }
                break;
                
            case controllerBack:
                [self sendKeyDown:kVK_Delete];
                break;
                
            default:
                break;
        }
    } else {
        switch (event) {
            case controllerUp:
                [self sendKeyDown:kVK_UpArrow];
                break;
            case controllerLeft:
                [self sendKeyDown:kVK_LeftArrow];
                break;
            case controllerDown:
                [self sendKeyDown:kVK_DownArrow];
                break;
            case controllerRight:
                [self sendKeyDown:kVK_RightArrow];
                break;
            case controllerEnter:
                [self sendKeyDown:kVK_Return];
                break;
            case controllerBack:
                [self sendKeyDown:kVK_Delete];
                break;

            case controllerUnkwown:
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
