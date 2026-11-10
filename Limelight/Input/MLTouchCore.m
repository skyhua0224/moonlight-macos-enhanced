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

