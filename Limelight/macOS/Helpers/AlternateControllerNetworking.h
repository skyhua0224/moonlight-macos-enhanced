//
//  AlternateControllerNetworking.h
//  Moonlight for macOS
//
//  Created by Michael Kenny on 20/2/21.
//  Copyright © 2021 Moonlight Game Streaming Project. All rights reserved.
//

#import <Foundation/Foundation.h>

@protocol ConnectionCallbacks;

BOOL cfdyControllerMethod(void);
BOOL cfdyMouseScrollMethod(void);

void CFDYSendMultiControllerEvent(short controllerNumber, short activeGamepadMask,
                                  short buttonFlags, unsigned char leftTrigger, unsigned char rightTrigger,
                                  short leftStickX, short leftStickY, short rightStickX, short rightStickY);
int CFDYSendHighResScrollEvent(short scrollAmount);

BOOL startListeningForRumblePackets(id<ConnectionCallbacks> connectionCallbacks);
void stopListeningForRumblePackets(void);
