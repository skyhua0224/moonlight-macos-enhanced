#pragma once

// The DualSense Mute button. GameController has no button for it, so it is read from the raw HID
// input report (byte 10 bit 2 on USB, the same byte after the Bluetooth header; the ds5 core parses
// both into bit 14 of AlkDs5State.buttons) and merged into the button state the controller support
// sends to the host as MISC_FLAG, which is the Share/Mic/Capture/Mute flag of the protocol. Header-only
// C so the unit test in tests/ds5-buttons builds it with the core parsers.

#include <stdbool.h>
#include <stdint.h>

#include "Limelight.h"

#define DS5_CORE_BUTTON_MUTE_BIT 14

static inline bool ds5_raw_mute_pressed(uint64_t coreButtons) {
  return ((coreButtons >> DS5_CORE_BUTTON_MUTE_BIT) & 1u) != 0;
}

// GameController's flags with the raw Mute state folded in. The raw state only ever adds the flag; a
// flag GameController reports for another pad is kept, and the result is the same however many times
// either source reports the same state, so the sender's equal-state check suppresses repeats.
static inline uint32_t ds5_merge_mute_flag(uint32_t gameControllerFlags, bool rawMute) {
  return rawMute ? (gameControllerFlags | (uint32_t)MISC_FLAG) : gameControllerFlags;
}

// Whether a new raw sample is a change worth handing to the main queue.
static inline bool ds5_mute_changed(bool previous, bool current) { return previous != current; }
