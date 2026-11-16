//
//  MLTouchCore.h
//  Moonlight for macOS
//
//  Direct multi-touch (touchscreen Mac, Sidecar iPad) core: coordinate mapping, pointer id
//  lifecycle, the native forwarder (LiSendTouchEvent wire events), the fallback pointer
//  emulator (touchpad mode, direct tap mode) and the mouse-emulation gate.
//
//  Foundation and CoreGraphics only, so the whole core runs in the stand-alone tests
//  (tests/touch). Nothing here talks to AppKit or to the host.
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Mode selection

/// The stored values of the 触控方式 setting. The order is persisted: append only.
typedef NS_ENUM(NSInteger, MLTouchInputMode) {
    MLTouchInputModeNative = 0,   // 原生多点触控: LiSendTouchEvent, real multi-touch on the host
    MLTouchInputModeTrackpad = 1, // 触控板模式: relative pointer, tap = click
    MLTouchInputModeDirect = 2,   // 直接点按: absolute pointer under the finger
};

/// What really runs: the preference, unless it is native and the host cannot take touch events.
/// hostFeatureFlags is LiGetHostFeatureFlags(); LI_FF_PEN_TOUCH_EVENTS (0x01) gates LiSendTouchEvent.
FOUNDATION_EXPORT MLTouchInputMode MLTouchEffectiveMode(MLTouchInputMode preferred, uint32_t hostFeatureFlags);
FOUNDATION_EXPORT BOOL MLTouchHostSupportsNative(uint32_t hostFeatureFlags);
/// Out-of-range stored values fall back to native.
FOUNDATION_EXPORT MLTouchInputMode MLTouchModeFromStoredValue(NSInteger value);
FOUNDATION_EXPORT NSString *MLTouchModeLogName(MLTouchInputMode mode);

#pragma mark - Coordinates

/// The rectangle the picture occupies inside the view, in view points with AppKit's bottom-left
/// origin. Aspect fit (centered, letterbox or pillarbox) unless stretch is set or a size is unknown.
FOUNDATION_EXPORT CGRect MLTouchVideoRect(CGSize viewSize, CGSize videoSize, BOOL stretch);

/// Maps a view point (bottom-left origin) to the 0..1 top-left-origin coordinates LiSendTouchEvent
/// wants, relative to the picture. Returns whether the point lies on the picture. With clamp the
/// output is always pulled into 0..1.
FOUNDATION_EXPORT BOOL MLTouchNormalize(CGPoint viewPoint, CGRect videoRect, BOOL clamp, CGPoint *normalized);

#pragma mark - Samples

typedef NS_ENUM(NSInteger, MLTouchPhase) {
    MLTouchPhaseBegan = 0,
    MLTouchPhaseMoved,
    MLTouchPhaseStationary,
    MLTouchPhaseEnded,
    MLTouchPhaseCancelled,
};

@interface MLTouchSample : NSObject
/// NSTouch.identity: unique for the life of a touch, copyable, compared with isEqual:.
@property (nonatomic, strong) id<NSObject, NSCopying> identity;
@property (nonatomic) MLTouchPhase phase;
/// In the stream view's coordinates (bottom-left origin).
@property (nonatomic) CGPoint point;
@property (nonatomic) NSTimeInterval timestamp;
+ (instancetype)sampleWithIdentity:(id<NSObject, NSCopying>)identity
                             phase:(MLTouchPhase)phase
                             point:(CGPoint)point
                         timestamp:(NSTimeInterval)timestamp;
@end

#pragma mark - Pointer ids

/// Maps touch identities to the stable small integers sent as pointerId: the lowest free one (five fingers are
/// 0..4), freed when the touch ends or is cancelled. The host keeps ten touch slots.
@interface MLTouchPointerTable : NSObject
@property (nonatomic, readonly) NSUInteger capacity;
@property (nonatomic, readonly) NSUInteger activeCount;
- (instancetype)initWithCapacity:(NSUInteger)capacity NS_DESIGNATED_INITIALIZER;
- (instancetype)init;
/// A new id for a touch that began, or -1 when every slot is taken. Asking again for the same
/// identity returns the id it already has.
- (NSInteger)beginIdentity:(id<NSObject, NSCopying>)identity;
/// The id of a live touch, or -1.
- (NSInteger)pointerIdForIdentity:(id<NSObject, NSCopying>)identity;
/// Frees the id of an ended or cancelled touch. Returns it, or -1 when the identity was unknown.
- (NSInteger)endIdentity:(id<NSObject, NSCopying>)identity;
- (NSArray<NSNumber *> *)activePointerIds;
- (NSArray *)activeIdentities;
- (void)reset;
@end

#pragma mark - Native forwarder

/// Wire event types, equal to LI_TOUCH_EVENT_* in moonlight-common-c Limelight.h (checked at compile
/// time where Limelight.h is included).
typedef NS_ENUM(uint8_t, MLTouchWireEvent) {
    MLTouchWireHover = 0x00,
    MLTouchWireDown = 0x01,
    MLTouchWireUp = 0x02,
    MLTouchWireMove = 0x03,
    MLTouchWireCancel = 0x04,
    MLTouchWireCancelAll = 0x07,
};

typedef void (^MLTouchWireSink)(MLTouchWireEvent event, uint32_t pointerId, float x, float y);

/// Turns raw touch samples into LiSendTouchEvent calls: stable pointer ids, picture-relative
/// coordinates, letterbox handling. A touch that begins in the black bars is not sent at all, and
/// stays ignored until it ends. A touch that drifts off the picture while forwarded is clamped.
@interface MLTouchForwarder : NSObject
@property (nonatomic) CGSize viewSize;
@property (nonatomic) CGSize videoSize;
@property (nonatomic) BOOL stretch;
@property (nonatomic, copy, nullable) MLTouchWireSink sink;
@property (nonatomic, readonly) NSUInteger activeCount;
@property (nonatomic, readonly) NSUInteger forwardedEventCount;
- (void)processSamples:(NSArray<MLTouchSample *> *)samples;
/// CANCEL_ALL for everything live on the host, and the touches that are down now are not sent again: their moves and
/// ends are dropped until each one ends (a gesture of the app took them over). Touches that begin later are sent.
- (void)cancelAllAndIgnoreCurrentTouches;
/// Whether the touch is being sent to the host (false for ignored touches).
- (BOOL)isForwarding:(id<NSObject, NSCopying>)identity;
- (NSInteger)pointerIdForIdentity:(id<NSObject, NSCopying>)identity;
- (NSArray<NSNumber *> *)activePointerIds;
/// Cancels every live touch on the host (focus loss, mode switch, stream end).
- (void)cancelAll;
@end

#pragma mark - Five-finger hold

typedef NS_ENUM(NSInteger, MLTouchHoldState) {
    MLTouchHoldStateIdle = 0,   // fewer than the required touches are down
    MLTouchHoldStateArming,     // exactly the required touches are down and still: the hold is running
    MLTouchHoldStateFired,      // it opened the Control Center; nothing more until every finger is up
    MLTouchHoldStateFailed,     // a finger moved, lifted or one too many landed; nothing more until every finger is up
};

/// Five touches held still for holdDuration open the Control Center (the one the game controller opens).
///
/// The hold starts when the fifth touch lands. It fails when a touch moves more than maxMovement points from where it
/// began, when any touch lifts, or when a sixth lands (four fingers never arm it), and a failed or finished hold is not
/// armed again until every finger is up. Time comes from the samples and -pollAtTime:, not from a clock.
@interface MLTouchFiveFingerHold : NSObject
@property (nonatomic) NSUInteger requiredTouches;       // default 5
@property (nonatomic) NSTimeInterval holdDuration;      // default 0.8 s
@property (nonatomic) CGFloat maxMovement;              // default 20 points
@property (nonatomic, readonly) MLTouchHoldState state;
@property (nonatomic, readonly) NSUInteger downCount;
/// 0..1 while arming, else 0.
- (double)progressAtTime:(NSTimeInterval)now;
/// Centre of the touches that are down.
@property (nonatomic, readonly) CGPoint centroid;
/// Called when the state changes (arming begins, fails, fires, resets), on whatever thread feeds it.
@property (nonatomic, copy, nullable) void (^onStateChange)(MLTouchHoldState state);
@property (nonatomic, copy, nullable) void (^onTrigger)(void);
- (void)processSamples:(NSArray<MLTouchSample *> *)samples;
- (void)pollAtTime:(NSTimeInterval)now;
- (void)reset;
@end

#pragma mark - Fallback pointer emulator

typedef NS_ENUM(NSInteger, MLTouchEmuKind) {
    MLTouchEmuKindMoveRelative,  // a, b = delta in view points
    MLTouchEmuKindMoveAbsolute,  // a, b = 0..1 on the picture, top-left origin
    MLTouchEmuKindButton,        // button, pressed
    MLTouchEmuKindScroll,        // a = vertical delta in view points, fingers up positive
};

typedef NS_ENUM(int, MLTouchEmuButton) {
    MLTouchEmuButtonLeft = 1,
    MLTouchEmuButtonRight = 3,
};

typedef struct {
    MLTouchEmuKind kind;
    float a;
    float b;
    int button;
    BOOL pressed;
} MLTouchEmuEvent;

typedef void (^MLTouchEmuSink)(MLTouchEmuEvent event);

/// 触控板模式 and 直接点按 on top of the same samples.
///
/// Trackpad: one finger moves the pointer by deltas; a short still tap clicks; two fingers scroll,
/// a short still two-finger tap right-clicks; holding one finger still for the long-press time
/// presses the left button, so the next movement drags, and lifting releases it.
/// Direct: the pointer jumps under the finger and the left button is pressed while it is down (tap =
/// click, drag = drag); a second finger releases the button and acts as the two-finger gestures.
///
/// Time comes from the samples and from -pollAtTime:, never from a clock, so the sequences are
/// testable.
@interface MLTouchPointerEmulator : NSObject
@property (nonatomic) MLTouchInputMode mode; // Trackpad or Direct
@property (nonatomic) CGSize viewSize;
@property (nonatomic) CGSize videoSize;
@property (nonatomic) BOOL stretch;
@property (nonatomic, copy, nullable) MLTouchEmuSink sink;
@property (nonatomic) NSTimeInterval tapMaxDuration;      // default 0.25 s
@property (nonatomic) NSTimeInterval longPressDuration;   // default 0.45 s
@property (nonatomic) NSTimeInterval twoFingerTapMaxDuration; // default 0.35 s
@property (nonatomic) CGFloat slop;                       // default 8 points
@property (nonatomic, readonly) BOOL leftButtonDown;
@property (nonatomic, readonly) NSUInteger activeCount;
- (void)processSamples:(NSArray<MLTouchSample *> *)samples;
/// Lets time-based gestures (long press) fire. Call a few times a second while a touch is down.
- (void)pollAtTime:(NSTimeInterval)now;
/// Releases a held button and forgets every touch.
- (void)cancelAll;
@end

#pragma mark - Mouse emulation gate

typedef NS_ENUM(NSInteger, MLTouchGateVerdict) {
    MLTouchGateVerdictPass = 0,
    MLTouchGateVerdictDropSubtype,    // the event itself says it came from a touch
    MLTouchGateVerdictDropCorrelated, // a touch was on the picture at that time and place
    MLTouchGateVerdictDropSequence,   // the rest of a click that was dropped at its start
};

/// Whether a mouse event's touch subtype may be believed when the gate has seen no touch at all. True only on a Mac that
/// has a touch screen (or a Sidecar touch display) while the stream window is not key: the touch that activates it never
/// reaches the recognizer. A Mac without one (every MacBook trackpad) never believes it: its clicks are real.
static inline BOOL MLTouchSubtypeBelievedWithoutTouch(BOOL anyScreenHasTouch, BOOL windowIsKey) {
    return anyScreenHasTouch && !windowIsKey;
}

/// Keeps the system's touch-to-mouse emulation from also clicking on the host while real touches
/// are being forwarded. The recognizer claims the touches; this is the second line, for events that
/// still arrive: it drops a mouse event whose subtype marks it as touch-made, or that lands within
/// nearRadius points of a touch that is down or ended within window seconds, and it drops the whole
/// click (up and drags) once its down was dropped, so the host never sees half of one.
@interface MLTouchMouseGate : NSObject
@property (nonatomic) BOOL enabled;
@property (nonatomic) NSTimeInterval window;   // default 0.35 s
@property (nonatomic) CGFloat nearRadius;      // default 48 points
@property (nonatomic) NSTimeInterval subtypeWindow;  // default 0.5 s: how long after a real touch the subtype is believed
/// Believe the subtype with no touch history. Only for the one case where a touch-made click can come from a touch the
/// recognizer never saw: the touch that activates an inactive window on a Mac that has a touch screen
/// (MLTouchSubtypeBelievedWithoutTouch). A trackpad press and a tap-to-click carry the same "touch" subtype (on a
/// MacBook every trackpad press is subtype-touch=1), so the subtype by itself must never drop a click.
@property (nonatomic) BOOL subtypeAlwaysDrops;
/// Suppresses only the GCMouse press/release pair that follows observed direct-touch evidence in the same frame.
/// A physical mouse or trackpad event without that evidence always passes.
- (BOOL)shouldDropGCMouseButton:(NSInteger)button pressed:(BOOL)pressed time:(NSTimeInterval)time;
/// Records the evidence used by -shouldDropGCMouseButton:pressed:time:.
- (void)noteDirectTouchBeganAtTime:(NSTimeInterval)time;
@property (nonatomic) NSTimeInterval activeTimeout;  // default 1.5 s: a touch that never closed stops counting
@property (nonatomic, readonly) NSUInteger droppedCount;
@property (nonatomic, readonly) NSUInteger passedNearTouchCount;
@property (nonatomic, readonly) NSUInteger passedClickCount;       // button downs that went on to the host
@property (nonatomic, readonly) NSUInteger droppedSubtypeCount;
@property (nonatomic, readonly) NSUInteger droppedCorrelatedCount;
@property (nonatomic, readonly) NSUInteger droppedSequenceCount;
- (void)noteTouchPoint:(CGPoint)viewPoint active:(BOOL)active time:(NSTimeInterval)time;
- (void)noteAllTouchesUpAtTime:(NSTimeInterval)time;
/// button: 0 left, 1 right, 2.. other. kind: down / dragged-or-moved / up.
typedef NS_ENUM(NSInteger, MLTouchGateMouseKind) { MLTouchGateMouseDown, MLTouchGateMouseMove, MLTouchGateMouseUp };
- (MLTouchGateVerdict)verdictForMouseKind:(MLTouchGateMouseKind)kind
                                   button:(NSInteger)button
                                    point:(CGPoint)viewPoint
                                     time:(NSTimeInterval)time
                             touchSubtype:(BOOL)touchSubtype
                            ageSinceTouch:(NSTimeInterval *_Nullable)ageSinceTouch;
- (void)reset;
@end

NS_ASSUME_NONNULL_END
