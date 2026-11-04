#include "../../Limelight/Input/DS5OutputMapping.h"

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

static AlkDs5Feedback blank(void) {
    AlkDs5Feedback fb;
    memset(&fb, 0, sizeof(fb));
    fb.struct_size = sizeof(fb);
    fb.abi = ALK_DS5_CORE_ABI_VERSION;
    return fb;
}

// Applies an extension the way ControllerSupport does and returns the output report.
static void report(const LI_DS5_OUTPUT_EXTENSION *o, int limit, uint8_t out[ALK_DS5_USB_OUTPUT_REPORT_BYTES],
                   uint8_t *f0, uint8_t *f1, uint8_t *f2) {
    AlkDs5Feedback fb = blank();
    uint8_t l1, l2, a0, a1;
    ds5_ext_light_flags(o, &l1, &l2);
    ds5_ext_audio_flags(o, &a0, &a1);
    fb.valid_flag0 = a0;
    fb.valid_flag1 = (uint8_t)(l1 | a1 | ((o->validMask & LI_DS5_OUT_PLAYER_LEDS) ? DS5_FLAG1_PLAYER_LEDS : 0));
    fb.valid_flag2 = l2;
    ds5_ext_apply_lights(&fb, o, l1, l2);
    ds5_ext_apply_audio(&fb, o, a0, a1, limit);
    if (o->validMask & LI_DS5_OUT_PLAYER_LEDS) fb.player_led_mask = o->playerLedMask;
    size_t length = 0;
    CHECK(alk_ds5_build_output_report(&fb, out, ALK_DS5_USB_OUTPUT_REPORT_BYTES, &length) == ALK_DS5_OK);
    CHECK(length == ALK_DS5_USB_OUTPUT_REPORT_BYTES);
    *f0 = out[1];
    *f1 = out[2];
    *f2 = out[39];
}

static void testEachFieldAlone(void) {
    uint8_t r[ALK_DS5_USB_OUTPUT_REPORT_BYTES], f0, f1, f2;
    LI_DS5_OUTPUT_EXTENSION o;

    memset(&o, 0, sizeof(o)); o.validMask = LI_DS5_OUT_PLAYER_LEDS; o.playerLedMask = 0x15;
    report(&o, 100, r, &f0, &f1, &f2);
    CHECK(f0 == 0 && f1 == 0x10 && f2 == 0 && r[44] == 0x15);

    memset(&o, 0, sizeof(o)); o.validMask = LI_DS5_OUT_MUTE_LED; o.muteLed = 1;
    report(&o, 100, r, &f0, &f1, &f2);
    CHECK(f0 == 0 && f1 == 0x01 && f2 == 0 && r[9] == 1);

    memset(&o, 0, sizeof(o)); o.validMask = LI_DS5_OUT_SPEAKER_VOLUME; o.speakerVolume = 0x64;
    report(&o, 100, r, &f0, &f1, &f2);
    CHECK(f0 == 0x20 && f1 == 0 && f2 == 0 && r[6] == 0x64);

    memset(&o, 0, sizeof(o)); o.validMask = LI_DS5_OUT_HEADPHONE_VOLUME; o.headphoneVolume = 0x30;
    report(&o, 100, r, &f0, &f1, &f2);
    CHECK(f0 == 0x10 && f1 == 0 && r[5] == 0x30);

    memset(&o, 0, sizeof(o)); o.validMask = LI_DS5_OUT_MIC_VOLUME; o.micVolume = 0x44;
    report(&o, 100, r, &f0, &f1, &f2);
    CHECK(f0 == 0x40 && f1 == 0 && r[7] == 0x44);

    memset(&o, 0, sizeof(o)); o.validMask = LI_DS5_OUT_MIC_MUTE; o.micMute = 1;
    report(&o, 100, r, &f0, &f1, &f2);
    CHECK(f0 == 0 && f1 == 0x02 && r[10] == 0x10);
    o.micMute = 0;
    report(&o, 100, r, &f0, &f1, &f2);
    CHECK(f1 == 0x02 && r[10] == 0x00);   // un-mute is a write, not an omission

    memset(&o, 0, sizeof(o)); o.validMask = LI_DS5_OUT_AUDIO_ROUTING; o.audioRouting = 0x30;
    report(&o, 100, r, &f0, &f1, &f2);
    CHECK(f0 == 0x80 && f1 == 0 && r[8] == 0x30);

    memset(&o, 0, sizeof(o)); o.validMask = LI_DS5_OUT_LIGHTBAR_BRIGHTNESS; o.lightbarBrightness = 2;
    report(&o, 100, r, &f0, &f1, &f2);
    CHECK(f0 == 0 && f1 == 0 && f2 == 0x01 && r[43] == 2);
}

static void testBrightnessRange(void) {
    uint8_t r[ALK_DS5_USB_OUTPUT_REPORT_BYTES], f0, f1, f2;
    LI_DS5_OUTPUT_EXTENSION o;
    memset(&o, 0, sizeof(o));
    o.validMask = LI_DS5_OUT_LIGHTBAR_BRIGHTNESS;
    for (int value = 0; value <= 2; value++) {
        o.lightbarBrightness = (uint8_t)value;
        report(&o, 100, r, &f0, &f1, &f2);
        CHECK(f2 == 0x01 && r[43] == value);
    }
    // 3 and above (including 255, "full" on a 0..255 scale) is not a device value: nothing is enabled.
    for (int value = 3; value <= 255; value += (value < 8 ? 1 : 63)) {
        o.lightbarBrightness = (uint8_t)value;
        report(&o, 100, r, &f0, &f1, &f2);
        CHECK(f2 == 0 && r[43] == 0);
    }
}

static void testFreshFlagsKeepEarlierValues(void) {
    // A second write must not repeat the first one's enable bits; the earlier value stays in the
    // data bytes so a coalesced report still carries it.
    AlkDs5Feedback fb = blank();
    LI_DS5_OUTPUT_EXTENSION first, second;
    memset(&first, 0, sizeof(first)); memset(&second, 0, sizeof(second));
    first.validMask = LI_DS5_OUT_SPEAKER_VOLUME; first.speakerVolume = 0x50;
    second.validMask = LI_DS5_OUT_MUTE_LED; second.muteLed = 1;
    uint8_t a0, a1, l1, l2;
    ds5_ext_audio_flags(&first, &a0, &a1);
    fb.valid_flag0 = a0; fb.valid_flag1 = a1;
    ds5_ext_apply_audio(&fb, &first, a0, a1, 100);
    ds5_ext_light_flags(&second, &l1, &l2);
    fb.valid_flag0 = 0; fb.valid_flag1 = l1; fb.valid_flag2 = l2;   // fresh flags
    ds5_ext_apply_lights(&fb, &second, l1, l2);
    uint8_t out[ALK_DS5_USB_OUTPUT_REPORT_BYTES];
    size_t length = 0;
    CHECK(alk_ds5_build_output_report(&fb, out, sizeof(out), &length) == ALK_DS5_OK);
    CHECK(out[1] == 0 && out[2] == 0x01);        // only the mute LED is enabled
    CHECK(out[6] == 0x50 && out[9] == 1);        // the speaker volume survives in the data bytes
}

static void testVolumeLimit(void) {
    CHECK(ds5_limited_volume(0x7f, DS5_HEADPHONE_VOLUME_MAX, 100) == 0x7f);
    CHECK(ds5_limited_volume(0x7f, DS5_HEADPHONE_VOLUME_MAX, 50) == 63);
    CHECK(ds5_limited_volume(0x10, DS5_HEADPHONE_VOLUME_MAX, 50) == 0x10);
    CHECK(ds5_limited_volume(0xff, DS5_SPEAKER_VOLUME_MAX, 40) == 102);
    CHECK(ds5_limited_volume(0xff, DS5_SPEAKER_VOLUME_MAX, 0) == 0xff);     // 0 means no limit set
    CHECK(ds5_limited_volume(0xff, DS5_SPEAKER_VOLUME_MAX, 250) == 0xff);
    CHECK(ds5_limited_volume(0, DS5_SPEAKER_VOLUME_MAX, 10) == 0);
    uint8_t r[ALK_DS5_USB_OUTPUT_REPORT_BYTES], f0, f1, f2;
    LI_DS5_OUTPUT_EXTENSION o;
    memset(&o, 0, sizeof(o));
    o.validMask = LI_DS5_OUT_SPEAKER_VOLUME | LI_DS5_OUT_HEADPHONE_VOLUME | LI_DS5_OUT_MIC_VOLUME;
    o.speakerVolume = 200; o.headphoneVolume = 100; o.micVolume = 200;
    report(&o, 50, r, &f0, &f1, &f2);
    CHECK(r[6] == 127 && r[5] == 63 && r[7] == 200);   // the microphone is not limited
}

static void testPlayerLedPatterns(void) {
    CHECK(ds5_player_index_for_led_mask(0x04) == 0);
    CHECK(ds5_player_index_for_led_mask(0x0a) == 1);
    CHECK(ds5_player_index_for_led_mask(0x15) == 2);
    CHECK(ds5_player_index_for_led_mask(0x1b) == 3);
    CHECK(ds5_player_index_for_led_mask(0x00) == -1);
    CHECK(ds5_player_index_for_led_mask(0x1f) == -2);
    CHECK(ds5_player_index_for_led_mask(0x01) == -2);
}

// What ControllerSupport does with a player LED value of the host: the pad shows its player number from
// connect (GCController.playerIndex), an empty message before the game set anything leaves it, a pattern
// of the game replaces it, and a later empty message turns the LEDs off.
typedef struct LedModel { int playerIndex; bool gameSet; } LedModel;

static void ledMessage(LedModel *m, uint32_t valid, uint8_t mask) {
    if (!(valid & LI_DS5_OUT_PLAYER_LEDS)) return;
    if (!ds5_player_led_request_applies(valid, mask, m->gameSet)) return;
    m->gameSet = mask != 0;
    m->playerIndex = ds5_player_index_for_led_mask(mask);
}

static void testPlayerLedRequests(void) {
    LedModel m = {0, false};  // player 1, as assigned on connect
    ledMessage(&m, 0x7f, 0x00);  // the host's initial snapshot (log 15:46:25, valid=0x7f)
    CHECK(m.playerIndex == 0);
    ledMessage(&m, 0x01, 0x00);  // a default message (log 15:52:53, valid=0x01 mask 0)
    CHECK(m.playerIndex == 0);
    ledMessage(&m, 0x02, 0x00);  // another field only
    CHECK(m.playerIndex == 0);
    ledMessage(&m, 0x01, 0x0a);  // the game asks for player 2
    CHECK(m.playerIndex == 1);
    ledMessage(&m, 0x7f, 0x00);  // a snapshot later in the session does not clear it
    CHECK(m.playerIndex == 1);
    ledMessage(&m, 0x01, 0x00);  // the game turns the LEDs off
    CHECK(m.playerIndex == -1);
    ledMessage(&m, 0x01, 0x15);
    CHECK(m.playerIndex == 2);
    ledMessage(&m, 0x01, 0x1f);  // a pattern GameController cannot draw is still a request
    CHECK(m.playerIndex == -2);
}

static void testFullGolden(void) {
    LI_DS5_OUTPUT_EXTENSION o;
    memset(&o, 0, sizeof(o));
    o.validMask = 0xff;
    o.playerLedMask = 0x1b; o.muteLed = 1; o.speakerVolume = 0x64; o.headphoneVolume = 0x30; o.micVolume = 0x40;
    o.micMute = 1; o.audioRouting = 0x30; o.lightbarBrightness = 1;
    uint8_t r[ALK_DS5_USB_OUTPUT_REPORT_BYTES], f0, f1, f2;
    report(&o, 100, r, &f0, &f1, &f2);
    static const uint8_t expected[ALK_DS5_USB_OUTPUT_REPORT_BYTES] = {
        [0] = 0x02, [1] = 0xf0, [2] = 0x13, [5] = 0x30, [6] = 0x64, [7] = 0x40, [8] = 0x30, [9] = 0x01,
        [10] = 0x10, [39] = 0x01, [43] = 0x01, [44] = 0x1b,
    };
    CHECK(memcmp(r, expected, sizeof(expected)) == 0);
}

// The pad audio bytes in the real USB output report the core builds: flags in bytes 1 and 2, headset volume in 5, speaker
// volume in 6, audio control in 8 (output path in bits 5:4), audio control 2 in 38.
static void testPadAudioBytes(void) {
    for (int headset = 0; headset <= 1; headset++) {
        const DS5PadAudioBytes bytes = ds5_pad_audio_bytes(headset != 0, 0x64, 0xff);
        AlkDs5Feedback fb = {.struct_size = sizeof(fb), .abi = ALK_DS5_CORE_ABI_VERSION, .device_index = 0};
        fb.valid_flag0 = bytes.flag0;
        fb.valid_flag1 = bytes.flag1;
        fb.headphone_volume = bytes.headphoneVolume;
        fb.speaker_volume = bytes.speakerVolume;
        fb.audio_control = bytes.audioControl;
        fb.audio_control2 = bytes.audioControl2;
        uint8_t out[ALK_DS5_USB_OUTPUT_REPORT_BYTES];
        size_t length = 0;
        CHECK(alk_ds5_build_output_report(&fb, out, sizeof(out), &length) == ALK_DS5_OK);
        CHECK(out[0] == 0x02);
        CHECK(out[1] == 0xb0);                    // headphone volume, speaker volume, audio control
        CHECK(out[2] == 0x80);                    // audio control 2
        CHECK(out[5] == 0x7f);                    // the headset volume is capped at the device maximum
        CHECK(out[6] == 0x64);
        CHECK(out[8] == (headset ? 0x00 : 0x30)); // output path 0 headset, 3 speaker
        CHECK(out[38] == (headset ? 0 : 2));      // +6 dB pre-amp with the speaker
        printf("pad audio %s: flags %02x %02x, bytes 5/6/8/38 = %02x %02x %02x %02x\n", headset ? "headset" : "speaker",
               out[1], out[2], out[5], out[6], out[8], out[38]);
    }
}

int main(void) {
    testPadAudioBytes();
    testEachFieldAlone();
    testBrightnessRange();
    testFreshFlagsKeepEarlierValues();
    testVolumeLimit();
    testPlayerLedPatterns();
    testPlayerLedRequests();
    testFullGolden();
    if (failures != 0) { fprintf(stderr, "%d failure(s)\n", failures); return 1; }
    printf("ds5 output mapping tests passed\n");
    return 0;
}
