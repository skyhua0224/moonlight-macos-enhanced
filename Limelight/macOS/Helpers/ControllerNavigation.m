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
    BOOL dpadUp;
    BOOL dpadDown;
    BOOL dpadLeft;
    BOOL dpadRight;
    BOOL buttonA;
    BOOL buttonB;
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

- (void)registerControllerCallbacks:(GCController *)controller {
    controller.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *gamepad, GCControllerElement *element) {
        MoonlightControllerEvent event;
        if (gamepad.dpad.up.pressed != self.lastGamepadState.dpadUp && gamepad.dpad.up.pressed) {
            event.button = kMCE_UpDpad;
        } else if (gamepad.dpad.down.pressed != self.lastGamepadState.dpadDown && gamepad.dpad.down.pressed) {
            event.button = kMCE_DownDpad;
        } else if (gamepad.dpad.left.pressed != self.lastGamepadState.dpadLeft && gamepad.dpad.left.pressed) {
            event.button = kMCE_LeftDpad;
        } else if (gamepad.dpad.right.pressed != self.lastGamepadState.dpadRight && gamepad.dpad.right.pressed) {
            event.button = kMCE_RightDpad;
        } else if (gamepad.buttonA.pressed != self.lastGamepadState.buttonA && gamepad.buttonA.pressed) {
            event.button = kMCE_AButton;
        } else if (gamepad.buttonB.pressed != self.lastGamepadState.buttonB && gamepad.buttonB.pressed) {
            event.button = kMCE_BButton;
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

- (ControllerState)controllerStateFromGamepad:(GCExtendedGamepad *)gamepad {
    ControllerState state;
    state.dpadUp = gamepad.dpad.up.pressed;
    state.dpadDown = gamepad.dpad.down.pressed;
    state.dpadLeft = gamepad.dpad.left.pressed;
    state.dpadRight = gamepad.dpad.right.pressed;
    
    return state;
}

@end
