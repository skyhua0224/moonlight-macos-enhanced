#include "../../Limelight/Input/DS5MotionMapping.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures;

#define CHECK(condition) \
    do { \
        if (!(condition)) { \
            fprintf(stderr, "%s:%d: check failed: %s\n", __FILE__, __LINE__, #condition); \
            failures++; \
        } \
    } while (0)

#define NEAR(a, b, tol) (fabsf((float)(a) - (float)(b)) <= (tol))

static void put16(uint8_t *p, int v) { p[0] = (uint8_t)(v & 0xff); p[1] = (uint8_t)((v >> 8) & 0xff); }

// A plausible factory block: gyro bias small, +-8640 counts at +-540 deg/s
// (sensitivity 64), accelerometer +-8192 counts at +-1 g.
static void factoryBlock(uint8_t report[41], int biasX) {
    memset(report, 0, 41);
    report[0] = 0x05;
    put16(report + 1, biasX); put16(report + 3, -3); put16(report + 5, 5);
    put16(report + 7, 8640); put16(report + 9, -8640);
    put16(report + 11, 8640); put16(report + 13, -8640);
    put16(report + 15, 8640); put16(report + 17, -8640);
    put16(report + 19, 540); put16(report + 21, 540);
    put16(report + 23, 8192); put16(report + 25, -8192);
    put16(report + 27, 8192); put16(report + 29, -8192);
    put16(report + 31, 8192); put16(report + 33, -8192);
}

static void testCalibration(void) {
    uint8_t report[41];
    DS5ImuCalibration c;
    factoryBlock(report, 12);
    CHECK(ds5_imu_calibration_from_report(report, sizeof(report), &c));
    CHECK(c.hardware);
    CHECK(NEAR(c.sensitivity[0], 64.0f, 0.001f));
    CHECK(NEAR(c.bias[0], 12.0f, 0.001f) && NEAR(c.bias[1], -3.0f, 0.001f) && NEAR(c.bias[2], 5.0f, 0.001f));
    CHECK(NEAR(c.sensitivity[3], 1.0f, 0.001f) && NEAR(c.bias[3], 0.0f, 0.001f));
    // 100 deg/s is 1600 counts above the bias at this scale.
    CHECK(NEAR(ds5_raw_gyro_dps(&c, 0, (int16_t)(12 + 1600)), 100.0f, 0.01f));
    CHECK(NEAR(ds5_raw_gyro_dps(&c, 0, 12), 0.0f, 0.001f));
    CHECK(NEAR(ds5_raw_gyro_dps(&c, 1, (int16_t)(-3 - 1600)), -100.0f, 0.01f));
    CHECK(NEAR(ds5_raw_accel_ms2(&c, 1, 8192), 9.80665f, 0.001f));
    CHECK(NEAR(ds5_raw_accel_ms2(&c, 1, 0), 0.0f, 0.001f));

    // Missing, short, wrong id, zero range and implausible blocks fall back to the plain scale.
    ds5_imu_calibration_default(&c);
    CHECK(!ds5_imu_calibration_from_report(NULL, 0, &c) && !c.hardware);
    CHECK(!ds5_imu_calibration_from_report(report, 20, &c) && !c.hardware);
    report[0] = 0x09;
    CHECK(!ds5_imu_calibration_from_report(report, sizeof(report), &c));
    factoryBlock(report, 12);
    put16(report + 9, 8640);                       // pitch range 0
    CHECK(!ds5_imu_calibration_from_report(report, sizeof(report), &c));
    factoryBlock(report, 5000);                    // bias far outside the plausible band
    CHECK(!ds5_imu_calibration_from_report(report, sizeof(report), &c));
    factoryBlock(report, 0);
    put16(report + 19, 100); put16(report + 21, 100); // sensitivity far from 64
    CHECK(!ds5_imu_calibration_from_report(report, sizeof(report), &c));
    // Uncalibrated scale: 16 counts per deg/s, one g at 8192.
    CHECK(NEAR(ds5_raw_gyro_dps(&c, 0, 1600), 100.0f, 0.01f));
    CHECK(NEAR(ds5_raw_accel_ms2(&c, 0, 8192), 9.80665f, 0.001f));
}

// The GameController mapping and the raw mapping must produce the same
// protocol vector for the same physical rotation or acceleration.
static void testSourcesAgree(void) {
    DS5ImuCalibration c;
    ds5_imu_calibration_default(&c);
    for (int axis = 0; axis < 3; axis++) {
        for (int sign = -1; sign <= 1; sign += 2) {
            float dps = 120.0f * (float)sign;
            // Protocol (= raw sensor) axes: 0 right, 1 out of the face, 2 toward the player.
            int16_t raw[3] = {0, 0, 0};
            raw[axis] = (int16_t)lrintf(dps * 16.0f);
            float fromRaw[3] = {ds5_raw_gyro_dps(&c, 0, raw[0]), ds5_raw_gyro_dps(&c, 1, raw[1]),
                                ds5_raw_gyro_dps(&c, 2, raw[2])};
            // The same rotation in the GameController frame: x right, y toward the top edge,
            // z out of the face. protocol 1 (out of the face) = GC z, protocol 2 (toward the
            // player) = -GC y.
            double rad = (double)dps / DS5_RADIANS_TO_DEGREES;
            double gc[3] = {0, 0, 0};
            if (axis == 0) gc[0] = rad;
            if (axis == 1) gc[2] = rad;
            if (axis == 2) gc[1] = -rad;
            float fromGc[3];
            ds5_gc_gyro_to_protocol(gc[0], gc[1], gc[2], fromGc);
            for (int i = 0; i < 3; i++) CHECK(NEAR(fromRaw[i], fromGc[i], 0.1f));
        }
    }
    // Lying flat on the table the face points up: raw Y reads +1 g, GameController z reads -1 g
    // (gravity direction in its frame); both become +g on the protocol Y axis.
    float gcFlat[3];
    ds5_gc_accel_to_protocol(0, 0, -1.0, gcFlat);
    CHECK(NEAR(gcFlat[0], 0.0f, 1e-4f) && NEAR(gcFlat[1], 9.80665f, 1e-3f) && NEAR(gcFlat[2], 0.0f, 1e-4f));
    CHECK(NEAR(ds5_raw_accel_ms2(&c, 1, 8192), gcFlat[1], 1e-3f));
    // Standing on the grips (top edge up): GC reads (0, -1, 0); protocol Z carries +g toward the player.
    float gcStand[3];
    ds5_gc_accel_to_protocol(0, -1.0, 0, gcStand);
    CHECK(NEAR(gcStand[2], -9.80665f, 1e-3f));
}

static void testScale(void) {
    // One full turn per second is 360 deg/s on both sources.
    float out[3];
    ds5_gc_gyro_to_protocol(2.0 * 3.14159265358979, 0, 0, out);
    CHECK(NEAR(out[0], 360.0f, 0.01f));
    DS5ImuCalibration c;
    ds5_imu_calibration_default(&c);
    CHECK(NEAR(ds5_raw_gyro_dps(&c, 0, (int16_t)(360 * 16)), 360.0f, 0.01f));
    // The raw range reaches 2000 deg/s without clipping in 16 bits.
    CHECK(NEAR(ds5_raw_gyro_dps(&c, 0, 32767), 2047.9f, 0.1f));
}

// The host turns a wire value into report counts with lround(value * gain * 16.4) for the gyro and
// lround(value / 9.80665 * 8192) for the accelerometer (ds5_native_client.cpp, submit_motion). This repeats that.
static int hostGyroCounts(float wire, float gain) { return (int)lrintf(wire * gain * 16.4f); }
static int hostAccelCounts(float wire) { return (int)lrintf(wire / DS5_STANDARD_GRAVITY * 8192.0f); }

// The raw source carries the pad's own int16 counts through the wire unchanged, whatever the factory block says.
static void testRawCarriesCounts(void) {
    for (int counts = -32768; counts <= 32767; counts++) {
        CHECK(hostGyroCounts(ds5_raw_gyro_wire_dps((int16_t)counts), 1.0f) == counts);
        CHECK(hostAccelCounts(ds5_raw_accel_wire_ms2((int16_t)counts)) == counts);
    }
    // The real pad's calibrated reading would differ (per-unit sensitivity and bias); what is sent does not depend on it.
    DS5ImuCalibration c;
    uint8_t report[41];
    factoryBlock(report, 12);
    CHECK(ds5_imu_calibration_from_report(report, sizeof(report), &c));
    CHECK(hostGyroCounts(ds5_raw_gyro_wire_dps(1234), 1.0f) == 1234);
    CHECK(!NEAR(ds5_raw_gyro_dps(&c, 0, 1234), ds5_raw_gyro_wire_dps(1234), 0.01f));
}

// A rotation about one physical axis alone, for both sources: exactly one axis of the wire vector moves and its
// sign is the one the real report would carry. Physical axes of the pad: pitch about its right side (report
// bytes 16-17), yaw about the face normal (18-19), roll about the axis toward the player (20-21).
static void testSingleAxisBothSources(void) {
    const float dps = 150.0f;
    for (int axis = 0; axis < 3; axis++) {
        for (int sign = -1; sign <= 1; sign += 2) {
            // Raw: the real pad reports the counts on that axis only.
            int16_t counts[3] = {0, 0, 0};
            counts[axis] = (int16_t)(sign * lrintf(dps * 16.4f));
            float wire[3];
            for (int i = 0; i < 3; i++) wire[i] = ds5_raw_gyro_wire_dps(counts[i]);
            int host[3];
            for (int i = 0; i < 3; i++) host[i] = hostGyroCounts(wire[i], 1.0f);
            for (int i = 0; i < 3; i++) CHECK(host[i] == (i == axis ? counts[axis] : 0));
            // GameController: the same physical rotation in its frame (x right, y toward the top edge, z out of the face).
            double rad = (double)sign * dps / DS5_RADIANS_TO_DEGREES;
            double gc[3] = {0, 0, 0};
            if (axis == 0) gc[0] = rad;      // pitch: about the right side
            if (axis == 1) gc[2] = rad;      // yaw: about the face normal
            if (axis == 2) gc[1] = -rad;     // roll: about the player-facing axis, opposite to the top-edge axis
            float gcWire[3];
            ds5_gc_gyro_to_protocol(gc[0], gc[1], gc[2], gcWire);
            for (int i = 0; i < 3; i++) {
                const int gcHost = hostGyroCounts(gcWire[i], 1.0f);
                CHECK(abs(gcHost - (i == axis ? counts[axis] : 0)) <= 2);
            }
        }
    }
    // The same for gravity on each axis alone (specific force, g): raw counts and the GameController direction of gravity.
    for (int axis = 0; axis < 3; axis++) {
        for (int sign = -1; sign <= 1; sign += 2) {
            int16_t counts[3] = {0, 0, 0};
            counts[axis] = (int16_t)(sign * 8192);
            // Specific force +1 g along raw axis 0 (right): GC acceleration (gravity direction) is -x.
            // Along raw axis 1 (out of the face): GC z = -1 (face up reads gravity down the z axis).
            // Along raw axis 2 (toward the player): GC y = +1 for sign +1 (the top edge points away from the player).
            double gcAcc[3] = {0, 0, 0};
            if (axis == 0) gcAcc[0] = -sign;
            if (axis == 1) gcAcc[2] = -sign;
            if (axis == 2) gcAcc[1] = sign;
            float gcWire[3];
            ds5_gc_accel_to_protocol(gcAcc[0], gcAcc[1], gcAcc[2], gcWire);
            for (int i = 0; i < 3; i++) {
                CHECK(hostAccelCounts(ds5_raw_accel_wire_ms2(counts[i])) == counts[i]);
                CHECK(abs(hostAccelCounts(gcWire[i]) - counts[i]) <= 1);
            }
        }
    }
}

static void testRatePacing(void) {
    // The host asks 250 Hz: samples 4 ms apart (a 250 Hz source) are all sent,
    // 7.7 ms apart (a 130 Hz source) are all sent, nothing is capped below the source rate.
    double last = 0.0;
    int sent = 0;
    for (int i = 1; i <= 1000; i++) {
        double now = i * 0.004;
        if (ds5_motion_due(now, last, 250)) { last = now; sent++; }
    }
    CHECK(sent == 1000);
    last = 0.0; sent = 0;
    for (int i = 1; i <= 1000; i++) {
        double now = i * 0.0077 + ((i & 1) ? 0.0006 : -0.0006);
        if (ds5_motion_due(now, last, 250)) { last = now; sent++; }
    }
    CHECK(sent == 1000);
    // A 1000 Hz source is thinned to the requested rate, never below it (within one interval).
    last = 0.0; sent = 0;
    for (int i = 1; i <= 1000; i++) {
        double now = i * 0.001;
        if (ds5_motion_due(now, last, 250)) { last = now; sent++; }
    }
    CHECK(sent >= 250 && sent <= 500);
    CHECK(!ds5_motion_due(1.0, 0.0, 0));
}

static void testSourceSelection(void) {
    CHECK(ds5_motion_select_source(DS5_MOTION_SOURCE_GAMECONTROLLER, 250, 130, 60) == DS5_MOTION_SOURCE_RAW);
    CHECK(ds5_motion_select_source(DS5_MOTION_SOURCE_GAMECONTROLLER, 130, 130, 60) == DS5_MOTION_SOURCE_GAMECONTROLLER);
    CHECK(ds5_motion_select_source(DS5_MOTION_SOURCE_GAMECONTROLLER, 150, 130, 60) == DS5_MOTION_SOURCE_GAMECONTROLLER);
    CHECK(ds5_motion_select_source(DS5_MOTION_SOURCE_RAW, 150, 130, 60) == DS5_MOTION_SOURCE_RAW);   // hysteresis
    CHECK(ds5_motion_select_source(DS5_MOTION_SOURCE_RAW, 100, 130, 60) == DS5_MOTION_SOURCE_GAMECONTROLLER);
    CHECK(ds5_motion_select_source(DS5_MOTION_SOURCE_RAW, 0, 130, 60) == DS5_MOTION_SOURCE_GAMECONTROLLER);
    CHECK(ds5_motion_select_source(DS5_MOTION_SOURCE_GAMECONTROLLER, 130, 0, 60) == DS5_MOTION_SOURCE_RAW);
}

int main(void) {
    testCalibration();
    testSourcesAgree();
    testScale();
    testRawCarriesCounts();
    testSingleAxisBothSources();
    testRatePacing();
    testSourceSelection();
    if (failures != 0) { fprintf(stderr, "%d failure(s)\n", failures); return 1; }
    printf("ds5 motion mapping tests passed\n");
    return 0;
}
