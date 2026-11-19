//
//  FreeMouseLivePointer.h
//
//  The system pointer, read from a thread that is not the main thread, in the stream view's coordinates. Plain C, so
//  tests/free-mouse-truth can run it.
//
//  The CoreHID free-mouse virtual cursor is reconciled against the pointer. The main thread gets the AppKit mouse
//  events that used to trigger that, and it gets them late and coalesced when it is busy (about 40 a second, 16 ms old,
//  in the log of a user with a 1000 Hz mouse); the cursor then drifts between reconciles and every reconcile is a visible
//  step. The pointer itself can be read at any time: CGEventCreate(NULL) + CGEventGetLocation return it in global
//  display coordinates (points, origin at the top left of the main display). The view's position in those
//  coordinates is only known to the main thread, so the main thread calibrates a fixed offset against NSEvent
//  mouseLocation when it handles an event, and the reconcile thread applies it.
//
//    viewX = cgX + ax
//    viewY = ySign * cgY + by      (ySign is -1 for a view whose y axis points up, +1 for a flipped view)
//

#ifndef MLFreeMouseLivePointer_h
#define MLFreeMouseLivePointer_h

#include <math.h>
#include <stdbool.h>

#include "FreeMouseVirtualCursor.h"

typedef struct {
    bool valid;
    double ax;
    double by;
    double ySign;
    double width;      // the view's size, in points
    double height;
    double stamp;      // when it was calibrated (seconds, any monotonic clock)
} MLLivePointerMap;

/// Calibrates the map: the pointer was at (cgX, cgY) in global coordinates and at (viewX, viewY) in the view, at the
/// same instant.
static inline MLLivePointerMap MLLivePointerMapCalibrate(double cgX, double cgY, double viewX, double viewY,
                                                         bool viewFlipped, double width, double height,
                                                         double stampSeconds) {
    MLLivePointerMap map = {false, 0.0, 0.0, viewFlipped ? 1.0 : -1.0, width, height, stampSeconds};
    if (!isfinite(cgX) || !isfinite(cgY) || !isfinite(viewX) || !isfinite(viewY) ||
        !isfinite(width) || !isfinite(height) || width <= 0.0 || height <= 0.0) {
        return map;
    }
    map.ax = viewX - cgX;
    map.by = viewY - map.ySign * cgY;
    map.valid = true;
    return map;
}

/// The view position of a pointer read at (cgX, cgY). False when the map is missing, older than maxAge seconds (the
/// view may have moved since), or the pointer is more than `tolerance` points outside the view.
static inline bool MLLivePointerMapToView(const MLLivePointerMap *map, double cgX, double cgY, double nowSeconds,
                                          double maxAgeSeconds, double tolerance, MLFreeMousePoint *out) {
    if (map == NULL || !map->valid || !isfinite(cgX) || !isfinite(cgY)) {
        return false;
    }
    double age = nowSeconds - map->stamp;
    if (!(age >= 0.0 && age <= maxAgeSeconds)) {
        return false;
    }
    MLFreeMousePoint view = {cgX + map->ax, map->ySign * cgY + map->by};
    if (view.x < -tolerance || view.y < -tolerance ||
        view.x > map->width + tolerance || view.y > map->height + tolerance) {
        return false;
    }
    if (out != NULL) {
        *out = view;
    }
    return true;
}

#endif /* MLFreeMouseLivePointer_h */
