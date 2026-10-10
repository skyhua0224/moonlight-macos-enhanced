//
//  MLPrecisionTouchpad.h
//  Moonlight for macOS
//
//  Sends the Mac trackpad's raw multi-finger contacts to a host that supports
//  Windows precision touchpad input, so Windows handles scrolling, pinch and
//  multi-finger gestures itself.
//

#import <Cocoa/Cocoa.h>
#include "Limelight.h"
#include "Limelight-internal.h"

NS_ASSUME_NONNULL_BEGIN

@interface MLPrecisionTouchpad : NSObject

/// Runs work on the input queue with the current input context. The work is dropped when there is none.
@property (nonatomic, copy, nullable) void (^dispatchHandler)(void (^work)(PML_INPUT_STREAM_CONTEXT ctx));
/// Returns the host's LI_FF_* feature flags, or 0 when they are not known yet.
@property (nonatomic, copy, nullable) uint32_t (^featureFlagsProvider)(void);
/// Mirrors the user setting. Turning it off cancels any contacts the host still holds.
@property (nonatomic) BOOL enabled;

/// Feeds the touches of a touch event on the stream view.
- (void)handleTouchesEvent:(NSEvent *)event inView:(NSView *)view;
/// Mouse button events that come from the trackpad itself are carried by the touchpad frames instead.
/// Returns YES when the button event was consumed and must not be sent as a mouse button.
- (BOOL)consumeMouseButton:(int)button pressed:(BOOL)pressed;
/// YES while the trackpad is driving the host (fingers down or just lifted), so its pointer motion must not also be sent.
- (BOOL)shouldSuppressPointerMotion;
/// YES for trackpad scroll events (including momentum) that Windows now produces from the contacts.
- (BOOL)shouldSuppressScrollEvent:(NSEvent *)event;
/// Cancels every contact on the host and forgets local state.
- (void)reset;

@end

NS_ASSUME_NONNULL_END
