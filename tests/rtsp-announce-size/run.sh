#!/bin/sh
# Builds and runs the ANNOUNCE size test of the stream library with a plain C compiler: the SDP the real generator
# (moonlight-common-c src/SdpGenerator.c) makes with every option on, against the 2048 bytes a Sunshine host reads an
# RTSP message into. Test source: moonlight-common-c tests/RtspAnnounceSizeTest.c.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$dir/../.." && pwd)
lib="$root/moonlight-common/moonlight-common-c"
out=${TMPDIR:-/tmp}/rtsp-announce-size-test.$$
${CC:-cc} -std=gnu11 -Wall -O1 -DHAS_SOCKLEN_T -I"$lib/src" -I"$lib/enet/include" -o "$out" \
    "$lib/tests/RtspAnnounceSizeTest.c" "$lib/src/RtspParser.c"
status=0
"$out" || status=$?
rm -f "$out"
exit $status
