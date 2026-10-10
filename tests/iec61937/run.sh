#!/bin/sh
# Builds the framer test and compares it with FFmpeg's spdif muxer. Needs gcc
# and an ffmpeg with the ac3/eac3 encoders and the spdif muxer. Usage:
#   tests/iec61937/run.sh [work-dir]
set -e
here=$(cd "$(dirname "$0")" && pwd)
src="$here/../../Limelight/Stream"
work=${1:-/tmp/ml-spdif-test}
mkdir -p "$work"
cd "$work"

gcc -std=c99 -Wall -Wextra -Werror -O2 -fsanitize=address,undefined \
    -I"$src" -o test_iec61937 "$here/test_iec61937.c" "$src/MLIEC61937.c"
./test_iec61937 selftest

# 5.1 and stereo, a spread of bit rates, and non-default bitstream modes
# (-audio_service_type sets bsmod in AC-3).
src_audio='anoisesrc=d=4:c=pink:r=48000'
n=0
for spec in \
    "ac3 6 640k 0" "ac3 6 448k 0" "ac3 6 384k 3" "ac3 2 192k 0" "ac3 2 96k 2" "ac3 1 64k 1" \
    "eac3 6 384k 0" "eac3 6 640k 0" "eac3 6 192k 0" "eac3 2 128k 0" "eac3 2 64k 0"; do
    set -- $spec
    codec=$1 ch=$2 rate=$3 svc=$4
    n=$((n + 1))
    ffmpeg -v error -y -f lavfi -i "$src_audio" -ac "$ch" -ar 48000 -c:a "$codec" -b:a "$rate" \
        -audio_service_type "$svc" -f "$codec" "in$n.$codec"
    ffmpeg -v error -y -i "in$n.$codec" -c copy -f spdif "ref$n.spdif"
    printf '%s ch=%s %s service=%s: ' "$codec" "$ch" "$rate" "$svc"
    ./test_iec61937 "$codec" "in$n.$codec" "ref$n.spdif"
done

# E-AC-3 frames with fewer than six blocks have to be collected into one burst.
# The encoder only produces 6-block frames and ffmpeg cannot remux rewritten
# headers, so the test rewrites numblkscod itself and checks against a naive
# second implementation of the burst layout.
./test_iec61937 oneblock in7.eac3
