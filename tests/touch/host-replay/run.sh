#!/bin/sh
# Host-side replay: runs Sunshine's real touch_update (extracted from foundation-sunshine) on the wire events the client
# produces. Needs the client dump (macOS: tests/touch/run.sh writes it) and the foundation-sunshine and platform sources.
#   usage: run.sh <wire.txt>
# env: SUNSHINE_SRC (a foundation-sunshine checkout), ALKAID_ROOT (a platform checkout); both default to siblings of this repository
set -e
dir=$(cd "$(dirname "$0")" && pwd)
wire=${1:?usage: run.sh <wire.txt>}
sun=${SUNSHINE_SRC:-$dir/../../../../foundation-sunshine}
alk=${ALKAID_ROOT:-$dir/../../../../alkaidlab-platform}
out=${TMPDIR:-/tmp}/touch-host-replay.$$
mkdir -p "$out"
python3 -I "$dir/extract.py" "$sun/src/platform/windows/input.cpp" "$out/extracted_touch.inc"
${CXX:-g++} -std=c++20 -Wall -Wextra -Wno-unused-parameter -Wno-unused-function -Wno-unused-variable -O1 -g \
  -fsanitize=address,undefined -I"$out" -I"$dir" \
  -I"$alk/adapters/gamestream/common/include" -I"$alk/sdk/c/include" -I"$alk/core/interaction/input/include" -I"$alk/core/kernel/include" \
  -o "$out/replay" "$dir/replay.cpp"
status=0
"$out/replay" "$wire" || status=$?
rm -rf "$out"
exit $status
