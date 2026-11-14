#!/bin/bash
# On the build host: padwalk.sh <label> <light|dark> <pad-script> [KEY=VAL...]
# Runs padrun.sh on the macOS host (over ssh) under the lock shared with every other macOS build and run.
# The Mac's builds and runs are one at a time: the lock is held for the whole ssh call.
dir=$(cd "$(dirname "$0")" && pwd)
args=""
for a in "$@"; do args+=" $(printf '%q' "$a")"; done
flock "${MAC_LOCK:-${TMPDIR:-/tmp}/mac-build.lock}" ssh "${MAC_HOST:?set MAC_HOST to the ssh name of the Mac}" "PAD_APP=${PAD_APP:-} PAD_SIZE=${PAD_SIZE:-1280x700} PAD_TIMEOUT=${PAD_TIMEOUT:-90} PAD_FRESH=${PAD_FRESH:-1} PAD_HOST=${PAD_HOST:-0A11-GAMINGPC-LIVE} bash -s --$args" < "$dir/padrun.sh"
