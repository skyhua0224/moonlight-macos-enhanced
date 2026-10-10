//
//  ControllerNavigation.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 13/1/2022.
//  Copyright © 2022 Moonlight Game Streaming Project. All rights reserved.
//

#import "ControllerNavigation.h"
#import "NSResponder+Moonlight.h"
#import "NSWindow+Moonlight.h"
#import "MoonlightEnhanced-Swift.h"

@import GameController;

// Navigation reads Apple's profile state without replacing the streaming
// callbacks. Each device has its own edge/repeat state, scoped to the key UI.
typedef struct {
    uint32_t buttons;
    double repeatAt;
} ControllerUIState;

enum {
    UIUp = 1 << 0,
    UIDown = 1 << 1,
    UILeft = 1 << 2,
    UIRight = 1 << 3,
    UIA = 1 << 4,
    UIB = 1 << 5,
    UIX = 1 << 6,
    UIMenu = 1 << 7,
    UIViewButton = 1 << 8,
    UILB = 1 << 9,
    UIRB = 1 << 10,
    UIY = 1 << 11,
};

static const uint32_t UIDirections = UIUp | UIDown | UILeft | UIRight;

@interface ControllerNavigation ()
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) NSMapTable<GCController *, NSValue *> *states;
@property (nonatomic, weak) NSWindow *navigationWindow;
@property (nonatomic) BOOL menuTracking;
@property (nonatomic) BOOL suspended;
@property (nonatomic, strong) NSArray<id> *observers;
@property (nonatomic, strong) id pointerMonitor;
@property (nonatomic, strong) ControllerHintPresenter *hints;
@property (nonatomic, strong) ControllerFocusNavigator *focusNavigator;
// The legend follows whichever input was used last: controller or pointer.
@property (nonatomic) BOOL controllerInUse;
@end

@implementation ControllerNavigation

- (instancetype)init {
    self = [super init];
    if (self) {
        self.states = [NSMapTable weakToStrongObjectsMapTable];
        self.hints = [[ControllerHintPresenter alloc] init];
        self.focusNavigator = [[ControllerFocusNavigator alloc] init];
        self.controllerInUse = YES;

        __weak typeof(self) weakSelf = self;
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        NSOperationQueue *main = NSOperationQueue.mainQueue;
        void (^refresh)(NSNotification *) = ^(NSNotification *note) {
            [weakSelf updatePollingTimer];
        };
        self.observers = @[
            [center addObserverForName:NSMenuDidBeginTrackingNotification object:nil queue:main usingBlock:^(NSNotification *note) {
                weakSelf.menuTracking = YES;
            }],
            [center addObserverForName:NSMenuDidEndTrackingNotification object:nil queue:main usingBlock:^(NSNotification *note) {
                weakSelf.menuTracking = NO;
            }],
            // Poll only while a controller is connected and the app is in front.
            [center addObserverForName:GCControllerDidConnectNotification object:nil queue:main usingBlock:refresh],
            [center addObserverForName:GCControllerDidDisconnectNotification object:nil queue:main usingBlock:refresh],
            [center addObserverForName:NSApplicationDidBecomeActiveNotification object:nil queue:main usingBlock:refresh],
            [center addObserverForName:NSApplicationDidResignActiveNotification object:nil queue:main usingBlock:refresh],
            // A shortcut capture sheet reads the controller directly.
            [center addObserverForName:@"ControllerNavigationSuspended" object:nil queue:main usingBlock:^(NSNotification *note) {
                weakSelf.suspended = [note.userInfo[@"suspended"] boolValue];
            }],
        ];
        self.pointerMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown | NSEventMaskScrollWheel | NSEventMaskMouseMoved
                                                                    handler:^NSEvent *(NSEvent *event) {
            // Right-stick scrolling is delivered with -sendEvent: and never reaches this monitor.
            weakSelf.controllerInUse = NO;
            return event;
        }];
        [self updatePollingTimer];
    }
    return self;
}

- (void)dealloc {
    [self.timer invalidate];
    [self.hints hide];
    if (self.pointerMonitor) {
        [NSEvent removeMonitor:self.pointerMonitor];
    }
    for (id observer in self.observers) {
        [NSNotificationCenter.defaultCenter removeObserver:observer];
    }
}

- (void)updatePollingTimer {
    BOOL wanted = NSApp.active && GCController.controllers.count > 0;
    if (wanted && self.timer == nil) {
        __weak typeof(self) weakSelf = self;
        self.timer = [NSTimer timerWithTimeInterval:1.0 / 60.0 repeats:YES block:^(NSTimer *timer) {
            [weakSelf pollNavigation];
        }];
        [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
    } else if (!wanted && self.timer != nil) {
        [self.timer invalidate];
        self.timer = nil;
        self.navigationWindow = nil;
        [self.states removeAllObjects];
        [self.hints hide];
        [self.focusNavigator reset];
    }
}

- (uint32_t)buttonsFor:(GCExtendedGamepad *)pad {
    return ((pad.dpad.up.pressed || pad.leftThumbstick.yAxis.value > 0.6f) ? UIUp : 0) |
        ((pad.dpad.down.pressed || pad.leftThumbstick.yAxis.value < -0.6f) ? UIDown : 0) |
        ((pad.dpad.left.pressed || pad.leftThumbstick.xAxis.value < -0.6f) ? UILeft : 0) |
        ((pad.dpad.right.pressed || pad.leftThumbstick.xAxis.value > 0.6f) ? UIRight : 0) |
        (pad.buttonA.pressed ? UIA : 0) |
        (pad.buttonB.pressed ? UIB : 0) |
        (pad.buttonX.pressed ? UIX : 0) |
        (pad.buttonY.pressed ? UIY : 0) |
        (pad.buttonMenu.pressed ? UIMenu : 0) |
        (pad.buttonOptions.pressed ? UIViewButton : 0) |
        (pad.leftShoulder.pressed ? UILB : 0) |
        (pad.rightShoulder.pressed ? UIRB : 0);
}

- (void)postKey:(unsigned short)code text:(NSString *)text modifiers:(NSEventModifierFlags)modifiers window:(NSWindow *)window {
    for (NSUInteger i = 0; i < 2; i++) {
        NSEvent *event = [NSEvent keyEventWithType:i == 0 ? NSEventTypeKeyDown : NSEventTypeKeyUp
                                          location:NSZeroPoint
                                     modifierFlags:modifiers
                                         timestamp:NSProcessInfo.processInfo.systemUptime
                                      windowNumber:window.windowNumber
                                           context:nil
                                        characters:text
                       charactersIgnoringModifiers:text
                                         isARepeat:NO
                                           keyCode:code];
        // App-local events also work while a native picker menu is tracking.
        [NSApp postEvent:event atStart:NO];
    }
}

- (void)pollNavigation {
    // The controller menu panel takes every input while it is open.
    ControllerMenuPanel *menuPanel = ControllerMenuPanel.shared;
    ControllerKeyboardPanel *keyboard = ControllerKeyboardPanel.shared;
    [keyboard validate];
    BOOL menuOverlay = menuPanel.isPresented && menuPanel.parentWindow != nil;
    BOOL keyboardOverlay = !menuOverlay && keyboard.isPresented && keyboard.parentWindow != nil;
    BOOL overlay = menuOverlay || keyboardOverlay;
    NSWindow *window = menuOverlay ? menuPanel.parentWindow : (keyboardOverlay ? keyboard.parentWindow : NSApp.keyWindow);
    NSWindow *root = window;
    while (root.sheetParent) {
        root = root.sheetParent;
    }
    BOOL main = !overlay && [root.identifier isEqualToString:@"MainWindow"] && root == window;
    BOOL settingsWindow = [root.identifier isEqualToString:@"ClientSettingsWindow"];
    BOOL settings = !overlay && settingsWindow;
    BOOL streamMenu = !overlay && self.menuTracking && [root.identifier isEqualToString:@"ClientStreamWindow"];
    if (!NSApp.active || !window || (!overlay && !main && !settings && !streamMenu)) {
        self.navigationWindow = nil;
        [self.hints hide];
        [self.focusNavigator updateWithWindow:nil showRing:NO];
        return;
    }

    BOOL changed = self.navigationWindow != window;
    self.navigationWindow = window;
    double now = NSProcessInfo.processInfo.systemUptime;
    for (GCController *controller in GCController.controllers) {
        GCExtendedGamepad *pad = controller.extendedGamepad;
        if (!pad) {
            continue;
        }

        ControllerUIState state = {0};
        NSValue *previous = [self.states objectForKey:controller];
        if (previous) {
            [previous getValue:&state size:sizeof(state)];
        }
        uint32_t buttons = [self buttonsFor:pad];
        if (self.suspended) {
            // Keep edge state current so the capture's presses do not fire on resume.
            state.buttons = buttons;
            state.repeatAt = 0;
            [self.states setObject:[NSValue valueWithBytes:&state objCType:@encode(ControllerUIState)] forKey:controller];
            continue;
        }
        if (buttons != 0 || fabsf(pad.rightThumbstick.yAxis.value) > 0.3f) {
            self.controllerInUse = YES;
        }
        // A window change swallows the press that caused it.
        uint32_t pressed = (changed || !previous) ? 0 : buttons & ~state.buttons;
        uint32_t directions = buttons & UIDirections;
        if (pressed & directions) {
            state.repeatAt = now + 0.35;
        } else if (directions && state.repeatAt > 0 && now >= state.repeatAt && !changed) {
            pressed |= directions;
            state.repeatAt = now + 0.10;
        } else if (!directions || changed) {
            state.repeatAt = 0;
        }
        state.buttons = buttons;
        [self.states setObject:[NSValue valueWithBytes:&state objCType:@encode(ControllerUIState)] forKey:controller];

        if (overlay) {
            [self sendPressed:pressed toHandler:^(ControllerFocusInput input) {
                if (keyboardOverlay) {
                    [keyboard handleInput:input];
                } else {
                    [menuPanel handleInput:input];
                }
            }];
            continue;
        }

        if (pressed & UIViewButton) {
            NSSearchField *search = main ? [window moonlight_searchFieldInToolbar] : nil;
            if (search) {
                if ([window makeFirstResponder:search]) {
                    [keyboard presentInWindow:window];
                }
            } else if (!window.sheetParent) {
                [NSNotificationCenter.defaultCenter postNotificationName:@"ControllerFocusSettingsSearch" object:window];
                if (settings) {
                    [self.focusNavigator focusSearchFieldInWindow:window];
                }
            }
            continue;
        }
        if (main && (pressed & UIMenu)) {
            [NSApp sendAction:@selector(showPreferences:) to:nil from:window];
            continue;
        }

        NSResponder *responder = window.firstResponder;
        while (responder && ![responder isKindOfClass:NSCollectionView.class]) {
            responder = responder.nextResponder;
        }
        if (main && responder && !self.menuTracking) {
            const uint32_t masks[] = {UIUp, UIDown, UILeft, UIRight, UIA, UIB, UIX};
            const unsigned short actions[] = {kMCE_UpDpad, kMCE_DownDpad, kMCE_LeftDpad, kMCE_RightDpad,
                                              kMCE_AButton, kMCE_BButton, kMCE_XButton};
            for (NSUInteger i = 0; i < 7; i++) {
                if (pressed & masks[i]) {
                    [responder controllerEvent:(MoonlightControllerEvent){.button = actions[i]}];
                }
            }
            continue;
        }

        // Settings: a focus ring over every control, LB/RB pick the column.
        if (settings && !self.menuTracking) {
            ControllerFocusNavigator *navigator = self.focusNavigator;
            [self sendPressed:pressed & ~(UIB | UIX | UIY | UIMenu) toHandler:^(ControllerFocusInput input) {
                [navigator handleInput:input window:window];
            }];
            if ((pressed & UIB) && ![navigator handleInput:ControllerFocusInputBack window:window]) {
                if (window.sheetParent) {
                    [self postKey:53 text:@"\033" modifiers:0 window:window];
                } else {
                    [window performClose:nil];
                }
            }
            if (fabsf(pad.rightThumbstick.yAxis.value) > 0.3f) {
                [self scrollWindow:window amount:pad.rightThumbstick.yAxis.value];
            }
            continue;
        }

        // Menus: move with arrows, confirm with Return.
        if (pressed & (UIUp | UILB)) {
            if (self.menuTracking) {
                [self postKey:126 text:@"" modifiers:0 window:window];
            } else {
                [self postKey:48 text:@"\t" modifiers:NSEventModifierFlagShift window:window];
            }
        }
        if (pressed & (UIDown | UIRB)) {
            if (self.menuTracking) {
                [self postKey:125 text:@"" modifiers:0 window:window];
            } else {
                [self postKey:48 text:@"\t" modifiers:0 window:window];
            }
        }
        if (pressed & UILeft) {
            [self postKey:123 text:@"" modifiers:0 window:window];
        }
        if (pressed & UIRight) {
            [self postKey:124 text:@"" modifiers:0 window:window];
        }
        if (pressed & UIA) {
            BOOL field = [window.firstResponder isKindOfClass:NSTextView.class] &&
                [(NSTextView *)window.firstResponder isFieldEditor];
            if (field || self.menuTracking) {
                [self postKey:36 text:@"\r" modifiers:0 window:window];
            } else {
                [self postKey:49 text:@" " modifiers:0 window:window];
            }
        }
        if (pressed & UIB) {
            if (self.menuTracking || window.sheetParent) {
                [self postKey:53 text:@"\033" modifiers:0 window:window];
            } else if (settings) {
                [window performClose:nil];
            }
        }
    }

    // The ring stays on the field being typed into while the keyboard is up.
    BOOL ringWindow = settings || (keyboardOverlay && settingsWindow);
    BOOL showRing = ringWindow && !self.suspended && !self.menuTracking && self.controllerInUse;
    [self.focusNavigator updateWithWindow:(ringWindow ? window : nil) showRing:showRing];

    if (self.suspended || !self.controllerInUse) {
        [self.hints hide];
    } else {
        ControllerHintContext context = keyboardOverlay ? ControllerHintContextKeyboard
            : ((overlay || self.menuTracking) ? ControllerHintContextMenu
               : (settings ? ControllerHintContextSettings : ControllerHintContextLibrary));
        [self.hints updateWithWindow:root context:context];
    }
}

- (void)sendPressed:(uint32_t)pressed toHandler:(void (^)(ControllerFocusInput input))handler {
    const uint32_t masks[] = {UIUp, UIDown, UILeft, UIRight, UIA, UIB, UILB, UIRB, UIX, UIY, UIMenu};
    const ControllerFocusInput inputs[] = {
        ControllerFocusInputUp, ControllerFocusInputDown, ControllerFocusInputLeft, ControllerFocusInputRight,
        ControllerFocusInputAccept, ControllerFocusInputBack, ControllerFocusInputPreviousColumn,
        ControllerFocusInputNextColumn, ControllerFocusInputDelete, ControllerFocusInputSpace,
        ControllerFocusInputDone,
    };
    for (NSUInteger i = 0; i < sizeof(masks) / sizeof(masks[0]); i++) {
        if (pressed & masks[i]) {
            handler(inputs[i]);
        }
    }
}

- (void)scrollWindow:(NSWindow *)window amount:(float)amount {
    CGEventRef scroll = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitPixel, 1, (int32_t)lrintf(amount * 8.0f));
    NSPoint center = [window convertPointToScreen:NSMakePoint(NSMidX(window.contentView.bounds),
                                                              NSMidY(window.contentView.bounds))];
    CGEventSetLocation(scroll, CGPointMake(center.x, NSScreen.screens.firstObject.frame.size.height - center.y));
    [window sendEvent:[NSEvent eventWithCGEvent:scroll]];
    CFRelease(scroll);
}

@end
