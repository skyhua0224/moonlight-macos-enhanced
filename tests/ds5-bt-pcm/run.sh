#!/bin/sh
set -e
dir=$(cd "$(dirname "$0")" && pwd)
out=${TMPDIR:-/tmp}/ds5-bt-pcm-test.$$
${CC:-cc} -std=c11 -Wall -Wextra -Werror -O1 -lm -o "$out" "$dir/test_ds5_bt_pcm.c"
status=0
"$out" || status=$?
rm -f "$out"
exit $status
