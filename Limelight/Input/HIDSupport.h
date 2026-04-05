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

@interface HIDInputDiagnosticsSnapshot : NSObject
@property(nonatomic) NSUInteger mouseMoveEvents;
@property(nonatomic) NSUInteger nonZeroRelativeEvents;
@property(nonatomic) NSUInteger relativeDispatches;
@property(nonatomic) NSUInteger absoluteDispatches;
@property(nonatomic) NSUInteger suppressedRelativeEvents;
@property(nonatomic) NSInteger rawRelativeDeltaX;
@property(nonatomic) NSInteger rawRelativeDeltaY;
@property(nonatomic) NSInteger sentRelativeDeltaX;
@property(nonatomic) NSInteger sentRelativeDeltaY;
@end

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
- (void)sendAbsoluteMousePositionForViewPoint:(NSPoint)viewPoint
                                referenceSize:(NSSize)referenceSize
                                clampToBounds:(BOOL)clampToBounds;
- (void)suppressRelativeMouseMotionForMilliseconds:(uint64_t)durationMs;
- (void)refreshInputDiagnosticsPreference;
- (void)resetInputDiagnostics;
- (HIDInputDiagnosticsSnapshot *)consumeInputDiagnosticsSnapshot;

- (void)rumbleLowFreqMotor:(unsigned short)lowFreqMotor
             highFreqMotor:(unsigned short)highFreqMotor;

- (void)tearDownHidManager;

@end
