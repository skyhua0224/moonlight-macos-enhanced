#!/bin/sh
# Builds and runs the DualSense Mute button parse and merge test against the ds5 core parsers.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
root=$dir/../..
out=${TMPDIR:-/tmp}/ds5-buttons-test.$$
${CC:-cc} -std=c11 -Wall -Wextra -Werror -O1 \
  -I"$root/moonlight-common/moonlight-common-c/src" \
  -I"$root/core/interaction/ds5-core/include" \
  -o "$out" "$dir/test_ds5_buttons.c" "$root/core/interaction/ds5-core/src/ds5_core.c" -lm
"$out"
rm -f "$out"
