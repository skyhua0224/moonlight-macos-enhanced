//
//  FreeMouseVirtualCursor.h
//
//  The arithmetic of the CoreHID free-mouse virtual cursor, with no AppKit in it so a plain C compiler can run it
//  (tests/free-mouse-truth). HIDSupport+Pointer.m owns one of these under its lock and feeds it:
//    advance   the raw CoreHID motion, scaled to view points (the cursor moves ahead of the system pointer),
//    anchor    a pointer position that is taken as the truth, with no correction sent,
//    reconcile a pointer position that is checked against the cursor; a drift over the threshold re-anchors it
//              and asks for a position correction to the host.
//  The cursor also learns the gain between the raw motion and the pointer from each anchor and reconcile.
//
//  The pointer position handed to anchor/reconcile and the raw motion summed since the previous anchor must describe
//  the same instant. A position stamped when an AppKit event was created and read after the main thread got to it
//  lags the raw motion by the event's queue time: the learned gain falls short, and every reconcile pulls the cursor
//  back by (speed x queue time). StreamViewController+MouseCapture.m therefore reconciles against the live pointer
//  (NSEvent.mouseLocation, "the current mouse position"), not against an event's locationInWindow.
//

#ifndef MLFreeMouseVirtualCursor_h
#define MLFreeMouseVirtualCursor_h

#include <math.h>
#include <stdbool.h>
#include <stddef.h>

typedef struct {
    double x;
    double y;
} MLFreeMousePoint;

typedef struct {
    bool hasAnchor;
    MLFreeMousePoint point;          // where the host cursor is believed to be
    MLFreeMousePoint lastAnchor;     // the pointer position of the previous anchor or reconcile
    MLFreeMousePoint gain;           // learned view points of pointer motion per view point of raw motion
    MLFreeMousePoint rawSinceAnchor; // raw motion (view points) summed since lastAnchor
} MLFreeMouseVirtualCursor;

static inline double MLFreeMouseClampCoordinate(double value, double upperBound) {
    if (!isfinite(value)) {
        return 0.0;
    }
    if (!isfinite(upperBound) || upperBound <= 0.0) {
        return 0.0;
    }
    if (value < 0.0) {
        return 0.0;
    }
    if (value > upperBound) {
        return upperBound;
    }
    return value;
}

static inline MLFreeMousePoint MLFreeMouseClampPoint(MLFreeMousePoint point, double width, double height) {
    MLFreeMousePoint clamped = {
        MLFreeMouseClampCoordinate(point.x, width > 0.0 ? width : 0.0),
        MLFreeMouseClampCoordinate(point.y, height > 0.0 ? height : 0.0),
    };
    return clamped;
}

static inline double MLFreeMouseClampGain(double value) {
    if (!isfinite(value)) {
        return 1.0;
    }
    if (value < 0.25) {
        return 0.25;
    }
    if (value > 4.0) {
        return 4.0;
    }
    return value;
}

static inline double MLFreeMouseBlendGain(double currentGain, double rawDelta, double observedDelta) {
    if (!isfinite(rawDelta) || !isfinite(observedDelta)) {
        return currentGain;
    }
    if (fabs(rawDelta) < 0.5 || fabs(observedDelta) < 0.25) {
        return currentGain;
    }
    if ((rawDelta > 0.0 && observedDelta < 0.0) || (rawDelta < 0.0 && observedDelta > 0.0)) {
        return currentGain;
    }

    double sample = MLFreeMouseClampGain(fabs(observedDelta / rawDelta));
    if (!isfinite(currentGain) || currentGain <= 0.0) {
        return sample;
    }

    return MLFreeMouseClampGain((currentGain * 0.82) + (sample * 0.18));
}

static inline void MLFreeMouseVirtualCursorReset(MLFreeMouseVirtualCursor *cursor) {
    cursor->hasAnchor = false;
    cursor->point = (MLFreeMousePoint){0.0, 0.0};
    cursor->lastAnchor = (MLFreeMousePoint){0.0, 0.0};
    cursor->gain = (MLFreeMousePoint){1.0, 1.0};
    cursor->rawSinceAnchor = (MLFreeMousePoint){0.0, 0.0};
}

/// Moves the cursor by raw motion already in view points (y up). Returns the new position, clamped to the view.
static inline MLFreeMousePoint MLFreeMouseVirtualCursorAdvance(MLFreeMouseVirtualCursor *cursor,
                                                               double viewDeltaX,
                                                               double viewDeltaY,
                                                               double width,
                                                               double height) {
    MLFreeMousePoint predicted = cursor->point;
    predicted.x += viewDeltaX * MLFreeMouseClampGain(cursor->gain.x);
    predicted.y += viewDeltaY * MLFreeMouseClampGain(cursor->gain.y);
    predicted = MLFreeMouseClampPoint(predicted, width, height);
    cursor->rawSinceAnchor.x += viewDeltaX;
    cursor->rawSinceAnchor.y += viewDeltaY;
    cursor->point = predicted;
    return predicted;
}

static inline void MLFreeMouseVirtualCursorLearn(MLFreeMouseVirtualCursor *cursor,
                                                 MLFreeMousePoint pointer,
                                                 bool blendGain) {
    if (cursor->hasAnchor && blendGain) {
        cursor->gain.x = MLFreeMouseBlendGain(cursor->gain.x, cursor->rawSinceAnchor.x,
                                              pointer.x - cursor->lastAnchor.x);
        cursor->gain.y = MLFreeMouseBlendGain(cursor->gain.y, cursor->rawSinceAnchor.y,
                                              pointer.y - cursor->lastAnchor.y);
    }
}

/// Takes the pointer position as the truth. Nothing is sent to the host for it.
static inline void MLFreeMouseVirtualCursorAnchor(MLFreeMouseVirtualCursor *cursor,
                                                  MLFreeMousePoint pointer,
                                                  double width,
                                                  double height,
                                                  bool blendGain) {
    MLFreeMousePoint clamped = MLFreeMouseClampPoint(pointer, width, height);
    MLFreeMouseVirtualCursorLearn(cursor, clamped, blendGain);
    cursor->point = clamped;
    cursor->lastAnchor = clamped;
    cursor->rawSinceAnchor = (MLFreeMousePoint){0.0, 0.0};
    cursor->hasAnchor = true;
}

/// Checks the pointer against the cursor and re-anchors on it. Returns true when the host needs a position
/// correction: no anchor yet, or the cursor was more than `threshold` view points away on either axis.
/// `driftOut`, when given, receives that distance (0 for the first anchor).
static inline bool MLFreeMouseVirtualCursorReconcile(MLFreeMouseVirtualCursor *cursor,
                                                     MLFreeMousePoint pointer,
                                                     double width,
                                                     double height,
                                                     bool blendGain,
                                                     double threshold,
                                                     double *driftOut) {
    MLFreeMousePoint clamped = MLFreeMouseClampPoint(pointer, width, height);
    bool correct = true;
    double drift = 0.0;
    if (cursor->hasAnchor) {
        MLFreeMouseVirtualCursorLearn(cursor, clamped, blendGain);
        double driftX = fabs(clamped.x - cursor->point.x);
        double driftY = fabs(clamped.y - cursor->point.y);
        double limit = threshold > 0.0 ? threshold : 0.0;
        correct = driftX > limit || driftY > limit;
        drift = driftX > driftY ? driftX : driftY;
    }
    cursor->point = clamped;
    cursor->lastAnchor = clamped;
    cursor->rawSinceAnchor = (MLFreeMousePoint){0.0, 0.0};
    cursor->hasAnchor = true;
    if (driftOut != NULL) {
        *driftOut = drift;
    }
    return correct;
}

#endif /* MLFreeMouseVirtualCursor_h */
