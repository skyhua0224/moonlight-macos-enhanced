// Tests the frame-rate meter (MLFpsMeter.h) against the number the overlay used to show (issue #87: "FPS jumps above the
// set rate"). Everything runs on a simulated clock; no stream, no host.
//
// The old rule, as VideoDecoderRenderer.m and the overlay applied it: a statistics window opens on a frame and closes on
// the first frame that arrives once 1000 ms have passed; every frame stores the open window, whose rate fields are 0;
// the overlay (timer every 500 ms) then showed frames-in-window / (now - window start). `OldWindow` below is that rule.
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "MLFpsMeter.h"

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

typedef struct {
    uint64_t start;
    uint32_t frames;
} OldWindow;

static void oldFrame(OldWindow *w, uint64_t now) {
    if (w->start == 0) {
        w->start = now;
    }
    if (now - w->start >= 1000) {
        w->start = now;
        w->frames = 0;
    }
    w->frames++;
}

static double oldRate(const OldWindow *w, uint64_t now) {
    if (w->frames == 0 || now <= w->start) {
        return 0.0;
    }
    return (double)w->frames / ((double)(now - w->start) / 1000.0);
}

static uint32_t lcg = 12345u;
static double rnd(void) {
    lcg = lcg * 1664525u + 1013904223u;
    return (double)(lcg >> 8) / (double)(1u << 24);
}

typedef struct {
    const char *name;
    double fps;
    double jitterMs;  // each arrival moves by a uniform amount in +-jitterMs
} Cadence;

typedef struct {
    double oldMax, oldP99, oldOver, newMax, newMin;
    int reads;
} Result;

static int cmpd(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : (x > y);
}

// 180 s of frames at `fps`; the overlay timer reads every `tickMs`, starting at `tickPhaseMs`.
static Result run(const Cadence *c, uint64_t tickMs, uint64_t tickPhaseMs) {
    const uint64_t t0 = 100000;
    const uint64_t end = t0 + 180000;
    MLFpsMeter meter;
    MLFpsMeterReset(&meter);
    OldWindow old = {0, 0};
    Result r = {0, 0, 0, 0, 1e9, 0};
    double *olds = malloc(sizeof(double) * 40000);
    uint64_t nextTick = t0 + tickPhaseMs;
    double ideal = (double)t0;
    uint64_t lastFrame = 0;
    int n = 0;
    while (ideal < (double)end) {
        double jittered = ideal + (c->jitterMs > 0 ? (rnd() * 2.0 - 1.0) * c->jitterMs : 0.0);
        uint64_t at = (uint64_t)llround(jittered);
        if (at < lastFrame) {
            at = lastFrame;
        }
        lastFrame = at;
        while (nextTick <= at) {
            // read: the frames up to `nextTick` are in; those at `at` are not yet
            if (nextTick > t0 + 3000) {
                double o = oldRate(&old, nextTick), nw = MLFpsMeterRate(&meter, nextTick);
                olds[n++] = o;
                if (o > r.oldMax) r.oldMax = o;
                if (o > c->fps * 1.05) r.oldOver += 1;
                if (nw > r.newMax) r.newMax = nw;
                if (nw < r.newMin) r.newMin = nw;
            }
            nextTick += tickMs;
        }
        oldFrame(&old, at);
        MLFpsMeterNote(&meter, at);
        ideal += 1000.0 / c->fps;
    }
    qsort(olds, (size_t)n, sizeof(double), cmpd);
    r.oldP99 = olds[(size_t)((double)n * 0.99)];
    r.oldOver = r.oldOver * 100.0 / (double)n;
    r.reads = n;
    free(olds);
    return r;
}

int main(void) {
    // 1. the rate is right at every instant of a steady stream, whatever the phase of the read
    {
        const Cadence cadences[] = {
            {"60 fps steady", 60.0, 0.0},
            {"60 fps, 3 ms jitter", 60.0, 3.0},
            {"120 fps steady", 120.0, 0.0},
            {"26.4 fps (idle desktop)", 26.4, 1.0},
            {"60 fps, 8 ms jitter", 60.0, 8.0},
        };
        for (size_t i = 0; i < sizeof(cadences) / sizeof(cadences[0]); i++) {
            const Cadence *c = &cadences[i];
            double worst = 0.0;
            for (uint64_t phase = 0; phase < 1000; phase += 7) {
                MLFpsMeter m;
                MLFpsMeterReset(&m);
                double ideal = 100000.0;
                uint64_t last = 0;
                uint64_t readAt = 103000 + phase;  // at least 3 s in
                double rate = 0.0;
                for (;;) {
                    uint64_t at = (uint64_t)llround(ideal + (c->jitterMs > 0 ? (rnd() * 2.0 - 1.0) * c->jitterMs : 0.0));
                    if (at < last) at = last;
                    if (at > readAt) break;
                    last = at;
                    MLFpsMeterNote(&m, at);
                    ideal += 1000.0 / c->fps;
                }
                rate = MLFpsMeterRate(&m, readAt);
                double err = fabs(rate - c->fps);
                if (err > worst) worst = err;
            }
            double limit = 1.0 / 0.95 + 0.6 + (c->jitterMs > 0 ? 1.5 : 0.0);  // one frame over 950 ms, plus edge frames
            CHECK(worst <= limit, "%s: worst error %.2f fps (limit %.2f)", c->name, worst, limit);
        }
    }

    // 2. before / after: what the overlay showed for the same arrivals, the timer every 500 ms
    printf("%-26s %-7s %9s %9s %11s %11s | %8s %8s\n", "cadence", "tick", "old max", "old p99", "old >105%", "(mean)", "new max", "new min");
    {
        const Cadence cadences[] = {
            {"60 fps steady", 60.0, 0.0},
            {"60 fps, 3 ms jitter", 60.0, 3.0},
            {"60 fps, 8 ms jitter", 60.0, 8.0},
            {"26.4 fps (idle desktop)", 26.4, 1.0},
        };
        double worstOldOverall = 0.0;
        for (size_t i = 0; i < sizeof(cadences) / sizeof(cadences[0]); i++) {
            for (uint64_t tick = 500; tick <= 1000; tick += 500) {
                // the phase between timer and window drifts by the arrival jitter, so scan the starting phase
                Result worst = {0, 0, 0, 0, 1e9, 0};
                double overSum = 0.0;
                int phases = 0;
                for (uint64_t phase = 0; phase < tick; phase += 37) {
                    Result r = run(&cadences[i], tick, phase);
                    overSum += r.oldOver;
                    phases++;
                    if (r.oldMax > worst.oldMax) worst.oldMax = r.oldMax;
                    if (r.oldP99 > worst.oldP99) worst.oldP99 = r.oldP99;
                    if (r.oldOver > worst.oldOver) worst.oldOver = r.oldOver;
                    if (r.newMax > worst.newMax) worst.newMax = r.newMax;
                    if (r.newMin < worst.newMin) worst.newMin = r.newMin;
                }
                printf("%-26s %4llu ms %9.1f %9.1f %10.1f%% %10.1f%% | %8.1f %8.1f\n", cadences[i].name, (unsigned long long)tick,
                       worst.oldMax, worst.oldP99, worst.oldOver, overSum / phases, worst.newMax, worst.newMin);
                if (worst.oldMax > worstOldOverall) worstOldOverall = worst.oldMax;
                double hi = cadences[i].fps * 1.0 + 1.0 / 0.95 + 0.6 + (cadences[i].jitterMs > 0 ? 3.0 : 0.0);
                double lo = cadences[i].fps - (1.0 / 0.95 + 0.6) - (cadences[i].jitterMs > 0 ? 3.0 : 0.0);
                CHECK(worst.newMax <= hi, "%s tick %llu: new max %.1f > %.1f", cadences[i].name, (unsigned long long)tick, worst.newMax, hi);
                CHECK(worst.newMin >= lo, "%s tick %llu: new min %.1f < %.1f", cadences[i].name, (unsigned long long)tick, worst.newMin, lo);
            }
        }
        // the old rule must reproduce the report, or this test would prove nothing about the cause
        CHECK(worstOldOverall > 100.0, "the old rule never went above 100 fps (max %.1f): the model is not the reported bug", worstOldOverall);
    }

    // 3. frames stop: the rate falls to zero within a second
    {
        MLFpsMeter m;
        MLFpsMeterReset(&m);
        for (uint64_t t = 50000; t < 52000; t += 17) MLFpsMeterNote(&m, t);
        double at500 = MLFpsMeterRate(&m, 52500), at1100 = MLFpsMeterRate(&m, 53100), at3000 = MLFpsMeterRate(&m, 55000);
        CHECK(at500 > 15.0 && at500 < 35.0, "half a second after the last frame: %.1f", at500);
        CHECK(at1100 == 0.0 && at3000 == 0.0, "after a second of nothing: %.1f / %.1f", at1100, at3000);
    }

    // 4. a few frames within milliseconds never read as a huge rate
    {
        MLFpsMeter m;
        MLFpsMeterReset(&m);
        MLFpsMeterNote(&m, 70000);
        MLFpsMeterNote(&m, 70002);
        MLFpsMeterNote(&m, 70004);
        for (uint64_t read = 70005; read < 71200; read += 3) {
            double r = MLFpsMeterRate(&m, read);
            CHECK(r <= 3.0 * 1000.0 / ML_FPS_METER_MIN_SPAN_MS + 1e-9, "burst read at +%llu ms: %.1f", (unsigned long long)(read - 70000), r);
        }
    }

    // 5. the start of a stream: the first 250 ms cannot show more than a frame over the minimum span
    {
        MLFpsMeter m;
        MLFpsMeterReset(&m);
        double worst = 0.0;
        for (uint64_t t = 80000; t < 81000; t += 17) {
            MLFpsMeterNote(&m, t);
            double r = MLFpsMeterRate(&m, t);
            if (r > worst) worst = r;
        }
        CHECK(worst <= 4.0 * 1000.0 / ML_FPS_METER_MIN_SPAN_MS + 1e-9 + 60.0, "first second of 60 fps: %.1f", worst);
    }

    // 6. the rate follows a change of cadence within a second, and old bins never come back (ring reuse over 100 s)
    {
        MLFpsMeter m;
        MLFpsMeterReset(&m);
        uint64_t t = 1000;
        for (; t < 41000; t += 17) MLFpsMeterNote(&m, t);       // about 60 fps for 40 s
        double steady = MLFpsMeterRate(&m, t);
        for (uint64_t end = t + 60000; t < end; t += 34) MLFpsMeterNote(&m, t);  // about 30 fps for 60 s
        double after = MLFpsMeterRate(&m, t);
        CHECK(steady > 56.0 && steady < 62.0, "steady 60: %.1f", steady);
        CHECK(after > 27.0 && after < 32.0, "after the change to 30: %.1f", after);
        double soon = 0.0;
        {
            MLFpsMeter s;
            MLFpsMeterReset(&s);
            uint64_t u = 5000;
            for (; u < 15000; u += 17) MLFpsMeterNote(&s, u);
            uint64_t change = u;
            for (; u < change + 1100; u += 34) MLFpsMeterNote(&s, u);
            soon = MLFpsMeterRate(&s, u);
        }
        CHECK(soon > 27.0 && soon < 36.0, "1.1 s after the change to 30: %.1f", soon);
    }

    // 7. a reading before the first frame, or with the clock behind it, is 0
    {
        MLFpsMeter m;
        MLFpsMeterReset(&m);
        CHECK(MLFpsMeterRate(&m, 12345) == 0.0, "empty meter");
        MLFpsMeterNote(&m, 20000);
        CHECK(MLFpsMeterRate(&m, 19000) == 0.0, "clock behind the first frame");
    }

    if (failures == 0) {
        printf("fps-meter: all checks passed\n");
    }
    return failures == 0 ? 0 : 1;
}
