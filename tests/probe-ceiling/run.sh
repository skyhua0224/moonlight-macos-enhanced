#!/bin/sh
# Compiles BandwidthProbeRules.swift and DeckRules.swift (Foundation only) with the tests and runs them.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$dir/../.." && pwd)
out=${TMPDIR:-/tmp}/probe-ceiling-test.$$
xcrun swiftc -O -o "$out" "$root/Limelight/macOS/ViewControllers/BandwidthProbeRules.swift" \
  "$root/Limelight/macOS/ViewControllers/DeckRules.swift" "$dir/main.swift"
"$out"
status=$?
rm -f "$out"
exit $status
