#pragma once

// Where the speaker pair of the host's `Wireless Controller` endpoint goes on the pad's four-channel USB device. This is the one
// place that says which device channel carries what; change the defaults here (or with the defaults keys read by the renderer)
// when a measurement on the pad shows a different mapping.
//
// What is known, and from where:
//  * The output path of the pad is selected by bits 5:4 of byte 8 of the USB output report. The Linux driver (hid-playstation.c,
//    dualsense_output_worker) documents the paths as: 0 "L-R X" (headphone left, headphone right, speaker unrouted), 1 "L-L X",
//    2 "L-L R", 3 "X-X R" (speaker takes the right channel only); dualsensectl comments the same ("internal: right channel to
//    speaker"). So by those sources the speaker plays channel 2 of the first pair, the headset plays channels 1 and 2 as left and right.
//  * A listening test on this pad (from memory, "only roughly right") heard channel 1 on the speaker and nothing from channel 2. That
//    contradicts the sources, so neither is trusted: the default puts the mean of left and right on BOTH channels for the speaker, which
//    is audible whichever channel the speaker takes, and stereo as is for the headset.
//  * Channels 3 and 4 of the device are the haptic actuators and are written as zero.
// ds5_pad_tone --map-test announces each channel, pauses and asks what was heard, to settle it on the real pad.
//
// Header-only C so that tests/ds5-padmix builds it without Apple frameworks.

#include <stdbool.h>
#include <string.h>

typedef enum DS5SpeakerMix {
  DS5_SPEAKER_MIX_BOTH = 0,  // mean of left and right on channels 1 and 2
  DS5_SPEAKER_MIX_CH1,       // mean on channel 1, channel 2 zero
  DS5_SPEAKER_MIX_CH2,       // mean on channel 2, channel 1 zero
} DS5SpeakerMix;

typedef enum DS5HeadsetMix {
  DS5_HEADSET_MIX_STEREO = 0,  // left on channel 1, right on channel 2
  DS5_HEADSET_MIX_MONO,        // mean of left and right on both channels
  DS5_HEADSET_MIX_SWAP,        // right on channel 1, left on channel 2
} DS5HeadsetMix;

typedef struct DS5PadMix {
  DS5SpeakerMix speaker;
  DS5HeadsetMix headset;
} DS5PadMix;

static inline DS5PadMix ds5_pad_mix_default(void) {
  DS5PadMix mix = {DS5_SPEAKER_MIX_BOTH, DS5_HEADSET_MIX_STEREO};
  return mix;
}

// Names as used by the defaults keys ds5PadSpeakerMix (both, ch1, ch2) and ds5PadHeadsetMix (stereo, mono, swap); NULL or an unknown
// name keeps the default.
static inline DS5PadMix ds5_pad_mix_from_names(const char *speaker, const char *headset) {
  DS5PadMix mix = ds5_pad_mix_default();
  if (speaker != NULL) {
    if (strcmp(speaker, "ch1") == 0) mix.speaker = DS5_SPEAKER_MIX_CH1;
    else if (strcmp(speaker, "ch2") == 0) mix.speaker = DS5_SPEAKER_MIX_CH2;
    else if (strcmp(speaker, "both") == 0) mix.speaker = DS5_SPEAKER_MIX_BOTH;
  }
  if (headset != NULL) {
    if (strcmp(headset, "mono") == 0) mix.headset = DS5_HEADSET_MIX_MONO;
    else if (strcmp(headset, "swap") == 0) mix.headset = DS5_HEADSET_MIX_SWAP;
    else if (strcmp(headset, "stereo") == 0) mix.headset = DS5_HEADSET_MIX_STEREO;
  }
  return mix;
}

// One frame: the host's left and right to the device's channels 1 and 2, for the route the pad is on.
static inline void ds5_pad_mix_frame(const DS5PadMix *mix, bool headsetRoute, float left, float right, float *channel1, float *channel2) {
  const float mean = 0.5f * (left + right);
  if (headsetRoute) {
    switch (mix->headset) {
      case DS5_HEADSET_MIX_MONO: *channel1 = mean; *channel2 = mean; return;
      case DS5_HEADSET_MIX_SWAP: *channel1 = right; *channel2 = left; return;
      case DS5_HEADSET_MIX_STEREO: default: *channel1 = left; *channel2 = right; return;
    }
  }
  switch (mix->speaker) {
    case DS5_SPEAKER_MIX_CH1: *channel1 = mean; *channel2 = 0.0f; return;
    case DS5_SPEAKER_MIX_CH2: *channel1 = 0.0f; *channel2 = mean; return;
    case DS5_SPEAKER_MIX_BOTH: default: *channel1 = mean; *channel2 = mean; return;
  }
}
