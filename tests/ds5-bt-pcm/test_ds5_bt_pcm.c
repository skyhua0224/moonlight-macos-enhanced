#include "../../Limelight/Input/DS5BluetoothPcm.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures = 0;

static void check(int cond, const char *what) {
    if (cond) return;
    fprintf(stderr, "FAIL %s\n", what);
    failures++;
}

static double rms(const double *v, size_t n) {
    double s = 0.0;
    size_t i;
    for (i = 0; i < n; i++) s += v[i] * v[i];
    return sqrt(s / (double)n);
}

static void test_layout(void) {
    uint8_t haptics[128];
    uint8_t opus0[200];
    uint8_t opus1[200];
    uint8_t report[547];
    uint8_t small[142];
    uint8_t block[64];
    size_t i;
    for (i = 0; i < 128; i++) haptics[i] = (uint8_t)(i + 1u);
    memset(opus0, 0xa5, sizeof(opus0));
    memset(opus1, 0x5a, sizeof(opus1));
    ds5_bt_pack_0x39(report, 0x22, 0, haptics, opus0, opus1);
    check(report[0] == 0x39 && report[1] == 0 && report[2] == 0x91, "0x39 header");
    check(report[3] == 6 && report[4] == 0x7e, "0x39 control length and flags");
    check(report[5] == 48 && report[8] == 48 && report[9] == 0x22, "0x39 buffer and counter");
    check(report[10] == 0xd2 && report[11] == 64, "0x39 haptic header");
    check(memcmp(report + 12, haptics, 128) == 0, "0x39 haptic blocks");
    check(report[140] == 0xd3 && report[141] == 200, "0x39 speaker subpacket");
    check(memcmp(report + 142, opus0, 200) == 0 && memcmp(report + 342, opus1, 200) == 0, "0x39 opus");
    check(report[542] == 0 && report[543] == 0 && report[546] == 0, "0x39 crc left to the writer");
    ds5_bt_pack_0x39(report, 4, 1, haptics, opus0, opus1);
    check(report[140] == 0xd6, "0x39 headset route");
    for (i = 0; i < 64; i++) block[i] = (uint8_t)(200u + i);
    ds5_bt_pack_0x32(small, 7, block);
    check(small[0] == 0x32 && small[1] == 0 && small[2] == 0x91 && small[3] == 7, "0x32 control header");
    check(small[4] == 0xfe && small[5] == 0 && small[8] == 0 && small[9] == 0xff && small[10] == 7, "0x32 control data");
    check(small[11] == 0x92 && small[12] == 64, "0x32 haptic header");
    check(memcmp(small + 13, block, 64) == 0, "0x32 haptic block");
    check(small[77] == 0 && small[137] == 0 && small[138] == 0 && small[141] == 0, "0x32 tail clear");
}

static void fill_sine(int16_t *dst, size_t frames, double freq, double amp, size_t origin) {
    size_t i;
    for (i = 0; i < frames; i++) {
        const double t = (double)(origin + i) / 48000.0;
        const int16_t s = (int16_t)(amp * sin(2.0 * 3.14159265358979323846 * freq * t));
        dst[i * 2u] = s;
        dst[i * 2u + 1u] = (int16_t)(-s / 2);
    }
}

static void test_haptic_filter(void) {
    enum { FRAMES = 4800 };
    int16_t *in = calloc(FRAMES * 2u, sizeof(int16_t));
    int16_t *out = calloc((FRAMES / 16 + 8) * 2u, sizeof(int16_t));
    DS5BtHaptic state;
    size_t produced;
    size_t i;
    double pass = 0.0;
    double stop = 0.0;
    size_t passCount = 0;
    size_t stopCount = 0;
    ds5_bt_haptic_reset(&state);
    fill_sine(in, FRAMES, 400.0, 16000.0, 0);
    produced = ds5_bt_haptic_process(&state, in, FRAMES, out);
    check(produced == FRAMES / 16, "400 Hz output count");
    for (i = 32; i < produced; i++) {
        pass += (double)out[i * 2u] * (double)out[i * 2u];
        passCount++;
    }
    pass = sqrt(pass / (double)passCount);
    check(pass > 16000.0 / 1.4142 * 0.85 && pass < 16000.0 / 1.4142 * 1.05, "400 Hz passband");
    ds5_bt_haptic_reset(&state);
    fill_sine(in, FRAMES, 6000.0, 16000.0, 0);
    produced = ds5_bt_haptic_process(&state, in, FRAMES, out);
    for (i = 32; i < produced; i++) {
        stop += (double)out[i * 2u] * (double)out[i * 2u];
        stopCount++;
    }
    stop = sqrt(stop / (double)stopCount);
    check(stop * 100.0 < pass, "6000 Hz attenuated by 40 dB");
    check(DS5_BT_HAPTIC_DELAY_SAMPLES * 1000 < 48000 * 2, "haptic delay under 2 ms");
    free(in);
    free(out);
    (void)rms;
}

static void test_pitch(void) {
    enum { BLOCKS = 3 };
    int16_t in[DS5_BT_PITCH_IN_FRAMES * 2];
    int16_t out[DS5_BT_PITCH_OUT_FRAMES * 2];
    DS5BtPitch state;
    int block;
    double err = 0.0;
    double sig = 0.0;
    int i;
    ds5_bt_pitch_reset(&state);
    for (block = 0; block < BLOCKS; block++) {
        fill_sine(in, DS5_BT_PITCH_IN_FRAMES, 1000.0, 12000.0, (size_t)block * DS5_BT_PITCH_IN_FRAMES);
        ds5_bt_pitch_512_to_480(&state, in, out);
        if (block == 0) continue;
        for (i = 40; i < DS5_BT_PITCH_OUT_FRAMES; i++) {
            const double position = (double)(block * DS5_BT_PITCH_IN_FRAMES) +
                                    (double)i * 512.0 / 480.0 - (double)DS5_BT_PITCH_DELAY_SAMPLES;
            const double ref = 12000.0 * sin(2.0 * 3.14159265358979323846 * 1000.0 * position / 48000.0);
            const double y = out[i * 2];
            err += (y - ref) * (y - ref);
            sig += ref * ref;
        }
    }
    check(10.0 * log10(sig / err) > 40.0, "pitch resample SNR");
    check(DS5_BT_PITCH_DELAY_SAMPLES * 1000 < 48000, "pitch delay under 1 ms");
    check(DS5_BT_PITCH_IN_FRAMES * 15 == DS5_BT_PITCH_OUT_FRAMES * 16, "512:480 is 16:15");
}

static void test_stream_switch(void) {
    DS5BtStream stream;
    DS5BtPeriod period;
    int16_t speaker[480 * 2];
    int16_t haptics[480 * 2];
    int sawSpeaker = 0;
    int sawHaptics = 0;
    int pushes;
    uint8_t report39[547];
    uint8_t report32[142];
    uint8_t opus[200];
    memset(&stream, 0, sizeof(stream));
    memset(opus, 0x11, sizeof(opus));
    fill_sine(speaker, 480, 440.0, 8000.0, 0);
    fill_sine(haptics, 480, 120.0, 20000.0, 0);
    for (pushes = 0; pushes < 6; pushes++) {
        const int ready = ds5_bt_stream_push(&stream, speaker, haptics, 480, &period);
        if (!ready) {
            check(stream.pending < (size_t)DS5_BT_SPEAKER_PERIOD_FRAMES, "speaker lane stays within one report");
            continue;
        }
        check(period.kind == DS5_BT_PERIOD_SPEAKER, "speaker lane emits 0x39 period");
        check(stream.pending < 480u, "no second report buffered");
        ds5_bt_pack_0x39(report39, 2, 0, period.haptics, opus, opus);
        check(report39[10] == 0xd2 && report39[12 + 24] != 0, "0x39 haptic bytes are not all left zero");
        sawSpeaker = 1;
    }
    check(sawSpeaker == 1, "speaker period produced");
    memset(&stream, 0, sizeof(stream));
    for (pushes = 0; pushes < 4; pushes++) {
        const int ready = ds5_bt_stream_push(&stream, NULL, haptics, 480, &period);
        if (!ready) {
            check(stream.pending < (size_t)DS5_BT_HAPTICS_PERIOD_FRAMES, "haptics lane stays within one report");
            continue;
        }
        check(period.kind == DS5_BT_PERIOD_HAPTICS, "haptics lane emits 0x32 period");
        ds5_bt_pack_0x32(report32, 1, period.haptics);
        check(report32[0] == 0x32 && report32[13 + 24] != 0, "0x32 carries haptic samples");
        sawHaptics = 1;
    }
    check(sawHaptics == 1, "haptics period produced");
    check(ds5_bt_stream_push(&stream, speaker, haptics, 480, &period) == 0, "mode switch drops the partial period");
    check(stream.withSpeaker == 1 && stream.pending == 480u, "switch restarts on the speaker lane");
}

static void test_s8_scale(void) {
    const int16_t in[4] = {16000, -16000, 32767, -32768};
    uint8_t out[4];
    ds5_bt_haptics_to_s8(in, 4, out);
    check(out[0] == 62, "positive scale");
    check(out[1] == (uint8_t)(int8_t)-62, "negative scale");
    check(out[2] == 127 && out[3] == (uint8_t)(int8_t)-127, "full scale uses 127");
}

int main(void) {
    test_layout();
    test_haptic_filter();
    test_pitch();
    test_stream_switch();
    test_s8_scale();
    if (failures != 0) {
        fprintf(stderr, "%d check(s) failed\n", failures);
        return 1;
    }
    puts("ds5 bluetooth pcm test: ok");
    return 0;
}

