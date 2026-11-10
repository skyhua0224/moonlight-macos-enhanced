#!/bin/sh
# Builds and runs the touch tests on macOS:
#   test_touch_core.m   coordinate mapping, pointer id lifecycle, forwarder, fallback selection by host flags,
#                       fallback pointer emulator, mouse emulation gate (Foundation only)
#   test_recognizer.m   the production recognizer driven by fake direct touches (AppKit, no window server needed)
#   dump_wire_sequences.m  writes the wire events of 1..10 finger gestures to $TOUCH_WIRE_DUMP (for host-replay/)
# No touch hardware and no host are involved.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$dir/../.." && pwd)
common="$root/moonlight-common/moonlight-common-c/src"
out=${TMPDIR:-/tmp}/touch-test.$$
CC=${CC:-xcrun clang}
COMMON="-std=gnu11 -fobjc-arc -Wall -Wextra -Werror -Wno-unused-parameter -O1 -g -fsanitize=address,undefined \
    -I$common -I$root/Limelight/Input -I$root/Limelight/macOS/Views"
status=0
$CC $COMMON -framework Foundation -framework CoreGraphics \
    -o "$out.core" "$dir/test_touch_core.m" "$root/Limelight/Input/MLTouchCore.m"
"$out.core" || status=1
$CC $COMMON -framework Cocoa \
    -o "$out.rec" "$dir/test_recognizer.m" "$root/Limelight/macOS/Views/MLDirectTouchRecognizer.m" "$root/Limelight/Input/MLTouchCore.m"
"$out.rec" || status=1
# The control ball's frame on every display size and dock side (header-only, Foundation + CoreGraphics).
$CC $COMMON -framework Foundation -framework CoreGraphics \
    -o "$out.geo" "$dir/test_edge_menu_geometry.m"
"$out.geo" || status=1
# The wire events the production forwarder makes for 1..10 fingers: host-replay/run.sh feeds them to Sunshine.
$CC $COMMON -framework Foundation -framework CoreGraphics \
    -o "$out.dump" "$dir/dump_wire_sequences.m" "$root/Limelight/Input/MLTouchCore.m"
"$out.dump" "${TOUCH_WIRE_DUMP:-$out.wire}" || status=1
rm -rf "$out".core* "$out".rec* "$out".dump* "$out".geo*
[ -n "$TOUCH_WIRE_DUMP" ] || rm -f "$out.wire"
exit $status
