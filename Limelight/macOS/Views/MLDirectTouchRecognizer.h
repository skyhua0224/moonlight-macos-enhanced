//
//  MLDirectTouchRecognizer.h
//  Moonlight for macOS
//
//  A gesture recognizer that takes every direct touch on the view (a touchscreen Mac, or an iPad
//  through Sidecar) and hands the raw contacts on. On macOS gesture recognizers are the only way to
//  receive direct touches: they do not go through the responder chain, NSWindow sendEvent: or event
//  monitors (Apple Tech Talk 111468, 3:45; NSResponder.h:66).
//

#import <Cocoa/Cocoa.h>
#import "MLTouchCore.h"

NS_ASSUME_NONNULL_BEGIN

@interface MLDirectTouchRecognizer : NSGestureRecognizer

/// Called with the samples of each touch event, in the stream view's coordinates. Main thread.
@property (nonatomic, copy, nullable) void (^samplesHandler)(NSArray<MLTouchSample *> *samples);
/// Called after samplesHandler, with every direct touch of the event, accepted or not (the debug overlay and the
/// mouse gate want to know about all of them), and how many touches are still down afterwards. Main thread.
@property (nonatomic, copy, nullable) void (^allSamplesHandler)(NSArray<MLTouchSample *> *samples, NSUInteger downCount);
/// Decides whether a touch that just landed belongs to the stream (the picture) or to something on top
/// of it (the edge menu, an overlay). Called once per touch, at its start. Rejected touches are not
/// reported, and the recognizer does not claim them, so the control they hit works as usual.
@property (nonatomic, copy, nullable) BOOL (^acceptsTouchAtPoint)(NSPoint viewPoint);
/// Touches that are down and being reported.
@property (nonatomic, readonly) NSUInteger activeTouchCount;
/// The state this recognizer last asked AppKit for (Possible after a reset).
@property (nonatomic, readonly) NSGestureRecognizerState lastRequestedState;
/// Drops all tracking (stream stop, mode switch). Reports nothing.
- (void)forgetAllTouches;

@end

NS_ASSUME_NONNULL_END
