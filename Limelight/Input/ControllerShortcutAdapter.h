#pragma once
#include "Limelight.h"

// Local analog markers used only by recognition/consumption; never wire buttons.
#define CONTROLLER_SHORTCUT_LEFT_TRIGGER_MARKER (UINT32_C(1) << 29)
#define CONTROLLER_SHORTCUT_RIGHT_TRIGGER_MARKER (UINT32_C(1) << 30)

// Runtime player keys for HID devices start here so they never share
// recognition state with GameController players 0–3.
#define CONTROLLER_SHORTCUT_HID_PLAYER_BASE 0x100

// Routing word returned by ControllerShortcutRuntime, in neutral button IDs:
// buttons withheld from the host, a touchpad press, and a short replayed tap.
static inline uint32_t ControllerShortcutRouteConsumed(uint64_t route) { return (uint32_t)(route & 0x1ffff); }
static inline bool ControllerShortcutRouteTouchpad(uint64_t route) { return (route & UINT64_C(0x80000000)) != 0; }
static inline uint32_t ControllerShortcutRouteReplay(uint64_t route) { return (uint32_t)((route >> 32) & 0x1ffff); }

// The persisted selection uses neutral physical-button IDs. Keep wire masks
// in this integration adapter, outside the reusable recognition policy.
static inline uint32_t ControllerShortcutProtocolMask(uint32_t selection) {
    static const uint32_t flags[] = {BACK_FLAG, PLAY_FLAG, LS_CLK_FLAG, RS_CLK_FLAG,
        LB_FLAG, RB_FLAG, A_FLAG, B_FLAG, X_FLAG, Y_FLAG, UP_FLAG, DOWN_FLAG, LEFT_FLAG, RIGHT_FLAG, TOUCHPAD_FLAG, CONTROLLER_SHORTCUT_LEFT_TRIGGER_MARKER, CONTROLLER_SHORTCUT_RIGHT_TRIGGER_MARKER};
    uint32_t result = 0;
    for (unsigned i = 0; i < sizeof(flags) / sizeof(flags[0]); i++)
        if (selection & (1u << i)) result |= flags[i];
    return result;
}
static inline uint32_t ControllerShortcutNeutralMask(uint32_t protocolButtons) {
    uint32_t result = 0;
    for (unsigned i = 0; i < 17; i++)
        if (protocolButtons & ControllerShortcutProtocolMask(1u << i)) result |= 1u << i;
    return result;
}
