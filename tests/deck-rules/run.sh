#!/bin/sh
# Compiles the pure rules (DeckRules.swift: time, art, address book, path classes; Foundation only) with their tests and runs them.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$dir/../.." && pwd)
out=${TMPDIR:-/tmp}/deck-rules-test.$$
xcrun swiftc -O -o "$out" "$root/Limelight/macOS/ViewControllers/DeckRules.swift" "$dir/main.swift"
"$out"
status=$?
rm -f "$out"
exit $status
