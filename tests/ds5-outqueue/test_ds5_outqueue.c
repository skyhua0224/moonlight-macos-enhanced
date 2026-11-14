#define _POSIX_C_SOURCE 200809L
#include "../../Limelight/Input/DS5OutputCoalescer.h"

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static int failures;
static int legacy;  // DS5_TEST_LEGACY=1: the behaviour before the output queue

#define CHECK(condition) \
    do { \
        if (!(condition)) { \
            fprintf(stderr, "%s:%d: check failed: %s\n", __FILE__, __LINE__, #condition); \
            failures++; \
        } \
    } while (0)

enum { LEN = 63 };

static void make_report(uint8_t *r, uint8_t flag0, uint8_t flag1, uint8_t flag2, uint8_t left, uint8_t right) {
    memset(r, 0, LEN);
    r[0] = 0x02;
    r[1] = flag0;
    r[2] = flag1;
    r[3] = right;
    r[4] = left;
    r[39] = flag2;
}

static bool paced(void) { return !legacy; }

static void init(DS5OutputCoalescer *c) {
    ds5_outc_init(c);
    if (legacy) c->pacedIntervalMs = 0.0;
}

// Runs the writer to the end at simulated time `now`: every write takes `writeMs`. Returns the last report written.
static unsigned drain_until(DS5OutputCoalescer *c, double *now, double writeMs, uint8_t *lastWritten, double stopAt) {
    unsigned writes = 0;
    for (int guard = 0; guard < 10000 && *now <= stopAt; guard++) {
        uint8_t out[DS5_OUTC_CAPACITY];
        size_t length = 0;
        uint64_t key = 0;
        double wait = 0.0;
        DS5OutputStep step = ds5_outc_next(c, *now, out, &length, &key, &wait);
        if (step == DS5_OUTC_WRITE) {
            writes++;
            if (lastWritten != NULL) memcpy(lastWritten, out, LEN);
            *now += writeMs;
            ds5_outc_complete(c, *now, true);
        } else if (step == DS5_OUTC_WAIT && wait > 0.0) {
            *now += wait;
        } else {
            break;
        }
    }
    return writes;
}

static void test_burst_is_capped_and_final_state_written(void) {
    DS5OutputCoalescer c;
    init(&c);
    uint8_t report[LEN], written[LEN] = {0};
    double now = 0.0;
    unsigned writes = 0;
    // 200 requests, one every 5 ms (a host sending at 200 Hz), each a different rumble value.
    for (int i = 0; i < 200; i++) {
        make_report(report, 0x03, 0, 0x04, (uint8_t)(i + 1), (uint8_t)(i + 1));
        CHECK(ds5_outc_submit(&c, 1, paced(), report, LEN));
        writes += drain_until(&c, &now, 4.0, written, now);
        now = (i + 1) * 5.0;
    }
    // The last request is the stop state; it must be written whatever the pacing says.
    make_report(report, 0x03, 0, 0x04, 0, 0);
    CHECK(ds5_outc_submit(&c, 1, paced(), report, LEN));
    writes += drain_until(&c, &now, 4.0, written, 1e9);
    // 1000 ms of requests: at most one write start per 30 ms, plus the first one and the final stop, which now
    // waits behind the running value (a pulse is held for one write) instead of replacing it.
    CHECK(writes <= 1000 / 30 + 3);
    CHECK(written[3] == 0 && written[4] == 0);  // the zero state is what the pad ends with
    DS5OutputStats s = c.stats;
    CHECK(s.requested == 201);
    CHECK(s.written == writes);
    CHECK(s.merged + s.identical + s.written >= s.requested - 1);
}

static void test_never_more_than_one_pending(void) {
    DS5OutputCoalescer c;
    init(&c);
    uint8_t report[LEN];
    for (int i = 0; i < 50; i++) {
        make_report(report, 0x03, 0, 0x04, (uint8_t)i, 0);
        CHECK(ds5_outc_submit(&c, 1, paced(), report, LEN));
    }
    uint8_t out[DS5_OUTC_CAPACITY];
    size_t length = 0;
    uint64_t key = 0;
    double wait = 0.0;
    CHECK(ds5_outc_next(&c, 0.0, out, &length, &key, &wait) == DS5_OUTC_WRITE);
    CHECK(out[4] == 49);  // the newest value, not the first
    CHECK(c.stats.merged == 49);
    CHECK(!c.hasPending);
}

static void test_identical_report_dropped_on_bluetooth_only(void) {
    DS5OutputCoalescer c;
    init(&c);
    uint8_t report[LEN], out[DS5_OUTC_CAPACITY];
    size_t length = 0;
    uint64_t key = 0;
    double wait = 0.0, now = 0.0;
    make_report(report, 0, 0x04, 0, 0, 0);
    report[45] = 200;  // a lightbar colour byte
    ds5_outc_submit(&c, 1, paced(), report, LEN);
    CHECK(ds5_outc_next(&c, now, out, &length, &key, &wait) == DS5_OUTC_WRITE);
    now += 32.0;
    ds5_outc_complete(&c, now, true);
    ds5_outc_submit(&c, 1, paced(), report, LEN);
    now += 100.0;
    DS5OutputStep again = ds5_outc_next(&c, now, out, &length, &key, &wait);
    CHECK(again == DS5_OUTC_IDLE);  // the pad already holds it
    CHECK(c.stats.identical == 1);
    // A USB pad (not paced) is written again, as before.
    DS5OutputCoalescer u;
    ds5_outc_init(&u);
    ds5_outc_submit(&u, 1, false, report, LEN);
    CHECK(ds5_outc_next(&u, 0.0, out, &length, &key, &wait) == DS5_OUTC_WRITE);
    ds5_outc_complete(&u, 1.0, true);
    ds5_outc_submit(&u, 1, false, report, LEN);
    CHECK(ds5_outc_next(&u, 1.0, out, &length, &key, &wait) == DS5_OUTC_WRITE);
}

static void test_zero_state_is_not_dropped_by_pacing(void) {
    DS5OutputCoalescer c;
    init(&c);
    uint8_t report[LEN], out[DS5_OUTC_CAPACITY];
    size_t length = 0;
    uint64_t key = 0;
    double wait = 0.0, now = 0.0;
    make_report(report, 0x03, 0, 0x04, 200, 200);
    ds5_outc_submit(&c, 1, paced(), report, LEN);
    CHECK(ds5_outc_next(&c, now, out, &length, &key, &wait) == DS5_OUTC_WRITE);
    now += 5.0;
    ds5_outc_complete(&c, now, true);
    make_report(report, 0x03, 0, 0x04, 0, 0);  // rumble off, 5 ms later
    ds5_outc_submit(&c, 1, paced(), report, LEN);
    DS5OutputStep step = ds5_outc_next(&c, now, out, &length, &key, &wait);
    CHECK(step == DS5_OUTC_WAIT && wait > 20.0 && wait <= 30.0);  // held back, not dropped
    now += wait;
    CHECK(ds5_outc_next(&c, now, out, &length, &key, &wait) == DS5_OUTC_WRITE);
    CHECK(out[3] == 0 && out[4] == 0 && out[1] == 0x03);
}

static void test_merge_keeps_union_of_flags_and_newest_values(void) {
    DS5OutputCoalescer c;
    init(&c);
    uint8_t a[LEN], b[LEN], out[DS5_OUTC_CAPACITY];
    size_t length = 0;
    uint64_t key = 0;
    double wait = 0.0;
    make_report(a, 0x03, 0x04, 0x01, 10, 20);
    make_report(b, 0x10, 0x10, 0x04, 30, 40);
    ds5_outc_submit(&c, 7, paced(), a, LEN);
    ds5_outc_submit(&c, 7, paced(), b, LEN);
    CHECK(ds5_outc_next(&c, 0.0, out, &length, &key, &wait) == DS5_OUTC_WRITE);
    CHECK(out[1] == 0x13 && out[2] == 0x14 && out[39] == 0x05);
    CHECK(out[3] == 40 && out[4] == 30);
    // Another pad's report is not merged into this one.
    DS5OutputCoalescer d;
    init(&d);
    ds5_outc_submit(&d, 1, paced(), a, LEN);
    ds5_outc_submit(&d, 2, paced(), b, LEN);
    CHECK(ds5_outc_next(&d, 0.0, out, &length, &key, &wait) == DS5_OUTC_WRITE);
    CHECK(key == 2 && out[1] == 0x10);
}

static void test_failed_write_is_retried(void) {
    DS5OutputCoalescer c;
    init(&c);
    uint8_t report[LEN], out[DS5_OUTC_CAPACITY];
    size_t length = 0;
    uint64_t key = 0;
    double wait = 0.0;
    make_report(report, 0x03, 0, 0x04, 9, 9);
    ds5_outc_submit(&c, 1, paced(), report, LEN);
    CHECK(ds5_outc_next(&c, 0.0, out, &length, &key, &wait) == DS5_OUTC_WRITE);
    ds5_outc_complete(&c, 40.0, false);
    ds5_outc_submit(&c, 1, paced(), report, LEN);
    CHECK(ds5_outc_next(&c, 100.0, out, &length, &key, &wait) == DS5_OUTC_WRITE);  // not taken for a duplicate
    CHECK(c.stats.failed == 1);
    // A pad that was matched again is written even with an equal report.
    ds5_outc_complete(&c, 140.0, true);
    ds5_outc_forget_last(&c, 1);
    ds5_outc_submit(&c, 1, paced(), report, LEN);
    CHECK(ds5_outc_next(&c, 300.0, out, &length, &key, &wait) == DS5_OUTC_WRITE);
}

// A model of the two queue layouts. The input callback hands a report to the writer and must return
// at once; the writer blocks for `writeMs` in each write (a slow Bluetooth setReport).
typedef struct Harness {
    pthread_mutex_t coalescerLock;
    pthread_mutex_t queueLock;  // the one serial queue of the old layout
    DS5OutputCoalescer c;
    int shared;
    volatile int stop;
    double writeMs;
} Harness;

static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1e6;
}

static void sleep_ms(double ms) {
    struct timespec ts = {(time_t)(ms / 1000.0), (long)((ms - (double)((time_t)(ms / 1000.0)) * 1000.0) * 1e6)};
    nanosleep(&ts, NULL);
}

static void *writer_thread(void *arg) {
    Harness *h = arg;
    while (!h->stop) {
        if (h->shared) pthread_mutex_lock(&h->queueLock);
        uint8_t out[DS5_OUTC_CAPACITY];
        size_t length = 0;
        uint64_t key = 0;
        double wait = 0.0;
        pthread_mutex_lock(&h->coalescerLock);
        DS5OutputStep step = ds5_outc_next(&h->c, now_ms(), out, &length, &key, &wait);
        pthread_mutex_unlock(&h->coalescerLock);
        if (step == DS5_OUTC_WRITE) {
            sleep_ms(h->writeMs);  // the blocking write
            pthread_mutex_lock(&h->coalescerLock);
            ds5_outc_complete(&h->c, now_ms(), true);
            pthread_mutex_unlock(&h->coalescerLock);
        }
        if (h->shared) pthread_mutex_unlock(&h->queueLock);
        sleep_ms(1.0);
    }
    return NULL;
}

static void make_audio(uint8_t *r, uint8_t mark) {
    memset(r, 0, 547);
    r[0] = 0x39;
    r[2] = mark;
}

static void test_audio_stays_ordered_on_the_frame_clock(void) {
    DS5OutputCoalescer c;
    init(&c);
    uint8_t report[547], out[DS5_OUTC_CAPACITY];
    size_t length = 0;
    uint64_t key = 0;
    double wait = 0.0;
    for (int i = 1; i <= 3; i++) {
        make_audio(report, (uint8_t)i);
        CHECK(ds5_outc_submit(&c, 1, true, report, 547));
    }
    CHECK(ds5_outc_next(&c, 0.0, out, &length, &key, &wait) == DS5_OUTC_WRITE);
    CHECK(out[0] == 0x39 && out[2] == 1 && length == 547);
    CHECK(ds5_outc_next(&c, 0.0, out, &length, &key, &wait) == DS5_OUTC_WAIT);
    CHECK(wait > 21.0 && wait < 21.4);
    // The first completion has not arrived. The next frame still starts on the clock.
    CHECK(ds5_outc_next(&c, DS5_OUTC_AUDIO_INTERVAL_MS, out, &length, &key, &wait) == DS5_OUTC_WRITE);
    CHECK(out[2] == 2);
    CHECK(c.audioInflight == 2);
    ds5_outc_complete(&c, DS5_OUTC_AUDIO_INTERVAL_MS + 1.0, true);
    CHECK(c.audioInflight == 1);
    CHECK(ds5_outc_next(&c, DS5_OUTC_AUDIO_INTERVAL_MS * 2.0, out, &length, &key, &wait) == DS5_OUTC_WRITE);
    CHECK(out[2] == 3);
}

static void test_haptics_latest_wins_without_delaying_audio(void) {
    DS5OutputCoalescer c;
    init(&c);
    uint8_t audio[547], haptic[LEN], out[DS5_OUTC_CAPACITY];
    size_t length = 0;
    uint64_t key = 0;
    double wait = 0.0;
    make_audio(audio, 1);
    make_audio(audio, 1);
    audio[2] = 1;
    CHECK(ds5_outc_submit(&c, 1, true, audio, 547));
    audio[2] = 2;
    CHECK(ds5_outc_submit(&c, 1, true, audio, 547));
    make_report(haptic, 0x03, 0, 0x04, 10, 10);
    CHECK(ds5_outc_submit(&c, 1, true, haptic, LEN));
    make_report(haptic, 0x03, 0, 0x04, 90, 90);
    CHECK(ds5_outc_submit(&c, 1, true, haptic, LEN));
    CHECK(c.stats.merged == 1);
    CHECK(ds5_outc_next(&c, 0.0, out, &length, &key, &wait) == DS5_OUTC_WRITE);
    CHECK(out[0] == 0x39 && out[2] == 1);
    // Audio is not due yet and the channel is busy with that report, so the haptic waits.
    CHECK(ds5_outc_next(&c, 1.0, out, &length, &key, &wait) == DS5_OUTC_WAIT);
    ds5_outc_complete(&c, 2.0, true);
    // Channel idle, audio still not due: the latest haptic goes out, not the stale one.
    CHECK(ds5_outc_next(&c, 2.0, out, &length, &key, &wait) == DS5_OUTC_WRITE);
    CHECK(length == LEN && out[4] == 90);
    ds5_outc_complete(&c, 3.0, true);
    CHECK(ds5_outc_next(&c, DS5_OUTC_AUDIO_INTERVAL_MS, out, &length, &key, &wait) == DS5_OUTC_WRITE);
    CHECK(out[0] == 0x39 && out[2] == 2);
}

static void test_slow_writer_does_not_delay_input(void) {
    Harness h;
    memset(&h, 0, sizeof(h));
    pthread_mutex_init(&h.coalescerLock, NULL);
    pthread_mutex_init(&h.queueLock, NULL);
    ds5_outc_init(&h.c);
    h.shared = legacy;
    h.writeMs = 200.0;
    pthread_t thread;
    pthread_create(&thread, NULL, writer_thread, &h);
    double worst = 0.0;
    uint8_t report[LEN];
    for (int i = 0; i < 400; i++) {  // 400 input callbacks, one per ms, each also submits feedback
        const double start = now_ms();
        if (h.shared) pthread_mutex_lock(&h.queueLock);  // the input callback runs on the writer's queue
        make_report(report, 0x03, 0, 0x04, (uint8_t)i, (uint8_t)i);
        pthread_mutex_lock(&h.coalescerLock);
        ds5_outc_submit(&h.c, 1, true, report, LEN);
        pthread_mutex_unlock(&h.coalescerLock);
        if (h.shared) pthread_mutex_unlock(&h.queueLock);
        const double took = now_ms() - start;
        if (took > worst) worst = took;
        sleep_ms(1.0);
    }
    h.stop = 1;
    pthread_join(thread, NULL);
    fprintf(stderr, "slowest input callback while a write blocked for %.0f ms: %.1f ms\n", h.writeMs, worst);
    CHECK(worst < 20.0);
}

static void test_haptics_only_report_uses_the_short_period(void) {
    DS5OutputCoalescer c;
    init(&c);
    uint8_t report[142], audio[547], out[DS5_OUTC_CAPACITY];
    size_t length = 0;
    uint64_t key = 0;
    double wait = 0.0;
    memset(report, 0, sizeof(report));
    report[0] = 0x32;
    report[13] = 1;
    CHECK(ds5_outc_submit(&c, 1, true, report, 142));
    report[13] = 2;
    CHECK(ds5_outc_submit(&c, 1, true, report, 142));
    CHECK(c.audioCount == 1);
    CHECK(c.stats.dropped == 1);
    // The older report is gone. Only the newest is written, and nothing else starts.
    CHECK(ds5_outc_next(&c, 0.0, out, &length, &key, &wait) == DS5_OUTC_WRITE);
    CHECK(out[0] == 0x32 && out[13] == 2 && length == 142);
    CHECK(c.audioInflight == 1);
    CHECK(ds5_outc_next(&c, 0.0, out, &length, &key, &wait) == DS5_OUTC_WAIT);
    CHECK(wait == 0.0);
    CHECK(ds5_outc_next(&c, DS5_OUTC_HAPTICS_INTERVAL_MS, out, &length, &key, &wait) == DS5_OUTC_WAIT);
    CHECK(c.audioInflight == 1);
    ds5_outc_complete(&c, DS5_OUTC_HAPTICS_INTERVAL_MS, true);
    CHECK(c.audioInflight == 0);
    CHECK(ds5_outc_next(&c, DS5_OUTC_HAPTICS_INTERVAL_MS, out, &length, &key, &wait) == DS5_OUTC_IDLE);

    // A completion that arrives after the period sends the newest report only.
    report[13] = 3;
    CHECK(ds5_outc_submit(&c, 1, true, report, 142));
    CHECK(ds5_outc_next(&c, DS5_OUTC_HAPTICS_INTERVAL_MS, out, &length, &key, &wait) == DS5_OUTC_WRITE);
    CHECK(out[13] == 3);
    report[13] = 4;
    CHECK(ds5_outc_submit(&c, 1, true, report, 142));
    report[13] = 5;
    CHECK(ds5_outc_submit(&c, 1, true, report, 142));
    CHECK(c.audioCount == 1);
    CHECK(ds5_outc_next(&c, DS5_OUTC_HAPTICS_INTERVAL_MS + 80.0, out, &length, &key, &wait) == DS5_OUTC_WAIT);
    ds5_outc_complete(&c, DS5_OUTC_HAPTICS_INTERVAL_MS + 80.0, true);
    CHECK(ds5_outc_next(&c, DS5_OUTC_HAPTICS_INTERVAL_MS + 80.0, out, &length, &key, &wait) == DS5_OUTC_WRITE);
    CHECK(out[0] == 0x32 && out[13] == 5);
    CHECK(c.audioInflight == 1);
    ds5_outc_complete(&c, DS5_OUTC_HAPTICS_INTERVAL_MS + 81.0, true);

    // A fast completion still waits out the 10.667 ms period.
    report[13] = 6;
    CHECK(ds5_outc_submit(&c, 1, true, report, 142));
    CHECK(ds5_outc_next(&c, 200.0, out, &length, &key, &wait) == DS5_OUTC_WRITE);
    ds5_outc_complete(&c, 200.5, true);
    report[13] = 7;
    CHECK(ds5_outc_submit(&c, 1, true, report, 142));
    CHECK(ds5_outc_next(&c, 201.0, out, &length, &key, &wait) == DS5_OUTC_WAIT);
    CHECK(wait > 9.0 && wait < 10.8);
    CHECK(ds5_outc_next(&c, 200.0 + DS5_OUTC_HAPTICS_INTERVAL_MS, out, &length, &key, &wait) == DS5_OUTC_WRITE);
    CHECK(out[13] == 7);
    ds5_outc_complete(&c, 200.0 + DS5_OUTC_HAPTICS_INTERVAL_MS + 0.5, true);

    report[13] = 8;
    CHECK(ds5_outc_submit(&c, 1, true, report, 142));
    make_audio(audio, 9);
    CHECK(ds5_outc_submit(&c, 1, true, audio, 547));
    CHECK(c.audioLength == 547);
    CHECK(c.stats.dropped >= 1);
    CHECK(ds5_outc_next(&c, 400.0, out, &length, &key, &wait) == DS5_OUTC_WRITE);
    CHECK(out[0] == 0x39 && out[2] == 9);
}

int main(void) {
    const char *mode = getenv("DS5_TEST_LEGACY");
    legacy = mode != NULL && mode[0] == '1';
    test_burst_is_capped_and_final_state_written();
    test_never_more_than_one_pending();
    test_identical_report_dropped_on_bluetooth_only();
    test_zero_state_is_not_dropped_by_pacing();
    test_merge_keeps_union_of_flags_and_newest_values();
    test_failed_write_is_retried();
    test_audio_stays_ordered_on_the_frame_clock();
    test_haptics_latest_wins_without_delaying_audio();
    test_haptics_only_report_uses_the_short_period();
    test_slow_writer_does_not_delay_input();
    if (failures != 0) {
        fprintf(stderr, "%d check(s) failed\n", failures);
        return 1;
    }
    puts("ds5 output queue test: ok");
    return 0;
}
