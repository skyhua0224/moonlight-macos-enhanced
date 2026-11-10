//
//  MLSessionGate.h
//  Moonlight
//
//  Admits calls into a connection context only while the session is live.
//
//  A Connection opens its gate once LiStartConnectionCtx() has succeeded and
//  retires it before LiStopConnectionCtx() destroys the control stream's
//  mutexes, events and ENet peer. Callers on other threads (the stream health
//  timer, the overlay, adaptive bitrate) enter the gate, call the *Ctx function
//  and leave. Retiring takes the same lock, so it waits for a call in progress
//  and no call starts afterwards. A retired gate never opens again.
//
//  Only short, non-blocking calls belong inside the gate: the lock is an
//  os_unfair_lock and a caller may be the main thread.
//

#ifndef MLSessionGate_h
#define MLSessionGate_h

#include <os/lock.h>
#include <stdbool.h>

typedef struct {
    os_unfair_lock lock;
    bool open;
    bool retired;
} MLSessionGate;

static inline void MLSessionGateInit(MLSessionGate *gate) {
    gate->lock = OS_UNFAIR_LOCK_INIT;
    gate->open = false;
    gate->retired = false;
}

// Returns false when the gate was already retired (the session stopped while starting).
static inline bool MLSessionGateOpen(MLSessionGate *gate) {
    os_unfair_lock_lock(&gate->lock);
    bool opened = !gate->retired;
    gate->open = opened;
    os_unfair_lock_unlock(&gate->lock);
    return opened;
}

// After this returns no call is inside the gate and none will enter.
static inline void MLSessionGateRetire(MLSessionGate *gate) {
    os_unfair_lock_lock(&gate->lock);
    gate->open = false;
    gate->retired = true;
    os_unfair_lock_unlock(&gate->lock);
}

// On true the caller holds the gate and must call MLSessionGateLeave() on the same thread.
static inline bool MLSessionGateEnter(MLSessionGate *gate) {
    os_unfair_lock_lock(&gate->lock);
    if (gate->open) {
        return true;
    }
    os_unfair_lock_unlock(&gate->lock);
    return false;
}

static inline void MLSessionGateLeave(MLSessionGate *gate) {
    os_unfair_lock_unlock(&gate->lock);
}

#endif /* MLSessionGate_h */
