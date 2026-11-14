#!/bin/bash
# ON the test Mac. Runs the built app (harness build) against the stand-in host of tests/host-cap2/mock_host.py, once as a
# capability 2 host and once as a capability 1 host, and reads the host's request log:
#   cap 2: the client holds /serverinfo?fsWait=<seq> requests (the events long-poll), a few plain serverinfo requests;
#   cap 1: never a fsWait request, a plain serverinfo about every 30 s (the quiet refresh).
# The host is seeded (MLC_SEED=repro: an unpaired host REPRO-NOCERT-1 at the stand-in's address) and the app keeps running
# (MLC_SOAK) so its discovery worker runs for the whole time. Before that, a short run executes the in-app self-test
# (MLC_SELFTEST_CAP: the real parsers and facts store against the capability 2 and capability 1 fixtures).
# One concept instance at a time.
# usage: smoke_discovery.sh <MoonlightEnhanced.app> <source tree with tests/> <outdir> [seconds per run, default 80]
set -u
export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
APP=$1; SRC=$2; OUT=$3; SECS=${4:-80}
mkdir -p "$OUT"
COPY="$OUT/MoonlightEnhanced.app"
rm -rf "$COPY"; ditto "$APP" "$COPY"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier std.skyhua.MoonlightConcept" "$COPY/Contents/Info.plist"
codesign --force --deep --sign - "$COPY" >/dev/null 2>&1
fail=0
HOMEDIR="$OUT/home-selftest"; rm -rf "$HOMEDIR"; mkdir -p "$HOMEDIR"; : > "$OUT/app-selftest.log"
open -n -a "$COPY" --stdout "$OUT/app-selftest.log" --stderr "$OUT/app-selftest.log" --env HOME="$HOMEDIR" --env CFFIXED_USER_HOME="$HOMEDIR" \
  --env MLC_HARNESS=1 --env MLC_SEED=none --env MLC_SETTLE=300 \
  --env MLC_SELFTEST_CAP="$SRC/tests/fixtures/host-cap2-serverinfo.xml,$SRC/tests/fixtures/host-cap1-serverinfo.xml,$SRC/tests/fixtures/host-cap2-applist.xml"
sleep 12
PID=$(pgrep -f "$COPY/Contents/MacOS" | head -1); [ -n "$PID" ] && kill "$PID" 2>/dev/null
grep -a "SELFTEST" "$OUT/app-selftest.log" | sed 's/^/  /'
grep -aq "SELFTEST-CAP ALL PASS" "$OUT/app-selftest.log" && echo "self-test PASS" || { echo "self-test FAIL"; fail=1; }
sleep 2
for CAP in 2 1; do
  PORT=$((48000 + RANDOM % 1000))
  while nc -z 127.0.0.1 $PORT 2>/dev/null; do PORT=$((PORT + 1)); done      # never take a port that is in use
  HOMEDIR="$OUT/home-cap$CAP"; rm -rf "$HOMEDIR"; mkdir -p "$HOMEDIR"
  : > "$OUT/mock-cap$CAP.log"; : > "$OUT/app-cap$CAP.log"
  python3 -I "$SRC/tests/host-cap2/mock_host.py" --cap $CAP --port $PORT --log "$OUT/mock-cap$CAP.log" --fixtures "$SRC/tests/fixtures" \
    --uniqueid REPRO-NOCERT-1 --bump-every 6 --max-seconds $((SECS + 20)) &
  MOCK=$!
  sleep 1
  ENVS=(--env HOME="$HOMEDIR" --env CFFIXED_USER_HOME="$HOMEDIR" --env MLC_HARNESS=1 --env MLC_SEED=repro --env MLC_REAL_NET=1 --env MLC_REPRO_ADDR=127.0.0.1:$PORT --env MLC_SOAK=1)
  open -n -a "$COPY" --stdout "$OUT/app-cap$CAP.log" --stderr "$OUT/app-cap$CAP.log" "${ENVS[@]}"
  sleep 4
  PID=$(pgrep -f "$COPY/Contents/MacOS" | head -1)
  echo "cap$CAP: app pid=$PID port=$PORT mock pid=$MOCK"
  sleep $SECS
  alive=no; kill -0 "$PID" 2>/dev/null && alive=yes
  [ -n "$PID" ] && kill "$PID" 2>/dev/null
  kill $MOCK 2>/dev/null; wait $MOCK 2>/dev/null
  L="$OUT/mock-cap$CAP.log"
  total=$(wc -l < "$L" | tr -d ' ')
  waits=$(grep -c 'fsWait=' "$L")
  plain=$(grep -c '^[0-9.]* /serverinfo' "$L"); plain=$((plain - waits))
  held=$(awk '/fsWait=/ { if ($NF+0 > 1.0) n++ } END { print n+0 }' "$L")
  echo "cap$CAP: app alive at end=$alive; requests=$total; fsWait requests=$waits (held >1 s: $held); plain serverinfo=$plain"
  if [ $CAP = 2 ]; then
    [ "$waits" -ge 4 ] && [ "$held" -ge 3 ] && echo "cap2 PASS: the client long-polls the events" || { echo "cap2 FAIL: no long-poll"; fail=1; }
  else
    R=$(python3 -I "$SRC/tests/host-cap2/rounds.py" "$L"); echo "cap1: rounds (+seconds:plain requests) $R"
    # a full discovery round is many requests (every address of every seeded host); with no events it comes about every 30 s
    ok=$(echo "$R" | python3 -I -c "
import re,sys
r=[(int(a),int(b)) for a,b in re.findall(r'\+(\d+)s:(\d+)', sys.stdin.read())]
big=[a for a,b in r if b>=5]
print('yes' if len(big)>=2 and all(y-x>=25 for x,y in zip(big,big[1:])) else 'no')")
    [ "$waits" -eq 0 ] && [ "$ok" = yes ] && echo "cap1 PASS: no fsWait, quiet refresh about every 30 s" || { echo "cap1 FAIL"; fail=1; }
  fi
  [ "$alive" = yes ] || { echo "cap$CAP FAIL: the app was not running at the end"; fail=1; }
done
echo "smoke exit=$fail"; exit $fail
