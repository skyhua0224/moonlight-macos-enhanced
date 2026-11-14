#!/bin/bash
# The audit walk of the Deck gamepad work (every row of the table in README.md), on the build host.
# usage: walks.sh <light|dark> [outdir-suffix]    prints "ok"/"FAIL" per check and a summary.
# Token language: see ConceptHarness.m (+runPadScript): u d l r a b x y menu view lb rb, R<button> = the same through the
# raw DualSense mapping, wait=ms shot=name log=text expect=<focus key|prefix*> expectstate=<substring of the state line>
# alert= streamreturn rebuild expectno=<text the reachable-controls line must not contain> expectsettings=<0|1>.
# The harness sandbox lists eight computers; the walks start on the third (3/8), LB / RB step through them in list order.
dir=$(cd "$(dirname "$0")" && pwd)
A=${1:-light}
fail=0; total=0
run() {  # label script
  local out; out=$("$dir/padwalk.sh" "$2-$A" "$A" "$3" 2>&1)
  echo "$out" > "${WALK_LOG:-/tmp/deck-pad-walk}-$2-$A.log"
  local f; f=$(echo "$out" | grep -c "FAIL\|timeout")
  local n; n=$(echo "$out" | grep -c "PAD expect")
  total=$((total+n)); fail=$((fail+f))
  echo "$1: $n checks, $f failed"
}
run "sidebar: the computer list is out of the focus graph (D-pad, stick, B never enter it)" sidebar "wait=2500,expect=primary,expectno=row row:,expectno=anchor add ,expectno=anchor cleanup,expectno=text -,l,l,expectstate=column=detail,expect=primary,b,expectstate=column=detail,expect=primary,d,d,d,d,d,d,d,d,l,l,l,l,l,l,l,l,l,l,u,u,u,u,u,u,u,u,u,u,u,u,l,l,expectstate=column=detail,expectno=row row:,shot=no-sidebar-focus"
run "page menu: Menu where nothing has a menu of its own (添加电脑, 清理旧记录)" pagemenu "wait=2500,expect=primary,menu,wait=600,expectstate=menuPanel=1,shot=page-menu,b,wait=400,expectstate=menuPanel=0,expect=primary"
run "home: hero buttons, more menu, shelf header, tiles, tile menu" home "wait=2500,expect=primary,shot=hero-primary,r,r,r,r,expect=settings,r,expect=more,a,wait=600,expectstate=menuPanel=1,shot=more-menu,b,wait=500,expect=more,l,l,l,l,l,expect=primary,d,d,expect=app:*,shot=tile,menu,wait=600,expectstate=menuPanel=1,shot=tile-menu,b,wait=500,expect=app:*,u,u,expect=primary,l,expectstate=column=detail,expect=primary"
run "home: connect, B cancels the connection (page 正在连接…, or the stream window's startup overlay)" connect "wait=2500,expect=primary,a,wait=100,shot=connecting,b,wait=2500,expectstate=back=0,expectstate=stream=0,expect=primary,expectstate=column=detail,shot=cancelled"
run "sheets: add computer (page menu), alert, B" addhost "wait=2500,expect=primary,menu,wait=600,a,wait=1500,expectstate=sheet=1,expectstate=kind=text,shot=add-sheet,d,r,b,wait=1200,expectstate=sheet=0,expect=primary,alert=Remove?,wait=300,expectstate=sheet=1,shot=alert-sheet,r,l,b,wait=1200,expectstate=sheet=0,expect=primary"
run "popover: 自定义主页 (X), controls, reorder menu, B" customize "wait=2500,expect=primary,x,wait=1200,expectstate=popover=1,shot=customize,d,d,d,d,d,d,d,expect=section:*,a,wait=600,expectstate=menuPanel=1,shot=customize-reorder,b,wait=400,b,wait=1200,expectstate=popover=0,expect=primary"
run "pages: unpaired (LB/RB to it, pair, cancel pairing with B)" unpaired "wait=2500,rb,rb,wait=1500,expect=primary,shot=unpaired,a,wait=300,expectstate=back=1,shot=pairing,b,wait=800,expectstate=back=0,expect=primary"
run "pages: offline computer" offline "wait=2500,rb,rb,rb,wait=1500,expect=primary,shot=offline,r,r,d,d,d,d,d,d,d,d,d,d,shot=offline-down"
run "computers: LB/RB feedback, ends of the list, focus stays on the page, page rebuild, window leaving and returning" switch "wait=2500,expect=primary,lb,wait=300,expectstate=2/8],lb,wait=300,expectstate=1/8],lb,wait=300,expectstate=1/8],wait=1500,expect=primary,expectstate=column=detail,rb,wait=300,expectstate=2/8],shot=switch-toast,wait=1200,expect=primary,expectstate=column=detail,rb,rb,rb,rb,rb,rb,wait=300,expectstate=8/8],rb,wait=300,expectstate=8/8],wait=1500,expectstate=column=detail,expectno=row row:,lb,lb,lb,lb,lb,wait=300,expectstate=3/8],wait=1500,expect=primary,d,d,expect=app:*,rebuild,wait=800,expect=app:*,streamreturn,wait=500,expect=app:*,d"
run "settings window (Y): B closes it, focus is back on the page, the press is not passed on" settings "wait=1200,y,wait=1500,expectsettings=1,b,wait=1500,expectsettings=0,expect=primary,expectstate=column=detail,b,wait=500,expectsettings=0,expect=primary,expectstate=column=detail,b,wait=500,expectsettings=0"
run "settings window (A on the gear): B closes it, focus returns to the gear" settingsgear "wait=2500,expect=primary,r,r,r,r,expect=settings,a,wait=1500,expectsettings=1,b,wait=1500,expectsettings=0,expect=settings,b,wait=500,expectsettings=0,expect=settings,expectstate=column=detail"
run "sections: LT / RT jump between the sections of the page, no wrap, back to the hero's primary button" sections "wait=2500,expect=primary,mark,rt,expectmoved=1,expect=app:*,rt,expectmoved=1,expect=app:*,rt,expectmoved=1,expect=app:*,rt,expectmoved=0,lt,expectmoved=1,expect=app:*,lt,expectmoved=1,expect=app:*,lt,wait=800,expect=primary,expectstate=column=detail,expectno=row row:"
run "sections: LT / RT through the raw DualSense path (analog trigger with hysteresis)" sectionsraw "wait=2500,expect=primary,mark,Rrt,expectmoved=1,expect=app:*,Rrt,expectmoved=1,Rlt,expectmoved=1,expect=app:*,Rlt,wait=800,expect=primary"
run "settings window: LT / RT turn pages in its panes, B goes back a column, then closes it, the focus is back on the page" settingspage "wait=2500,y,wait=1500,expectsettings=1,r,r,wait=400,mark,rt,wait=400,expectmoved=1,lt,wait=400,expectmoved=1,b,wait=500,expectstate=column=sidebar,b,wait=1500,expectsettings=0,expect=primary,expectstate=column=detail"
run "settings window: B after the pad moved the focus in it closes it and it stays closed (the focus ring is not put back on a closing window)" settingsring "wait=2500,y,wait=1500,expectsettings=1,r,wait=300,b,wait=1500,expectsettings=0,expect=primary,expectstate=column=detail,wait=1500,expectsettings=0"
run "pad presence: the pointer hides the ring, the first press shows it again" presence "wait=2500,expect=primary,expectstate=ring=1,mouse,expectstate=used=0,expectstate=ring=0,d,wait=300,expectstate=used=1,expectstate=ring=1,expect=primary,d,expect="
run "raw DualSense path: move, activate, menu, back, computers" raw "wait=2500,expect=primary,Rr,Rd,Rd,Rmenu,wait=500,expectstate=menuPanel=1,Rb,wait=400,expectstate=menuPanel=0,Rl,expectstate=column=detail,Rrb,wait=300,expectstate=4/8]"
echo "summary: $total checks, $fail failed (appearance $A)"
[ $fail = 0 ]
