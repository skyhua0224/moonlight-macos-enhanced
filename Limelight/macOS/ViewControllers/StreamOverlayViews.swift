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

