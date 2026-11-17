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

- (void)refresh {
    if (_tornDown) return;
    StreamViewMac *view = _streamView;
    HIDSupport *hid = _hid;
    if (view == nil || hid == nil) return;

    if (@available(macOS 27.0, *)) {
        MLTouchInputMode preferred = MLTouchModeFromStoredValue([SettingsClass touchInputModeFor:_hostUUID]);
        uint32_t flags = [hid touchHostFeatureFlags];
        MLTouchInputMode effective = MLTouchEffectiveMode(preferred, flags);
        if (effective != _effective && (_forwarder.activeCount > 0 || _emulator.activeCount > 0)) {
            [self cancelLiveTouches];
        }
        BOOL changed = !_installed || preferred != _preferred || effective != _effective || flags != _hostFlags;
        _preferred = preferred;
        _effective = effective;
        _hostFlags = flags;
        _emulator.mode = effective == MLTouchInputModeDirect ? MLTouchInputModeDirect : MLTouchInputModeTrackpad;
        _gate.enabled = YES;
        // The "touch" subtype is NOT trusted on its own: every Mac trackpad press and tap-to-click carries it (a MacBook
        // trackpad lost every click to it). It is believed only with a touch in play, or for the click that
        // activates an inactive window on a Mac with a touch screen (shouldDropMouseEvent sets that per event).
        _gate.subtypeAlwaysDrops = NO;
        [self installRecognizerIfNeeded];
        [self applyWindowTouchPolicy];
        [self applyDebugPreference];
        if (changed) {
            Log(LOG_I, @"[touch] preference=%@ effective=%@ hostFlags=0x%x hostNativeTouch=%d touchScreen=%d clickPath=mouse(trackpad and mouse presses always reach the host; touch-made clicks are dropped only while a real touch is in play) debugOverlay=%d(display only)",
                MLTouchModeLogName(preferred), MLTouchModeLogName(effective), flags, MLTouchHostSupportsNative(flags) ? 1 : 0,
                [MLTouchRuntime anyScreenHasTouch] ? 1 : 0,
                [NSUserDefaults.standardUserDefaults boolForKey:MLTouchDebugDefaultsKey] ? 1 : 0);
            os_log(MLTouchLog(), "config preference=%{public}@ effective=%{public}@ hostFlags=0x%x LI_FF_PEN_TOUCH_EVENTS=%d fallback=%d",
                   MLTouchModeLogName(preferred), MLTouchModeLogName(effective), flags,
                   MLTouchHostSupportsNative(flags) ? 1 : 0,
                   (preferred == MLTouchInputModeNative && effective != MLTouchInputModeNative) ? 1 : 0);
            [self logScreens:@"config"];
        }
        [self updateHud];
    } else {
        if (!_installed) {
            os_log(MLTouchLog(), "direct touch unavailable: macOS < 27, no gesture-recognizer touches");
            _installed = YES; // log once
        }
    }
}

- (void)installRecognizerIfNeeded {
    if (_recognizer != nil) return;
    StreamViewMac *view = _streamView;
    if (view == nil) return;
    __weak typeof(self) weakSelf = self;
    MLDirectTouchRecognizer *recognizer = [[MLDirectTouchRecognizer alloc] initWithTarget:nil action:nil];
    recognizer.acceptsTouchAtPoint = ^BOOL(NSPoint point) {
        return [weakSelf pointBelongsToPicture:point];
    };
    recognizer.allSamplesHandler = ^(NSArray<MLTouchSample *> *samples, NSUInteger downCount) {
        [weakSelf handleAllSamples:samples downCount:downCount];
    };
    recognizer.samplesHandler = ^(NSArray<MLTouchSample *> *samples) {
        [weakSelf handleAcceptedSamples:samples];
    };
    [view addGestureRecognizer:recognizer];
    _recognizer = recognizer;
    _installed = YES;
    if (@available(macOS 27.0, *)) {
        // A second finger on a control (edge menu) must still be able to press it while a finger is on the picture.
        view.exclusiveGestureBehavior = NSViewExclusiveGestureBehaviorNotExclusive;
    }
}

- (BOOL)pointBelongsToPicture:(NSPoint)point {
    StreamViewMac *view = _streamView;
    if (view == nil || view.superview == nil) return YES;
    NSPoint inSuper = [view convertPoint:point toView:view.superview];
    NSView *hit = [view hitTest:inSuper];
    return [MLTouchRuntime isHostContentView:hit streamView:view];
}

// NSWindow.disablesDirectTouchSystemGestures is documented for macOS 27.3 (beta) and is not in the 27.0 SDK
// headers: set it only where the window answers to it. Three-finger swipes and the pinch are then the stream's.
- (void)applyWindowTouchPolicy {
    NSWindow *window = _streamView.window;
    if (window == nil) return;
    SEL setter = NSSelectorFromString(@"setDisablesDirectTouchSystemGestures:");
    if (![window respondsToSelector:setter]) return;
    BOOL wanted = _effective == MLTouchInputModeNative && _installed;
    if (wanted == _systemGesturesDisabledByUs) return;
    [window setValue:@(wanted) forKey:@"disablesDirectTouchSystemGestures"];
    _systemGesturesDisabledByUs = wanted;
    os_log(MLTouchLog(), "window disablesDirectTouchSystemGestures=%d", wanted ? 1 : 0);
}

- (void)cancelLiveTouches {
    BOOL hadAny = _forwarder.activeCount > 0 || _emulator.activeCount > 0;
    [_forwarder cancelAll];
    [_emulator cancelAll];
    [_recognizer forgetAllTouches];
    [_blocked removeAllObjects];
    [_hold reset];
    [_overlay removeAllDots];
    [_gate noteAllTouchesUpAtTime:NSProcessInfo.processInfo.systemUptime];
    _downCount = 0;
    [self stopPollTimer];
    if (hadAny) os_log(MLTouchLog(), "live touches cancelled (input paused, mode change or stream end)");
}

- (void)tearDown {
    if (_tornDown) return;
    [self cancelLiveTouches];
    _tornDown = YES;
    if (_systemGesturesDisabledByUs) {
        NSWindow *window = _streamView.window;
        SEL setter = NSSelectorFromString(@"setDisablesDirectTouchSystemGestures:");
        if (window != nil && [window respondsToSelector:setter]) {
            [window setValue:@NO forKey:@"disablesDirectTouchSystemGestures"];
        }
        _systemGesturesDisabledByUs = NO;
    }
    if (_recognizer != nil) [_streamView removeGestureRecognizer:_recognizer];
    _recognizer = nil;
    [_overlay removeFromSuperview];
    _overlay = nil;
    [self stopHoldTimer];
    [_ringView removeFromSuperview];
    _ringView = nil;
    [_hintView removeFromSuperview];
    _hintView = nil;
    [self removeObservers];
    [_summaryTimer invalidate];
    _summaryTimer = nil;
    _gate.enabled = NO;
    Log(LOG_I, @"[touch] stream summary touchPath=%@ clicks reached host=%lu dropped=%lu (subtype=%lu correlated-with-touch=%lu rest-of-dropped-click=%lu) touch wire events=%lu",
        MLTouchModeLogName(_effective), (unsigned long)_gate.passedClickCount, (unsigned long)_gate.droppedCount,
        (unsigned long)_gate.droppedSubtypeCount, (unsigned long)_gate.droppedCorrelatedCount,
        (unsigned long)_gate.droppedSequenceCount, (unsigned long)_totalWire);
    os_log(MLTouchLog(), "runtime torn down wire-events=%lu", (unsigned long)_totalWire);
}

- (void)removeObservers {
    if (_defaultsObserver != nil) [NSNotificationCenter.defaultCenter removeObserver:_defaultsObserver];
    if (_screenObserver != nil) [NSNotificationCenter.defaultCenter removeObserver:_screenObserver];
    _defaultsObserver = nil;
    _screenObserver = nil;
    if (_windowScreenObserver != nil) [NSNotificationCenter.defaultCenter removeObserver:_windowScreenObserver];
    _windowScreenObserver = nil;
}

- (void)setVideoWidth:(int)width height:(int)height stretch:(BOOL)stretch {
    _videoSize = CGSizeMake(MAX(width, 0), MAX(height, 0));
    _stretch = stretch;
}

- (void)setVideoWidth:(int)width height:(int)height {
    [self setVideoWidth:width height:height stretch:_stretch];
}

- (void)setStretch:(BOOL)stretch {
    _stretch = stretch;
}

#pragma mark Debug overlay

- (void)applyDebugPreference {
    if (_defaultsObserver == nil) {
        __weak typeof(self) weakSelf = self;
        _defaultsObserver = [NSNotificationCenter.defaultCenter addObserverForName:NSUserDefaultsDidChangeNotification
                                                                            object:nil queue:NSOperationQueue.mainQueue
                                                                        usingBlock:^(NSNotification *note) {
            [weakSelf applyDebugPreference];
        }];
        _screenObserver = [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidChangeScreenParametersNotification
                                                                          object:nil queue:NSOperationQueue.mainQueue
                                                                      usingBlock:^(NSNotification *note) {
            [weakSelf logScreens:@"screen-change"];
            if (weakSelf.screenChangedHandler != nil) weakSelf.screenChangedHandler();
        }];
        // the window moving to another screen (Sidecar) re-lays-out the stream menu ball
        _windowScreenObserver = [NSNotificationCenter.defaultCenter addObserverForName:NSWindowDidChangeScreenNotification
                                                                                object:nil queue:NSOperationQueue.mainQueue
                                                                            usingBlock:^(NSNotification *note) {
            if (note.object != weakSelf.streamWindow) return;
            [weakSelf logScreens:@"window-screen-change"];
            if (weakSelf.screenChangedHandler != nil) weakSelf.screenChangedHandler();
        }];
    }
    BOOL wanted = [NSUserDefaults.standardUserDefaults boolForKey:MLTouchDebugDefaultsKey];
    StreamViewMac *view = _streamView;
    if (view == nil) return;
    if (wanted && _overlay == nil) {
        _overlay = [[MLTouchDebugOverlayView alloc] initWithFrame:view.bounds];
        [view raiseSubviewAboveContent:_overlay];
        os_log(MLTouchLog(), "debug overlay on (defaults MLTouchDebug)");
    } else if (!wanted && _overlay != nil) {
        [_overlay removeFromSuperview];
        _overlay = nil;
        os_log(MLTouchLog(), "debug overlay off");
    }
    [self updateHud];
}

- (void)updateHud {
    if (_overlay == nil) return;
    if (_overlay.superview == nil && _streamView != nil) [_streamView raiseSubviewAboveContent:_overlay];
    NSString *prefName = MLTouchModeLogName(_preferred);
    NSString *effName = MLTouchModeLogName(_effective);
    BOOL hostNative = MLTouchHostSupportsNative(_hostFlags);
    BOOL forwarding = _effective == MLTouchInputModeNative;
    BOOL api = NO;
    if (@available(macOS 27.0, *)) api = YES;
    _overlay.hudLines = @[
        @"MLTouchDebug",
        [NSString stringWithFormat:@"touches down: %lu   (max %lu)", (unsigned long)_downCount, (unsigned long)_maxDown],
        [NSString stringWithFormat:@"forwarded to host as touch: %@   wire events: %lu", forwarding ? @"YES" : @"NO", (unsigned long)_totalWire],
        [NSString stringWithFormat:@"host LI_FF_PEN_TOUCH_EVENTS: %@ (flags 0x%x)", hostNative ? @"YES" : @"NO", _hostFlags],
        [NSString stringWithFormat:@"mode: %@  (setting: %@)", effName, prefName],
        [NSString stringWithFormat:@"screen touch: %@  api: %@", [MLTouchRuntime anyScreenHasTouch] ? @"multi-touch" : @"none", api ? @"macOS 27" : @"missing"],
        [NSString stringWithFormat:@"mouse emulation dropped: %lu  leaked near a touch: %lu",
            (unsigned long)_gate.droppedCount, (unsigned long)_gate.passedNearTouchCount],
        [NSString stringWithFormat:@"send failures: %lu (last %d)  refused touches: %lu",
            (unsigned long)_hid.touchSendFailures, _hid.touchLastSendError, (unsigned long)_blockedCount],
    ];
}

#pragma mark Touch events

- (NSString *)idList:(NSArray<NSNumber *> *)ids {
    return ids.count == 0 ? @"-" : [[ids valueForKey:@"stringValue"] componentsJoinedByString:@","];
}

- (void)handleAllSamples:(NSArray<MLTouchSample *> *)samples downCount:(NSUInteger)downCount {
    if (_tornDown) return;
    MLTouchSample *last = samples.lastObject;
    [_gate noteTouchPoint:last.point active:downCount > 0 time:last.timestamp];
    if (downCount == 0) [_gate noteAllTouchesUpAtTime:last.timestamp];

    NSUInteger began = 0, ended = 0;
    for (MLTouchSample *s in samples) {
        if (s.phase == MLTouchPhaseBegan) began++;
        else if (s.phase == MLTouchPhaseEnded || s.phase == MLTouchPhaseCancelled) ended++;
        else if (s.phase == MLTouchPhaseMoved) _sumMoves++;
    }
    if (began > 0 && _hintView != nil) [self dismissHint];   // a touch anywhere closes it, and is still the stream's
    _sumBegan += began;
    _sumEnded += ended;
    _downCount = downCount;
    _maxDown = MAX(_maxDown, downCount);
    _sumMaxDown = MAX(_sumMaxDown, downCount);
    [self startSummaryTimerIfNeeded];

    if (began > 0 || ended > 0) {
        BOOL native = _effective == MLTouchInputModeNative;
        NSString *kind = ended > 0 && began == 0 ? @"ended" : (began > 0 && ended == 0 ? @"began" : @"began+ended");
        os_log(MLTouchLog(), "touches %{public}@ down=%lu began=%lu ended=%lu mode=%{public}@ forwarded-ids=[%{public}@] wire-total=%lu",
               kind, (unsigned long)downCount, (unsigned long)began, (unsigned long)ended,
               MLTouchModeLogName(_effective), native ? [self idList:_forwarder.activePointerIds] : @"-", (unsigned long)_totalWire);
        Log(LOG_I, @"[touch] %@ down=%lu mode=%@", kind, (unsigned long)downCount, MLTouchModeLogName(_effective));
    }

    if (_overlay != nil) {
        for (MLTouchSample *s in samples) {
            if (s.phase == MLTouchPhaseEnded || s.phase == MLTouchPhaseCancelled) {
                [_overlay removeDotForKey:s.identity];
                continue;
            }
            NSInteger pid = [_forwarder pointerIdForIdentity:s.identity];
            BOOL accepted = pid >= 0 || (_effective != MLTouchInputModeNative && [self pointBelongsToPicture:s.point]);
            if (_effective == MLTouchInputModeNative) {
                if (accepted) [_overlay setDotAtPoint:s.point label:[NSString stringWithFormat:@"id %ld  → host", (long)pid] state:MLTouchDotForwarded forKey:s.identity];
                else [_overlay setDotAtPoint:s.point label:@"not forwarded" state:MLTouchDotNotForwarded forKey:s.identity];
            } else {
                if (accepted) [_overlay setDotAtPoint:s.point label:[NSString stringWithFormat:@"%@ emu", MLTouchModeLogName(_effective)] state:MLTouchDotEmulated forKey:s.identity];
                else [_overlay setDotAtPoint:s.point label:@"not forwarded" state:MLTouchDotNotForwarded forKey:s.identity];
            }
        }
        [self updateHud];
    }
}

- (void)handleAcceptedSamples:(NSArray<MLTouchSample *> *)samples {
    if (_tornDown) return;
    StreamViewMac *view = _streamView;
    if (view == nil) return;

    // The host's feature flags may have arrived since the last touch: re-resolve while nothing is down.
    if (_forwarder.activeCount == 0 && _emulator.activeCount == 0) {
        [self refresh];
    }

    // The hold watches every touch on the picture, taken or not.
    [_hold processSamples:samples];
    samples = [self samplesTheStreamTakes:samples view:view];
    if (samples.count == 0) return;

    // Source: apple-appkit-gesture-recognizers-20261117, "Set up gesture recognizers". Only a touch the stream
    // accepted is evidence for gating the separate GameController path.
    for (MLTouchSample *sample in samples) {
        if (sample.phase == MLTouchPhaseBegan) {
            [_gate noteDirectTouchBeganAtTime:sample.timestamp];
        }
    }

    CGSize viewSize = view.bounds.size;
    _forwarder.viewSize = viewSize;  _forwarder.videoSize = _videoSize;  _forwarder.stretch = _stretch;
    _emulator.viewSize = viewSize;   _emulator.videoSize = _videoSize;   _emulator.stretch = _stretch;

    if (_effective == MLTouchInputModeNative) {
        [_forwarder processSamples:samples];
    } else {
        [_emulator processSamples:samples];
        if (_emulator.activeCount > 0) [self startPollTimer]; else [self stopPollTimer];
    }
}

- (BOOL)shouldDropGCMouseButton:(NSInteger)button pressed:(BOOL)pressed time:(NSTimeInterval)time {
    if (_tornDown || !_gate.enabled) return NO;
    BOOL drop = [_gate shouldDropGCMouseButton:button pressed:pressed time:time];
    if (drop) {
        os_log(MLTouchLog(), "GCMouse button %{public}@ gated after direct-touch evidence button=%ld time=%.6f",
               pressed ? @"press" : @"release", (long)button, time);
    }
    return drop;
}

// A touch is taken or refused as a whole, when it begins: if the stream is not accepting input at that moment the
// touch is never sent (its moves and its end are dropped with it), so the host cannot see an end without a beginning.
- (NSArray<MLTouchSample *> *)samplesTheStreamTakes:(NSArray<MLTouchSample *> *)samples view:(StreamViewMac *)view {
    NSMutableArray<MLTouchSample *> *taken = nil;
    BOOL allowed = YES;
    BOOL checked = NO;
    for (MLTouchSample *s in samples) {
        BOOL drop = NO;
        if (s.phase == MLTouchPhaseBegan) {
            if (!checked) {
                checked = YES;
                allowed = self.touchAllowedHandler == nil || self.touchAllowedHandler();
                NSWindow *window = view.window;
                if (allowed && window != nil && !window.isKeyWindow && self.touchEngageHandler != nil) {
                    // Touching the picture is a click on it: the window becomes key, as for a mouse click.
                    self.touchEngageHandler();
                }
            }
            if (!allowed) {
                [_blocked addObject:s.identity];
                _blockedCount++;
                os_log(MLTouchLog(), "touch refused at its start: the stream is not taking input now (menu, stopping, reconnecting or no window); total=%lu", (unsigned long)_blockedCount);
                drop = YES;
            }
        } else if ([_blocked containsObject:s.identity]) {
            if (s.phase == MLTouchPhaseEnded || s.phase == MLTouchPhaseCancelled) [_blocked removeObject:s.identity];
            drop = YES;
        }
        if (drop && taken == nil) {
            taken = [NSMutableArray arrayWithCapacity:samples.count];
            for (MLTouchSample *earlier in samples) {
                if (earlier == s) break;
                [taken addObject:earlier];
            }
        }
        if (!drop && taken != nil) [taken addObject:s];
    }
    return taken != nil ? taken : samples;
}

#pragma mark Five-finger hold

- (void)fiveFingerHoldStateChanged:(MLTouchHoldState)state {
    static const char *names[] = { "idle", "arming", "fired", "failed" };
    if (state != MLTouchHoldStateIdle) {
        os_log(MLTouchLog(), "five-finger hold %{public}s (touches down=%lu)", names[state], (unsigned long)_hold.downCount);
    }
    if (state == MLTouchHoldStateArming) {
        [self startHoldTimer];
    } else {
        [self stopHoldTimer];
        [_ringView hideRing];
    }
}

- (void)fiveFingerHoldFired {
    // The five touches were being sent from their first contact. They are void now: the host is told to cancel all of
    // them, and the five are not sent again, whatever they do, until they are lifted.
    [_forwarder cancelAllAndIgnoreCurrentTouches];
    [_emulator cancelAll];
    [_ringView hideRing];
    os_log(MLTouchLog(), "five-finger hold opened the Control Center; host told CANCEL_ALL, wire-total=%lu", (unsigned long)_totalWire);
    Log(LOG_I, @"[touch] five-finger hold opened the Control Center");
    if (_hintView != nil) [self dismissHint];
    if (self.openControlCenterHandler != nil) {
        void (^handler)(void) = self.openControlCenterHandler;
        dispatch_async(dispatch_get_main_queue(), handler);
    }
}

- (void)startHoldTimer {
    if (_holdTimer != nil) return;
    StreamViewMac *view = _streamView;
    if (view != nil && _ringView == nil) {
        _ringView = [[MLTouchHoldRingView alloc] initWithFrame:view.bounds];
    }
    if (view != nil && _ringView.superview == nil) [view raiseSubviewAboveContent:_ringView];
    __weak typeof(self) weakSelf = self;
    _holdTimer = [NSTimer timerWithTimeInterval:1.0 / 60.0 repeats:YES block:^(NSTimer *timer) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil) { [timer invalidate]; return; }
        NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
        double progress = [strongSelf->_hold progressAtTime:now];
        if (strongSelf->_hold.state == MLTouchHoldStateArming) {
            [strongSelf->_ringView showProgress:progress at:strongSelf->_hold.centroid];
        }
        [strongSelf->_hold pollAtTime:now];
    }];
    [NSRunLoop.mainRunLoop addTimer:_holdTimer forMode:NSRunLoopCommonModes];
}

- (void)stopHoldTimer {
    [_holdTimer invalidate];
    _holdTimer = nil;
}

#pragma mark One-time hint

- (void)showFiveFingerHintIfNeeded {
    StreamViewMac *view = _streamView;
    if (_tornDown || view == nil || _hintShownThisRun || _hintView != nil) return;
    if (![MLTouchRuntime anyScreenHasTouch]) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults boolForKey:@"MLTouchFiveFingerHintShown"] && ![defaults boolForKey:@"MLTouchHintForce"]) return;
    _hintShownThisRun = YES;
    [defaults setBool:YES forKey:@"MLTouchFiveFingerHintShown"];

    NSString *text = [LanguageManager.shared localize:@"Hold five fingers to open Control Center"];
    MLTouchHintView *hint = [[MLTouchHintView alloc] initWithText:text];
    NSSize size = hint.frame.size;
    hint.frame = NSMakeRect(NSMidX(view.bounds) - size.width / 2, 56, size.width, size.height);
    hint.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMaxYMargin;
    hint.alphaValue = 0;
    [view raiseSubviewAboveContent:hint];
    _hintView = hint;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.25;
        hint.animator.alphaValue = 1;
    }];
    os_log(MLTouchLog(), "five-finger hint shown (once; defaults MLTouchFiveFingerHintShown)");
    __weak typeof(self) weakSelf = self;
    __weak MLTouchHintView *weakHint = hint;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(7.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf != nil && strongSelf->_hintView == weakHint) [strongSelf dismissHint];
    });
}

- (void)dismissHint {
    MLTouchHintView *hint = _hintView;
    _hintView = nil;
    if (hint == nil) return;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.25;
        hint.animator.alphaValue = 0;
    } completionHandler:^{
        [hint removeFromSuperview];
    }];
}

#pragma mark Sending

- (void)sendWire:(MLTouchWireEvent)event pointerId:(uint32_t)pointerId x:(float)x y:(float)y {
    _totalWire++;
    _sumWire++;
    [_hid sendTouchWireEvent:event pointerId:pointerId x:x y:y];
}

- (CGFloat)hostPixelsPerViewPoint {
    StreamViewMac *view = _streamView;
    if (view == nil || _videoSize.width <= 0) return 1.0;
    CGRect rect = MLTouchVideoRect(view.bounds.size, _videoSize, _stretch);
    return rect.size.width > 0 ? _videoSize.width / rect.size.width : 1.0;
}

- (void)sendEmulated:(MLTouchEmuEvent)event {
    HIDSupport *hid = _hid;
    if (hid == nil) return;
    switch (event.kind) {
        case MLTouchEmuKindMoveRelative: {
            CGFloat sensitivity = [SettingsClass pointerSensitivityFor:_hostUUID];
            if (!isfinite(sensitivity) || sensitivity <= 0) sensitivity = 1.0;
            float scale = (float)([self hostPixelsPerViewPoint] * MIN(MAX(sensitivity, 0.25), 3.0));
            _relRemainderX += event.a * scale;
            _relRemainderY += -event.b * scale;      // view y is up, the host's is down
            short dx = (short)truncf(_relRemainderX), dy = (short)truncf(_relRemainderY);
            _relRemainderX -= dx;
            _relRemainderY -= dy;
            [hid sendTouchRelativeDeltaX:dx deltaY:dy];
            break;
        }
        case MLTouchEmuKindMoveAbsolute: {
            CGSize reference = _videoSize.width > 0 ? _videoSize : CGSizeMake(10000, 10000);
            [hid sendTouchAbsoluteX:event.a y:event.b referenceSize:reference];
            break;
        }
        case MLTouchEmuKindButton:
            [hid sendTouchMouseButton:event.button pressed:event.pressed];
            break;
        case MLTouchEmuKindScroll: {
            // About 15 points of finger travel to one wheel notch (120 units); fingers up scrolls content up.
            CGFloat speed = [SettingsClass gestureScrollSpeedFor:_hostUUID];
            if (!isfinite(speed) || speed <= 0) speed = 1.0;
            float direction = [SettingsClass reverseScrollDirectionFor:_hostUUID] ? 1.0f : -1.0f;
            _scrollRemainder += event.a * 8.0f * (float)speed * direction;
            short amount = (short)truncf(_scrollRemainder);
            _scrollRemainder -= amount;
            [hid sendTouchHighResScroll:amount];
            break;
        }
    }
}

#pragma mark Poll and summary timers

- (void)startPollTimer {
    if (_pollTimer != nil) return;
    __weak typeof(self) weakSelf = self;
    _pollTimer = [NSTimer timerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *timer) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil) { [timer invalidate]; return; }
        [strongSelf->_emulator pollAtTime:NSProcessInfo.processInfo.systemUptime];
    }];
    [NSRunLoop.mainRunLoop addTimer:_pollTimer forMode:NSRunLoopCommonModes];
}

- (void)stopPollTimer {
    [_pollTimer invalidate];
    _pollTimer = nil;
}

// One line a second while touches or touch-made mouse events are happening: no line per move.
- (void)startSummaryTimerIfNeeded {
    _summaryQuiet = NO;
    if (_summaryTimer != nil) return;
    __weak typeof(self) weakSelf = self;
    _summaryTimer = [NSTimer timerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil) { [timer invalidate]; return; }
        [strongSelf emitSummary];
    }];
    [NSRunLoop.mainRunLoop addTimer:_summaryTimer forMode:NSRunLoopCommonModes];
}

- (void)emitSummary {
    BOOL idle = _sumMoves == 0 && _sumWire == 0 && _sumBegan == 0 && _sumEnded == 0 && _sumMouseEvents == 0 && _downCount == 0;
    if (idle) {
        if (_summaryQuiet) {
            [_summaryTimer invalidate];
            _summaryTimer = nil;
        }
        _summaryQuiet = YES;
        return;
    }
    _summaryQuiet = NO;
    if (_hid.touchSendFailures > 0) {
        os_log(MLTouchLog(), "send failures so far=%lu last=%d", (unsigned long)_hid.touchSendFailures, _hid.touchLastSendError);
    }
    os_log(MLTouchLog(), "summary 1s moves=%lu began=%lu ended=%lu wire=%lu maxDown=%lu down=%lu mouseEvents=%lu mouseDropped=%lu mouseLeakedNearTouch(total)=%lu",
           (unsigned long)_sumMoves, (unsigned long)_sumBegan, (unsigned long)_sumEnded, (unsigned long)_sumWire,
           (unsigned long)_sumMaxDown, (unsigned long)_downCount, (unsigned long)_sumMouseEvents,
           (unsigned long)_sumMouseDropped, (unsigned long)_gate.passedNearTouchCount);
    _sumMoves = _sumBegan = _sumEnded = _sumWire = _sumMouseEvents = _sumMouseDropped = 0;
    _sumMaxDown = _downCount;
    [_overlay removeStaleDotsOlderThan:2.0];
}

#pragma mark Mouse emulation gate

- (BOOL)shouldDropMouseEvent:(NSEvent *)event kind:(MLTouchGateMouseKind)kind {
    if (_tornDown || !_gate.enabled) return NO;
    StreamViewMac *view = _streamView;
    NSPoint point = view != nil ? [view convertPoint:event.locationInWindow fromView:nil] : event.locationInWindow;
    BOOL subtype = event.subtype == NSEventSubtypeTouch;
    _gate.subtypeAlwaysDrops = MLTouchSubtypeBelievedWithoutTouch([MLTouchRuntime anyScreenHasTouch], view.window.isKeyWindow);
    NSTimeInterval age = -1;
    MLTouchGateVerdict verdict = [_gate verdictForMouseKind:kind
                                                     button:event.type == NSEventTypeMouseMoved ? 0 : (NSInteger)event.buttonNumber
                                                      point:point
                                                       time:event.timestamp
                                               touchSubtype:subtype
                                              ageSinceTouch:&age];
    BOOL drop = verdict != MLTouchGateVerdictPass;
    if (drop && kind == MLTouchGateMouseDown && verdict == MLTouchGateVerdictDropSubtype &&
        _downCount == 0 && view != nil && !view.window.isKeyWindow && self.touchEngageHandler != nil) {
        // The click that would have activated the window: do that, and keep the click itself from the host.
        self.touchEngageHandler();
    }
    if (drop && kind == MLTouchGateMouseDown && !_loggedFirstClickDrop) {
        _loggedFirstClickDrop = YES;
        Log(LOG_W, @"[touch] first dropped click this stream: verdict=%d subtype-touch=%d touchDown=%lu ageSinceTouch=%.0fms touchScreen=%d keyWindow=%d",
            (int)verdict, subtype ? 1 : 0, (unsigned long)_downCount, age >= 0 ? age * 1000.0 : -1.0,
            [MLTouchRuntime anyScreenHasTouch] ? 1 : 0, view.window.isKeyWindow ? 1 : 0);
    }
    BOOL recentTouch = age >= 0 && age <= 2.0;
    if (kind != MLTouchGateMouseMove && (drop || recentTouch || subtype)) {
        static const char *names[] = { "pass", "drop-subtype", "drop-correlated", "drop-sequence" };
        os_log(MLTouchLog(), "mouse event %{public}@ button=%ld verdict=%{public}s age-since-touch=%.0fms subtype-touch=%d down=%lu (a click that follows a touch within 350 ms is the system's emulation)",
               kind == MLTouchGateMouseDown ? @"down" : @"up", (long)event.buttonNumber, names[verdict],
               age >= 0 ? age * 1000.0 : -1.0, subtype ? 1 : 0, (unsigned long)_downCount);
        [self startSummaryTimerIfNeeded];
    }
    _sumMouseEvents += recentTouch || drop ? 1 : 0;
    if (drop) _sumMouseDropped++;
    if (_overlay != nil && (drop || recentTouch)) [self updateHud];
    return drop;
}

@end
