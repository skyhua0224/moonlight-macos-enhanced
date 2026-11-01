#!/bin/sh
# Builds and runs the DualSense motion mapping test. Needs only a C compiler.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
out=${TMPDIR:-/tmp}/ds5-motion-test.$$
${CC:-cc} -std=c11 -Wall -Wextra -Werror -O1 -o "$out" "$dir/test_ds5_motion.c" -lm
"$out"
rm -f "$out"
