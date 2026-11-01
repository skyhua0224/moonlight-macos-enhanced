#pragma once

// Mapping from the DualSense output extension (control message 0x5515) to the DualSense output
// report. Header-only C so the unit test in tests/ds5-output builds it with the report builder of
// the ds5 core and checks the bytes. The enable bits are those of the Linux hid-playstation driver
// (DS_OUTPUT_VALID_FLAG0/1/2) and SDL's PS5 driver; the brightness bit of flag2 and its 0..2 value
// range come from community notes and are the one unverified part (see the test).

#include <stdbool.h>
#include <stdint.h>

#include "Limelight.h"
#include "../../core/interaction/ds5-core/include/alkaidlab/ds5_core/ds5_core.h"

enum {
  DS5_FLAG0_HEADPHONE_VOLUME = 0x10,
  DS5_FLAG0_SPEAKER_VOLUME = 0x20,
  DS5_FLAG0_MIC_VOLUME = 0x40,
  DS5_FLAG0_AUDIO_CONTROL = 0x80,
  DS5_FLAG1_MUTE_LED = 0x01,
  DS5_FLAG1_MIC_MUTE = 0x02,
  DS5_FLAG1_LIGHTBAR = 0x04,
  DS5_FLAG1_PLAYER_LEDS = 0x10,
  DS5_FLAG1_AUDIO_CONTROL2 = 0x80,
  DS5_FLAG2_LIGHT_BRIGHTNESS = 0x01,
  DS5_HEADPHONE_VOLUME_MAX = 0x7f,
  DS5_SPEAKER_VOLUME_MAX = 0xff,
  DS5_LIGHTBAR_BRIGHTNESS_MAX = 2,
};

// The patterns a DualSense shows for players 1 to 4 (the Linux driver's player LED table). They are
// the ones GameController draws for GCControllerPlayerIndex1 to 4.
static const uint8_t kDS5PlayerLEDPatterns[4] = {0x04, 0x0a, 0x15, 0x1b};

// 0..3 for a pattern GameController draws for that player, -1 for no LEDs, -2 for any other pattern
// (which only the raw output report can show).
static inline int ds5_player_index_for_led_mask(uint8_t mask) {
  for (int index = 0; index < 4; index++) {
    if (kDS5PlayerLEDPatterns[index] == mask) return index;
  }
  return mask == 0 ? -1 : -2;
}

// Whether a player LED value of the host extension (validMask has LI_DS5_OUT_PLAYER_LEDS) is a request.
// The wire carries the valid bit and the 5-bit mask, so a mask of 0 is "all off" and also what a host
// sends when the game never wrote the LEDs. It is taken as a request when the game has set a pattern
// before (so a game can still turn the LEDs off), and not in a snapshot that marks every field valid
// (the initial default state). Before that it means "no value" and the connect-time number stays.
static inline bool ds5_player_led_request_applies(uint32_t validMask, uint8_t mask, bool gameHasSetPattern) {
  if (mask != 0) return true;
  const uint32_t everything = LI_DS5_OUT_PLAYER_LEDS | LI_DS5_OUT_MUTE_LED | LI_DS5_OUT_SPEAKER_VOLUME |
                              LI_DS5_OUT_HEADPHONE_VOLUME | LI_DS5_OUT_MIC_VOLUME | LI_DS5_OUT_MIC_MUTE |
                              LI_DS5_OUT_AUDIO_ROUTING;
  if ((validMask & everything) == everything) return false;
  return gameHasSetPattern;
}

static inline bool ds5_brightness_valid(uint8_t value) { return value <= DS5_LIGHTBAR_BRIGHTNESS_MAX; }

// Enable bits for the lights of an extension: mute LED and lightbar brightness. The player LEDs have
// their own writer and are not part of this report.
static inline void ds5_ext_light_flags(const LI_DS5_OUTPUT_EXTENSION *o, uint8_t *flag1, uint8_t *flag2) {
  *flag1 = (o->validMask & LI_DS5_OUT_MUTE_LED) ? DS5_FLAG1_MUTE_LED : 0;
  *flag2 = ((o->validMask & LI_DS5_OUT_LIGHTBAR_BRIGHTNESS) && ds5_brightness_valid(o->lightbarBrightness))
               ? DS5_FLAG2_LIGHT_BRIGHTNESS : 0;
}

static inline void ds5_ext_apply_lights(AlkDs5Feedback *fb, const LI_DS5_OUTPUT_EXTENSION *o,
                                        uint8_t flag1, uint8_t flag2) {
  if (flag1 & DS5_FLAG1_MUTE_LED) fb->mute_led = o->muteLed;
  if (flag2 & DS5_FLAG2_LIGHT_BRIGHTNESS) fb->lightbar_brightness = o->lightbarBrightness;
}

static inline void ds5_ext_audio_flags(const LI_DS5_OUTPUT_EXTENSION *o, uint8_t *flag0, uint8_t *flag1) {
  *flag0 = 0;
  *flag1 = 0;
  if (o->validMask & LI_DS5_OUT_HEADPHONE_VOLUME) *flag0 |= DS5_FLAG0_HEADPHONE_VOLUME;
  if (o->validMask & LI_DS5_OUT_SPEAKER_VOLUME) *flag0 |= DS5_FLAG0_SPEAKER_VOLUME;
  if (o->validMask & LI_DS5_OUT_MIC_VOLUME) *flag0 |= DS5_FLAG0_MIC_VOLUME;
  if (o->validMask & LI_DS5_OUT_AUDIO_ROUTING) *flag0 |= DS5_FLAG0_AUDIO_CONTROL;
  if (o->validMask & LI_DS5_OUT_MIC_MUTE) *flag1 |= DS5_FLAG1_MIC_MUTE;
}

// limitPercent (1..100) caps the headset and speaker volume to that share of the device range.
static inline uint8_t ds5_limited_volume(uint8_t value, int deviceMax, int limitPercent) {
  const int limit = limitPercent < 1 ? 100 : (limitPercent > 100 ? 100 : limitPercent);
  const int cap = (deviceMax * limit) / 100;
  return (uint8_t)(value < cap ? value : cap);
}

static inline void ds5_ext_apply_audio(AlkDs5Feedback *fb, const LI_DS5_OUTPUT_EXTENSION *o,
                                       uint8_t flag0, uint8_t flag1, int limitPercent) {
  if (flag0 & DS5_FLAG0_HEADPHONE_VOLUME)
    fb->headphone_volume = ds5_limited_volume(o->headphoneVolume, DS5_HEADPHONE_VOLUME_MAX, limitPercent);
  if (flag0 & DS5_FLAG0_SPEAKER_VOLUME)
    fb->speaker_volume = ds5_limited_volume(o->speakerVolume, DS5_SPEAKER_VOLUME_MAX, limitPercent);
  if (flag0 & DS5_FLAG0_MIC_VOLUME) fb->mic_volume = o->micVolume;
  if (flag0 & DS5_FLAG0_AUDIO_CONTROL) fb->audio_control = o->audioRouting;
  if (flag1 & DS5_FLAG1_MIC_MUTE) fb->mic_mute = o->micMute;
}

// The pad's own audio bytes while the host's speaker pair is played on it over USB (see ControllerSupport,
// configurePadAudioForPlayer:). Output path in bits 5:4 of byte 8: 3 = the right channel to the internal speaker with the
// headset muted, 0 = left and right to the headset with the speaker muted (the Linux driver's choice, by the headset bit of
// the input report). Speaker volume byte 6: the pad accepts 0x3d to 0x64. Pre-amp in byte 38: +6 dB (2) with the speaker.
typedef struct DS5PadAudioBytes {
  uint8_t flag0, flag1;
  uint8_t headphoneVolume, speakerVolume, audioControl, audioControl2;
} DS5PadAudioBytes;

static inline DS5PadAudioBytes ds5_pad_audio_bytes(bool headset, uint8_t speakerVolume, uint8_t headsetVolume) {
  DS5PadAudioBytes bytes;
  bytes.flag0 = DS5_FLAG0_HEADPHONE_VOLUME | DS5_FLAG0_SPEAKER_VOLUME | DS5_FLAG0_AUDIO_CONTROL;
  bytes.flag1 = DS5_FLAG1_AUDIO_CONTROL2;
  bytes.headphoneVolume = headsetVolume > DS5_HEADPHONE_VOLUME_MAX ? (uint8_t)DS5_HEADPHONE_VOLUME_MAX : headsetVolume;
  bytes.speakerVolume = speakerVolume;
  bytes.audioControl = (uint8_t)((headset ? 0u : 3u) << 4);
  bytes.audioControl2 = headset ? 0 : 2;
  return bytes;
}
