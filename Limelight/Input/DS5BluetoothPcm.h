#pragma once

// Bluetooth DualSense PCM for the HID audio reports.
//
// Speaker pitch. ds5-gcsman-bt-audio-20261107 (section Audio must be
// pitched up 512:480) and ds5-dongle-audio-20261107 (SetRates 51200 to
// 48000, 512 frames resampled to 480): a 0x39 report is played over
// 21.333 ms, while two Opus frames are only 20 ms. The ratio is 16/15.
// Uncompensated audio plays about a semitone flat. Opus stays at 48 kHz,
// 10 ms, 480 samples (ds5-opus-api-20261107, ds5-rfc6716-20261107). The
// source is time-compressed first: 512 frames become 480 encoder frames.
// One report consumes 1024 source frames, one 21.333 ms slot, and the
// pad stretch restores the original pitch.
//
// Haptics. Those sources and ds5-saxense-c-20261109: the actuator lane is
// 3 kHz stereo signed 8-bit. Two 64-byte blocks fill a 0x39 report. One
// 64-byte block fills a 142-byte 0x32 report every 10.667 ms when the
// speaker is off. 48 kHz input is low-passed, then decimated by 16.
// The low-pass is a Kaiser-windowed sinc (ds5-jos-window-method-20261109,
// ds5-jos-kaiser-20261109): 129 taps, cutoff 1200 Hz, beta 5. Group delay
// is 64 samples at 48 kHz, 1.333 ms. The speaker resampler uses the same
// window method, 49 taps, 15 phases, cutoff 0.45 * 480/512 of the input
// rate, group delay 24 samples, 0.500 ms. Nothing is queued beyond the
// single report those filters are filling.

#include <math.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#if defined(__GNUC__) || defined(__clang__)
#define DS5_BT_UNUSED __attribute__((unused))
#else
#define DS5_BT_UNUSED
#endif

#ifdef __cplusplus
extern "C" {
#endif

enum {
    DS5_BT_HAPTIC_TAPS = 129,
    DS5_BT_HAPTIC_DECIMATION = 16,
    DS5_BT_HAPTIC_DELAY_SAMPLES = (DS5_BT_HAPTIC_TAPS - 1) / 2,
    DS5_BT_PITCH_TAPS = 49,
    DS5_BT_PITCH_PHASES = 15,
    DS5_BT_PITCH_DELAY_SAMPLES = (DS5_BT_PITCH_TAPS - 1) / 2,
    DS5_BT_PITCH_IN_FRAMES = 512,
    DS5_BT_PITCH_OUT_FRAMES = 480,
    DS5_BT_SPEAKER_PERIOD_FRAMES = 1024,
    DS5_BT_HAPTICS_PERIOD_FRAMES = 512,
    DS5_BT_PENDING_CAP = 1600,
    DS5_BT_REPORT_0x39_BYTES = 547,
    DS5_BT_REPORT_0x32_BYTES = 142,
    DS5_BT_HAPTIC_BLOCK_BYTES = 64,
    DS5_BT_OPUS_BYTES = 200
};

enum {
    DS5_BT_PERIOD_NONE = 0,
    DS5_BT_PERIOD_HAPTICS = 1,
    DS5_BT_PERIOD_SPEAKER = 2
};

typedef struct DS5BtHaptic {
    double delay[2][DS5_BT_HAPTIC_TAPS];
    size_t pos;
    unsigned until;
} DS5BtHaptic;

typedef struct DS5BtPitch {
    int16_t history[2][DS5_BT_PITCH_TAPS - 1];
} DS5BtPitch;

typedef struct DS5BtPeriod {
    int kind;
    uint8_t haptics[DS5_BT_HAPTIC_BLOCK_BYTES * 2u];
    int16_t speaker[DS5_BT_PITCH_OUT_FRAMES * 2u * 2u];
} DS5BtPeriod;

typedef struct DS5BtStream {
    DS5BtHaptic haptic;
    DS5BtPitch pitch;
    int16_t pendingSpeaker[DS5_BT_PENDING_CAP * 2u];
    int16_t pendingHaptic[DS5_BT_PENDING_CAP * 2u];
    size_t pending;
    int withSpeaker;
    int primed;
} DS5BtStream;

static double g_ds5_bt_haptic_coef[DS5_BT_HAPTIC_TAPS];
static double g_ds5_bt_pitch_coef[DS5_BT_PITCH_PHASES][DS5_BT_PITCH_TAPS];
static int g_ds5_bt_pcm_ready;

static DS5_BT_UNUSED double ds5_bt_i0(double x) {
    double sum = 1.0;
    double term = 1.0;
    const double half = x * 0.5;
    int k;
    for (k = 1; k < 40; k++) {
        term *= (half / (double)k) * (half / (double)k);
        sum += term;
        if (term < sum * 1e-14) break;
    }
    return sum;
}

static DS5_BT_UNUSED double ds5_bt_kaiser(int index, int taps, double beta) {
    const double mid = (double)(taps - 1) * 0.5;
    const double radius = mid == 0.0 ? 0.0 : ((double)index - mid) / mid;
    if (radius > 1.0 || radius < -1.0) return 0.0;
    return ds5_bt_i0(beta * sqrt(1.0 - radius * radius)) / ds5_bt_i0(beta);
}

static DS5_BT_UNUSED double ds5_bt_sinc_lowpass(double x, double cutoffCycles) {
    const double pi = 3.14159265358979323846;
    if (x > -1e-12 && x < 1e-12) return 2.0 * cutoffCycles;
    return sin(2.0 * pi * cutoffCycles * x) / (pi * x);
}

static DS5_BT_UNUSED int16_t ds5_bt_clamp_i16(double value) {
    const double rounded = value >= 0.0 ? value + 0.5 : value - 0.5;
    if (rounded >= 32767.0) return 32767;
    if (rounded <= -32768.0) return -32768;
    return (int16_t)rounded;
}

static DS5_BT_UNUSED void ds5_bt_pcm_design(void) {
    const double hapticCutoff = 1200.0 / 48000.0;
    const double pitchCutoff = 0.45 * (480.0 / 512.0);
    double sum;
    int n;
    int phase;
    int tap;
    if (g_ds5_bt_pcm_ready) return;
    sum = 0.0;
    for (n = 0; n < DS5_BT_HAPTIC_TAPS; n++) {
        const double x = (double)n - (double)DS5_BT_HAPTIC_DELAY_SAMPLES;
        g_ds5_bt_haptic_coef[n] = ds5_bt_sinc_lowpass(x, hapticCutoff) * ds5_bt_kaiser(n, DS5_BT_HAPTIC_TAPS, 5.0);
        sum += g_ds5_bt_haptic_coef[n];
    }
    for (n = 0; n < DS5_BT_HAPTIC_TAPS; n++) g_ds5_bt_haptic_coef[n] /= sum;
    for (phase = 0; phase < DS5_BT_PITCH_PHASES; phase++) {
        const double fraction = (double)phase / (double)DS5_BT_PITCH_PHASES;
        sum = 0.0;
        for (tap = 0; tap < DS5_BT_PITCH_TAPS; tap++) {
            const double x = ((double)tap + fraction) - (double)DS5_BT_PITCH_DELAY_SAMPLES;
            g_ds5_bt_pitch_coef[phase][tap] =
                ds5_bt_sinc_lowpass(x, pitchCutoff) * ds5_bt_kaiser(tap, DS5_BT_PITCH_TAPS, 6.0);
            sum += g_ds5_bt_pitch_coef[phase][tap];
        }
        for (tap = 0; tap < DS5_BT_PITCH_TAPS; tap++) g_ds5_bt_pitch_coef[phase][tap] /= sum;
    }
    g_ds5_bt_pcm_ready = 1;
}

static DS5_BT_UNUSED void ds5_bt_haptic_reset(DS5BtHaptic *state) {
    memset(state, 0, sizeof(*state));
    state->until = DS5_BT_HAPTIC_DECIMATION;
}

static DS5_BT_UNUSED void ds5_bt_pitch_reset(DS5BtPitch *state) {
    memset(state, 0, sizeof(*state));
}

static DS5_BT_UNUSED size_t ds5_bt_haptic_process(DS5BtHaptic *state, const int16_t *interleaved, size_t frames, int16_t *outStereo) {
    size_t produced = 0;
    size_t frame;
    ds5_bt_pcm_design();
    for (frame = 0; frame < frames; frame++) {
        int channel;
        state->delay[0][state->pos] = interleaved[frame * 2u];
        state->delay[1][state->pos] = interleaved[frame * 2u + 1u];
        state->pos++;
        if (state->pos == (size_t)DS5_BT_HAPTIC_TAPS) state->pos = 0;
        state->until--;
        if (state->until != 0) continue;
        state->until = DS5_BT_HAPTIC_DECIMATION;
        for (channel = 0; channel < 2; channel++) {
            double acc = 0.0;
            int tap;
            for (tap = 0; tap < DS5_BT_HAPTIC_TAPS; tap++) {
                const size_t at =
                    (state->pos + (size_t)DS5_BT_HAPTIC_TAPS - 1u - (size_t)tap) % (size_t)DS5_BT_HAPTIC_TAPS;
                acc += state->delay[channel][at] * g_ds5_bt_haptic_coef[tap];
            }
            outStereo[produced * 2u + (size_t)channel] = ds5_bt_clamp_i16(acc);
        }
        produced++;
    }
    return produced;
}

static DS5_BT_UNUSED void ds5_bt_haptics_to_s8(const int16_t *samples, size_t count, uint8_t *out) {
    size_t index;
    for (index = 0; index < count; index++) {
        const double scaled = (double)samples[index] * 127.0 / 32768.0;
        const int rounded = scaled >= 0.0 ? (int)(scaled + 0.5) : (int)(scaled - 0.5);
        const int clamped = rounded > 127 ? 127 : (rounded < -128 ? -128 : rounded);
        out[index] = (uint8_t)clamped;
    }
}

static DS5_BT_UNUSED void ds5_bt_pitch_512_to_480(DS5BtPitch *state, const int16_t *in, int16_t *out) {
    int channel;
    ds5_bt_pcm_design();
    for (channel = 0; channel < 2; channel++) {
        int16_t window[DS5_BT_PITCH_TAPS - 1 + DS5_BT_PITCH_IN_FRAMES];
        int index;
        memcpy(window, state->history[channel], sizeof(state->history[channel]));
        for (index = 0; index < DS5_BT_PITCH_IN_FRAMES; index++) {
            window[DS5_BT_PITCH_TAPS - 1 + index] = in[index * 2 + channel];
        }
        for (index = 0; index < DS5_BT_PITCH_OUT_FRAMES; index++) {
            const int inputPos = (index * DS5_BT_PITCH_IN_FRAMES) / DS5_BT_PITCH_OUT_FRAMES;
            const int phase = (index * 16) % DS5_BT_PITCH_PHASES;
            const int base = DS5_BT_PITCH_TAPS - 1 + inputPos;
            double acc = 0.0;
            int tap;
            for (tap = 0; tap < DS5_BT_PITCH_TAPS; tap++) {
                acc += (double)window[base - tap] * g_ds5_bt_pitch_coef[phase][tap];
            }
            out[index * 2 + channel] = ds5_bt_clamp_i16(acc);
        }
        for (index = 0; index < DS5_BT_PITCH_TAPS - 1; index++) {
            state->history[channel][index] =
                in[(DS5_BT_PITCH_IN_FRAMES - (DS5_BT_PITCH_TAPS - 1) + index) * 2 + channel];
        }
    }
}

// report[1] and the trailing CRC stay zero. The HID writer stamps both.
static DS5_BT_UNUSED void ds5_bt_pack_0x39(uint8_t report[DS5_BT_REPORT_0x39_BYTES], uint8_t packetCounter, int headset,
                             const uint8_t haptics[DS5_BT_HAPTIC_BLOCK_BYTES * 2u],
                             const uint8_t opus0[DS5_BT_OPUS_BYTES], const uint8_t opus1[DS5_BT_OPUS_BYTES]) {
    memset(report, 0, DS5_BT_REPORT_0x39_BYTES);
    report[0] = 0x39u;
    report[2] = 0x91u;
    report[3] = 6u;
    report[4] = 0x7eu;
    report[5] = 48u;
    report[6] = 48u;
    report[7] = 48u;
    report[8] = 48u;
    report[9] = packetCounter;
    report[10] = 0xd2u;
    report[11] = (uint8_t)DS5_BT_HAPTIC_BLOCK_BYTES;
    memcpy(report + 12, haptics, DS5_BT_HAPTIC_BLOCK_BYTES * 2u);
    report[140] = (uint8_t)(headset ? 0xd6u : 0xd3u);
    report[141] = (uint8_t)DS5_BT_OPUS_BYTES;
    memcpy(report + 142, opus0, DS5_BT_OPUS_BYTES);
    memcpy(report + 342, opus1, DS5_BT_OPUS_BYTES);
}

// SAxense 0x32 chain: control sub-packet 0x91 of length 7, then one 0x92 block.
static DS5_BT_UNUSED void ds5_bt_pack_0x32(uint8_t report[DS5_BT_REPORT_0x32_BYTES], uint8_t controlCounter,
                             const uint8_t haptics[DS5_BT_HAPTIC_BLOCK_BYTES]) {
    memset(report, 0, DS5_BT_REPORT_0x32_BYTES);
    report[0] = 0x32u;
    report[2] = 0x91u;
    report[3] = 7u;
    report[4] = 0xfeu;
    report[9] = 0xffu;
    report[10] = controlCounter;
    report[11] = 0x92u;
    report[12] = (uint8_t)DS5_BT_HAPTIC_BLOCK_BYTES;
    memcpy(report + 13, haptics, DS5_BT_HAPTIC_BLOCK_BYTES);
}

static DS5_BT_UNUSED void ds5_bt_stream_reset(DS5BtStream *stream) {
    memset(stream, 0, sizeof(*stream));
    ds5_bt_haptic_reset(&stream->haptic);
    ds5_bt_pitch_reset(&stream->pitch);
}

// speaker == NULL selects the 0x32 lane. haptics == NULL leaves the 0x39 haptic blocks at zero.
// Returns 1 when period holds one report of PCM. A call produces at most one period.
static DS5_BT_UNUSED int ds5_bt_stream_push(DS5BtStream *stream, const int16_t *speaker, const int16_t *haptics, size_t frames,
                              DS5BtPeriod *period) {
    const int wantSpeaker = speaker != NULL;
    size_t index;
    period->kind = DS5_BT_PERIOD_NONE;
    if (frames == 0 || frames > 480u || (speaker == NULL && haptics == NULL)) return 0;
    ds5_bt_pcm_design();
    if (!stream->primed || stream->withSpeaker != wantSpeaker) {
        ds5_bt_stream_reset(stream);
        stream->primed = 1;
        stream->withSpeaker = wantSpeaker;
    }
    if (stream->pending + frames > (size_t)DS5_BT_PENDING_CAP) {
        ds5_bt_stream_reset(stream);
        stream->primed = 1;
        stream->withSpeaker = wantSpeaker;
    }
    for (index = 0; index < frames; index++) {
        const size_t at = (stream->pending + index) * 2u;
        if (speaker != NULL) {
            stream->pendingSpeaker[at] = speaker[index * 2u];
            stream->pendingSpeaker[at + 1u] = speaker[index * 2u + 1u];
        }
        if (haptics != NULL) {
            stream->pendingHaptic[at] = haptics[index * 2u];
            stream->pendingHaptic[at + 1u] = haptics[index * 2u + 1u];
        }
    }
    stream->pending += frames;
    if (wantSpeaker && stream->pending >= (size_t)DS5_BT_SPEAKER_PERIOD_FRAMES) {
        int16_t hapticPcm[64 * 2];
        const size_t produced =
            ds5_bt_haptic_process(&stream->haptic, stream->pendingHaptic, (size_t)DS5_BT_SPEAKER_PERIOD_FRAMES, hapticPcm);
        if (produced != 64u) return 0;
        ds5_bt_haptics_to_s8(hapticPcm, 128u, period->haptics);
        ds5_bt_pitch_512_to_480(&stream->pitch, stream->pendingSpeaker, period->speaker);
        ds5_bt_pitch_512_to_480(&stream->pitch, stream->pendingSpeaker + DS5_BT_PITCH_IN_FRAMES * 2,
                                period->speaker + DS5_BT_PITCH_OUT_FRAMES * 2);
        stream->pending -= (size_t)DS5_BT_SPEAKER_PERIOD_FRAMES;
        memmove(stream->pendingSpeaker, stream->pendingSpeaker + DS5_BT_SPEAKER_PERIOD_FRAMES * 2,
                stream->pending * 2u * sizeof(int16_t));
        memmove(stream->pendingHaptic, stream->pendingHaptic + DS5_BT_SPEAKER_PERIOD_FRAMES * 2,
                stream->pending * 2u * sizeof(int16_t));
        period->kind = DS5_BT_PERIOD_SPEAKER;
        return 1;
    }
    if (!wantSpeaker && stream->pending >= (size_t)DS5_BT_HAPTICS_PERIOD_FRAMES) {
        int16_t hapticPcm[32 * 2];
        const size_t produced = ds5_bt_haptic_process(&stream->haptic, stream->pendingHaptic,
                                                      (size_t)DS5_BT_HAPTICS_PERIOD_FRAMES, hapticPcm);
        if (produced != 32u) return 0;
        ds5_bt_haptics_to_s8(hapticPcm, 64u, period->haptics);
        stream->pending -= (size_t)DS5_BT_HAPTICS_PERIOD_FRAMES;
        memmove(stream->pendingHaptic, stream->pendingHaptic + DS5_BT_HAPTICS_PERIOD_FRAMES * 2,
                stream->pending * 2u * sizeof(int16_t));
        period->kind = DS5_BT_PERIOD_HAPTICS;
        return 1;
    }
    return 0;
}

#ifdef __cplusplus
}
#endif

