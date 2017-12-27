//
//  HIDSupport.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 26/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import "HIDSupport.h"

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

    
    //    {kVK_Function, 0x},
};

@interface HIDSupport ()
@property (nonatomic, strong) NSDictionary *mappings;
@property (nonatomic) IOHIDManagerRef hidManager;
@property (nonatomic) int x;
@property (nonatomic) int y;
@property (nonatomic) NSTimeInterval lastTimestamp;
@end

@implementation HIDSupport

- (instancetype)init {
    self = [super init];
    if (self) {
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        for (size_t i = 0; i < sizeof(keys) / sizeof(struct KeyMapping); i++) {
            struct KeyMapping m = keys[i];
            [d setObject:@(m.windows) forKey:@(m.mac)];
        }
        _mappings = [NSDictionary dictionaryWithDictionary:d];
        
        [self setupHidManager];
    }
    return self;
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
            
        default:
            break;
    }
}

- (void)keyDown:(NSEvent *)event {
    LiSendKeyboardEvent([self translateKeyCodeWithEvent:event], KEY_ACTION_DOWN, [self translateKeyModifierWithEvent:event]);
}

- (void)keyUp:(NSEvent *)event {
    LiSendKeyboardEvent([self translateKeyCodeWithEvent:event], KEY_ACTION_UP, [self translateKeyModifierWithEvent:event]);
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
    return modifiers;
}



void myHIDCallback(void* context, IOReturn result, void* sender, IOHIDValueRef value) {
    IOHIDElementRef elem = IOHIDValueGetElement(value);
    uint32_t usagePage = IOHIDElementGetUsagePage(elem);
    uint32_t usage = IOHIDElementGetUsage(elem);
    CFIndex intValue = IOHIDValueGetIntegerValue(value);

    HIDSupport *self = (__bridge HIDSupport *)context;
    
    switch (usagePage) {
        case kHIDPage_GenericDesktop:
            switch (usage) {
                case kHIDUsage_GD_X:
                    self.x += (int)intValue;
                    break;
                case kHIDUsage_GD_Y:
                    self.y += (int)intValue;
                    break;

                default:
                    break;
            }
            NSTimeInterval timestamp = [NSDate timeIntervalSinceReferenceDate];
            if (timestamp - self.lastTimestamp > 0.02) {
                LiSendMouseMoveEvent(self.x, self.y);
                self.x = 0;
                self.y = 0;
                self.lastTimestamp = timestamp;
            }
            break;
        case kHIDPage_Button:
            NSLog(@"BUTTON usage: %@, intValue: %@", @(usage), @(intValue));
            break;

        default:
            break;
    }
}

- (void)setupHidManager {
    self.hidManager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    IOHIDManagerOpen(self.hidManager, kIOHIDOptionsTypeNone);
    
    NSArray *matches = @[
                         @{@kIOHIDDeviceUsagePageKey: @(kHIDPage_GenericDesktop), @kIOHIDDeviceUsageKey: @(kHIDUsage_GD_Mouse)},
                         ];
    IOHIDManagerSetDeviceMatchingMultiple(self.hidManager, (__bridge CFArrayRef)matches);

    IOHIDManagerRegisterInputValueCallback(self.hidManager, myHIDCallback, (__bridge void * _Nullable)(self));
    
    IOHIDManagerScheduleWithRunLoop(self.hidManager, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
}

@end
