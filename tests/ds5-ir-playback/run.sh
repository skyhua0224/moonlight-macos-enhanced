#!/bin/sh
# Builds and runs the DualSense IR playback test. Needs only a C compiler.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
out=${TMPDIR:-/tmp}/ds5-ir-playback-test.$$
${CC:-cc} -std=c11 -Wall -Wextra -Werror -O1 -o "$out" "$dir/test_ds5_ir_playback.c" -lm
"$out"
rm -f "$out"
