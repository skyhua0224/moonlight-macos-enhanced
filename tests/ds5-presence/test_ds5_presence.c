#include "../../Limelight/Input/DS5PadPresence.h"

#include <stdio.h>

static int failures;

#define CHECK(condition) \
    do { \
        if (!(condition)) { \
            fprintf(stderr, "%s:%d: check failed: %s\n", __FILE__, __LINE__, #condition); \
            failures++; \
        } \
    } while (0)

int main(void) {
    // No pad: the active mask is empty, so no virtual pad exists on the host.
    CHECK(ds5_pad_active_mask(0) == 0);
    // One pad as player 0 and two pads as players 0 and 2.
    CHECK(ds5_pad_active_mask(0x1) == 0x1);
    CHECK(ds5_pad_active_mask(0x5) == 0x5);
    // Unplugging player 0 clears its bit: the removal packet carries 0, not a constant 1.
    CHECK(ds5_pad_active_mask(0x1 & ~0x1u) == 0);
    CHECK(ds5_pad_active_mask(0x3 & ~0x1u) == 0x2);
    // Bits above the fourth player are never sent.
    CHECK(ds5_pad_active_mask(0xff) == 0xf);

    // Numbers: lowest free, and a pad that comes back keeps its number when that is free.
    CHECK(ds5_pad_choose_number(0, -1) == 0);
    CHECK(ds5_pad_choose_number(0x1, -1) == 1);
    CHECK(ds5_pad_choose_number(0x0, 1) == 1);       // pad 2 unplugged and replugged first: still player 2
    CHECK(ds5_pad_choose_number(0x2, 1) == 0);       // its number is taken: lowest free
    CHECK(ds5_pad_choose_number(0xf, 0) == -1);
    CHECK(ds5_pad_choose_number(0x7, 9) == 3);       // an out-of-range memory is ignored

    // A neutral event for a pad that is gone or unknown to the host would create it.
    CHECK(!ds5_pad_may_send(false, true));
    CHECK(!ds5_pad_may_send(true, false));
    CHECK(ds5_pad_may_send(true, true));
    // The HID driver says nothing until a real HID pad delivered a report: this is the packet that made a
    // virtual pad appear on the host for a Mac with no pad at all.
    CHECK(!ds5_hid_may_send(false));
    CHECK(ds5_hid_may_send(true));

    // A callback finds its controller by identity. GameController's player number is rewritten for the LED
    // pattern (down to -1) and reset by a reconnect; the old lookup by that number found nothing, and the
    // update for "nothing" announced player 0 again on every callback.
    int padA = 0, padB = 0, stranger = 0;
    const void *owners[4] = { &padA, NULL, &padB, NULL };
    CHECK(ds5_pad_slot_for_identity(owners, 4, &padA) == 0);
    CHECK(ds5_pad_slot_for_identity(owners, 4, &padB) == 2);
    CHECK(ds5_pad_slot_for_identity(owners, 4, &stranger) == -1);
    CHECK(ds5_pad_slot_for_identity(owners, 4, NULL) == -1);
    owners[0] = NULL;  // the pad was removed
    CHECK(ds5_pad_slot_for_identity(owners, 4, &padA) == -1);

    // Replay of the flood: 100 callbacks for one pad, the player number having been reset to -1. By number the
    // slot is never found (every callback would announce); by identity it is found every time.
    int found_by_number = 0, found_by_identity = 0;
    for (int callback = 0; callback < 100; callback++) {
        const int gc_player_index = -1;
        if (gc_player_index >= 0 && gc_player_index < 4 && owners[gc_player_index] != NULL) found_by_number++;
        if (ds5_pad_slot_for_identity(owners, 4, &padB) >= 0) found_by_identity++;
    }
    CHECK(found_by_number == 0);
    CHECK(found_by_identity == 100);
    return failures == 0 ? 0 : 1;
}
