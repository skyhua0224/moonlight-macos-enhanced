#!/bin/bash
# Runs ON the macOS harness Mac. usage: padrun.sh <label> <light|dark> <pad-script> [KEY=VAL ...]
# Launches the concept (MLC_CONCEPT_HARNESS) build with a scripted pad (MLC_PAD, see ConceptHarness.m runPadScript),
# waits for it to quit, prints its PAD lines. Environment: PAD_APP (the .app), PAD_SANDBOX (the harness sandbox directory),
# PAD_SIZE, PAD_TIMEOUT, PAD_FRESH (re-clone the sandbox home first), PAD_HOST.
set -u
export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
LABEL=$1; APPEAR=$2; SCRIPT=$3; shift 3
SB=${PAD_SANDBOX:-/tmp/apps-concept}
APPDIR=${PAD_APP:-$SB/dd-padh/Build/Products/Release/MoonlightEnhanced.app}
OUT=$SB/pad-out/$LABEL
HOMEDIR=$SB/home-pad
[ -n "${PAD_FRESH:-}" ] && rm -rf $HOMEDIR
[ -d $HOMEDIR ] || cp -Rc $SB/home-first $HOMEDIR
mkdir -p $OUT $SB/pids
rm -f $OUT/*.png $OUT/run.log
ENVARGS=(--env HOME=$HOMEDIR --env CFFIXED_USER_HOME=$HOMEDIR --env MLC_HARNESS=1 --env MLC_POSTERS=$SB/posters-shaped-all
  --env MLC_SCENE=apps --env MLC_VARIANT=A0 --env MLC_SIZE=${PAD_SIZE:-1280x700} --env MLC_APPEARANCE=$APPEAR --env MLC_HOST=${PAD_HOST:-0A11-GAMINGPC-LIVE}
  --env MLC_PAD="$SCRIPT" --env MLC_PAD_OUT=$OUT --env MLC_SETTLE=${PAD_SETTLE:-4} --env MLC_WINY=40)
for kv in "$@"; do ENVARGS+=(--env "$kv"); done
open -n -a "$APPDIR" --stdout $OUT/run.log --stderr $OUT/run.log "${ENVARGS[@]}"
sleep 3
# the pid of THIS app, by its path (another harness run may share the bundle id)
PID=$(ps -axo pid,command | grep "$APPDIR/Contents/MacOS" | grep -v grep | awk '{print $1}' | head -1)
echo "pid=$PID"; [ -n "$PID" ] && echo $PID > $SB/pids/pad.pid
for i in $(seq 1 ${PAD_TIMEOUT:-90}); do
  [ -n "$PID" ] && kill -0 $PID 2>/dev/null || break
  sleep 1
done
if [ -n "$PID" ] && kill -0 $PID 2>/dev/null; then echo "timeout; stopping recorded pid $PID"; kill $PID; sleep 2; kill -0 $PID 2>/dev/null && kill -9 $PID; fi
grep "^PAD" $OUT/run.log
ls $OUT | tr '\n' ' '; echo
