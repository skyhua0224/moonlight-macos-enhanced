#!/bin/sh
# Builds and runs the frame-rate meter test with a plain C compiler. Production code:
# Limelight/Stream/MLFpsMeter.h, the same header VideoDecoderRenderer.m uses.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$dir/../.." && pwd)
out=${TMPDIR:-/tmp}/fps-meter-test.$$
${CC:-cc} -std=c11 -Wall -Wextra -Werror -O1 -g -fsanitize=address,undefined \
    -I"$root/Limelight/Stream" -o "$out" "$dir/test_fps_meter.c" -lm
status=0
"$out" || status=$?
rm -rf "$out" "$out.dSYM"
exit $status
