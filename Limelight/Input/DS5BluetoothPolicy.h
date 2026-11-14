#pragma once

#include <stdbool.h>
#include <stdlib.h>

// Client side of the tuning keys that belong to the client (host tuning catalog ALK-DS5T/1):
//   10  ds5.haptics.bt.fallback   auto / ir / rumble / off
//   100 ds5.compat.btOutput       auto / legacy / ir / off / pcm
//                                 (wins over key 10 when it is not auto; pcm is experimental haptics-only and off unless selected)
//   101 ds5.compat.reportRateCapHz 30..1000 Hz, default 250  (upper limit of the motion report rate)
// Header-only C so tests/ds5-policy builds it without Apple frameworks.
//
// Key 10 semantics (catalog): a Bluetooth DualSense has no four-channel audio endpoint, so `auto`
// prefers CoreHaptics from the host's analysed (IR) haptics, then plain rumble, and the last choice is
// off; an explicit `ir` reports the haptics unavailable instead of falling back when the device cannot
// render IR; `rumble` asks the host for plain rumble only; `off` plays no haptics on Bluetooth.
// Key 100 is the coarse choice of the Bluetooth output path: legacy is plain rumble, ir is analysed
// haptics, off is nothing, pcm is the experimental actuator-PCM path. The pad speaker stays on USB.
// Automatic (with key 10 still automatic) asks for analysed haptics (IR v2) and does not
// request PCM. Value 4 is off unless the user selects it. DS5_BT_FULL_PCM=1 forces that
// experimental path when both keys are still automatic, without changing saved settings.
// Key 100 wins over key 10, and a disagreement between two explicit values is reported once.

typedef enum DS5BluetoothMode {
  DS5_BT_AUTO = 0,
  DS5_BT_IR = 1,
  DS5_BT_RUMBLE = 2,
  DS5_BT_OFF = 3,
  DS5_BT_PCM = 4,  // key 100 value 4: experimental haptics PCM, speaker stays on USB
} DS5BluetoothMode;

// What a synchronous HID snapshot saw at stream start. The launch flags are fixed then.
typedef enum DS5PadLink {
  DS5_LINK_NONE = 0,
  DS5_LINK_USB = 1,
  DS5_LINK_BLUETOOTH = 2,
  DS5_LINK_MIXED = 3,
  DS5_LINK_UNKNOWN = 4,
} DS5PadLink;

#define DS5_REPORT_RATE_CAP_MIN 30
#define DS5_REPORT_RATE_CAP_MAX 1000
#define DS5_REPORT_RATE_CAP_DEFAULT 250

// fallback: key 10 as 0 auto, 1 ir, 2 rumble, 3 off.
// btOutput: key 100 as 0 auto, 1 legacy, 2 ir, 3 off, 4 experimental haptics PCM.
static inline DS5BluetoothMode ds5_resolve_bluetooth_mode(int fallback, int btOutput, bool *conflict) {
  DS5BluetoothMode fromFallback = (fallback >= 0 && fallback <= 3) ? (DS5BluetoothMode)fallback : DS5_BT_AUTO;
  DS5BluetoothMode fromOutput = DS5_BT_AUTO;
  switch (btOutput) {
    case 1: fromOutput = DS5_BT_RUMBLE; break;
    case 2: fromOutput = DS5_BT_IR; break;
    case 3: fromOutput = DS5_BT_OFF; break;
    case 4: fromOutput = DS5_BT_PCM; break;
    default: break;
  }
  if (conflict != 0) *conflict = fromOutput != DS5_BT_AUTO && fromFallback != DS5_BT_AUTO && fromOutput != fromFallback;
  return fromOutput != DS5_BT_AUTO ? fromOutput : fromFallback;
}

// Whether the launch offers analysed haptics (IR v2) to the host for a Bluetooth pad.
// Full PCM keeps IR as well, so a USB pad that does not take the PCM path still gets the previous offer.
static inline bool ds5_bluetooth_negotiates_ir(DS5BluetoothMode mode) {
  return mode == DS5_BT_AUTO || mode == DS5_BT_IR || mode == DS5_BT_PCM;
}

// Explicit key 100 value 4, or DS5_BT_FULL_PCM=1 while both keys are still automatic.
// Automatic by itself stays on IR v2.
static inline bool ds5_bluetooth_requests_full_pcm(int btOutput, DS5BluetoothMode resolved) {
  if (btOutput == 4) return true;
  const char *forced = getenv("DS5_BT_FULL_PCM");
  return forced != NULL && forced[0] == '1' && forced[1] == '\0' && btOutput == 0 && resolved == DS5_BT_AUTO;
}

// Bluetooth, or no pad yet: ask for actuator PCM and the pad speaker. A USB pad,
// a mixed pair, or the USB PCM passthrough stays on the USB path. A USB audio
// endpoint with no confirmed Bluetooth pad does too.
static inline bool ds5_full_pcm_for_link(bool settingRequests, int link, bool usbPassthrough, bool usbEndpoint) {
  if (!settingRequests || usbPassthrough) return false;
  if (link == DS5_LINK_USB || link == DS5_LINK_MIXED) return false;
  if (usbEndpoint && link != DS5_LINK_BLUETOOTH) return false;
  return link == DS5_LINK_BLUETOOTH || link == DS5_LINK_NONE || link == DS5_LINK_UNKNOWN;
}

// Whether rumble reaches a Bluetooth DualSense at all.
static inline bool ds5_bluetooth_allows_rumble(DS5BluetoothMode mode) { return mode != DS5_BT_OFF; }

// Whether analysed haptics that CoreHaptics cannot render may fall back to plain rumble.
static inline bool ds5_bluetooth_allows_motor_fallback(DS5BluetoothMode mode) { return mode != DS5_BT_IR; }

// The motion report rate to run: what the host asked for, limited by the cap. 0 stays 0 (stop).
static inline unsigned ds5_capped_report_rate(unsigned hostRate, int cap) {
  if (hostRate == 0) return 0;
  const unsigned limit = (unsigned)(cap < DS5_REPORT_RATE_CAP_MIN ? DS5_REPORT_RATE_CAP_MIN
                                    : (cap > DS5_REPORT_RATE_CAP_MAX ? DS5_REPORT_RATE_CAP_MAX : cap));
  return hostRate < limit ? hostRate : limit;
}
