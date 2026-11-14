#!/bin/sh
# Builds and runs the DualSense output mapping test against the ds5 core report builder.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
root=$dir/../..
out=${TMPDIR:-/tmp}/ds5-output-test.$$
${CC:-cc} -std=c11 -Wall -Wextra -Werror -O1 \
  -I"$root/moonlight-common/moonlight-common-c/src" \
  -I"$root/core/interaction/ds5-core/include" \
  -o "$out" "$dir/test_ds5_output.c" "$root/core/interaction/ds5-core/src/ds5_core.c" -lm
"$out"
rm -f "$out"
