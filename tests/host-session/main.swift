import Foundation

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
  if !ok { failures += 1 }
  print("\(ok ? "PASS" : "FAIL") \(name)\(ok ? "" : " — " + detail())")
}

let busy = "SUNSHINE_SERVER_BUSY", free = "SUNSHINE_SERVER_FREE"
let gfeBusy = "MJOLNIR_STATE_SERVER_BUSY", gfeFree = "MJOLNIR_STATE_SERVER_FREE"

/// A host that cancels asynchronously: /serverinfo says busy for `busyAnswers` more answers, then free.
func quit(isFoundation: Bool, first: String?, busyAnswers: Int, unreadable: Int = 0) -> (HostSessionPolicy.QuitResult, polls: Int, waited: Double) {
  var left = busyAnswers, bad = unreadable, polls = 0, waited = 0.0
  let result = HostSessionPolicy.finishQuit(isFoundation: isFoundation, firstState: first, poll: {
    polls += 1
    if bad > 0 { bad -= 1; return nil }
    if left > 0 { left -= 1; return busy }
    return free
  }, wait: { waited += $0 })
  return (result, polls, waited)
}

// MARK: - quitting an app another client started (VoidLink does it)

do {
  let r = quit(isFoundation: true, first: busy, busyAnswers: 5)     // cancel answered 200, the app takes ~1.8 s to go
  check("Foundation Sunshine: 200, still busy right after, free after 6 polls: quit", r.0 == .quit && r.polls == 6, "\(r)")
  check("... and it waited for it (1.8 s), not 0", abs(r.waited - 1.8) < 0.01, "\(r.waited)")
}
do {
  let r = quit(isFoundation: false, first: busy, busyAnswers: 3)    // plain Sunshine: SUNSHINE_ prefix, no FS capability
  check("Sunshine (SUNSHINE_ state): polled until free: quit", r.0 == .quit, "\(r)")
}
do {
  let r = quit(isFoundation: true, first: free, busyAnswers: 0)
  check("free at once: quit without polling", r.0 == .quit && r.polls == 0)
}
do {
  let r = quit(isFoundation: true, first: busy, busyAnswers: 1000)
  check("still busy after 10 s: still running (not 'another client')", r.0 == .stillRunning && abs(r.waited - 10) < 0.5, "\(r)")
  check("... after 33 polls of 0.3 s", r.polls >= 33 && r.polls <= 34, "\(r.polls)")
}
do {
  let r = quit(isFoundation: true, first: nil, busyAnswers: 2, unreadable: 2)
  check("serverinfo unreadable right after the 200 (host busy cancelling): polling goes on", r.0 == .quit, "\(r)")
}
do {
  let r = quit(isFoundation: false, first: gfeBusy, busyAnswers: 0)
  check("GFE: 200 and still busy: the old reading (another client started it), no polling", r.0 == .otherClientOnGFE && r.polls == 0, "\(r)")
  let ok = quit(isFoundation: false, first: gfeFree, busyAnswers: 0)
  check("GFE: free: quit", ok.0 == .quit)
}
do {
  var polled = 0
  let code = HostSessionPolicy.quitOutcome(isFoundation: true, firstState: busy, poll: { polled += 1; return polled >= 2 ? free : busy }, wait: { _ in })
  check("ObjC bridge returns 1 for quit", code == 1 && polled == 2)
  check("ObjC bridge returns 2 for still running", HostSessionPolicy.quitOutcome(isFoundation: true, firstState: busy, poll: { busy }, wait: { _ in }) == 2)
  check("ObjC bridge returns 3 for GFE with another client's app", HostSessionPolicy.quitOutcome(isFoundation: false, firstState: gfeBusy, poll: { gfeBusy }, wait: { _ in }) == 3)
}

// MARK: - the running-app mark follows the host

check("busy with an app: that app runs", HostSessionPolicy.runningAppId(state: busy, currentGame: "25818427") == "25818427")
check("free: nothing runs, even when currentgame still names the last game", HostSessionPolicy.runningAppId(state: free, currentGame: "25818427") == nil)
check("busy with currentgame 0 or empty: nothing", HostSessionPolicy.runningAppId(state: busy, currentGame: "0") == nil && HostSessionPolicy.runningAppId(state: busy, currentGame: "") == nil && HostSessionPolicy.runningAppId(state: busy, currentGame: nil) == nil)

// Transition 1: another client (VoidLink) quits the app: the page showed 继续游戏, the host now says free.
do {
  var shown: String? = "98082571"
  let c = HostSessionPolicy.reconcile(current: shown, reachable: true, state: free, currentGame: "98082571")
  shown = c.runningId
  check("another client quit the app: the running mark is cleared", c.changed && shown == nil, "\(c)")
  let again = HostSessionPolicy.reconcile(current: shown, reachable: true, state: free, currentGame: "0")
  check("... and the next poll changes nothing", !again.changed && again.runningId == nil)
}
// Transition 2: another client starts an app.
do {
  var shown: String? = nil
  let c = HostSessionPolicy.reconcile(current: shown, reachable: true, state: busy, currentGame: "333815437")
  shown = c.runningId
  check("another client started an app: it is marked running", c.changed && shown == "333815437", "\(c)")
  let switched = HostSessionPolicy.reconcile(current: shown, reachable: true, state: busy, currentGame: "439805038")
  check("another client switched to a different app: the mark moves", switched.changed && switched.runningId == "439805038")
  check("same app again: unchanged", !HostSessionPolicy.reconcile(current: "439805038", reachable: true, state: busy, currentGame: "439805038").changed)
}
// A failed request is not "the app quit".
do {
  let c = HostSessionPolicy.reconcile(current: "98082571", reachable: false, state: nil, currentGame: nil)
  check("host unreachable: the mark stays", !c.changed && c.runningId == "98082571")
}
// the ObjC pointer form
do {
  var changed = ObjCBool(false)
  let id = HostSessionPolicy.reconciledRunningId(current: "1", reachable: true, state: free, currentGame: "1", changed: &changed)
  check("ObjC form: cleared and changed", id == nil && changed.boolValue)
}

// MARK: - starting an app while another runs (大屏模式 over Steam)

let steam = "98082571", bigScreen = "1986222379"
check("host free: launch", HostSessionPolicy.launchDecision(state: free, currentGame: "0", appId: bigScreen) == 1)
check("host free but currentgame names the last game: still launch", HostSessionPolicy.launchDecision(state: free, currentGame: steam, appId: bigScreen) == 1)
check("Steam runs, start 大屏模式: another app is running, not resume", HostSessionPolicy.launchDecision(state: busy, currentGame: steam, appId: bigScreen) == 3)
check("大屏模式 runs, start 大屏模式 (继续): resume", HostSessionPolicy.launchDecision(state: busy, currentGame: bigScreen, appId: bigScreen) == 2)
check("Steam runs, resume Steam: resume", HostSessionPolicy.launchDecision(state: busy, currentGame: steam, appId: steam) == 2)
check("GFE busy with another app: not a resume either", HostSessionPolicy.launchDecision(state: gfeBusy, currentGame: steam, appId: bigScreen) == 3)
check("busy, no app named (old host): resume as before", HostSessionPolicy.launchDecision(state: busy, currentGame: "0", appId: bigScreen) == 2)

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
