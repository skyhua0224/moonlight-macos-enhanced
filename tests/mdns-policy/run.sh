#!/bin/sh
# Compiles the real Limelight/Network/MDNSManager.m with a fake Bonjour browser and stubs for its Swift/Core Data
# neighbours, then runs the cases in main.m (switch off => no Bonjour at all, window hidden => no restarts, ...).
set -e
dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$dir/../.." && pwd)
out=${TMPDIR:-/tmp}/mdns-policy-test.$$
xcrun clang -fobjc-arc -Wall -Wno-objc-method-access -include "$dir/stubs/prefix.h" -I "$dir/stubs" -I "$root/Limelight/Network" \
  -framework Foundation -framework AppKit -o "$out" \
  "$root/Limelight/Network/MDNSManager.m" "$dir/stubs/stubs.m" "$dir/main.m"
"$out"
status=$?
rm -f "$out"
exit $status
