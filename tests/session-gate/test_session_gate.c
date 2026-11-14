// Lifecycle test for the connection session handle (Limelight/Stream/MLSessionGate.h).
//
// Models a crash: the stream health timer called the
// process-wide LiRequestIdrFrame(), which resolved the main thread's bound context.
// An input event had bound it to the previous session; that Connection was freed on
// reconnect, so LbqFlushQueueItems() locked a freed mutex.
//
// The queue is the library's own LinkedBlockingQueue.c; the fake connection embeds its
// context the way Connection embeds ML_CONNECTION_CONTEXT. Build with AddressSanitizer
// (run.sh does). SESSION_GATE_TEST_LEGACY=1 runs the timer the old way (thread-bound
// context, no gate); it is expected to fail.

#include "LinkedBlockingQueue.h"
#include "MLSessionGate.h"

#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// Platform shims: LinkedBlockingQueue.c needs only these, with Platform.c's POSIX behaviour.
int PltCreateMutex(PLT_MUTEX *mutex) { return pthread_mutex_init(mutex, NULL); }
void PltDeleteMutex(PLT_MUTEX *mutex) { pthread_mutex_destroy(mutex); }
void PltLockMutex(PLT_MUTEX *mutex) { pthread_mutex_lock(mutex); }
void PltUnlockMutex(PLT_MUTEX *mutex) { pthread_mutex_unlock(mutex); }
int PltCreateConditionVariable(PLT_COND *cond, PLT_MUTEX *mutex) { (void)mutex; return pthread_cond_init(cond, NULL); }
void PltDeleteConditionVariable(PLT_COND *cond) { pthread_cond_destroy(cond); }
void PltSignalConditionVariable(PLT_COND *cond) { pthread_cond_signal(cond); }
void PltWaitForConditionVariable(PLT_COND *cond, PLT_MUTEX *mutex) { pthread_cond_wait(cond, mutex); }

typedef struct {
    LINKED_BLOCKING_QUEUE invalidReferenceFrameTuples;
    atomic_bool destroyed;
    atomic_int idrRequests;
} FakeControlContext;

typedef struct {
    MLSessionGate gate;
    FakeControlContext ctx;
} FakeConnection;

static int failures;
static int legacy;

#define CHECK(cond, ...) do { if (!(cond)) { failures++; fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); } } while (0)

// LiRequestIdrFrameCtx(): flush the RFI queue, then flag the IDR.
static void requestIdrFrameCtx(FakeControlContext *ctx) {
    PLINKED_BLOCKING_QUEUE_ENTRY entry = LbqFlushQueueItems(&ctx->invalidReferenceFrameTuples);
    (void)entry;
    if (atomic_load(&ctx->destroyed)) {
        failures++;
        fprintf(stderr, "FAIL: IDR request ran on a stopped control stream\n");
    }
    atomic_fetch_add(&ctx->idrRequests, 1);
}

// Process-wide entry point: thread binding, else the unused global context.
static FakeControlContext gGlobalCtx;
static __thread FakeControlContext *tBoundCtx;
static void legacyRequestIdrFrame(void) { requestIdrFrameCtx(tBoundCtx != NULL ? tBoundCtx : &gGlobalCtx); }

// -[Connection requestIdrFrame]
static int connectionRequestIdrFrame(FakeConnection *conn) {
    if (conn == NULL || !MLSessionGateEnter(&conn->gate)) {
        return 0;
    }
    requestIdrFrameCtx(&conn->ctx);
    MLSessionGateLeave(&conn->gate);
    return 1;
}

static FakeConnection *connectionCreateAndStart(void) {
    FakeConnection *conn = calloc(1, sizeof(*conn));
    MLSessionGateInit(&conn->gate);
    LbqInitializeLinkedBlockingQueue(&conn->ctx.invalidReferenceFrameTuples, 20);
    MLSessionGateOpen(&conn->gate);
    return conn;
}

// -terminate then LiStopConnectionCtx(): retire, then destroy the control stream.
static void connectionTerminateAndStop(FakeConnection *conn) {
    if (!legacy) {
        MLSessionGateRetire(&conn->gate);
        // ConnectionForgetMainThreadContext(), on the main thread.
        if (tBoundCtx == &conn->ctx) {
            tBoundCtx = NULL;
        }
    }
    atomic_store(&conn->ctx.destroyed, true);
    LbqDestroyLinkedBlockingQueue(&conn->ctx.invalidReferenceFrameTuples);
}

static void timerFire(FakeConnection *current) {
    if (legacy) {
        legacyRequestIdrFrame();
    } else {
        connectionRequestIdrFrame(current);
    }
}

// The crash: main-thread input binds session A, a reconnect frees A, the timer fires on B.
static void testReconnectThenTimer(void) {
    FakeConnection *a = connectionCreateAndStart();
    tBoundCtx = &a->ctx;  // HIDInputContext() on the main thread
    connectionTerminateAndStop(a);
    free(a);              // StreamManager released the old Connection

    FakeConnection *b = connectionCreateAndStart();
    timerFire(b);         // payload stall, streak >= 2
    CHECK(atomic_load(&b->ctx.idrRequests) == 1, "IDR after reconnect reached the new session %d times, expected 1",
          atomic_load(&b->ctx.idrRequests));
    CHECK(tBoundCtx == NULL, "main thread still bound to the stopped session");
    connectionTerminateAndStop(b);
    free(b);
}

typedef struct {
    FakeConnection *conn;
    atomic_bool stop;
    atomic_int fired;
} TimerArgs;

static void *timerThread(void *arg) {
    TimerArgs *args = arg;
    if (legacy) {
        tBoundCtx = &args->conn->ctx;
    }
    while (!atomic_load(&args->stop)) {
        timerFire(args->conn);
        atomic_fetch_add(&args->fired, 1);
    }
    return NULL;
}

// Stop while the timer is pending: no request may be inside or start after -terminate.
static void testStopWhileTimerPending(void) {
    for (int round = 0; round < 200; round++) {
        FakeConnection *conn = connectionCreateAndStart();
        TimerArgs args = { .conn = conn };
        pthread_t thread;
        pthread_create(&thread, NULL, timerThread, &args);
        while (atomic_load(&args.fired) < 1 + round % 7) {
            sched_yield();
        }
        connectionTerminateAndStop(conn);
        int before = atomic_load(&conn->ctx.idrRequests);
        usleep(200);
        int after = atomic_load(&conn->ctx.idrRequests);
        atomic_store(&args.stop, true);
        pthread_join(thread, NULL);
        CHECK(before == after, "round %d: %d IDR requests after the session stopped", round, after - before);
        free(conn);
        if (failures > 0) {
            return;
        }
    }
}

static void testRetireBeforeStartKeepsClosed(void) {
    MLSessionGate gate;
    MLSessionGateInit(&gate);
    CHECK(!MLSessionGateEnter(&gate), "gate admits calls before the session started");
    MLSessionGateRetire(&gate);
    CHECK(!MLSessionGateOpen(&gate), "a retired gate opened when the start finished");
    CHECK(!MLSessionGateEnter(&gate), "a retired gate admits calls");
    CHECK(connectionRequestIdrFrame(NULL) == 0, "no connection must report not sent");
}

int main(void) {
    const char *env = getenv("SESSION_GATE_TEST_LEGACY");
    legacy = env != NULL && strcmp(env, "1") == 0;
    LbqInitializeLinkedBlockingQueue(&gGlobalCtx.invalidReferenceFrameTuples, 20);

    if (!legacy) {
        testRetireBeforeStartKeepsClosed();
    }
    testReconnectThenTimer();
    testStopWhileTimerPending();

    if (failures > 0) {
        fprintf(stderr, "session gate tests: %d failure(s)%s\n", failures, legacy ? " (legacy behaviour, expected)" : "");
        return 1;
    }
    printf("session gate tests passed\n");
    return 0;
}
