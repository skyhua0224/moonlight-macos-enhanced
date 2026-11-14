#!/bin/sh
# Compiles the overlay model and views (StreamOverlay.swift, StreamOverlayViews.swift) with stand-ins for the string lookup
# and runs the layout checks on the real views: width independent of values, fixed anchors, wrapping.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$dir/../../.." && pwd)
vc="$root/Limelight/macOS/ViewControllers"
out=${TMPDIR:-/tmp}/overlay-layout-test.$$
xcrun swiftc -O -o "$out" "$vc/OverlayHealth.swift" "$vc/StreamOverlay.swift" "$vc/StreamOverlayViews.swift" \
  "$dir/stubs.swift" "$dir/main.swift"
"$out"
status=$?
rm -f "$out"
exit $status
