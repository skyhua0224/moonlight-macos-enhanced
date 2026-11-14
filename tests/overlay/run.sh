#!/bin/sh
# Compiles the overlay's warning rules and row planner (OverlayHealth.swift) and the stream shortcut table
# (SettingsShortcuts.swift, OverlayShortcutRules.swift) on their own with the test cases, and runs them on real [perf] lines.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$dir/../.." && pwd)
out=${TMPDIR:-/tmp}/overlay-test.$$
xcrun swiftc -O -o "$out" "$root/Limelight/macOS/ViewControllers/OverlayHealth.swift" \
  "$root/Limelight/macOS/ViewControllers/SettingsShortcuts.swift" "$root/Limelight/macOS/ViewControllers/OverlayShortcutRules.swift" "$dir/main.swift"
"$out" "$dir/perf-sample.txt"
status=$?
rm -f "$out"
exit $status
