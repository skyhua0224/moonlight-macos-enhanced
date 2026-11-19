#!/bin/sh
# Builds and runs the non-blocking permission alert check with swiftc. It opens windows, so it needs a window server
# session (a Mac with a user logged in); it is not part of CI. Production code:
# Limelight/macOS/Helpers/InputMonitoringLaunchPrompt.swift.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$dir/../.." && pwd)
out=${TMPDIR:-/tmp}/permission-alert-nonblocking-test.$$
swiftc -O -o "$out" "$root/Limelight/macOS/Helpers/InputMonitoringLaunchPrompt.swift" "$dir/main.swift"
status=0
"$out" || status=$?
rm -rf "$out"
exit $status
