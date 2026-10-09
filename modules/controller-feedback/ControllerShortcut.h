#pragma once
#include <stdbool.h>
#include <stdint.h>
#include <math.h>

// Transport-independent chord/hold recognition, fed monotonic seconds and
// the caller's button masks. No controller framework or wire types.
typedef struct {
    uint32_t sourceMask;
    double began;
    double holdSeconds;
    bool initialized, tracking, active, blockedUntilRelease;
} ControllerShortcutGesture;

static inline bool ControllerShortcutUpdate(ControllerShortcutGesture *state,
    uint32_t buttons, uint32_t sourceMask, double holdSeconds, bool enabled, double now) {
    double duration = isfinite(holdSeconds) ? fmin(5.0, fmax(0.0, holdSeconds)) : 0.0;
    if (state->initialized && (state->sourceMask != sourceMask || state->holdSeconds != duration)) {
        *state = (ControllerShortcutGesture){.initialized = true, .sourceMask = sourceMask,
            .blockedUntilRelease = (buttons & sourceMask) != 0};
    }
    state->initialized = true;
    state->sourceMask = sourceMask;
    state->holdSeconds = duration;
    if (!enabled || sourceMask == 0 || !isfinite(now)) {
        state->tracking = state->active = false;
        state->blockedUntilRelease = (buttons & sourceMask) != 0;
        return false;
    }
    if ((buttons & sourceMask) == 0) {
        state->tracking = state->active = state->blockedUntilRelease = false;
        return false;
    }
    if ((buttons & sourceMask) != sourceMask) {
        if (state->active) state->blockedUntilRelease = true;
        state->tracking = state->active = false;
        return false;
    }
    if (state->blockedUntilRelease) return false;
    if (!state->tracking) { state->tracking = true; state->began = now; }
    state->active = now - state->began >= duration;
    return state->active;
}
