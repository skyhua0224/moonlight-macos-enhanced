#!/bin/sh
# Builds and runs the SDR colour-space test on macOS (Foundation + CoreGraphics, no host or window needed).
set -e
dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$dir/../.." && pwd)
out=${TMPDIR:-/tmp}/sdr-colorspace-test.$$
CC=${CC:-xcrun clang}
$CC -std=gnu11 -fobjc-arc -Wall -Wextra -Werror -Wno-unused-parameter -O1 -g -fsanitize=address,undefined \
    -I"$root/Limelight/Stream" -framework Foundation -framework CoreGraphics \
    -o "$out" "$dir/test_sdr_colorspace.m"
status=0
"$out" || status=1
rm -f "$out"
exit $status
