#!/bin/sh
# Builds and runs the DualSense Bluetooth policy and report-rate cap test with a plain C compiler.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
out=${TMPDIR:-/tmp}/ds5-policy-test.$$
${CC:-cc} -std=c11 -Wall -Wextra -Werror -O1 -o "$out" "$dir/test_ds5_policy.c"
"$out"
rm -f "$out"
