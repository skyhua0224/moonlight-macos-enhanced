#!/bin/sh
# Compiles HostSessionPolicy.swift (Foundation only) on its own with the test cases and runs them.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$dir/../.." && pwd)
out=${TMPDIR:-/tmp}/host-session-test.$$
xcrun swiftc -O -o "$out" "$root/Limelight/macOS/ViewControllers/HostSessionPolicy.swift" "$dir/main.swift"
"$out"
status=$?
rm -f "$out"
exit $status
