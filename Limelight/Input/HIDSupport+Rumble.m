//
//  HIDSupport+Rumble.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 26/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//
#import "HIDSupport_Internal.h"

static UInt32 crc32_for_byte(UInt32 r) {
    int i;
    for (i = 0; i < 8; ++i) {
        r = (r & 1 ? 0 : (UInt32)0xEDB88320L) ^ r >> 1;
    }
    return r ^ (UInt32)0xFF000000L;
}

static UInt32 SDL_crc32(UInt32 crc, const void *data, size_t len) {
    size_t i;
    for (i = 0; i < len; ++i) {
        crc = crc32_for_byte((UInt8)crc ^ ((const UInt8 *)data)[i]) ^ crc >> 8;
    }
    return crc;
}

SwitchCommonOutputPacket_t switchRumblePacket;

@implementation HIDSupport (Rumble)

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
        
        if (isXbox(device) || isKingKong(device)) {
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
    for (NSObject *device in devices) {
        IOHIDDeviceRef hidDevice = (__bridge IOHIDDeviceRef)device;
        UInt16 productId = usbIdFromDevice(hidDevice, @kIOHIDProductIDKey);
        if (productId != 0x028E) {
            return hidDevice;
        }
    }
    
    return nil;
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

@end
