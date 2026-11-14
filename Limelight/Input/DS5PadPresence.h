#pragma once

// Which virtual pad the host should have for the pads that exist on this Mac. Header-only C so
// tests/ds5-presence builds it without Apple frameworks.
//
// The host creates a pad when it hears of one (arrival packet, or a multi-controller packet whose
// active mask has the pad's bit) and frees it when a multi-controller packet clears the bit. So:
//   * the active mask is the set of player numbers that have a real pad now, never a constant;
//   * a pad that goes away sends one packet with its bit cleared;
//   * nothing is ever sent for a number without a real pad (a neutral event would create it).

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define DS5_PAD_MAX 4

// The active mask for the numbers in `assigned` (bit n set: player n has a pad).
static inline uint16_t ds5_pad_active_mask(unsigned assigned) { return (uint16_t)(assigned & ((1u << DS5_PAD_MAX) - 1u)); }

// The number for a pad that appears: its remembered number when that is still free (so a pad that
// comes back is the same player), otherwise the lowest free one. -1 when all four are taken.
static inline int ds5_pad_choose_number(unsigned assigned, int remembered) {
  if (remembered >= 0 && remembered < DS5_PAD_MAX && (assigned & (1u << remembered)) == 0u) return remembered;
  for (int number = 0; number < DS5_PAD_MAX; number++) {
    if ((assigned & (1u << number)) == 0u) return number;
  }
  return -1;
}

// Whether a neutral or any other packet may be sent for this pad: it must still exist and the host
// must have heard of it already.
static inline bool ds5_pad_may_send(bool padExists, bool announced) { return padExists && announced; }

// The HID driver (pads read straight from IOHIDManager) may send only after it parsed a report from a
// real pad. Without one, any controller packet would create a virtual pad on the host.
static inline bool ds5_hid_may_send(bool hidPadReportSeen) { return hidPadReportSeen; }

// The slot whose pad is this very object, or -1. GameController's player number cannot be the key: the
// host's LED requests rewrite it (down to "unset") and a Bluetooth reconnect resets it.
static inline int ds5_pad_slot_for_identity(const void *const *owners, int count, const void *identity) {
  if (identity == NULL) return -1;
  for (int slot = 0; slot < count; slot++) {
    if (owners[slot] == identity) return slot;
  }
  return -1;
}
