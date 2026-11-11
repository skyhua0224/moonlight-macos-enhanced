#!/bin/sh
# Compiles HostEventsRules.swift and DeckRules.swift (Foundation only) with the capability 1 and capability 2 serverinfo fixtures
# (tests/fixtures/host-cap*.xml) and the tests, and runs them.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$dir/../.." && pwd)
out=${TMPDIR:-/tmp}/host-events-test.$$
xcrun swiftc -O -o "$out" "$root/Limelight/macOS/ViewControllers/HostEventsRules.swift" \
  "$root/Limelight/macOS/ViewControllers/DeckRules.swift" "$dir/main.swift"
"$out" "$root/tests/fixtures"
status=$?
rm -f "$out"
exit $status
