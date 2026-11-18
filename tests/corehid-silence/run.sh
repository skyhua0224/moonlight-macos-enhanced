#!/bin/sh
# Builds and runs the CoreHID silence test with a plain C compiler. Production code:
# Limelight/Input/CoreHIDSilence.h, the same header HIDSupport+Pointer.m uses.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$dir/../.." && pwd)
out=${TMPDIR:-/tmp}/corehid-silence-test.$$
${CC:-cc} -std=c11 -Wall -Wextra -Werror -O1 -g -fsanitize=address,undefined \
    -I"$root/Limelight/Input" -o "$out" "$dir/test_corehid_silence.c"
status=0
"$out" || status=$?
rm -rf "$out" "$out.dSYM"
exit $status
