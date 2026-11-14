#pragma once

// Delivery of analysed haptics frames (IR v2) to the pad actuators with no tick lost.
//
// The host sends one frame per 5 ms. The control thread pushes each frame here; the main queue drains the queue
// whenever it runs, which is not every 5 ms: a main queue busy for 10 ms used to find only the newest frame, and a
// tick (one or two frames with energy between silent frames) was replaced by silence before it was ever played.
// Here every frame is kept in order, a drain applies the strongest frame of the batch when it is stronger than the
// newest one, and a nonzero value is held for at least DS5_IRP_MIN_HOLD seconds before a quieter one replaces it
// (the same rule as the rumble scheduler), so a tick is played once, whole, however the drains fall.
// Header-only C so that tests/ds5-ir-playback builds it without Apple frameworks.

#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#define DS5_IRP_QUEUE 64
#define DS5_IRP_ENERGY_FLOOR 0.02f
#define DS5_IRP_MIN_HOLD 0.020

typedef struct DS5IrFrame {
  float rms[2], peak[2], transient[2], lowBand[2];
  bool silent;
  uint32_t flags;
  uint32_t seq;
} DS5IrFrame;

typedef struct DS5IrPlayback {
  DS5IrFrame queue[DS5_IRP_QUEUE];
  unsigned count;
  float appliedLevel;
  double holdUntil;
  bool hasPending;
  DS5IrFrame pending;
  bool lastSeenEnergy;
  bool lastRising;  // the value ds5_irp_step returned last was energy after silence
  // Counters, read and cleared by ds5_irp_take_stats.
  unsigned framesIn, batches, maxBatch, overflows, ticksSeen, risingApplied, issued, applies;
} DS5IrPlayback;

typedef struct DS5IrStats {
  unsigned framesIn, batches, maxBatch, overflows, ticksSeen, risingApplied, issued, applies;
} DS5IrStats;

static inline float ds5_irp_unit(float v) { return isfinite(v) ? fminf(1.0f, fmaxf(0.0f, v)) : 0.0f; }

// What the client projects for one lane (rms toward the peak by the transient strength).
static inline float ds5_irp_lane_intensity(const DS5IrFrame *f, int lane) {
  const float average = ds5_irp_unit(f->rms[lane]);
  const float peak = fmaxf(average, ds5_irp_unit(f->peak[lane]));
  return average + (peak - average) * ds5_irp_unit(f->transient[lane]);
}

static inline float ds5_irp_level(const DS5IrFrame *f) {
  if (f->silent) return 0.0f;
  return fmaxf(ds5_irp_lane_intensity(f, 0), ds5_irp_lane_intensity(f, 1));
}

static inline void ds5_irp_reset(DS5IrPlayback *p) { memset(p, 0, sizeof(*p)); }

// Called for every frame as it arrives, under the caller's lock.
static inline void ds5_irp_push(DS5IrPlayback *p, const DS5IrFrame *frame) {
  p->framesIn++;
  const bool energy = ds5_irp_level(frame) >= DS5_IRP_ENERGY_FLOOR;
  if (energy && !p->lastSeenEnergy) p->ticksSeen++;
  p->lastSeenEnergy = energy;
  if (p->count >= DS5_IRP_QUEUE) {
    // Overflow: drop the oldest frame without energy, else the oldest.
    unsigned drop = 0;
    for (unsigned i = 0; i < p->count; i++) {
      if (ds5_irp_level(&p->queue[i]) < DS5_IRP_ENERGY_FLOOR) { drop = i; break; }
    }
    memmove(&p->queue[drop], &p->queue[drop + 1], (p->count - drop - 1) * sizeof(DS5IrFrame));
    p->count--;
    p->overflows++;
  }
  p->queue[p->count++] = *frame;
}

// Decides what to apply now. Returns true with *out set when a value is to be applied; *wakeAt is the time a
// further step is needed (a deferred value waits for the hold to end), 0 when none.
static inline bool ds5_irp_step(DS5IrPlayback *p, double now, DS5IrFrame *out, double *wakeAt) {
  const unsigned n = p->count;
  p->count = 0;
  *wakeAt = 0.0;
  if (n > 0) {
    p->batches++;
    if (n > p->maxBatch) p->maxBatch = n;
  }
  const DS5IrFrame *peak = NULL, *final = NULL;
  float peakLevel = -1.0f, finalLevel = 0.0f;
  if (n > 0) {
    final = &p->queue[n - 1];
    finalLevel = ds5_irp_level(final);
    for (unsigned i = 0; i < n; i++) {
      const float level = ds5_irp_level(&p->queue[i]);
      if (level >= peakLevel) { peakLevel = level; peak = &p->queue[i]; }
    }
  }
  const float before = p->appliedLevel;
  bool apply = false;
  p->lastRising = false;
  DS5IrFrame chosen;
  memset(&chosen, 0, sizeof(chosen));
  bool deferFinal = false;
  if (now < p->holdUntil) {
    if (n > 0) {
      if (peakLevel > before + 1e-6f) { chosen = *peak; apply = true; }
      p->pending = *final;
      p->hasPending = true;
    }
  } else if (n > 0) {
    p->hasPending = false;
    if (peakLevel > finalLevel + 1e-6f) { chosen = *peak; deferFinal = true; }
    else chosen = *final;
    apply = true;
    if (deferFinal) { p->pending = *final; p->hasPending = true; }
  } else if (p->hasPending) {
    chosen = p->pending;
    p->hasPending = false;
    apply = true;
  }
  if (apply) {
    const float level = ds5_irp_level(&chosen);
    const bool rising = level >= DS5_IRP_ENERGY_FLOOR && before < DS5_IRP_ENERGY_FLOOR;
    p->lastRising = rising;
    if (rising) p->risingApplied++;
    if (rising || deferFinal) p->holdUntil = now + DS5_IRP_MIN_HOLD;
    p->appliedLevel = level;
    p->applies++;
    *out = chosen;
  }
  if (p->hasPending) *wakeAt = p->holdUntil > now ? p->holdUntil : now;
  return apply;
}

// The caller issued the applied value to the actuators (true when it was an energy value after silence).
static inline void ds5_irp_note_issued(DS5IrPlayback *p, bool rising) { if (rising) p->issued++; }

static inline DS5IrStats ds5_irp_take_stats(DS5IrPlayback *p) {
  DS5IrStats s = {p->framesIn, p->batches, p->maxBatch, p->overflows, p->ticksSeen, p->risingApplied, p->issued, p->applies};
  p->framesIn = p->batches = p->maxBatch = p->overflows = p->ticksSeen = p->risingApplied = p->issued = p->applies = 0;
  return s;
}
