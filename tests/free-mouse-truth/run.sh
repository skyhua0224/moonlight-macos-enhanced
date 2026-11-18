#!/bin/sh
# Builds and runs the free-mouse virtual cursor test with a plain C compiler. Production code:
# Limelight/Input/FreeMouseVirtualCursor.h, the same header HIDSupport+Pointer.m uses.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$dir/../.." && pwd)
out=${TMPDIR:-/tmp}/free-mouse-truth-test.$$
${CC:-cc} -std=c11 -Wall -Wextra -Werror -O1 -g -fsanitize=address,undefined \
    -I"$root/Limelight/Input" -o "$out" "$dir/test_free_mouse_truth.c" -lm
status=0
"$out" || status=$?
rm -rf "$out" "$out.dSYM"
exit $status
