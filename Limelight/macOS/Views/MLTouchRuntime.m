//
//  MLTouchRuntime.m
//  Moonlight for macOS
//

#import "MLTouchRuntime.h"
#import "MLDirectTouchRecognizer.h"
#import "StreamViewMac.h"
#import "HIDSupport.h"
#import "MoonlightEnhanced-Swift.h"
#import "Logger.h"
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>

os_log_t MLTouchLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("std.skyhua.MoonlightMacEnhanced", "touch");
    });
    return log;
}

static NSString *const MLTouchDebugDefaultsKey = @"MLTouchDebug";

#pragma mark - Debug overlay

typedef NS_ENUM(NSInteger, MLTouchDotState) {
    MLTouchDotForwarded = 0,   // sent to the host as a touch
    MLTouchDotEmulated,        // turned into mouse input by the fallback mode
    MLTouchDotNotForwarded,    // landed on a control on top of the picture, or outside the picture
};

@interface MLTouchDebugOverlayView : NSView
@property (nonatomic, copy) NSArray<NSString *> *hudLines;
- (void)setDotAtPoint:(NSPoint)point label:(NSString *)label state:(MLTouchDotState)state forKey:(id)key;
- (void)removeDotForKey:(id)key;
- (void)removeStaleDotsOlderThan:(NSTimeInterval)seconds;
- (void)removeAllDots;
@end

@implementation MLTouchDebugOverlayView {
    NSMutableDictionary<id, NSDictionary *> *_dots;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _dots = [NSMutableDictionary dictionary];
        _hudLines = @[];
        self.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    }
    return self;
}

// Never takes a touch or a click: the picture underneath keeps working while the overlay shows.
- (NSView *)hitTest:(NSPoint)point { return nil; }
- (BOOL)isOpaque { return NO; }

- (void)setHudLines:(NSArray<NSString *> *)hudLines {
    if ([_hudLines isEqualToArray:hudLines]) return;
    _hudLines = [hudLines copy];
    self.needsDisplay = YES;
}

- (void)setDotAtPoint:(NSPoint)point label:(NSString *)label state:(MLTouchDotState)state forKey:(id)key {
    _dots[key] = @{ @"x": @(point.x), @"y": @(point.y), @"label": label, @"state": @(state),
                    @"t": @(NSProcessInfo.processInfo.systemUptime) };
    self.needsDisplay = YES;
}

- (void)removeDotForKey:(id)key {
    if (_dots[key] != nil) {
        [_dots removeObjectForKey:key];
        self.needsDisplay = YES;
    }
}

- (void)removeStaleDotsOlderThan:(NSTimeInterval)seconds {
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    for (id key in _dots.allKeys) {
        if (now - [_dots[key][@"t"] doubleValue] > seconds) [_dots removeObjectForKey:key];
    }
    self.needsDisplay = YES;
}

- (void)removeAllDots {
    [_dots removeAllObjects];
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    NSDictionary *textAttrs = @{
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:13 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: NSColor.whiteColor,
    };
    for (NSDictionary *dot in _dots.allValues) {
        NSPoint p = NSMakePoint([dot[@"x"] doubleValue], [dot[@"y"] doubleValue]);
        NSColor *color;
        switch ((MLTouchDotState)[dot[@"state"] integerValue]) {
            case MLTouchDotForwarded: color = [NSColor colorWithSRGBRed:0.2 green:0.9 blue:0.4 alpha:1]; break;
            case MLTouchDotEmulated: color = [NSColor colorWithSRGBRed:0.3 green:0.6 blue:1.0 alpha:1]; break;
            default: color = [NSColor colorWithSRGBRed:1.0 green:0.35 blue:0.3 alpha:1]; break;
        }
        NSRect circle = NSMakeRect(p.x - 30, p.y - 30, 60, 60);
        NSBezierPath *path = [NSBezierPath bezierPathWithOvalInRect:circle];
        [[color colorWithAlphaComponent:0.28] setFill];
        [path fill];
        [color setStroke];
        path.lineWidth = 3;
        [path stroke];
        NSString *label = dot[@"label"];
        NSSize size = [label sizeWithAttributes:textAttrs];
        NSRect chip = NSMakeRect(p.x - size.width / 2 - 5, p.y + 34, size.width + 10, size.height + 4);
        [[NSColor colorWithWhite:0 alpha:0.7] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:chip xRadius:5 yRadius:5] fill];
        [label drawAtPoint:NSMakePoint(chip.origin.x + 5, chip.origin.y + 2) withAttributes:textAttrs];
    }

    if (_hudLines.count > 0) {
        CGFloat lineHeight = 17, width = 0;
        for (NSString *line in _hudLines) width = MAX(width, [line sizeWithAttributes:textAttrs].width);
        NSRect box = NSMakeRect(12, self.bounds.size.height - 12 - lineHeight * _hudLines.count - 12,
                                width + 20, lineHeight * _hudLines.count + 12);
        [[NSColor colorWithWhite:0 alpha:0.72] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:box xRadius:8 yRadius:8] fill];
        CGFloat y = box.origin.y + box.size.height - 6 - lineHeight;
        for (NSString *line in _hudLines) {
            [line drawAtPoint:NSMakePoint(box.origin.x + 10, y) withAttributes:textAttrs];
            y -= lineHeight;
        }
    }
}
@end


#pragma mark - Hold ring and hint

/// The ring that fills at the centre of five held touches. Never takes a touch.
@interface MLTouchHoldRingView : NSView
- (void)showProgress:(double)progress at:(NSPoint)center;
- (void)hideRing;
@end

@implementation MLTouchHoldRingView {
    CAShapeLayer *_track;
    CAShapeLayer *_arc;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        self.wantsLayer = YES;
        self.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        _track = [CAShapeLayer layer];
        _arc = [CAShapeLayer layer];
        for (CAShapeLayer *l in @[_track, _arc]) {
            l.fillColor = nil;
            l.lineWidth = 7;
            l.lineCap = kCALineCapRound;
            l.hidden = YES;
            [self.layer addSublayer:l];
        }
        _track.strokeColor = [NSColor colorWithWhite:1 alpha:0.28].CGColor;
        _arc.strokeColor = NSColor.controlAccentColor.CGColor;
        _arc.shadowColor = NSColor.blackColor.CGColor;
        _arc.shadowOpacity = 0.4;
        _arc.shadowRadius = 4;
        _arc.shadowOffset = CGSizeZero;
    }
    return self;
}

- (NSView *)hitTest:(NSPoint)point { return nil; }

- (void)showProgress:(double)progress at:(NSPoint)center {
    const CGFloat radius = 46;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    CGPathRef path = CGPathCreateWithEllipseInRect(CGRectMake(center.x - radius, center.y - radius, radius * 2, radius * 2), NULL);
    // Starts at twelve o'clock and fills clockwise: a circle path starts at three o'clock and runs counter-clockwise.
    CGAffineTransform rotate = CGAffineTransformMakeTranslation(center.x, center.y);
    rotate = CGAffineTransformRotate(rotate, M_PI_2);
    rotate = CGAffineTransformScale(rotate, 1, -1);
    rotate = CGAffineTransformTranslate(rotate, -center.x, -center.y);
    CGPathRef arcPath = CGPathCreateCopyByTransformingPath(path, &rotate);
    _track.path = path;
    _arc.path = arcPath;
    CGPathRelease(path);
    CGPathRelease(arcPath);
    _arc.strokeEnd = MIN(MAX(progress, 0.0), 1.0);
    _track.hidden = NO;
    _arc.hidden = NO;
    [CATransaction commit];
}

- (void)hideRing {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _track.hidden = YES;
    _arc.hidden = YES;
    [CATransaction commit];
}
@end

/// The one-time hint: five dots pressing in turn, and one line. Never takes a touch.
@interface MLTouchHintView : NSVisualEffectView
@end

@implementation MLTouchHintView
- (instancetype)initWithText:(NSString *)text {
    self = [super initWithFrame:NSMakeRect(0, 0, 420, 64)];
    if (self) {
        self.material = NSVisualEffectMaterialHUDWindow;
        self.blendingMode = NSVisualEffectBlendingModeWithinWindow;
        self.state = NSVisualEffectStateActive;
        self.wantsLayer = YES;
        self.layer.cornerRadius = 18;
        self.layer.masksToBounds = YES;
        // five dots, a press wave running across them
        for (int i = 0; i < 5; i++) {
            CAShapeLayer *dot = [CAShapeLayer layer];
            dot.frame = CGRectMake(18 + i * 22, 22, 20, 20);
            dot.path = CGPathCreateWithEllipseInRect(CGRectMake(2, 2, 16, 16), NULL);
            dot.fillColor = NSColor.controlAccentColor.CGColor;
            dot.opacity = 0.45;
            CAKeyframeAnimation *press = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
            press.values = @[@0.45, @1.0, @1.0, @0.45];
            press.keyTimes = @[@0.0, @0.18, @0.7, @1.0];
            press.duration = 1.6;
            press.repeatCount = HUGE_VALF;
            press.beginTime = CACurrentMediaTime() + i * 0.12;
            press.timeOffset = 0;
            press.fillMode = kCAFillModeBoth;
            [dot addAnimation:press forKey:@"press"];
            CAKeyframeAnimation *scale = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale"];
            scale.values = @[@1.0, @0.8, @0.8, @1.0];
            scale.keyTimes = press.keyTimes;
            scale.duration = 1.6;
            scale.repeatCount = HUGE_VALF;
            scale.beginTime = press.beginTime;
            scale.fillMode = kCAFillModeBoth;
            [dot addAnimation:scale forKey:@"scale"];
            [self.layer addSublayer:dot];
        }
        NSTextField *label = [NSTextField labelWithString:text];
        label.font = [NSFont systemFontOfSize:15 weight:NSFontWeightMedium];
        label.textColor = NSColor.labelColor;
        label.frame = NSMakeRect(136, 21, 270, 22);
        [self addSubview:label];
    }
    return self;
}
- (NSView *)hitTest:(NSPoint)point { return nil; }
@end

#pragma mark - Runtime

@implementation MLTouchRuntime {
    __weak StreamViewMac *_streamView;
    __weak HIDSupport *_hid;
    NSString *_hostUUID;
    MLDirectTouchRecognizer *_recognizer;
    MLTouchForwarder *_forwarder;
    MLTouchPointerEmulator *_emulator;
    MLTouchMouseGate *_gate;
    MLTouchDebugOverlayView *_overlay;
    id _defaultsObserver;
    id _screenObserver;
    id _windowScreenObserver;

    MLTouchInputMode _preferred;
    MLTouchInputMode _effective;
    uint32_t _hostFlags;
    BOOL _installed;
    BOOL _tornDown;
    CGSize _videoSize;
    BOOL _stretch;
    NSUInteger _downCount;
    NSUInteger _maxDown;

    NSTimer *_pollTimer;
    NSTimer *_summaryTimer;
    NSUInteger _sumMoves, _sumWire, _sumMouseDropped, _sumMouseEvents, _sumBegan, _sumEnded;
    NSUInteger _sumMaxDown;
    BOOL _summaryQuiet;
    NSUInteger _totalWire;

    float _relRemainderX, _relRemainderY, _scrollRemainder;
    MLTouchFiveFingerHold *_hold;
    MLTouchHoldRingView *_ringView;
    MLTouchHintView *_hintView;
    NSTimer *_holdTimer;
    BOOL _hintShownThisRun;
    NSMutableSet<id> *_blocked;          // touches the stream refused at their start
    NSUInteger _blockedCount;
    BOOL _systemGesturesDisabledByUs;
    BOOL _loggedFirstClickDrop;
}

- (instancetype)initWithStreamView:(StreamViewMac *)streamView hid:(HIDSupport *)hid hostUUID:(NSString *)hostUUID {
    self = [super init];
    if (self) {
        _streamView = streamView;
        _hid = hid;
        _hostUUID = [hostUUID copy];
        _blocked = [NSMutableSet set];
        _hold = [[MLTouchFiveFingerHold alloc] init];
        _forwarder = [[MLTouchForwarder alloc] init];
        _emulator = [[MLTouchPointerEmulator alloc] init];
        _gate = [[MLTouchMouseGate alloc] init];
        _effective = MLTouchInputModeNative;
        __weak typeof(self) weakSelf = self;
        _hold.onTrigger = ^{ [weakSelf fiveFingerHoldFired]; };
        _hold.onStateChange = ^(MLTouchHoldState state) { [weakSelf fiveFingerHoldStateChanged:state]; };
        _forwarder.sink = ^(MLTouchWireEvent event, uint32_t pointerId, float x, float y) {
            [weakSelf sendWire:event pointerId:pointerId x:x y:y];
        };
        _emulator.sink = ^(MLTouchEmuEvent event) {
            [weakSelf sendEmulated:event];
        };
    }
    return self;
}

- (void)dealloc {
    [self removeObservers];
}

- (NSWindow *)streamWindow { return _streamView.window; }
- (MLTouchInputMode)effectiveMode { return _effective; }
- (BOOL)installed { return _installed; }

#pragma mark Setup

+ (BOOL)anyScreenHasTouch {
    if (@available(macOS 27.0, *)) {
        for (NSScreen *screen in NSScreen.screens) {
            if (screen.touchCapabilities & NSScreenTouchCapabilitiesMultiTouch) return YES;
        }
    }
    return NO;
}

+ (BOOL)isHostContentView:(NSView *)view streamView:(NSView *)streamView {
    if (view == nil || view == streamView) return YES;
    if ([view isKindOfClass:[MTKView class]]) return YES;
    static Class container;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ container = NSClassFromString(@"RendererLayerContainer"); });
    if (container != Nil && [view isKindOfClass:container]) return YES;
    if ([view isKindOfClass:[MLTouchDebugOverlayView class]]) return YES;
    return NO;
}

- (NSString *)screenCapabilitySummary {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSScreen *screen in NSScreen.screens) {
        NSUInteger caps = 0;
        if (@available(macOS 27.0, *)) caps = (NSUInteger)screen.touchCapabilities;
        [parts addObject:[NSString stringWithFormat:@"%@=%lu", screen.localizedName, (unsigned long)caps]];
    }
    return [parts componentsJoinedByString:@", "];
}

- (void)logScreens:(NSString *)reason {
    BOOL available = NO;
    if (@available(macOS 27.0, *)) available = YES;
    os_log(MLTouchLog(), "screens reason=%{public}@ touchCapabilities api=%{public}@ any-multitouch=%d [%{public}@] (NSScreenTouchCapabilitiesMultiTouch = 1)",
           reason, available ? @"yes" : @"no (macOS < 27)", [MLTouchRuntime anyScreenHasTouch] ? 1 : 0,
           [self screenCapabilitySummary]);
}

