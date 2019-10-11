//
//  ControllerSupport.m
//  Moonlight
//
//  Created by Cameron Gutman on 10/20/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "ControllerSupport.h"
#import "Controller.h"

#import "OnScreenControls.h"

#import "DataManager.h"
#include "Limelight.h"

@import GameController;
@import AudioToolbox;

enum ButtonDebouncerState {
    BDS_none,
    BDS_initialPress,
    BDS_down,
    BDS_replicatedPress,
    BDS_chord
};

@interface ButtonDebouncer : NSObject
@property (nonatomic) unsigned int button;
@property (nonatomic, strong) GCControllerButtonInput *input;
@property (nonatomic, strong) ControllerSupport *support;
@property (nonatomic) unsigned int chordButton;

@property (nonatomic, weak) ButtonDebouncer *other;

@property (nonatomic) enum ButtonDebouncerState state;
@property (nonatomic, strong) NSDate *buttonDownTime;
@property (nonatomic, strong) NSTimer *buttonDebounceTimer;
@property (nonatomic, strong) NSTimer *replicatedButtonTimeTimer;

@end

@implementation ButtonDebouncer

- (instancetype)initWithButton:(unsigned int)button input:(GCControllerButtonInput *)input controllerSupport:(ControllerSupport *)support chordButton:(unsigned int)chordButton {
    self = [super init];
    if (self) {
        self.button = button;
        self.input = input;
        self.support = support;
        self.chordButton = chordButton;
    }
    return self;
}

- (void)handlePress:(Controller *)controller pressedButtons:(int)pressedButtons {
    if (controller.lastButtonFlags & self.button) {
        if (self.state == BDS_none) {
            
            // If we are 2nd button and 1st button is in initialPress state, then:
            //   turn on chord button
            //   put 1st and 2nd buttons into special chord state
            if (self.other.state == BDS_initialPress) {
                
                [self transitionToChordState];
                [self.other transitionToChordState];

                [self updateLastButtonFlagsForChordState:controller];
            } else {

                self.state = BDS_initialPress;
                self.buttonDownTime = [[NSDate alloc] init];
                controller.lastButtonFlags &= ~self.button;
                
                [self.buttonDebounceTimer invalidate];
                self.buttonDebounceTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:NO block:^(NSTimer * _Nonnull timer) {
                    [self initialPressTimeout:controller];
                }];
            }
        } else if (self.state == BDS_initialPress) {
            controller.lastButtonFlags &= ~self.button;
        } else if (self.state == BDS_chord) {
            [self updateLastButtonFlagsForChordState:controller];
        }
    }
}

- (void)handleRelease:(Controller *)controller releasedButtons:(int)releasedButtons {
    if (releasedButtons & self.button) {
        
        if (self.state == BDS_down && !self.input.pressed) {
            self.state = BDS_none;
            
        } else if (self.state == BDS_initialPress && !self.input.pressed) {
            
            controller.lastButtonFlags |= self.button;
            [self.support updateFinished:controller];
            
            self.state = BDS_replicatedPress;
            
            NSTimeInterval pressDuration = -[self.buttonDownTime timeIntervalSinceNow];
            
            [self.buttonDebounceTimer invalidate];
            [self.replicatedButtonTimeTimer invalidate];
            self.replicatedButtonTimeTimer = [NSTimer scheduledTimerWithTimeInterval:pressDuration repeats:NO block:^(NSTimer * _Nonnull timer) {
                
                controller.lastButtonFlags &= ~self.button;
                [self.support updateFinished:controller];

                self.state = BDS_none;
            }];

        } else if (self.state == BDS_chord && !self.input.pressed) {
            if (self.other.state == BDS_chord && !self.other.input.pressed) {

                controller.lastButtonFlags &= ~self.chordButton;

                [self transitionToNoneState];
                [self.other transitionToNoneState];
            } else if (self.other.state == BDS_chord && self.other.input.pressed) {
                
                [self updateLastButtonFlagsForChordState:controller];
            }
        }
    }
}

- (void)initialPressTimeout:(Controller *)controller {
    if (self.state == BDS_initialPress) {
        if (self.input.pressed) {
            self.state = BDS_down;
            controller.lastButtonFlags |= self.button;
            [self.support updateFinished:controller];
        }
    }
}

- (void)transitionToChordState {
    self.state = BDS_chord;
}

- (void)transitionToNoneState {
    self.state = BDS_none;
}

- (void)updateLastButtonFlagsForChordState:(Controller *)controller {
    controller.lastButtonFlags |= self.chordButton;
    
    controller.lastButtonFlags &= ~self.button;
    controller.lastButtonFlags &= ~self.other.button;
}

@end

@implementation ControllerSupport {
    NSLock *_controllerStreamLock;
    NSMutableDictionary *_controllers;
    NSTimer *_rumbleTimer;
    
    OnScreenControls *_osc;
    
    // This controller object is shared between on-screen controls
    // and player 0
    Controller *_player0osc;
    
#define EMULATING_SELECT     0x1
#define EMULATING_SPECIAL    0x2
    
    bool _oscEnabled;
    char _controllerNumbers;
    bool _multiController;

    NSMutableDictionary<NSNumber * /* key flag */, NSMutableDictionary<NSNumber * /* player index */, ButtonDebouncer *> *> *_debouncers;
}

// UPDATE_BUTTON_FLAG(controller, flag, pressed)
#define UPDATE_BUTTON_FLAG(controller, x, y) \
((y) ? [self setButtonFlag:controller flags:x] : [self clearButtonFlag:controller flags:x])

-(void) rumbleController: (Controller*)controller
{
#if 0
    // Only vibrate if the amplitude is large enough
    if (controller.lowFreqMotor > 0x5000 || controller.highFreqMotor > 0x5000) {
        // If the gamepad is nil (on-screen controls) or it's attached to the device,
        // then vibrate the device itself
        UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy];
        [feedback prepare];
        [feedback impactOccurred];
    }
#endif
}

-(void) rumble:(unsigned short)controllerNumber lowFreqMotor:(unsigned short)lowFreqMotor highFreqMotor:(unsigned short)highFreqMotor
{
    Controller* controller = [_controllers objectForKey:[NSNumber numberWithInteger:controllerNumber]];
    if (controller == nil && controllerNumber == 0 && _oscEnabled) {
        // No physical controller, but we have on-screen controls
        controller = _player0osc;
    }
    if (controller == nil) {
        // No connected controller for this player
        return;
    }
    
    // Update the motor levels for the rumble timer to grab next iteration
    controller.lowFreqMotor = lowFreqMotor;
    controller.highFreqMotor = highFreqMotor;
    
    // Rumble now to ensure short vibrations aren't missed
    [self rumbleController:controller];
}

-(void) updateLeftStick:(Controller*)controller x:(short)x y:(short)y
{
    @synchronized(controller) {
        controller.lastLeftStickX = x;
        controller.lastLeftStickY = y;
    }
}

-(void) updateRightStick:(Controller*)controller x:(short)x y:(short)y
{
    @synchronized(controller) {
        controller.lastRightStickX = x;
        controller.lastRightStickY = y;
    }
}

-(void) updateLeftTrigger:(Controller*)controller left:(char)left
{
    @synchronized(controller) {
        controller.lastLeftTrigger = left;
    }
}

-(void) updateRightTrigger:(Controller*)controller right:(char)right
{
    @synchronized(controller) {
        controller.lastRightTrigger = right;
    }
}

-(void) updateTriggers:(Controller*) controller left:(char)left right:(char)right
{
    @synchronized(controller) {
        controller.lastLeftTrigger = left;
        controller.lastRightTrigger = right;
    }
}

-(void) handleSpecialCombosReleased:(Controller*)controller releasedButtons:(int)releasedButtons
{
    [self->_debouncers enumerateKeysAndObjectsUsingBlock:^(NSNumber * _Nonnull keyFlag, NSMutableDictionary<NSNumber *,ButtonDebouncer *> * _Nonnull debouncers, BOOL * _Nonnull stop) {
        ButtonDebouncer *debouncer = debouncers[@(controller.playerIndex)];
        [debouncer handleRelease:controller releasedButtons:releasedButtons];
    }];
}

-(void) handleSpecialCombosPressed:(Controller*)controller pressedButtons:(int)pressedButtons
{
    [self->_debouncers enumerateKeysAndObjectsUsingBlock:^(NSNumber * _Nonnull keyFlag, NSMutableDictionary<NSNumber *,ButtonDebouncer *> * _Nonnull debouncers, BOOL * _Nonnull stop) {
        ButtonDebouncer *debouncer = debouncers[@(controller.playerIndex)];
        [debouncer handlePress:controller pressedButtons:pressedButtons];
    }];
}

-(void) updateButtonFlags:(Controller*)controller flags:(int)flags
{
    @synchronized(controller) {
        controller.lastButtonFlags = flags;
        
        // This must be called before handleSpecialCombosPressed
        // because we clear the original button flags there
        int releasedButtons = (controller.lastButtonFlags ^ flags) & ~flags;
        int pressedButtons = (controller.lastButtonFlags ^ flags) & flags;
        
        [self handleSpecialCombosReleased:controller releasedButtons:releasedButtons];
        
        [self handleSpecialCombosPressed:controller pressedButtons:pressedButtons];
    }
}

-(void) setButtonFlag:(Controller*)controller flags:(int)flags
{
    @synchronized(controller) {
        controller.lastButtonFlags |= flags;
        [self handleSpecialCombosPressed:controller pressedButtons:flags];
    }
}

-(void) clearButtonFlag:(Controller*)controller flags:(int)flags
{
    @synchronized(controller) {
        controller.lastButtonFlags &= ~flags;
        [self handleSpecialCombosReleased:controller releasedButtons:flags];
    }
}

-(void) updateFinished:(Controller*)controller
{
    [_controllerStreamLock lock];
    @synchronized(controller) {
        // Player 1 is always present for OSC
        LiSendMultiControllerEvent(_multiController ? controller.playerIndex : 0,
                                   (_multiController ? _controllerNumbers : 1) | (_oscEnabled ? 1 : 0), controller.lastButtonFlags, controller.lastLeftTrigger, controller.lastRightTrigger, controller.lastLeftStickX, controller.lastLeftStickY, controller.lastRightStickX, controller.lastRightStickY);
    }
    [_controllerStreamLock unlock];
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

-(void) unregisterControllerCallbacks:(GCController*) controller
{
    if (controller != NULL) {
        controller.controllerPausedHandler = NULL;
        
        if (controller.extendedGamepad != NULL) {
            controller.extendedGamepad.valueChangedHandler = NULL;
        }
        else if (controller.gamepad != NULL) {
            controller.gamepad.valueChangedHandler = NULL;
        }
    }
}

-(void) registerControllerCallbacks:(GCController*) controller
{
    if (controller != NULL) {
        // iOS 13 allows the Start button to behave like a normal button, however
        // older MFi controllers can send an instant down+up event for the start button
        // which means the button will not be down long enough to register on the PC.
        // To work around this issue, use the old controllerPausedHandler if the controller
        // doesn't have a Select button (which indicates it probably doesn't have a proper
        // Start button either).
        BOOL useLegacyPausedHandler = YES;
        if (@available(iOS 13.0, tvOS 13.0, macOS 10.15, *)) {
            if (controller.extendedGamepad != nil &&
                controller.extendedGamepad.buttonOptions != nil) {
                useLegacyPausedHandler = NO;
            }
        }
        
        if (useLegacyPausedHandler) {
            controller.controllerPausedHandler = ^(GCController *controller) {
                Controller* limeController = [self->_controllers objectForKey:[NSNumber numberWithInteger:controller.playerIndex]];
                
                // Get off the main thread
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
                    [self setButtonFlag:limeController flags:PLAY_FLAG];
                    [self updateFinished:limeController];
                    
                    // Pause for 100 ms
                    usleep(100 * 1000);
                    
                    [self clearButtonFlag:limeController flags:PLAY_FLAG];
                    [self updateFinished:limeController];
                });
            };
        }
        
        if (controller.extendedGamepad != NULL) {
            controller.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *gamepad, GCControllerElement *element) {
                Controller* limeController = [self->_controllers objectForKey:[NSNumber numberWithInteger:gamepad.controller.playerIndex]];
                short leftStickX, leftStickY;
                short rightStickX, rightStickY;
                char leftTrigger, rightTrigger;
                
                UPDATE_BUTTON_FLAG(limeController, A_FLAG, gamepad.buttonA.pressed);
                UPDATE_BUTTON_FLAG(limeController, B_FLAG, gamepad.buttonB.pressed);
                UPDATE_BUTTON_FLAG(limeController, X_FLAG, gamepad.buttonX.pressed);
                UPDATE_BUTTON_FLAG(limeController, Y_FLAG, gamepad.buttonY.pressed);
                
                UPDATE_BUTTON_FLAG(limeController, UP_FLAG, gamepad.dpad.up.pressed);
                UPDATE_BUTTON_FLAG(limeController, DOWN_FLAG, gamepad.dpad.down.pressed);
                UPDATE_BUTTON_FLAG(limeController, LEFT_FLAG, gamepad.dpad.left.pressed);
                UPDATE_BUTTON_FLAG(limeController, RIGHT_FLAG, gamepad.dpad.right.pressed);
                
                UPDATE_BUTTON_FLAG(limeController, LB_FLAG, gamepad.leftShoulder.pressed);
                UPDATE_BUTTON_FLAG(limeController, RB_FLAG, gamepad.rightShoulder.pressed);
                
                // Yay, iOS 12.1 now supports analog stick buttons
                if (@available(iOS 12.1, tvOS 12.1, macOS 10.14.1, *)) {
                    if (gamepad.leftThumbstickButton != nil) {
                        UPDATE_BUTTON_FLAG(limeController, LS_CLK_FLAG, gamepad.leftThumbstickButton.pressed);
                    }
                    if (gamepad.rightThumbstickButton != nil) {
                        UPDATE_BUTTON_FLAG(limeController, RS_CLK_FLAG, gamepad.rightThumbstickButton.pressed);
                    }
                }
                
                if (@available(iOS 13.0, tvOS 13.0, macOS 10.15, *)) {
                    // Options button is optional (only present on Xbox One S and PS4 gamepads)
                    if (gamepad.buttonOptions != nil) {
                        UPDATE_BUTTON_FLAG(limeController, BACK_FLAG, gamepad.buttonOptions.pressed);

                        // For older MFi gamepads, the menu button will already be handled by
                        // the controllerPausedHandler.
                        UPDATE_BUTTON_FLAG(limeController, PLAY_FLAG, gamepad.buttonMenu.pressed);
                    }
                }
                
                leftStickX = gamepad.leftThumbstick.xAxis.value * 0x7FFE;
                leftStickY = gamepad.leftThumbstick.yAxis.value * 0x7FFE;
                
                rightStickX = gamepad.rightThumbstick.xAxis.value * 0x7FFE;
                rightStickY = gamepad.rightThumbstick.yAxis.value * 0x7FFE;
                
                leftTrigger = gamepad.leftTrigger.value * 0xFF;
                rightTrigger = gamepad.rightTrigger.value * 0xFF;
                
                [self updateLeftStick:limeController x:leftStickX y:leftStickY];
                [self updateRightStick:limeController x:rightStickX y:rightStickY];
                [self updateTriggers:limeController left:leftTrigger right:rightTrigger];
                [self updateFinished:limeController];
            };
        }
        else if (controller.gamepad != NULL) {
            controller.gamepad.valueChangedHandler = ^(GCGamepad *gamepad, GCControllerElement *element) {
                Controller* limeController = [self->_controllers objectForKey:[NSNumber numberWithInteger:gamepad.controller.playerIndex]];
                UPDATE_BUTTON_FLAG(limeController, A_FLAG, gamepad.buttonA.pressed);
                UPDATE_BUTTON_FLAG(limeController, B_FLAG, gamepad.buttonB.pressed);
                UPDATE_BUTTON_FLAG(limeController, X_FLAG, gamepad.buttonX.pressed);
                UPDATE_BUTTON_FLAG(limeController, Y_FLAG, gamepad.buttonY.pressed);
                
                UPDATE_BUTTON_FLAG(limeController, UP_FLAG, gamepad.dpad.up.pressed);
                UPDATE_BUTTON_FLAG(limeController, DOWN_FLAG, gamepad.dpad.down.pressed);
                UPDATE_BUTTON_FLAG(limeController, LEFT_FLAG, gamepad.dpad.left.pressed);
                UPDATE_BUTTON_FLAG(limeController, RIGHT_FLAG, gamepad.dpad.right.pressed);
                
                UPDATE_BUTTON_FLAG(limeController, LB_FLAG, gamepad.leftShoulder.pressed);
                UPDATE_BUTTON_FLAG(limeController, RB_FLAG, gamepad.rightShoulder.pressed);
                
                [self updateFinished:limeController];
            };
        }
    } else {
        Log(LOG_W, @"Tried to register controller callbacks on NULL controller");
    }
}

-(void) updateAutoOnScreenControlMode
{
    // Auto on-screen control support may not be enabled
    if (_osc == NULL) {
        return;
    }
    
    OnScreenControlsLevel level = OnScreenControlsLevelFull;
    
    // We currently stop after the first controller we find.
    // Maybe we'll want to change that logic later.
    for (int i = 0; i < [[GCController controllers] count]; i++) {
        GCController *controller = [GCController controllers][i];
        
        if (controller != NULL) {
            if (controller.extendedGamepad != NULL) {
                level = OnScreenControlsLevelAutoGCExtendedGamepad;
                if (@available(iOS 12.1, tvOS 12.1, macOS 10.14.1, *)) {
                    if (controller.extendedGamepad.leftThumbstickButton != nil &&
                        controller.extendedGamepad.rightThumbstickButton != nil) {
                        level = OnScreenControlsLevelAutoGCExtendedGamepad;
                        if (@available(iOS 13.0, tvOS 13.0, macOS 10.15, *)) {
                            if (controller.extendedGamepad.buttonOptions != nil) {
                                // Has L3/R3 and Select, so we can show nothing :)
                                level = OnScreenControlsLevelOff;
                            }
                        }
                    }
                }
                break;
            }
            else if (controller.gamepad != NULL) {
                level = OnScreenControlsLevelAutoGCGamepad;
                break;
            }
        }
    }
    
#if TARGET_OS_IPHONE
    [_osc setLevel:level];
#endif
}

-(void) initAutoOnScreenControlMode:(OnScreenControls*)osc
{
    _osc = osc;
    
    [self updateAutoOnScreenControlMode];
}

-(void) assignController:(GCController*)controller {
    for (int i = 0; i < 4; i++) {
        if (!(_controllerNumbers & (1 << i))) {
            _controllerNumbers |= (1 << i);
            controller.playerIndex = i;
            
            Controller* limeController;

            if (i == 0) {
                // Player 0 shares a controller object with the on-screen controls
                limeController = _player0osc;
            } else {
                limeController = [[Controller alloc] init];
                limeController.playerIndex = i;
            }
            
            limeController.gamepad = controller;

            [_controllers setObject:limeController forKey:[NSNumber numberWithInteger:controller.playerIndex]];
            
            Log(LOG_I, @"Assigning controller index: %d", i);
            break;
        }
    }
}

#if TARGET_OS_IPHONE
-(Controller*) getOscController {
    return _player0osc;
}
#endif

+(bool) isSupportedGamepad:(GCController*) controller {
    return controller.extendedGamepad != nil || controller.gamepad != nil;
}

#pragma clang diagnostic pop

+(int) getGamepadCount {
    int count = 0;
    
    for (GCController* controller in [GCController controllers]) {
        if ([ControllerSupport isSupportedGamepad:controller]) {
            count++;
        }
    }
    
    return count;
}

+(int) getConnectedGamepadMask:(StreamConfiguration*)streamConfig {
    int mask = 0;
    
//    if (streamConfig.multiController) {
//        int i = 0;
//        for (GCController* controller in [GCController controllers]) {
//            if ([ControllerSupport isSupportedGamepad:controller]) {
//                mask |= 1 << i++;
//            }
//        }
//    }
//    else {
        // Some games don't deal with having controller reconnected
        // properly so always report controller 1 if not in MC mode
        mask = 0x1;
//    }
    
#if TARGET_OS_IPHONE
    DataManager* dataMan = [[DataManager alloc] init];
    OnScreenControlsLevel level = (OnScreenControlsLevel)[[dataMan getSettings].onscreenControls integerValue];
    
    // Even if no gamepads are present, we will always count one
    // if OSC is enabled.
    if (level != OnScreenControlsLevelOff) {
        mask |= 0x1;
    }
#endif
    
    return mask;
}

-(void) rumbleTimer
{
    for (int i = 0; i < 4; i++) {
        Controller* controller = [_controllers objectForKey:[NSNumber numberWithInteger:i]];
        if (controller == nil && i == 0 && _oscEnabled) {
            // No physical controller, but we have on-screen controls
            controller = _player0osc;
        }
        if (controller == nil) {
            // No connected controller for this player
            continue;
        }
        
        [self rumbleController:controller];
    }
}

-(id) initWithConfig:(StreamConfiguration*)streamConfig
{
    self = [super init];
    
    _controllerStreamLock = [[NSLock alloc] init];
    _controllers = [[NSMutableDictionary alloc] init];
    _controllerNumbers = 0;
//    _multiController = streamConfig.multiController;

    _debouncers = [[NSMutableDictionary alloc] init];
    _debouncers[@(PLAY_FLAG)] = [[NSMutableDictionary alloc] init];
    _debouncers[@(BACK_FLAG)] = [[NSMutableDictionary alloc] init];

    _player0osc = [[Controller alloc] init];
    _player0osc.playerIndex = 0;

#if TARGET_OS_IPHONE
    DataManager* dataMan = [[DataManager alloc] init];
    _oscEnabled = (OnScreenControlsLevel)[[dataMan getSettings].onscreenControls integerValue] != OnScreenControlsLevelOff;
#endif
    
    _rumbleTimer = [NSTimer scheduledTimerWithTimeInterval:0.20
                                                    target:self
                                                  selector:@selector(rumbleTimer)
                                                  userInfo:nil
                                                   repeats:YES];
    
    Log(LOG_I, @"Number of supported controllers connected: %d", [ControllerSupport getGamepadCount]);
    Log(LOG_I, @"Multi-controller: %d", _multiController);
    
    for (GCController* controller in [GCController controllers]) {
        if ([ControllerSupport isSupportedGamepad:controller]) {
            [self assignController:controller];
            [self registerControllerCallbacks:controller];
            [self updateAutoOnScreenControlMode];

            if (@available(iOS 13.0, macOS 10.15, *)) {
                ButtonDebouncer *play = [[ButtonDebouncer alloc] initWithButton:PLAY_FLAG input:controller.extendedGamepad.buttonMenu controllerSupport:self chordButton:SPECIAL_FLAG];
                ButtonDebouncer *back = [[ButtonDebouncer alloc] initWithButton:BACK_FLAG input:controller.extendedGamepad.buttonOptions controllerSupport:self chordButton:SPECIAL_FLAG];
                play.other = back;
                back.other = play;
                _debouncers[@(PLAY_FLAG)][@(controller.playerIndex)] = play;
                _debouncers[@(BACK_FLAG)][@(controller.playerIndex)] = back;
            }
        }
    }
    
    self.connectObserver = [[NSNotificationCenter defaultCenter] addObserverForName:GCControllerDidConnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        Log(LOG_I, @"Controller connected!");
        
        GCController* controller = note.object;
        
        if (![ControllerSupport isSupportedGamepad:controller]) {
            // Ignore micro gamepads and motion controllers
            return;
        }
        
        [self assignController:controller];
        
        // Register callbacks on the new controller
        [self registerControllerCallbacks:controller];
        
        // Re-evaluate the on-screen control mode
        [self updateAutoOnScreenControlMode];
    }];
    self.disconnectObserver = [[NSNotificationCenter defaultCenter] addObserverForName:GCControllerDidDisconnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        Log(LOG_I, @"Controller disconnected!");
        
        GCController* controller = note.object;
        
        if (![ControllerSupport isSupportedGamepad:controller]) {
            // Ignore micro gamepads and motion controllers
            return;
        }
        
        [self unregisterControllerCallbacks:controller];
        self->_controllerNumbers &= ~(1 << controller.playerIndex);
        Log(LOG_I, @"Unassigning controller index: %ld", (long)controller.playerIndex);
        
        // Unset the GCController on this object (in case it is the OSC, which will persist)
        Controller* limeController = [self->_controllers objectForKey:[NSNumber numberWithInteger:controller.playerIndex]];
        limeController.gamepad = nil;
        
        // Inform the server of the updated active gamepads before removing this controller
        [self updateFinished:limeController];
        [self->_controllers removeObjectForKey:[NSNumber numberWithInteger:controller.playerIndex]];

        // Re-evaluate the on-screen control mode
        [self updateAutoOnScreenControlMode];
    }];
    return self;
}

-(void) cleanup
{
    [_rumbleTimer invalidate];
    _rumbleTimer = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self.connectObserver];
    [[NSNotificationCenter defaultCenter] removeObserver:self.disconnectObserver];
    [_controllers removeAllObjects];
    _controllerNumbers = 0;
    for (GCController* controller in [GCController controllers]) {
        if ([ControllerSupport isSupportedGamepad:controller]) {
            [self unregisterControllerCallbacks:controller];
        }
    }
}

@end
