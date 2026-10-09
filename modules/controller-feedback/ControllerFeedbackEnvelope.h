#ifndef CONTROLLER_FEEDBACK_ENVELOPE_H
#define CONTROLLER_FEEDBACK_ENVELOPE_H

#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

// New, transport-independent arithmetic policy. No Qt/SDL/Moonlight types,
// packets, callbacks, headers or libraries belong in this module.
// The output domains are the public Core Haptics intensity/sharpness ranges:
// https://developer.apple.com/documentation/corehaptics/chhapticeventparameterid
// This policy interpolates the measured RMS toward the peak at transients;
// it does not use the QT client's gain constants or perceptual calibration.
// A standalone distribution license must be selected by the project owner.
typedef struct {
    float rms;
    float peak;
    float transient;
    float lowBandFraction;
} ControllerActuatorEnvelope;

typedef struct {
    float intensity;
    float sharpness;
} ControllerActuatorParameters;

static inline float ControllerFeedbackUnit(float value) {
    if (!isfinite(value)) return 0.0f;
    return fminf(1.0f, fmaxf(0.0f, value));
}

static inline ControllerActuatorParameters ControllerFeedbackProject(
    ControllerActuatorEnvelope sample, bool stopped) {
    ControllerActuatorParameters output = {0.0f, 0.5f};
    if (stopped) return output;
    const float average = ControllerFeedbackUnit(sample.rms);
    const float peak = fmaxf(average, ControllerFeedbackUnit(sample.peak));
    const float edge = ControllerFeedbackUnit(sample.transient);
    output.intensity = average + (peak - average) * edge;
    output.sharpness = 1.0f - ControllerFeedbackUnit(sample.lowBandFraction);
    return output;
}

// A legacy low/high motor pair cannot represent stereo actuator waveforms.
// This compatibility reduction preserves the strongest lane in each band.
static inline void ControllerFeedbackReduceBands(
    const ControllerActuatorEnvelope samples[2], bool stopped,
    float *low, float *high) {
    *low = 0.0f;
    *high = 0.0f;
    for (int lane = 0; lane < 2; ++lane) {
        ControllerActuatorParameters output = ControllerFeedbackProject(samples[lane], stopped);
        const float lowFraction = ControllerFeedbackUnit(samples[lane].lowBandFraction);
        *low = fmaxf(*low, output.intensity * lowFraction);
        *high = fmaxf(*high, output.intensity * (1.0f - lowFraction));
    }
}

static inline void ControllerFeedbackReducePCM16LE(const uint8_t *bytes,
    uint32_t frames, float *low, float *high) {
    *low = *high = 0.0f;
    if (bytes == NULL || frames == 0) return;
    double energy[2] = {0.0, 0.0};
    for (uint32_t frame = 0; frame < frames; frame++) {
        for (unsigned lane = 0; lane < 2; lane++) {
            const uint8_t *p = bytes + frame * 4 + lane * 2;
            int32_t sample = p[0] | ((uint32_t)p[1] << 8);
            if (sample >= 32768) sample -= 65536;
            double amplitude = sample / 32768.0;
            energy[lane] += amplitude * amplitude;
        }
    }
    *low = (float)fmin(1.0, sqrt(energy[0] / frames) * 1.5);
    *high = (float)fmin(1.0, sqrt(energy[1] / frames) * 1.5);
}

#endif
