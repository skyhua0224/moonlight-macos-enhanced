//
//  HIDSupport.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 26/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import "HIDSupport.h"
#import "Controller.h"
#import "AlternateControllerNetworking.h"

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

typedef enum {
    k_EPS4ReportIdUsbState = 1,
    k_EPS4ReportIdUsbEffects = 5,
    k_EPS4ReportIdBluetoothState1 = 17,
    k_EPS4ReportIdBluetoothState2 = 18,
    k_EPS4ReportIdBluetoothState3 = 19,
    k_EPS4ReportIdBluetoothState4 = 20,
    k_EPS4ReportIdBluetoothState5 = 21,
    k_EPS4ReportIdBluetoothState6 = 22,
    k_EPS4ReportIdBluetoothState7 = 23,
    k_EPS4ReportIdBluetoothState8 = 24,
    k_EPS4ReportIdBluetoothState9 = 25,
    k_EPS4ReportIdBluetoothEffects = 17,
    k_EPS4ReportIdDisconnectMessage = 226,
} EPS4ReportId;

typedef enum {
    k_ePS4FeatureReportIdGyroCalibration_USB = 0x02,
    k_ePS4FeatureReportIdGyroCalibration_BT = 0x05,
    k_ePS4FeatureReportIdSerialNumber = 0x12,
} EPS4FeatureReportID;

typedef struct {
    UInt8 ucLeftJoystickX;
    UInt8 ucLeftJoystickY;
    UInt8 ucRightJoystickX;
    UInt8 ucRightJoystickY;
    UInt8 rgucButtonsHatAndCounter[3];
    UInt8 ucTriggerLeft;
    UInt8 ucTriggerRight;
    UInt8 _rgucPad0[3];
    UInt8 rgucGyroX[2];
    UInt8 rgucGyroY[2];
    UInt8 rgucGyroZ[2];
    UInt8 rgucAccelX[2];
    UInt8 rgucAccelY[2];
    UInt8 rgucAccelZ[2];
    UInt8 _rgucPad1[5];
    UInt8 ucBatteryLevel;
    UInt8 _rgucPad2[4];
    UInt8 ucTouchpadCounter1;
    UInt8 rgucTouchpadData1[3];
    UInt8 ucTouchpadCounter2;
    UInt8 rgucTouchpadData2[3];
} PS4StatePacket_t;

static UInt32 crc32_for_byte(UInt32 r)
{
    int i;
    for(i = 0; i < 8; ++i) {
        r = (r & 1? 0: (UInt32)0xEDB88320L) ^ r >> 1;
    }
    return r ^ (UInt32)0xFF000000L;
}

UInt32 SDL_crc32(UInt32 crc, const void *data, size_t len)
{
    // As an optimization we can precalculate a 256 entry table for each byte.
    size_t i;
    for(i = 0; i < len; ++i) {
        crc = crc32_for_byte((UInt8)crc ^ ((const UInt8*)data)[i]) ^ crc >> 8;
    }
    return crc;
}

@interface HIDSupport ()
@property (nonatomic) dispatch_queue_t rumbleQueue;
@property (nonatomic, strong) NSDictionary *mappings;
@property (nonatomic) IOHIDManagerRef hidManager;
@property (nonatomic, strong) Controller *controller;
@property (nonatomic) CVDisplayLinkRef displayLink;
@property (nonatomic) CGFloat mouseDeltaX;
@property (nonatomic) CGFloat mouseDeltaY;
@property (nonatomic) UInt8 previousLowFreqMotor;
@property (nonatomic) UInt8 previousHighFreqMotor;
@property (atomic) UInt16 nextLowFreqMotor;
@property (atomic) UInt16 nextHighFreqMotor;
@property (atomic) dispatch_semaphore_t rumbleSemaphore;
@property (atomic) BOOL closeRumble;
@property (nonatomic) PS4StatePacket_t lastPS4State;
@property (nonatomic) NSInteger controllerDriver;
@end

@implementation HIDSupport

- (instancetype)init {
    self = [super init];
    if (self) {
        [self setupHidManager];
        self.previousLowFreqMotor = 0xFF;
        self.previousHighFreqMotor = 0xFF;

        [self rumbleSync];

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
        if (me.shouldSendInputEvents) {
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
    if (self.shouldSendInputEvents) {
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
}

- (void)keyDown:(NSEvent *)event {
    if (self.shouldSendInputEvents) {
        LiSendKeyboardEvent(0x8000 | [self translateKeyCodeWithEvent:event], KEY_ACTION_DOWN, [self translateKeyModifierWithEvent:event]);
    }
}

- (void)keyUp:(NSEvent *)event {
    if (self.shouldSendInputEvents) {
        LiSendKeyboardEvent(0x8000 | [self translateKeyCodeWithEvent:event], KEY_ACTION_UP, [self translateKeyModifierWithEvent:event]);
    }
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
    if (self.shouldSendInputEvents) {
        LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, button);
    }
}

- (void)mouseUp:(NSEvent *)event withButton:(int)button {
    if (self.shouldSendInputEvents) {
        LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, button);
    }
}

- (void)mouseMoved:(NSEvent *)event {
    self.mouseDeltaX += event.deltaX;
    self.mouseDeltaY += event.deltaY;
}

- (void)scrollWheel:(NSEvent *)event {
    if (self.shouldSendInputEvents) {
        if (event.hasPreciseScrollingDeltas) {
            if (cfdyMouseScrollMethod()) {
                CFDYSendHighResScrollEvent(event.scrollingDeltaY);
            } else {
                LiSendHighResScrollEvent(event.scrollingDeltaY);
            }
        } else {
            LiSendScrollEvent(event.scrollingDeltaY);
        }
    }
}

- (int)hidGetFeatureReport:(IOHIDDeviceRef)device data:(unsigned char *)data length:(size_t)length {
    CFIndex len = length;
    IOReturn res;
        
    int skipped_report_id = 0;
    int report_number = data[0];
    if (report_number == 0x0) {
//         Offset the return buffer by 1, so that the report ID
//         will remain in byte 0.
        data++;
        len--;
        skipped_report_id = 1;
    }
    
    res = IOHIDDeviceGetReport(device,
                               kIOHIDReportTypeFeature,
                               report_number, /* Report ID */
                               data, &len);
    if (res != kIOReturnSuccess) {
        return -1;
    }

    if (skipped_report_id) {
        len++;
    }

    return (int)len;
}

- (void)rumbleSync {
    if (self.controllerDriver == 0) {
        [self rumbleLowFreqMotor:0 highFreqMotor:0];
    }
}

- (void)runRumbleLoop {
    while (YES) {
        // wait for signal
        dispatch_semaphore_wait(self.rumbleSemaphore, DISPATCH_TIME_FOREVER);
        
        if (self.closeRumble) {
            break;
        }
        
        NSSet *devices = CFBridgingRelease(IOHIDManagerCopyDevices(self.hidManager));
        if (devices.count == 0) {
            continue;
        }
        IOHIDDeviceRef device = (__bridge IOHIDDeviceRef)devices.allObjects[0];
        if (device == nil) {
            continue;
        }
        
        // get next value
        UInt16 lowFreqMotor = self.nextLowFreqMotor;
        UInt16 highFreqMotor = self.nextHighFreqMotor;
        
        if (isXbox(device)) {
            UInt8 rumble_packet[] = { 0x03, 0x0F, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x00, 0xEB };
            
            UInt8 convertedLowFreqMotor = lowFreqMotor / 655;
            UInt8 convertedHighFreqMotor = highFreqMotor / 655;
            if (convertedLowFreqMotor != self.previousLowFreqMotor || convertedHighFreqMotor != self.previousHighFreqMotor) {
                
                self.previousLowFreqMotor = convertedLowFreqMotor;
                self.previousHighFreqMotor = convertedHighFreqMotor;

                rumble_packet[4] = convertedLowFreqMotor;
                rumble_packet[5] = convertedHighFreqMotor;
                
                IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, rumble_packet[0], rumble_packet, sizeof(rumble_packet));
                usleep(30000);
            }
        } else if (isPlayStation(device)) {
            UInt8 reportData[64];
            int size;

            // This will fail if we're on Bluetooth.
            reportData[0] = k_ePS4FeatureReportIdSerialNumber;
            size = [self hidGetFeatureReport:device data:reportData length:sizeof(reportData)];
            BOOL isBluetooth = !(size >= 7);
            
            UInt8 data[78] = {};
            if (isBluetooth) {
                data[0] = 17;
                data[1] = 0xC0 | 0x04; // Magic value HID + CRC, also sets interval to 4ms for samples.
                data[3] = 0x03; // 0x1 is rumble, 0x2 is lightbar, 0x4 is the blink interval.
            } else {
                data[0] = 5;
                data[1] = 0x07; // Magic value
            }
            UInt8 convertedLowFreqMotor = lowFreqMotor / 256;
            UInt8 convertedHighFreqMotor = highFreqMotor / 256;
            if ((convertedLowFreqMotor != self.previousLowFreqMotor || convertedHighFreqMotor != self.previousHighFreqMotor) || (convertedLowFreqMotor == 0 && convertedHighFreqMotor == 0)) {
                
//                convertedLowFreqMotor = convertedLowFreqMotor > 0 ? convertedLowFreqMotor : 0;
//                convertedHighFreqMotor = convertedHighFreqMotor > 0 ? convertedHighFreqMotor : 0;
                self.previousLowFreqMotor = convertedLowFreqMotor;
                self.previousHighFreqMotor = convertedHighFreqMotor;
                
                if (isBluetooth) {
                    data[6] = convertedHighFreqMotor;
                    data[7] = convertedLowFreqMotor;
                    data[8] = 0; // red
                    data[9] = 0; // green
                    data[10] = 12; // blue
                } else {
                    data[4] = convertedHighFreqMotor;
                    data[5] = convertedLowFreqMotor;
                    data[6] = 0; // red
                    data[7] = 0; // green
                    data[8] = 12; // blue
                }
                
                if (isBluetooth) {
                    // Bluetooth reports need a CRC at the end of the packet (at least on Linux).
                    UInt8 ubHdr = 0xA2; // hidp header is part of the CRC calculation.
                    UInt32 unCRC;
                    unCRC = SDL_crc32(0, &ubHdr, 1);
                    unCRC = SDL_crc32(unCRC, data, (size_t)(sizeof(data) - sizeof(unCRC)));
                    memcpy(&data[sizeof(data) - sizeof(unCRC)], &unCRC, sizeof(unCRC));
                }

                IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, data[0], data, sizeof(data));
                usleep(30000);
            }
        }
    }
}

- (void)rumbleLowFreqMotor:(unsigned short)lowFreqMotor highFreqMotor:(unsigned short)highFreqMotor {
    self.nextLowFreqMotor = lowFreqMotor;
    self.nextHighFreqMotor = highFreqMotor;

    dispatch_semaphore_signal(self.rumbleSemaphore);
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

- (NSInteger)controllerDriver {
    return [[NSUserDefaults standardUserDefaults] integerForKey:@"controllerDriver"];
}

UInt16 usbIdFromDevice(IOHIDDeviceRef device, NSString *key) {
    CFNumberRef vendor = (CFNumberRef)(IOHIDDeviceGetProperty(device, (CFStringRef)key));
    return [(NSNumber *)CFBridgingRelease(vendor) unsignedShortValue];
}

BOOL isXbox(IOHIDDeviceRef device) {
    UInt16 vendorId = usbIdFromDevice(device, @kIOHIDVendorIDKey);
    UInt16 productId = usbIdFromDevice(device, @kIOHIDProductIDKey);
    return vendorId == 0x045E && (productId == 0x02FD || productId == 0x0B13);
}

BOOL isPlayStation(IOHIDDeviceRef device) {
    UInt16 vendorId = usbIdFromDevice(device, @kIOHIDVendorIDKey);
    UInt16 productId = usbIdFromDevice(device, @kIOHIDProductIDKey);
    return vendorId == 0x054C && (productId == 0x09CC || productId == 0x05c4);
}

- (void)handlePlaystationDpad:(NSInteger)intValue {
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
}

void myHIDCallback(void* context, IOReturn result, void* sender, IOHIDValueRef value) {
    IOHIDElementRef elem = IOHIDValueGetElement(value);
    uint32_t usagePage = IOHIDElementGetUsagePage(elem);
    uint32_t usage = IOHIDElementGetUsage(elem);
    CFIndex intValue = IOHIDValueGetIntegerValue(value);
    
    HIDSupport *self = (__bridge HIDSupport *)context;
    
    IOHIDDeviceRef device = (IOHIDDeviceRef)sender;
    
    if (isXbox(device)) {
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

    } else if (isPlayStation(device)) {
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
                        [self handlePlaystationDpad:intValue];
                        break;

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

    if (self.controllerDriver == 0) {
        if (cfdyControllerMethod()) {
            CFDYSendMultiControllerEvent(self.controller.playerIndex, 1, self.controller.lastButtonFlags, self.controller.lastLeftTrigger, self.controller.lastRightTrigger, self.controller.lastLeftStickX, self.controller.lastLeftStickY, self.controller.lastRightStickX, self.controller.lastRightStickY);
        } else {
            LiSendMultiControllerEvent(self.controller.playerIndex, 1, self.controller.lastButtonFlags, self.controller.lastLeftTrigger, self.controller.lastRightTrigger, self.controller.lastLeftStickX, self.controller.lastLeftStickY, self.controller.lastRightStickX, self.controller.lastRightStickY);
        }
    }
}

void myHIDReportCallback (
                          void * _Nullable        context,
                          IOReturn                result,
                          void * _Nullable        sender,
                          IOHIDReportType         type,
                          uint32_t                reportID,
                          uint8_t *               report,
                          CFIndex                 reportLength) {
    HIDSupport *self = (__bridge HIDSupport *)context;
    
    IOHIDDeviceRef device = (IOHIDDeviceRef)sender;
    if (!isPlayStation(device)) {
        return;
    };
    
    PS4StatePacket_t *state = (PS4StatePacket_t *)report;
    switch (report[0]) {
        case k_EPS4ReportIdUsbState:
            state = (PS4StatePacket_t *)(report + 1);
            break;
        case k_EPS4ReportIdBluetoothState1:
        case k_EPS4ReportIdBluetoothState2:
        case k_EPS4ReportIdBluetoothState3:
        case k_EPS4ReportIdBluetoothState4:
        case k_EPS4ReportIdBluetoothState5:
        case k_EPS4ReportIdBluetoothState6:
        case k_EPS4ReportIdBluetoothState7:
        case k_EPS4ReportIdBluetoothState8:
        case k_EPS4ReportIdBluetoothState9:
            // Bluetooth state packets have two additional bytes at the beginning, the first notes if HID is present.
            if (report[1] & 0x80) {
                state = (PS4StatePacket_t *)(report + 3);
            }
            break;
        default:
            NSLog(@"Unknown PS4 packet: 0x%hhu", report[0]);
            break;
    }
            
    
    UInt8 abxy = state->rgucButtonsHatAndCounter[0] >> 4;
    [self updateButtonFlags:X_FLAG state:(abxy & 0x01) != 0];
    [self updateButtonFlags:A_FLAG state:(abxy & 0x02) != 0];
    [self updateButtonFlags:B_FLAG state:(abxy & 0x04) != 0];
    [self updateButtonFlags:Y_FLAG state:(abxy & 0x08) != 0];
    
    [self handlePlaystationDpad:state->rgucButtonsHatAndCounter[0] & 0x0F];

    UInt8 otherButtons = state->rgucButtonsHatAndCounter[1];
    [self updateButtonFlags:LB_FLAG state:(otherButtons & 0x01) != 0];
    [self updateButtonFlags:RB_FLAG state:(otherButtons & 0x02) != 0];
    [self updateButtonFlags:BACK_FLAG state:(otherButtons & 0x10) != 0];
    [self updateButtonFlags:PLAY_FLAG state:(otherButtons & 0x20) != 0];
    [self updateButtonFlags:LS_CLK_FLAG state:(otherButtons & 0x40) != 0];
    [self updateButtonFlags:RS_CLK_FLAG state:(otherButtons & 0x80) != 0];

    [self updateButtonFlags:SPECIAL_FLAG state:(state->rgucButtonsHatAndCounter[2] & 0x01) != 0];
    
    self.controller.lastLeftTrigger = state->ucTriggerLeft;
    self.controller.lastRightTrigger = state->ucTriggerRight;

    self.controller.lastLeftStickX = (state->ucLeftJoystickX - 128) * 255 + 1;
    self.controller.lastLeftStickY = (state->ucLeftJoystickY - 128) * -255;
    self.controller.lastRightStickX = (state->ucRightJoystickX - 128) * 255 + 1;
    self.controller.lastRightStickY = (state->ucRightJoystickY - 128) * -255;
    
    if (self.controllerDriver == 0) {

        if (self.lastPS4State.rgucButtonsHatAndCounter[0] != state->rgucButtonsHatAndCounter[0] ||
            self.lastPS4State.rgucButtonsHatAndCounter[1] != state->rgucButtonsHatAndCounter[1] ||
            self.lastPS4State.rgucButtonsHatAndCounter[2] != state->rgucButtonsHatAndCounter[2] ||
            self.lastPS4State.ucTriggerLeft != state->ucTriggerLeft ||
            self.lastPS4State.ucTriggerRight != state->ucTriggerRight ||
            self.lastPS4State.ucLeftJoystickX != state->ucLeftJoystickX ||
            self.lastPS4State.ucLeftJoystickY != state->ucLeftJoystickY ||
            self.lastPS4State.ucRightJoystickX != state->ucRightJoystickX ||
            self.lastPS4State.ucRightJoystickY != state->ucRightJoystickY ||
            0)
        {
            if (cfdyControllerMethod()) {
                CFDYSendMultiControllerEvent(self.controller.playerIndex, 1, self.controller.lastButtonFlags, self.controller.lastLeftTrigger, self.controller.lastRightTrigger, self.controller.lastLeftStickX, self.controller.lastLeftStickY, self.controller.lastRightStickX, self.controller.lastRightStickY);
            } else {
                LiSendMultiControllerEvent(self.controller.playerIndex, 1, self.controller.lastButtonFlags, self.controller.lastLeftTrigger, self.controller.lastRightTrigger, self.controller.lastLeftStickX, self.controller.lastLeftStickY, self.controller.lastRightStickX, self.controller.lastRightStickY);
            }
            self.lastPS4State = *state;
        }
    }
}

void myHIDDeviceMatchingCallback(void * _Nullable        context,
                                IOReturn                result,
                                void * _Nullable        sender,
                                IOHIDDeviceRef          device) {
    HIDSupport *self = (__bridge HIDSupport *)context;

    [self rumbleSync];
}

void myHIDDeviceRemovalCallback(void * _Nullable        context,
                                IOReturn                result,
                                void * _Nullable        sender,
                                IOHIDDeviceRef          device) {
    HIDSupport *self = (__bridge HIDSupport *)context;

    if (self.controllerDriver == 0) {
        self.controller.lastButtonFlags = 0;
        self.controller.lastLeftTrigger = 0;
        self.controller.lastRightTrigger = 0;
        self.controller.lastLeftStickX = 0;
        self.controller.lastLeftStickY = 0;
        self.controller.lastRightStickX = 0;
        self.controller.lastRightStickY = 0;
        
        if (cfdyControllerMethod()) {
            CFDYSendMultiControllerEvent(self.controller.playerIndex, 1, self.controller.lastButtonFlags, self.controller.lastLeftTrigger, self.controller.lastRightTrigger, self.controller.lastLeftStickX, self.controller.lastLeftStickY, self.controller.lastRightStickX, self.controller.lastRightStickY);
        } else {
            LiSendMultiControllerEvent(self.controller.playerIndex, 1, self.controller.lastButtonFlags, self.controller.lastLeftTrigger, self.controller.lastRightTrigger, self.controller.lastLeftStickX, self.controller.lastLeftStickY, self.controller.lastRightStickX, self.controller.lastRightStickY);
        }
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
    IOHIDManagerRegisterInputReportCallback(self.hidManager, myHIDReportCallback, (__bridge void * _Nullable)(self));
    IOHIDManagerRegisterDeviceMatchingCallback(self.hidManager, myHIDDeviceMatchingCallback, (__bridge void * _Nullable)(self));
    IOHIDManagerRegisterDeviceRemovalCallback(self.hidManager, myHIDDeviceRemovalCallback, (__bridge void * _Nullable)(self));
    
    IOHIDManagerScheduleWithRunLoop(self.hidManager, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    
    self.rumbleSemaphore = dispatch_semaphore_create(0);
    self.rumbleQueue = dispatch_queue_create("rumbleQueue", nil);
    
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.rumbleQueue, ^{
        [weakSelf runRumbleLoop];
    });
}

- (void)tearDownHidManager {
    self.closeRumble = YES;
    dispatch_semaphore_signal(self.rumbleSemaphore);
    
    self.rumbleQueue = nil;
    
    IOHIDManagerUnscheduleFromRunLoop(self.hidManager, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    IOHIDManagerClose(self.hidManager, kIOHIDOptionsTypeNone);
    CFRelease(self.hidManager);
}


@end
