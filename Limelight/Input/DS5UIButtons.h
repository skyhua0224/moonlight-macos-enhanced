#pragma once

// Interface navigation from the DualSense raw HID input (the DS5 bridge), for when GameController
// does not report the pad. The core parser (ds5_core.c) turns a report into AlkDs5State; this maps
// that state to the bit set ControllerNavigation reads (the same bits its GameController path
// builds), so one edge/repeat machine serves both sources. Header-only C so tests/ds5-ui-pad builds
// it with the core parsers and no Apple frameworks.
//
// State layout (ds5_core.c, parse): buttons bit 0 Square, 1 Cross, 2 Circle, 3 Triangle, 4 L1, 5 R1,
// 6 L2, 7 R2, 8 Create, 9 Options, 10 L3, 11 R3, 12 PS, 13 touchpad, 14 Mute. hat: 0 up, 1 up-right,
// 2 right, 3 down-right, 4 down, 5 down-left, 6 left, 7 up-left, 8 and above neutral. Sticks are
// 0..255 with 128 at rest and up at the low end.

#include <stdbool.h>
#include <stdint.h>

// Same values as the UI enum in ControllerNavigation.m (which checks them at compile time).
enum {
  DS5UI_UP = 1 << 0,
  DS5UI_DOWN = 1 << 1,
  DS5UI_LEFT = 1 << 2,
  DS5UI_RIGHT = 1 << 3,
  DS5UI_A = 1 << 4,
  DS5UI_B = 1 << 5,
  DS5UI_X = 1 << 6,
  DS5UI_MENU = 1 << 7,
  DS5UI_VIEW = 1 << 8,
  DS5UI_LB = 1 << 9,
  DS5UI_RB = 1 << 10,
  DS5UI_Y = 1 << 11,
  DS5UI_LT = 1 << 12,
  DS5UI_RT = 1 << 13,
};

#define DS5UI_CORE_SQUARE 0
#define DS5UI_CORE_CROSS 1
#define DS5UI_CORE_CIRCLE 2
#define DS5UI_CORE_TRIANGLE 3
#define DS5UI_CORE_L1 4
#define DS5UI_CORE_R1 5
#define DS5UI_CORE_CREATE 8
#define DS5UI_CORE_OPTIONS 9
#define DS5UI_CORE_L2 6
#define DS5UI_CORE_R2 7

// The triggers are analog. A trigger counts as pressed past 0.60 of its travel and as released below 0.35: the gap keeps
// a trigger resting near the threshold from chattering, so one pull is one press. Edge only, it never repeats.
#define DS5UI_TRIGGER_PRESS 0.60f
#define DS5UI_TRIGGER_RELEASE 0.35f

static inline bool ds5_ui_core_bit(uint64_t buttons, int bit) { return ((buttons >> bit) & 1u) != 0; }

// The stick deflection (-1 .. 1, positive right / down in HID order) of one raw axis byte.
static inline float ds5_ui_axis(uint8_t raw) { return ((float)raw - 128.0f) / 127.0f; }

// Cross confirms (A), Circle goes back (B), Square is X, Triangle is Y, Options is Menu, Create is
// View, L1/R1 are the shoulders. The d-pad is the hat; the left stick counts like the GameController
// path counts it: only its stronger axis, past 0.6.
static inline uint32_t ds5_ui_buttons(uint64_t coreButtons, uint8_t hat, uint8_t leftX, uint8_t leftY) {
  uint32_t ui = 0;
  switch (hat) {
    case 0: ui |= DS5UI_UP; break;
    case 1: ui |= DS5UI_UP | DS5UI_RIGHT; break;
    case 2: ui |= DS5UI_RIGHT; break;
    case 3: ui |= DS5UI_DOWN | DS5UI_RIGHT; break;
    case 4: ui |= DS5UI_DOWN; break;
    case 5: ui |= DS5UI_DOWN | DS5UI_LEFT; break;
    case 6: ui |= DS5UI_LEFT; break;
    case 7: ui |= DS5UI_UP | DS5UI_LEFT; break;
    default: break;
  }
  const float x = ds5_ui_axis(leftX);
  const float y = ds5_ui_axis(leftY);
  const float ax = x < 0 ? -x : x;
  const float ay = y < 0 ? -y : y;
  if (ax > ay) {
    if (x < -0.6f) ui |= DS5UI_LEFT;
    if (x > 0.6f) ui |= DS5UI_RIGHT;
  } else {
    if (y < -0.6f) ui |= DS5UI_UP;
    if (y > 0.6f) ui |= DS5UI_DOWN;
  }
  if (ds5_ui_core_bit(coreButtons, DS5UI_CORE_CROSS)) ui |= DS5UI_A;
  if (ds5_ui_core_bit(coreButtons, DS5UI_CORE_CIRCLE)) ui |= DS5UI_B;
  if (ds5_ui_core_bit(coreButtons, DS5UI_CORE_SQUARE)) ui |= DS5UI_X;
  if (ds5_ui_core_bit(coreButtons, DS5UI_CORE_TRIANGLE)) ui |= DS5UI_Y;
  if (ds5_ui_core_bit(coreButtons, DS5UI_CORE_OPTIONS)) ui |= DS5UI_MENU;
  if (ds5_ui_core_bit(coreButtons, DS5UI_CORE_CREATE)) ui |= DS5UI_VIEW;
  if (ds5_ui_core_bit(coreButtons, DS5UI_CORE_L1)) ui |= DS5UI_LB;
  if (ds5_ui_core_bit(coreButtons, DS5UI_CORE_R1)) ui |= DS5UI_RB;
  return ui;
}

// One trigger, travel 0 .. 1: `wasDown` is what it was at the last report.
static inline bool ds5_ui_trigger_down(float travel, bool wasDown) {
  return wasDown ? travel > DS5UI_TRIGGER_RELEASE : travel >= DS5UI_TRIGGER_PRESS;
}

// L2 / R2 as UI bits from the raw analog bytes (0 .. 255), with hysteresis against `previous` (the bits returned by the
// last call). The digital L2 / R2 bits of the report also count, for a pad whose analog byte stays at rest.
static inline uint32_t ds5_ui_triggers(uint32_t previous, uint8_t leftTrigger, uint8_t rightTrigger, uint64_t coreButtons) {
  uint32_t ui = 0;
  if (ds5_ui_trigger_down((float)leftTrigger / 255.0f, (previous & DS5UI_LT) != 0) || ds5_ui_core_bit(coreButtons, DS5UI_CORE_L2)) ui |= DS5UI_LT;
  if (ds5_ui_trigger_down((float)rightTrigger / 255.0f, (previous & DS5UI_RT) != 0) || ds5_ui_core_bit(coreButtons, DS5UI_CORE_R2)) ui |= DS5UI_RT;
  return ui;
}

// The right stick's vertical deflection, used to scroll the page (up is positive, like GameController).
static inline float ds5_ui_scroll(uint8_t rightY) { return -ds5_ui_axis(rightY); }
