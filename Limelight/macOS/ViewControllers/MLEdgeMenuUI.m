//
//  MLEdgeMenuUI.m
//  Moonlight for macOS
//

#import "StreamViewController_Internal.h"

@implementation MLEdgeMenuHandleView {
    NSImageView *_iconView;
    // Drag distance accumulated from event deltas. Pointer warps (mouse capture
    // hand-offs, virtual cursor sync) never show up in event deltas, whereas a
    // screen-position difference would jump by the size of the warp.
    NSPoint _dragTranslation;
    BOOL _dragStarted;
    // Set when the controller aborts a press (menu shown, key loss); the rest
    // of that physical press is ignored until the next mouseDown.
    BOOL _interactionCancelled;
    NSTrackingArea *_trackingArea;
    CAGradientLayer *_backgroundGradientLayer;
    CAShapeLayer *_curveLayerA;
    CAShapeLayer *_curveLayerB;
    CALayer *_plateShadowLayer;
    CALayer *_plateLayer;
    CALayer *_plateInnerLayer;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        self.wantsLayer = YES;
        self.layer.masksToBounds = NO;
        self.layer.cornerRadius = 28.0;

        _backgroundGradientLayer = [CAGradientLayer layer];
        _backgroundGradientLayer.startPoint = CGPointMake(0.12, 0.08);
        _backgroundGradientLayer.endPoint = CGPointMake(0.92, 0.98);
        [self.layer addSublayer:_backgroundGradientLayer];

        _curveLayerA = [CAShapeLayer layer];
        _curveLayerA.fillColor = NSColor.clearColor.CGColor;
        _curveLayerA.lineWidth = 2.0;
        [self.layer addSublayer:_curveLayerA];

        _curveLayerB = [CAShapeLayer layer];
        _curveLayerB.fillColor = NSColor.clearColor.CGColor;
        _curveLayerB.lineWidth = 1.6;
        [self.layer addSublayer:_curveLayerB];

        _plateShadowLayer = [CALayer layer];
        [self.layer addSublayer:_plateShadowLayer];

        _plateLayer = [CALayer layer];
        [_plateShadowLayer addSublayer:_plateLayer];

        _plateInnerLayer = [CALayer layer];
        [_plateLayer addSublayer:_plateInnerLayer];

        _iconView = [[NSImageView alloc] initWithFrame:NSZeroRect];
        _iconView.imageScaling = NSImageScaleProportionallyUpOrDown;
        _iconView.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin | NSViewMaxYMargin;
        [self addSubview:_iconView];

        [self updateVisualStyle];
    }
    return self;
}

- (NSImageView *)iconView {
    return _iconView;
}

- (BOOL)isFlipped {
    return YES;
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    return YES;
}

- (NSView *)hitTest:(NSPoint)point {
    // hitTest: receives the point in the superview's coordinate space.
    NSPoint localPoint = [self convertPoint:point fromView:self.superview];
    CGFloat radius = MIN(self.bounds.size.width, self.bounds.size.height) * 0.33;
    NSBezierPath *hitPath = [NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:radius yRadius:radius];
    return [hitPath containsPoint:localPoint] ? self : nil;
}

- (void)setActiveAppearance:(BOOL)activeAppearance {
    _activeAppearance = activeAppearance;
    [self updateVisualStyle];
}

- (void)setCompactAppearance:(BOOL)compactAppearance {
    _compactAppearance = compactAppearance;
    [self setNeedsLayout:YES];
    [self updateVisualStyle];
}

- (void)setDockEdge:(MLFreeMouseExitEdge)dockEdge {
    _dockEdge = dockEdge;
    [self setNeedsLayout:YES];
    [self updateVisualStyle];
}

- (void)layout {
    [super layout];

    CGFloat cornerRadius = MIN(self.bounds.size.width, self.bounds.size.height) * 0.33;
    self.layer.cornerRadius = cornerRadius;
    CGPathRef shadowPath = CGPathCreateWithRoundedRect(NSRectToCGRect(self.bounds), cornerRadius, cornerRadius, NULL);
    self.layer.shadowPath = shadowPath;
    CGPathRelease(shadowPath);
    _backgroundGradientLayer.frame = self.bounds;

    NSBezierPath *curvePathA = [NSBezierPath bezierPath];
    [curvePathA appendBezierPathWithOvalInRect:NSInsetRect(self.bounds, -self.bounds.size.width * 0.42, -self.bounds.size.height * 0.18)];
    CGPathRef curvePathARef = [self.class cgPathFromBezierPath:curvePathA];
    _curveLayerA.path = curvePathARef;
    CGPathRelease(curvePathARef);

    NSBezierPath *curvePathB = [NSBezierPath bezierPath];
    [curvePathB appendBezierPathWithOvalInRect:NSMakeRect(-self.bounds.size.width * 0.20,
                                                          self.bounds.size.height * 0.10,
                                                          self.bounds.size.width * 1.42,
                                                          self.bounds.size.height * 1.12)];
    CGPathRef curvePathBRef = [self.class cgPathFromBezierPath:curvePathB];
    _curveLayerB.path = curvePathBRef;
    CGPathRelease(curvePathBRef);

    CGFloat plateSize = MIN(self.bounds.size.width, self.bounds.size.height) * MLEdgeMenuPlateRatio;
    NSRect plateFrame = NSMakeRect((NSWidth(self.bounds) - plateSize) / 2.0,
                                   (NSHeight(self.bounds) - plateSize) / 2.0,
                                   plateSize,
                                   plateSize);
    _plateShadowLayer.frame = NSInsetRect(plateFrame, -6.0, -6.0);
    _plateLayer.frame = NSInsetRect(_plateShadowLayer.bounds, 6.0, 6.0);
    _plateLayer.cornerRadius = plateSize * 0.30;
    _plateInnerLayer.frame = CGRectInset(_plateLayer.bounds, 4.0, 4.0);
    _plateInnerLayer.cornerRadius = MAX(8.0, _plateLayer.cornerRadius - 4.0);

    CGFloat iconSize = plateSize * 0.42;
    _iconView.frame = NSMakeRect(NSMinX(plateFrame) + (plateSize - iconSize) / 2.0,
                                 NSMinY(plateFrame) + (plateSize - iconSize) / 2.0,
                                 iconSize,
                                 iconSize);
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];

    if (_trackingArea) {
        [self removeTrackingArea:_trackingArea];
    }

    NSTrackingAreaOptions options = NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect;
    _trackingArea = [[NSTrackingArea alloc] initWithRect:self.bounds options:options owner:self userInfo:nil];
    [self addTrackingArea:_trackingArea];
}

- (void)mouseEntered:(NSEvent *)event {
    [super mouseEntered:event];
    if (self.hoverHandler) {
        self.hoverHandler(YES);
    }
}

- (void)mouseExited:(NSEvent *)event {
    [super mouseExited:event];
    if (self.hoverHandler) {
        self.hoverHandler(NO);
    }
}

- (void)updateVisualStyle {
    BOOL active = self.activeAppearance;

    _backgroundGradientLayer.colors = @[
        (__bridge id)NSColor.clearColor.CGColor,
        (__bridge id)NSColor.clearColor.CGColor
    ];
    _backgroundGradientLayer.cornerRadius = self.layer.cornerRadius;

    self.layer.borderWidth = 0.0;
    self.layer.borderColor = NSColor.clearColor.CGColor;
    self.layer.shadowColor = [NSColor colorWithRed:0.0 green:0.0 blue:0.0 alpha:0.44].CGColor;
    self.layer.shadowOpacity = 0.0f;
    self.layer.shadowRadius = 0.0f;
    self.layer.shadowOffset = CGSizeZero;

    _curveLayerA.strokeColor = NSColor.clearColor.CGColor;
    _curveLayerB.strokeColor = NSColor.clearColor.CGColor;

    _plateShadowLayer.shadowColor = [NSColor colorWithWhite:0.0 alpha:0.26].CGColor;
    _plateShadowLayer.shadowOpacity = active ? 0.24f : 0.18f;
    _plateShadowLayer.shadowRadius = active ? 16.0f : 12.0f;
    _plateShadowLayer.shadowOffset = CGSizeMake(0.0, 3.0);

    _plateLayer.backgroundColor = [NSColor colorWithRed:0.96 green:0.97 blue:0.99 alpha:0.98].CGColor;
    _plateLayer.borderWidth = 1.0;
    _plateLayer.borderColor = [NSColor colorWithWhite:1.0 alpha:0.78].CGColor;

    _plateInnerLayer.backgroundColor = [NSColor colorWithRed:0.89 green:0.91 blue:0.95 alpha:0.92].CGColor;
    _plateInnerLayer.borderWidth = 1.0;
    _plateInnerLayer.borderColor = [NSColor colorWithWhite:0.72 alpha:0.42].CGColor;

    _iconView.contentTintColor = [NSColor colorWithRed:0.12 green:0.15 blue:0.20 alpha:0.98];
}

- (void)mouseDown:(NSEvent *)event {
    _dragTranslation = NSZeroPoint;
    _dragStarted = NO;
    _interactionCancelled = NO;
}

- (BOOL)dragInProgress {
    return _dragStarted;
}

- (void)mouseDragged:(NSEvent *)event {
    if (_interactionCancelled) {
        return;
    }
    if ((NSEvent.pressedMouseButtons & 1) == 0) {
        // The button is already up but its mouseUp never reached this view.
        [self finishInteractionWithEvent:event];
        return;
    }
    const CGFloat maxStep = 240.0;
    _dragTranslation.x += MIN(MAX(event.deltaX, -maxStep), maxStep);
    _dragTranslation.y -= MIN(MAX(event.deltaY, -maxStep), maxStep);
    if (!_dragStarted) {
        if (fabs(_dragTranslation.x) < 2.0 && fabs(_dragTranslation.y) < 2.0) {
            return;
        }
        _dragStarted = YES;
        if (self.dragHandler) {
            self.dragHandler(NSGestureRecognizerStateBegan, NSZeroPoint);
        }
    }

    if (self.dragHandler) {
        self.dragHandler(NSGestureRecognizerStateChanged, _dragTranslation);
    }
}

- (void)mouseUp:(NSEvent *)event {
    if (_interactionCancelled) {
        _interactionCancelled = NO;
        _dragStarted = NO;
        return;
    }
    [self finishInteractionWithEvent:event];
}

- (void)finishInteractionWithEvent:(NSEvent *)event {
    BOOL wasDragging = _dragStarted;
    _dragStarted = NO;
    _interactionCancelled = YES;
    if (wasDragging) {
        if (self.dragHandler) {
            self.dragHandler(NSGestureRecognizerStateEnded, _dragTranslation);
        }
    } else if (self.activationHandler && event.type == NSEventTypeLeftMouseUp) {
        self.activationHandler(event);
    }
}

- (void)cancelPendingInteraction {
    BOOL wasDragging = _dragStarted;
    _dragStarted = NO;
    _interactionCancelled = YES;
    if (wasDragging && self.dragHandler) {
        self.dragHandler(NSGestureRecognizerStateEnded, _dragTranslation);
    }
}

- (void)mouseMoved:(NSEvent *)event {
    [super mouseMoved:event];
    if (self.hoverHandler) {
        self.hoverHandler(YES);
    }
}

+ (CGPathRef)cgPathFromBezierPath:(NSBezierPath *)bezierPath {
    NSInteger numElements = bezierPath.elementCount;
    if (numElements == 0) {
        return CGPathCreateMutable();
    }

    CGMutablePathRef path = CGPathCreateMutable();
    NSPoint points[3];
    for (NSInteger i = 0; i < numElements; i++) {
        switch ([bezierPath elementAtIndex:i associatedPoints:points]) {
            case NSBezierPathElementMoveTo:
                CGPathMoveToPoint(path, NULL, points[0].x, points[0].y);
                break;
            case NSBezierPathElementLineTo:
                CGPathAddLineToPoint(path, NULL, points[0].x, points[0].y);
                break;
            case NSBezierPathElementCurveTo:
                CGPathAddCurveToPoint(path, NULL, points[0].x, points[0].y, points[1].x, points[1].y, points[2].x, points[2].y);
                break;
            case NSBezierPathElementClosePath:
                CGPathCloseSubpath(path);
                break;
            case NSBezierPathElementQuadraticCurveTo:
                CGPathAddQuadCurveToPoint(path, NULL, points[0].x, points[0].y, points[1].x, points[1].y);
                break;
        }
    }

    return path;
}

@end
