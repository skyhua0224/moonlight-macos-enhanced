//
//  MLFpsMeter.h
//  Moonlight for macOS
//
//  Frames per second over the last second, read at any moment. Plain C: no clock, no lock, no Foundation; the caller
//  passes milliseconds (LiGetMillis) and serialises its own calls. Production use: VideoDecoderRenderer.m keeps one
//  meter each for received, decoded and rendered frames and VideoDecoderRenderer.videoStats reads them.
//
//  Why this exists. The statistics window (VideoStats) closes on a frame arrival once a second has passed, and every
//  rendered frame then stores the window that is still open. The overlay read the open window as count / (now - start).
//  Just after a window opened that is a handful of frames over a few milliseconds: 108, 285 or 500 fps on a stream that
//  never carried more than 60 (user log, issue #87: rx=285.7 in the same second the packet counter said 26). The
//  distance between the window start and the overlay timer drifts by the arrival jitter every second, so the numbers
//  climb for several seconds and fall back.
//
//  The meter counts frames in 50 ms bins. The rate is the frames in the last 19 complete bins plus the part of the
//  current one, over exactly that span (950 to 1000 ms), so the span never gets short; one frame more or less is about
//  one fps. Within the first 250 ms of a stream the span is 250 ms, so a first burst cannot show as a huge rate.
//

#ifndef ML_FPS_METER_H
#define ML_FPS_METER_H

#include <stdint.h>
#include <string.h>

#define ML_FPS_METER_BIN_MS 50u
#define ML_FPS_METER_WINDOW_BINS 20u
// A ring a few bins longer than the window; a slot holds the number of the bin it counts, plus one (0 = never used).
#define ML_FPS_METER_RING 32u
#define ML_FPS_METER_MIN_SPAN_MS 250u

typedef struct {
    uint64_t slotBin[ML_FPS_METER_RING];
    uint32_t slotCount[ML_FPS_METER_RING];
    uint64_t firstMs;  // the first frame since the last reset; 0 = none yet
} MLFpsMeter;

static inline void MLFpsMeterReset(MLFpsMeter *meter) {
    memset(meter, 0, sizeof(*meter));
}

// One frame at `nowMs`.
static inline void MLFpsMeterNote(MLFpsMeter *meter, uint64_t nowMs) {
    uint64_t bin = nowMs / ML_FPS_METER_BIN_MS;
    uint32_t slot = (uint32_t)(bin % ML_FPS_METER_RING);
    if (meter->slotBin[slot] != bin + 1) {
        meter->slotBin[slot] = bin + 1;
        meter->slotCount[slot] = 0;
    }
    meter->slotCount[slot] += 1;
    if (meter->firstMs == 0) {
        meter->firstMs = nowMs != 0 ? nowMs : 1;
    }
}

// Frames per second over the last second as of `nowMs`; 0 when nothing arrived in it.
static inline double MLFpsMeterRate(const MLFpsMeter *meter, uint64_t nowMs) {
    if (meter->firstMs == 0 || nowMs < meter->firstMs) {
        return 0.0;
    }
    uint64_t current = nowMs / ML_FPS_METER_BIN_MS;
    uint64_t oldest = current >= ML_FPS_METER_WINDOW_BINS - 1u ? current - (ML_FPS_METER_WINDOW_BINS - 1u) : 0;
    uint64_t frames = 0;
    for (uint64_t bin = oldest; bin <= current; bin++) {
        uint32_t slot = (uint32_t)(bin % ML_FPS_METER_RING);
        if (meter->slotBin[slot] == bin + 1) {
            frames += meter->slotCount[slot];
        }
    }
    if (frames == 0) {
        return 0.0;
    }
    uint64_t spanMs = (current - oldest) * ML_FPS_METER_BIN_MS + (nowMs - current * ML_FPS_METER_BIN_MS);
    uint64_t sinceFirst = nowMs - meter->firstMs;
    if (sinceFirst < spanMs) {
        spanMs = sinceFirst;
    }
    if (spanMs < ML_FPS_METER_MIN_SPAN_MS) {
        spanMs = ML_FPS_METER_MIN_SPAN_MS;
    }
    return (double)frames * 1000.0 / (double)spanMs;
}

#endif
