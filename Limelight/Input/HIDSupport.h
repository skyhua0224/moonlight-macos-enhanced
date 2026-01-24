//
//  HIDSupport.h
//  Moonlight for macOS
//
//  Created by Michael Kenny on 26/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import "TemporaryHost.h"
#import <Foundation/Foundation.h>

extern NSString *const HIDMouseModeToggledNotification;
extern NSString *const HIDGamepadQuitNotification;

@interface HIDSupport : NSObject
@property(atomic) BOOL shouldSendInputEvents;
@property(atomic) TemporaryHost *host;
@property(nonatomic, assign) void *inputContext;

- (instancetype)init:(TemporaryHost *)host;

- (void)flagsChanged:(NSEvent *)event;
- (void)keyDown:(NSEvent *)event;
- (void)keyUp:(NSEvent *)event;

- (void)releaseAllModifierKeys;

- (void)mouseDown:(NSEvent *)event withButton:(int)button;
- (void)mouseUp:(NSEvent *)event withButton:(int)button;
- (void)mouseMoved:(NSEvent *)event;
- (void)scrollWheel:(NSEvent *)event;

- (void)rumbleLowFreqMotor:(unsigned short)lowFreqMotor
             highFreqMotor:(unsigned short)highFreqMotor;

- (void)tearDownHidManager;

@end
