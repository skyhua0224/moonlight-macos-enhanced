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
#import "Ticks.h"

#include "Limelight.h"

#import <Carbon/Carbon.h>

#import <IOKit/hid/IOHIDManager.h>
#import <IOKit/hid/IOHIDKeys.h>
#import <IOKit/hid/IOHIDElement.h>

@import GameController;

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

typedef enum {
    k_EPS5ReportIdState = 0x01,
    k_EPS5ReportIdUsbEffects = 0x02,
    k_EPS5ReportIdBluetoothEffects = 0x31,
    k_EPS5ReportIdBluetoothState = 0x31,
} EPS5ReportId;

typedef struct {
    UInt8 ucLeftJoystickX;              /* 0 */
    UInt8 ucLeftJoystickY;              /* 1 */
    UInt8 ucRightJoystickX;             /* 2 */
    UInt8 ucRightJoystickY;             /* 3 */
    UInt8 ucTriggerLeft;                /* 4 */
    UInt8 ucTriggerRight;               /* 5 */
    UInt8 ucCounter;                    /* 6 */
    UInt8 rgucButtonsAndHat[3];         /* 7 */
    UInt8 ucZero;                       /* 10 */
    UInt8 rgucPacketSequence[4];        /* 11 - 32 bit little endian */
    UInt8 rgucGyroX[2];                 /* 15 */
    UInt8 rgucGyroY[2];                 /* 17 */
    UInt8 rgucGyroZ[2];                 /* 19 */
    UInt8 rgucAccelX[2];                /* 21 */
    UInt8 rgucAccelY[2];                /* 23 */
    UInt8 rgucAccelZ[2];                /* 25 */
    UInt8 rgucTimer1[4];                /* 27 - 32 bit little endian */
    UInt8 ucBatteryTemp;                /* 31 */
    UInt8 ucTouchpadCounter1;           /* 32 - high bit clear + counter */
    UInt8 rgucTouchpadData1[3];         /* 33 - X/Y, 12 bits per axis */
    UInt8 ucTouchpadCounter2;           /* 36 - high bit clear + counter */
    UInt8 rgucTouchpadData2[3];         /* 37 - X/Y, 12 bits per axis */
    UInt8 rgucUnknown1[8];              /* 40 */
    UInt8 rgucTimer2[4];                /* 48 - 32 bit little endian */
    UInt8 ucBatteryLevel;               /* 52 */
    UInt8 ucConnectState;               /* 53 - 0x08 = USB, 0x01 = headphone */

    /* There's more unknown data at the end, and a 32-bit CRC on Bluetooth */
} PS5StatePacket_t;

typedef struct {
    UInt8 ucEnableBits1;                /* 0 */
    UInt8 ucEnableBits2;                /* 1 */
    UInt8 ucRumbleRight;                /* 2 */
    UInt8 ucRumbleLeft;                 /* 3 */
    UInt8 ucHeadphoneVolume;            /* 4 */
    UInt8 ucSpeakerVolume;              /* 5 */
    UInt8 ucMicrophoneVolume;           /* 6 */
    UInt8 ucAudioEnableBits;            /* 7 */
    UInt8 ucMicLightMode;               /* 8 */
    UInt8 ucAudioMuteBits;              /* 9 */
    UInt8 rgucRightTriggerEffect[11];   /* 10 */
    UInt8 rgucLeftTriggerEffect[11];    /* 21 */
    UInt8 rgucUnknown1[6];              /* 32 */
    UInt8 ucLedFlags;                   /* 38 */
    UInt8 rgucUnknown2[2];              /* 39 */
    UInt8 ucLedAnim;                    /* 41 */
    UInt8 ucLedBrightness;              /* 42 */
    UInt8 ucPadLights;                  /* 43 */
    UInt8 ucLedRed;                     /* 44 */
    UInt8 ucLedGreen;                   /* 45 */
    UInt8 ucLedBlue;                    /* 46 */
} DS5EffectsState_t;

static UInt32 crc32_for_byte(UInt32 r) {
    int i;
    for(i = 0; i < 8; ++i) {
        r = (r & 1? 0: (UInt32)0xEDB88320L) ^ r >> 1;
    }
    return r ^ (UInt32)0xFF000000L;
}

UInt32 SDL_crc32(UInt32 crc, const void *data, size_t len) {
    // As an optimization we can precalculate a 256 entry table for each byte.
    size_t i;
    for(i = 0; i < len; ++i) {
        crc = crc32_for_byte((UInt8)crc ^ ((const UInt8*)data)[i]) ^ crc >> 8;
    }
    return crc;
}

typedef enum {
    k_eSwitchSubcommandIDs_BluetoothManualPair = 0x01,
    k_eSwitchSubcommandIDs_RequestDeviceInfo   = 0x02,
    k_eSwitchSubcommandIDs_SetInputReportMode  = 0x03,
    k_eSwitchSubcommandIDs_SetHCIState         = 0x06,
    k_eSwitchSubcommandIDs_SPIFlashRead        = 0x10,
    k_eSwitchSubcommandIDs_SetPlayerLights     = 0x30,
    k_eSwitchSubcommandIDs_SetHomeLight        = 0x38,
    k_eSwitchSubcommandIDs_EnableIMU           = 0x40,
    k_eSwitchSubcommandIDs_SetIMUSensitivity   = 0x41,
    k_eSwitchSubcommandIDs_EnableVibration     = 0x48,
} ESwitchSubcommandIDs;

typedef enum {
    k_eSwitchInputReportIDs_SubcommandReply       = 0x21,
    k_eSwitchInputReportIDs_FullControllerState   = 0x30,
    k_eSwitchInputReportIDs_SimpleControllerState = 0x3F,
    k_eSwitchInputReportIDs_CommandAck            = 0x81,
} ESwitchInputReportIDs;

typedef struct {
    UInt32 unAddress;
    UInt8 ucLength;
} SwitchSPIOpData_t;

typedef struct {
    UInt8 ucCounter;
    UInt8 ucBatteryAndConnection;
    UInt8 rgucButtons[3];
    UInt8 rgucJoystickLeft[3];
    UInt8 rgucJoystickRight[3];
    UInt8 ucVibrationCode;
} SwitchControllerStatePacket_t;

typedef struct {
    SwitchControllerStatePacket_t m_controllerState;

    UInt8 ucSubcommandAck;
    UInt8 ucSubcommandID;

    #define k_unSubcommandDataBytes 35
    union {
        UInt8 rgucSubcommandData[k_unSubcommandDataBytes];

        struct {
            SwitchSPIOpData_t opData;
            UInt8 rgucReadData[k_unSubcommandDataBytes - sizeof(SwitchSPIOpData_t)];
        } spiReadData;

        struct {
            UInt8 rgucFirmwareVersion[2];
            UInt8 ucDeviceType;
            UInt8 ucFiller1;
            UInt8 rgucMACAddress[6];
            UInt8 ucFiller2;
            UInt8 ucColorLocation;
        } deviceInfo;
    };
} SwitchSubcommandInputPacket_t;

typedef struct {
    UInt8 rgucData[4];
} SwitchRumbleData_t;

typedef struct {
    UInt8 ucPacketType;
    UInt8 ucPacketNumber;
    SwitchRumbleData_t rumbleData[2];
} SwitchCommonOutputPacket_t;

#define k_unSwitchOutputPacketDataLength 49
#define k_unSwitchMaxOutputPacketLength 64

typedef struct {
    SwitchCommonOutputPacket_t commonData;

    UInt8 ucSubcommandID;
    UInt8 rgucSubcommandData[k_unSwitchOutputPacketDataLength - sizeof(SwitchCommonOutputPacket_t) - 1];
} SwitchSubcommandOutputPacket_t;

typedef struct {
    UInt8 rgucButtons[2];
    UInt8 ucStickHat;
    UInt8 rgucJoystickLeft[2];
    UInt8 rgucJoystickRight[2];
} SwitchInputOnlyControllerStatePacket_t;

typedef struct {
    UInt8 rgucButtons[2];
    UInt8 ucStickHat;
    int16_t sJoystickLeft[2];
    int16_t sJoystickRight[2];
} SwitchSimpleStatePacket_t;

typedef struct {
    SwitchControllerStatePacket_t controllerState;

    struct {
        int16_t sAccelX;
        int16_t sAccelY;
        int16_t sAccelZ;

        int16_t sGyroX;
        int16_t sGyroY;
        int16_t sGyroZ;
    } imuState[3];
} SwitchStatePacket_t;

#define RUMBLE_WRITE_FREQUENCY_MS 25
#define RUMBLE_REFRESH_FREQUENCY_MS 40

typedef enum {
    k_eSwitchOutputReportIDs_RumbleAndSubcommand = 0x01,
    k_eSwitchOutputReportIDs_Rumble              = 0x10,
    k_eSwitchOutputReportIDs_Proprietary         = 0x80,
} ESwitchOutputReportIDs;

#define k_unSwitchOutputPacketDataLength 49
#define k_unSwitchMaxOutputPacketLength 64
#define k_unSwitchBluetoothPacketLength k_unSwitchOutputPacketDataLength
#define k_unSwitchUSBPacketLength k_unSwitchMaxOutputPacketLength


@interface HIDSupport ()
@property (nonatomic) dispatch_queue_t rumbleQueue;
@property (nonatomic, strong) NSDictionary *mappings;
@property (nonatomic) IOHIDManagerRef hidManager;
@property (nonatomic, strong) Controller *controller;
@property (nonatomic) CVDisplayLinkRef displayLink;
@property (atomic) CGFloat mouseDeltaX;
@property (atomic) CGFloat mouseDeltaY;
@property (nonatomic) UInt8 previousLowFreqMotor;
@property (nonatomic) UInt8 previousHighFreqMotor;
@property (atomic) UInt16 nextLowFreqMotor;
@property (atomic) UInt16 nextHighFreqMotor;
@property (atomic) dispatch_semaphore_t rumbleSemaphore;
@property (atomic) BOOL closeRumble;
@property (atomic) BOOL isRumbleTimer;
@property (nonatomic) PS4StatePacket_t lastPS4State;
@property (nonatomic) PS5StatePacket_t lastPS5State;
@property (nonatomic) NSInteger controllerDriver;
@property (nonatomic) BOOL isPS5Bluetooth;

@property (nonatomic) SwitchSimpleStatePacket_t lastSimpleSwitchState;
@property (nonatomic) SwitchStatePacket_t lastSwitchState;

@property (atomic) dispatch_semaphore_t hidReadSemaphore;
@property (atomic) BOOL vibrationEnableResponded;
@property (atomic) BOOL waitingForVibrationEnable;
@property (atomic) UInt32 startedWaitingForVibrationEnable;
@property (nonatomic) dispatch_queue_t enableVibrationQueue;

@property (nonatomic) BOOL switchUsingBluetooth;
@property (nonatomic) UInt8 switchCommandNumber;
@property (nonatomic) BOOL switchRumbleActive;
@property (nonatomic) UInt32 switchUnRumbleSent;
@property (nonatomic) BOOL switchRumblePending;
@property (nonatomic) BOOL switchRumbleZeroPending;
@property (nonatomic) UInt32 switchUnRumblePending;

@property (nonatomic, strong) Ticks *ticks;

@property (nonatomic) id mouseConnectObserver;
@property (nonatomic) id mouseDisconnectObserver;

@property (nonatomic) BOOL useGCMouse;
@end

@implementation HIDSupport

SwitchCommonOutputPacket_t switchRumblePacket;

- (instancetype)init {
    self = [super init];
    if (self) {
        [self setupHidManager];
        
        self.ticks = [[Ticks alloc] init];
        self.switchUsingBluetooth = YES;
        
        self.previousLowFreqMotor = 0xFF;
        self.previousHighFreqMotor = 0xFF;

        [self rumbleSync];

        self.controller = [[Controller alloc] init];
        
        if (@available(macOS 11.0, *)) {
            for (GCMouse *mouse in GCMouse.mice) {
                [self registerMouseCallbacks:mouse];
            }

            self.mouseConnectObserver = [[NSNotificationCenter defaultCenter] addObserverForName:GCMouseDidConnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification * _Nonnull note) {
                [self registerMouseCallbacks:note.object];
            }];
            self.mouseDisconnectObserver = [[NSNotificationCenter defaultCenter] addObserverForName:GCMouseDidDisconnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification * _Nonnull note) {
                [self unregisterMouseCallbacks:note.object];
            }];
        }
        
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
    NSLog(@"HIDSupport dealloc");
}

-(void)registerMouseCallbacks:(GCMouse *)mouse API_AVAILABLE(macos(11.0)) {
    if (!self.useGCMouse) {
        return;
    }
    
    mouse.mouseInput.mouseMovedHandler = ^(GCMouseInput * _Nonnull mouse, float deltaX, float deltaY) {
        self.mouseDeltaX += deltaX;
        self.mouseDeltaY -= deltaY;
    };
    
    mouse.mouseInput.leftButton.pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
        if (self.shouldSendInputEvents) {
            LiSendMouseButtonEvent(pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE, BUTTON_LEFT);
        }
    };
    mouse.mouseInput.middleButton.pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
        if (self.shouldSendInputEvents) {
            LiSendMouseButtonEvent(pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE, BUTTON_MIDDLE);
        }
    };
    mouse.mouseInput.rightButton.pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
        if (self.shouldSendInputEvents) {
            LiSendMouseButtonEvent(pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE, BUTTON_RIGHT);
        }
    };
    
    mouse.mouseInput.auxiliaryButtons[0].pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
        if (self.shouldSendInputEvents) {
            LiSendMouseButtonEvent(pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE, BUTTON_X1);
        }
    };
    mouse.mouseInput.auxiliaryButtons[1].pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
        if (self.shouldSendInputEvents) {
            LiSendMouseButtonEvent(pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE, BUTTON_X2);
        }
    };
    
    mouse.mouseInput.scroll.yAxis.valueChangedHandler = ^(GCControllerAxisInput * _Nonnull axis, float value) {
#ifdef USE_RESOLUTION_SYNC
            if (cfdyMouseScrollMethod()) {
                CFDYSendHighResScrollEvent(value);
            } else {
#endif
                LiSendHighResScrollEvent(value);
#ifdef USE_RESOLUTION_SYNC
            }
#endif
    };
}

-(void)unregisterMouseCallbacks:(GCMouse*)mouse API_AVAILABLE(macos(11.0)) {
    if (!self.useGCMouse) {
        return;
    }
    
    mouse.mouseInput.mouseMovedHandler = nil;
    
    mouse.mouseInput.leftButton.pressedChangedHandler = nil;
    mouse.mouseInput.middleButton.pressedChangedHandler = nil;
    mouse.mouseInput.rightButton.pressedChangedHandler = nil;
    
    for (GCControllerButtonInput* auxButton in mouse.mouseInput.auxiliaryButtons) {
        auxButton.pressedChangedHandler = nil;
    }
}

- (void)sendControllerEvent {
#ifdef USE_RESOLUTION_SYNC
    if (cfdyControllerMethod()) {
        CFDYSendMultiControllerEvent(self.controller.playerIndex, 1, self.controller.lastButtonFlags, self.controller.lastLeftTrigger, self.controller.lastRightTrigger, self.controller.lastLeftStickX, self.controller.lastLeftStickY, self.controller.lastRightStickX, self.controller.lastRightStickY);
    } else {
#endif
        LiSendMultiControllerEvent(self.controller.playerIndex, 1, self.controller.lastButtonFlags, self.controller.lastLeftTrigger, self.controller.lastRightTrigger, self.controller.lastLeftStickX, self.controller.lastLeftStickY, self.controller.lastRightStickX, self.controller.lastRightStickY);
#ifdef USE_RESOLUTION_SYNC
    }
#endif
}

static CVReturn displayLinkOutputCallback(CVDisplayLinkRef displayLink,
                                          const CVTimeStamp *now,
                                          const CVTimeStamp *vsyncTime,
                                          CVOptionFlags flagsIn,
                                          CVOptionFlags *flagsOut,
                                          void *displayLinkContext)
{
    HIDSupport *me = (__bridge HIDSupport *)displayLinkContext;
    if (me == nil) {
        return kCVReturnError;
    }

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
    
    __weak typeof(self) weakSelf = self;
    status = CVDisplayLinkSetOutputCallback(self.displayLink, displayLinkOutputCallback, (__bridge void * _Nullable)(weakSelf));
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
    if (self.useGCMouse) {
        return;
    }
    
    if (self.shouldSendInputEvents) {
        LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, button);
    }
}

- (void)mouseUp:(NSEvent *)event withButton:(int)button {
    if (self.useGCMouse) {
        return;
    }
    
    if (self.shouldSendInputEvents) {
        LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, button);
    }
}

- (void)mouseMoved:(NSEvent *)event {
    if (self.useGCMouse) {
        return;
    }
    
    self.mouseDeltaX += event.deltaX;
    self.mouseDeltaY += event.deltaY;
}

- (void)scrollWheel:(NSEvent *)event {
    if (self.useGCMouse) {
        return;
    }
    
    if (self.shouldSendInputEvents) {
        if (event.hasPreciseScrollingDeltas) {
#ifdef USE_RESOLUTION_SYNC
            if (cfdyMouseScrollMethod()) {
                CFDYSendHighResScrollEvent(event.scrollingDeltaY);
            } else {
#endif
                LiSendHighResScrollEvent(event.scrollingDeltaY);
#ifdef USE_RESOLUTION_SYNC
            }
#endif
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
//      Offset the return buffer by 1, so that the report ID
//      will remain in byte 0.
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
        
        IOHIDDeviceRef device = [self getFirstDevice];
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
        } else if (isPS4(device)) {
            UInt8 reportData[64];
            int size;

            // This will fail if we're on Bluetooth.
            reportData[0] = k_ePS4FeatureReportIdSerialNumber;
            size = [self hidGetFeatureReport:device data:reportData length:sizeof(reportData)];
            BOOL isBluetooth = !(size >= 7);
            
            UInt8 data[78] = {};
            if (isBluetooth) {
                data[0] = k_EPS4ReportIdBluetoothEffects;
                data[1] = 0xC0 | 0x04; // Magic value HID + CRC, also sets interval to 4ms for samples.
                data[3] = 0x03; // 0x1 is rumble, 0x2 is lightbar, 0x4 is the blink interval.
            } else {
                data[0] = k_EPS4ReportIdUsbEffects;
                data[1] = 0x07; // Magic value
            }
            UInt8 convertedLowFreqMotor = lowFreqMotor / 256;
            UInt8 convertedHighFreqMotor = highFreqMotor / 256;
            if ((convertedLowFreqMotor != self.previousLowFreqMotor || convertedHighFreqMotor != self.previousHighFreqMotor) || (convertedLowFreqMotor == 0 && convertedHighFreqMotor == 0)) {
                
                self.previousLowFreqMotor = convertedLowFreqMotor;
                self.previousHighFreqMotor = convertedHighFreqMotor;
                
                int i = isBluetooth ? 6 : 4;
                data[i++] = convertedHighFreqMotor;
                data[i++] = convertedLowFreqMotor;
                data[i++] = 0; // red
                data[i++] = 0; // green
                data[i++] = 12; // blue
                
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
        } else if (isPS5(device)) {
            int dataSize, offset;

            UInt8 data[78] = {};
            if (self.isPS5Bluetooth) {
                data[0] = k_EPS5ReportIdBluetoothEffects;
                data[1] = 0x02; // Magic value

                dataSize = 78;
                offset = 2;
            } else {
                data[0] = k_EPS5ReportIdBluetoothEffects;

                dataSize = 48;
                offset = 1;
            }
            DS5EffectsState_t *effects = (DS5EffectsState_t *)&data[offset];

            UInt8 convertedLowFreqMotor = lowFreqMotor / 256;
            UInt8 convertedHighFreqMotor = highFreqMotor / 256;
            if ((convertedLowFreqMotor != self.previousLowFreqMotor || convertedHighFreqMotor != self.previousHighFreqMotor) || (convertedLowFreqMotor == 0 && convertedHighFreqMotor == 0)) {

                self.previousLowFreqMotor = convertedLowFreqMotor;
                self.previousHighFreqMotor = convertedHighFreqMotor;

                effects->ucEnableBits1 |= 0x01; /* Enable rumble emulation */
                effects->ucEnableBits1 |= 0x02; /* Disable audio haptics */

                effects->ucRumbleLeft = convertedLowFreqMotor;
                effects->ucRumbleRight = convertedHighFreqMotor;

                if (self.isPS5Bluetooth) {
                    // Bluetooth reports need a CRC at the end of the packet (at least on Linux).
                    UInt8 ubHdr = 0xA2; // hidp header is part of the CRC calculation.
                    UInt32 unCRC;
                    unCRC = SDL_crc32(0, &ubHdr, 1);
                    unCRC = SDL_crc32(unCRC, data, (size_t)(dataSize - sizeof(unCRC)));
                    memcpy(&data[dataSize - sizeof(unCRC)], &unCRC, sizeof(unCRC));
                }

                IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, data[0], data, dataSize);
                usleep(30000);
            }
        } else if (isNintendo(device)) {
            if (self.isRumbleTimer) {
                if (self.switchRumblePending || self.switchRumbleZeroPending) {
                    [self switchSendPendingRumble:device];
                } else if (self.switchRumbleActive && TICKS_PASSED([self.ticks getTicks], self.switchUnRumbleSent + RUMBLE_REFRESH_FREQUENCY_MS)) {
                    NSLog(@"Sent continuing rumble");
                    [self writeRumble:device];
                }
                
                if (self.switchRumblePending) {
                    usleep(RUMBLE_REFRESH_FREQUENCY_MS * 1000);
                    self.isRumbleTimer = YES;
                    dispatch_semaphore_signal(self.rumbleSemaphore);
                } else {
                    self.isRumbleTimer = NO;
                }
            } else {
                self.switchUnRumbleSent = [self.ticks getTicks];
                [self switch_RumbleJoystick:device lowFreqMotor:lowFreqMotor highFreqMotor:highFreqMotor];
                
                usleep(RUMBLE_REFRESH_FREQUENCY_MS * 1000);
                self.isRumbleTimer = YES;
                dispatch_semaphore_signal(self.rumbleSemaphore);
            }
        }
    }
}

- (IOHIDDeviceRef)getFirstDevice {
    NSSet *devices = CFBridgingRelease(IOHIDManagerCopyDevices(self.hidManager));
    if (devices.count == 0) {
        return nil;
    }
    IOHIDDeviceRef device = (__bridge IOHIDDeviceRef)devices.allObjects[0];
    if (device == nil) {
        return nil;
    }
    
    return device;
}


#pragma mark - Switch rumble stuff

- (int)switch_RumbleJoystick:(IOHIDDeviceRef)device lowFreqMotor:(UInt16)lowFreqMotor highFreqMotor:(UInt16)highFreqMotor {
    if (self.switchRumblePending) {
        if ([self switchSendPendingRumble:device] < 0) {
            return -1;
        }
    }

    if (self.switchUsingBluetooth && ([self.ticks getTicks] - self.switchUnRumbleSent) < RUMBLE_WRITE_FREQUENCY_MS) {
        if (lowFreqMotor || highFreqMotor) {
            UInt32 unRumblePending = lowFreqMotor << 16 | highFreqMotor;

            /* Keep the highest rumble intensity in the given interval */
            if (unRumblePending > self.switchUnRumblePending) {
                self.switchUnRumblePending = unRumblePending;
            }
            self.switchRumblePending = YES;
            self.switchRumbleZeroPending = NO;
        } else {
            /* When rumble is complete, turn it off */
            self.switchRumbleZeroPending = YES;
        }
        return 0;
    }

    NSLog(@"Sent rumble %d/%d", lowFreqMotor, highFreqMotor);

    return [self switchActuallyRumbleJoystick:device low_frequency_rumble:lowFreqMotor high_frequency_rumble:highFreqMotor];
}

- (BOOL)setVibrationEnabled:(UInt8)enabled {
    return [self writeSubcommand:k_eSwitchSubcommandIDs_EnableVibration pBuf:&enabled ucLen:sizeof(enabled) ppReply:nil];
}

- (BOOL)writeSubcommand:(ESwitchSubcommandIDs)ucCommandID pBuf:(UInt8 *)pBuf ucLen:(UInt8)ucLen ppReply:(SwitchSubcommandInputPacket_t **)ppReply {
    int nRetries = 5;
    BOOL success = NO;

    while (!success && nRetries--) {
        SwitchSubcommandOutputPacket_t commandPacket;
        [self constructSubcommand:ucCommandID pBuf:pBuf ucLen:ucLen outPacket:&commandPacket];

        IOHIDDeviceRef device = [self getFirstDevice];
        
        self.waitingForVibrationEnable = YES;
        self.startedWaitingForVibrationEnable = [self.ticks getTicks];
        if (![self writePacket:device pBuf:&commandPacket ucLen:sizeof(commandPacket)]) {
            continue;
        }

        dispatch_semaphore_wait(self.hidReadSemaphore, DISPATCH_TIME_FOREVER);
        success = self.vibrationEnableResponded;
    }

    return success;
}

- (void)constructSubcommand:(ESwitchSubcommandIDs)ucCommandID pBuf:(UInt8 *)pBuf ucLen:(UInt8)ucLen outPacket:(SwitchSubcommandOutputPacket_t *)outPacket {
    memset(outPacket, 0, sizeof(*outPacket));

    outPacket->commonData.ucPacketType = k_eSwitchOutputReportIDs_RumbleAndSubcommand;
    outPacket->commonData.ucPacketNumber = self.switchCommandNumber;

    memcpy(&outPacket->commonData.rumbleData, &switchRumblePacket.rumbleData, sizeof(switchRumblePacket.rumbleData));

    outPacket->ucSubcommandID = ucCommandID;
    memcpy(outPacket->rgucSubcommandData, pBuf, ucLen);

    self.switchCommandNumber = (self.switchCommandNumber + 1) & 0xF;
}

- (int)switchSendPendingRumble:(IOHIDDeviceRef)device {
    if (([self.ticks getTicks] - self.switchUnRumbleSent) < RUMBLE_WRITE_FREQUENCY_MS) {
        return 0;
    }
    
    if (self.switchRumblePending) {
        UInt16 low_frequency_rumble = (UInt16)(self.switchUnRumblePending >> 16);
        UInt16 high_frequency_rumble = (UInt16)self.switchUnRumblePending;

        NSLog(@"Sent pending rumble %d/%d", low_frequency_rumble, high_frequency_rumble);

        self.switchRumblePending = NO;
        self.switchUnRumblePending = 0;

        return [self switchActuallyRumbleJoystick:device low_frequency_rumble:low_frequency_rumble high_frequency_rumble:high_frequency_rumble];
    }

    if (self.switchRumbleZeroPending) {
        self.switchRumbleZeroPending = NO;

        NSLog(@"Sent pending zero rumble");

        return [self switchActuallyRumbleJoystick:device low_frequency_rumble:0 high_frequency_rumble:0];
    }

    return 0;
}

- (int)switchActuallyRumbleJoystick:(IOHIDDeviceRef)device low_frequency_rumble:(UInt16)low_frequency_rumble high_frequency_rumble:(UInt16)high_frequency_rumble {
    const UInt16 k_usHighFreq = 0x0074;
    const UInt8 k_ucHighFreqAmp = 0xBE;
    const UInt8 k_ucLowFreq = 0x3D;
    const UInt16 k_usLowFreqAmp = 0x806F;

    if (low_frequency_rumble) {
        [self switchEncodeRumble:&switchRumblePacket.rumbleData[0] usHighFreq:k_usHighFreq ucHighFreqAmp:k_ucHighFreqAmp ucLowFreq:k_ucLowFreq usLowFreqAmp:k_usLowFreqAmp];
    } else {
        [self setNeutralRumble:&switchRumblePacket.rumbleData[0]];
    }

    if (high_frequency_rumble) {
        [self switchEncodeRumble:&switchRumblePacket.rumbleData[1] usHighFreq:k_usHighFreq ucHighFreqAmp:k_ucHighFreqAmp ucLowFreq:k_ucLowFreq usLowFreqAmp:k_usLowFreqAmp];
    } else {
        [self setNeutralRumble:&switchRumblePacket.rumbleData[1]];
    }

    self.switchRumbleActive = (low_frequency_rumble || high_frequency_rumble) ? YES : NO;

    if (![self writeRumble:device]) {
        NSLog(@"Couldn't send rumble packet");
        return -1;
    }
    return 0;
}

- (void)setNeutralRumble:(SwitchRumbleData_t *)pRumble {
    pRumble->rgucData[0] = 0x00;
    pRumble->rgucData[1] = 0x01;
    pRumble->rgucData[2] = 0x40;
    pRumble->rgucData[3] = 0x40;
}

- (void)switchEncodeRumble:(SwitchRumbleData_t *)pRumble usHighFreq:(UInt16)usHighFreq ucHighFreqAmp:(UInt8)ucHighFreqAmp ucLowFreq:(UInt8)ucLowFreq usLowFreqAmp:(UInt16)usLowFreqAmp {
    if (ucHighFreqAmp > 0 || usLowFreqAmp > 0) {
        // High-band frequency and low-band amplitude are actually nine-bits each so they
        // take a bit from the high-band amplitude and low-band frequency bytes respectively
        pRumble->rgucData[0] = usHighFreq & 0xFF;
        pRumble->rgucData[1] = ucHighFreqAmp | ((usHighFreq >> 8) & 0x01);

        pRumble->rgucData[2]  = ucLowFreq | ((usLowFreqAmp >> 8) & 0x80);
        pRumble->rgucData[3]  = usLowFreqAmp & 0xFF;

        NSLog(@"Freq: %.2X %.2X  %.2X, Amp: %.2X  %.2X %.2X\n", usHighFreq & 0xFF, ((usHighFreq >> 8) & 0x01), ucLowFreq, ucHighFreqAmp, ((usLowFreqAmp >> 8) & 0x80), usLowFreqAmp & 0xFF);
    } else {
        [self setNeutralRumble:pRumble];
    }
}

- (BOOL)writeRumble:(IOHIDDeviceRef)device {
    // Write into m_RumblePacket rather than a temporary buffer to allow the current rumble state
    // to be retained for subsequent rumble or subcommand packets sent to the controller
    
    switchRumblePacket.ucPacketType = k_eSwitchOutputReportIDs_Rumble;
    switchRumblePacket.ucPacketNumber = self.switchCommandNumber;
    self.switchCommandNumber = (self.switchCommandNumber + 1) & 0xF;

    // Refresh the rumble state periodically
    self.switchUnRumbleSent = [self.ticks getTicks];

    return [self writePacket:device pBuf:(UInt8 *)&switchRumblePacket ucLen:sizeof(switchRumblePacket)];
}

- (BOOL)writePacket:(IOHIDDeviceRef)device pBuf:(void *)pBuf ucLen:(UInt8)ucLen {
    UInt8 rgucBuf[k_unSwitchMaxOutputPacketLength];
    const size_t unWriteSize = self.switchUsingBluetooth ? k_unSwitchBluetoothPacketLength : k_unSwitchUSBPacketLength;

    if (ucLen > k_unSwitchOutputPacketDataLength) {
        return NO;
    }

    if (ucLen < unWriteSize) {
        memcpy(rgucBuf, pBuf, ucLen);
        memset(rgucBuf+ucLen, 0, unWriteSize-ucLen);
        pBuf = rgucBuf;
        ucLen = (UInt8)unWriteSize;
    }
    
    UInt8 *data = (UInt8 *)pBuf;
    IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, data[0], data, ucLen);
    return YES;
}


- (void)rumbleLowFreqMotor:(unsigned short)lowFreqMotor highFreqMotor:(unsigned short)highFreqMotor {
    self.nextLowFreqMotor = lowFreqMotor;
    self.nextHighFreqMotor = highFreqMotor;

    self.isRumbleTimer = NO;
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

- (BOOL)useGCMouse {
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"useGCMouseDriver"];
}

- (NSInteger)controllerDriver {
    return [[NSUserDefaults standardUserDefaults] integerForKey:@"controllerDriver"];
}

UInt16 usbIdFromDevice(IOHIDDeviceRef device, NSString *key) {
    CFNumberRef vendor = (CFNumberRef)(IOHIDDeviceGetProperty(device, (CFStringRef)key));
    return [(NSNumber *)CFBridgingRelease(vendor) unsignedShortValue];
}

BOOL isNintendo(IOHIDDeviceRef device) {
    UInt16 vendorId = usbIdFromDevice(device, @kIOHIDVendorIDKey);
    UInt16 productId = usbIdFromDevice(device, @kIOHIDProductIDKey);
    return vendorId == 0x057E && (productId == 0x2009);
}

BOOL isXbox(IOHIDDeviceRef device) {
    UInt16 vendorId = usbIdFromDevice(device, @kIOHIDVendorIDKey);
    UInt16 productId = usbIdFromDevice(device, @kIOHIDProductIDKey);
    return vendorId == 0x045E && (productId == 0x02FD || productId == 0x0B13);
}

BOOL isPlayStation(IOHIDDeviceRef device) {
    UInt16 vendorId = usbIdFromDevice(device, @kIOHIDVendorIDKey);
    UInt16 productId = usbIdFromDevice(device, @kIOHIDProductIDKey);
    return vendorId == 0x054C && (productId == 0x09CC || productId == 0x05C4 || productId == 0x0CE6);
}

BOOL isPS4(IOHIDDeviceRef device) {
    UInt16 vendorId = usbIdFromDevice(device, @kIOHIDVendorIDKey);
    UInt16 productId = usbIdFromDevice(device, @kIOHIDProductIDKey);
    return vendorId == 0x054C && (productId == 0x09CC || productId == 0x05c4);
}

BOOL isPS5(IOHIDDeviceRef device) {
    UInt16 vendorId = usbIdFromDevice(device, @kIOHIDVendorIDKey);
    UInt16 productId = usbIdFromDevice(device, @kIOHIDProductIDKey);
    return vendorId == 0x054C && (productId == 0x0ce6);
}

- (void)handleDpad:(NSInteger)intValue {
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
    }

    if (self.controllerDriver == 0) {
        [self sendControllerEvent];
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
    if (!isPlayStation(device) && !isNintendo(device)) {
        return;
    };
    
    if (isPS4(device)) {
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
        
        [self handleDpad:state->rgucButtonsHatAndCounter[0] & 0x0F];

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
                [self sendControllerEvent];
                self.lastPS4State = *state;
            }
        }
    } else if (isPS5(device)) {
        PS5StatePacket_t *state = (PS5StatePacket_t *)report;
        switch (report[0]) {
            case k_EPS5ReportIdState:
                state = (PS5StatePacket_t *)(report + 1);
                self.isPS5Bluetooth = reportLength == 10;
                break;
            case k_EPS5ReportIdBluetoothState:
                state = (PS5StatePacket_t *)(report + 2);
                self.isPS5Bluetooth = YES;
                break;
            default:
                NSLog(@"Unknown PS5 packet: 0x%hhu", report[0]);
                break;
        }
        
        UInt8 abxy = state->rgucButtonsAndHat[0] >> 4;
        [self updateButtonFlags:X_FLAG state:(abxy & 0x01) != 0];
        [self updateButtonFlags:A_FLAG state:(abxy & 0x02) != 0];
        [self updateButtonFlags:B_FLAG state:(abxy & 0x04) != 0];
        [self updateButtonFlags:Y_FLAG state:(abxy & 0x08) != 0];
        
        [self handleDpad:state->rgucButtonsAndHat[0] & 0x0F];

        UInt8 otherButtons = state->rgucButtonsAndHat[1];
        [self updateButtonFlags:LB_FLAG state:(otherButtons & 0x01) != 0];
        [self updateButtonFlags:RB_FLAG state:(otherButtons & 0x02) != 0];
        [self updateButtonFlags:BACK_FLAG state:(otherButtons & 0x10) != 0];
        [self updateButtonFlags:PLAY_FLAG state:(otherButtons & 0x20) != 0];
        [self updateButtonFlags:LS_CLK_FLAG state:(otherButtons & 0x40) != 0];
        [self updateButtonFlags:RS_CLK_FLAG state:(otherButtons & 0x80) != 0];

        [self updateButtonFlags:SPECIAL_FLAG state:(state->rgucButtonsAndHat[2] & 0x01) != 0];
        
        self.controller.lastLeftTrigger = state->ucTriggerLeft;
        self.controller.lastRightTrigger = state->ucTriggerRight;

        self.controller.lastLeftStickX = (state->ucLeftJoystickX - 128) * 255 + 1;
        self.controller.lastLeftStickY = (state->ucLeftJoystickY - 128) * -255;
        self.controller.lastRightStickX = (state->ucRightJoystickX - 128) * 255 + 1;
        self.controller.lastRightStickY = (state->ucRightJoystickY - 128) * -255;
        
        if (self.controllerDriver == 0) {

            if (self.lastPS5State.rgucButtonsAndHat[0] != state->rgucButtonsAndHat[0] ||
                self.lastPS5State.rgucButtonsAndHat[1] != state->rgucButtonsAndHat[1] ||
                self.lastPS5State.rgucButtonsAndHat[2] != state->rgucButtonsAndHat[2] ||
                self.lastPS5State.ucTriggerLeft != state->ucTriggerLeft ||
                self.lastPS5State.ucTriggerRight != state->ucTriggerRight ||
                self.lastPS5State.ucLeftJoystickX != state->ucLeftJoystickX ||
                self.lastPS5State.ucLeftJoystickY != state->ucLeftJoystickY ||
                self.lastPS5State.ucRightJoystickX != state->ucRightJoystickX ||
                self.lastPS5State.ucRightJoystickY != state->ucRightJoystickY ||
                0)
            {
                [self sendControllerEvent];
                self.lastPS5State = *state;
            }
        }
    } else if (isNintendo(device)) {
        if (self.waitingForVibrationEnable) {
            if (TICKS_PASSED([self.ticks getTicks], self.startedWaitingForVibrationEnable + 100)) {
                self.vibrationEnableResponded = NO;
                self.waitingForVibrationEnable = NO;
                dispatch_semaphore_signal(self.hidReadSemaphore);
            }
            if (report[0] == k_eSwitchInputReportIDs_SubcommandReply) {
                SwitchSubcommandInputPacket_t *reply = (SwitchSubcommandInputPacket_t *)&report[1];
                if (reply->ucSubcommandID == k_eSwitchSubcommandIDs_EnableVibration && (reply->ucSubcommandAck & 0x80)) {
                    self.vibrationEnableResponded = YES;
                    self.waitingForVibrationEnable = NO;
                    dispatch_semaphore_signal(self.hidReadSemaphore);
                }
            }
        } else {
            if (report[0] == k_eSwitchInputReportIDs_SimpleControllerState) {
                SwitchSimpleStatePacket_t *packet = (SwitchSimpleStatePacket_t *)&report[1];
                
                SInt16 axis;
                
                UInt8 buttons = packet->rgucButtons[0];
                [self updateButtonFlags:Y_FLAG state:(buttons & 0x08) != 0];
                [self updateButtonFlags:B_FLAG state:(buttons & 0x02) != 0];
                [self updateButtonFlags:A_FLAG state:(buttons & 0x01) != 0];
                [self updateButtonFlags:X_FLAG state:(buttons & 0x04) != 0];
                [self updateButtonFlags:LB_FLAG state:(buttons & 0x10) != 0];
                [self updateButtonFlags:RB_FLAG state:(buttons & 0x20) != 0];
                axis = (buttons & 0x40) ? 32767 : -32768;
                self.controller.lastLeftTrigger = axis;
                axis = (buttons & 0x80) ? 32767 : -32768;
                self.controller.lastRightTrigger = axis;
                
                UInt8 otherButtons = packet->rgucButtons[1];
                [self updateButtonFlags:BACK_FLAG state:(otherButtons & 0x01) != 0];
                [self updateButtonFlags:PLAY_FLAG state:(otherButtons & 0x02) != 0];
                [self updateButtonFlags:LS_CLK_FLAG state:(otherButtons & 0x04) != 0];
                [self updateButtonFlags:RS_CLK_FLAG state:(otherButtons & 0x08) != 0];
                
                [self updateButtonFlags:SPECIAL_FLAG state:(otherButtons & 0x10) != 0];
                
                [self handleDpad:packet->ucStickHat];

                axis = packet->sJoystickLeft[0] - INT_MAX;
                self.controller.lastLeftStickX = axis;
                axis = packet->sJoystickLeft[1] - INT_MAX;
                self.controller.lastLeftStickY = axis;
                axis = packet->sJoystickRight[0] - INT_MAX;
                self.controller.lastRightStickX = axis;
                axis = packet->sJoystickRight[1] - INT_MAX;
                self.controller.lastRightStickY = axis;
                
                if (self.controllerDriver == 0) {
                    
                    if (self.lastSimpleSwitchState.rgucButtons[0] != packet->rgucButtons[0] ||
                        self.lastSimpleSwitchState.rgucButtons[1] != packet->rgucButtons[1] ||
                        self.lastSimpleSwitchState.ucStickHat != packet->ucStickHat ||
                        self.lastSimpleSwitchState.sJoystickLeft[0] != packet->sJoystickLeft[0] ||
                        self.lastSimpleSwitchState.sJoystickLeft[1] != packet->sJoystickLeft[1] ||
                        self.lastSimpleSwitchState.sJoystickRight[0] != packet->sJoystickRight[0] ||
                        self.lastSimpleSwitchState.sJoystickRight[1] != packet->sJoystickRight[1] ||
                        0)
                    {
                        [self sendControllerEvent];
                        self.lastSimpleSwitchState = *packet;
                    }
                }
            } else if (report[0] == k_eSwitchInputReportIDs_FullControllerState) {
                SwitchStatePacket_t *packet = (SwitchStatePacket_t *)&report[1];
                
                SInt16 axis;
                
                UInt8 buttons = packet->controllerState.rgucButtons[0];
                [self updateButtonFlags:Y_FLAG state:(buttons & 0x02) != 0];
                [self updateButtonFlags:B_FLAG state:(buttons & 0x08) != 0];
                [self updateButtonFlags:A_FLAG state:(buttons & 0x04) != 0];
                [self updateButtonFlags:X_FLAG state:(buttons & 0x01) != 0];
                [self updateButtonFlags:RB_FLAG state:(buttons & 0x40) != 0];
                axis = (buttons & 0x80) ? 32767 : -32768;
                self.controller.lastRightTrigger = axis;
                
                UInt8 otherButtons = packet->controllerState.rgucButtons[1];
                [self updateButtonFlags:BACK_FLAG state:(otherButtons & 0x01) != 0];
                [self updateButtonFlags:PLAY_FLAG state:(otherButtons & 0x02) != 0];
                [self updateButtonFlags:LS_CLK_FLAG state:(otherButtons & 0x08) != 0];
                [self updateButtonFlags:RS_CLK_FLAG state:(otherButtons & 0x04) != 0];
                
                [self updateButtonFlags:SPECIAL_FLAG state:(otherButtons & 0x10) != 0];
                
                UInt8 otherOtherButtons = packet->controllerState.rgucButtons[2];
                [self updateButtonFlags:DOWN_FLAG state:(otherOtherButtons & 0x01) != 0];
                [self updateButtonFlags:UP_FLAG state:(otherOtherButtons & 0x02) != 0];
                [self updateButtonFlags:RIGHT_FLAG state:(otherOtherButtons & 0x04) != 0];
                [self updateButtonFlags:LEFT_FLAG state:(otherOtherButtons & 0x08) != 0];
                [self updateButtonFlags:LB_FLAG state:(otherOtherButtons & 0x40) != 0];
                axis = (otherOtherButtons & 0x80) ? 32767 : -32768;
                self.controller.lastLeftTrigger = axis;
                
                axis = packet->controllerState.rgucJoystickLeft[0] | ((packet->controllerState.rgucJoystickLeft[1] & 0xF) << 8);
                self.controller.lastLeftStickX = MAX(MIN((axis - 2048) * 24, INT16_MAX), INT16_MIN);
                axis = ((packet->controllerState.rgucJoystickLeft[1] & 0xF0) >> 4) | (packet->controllerState.rgucJoystickLeft[2] << 4);
                self.controller.lastLeftStickY = MAX(MIN((axis - 2048) * 24, INT16_MAX), INT16_MIN);
                axis = packet->controllerState.rgucJoystickRight[0] | ((packet->controllerState.rgucJoystickRight[1] & 0xF) << 8);
                self.controller.lastRightStickX = MAX(MIN((axis - 2048) * 24, INT16_MAX), INT16_MIN);
                axis = ((packet->controllerState.rgucJoystickRight[1] & 0xF0) >> 4) | (packet->controllerState.rgucJoystickRight[2] << 4);
                self.controller.lastRightStickY = MAX(MIN((axis - 2048) * 24, INT16_MAX), INT16_MIN);
                
                if (self.controllerDriver == 0) {
                    
                    if (self.lastSwitchState.controllerState.rgucButtons[0] != packet->controllerState.rgucButtons[0] ||
                        self.lastSwitchState.controllerState.rgucButtons[1] != packet->controllerState.rgucButtons[1] ||
                        self.lastSwitchState.controllerState.rgucButtons[2] != packet->controllerState.rgucButtons[2] ||
                        self.lastSwitchState.controllerState.rgucJoystickLeft[0] != packet->controllerState.rgucJoystickLeft[0] ||
                        self.lastSwitchState.controllerState.rgucJoystickLeft[1] != packet->controllerState.rgucJoystickLeft[1] ||
                        self.lastSwitchState.controllerState.rgucJoystickRight[0] != packet->controllerState.rgucJoystickRight[0] ||
                        self.lastSwitchState.controllerState.rgucJoystickRight[1] != packet->controllerState.rgucJoystickRight[1] ||
                        0)
                    {
                        [self sendControllerEvent];
                        self.lastSwitchState = *packet;
                    }
                }
            }
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
        
        [self sendControllerEvent];
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
    
    self.enableVibrationQueue = dispatch_queue_create("enableVibrationQueue", nil);

    self.hidReadSemaphore = dispatch_semaphore_create(0);

    __weak typeof(self) weakSelf = self;
    dispatch_async(self.rumbleQueue, ^{
        [weakSelf runRumbleLoop];
    });

    IOHIDDeviceRef device = [self getFirstDevice];
    if (device != nil) {
        if (isNintendo(device)) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), self.enableVibrationQueue, ^{
                if (![self setVibrationEnabled:1]) {
                    NSLog(@"Couldn't enable vibration");
                }
            });
        }
    }
}

- (void)tearDownHidManager {    
    [[NSNotificationCenter defaultCenter] removeObserver:self.mouseConnectObserver];
    [[NSNotificationCenter defaultCenter] removeObserver:self.mouseDisconnectObserver];
    self.mouseConnectObserver = nil;
    self.mouseDisconnectObserver = nil;

    if (@available(macOS 11.0, *)) {
        for (GCMouse *mouse in GCMouse.mice) {
            [self unregisterMouseCallbacks:mouse];
        }
    }
    
    if (self.displayLink != NULL) {
        CVDisplayLinkStop(self.displayLink);
        CVDisplayLinkRelease(self.displayLink);
    }
    
    self.closeRumble = YES;
    self.isRumbleTimer = NO;
    dispatch_semaphore_signal(self.rumbleSemaphore);
    
    self.rumbleQueue = nil;
    
    IOHIDManagerUnscheduleFromRunLoop(self.hidManager, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    IOHIDManagerClose(self.hidManager, kIOHIDOptionsTypeNone);
    CFRelease(self.hidManager);
}


@end
