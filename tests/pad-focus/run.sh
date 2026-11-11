#!/bin/sh
# Compiles the pure pad-focus rules (ControllerFocusRules.swift, Foundation only; ControllerPressGate.h, plain C) with their tests and runs them.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$dir/../.." && pwd)
out=${TMPDIR:-/tmp}/pad-focus-test.$$
xcrun swiftc -O -o "$out.swift" "$root/Limelight/macOS/ViewControllers/ControllerFocusRules.swift" "$dir/main.swift"
xcrun clang -O1 -Wall -Werror -I "$root/Limelight/macOS/Helpers" -o "$out.c" "$dir/gate.c"
status=0
"$out.swift" || status=1
"$out.c" || status=1
rm -f "$out.swift" "$out.c"
exit $status
