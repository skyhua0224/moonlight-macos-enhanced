//
//  AlternateControllerNetworking.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 20/2/21.
//  Copyright © 2021 Moonlight Game Streaming Project. All rights reserved.
//

#ifdef USE_RESOLUTION_SYNC
#import "AlternateControllerNetworking.h"
#import "Input.h"

#import "PlatformSockets.h"
#import "Connection.h"

extern struct sockaddr_storage RemoteAddr;
extern SOCKADDR_LEN RemoteAddrLen;


static SOCKET controllerSocket = INVALID_SOCKET;
static SOCKET mouseScrollSocket = INVALID_SOCKET;
static SOCKET rumbleSocket = INVALID_SOCKET;

const port = 48020;

static dispatch_queue_t rumbleQueue;

typedef struct _NV_RUMBLE_PACKET {
    uint16_t playerIndex;
    uint16_t lowFreqMotor;
    uint16_t highFreqMotor;
} NV_RUMBLE_PACKET;

BOOL disableResolutionSync(void) {
    return ![NSUserDefaults.standardUserDefaults boolForKey:@"enableResolutionSync"];
}

BOOL cfdyControllerMethod(void) {
    return [[NSUserDefaults standardUserDefaults] integerForKey:@"controllerMethod"] == 1 && !disableResolutionSync();
}

BOOL cfdyMouseScrollMethod(void) {
    return [[NSUserDefaults standardUserDefaults] integerForKey:@"mouseScrollMethod"] == 1 && !disableResolutionSync();
}

void CFDYSendMultiControllerEvent(short controllerNumber, short activeGamepadMask,
                                       short buttonFlags, unsigned char leftTrigger, unsigned char rightTrigger,
                                       short leftStickX, short leftStickY, short rightStickX, short rightStickY) {
    
    if (disableResolutionSync()) {
        return;
    }

    if (controllerSocket == INVALID_SOCKET) {
        controllerSocket = createSocket(AF_INET, SOCK_DGRAM, IPPROTO_UDP, true);
        if (controllerSocket == SOCKET_ERROR) {
            NSLog(@"Error creating controller input socket: %d", LastSocketError());
        }
    }

    NV_MULTI_CONTROLLER_PACKET packet = {};
    
    packet.header.size = htonl(sizeof packet - sizeof packet.header);
    packet.header.magic = MULTI_CONTROLLER_MAGIC_GEN5;
    packet.controllerNumber = controllerNumber;
    packet.activeGamepadMask = activeGamepadMask;
    packet.buttonFlags = buttonFlags;
    packet.leftTrigger = leftTrigger;
    packet.rightTrigger = rightTrigger;
    packet.leftStickX = leftStickX;
    packet.leftStickY = leftStickY;
    packet.rightStickX = rightStickX;
    packet.rightStickY = rightStickY;
    
    struct sockaddr_in *addr = malloc(RemoteAddrLen);
    memcpy(addr, &RemoteAddr, RemoteAddrLen);
    addr->sin_port = htons(port);
    
    if (sendto(controllerSocket, &packet, sizeof(packet), 0, (const struct sockaddr *)addr, RemoteAddrLen) < 0) {
        controllerSocket = INVALID_SOCKET;
        NSLog(@"Error sending controller packet: %d", LastSocketError());
    }
}

int CFDYSendHighResScrollEvent(short scrollAmount) {
    if (disableResolutionSync()) {
        return 1;
    }

    if (mouseScrollSocket == INVALID_SOCKET) {
        mouseScrollSocket = createSocket(AF_INET, SOCK_DGRAM, IPPROTO_UDP, true);
        if (mouseScrollSocket == SOCKET_ERROR) {
            NSLog(@"Error creating mouse scroll socket: %d", LastSocketError());
        }
    }

    NV_SCROLL_PACKET packet = {};
    
    packet.header.size = htonl(sizeof packet - sizeof packet.header);
    packet.header.magic = SCROLL_MAGIC_GEN5;
    packet.scrollAmt1 = htons(scrollAmount);
    packet.scrollAmt2 = packet.scrollAmt1;
    packet.zero3 = 0;

    struct sockaddr_in *addr = malloc(RemoteAddrLen);
    memcpy(addr, &RemoteAddr, RemoteAddrLen);
    addr->sin_port = htons(port);
    
    if (sendto(mouseScrollSocket, &packet, sizeof(packet), 0, (const struct sockaddr *)addr, RemoteAddrLen) < 0) {
        mouseScrollSocket = INVALID_SOCKET;
        NSLog(@"Error sending mouse scroll packet: %d", LastSocketError());
        return 1;
    }
    
    return 0;
}

BOOL startListeningForRumblePackets(id<ConnectionCallbacks> connectionCallbacks) {
    if (disableResolutionSync()) {
        return NO;
    }

    rumbleSocket = createSocket(AF_INET, SOCK_DGRAM, IPPROTO_UDP, NO);
    
    struct sockaddr_in addr;
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(48020);
    
    if (bind(rumbleSocket, (struct sockaddr *)&addr, sizeof(addr)) == SOCKET_ERROR) {
        NSLog(@"Error binding port: %d", LastSocketError());
        return NO;
    }
    
    rumbleQueue = dispatch_queue_create("rumbleListenQueue", nil);
    dispatch_async(rumbleQueue, ^{
        while (YES) {
            char buffer[1000];
            ssize_t receiveLength = recvUdpSocket(rumbleSocket, buffer, sizeof(buffer), NO);
            if (receiveLength == SOCKET_ERROR) {
                if (LastSocketError() == EINTR || LastSocketError() == EBADF) {
                    break;
                }
                NSLog(@"Error receiving packet: %d", LastSocketError());
            } else {
                if (receiveLength >= sizeof(NV_RUMBLE_PACKET)) {
                    NV_RUMBLE_PACKET *rumblePacket = (NV_RUMBLE_PACKET *)buffer;
                    [connectionCallbacks rumble:rumblePacket->playerIndex lowFreqMotor:rumblePacket->lowFreqMotor highFreqMotor:rumblePacket->highFreqMotor];
                }
            }
        }
    });
    
    return YES;
}

void stopListeningForRumblePackets(void) {
    if (disableResolutionSync()) {
        return;
    }

    if (rumbleSocket != INVALID_SOCKET) {
        closeSocket(rumbleSocket);
        rumbleSocket = INVALID_SOCKET;
    }
}
#endif
