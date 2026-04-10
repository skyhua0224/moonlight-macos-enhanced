//
//  HIDSupportRumbleTypes.h
//  Moonlight for macOS
//
//  Created by Michael Kenny on 26/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//
#import <Foundation/Foundation.h>

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
