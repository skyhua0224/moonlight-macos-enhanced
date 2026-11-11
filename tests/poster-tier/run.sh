#!/bin/sh
# Compiles PosterTier.swift (Foundation only) on its own with the test cases and runs them.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$dir/../.." && pwd)
out=${TMPDIR:-/tmp}/poster-tier-test.$$
xcrun swiftc -O -o "$out" "$root/Limelight/macOS/ViewControllers/PosterTier.swift" "$dir/main.swift"
"$out"
status=$?
rm -f "$out"
exit $status
