//
//  CoreHIDSilence.h
//  Moonlight for macOS
//
//  Decides when the CoreHID mouse is silent: AppKit reports pointer motion while CoreHID, which the hybrid free
//  mouse relies on for its raw motion, has not delivered any. Plain C so tests/corehid-silence can run it without
//  AppKit.
//
//  The hybrid free mouse moves a virtual cursor with the raw CoreHID motion and corrects it against the system
//  pointer. With no CoreHID motion the virtual cursor stands still, every AppKit event is "far" from it, and the
//  app sent a relative move plus an absolute correction for each one; the host pulled the cursor back and forth.
//  CoreHID delivers nothing, without any error, when Input Monitoring is not allowed for this build (the shipped
//  builds are ad-hoc signed, so the permission belongs to one build), when no device it carries is in use (a
//  built-in trackpad is not carried), or when no device matched.
//  (Sources: macos-apple-corehid-20261116, macos-apple-nsevent-mousemoved-20261116,
//  macos-apple-tn3127-requirements-20261119.)
//

#ifndef CoreHIDSilence_h
#define CoreHIDSilence_h

#include <stdbool.h>
#include <stdint.h>
#include <string.h>

enum {
    // The AppKit motion has to go on this long with no CoreHID motion before CoreHID counts as silent. CoreHID
    // reports a move within a few ms of AppKit seeing it, so a working CoreHID never gets near this.
    MLCoreHIDSilenceGraceMs = 250,
    // ...and be at least this many events, so a single stray event never decides.
    MLCoreHIDSilenceMinAppKitMoves = 8,
    // A pause longer than this ends a burst of motion; the next move starts a new one.
    MLCoreHIDSilenceBurstGapMs = 400,
};

typedef struct {
    // CoreHID has delivered motion since the driver started.
    bool delivered;
    // The verdict: CoreHID is not carrying the motion that AppKit sees.
    bool silent;
    uint32_t burstMoves;
    uint64_t burstStartMs;
    uint64_t lastMoveMs;
} MLCoreHIDSilence;

static inline void MLCoreHIDSilenceReset(MLCoreHIDSilence *state) {
    memset(state, 0, sizeof(*state));
}

// CoreHID delivered motion: it works, whatever was decided before.
static inline void MLCoreHIDSilenceNoteDelivery(MLCoreHIDSilence *state) {
    state->delivered = true;
    state->silent = false;
    state->burstMoves = 0;
}

// One AppKit pointer move that CoreHID did not carry (the caller has already left out the moves that follow a recent
// CoreHID delivery). Returns true exactly once, for the move that turns the verdict to silent.
static inline bool MLCoreHIDSilenceNoteAppKitMove(MLCoreHIDSilence *state, uint64_t nowMs) {
    if (state->delivered || state->silent) {
        return false;
    }

    if (state->burstMoves == 0 || nowMs < state->lastMoveMs ||
        nowMs - state->lastMoveMs > MLCoreHIDSilenceBurstGapMs) {
        state->burstStartMs = nowMs;
        state->burstMoves = 0;
    }
    state->lastMoveMs = nowMs;
    state->burstMoves += 1;

    if (state->burstMoves >= MLCoreHIDSilenceMinAppKitMoves &&
        nowMs - state->burstStartMs >= MLCoreHIDSilenceGraceMs) {
        state->silent = true;
        return true;
    }
    return false;
}

typedef struct {
    // Send this event's pointer position to the host, as the only thing sent for it: no relative move, and the
    // virtual cursor is not corrected for it (that would be a second absolute send).
    bool sendAbsolute;
    // This event turned the verdict to silent: CoreHID is no longer used for the free mouse.
    bool markSilent;
} MLCoreHIDAppKitMoveAction;

// What to do with one AppKit pointer move while the hybrid free mouse is active. `coreHIDRecent`: CoreHID has
// delivered motion within the last quarter second, so this move is a second copy of motion CoreHID already carries.
// Otherwise AppKit is the only source for it, and the one thing to send is its position.
static inline MLCoreHIDAppKitMoveAction MLCoreHIDDecideAppKitMove(MLCoreHIDSilence *state,
                                                                  bool coreHIDRecent,
                                                                  uint64_t nowMs) {
    MLCoreHIDAppKitMoveAction action = {false, false};
    if (coreHIDRecent) {
        return action;
    }
    action.sendAbsolute = true;
    action.markSilent = MLCoreHIDSilenceNoteAppKitMove(state, nowMs);
    return action;
}

#endif /* CoreHIDSilence_h */
