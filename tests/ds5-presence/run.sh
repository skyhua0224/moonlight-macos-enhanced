#!/bin/sh
# Builds and runs the virtual pad presence test with a plain C compiler.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
out=${TMPDIR:-/tmp}/ds5-presence-test.$$
${CC:-cc} -std=c11 -Wall -Wextra -Werror -O1 -o "$out" "$dir/test_ds5_presence.c"
"$out"
rm -f "$out"
