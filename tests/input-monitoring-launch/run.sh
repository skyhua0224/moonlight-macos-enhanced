#!/bin/sh
# Builds and runs the launch-time Input Monitoring rules test with swiftc. Production code:
# Limelight/macOS/Helpers/InputMonitoringLaunchPrompt.swift (Foundation only).
set -e
dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$dir/../.." && pwd)
out=${TMPDIR:-/tmp}/input-monitoring-launch-test.$$
swiftc -O -o "$out" "$root/Limelight/macOS/Helpers/InputMonitoringLaunchPrompt.swift" "$dir/main.swift"
status=0
"$out" || status=$?
rm -rf "$out"
exit $status
