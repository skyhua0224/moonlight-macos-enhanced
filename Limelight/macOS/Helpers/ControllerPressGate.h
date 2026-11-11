//
//  ControllerPressGate.h
//  A press that was held while the window under the pad changed (a settings window or a sheet closed by that very
//  press, a stream ending) is not a press in the next window: its bits stay blocked until the button is released.
//  Plain C, so tests/pad-focus compiles it on its own.
//

#ifndef ControllerPressGate_h
#define ControllerPressGate_h

#include <stdint.h>
#include <stdbool.h>

/// - buttons: the buttons down now; previous: the buttons down at the last poll;
///   windowChanged: the window that gets the pad is another one than at the last poll;
///   blocked: per pad, the bits that stay silent until released.
/// Returns the buttons that went down at this poll and may act.
static inline uint32_t ControllerPressGatePressed(uint32_t buttons, uint32_t previous, bool windowChanged, uint32_t *blocked) {
    if (windowChanged) {
        *blocked |= buttons;
    }
    *blocked &= buttons;
    return buttons & ~previous & ~*blocked;
}

#endif
