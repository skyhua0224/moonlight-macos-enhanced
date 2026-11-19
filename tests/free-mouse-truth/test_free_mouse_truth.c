// Tests the CoreHID free-mouse virtual cursor (FreeMouseVirtualCursor.h):
//  1. the rules: gain clamp and blend, anchor, reconcile threshold, clamping to the view;
//  2. a replay of fast circular mouse motion: raw CoreHID motion at 1 kHz with the system's pointer acceleration on
//     top, and an AppKit mouse event at 120 Hz that reaches the main thread `queue` ms after it was created. The
//     cursor is reconciled either against the pointer as it is when the main thread runs (live: what the app does)
//     or against the location stored in the event (event: what the app did until rc.9).
// The replay measures what the host receives: the distance between the cursor position sent and the real pointer at
// that moment, and the position steps over 40 view points. No hardware, no host.
//  3. the live pointer map (FreeMouseLivePointer.h): reading the pointer off the main thread;
//  4. the smoothness of the host cursor, frame by frame, with the cursor reconciled at the rate of the main thread's
//     mouse events (about 40 a second, 17 ms old: what a 1000 Hz mouse got in a user's log) or at the rate of the raw
//     motion (every 4 ms, the pointer read through the map).
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "FreeMouseLivePointer.h"
#include "FreeMouseVirtualCursor.h"

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

static int failures = 0;
#define CHECK(cond, ...)                                              \
    do {                                                              \
        if (!(cond)) {                                                \
            failures++;                                               \
            printf("FAIL %s:%d: ", __FILE__, __LINE__);               \
            printf(__VA_ARGS__);                                      \
            printf("\n");                                             \
        }                                                             \
    } while (0)

static int near(double a, double b, double eps) { return fabs(a - b) <= eps; }

static void testRules(void) {
    CHECK(near(MLFreeMouseClampGain(0.1), 0.25, 1e-12), "gain floor");
    CHECK(near(MLFreeMouseClampGain(9.0), 4.0, 1e-12), "gain ceiling");
    CHECK(near(MLFreeMouseClampGain(NAN), 1.0, 1e-12), "gain nan");
    CHECK(near(MLFreeMouseBlendGain(1.0, 10.0, 20.0), 1.0 * 0.82 + 2.0 * 0.18, 1e-12), "blend");
    CHECK(near(MLFreeMouseBlendGain(1.5, 0.2, 3.0), 1.5, 1e-12), "tiny raw motion is ignored");
    CHECK(near(MLFreeMouseBlendGain(1.5, 5.0, 0.1), 1.5, 1e-12), "tiny observed motion is ignored");
    CHECK(near(MLFreeMouseBlendGain(1.5, 5.0, -5.0), 1.5, 1e-12), "opposite directions are ignored");

    MLFreeMouseVirtualCursor c;
    MLFreeMouseVirtualCursorReset(&c);
    CHECK(!c.hasAnchor && near(c.gain.x, 1.0, 1e-12) && near(c.gain.y, 1.0, 1e-12), "reset");

    double drift = -1.0;
    CHECK(MLFreeMouseVirtualCursorReconcile(&c, (MLFreeMousePoint){100, 100}, 800, 600, true, 1.5, &drift),
          "the first reconcile has nothing to compare with and corrects");
    CHECK(c.hasAnchor && near(drift, 0.0, 1e-12) && near(c.point.x, 100, 1e-12), "first anchor");

    MLFreeMouseVirtualCursorAdvance(&c, 10, -4, 800, 600);
    CHECK(near(c.point.x, 110, 1e-12) && near(c.point.y, 96, 1e-12), "advance at gain 1");
    CHECK(!MLFreeMouseVirtualCursorReconcile(&c, (MLFreeMousePoint){111.0, 96.5}, 800, 600, true, 1.5, &drift),
          "a pointer within the threshold needs no correction");
    CHECK(near(drift, 1.0, 1e-9), "drift is the larger axis: %f", drift);
    CHECK(near(c.point.x, 111.0, 1e-12), "the cursor is re-anchored on the pointer");

    double gainBefore = c.gain.x;
    MLFreeMouseVirtualCursorAdvance(&c, 10, 0, 800, 600);
    CHECK(MLFreeMouseVirtualCursorReconcile(&c, (MLFreeMousePoint){125.0, 96.5}, 800, 600, true, 1.5, &drift),
          "a pointer 4 points away corrects");
    CHECK(near(drift, 125.0 - (111.0 + 10.0 * gainBefore), 1e-9), "drift %f", drift);
    CHECK(c.gain.x > gainBefore && c.gain.x < gainBefore + 0.1, "the gain moved toward 1.4: %f", c.gain.x);

    MLFreeMouseVirtualCursorAdvance(&c, 5000, 5000, 800, 600);
    CHECK(near(c.point.x, 800, 1e-12) && near(c.point.y, 600, 1e-12), "the cursor stays in the view");

    MLFreeMouseVirtualCursorReset(&c);
    MLFreeMouseVirtualCursorAnchor(&c, (MLFreeMousePoint){10, 10}, 800, 600, true);
    MLFreeMouseVirtualCursorAdvance(&c, 10, 10, 800, 600);
    MLFreeMouseVirtualCursorAnchor(&c, (MLFreeMousePoint){30, 30}, 800, 600, false);
    CHECK(near(c.gain.x, 1.0, 1e-12), "no gain learning while a button is held");
}

// ---- replay ----

#define MS_PER_RUN 8000
typedef struct {
    double p50, p95, max;
    int jumps40;
    double gain;
} Result;

static MLFreeMousePoint truthAt(double t) {
    // Circles of radius 250 view points, about 2.2 turns a second (up to ~3400 points/s), speed breathing by +-30 %.
    double omega = 2.0 * M_PI * 2.2 * (1.0 + 0.3 * sin(t * 1.3));
    double phase = omega * t;
    return (MLFreeMousePoint){500.0 + 250.0 * cos(phase), 400.0 + 250.0 * sin(phase)};
}

// System pointer acceleration: view points of pointer motion per raw count. The cursor's base scale is 0.75.
static double systemGain(double speed) { return 0.75 * (1.0 + 0.4 * fmin(speed / 1500.0, 1.5)); }

static int cmpDouble(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y;
}

static Result replay(int useLivePointer, int queueMs) {
    static MLFreeMousePoint truth[MS_PER_RUN];
    static MLFreeMousePoint raw[MS_PER_RUN];
    for (int i = 0; i < MS_PER_RUN; i++) truth[i] = truthAt(i / 1000.0);
    raw[0] = (MLFreeMousePoint){0, 0};
    for (int i = 1; i < MS_PER_RUN; i++) {
        double dx = truth[i].x - truth[i - 1].x, dy = truth[i].y - truth[i - 1].y;
        double g = systemGain(hypot(dx, dy) / 0.001);
        raw[i] = (MLFreeMousePoint){dx / g, dy / g};      // raw counts, in view points at scale 1
    }

    MLFreeMouseVirtualCursor c;
    MLFreeMouseVirtualCursorReset(&c);
    MLFreeMouseVirtualCursorAnchor(&c, truth[0], 1000, 800, true);

    static double err[MS_PER_RUN * 2];
    int errCount = 0, jumps = 0;
    MLFreeMousePoint last = truth[0];
    int eventCreated[MS_PER_RUN / 8 + 8], eventDeliver[MS_PER_RUN / 8 + 8], head = 0, tail = 0;
    const int warmup = 1500;   // the gain is learned in the first second

    for (int i = 1; i < MS_PER_RUN; i++) {
        MLFreeMousePoint sent = MLFreeMouseVirtualCursorAdvance(&c, raw[i].x * 0.75, raw[i].y * 0.75, 1000, 800);
        int sentNow = 1;
        if (i % 8 == 0) {                                 // an AppKit mouse event at 125 Hz
            eventCreated[tail] = i; eventDeliver[tail] = i + queueMs; tail++;
        }
        while (head < tail && eventDeliver[head] <= i) {
            MLFreeMousePoint pointer = useLivePointer ? truth[i] : truth[eventCreated[head]];
            head++;
            if (MLFreeMouseVirtualCursorReconcile(&c, pointer, 1000, 800, true, 1.5, NULL)) {
                sent = c.point;
                sentNow = 1;
            }
        }
        if (sentNow) {
            if (i >= warmup) {
                err[errCount++] = hypot(sent.x - truth[i].x, sent.y - truth[i].y);
                if (hypot(sent.x - last.x, sent.y - last.y) > 40.0) jumps++;
            }
            last = sent;
        }
    }
    qsort(err, (size_t)errCount, sizeof(double), cmpDouble);
    Result r = {err[errCount / 2], err[(int)(errCount * 0.95)], err[errCount - 1], jumps, c.gain.x};
    return r;
}

static void testReplay(void) {
    static const int queues[] = {0, 2, 8, 16, 33, 50};
    Result live[6], event[6];
    printf("replay of fast circular motion (view points; error = cursor sent to the host vs the real pointer)\n");
    printf("  queue   pointer source  p50    p95    max   steps>40  gain\n");
    for (int k = 0; k < 6; k++) {
        live[k] = replay(1, queues[k]);
        event[k] = replay(0, queues[k]);
        printf("  %3d ms  event location %6.1f %6.1f %6.1f %6d    %.2f\n", queues[k], event[k].p50, event[k].p95, event[k].max, event[k].jumps40, event[k].gain);
        printf("          live pointer   %6.1f %6.1f %6.1f %6d    %.2f\n", live[k].p50, live[k].p95, live[k].max, live[k].jumps40, live[k].gain);
    }

    for (int k = 0; k < 6; k++) {
        CHECK(live[k].p95 <= 3.0, "live pointer, queue %d ms: p95 %.1f", queues[k], live[k].p95);
        CHECK(live[k].jumps40 == 0, "live pointer, queue %d ms: %d steps over 40", queues[k], live[k].jumps40);
        CHECK(live[k].max <= 25.0, "live pointer, queue %d ms: max %.1f", queues[k], live[k].max);
    }
    CHECK(near(event[0].p95, live[0].p95, 0.5), "with no queue time both sources agree: %.2f vs %.2f", event[0].p95, live[0].p95);
    // The location stored in the event is what makes the cursor lag: its error grows with the queue time.
    for (int k = 1; k < 6; k++) {
        CHECK(event[k].p95 > event[k - 1].p95 - 0.5, "event location: error grows with queue time (%d ms)", queues[k]);
    }
    CHECK(event[4].p95 > 10.0 * live[4].p95, "33 ms queue: event %.1f vs live %.1f", event[4].p95, live[4].p95);
}


static void testLivePointerMap(void) {
    // A 400 x 300 view. One reading: the pointer was at global (350, 640) and at view (50, 60). Other readings follow
    // from the sign of the view's y axis.
    MLLivePointerMap m = MLLivePointerMapCalibrate(350, 640, 50, 60, false, 400, 300, 10.0);
    CHECK(m.valid, "calibrated");
    MLFreeMousePoint v;
    CHECK(MLLivePointerMapToView(&m, 350, 640, 10.0, 0.3, 2.0, &v) && near(v.x, 50, 1e-9) && near(v.y, 60, 1e-9), "same reading");
    CHECK(MLLivePointerMapToView(&m, 380, 600, 10.1, 0.3, 2.0, &v) && near(v.x, 80, 1e-9) && near(v.y, 100, 1e-9),
          "pointer moved right and down on the screen: x grows, y (up) grows by 40: got %f %f", v.x, v.y);
    MLLivePointerMap f = MLLivePointerMapCalibrate(350, 640, 50, 60, true, 400, 300, 10.0);
    CHECK(MLLivePointerMapToView(&f, 380, 600, 10.1, 0.3, 2.0, &v) && near(v.x, 80, 1e-9) && near(v.y, 20, 1e-9),
          "flipped view: y follows the screen: got %f", v.y);
    CHECK(!MLLivePointerMapToView(&m, 350, 640, 10.4, 0.3, 2.0, &v), "a map older than the limit is not used");
    CHECK(!MLLivePointerMapToView(&m, 350, 640, 9.9, 0.3, 2.0, &v), "a map from the future is not used");
    CHECK(!MLLivePointerMapToView(&m, 350 + 460, 640, 10.0, 0.3, 2.0, &v), "pointer outside the view");
    CHECK(MLLivePointerMapToView(&m, 350 + 351, 640, 10.0, 0.3, 2.0, &v), "within the tolerance outside the edge");
    m.valid = false;
    CHECK(!MLLivePointerMapToView(&m, 350, 640, 10.0, 0.3, 2.0, &v), "an invalid map is not used");
    MLLivePointerMap bad = MLLivePointerMapCalibrate(NAN, 0, 0, 0, false, 400, 300, 0.0);
    CHECK(!bad.valid, "non-finite readings do not calibrate");
    bad = MLLivePointerMapCalibrate(1, 1, 1, 1, false, 0, 300, 0.0);
    CHECK(!bad.valid, "an empty view does not calibrate");
}

// ---- smoothness replay: what the host cursor does frame by frame ----

#define SM_N 20000   // ms
static MLFreeMousePoint smTruth[SM_N], smRaw[SM_N];
static unsigned long long smSeed = 88172645463325252ULL;
static double smRand(void) {
    smSeed ^= smSeed << 13; smSeed ^= smSeed >> 7; smSeed ^= smSeed << 17;
    return (double)(smSeed >> 11) * (1.0 / 9007199254740992.0);
}
static double smGain(double speed) {   // pointer view points per raw view point; grows with speed like macOS's curve
    double s = speed / 1000.0;
    return 0.75 * (1.0 + 0.9 * (1.0 - exp(-s * 0.9)) + 0.1 * fmin(s, 4.0));
}
static void smGenerate(void) {
    // Minimum-jerk strokes between random targets with pauses: flicks of 90 to 450 ms, and some slow small moves.
    double x = 500, y = 400; int i = 0;
    while (i < SM_N - 1) {
        double tx = 80 + smRand() * 840, ty = 60 + smRand() * 680;
        int dur = 90 + (int)(smRand() * 360), pause = (int)(smRand() * 250);
        if (smRand() < 0.25) { tx = x + (smRand() - 0.5) * 60; ty = y + (smRand() - 0.5) * 60; dur = 300 + (int)(smRand() * 500); }
        for (int k = 0; k < dur && i < SM_N - 1; k++, i++) {
            double u = (double)k / dur, s = u * u * u * (10 - 15 * u + 6 * u * u);
            smTruth[i] = (MLFreeMousePoint){x + (tx - x) * s, y + (ty - y) * s};
        }
        x = tx; y = ty;
        for (int k = 0; k < pause && i < SM_N - 1; k++, i++) smTruth[i] = (MLFreeMousePoint){x, y};
    }
    smTruth[SM_N - 1] = smTruth[SM_N - 2];
    smRaw[0] = (MLFreeMousePoint){0, 0};
    for (int i = 1; i < SM_N; i++) {
        double dx = smTruth[i].x - smTruth[i - 1].x, dy = smTruth[i].y - smTruth[i - 1].y;
        double g = smGain(hypot(dx, dy) / 0.001);
        smRaw[i] = (MLFreeMousePoint){dx / g, dy / g};
    }
}
typedef struct { double jerk, jerkTruth; int spikes; double p95Lag; int corrections; } SmoothResult;
static int cmpD(const void *a, const void *b) { double x = *(const double *)a, y = *(const double *)b; return x < y ? -1 : x > y; }

// useLive: the pointer read when the reconcile runs (the app); else the location stored in the event (rc.7).
// reconcileHz: how often the pointer is read; ageMs: how long after it was created a mouse event reaches the main thread
// (0 for the CoreHID thread, which does not wait for it); pointerLagMs: how long the system pointer trails the raw motion.
static SmoothResult smReplay(int useLive, double reconcileHz, int ageMs, int pointerLagMs) {
    static MLFreeMousePoint sentAt[SM_N];
    static int created[SM_N], deliver[SM_N];
    MLFreeMouseVirtualCursor c;
    MLFreeMouseVirtualCursorReset(&c);
    MLFreeMouseVirtualCursorAnchor(&c, smTruth[0], 1000, 800, true);
    MLFreeMousePoint sent = smTruth[0];
    int period = (int)(1000.0 / reconcileHz + 0.5), head = 0, tail = 0, corrections = 0;
    if (period < 1) period = 1;
    for (int i = 1; i < SM_N; i++) {
        sent = MLFreeMouseVirtualCursorAdvance(&c, smRaw[i].x * 0.75, smRaw[i].y * 0.75, 1000, 800);
        if (i % period == 0) { created[tail] = i; deliver[tail] = i + ageMs; tail++; }
        while (head < tail && deliver[head] <= i) {
            int src = useLive ? i : created[head];
            head++;
            int at = src - pointerLagMs; if (at < 0) at = 0;
            MLFreeMousePoint p = smTruth[at];
            p.x = floor(p.x * 2.0 + 0.5) / 2.0; p.y = floor(p.y * 2.0 + 0.5) / 2.0;   // device pixels on a 2x display
            if (MLFreeMouseVirtualCursorReconcile(&c, p, 1000, 800, true, 1.5, NULL)) { sent = c.point; corrections++; }
        }
        sentAt[i] = sent;
    }
    sentAt[0] = smTruth[0];
    const int step = 1000 / 60, frames = SM_N / step;
    double sj = 0, tj = 0; int spikes = 0, n = 0, nl = 0;
    static double lag[SM_N];
    for (int f = 2; f < frames - 2; f++) {
        MLFreeMousePoint a = sentAt[(f - 2) * step], b = sentAt[(f - 1) * step], d = sentAt[f * step];
        MLFreeMousePoint ta = smTruth[(f - 2) * step], tb = smTruth[(f - 1) * step], td = smTruth[f * step];
        double jx = d.x - 2 * b.x + a.x, jy = d.y - 2 * b.y + a.y, tjx = td.x - 2 * tb.x + ta.x, tjy = td.y - 2 * tb.y + ta.y;
        sj += jx * jx + jy * jy; tj += tjx * tjx + tjy * tjy; n++;
        if (hypot(jx - tjx, jy - tjy) > 8.0) spikes++;
        lag[nl++] = hypot(d.x - td.x, d.y - td.y);
    }
    qsort(lag, (size_t)nl, sizeof(double), cmpD);
    SmoothResult r = {sqrt(sj / n), sqrt(tj / n), spikes, lag[(int)(nl * 0.95)], corrections};
    return r;
}

static void testSmoothness(void) {
    smGenerate();
    printf("\nhost cursor smoothness at 60 frames a second, 20 s of strokes (jerk: RMS second difference per frame, view points;\n"
           "spikes: frames whose jerk differs from the pointer's by over 8; lag: p95 distance to the pointer)\n");
    printf("  reconcile                              pointer lag  jerk  (pointer)  spikes   lag\n");
    static const int lags[] = {0, 4, 8};
    SmoothResult stale40[3], live40[3], live250[3];
    for (int k = 0; k < 3; k++) {
        stale40[k] = smReplay(0, 40, 17, lags[k]);
        live40[k] = smReplay(1, 40, 17, lags[k]);
        live250[k] = smReplay(1, 250, 0, lags[k]);
        printf("  main thread 40/s, 17 ms old, event pos    %2d ms    %6.2f   %6.2f   %6d  %6.1f\n", lags[k], stale40[k].jerk, stale40[k].jerkTruth, stale40[k].spikes, stale40[k].p95Lag);
        printf("  main thread 40/s, 17 ms old, live pointer %2d ms    %6.2f   %6.2f   %6d  %6.1f\n", lags[k], live40[k].jerk, live40[k].jerkTruth, live40[k].spikes, live40[k].p95Lag);
        printf("  CoreHID thread 250/s, live pointer        %2d ms    %6.2f   %6.2f   %6d  %6.1f\n", lags[k], live250[k].jerk, live250[k].jerkTruth, live250[k].spikes, live250[k].p95Lag);
    }
    for (int k = 0; k < 3; k++) {
        CHECK(live250[k].jerk <= live250[k].jerkTruth * 1.05, "250/s: the cursor is as smooth as the pointer (lag %d ms): %.2f vs %.2f", lags[k], live250[k].jerk, live250[k].jerkTruth);
        CHECK(live250[k].spikes <= 10, "250/s: %d spikes (lag %d ms)", live250[k].spikes, lags[k]);
        CHECK(live250[k].spikes * 5 < live40[k].spikes, "250/s has far fewer spikes than 40/s: %d vs %d (lag %d ms)", live250[k].spikes, live40[k].spikes, lags[k]);
        CHECK(live40[k].jerk > live250[k].jerk * 1.3, "40/s is rougher: %.2f vs %.2f (lag %d ms)", live40[k].jerk, live250[k].jerk, lags[k]);
        CHECK(live40[k].spikes < stale40[k].spikes, "at 40/s the live pointer beats the event position: %d vs %d spikes (lag %d ms)", live40[k].spikes, stale40[k].spikes, lags[k]);
    }
}

int main(void) {
    testRules();
    testReplay();
    testLivePointerMap();
    testSmoothness();
    if (failures) {
        printf("%d check(s) failed\n", failures);
        return 1;
    }
    printf("free-mouse-truth: all checks passed\n");
    return 0;
}
