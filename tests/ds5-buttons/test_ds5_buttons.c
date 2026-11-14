#include "../../Limelight/Input/DS5ButtonMerge.h"
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

static void usbReport(uint8_t report[ALK_DS5_USB_INPUT_REPORT_BYTES], uint64_t buttons) {
    AlkDs5State state;
    memset(&state, 0, sizeof(state));
    state.struct_size = sizeof(state);
    state.abi = ALK_DS5_CORE_ABI_VERSION;
    state.hat = 8;
    state.buttons = buttons;
    size_t length = 0;
    CHECK(alk_ds5_build_input_report(&state, report, ALK_DS5_USB_INPUT_REPORT_BYTES, &length) == ALK_DS5_OK);
}

// Bluetooth report 0x31: id, one header byte, then the common block that follows the id on USB; the
// last four bytes are the CRC with seed 0xa1.
static void btReport(uint8_t out[ALK_DS5_BT_INPUT_REPORT_BYTES], const uint8_t usb[ALK_DS5_USB_INPUT_REPORT_BYTES]) {
    memset(out, 0, ALK_DS5_BT_INPUT_REPORT_BYTES);
    out[0] = 0x31;
    memcpy(out + 2, usb + 1, ALK_DS5_USB_INPUT_REPORT_BYTES - 1);
    const uint32_t crc = alk_ds5_crc32_seed(0xa1, out, ALK_DS5_BT_INPUT_REPORT_BYTES - 4);
    for (int i = 0; i < 4; i++) out[ALK_DS5_BT_INPUT_REPORT_BYTES - 4 + i] = (uint8_t)(crc >> (8 * i));
}

static bool parsedMute(const uint8_t *report, size_t length, bool bluetooth) {
    AlkDs5ExtendedInput input;
    memset(&input, 0, sizeof(input));
    input.struct_size = sizeof(input);
    input.abi = ALK_DS5_CORE_ABI_VERSION;
    AlkDs5Error error = bluetooth ? alk_ds5_parse_bluetooth_input_report(report, length, &input)
                                  : alk_ds5_parse_input_report_ex(report, length, &input);
    CHECK(error == ALK_DS5_OK);
    return ds5_raw_mute_pressed(input.state.buttons);
}

static void testParse(void) {
    uint8_t usb[ALK_DS5_USB_INPUT_REPORT_BYTES], bt[ALK_DS5_BT_INPUT_REPORT_BYTES];
    usbReport(usb, 0);
    CHECK(!parsedMute(usb, sizeof(usb), false));
    usb[10] = 0x04;   // hid-playstation DS_BUTTONS2_MIC_MUTE
    CHECK(parsedMute(usb, sizeof(usb), false));
    btReport(bt, usb);
    CHECK(parsedMute(bt, sizeof(bt), true));
    usb[10] = 0x03;   // PS and touchpad click are not the Mute button
    CHECK(!parsedMute(usb, sizeof(usb), false));
    btReport(bt, usb);
    CHECK(!parsedMute(bt, sizeof(bt), true));
    // Other buttons around it do not disturb it.
    usbReport(usb, 0xffffull & ~(1ull << DS5_CORE_BUTTON_MUTE_BIT));
    CHECK(!parsedMute(usb, sizeof(usb), false));
    usbReport(usb, 1ull << DS5_CORE_BUTTON_MUTE_BIT);
    CHECK(usb[10] == 0x04 && usb[9] == 0 && (usb[8] & 0xf0) == 0);
    CHECK(parsedMute(usb, sizeof(usb), false));
    // The jack status byte (54) carries the mic-muted state, a different fact; it does not press the button.
    usbReport(usb, 0);
    usb[54] = 0x04;
    CHECK(!parsedMute(usb, sizeof(usb), false));
}

static void testMerge(void) {
    CHECK(ds5_merge_mute_flag(A_FLAG, false) == A_FLAG);
    CHECK(ds5_merge_mute_flag(A_FLAG, true) == (A_FLAG | MISC_FLAG));
    CHECK(ds5_merge_mute_flag(0, true) == MISC_FLAG);
    // GameController reporting the same flag too changes nothing: no second press.
    CHECK(ds5_merge_mute_flag(A_FLAG | MISC_FLAG, true) == (A_FLAG | MISC_FLAG));
    CHECK(ds5_merge_mute_flag(MISC_FLAG, false) == MISC_FLAG);
    // A repeat of the same raw state is no change; a flip is.
    CHECK(!ds5_mute_changed(false, false));
    CHECK(!ds5_mute_changed(true, true));
    CHECK(ds5_mute_changed(false, true));
    CHECK(ds5_mute_changed(true, false));
    // Sequence: press, a GameController change while held, release. The state sent changes only at the
    // press and at the release.
    uint32_t sent = 0;
    int sends = 0;
    bool raw = false;
    const uint32_t gc[] = {0, 0, A_FLAG, A_FLAG, 0, 0};
    const bool rawSeq[] = {false, true, true, true, true, false};
    for (int i = 0; i < 6; i++) {
        raw = rawSeq[i];
        uint32_t state = ds5_merge_mute_flag(gc[i], raw);
        if (state != sent) { sent = state; sends++; }
    }
    CHECK(sends == 4);   // press, +A, -A (still held), release
    CHECK(sent == 0);
}

int main(void) {
    testParse();
    testMerge();
    if (failures != 0) { fprintf(stderr, "%d failure(s)\n", failures); return 1; }
    printf("ds5 button merge tests passed\n");
    return 0;
}
