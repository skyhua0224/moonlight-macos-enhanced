#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
cc -std=gnu11 -Wall -Wextra -Werror -I Limelight/Network Limelight/Network/HostPathRank.c tests/host-path-rank/test_host_path_rank.c -lpthread -o "${TMPDIR:-/tmp}/host-path-rank-test.$$"
"${TMPDIR:-/tmp}/host-path-rank-test.$$"; status=$?
rm -f "${TMPDIR:-/tmp}/host-path-rank-test.$$"
exit $status
