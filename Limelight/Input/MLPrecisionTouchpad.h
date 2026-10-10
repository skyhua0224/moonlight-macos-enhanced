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

#define MLTouchpadMaxContacts 5

/// How the Mac trackpad is shared between Windows' precision touchpad and the normal pointer path.
typedef NS_ENUM(NSInteger, MLPrecisionTouchpadMode) {
    /// Normal pointer, click and scroll input only.
    MLPrecisionTouchpadModeOff = 0,
    /// Every finger goes to Windows as touchpad contacts; the trackpad produces no pointer motion, clicks or scrolling.
    MLPrecisionTouchpadModeBlock = 1,
    /// A single finger keeps the normal pointer path (motion, clicks, taps). Once a second finger lands, the whole
    /// gesture goes to Windows as touchpad contacts (scroll, pinch, multi-finger gestures) until all fingers lift.
    MLPrecisionTouchpadModeBoth = 2,
};

/// One touchpad frame as it is put on the wire. Coordinates are 0...1 with a top-left origin.
typedef struct {
    uint8_t count;
    uint8_t types[MLTouchpadMaxContacts];
    uint32_t ids[MLTouchpadMaxContacts];
    float x[MLTouchpadMaxContacts];
    float y[MLTouchpadMaxContacts];
    float pressure[MLTouchpadMaxContacts];
    uint16_t widthMm;
    uint16_t heightMm;
    uint8_t buttonState;
} MLTouchpadFrame;

/// Decodes the host's touchpad support from its LI_FF_* feature flags. Returns NO when neither form is supported.
BOOL MLTouchpadHostSupport(uint32_t featureFlags, BOOL *useFrames);
/// Sends a frame as one frame event, or as one touchpad event per contact when the host has no frame events.
/// Returns 0 on success or a common-c error code.
int MLTouchpadSendFrame(PML_INPUT_STREAM_CONTEXT ctx, const MLTouchpadFrame *frame, BOOL useFrames);
/// Cancels every contact the host still holds.
int MLTouchpadSendCancelAll(PML_INPUT_STREAM_CONTEXT ctx, uint16_t widthMm, uint16_t heightMm);

@interface MLPrecisionTouchpad : NSObject

/// Runs work on the input queue with the current input context. The work is dropped when there is none.
@property (nonatomic, copy, nullable) void (^dispatchHandler)(void (^work)(PML_INPUT_STREAM_CONTEXT ctx));
/// Returns the host's LI_FF_* feature flags, or 0 when they are not known yet.
@property (nonatomic, copy, nullable) uint32_t (^featureFlagsProvider)(void);
/// Mirrors the user setting. Changing it cancels any contacts the host still holds.
@property (nonatomic) MLPrecisionTouchpadMode mode;

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
