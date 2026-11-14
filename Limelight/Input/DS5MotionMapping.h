#pragma once

// Motion mapping for the DualSense client. Header-only C so the unit test in
// tests/ds5-motion builds it without Apple frameworks.
//
// Protocol side: the host receives rotation in deg/s and acceleration in m/s^2
// on the gamepad axes used by SDL (X right, Y out of the face, Z toward the
// player; lying flat reads +1 g on Y).
//
// Two sources feed it:
//  * GameController (GCMotion): right-handed frame X right, Y toward the top
//    edge, Z out of the face. Rotation in rad/s, acceleration in g as the
//    direction of gravity. Mapping, measured on a DualSense on this client:
//    rotation (x, z, -y), acceleration (-x, -z, y).
//  * The raw HID input report: the sensor axes are already in the protocol
//    order. Gyro counts convert with the factory calibration of feature report
//    0x05 (bias and sensitivity per axis) at 1024 counts per deg/s of the
//    calibrated scale, or 64 / 1024 when the report is absent or implausible.
//    Accelerometer counts convert at 8192 counts per g.
//
// Calibration layout (feature report 0x05, 41 bytes with the report id): the
// Linux hid-playstation driver documents the same fields in
// dualsense_get_calibration_data(); the plausibility rule below keeps a bad
// factory block from skewing the scale.

#include <math.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define DS5_GYRO_RES_PER_DEGREE 1024.0f
#define DS5_ACCEL_RES_PER_G 8192.0f
#define DS5_STANDARD_GRAVITY 9.80665f
#define DS5_RADIANS_TO_DEGREES 57.29577951308232f
#define DS5_CALIBRATION_MIN_BYTES 35

typedef struct DS5ImuCalibration {
  bool hardware;
  float bias[6];
  float sensitivity[6];
} DS5ImuCalibration;

static inline int16_t ds5_load_s16(const uint8_t *p) { return (int16_t)(uint16_t)(p[0] | (p[1] << 8)); }

static inline void ds5_imu_calibration_default(DS5ImuCalibration *c) {
  for (int i = 0; i < 6; i++) {
    c->bias[i] = 0.0f;
    c->sensitivity[i] = 1.0f;
  }
  c->hardware = false;
}

// report: feature report 0x05 including the report id at [0]. Returns true when
// the factory block was read and is plausible; otherwise c holds the default.
static inline bool ds5_imu_calibration_from_report(const uint8_t *report, size_t length, DS5ImuCalibration *c) {
  ds5_imu_calibration_default(c);
  if (report == NULL || length < DS5_CALIBRATION_MIN_BYTES || report[0] != 0x05) return false;
  const int16_t gyroBias[3] = {ds5_load_s16(report + 1), ds5_load_s16(report + 3), ds5_load_s16(report + 5)};
  const int16_t plus[3] = {ds5_load_s16(report + 7), ds5_load_s16(report + 11), ds5_load_s16(report + 15)};
  const int16_t minus[3] = {ds5_load_s16(report + 9), ds5_load_s16(report + 13), ds5_load_s16(report + 17)};
  const int16_t speedPlus = ds5_load_s16(report + 19), speedMinus = ds5_load_s16(report + 21);
  const int16_t accPlus[3] = {ds5_load_s16(report + 23), ds5_load_s16(report + 27), ds5_load_s16(report + 31)};
  const int16_t accMinus[3] = {ds5_load_s16(report + 25), ds5_load_s16(report + 29), ds5_load_s16(report + 33)};
  const float numerator = (float)((int)speedPlus + (int)speedMinus) * DS5_GYRO_RES_PER_DEGREE;
  DS5ImuCalibration parsed;
  ds5_imu_calibration_default(&parsed);
  for (int i = 0; i < 3; i++) {
    const int range = (int)plus[i] - (int)minus[i];
    if (range == 0) return false;
    parsed.bias[i] = (float)gyroBias[i];
    parsed.sensitivity[i] = numerator / (float)range;
    const int accelRange = (int)accPlus[i] - (int)accMinus[i];
    if (accelRange == 0) return false;
    parsed.bias[3 + i] = (float)((int)accPlus[i] - accelRange / 2);
    parsed.sensitivity[3 + i] = 2.0f * DS5_ACCEL_RES_PER_G / (float)accelRange;
  }
  for (int i = 0; i < 6; i++) {
    const float divisor = i < 3 ? 64.0f : 1.0f;
    if (fabsf(parsed.bias[i]) > 1024.0f || fabsf(1.0f - parsed.sensitivity[i] / divisor) > 0.5f) return false;
  }
  parsed.hardware = true;
  *c = parsed;
  return true;
}

// The raw source carries the pad's own counts through unchanged: the host turns the wire value back into counts
// with the same two fixed factors (16.4 counts per deg/s, 8192 counts per g), so the virtual report holds the
// integers of the real report and no per-unit calibration, rounding or sign can shift them.
#define DS5_WIRE_GYRO_COUNTS_PER_DPS 16.4f

static inline float ds5_raw_gyro_wire_dps(int16_t counts) { return (float)counts / DS5_WIRE_GYRO_COUNTS_PER_DPS; }

static inline float ds5_raw_accel_wire_ms2(int16_t counts) {
  return (float)counts / DS5_ACCEL_RES_PER_G * DS5_STANDARD_GRAVITY;
}

// Raw gyro counts of axis 0..2 to deg/s with the factory calibration (diagnostics only; not what is sent).
static inline float ds5_raw_gyro_dps(const DS5ImuCalibration *c, int axis, int16_t counts) {
  float scaled = c->hardware ? ((float)counts - c->bias[axis]) * c->sensitivity[axis] : (float)counts * 64.0f;
  return scaled / DS5_GYRO_RES_PER_DEGREE;
}

// Raw accelerometer counts of axis 0..2 to m/s^2.
static inline float ds5_raw_accel_ms2(const DS5ImuCalibration *c, int axis, int16_t counts) {
  float scaled = c->hardware ? ((float)counts - c->bias[3 + axis]) * c->sensitivity[3 + axis] : (float)counts;
  return scaled / DS5_ACCEL_RES_PER_G * DS5_STANDARD_GRAVITY;
}

// GameController rotation (rad/s, GC frame) to protocol deg/s.
static inline void ds5_gc_gyro_to_protocol(double gx, double gy, double gz, float out[3]) {
  out[0] = (float)(gx * DS5_RADIANS_TO_DEGREES);
  out[1] = (float)(gz * DS5_RADIANS_TO_DEGREES);
  out[2] = (float)(-gy * DS5_RADIANS_TO_DEGREES);
}

// GameController acceleration (g, GC frame) to protocol m/s^2.
static inline void ds5_gc_accel_to_protocol(double ax, double ay, double az, float out[3]) {
  out[0] = (float)(-ax * DS5_STANDARD_GRAVITY);
  out[1] = (float)(-az * DS5_STANDARD_GRAVITY);
  out[2] = (float)(ay * DS5_STANDARD_GRAVITY);
}

// A sample is due once half the requested interval has passed since the last
// one sent, so a source slightly faster or slower than the host asked for never
// skips on jitter. A rate of 0 means the host asked to stop. The result never
// caps a source below the requested rate.
static inline bool ds5_motion_due(double now, double last, unsigned rateHz) {
  return rateHz > 0 && now - last >= 0.5 / (double)rateHz;
}

typedef enum DS5MotionSource {
  DS5_MOTION_SOURCE_GAMECONTROLLER = 0,
  DS5_MOTION_SOURCE_RAW = 1,
} DS5MotionSource;

// Chooses the motion source for the next window from the sample counts of the
// last one. Raw is preferred only when it delivered clearly more samples than
// GameController (at least 25 %) and a full window of raw data exists; the
// current source is kept otherwise, so the choice does not flap.
static inline DS5MotionSource ds5_motion_select_source(DS5MotionSource current, unsigned rawSamples,
                                                       unsigned gcSamples, unsigned minSamples) {
  if (rawSamples < minSamples) return DS5_MOTION_SOURCE_GAMECONTROLLER;
  if (gcSamples < minSamples) return DS5_MOTION_SOURCE_RAW;
  if (current == DS5_MOTION_SOURCE_GAMECONTROLLER) {
    return (rawSamples * 4u >= gcSamples * 5u) ? DS5_MOTION_SOURCE_RAW : DS5_MOTION_SOURCE_GAMECONTROLLER;
  }
  return (gcSamples * 4u >= rawSamples * 5u) ? DS5_MOTION_SOURCE_GAMECONTROLLER : DS5_MOTION_SOURCE_RAW;
}
