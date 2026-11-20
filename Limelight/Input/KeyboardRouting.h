#pragma once

// The pure decisions behind the keyboard paths the stream window takes, kept free of AppKit so tests/key-routing builds
// them with a plain C compiler. HIDSupport.m and StreamViewController+MouseCapture.m call these; nothing is decided
// twice.
//
//  * Modifier masks and the Mac-modifier -> remote-modifier mapping (Windows key order: Command is the held LeftAlt,
//  #62).
//  * What a pass-through key equivalent does after the key goes down (Control+WASD sends the down only, #82).
//  * What the local key-up monitor does for an equivalent held on the host (#62, #111).

#include <stdbool.h>
#include <stdint.h>

typedef unsigned long HIDKeyboardPhysicalModifierMask;
enum {
  HIDKeyboardPhysicalModifierMaskLeftShift = 1 << 0,
  HIDKeyboardPhysicalModifierMaskRightShift = 1 << 1,
  HIDKeyboardPhysicalModifierMaskLeftControl = 1 << 2,
  HIDKeyboardPhysicalModifierMaskRightControl = 1 << 3,
  HIDKeyboardPhysicalModifierMaskLeftOption = 1 << 4,
  HIDKeyboardPhysicalModifierMaskRightOption = 1 << 5,
  HIDKeyboardPhysicalModifierMaskLeftCommand = 1 << 6,
  HIDKeyboardPhysicalModifierMaskRightCommand = 1 << 7,
};

typedef unsigned long HIDKeyboardRemoteModifierMask;
enum {
  HIDKeyboardRemoteModifierMaskLeftShift = 1 << 0,
  HIDKeyboardRemoteModifierMaskRightShift = 1 << 1,
  HIDKeyboardRemoteModifierMaskLeftControl = 1 << 2,
  HIDKeyboardRemoteModifierMaskRightControl = 1 << 3,
  HIDKeyboardRemoteModifierMaskLeftAlt = 1 << 4,
  HIDKeyboardRemoteModifierMaskRightAlt = 1 << 5,
  HIDKeyboardRemoteModifierMaskLeftMeta = 1 << 6,
  HIDKeyboardRemoteModifierMaskRightMeta = 1 << 7,
};

// The Windows virtual-key code the host receives for one remote modifier.
static inline unsigned short HIDRemoteModifierKeyCode(HIDKeyboardRemoteModifierMask mask) {
  switch (mask) {
  case HIDKeyboardRemoteModifierMaskLeftShift:
    return 0xA0;
  case HIDKeyboardRemoteModifierMaskRightShift:
    return 0xA1;
  case HIDKeyboardRemoteModifierMaskLeftControl:
    return 0xA2;
  case HIDKeyboardRemoteModifierMaskRightControl:
    return 0xA3;
  case HIDKeyboardRemoteModifierMaskLeftAlt:
    return 0xA4;
  case HIDKeyboardRemoteModifierMaskRightAlt:
    return 0xA5;
  case HIDKeyboardRemoteModifierMaskLeftMeta:
    return 0x5B;
  case HIDKeyboardRemoteModifierMaskRightMeta:
    return 0x5C;
  default:
    return 0;
  }
}

// The compatibility switches that shape the mapping, already evaluated for the event at hand.
typedef struct MLModifierPolicy {
  bool swapLeftControlAndWin;
  bool hardMapCommandToControl;
  bool translateShortcutCommandToControl;
  bool swapOptionAndCommand; // Windows key order
  bool deferredLeftCommandToControl;
  bool deferredRightCommandToControl;
} MLModifierPolicy;

// Which remote modifiers should be down for the physical modifiers held now.
static inline HIDKeyboardRemoteModifierMask MLDesiredRemoteModifierMask(HIDKeyboardPhysicalModifierMask physical,
                                                                        MLModifierPolicy p) {
  HIDKeyboardRemoteModifierMask desired = 0;
  if (physical & HIDKeyboardPhysicalModifierMaskLeftShift)
    desired |= HIDKeyboardRemoteModifierMaskLeftShift;
  if (physical & HIDKeyboardPhysicalModifierMaskRightShift)
    desired |= HIDKeyboardRemoteModifierMaskRightShift;
  if (physical & HIDKeyboardPhysicalModifierMaskLeftControl) {
    desired |=
        p.swapLeftControlAndWin ? HIDKeyboardRemoteModifierMaskLeftMeta : HIDKeyboardRemoteModifierMaskLeftControl;
  }
  if (physical & HIDKeyboardPhysicalModifierMaskRightControl)
    desired |= HIDKeyboardRemoteModifierMaskRightControl;
  if (physical & HIDKeyboardPhysicalModifierMaskLeftOption) {
    desired |= p.swapOptionAndCommand ? HIDKeyboardRemoteModifierMaskLeftMeta : HIDKeyboardRemoteModifierMaskLeftAlt;
  }
  if (physical & HIDKeyboardPhysicalModifierMaskRightOption) {
    desired |= p.swapOptionAndCommand ? HIDKeyboardRemoteModifierMaskRightMeta : HIDKeyboardRemoteModifierMaskRightAlt;
  }

  if (p.swapOptionAndCommand) {
    // Windows key order: the key beside Control sends Win, the next one Alt, like a PC keyboard.
    if (physical & HIDKeyboardPhysicalModifierMaskLeftCommand)
      desired |= HIDKeyboardRemoteModifierMaskLeftAlt;
    if (physical & HIDKeyboardPhysicalModifierMaskRightCommand)
      desired |= HIDKeyboardRemoteModifierMaskRightAlt;
    return desired;
  }

  if (physical & HIDKeyboardPhysicalModifierMaskLeftCommand) {
    desired |= (p.hardMapCommandToControl || p.swapLeftControlAndWin || p.translateShortcutCommandToControl ||
                p.deferredLeftCommandToControl)
                   ? HIDKeyboardRemoteModifierMaskLeftControl
                   : HIDKeyboardRemoteModifierMaskLeftMeta;
  }
  if (physical & HIDKeyboardPhysicalModifierMaskRightCommand) {
    desired |= (p.hardMapCommandToControl || p.translateShortcutCommandToControl || p.deferredRightCommandToControl)
                   ? HIDKeyboardRemoteModifierMaskRightControl
                   : HIDKeyboardRemoteModifierMaskRightMeta;
  }
  return desired;
}

typedef struct MLModifierEdge {
  unsigned short vk;
  bool down;
} MLModifierEdge;

typedef struct MLModifierEdgeList {
  int count;
  MLModifierEdge edges[8];
} MLModifierEdgeList;

// The key events that bring the host from `previous` to `desired`, in the fixed order shift, control, alt, meta
// (left before right). A value, so a block can capture it.
static inline MLModifierEdgeList MLModifierEdges(HIDKeyboardRemoteModifierMask previous,
                                                 HIDKeyboardRemoteModifierMask desired) {
  static const HIDKeyboardRemoteModifierMask order[8] = {
      HIDKeyboardRemoteModifierMaskLeftShift,   HIDKeyboardRemoteModifierMaskRightShift,
      HIDKeyboardRemoteModifierMaskLeftControl, HIDKeyboardRemoteModifierMaskRightControl,
      HIDKeyboardRemoteModifierMaskLeftAlt,     HIDKeyboardRemoteModifierMaskRightAlt,
      HIDKeyboardRemoteModifierMaskLeftMeta,    HIDKeyboardRemoteModifierMaskRightMeta,
  };
  HIDKeyboardRemoteModifierMask changed = previous ^ desired;
  MLModifierEdgeList list;
  list.count = 0;
  for (int i = 0; i < 8; i++) {
    if ((changed & order[i]) == 0)
      continue;
    unsigned short vk = HIDRemoteModifierKeyCode(order[i]);
    if (vk == 0)
      continue;
    list.edges[list.count].vk = vk;
    list.edges[list.count].down = (desired & order[i]) != 0;
    list.count++;
  }
  return list;
}

// A key equivalent that no shortcut of ours took goes to the host as a key down. What follows:
// Function keys and Windows-order Command chords wait for the local key-up monitor.
// Other Control chords wait for the ordinary responder key-up (#82).
// The remaining equivalents, including the synthetic Caps Lock press, are taps.
typedef struct MLPassThroughPlan {
  bool keyUpNow;
  bool holdUntilKeyUp;
} MLPassThroughPlan;

static inline MLPassThroughPlan MLPassThroughChordPlan(bool controlHeld, bool commandHeld, bool windowsKeyOrder,
                                                       bool functionKey) {
  bool trackRelease = functionKey || (windowsKeyOrder && commandHeld);
  MLPassThroughPlan plan = {!controlHeld && !trackRelease, trackRelease};
  return plan;
}

#ifdef __OBJC__
#import <AppKit/AppKit.h>

// Apple documents the Function flag on navigation and F keys, and reserves the
// function-key Unicode range. Check both so Fn with a printable key still
// follows the ordinary shortcut policy (macos-apple-nsevent-function-20261120
// and macos-apple-function-key-unicode-20261120, Discussion).
static inline MLPassThroughPlan MLPassThroughPlanForKeyEquivalent(NSEvent *event, bool windowsKeyOrder) {
  // See macos-apple-nsevent-modifiers-20261120 and
  // macos-apple-nsevent-unmodified-characters-20261120 (Discussion).
  NSEventModifierFlags flags = event.modifierFlags;
  BOOL functionKey = NO;
  if (flags & NSEventModifierFlagFunction) {
    NSString *characters = event.charactersIgnoringModifiers;
    if (characters.length == 1) {
      unichar character = [characters characterAtIndex:0];
      functionKey = character >= NSUpArrowFunctionKey && character <= 0xF8FF;
    }
  }
  return MLPassThroughChordPlan((flags & NSEventModifierFlagControl) != 0, (flags & NSEventModifierFlagCommand) != 0,
                                windowsKeyOrder, functionKey);
}
#endif

typedef enum MLHeldKeyUpAction {
  MLHeldKeyUpLetThrough = 0,      // not ours: the event goes on down the responder chain
  MLHeldKeyUpForgetAndLetThrough, // the hold is dropped without sending anything
  MLHeldKeyUpSendAndConsume,      // the up goes to the host and the event stops here
} MLHeldKeyUpAction;

// The local key-up monitor releases the key by key code even if its modifiers changed.
static inline MLHeldKeyUpAction MLHeldKeyUpDecision(bool eventForThisWindow, bool inputEnabled, bool keyIsHeld) {
  if (!eventForThisWindow || !inputEnabled)
    return MLHeldKeyUpForgetAndLetThrough;
  if (!keyIsHeld)
    return MLHeldKeyUpLetThrough;
  return MLHeldKeyUpSendAndConsume;
}
