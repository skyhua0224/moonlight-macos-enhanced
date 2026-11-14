#!/bin/bash
# Opens every settings pane of a built app at the default window size (960x680 content), in English and in Chinese,
# and reads back how many lines each marked description line took when it was really laid out
# (SettingsLineCheck.swift). Exit status 1 when any row description needs more than one line.
#
# usage: run.sh <path to MoonlightEnhanced.app> <out-dir>
# The app is copied under the concept bundle id and run with a private HOME; nothing is installed.
export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
APP=${1:?usage: run.sh <app> <out-dir>}
OUT=${2:?usage: run.sh <app> <out-dir>}
mkdir -p "$OUT"
S="$OUT/app"; rm -rf "$S"; mkdir -p "$S"
ditto "$APP" "$S/MoonlightEnhanced.app"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier std.skyhua.MoonlightConcept" "$S/MoonlightEnhanced.app/Contents/Info.plist"
codesign --force --deep --sign - "$S/MoonlightEnhanced.app" >/dev/null 2>&1
: > "$OUT/all.log"
for lang in English 简体中文; do
  # ConceptHarness only runs with a HOME under /tmp/apps-concept/ (its sandbox rule)
  HOMEDIR="/tmp/apps-concept/linecheck-home-$lang"; rm -rf "$HOMEDIR"; mkdir -p "$HOMEDIR"
  LOG="$OUT/run-$lang.log"
  open -n -a "$S/MoonlightEnhanced.app" --stdout "$LOG" --stderr "$LOG" \
    --env HOME="$HOMEDIR" --env CFFIXED_USER_HOME="$HOMEDIR" \
    --env MLC_HARNESS=1 --env MLC_SCENE=settings --env MLC_SETTLE=50 --env MLC_OUT="$OUT/capture-$lang.png" --env MLC_LINECHECK=1 \
    --args -appLanguage "$lang"
  for i in $(seq 1 60); do sleep 1; pgrep -f "$S/MoonlightEnhanced.app/Contents/MacOS" >/dev/null || break; done
  pgrep -f "$S/MoonlightEnhanced.app/Contents/MacOS" >/dev/null && { echo "$lang: still running after 60 s, stopping"; pkill -f "$S/MoonlightEnhanced.app/Contents/MacOS"; }
  # the pane marker the driver writes before it switches pane gives each line its pane
  awk -v lang="$lang" '/^\[linecheck-pane\]/ {pane=$2; next} /^\[linecheck\]/ {sub(/^\[linecheck\]/, "[linecheck] lang=" lang " pane=" pane); print}' "$LOG" >> "$OUT/all.log"
done
python3 - "$OUT/all.log" <<'PY'
import re,sys
rows={}
for line in open(sys.argv[1],encoding='utf-8'):
    m=re.match(r'\[linecheck\] lang=(\S+) pane=(\d+) id=(.*?) lines=(\d+) width=(\d+) text=(.*)$',line.rstrip('\n'))
    if not m: continue
    lang,pane,ident,lines,width,text=m.groups()
    rows[(lang,pane,ident)]=(int(lines),int(width),text)   # the last report is the settled layout
bad=[(k,v) for k,v in rows.items() if v[0]>1]
print("%d description lines measured, %d need more than one line" % (len(rows),len(bad)))
for (lang,pane,ident),(lines,width,text) in sorted(bad):
    print("  %s pane %s %s: %d lines at width %d: %s" % (lang,pane,ident,lines,width,text[:70]))
sys.exit(1 if bad else 0)
PY
