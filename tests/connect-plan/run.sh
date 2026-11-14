#!/bin/sh
# Compiles DeckConnectPlan.swift on its own (Foundation only) with the test cases and runs them.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$dir/../.." && pwd)
out=${TMPDIR:-/tmp}/connect-plan-test.$$
xcrun swiftc -O -o "$out" "$root/Limelight/macOS/ViewControllers/DeckConnectPlan.swift" "$dir/main.swift"
"$out"
status=$?
rm -f "$out"
exit $status
