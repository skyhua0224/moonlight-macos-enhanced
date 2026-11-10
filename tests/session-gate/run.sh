#!/bin/sh
# Builds and runs the session handle lifecycle test (stop or reconnect while the
# stream health timer is pending) with AddressSanitizer.
# SESSION_GATE_TEST_LEGACY=1 runs the timer the old way (process-wide LiRequestIdrFrame(),
# no gate); it is expected to fail with a use-after-free or a request on a stopped stream.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$dir/../.." && pwd)
common="$root/moonlight-common/moonlight-common-c/src"
out=${TMPDIR:-/tmp}/session-gate-test.$$
${CC:-cc} -std=c11 -Wall -Wextra -Werror -O1 -g -pthread -fsanitize=address \
    -I"$common" -I"$root/Limelight/Stream" \
    -o "$out" "$dir/test_session_gate.c" "$common/LinkedBlockingQueue.c"
status=0
"$out" || status=$?
rm -rf "$out" "$out.dSYM"
exit $status
