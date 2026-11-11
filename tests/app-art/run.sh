#!/bin/sh
# Compiles AppArtPolicy.swift (Foundation only) on its own with the test cases and runs them.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$dir/../.." && pwd)
out=${TMPDIR:-/tmp}/app-art-test.$$
xcrun swiftc -O -o "$out" "$root/Limelight/macOS/ViewControllers/AppArtPolicy.swift" "$dir/main.swift"
"$out"
status=$?
rm -f "$out"
exit $status
