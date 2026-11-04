#define _POSIX_C_SOURCE 200112L
#include "../../Limelight/Input/DS5BluetoothPolicy.h"

#include <stdlib.h>
#include <stdio.h>

static int failures;

#define CHECK(condition) \
    do { \
        if (!(condition)) { \
            fprintf(stderr, "%s:%d: check failed: %s\n", __FILE__, __LINE__, #condition); \
            failures++; \
        } \
    } while (0)

int main(void) {
    unsetenv("DS5_BT_FULL_PCM");
    bool conflict = true;
    // Defaults change nothing.
    CHECK(ds5_resolve_bluetooth_mode(0, 0, &conflict) == DS5_BT_AUTO && !conflict);
    // Key 10 alone.
    CHECK(ds5_resolve_bluetooth_mode(1, 0, &conflict) == DS5_BT_IR && !conflict);
    CHECK(ds5_resolve_bluetooth_mode(2, 0, &conflict) == DS5_BT_RUMBLE && !conflict);
    CHECK(ds5_resolve_bluetooth_mode(3, 0, &conflict) == DS5_BT_OFF && !conflict);
    // Key 100 alone: legacy is rumble.
    CHECK(ds5_resolve_bluetooth_mode(0, 1, &conflict) == DS5_BT_RUMBLE && !conflict);
    CHECK(ds5_resolve_bluetooth_mode(0, 2, &conflict) == DS5_BT_IR && !conflict);
    CHECK(ds5_resolve_bluetooth_mode(0, 3, &conflict) == DS5_BT_OFF && !conflict);
    CHECK(ds5_resolve_bluetooth_mode(0, 4, &conflict) == DS5_BT_PCM && !conflict);
    CHECK(ds5_resolve_bluetooth_mode(1, 4, &conflict) == DS5_BT_PCM && conflict);
    // Both explicit and equal: no conflict. Different: key 100 wins and a conflict is reported.
    CHECK(ds5_resolve_bluetooth_mode(2, 1, &conflict) == DS5_BT_RUMBLE && !conflict);
    CHECK(ds5_resolve_bluetooth_mode(1, 3, &conflict) == DS5_BT_OFF && conflict);
    CHECK(ds5_resolve_bluetooth_mode(3, 2, &conflict) == DS5_BT_IR && conflict);
    // Out-of-range values read as auto.
    CHECK(ds5_resolve_bluetooth_mode(9, -1, 0) == DS5_BT_AUTO);
    // Negotiation and fallbacks.
    CHECK(ds5_bluetooth_negotiates_ir(DS5_BT_AUTO) && ds5_bluetooth_negotiates_ir(DS5_BT_IR));
    CHECK(ds5_bluetooth_negotiates_ir(DS5_BT_PCM));
    CHECK(!ds5_bluetooth_negotiates_ir(DS5_BT_RUMBLE) && !ds5_bluetooth_negotiates_ir(DS5_BT_OFF));
    CHECK(!ds5_bluetooth_requests_full_pcm(0, DS5_BT_AUTO));
    CHECK(ds5_bluetooth_requests_full_pcm(4, DS5_BT_IR));
    CHECK(!ds5_bluetooth_requests_full_pcm(0, DS5_BT_IR));
    CHECK(!ds5_bluetooth_requests_full_pcm(2, DS5_BT_IR));
    setenv("DS5_BT_FULL_PCM", "1", 1);
    CHECK(ds5_bluetooth_requests_full_pcm(0, DS5_BT_AUTO));
    CHECK(!ds5_bluetooth_requests_full_pcm(0, DS5_BT_IR));
    CHECK(!ds5_bluetooth_requests_full_pcm(2, DS5_BT_IR));
    unsetenv("DS5_BT_FULL_PCM");
    CHECK(!ds5_bluetooth_requests_full_pcm(0, DS5_BT_AUTO));
    CHECK(ds5_full_pcm_for_link(true, DS5_LINK_BLUETOOTH, false, false));
    CHECK(ds5_full_pcm_for_link(true, DS5_LINK_NONE, false, false));
    CHECK(ds5_full_pcm_for_link(true, DS5_LINK_UNKNOWN, false, false));
    CHECK(!ds5_full_pcm_for_link(true, DS5_LINK_USB, false, false));
    CHECK(!ds5_full_pcm_for_link(true, DS5_LINK_MIXED, false, false));
    CHECK(!ds5_full_pcm_for_link(true, DS5_LINK_BLUETOOTH, true, false));
    CHECK(!ds5_full_pcm_for_link(true, DS5_LINK_NONE, false, true));
    CHECK(!ds5_full_pcm_for_link(false, DS5_LINK_BLUETOOTH, false, false));
    CHECK(ds5_bluetooth_allows_rumble(DS5_BT_AUTO) && ds5_bluetooth_allows_rumble(DS5_BT_RUMBLE) &&
          ds5_bluetooth_allows_rumble(DS5_BT_IR) && !ds5_bluetooth_allows_rumble(DS5_BT_OFF));
    CHECK(ds5_bluetooth_allows_motor_fallback(DS5_BT_AUTO) && !ds5_bluetooth_allows_motor_fallback(DS5_BT_IR));
    // Rate cap: a limit, never a raise; 0 stays 0; the cap itself is clamped.
    CHECK(ds5_capped_report_rate(250, 250) == 250);
    CHECK(ds5_capped_report_rate(250, 1000) == 250);
    CHECK(ds5_capped_report_rate(250, 120) == 120);
    CHECK(ds5_capped_report_rate(0, 120) == 0);
    CHECK(ds5_capped_report_rate(250, 5) == 30);
    CHECK(ds5_capped_report_rate(2000, 5000) == 1000);
    CHECK(ds5_capped_report_rate(20, 250) == 20);
    if (failures != 0) { fprintf(stderr, "%d failure(s)\n", failures); return 1; }
    printf("ds5 bluetooth policy tests passed\n");
    return 0;
}
