//
//  MLTouchRuntime.h
//  Moonlight for macOS
//
//  Owns direct touch for one stream window: the recognizer on the stream view, the native
//  forwarder or the fallback emulator (by the 触控方式 setting and the host's feature flags), the
//  mouse-emulation gate, the os_log record and the hidden debug overlay.
//

#import <Cocoa/Cocoa.h>
#import <os/log.h>
#import "MLTouchCore.h"

@class StreamViewMac;
@class HIDSupport;

NS_ASSUME_NONNULL_BEGIN

@interface MLTouchRuntime : NSObject

- (instancetype)initWithStreamView:(StreamViewMac *)streamView
                               hid:(HIDSupport *)hid
                          hostUUID:(NSString *)hostUUID;

/// The picture's pixel size and whether it is stretched over the view. Call when either changes.
- (void)setVideoWidth:(int)width height:(int)height stretch:(BOOL)stretch;
- (void)setVideoWidth:(int)width height:(int)height;
- (void)setStretch:(BOOL)stretch;

/// Re-reads the setting and the host's feature flags. Call at stream start, when the connection is up, and
/// when the setting changes.
- (void)refresh;

/// Lets go of every live touch on the host (input paused, stream stopping, mode switch).
- (void)cancelLiveTouches;

/// Removes the recognizer and the overlay. The runtime is dead afterwards.
- (void)tearDown;

/// Asked at the start of every touch: may the stream take it now? (Not while it stops, reconnects, shows its menu,
/// or has no visible window.) A touch it refuses is not sent at all, and neither are its moves and its end, so the
/// host never sees half of a touch. Defaults to YES.
@property (nonatomic, copy, nullable) BOOL (^touchAllowedHandler)(void);
/// Called when a touch (or a touch-made click the recognizer did not see) lands on a stream window that is not the key
/// window: the stream's own "click to engage" step (make the window key, the stream view first responder).
@property (nonatomic, copy, nullable) void (^touchEngageHandler)(void);

/// Five touches held still open the Control Center (the one the game controller opens): called on the main queue
/// when the hold completes. The runtime has already told the host the touches are void (CANCEL_ALL).
@property (nonatomic, copy, nullable) void (^openControlCenterHandler)(void);

/// The first time a touch screen is in play: five dots and "hold five fingers to open Control Center", for a few
/// seconds. Remembered in the defaults key MLTouchFiveFingerHintShown. Does not take or block touches.
- (void)showFiveFingerHintIfNeeded;

/// Called when the screens change or the window moves to another screen (the control ball lays itself out again).
@property (nonatomic, copy, nullable) void (^screenChangedHandler)(void);

@property (nonatomic, readonly, nullable) NSWindow *streamWindow;

/// The mode that is really running now.
@property (nonatomic, readonly) MLTouchInputMode effectiveMode;
@property (nonatomic, readonly) BOOL installed;

/// For StreamViewMac's mouse overrides: should this mouse event be kept from the host because it is the
/// system's emulation of a touch? Also writes the line into the touch log. Main thread.
- (BOOL)shouldDropMouseEvent:(NSEvent *)event kind:(MLTouchGateMouseKind)kind;
/// Suppresses a GCMouse button pair only after a direct-touch begin was observed in the same frame window.
- (BOOL)shouldDropGCMouseButton:(NSInteger)button pressed:(BOOL)pressed time:(NSTimeInterval)time;

/// Whether a stream view subview is part of the picture (the video views), as opposed to a control on top of it.
+ (BOOL)isHostContentView:(nullable NSView *)view streamView:(NSView *)streamView;

/// Does any connected screen report multi-touch (a touchscreen Mac, or a Sidecar iPad)? NO before macOS 27.
+ (BOOL)anyScreenHasTouch;

@end

/// The os_log used by everything touch: subsystem std.skyhua.MoonlightMacEnhanced, category touch.
FOUNDATION_EXPORT os_log_t MLTouchLog(void);

NS_ASSUME_NONNULL_END
