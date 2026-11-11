#include "../../Limelight/Input/DS5UIButtons.h"
#include "../../core/interaction/ds5-core/include/alkaidlab/ds5_core/ds5_core.h"

#include <stdio.h>
#include <string.h>

static int failures;

#define CHECK(condition) \
    do { \
        if (!(condition)) { \
            fprintf(stderr, "%s:%d: check failed: %s\n", __FILE__, __LINE__, #condition); \
            failures++; \
        } \
    } while (0)

// A USB input report with the given core buttons, hat and left stick, parsed back by the real core
// parser, so the test covers the bit layout the bridge actually delivers.
static uint32_t ui(uint64_t buttons, uint8_t hat, uint8_t lx, uint8_t ly) {
    AlkDs5State state;
    memset(&state, 0, sizeof(state));
    state.struct_size = sizeof(state);
    state.abi = ALK_DS5_CORE_ABI_VERSION;
    state.hat = hat;
    state.buttons = buttons;
    state.left_x = lx;
    state.left_y = ly;
    state.right_x = 128;
    state.right_y = 128;
    uint8_t report[ALK_DS5_USB_INPUT_REPORT_BYTES];
    size_t length = 0;
    CHECK(alk_ds5_build_input_report(&state, report, sizeof(report), &length) == ALK_DS5_OK);
    AlkDs5State parsed;
    memset(&parsed, 0, sizeof(parsed));
    parsed.struct_size = sizeof(parsed);
    parsed.abi = ALK_DS5_CORE_ABI_VERSION;
    CHECK(alk_ds5_parse_input_report(report, length, &parsed) == ALK_DS5_OK);
    return ds5_ui_buttons(parsed.buttons, parsed.hat, parsed.left_x, parsed.left_y);
}

static void testButtons(void) {
    CHECK(ui(0, 8, 128, 128) == 0);
    CHECK(ui(1u << DS5UI_CORE_CROSS, 8, 128, 128) == DS5UI_A);
    CHECK(ui(1u << DS5UI_CORE_CIRCLE, 8, 128, 128) == DS5UI_B);
    CHECK(ui(1u << DS5UI_CORE_SQUARE, 8, 128, 128) == DS5UI_X);
    CHECK(ui(1u << DS5UI_CORE_TRIANGLE, 8, 128, 128) == DS5UI_Y);
    CHECK(ui(1u << DS5UI_CORE_OPTIONS, 8, 128, 128) == DS5UI_MENU);
    CHECK(ui(1u << DS5UI_CORE_CREATE, 8, 128, 128) == DS5UI_VIEW);
    CHECK(ui(1u << DS5UI_CORE_L1, 8, 128, 128) == DS5UI_LB);
    CHECK(ui(1u << DS5UI_CORE_R1, 8, 128, 128) == DS5UI_RB);
    // L2, R2, L3, R3, PS, touchpad and Mute add no UI bit here (the triggers are ds5_ui_triggers, with hysteresis)
    CHECK(ui((1u << 6) | (1u << 7) | (1u << 10) | (1u << 11) | (1u << 12) | (1u << 13) | (1u << 14), 8, 128, 128) == 0);
}

static void testHat(void) {
    CHECK(ui(0, 0, 128, 128) == DS5UI_UP);
    CHECK(ui(0, 2, 128, 128) == DS5UI_RIGHT);
    CHECK(ui(0, 4, 128, 128) == DS5UI_DOWN);
    CHECK(ui(0, 6, 128, 128) == DS5UI_LEFT);
    CHECK(ui(0, 1, 128, 128) == (DS5UI_UP | DS5UI_RIGHT));
    CHECK(ui(0, 5, 128, 128) == (DS5UI_DOWN | DS5UI_LEFT));
    CHECK(ui(0, 8, 128, 128) == 0);
    CHECK(ui(0, 15, 128, 128) == 0);
}

static void testStick(void) {
    CHECK(ui(0, 8, 128, 0) == DS5UI_UP);
    CHECK(ui(0, 8, 128, 255) == DS5UI_DOWN);
    CHECK(ui(0, 8, 0, 128) == DS5UI_LEFT);
    CHECK(ui(0, 8, 255, 128) == DS5UI_RIGHT);
    // a stick pushed down also reads a little sideways: only the stronger axis counts
    CHECK(ui(0, 8, 190, 255) == DS5UI_DOWN);
    CHECK(ui(0, 8, 255, 190) == DS5UI_RIGHT);
    // below the threshold nothing happens
    CHECK(ui(0, 8, 128, 180) == 0);
    CHECK(ui(0, 8, 90, 128) == 0);
}

static void testScroll(void) {
    CHECK(ds5_ui_scroll(0) > 0.9f);
    CHECK(ds5_ui_scroll(255) < -0.9f);
    CHECK(ds5_ui_scroll(128) > -0.01f && ds5_ui_scroll(128) < 0.01f);
}

// A report with the given trigger bytes, parsed back by the core parser, then mapped with the hysteresis.
static uint32_t triggersFromReport(uint32_t previous, uint8_t l2, uint8_t r2, uint64_t buttons) {
    AlkDs5State state;
    memset(&state, 0, sizeof(state));
    state.struct_size = sizeof(state);
    state.abi = ALK_DS5_CORE_ABI_VERSION;
    state.hat = 8;
    state.buttons = buttons;
    state.left_x = state.left_y = state.right_x = state.right_y = 128;
    state.left_trigger = l2;
    state.right_trigger = r2;
    uint8_t report[ALK_DS5_USB_INPUT_REPORT_BYTES];
    size_t length = 0;
    CHECK(alk_ds5_build_input_report(&state, report, sizeof(report), &length) == ALK_DS5_OK);
    AlkDs5State parsed;
    memset(&parsed, 0, sizeof(parsed));
    parsed.struct_size = sizeof(parsed);
    parsed.abi = ALK_DS5_CORE_ABI_VERSION;
    CHECK(alk_ds5_parse_input_report(report, length, &parsed) == ALK_DS5_OK);
    return ds5_ui_triggers(previous, parsed.left_trigger, parsed.right_trigger, parsed.buttons);
}

static void testTriggers(void) {
    CHECK(triggersFromReport(0, 0, 0, 0) == 0);
    CHECK(triggersFromReport(0, 255, 0, 0) == DS5UI_LT);
    CHECK(triggersFromReport(0, 0, 255, 0) == DS5UI_RT);
    CHECK(triggersFromReport(0, 255, 255, 0) == (DS5UI_LT | DS5UI_RT));
    // pressed from 0.60 of the travel (153 of 255), not before
    CHECK(triggersFromReport(0, 140, 0, 0) == 0);
    CHECK(triggersFromReport(0, 152, 0, 0) == 0);
    CHECK(triggersFromReport(0, 153, 0, 0) == DS5UI_LT);
    // once down it stays down until the travel is below 0.35 (89 of 255): no chatter around the threshold
    CHECK(triggersFromReport(DS5UI_LT, 100, 0, 0) == DS5UI_LT);
    CHECK(triggersFromReport(DS5UI_LT, 90, 0, 0) == DS5UI_LT);
    CHECK(triggersFromReport(DS5UI_LT, 89, 0, 0) == 0);
    CHECK(triggersFromReport(DS5UI_LT, 0, 0, 0) == 0);
    // one trigger's state does not leak into the other
    CHECK(triggersFromReport(DS5UI_LT, 100, 120, 0) == DS5UI_LT);
    // the digital bits of a report also count
    CHECK(triggersFromReport(0, 0, 0, 1u << DS5UI_CORE_L2) == DS5UI_LT);
    CHECK(triggersFromReport(0, 0, 0, 1u << DS5UI_CORE_R2) == DS5UI_RT);
    // a pull is one press: the edges of a slow pull that wobbles around both thresholds
    const uint8_t pull[] = {0, 60, 100, 150, 160, 170, 140, 120, 100, 95, 85, 80, 0, 120, 155, 200, 255, 90, 60, 0};
    uint32_t bits = 0;
    int rising = 0;
    for (size_t i = 0; i < sizeof(pull); i++) {
        uint32_t now = ds5_ui_triggers(bits, pull[i], 0, 0);
        if ((now & DS5UI_LT) && !(bits & DS5UI_LT)) rising++;
        bits = now;
    }
    CHECK(rising == 2);
    // the GameController path uses the same rule on a 0 .. 1 travel
    CHECK(ds5_ui_trigger_down(0.7f, false));
    CHECK(!ds5_ui_trigger_down(0.5f, false));
    CHECK(ds5_ui_trigger_down(0.5f, true));
    CHECK(!ds5_ui_trigger_down(0.3f, true));
    CHECK(!ds5_ui_trigger_down(0.0f, false));
    CHECK(ds5_ui_trigger_down(1.0f, true));
    // the bits sit where the UI enum of ControllerNavigation.m expects them
    CHECK(DS5UI_LT == (1 << 12) && DS5UI_RT == (1 << 13));
}

int main(void) {
    testButtons();
    testHat();
    testStick();
    testScroll();
    testTriggers();
    if (failures != 0) {
        fprintf(stderr, "%d failure(s)\n", failures);
        return 1;
    }
    printf("ds5-ui-pad: all checks passed\n");
    return 0;
}
