#!/bin/sh
# Compiles the real Limelight/macOS/Helpers/AwdlHoldLedger.m (the part of the privileged helper that decides who keeps
# awdl0 down and when it comes back) with a fake interface, and runs the cases in main.m. The helper itself is
# compiled, as a syntax check, by the second command; it needs root to do anything, so it is not run.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$dir/../.." && pwd)
helpers="$root/Limelight/macOS/Helpers"
out=${TMPDIR:-/tmp}/awdl-hold-ledger-test.$$
xcrun clang -fobjc-arc -Wall -Wextra -I "$helpers" -framework Foundation -o "$out" "$helpers/AwdlHoldLedger.m" "$dir/main.m"
status=0
"$out" || status=$?
rm -f "$out"
xcrun clang -fobjc-arc -Wall -c -I "$helpers" -o /dev/null "$helpers/AwdlPrivilegedHelperMain.m"
exit $status
