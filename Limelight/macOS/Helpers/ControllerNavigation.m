//
//  ControllerNavigation.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 13/1/2022.
//  Copyright © 2022 Moonlight Game Streaming Project. All rights reserved.
//

#import "ControllerNavigation.h"
#import "NSResponder+Moonlight.h"

@import GameController;

typedef struct {
    struct {
        BOOL up;
        BOOL down;
        BOOL left;
        BOOL right;
    } dpad;
    struct {
        BOOL up;
        BOOL down;
        BOOL left;
        BOOL right;
    } leftThumbstick;
    BOOL buttonA;
    BOOL buttonB;
    BOOL buttonX;
} ControllerState;

@interface ControllerNavigation ()
@property (nonatomic) id controllerConnectObserver;
@property (nonatomic) id controllerDisconnectObserver;
@property (nonatomic) ControllerState lastGamepadState;
@end

@implementation ControllerNavigation

- (instancetype)init {
    self = [super init];
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

#define COMPARE_STATES(Name) \
    gamepad.Name.pressed != self.lastGamepadState.Name && gamepad.Name.pressed

- (void)registerControllerCallbacks:(GCController *)controller {
    controller.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *gamepad, GCControllerElement *element) {
        MoonlightControllerEvent event;
        if (COMPARE_STATES(dpad.up)) {
            event.button = kMCE_UpDpad;
        } else if (COMPARE_STATES(dpad.down)) {
            event.button = kMCE_DownDpad;
        } else if (COMPARE_STATES(dpad.left)) {
            event.button = kMCE_LeftDpad;
        } else if (COMPARE_STATES(dpad.right)) {
            event.button = kMCE_RightDpad;
//        } else if (COMPARE_STATES(leftThumbstick.up)) {
//            event.button = kMCE_UpDpad;
//        } else if (COMPARE_STATES(leftThumbstick.down)) {
//            event.button = kMCE_DownDpad;
//        } else if (COMPARE_STATES(leftThumbstick.left)) {
//            event.button = kMCE_LeftDpad;
//        } else if (COMPARE_STATES(leftThumbstick.right)) {
//            event.button = kMCE_RightDpad;
        } else if (COMPARE_STATES(buttonA)) {
            event.button = kMCE_AButton;
        } else if (COMPARE_STATES(buttonB)) {
            event.button = kMCE_BButton;
        } else if (COMPARE_STATES(buttonX)) {
            event.button = kMCE_XButton;
        } else {
            event.button = kMCE_Unknown;
        }
        self.lastGamepadState = [self controllerStateFromGamepad:gamepad];
        
        [NSApplication.sharedApplication.mainWindow.firstResponder controllerEvent:event];
    };
}

- (void)unregisterControllerCallbacks:(GCController *)controller {
    controller.extendedGamepad.valueChangedHandler = nil;
}

#define COPY_STATE(Name) \
    state.Name = gamepad.Name.pressed

- (ControllerState)controllerStateFromGamepad:(GCExtendedGamepad *)gamepad {
    ControllerState state;
    COPY_STATE(dpad.up);
    COPY_STATE(dpad.down);
    COPY_STATE(dpad.left);
    COPY_STATE(dpad.right);
//    COPY_STATE(leftThumbstick.up);
//    COPY_STATE(leftThumbstick.down);
//    COPY_STATE(leftThumbstick.left);
//    COPY_STATE(leftThumbstick.right);
    COPY_STATE(buttonA);
    COPY_STATE(buttonB);
    COPY_STATE(buttonX);

    return state;
}

@end
