// Behaviour matrix of the DualSense tuning keys that belong to the client: 10, 100, 101 and 105.
// Each key is set to its non-default values, the decision the client takes from it is measured, the
// extremes and the clamping are checked, and the default is restored and measured again.  Prints one
// ROW per key: ROW<TAB>key<TAB>name<TAB>PASS|FAIL<TAB>client<TAB>evidence.
#include "../../Limelight/Input/DS5BluetoothPolicy.h"

#include <stdio.h>
#include <string.h>

// ControllerIsFeedbackTarget, extracted from Limelight/Input/ControllerSupport.m by run.sh with
// "support." rewritten to "support->".
typedef struct ControllerSupport { long controllerFeedbackTarget; } ControllerSupport;
#define BOOL bool
#include "feedback_target.inc"

static char evidence[1024];
static int failed;

static void note(const char *format, int a, int b, int c, int d) {
  size_t used = strlen(evidence);
  snprintf(evidence + used, sizeof evidence - used, format, a, b, c, d);
}

#define EXPECT(cond, what) \
  do { \
    if (!(cond)) { \
      failed = 1; \
      size_t used = strlen(evidence); \
      snprintf(evidence + used, sizeof evidence - used, "FAILED(%s) ", what); \
    } \
  } while (0)

static void begin(void) { evidence[0] = 0; failed = 0; }
static void row(int key, const char *name) {
  printf("ROW\t%d\t%s\t%s\tclient\t%s\n", key, name, failed ? "FAIL" : "PASS", evidence);
}

// The behaviour of one Bluetooth mode as the stream setup and the feedback path see it.
static void mode_behaviour(DS5BluetoothMode mode, int out[3]) {
  out[0] = ds5_bluetooth_negotiates_ir(mode);
  out[1] = ds5_bluetooth_allows_rumble(mode);
  out[2] = ds5_bluetooth_allows_motor_fallback(mode);
}

static int same(const int a[3], const int b[3]) { return a[0] == b[0] && a[1] == b[1] && a[2] == b[2]; }

int main(void) {
  int baseline[3], other[3];
  mode_behaviour(ds5_resolve_bluetooth_mode(0, 0, 0), baseline);

  // Key 10: auto / ir / rumble / off.
  begin();
  note("default negotiates_ir=%d allows_rumble=%d motor_fallback=%d", baseline[0], baseline[1], baseline[2], 0);
  for (int value = 1; value <= 3; ++value) {
    mode_behaviour(ds5_resolve_bluetooth_mode(value, 0, 0), other);
    note(" | value %d -> ir=%d rumble=%d fallback=%d", value, other[0], other[1], other[2]);
    EXPECT(!same(baseline, other), "value changes no decision");
  }
  mode_behaviour(ds5_resolve_bluetooth_mode(2, 0, 0), other);
  EXPECT(!other[0] && other[1], "rumble: no IR, rumble allowed");
  mode_behaviour(ds5_resolve_bluetooth_mode(3, 0, 0), other);
  EXPECT(!other[0] && !other[1], "off: no IR, no rumble");
  mode_behaviour(ds5_resolve_bluetooth_mode(1, 0, 0), other);
  EXPECT(other[0] && !other[2], "ir: IR offered, no motor fallback");
  mode_behaviour(ds5_resolve_bluetooth_mode(9, 0, 0), other);
  EXPECT(same(baseline, other), "out of range must read as auto");
  mode_behaviour(ds5_resolve_bluetooth_mode(-1, 0, 0), other);
  EXPECT(same(baseline, other), "negative must read as auto");
  mode_behaviour(ds5_resolve_bluetooth_mode(2, 0, 0), other);
  mode_behaviour(ds5_resolve_bluetooth_mode(0, 0, 0), other);
  EXPECT(same(baseline, other), "restoring auto must restore the decisions");
  row(10, "ds5.haptics.bt.fallback");

  // Key 100: auto / legacy / ir / off, wins over key 10.
  begin();
  note("default ir=%d rumble=%d fallback=%d", baseline[0], baseline[1], baseline[2], 0);
  const DS5BluetoothMode expected_mode[4] = { DS5_BT_AUTO, DS5_BT_RUMBLE, DS5_BT_IR, DS5_BT_OFF };
  for (int value = 1; value <= 3; ++value) {
    mode_behaviour(ds5_resolve_bluetooth_mode(0, value, 0), other);
    note(" | value %d -> ir=%d rumble=%d fallback=%d", value, other[0], other[1], other[2]);
    EXPECT(!same(baseline, other), "value changes no decision");
    EXPECT(ds5_resolve_bluetooth_mode(0, value, 0) == expected_mode[value], "mapping of the value");
  }
  bool conflict = false;
  EXPECT(ds5_resolve_bluetooth_mode(3, 1, &conflict) == DS5_BT_RUMBLE && conflict, "key 100 wins over key 10 and the conflict is reported");
  EXPECT(ds5_resolve_bluetooth_mode(2, 1, &conflict) == DS5_BT_RUMBLE && !conflict, "equal explicit values do not conflict");
  EXPECT(ds5_resolve_bluetooth_mode(0, 9, 0) == DS5_BT_AUTO && ds5_resolve_bluetooth_mode(0, -4, 0) == DS5_BT_AUTO, "out of range reads as auto");
  mode_behaviour(ds5_resolve_bluetooth_mode(0, 0, 0), other);
  EXPECT(same(baseline, other), "restoring auto must restore the decisions");
  row(100, "ds5.compat.btOutput");

  // Key 101: the motion report rate is limited by the cap, never raised; the cap is clamped to 30..1000.
  begin();
  const unsigned host_rate = 250;
  const unsigned base_rate = ds5_capped_report_rate(host_rate, DS5_REPORT_RATE_CAP_DEFAULT);
  note("default cap 250 -> %d Hz for a host request of %d Hz", (int)base_rate, (int)host_rate, 0, 0);
  const int caps[] = { 30, 60, 120, 1000 };
  for (unsigned i = 0; i < sizeof caps / sizeof caps[0]; ++i) {
    const unsigned rate = ds5_capped_report_rate(host_rate, caps[i]);
    note(" | cap %d -> %d Hz", caps[i], (int)rate, 0, 0);
    EXPECT(rate == (host_rate < (unsigned)caps[i] ? host_rate : (unsigned)caps[i]), "rate is min(host, cap)");
  }
  EXPECT(ds5_capped_report_rate(host_rate, 120) < base_rate, "a lower cap must lower the rate");
  EXPECT(ds5_capped_report_rate(host_rate, 5) == 30, "cap below the minimum clamps to 30");
  EXPECT(ds5_capped_report_rate(2000, 5000) == 1000, "cap above the maximum clamps to 1000");
  EXPECT(ds5_capped_report_rate(0, 120) == 0, "a stop request stays a stop");
  EXPECT(ds5_capped_report_rate(host_rate, DS5_REPORT_RATE_CAP_DEFAULT) == base_rate, "restoring 250 must restore the rate");
  row(101, "ds5.compat.reportRateCapHz");

  // Key 105: auto (-1) delivers feedback to every controller, controllerN only to controller N.
  begin();
  ControllerSupport support = { -1 };
  int delivered_auto = 0;
  for (unsigned short n = 0; n < 4; ++n) delivered_auto += ControllerIsFeedbackTarget(&support, n);
  note("default auto delivers to %d of 4 controllers", delivered_auto, 0, 0, 0);
  EXPECT(delivered_auto == 4, "auto delivers to all");
  for (long target = 0; target < 4; ++target) {
    support.controllerFeedbackTarget = target;
    int delivered = 0, only = -1;
    for (unsigned short n = 0; n < 4; ++n) {
      if (ControllerIsFeedbackTarget(&support, n)) { delivered++; only = n; }
    }
    note(" | controller%d -> delivered to %d (controller %d)", (int)target + 1, delivered, only, 0);
    EXPECT(delivered == 1 && only == target, "exactly the chosen controller");
  }
  support.controllerFeedbackTarget = -1;
  delivered_auto = 0;
  for (unsigned short n = 0; n < 4; ++n) delivered_auto += ControllerIsFeedbackTarget(&support, n);
  EXPECT(delivered_auto == 4, "restoring auto must restore delivery to all");
  row(105, "ds5.feedback.target");
  return 0;
}
