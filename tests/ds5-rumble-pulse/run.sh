#!/bin/sh
# Builds and runs the rumble pulse test: synthetic 10 ms pulses at 5, 10 and 20 Hz through the pulse scheduler and the
# raw output coalescer, in the USB shape (unpaced, writes complete in 2 ms) and the Bluetooth shape (30 ms pacing,
# writes complete in 32 ms). No pulse may be lost.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
out=${TMPDIR:-/tmp}/ds5-rumble-pulse-test.$$
${CC:-cc} -std=c11 -Wall -Wextra -Werror -O1 -o "$out" "$dir/test_ds5_rumble_pulse.c"
status=0
"$out" || status=$?
rm -f "$out"
exit $status
