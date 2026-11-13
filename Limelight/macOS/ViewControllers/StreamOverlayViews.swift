//
//  StreamOverlayViews.swift
//  The views of the in-stream performance HUD, drawn after Apple's Metal Performance HUD:
//  a compact rounded translucent dark panel, SF Mono, small upper-case labels, tiny graphs, no text shadows.
//
//  Layout rules (user reports: the panel "twitches" and jumps to the left):
//  - The hosting view always covers the stream view; the panel is placed by SwiftUI alignment inside it. The edge the
//    panel is anchored to (left, right, centre line, top or bottom) never moves: there is no AppKit measuring pass,
//    no fittingSize, no second layout after a tick.
//  - Numbers sit in slots whose width is reserved (monospaced digits), so the panel is as wide as its items and does not
//    change width when a value gains or loses a digit. Only the set of items (fields, a warning) changes the size.
//  - Values change without any animation (no implicit transitions); only the fade-out of an idle panel is animated.
//

import AppKit
import SwiftUI

// MARK: - Scale

private struct OverlayScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }

extension EnvironmentValues {
  /// The size setting of the HUD (0.8 ... 1.5): every font size and graph size is multiplied by it.
  var overlayScale: CGFloat {
    get { self[OverlayScaleKey.self] }
    set { self[OverlayScaleKey.self] = newValue }
  }
}

@available(macOS 14.0, *)
private struct OverlayFontModifier: ViewModifier {
  @Environment(\.overlayScale) private var s
  let size: CGFloat
  let weight: Font.Weight
  func body(content: Content) -> some View { content.font(.system(size: size * s, weight: weight, design: .monospaced)) }
}

@available(macOS 14.0, *)
extension View {
  /// SF Mono at the HUD's size setting.
  func ovFont(_ size: CGFloat, _ weight: Font.Weight = .medium) -> some View { modifier(OverlayFontModifier(size: size, weight: weight)) }
}

// MARK: - Plate

/// The panel: the thin dark material under a black tint, a hairline edge, no shadow. Apple's HUD is a translucent dark
/// rounded rectangle; legibility comes from the panel, not from glows around the glyphs. `opacity` is the tint.
@available(macOS 14.0, *)
extension View {
  func overlayPanel<S: InsettableShape>(_ shape: S, opacity: Double) -> some View {
    self
      .environment(\.colorScheme, .dark)
      .background {
        ZStack {
          shape.fill(.ultraThinMaterial)
          shape.fill(Color.black.opacity(opacity))
        }
        .environment(\.colorScheme, .dark)
      }
      .overlay(shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
  }
}

enum OverlayInk {
  static let value = Color.white.opacity(0.96)
  static let label = Color.white.opacity(0.62)
  static let unit = Color.white.opacity(0.66)
  static let rule = Color.white.opacity(0.20)
  static let graph = Color(red: 0.46, green: 0.92, blue: 0.64)
}

// MARK: - Field icons (the corner list shows icons, not captions)

extension OverlayField {
  var symbol: String {
    switch self {
    case .elapsed: return "stopwatch"
    case .route: return "wifi"
    case .quality: return "sparkles.tv"
    case .clock: return "clock"
    case .battery: return "battery.75percent"
    case .resolution: return "rectangle.on.rectangle"
    case .codec: return "film"
    case .chroma: return "paintpalette"
    case .hdr: return "sun.max"
    case .fps: return "speedometer"
    case .fpsReceived: return "arrow.down.circle"
    case .fpsDecoded: return "cpu"
    case .onePercentLow: return "arrow.down.to.line"
    case .streamLatency: return "timer"
    case .rtt: return "arrow.left.arrow.right"
    case .loss: return "square.stack.3d.down.right"
    case .netLoss: return "antenna.radiowaves.left.and.right"
    case .fec: return "shield.lefthalf.filled"
    case .parity: return "shield"
    case .jitter: return "waveform.path.ecg"
    case .bitrate: return "arrow.down.right.and.arrow.up.left"
    case .pacing: return "metronome"
    case .renderP99: return "chart.xyaxis.line"
    case .stalls: return "pause.circle"
    case .pipeline: return "point.3.connected.trianglepath.dotted"
    case .hostEncode: return "desktopcomputer"
    case .decode: return "film.stack"
    case .queue: return "tray.full"
    }
  }
}

// MARK: - Pieces

/// A tiny line chart (or bars) over a ring buffer. Drawn at the stats rate, not per frame.
@available(macOS 14.0, *)
struct OverlaySparkline: View {
  let values: [Double]
  var tint: Color = OverlayInk.graph
  /// A reference value drawn as a thin line (e.g. the frame interval of the target fps).
  var target: Double?
  var bars = false

  var body: some View {
    Canvas { ctx, size in
      guard values.count > 1 else { return }
      var top = max(values.max() ?? 1, (target ?? 0) * 1.6, 0.001)
      var low = min(values.min() ?? 0, 0)
      if !bars {
        // a line chart ranges to its own data (with a little air), so a steady value is still a visible line
        let lo = values.min() ?? 0, hi = values.max() ?? 1
        let pad = max((hi - lo) * 0.2, abs(hi) * 0.06, 0.05)
        low = lo - pad; top = hi + pad
      }
      let span = max(top - low, 0.001)
      func y(_ v: Double) -> CGFloat { size.height - CGFloat((v - low) / span) * size.height }
      if bars {
        let w = size.width / CGFloat(values.count)
        for (i, v) in values.enumerated() {
          let h = max(1.5, CGFloat((v - low) / span) * size.height)
          let rect = CGRect(x: CGFloat(i) * w + 0.5, y: size.height - h, width: max(1, w - 1.5), height: h)
          ctx.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(tint.opacity(0.85)))
        }
      } else {
        var line = Path()
        for (i, v) in values.enumerated() {
          let p = CGPoint(x: size.width * CGFloat(i) / CGFloat(values.count - 1), y: y(v))
          if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
        }
        var fill = line
        fill.addLine(to: CGPoint(x: size.width, y: size.height))
        fill.addLine(to: CGPoint(x: 0, y: size.height))
        fill.closeSubpath()
        ctx.fill(fill, with: .linearGradient(Gradient(colors: [tint.opacity(0.26), tint.opacity(0.02)]),
                                             startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
        ctx.stroke(line, with: .color(tint), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
      }
      if let target {
        var t = Path()
        t.move(to: CGPoint(x: 0, y: y(target))); t.addLine(to: CGPoint(x: size.width, y: y(target)))
        ctx.stroke(t, with: .color(Color.white.opacity(0.5)), style: StrokeStyle(lineWidth: 0.7, dash: [3, 2]))
      }
    }
  }
}

/// A small upper-case caption (Latin text; Chinese is unaffected by the case).
@available(macOS 14.0, *)
struct OverlayCaption: View {
  let text: String
  var body: some View {
    Text(text).ovFont(9.5, .medium).textCase(.uppercase).tracking(0.4).foregroundStyle(OverlayInk.label).lineLimit(1).fixedSize()
  }
}

/// value with a smaller secondary unit: "26" + "ms". The slot reserves the width of the digits.
@available(macOS 14.0, *)
struct OverlayValueText: View {
  let value: OverlayValue
  var size: CGFloat = 12.5
  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 2) {
      // the slot reserves the width of the digits, the number sits at its right end
      ZStack(alignment: .trailing) {
        if !value.slot.isEmpty { Text(value.slot).ovFont(size, .medium).hidden() }
        Text(value.text).ovFont(size, .medium).foregroundStyle(value.level.color)
      }
      .fixedSize()
      if !value.unit.isEmpty { Text(value.unit).ovFont(max(size - 3, 9.5), .medium).foregroundStyle(OverlayInk.unit).fixedSize() }
    }
    .lineLimit(1)
  }
}

@available(macOS 14.0, *)
struct OverlayDot: View {
  let level: OverlayLevel
  var size: CGFloat = 6
  @Environment(\.overlayScale) private var s
  var body: some View { Circle().fill(level.dot).frame(width: size * s, height: size * s) }
}

/// A warning as one item in a row: a triangle and the text in amber.
@available(macOS 14.0, *)
struct OverlayWarningItem: View {
  let text: String
  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: "exclamationmark.triangle.fill").ovFont(9.5)
      Text(text).ovFont(10.5, .medium).lineLimit(1)
    }
    .foregroundStyle(OverlayLevel.high.color)
    .fixedSize()
  }
}

enum OverlayFlowRole { case item, divider }

struct OverlayFlowRoleKey: LayoutValueKey {
  static let defaultValue = OverlayFlowRole.item
}

/// Lays groups out on one row and wraps only when the row would be wider than `maxWidth`, with the measured
/// width of every group (no estimate). The divider between two groups is dropped where a row starts.
/// The breaking itself is OverlayFlowPlanner (tested on its own).
@available(macOS 14.0, *)
struct OverlayFlowLayout: Layout {
  var maxWidth: CGFloat
  var rowSpacing: CGFloat = 5
  var maxRows = 4

  private func plan(_ subviews: Subviews) -> OverlayFlowPlanner.Plan {
    let items = subviews.map { sub -> OverlayFlowPlanner.Item in
      let size = sub.sizeThatFits(.unspecified)
      return OverlayFlowPlanner.Item(width: size.width, height: size.height, isDivider: sub[OverlayFlowRoleKey.self] == .divider)
    }
    return OverlayFlowPlanner.plan(items, maxWidth: maxWidth, rowSpacing: rowSpacing, maxRows: maxRows)
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    plan(subviews).size
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let result = plan(subviews)
    // rows are as high as their tallest item: each item is centred in its row
    var rowHeights: [Int: CGFloat] = [:]
    for (i, sub) in subviews.enumerated() {
      guard let p = result.placements[i] else { continue }
      rowHeights[p.row] = max(rowHeights[p.row] ?? 0, sub.sizeThatFits(.unspecified).height)
    }
    for (i, sub) in subviews.enumerated() {
      if let p = result.placements[i] {
        let size = sub.sizeThatFits(.unspecified)
        let dy = ((rowHeights[p.row] ?? size.height) - size.height) / 2
        sub.place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y + dy), proposal: ProposedViewSize(size))
      } else {
        sub.place(at: CGPoint(x: -20_000, y: -20_000), proposal: .zero)
      }
    }
  }
}

// MARK: - Root

@available(macOS 14.0, *)
extension OverlayPosition {
  var alignment: Alignment {
    switch self {
    case .topLeft: return .topLeading
    case .topCenter: return .top
    case .topRight: return .topTrailing
    case .bottomLeft: return .bottomLeading
    case .bottomCenter: return .bottom
    case .bottomRight: return .bottomTrailing
    }
  }
}

/// What the panel is placed in: the size of the stream view and the top inset the camera housing / title bar takes.
struct OverlayGeometry: Equatable {
  var width: CGFloat = 1280
  var height: CGFloat = 720
  var safeTop: CGFloat = 0
  /// Space kept clear (points): remote title bars / notch at the top, the remote taskbar or Dock at the bottom.
  static let sideInset: CGFloat = 14
  static let topMargin: CGFloat = 10
  static let bottomSafeInset: CGFloat = 64
  /// Clear space at the bottom; the settings preview uses a small one.
  var bottomInset: CGFloat = OverlayGeometry.bottomSafeInset
  /// How wide a row of the panel may get before it wraps.
  var maxWidth: CGFloat { min(1500, max(200, width - Self.sideInset * 2)) }
}

@available(macOS 14.0, *)
struct OverlayRoot: View {
  @ObservedObject var model: OverlayModel
  @ObservedObject var prefs: OverlayPrefs

  private var faded: Bool { prefs.autoFade && model.faded && model.anomalies.isEmpty }

  var body: some View {
    let g = model.geometry
    let position = prefs.position
    Group {
      if !model.hasData && !model.poor {
        EmptyView()
      } else if let notch = model.notch {
        OverlayNotchSplit(model: model, prefs: prefs, notch: notch)
          .frame(width: notch.leftWidth + notch.gap + notch.rightWidth, height: notch.height)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          .padding(.leading, notch.originX).padding(.top, notch.topOffset)
      } else {
        panel
          .transaction { $0.animation = nil }   // a changing value never animates the panel
          .opacity(faded ? 0.35 : 1)
          .animation(.easeInOut(duration: 0.4), value: faded)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: position.alignment)
          .padding(.horizontal, OverlayGeometry.sideInset)
          .padding(.top, g.safeTop + OverlayGeometry.topMargin)
          .padding(.bottom, position.isBottom ? g.bottomInset : OverlayGeometry.topMargin)
      }
    }
    .environment(\.overlayScale, CGFloat(prefs.scale))
    .environment(\.colorScheme, .dark)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  @ViewBuilder private var panel: some View {
    Group {
      switch prefs.style {
      case .legacy: EmptyView()
      case .textBar: OverlayCompact(model: model, prefs: prefs)
      case .cornerList: OverlayCorner(model: model, prefs: prefs)
      case .chartHUD: OverlayChart(model: model, prefs: prefs)
      }
    }
    .fixedSize()
    .background {
      // the settings preview asks for the panel's size, to scale a tall panel into its small card; a stream never does
      if model.reportsSize {
        GeometryReader { geo in Color.clear.preference(key: OverlayPanelSizeKey.self, value: geo.size) }
      }
    }
    .overlayProbe(model)
  }
}

struct OverlayPanelSizeKey: PreferenceKey {
  static let defaultValue = CGSize.zero
  static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

#if MLC_CONCEPT_HARNESS
/// Harness only: records where the panel really is (window coordinates), to prove it never moves.
@available(macOS 14.0, *)
extension View {
  func overlayProbe(_ model: OverlayModel) -> some View {
    background(GeometryReader { geo in
      Color.clear.onChange(of: geo.frame(in: .global), initial: true) { _, frame in OverlayStability.shared.record(frame) }
    })
  }
}

final class OverlayStability: NSObject {
  static let shared = OverlayStability()
  private(set) var frames: [CGRect] = []
  private var last: CGRect?
  func record(_ frame: CGRect) { frames.append(frame); last = frame }
  /// Starts counting again from the frame the panel has now.
  func reset() { frames = last.map { [$0] } ?? [] }
}
#else
@available(macOS 14.0, *)
extension View {
  func overlayProbe(_ model: OverlayModel) -> some View { self }
}
#endif

// MARK: - Items

/// The shown items in the user's order, cut into runs of one group each (a divider sits between two runs).
@available(macOS 14.0, *)
func overlayGrouped(_ prefs: OverlayPrefs, _ m: OverlayMetrics) -> [(OverlayGroup, [(OverlayField, OverlayValue)])] {
  var result: [(OverlayGroup, [(OverlayField, OverlayValue)])] = []
  for field in prefs.style.shown(prefs.fields) {
    guard let value = overlayValue(field, m) else { continue }
    if let last = result.last, last.0 == field.group { result[result.count - 1].1.append((field, value)) }
    else { result.append((field.group, [(field, value)])) }
  }
  return result
}

/// One "caption value" pair in running text.
@available(macOS 14.0, *)
struct OverlayPair: View {
  let field: OverlayField
  let value: OverlayValue
  static let unlabelled: Set<OverlayField> = [.resolution, .codec, .chroma, .hdr, .elapsed, .route, .quality, .clock, .battery]
  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 4) {
      if !Self.unlabelled.contains(field) { OverlayCaption(text: field.title) }
      OverlayValueText(value: value)
    }
    .fixedSize()
  }
}

// MARK: - 1. Compact: one row, as wide as its items

@available(macOS 14.0, *)
struct OverlayCompact: View {
  @ObservedObject var model: OverlayModel
  @ObservedObject var prefs: OverlayPrefs
  @Environment(\.overlayScale) private var s

  /// Half of the space between two items; every item carries it on both sides, so a wrapped row needs no special case.
  private var gap: CGFloat { 4.5 * s }

  private var divider: some View {
    Rectangle().fill(OverlayInk.rule).frame(width: 1, height: 12 * s).padding(.horizontal, gap)
      .layoutValue(key: OverlayFlowRoleKey.self, value: .divider)
  }

  var body: some View {
    let groups = overlayGrouped(prefs, model.m)
    let warning = prefs.expandOnAnomaly ? model.anomalies : []
    // Every pair is its own item, so a row can break between any two of them and only when it has to; the divider
    // between two groups is dropped where a row starts (OverlayFlowPlanner).
    OverlayFlowLayout(maxWidth: model.geometry.maxWidth - 2 * (12 * s - gap), rowSpacing: 4 * s) {
      ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
        if index > 0 { divider }
        ForEach(group.1, id: \.0) { OverlayPair(field: $0.0, value: $0.1).padding(.horizontal, gap) }
      }
      if !warning.isEmpty {
        if !groups.isEmpty { divider }
        OverlayWarningItem(text: warning.joined(separator: " · ")).padding(.horizontal, gap)
      }
    }
    .padding(.horizontal, 12 * s - gap).padding(.vertical, 7 * s)
    .overlayPanel(RoundedRectangle(cornerRadius: 10 * s, style: .continuous), opacity: prefs.plateOpacity)
  }
}

// MARK: - 2. Corner: icons and values in a column

@available(macOS 14.0, *)
struct OverlayCorner: View {
  @ObservedObject var model: OverlayModel
  @ObservedObject var prefs: OverlayPrefs
  @Environment(\.overlayScale) private var s

  private func ring(_ field: OverlayField) -> OverlayRing? {
    switch field {
    case .fps: return model.fps
    case .streamLatency: return model.latency
    case .bitrate: return model.bitrate
    default: return nil
    }
  }

  private func symbol(_ field: OverlayField) -> String {
    guard field == .route else { return field.symbol }
    let route = model.m.route
    if route == "remote" || route.contains(DL("deck.route.public")) { return "globe" }
    return route.contains(DL("deck.route.relay")) ? "point.3.connected.trianglepath.dotted" : "wifi"
  }

  var body: some View {
    let rows = prefs.style.shown(prefs.fields).compactMap { f in overlayValue(f, model.m).map { (f, $0) } }
    let hasGraph = rows.contains { ring($0.0) != nil }
    VStack(alignment: .leading, spacing: 6 * s) {
      Grid(alignment: .leading, horizontalSpacing: 7 * s, verticalSpacing: 4 * s) {
        ForEach(rows, id: \.0) { field, value in
          GridRow {
            Image(systemName: symbol(field)).ovFont(10.5).foregroundStyle(OverlayInk.label)
              .frame(width: 14 * s).gridColumnAlignment(.center)
            if value.slot.isEmpty {
              // text that does not change width (resolution, codec, the time): one cell across the number and unit columns
              Text(value.text).ovFont(12.5, .medium).foregroundStyle(value.level.color).lineLimit(1).fixedSize()
                .gridCellColumns(2).gridColumnAlignment(.leading)
            } else {
              // the numbers of all rows end on one line, the units start on another
              ZStack(alignment: .trailing) {
                Text(value.slot).ovFont(12.5, .medium).hidden()
                Text(value.text).ovFont(12.5, .medium).foregroundStyle(value.level.color)
              }
              .fixedSize().gridColumnAlignment(.trailing)
              Text(value.unit).ovFont(9.5, .medium).foregroundStyle(OverlayInk.unit).lineLimit(1).fixedSize().gridColumnAlignment(.leading)
            }
            if hasGraph {
              if let ring = ring(field) { OverlaySparkline(values: ring.values).frame(width: 36 * s, height: 11 * s) }
              else { Color.clear.frame(width: 36 * s, height: 1) }
            }
          }
        }
      }
      if prefs.expandOnAnomaly, !model.anomalies.isEmpty { OverlayWarningItem(text: model.anomalies.joined(separator: " · ")) }
    }
    .padding(.horizontal, 11 * s).padding(.vertical, 9 * s)
    .overlayPanel(RoundedRectangle(cornerRadius: 12 * s, style: .continuous), opacity: prefs.plateOpacity)
  }
}

// MARK: - 3. Chart: big frame rate, interval bars, mini graphs

@available(macOS 14.0, *)
struct OverlayChart: View {
  @ObservedObject var model: OverlayModel
  @ObservedObject var prefs: OverlayPrefs
  @Environment(\.overlayScale) private var s

  private func mini(_ field: OverlayField, _ ring: OverlayRing) -> some View {
    let value = overlayValue(field, model.m)
    return GridRow {
      OverlayCaption(text: field.title).gridColumnAlignment(.leading)
      OverlaySparkline(values: ring.values, tint: OverlayInk.graph).frame(width: 84 * s, height: 14 * s)
      if let value { OverlayValueText(value: value, size: 12).gridColumnAlignment(.leading) } else { Color.clear.frame(width: 1, height: 1) }
    }
  }

  /// The graph rows in the user's order; loss and network loss are one row.
  private func miniRows(shown: Set<OverlayField>, order: [OverlayField]) -> [(OverlayField, OverlayRing)] {
    var rows: [(OverlayField, OverlayRing)] = []
    var lossDone = false
    for field in order {
      switch field {
      case .streamLatency: rows.append((field, model.latency))
      case .bitrate: rows.append((field, model.bitrate))
      case .pipeline: rows.append((field, model.pipeline))
      case .loss, .netLoss:
        if !lossDone { lossDone = true; rows.append((model.m.netAvailable && shown.contains(.netLoss) ? .netLoss : .loss, model.loss)) }
      default: break
      }
    }
    return rows
  }

  var body: some View {
    let m = model.m
    let order = prefs.style.shown(prefs.fields)
    let shown = Set(order)
    let interval = 1000 / Double(max(m.configuredFps, 1))
    let chips = [OverlayField.resolution, .codec, .chroma, .hdr].filter { shown.contains($0) }.compactMap { f in overlayValue(f, m).map { (f, $0) } }
    VStack(alignment: .leading, spacing: 7 * s) {
      if shown.contains(.fps), let fps = overlayValue(.fps, m) {
        HStack(alignment: .firstTextBaseline, spacing: 5 * s) {
          OverlayDot(level: model.overall)
          ZStack(alignment: .trailing) {
            Text(fps.slot).ovFont(26, .medium).hidden()
            Text(fps.text).ovFont(26, .medium).foregroundStyle(fps.level.color)
          }.fixedSize()
          OverlayCaption(text: "fps")
          Spacer(minLength: 8 * s)
          Text("\(DL("ov.target")) \(m.configuredFps)").ovFont(9.5).foregroundStyle(OverlayInk.label).fixedSize()
        }
      }
      if !chips.isEmpty {
        HStack(spacing: 7 * s) { ForEach(chips, id: \.0) { Text($0.1.text).ovFont(10.5, .medium).foregroundStyle(OverlayInk.value).fixedSize() } }
      }
      if shown.contains(.renderP99) {
        OverlaySparkline(values: model.interval.values, tint: OverlayInk.graph, target: interval, bars: true)
          .frame(maxWidth: .infinity).frame(height: 28 * s)
      }
      Grid(alignment: .leading, horizontalSpacing: 8 * s, verticalSpacing: 5 * s) {
        ForEach(miniRows(shown: shown, order: order), id: \.0) { mini($0.0, $0.1) }
      }
      if prefs.expandOnAnomaly, !model.anomalies.isEmpty { OverlayWarningItem(text: model.anomalies.joined(separator: " · ")) }
    }
    .padding(.horizontal, 12 * s).padding(.vertical, 10 * s)
    .overlayPanel(RoundedRectangle(cornerRadius: 12 * s, style: .continuous), opacity: prefs.plateOpacity)
  }
}

// MARK: - Notch split: left group | camera housing | right group

@available(macOS 14.0, *)
struct OverlayNotchSplit: View {
  @ObservedObject var model: OverlayModel
  @ObservedObject var prefs: OverlayPrefs
  let notch: OverlayNotch

  private func pill(_ fields: [OverlayField]) -> some View {
    let items = fields.compactMap { f in overlayValue(f, model.m).map { (f, $0) } }
    return HStack(spacing: 8) {
      ForEach(items, id: \.0) { item in OverlayValueText(value: item.1, size: 11) }
    }
    .padding(.horizontal, 9).frame(height: min(notch.height - 8, 22))
    .overlayPanel(Capsule(), opacity: prefs.plateOpacity)
    .fixedSize()
    .opacity(items.isEmpty ? 0 : 1)
  }

  var body: some View {
    let shown = prefs.style.shown(prefs.fields)
    // video and frame rate on the left, network and the rest on the right
    let leftGroups: Set<OverlayGroup> = [.video, .rate]
    let left = shown.filter { leftGroups.contains($0.group) }
    let right = shown.filter { !leftGroups.contains($0.group) }
    HStack(spacing: 0) {
      HStack(spacing: 6) { OverlayDot(level: model.overall); pill(left) }.frame(width: notch.leftWidth - 12, alignment: .trailing)
      Color.clear.frame(width: notch.gap + 12)
      pill(right).frame(width: notch.rightWidth - 12, alignment: .leading)
    }
    .frame(width: notch.leftWidth + notch.gap + notch.rightWidth, height: notch.height)
    .transaction { $0.animation = nil }
  }
}
