#pragma once

#include <stdbool.h>

// Feed monotonic seconds from NSProcessInfo.systemUptime. A settings change
// during a hold requires a release before another gesture can begin.
typedef struct {
    double began;
    bool tracking;
    bool consumed;
    bool blockedUntilRelease;
} ControllerMenuGesture;

static inline void ControllerMenuGestureInterrupt(ControllerMenuGesture *gesture,
                                                 bool pressed) {
    bool consumed = gesture->consumed && pressed;
    *gesture = (ControllerMenuGesture){
        .consumed = consumed,
        .blockedUntilRelease = pressed,
    };
}

static inline bool ControllerMenuGestureUpdate(ControllerMenuGesture *gesture,
                                              bool enabled,
                                              bool pressed,
                                              double now) {
    if (!pressed) {
        *gesture = (ControllerMenuGesture){0};
        return false;
    }
    if (!enabled) {
        ControllerMenuGestureInterrupt(gesture, true);
        return false;
    }
    if (gesture->blockedUntilRelease || gesture->consumed) {
        return false;
    }
    if (!gesture->tracking) {
        gesture->tracking = true;
        gesture->began = now;
    }
    if (now - gesture->began < 2.0) {
        return false;
    }
    gesture->consumed = true;
    return true;
}
