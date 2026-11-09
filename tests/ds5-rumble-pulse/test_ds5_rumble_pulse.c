#include "../../Limelight/Input/DS5OutputCoalescer.h"
#include "../../Limelight/Input/DS5RumbleScheduler.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>

static int failures;

#define CHECK(condition) \
    do { \
        if (!(condition)) { \
            fprintf(stderr, "%s:%d: check failed: %s\n", __FILE__, __LINE__, #condition); \
            failures++; \
        } \
    } while (0)

enum { LEN = 63 };

static void make_report(uint8_t *r, uint8_t left, uint8_t right) {
    memset(r, 0, LEN);
    r[0] = 0x02;
    r[1] = 0x03;
    r[3] = right;
    r[4] = left;
    r[39] = 0x04;
}

// What the pad received: the sequence of motor states and when each started.
typedef struct { double at; bool running; } PadEvent;
typedef struct { PadEvent events[4096]; int count; } PadLog;

static void pad_note(PadLog *log, double at, bool running) {
    if (log->count > 0 && log->events[log->count - 1].running == running) return;
    log->events[log->count].at = at;
    log->events[log->count].running = running;
    log->count++;
}

// Runs a series of host pulses: a start at k * period and a stop pulseMs later, for `seconds`. The scheduler's output goes
// through the coalescer; the writer completes each write after writeMs and starts one at most every pacing ms.
// Returns the number of distinct runs the pad saw (a run is a start followed by a stop).
static int run_series(double periodMs, double pulseMs, double seconds, bool paced, double writeMs, PadLog *log, DS5RumbleStats *outStats, DS5OutputStats *outCoalescer) {
    DS5RumbleScheduler sched;
    DS5OutputCoalescer co;
    ds5_rs_init(&sched);
    ds5_outc_init(&co);
    if (!paced) co.pacedIntervalMs = 0.0;
    memset(log, 0, sizeof(*log));
    const int pulses = (int)(seconds * 1000.0 / periodMs);
    const double end = seconds * 1000.0 + 500.0;
    double writeDoneAt = -1.0;
    bool inFlight = false;
    for (double now = 0.0; now <= end; now += 0.5) {
        // Host events at this instant.
        for (int k = 0; k < pulses; k++) {
            const double start = k * periodMs + 3.0;
            DS5RumbleAction a = { false, 0, 0 };
            bool have = false;
            if (fabs(now - start) < 0.25) { a = ds5_rs_event(&sched, now, 40000, 40000); have = true; }
            else if (fabs(now - (start + pulseMs)) < 0.25) { a = ds5_rs_event(&sched, now, 0, 0); have = true; }
            if (have && a.apply) {
                uint8_t r[LEN];
                make_report(r, (uint8_t)(a.low >> 8), (uint8_t)(a.high >> 8));
                ds5_outc_submit(&co, 1, paced, r, LEN);
            }
        }
        const double due = ds5_rs_next_due(&sched);
        if (due >= 0.0 && now >= due) {
            DS5RumbleAction a = ds5_rs_tick(&sched, now);
            if (a.apply) {
                uint8_t r[LEN];
                make_report(r, (uint8_t)(a.low >> 8), (uint8_t)(a.high >> 8));
                ds5_outc_submit(&co, 1, paced, r, LEN);
            }
        }
        if (inFlight && now >= writeDoneAt) {
            ds5_outc_complete(&co, now, true);
            inFlight = false;
        }
        if (!inFlight) {
            uint8_t out[DS5_OUTC_CAPACITY];
            size_t length = 0;
            uint64_t key = 0;
            double wait = 0.0;
            if (ds5_outc_next(&co, now, out, &length, &key, &wait) == DS5_OUTC_WRITE) {
                pad_note(log, now, (out[3] | out[4]) != 0u);
                inFlight = true;
                writeDoneAt = now + writeMs;
            }
        }
    }
    int runs = 0;
    for (int i = 0; i < log->count; i++) if (log->events[i].running) runs++;
    *outStats = ds5_rs_take_stats(&sched);
    *outCoalescer = ds5_outc_take_stats(&co);
    return runs;
}

static void check_series(const char *name, double hz, bool paced, double writeMs) {
    PadLog log;
    DS5RumbleStats stats;
    DS5OutputStats cstats;
    const double period = 1000.0 / hz;
    const int runs = run_series(period, 10.0, 4.0, paced, writeMs, &log, &stats, &cstats);
    const int pulses = (int)(4.0 * 1000.0 / period);
    if (runs != pulses) fprintf(stderr, "%s: %d host pulses, the pad saw %d runs (applied %u pulses %u deferred %u merged %u written %u kept %u dropped %u)\n", name, pulses, runs, stats.applied, stats.pulses, stats.deferred, stats.merged, cstats.written, cstats.kept, cstats.dropped);
    CHECK(runs == pulses);
    CHECK(stats.received == (unsigned)pulses * 2u);
    CHECK(cstats.dropped == 0);
    // Every run stays apart from the next: a stop sits between two starts, and no run is shorter than one write.
    for (int i = 0; i + 1 < log.count; i++) {
        if (log.events[i].running) CHECK(log.events[i + 1].at - log.events[i].at >= (paced ? 5.0 : 2.0) - 1e-9);
    }
}

// The CoreHaptics path: the scheduler's applied values go to the engine directly, one call per edge, with no write
// to wait for. Every pulse must start and stop as its own run.
static void check_corehaptics_series(const char *name, double hz) {
    DS5RumbleScheduler sched;
    ds5_rs_init(&sched);
    const double period = 1000.0 / hz;
    const int pulses = (int)(4.0 * 1000.0 / period);
    bool running = false;
    int runs = 0;
    double startedAt = 0.0, shortest = 1e9, lastStop = -1e9, smallestGap = 1e9;
    const double end = 4.0 * 1000.0 + 500.0;
    for (double now = 0.0; now <= end; now += 0.5) {
        DS5RumbleAction a = { false, 0, 0 };
        for (int k = 0; k < pulses; k++) {
            const double start = k * period + 3.0;
            if (fabs(now - start) < 0.25) a = ds5_rs_event(&sched, now, 40000, 40000);
            else if (fabs(now - (start + 10.0)) < 0.25) a = ds5_rs_event(&sched, now, 0, 0);
        }
        if (!a.apply) {
            const double due = ds5_rs_next_due(&sched);
            if (due >= 0.0 && now >= due) a = ds5_rs_tick(&sched, now);
        }
        if (!a.apply) continue;
        const bool nonzero = (a.low | a.high) != 0u;
        if (nonzero && !running) {
            running = true;
            startedAt = now;
            runs++;
            if (now - lastStop < smallestGap) smallestGap = now - lastStop;
        } else if (!nonzero && running) {
            running = false;
            lastStop = now;
            if (now - startedAt < shortest) shortest = now - startedAt;
        }
    }
    if (runs != pulses) fprintf(stderr, "%s: %d host pulses, the engine played %d\n", name, pulses, runs);
    CHECK(runs == pulses);
    CHECK(shortest >= DS5_RS_MIN_PULSE_MS - 0.6);  // each pulse is held for the minimum length
    CHECK(smallestGap > 10.0);                      // and stays apart from the next one
}

static void test_series(void) {
    for (int usb = 0; usb < 2; usb++) {
        for (int index = 0; index < 3; index++) {
            const double hz = index == 0 ? 5.0 : index == 1 ? 10.0 : 20.0;
            char name[96];
            if (!usb && index == 2) {
                // Raw Bluetooth writes take about 32 ms each and go one at a time: a pulse needs two (start and
                // stop), so 20 pulses a second (40 writes) do not fit the radio. That case is the CoreHaptics path,
                // which has no write to wait for; the raw path must report what it could not carry, not hide it.
                snprintf(name, sizeof name, "CoreHaptics (Bluetooth pad) %.0f Hz 10 ms pulses", hz);
                check_corehaptics_series(name, hz);
                PadLog log;
                DS5RumbleStats stats;
                DS5OutputStats cstats;
                const int runs = run_series(1000.0 / hz, 10.0, 4.0, true, 32.0, &log, &stats, &cstats);
                CHECK(runs > 0 && runs < 80);
                CHECK(cstats.dropped > 0);  // counted, not silent
                continue;
            }
            snprintf(name, sizeof name, "%s %.0f Hz 10 ms pulses", usb ? "USB" : "Bluetooth raw", hz);
            check_series(name, hz, !usb, usb ? 2.0 : 32.0);
            if (usb) {
                snprintf(name, sizeof name, "CoreHaptics (USB pad) %.0f Hz 10 ms pulses", hz);
                check_corehaptics_series(name, hz);
            }
        }
    }
}

static void test_a_stop_inside_the_hold_is_deferred_not_dropped(void) {
    DS5RumbleScheduler s;
    ds5_rs_init(&s);
    DS5RumbleAction a = ds5_rs_event(&s, 0.0, 50000, 20000);
    CHECK(a.apply && a.low == 50000);
    a = ds5_rs_event(&s, 2.0, 0, 0);
    CHECK(!a.apply);  // held to the end of the pulse
    CHECK(ds5_rs_next_due(&s) == DS5_RS_MIN_PULSE_MS);
    a = ds5_rs_tick(&s, DS5_RS_MIN_PULSE_MS);
    CHECK(a.apply && a.low == 0 && a.high == 0);
    CHECK(s.stats.deferred == 1);
}

static void test_peak_inside_a_hold(void) {
    DS5RumbleScheduler s;
    ds5_rs_init(&s);
    ds5_rs_event(&s, 0.0, 10000, 60000);
    DS5RumbleAction a = ds5_rs_event(&s, 4.0, 30000, 5000);
    CHECK(a.apply && a.low == 30000 && a.high == 60000);  // the louder value of each motor
    // After the hold the newest value plays.
    a = ds5_rs_tick(&s, DS5_RS_MIN_PULSE_MS + 1.0);
    CHECK(a.apply && a.low == 30000 && a.high == 5000);
}

static void test_a_long_rumble_is_untouched(void) {
    DS5RumbleScheduler s;
    ds5_rs_init(&s);
    DS5RumbleAction a = ds5_rs_event(&s, 0.0, 40000, 40000);
    CHECK(a.apply);
    a = ds5_rs_event(&s, 500.0, 20000, 20000);
    CHECK(a.apply && a.low == 20000);  // after the hold the newest value, not the peak
    a = ds5_rs_event(&s, 900.0, 0, 0);
    CHECK(a.apply && a.low == 0);  // no deferral outside a hold
    CHECK(s.stats.deferred == 0);
}

static void test_coalescer_keeps_a_pulse_behind_the_pending_one(void) {
    DS5OutputCoalescer c;
    ds5_outc_init(&c);
    uint8_t r[LEN], out[DS5_OUTC_CAPACITY];
    size_t length = 0;
    uint64_t key = 0;
    double wait = 0.0;
    make_report(r, 200, 200);
    ds5_outc_submit(&c, 1, true, r, LEN);
    make_report(r, 0, 0);
    ds5_outc_submit(&c, 1, true, r, LEN);  // the stop must not replace the start
    make_report(r, 180, 180);
    ds5_outc_submit(&c, 1, true, r, LEN);  // a second pulse behind the stop
    CHECK(c.queueCount == 3);
    CHECK(ds5_outc_next(&c, 0.0, out, &length, &key, &wait) == DS5_OUTC_WRITE && out[4] == 200);
    ds5_outc_complete(&c, 30.0, true);
    CHECK(ds5_outc_next(&c, 30.0, out, &length, &key, &wait) == DS5_OUTC_WRITE && out[4] == 0);
    ds5_outc_complete(&c, 31.0, true);
    CHECK(ds5_outc_next(&c, 60.0, out, &length, &key, &wait) == DS5_OUTC_WRITE && out[4] == 180);
    CHECK(c.stats.pulses == 2);
}

static void test_peak_inside_a_pending_pulse(void) {
    DS5OutputCoalescer c;
    ds5_outc_init(&c);
    uint8_t r[LEN], out[DS5_OUTC_CAPACITY];
    size_t length = 0;
    uint64_t key = 0;
    double wait = 0.0;
    make_report(r, 200, 10);
    ds5_outc_submit(&c, 1, true, r, LEN);
    make_report(r, 50, 150);
    ds5_outc_submit(&c, 1, true, r, LEN);
    CHECK(c.queueCount == 1);
    CHECK(ds5_outc_next(&c, 0.0, out, &length, &key, &wait) == DS5_OUTC_WRITE);
    CHECK(out[4] == 200 && out[3] == 150);  // left 200 and right 150: the peak of each motor
}

int main(void) {
    test_series();
    test_a_stop_inside_the_hold_is_deferred_not_dropped();
    test_peak_inside_a_hold();
    test_a_long_rumble_is_untouched();
    test_coalescer_keeps_a_pulse_behind_the_pending_one();
    test_peak_inside_a_pending_pulse();
    if (failures != 0) {
        fprintf(stderr, "%d rumble pulse check(s) failed\n", failures);
        return 1;
    }
    puts("rumble pulse tests passed");
    return 0;
}
