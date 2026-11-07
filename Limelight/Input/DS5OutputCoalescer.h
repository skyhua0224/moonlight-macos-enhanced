#pragma once

// Pending slot, pacing and duplicate filter for the raw HID output writer (DS5RawHIDBridge).
// Header-only C with no Apple types so tests/ds5-outqueue builds it with a plain C compiler. The
// caller owns the lock around every call and the queue the writes run on; nothing here blocks.
//
// Reports that change nothing about the motors merge into the pending one: the union of the enable bytes
// (1, 2 and 39 of the USB layout) with the newest values. A pulse is never merged away: when the motors
// go from running to stopped (or from stopped to running while the pad is still running a pulse) the
// report becomes a new entry behind the pending one, at most DS5_OUTC_QUEUE entries deep, and every entry is
// written once. While two reports both run the motors the louder value of each motor wins (the peak).
// A paced pad (Bluetooth) is written one report at a time, at most once per pacedIntervalMs, and a
// report equal to the one last written is not written again. An unpaced pad (USB) is written as
// soon as the previous write has completed.
// Bluetooth PCM frames (0x39 audio, 0x32 haptics) have their own lanes: they stay ordered on their frame
// clock and are never merged. Only while such a stream runs, any other Bluetooth report waits in a single
// slot between the frames and the newest one wins; outside a PCM stream every report goes through the
// queue above, so a rumble pulse keeps its start and stop edges on Bluetooth as it does on USB.

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#define DS5_OUTC_CAPACITY 547
// Entries waiting at once: enough for several pulse edges inside one Bluetooth pacing window.
#define DS5_OUTC_QUEUE 8
#define DS5_OUTC_PACED_INTERVAL_MS 30.0
#define DS5_OUTC_AUDIO_INTERVAL_MS (1000.0 * 64.0 / 3000.0)
// One 64-byte haptic block. Half of the 0x39 slot: 32/3000 seconds.
#define DS5_OUTC_HAPTICS_INTERVAL_MS (1000.0 * 32.0 / 3000.0)
#define DS5_OUTC_AUDIO_PIPELINE 2

typedef struct DS5OutputStats {
  unsigned requested;  // reports handed to the writer
  unsigned written;    // writes started
  unsigned merged;     // requests folded into a pending report
  unsigned identical;  // reports not written because the pad already holds them
  unsigned failed;     // writes that completed with an error
  unsigned pulses;     // writes that started the motors (a pulse reaches the pad)
  unsigned kept;       // reports kept as their own entry because they end or start a pulse
  unsigned dropped;    // reports merged into the last entry because the queue was full
  double maxWriteMs;   // longest write, start to completion
} DS5OutputStats;

typedef struct DS5OutputCoalescer {
  uint8_t queue[DS5_OUTC_QUEUE][DS5_OUTC_CAPACITY];
  bool queueRunning[DS5_OUTC_QUEUE];  // whether the motors run after this entry
  size_t queueCount;
  uint8_t pending[DS5_OUTC_CAPACITY];  // the entry that is written next (a copy of queue[0])
  size_t pendingLength;
  uint64_t pendingKey;
  bool pendingPaced;
  bool pendingAudio;
  bool hasPending;
  bool lastRunning;  // whether the motors ran after the last write
  uint8_t audioLane[DS5_OUTC_QUEUE][DS5_OUTC_CAPACITY];
  size_t audioCount;
  size_t audioLength;
  uint64_t audioKey;
  bool hasAudioLane;
  uint8_t hapticReport[DS5_OUTC_CAPACITY];
  size_t hapticLength;
  uint64_t hapticKey;
  bool hasHaptic;
  double lastAudioStartMs;
  double audioIntervalMs;
  bool hasAudioStart;
  uint8_t audioInflight;
  double audioInflightStart[DS5_OUTC_AUDIO_PIPELINE];
  uint8_t flight[DS5_OUTC_CAPACITY];
  size_t flightLength;
  uint64_t flightKey;
  bool inFlight;
  bool flightRunning;
  double flightStartMs;
  uint8_t last[DS5_OUTC_CAPACITY];
  size_t lastLength;
  uint64_t lastKey;
  bool hasLast;
  double lastStartMs;
  bool hasStart;
  double pacedIntervalMs;
  DS5OutputStats stats;
} DS5OutputCoalescer;

typedef enum DS5OutputStep {
  DS5_OUTC_IDLE = 0,   // nothing to write
  DS5_OUTC_WAIT = 1,   // a report is pending: retry after waitMs, or after the completion when waitMs is 0
  DS5_OUTC_WRITE = 2,  // write the returned report now, then call ds5_outc_complete
} DS5OutputStep;

static inline void ds5_outc_init(DS5OutputCoalescer *c) {
  memset(c, 0, sizeof(*c));
  c->pacedIntervalMs = DS5_OUTC_PACED_INTERVAL_MS;
  c->audioIntervalMs = DS5_OUTC_AUDIO_INTERVAL_MS;
}

// Forget everything pending and remembered (the writer stopped).
static inline void ds5_outc_clear(DS5OutputCoalescer *c) {
  c->hasPending = false;
  c->queueCount = 0;
  c->lastRunning = false;
  c->hasLast = false;
  c->inFlight = false;
  c->hasStart = false;
  c->pendingAudio = false;
  c->audioCount = 0;
  c->hasAudioLane = false;
  c->hasHaptic = false;
  c->hasAudioStart = false;
  c->audioInflight = 0;
}

static inline bool ds5_outc_busy(const DS5OutputCoalescer *c) {
  return c->hasPending || c->inFlight || c->hasAudioLane || c->hasHaptic || c->audioInflight > 0;
}

static inline double ds5_outc_audio_wait_ms(const DS5OutputCoalescer *c, double nowMs) {
  if (!c->hasAudioLane || c->audioCount == 0 || !c->hasAudioStart) return 0.0;
  const double due = c->lastAudioStartMs + c->audioIntervalMs;
  return nowMs < due ? due - nowMs : 0.0;
}

// Bluetooth audio reports are fixed-size HID frames (the public 0x39 layout is
// 547 bytes). They must remain ordered even when two successive frames have
// identical payloads; merging or duplicate suppression would create an audio
// underrun. The shorter 0x35 layout is also kept in this class for future
// runtime-probed firmware variants.
static inline bool ds5_outc_is_audio_report(size_t length) {
  return length >= 334u;
}

// 0x39 carries two 3 kHz blocks (21.333 ms). 0x32 carries one (10.667 ms).
// apple-iohid-setreport-kernel-20261109: completion is the signal that the
// previous output report has left. On this Bluetooth pad a second outstanding
// 0x32 stretches that completion from under a millisecond into tens of
// milliseconds, so the short report keeps one in flight and one newest pending report. It is not a queue.
static inline bool ds5_outc_is_short_haptic(const uint8_t *report, size_t length) {
  return report != NULL && length == 142u && report[0] == 0x32u;
}

static inline bool ds5_outc_is_pcm_stream(const uint8_t *report, size_t length) {
  if (ds5_outc_is_audio_report(length)) return true;
  return ds5_outc_is_short_haptic(report, length);
}

static inline unsigned ds5_outc_pcm_pipeline(const DS5OutputCoalescer *c) {
  if (c->audioLength == 142u) return 1u;
  return (unsigned)DS5_OUTC_AUDIO_PIPELINE;
}

static inline double ds5_outc_pcm_interval_ms(size_t length) {
  return ds5_outc_is_audio_report(length) ? DS5_OUTC_AUDIO_INTERVAL_MS : DS5_OUTC_HAPTICS_INTERVAL_MS;
}

// The pad behind `key` was replaced or removed: what was last written to it no longer holds.
static inline void ds5_outc_forget_last(DS5OutputCoalescer *c, uint64_t key) {
  if (c->hasLast && c->lastKey == key) c->hasLast = false;
}

// Whether a USB-layout report carries the rumble enable bits (compatible vibration, flag0 0x01, or the improved
// curve, flag2 0x04), and the motor bytes (right 3, left 4).
static inline bool ds5_outc_carries_rumble(const uint8_t *report, size_t length) {
  return length > 39 && ((report[1] & 0x01u) != 0u || (report[39] & 0x04u) != 0u);
}

static inline void ds5_outc_publish_front(DS5OutputCoalescer *c) {
  if (c->queueCount == 0) {
    c->hasPending = false;
    return;
  }
  memcpy(c->pending, c->queue[0], c->pendingLength);
  c->hasPending = true;
}

static inline void ds5_outc_drop_bt_lanes(DS5OutputCoalescer *c) {
  c->audioCount = 0;
  c->hasAudioLane = false;
  c->hasHaptic = false;
  c->pendingAudio = false;
}

static inline bool ds5_outc_submit_bt(DS5OutputCoalescer *c, uint64_t key, const uint8_t *report, size_t length, bool audio) {
  c->stats.requested++;
  if ((c->hasAudioLane && c->audioKey != key) || (c->hasHaptic && c->hapticKey != key) ||
      (c->queueCount > 0 && c->pendingKey != key)) {
    ds5_outc_drop_bt_lanes(c);
    c->queueCount = 0;
    c->hasPending = false;
  }
  c->queueCount = 0;
  c->hasPending = false;
  if (audio && ds5_outc_is_short_haptic(report, length)) {
    if (c->hasAudioLane && c->audioLength != length) {
      c->stats.dropped += (unsigned)c->audioCount;
      c->audioCount = 0;
      c->hasAudioStart = false;
    }
    c->audioIntervalMs = DS5_OUTC_HAPTICS_INTERVAL_MS;
    if (c->audioCount >= 1u) {
      memcpy(c->audioLane[0], report, length);
      c->stats.dropped++;
    } else {
      memcpy(c->audioLane[0], report, length);
    }
    c->audioCount = 1u;
    c->audioLength = length;
    c->audioKey = key;
    c->hasAudioLane = true;
    c->pendingAudio = true;
    c->pendingPaced = true;
    c->pendingKey = key;
    c->pendingLength = length;
    return true;
  }
  if (audio) {
    if (c->hasAudioLane && c->audioLength != 0 && c->audioLength != length) {
      c->stats.dropped += (unsigned)c->audioCount;
      c->audioCount = 0;
      c->hasAudioStart = false;
    }
    c->audioIntervalMs = ds5_outc_pcm_interval_ms(length);
    if (c->audioCount >= DS5_OUTC_QUEUE) {
      memcpy(c->audioLane[DS5_OUTC_QUEUE - 1u], report, length);
      c->stats.dropped++;
    } else {
      const size_t at = c->audioCount++;
      memcpy(c->audioLane[at], report, length);
      if (at > 0) c->stats.kept++;
    }
    c->audioLength = length;
    c->audioKey = key;
    c->hasAudioLane = true;
    c->pendingAudio = true;
    c->pendingPaced = true;
    c->pendingKey = key;
    c->pendingLength = length;
    return true;
  }
  if (c->hasHaptic) c->stats.merged++;
  memcpy(c->hapticReport, report, length);
  c->hapticLength = length;
  c->hapticKey = key;
  c->hasHaptic = true;
  c->pendingPaced = true;
  c->pendingAudio = c->hasAudioLane;
  c->pendingKey = key;
  c->pendingLength = length;
  return true;
}

static inline DS5OutputStep ds5_outc_take_haptic(DS5OutputCoalescer *c, double nowMs, uint8_t *out, size_t *outLength,
                                                 uint64_t *outKey) {
  if (c->hasLast && c->lastKey == c->hapticKey && c->lastLength == c->hapticLength &&
      memcmp(c->last, c->hapticReport, c->hapticLength) == 0) {
    c->hasHaptic = false;
    c->stats.identical++;
    return DS5_OUTC_IDLE;
  }
  const bool running = ds5_outc_carries_rumble(c->hapticReport, c->hapticLength) &&
                       ((c->hapticReport[3] | c->hapticReport[4]) != 0u);
  memcpy(c->flight, c->hapticReport, c->hapticLength);
  c->flightLength = c->hapticLength;
  c->flightKey = c->hapticKey;
  c->flightRunning = running;
  if (running) c->stats.pulses++;
  c->hasHaptic = false;
  c->inFlight = true;
  c->flightStartMs = nowMs;
  c->stats.written++;
  memcpy(out, c->flight, c->flightLength);
  *outLength = c->flightLength;
  *outKey = c->flightKey;
  return DS5_OUTC_WRITE;
}

static inline DS5OutputStep ds5_outc_next_bt(DS5OutputCoalescer *c, double nowMs, uint8_t *out, size_t *outLength,
                                              uint64_t *outKey, double *waitMs) {
  *waitMs = 0.0;
  if (c->hasAudioLane && c->audioCount > 0) {
    if (c->audioInflight >= ds5_outc_pcm_pipeline(c)) {
      *waitMs = 0.0;
      return DS5_OUTC_WAIT;
    }
    if (c->hasAudioStart) {
      const double due = c->lastAudioStartMs + c->audioIntervalMs;
      if (nowMs < due) {
        if (c->hasHaptic && c->audioInflight == 0 && !c->inFlight) {
          const DS5OutputStep step = ds5_outc_take_haptic(c, nowMs, out, outLength, outKey);
          if (step == DS5_OUTC_WRITE) return step;
        }
        *waitMs = due - nowMs;
        return DS5_OUTC_WAIT;
      }
    }
    if (c->inFlight) return DS5_OUTC_WAIT;
    memcpy(out, c->audioLane[0], c->audioLength);
    *outLength = c->audioLength;
    *outKey = c->audioKey;
    for (size_t i = 1; i < c->audioCount; i++) memcpy(c->audioLane[i - 1], c->audioLane[i], DS5_OUTC_CAPACITY);
    c->audioCount--;
    c->hasAudioLane = c->audioCount > 0;
    c->pendingAudio = c->hasAudioLane;
    c->audioInflightStart[c->audioInflight] = nowMs;
    c->audioInflight++;
    c->lastAudioStartMs = nowMs;
    c->hasAudioStart = true;
    c->stats.written++;
    return DS5_OUTC_WRITE;
  }
  if (c->hasHaptic) {
    if (c->inFlight || c->audioInflight > 0) return DS5_OUTC_WAIT;
    return ds5_outc_take_haptic(c, nowMs, out, outLength, outKey);
  }
  return DS5_OUTC_IDLE;
}

static inline bool ds5_outc_submit_queue(DS5OutputCoalescer *c, uint64_t key, bool paced, const uint8_t *report, size_t length);

// Takes a report for the pad `key`. Returns false when it cannot be held.
// PCM frames (0x39 audio, 0x32 haptics) use the Bluetooth lanes. Any other paced report waits in the single
// slot between those frames only while a PCM stream runs; otherwise it goes through the ordered queue, so a
// rumble pulse on a Bluetooth pad keeps its start and stop edges just as on USB.
static inline bool ds5_outc_submit(DS5OutputCoalescer *c, uint64_t key, bool paced, const uint8_t *report, size_t length) {
  if (report == NULL || length == 0 || length > DS5_OUTC_CAPACITY) return false;
  const bool pcm = ds5_outc_is_pcm_stream(report, length);
  if (pcm || (paced && (c->hasAudioLane || c->audioInflight > 0))) return ds5_outc_submit_bt(c, key, report, length, pcm);
  if (paced && c->hasHaptic && c->hapticKey == key && c->hapticLength == length) {
    // The PCM stream ended with a report still in its slot: it goes first in the queue (already counted).
    uint8_t held[DS5_OUTC_CAPACITY];
    memcpy(held, c->hapticReport, length);
    c->hasHaptic = false;
    ds5_outc_submit_queue(c, key, true, held, length);
    c->stats.requested--;
  }
  if (c->hasAudioLane || c->hasHaptic) ds5_outc_drop_bt_lanes(c);
  return ds5_outc_submit_queue(c, key, paced, report, length);
}

static inline bool ds5_outc_submit_queue(DS5OutputCoalescer *c, uint64_t key, bool paced, const uint8_t *report, size_t length) {
  c->stats.requested++;
  if (c->queueCount > 0 && (c->pendingKey != key || c->pendingLength != length)) {
    // Another pad (or layout): what waited for the old one is replaced, as it always was.
    c->queueCount = 0;
  }
  const bool audio = ds5_outc_is_audio_report(length);
  if (audio) {
    if (c->queueCount >= DS5_OUTC_QUEUE) {
      // Keep the newest audio frame when HID completion falls behind. The
      // queue is deliberately bounded so a stalled Bluetooth link cannot
      // retain unbounded PCM latency.
      memcpy(c->queue[DS5_OUTC_QUEUE - 1u], report, length);
      c->queueRunning[DS5_OUTC_QUEUE - 1u] = false;
      c->stats.dropped++;
    } else {
      const size_t at = c->queueCount++;
      memcpy(c->queue[at], report, length);
      c->queueRunning[at] = false;
      if (at > 0) c->stats.kept++;
    }
    c->pendingLength = length;
    c->pendingKey = key;
    c->pendingPaced = paced;
    c->pendingAudio = true;
    c->pacedIntervalMs = 1000.0 * 64.0 / 3000.0;
    ds5_outc_publish_front(c);
    return true;
  }

  const bool carries = ds5_outc_carries_rumble(report, length);
  const bool running = carries ? ((report[3] | report[4]) != 0u) : false;
  const bool lastQueuedRunning = c->queueCount > 0 ? c->queueRunning[c->queueCount - 1] : c->lastRunning;
  const bool beforeLastRunning = c->queueCount > 1 ? c->queueRunning[c->queueCount - 2] : c->lastRunning;
  const bool runningNow = carries ? running : lastQueuedRunning;
  bool push = false;
  if (c->queueCount == 0) {
    push = true;
  } else if (carries && running != lastQueuedRunning) {
    // The motors start or stop. The change is kept as its own entry unless the entry in front is itself only an
    // idle report between two idle states (then nothing is lost by folding it in).
    push = lastQueuedRunning || beforeLastRunning;
  }
  if (push && c->queueCount >= DS5_OUTC_QUEUE) {
    push = false;
    c->stats.dropped++;
  }
  if (push) {
    const size_t at = c->queueCount++;
    memcpy(c->queue[at], report, length);
    c->queueRunning[at] = runningNow;
    if (at > 0) c->stats.kept++;
    if (at > 0 || false) {
      // Behind an older entry: the enable bytes of what was written before it are not carried over; every entry
      // states what it changes.
    }
  } else {
    const size_t at = c->queueCount - 1;
    uint8_t flags[3] = { c->queue[at][1], c->queue[at][2], c->queue[at][39] };
    const uint8_t oldRight = c->queue[at][3], oldLeft = c->queue[at][4];
    const bool oldCarried = ds5_outc_carries_rumble(c->queue[at], length) && ((oldRight | oldLeft) != 0u);
    c->stats.merged++;
    if (carries || !(length > 39)) {
      memcpy(c->queue[at], report, length);
    } else {
      // A report that does not touch the motors adds its enable bits and its other values; the motors stay.
      uint8_t keep[DS5_OUTC_CAPACITY];
      memcpy(keep, c->queue[at], length);
      memcpy(c->queue[at], report, length);
      c->queue[at][3] = keep[3];
      c->queue[at][4] = keep[4];
    }
    if (length > 39) {
      c->queue[at][1] |= flags[0];
      c->queue[at][2] |= flags[1];
      c->queue[at][39] |= flags[2];
      // Two reports that both run the motors: the louder value of each motor wins.
      if (carries && running && oldCarried) {
        if (oldRight > c->queue[at][3]) c->queue[at][3] = oldRight;
        if (oldLeft > c->queue[at][4]) c->queue[at][4] = oldLeft;
      }
    }
    c->queueRunning[at] = runningNow;
  }
  c->pendingLength = length;
  c->pendingKey = key;
  c->pendingPaced = paced;
  c->pendingAudio = false;
  c->pacedIntervalMs = DS5_OUTC_PACED_INTERVAL_MS;
  ds5_outc_publish_front(c);
  return true;
}

// Decides the next step at `nowMs`. For DS5_OUTC_WRITE the report to write is copied to `out`
// (capacity DS5_OUTC_CAPACITY) with its length and key.
static inline DS5OutputStep ds5_outc_next(DS5OutputCoalescer *c, double nowMs, uint8_t *out, size_t *outLength,
                                          uint64_t *outKey, double *waitMs) {
  *waitMs = 0.0;
  if (c->hasAudioLane || c->hasHaptic) return ds5_outc_next_bt(c, nowMs, out, outLength, outKey, waitMs);
  if (c->audioInflight > 0) return DS5_OUTC_WAIT;
  if (!c->hasPending) return DS5_OUTC_IDLE;
  if (c->pendingPaced && !c->pendingAudio && c->hasLast && c->lastKey == c->pendingKey && c->lastLength == c->pendingLength &&
      memcmp(c->last, c->pending, c->pendingLength) == 0 && !c->inFlight) {
    c->hasPending = false;
    c->stats.identical++;
    return DS5_OUTC_IDLE;
  }
  if (c->inFlight) return DS5_OUTC_WAIT;
  if (c->pendingPaced && c->hasStart) {
    const double due = c->lastStartMs + c->pacedIntervalMs;
    if (nowMs < due) {
      *waitMs = due - nowMs;
      return DS5_OUTC_WAIT;
    }
  }
  memcpy(c->flight, c->queue[0], c->pendingLength);
  c->flightLength = c->pendingLength;
  c->flightKey = c->pendingKey;
  c->flightRunning = c->queueRunning[0];
  if (c->flightRunning && ds5_outc_carries_rumble(c->flight, c->flightLength)) c->stats.pulses++;
  for (size_t i = 1; i < c->queueCount; i++) {
    memcpy(c->queue[i - 1], c->queue[i], DS5_OUTC_CAPACITY);
    c->queueRunning[i - 1] = c->queueRunning[i];
  }
  c->queueCount--;
  ds5_outc_publish_front(c);
  c->inFlight = true;
  c->flightStartMs = nowMs;
  c->lastStartMs = nowMs;
  c->hasStart = true;
  c->stats.written++;
  memcpy(out, c->flight, c->flightLength);
  *outLength = c->flightLength;
  *outKey = c->flightKey;
  return DS5_OUTC_WRITE;
}

// The write returned by ds5_outc_next completed. A failed write forgets the remembered report so the
// same state is written again by the next request.
static inline void ds5_outc_complete(DS5OutputCoalescer *c, double nowMs, bool success) {
  if (c->audioInflight > 0 && !c->inFlight) {
    const double elapsed = nowMs - c->audioInflightStart[0];
    for (uint8_t i = 1; i < c->audioInflight; i++) c->audioInflightStart[i - 1] = c->audioInflightStart[i];
    c->audioInflight--;
    if (elapsed > c->stats.maxWriteMs) c->stats.maxWriteMs = elapsed;
    if (!success) c->stats.failed++;
    return;
  }
  if (!c->inFlight) return;
  c->inFlight = false;
  const double elapsed = nowMs - c->flightStartMs;
  if (elapsed > c->stats.maxWriteMs) c->stats.maxWriteMs = elapsed;
  if (success) {
    memcpy(c->last, c->flight, c->flightLength);
    c->lastLength = c->flightLength;
    c->lastKey = c->flightKey;
    c->hasLast = true;
    c->lastRunning = c->flightRunning;
  } else {
    c->stats.failed++;
    c->hasLast = false;
  }
}

// The write returned by ds5_outc_next could not be started (the pad is gone): nothing was written.
static inline void ds5_outc_abort(DS5OutputCoalescer *c) {
  if (c->audioInflight > 0 && !c->inFlight) {
    c->audioInflight--;
    if (c->audioInflight == 0) c->hasAudioStart = false;
    if (c->stats.written > 0) c->stats.written--;
    return;
  }
  if (!c->inFlight) return;
  c->inFlight = false;
  c->hasStart = false;
  if (c->stats.written > 0) c->stats.written--;
}

// Copies the counters and starts a new window.
static inline DS5OutputStats ds5_outc_take_stats(DS5OutputCoalescer *c) {
  const DS5OutputStats stats = c->stats;
  memset(&c->stats, 0, sizeof(c->stats));
  return stats;
}
