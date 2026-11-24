#!/bin/sh
# Compiles UpdateVersionPolicy.swift (Foundation only) on its own with the test cases and runs them.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$dir/../.." && pwd)
out=${TMPDIR:-/tmp}/update-version-policy-test.$$
xcrun swiftc -O -o "$out" "$root/Limelight/macOS/Helpers/UpdateVersionPolicy.swift" "$dir/main.swift"
status=0
"$out" || status=$?
rm -f "$out"
exit $status
