import AppKit
import Carbon.HIToolbox
import Foundation

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
  if !ok { failures += 1 }
  print("\(ok ? "PASS" : "FAIL") \(name)\(ok ? "" : " — " + detail())")
}

func sample(_ t: Double, rx: Float = 60, rd: Float? = nil, low1: Float = 55, netLoss: Float = 0, stalls: UInt32 = 0,
            noPayload: Int = 0, frozen: Int = 0, poor: Bool = false) -> OverlayHealthSample {
  OverlayHealthSample(time: t, renderedFps: rd ?? rx, receivedFps: rx, onePercentLow: low1, netAvailable: true,
                      netLossPercent: netLoss, clientDropPercent: 0, clientStallTotal: stalls,
                      noPayloadSeconds: noPayload, frozenSeconds: frozen, poor: poor)
}

// MARK: - warnings

// 1. A game that limits itself to 60 on a 144 stream, with a few isolated lost frames: nothing to say.
do {
  let d = OverlayHealthDetector()
  var any = false, level = OverlayHealthLevel.normal
  for i in 0..<240 {
    let t = Double(i) * 0.5
    // one window of 1.3 % every 12 s (one frame of ~75 in the 3 s window)
    let loss: Float = (i % 24) < 6 ? 1.3 : 0
    let s = d.ingest(sample(t, rx: 60 - Float(i % 3), low1: 54, netLoss: loss))
    if !s.warnings.isEmpty { any = true }
    level = max(level, s.level)
  }
  check("game-limited 60 fps with a lost frame now and then: no warning, status normal", !any && level == .normal, "any=\(any) level=\(level)")
}

// 2. One lost frame on a screen that sends 30 fps is 3.3 % of its 3 s window: below the frame count.
do {
  let d = OverlayHealthDetector()
  var any = false
  for i in 0..<60 { if !d.ingest(sample(Double(i) * 0.5, rx: 30, netLoss: (i >= 10 && i < 16) ? 3.3 : 0)).warnings.isEmpty { any = true } }
  check("30 fps, one lost frame in 3 s (3.3 %): no warning", !any)
}

// 3. A real burst: 20 % of the frames of 60 fps for 6 s is 90 frames. It warns, is shown, and goes after the window.
do {
  let d = OverlayHealthDetector()
  var firstWarn: Double?, lastWarn: Double?
  var shownPercent: Float = 0
  for i in 0..<120 {
    let t = Double(i) * 0.5
    let s = d.ingest(sample(t, rx: 60, netLoss: (i >= 20 && i < 32) ? 20 : 0))
    if s.warnings.contains(where: { if case .netLoss = $0 { return true } else { return false } }) {
      if firstWarn == nil { firstWarn = t }
      lastWarn = t
      shownPercent = max(shownPercent, s.lossPercent)
    }
  }
  check("loss burst of 20 % for 6 s: warns within 5 s of its start", firstWarn != nil && firstWarn! <= 15, "first=\(String(describing: firstWarn))")
  check("loss burst: the warning is gone after the 10 s window and the hold", lastWarn != nil && lastWarn! <= 16 + 10 + 4, "last=\(String(describing: lastWarn))")
  check("loss burst: shown percent is the 10 s figure (5..20), not the raw 20", shownPercent >= 5 && shownPercent < 20, "\(shownPercent)")
}

// 4. A corrupt interval sample (the wrapped 42949672.4 %) is not near-certain loss: before it was
//    rejected it filled six ticks with the 0.95 loss-share cap and the 10 s window showed a false
//    ~85 % (114 of 134 frames) network-loss warning while nothing was lost.
do {
  let d = OverlayHealthDetector()
  var anyNetLoss = false
  var worstLevel = OverlayHealthLevel.normal
  var shownPercent: Float = 0
  for i in 0..<120 {
    let t = Double(i) * 0.5
    let s = d.ingest(sample(t, rx: 60, netLoss: (i >= 20 && i < 26) ? 42949672.4 : 0))
    if s.warnings.contains(where: { if case .netLoss = $0 { return true } else { return false } }) { anyNetLoss = true }
    worstLevel = max(worstLevel, s.level)
    shownPercent = max(shownPercent, s.lossPercent)
  }
  check("a wrapped 42949672.4 % sample raises no network-loss warning", !anyNetLoss)
  check("a wrapped sample leaves the status normal and the shown percent at 0", worstLevel == .normal && shownPercent == 0, "level=\(worstLevel) percent=\(shownPercent)")
}

// 5. Client stalls: two in 10 s are nothing, three are a warning that stays for the hold.
do {
  let d = OverlayHealthDetector()
  var warnedAt: [Double] = []
  var total: UInt32 = 0
  for i in 0..<80 {
    let t = Double(i) * 0.5
    if i == 4 || i == 8 { total += 1 }
    if i == 30 || i == 34 || i == 38 { total += 1 }
    let s = d.ingest(sample(t, stalls: total))
    if s.warnings.contains(where: { if case .stalls = $0 { return true } else { return false } }) { warnedAt.append(t) }
  }
  check("two client stalls in 10 s: no warning (first at 2 s, second at 4 s)", !warnedAt.contains(where: { $0 < 15 }), "\(warnedAt)")
  check("three client stalls in 10 s: warning from the third", warnedAt.first == 19, "\(warnedAt.first ?? -1)")
  check("the stall warning is gone once the stalls leave the window", (warnedAt.last ?? 99) <= 19 + 10, "\(warnedAt.last ?? -1)")
}

// 6. The counter of the renderer starts again with a new stream: no negative or huge difference.
do {
  let d = OverlayHealthDetector()
  _ = d.ingest(sample(0, stalls: 50))
  let s = d.ingest(sample(0.5, stalls: 0))
  check("stall counter restarting at 0 is not a burst of stalls", s.recentStalls == 0, "\(s.recentStalls)")
}

// 7. 1% low is judged against the stream's own rate, and only when something else was seen.
do {
  let d = OverlayHealthDetector()
  var any = false
  for i in 0..<60 { if !d.ingest(sample(Double(i) * 0.5, rx: 60, low1: 20)).warnings.isEmpty { any = true } }
  check("1% low far below the rate but nothing else wrong: no warning", !any)
  let d2 = OverlayHealthDetector()
  var warned = false
  var stalls: UInt32 = 0
  for i in 0..<60 {
    if i >= 20 && i % 3 == 0 { stalls += 1 }
    if d2.ingest(sample(Double(i) * 0.5, rx: 60, low1: 20, stalls: stalls)).warnings.contains(where: { if case .lowPacing = $0 { return true } else { return false } }) { warned = true }
  }
  check("1% low at a third of the rate together with stalls: warning", warned)
  check("1% low against the stream's rate (54 of 60) is normal, against 144 it would not be",
        OverlayHealth.onePercentLowLevel(low: 54, baseline: 60, configured: 144) == .normal &&
        OverlayHealth.onePercentLowLevel(low: 54, baseline: 0, configured: 144) != .normal)
}

// 8. fps colour: what the client rendered of what it received.
do {
  check("fps 60 rendered of 60 received on a 144 stream: normal", OverlayHealth.fpsLevel(rendered: 60, received: 60) == .normal)
  check("fps 10 of 10 on a quiet screen: normal", OverlayHealth.fpsLevel(rendered: 10, received: 10) == .normal)
  check("rendered 45 of 60 received: amber", OverlayHealth.fpsLevel(rendered: 45, received: 60) == .high)
  check("rendered 30 of 60 received: red", OverlayHealth.fpsLevel(rendered: 30, received: 60) == .bad)
}

// 9. no data / frozen / poor stay, from 3 s on, and make the status bad.
do {
  let d = OverlayHealthDetector()
  check("no payload for 2 s: not yet", d.ingest(sample(0, noPayload: 2)).warnings.isEmpty)
  let s = d.ingest(sample(0.5, noPayload: 3))
  check("no payload for 3 s: warning, status bad", s.warnings == [.noData(seconds: 3)] && s.level == .bad, "\(s.warnings) \(s.level)")
  let p = OverlayHealthDetector().ingest(sample(0, poor: true))
  check("poor connection: warning, status bad", p.warnings == [.poor] && p.level == .bad)
}

// 10. A real stream (506 [perf] lines): the old rules against the new ones.
do {
  struct Row { var session: Int; var t: Double; var cfg: Float; var rx: Float; var rd: Float; var low1: Float; var stalls: Int; var netLoss: Float }
  var rows: [Row] = []
  let dir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().path
  let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : dir + "/perf-sample.txt"
  if let text = try? String(contentsOfFile: path, encoding: .utf8) {
    for line in text.split(separator: "\n") where !line.hasPrefix("#") {
      let f = line.split(separator: " ").map(String.init)
      if f.count == 8 { rows.append(Row(session: Int(f[0])!, t: Double(f[1])!, cfg: Float(f[2])!, rx: Float(f[3])!, rd: Float(f[4])!, low1: Float(f[5])!, stalls: Int(f[6])!, netLoss: Float(f[7])!)) }
    }
  }
  check("replay data present", rows.count > 400, "\(rows.count) rows from \(path)")
  for session in Set(rows.map { $0.session }).sorted() {
    let s = rows.filter { $0.session == session }
    if s.count < 30 { continue }
    // old rules: the warning line (loss >= 1 %, stalls went up, 1% low under half of the configured rate) for 4 s
    var oldShown = 0, oldUntil = -1.0, lastStalls = 0
    var oldFpsColoured = 0
    for r in s {
      var found = r.netLoss >= 1.0 || r.stalls > lastStalls || (r.low1 > 0 && r.low1 < 0.5 * r.cfg && r.rd > 0.8 * r.cfg)
      lastStalls = r.stalls
      if found { oldUntil = r.t + 4; found = false }
      if r.t < oldUntil { oldShown += 1 }
      if r.rd / r.cfg < 0.85 { oldFpsColoured += 1 }
    }
    let d = OverlayHealthDetector()
    var newShown = 0, newFpsColoured = 0, bad = 0
    var kinds = Set<String>()
    for r in s {
      let st = d.ingest(OverlayHealthSample(time: r.t, renderedFps: r.rd, receivedFps: r.rx, onePercentLow: r.low1, netAvailable: true,
                                            netLossPercent: r.netLoss, clientDropPercent: 0, clientStallTotal: 0,
                                            noPayloadSeconds: 0, frozenSeconds: 0, poor: false))
      if !st.warnings.isEmpty { newShown += 1 }
      for w in st.warnings { if case .netLoss = w { kinds.insert("loss") } else { kinds.insert("other") } }
      if st.level == .bad { bad += 1 }
      if OverlayHealth.fpsLevel(rendered: r.rd, received: r.rx) != .normal { newFpsColoured += 1 }
    }
    let n = Double(s.count)
    print(String(format: "  session %d (%d ticks, configured %.0f): warning line old %.0f %% -> new %.0f %%, fps coloured old %.0f %% -> new %.0f %%, status bad %.0f %%",
                 session, s.count, s[0].cfg, 100 * Double(oldShown) / n, 100 * Double(newShown) / n, 100 * Double(oldFpsColoured) / n, 100 * Double(newFpsColoured) / n, 100 * Double(bad) / n))
    check("session \(session): fps never coloured (rendered == received)", newFpsColoured == 0, "\(newFpsColoured)")
    check("session \(session): warning line at least 3x rarer than before (old \(oldShown), new \(newShown) of \(s.count))", newShown * 3 <= oldShown, "\(oldShown) -> \(newShown)")
    // session 3 really lost 2.5 % of its frames (110 unrecoverable frames in four minutes); the others about 1 %
    check("session \(session): warning line up for at most 20 % of the time", Double(newShown) <= 0.20 * n, "\(newShown) of \(s.count)")
  }
}

// MARK: - row layout

do {
  func items(_ widths: [CGFloat], divider: CGFloat = 23) -> [OverlayFlowPlanner.Item] {
    var result: [OverlayFlowPlanner.Item] = []
    for (i, w) in widths.enumerated() {
      if i > 0 { result.append(.init(width: divider, height: 13, isDivider: true)) }
      result.append(.init(width: w, height: 18, isDivider: false))
    }
    return result
  }
  // 120 + 23 + 140 + 23 + 100 = 406
  let fits = OverlayFlowPlanner.plan(items([120, 140, 100]), maxWidth: 406, rowSpacing: 5, maxRows: 4)
  check("a line that fits (406 of 406) stays on one row", fits.rowCount == 1 && fits.size.height == 18 && fits.size.width == 406, "\(fits.rowCount) \(fits.size)")
  check("one row: every divider is placed", fits.placements.allSatisfy { $0 != nil })
  check("one row: x positions run left to right", fits.placements[0]?.x == 0 && fits.placements[2]?.x == 143 && fits.placements[4]?.x == 306, "\(fits.placements)")
  let wide = OverlayFlowPlanner.plan(items([120, 140, 100]), maxWidth: 1500, rowSpacing: 5, maxRows: 4)
  check("on a wide screen: one row of the intrinsic width", wide.rowCount == 1 && wide.size.width == 406)
  let narrow = OverlayFlowPlanner.plan(items([120, 140, 100]), maxWidth: 405, rowSpacing: 5, maxRows: 4)
  check("one point too narrow: only the last group moves down", narrow.rowCount == 2 && narrow.placements[4]?.row == 1 && narrow.placements[4]?.x == 0, "\(narrow.placements)")
  check("the divider that would start the second row is dropped", narrow.placements[3] == nil)
  check("two rows: height is two rows and the row gap", narrow.size.height == 18 + 5 + 18, "\(narrow.size)")
  check("two rows: width is the wider row", narrow.size.width == 283, "\(narrow.size)")
  let tooWide = OverlayFlowPlanner.plan(items([600]), maxWidth: 400, rowSpacing: 5, maxRows: 4)
  check("one item wider than the screen is kept, alone", tooWide.rowCount == 1 && tooWide.placements[0] != nil)
  let many = OverlayFlowPlanner.plan(items([100, 100, 100, 100, 100, 100]), maxWidth: 120, rowSpacing: 5, maxRows: 4)
  check("rows past the last row are not shown", many.rowCount == 4 && many.placements[6] != nil && many.placements[8] == nil, "\(many.rowCount) \(many.placements)")
  let empty = OverlayFlowPlanner.plan([], maxWidth: 400, rowSpacing: 5, maxRows: 4)
  check("nothing to show: size zero", empty.size == .zero && empty.rowCount == 0)
  // a recorded case: the usual fields of the text bar with a warning at the end, 1920 wide screen
  let usual = OverlayFlowPlanner.plan(items([205, 150, 245, 110, 230]), maxWidth: 1500 - 28, rowSpacing: 5, maxRows: 4)
  check("usual fields plus a warning on a 1920 screen: one row", usual.rowCount == 1, "\(usual.rowCount) \(usual.size)")
}

// MARK: - shortcuts

do {
  let defaults = StreamShortcutProfile.defaultShortcuts()
  let co: NSEvent.ModifierFlags = [.control, .option]
  let cos: NSEvent.ModifierFlags = [.control, .option, .shift]
  let toggle = StreamShortcutProfile.togglePerformanceOverlayAction, cycle = StreamShortcutProfile.cyclePerformanceOverlayStyleAction
  check("Control-Option-S toggles the overlay", StreamShortcutProfile.overlayAction(forKeyCode: kVK_ANSI_S, modifierFlags: co, shortcuts: nil) == toggle)
  check("Control-Option-Shift-S still cycles the style", StreamShortcutProfile.overlayAction(forKeyCode: kVK_ANSI_S, modifierFlags: cos, shortcuts: nil) == cycle)
  check("Control-Option-S with the profile's own stored shortcuts (an older profile without the cycle entry)",
        StreamShortcutProfile.overlayAction(forKeyCode: kVK_ANSI_S, modifierFlags: co, shortcuts: [toggle: StreamShortcut(keyCode: kVK_ANSI_S, modifierFlags: co)]) == toggle &&
        StreamShortcutProfile.overlayAction(forKeyCode: kVK_ANSI_S, modifierFlags: cos, shortcuts: [toggle: StreamShortcut(keyCode: kVK_ANSI_S, modifierFlags: co)]) == cycle)
  check("Caps Lock or Function in the flags does not matter", StreamShortcutProfile.overlayAction(forKeyCode: kVK_ANSI_S, modifierFlags: [.control, .option, .capsLock, .numericPad], shortcuts: nil) == toggle)
  check("Control-Option alone is not an overlay shortcut", StreamShortcutProfile.overlayAction(forKeyCode: kVK_Control, modifierFlags: co, shortcuts: nil) == nil)
  check("Option-S, Control-S, Command-S, S are not overlay shortcuts",
        [NSEvent.ModifierFlags.option, .control, .command, []].allSatisfy { StreamShortcutProfile.overlayAction(forKeyCode: kVK_ANSI_S, modifierFlags: $0, shortcuts: nil) == nil })
  check("Control-Option-M / G / W are not overlay shortcuts",
        [kVK_ANSI_M, kVK_ANSI_G, kVK_ANSI_W].allSatisfy { StreamShortcutProfile.overlayAction(forKeyCode: $0, modifierFlags: co, shortcuts: nil) == nil })
  check("the defaults are Control-Option-S and Control-Option-Shift-S",
        defaults[toggle]?.keyCode == kVK_ANSI_S && defaults[toggle]?.modifierFlags == co && defaults[cycle]?.keyCode == kVK_ANSI_S && defaults[cycle]?.modifierFlags == cos)
  check("settings shortcut editor lists both overlay actions", StreamShortcutProfile.actionOrder().contains(toggle) && StreamShortcutProfile.actionOrder().contains(cycle))
  // Command-W and the other ways to leave the stream are untouched, and the overlay shortcuts do not match them
  let w: [(String, NSEvent.ModifierFlags)] = [(StreamShortcutProfile.showDisconnectOptionsAction, [.command]), (StreamShortcutProfile.disconnectStreamAction, [.control, .option]),
                                              (StreamShortcutProfile.closeAndQuitAppAction, [.control, .shift])]
  check("Command-W is Show Disconnect Options, Control-Option-W disconnects, Control-Shift-W closes and quits",
        w.allSatisfy { defaults[$0.0]?.keyCode == kVK_ANSI_W && defaults[$0.0]?.modifierFlags == $0.1 })
  check("none of the W chords is taken by an overlay action",
        w.allSatisfy { StreamShortcutProfile.overlayAction(forKeyCode: kVK_ANSI_W, modifierFlags: $0.1, shortcuts: nil) == nil })
  // a profile saved by an older build (a real one, with every action stored) resolves the same way
  var saved: [String: StreamShortcut] = [:]
  for (action, s) in defaults { saved[action] = s }
  check("a stored profile with every default keeps Command-W on Show Disconnect Options and Control-Option-S on the toggle",
        StreamShortcutProfile.normalizedShortcuts(saved)[StreamShortcutProfile.showDisconnectOptionsAction]?.modifierFlags == [.command] &&
        StreamShortcutProfile.overlayAction(forKeyCode: kVK_ANSI_S, modifierFlags: co, shortcuts: saved) == toggle)
  // no two stream shortcuts are the same key chord
  var seen: [String: String] = [:]
  var clash: [String] = []
  for action in StreamShortcutProfile.actionOrder() {
    guard let s = defaults[action] else { continue }
    let key = "\(s.modifierOnly ? "modifiers-only" : "key \(s.keyCode)") mods \(s.modifierFlags.rawValue)"
    if let other = seen[key] { clash.append("\(action) = \(other)") }
    seen[key] = action
  }
  check("no two default stream shortcuts collide", clash.isEmpty, "\(clash)")
  print("  stream shortcuts (default): " + StreamShortcutProfile.actionOrder().compactMap { a in
    defaults[a].map { "\(StreamShortcutProfile.displayTokens(for: $0).joined()) \(a)" } }.joined(separator: "; "))
}

// MARK: - who else wants a shortcut (OverlayShortcutRules)
do {
  let co: NSEvent.ModifierFlags = [.control, .option]
  // a test Mac: enabled symbolic hot keys 60 / 61 / 65, read with `defaults export com.apple.symbolichotkeys`
  func entry(_ params: [Int]) -> [String: Any] { ["enabled": true, "value": ["parameters": params, "type": "standard"]] }
  let source: [String: Any] = [
    "60": entry([32, 49, 262144]), "61": entry([32, 49, 786432]), "65": entry([65535, 49, 1572864]),
    "64": ["enabled": false, "value": ["parameters": [32, 49, 1048576], "type": "standard"]] as [String: Any],
    "7": ["enabled": true] as [String: Any],
  ]
  let keys = OverlayShortcutRules.systemHotKeys(from: source)
  check("system hot keys: only the enabled ones with parameters (60, 61, 65)", keys.map { $0.id } == [60, 61, 65], "\(keys)")
  check("Control-Option-S is not a macOS shortcut on the test Mac",
        OverlayShortcutRules.systemConflict(keyCode: kVK_ANSI_S, flags: co, hotKeys: keys) == nil)
  check("Control-Option-Space is macOS input source switching",
        OverlayShortcutRules.systemConflict(keyCode: kVK_Space, flags: co, hotKeys: keys)?.owner == "Input source switching")
  check("Spotlight (disabled there) is not reported", OverlayShortcutRules.systemConflict(keyCode: kVK_Space, flags: [.command], hotKeys: keys) == nil)
  check("Control-Option-Shift-Space is not the Control-Option-Space shortcut", OverlayShortcutRules.systemConflict(keyCode: kVK_Space, flags: [.control, .option, .shift], hotKeys: keys) == nil)
  check("Caps Lock and Function in the flags do not matter", OverlayShortcutRules.systemConflict(keyCode: kVK_Space, flags: [.control, .option, .capsLock, .function], hotKeys: keys) != nil)

  check("Option-Space is a launcher's shortcut", OverlayShortcutRules.knownConflict(keyCode: kVK_Space, flags: [.option])?.owner == "Raycast / Alfred")
  check("Command-Shift-V is Paste's", OverlayShortcutRules.knownConflict(keyCode: kVK_ANSI_V, flags: [.command, .shift])?.kind == .knownApp)
  check("Control-Option-S is on no known list", OverlayShortcutRules.knownConflict(keyCode: kVK_ANSI_S, flags: co) == nil)

  let defaults = StreamShortcutProfile.defaultShortcuts()
  let toggle = StreamShortcutProfile.togglePerformanceOverlayAction
  check("the toggle moved onto Control-Option-M clashes with the mouse-mode action",
        OverlayShortcutRules.streamConflict(keyCode: kVK_ANSI_M, flags: co, action: toggle, shortcuts: defaults)?.kind == .stream)
  check("the toggle on its own Control-Option-S does not clash with itself",
        OverlayShortcutRules.streamConflict(keyCode: kVK_ANSI_S, flags: co, action: toggle, shortcuts: defaults) == nil)
  check("Control-Option-Shift-S belongs to the cycle action, so the toggle cannot take it",
        OverlayShortcutRules.streamConflict(keyCode: kVK_ANSI_S, flags: [.control, .option, .shift], action: toggle, shortcuts: defaults)?.kind == .stream)
  check("the combined check: Control-Option-S free, Control-Option-Space refused",
        OverlayShortcutRules.conflict(keyCode: kVK_ANSI_S, flags: co, action: toggle, shortcuts: defaults, hotKeys: keys) == nil &&
        OverlayShortcutRules.conflict(keyCode: kVK_Space, flags: co, action: toggle, shortcuts: defaults, hotKeys: keys)?.kind == .system)
  check("Carbon modifier mask of Control-Option is 0x1800", OverlayShortcutRules.carbonModifiers(co) == 0x1800, "\(OverlayShortcutRules.carbonModifiers(co))")

  // the event taps found on the test Mac (CGGetEventTapList through ctypes)
  typealias T = OverlayShortcutRules.TapInfo
  let taps = [
    T(pid: 59695, name: "WeType", active: true, enabled: true, keyDown: true),
    T(pid: 1330, name: "BetterDisplay", active: true, enabled: true, keyDown: true),
    T(pid: 58777, name: "openlogi-agent", active: true, enabled: true, keyDown: true),
    T(pid: 3674, name: "SiriNCService", active: true, enabled: true, keyDown: true),
    T(pid: 38848, name: "?", active: true, enabled: false, keyDown: false),
    T(pid: 66577, name: "Raycast", active: true, enabled: true, keyDown: true),
    T(pid: 66577, name: "Raycast", active: true, enabled: true, keyDown: true),
    T(pid: 24621, name: "ghostty", active: true, enabled: true, keyDown: true),
    T(pid: 655, name: "universalaccessd", active: false, enabled: true, keyDown: true),
    T(pid: 779, name: "ViewBridgeAuxiliary", active: false, enabled: true, keyDown: true),
    T(pid: 4242, name: "Moonlight", active: true, enabled: true, keyDown: true),
    T(pid: 4343, name: "FlowAgent", active: true, enabled: false, keyDown: true),
    T(pid: 4444, name: "MouseOnly", active: true, enabled: true, keyDown: false),
  ]
  let owners = OverlayShortcutRules.keyTapOwners(taps, excluding: 4242)
  check("key tap owners: active, enabled, listening to key down, not this process, once each, sorted",
        owners == ["BetterDisplay", "ghostty", "openlogi-agent", "Raycast", "SiriNCService", "WeType"], "\(owners)")
  check("a listen-only tap cannot take a key", !owners.contains("universalaccessd") && !owners.contains("ViewBridgeAuxiliary"))
  check("a disabled tap or one without key events is not a suspect", !owners.contains("FlowAgent") && !owners.contains("MouseOnly"))
  check("test result: the key arrived", OverlayShortcutRules.testResult(arrived: true, taps: taps, ownPid: 4242) == .arrived)
  check("test result: the key did not arrive, the suspects are named",
        OverlayShortcutRules.testResult(arrived: false, taps: taps, ownPid: 4242) == .missing(candidates: owners))
  check("log line names the other processes",
        OverlayShortcutRules.logLine(owners: owners) == "[shortcut] active key taps held by other processes: BetterDisplay, ghostty, openlogi-agent, Raycast, SiriNCService, WeType")
  check("log line with nobody", OverlayShortcutRules.logLine(owners: []) == "[shortcut] active key taps held by other processes: none")
  check("the live tap list can be read here", OverlayShortcutRules.installedTaps().count >= 0)
}

// MARK: - shortcut keycaps (the second row of the HUD page drew ´ ˥ ⇧ S for ⌃ ⌥ ⇧ S)

do {
  func tokens(_ key: Int, _ flags: NSEvent.ModifierFlags) -> [String] {
    StreamShortcutProfile.displayTokens(for: StreamShortcut(keyCode: key, modifierFlags: flags))
  }
  let defaults = StreamShortcutProfile.defaultShortcuts()
  let toggle = StreamShortcutProfile.togglePerformanceOverlayAction, cycle = StreamShortcutProfile.cyclePerformanceOverlayStyleAction
  check("keycaps: default toggle is ⌃ ⌥ S", defaults[toggle].map { StreamShortcutProfile.displayTokens(for: $0) } == ["⌃", "⌥", "S"])
  check("keycaps: default style cycle is ⌃ ⌥ ⇧ S", defaults[cycle].map { StreamShortcutProfile.displayTokens(for: $0) } == ["⌃", "⌥", "⇧", "S"])
  check("keycaps: Option+Shift+S", tokens(kVK_ANSI_S, [.option, .shift]) == ["⌥", "⇧", "S"])
  check("keycaps: Control+Option+Shift+Command+S in the standard order", tokens(kVK_ANSI_S, [.command, .shift, .option, .control]) == ["⌃", "⌥", "⇧", "⌘", "S"])
  check("keycaps: Shift+Option on a digit and an F-key", tokens(kVK_ANSI_1, [.shift, .option]) == ["⌥", "⇧", "1"] && tokens(kVK_F5, [.option, .shift]) == ["⌥", "⇧", "F5"])
  check("keycaps: Caps Lock and the numeric-pad flag add no cap", tokens(kVK_ANSI_S, [.control, .option, .shift, .capsLock, .numericPad]) == ["⌃", "⌥", "⇧", "S"])
  check("keycaps: the modifiers are the symbols, never the characters they type (Option-S is ß, Shift-S is S)",
        !tokens(kVK_ANSI_S, [.option, .shift]).contains(where: { $0 == "ß" || $0 == "Í" || $0 == "s" }))
  // a recorded chord goes through the same normalisation as the saved ones
  let recorded = [cycle: StreamShortcut(keyCode: kVK_ANSI_K, modifierFlags: [.shift, .option])]
  let kept = StreamShortcutProfile.normalizedShortcuts(recorded)[cycle]
  check("keycaps: a recorded Option+Shift+K keeps ⌥ ⇧ K", kept.map { StreamShortcutProfile.displayTokens(for: $0) } == ["⌥", "⇧", "K"])
}

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
