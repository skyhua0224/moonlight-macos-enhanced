#!/bin/sh
# Builds and runs the DualSense raw output coalescer test (pacing, merging, duplicate filter, writer isolation).
# DS5_TEST_LEGACY=1 runs the same checks against the behaviour before the output queue (no pacing, no
# duplicate filter, writes on the input queue); they are expected to fail.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
out=${TMPDIR:-/tmp}/ds5-outqueue-test.$$
${CC:-cc} -std=c11 -Wall -Wextra -Werror -O1 -pthread -o "$out" "$dir/test_ds5_outqueue.c"
status=0
"$out" || status=$?
rm -f "$out"
exit $status
