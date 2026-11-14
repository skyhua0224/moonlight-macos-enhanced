// Layout of the performance HUD, with the real views: one OverlayRoot in an offscreen hosting view the size of a stream
// window, rendered to a bitmap. The panel is whatever is not transparent. Checks (user reports):
//  - the panel is as wide as its items and does not change size when values change (any digit count)
//  - the anchored edge never moves (left, right, centre line, top, bottom), whatever the values and the warning
//  - the size changes only when the set of items changes
//  - it is never a full-width bar
import AppKit
import SwiftUI

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
  print((ok ? "PASS " : "FAIL ") + name + (ok ? "" : "  -- " + detail()))
  if !ok { failures += 1 }
}

_ = NSApplication.shared

func metrics(_ seed: Int, configured: Int = 144) -> OverlayMetrics {
  let m = OverlaySample.metrics(tick: seed, anomaly: false)
  var s = UInt64(seed &* 2654435761 &+ 99)
  func next() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double((s >> 33) & 0xFFFFF) / Double(0xFFFFF) }
  m.configuredFps = configured
  let fps: [Float] = [144, 98, 59, 61, 9, 120, 7, 143, 100, 33]
  m.renderedFps = fps[seed % fps.count]; m.receivedFps = m.renderedFps; m.decodedFps = m.renderedFps
  m.onePercentLow = Float(next() * Double(configured))
  m.streamLatencyMs = Float(1 + next() * 160); m.rttMs = Float(1 + next() * 140)
  m.bitrateMbps = 0.4 + next() * 230
  m.jitterMs = Float(next() * 30); m.pacingJitterMs = Float(next() * 12)
  m.renderP99Ms = Float(4 + next() * 140); m.pipelineMs = Float(2 + next() * 90)
  m.hostMs = Float(next() * 30); m.decodeMs = Float(next() * 25); m.queueMs = Float(next() * 20)
  m.lossPercent = Float(next() * 3); m.netLossPercent = m.lossPercent
  m.elapsedSeconds = Double(seed) * 3.7 + 5
  m.clientTime = String(format: "%02d:%02d", 9 + seed % 14, seed % 60)
  return m
}

/// Bounding box of everything drawn (alpha > 0) in the hosting view, in view coordinates, origin top left.
func drawnBox(_ hosting: NSView) -> CGRect? {
  hosting.layoutSubtreeIfNeeded()
  guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
  hosting.cacheDisplay(in: hosting.bounds, to: rep)
  var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
  let scale = CGFloat(rep.pixelsWide) / hosting.bounds.width
  for y in 0..<rep.pixelsHigh {
    for x in 0..<rep.pixelsWide {
      if let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.02 {
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
      }
    }
  }
  if maxX < 0 { return nil }
  return CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale, width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
}

struct Setup {
  var style: OverlayStyle
  var position: OverlayPosition
  var fields: [OverlayField]
}

func makeRoot(_ setup: Setup, width: CGFloat = 1280, height: CGFloat = 720) -> (NSHostingView<OverlayRoot>, OverlayModel, OverlayPrefs) {
  let prefs = OverlayPrefs()
  prefs.style = setup.style
  prefs.positionRaw = setup.position.rawValue
  prefs.fields = setup.fields
  prefs.scale = 1
  let model = OverlayModel()
  model.geometry = OverlayGeometry(width: width, height: height, safeTop: 0)
  for t in 0..<96 { model.apply(metrics(t), now: Date().addingTimeInterval(Double(t) * 0.5 - 48)) }
  let hosting = NSHostingView(rootView: OverlayRoot(model: model, prefs: prefs))
  hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
  if #available(macOS 13.3, *) { hosting.safeAreaRegions = [] }
  return (hosting, model, prefs)
}

let usual = OverlayField.usual
let manyFields: [OverlayField] = [.resolution, .codec, .fps, .onePercentLow, .streamLatency, .rtt, .loss, .bitrate, .jitter, .renderP99, .pipeline, .elapsed, .clock]
let chartFields: [OverlayField] = [.resolution, .codec, .fps, .renderP99, .streamLatency, .bitrate, .loss, .pipeline]

// MARK: size does not depend on values
for (name, style, fields) in [("compact", OverlayStyle.textBar, usual), ("compact (many items)", .textBar, manyFields),
                              ("corner", .cornerList, manyFields), ("chart", .chartHUD, chartFields)] {
  let (hosting, model, _) = makeRoot(Setup(style: style, position: .topLeft, fields: fields))
  var boxes: [CGRect] = []
  for seed in 200..<240 {
    model.apply(metrics(seed))
    if let b = drawnBox(hosting) { boxes.append(b) }
  }
  let widths = Set(boxes.map { Int($0.width.rounded()) }), heights = Set(boxes.map { Int($0.height.rounded()) })
  check("\(name): 40 ticks of values with 1 to 3 digit numbers, one panel width", widths.count == 1, "\(widths.sorted())")
  check("\(name): same for the height", heights.count == 1, "\(heights.sorted())")
  if let b = boxes.first {
    check("\(name): the panel is not a full-width bar (\(Int(b.width)) of 1280)", b.width < 1280 - 28, "\(b)")
  }
}

// MARK: the anchored edge never moves
let anchors: [(OverlayPosition, String)] = [(.topLeft, "left"), (.topCenter, "centre"), (.topRight, "right"),
                                            (.bottomLeft, "left"), (.bottomCenter, "centre"), (.bottomRight, "right")]
for style in OverlayStyle.choosable {
  for (position, edge) in anchors {
    let fields = style == .chartHUD ? chartFields : manyFields
    let (hosting, model, _) = makeRoot(Setup(style: style, position: position, fields: fields))
    var boxes: [CGRect] = []
    for seed in 300..<325 {
      model.apply(metrics(seed))
      if let b = drawnBox(hosting) { boxes.append(b) }
    }
    guard let first = boxes.first else { check("\(style) at \(position): something is drawn", false); continue }
    let xs: Set<Int>
    switch edge {
    case "left": xs = Set(boxes.map { Int($0.minX.rounded()) })
    case "right": xs = Set(boxes.map { Int($0.maxX.rounded()) })
    default: xs = Set(boxes.map { Int($0.midX.rounded()) })
    }
    let ys = Set(boxes.map { position.isBottom ? Int($0.maxY.rounded()) : Int($0.minY.rounded()) })
    check("\(style) at \(position): \(edge) edge fixed over 25 ticks", xs.count == 1 && ys.count == 1, "x=\(xs.sorted()) y=\(ys.sorted())")
    // inside the margins
    check("\(style) at \(position): inside the side margins", first.minX >= 13.5 && first.maxX <= 1280 - 13.5, "\(first)")
    if position.isBottom { check("\(style) at \(position): keeps 64 pt clear at the bottom", first.maxY <= 720 - 63.5, "\(first)") }
  }
}

// MARK: a warning changes the size (a new item), never the anchored edge
do {
  let (hosting, model, _) = makeRoot(Setup(style: .textBar, position: .topRight, fields: usual))
  guard let before = drawnBox(hosting) else { fatalError("nothing drawn") }
  model.anomalies = ["warning"]
  guard let after = drawnBox(hosting) else { fatalError("nothing drawn") }
  check("compact topRight: a warning makes the panel wider", after.width > before.width, "\(before.width) -> \(after.width)")
  check("compact topRight: the right edge stays where it was", Int(after.maxX.rounded()) == Int(before.maxX.rounded()), "\(before.maxX) -> \(after.maxX)")
  check("compact topRight: the top stays where it was", Int(after.minY.rounded()) == Int(before.minY.rounded()))
  model.anomalies = []
  let back = drawnBox(hosting)
  check("compact topRight: the warning gone, the panel is the old size again", back.map { Int($0.width.rounded()) } == Int(before.width.rounded()))
}

// MARK: size changes only with the set of items
do {
  let (hosting, _, prefs) = makeRoot(Setup(style: .textBar, position: .topLeft, fields: [.fps, .streamLatency]))
  let two = drawnBox(hosting)!.width
  prefs.fields = [.fps, .streamLatency, .bitrate]
  let three = drawnBox(hosting)!.width
  check("one more item: wider (\(Int(two)) -> \(Int(three)))", three > two + 20)
  prefs.fields = [.fps]
  let one = drawnBox(hosting)!.width
  check("one item: narrower than two", one < two)
  prefs.scale = 1.4
  let big = drawnBox(hosting)!.width
  check("size 140 %: the panel grows (\(Int(one)) -> \(Int(big)))", big > one * 1.3)
}

// MARK: wraps only when the screen is truly too narrow
do {
  let (wide, _, _) = makeRoot(Setup(style: .textBar, position: .topLeft, fields: usual), width: 1920)
  let (mid, _, _) = makeRoot(Setup(style: .textBar, position: .topLeft, fields: usual), width: 1280)
  let w = drawnBox(wide)!, m = drawnBox(mid)!
  check("1920 wide: the usual items on one row (\(Int(w.width)) x \(Int(w.height)))", w.height < 34, "\(w)")
  check("1280 wide: still one row", m.height < 34 && m.width == w.width, "\(m)")
  let (narrow, _, _) = makeRoot(Setup(style: .textBar, position: .topLeft, fields: usual), width: Int(w.width) - 20 > 0 ? w.width - 20 : 300)
  let n = drawnBox(narrow)!
  check("20 pt narrower than the row: two rows, inside the screen (\(Int(n.width)) x \(Int(n.height)))", n.height > w.height + 10 && n.maxX <= w.width - 20 - 13.5, "\(n)")
  let (tiny, _, _) = makeRoot(Setup(style: .textBar, position: .topLeft, fields: manyFields), width: 520)
  let t = drawnBox(tiny)!
  check("520 wide with many items: wraps and stays inside the screen", t.height > 60 && t.minX >= 13.5 && t.maxX <= 520 - 13.5, "\(t)")
}

// MARK: styles stored by older builds, and the order of the cycle shortcut
do {
  check("the full-width strip, sectioned bar, capsule, detailed and anomaly-only styles of older builds become compact",
        ["topStrip", "sectioned", "capsule", "detailed", "anomalyOnly", "nonsense", ""].allSatisfy { OverlayStyle.stored($0) == .textBar })
  check("the three current styles are kept as stored", OverlayStyle.stored("textBar") == .textBar && OverlayStyle.stored("cornerList") == .cornerList && OverlayStyle.stored("chartHUD") == .chartHUD)
  check("nothing stored: compact", OverlayStyle.stored(nil) == .textBar)
  check("the settings page offers compact, corner, chart in that order", OverlayStyle.choosable == [.textBar, .cornerList, .chartHUD])
  let prefs = OverlayPrefs()
  prefs.style = .textBar
  var visited: [OverlayStyle] = []
  for _ in 0..<4 { OverlayPrefsBridge.cycleStyle(); visited.append(OverlayPrefs.shared.style) }
  check("the cycle shortcut visits corner, chart, compact, corner (never the old one-line style)", visited == [.cornerList, .chartHUD, .textBar, .cornerList], "\(visited)")
  check("six positions: three at the top, three at the bottom", OverlayPosition.allCases.count == 6 && OverlayPosition.allCases.filter { $0.isBottom }.count == 3)
  let reset = OverlayPrefs()
  reset.style = .chartHUD; reset.positionRaw = "bottomLeft"; reset.scale = 1.3; reset.plateOpacity = 0.8
  reset.resetToDefaults()
  check("reset to defaults", reset.style == .textBar && reset.positionRaw == "auto" && reset.scale == 1 && reset.plateOpacity == OverlayPrefs.defaultPlateOpacity && reset.fields == OverlayField.usual)
  check("the plate default is lighter than the old tint (0.50 over a light material) would read: tint 0.55 over the dark material", OverlayPrefs.defaultPlateOpacity == 0.55)
}

// MARK: the order of the items is the user's
do {
  check("the shown items keep the order of the list, once each",
        OverlayStyle.textBar.shown([.bitrate, .fps, .bitrate, .clock, .streamLatency]) == [.bitrate, .fps, .clock, .streamLatency])
  check("the chart keeps the order of the items it has room for",
        OverlayStyle.chartHUD.shown([.bitrate, .clock, .fps, .streamLatency]) == [.bitrate, .fps, .streamLatency])
  let prefs = OverlayPrefs()
  prefs.fields = [.fps, .streamLatency, .bitrate]
  prefs.moveFields(from: IndexSet(integer: 2), to: 0)
  check("drag the last row to the top", prefs.fields == [.bitrate, .fps, .streamLatency], "\(prefs.fields)")
  prefs.moveFields(from: IndexSet(integer: 0), to: 3)
  check("drag the first row to the end", prefs.fields == [.fps, .streamLatency, .bitrate], "\(prefs.fields)")
  prefs.toggle(.clock)
  check("a ticked item joins at the end", prefs.fields == [.fps, .streamLatency, .bitrate, .clock])
  prefs.toggle(.fps)
  check("an unticked item leaves, the rest keep their order", prefs.fields == [.streamLatency, .bitrate, .clock])
  prefs.fields = [.fps, .streamLatency, .onePercentLow, .bitrate]
  let m = OverlaySample.metrics(tick: 5, anomaly: false)
  let groups = overlayGrouped(prefs, m)
  check("the compact bar cuts runs of one group where the order changes group",
        groups.map { $0.0 } == [.rate, .network, .rate, .network] && groups.map { $0.1.count } == [1, 1, 1, 1], "\(groups.map { $0.0 })")
  prefs.fields = [.fps, .onePercentLow, .streamLatency, .bitrate]
  check("neighbours of one group stay in one run", overlayGrouped(prefs, m).map { $0.1.count } == [2, 2])
  // the order shows in the picture: the same two items swapped draw the same width but not the same picture
  let (hosting, _, p2) = makeRoot(Setup(style: .cornerList, position: .topLeft, fields: [.fps, .streamLatency, .bitrate]))
  let a = drawnBox(hosting)!
  p2.fields = [.bitrate, .streamLatency, .fps]
  let b = drawnBox(hosting)!
  check("reordering keeps the size of the panel", Int(a.width.rounded()) == Int(b.width.rounded()) && Int(a.height.rounded()) == Int(b.height.rounded()), "\(a) \(b)")
}

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
