#pragma once

// One DualSense can be attached by USB and by Bluetooth at the same time, and macOS then lists two HID devices for it.
// Each used to become its own raw pad ("player 0" and "player 1"): twice the input reports (380 a second instead of
// 250), a second set of feature reads, a motion source forced to GameController because there were two raw devices, and
// output writes that could go to the Bluetooth device. The two are the same pad when their serials are the same twelve
// hex digits (the pad's address); the USB one is kept. Header-only C so tests/ds5-twin builds it without Apple frameworks.

#include <stdbool.h>
#include <stddef.h>

// The pad address of a serial string: its twelve hex digits in lower case, ignoring separators. False when the string does
// not hold exactly twelve hex digits.
static inline bool ds5_serial_key(const char *serial, char out[13]) {
  if (serial == NULL) return false;
  size_t count = 0;
  for (const char *p = serial; *p != 0; p++) {
    char c = *p;
    if (c >= 'A' && c <= 'F') c = (char)(c - 'A' + 'a');
    const bool hex = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
    if (hex) {
      if (count >= 12) return false;
      out[count++] = c;
    } else if (c != ':' && c != '-' && c != ' ') {
      return false;
    }
  }
  if (count != 12) return false;
  out[12] = 0;
  return true;
}

typedef enum DS5TwinDecision {
  DS5_TWIN_NONE = 0,         // not twins: the new device is a pad of its own
  DS5_TWIN_IGNORE_NEW = 1,   // the pad is already served by a device that is at least as good
  DS5_TWIN_REPLACE_OLD = 2,  // the new device is the USB one: it takes the place of the Bluetooth device
} DS5TwinDecision;

static inline DS5TwinDecision ds5_twin_decide(bool sameKey, bool oldPresent, bool newIsUSB, bool oldIsUSB) {
  if (!sameKey || !oldPresent) return DS5_TWIN_NONE;
  if (newIsUSB && !oldIsUSB) return DS5_TWIN_REPLACE_OLD;
  return DS5_TWIN_IGNORE_NEW;
}
