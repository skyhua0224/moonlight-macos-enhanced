//
//  MLTouchCore.m
//  Moonlight for macOS
//

#import "MLTouchCore.h"
#import "Limelight.h"

// The wire values above must stay equal to the library's.
_Static_assert(MLTouchWireHover == LI_TOUCH_EVENT_HOVER, "touch event HOVER");
_Static_assert(MLTouchWireDown == LI_TOUCH_EVENT_DOWN, "touch event DOWN");
_Static_assert(MLTouchWireUp == LI_TOUCH_EVENT_UP, "touch event UP");
_Static_assert(MLTouchWireMove == LI_TOUCH_EVENT_MOVE, "touch event MOVE");
_Static_assert(MLTouchWireCancel == LI_TOUCH_EVENT_CANCEL, "touch event CANCEL");
_Static_assert(MLTouchWireCancelAll == LI_TOUCH_EVENT_CANCEL_ALL, "touch event CANCEL_ALL");
_Static_assert(MLTouchEmuButtonLeft == BUTTON_LEFT, "left button");
_Static_assert(MLTouchEmuButtonRight == BUTTON_RIGHT, "right button");

#pragma mark - Mode selection

BOOL MLTouchHostSupportsNative(uint32_t hostFeatureFlags) {
    return (hostFeatureFlags & LI_FF_PEN_TOUCH_EVENTS) != 0;
}

MLTouchInputMode MLTouchModeFromStoredValue(NSInteger value) {
    switch (value) {
        case MLTouchInputModeTrackpad: return MLTouchInputModeTrackpad;
        case MLTouchInputModeDirect: return MLTouchInputModeDirect;
        default: return MLTouchInputModeNative;
    }
}

MLTouchInputMode MLTouchEffectiveMode(MLTouchInputMode preferred, uint32_t hostFeatureFlags) {
    if (preferred == MLTouchInputModeNative && !MLTouchHostSupportsNative(hostFeatureFlags)) {
        // An old Sunshine or GFE: touch as a touchpad, the way Moonlight on iOS does it. LiSendMousePositionEvent
        // is unreliable in games, so absolute tapping stays something the user asks for.
        return MLTouchInputModeTrackpad;
    }
    return MLTouchModeFromStoredValue(preferred);
}

NSString *MLTouchModeLogName(MLTouchInputMode mode) {
    switch (mode) {
        case MLTouchInputModeNative: return @"native";
        case MLTouchInputModeTrackpad: return @"trackpad";
        case MLTouchInputModeDirect: return @"direct";
    }
    return @"unknown";
}

#pragma mark - Coordinates

CGRect MLTouchVideoRect(CGSize viewSize, CGSize videoSize, BOOL stretch) {
    CGRect full = CGRectMake(0, 0, MAX(viewSize.width, 0), MAX(viewSize.height, 0));
    if (stretch || viewSize.width <= 0 || viewSize.height <= 0 || videoSize.width <= 0 || videoSize.height <= 0 ||
        !isfinite(viewSize.width) || !isfinite(viewSize.height) ||
        !isfinite(videoSize.width) || !isfinite(videoSize.height)) {
        return full;
    }
    CGFloat scale = MIN(viewSize.width / videoSize.width, viewSize.height / videoSize.height);
    CGFloat w = videoSize.width * scale;
    CGFloat h = videoSize.height * scale;
    return CGRectMake((viewSize.width - w) / 2.0, (viewSize.height - h) / 2.0, w, h);
}

BOOL MLTouchNormalize(CGPoint viewPoint, CGRect videoRect, BOOL clamp, CGPoint *normalized) {
    if (videoRect.size.width <= 0 || videoRect.size.height <= 0 || !isfinite(viewPoint.x) || !isfinite(viewPoint.y)) {
        if (normalized != NULL) *normalized = CGPointZero;
        return NO;
    }
    CGFloat x = (viewPoint.x - videoRect.origin.x) / videoRect.size.width;
    CGFloat y = 1.0 - (viewPoint.y - videoRect.origin.y) / videoRect.size.height;
    BOOL inside = x >= 0.0 && x <= 1.0 && y >= 0.0 && y <= 1.0;
    if (clamp) {
        x = MIN(MAX(x, 0.0), 1.0);
        y = MIN(MAX(y, 0.0), 1.0);
    }
    if (normalized != NULL) *normalized = CGPointMake(x, y);
    return inside;
}

#pragma mark - Samples

@implementation MLTouchSample
+ (instancetype)sampleWithIdentity:(id<NSObject, NSCopying>)identity
                             phase:(MLTouchPhase)phase
                             point:(CGPoint)point
                         timestamp:(NSTimeInterval)timestamp {
    MLTouchSample *sample = [[MLTouchSample alloc] init];
    sample.identity = identity;
    sample.phase = phase;
    sample.point = point;
    sample.timestamp = timestamp;
    return sample;
}
@end

#pragma mark - Pointer ids

@implementation MLTouchPointerTable {
    NSUInteger _capacity;
    NSMutableDictionary<id, NSNumber *> *_idByIdentity;
    BOOL *_used;
}

- (instancetype)init {
    return [self initWithCapacity:10];
}

- (instancetype)initWithCapacity:(NSUInteger)capacity {
    self = [super init];
    if (self) {
        _capacity = MAX(capacity, 1);
        _idByIdentity = [NSMutableDictionary dictionary];
        _used = calloc(_capacity, sizeof(BOOL));
    }
    return self;
}

- (void)dealloc {
    free(_used);
}

- (NSUInteger)capacity { return _capacity; }
- (NSUInteger)activeCount { return _idByIdentity.count; }

- (NSInteger)beginIdentity:(id<NSObject, NSCopying>)identity {
    NSNumber *existing = _idByIdentity[identity];
    if (existing != nil) return existing.integerValue;
    // The lowest free id: five fingers are ids 0..4, and an id comes back as soon as its touch is released
    // (the host matches a pointer by id only while its slot is live, so a released id is free for the host too).
    for (NSUInteger candidate = 0; candidate < _capacity; candidate++) {
        if (!_used[candidate]) {
            _used[candidate] = YES;
            _idByIdentity[identity] = @(candidate);
            return (NSInteger)candidate;
        }
    }
    return -1;
}

- (NSInteger)pointerIdForIdentity:(id<NSObject, NSCopying>)identity {
    NSNumber *value = _idByIdentity[identity];
    return value != nil ? value.integerValue : -1;
}

- (NSInteger)endIdentity:(id<NSObject, NSCopying>)identity {
    NSNumber *value = _idByIdentity[identity];
    if (value == nil) return -1;
    _used[value.unsignedIntegerValue] = NO;
    [_idByIdentity removeObjectForKey:identity];
    return value.integerValue;
}

- (NSArray<NSNumber *> *)activePointerIds {
    return [[_idByIdentity allValues] sortedArrayUsingSelector:@selector(compare:)];
}

- (NSArray *)activeIdentities {
    return _idByIdentity.allKeys;
}

- (void)reset {
    [_idByIdentity removeAllObjects];
    memset(_used, 0, _capacity * sizeof(BOOL));
}
@end

#pragma mark - Native forwarder

@implementation MLTouchForwarder {
    MLTouchPointerTable *_table;
    NSMutableSet<id> *_ignored;
    NSUInteger _forwardedEventCount;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _table = [[MLTouchPointerTable alloc] initWithCapacity:10];
        _ignored = [NSMutableSet set];
    }
    return self;
}

- (NSUInteger)activeCount { return _table.activeCount; }
- (NSUInteger)forwardedEventCount { return _forwardedEventCount; }
- (BOOL)isForwarding:(id<NSObject, NSCopying>)identity { return [_table pointerIdForIdentity:identity] >= 0; }
- (NSInteger)pointerIdForIdentity:(id<NSObject, NSCopying>)identity { return [_table pointerIdForIdentity:identity]; }
- (NSArray<NSNumber *> *)activePointerIds { return [_table activePointerIds]; }

- (void)emit:(MLTouchWireEvent)event pointerId:(NSInteger)pointerId point:(CGPoint)point {
    _forwardedEventCount += 1;
    if (self.sink != nil) {
        self.sink(event, (uint32_t)pointerId, (float)point.x, (float)point.y);
    }
}

- (void)processSamples:(NSArray<MLTouchSample *> *)samples {
    CGRect rect = MLTouchVideoRect(self.viewSize, self.videoSize, self.stretch);
    for (MLTouchSample *sample in samples) {
        id identity = sample.identity;
        CGPoint normalized = CGPointZero;
        switch (sample.phase) {
            case MLTouchPhaseBegan:
            case MLTouchPhaseMoved:
            case MLTouchPhaseStationary: {
                if ([_ignored containsObject:identity]) break;
                NSInteger pointerId = [_table pointerIdForIdentity:identity];
                if (pointerId < 0) {
                    // New, or seen first in the middle of its life: a touch down in the black bars or
                    // with no free slot is never sent.
                    BOOL inside = MLTouchNormalize(sample.point, rect, NO, &normalized);
                    pointerId = inside ? [_table beginIdentity:identity] : -1;
                    if (pointerId < 0) {
                        [_ignored addObject:identity];
                        break;
                    }
                    [self emit:MLTouchWireDown pointerId:pointerId point:normalized];
                    break;
                }
                if (sample.phase == MLTouchPhaseStationary) break;
                MLTouchNormalize(sample.point, rect, YES, &normalized);
                [self emit:MLTouchWireMove pointerId:pointerId point:normalized];
                break;
            }
            case MLTouchPhaseEnded: {
                if ([_ignored containsObject:identity]) {
                    [_ignored removeObject:identity];
                    break;
                }
                NSInteger pointerId = [_table endIdentity:identity];
                if (pointerId < 0) break;
                MLTouchNormalize(sample.point, rect, YES, &normalized);
                [self emit:MLTouchWireUp pointerId:pointerId point:normalized];
                break;
            }
            case MLTouchPhaseCancelled: {
                if ([_ignored containsObject:identity]) {
                    [_ignored removeObject:identity];
                    break;
                }
                NSInteger pointerId = [_table endIdentity:identity];
                if (pointerId < 0) break;
                [self emit:MLTouchWireCancel pointerId:pointerId point:CGPointZero];
                break;
            }
        }
    }
}

- (void)cancelAll {
    if (_table.activeCount > 0) {
        [self emit:MLTouchWireCancelAll pointerId:0 point:CGPointZero];
    }
    [_table reset];
    [_ignored removeAllObjects];
}

- (void)cancelAllAndIgnoreCurrentTouches {
    NSArray *current = [_table activeIdentities];
    if (_table.activeCount > 0) {
        [self emit:MLTouchWireCancelAll pointerId:0 point:CGPointZero];
    }
    [_table reset];
    // Their later moves would otherwise look like touches first seen mid-life and begin again on the host.
    [_ignored addObjectsFromArray:current];
}
@end

#pragma mark - Five-finger hold

@implementation MLTouchFiveFingerHold {
    NSMutableDictionary<id, NSValue *> *_start;
    NSMutableDictionary<id, NSValue *> *_last;
    MLTouchHoldState _state;
    NSTimeInterval _armedAt;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _start = [NSMutableDictionary dictionary];
        _last = [NSMutableDictionary dictionary];
        _requiredTouches = 5;
        _holdDuration = 0.8;
        _maxMovement = 20.0;
    }
    return self;
}

- (MLTouchHoldState)state { return _state; }
- (NSUInteger)downCount { return _last.count; }

- (CGPoint)centroid {
    if (_last.count == 0) return CGPointZero;
    CGFloat x = 0, y = 0;
    for (NSValue *v in _last.allValues) { CGPoint p = v.pointValue; x += p.x; y += p.y; }
    return CGPointMake(x / _last.count, y / _last.count);
}

- (double)progressAtTime:(NSTimeInterval)now {
    if (_state != MLTouchHoldStateArming || self.holdDuration <= 0) return 0;
    return MIN(MAX((now - _armedAt) / self.holdDuration, 0.0), 1.0);
}

- (void)setState:(MLTouchHoldState)state {
    if (_state == state) return;
    _state = state;
    if (self.onStateChange != nil) self.onStateChange(state);
}

- (BOOL)anyMovedTooFar {
    for (id key in _last) {
        CGPoint a = _start[key].pointValue, b = _last[key].pointValue;
        if (hypot(a.x - b.x, a.y - b.y) > self.maxMovement) return YES;
    }
    return NO;
}

- (void)processSamples:(NSArray<MLTouchSample *> *)samples {
    for (MLTouchSample *sample in samples) {
        id identity = sample.identity;
        NSValue *point = [NSValue valueWithPoint:NSPointFromCGPoint(sample.point)];
        switch (sample.phase) {
            case MLTouchPhaseBegan:
                _start[identity] = point;
                _last[identity] = point;
                if (_last.count > self.requiredTouches) {
                    if (_state == MLTouchHoldStateArming || _state == MLTouchHoldStateIdle) self.state = MLTouchHoldStateFailed;
                } else if (_last.count == self.requiredTouches && _state == MLTouchHoldStateIdle) {
                    _armedAt = sample.timestamp;
                    self.state = [self anyMovedTooFar] ? MLTouchHoldStateFailed : MLTouchHoldStateArming;
                }
                break;
            case MLTouchPhaseMoved:
            case MLTouchPhaseStationary:
                if (_last[identity] == nil) break;
                _last[identity] = point;
                if (_state == MLTouchHoldStateArming && [self anyMovedTooFar]) self.state = MLTouchHoldStateFailed;
                break;
            case MLTouchPhaseEnded:
            case MLTouchPhaseCancelled:
                if (_last[identity] == nil) break;
                [_last removeObjectForKey:identity];
                [_start removeObjectForKey:identity];
                if (_state == MLTouchHoldStateArming) self.state = MLTouchHoldStateFailed;
                if (_last.count == 0) self.state = MLTouchHoldStateIdle;
                break;
        }
    }
}

- (void)pollAtTime:(NSTimeInterval)now {
    if (_state != MLTouchHoldStateArming) return;
    if (now - _armedAt >= self.holdDuration - 1e-6) {
        self.state = MLTouchHoldStateFired;
        if (self.onTrigger != nil) self.onTrigger();
    }
}

- (void)reset {
    [_start removeAllObjects];
    [_last removeAllObjects];
    self.state = MLTouchHoldStateIdle;
}
@end

#pragma mark - Fallback pointer emulator

@interface MLTouchTrack : NSObject
@property (nonatomic, strong) id identity;
@property (nonatomic) CGPoint start;
@property (nonatomic) CGPoint last;
@property (nonatomic) NSTimeInterval startTime;
@property (nonatomic) CGFloat maxDisplacement;
@property (nonatomic) NSUInteger order;
@end
@implementation MLTouchTrack
@end

@implementation MLTouchPointerEmulator {
    NSMutableDictionary<id, MLTouchTrack *> *_tracks;
    NSUInteger _orderCounter;
    BOOL _leftDown;
    BOOL _longPressFired;
    BOOL _multi;              // two or more fingers were down in this session
    BOOL _twoHandled;         // the session's right click was decided
    BOOL _twoScrolled;
    NSTimeInterval _twoStartTime;
    CGFloat _twoMaxDisplacement;
    CGPoint _centroid;
    CGFloat _centroidTravel;
    CGPoint _twoLastCentroid;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _tracks = [NSMutableDictionary dictionary];
        _mode = MLTouchInputModeTrackpad;
        _tapMaxDuration = 0.25;
        _longPressDuration = 0.45;
        _twoFingerTapMaxDuration = 0.35;
        _slop = 8.0;
    }
    return self;
}

- (BOOL)leftButtonDown { return _leftDown; }
- (NSUInteger)activeCount { return _tracks.count; }

- (void)send:(MLTouchEmuKind)kind a:(float)a b:(float)b button:(int)button pressed:(BOOL)pressed {
    if (self.sink == nil) return;
    MLTouchEmuEvent event = { kind, a, b, button, pressed };
    self.sink(event);
}

- (void)sendButton:(int)button pressed:(BOOL)pressed {
    [self send:MLTouchEmuKindButton a:0 b:0 button:button pressed:pressed];
}

- (void)sendAbsoluteAtViewPoint:(CGPoint)point {
    CGRect rect = MLTouchVideoRect(self.viewSize, self.videoSize, self.stretch);
    CGPoint normalized = CGPointZero;
    MLTouchNormalize(point, rect, YES, &normalized);
    [self send:MLTouchEmuKindMoveAbsolute a:normalized.x b:normalized.y button:0 pressed:NO];
}

- (void)releaseLeftIfDown {
    if (_leftDown) {
        _leftDown = NO;
        [self sendButton:MLTouchEmuButtonLeft pressed:NO];
    }
}

static CGFloat MLDistance(CGPoint a, CGPoint b) {
    return hypot(a.x - b.x, a.y - b.y);
}

/// The two earliest fingers of the session, in the order they landed.
- (NSArray<MLTouchTrack *> *)firstTwoTracks {
    NSArray *sorted = [_tracks.allValues sortedArrayUsingComparator:^NSComparisonResult(MLTouchTrack *a, MLTouchTrack *b) {
        return a.order < b.order ? NSOrderedAscending : (a.order > b.order ? NSOrderedDescending : NSOrderedSame);
    }];
    return sorted.count > 2 ? [sorted subarrayWithRange:NSMakeRange(0, 2)] : sorted;
}

