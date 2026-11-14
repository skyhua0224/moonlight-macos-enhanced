#pragma once

// Plays host rumble as pulses. Header-only C with an explicit clock so tests/ds5-rumble-pulse runs it with a
// plain C compiler; the caller owns the lock and the timer.
//
// A host that rumbles for a few milliseconds (a menu tick, a footstep) sends a value and, soon after, zero. Played
// as "newest value wins" the two often arrive together and the pulse vanishes. Here a start is applied at once and
// held for at least `minPulseMs`; a stop that arrives earlier is deferred to the end of that hold; a start that
// arrives inside the hold keeps the louder value of each motor (the peak) and a stop that follows is deferred too.
// Nothing here waits: an event returns what to apply now and ds5_rs_next_due tells when to call ds5_rs_tick.

#include <stdbool.h>
#include <stdint.h>
#include <string.h>

// Long enough for a CoreHaptics transient and for one Bluetooth write, short enough that 20 pulses a second stay apart.
#define DS5_RS_MIN_PULSE_MS 16.0

typedef struct DS5RumbleStats {
  unsigned received;  // host rumble values handed to the scheduler
  unsigned applied;   // values applied to the pad
  unsigned pulses;    // starts applied
  unsigned deferred;  // stops held back to the end of a pulse
  unsigned merged;    // values folded into a running pulse (peak) or into a pending stop
  double shortestPulseMs;  // shortest host pulse seen (start to its stop), 0 when none
  double longestPulseMs;
} DS5RumbleStats;

typedef struct DS5RumbleScheduler {
  uint16_t low, high;          // what is applied now
  uint16_t wantLow, wantHigh;  // the newest value the host asked for
  bool running;                // low or high nonzero is applied
  double holdUntilMs;          // a started pulse is not stopped before this
  double hostStartMs;          // when the host's current pulse started (for the statistics)
  bool hostRunning;
  double minPulseMs;
  DS5RumbleStats stats;
} DS5RumbleScheduler;

typedef struct DS5RumbleAction {
  bool apply;
  uint16_t low, high;
} DS5RumbleAction;

static inline void ds5_rs_init(DS5RumbleScheduler *s) {
  memset(s, 0, sizeof(*s));
  s->minPulseMs = DS5_RS_MIN_PULSE_MS;
}

static inline DS5RumbleAction ds5_rs_apply(DS5RumbleScheduler *s, uint16_t low, uint16_t high) {
  DS5RumbleAction action = { false, 0, 0 };
  if (s->low == low && s->high == high) return action;
  s->low = low;
  s->high = high;
  s->running = (low | high) != 0u;
  s->stats.applied++;
  action.apply = true;
  action.low = low;
  action.high = high;
  return action;
}

// A host value arrives at `nowMs`.
static inline DS5RumbleAction ds5_rs_event(DS5RumbleScheduler *s, double nowMs, uint16_t low, uint16_t high) {
  DS5RumbleAction none = { false, 0, 0 };
  s->stats.received++;
  const bool nonzero = (low | high) != 0u;
  if (nonzero && !s->hostRunning) {
    s->hostRunning = true;
    s->hostStartMs = nowMs;
  } else if (!nonzero && s->hostRunning) {
    const double length = nowMs - s->hostStartMs;
    s->hostRunning = false;
    if (s->stats.shortestPulseMs == 0.0 || length < s->stats.shortestPulseMs) s->stats.shortestPulseMs = length;
    if (length > s->stats.longestPulseMs) s->stats.longestPulseMs = length;
  }
  s->wantLow = low;
  s->wantHigh = high;
  if (nonzero) {
    if (!s->running) {
      s->holdUntilMs = nowMs + s->minPulseMs;
      s->stats.pulses++;
      return ds5_rs_apply(s, low, high);
    }
    if (nowMs < s->holdUntilMs) {
      // Inside a hold: the louder value of each motor plays until the hold ends.
      const uint16_t peakLow = low > s->low ? low : s->low;
      const uint16_t peakHigh = high > s->high ? high : s->high;
      s->stats.merged++;
      return ds5_rs_apply(s, peakLow, peakHigh);
    }
    return ds5_rs_apply(s, low, high);
  }
  // A stop.
  if (s->running && nowMs < s->holdUntilMs) {
    s->stats.deferred++;
    return none;
  }
  return ds5_rs_apply(s, 0, 0);
}

// When ds5_rs_tick must be called next, in ms on the same clock, or a negative number when nothing is due.
static inline double ds5_rs_next_due(const DS5RumbleScheduler *s) {
  if (s->running && (s->low != s->wantLow || s->high != s->wantHigh)) return s->holdUntilMs;
  return -1.0;
}

// The hold of a pulse ended: play what the host wants now (a stop, or the newest value after a peak).
static inline DS5RumbleAction ds5_rs_tick(DS5RumbleScheduler *s, double nowMs) {
  DS5RumbleAction none = { false, 0, 0 };
  if (!s->running || nowMs < s->holdUntilMs) return none;
  if (s->low == s->wantLow && s->high == s->wantHigh) return none;
  return ds5_rs_apply(s, s->wantLow, s->wantHigh);
}

// The pad went away or the stream ended: forget the pulse (the caller writes the stop).
static inline void ds5_rs_reset(DS5RumbleScheduler *s) {
  const DS5RumbleStats stats = s->stats;
  ds5_rs_init(s);
  s->stats = stats;
}

static inline DS5RumbleStats ds5_rs_take_stats(DS5RumbleScheduler *s) {
  const DS5RumbleStats stats = s->stats;
  memset(&s->stats, 0, sizeof(s->stats));
  return stats;
}
