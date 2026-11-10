//
//  MLEdgeMenuGeometry.h
//  Moonlight for macOS
//
//  Where the floating control ball (edge menu) sits. Pure geometry, Foundation only, so the unit test builds it
//  without AppKit. The ball view is `size` square; its visible plate is `plateRatio` of that, centred, the rest is
//  shadow room.
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

typedef NS_ENUM(NSInteger, MLEdgeMenuDock) {
    MLEdgeMenuDockLeft = 0,
    MLEdgeMenuDockRight,
    MLEdgeMenuDockTop,
    MLEdgeMenuDockBottom,
};

typedef struct {
    CGFloat size;               // ball view width = height
    CGFloat plateRatio;         // visible plate / ball view
    CGFloat plateEdgeGap;       // gap between the plate and the edge while it is shown
    CGFloat collapsedFraction;  // the part of the plate that stays on screen while it is tucked away (0...1)
    CGFloat crossInset;         // keep-out along the edge, at both ends (corner room)
} MLEdgeMenuMetrics;

typedef struct { CGFloat top, left, bottom, right; } MLEdgeMenuInsets;   // the safe area: notch, menu bar, rounded corners

/// The ball's frame inside `rect` (the stream view's bounds, y up).
///   tucked: idle, slid toward the edge so that `collapsedFraction` of the plate stays visible; NO: fully docked.
///   ratio:  position along the edge, 0...1.
/// The whole plate is always inside `rect` when it is not tucked, and at least `collapsedFraction` of it is inside
/// when it is tucked, on every display size; the safe area keeps it out from under a notch or the menu bar.
static inline CGRect MLEdgeMenuComputeFrame(CGRect rect, MLEdgeMenuInsets safe, MLEdgeMenuDock dock, CGFloat ratio,
                                            BOOL tucked, MLEdgeMenuMetrics m) {
    CGFloat size = m.size;
    CGFloat plate = size * m.plateRatio;
    CGFloat pad = (size - plate) / 2.0;
    CGFloat fraction = MIN(MAX(m.collapsedFraction, 0.0), 1.0);
    // Offset by the transparent margin around the plate so that the plate itself docks.
    CGFloat inset = tucked ? plate * fraction - plate - pad : m.plateEdgeGap - pad;
    BOOL vertical = dock == MLEdgeMenuDockLeft || dock == MLEdgeMenuDockRight;
    CGFloat lo, hi;
    if (vertical) {
        lo = CGRectGetMinY(rect) + MAX(m.crossInset, safe.bottom);
        hi = CGRectGetMaxY(rect) - size - MAX(m.crossInset, safe.top);
    } else {
        lo = CGRectGetMinX(rect) + MAX(m.crossInset, safe.left);
        hi = CGRectGetMaxX(rect) - size - MAX(m.crossInset, safe.right);
    }
    if (hi < lo) {
        // A view too small for the keep-out: centre the ball.
        CGFloat span = vertical ? CGRectGetHeight(rect) : CGRectGetWidth(rect);
        lo = hi = (vertical ? CGRectGetMinY(rect) : CGRectGetMinX(rect)) + MAX((span - size) / 2.0, 0.0);
    }
    CGFloat coordinate = lo + (hi - lo) * MIN(MAX(ratio, 0.0), 1.0);
    // The edge the ball docks to starts at the safe area (a notch cut at the top, rounded corners), tucked or not.
    switch (dock) {
        case MLEdgeMenuDockLeft:
            return CGRectMake(CGRectGetMinX(rect) + inset + safe.left, coordinate, size, size);
        case MLEdgeMenuDockTop:
            return CGRectMake(coordinate, CGRectGetMaxY(rect) - size - inset - safe.top, size, size);
        case MLEdgeMenuDockBottom:
            return CGRectMake(coordinate, CGRectGetMinY(rect) + inset + safe.bottom, size, size);
        case MLEdgeMenuDockRight:
        default:
            return CGRectMake(CGRectGetMaxX(rect) - size - inset - safe.right, coordinate, size, size);
    }
}

/// The part of the plate (as a rectangle) that lies inside `rect`; used to check and to log what the user sees.
static inline CGRect MLEdgeMenuVisiblePlate(CGRect frame, CGRect rect, MLEdgeMenuMetrics m) {
    CGFloat plate = m.size * m.plateRatio;
    CGFloat pad = (m.size - plate) / 2.0;
    CGRect plateRect = CGRectMake(frame.origin.x + pad, frame.origin.y + pad, plate, plate);
    return CGRectIntersection(plateRect, rect);
}
