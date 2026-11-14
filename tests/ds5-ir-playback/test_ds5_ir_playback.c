#include "../../Limelight/Input/DS5IrPlayback.h"

#include <stdio.h>
#include <stdlib.h>

static int failures;
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "%s:%d: check failed: %s\n", __FILE__, __LINE__, #c); failures++; } } while (0)

typedef struct { double t; DS5IrFrame f; } TimedFrame;

static DS5IrFrame frameWith(float level, unsigned seq) {
  DS5IrFrame f;
  memset(&f, 0, sizeof(f));
  f.rms[0] = f.rms[1] = level;
  f.peak[0] = f.peak[1] = level;
  f.silent = level <= 0.0f;
  f.seq = seq;
  return f;
}

// The old delivery: the newest frame since the last drain, nothing else.
typedef struct { bool have; DS5IrFrame latest; float applied; unsigned risingApplied; } OldMailbox;

static unsigned xorshift(unsigned *s) { *s ^= *s << 13; *s ^= *s >> 17; *s ^= *s << 5; return *s; }

typedef enum { DrainSteady, DrainJitter, DrainStalls } DrainModel;

typedef struct { unsigned ticks, oldPlayed, newPlayed, newIssued, batchMax; double shortestHold; } Result;

// Frames arrive every 5 ms. A tick of lengthMs at rateHz has level 0.15. The main queue drains by the model;
// the new playback also gets its own wake-ups.
static Result run(double lengthMs, double rateHz, DrainModel model, unsigned seed) {
  const double frameDt = 0.005, seconds = 8.0;
  const unsigned frames = (unsigned)(seconds / frameDt);
  const unsigned period = (unsigned)(1.0 / rateHz / frameDt + 0.5);
  const unsigned tickFrames = (unsigned)ceil(lengthMs / 5.0);
  OldMailbox old = {0};
  DS5IrPlayback *np = calloc(1, sizeof(*np));
  Result r = {0};
  r.shortestHold = 1e9;
  double nextDrain = 0.001, wake = 0.0;
  double lastEnergyStart = -1.0, appliedAt = -1.0;
  bool appliedEnergy = false;
  unsigned s = seed;
  for (unsigned i = 0; i < frames; i++) {
    const double t = i * frameDt;
    const unsigned phase = i >= 40 ? (i - 40) % period : 0xffffffffu;
    const bool tick = i >= 40 && phase < tickFrames;
    if (tick && phase == 0) r.ticks++;
    DS5IrFrame f = frameWith(tick ? 0.15f : 0.0f, i + 1);
    ds5_irp_push(np, &f);
    old.have = true;
    old.latest = f;
    // Drains that fall before the next frame arrives.
    while (nextDrain <= t + frameDt || (wake != 0.0 && wake <= t + frameDt)) {
      double now;
      if (wake != 0.0 && (wake <= nextDrain || nextDrain > t + frameDt)) { now = wake; wake = 0.0; }
      else { now = nextDrain; }
      // Old mailbox: the newest frame since the previous drain; it plays only if it is the one with energy.
      if (now == nextDrain) {
        if (old.have) {
          const float level = ds5_irp_level(&old.latest);
          if (level >= DS5_IRP_ENERGY_FLOOR && old.applied < DS5_IRP_ENERGY_FLOOR) old.risingApplied++;
          old.applied = level;
          old.have = false;
        }
        double gap = 0.0055;
        if (model == DrainJitter) gap = 0.001 + (xorshift(&s) % 30) * 0.001;
        if (model == DrainStalls) gap = (xorshift(&s) % 7 == 0) ? 0.060 : 0.004;
        nextDrain = now + gap;
      }
      DS5IrFrame out;
      double w;
      if (ds5_irp_step(np, now, &out, &w)) {
        const float level = ds5_irp_level(&out);
        const bool rising = level >= DS5_IRP_ENERGY_FLOOR && !appliedEnergy;
        if (rising) { appliedAt = now; lastEnergyStart = now; }
        if (!rising && level < DS5_IRP_ENERGY_FLOOR && appliedEnergy && appliedAt >= 0 && now - appliedAt < r.shortestHold) r.shortestHold = now - appliedAt;
        appliedEnergy = level >= DS5_IRP_ENERGY_FLOOR;
        ds5_irp_note_issued(np, rising);
      }
      if (w != 0.0 && (wake == 0.0 || w < wake)) wake = w;
    }
  }
  (void)lastEnergyStart;
  DS5IrStats st = ds5_irp_take_stats(np);
  r.oldPlayed = old.risingApplied;
  r.newPlayed = st.risingApplied;
  r.newIssued = st.issued;
  r.batchMax = st.maxBatch;
  free(np);
  return r;
}

int main(void) {
  const double lengths[3] = {5, 10, 20}, rates[3] = {2, 5, 10};
  const char *names[3] = {"steady 5.5 ms", "jitter 1-30 ms", "stalls 60 ms"};
  for (int m = 0; m < 3; m++) {
    for (int l = 0; l < 3; l++) {
      for (int rr = 0; rr < 3; rr++) {
        Result r = run(lengths[l], rates[rr], (DrainModel)m, 12345u + (unsigned)(l * 7 + rr));
        printf("IR main queue %-14s tick %2.0f ms at %4.1f Hz: ticks %3u  old mailbox played %3u  new playback played %3u issued %3u (largest batch %u frames, shortest applied energy %.1f ms)\n",
               names[m], lengths[l], rates[rr], r.ticks, r.oldPlayed, r.newPlayed, r.newIssued, r.batchMax,
               r.shortestHold > 1e8 ? 0.0 : r.shortestHold * 1000.0);
        CHECK(r.newPlayed == r.ticks);
        CHECK(r.newIssued == r.ticks);
        CHECK(r.shortestHold > 1e8 || r.shortestHold >= DS5_IRP_MIN_HOLD - 0.0011);
      }
    }
  }
  // A run of silence changes nothing; a lone silent frame after energy releases once the hold is over.
  DS5IrPlayback *p = calloc(1, sizeof(*p));
  DS5IrFrame out; double wake;
  DS5IrFrame e = frameWith(0.5f, 1), z = frameWith(0.0f, 2);
  ds5_irp_push(p, &e); ds5_irp_push(p, &z);
  CHECK(ds5_irp_step(p, 1.000, &out, &wake) && ds5_irp_level(&out) > 0.4f);   // the peak first
  CHECK(wake > 1.0 && wake <= 1.0 + DS5_IRP_MIN_HOLD + 1e-9);
  CHECK(!ds5_irp_step(p, 1.010, &out, &wake));                                 // still holding
  CHECK(ds5_irp_step(p, 1.021, &out, &wake) && ds5_irp_level(&out) == 0.0f);   // then the deferred silence
  CHECK(p->risingApplied == 1 && p->ticksSeen == 1);
  free(p);
  if (failures) { fprintf(stderr, "%d failure(s)\n", failures); return 1; }
  printf("ds5 IR playback tests passed\n");
  return 0;
}
