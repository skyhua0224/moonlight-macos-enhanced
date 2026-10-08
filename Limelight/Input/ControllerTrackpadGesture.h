#pragma once
#include <stdbool.h>
#include <math.h>
#include <stdint.h>

typedef struct {
    uint32_t buttons;
    uint8_t leftTrigger, rightTrigger;
    int16_t leftX, leftY, rightX, rightY;
} ControllerGamepadState;

static inline bool ControllerGamepadStateEqual(ControllerGamepadState a, ControllerGamepadState b) {
    return a.buttons == b.buttons && a.leftTrigger == b.leftTrigger && a.rightTrigger == b.rightTrigger &&
        a.leftX == b.leftX && a.leftY == b.leftY && a.rightX == b.rightX && a.rightY == b.rightY;
}

// Original contact-state adapter for Apple's Game Controller callbacks.
typedef struct {
    float x[2], y[2];
    float anchorX, anchorY;
    unsigned contacts;
    bool scrollGesture;
    unsigned scrollAxis;
    unsigned maximumContacts;
    float originX[2], originY[2];
    float maximumTravelSquared;
} ControllerTrackpadGesture;

typedef struct {
    float dx, dy;
    bool scroll;
} ControllerTrackpadDelta;

static inline bool ControllerTrackpadUpdate(ControllerTrackpadGesture *state, unsigned finger,
                                            bool touching, float x, float y) {
    if (finger > 1 || !isfinite(x) || !isfinite(y)) return false;
    unsigned oldContacts = state->contacts;
    if (touching) {
        if (oldContacts == 0) {
            state->maximumContacts = 0;
            state->maximumTravelSquared = 0;
            state->scrollAxis = 0;
        }
        if ((oldContacts & (1u << finger)) == 0) {
            state->originX[finger] = x;
            state->originY[finger] = y;
        } else {
            float dx = x - state->originX[finger], dy = y - state->originY[finger];
            state->maximumTravelSquared = fmaxf(state->maximumTravelSquared, dx * dx + dy * dy);
        }
        state->x[finger] = x;
        state->y[finger] = y;
        state->contacts |= 1u << finger;
        unsigned count = state->contacts == 3 ? 2 : 1;
        if (count > state->maximumContacts) state->maximumContacts = count;
    } else {
        // A release can report a reset coordinate; it is never movement.
        state->contacts &= ~(1u << finger);
    }
    if (state->contacts == oldContacts) return false;
    if (state->contacts == 3) state->scrollGesture = true;
    if (state->contacts == 0) state->scrollGesture = false;
    if (state->contacts == 3) {
        state->anchorX = (state->x[0] + state->x[1]) * 0.5f;
        state->anchorY = (state->y[0] + state->y[1]) * 0.5f;
    } else {
        unsigned remaining = state->contacts == 2 ? 1 : 0;
        state->anchorX = state->x[remaining];
        state->anchorY = state->y[remaining];
    }
    return true;
}

static inline ControllerTrackpadDelta ControllerTrackpadConsume(ControllerTrackpadGesture *state) {
    ControllerTrackpadDelta result = {0};
    if (state->contacts == 0 || (state->scrollGesture && state->contacts != 3)) return result;
    unsigned finger = state->contacts == 2 ? 1 : 0;
    float x = state->scrollGesture ? (state->x[0] + state->x[1]) * 0.5f : state->x[finger];
    float y = state->scrollGesture ? (state->y[0] + state->y[1]) * 0.5f : state->y[finger];
    float dx = x - state->anchorX, dy = y - state->anchorY;
    float threshold = state->scrollGesture ? 0.001f : 0.0008f;
    // Retain the anchor within the noise band so slow intentional movement
    // accumulates rather than being discarded at every callback.
    if (dx * dx + dy * dy < threshold * threshold) return result;
    state->anchorX = x;
    state->anchorY = y;
    result.dx = dx;
    result.dy = dy;
    result.scroll = state->scrollGesture;
    if (result.scroll) {
        // Lock a clearly vertical/horizontal gesture; small lateral noise
        // must not produce a second wheel stream while scrolling a list.
        if (state->scrollAxis == 0) {
            if (fabsf(dy) > fabsf(dx) * 1.8f) state->scrollAxis = 1;
            else if (fabsf(dx) > fabsf(dy) * 1.8f) state->scrollAxis = 2;
        }
        if (state->scrollAxis == 1) result.dx = 0;
        if (state->scrollAxis == 2) result.dy = 0;
    }
    return result;
}
