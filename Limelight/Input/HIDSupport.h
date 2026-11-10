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
/// Runs on the main queue when input is switched off (focus lost, menu opened): live touches must be let go.
@property(nonatomic, copy) void (^touchSuspendHandler)(void);
/// LiSendTouchEvent calls that did not go out (input queue full, not initialised, host without the feature), and the
/// last error code. Read for the debug overlay and the touch log.
@property(atomic) NSUInteger touchSendFailures;
@property(atomic) int touchLastSendError;
/// Pointer ids whose DOWN went out and whose UP has not (bit n = pointer n). Touched on the input queue only.
@property(nonatomic) uint32_t touchDownSentMask;
/// Gamepad devices the HID manager currently matches, and whether one of them delivered a report this
/// class parsed. The HID driver sends controller packets only after such a report: without a real pad
/// it must say nothing, because any controller packet creates a virtual pad on the host.
@property(atomic) NSInteger hidGamepadDeviceCount;
@property(atomic) BOOL hidGamepadReportSeen;
@property(nonatomic, copy) uint64_t (^controllerShortcutHandler)(unsigned short, uint32_t);
- (void)refreshControllerShortcutOutput;
- (void)toggleControllerMouseMode;
@property(atomic) TemporaryHost *host;
@property(nonatomic, assign) void *inputContext;
@property(nonatomic, copy) HIDFreeMouseAbsoluteSyncHandler freeMouseAbsoluteSyncHandler;

- (instancetype)init:(TemporaryHost *)host;

- (void)flagsChanged:(NSEvent *)event;
- (void)keyDown:(NSEvent *)event;
- (void)keyUp:(NSEvent *)event;

// Sends committed text from the Mac input method as UTF-8 text. Returns NO when nothing could be sent.
- (BOOL)sendUtf8Text:(NSString *)text;

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
- (void)refreshGamepadMouseModeConfiguration;
- (void)tearDownHidManager;
- (BOOL)shouldUseAbsolutePointerPathForCurrentConfiguration;
- (BOOL)shouldUseCoreHIDFreeMouseAbsoluteSyncForCurrentConfiguration;
- (BOOL)hasRecentCoreHIDMouseMovement;

@end

// Native Windows precision touchpad: raw trackpad contacts instead of mouse motion and scrolling.
@interface HIDSupport (PrecisionTouchpad)
- (void)setUpPrecisionTouchpad;
- (void)refreshPrecisionTouchpadConfiguration;
- (void)handleTrackpadTouchesEvent:(NSEvent *)event inView:(NSView *)view;
@end

// Direct touch (touchscreen Mac, Sidecar iPad): what reaches the host from the touch layer. All of these
// queue on the input queue like every other input; none of them read AppKit events.
@interface HIDSupport (DirectTouch)
/// LiGetHostFeatureFlags() of this stream's connection (0 until the connection knows).
- (uint32_t)touchHostFeatureFlags;
/// LiSendTouchEvent, in order on the input queue. A pointer's later events go out only after its DOWN did.
- (void)sendTouchWireEvent:(uint8_t)eventType pointerId:(uint32_t)pointerId x:(float)x y:(float)y;
- (void)sendTouchRelativeDeltaX:(short)deltaX deltaY:(short)deltaY;
/// x and y in 0..1 over the picture, top-left origin. referenceSize is the picture size in pixels.
- (void)sendTouchAbsoluteX:(float)x y:(float)y referenceSize:(CGSize)referenceSize;
- (void)sendTouchMouseButton:(int)button pressed:(BOOL)pressed;
- (void)sendTouchHighResScroll:(short)amount;
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
- (void)submitAuthoredRumbleLow:(unsigned short)low high:(unsigned short)high
                     sequence:(uint32_t)sequence discontinuity:(BOOL)discontinuity;
- (void)rumbleLowFreqMotor:(unsigned short)lowFreqMotor
             highFreqMotor:(unsigned short)highFreqMotor;
@end
