#!/bin/sh
# Builds and runs the keyboard-path rules test (Control pass-through, Windows-order Command as held LeftAlt, held key-up
# monitor, sheet close) with a plain C compiler. Production code: Limelight/Input/KeyboardRouting.h and
# Limelight/macOS/ViewControllers/SheetCloseRules.h, the same headers HIDSupport.m and the stream/settings controllers use.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$dir/../.." && pwd)
out=${TMPDIR:-/tmp}/key-routing-test.$$
${CC:-cc} -std=c11 -Wall -Wextra -Werror -O1 -g -fsanitize=address,undefined \
    -I"$root/Limelight/Input" -I"$root/Limelight/macOS/ViewControllers" -o "$out" "$dir/test_key_routing.c"
status=0
"$out" || status=$?
rm -rf "$out" "$out.dSYM"
exit $status
