// Keyboard-path rules (#82 Control+WASD, #62 Command as held LeftAlt in Windows key order, #81 sheet close).
#include <stdio.h>
#include <string.h>
#include "KeyboardRouting.h"
#include "SheetCloseRules.h"

static int failures = 0;
static void check(const char *name, bool ok) {
    if (!ok) failures++;
    printf("%s %s\n", ok ? "PASS" : "FAIL", name);
}

static MLModifierPolicy windowsOrder(void) {
    MLModifierPolicy p; memset(&p, 0, sizeof p); p.swapOptionAndCommand = true; return p;
}
static MLModifierPolicy standard(void) { MLModifierPolicy p; memset(&p, 0, sizeof p); return p; }

// What the host sees: a tiny model of HIDSupport.flagsChanged (previous remote mask, edges, new mask) and of the key sends.
typedef struct { unsigned short vk; bool down; } Sent;
typedef struct { Sent log[64]; int n; HIDKeyboardRemoteModifierMask remote; unsigned heldKeys[16]; int heldN; } Host;

static void hostModifiers(Host *h, HIDKeyboardPhysicalModifierMask physical, MLModifierPolicy p) {
    HIDKeyboardRemoteModifierMask desired = MLDesiredRemoteModifierMask(physical, p);
    MLModifierEdgeList list = MLModifierEdges(h->remote, desired);
    for (int i = 0; i < list.count; i++) { h->log[h->n].vk = list.edges[i].vk; h->log[h->n].down = list.edges[i].down; h->n++; }
    h->remote = desired;
}
static void hostKey(Host *h, unsigned short vk, bool down) { h->log[h->n].vk = vk; h->log[h->n].down = down; h->n++; }
static bool lastIs(const Host *h, unsigned short vk, bool down) { return h->n > 0 && h->log[h->n-1].vk == vk && h->log[h->n-1].down == down; }
static int countOf(const Host *h, unsigned short vk, bool down) {
    int c = 0; for (int i = 0; i < h->n; i++) if (h->log[i].vk == vk && h->log[i].down == down) c++; return c;
}

static void passThrough(Host *h, unsigned short vk, bool control, bool command, bool windows, bool *held) {
    // the path of onKeyboardEquivalent after no shortcut took the event
    hostKey(h, vk, true);
    MLPassThroughPlan plan = MLPassThroughChordPlan(control, command, windows);
    if (plan.keyUpNow) hostKey(h, vk, false);
    *held = plan.holdUntilKeyUp;
}

int main(void) {
    // ---- #82 Control+WASD
    { MLPassThroughPlan p = MLPassThroughChordPlan(true, false, false);
      check("#82 Control+key: no key up with the down (the key stays held while it is held)", !p.keyUpNow && !p.holdUntilKeyUp); }
    { MLPassThroughPlan p = MLPassThroughChordPlan(false, false, false);
      check("#82 plain key equivalent: down and up at once", p.keyUpNow && !p.holdUntilKeyUp); }
    { MLPassThroughPlan p = MLPassThroughChordPlan(true, false, true);
      check("#82 Control+key in Windows key order: still only the down", !p.keyUpNow && !p.holdUntilKeyUp); }
    { MLPassThroughPlan p = MLPassThroughChordPlan(false, true, false);
      check("Command chord (standard order): down and up at once", p.keyUpNow && !p.holdUntilKeyUp); }
    { Host h; memset(&h, 0, sizeof h); bool held = false;
      hostModifiers(&h, HIDKeyboardPhysicalModifierMaskLeftControl, standard());
      passThrough(&h, 0x57 /* W */, true, false, false, &held);
      check("#82 Control held then W: host got Ctrl down, W down, and nothing more", h.n == 2 && lastIs(&h, 0x57, true) && countOf(&h, 0x57, false) == 0);
      hostKey(&h, 0x57, false);   // the ordinary key-up path when the user lets go
      check("#82 W released later: exactly one W up", countOf(&h, 0x57, false) == 1 && countOf(&h, 0x57, true) == 1); }
    { Host h; memset(&h, 0, sizeof h); bool held = false; int downs = 0;
      hostModifiers(&h, HIDKeyboardPhysicalModifierMaskLeftControl, standard());
      // key repeat of W while Control is held: each repeat is a key equivalent again
      for (int i = 0; i < 5; i++) { passThrough(&h, 0x57, true, false, false, &held); downs++; }
      check("#82 repeating W under Control sends repeats of the down only", countOf(&h, 0x57, true) == downs && countOf(&h, 0x57, false) == 0); }

    // ---- #62 Command as LeftAlt in Windows key order
    { MLModifierPolicy w = windowsOrder();
      check("#62 Left Command is LeftAlt", MLDesiredRemoteModifierMask(HIDKeyboardPhysicalModifierMaskLeftCommand, w) == HIDKeyboardRemoteModifierMaskLeftAlt);
      check("#62 Right Command is RightAlt", MLDesiredRemoteModifierMask(HIDKeyboardPhysicalModifierMaskRightCommand, w) == HIDKeyboardRemoteModifierMaskRightAlt);
      check("#62 Left Option is LeftMeta (Win)", MLDesiredRemoteModifierMask(HIDKeyboardPhysicalModifierMaskLeftOption, w) == HIDKeyboardRemoteModifierMaskLeftMeta);
      check("#62 Right Option is RightMeta", MLDesiredRemoteModifierMask(HIDKeyboardPhysicalModifierMaskRightOption, w) == HIDKeyboardRemoteModifierMaskRightMeta);
      check("#62 Control stays Control", MLDesiredRemoteModifierMask(HIDKeyboardPhysicalModifierMaskLeftControl, w) == HIDKeyboardRemoteModifierMaskLeftControl);
      check("#62 Command ignores deferred/translation flags in this mode",
            ({ MLModifierPolicy q = w; q.translateShortcutCommandToControl = true; q.deferredLeftCommandToControl = true; q.hardMapCommandToControl = true;
               MLDesiredRemoteModifierMask(HIDKeyboardPhysicalModifierMaskLeftCommand, q) == HIDKeyboardRemoteModifierMaskLeftAlt; })); }
    { MLModifierPolicy s = standard();
      check("standard order: Command is Win", MLDesiredRemoteModifierMask(HIDKeyboardPhysicalModifierMaskLeftCommand, s) == HIDKeyboardRemoteModifierMaskLeftMeta);
      check("standard order: Option is Alt", MLDesiredRemoteModifierMask(HIDKeyboardPhysicalModifierMaskLeftOption, s) == HIDKeyboardRemoteModifierMaskLeftAlt);
      MLModifierPolicy t = s; t.hardMapCommandToControl = true;
      check("Command-to-Control mode: Command is Control", MLDesiredRemoteModifierMask(HIDKeyboardPhysicalModifierMaskLeftCommand, t) == HIDKeyboardRemoteModifierMaskLeftControl);
      MLModifierPolicy u = s; u.swapLeftControlAndWin = true;
      check("swap Control/Win: Control is Win, Command is Control",
            MLDesiredRemoteModifierMask(HIDKeyboardPhysicalModifierMaskLeftControl, u) == HIDKeyboardRemoteModifierMaskLeftMeta &&
            MLDesiredRemoteModifierMask(HIDKeyboardPhysicalModifierMaskLeftCommand, u) == HIDKeyboardRemoteModifierMaskLeftControl); }
    { Host h; memset(&h, 0, sizeof h); MLModifierPolicy w = windowsOrder();
      hostModifiers(&h, HIDKeyboardPhysicalModifierMaskLeftCommand, w);
      check("#62 Command down: one LeftAlt (0xA4) key down, held", h.n == 1 && lastIs(&h, 0xA4, true));
      hostModifiers(&h, HIDKeyboardPhysicalModifierMaskLeftCommand, w);   // a repeated flagsChanged with the same state
      check("#62 same state again: nothing new is sent", h.n == 1);
      hostModifiers(&h, 0, w);
      check("#62 Command up: LeftAlt released", h.n == 2 && lastIs(&h, 0xA4, false)); }
    { Host h; memset(&h, 0, sizeof h); MLModifierPolicy w = windowsOrder(); bool held = false;
      // Command held, then Tab: the Alt+Tab of a PC keyboard
      hostModifiers(&h, HIDKeyboardPhysicalModifierMaskLeftCommand, w);
      passThrough(&h, 0x09 /* Tab */, false, true, true, &held);
      check("#62 Command+Tab: Alt down, Tab down, Tab stays held (no up yet), Alt still down",
            countOf(&h, 0xA4, true) == 1 && countOf(&h, 0xA4, false) == 0 && countOf(&h, 0x09, true) == 1 && countOf(&h, 0x09, false) == 0 && held);
      MLHeldKeyUpAction a = MLHeldKeyUpDecision(true, true, true, held);
      check("#62 Tab key up: the monitor sends it and consumes the event", a == MLHeldKeyUpSendAndConsume);
      hostKey(&h, 0x09, false);
      hostModifiers(&h, 0, w);
      check("#62 then Command up: Alt released after Tab", lastIs(&h, 0xA4, false) && countOf(&h, 0x09, false) == 1);
      check("#62 a second Tab up is not ours any more", MLHeldKeyUpDecision(true, true, true, false) == MLHeldKeyUpLetThrough); }
    { MLHeldKeyUpAction a;
      a = MLHeldKeyUpDecision(true, true, true, true);
      check("held-key up: held in Windows order and input on: send and consume", a == MLHeldKeyUpSendAndConsume);
      a = MLHeldKeyUpDecision(true, true, true, false);
      check("held-key up: not held: let it through", a == MLHeldKeyUpLetThrough);
      a = MLHeldKeyUpDecision(true, false, true, true);
      check("held-key up: input off: forget the hold, let through", a == MLHeldKeyUpForgetAndLetThrough);
      a = MLHeldKeyUpDecision(true, true, false, true);
      check("held-key up: mode left Windows order while held: forget, let through", a == MLHeldKeyUpForgetAndLetThrough);
      a = MLHeldKeyUpDecision(false, true, true, true);
      check("held-key up: event of another window: forget, let through", a == MLHeldKeyUpForgetAndLetThrough); }

    // ---- modifier edge order and combinations
    { MLModifierEdgeList l = MLModifierEdges(0, HIDKeyboardRemoteModifierMaskLeftShift | HIDKeyboardRemoteModifierMaskLeftAlt | HIDKeyboardRemoteModifierMaskLeftControl);
      check("edges come in shift, control, alt order", l.count == 3 && l.edges[0].vk == 0xA0 && l.edges[1].vk == 0xA2 && l.edges[2].vk == 0xA4 && l.edges[0].down && l.edges[1].down && l.edges[2].down);
      l = MLModifierEdges(HIDKeyboardRemoteModifierMaskLeftAlt | HIDKeyboardRemoteModifierMaskRightMeta, HIDKeyboardRemoteModifierMaskRightMeta);
      check("only the changed modifier is sent", l.count == 1 && l.edges[0].vk == 0xA4 && !l.edges[0].down);
      check("no change, no edges", MLModifierEdges(HIDKeyboardRemoteModifierMaskLeftAlt, HIDKeyboardRemoteModifierMaskLeftAlt).count == 0); }

    // ---- #81 sheet close
    { MLSheetClosePlan p = MLSheetClose(true, true, true);
      check("#81 presented by a controller: dismiss through it, and tell SwiftUI", p.route == MLSheetCloseViaPresenter && p.notifyCloseHandler); }
    { MLSheetClosePlan p = MLSheetClose(false, true, true);
      check("#81 SwiftUI sheet host: end the sheet on its parent window, and tell SwiftUI", p.route == MLSheetCloseViaSheetParent && p.notifyCloseHandler); }
    { MLSheetClosePlan p = MLSheetClose(false, false, true);
      check("#81 no route left (already gone): nothing to end, SwiftUI still told so the dialog can open again", p.route == MLSheetCloseNoWindowRoute && p.notifyCloseHandler); }
    { MLSheetClosePlan p = MLSheetClose(true, false, false);
      check("#81 no handler (opened from AppKit): no notification", !p.notifyCloseHandler); }

    printf("%s\n", failures == 0 ? "ALL PASS" : "FAILURES");
    return failures == 0 ? 0 : 1;
}
