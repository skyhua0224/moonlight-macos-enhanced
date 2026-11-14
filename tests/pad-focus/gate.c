// The press gate of the pad poll (ControllerPressGate.h): a button held through a window change stays silent.
#include <stdio.h>
#include <stdint.h>
#include "ControllerPressGate.h"

static int failures = 0;
static void check(const char *name, int ok) {
    if (!ok) failures++;
    printf("%s %s\n", ok ? "PASS" : "FAIL", name);
}

enum { A = 1 << 4, B = 1 << 5, Y = 1 << 11 };

int main(void) {
    uint32_t blocked = 0;
    check("a new press acts", ControllerPressGatePressed(B, 0, false, &blocked) == B);

    // B closes the settings window: the poll that sees the new window has B still down, and the pad's state was
    // refreshed (previous has B) or not (previous is stale and lacks B): neither may act
    blocked = 0;
    check("press on the poll of the window change is swallowed", ControllerPressGatePressed(B, 0, true, &blocked) == 0);
    check("... and stays swallowed while it is held (stale state, no edge seen)", ControllerPressGatePressed(B, 0, false, &blocked) == 0);
    check("... still while held", ControllerPressGatePressed(B, B, false, &blocked) == 0);
    check("released: nothing", ControllerPressGatePressed(0, B, false, &blocked) == 0);
    check("the next real press of the same button acts", ControllerPressGatePressed(B, 0, false, &blocked) == B);

    // another button pressed while B is still held after the change acts at once
    blocked = 0;
    ControllerPressGatePressed(B, 0, true, &blocked);
    check("a different button pressed while the old one is held acts", ControllerPressGatePressed(B | A, B, false, &blocked) == A);
    check("the held one stays silent", (blocked & B) != 0);

    // a release that happens between two polls of a changed window is seen
    blocked = 0;
    ControllerPressGatePressed(Y, 0, true, &blocked);
    ControllerPressGatePressed(0, Y, false, &blocked);
    check("release clears the block", blocked == 0);
    check("a press after the release acts", ControllerPressGatePressed(Y, 0, false, &blocked) == Y);

    // held buttons without a change are the ordinary edge: no repeat
    blocked = 0;
    check("held without a change: no second press", ControllerPressGatePressed(A, A, false, &blocked) == 0);

    printf(failures == 0 ? "all passed\n" : "%d FAILED\n", failures);
    return failures == 0 ? 0 : 1;
}
