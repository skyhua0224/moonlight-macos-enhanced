// Tests the CoreHID free-mouse virtual cursor (FreeMouseVirtualCursor.h):
//  1. the rules: gain clamp and blend, anchor, reconcile threshold, clamping to the view;
//  2. a replay of fast circular mouse motion: raw CoreHID motion at 1 kHz with the system's pointer acceleration on
//     top, and an AppKit mouse event at 120 Hz that reaches the main thread `queue` ms after it was created. The
//     cursor is reconciled either against the pointer as it is when the main thread runs (live: what the app does)
//     or against the location stored in the event (event: what the app did until rc.9).
// The replay measures what the host receives: the distance between the cursor position sent and the real pointer at
// that moment, and the position steps over 40 view points. No hardware, no host.
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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

int main(void) {
    testRules();
    testReplay();
    if (failures) {
        printf("%d check(s) failed\n", failures);
        return 1;
    }
    printf("free-mouse-truth: all checks passed\n");
    return 0;
}
