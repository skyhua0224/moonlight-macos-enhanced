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
typedef void (^HIDFreeMouseAbsoluteSyncHandler)(void);
@class StreamShortcut;

@interface HIDInputDiagnosticsSnapshot : NSObject
@property(nonatomic) NSUInteger mouseMoveEvents;
@property(nonatomic) NSUInteger nonZeroRelativeEvents;
@property(nonatomic) NSUInteger relativeDispatches;
@property(nonatomic) NSUInteger absoluteDispatches;
@property(nonatomic) NSUInteger absoluteDuplicateSkips;
@property(nonatomic) NSUInteger coreHIDRawEvents;
@property(nonatomic) NSUInteger coreHIDDispatches;
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
@property(nonatomic, copy) HIDFreeMouseAbsoluteSyncHandler freeMouseAbsoluteSyncHandler;

- (instancetype)init:(TemporaryHost *)host;

- (void)flagsChanged:(NSEvent *)event;
- (void)keyDown:(NSEvent *)event;
- (void)keyUp:(NSEvent *)event;

- (void)releaseAllModifierKeys;
- (void)sendSyntheticRemoteShortcut:(StreamShortcut *)shortcut;
- (void)sendSyntheticRemoteModifierTapForFlags:(NSEventModifierFlags)modifierFlags;
- (void)sendSyntheticRemoteModifierTapForKeyCode:(unsigned short)keyCode
            preferShortcutTranslationCommandMapping:(BOOL)preferShortcutTranslationCommandMapping;
- (void)beginDeferredShortcutTranslationCommandHoldForKeyCode:(unsigned short)keyCode;
- (void)endDeferredShortcutTranslationCommandHoldForKeyCode:(unsigned short)keyCode;
- (BOOL)getLastAbsolutePointerHostX:(short *)hostX
                              hostY:(short *)hostY
                     referenceWidth:(short *)referenceWidth
                    referenceHeight:(short *)referenceHeight
                              ageMs:(uint64_t *)ageMs
                             source:(NSString * __autoreleasing *)source;
- (void)refreshInputDiagnosticsPreference;
- (void)resetInputDiagnostics;
- (HIDInputDiagnosticsSnapshot *)consumeInputDiagnosticsSnapshot;
- (void)refreshMouseInputConfiguration;
- (void)tearDownHidManager;
- (BOOL)shouldUseAbsolutePointerPathForCurrentConfiguration;
- (BOOL)shouldUseCoreHIDFreeMouseAbsoluteSyncForCurrentConfiguration;
- (BOOL)hasRecentCoreHIDMouseMovement;

@end

@interface HIDSupport (PointerInput)
- (BOOL)hasPressedMouseButtons;
- (void)releaseAllPressedMouseButtons;
- (void)mouseDown:(NSEvent *)event withButton:(int)button;
- (void)mouseUp:(NSEvent *)event withButton:(int)button;
- (void)mouseMoved:(NSEvent *)event;
- (void)setFreeMouseVirtualCursorActive:(BOOL)active;
- (void)resetFreeMouseVirtualCursorState;
- (void)updateFreeMouseVirtualCursorAnchorWithViewPoint:(NSPoint)viewPoint
                                          referenceSize:(NSSize)referenceSize;
- (BOOL)reconcileFreeMouseVirtualCursorToViewPoint:(NSPoint)viewPoint
                                     referenceSize:(NSSize)referenceSize
                               correctionThreshold:(CGFloat)correctionThreshold;
- (BOOL)getFreeMouseVirtualCursorPoint:(NSPoint *)viewPoint
                         referenceSize:(NSSize *)referenceSize;
- (void)sendAbsoluteMousePositionForViewPoint:(NSPoint)viewPoint
                                referenceSize:(NSSize)referenceSize
                                clampToBounds:(BOOL)clampToBounds;
- (void)sendMouseButton:(int)button
                pressed:(BOOL)pressed
      syncedToViewPoint:(NSPoint)viewPoint
          referenceSize:(NSSize)referenceSize
          clampToBounds:(BOOL)clampToBounds;
- (BOOL)absoluteMousePayloadForViewPoint:(NSPoint)viewPoint
                           referenceSize:(NSSize)referenceSize
                           clampToBounds:(BOOL)clampToBounds
                                   hostX:(short *)hostX
                                   hostY:(short *)hostY
                          referenceWidth:(short *)referenceWidth
                         referenceHeight:(short *)referenceHeight;
- (void)suppressRelativeMouseMotionForMilliseconds:(uint64_t)durationMs;
@end

@interface HIDSupport (ScrollInput)
- (void)scrollWheel:(NSEvent *)event;
@end

@interface HIDSupport (RumbleOutput)
- (void)rumbleLowFreqMotor:(unsigned short)lowFreqMotor
             highFreqMotor:(unsigned short)highFreqMotor;
@end
