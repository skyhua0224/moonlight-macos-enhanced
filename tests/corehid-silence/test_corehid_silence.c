// Tests when the CoreHID mouse counts as silent (CoreHIDSilence.h) and what is sent for each AppKit pointer move.
// Replays the cases of issue 87: CoreHID delivered no motion at all (Input Monitoring not allowed for this build), so
// the hybrid free mouse sent a relative move and an absolute correction for every AppKit event and the host cursor
// was pulled back and forth. No hardware, no host.
#include <math.h>
#include <stdio.h>

#include "CoreHIDSilence.h"
#include "FreeMouseVirtualCursor.h"

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
    unsigned moves;
    unsigned absoluteSends;
    unsigned relativeSends; // the app no longer sends a relative move for a hybrid AppKit event: always 0
    unsigned skipped;
    unsigned verdicts;
    uint64_t verdictAtMs;
} Tally;

// What HIDSupport does with one AppKit move: the decision, then what it sends.
static void appKitMove(MLCoreHIDSilence *state, Tally *tally, uint64_t nowMs, bool coreHIDRecent) {
    tally->moves++;
    MLCoreHIDAppKitMoveAction action = MLCoreHIDDecideAppKitMove(state, coreHIDRecent, nowMs);
    if (action.markSilent) {
        tally->verdicts++;
        tally->verdictAtMs = nowMs;
    }
    if (action.sendAbsolute) {
        tally->absoluteSends++;
    } else {
        tally->skipped++;
    }
}

static void testSilentCoreHID(void) {
    // 1 kHz AppKit motion for two seconds, CoreHID delivers nothing.
    MLCoreHIDSilence state;
    MLCoreHIDSilenceReset(&state);
    Tally tally = {0};
    for (uint64_t t = 1000; t < 3000; t++) {
        appKitMove(&state, &tally, t, false);
    }
    CHECK(tally.verdicts == 1, "one verdict, got %u", tally.verdicts);
    CHECK(state.silent, "silent");
    CHECK(tally.verdictAtMs >= 1000 + MLCoreHIDSilenceGraceMs && tally.verdictAtMs <= 1000 + MLCoreHIDSilenceGraceMs + 2,
          "verdict after the grace period, at %llu", (unsigned long long)tally.verdictAtMs);
    CHECK(tally.absoluteSends == tally.moves, "exactly one send per event: %u sends for %u events",
          tally.absoluteSends, tally.moves);
    CHECK(tally.relativeSends == 0, "never a relative move");
}

static void testSilentCoreHIDAtTrackpadRate(void) {
    // 125 Hz motion (8 ms apart): the verdict still comes, after the grace period.
    MLCoreHIDSilence state;
    MLCoreHIDSilenceReset(&state);
    Tally tally = {0};
    for (uint64_t t = 0; t < 2000; t += 8) {
        appKitMove(&state, &tally, t, false);
    }
    CHECK(tally.verdicts == 1, "verdict at 125 Hz, got %u", tally.verdicts);
    CHECK(tally.verdictAtMs >= MLCoreHIDSilenceGraceMs && tally.verdictAtMs < MLCoreHIDSilenceGraceMs + 16,
          "verdict time %llu", (unsigned long long)tally.verdictAtMs);
}

static void testHealthyCoreHID(void) {
    // CoreHID motion every ms, the AppKit copy of each a few ms later: every AppKit move follows a recent CoreHID
    // delivery, so nothing is sent for it and no verdict is made.
    MLCoreHIDSilence state;
    MLCoreHIDSilenceReset(&state);
    Tally tally = {0};
    for (uint64_t t = 1000; t < 6000; t++) {
        MLCoreHIDSilenceNoteDelivery(&state);
        appKitMove(&state, &tally, t + 3, true);
    }
    CHECK(tally.verdicts == 0, "no verdict");
    CHECK(!state.silent, "not silent");
    CHECK(tally.absoluteSends == 0 && tally.relativeSends == 0, "nothing sent for the AppKit copy of CoreHID motion");
    CHECK(tally.skipped == tally.moves, "all skipped");
}

static void testCoreHIDStopsAfterWorking(void) {
    // CoreHID worked for a second, then the user moved a pointer it does not carry (a trackpad). The verdict stays
    // "not silent" (CoreHID did deliver), but each AppKit move is sent once, as a position.
    MLCoreHIDSilence state;
    MLCoreHIDSilenceReset(&state);
    Tally tally = {0};
    for (uint64_t t = 0; t < 1000; t++) {
        MLCoreHIDSilenceNoteDelivery(&state);
        appKitMove(&state, &tally, t + 2, true);
    }
    Tally trackpad = {0};
    for (uint64_t t = 2000; t < 3000; t += 8) {
        appKitMove(&state, &trackpad, t, false);
    }
    CHECK(trackpad.verdicts == 0, "CoreHID did deliver once: no verdict");
    CHECK(trackpad.absoluteSends == trackpad.moves, "each trackpad move sent once as a position");
    CHECK(trackpad.relativeSends == 0, "never relative");
}

static void testStrayEventsNeverDecide(void) {
    // A few single moves seconds apart (the pointer nudged by something else) are not a verdict.
    MLCoreHIDSilence state;
    MLCoreHIDSilenceReset(&state);
    Tally tally = {0};
    for (uint64_t t = 0; t < 60000; t += 3000) {
        appKitMove(&state, &tally, t, false);
    }
    CHECK(tally.verdicts == 0, "isolated moves make no verdict");
    // A short burst under the grace period is not either.
    for (uint64_t t = 70000; t < 70000 + MLCoreHIDSilenceGraceMs - 10; t += 10) {
        appKitMove(&state, &tally, t, false);
    }
    CHECK(tally.verdicts == 0, "a burst shorter than the grace period makes no verdict");
}

static void testPauseRestartsBurst(void) {
    // Two bursts separated by a pause: the grace period is counted inside one burst, not across the pause.
    MLCoreHIDSilence state;
    MLCoreHIDSilenceReset(&state);
    Tally tally = {0};
    for (uint64_t t = 0; t < 200; t += 10) { // 200 ms burst
        appKitMove(&state, &tally, t, false);
    }
    for (uint64_t t = 5000; t < 5200; t += 10) { // another 200 ms burst after a pause
        appKitMove(&state, &tally, t, false);
    }
    CHECK(tally.verdicts == 0, "two 200 ms bursts are not one 400 ms burst");
}

static void testDeliveryClearsVerdict(void) {
    MLCoreHIDSilence state;
    MLCoreHIDSilenceReset(&state);
    Tally tally = {0};
    for (uint64_t t = 0; t < 500; t++) {
        appKitMove(&state, &tally, t, false);
    }
    CHECK(state.silent, "silent first");
    // The user allows Input Monitoring, comes back, CoreHID delivers: it is in use again.
    MLCoreHIDSilenceNoteDelivery(&state);
    CHECK(!state.silent && state.delivered, "delivery clears the verdict");
    Tally after = {0};
    for (uint64_t t = 1000; t < 1500; t++) {
        MLCoreHIDSilenceNoteDelivery(&state);
        appKitMove(&state, &after, t + 3, true);
    }
    CHECK(after.verdicts == 0 && after.absoluteSends == 0, "healthy again");
}

static void testClockGoingBackwardsIsSafe(void) {
    MLCoreHIDSilence state;
    MLCoreHIDSilenceReset(&state);
    Tally tally = {0};
    appKitMove(&state, &tally, 10000, false);
    appKitMove(&state, &tally, 5000, false); // the clock stepped back
    CHECK(tally.verdicts == 0, "no verdict from a clock step");
}

// The log of issue 87: 2.9 s of circular mouse motion, 1473 AppKit events, no CoreHID motion at all. Before the fix
// each event was sent as a relative move and, since the virtual cursor never moved, also as a position correction
// (the log counted rel=1443 abs=1436 corrections=1432). After it: one position per event, none of the other two.
static void testIssue87Replay(void) {
    const double width = 1920.0, height = 1080.0, threshold = 1.5; // the app's correction threshold
    const int events = 1473;
    const double stepMs = 2000.0 / events * 1.45; // about 2.9 s

    // Before: every AppKit event is sent relative, then the virtual cursor is reconciled against the pointer.
    MLFreeMouseVirtualCursor cursor;
    MLFreeMouseVirtualCursorReset(&cursor);
    unsigned oldRelative = 0, oldCorrections = 0;
    // After: the decision above.
    MLCoreHIDSilence state;
    MLCoreHIDSilenceReset(&state);
    Tally fixedTally = {0};

    for (int i = 0; i < events; i++) {
        double angle = i * 0.012;
        MLFreeMousePoint pointer = {960.0 + 420.0 * cos(angle), 540.0 + 300.0 * sin(angle)};
        // before
        oldRelative++;
        double drift = 0.0;
        if (MLFreeMouseVirtualCursorReconcile(&cursor, pointer, width, height, true, threshold, &drift)) {
            oldCorrections++;
        }
        // after
        appKitMove(&state, &fixedTally, 5000 + (uint64_t)(i * stepMs), false);
    }

    CHECK(oldCorrections >= (unsigned)(events * 0.9),
          "the old path corrects almost every event, as in the log: %u of %d", oldCorrections, events);
    CHECK(oldRelative + oldCorrections > (unsigned)(events * 1.9),
          "the old path sends about two things per event: %u for %d events", oldRelative + oldCorrections, events);
    CHECK(fixedTally.absoluteSends == (unsigned)events,
          "the fixed path sends one position per event: %u", fixedTally.absoluteSends);
    CHECK(fixedTally.relativeSends == 0, "the fixed path sends no relative move");
    CHECK(fixedTally.verdicts == 1, "and CoreHID is taken as unavailable once");
    printf("issue 87 replay: before %u relative + %u corrections for %d events; after %u positions\n",
           oldRelative, oldCorrections, events, fixedTally.absoluteSends);
}

int main(void) {
    testIssue87Replay();
    testSilentCoreHID();
    testSilentCoreHIDAtTrackpadRate();
    testHealthyCoreHID();
    testCoreHIDStopsAfterWorking();
    testStrayEventsNeverDecide();
    testPauseRestartsBurst();
    testDeliveryClearsVerdict();
    testClockGoingBackwardsIsSafe();
    if (failures != 0) {
        printf("%d check(s) failed\n", failures);
        return 1;
    }
    printf("corehid-silence: all checks passed\n");
    return 0;
}
