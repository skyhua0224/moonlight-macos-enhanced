//
//  StreamViewMac.m
//  Moonlight for macOS
//
//  Created by Michael Kenny on 27/12/17.
//  Copyright © 2017 Moonlight Stream. All rights reserved.
//

#import "StreamViewMac.h"
#import "MoonlightEnhanced-Swift.h"
#import "Logger.h"

@interface StreamViewMac ()
@property (nonatomic, strong) NSView *startupOverlay;
@property (nonatomic) BOOL startupOverlayRaising;
@property (nonatomic) BOOL startupOverlayRaiseScheduled;
@property (nonatomic, strong) NSTimer *startupOverlayDiagnosticTimer;
@property (nonatomic) NSUInteger startupOverlayDiagnosticCount;

@end

@implementation StreamViewMac

- (NSCursor *)preferredLocalCursor {
    if (!self.prefersHiddenLocalCursor) {
        return [NSCursor arrowCursor];
    }

    static NSCursor *hiddenCursor;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSImage *cursorImage = [[NSImage alloc] initWithSize:NSMakeSize(16, 16)];
        [cursorImage lockFocus];
        [[NSColor clearColor] setFill];
        NSRectFill(NSMakeRect(0, 0, cursorImage.size.width, cursorImage.size.height));
        [cursorImage unlockFocus];
        hiddenCursor = [[NSCursor alloc] initWithImage:cursorImage hotSpot:NSZeroPoint];
    });

    return hiddenCursor;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) {
        [self installStartupOverlay];
    }
    return self;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) [self installStartupOverlay];
    return self;
}

- (void)installStartupOverlay {
    if (self.startupOverlay != nil) return;
    self.startupOverlay = [StreamingStartupOverlayFactory makeView];
    self.startupOverlay.frame = self.bounds;
    self.startupOverlay.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.startupOverlay.wantsLayer = YES;
    self.startupOverlay.layer.zPosition = 1000;
    [self addSubview:self.startupOverlay positioned:NSWindowAbove relativeTo:nil];
}

// Keeps the loading overlay above whatever else lives in the stream view (the
// renderer's presentation view, the control orb). The layer z-position alone
// is not relied on, and the overlay is only re-parented when it is not already
// on top so its animation is not restarted by every status update.
- (void)raiseStartupOverlayIfNeeded {
    NSView *overlay = self.startupOverlay;
    if (overlay == nil || overlay.hidden) return;
    overlay.layer.zPosition = 1000;
    if (self.subviews.lastObject == overlay) return;
    self.startupOverlayRaising = YES;
    [self addSubview:overlay positioned:NSWindowAbove relativeTo:nil];
    self.startupOverlayRaising = NO;
}

- (void)raiseSubviewAboveContent:(NSView *)view {
    if (view == nil) return;
    NSView *overlay = self.startupOverlay;
    if (overlay != nil && !overlay.hidden && overlay != view && overlay.superview == self) {
        NSArray<NSView *> *subviews = self.subviews;
        if (view.superview == self && subviews.count >= 2 && subviews.lastObject == overlay &&
            subviews[subviews.count - 2] == view) {
            return;
        }
        [self addSubview:view positioned:NSWindowBelow relativeTo:overlay];
        return;
    }
    if (view.superview == self && self.subviews.lastObject == view) return;
    [self addSubview:view positioned:NSWindowAbove relativeTo:nil];
}

- (void)didAddSubview:(NSView *)subview {
    [super didAddSubview:subview];
    if (subview == self.startupOverlay || self.startupOverlayRaising ||
        self.startupOverlay == nil || self.startupOverlay.hidden ||
        self.startupOverlayRaiseScheduled) {
        return;
    }
    // Someone inserted a view above the overlay while it is showing.
    self.startupOverlayRaiseScheduled = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil) return;
        strongSelf.startupOverlayRaiseScheduled = NO;
        [strongSelf raiseStartupOverlayIfNeeded];
    });
}

- (void)logStartupOverlayStateWithReason:(NSString *)reason {
    NSView *overlay = self.startupOverlay;
    if (overlay == nil) return;
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSView *subview in self.subviews) {
        [names addObject:NSStringFromClass(subview.class)];
    }
    NSWindow *window = self.window;
    Log(LOG_I, @"[diag] startup-overlay reason=%@ status=%@ hidden=%d index=%ld/%lu z=%.0f layerParent=%d overlayFrame=%@ bounds=%@ window=%d key=%d visible=%d occlusion=%lu fullscreen=%d subviews=%@",
        reason,
        self.statusText ?: @"(nil)",
        overlay.hidden ? 1 : 0,
        (long)[self.subviews indexOfObject:overlay],
        (unsigned long)self.subviews.count,
        overlay.layer.zPosition,
        overlay.layer.superlayer == self.layer ? 1 : 0,
        NSStringFromRect(overlay.frame),
        NSStringFromRect(self.bounds),
        window != nil ? 1 : 0,
        window.isKeyWindow ? 1 : 0,
        window.isVisible ? 1 : 0,
        (unsigned long)window.occlusionState,
        (window.styleMask & NSWindowStyleMaskFullScreen) != 0 ? 1 : 0,
        [names componentsJoinedByString:@","]);
}

// While the overlay is up, log where it sits twice a second so a missing
// spinner can be matched against the view hierarchy at that moment.
- (void)startStartupOverlayDiagnostics {
    if (self.startupOverlayDiagnosticTimer != nil) return;
    self.startupOverlayDiagnosticCount = 0;
    __weak typeof(self) weakSelf = self;
    self.startupOverlayDiagnosticTimer = [NSTimer timerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil || strongSelf.statusText == nil || ++strongSelf.startupOverlayDiagnosticCount > 16) {
            [timer invalidate];
            if (strongSelf != nil) strongSelf.startupOverlayDiagnosticTimer = nil;
            return;
        }
        [strongSelf logStartupOverlayStateWithReason:@"tick"];
    }];
    [[NSRunLoop mainRunLoop] addTimer:self.startupOverlayDiagnosticTimer forMode:NSRunLoopCommonModes];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [self refreshPreferredLocalCursor];
    [self raiseStartupOverlayIfNeeded];
}

- (void)setPrefersHiddenLocalCursor:(BOOL)prefersHiddenLocalCursor {
    if (_prefersHiddenLocalCursor == prefersHiddenLocalCursor) {
        return;
    }

    _prefersHiddenLocalCursor = prefersHiddenLocalCursor;
    [self refreshPreferredLocalCursor];
}

- (void)refreshPreferredLocalCursor {
    if (self.window != nil) {
        [self.window invalidateCursorRectsForView:self];
    }

    [[self preferredLocalCursor] set];
}

- (void)setStatusText:(NSString *)statusText {
    if (![NSThread isMainThread]) {
        NSString *text = [statusText copy];
        dispatch_async(dispatch_get_main_queue(), ^{ self.statusText = text; });
        return;
    }
    _statusText = [statusText copy];
    [self installStartupOverlay];
    self.startupOverlay.hidden = statusText == nil;
    if (statusText == nil) {
        self.window.title = self.appName;
        [self logStartupOverlayStateWithReason:@"cleared"];
    } else {
        [self raiseStartupOverlayIfNeeded];
        self.window.title = [[self.appName stringByAppendingString:@" - "] stringByAppendingString:statusText];
        [self logStartupOverlayStateWithReason:@"status"];
        [self startStartupOverlayDiagnostics];
    }
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    
    [[NSColor blackColor] setFill];
    NSRectFill(dirtyRect);
}

- (void)resetCursorRects {
    [super resetCursorRects];
    [self addCursorRect:self.bounds cursor:[self preferredLocalCursor]];
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    (void)event;
    return YES;
}

- (BOOL)mouseDownCanMoveWindow {
    return NO;
}

- (void)setIndirectTouchesEnabled:(BOOL)enabled {
    self.allowedTouchTypes = enabled ? NSTouchTypeMaskIndirect : 0;
    // Resting palms and thumbs are not contacts the host should see.
    self.wantsRestingTouches = NO;
}

- (void)touchesBeganWithEvent:(NSEvent *)event {
    if (self.touchHandler != nil) {
        self.touchHandler(event, self);
    }
}

- (void)touchesMovedWithEvent:(NSEvent *)event {
    if (self.touchHandler != nil) {
        self.touchHandler(event, self);
    }
}

- (void)touchesEndedWithEvent:(NSEvent *)event {
    if (self.touchHandler != nil) {
        self.touchHandler(event, self);
    }
}

- (void)touchesCancelledWithEvent:(NSEvent *)event {
    if (self.touchHandler != nil) {
        self.touchHandler(event, self);
    }
}

- (BOOL)performKeyEquivalent:(NSEvent *)event {
    return [self.keyboardNotifiable onKeyboardEquivalent:event];
}

@end
