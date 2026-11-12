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
#import "DS5RawHIDBridge.h"
#import "DS5UIButtons.h"
#import "ControllerPressGate.h"

@import GameController;

// Navigation reads Apple's profile state without replacing the streaming
// callbacks. Each device has its own edge/repeat state, scoped to the key UI.
typedef struct {
    uint32_t buttons;
    double repeatAt;
    uint32_t blocked;
    // L2 / R2 as of the last poll (the hysteresis of an analog trigger needs its own past)
    uint32_t triggers;
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
    UILT = 1 << 12,
    UIRT = 1 << 13,
};

static const uint32_t UIDirections = UIUp | UIDown | UILeft | UIRight;

// The raw DualSense path (DS5UIButtons.h) builds these same bits.
_Static_assert(DS5UI_UP == UIUp && DS5UI_DOWN == UIDown && DS5UI_LEFT == UILeft && DS5UI_RIGHT == UIRight &&
               DS5UI_A == UIA && DS5UI_B == UIB && DS5UI_X == UIX && DS5UI_MENU == UIMenu &&
               DS5UI_VIEW == UIViewButton && DS5UI_LB == UILB && DS5UI_RB == UIRB && DS5UI_Y == UIY &&
               DS5UI_LT == UILT && DS5UI_RT == UIRT,
               "DS5UIButtons.h and ControllerNavigation.m disagree on the UI bits");

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
// A DualSense that GameController does not report is read from the raw HID bridge (only while the
// interface is on screen and no stream owns the device).
@property (nonatomic, strong) DS5RawHIDBridge *rawBridge;
@property (atomic) uint32_t rawButtons;
@property (atomic) uint32_t rawTriggers;
@property (atomic) float rawScrollY;
@property (nonatomic, strong) NSObject *rawKey;
@property (nonatomic, strong) NSTimer *rawProbeTimer;
@property (nonatomic) BOOL rawPresent;
// The harness's scripted pad: presses injected through the same edge/repeat machine as a real pad.
@property (nonatomic) BOOL simulated;
@property (nonatomic, strong) NSObject *simKey;
@property (nonatomic) uint32_t simMask;
@property (nonatomic) int simTicks;
@property (nonatomic) BOOL pointerArmed;
@end

#ifdef MLC_CONCEPT_HARNESS
static __weak ControllerNavigation *sHarnessInstance;
#endif

@implementation ControllerNavigation

#ifdef MLC_CONCEPT_HARNESS
+ (NSString *)harnessState {
    ControllerNavigation *instance = sHarnessInstance;
    if (instance == nil) {
        return @"navigation=none";
    }
    ControllerMenuPanel *menu = ControllerMenuPanel.shared;
    NSWindow *mainWindow = [instance deckMainWindow];
    return [NSString stringWithFormat:@"%@ menuPanel=%d sheet=%d popover=%d used=%d stream=%d toast=[%@] nav=%@ fr=%@", [instance.focusNavigator debugState],
            menu.isPresented, mainWindow.attachedSheet != nil, [instance visiblePopover] != nil, instance.controllerInUse,
            [instance startingStreamWindow] != nil, ControllerHostToast.shared.shownText,
            instance.navigationWindow.identifier ?: @"-", NSStringFromClass(instance.navigationWindow.firstResponder.class)];
}

+ (NSString *)harnessTargets {
    return [sHarnessInstance.focusNavigator debugTargets] ?: @"";
}

+ (NSString *)harnessFocusedKey {
    return sHarnessInstance.focusNavigator.focusedKey ?: @"";
}
#endif

- (instancetype)init {
    self = [super init];
    if (self) {
#ifdef MLC_CONCEPT_HARNESS
        sHarnessInstance = self;
#endif
        self.states = [NSMapTable weakToStrongObjectsMapTable];
        self.hints = [[ControllerHintPresenter alloc] init];
        self.focusNavigator = [[ControllerFocusNavigator alloc] init];
        self.controllerInUse = YES;
        self.rawKey = [[NSObject alloc] init];
        self.simKey = [[NSObject alloc] init];
#ifdef MLC_CONCEPT_HARNESS
        if (getenv("MLC_PAD") != NULL) {
            self.simulated = YES;
            [ControllerPresenceBridge setSimulated:YES];
        }
#endif

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
#ifdef MLC_CONCEPT_HARNESS
            // The harness presses a button: userInfo[@"mask"] holds UI bits; they are held for two polls.
            [center addObserverForName:@"MLControllerInject" object:nil queue:main usingBlock:^(NSNotification *note) {
                weakSelf.simMask = (uint32_t)[note.userInfo[@"mask"] unsignedIntValue];
                weakSelf.simTicks = 2;
            }],
            // The next pointer event counts as the user's pointer (it hides the ring).
            [center addObserverForName:@"MLControllerPointerArmed" object:nil queue:main usingBlock:^(NSNotification *note) {
                weakSelf.pointerArmed = YES;
            }],
            // The same press through the raw DualSense path: a DS5 state goes through the mapping of DS5UIButtons.h.
            [center addObserverForName:@"MLControllerInjectRaw" object:nil queue:main usingBlock:^(NSNotification *note) {
                weakSelf.simMask = ds5_ui_buttons([note.userInfo[@"buttons"] unsignedLongLongValue],
                                                   (uint8_t)[note.userInfo[@"hat"] unsignedIntValue],
                                                   (uint8_t)[note.userInfo[@"lx"] unsignedIntValue],
                                                   (uint8_t)[note.userInfo[@"ly"] unsignedIntValue]) |
                    ds5_ui_triggers(0, (uint8_t)[note.userInfo[@"lt"] unsignedIntValue], (uint8_t)[note.userInfo[@"rt"] unsignedIntValue], 0);
                weakSelf.simTicks = 2;
            }],
#endif
        ];
        self.pointerMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown | NSEventMaskScrollWheel | NSEventMaskMouseMoved
                                                                    handler:^NSEvent *(NSEvent *event) {
#ifdef MLC_CONCEPT_HARNESS
            // The harness Mac has a real pointer that may sit over the window: only the script's own pointer event counts.
            if (weakSelf.simulated && !weakSelf.pointerArmed) {
                return event;
            }
            weakSelf.pointerArmed = NO;
#endif
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
    BOOL anyPad = GCController.controllers.count > 0 || self.rawPresent || self.simulated;
    BOOL wanted = (NSApp.active || self.simulated) && anyPad;
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
    // A DualSense GameController does not report: look for one now and then while the app is in front.
    BOOL probe = NSApp.active && GCController.controllers.count == 0;
    if (probe && self.rawProbeTimer == nil) {
        __weak typeof(self) weakSelf = self;
        self.rawProbeTimer = [NSTimer timerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) {
            [weakSelf probeRawPad];
        }];
        [[NSRunLoop mainRunLoop] addTimer:self.rawProbeTimer forMode:NSRunLoopCommonModes];
        [self probeRawPad];
    } else if (!probe && self.rawProbeTimer != nil) {
        [self.rawProbeTimer invalidate];
        self.rawProbeTimer = nil;
        [self stopRawBridge];
    }
}

- (void)probeRawPad {
    BOOL streaming = NO;
    for (NSWindow *candidate in NSApp.windows) {
        if (candidate.isVisible && [candidate.identifier isEqualToString:@"ClientStreamWindow"]) {
            streaming = YES;
        }
    }
    int usb = 0, bluetooth = 0, other = 0;
    if (!streaming && GCController.controllers.count == 0) {
        [DS5RawHIDBridge connectedPadLinkUsb:&usb bluetooth:&bluetooth other:&other];
    }
    BOOL attached = usb + bluetooth + other > 0;
    if (attached && self.rawBridge == nil) {
        DS5RawHIDBridge *bridge = [[DS5RawHIDBridge alloc] init];
        __weak typeof(self) weakSelf = self;
        [bridge startWithInputHandler:^(NSString *identity, const AlkDs5ExtendedInput *input, BOOL isBluetooth) {
            weakSelf.rawTriggers = ds5_ui_triggers(weakSelf.rawTriggers, input->state.left_trigger, input->state.right_trigger, input->state.buttons);
            weakSelf.rawButtons = ds5_ui_buttons(input->state.buttons, input->state.hat, input->state.left_x, input->state.left_y) | weakSelf.rawTriggers;
            weakSelf.rawScrollY = ds5_ui_scroll(input->state.right_y);
        } featureHandler:^(NSString *identity, uint8_t reportID, const uint8_t *report, size_t length) {
        }];
        self.rawBridge = bridge;
        Log(LOG_I, @"[controller-ui] reading the DualSense from the raw HID bridge (usb=%d bt=%d)", usb, bluetooth);
    } else if (!attached && self.rawBridge != nil) {
        [self stopRawBridge];
    }
    if (self.rawPresent != (self.rawBridge != nil)) {
        self.rawPresent = self.rawBridge != nil;
        [ControllerPresenceBridge setRawPad:self.rawPresent];
        [self updatePollingTimer];
    }
}

- (void)stopRawBridge {
    if (self.rawBridge != nil) {
        [self.rawBridge stop];
        self.rawBridge = nil;
        self.rawButtons = 0;
        self.rawTriggers = 0;
        self.rawScrollY = 0;
    }
    if (self.rawPresent) {
        self.rawPresent = NO;
        [ControllerPresenceBridge setRawPad:NO];
    }
}

- (uint32_t)buttonsFor:(GCExtendedGamepad *)pad {
    // A stick pushed down also reads a little left or right. Taking both axes sent "down" and
    // "left" together, and left means back in the menus: scrolling a list popped it to its parent.
    // Only the stronger axis of the stick counts; the d-pad has no such overlap.
    const float stickX = pad.leftThumbstick.xAxis.value;
    const float stickY = pad.leftThumbstick.yAxis.value;
    const BOOL stickHorizontal = fabsf(stickX) > fabsf(stickY);
    return ((pad.dpad.up.pressed || (!stickHorizontal && stickY > 0.6f)) ? UIUp : 0) |
        ((pad.dpad.down.pressed || (!stickHorizontal && stickY < -0.6f)) ? UIDown : 0) |
        ((pad.dpad.left.pressed || (stickHorizontal && stickX < -0.6f)) ? UILeft : 0) |
        ((pad.dpad.right.pressed || (stickHorizontal && stickX > 0.6f)) ? UIRight : 0) |
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

// The window the Deck interface is in: the main window, a sheet of it, an alert or a popover opened from it.
- (NSWindow *)deckMainWindow {
    for (NSWindow *candidate in NSApp.windows) {
        if ([candidate.identifier isEqualToString:@"MainWindow"] && candidate.isVisible) {
            return candidate;
        }
    }
    return nil;
}

- (NSWindow *)visiblePopover {
    for (NSWindow *candidate in NSApp.windows) {
        if (candidate.isVisible && [NSStringFromClass(candidate.class) containsString:@"Popover"]) {
            return candidate;
        }
    }
    return nil;
}

// The stream window while it only shows the startup overlay (the connection is being made; no frame yet).
- (BOOL)view:(NSView *)view containsStartupOverlay:(int)depth {
    if (depth > 6) {
        return NO;
    }
    if (!view.isHidden && [NSStringFromClass(view.class) containsString:@"StartupOverlayView"]) {
        return YES;
    }
    for (NSView *subview in view.subviews) {
        if ([self view:subview containsStartupOverlay:depth + 1]) {
            return YES;
        }
    }
    return NO;
}

- (NSWindow *)startingStreamWindow {
    for (NSWindow *candidate in NSApp.windows) {
        if (candidate.isVisible && [candidate.identifier isEqualToString:@"ClientStreamWindow"] &&
            [self view:candidate.contentView containsStartupOverlay:0]) {
            return candidate;
        }
    }
    return nil;
}

- (BOOL)deckWindow:(NSWindow *)window root:(NSWindow *)root {
    if (![MLDeckVariant isDeck]) {
        return NO;
    }
    if ([root.identifier isEqualToString:@"MainWindow"]) {
        return YES;
    }
    if ([self deckMainWindow] == nil) {
        return NO;
    }
    return window == NSApp.modalWindow || [NSStringFromClass(window.class) containsString:@"Popover"];
}

- (NSButton *)buttonWithKeyEquivalent:(NSString *)key inView:(NSView *)view {
    if ([view isKindOfClass:NSButton.class] && [((NSButton *)view).keyEquivalent isEqualToString:key] && !view.isHidden) {
        return (NSButton *)view;
    }
    for (NSView *subview in view.subviews) {
        NSButton *found = [self buttonWithKeyEquivalent:key inView:subview];
        if (found) {
            return found;
        }
    }
    return nil;
}

// B on a sheet, alert or popover of the Deck: its own cancel button (Esc is its key equivalent), else the
// presenting controller dismisses it, else the sheet is ended as cancelled, else the Esc key goes to it.
- (void)dismissDeckWindow:(NSWindow *)window {
    NSButton *cancel = [self buttonWithKeyEquivalent:@"\033" inView:window.contentView];
    if (cancel != nil && cancel.isEnabled) {
        [cancel performClick:nil];
        return;
    }
    NSViewController *controller = window.contentViewController;
    if (controller.presentingViewController != nil) {
        [controller.presentingViewController dismissViewController:controller];
        return;
    }
    if (window == NSApp.modalWindow) {
        [NSApp stopModalWithCode:NSModalResponseCancel];
        return;
    }
    if (window.sheetParent != nil) {
        [window.sheetParent endSheet:window returnCode:NSModalResponseCancel];
        return;
    }
    [window makeKeyWindow];
    [self postKey:53 text:@"\033" modifiers:0 window:window];
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
    if (!overlay && [MLDeckVariant isDeck]) {
        // A popover (自定义主页, the icon picker) is not always the key window; the pad drives it when it is up.
        NSWindow *popover = [self visiblePopover];
        if (popover != nil) {
            window = popover;
        }
    }
    // A window that is closing is still the key window for a moment. The focus ring is a child window of it: ordering
    // the ring in would bring the closed window back on screen (the settings window reappearing after B).
    if (window != nil && !window.isVisible) {
        window = nil;
    }
#ifdef MLC_CONCEPT_HARNESS
    if (self.simulated && [self startingStreamWindow] != nil) {
        window = [self startingStreamWindow];
    }
    if (window == nil && self.simulated) {
        // The harness Mac has no key window (a login session): the scripted pad drives the topmost window of the app,
        // which is the settings window while it is open (it would be the key window on a real Mac).
        NSWindow *settingsWindow = nil;
        for (NSWindow *candidate in NSApp.windows) {
            if (candidate.isVisible && [candidate.identifier isEqualToString:@"ClientSettingsWindow"]) {
                settingsWindow = candidate;
            }
        }
        NSWindow *mainWindow = [self deckMainWindow];
        window = settingsWindow ?: (mainWindow.attachedSheet ?: mainWindow);
    }
#endif
    NSWindow *root = window;
    while (root.sheetParent) {
        root = root.sheetParent;
    }
    BOOL deckEligible = [self deckWindow:window root:root];
    BOOL deck = !overlay && deckEligible;
    BOOL main = !overlay && !deck && [root.identifier isEqualToString:@"MainWindow"] && root == window;
    BOOL settingsWindow = [root.identifier isEqualToString:@"ClientSettingsWindow"];
    BOOL settings = !overlay && settingsWindow;
    BOOL streamMenu = !overlay && self.menuTracking && [root.identifier isEqualToString:@"ClientStreamWindow"];
    BOOL active = NSApp.active || self.simulated;
    // B while the connection is being made (the stream window only shows its startup overlay) cancels it, as closing the window does.
    BOOL starting = !overlay && [root.identifier isEqualToString:@"ClientStreamWindow"] && !self.menuTracking &&
        [self view:root.contentView containsStartupOverlay:0];
    if (!active || !window || (!overlay && !main && !settings && !streamMenu && !deck && !starting)) {
        self.navigationWindow = nil;
        [self.hints hide];
        [self.focusNavigator updateWithWindow:nil showRing:NO];
        return;
    }

    BOOL changed = self.navigationWindow != window;
    self.navigationWindow = window;
    double now = NSProcessInfo.processInfo.systemUptime;

    // The pads that can drive the interface this tick: every GameController pad, else the raw DualSense,
    // and the harness's scripted pad.
    NSMutableArray *keys = [NSMutableArray array];
    NSMutableArray<NSNumber *> *maskList = [NSMutableArray array];
    NSMutableArray<NSNumber *> *scrollList = [NSMutableArray array];
    // L2 / R2 travel of the GameController pads (the raw and scripted pads carry theirs in the mask already)
    NSMutableArray<NSArray<NSNumber *> *> *triggerList = [NSMutableArray array];
    for (GCController *controller in GCController.controllers) {
        GCExtendedGamepad *pad = controller.extendedGamepad;
        if (pad) {
            [keys addObject:controller];
            [maskList addObject:@([self buttonsFor:pad])];
            [scrollList addObject:@(pad.rightThumbstick.yAxis.value)];
            [triggerList addObject:@[@(pad.leftTrigger.value), @(pad.rightTrigger.value)]];
        }
    }
    if (keys.count == 0 && self.rawBridge != nil) {
        [keys addObject:self.rawKey];
        [maskList addObject:@(self.rawButtons)];
        [scrollList addObject:@(self.rawScrollY)];
        [triggerList addObject:@[]];
    }
    if (self.simulated) {
        [keys addObject:self.simKey];
        uint32_t held = 0;
        if (self.simTicks > 0) {
            held = self.simMask;
            self.simTicks--;
        }
        [maskList addObject:@(held)];
        [scrollList addObject:@0];
        [triggerList addObject:@[]];
    }

    for (NSUInteger index = 0; index < keys.count; index++) {
        id key = keys[index];
        ControllerUIState state = {0};
        NSValue *previous = [self.states objectForKey:key];
        if (previous) {
            [previous getValue:&state size:sizeof(state)];
        }
        uint32_t buttons = maskList[index].unsignedIntValue;
        float scrollY = scrollList[index].floatValue;
        if (triggerList[index].count == 2) {
            uint32_t triggers = 0;
            if (ds5_ui_trigger_down(triggerList[index][0].floatValue, (state.triggers & UILT) != 0)) triggers |= UILT;
            if (ds5_ui_trigger_down(triggerList[index][1].floatValue, (state.triggers & UIRT) != 0)) triggers |= UIRT;
            state.triggers = triggers;
            buttons |= triggers;
        }
        if (self.suspended) {
            // Keep edge state current so the capture's presses do not fire on resume.
            state.buttons = buttons;
            state.repeatAt = 0;
            [self.states setObject:[NSValue valueWithBytes:&state objCType:@encode(ControllerUIState)] forKey:key];
            continue;
        }
        // After the pointer was used, the first press only brings the focus back on screen: it does nothing else.
        BOOL revealing = !self.controllerInUse && buttons != 0;
        if (buttons != 0 || fabsf(scrollY) > 0.3f) {
            self.controllerInUse = YES;
        }
        // A window change swallows the press that caused it, and every button held through it until it is released:
        // the B that closed the settings window is not a B on the page behind.
        uint32_t pressed = ControllerPressGatePressed(buttons, state.buttons, changed, &state.blocked);
        if (!previous || revealing) {
            pressed = 0;
        }
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
        [self.states setObject:[NSValue valueWithBytes:&state objCType:@encode(ControllerUIState)] forKey:key];

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

        if (starting) {
            if (pressed & UIB) {
                Log(LOG_I, @"[controller-ui] B cancels the connection (stream window closed while starting)");
                if (root.styleMask & NSWindowStyleMaskClosable) {
                    [root performClose:nil];
                } else {
                    [root close];
                }
            }
            continue;
        }

        if (pressed & UIViewButton) {
            NSSearchField *search = (main || deck) && !window.sheetParent ? [window moonlight_searchFieldInToolbar] : nil;
            if (search) {
                if ([window makeFirstResponder:search]) {
                    [keyboard presentInWindow:window];
                }
            } else if (deck) {
                [self.focusNavigator focusSearchFieldInWindow:window];
            } else if (!window.sheetParent) {
                [NSNotificationCenter.defaultCenter postNotificationName:@"ControllerFocusSettingsSearch" object:window];
                if (settings) {
                    [self.focusNavigator focusSearchFieldInWindow:window];
                }
            }
            continue;
        }

        // Deck: a focus ring over every control (the sidebar, the hero, the shelves, the sheets). D-pad and left
        // stick move, A activates, B goes back or closes, Menu lists the context menu, LB/RB switch computers,
        // Y opens the settings, X 自定义主页, View searches, the right stick scrolls.
        if (deck && !self.menuTracking) {
            ControllerFocusNavigator *navigator = self.focusNavigator;
            navigator.isDeck = YES;
            BOOL isMain = [window.identifier isEqualToString:@"MainWindow"] && !window.sheetParent;
            [self sendPressed:pressed & ~(UIB | UIX | UIY | UIMenu) toHandler:^(ControllerFocusInput input) {
                [navigator handleInput:input window:window];
            }];
            if (pressed & UIMenu) {
                [navigator handleInput:ControllerFocusInputContextMenu window:window];
            }
            if ((pressed & UIY) && isMain) {
                [NSApp sendAction:@selector(showPreferences:) to:nil from:window];
            }
            if ((pressed & UIX) && isMain) {
                if (@available(macOS 14.0, *)) {
                    [[MLDeckHomeCustomizer shared] show];
                }
            }
            if ((pressed & UIB) && ![navigator handleInput:ControllerFocusInputBack window:window]) {
                if (window.sheetParent || !isMain) {
                    [self dismissDeckWindow:window];
                }
            }
            if (fabsf(scrollY) > 0.3f) {
                [self scrollWindow:window amount:scrollY];
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
            navigator.isDeck = NO;
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
            if (scrollY > 0.3f || scrollY < -0.3f) {
                [self scrollWindow:window amount:scrollY];
            }
            continue;
        }

        // Menus: move with arrows, confirm with Return.
        if (pressed & (UIUp | UILB)) {
            if (self.menuTracking) {
                [self postKey:126 text:@"" modifiers:0 window:window];
            } else {
                [self postKey:48 text:@"\t" modifiers:NSEventModifierFlagShift window:window];
            }
        }
        if (pressed & (UIDown | UIRB)) {
            if (self.menuTracking) {
                [self postKey:125 text:@"" modifiers:0 window:window];
            } else {
                [self postKey:48 text:@"\t" modifiers:0 window:window];
            }
        }
        if (pressed & UILeft) {
            [self postKey:123 text:@"" modifiers:0 window:window];
        }
        if (pressed & UIRight) {
            [self postKey:124 text:@"" modifiers:0 window:window];
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
    BOOL keyboardRing = keyboardOverlay && (settingsWindow || [self deckWindow:window root:root]);
    BOOL ringWindow = settings || deck || keyboardRing;
    self.focusNavigator.isDeck = deck || (keyboardRing && !settingsWindow);
    BOOL showRing = ringWindow && !self.suspended && !self.menuTracking && self.controllerInUse;
    [self.focusNavigator updateWithWindow:(ringWindow ? window : nil) showRing:showRing];

    if (self.suspended || !self.controllerInUse || starting) {
        [self.hints hide];
    } else {
        ControllerHintContext context = keyboardOverlay ? ControllerHintContextKeyboard
            : ((overlay || self.menuTracking) ? ControllerHintContextMenu
               : (deck ? (([window.identifier isEqualToString:@"MainWindow"] && !window.sheetParent) ? ControllerHintContextDeck : ControllerHintContextMenu)
                  : (settings ? ControllerHintContextSettings : ControllerHintContextLibrary)));
        NSWindow *hintWindow = (deck || (overlay && [self deckWindow:window root:root])) ? ([self deckMainWindow] ?: root) : root;
        [self.hints updateWithWindow:hintWindow context:context];
    }
}

- (void)sendPressed:(uint32_t)pressed toHandler:(void (^)(ControllerFocusInput input))handler {
    const uint32_t masks[] = {UIUp, UIDown, UILeft, UIRight, UIA, UIB, UILB, UIRB, UIX, UIY, UIMenu, UILT, UIRT};
    const ControllerFocusInput inputs[] = {
        ControllerFocusInputUp, ControllerFocusInputDown, ControllerFocusInputLeft, ControllerFocusInputRight,
        ControllerFocusInputAccept, ControllerFocusInputBack, ControllerFocusInputPreviousColumn,
        ControllerFocusInputNextColumn, ControllerFocusInputDelete, ControllerFocusInputSpace,
        ControllerFocusInputDone, ControllerFocusInputPreviousSection, ControllerFocusInputNextSection,
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
