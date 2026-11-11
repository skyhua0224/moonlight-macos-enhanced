#!/bin/bash
# ON the test Mac. usage: run_art.sh <label> <MoonlightEnhanced.app> <source tree with tests/> <outdir> <seconds> <env for the app, e.g. MLC_TRYOPEN=7>... -- <art_host.py args>
# One concept instance at a time (harness-one-concept-instance-at-a-time).
set -u
export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
LABEL=$1; APP=$2; SRC=$3; OUT=$4; SECS=$5; shift 5
APPENV=(); while [ $# -gt 0 ] && [ "$1" != "--" ]; do APPENV+=(--env "$1"); shift; done; shift
SRVARGS=("$@")
mkdir -p "$OUT"
for P in 50000 50005; do if lsof -nP -iTCP:$P -sTCP:LISTEN >/dev/null 2>&1; then echo "port $P is taken: not running"; exit 3; fi; done
if pgrep -f "std.skyhua.MoonlightConcept\|MoonlightEnhanced.app/Contents/MacOS" >/dev/null; then :; fi
COPY="$OUT/$LABEL.app"; rm -rf "$COPY"; ditto "$APP" "$COPY"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier std.skyhua.MoonlightConcept" "$COPY/Contents/Info.plist"
codesign --force --deep --sign - "$COPY" >/dev/null 2>&1
HOMEDIR="${HOMEDIR_OVERRIDE:-$OUT/home-$LABEL}"; [ -n "${KEEPHOME:-}" ] || rm -rf "$HOMEDIR"; mkdir -p "$HOMEDIR"
T=/tmp/apps-concept/tls2
SLOG="$OUT/$LABEL.host.log"; : > "$SLOG"
python3 -I "$SRC/tests/net-quiet/art_host.py" --cert $T/c.pem --key $T/k.pem --log "$SLOG" --fixtures "$SRC/tests/fixtures" --max-seconds $((SECS + 15)) ${SRVARGS[@]+"${SRVARGS[@]}"} > "$OUT/$LABEL.host.out" 2>&1 &
SRV=$!
sleep 4
open -n -a "$COPY" --stdout "$OUT/$LABEL.app.log" --stderr "$OUT/$LABEL.app.log" --env HOME="$HOMEDIR" --env CFFIXED_USER_HOME="$HOMEDIR" \
  --env MLC_HARNESS=1 --env MLC_SEED=tls --env MLC_TLS_N=1 --env MLC_TLS_CERT=$T/c.der --env MLC_REAL_NET=1 --env MLC_TLS_EXT=50005 ${APPENV[@]+"${APPENV[@]}"}
sleep 5
PID=$(pgrep -f "$COPY/Contents/MacOS" | head -1)
echo "$LABEL: app pid=$PID server pid=$SRV"
sleep $SECS
alive=no; kill -0 "$PID" 2>/dev/null && alive=yes
[ -n "$PID" ] && kill "$PID" 2>/dev/null
sleep 1; kill $SRV 2>/dev/null; wait $SRV 2>/dev/null
L="$OUT/$LABEL.host.log"; A="$HOMEDIR/Library/Logs/Moonlight/moonlight-debug.log"
cp "$A" "$OUT/$LABEL.debug.log" 2>/dev/null
assets=$(grep -c '/appasset' "$L"); aborted=$(grep '/appasset' "$L" | grep -c aborted)
okfull=$(grep '/appasset' "$L" | grep -c ' 200 .* ok$'); not_mod=$(grep -c '/appasset.* 304 ' "$L")
bytes=$(grep '/appasset' "$L" | awk '{s+=$(NF-1)} END {print s+0}')
sinfo=$(grep -c '/serverinfo' "$L")
windows=$(grep -ac 'prepareForStreaming begin generation=1 ' "$A"); absorbed=$(grep -ac 'is pending already' "$A")
echo "$LABEL: alive=$alive appasset requests=$assets (aborted=$aborted, complete=$okfull, 304=$not_mod) bytes sent=$bytes serverinfo=$sinfo | stream windows opened=$windows, clicks absorbed=$absorbed"
