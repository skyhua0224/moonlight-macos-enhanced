//
//  HIDSupport.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 26/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import "HIDSupport.h"
#import "Controller.h"

#include "Limelight.h"

#import <Carbon/Carbon.h>

#import <IOKit/hid/IOHIDManager.h>
#import <IOKit/hid/IOHIDKeys.h>
#import <IOKit/hid/IOHIDElement.h>

struct KeyMapping {
    unsigned short mac;
    short windows;
};

static struct KeyMapping keys[] = {
    {kVK_ANSI_A, 'A'},
    {kVK_ANSI_B, 'B'},
    {kVK_ANSI_C, 'C'},
    {kVK_ANSI_D, 'D'},
    {kVK_ANSI_E, 'E'},
    {kVK_ANSI_F, 'F'},
    {kVK_ANSI_G, 'G'},
    {kVK_ANSI_H, 'H'},
    {kVK_ANSI_I, 'I'},
    {kVK_ANSI_J, 'J'},
    {kVK_ANSI_K, 'K'},
    {kVK_ANSI_L, 'L'},
    {kVK_ANSI_M, 'M'},
    {kVK_ANSI_N, 'N'},
    {kVK_ANSI_O, 'O'},
    {kVK_ANSI_P, 'P'},
    {kVK_ANSI_Q, 'Q'},
    {kVK_ANSI_R, 'R'},
    {kVK_ANSI_S, 'S'},
    {kVK_ANSI_T, 'T'},
    {kVK_ANSI_U, 'U'},
    {kVK_ANSI_V, 'V'},
    {kVK_ANSI_W, 'W'},
    {kVK_ANSI_X, 'X'},
    {kVK_ANSI_Y, 'Y'},
    {kVK_ANSI_Z, 'Z'},

    {kVK_ANSI_0, '0'},
    {kVK_ANSI_1, '1'},
    {kVK_ANSI_2, '2'},
    {kVK_ANSI_3, '3'},
    {kVK_ANSI_4, '4'},
    {kVK_ANSI_5, '5'},
    {kVK_ANSI_6, '6'},
    {kVK_ANSI_7, '7'},
    {kVK_ANSI_8, '8'},
    {kVK_ANSI_9, '9'},
    
    {kVK_ANSI_Equal, 0xBB},
    {kVK_ANSI_Minus, 0xBD},
    {kVK_ANSI_RightBracket, 0xDD},
    {kVK_ANSI_LeftBracket, 0xDB},
    {kVK_ANSI_Quote, 0xDE},
    {kVK_ANSI_Semicolon, 0xBA},
    {kVK_ANSI_Backslash, 0xDC},
    {kVK_ANSI_Comma, 0xBC},
    {kVK_ANSI_Slash, 0xBF},
    {kVK_ANSI_Period, 0xBE},
    {kVK_ANSI_Grave, 0xC0},
    {kVK_ANSI_KeypadDecimal, 0x6E},
    {kVK_ANSI_KeypadMultiply, 0x6A},
    {kVK_ANSI_KeypadPlus, 0x6B},
    {kVK_ANSI_KeypadClear, 0xFE},
    {kVK_ANSI_KeypadDivide, 0x6F},
    {kVK_ANSI_KeypadEnter, 0x0D},
    {kVK_ANSI_KeypadMinus, 0x6D},
    {kVK_ANSI_KeypadEquals, 0xBB},
    {kVK_ANSI_Keypad0, 0x60},
    {kVK_ANSI_Keypad1, 0x61},
    {kVK_ANSI_Keypad2, 0x62},
    {kVK_ANSI_Keypad3, 0x63},
    {kVK_ANSI_Keypad4, 0x64},
    {kVK_ANSI_Keypad5, 0x65},
    {kVK_ANSI_Keypad6, 0x66},
    {kVK_ANSI_Keypad7, 0x67},
    {kVK_ANSI_Keypad8, 0x68},
    {kVK_ANSI_Keypad9, 0x69},
    
    {kVK_Delete, 0x08},
    {kVK_Tab, 0x09},
    {kVK_Return, 0x0D},
    {kVK_Shift, 0xA0},
    {kVK_Control, 0xA2},
    {kVK_Option, 0xA4},
    {kVK_CapsLock, 0x14},
    {kVK_Escape, 0x1B},
    {kVK_Space, 0x20},
    {kVK_PageUp, 0x21},
    {kVK_PageDown, 0x22},
    {kVK_End, 0x23},
    {kVK_Home, 0x24},
    {kVK_LeftArrow, 0x25},
    {kVK_UpArrow, 0x26},
    {kVK_RightArrow, 0x27},
    {kVK_DownArrow, 0x28},
    {kVK_ForwardDelete, 0x2E},
    {kVK_Help, 0x2F},
    {kVK_Command, 0x5B},
    {kVK_RightCommand, 0x5C},
    {kVK_RightShift, 0xA1},
    {kVK_RightOption, 0xA5},
    {kVK_RightControl, 0xA3},
    {kVK_Mute, 0xAD},
    {kVK_VolumeDown, 0xAE},
    {kVK_VolumeUp, 0xAF},

    {kVK_F1, 0x70},
    {kVK_F2, 0x71},
    {kVK_F3, 0x72},
    {kVK_F4, 0x73},
    {kVK_F5, 0x74},
    {kVK_F6, 0x75},
    {kVK_F7, 0x76},
    {kVK_F8, 0x77},
    {kVK_F9, 0x78},
    {kVK_F10, 0x79},
    {kVK_F11, 0x7A},
    {kVK_F12, 0x7B},
    {kVK_F13, 0x7C},
    {kVK_F14, 0x7D},
    {kVK_F15, 0x7E},
    {kVK_F16, 0x7F},
    {kVK_F17, 0x80},
    {kVK_F18, 0x81},
    {kVK_F19, 0x82},
    {kVK_F20, 0x83},
};

@interface HIDSupport ()
@property (nonatomic, strong) NSDictionary *mappings;
@property (nonatomic) IOHIDManagerRef hidManager;
@property (nonatomic, strong) Controller *controller;
@property (nonatomic) CVDisplayLinkRef displayLink;
@property (nonatomic) CGFloat mouseDeltaX;
@property (nonatomic) CGFloat mouseDeltaY;
@end

@implementation HIDSupport

- (instancetype)init {
    self = [super init];
    if (self) {
        [self setupHidManager];
        
        self.controller = [[Controller alloc] init];

        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        for (size_t i = 0; i < sizeof(keys) / sizeof(struct KeyMapping); i++) {
            struct KeyMapping m = keys[i];
            [d setObject:@(m.windows) forKey:@(m.mac)];
        }
        _mappings = [NSDictionary dictionaryWithDictionary:d];
        
        [self initializeDisplayLink];
    }
    return self;
}

- (void)dealloc {
    [self tearDownHidManager];
    
    if (self.displayLink != NULL) {
        CVDisplayLinkStop(self.displayLink);
        CVDisplayLinkRelease(self.displayLink);
    }
}

static CVReturn displayLinkOutputCallback(CVDisplayLinkRef displayLink,
                                          const CVTimeStamp *now,
                                          const CVTimeStamp *vsyncTime,
                                          CVOptionFlags flagsIn,
                                          CVOptionFlags *flagsOut,
                                          void *displayLinkContext)
{
    HIDSupport *me = (__bridge HIDSupport *)displayLinkContext;
    
    
    int32_t deltaX, deltaY;
    deltaX = me.mouseDeltaX;
    deltaY = me.mouseDeltaY;
    if (deltaX != 0 || deltaY != 0) {
        me.mouseDeltaX = 0;
        me.mouseDeltaY = 0;
        if (me.shouldSendMouseEvents) {
            LiSendMouseMoveEvent(deltaX, deltaY);
        }
    }

    return kCVReturnSuccess;
}

- (BOOL)initializeDisplayLink
{
    NSNumber *screenNumber = [[NSScreen mainScreen] deviceDescription][@"NSScreenNumber"];

    CGDirectDisplayID displayId = [screenNumber unsignedIntValue];
    CVDisplayLinkRef displayLink;
    CVReturn status = CVDisplayLinkCreateWithCGDisplay(displayId, &displayLink);
    if (status != kCVReturnSuccess) {
        Log(LOG_E, @"Failed to create CVDisplayLink: %d", status);
        return NO;
    }
    self.displayLink = displayLink;
    
    status = CVDisplayLinkSetOutputCallback(self.displayLink, displayLinkOutputCallback, (__bridge void * _Nullable)(self));
    if (status != kCVReturnSuccess) {
        Log(LOG_E, @"CVDisplayLinkSetOutputCallback() failed: %d", status);
        return NO;
    }
    
    status = CVDisplayLinkStart(self.displayLink);
    if (status != kCVReturnSuccess) {
        Log(LOG_E, @"CVDisplayLinkStart() failed: %d", status);
        return NO;
    }
    
    return YES;
}

- (int)sendKeyboardModifierEvent:(NSEvent *)event withKeyCode:(unsigned short)keyCode andModifierFlag:(NSEventModifierFlags)modifierFlag {
    return LiSendKeyboardEvent(keyCode, event.modifierFlags & modifierFlag ? KEY_ACTION_DOWN : KEY_ACTION_UP, [self translateKeyModifierWithEvent:event]);
}

- (void)flagsChanged:(NSEvent *)event {
    switch (event.keyCode) {
        case kVK_Shift:
            [self sendKeyboardModifierEvent:event withKeyCode:0xA0 andModifierFlag:NSEventModifierFlagShift];
            break;
        case kVK_RightShift:
            [self sendKeyboardModifierEvent:event withKeyCode:0xA1 andModifierFlag:NSEventModifierFlagShift];
            break;
            
        case kVK_Control:
            [self sendKeyboardModifierEvent:event withKeyCode:0xA2 andModifierFlag:NSEventModifierFlagControl];
            break;
        case kVK_RightControl:
            [self sendKeyboardModifierEvent:event withKeyCode:0xA3 andModifierFlag:NSEventModifierFlagControl];
            break;

        case kVK_Option:
            [self sendKeyboardModifierEvent:event withKeyCode:0xA4 andModifierFlag:NSEventModifierFlagOption];
            break;
        case kVK_RightOption:
            [self sendKeyboardModifierEvent:event withKeyCode:0xA5 andModifierFlag:NSEventModifierFlagOption];
            break;
            
        case kVK_Command:
            [self sendKeyboardModifierEvent:event withKeyCode:0x5B andModifierFlag:NSEventModifierFlagCommand];
            break;
        case kVK_RightCommand:
            [self sendKeyboardModifierEvent:event withKeyCode:0x5C andModifierFlag:NSEventModifierFlagCommand];
            break;

        default:
            break;
    }
}

- (void)keyDown:(NSEvent *)event {
    LiSendKeyboardEvent(0x8000 | [self translateKeyCodeWithEvent:event], KEY_ACTION_DOWN, [self translateKeyModifierWithEvent:event]);
}

- (void)keyUp:(NSEvent *)event {
    LiSendKeyboardEvent(0x8000 | [self translateKeyCodeWithEvent:event], KEY_ACTION_UP, [self translateKeyModifierWithEvent:event]);
}

- (void)releaseAllModifierKeys {
    LiSendKeyboardEvent(0x5B, KEY_ACTION_UP, 0);
    LiSendKeyboardEvent(0x5C, KEY_ACTION_UP, 0);
    LiSendKeyboardEvent(0xA0, KEY_ACTION_UP, 0);
    LiSendKeyboardEvent(0xA1, KEY_ACTION_UP, 0);
    LiSendKeyboardEvent(0xA2, KEY_ACTION_UP, 0);
    LiSendKeyboardEvent(0xA3, KEY_ACTION_UP, 0);
    LiSendKeyboardEvent(0xA4, KEY_ACTION_UP, 0);
    LiSendKeyboardEvent(0xA5, KEY_ACTION_UP, 0);
}

- (void)mouseDown:(NSEvent *)event withButton:(int)button {
    if (self.shouldSendMouseEvents) {
        LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, button);
    }
}

- (void)mouseUp:(NSEvent *)event withButton:(int)button {
    if (self.shouldSendMouseEvents) {
        LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, button);
    }
}

- (void)mouseMoved:(NSEvent *)event {
    self.mouseDeltaX += event.deltaX;
    self.mouseDeltaY += event.deltaY;
}

- (void)scrollWheel:(NSEvent *)event {
    if (self.shouldSendMouseEvents) {
        if (event.hasPreciseScrollingDeltas) {
            LiSendHighResScrollEvent(event.scrollingDeltaY);
        } else {
            LiSendScrollEvent(event.scrollingDeltaY);
        }
    }
}

- (short)translateKeyCodeWithEvent:(NSEvent *)event {
    if (![self.mappings objectForKey:@(event.keyCode)]) {
        return 0;
    }
    return [self.mappings[@(event.keyCode)] shortValue];
}

- (char)translateKeyModifierWithEvent:(NSEvent *)event {
    char modifiers = 0;
    if (event.modifierFlags & NSEventModifierFlagShift) {
        modifiers |= MODIFIER_SHIFT;
    }
    if (event.modifierFlags & NSEventModifierFlagControl) {
        modifiers |= MODIFIER_CTRL;
    }
    if (event.modifierFlags & NSEventModifierFlagOption) {
        modifiers |= MODIFIER_ALT;
    }
    if (event.modifierFlags & NSEventModifierFlagCommand) {
        modifiers |= MODIFIER_META;
    }
    return modifiers;
}

void myHIDCallback(void* context, IOReturn result, void* sender, IOHIDValueRef value) {
    IOHIDElementRef elem = IOHIDValueGetElement(value);
    uint32_t usagePage = IOHIDElementGetUsagePage(elem);
    uint32_t usage = IOHIDElementGetUsage(elem);
    CFIndex intValue = IOHIDValueGetIntegerValue(value);
    
    HIDSupport *self = (__bridge HIDSupport *)context;
    
    IOHIDDeviceRef device = (IOHIDDeviceRef)sender;
    
    CFNumberRef vendor = (CFNumberRef)(IOHIDDeviceGetProperty(device, CFSTR(kIOHIDVendorIDKey)));
    UInt16 vendorId = [(NSNumber *)CFBridgingRelease(vendor) unsignedShortValue];
    
    CFNumberRef product = (CFNumberRef)(IOHIDDeviceGetProperty(device, CFSTR(kIOHIDProductIDKey)));
    UInt16 productId = [(NSNumber *)CFBridgingRelease(product) unsignedShortValue];

    if (vendorId == 0x045E && (productId == 0x02FD || productId == 0x0B13)) { // Xbox One S Wireless and Xbox Series X/S Wireless Controller
        switch (usagePage) {
            case kHIDPage_GenericDesktop:
                switch (usage) {
                    case kHIDUsage_GD_X:
                        self.controller.lastLeftStickX = MIN((intValue - 32768), 32767);
                        break;
                    case kHIDUsage_GD_Y:
                        self.controller.lastLeftStickY = MIN(-(intValue - 32768), 32767);
                        break;
                    case kHIDUsage_GD_Z:
                        self.controller.lastRightStickX = MIN((intValue - 32768), 32767);
                        break;
                    case kHIDUsage_GD_Rz:
                        self.controller.lastRightStickY = MIN(-(intValue - 32768), 32767);
                        break;
                        
                    case kHIDUsage_GD_Hatswitch:
                        switch (intValue) {
                            case 1:
                                [self updateButtonFlags:UP_FLAG state:YES];
                                break;
                            case 2:
                                [self updateButtonFlags:UP_FLAG | RIGHT_FLAG state:YES];
                                break;
                            case 3:
                                [self updateButtonFlags:RIGHT_FLAG state:YES];
                                break;
                            case 4:
                                [self updateButtonFlags:DOWN_FLAG | RIGHT_FLAG state:YES];
                                break;
                            case 5:
                                [self updateButtonFlags:DOWN_FLAG state:YES];
                                break;
                            case 6:
                                [self updateButtonFlags:DOWN_FLAG | LEFT_FLAG state:YES];
                                break;
                            case 7:
                                [self updateButtonFlags:LEFT_FLAG state:YES];
                                break;
                            case 8:
                                [self updateButtonFlags:UP_FLAG | LEFT_FLAG state:YES];
                                break;

                            case 0:
                                [self updateButtonFlags:UP_FLAG | RIGHT_FLAG | DOWN_FLAG | LEFT_FLAG state:NO];
                                break;

                            default:
                                break;
                        }

                    default:
                        break;
                }
            case kHIDPage_Simulation:
                switch (usage) {
                    case kHIDUsage_Sim_Brake:
                        self.controller.lastLeftTrigger = intValue;
                        break;
                    case kHIDUsage_Sim_Accelerator:
                        self.controller.lastRightTrigger = intValue;
                        break;

                    default:
                        break;
                }

            case kHIDPage_Button:
                switch (usage) {
                    case 1:
                        [self updateButtonFlags:A_FLAG state:intValue];
                        break;
                    case 2:
                        [self updateButtonFlags:B_FLAG state:intValue];
                        break;
                    case 4:
                        [self updateButtonFlags:X_FLAG state:intValue];
                        break;
                    case 5:
                        [self updateButtonFlags:Y_FLAG state:intValue];
                        break;
                    case 7:
                        [self updateButtonFlags:LB_FLAG state:intValue];
                        break;
                    case 8:
                        [self updateButtonFlags:RB_FLAG state:intValue];
                        break;
                    case 11:
                        [self updateButtonFlags:BACK_FLAG state:intValue];
                        break;
                    case 12:
                        [self updateButtonFlags:PLAY_FLAG state:intValue];
                        break;
                    case 13:
                        [self updateButtonFlags:SPECIAL_FLAG state:intValue];
                        break;

                        
                    default:
                        break;
                }
                
            case kHIDPage_Consumer:
                switch (usage) {
                    case kHIDUsage_Csmr_ACBack:
                        [self updateButtonFlags:BACK_FLAG state:intValue];
                        break;
                    case kHIDUsage_Csmr_ACHome:
                        [self updateButtonFlags:SPECIAL_FLAG state:intValue];
                        break;
                    case 14:
                        [self updateButtonFlags:LS_CLK_FLAG state:intValue];
                        break;
                    case 15:
                        [self updateButtonFlags:RS_CLK_FLAG state:intValue];
                        break;

                    default:
                        break;
                }
                
            default:
                break;
        }

    } else if (vendorId == 0x054C && productId == 0x09CC) { // DualShock 4
        switch (usagePage) {
            case kHIDPage_GenericDesktop:
                switch (usage) {
                    case kHIDUsage_GD_X:
                        self.controller.lastLeftStickX = (intValue - 128) * 255 + 1;
                        break;
                    case kHIDUsage_GD_Y:
                        self.controller.lastLeftStickY = (intValue - 128) * -255;
                        break;
                    case kHIDUsage_GD_Z:
                        self.controller.lastRightStickX = (intValue - 128) * 255 + 1;
                        break;
                    case kHIDUsage_GD_Rx:
                        self.controller.lastLeftTrigger = intValue;
                        break;
                    case kHIDUsage_GD_Ry:
                        self.controller.lastRightTrigger = intValue;
                        break;
                    case kHIDUsage_GD_Rz:
                        self.controller.lastRightStickY = (intValue - 128) * -255;
                        break;
                        
                    case kHIDUsage_GD_Hatswitch:
                        switch (intValue) {
                            case 0:
                                [self updateButtonFlags:UP_FLAG state:YES];
                                break;
                            case 1:
                                [self updateButtonFlags:UP_FLAG | RIGHT_FLAG state:YES];
                                break;
                            case 2:
                                [self updateButtonFlags:RIGHT_FLAG state:YES];
                                break;
                            case 3:
                                [self updateButtonFlags:DOWN_FLAG | RIGHT_FLAG state:YES];
                                break;
                            case 4:
                                [self updateButtonFlags:DOWN_FLAG state:YES];
                                break;
                            case 5:
                                [self updateButtonFlags:DOWN_FLAG | LEFT_FLAG state:YES];
                                break;
                            case 6:
                                [self updateButtonFlags:LEFT_FLAG state:YES];
                                break;
                            case 7:
                                [self updateButtonFlags:UP_FLAG | LEFT_FLAG state:YES];
                                break;

                            case 8:
                                [self updateButtonFlags:UP_FLAG | RIGHT_FLAG | DOWN_FLAG | LEFT_FLAG state:NO];
                                break;

                            default:
                                break;
                        }

                    default:
                        break;
                }

            case kHIDPage_Button:
                switch (usage) {
                    case 1:
                        [self updateButtonFlags:X_FLAG state:intValue];
                        break;
                    case 2:
                        [self updateButtonFlags:A_FLAG state:intValue];
                        break;
                    case 3:
                        [self updateButtonFlags:B_FLAG state:intValue];
                        break;
                    case 4:
                        [self updateButtonFlags:Y_FLAG state:intValue];
                        break;

                    case 5:
                        [self updateButtonFlags:LB_FLAG state:intValue];
                        break;
                    case 6:
                        [self updateButtonFlags:RB_FLAG state:intValue];
                        break;

                    case 9:
                        [self updateButtonFlags:BACK_FLAG state:intValue];
                        break;
                    case 10:
                        [self updateButtonFlags:PLAY_FLAG state:intValue];
                        break;

                    case 11:
                        [self updateButtonFlags:LS_CLK_FLAG state:intValue];
                        break;
                    case 12:
                        [self updateButtonFlags:RS_CLK_FLAG state:intValue];
                        break;

                    case 13:
                        [self updateButtonFlags:SPECIAL_FLAG state:intValue];
                        break;

                        
                    default:
                        break;
                }
                
            default:
                break;
        }
    }

    BOOL useHIDControllerDriver = [[NSUserDefaults standardUserDefaults] integerForKey:@"controllerDriver"] == 0;
    if (useHIDControllerDriver) {
        LiSendMultiControllerEvent(self.controller.playerIndex, 1, self.controller.lastButtonFlags, self.controller.lastLeftTrigger, self.controller.lastRightTrigger, self.controller.lastLeftStickX, self.controller.lastLeftStickY, self.controller.lastRightStickX, self.controller.lastRightStickY);
    }
}

- (void)updateButtonFlags:(int)flag state:(BOOL)set {
    if (set) {
        self.controller.lastButtonFlags |= flag;
    } else {
        self.controller.lastButtonFlags &= ~flag;
    }
}

- (void)setupHidManager {
    self.hidManager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    IOHIDManagerOpen(self.hidManager, kIOHIDOptionsTypeNone);
    
    NSArray *matches = @[
                         @{@kIOHIDDeviceUsagePageKey: @(kHIDPage_GenericDesktop), @kIOHIDDeviceUsageKey: @(kHIDUsage_GD_Joystick)},
                         @{@kIOHIDDeviceUsagePageKey: @(kHIDPage_GenericDesktop), @kIOHIDDeviceUsageKey: @(kHIDUsage_GD_GamePad)},
                         @{@kIOHIDDeviceUsagePageKey: @(kHIDPage_GenericDesktop), @kIOHIDDeviceUsageKey: @(kHIDUsage_GD_MultiAxisController)},
                         ];
    IOHIDManagerSetDeviceMatchingMultiple(self.hidManager, (__bridge CFArrayRef)matches);
    
    IOHIDManagerRegisterInputValueCallback(self.hidManager, myHIDCallback, (__bridge void * _Nullable)(self));
    
    IOHIDManagerScheduleWithRunLoop(self.hidManager, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
}

- (void)tearDownHidManager {
    IOHIDManagerUnscheduleFromRunLoop(self.hidManager, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    IOHIDManagerClose(self.hidManager, kIOHIDOptionsTypeNone);
}


@end
