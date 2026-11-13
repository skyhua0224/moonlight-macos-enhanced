//
//  OverlayHealth.swift
//  When the in-stream overlay may say something is wrong, and how its row layout breaks lines.
//  Foundation only, so tests/overlay compiles it on its own.
//
//  Why this exists (a user log of 504 [perf] lines): the old overlay
//  showed a warning line on 34..70 % of the seconds and coloured the fps value amber or red on 25..90 % of them
//  while the client rendered exactly what it received (rd == rx on every line). The causes were
//   - fps and 1% low were judged against the configured rate (120/144); a game that limits itself to 60, or a host
//     that sends only changed frames (10..60 fps on a quiet screen), looked like a failure;
//   - "stalls" counted every render interval over 100 ms, including the ones where the host simply sent no frame,
//     and it was a count over a window of up to 3600 samples that went up whenever one more gap was seen;
//   - the 3 s network-loss window was warned at 1 %, which is one lost frame out of 100 (a screen sending 30 fps
//     has 90 frames in that window), and every value was colour-flagged on a single window.
//  A warning now needs a count and a rate over a 10 s window and is kept for 4 s so it can be read.
//

import Foundation

// MARK: - Levels

enum OverlayHealthLevel: Int, Comparable {
  case normal, high, bad
  static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

// MARK: - What the detector looks at, and what it says

/// One stats tick (every 0.5 s).
struct OverlayHealthSample {
  var time: TimeInterval
  var renderedFps: Float
  var receivedFps: Float
  var onePercentLow: Float
  var netAvailable: Bool
  /// common-c, share of frames lost in its last 3 s window.
  var netLossPercent: Float
  /// Client-side share of frames dropped for the network (used when common-c has no figure).
  var clientDropPercent: Float
  /// Render intervals over 100 ms that the client added itself, counted since the stream started.
  var clientStallTotal: UInt32
  var noPayloadSeconds: Int
  var frozenSeconds: Int
  var poor: Bool
}

enum OverlayWarning: Equatable {
  case netLoss(percent: Float)
  case clientLoss(percent: Float)
  case stalls(count: Int)
  case lowPacing(fps: Float)
  case noData(seconds: Int)
  case frozen(seconds: Int)
  case poor
}

struct OverlayHealthState: Equatable {
  var warnings: [OverlayWarning] = []
  var level: OverlayHealthLevel = .normal
  /// Frames lost over the last 10 s, in percent (time weighted; the figure the overlay shows).
  var lossPercent: Float = 0
  /// Client-added stalls in the last 10 s.
  var recentStalls = 0
  /// The stream's own typical rate: the median received fps of the last 10 s (0 while unknown).
  var baselineFps: Float = 0
}

struct OverlayHealthThresholds {
  var window: TimeInterval = 10
  var hold: TimeInterval = 4
  /// Lost frames / frames the host sent, over the window, and the least number of lost frames: one lost frame on a
  /// screen that sends 30 fps is 1 % of a 3 s window and not a problem. Against four recorded streams (loss
  /// 0.8 %, 2.5 %, 1.0 % of all frames) 5 % / 8 frames keeps the line up for 0 %, 17 % and 6 % of the time;
  /// at 3 % / 5 frames it was 4 %, 30 % and 11 %.
  var lossPercent: Float = 5
  var lossMinFrames: Double = 8
  /// Bad (red status dot) from here.
  var lossBadPercent: Float = 15
  var stallCount = 3
  /// 1% low against the stream's own median rate, only for streams of at least this rate, and only when something
  /// else (a stall or loss) was seen in the window.
  var lowRelative: Float = 0.5
  var lowMinBaselineFps: Float = 24
  var lowMinTicks = 6
  /// A stream that sends nothing for this long is reported.
  var noDataSeconds = 3
}

// MARK: - Detector

final class OverlayHealthDetector {
  private struct Tick {
    var time: TimeInterval
    var lost: Double
    var total: Double
    var stalls: Int
    var fps: Float
  }
  private enum Kind: Hashable { case loss, stalls, low }

  let thresholds: OverlayHealthThresholds
  private var ticks: [Tick] = []
  private var lastStallTotal: UInt32?
  private var lastTime: TimeInterval?
  private var shown: [Kind: (until: TimeInterval, warning: OverlayWarning)] = [:]

  init(thresholds: OverlayHealthThresholds = OverlayHealthThresholds()) { self.thresholds = thresholds }

  func reset() {
    ticks.removeAll(); lastStallTotal = nil; lastTime = nil; shown.removeAll()
  }

  @discardableResult
  func ingest(_ s: OverlayHealthSample) -> OverlayHealthState {
    let t = thresholds
    let dt = min(2, max(0.05, lastTime.map { s.time - $0 } ?? 0.5))
    lastTime = s.time

    // Frames lost during this tick: the loss share of the window it sits in, times the frames of the tick.
    let lossShare = Double(min(0.95, max(0, (s.netAvailable ? s.netLossPercent : s.clientDropPercent) / 100)))
    let received = Double(max(0, s.receivedFps)) * dt
    let total = received / (1 - lossShare)
    let lost = total - received

    var newStalls = 0
    if let last = lastStallTotal, s.clientStallTotal >= last { newStalls = Int(s.clientStallTotal - last) }
    lastStallTotal = s.clientStallTotal

    ticks.append(Tick(time: s.time, lost: lost, total: total, stalls: newStalls, fps: s.receivedFps))
    ticks.removeAll { s.time - $0.time > t.window }

    let lostSum = ticks.reduce(0.0) { $0 + $1.lost }
    let totalSum = ticks.reduce(0.0) { $0 + $1.total }
    let lossPercent = totalSum > 0 ? Float(100 * lostSum / totalSum) : 0
    let stalls = ticks.reduce(0) { $0 + $1.stalls }
    let fpsSorted = ticks.map { $0.fps }.sorted()
    let baseline = ticks.count >= t.lowMinTicks ? fpsSorted[fpsSorted.count / 2] : 0

    func keep(_ kind: Kind, _ active: Bool, _ warning: @autoclosure () -> OverlayWarning) {
      if active { shown[kind] = (s.time + t.hold, warning()) }
    }
    let lossActive = lossPercent >= t.lossPercent && lostSum >= t.lossMinFrames
    keep(.loss, lossActive, s.netAvailable ? .netLoss(percent: lossPercent) : .clientLoss(percent: lossPercent))
    keep(.stalls, stalls >= t.stallCount, .stalls(count: stalls))
    let corroborated = stalls >= 1 || lossPercent >= t.lossPercent / 2
    keep(.low, corroborated && baseline >= t.lowMinBaselineFps && s.onePercentLow > 0 && s.onePercentLow < t.lowRelative * baseline,
         .lowPacing(fps: s.onePercentLow))
    shown = shown.filter { $0.value.until > s.time }

    var warnings: [OverlayWarning] = []
    // fixed order, so the line does not reshuffle while it is up
    for kind in [Kind.loss, .stalls, .low] { if let w = shown[kind]?.warning { warnings.append(w) } }
    if s.noPayloadSeconds >= t.noDataSeconds { warnings.append(.noData(seconds: s.noPayloadSeconds)) }
    else if s.frozenSeconds >= t.noDataSeconds { warnings.append(.frozen(seconds: s.frozenSeconds)) }
    if s.poor { warnings.append(.poor) }

    var level = OverlayHealthLevel.normal
    if !warnings.isEmpty { level = .high }
    if s.poor || s.noPayloadSeconds >= t.noDataSeconds || s.frozenSeconds >= t.noDataSeconds || (lossActive && lossPercent >= t.lossBadPercent) {
      level = .bad
    }
    return OverlayHealthState(warnings: warnings, level: level, lossPercent: lossPercent, recentStalls: stalls, baselineFps: baseline)
  }
}

// MARK: - Colour levels for single values

enum OverlayHealth {
  /// The client's frame rate is judged against what it received, not against the configured rate: a game that
  /// limits itself, or a host that sends only changed frames, is not a problem on this side.
  static func fpsLevel(rendered: Float, received: Float) -> OverlayHealthLevel {
    guard received >= 20 else { return .normal }
    let share = rendered / received
    return share < 0.6 ? .bad : (share < 0.8 ? .high : .normal)
  }

  /// 1% low against the stream's own rate (the configured rate while that is not known yet).
  static func onePercentLowLevel(low: Float, baseline: Float, configured: Float) -> OverlayHealthLevel {
    let reference = baseline > 0 ? baseline : max(configured, 1)
    let share = low / reference
    return share < 0.35 ? .bad : (share < 0.5 ? .high : .normal)
  }

  static func lossLevel(_ percent: Float) -> OverlayHealthLevel { percent >= 5 ? .bad : (percent >= 1.5 ? .high : .normal) }
}

// MARK: - Row layout

/// Breaks a run of items and the dividers between them into rows. An item stays on the row it fits on; the
/// divider that would sit at the start of a row is dropped. Rows past `maxRows` are not shown.
enum OverlayFlowPlanner {
  struct Item {
    var width: CGFloat
    var height: CGFloat
    var isDivider: Bool
  }
  struct Placement: Equatable {
    var x: CGFloat
    var y: CGFloat
    var row: Int
  }
  struct Plan {
    /// nil: the item is not shown (a divider at a row start, or past the last row).
    var placements: [Placement?]
    var size: CGSize
    var rowCount: Int
  }

  static func plan(_ items: [Item], maxWidth: CGFloat, rowSpacing: CGFloat, maxRows: Int) -> Plan {
    var placements: [Placement?] = Array(repeating: nil, count: items.count)
    var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, row = 0, usedWidth: CGFloat = 0
    var rowHasItem = false
    var pendingDivider: Int?
    for (index, item) in items.enumerated() {
      if item.isDivider { pendingDivider = index; continue }
      let dividerWidth = (rowHasItem ? pendingDivider.map { items[$0].width } : nil) ?? 0
      if rowHasItem && x + dividerWidth + item.width > maxWidth + 0.01 {
        row += 1; y += rowHeight + rowSpacing; x = 0; rowHeight = 0; rowHasItem = false
      }
      if row >= maxRows { pendingDivider = nil; continue }
      if rowHasItem, let d = pendingDivider {
        placements[d] = Placement(x: x, y: y, row: row)
        x += items[d].width
      }
      placements[index] = Placement(x: x, y: y, row: row)
      x += item.width
      rowHeight = max(rowHeight, item.height)
      usedWidth = max(usedWidth, x)
      rowHasItem = true
      pendingDivider = nil
    }
    let shownRows = rowHasItem || row > 0 ? min(row + 1, maxRows) : 0
    return Plan(placements: placements, size: CGSize(width: usedWidth, height: y + rowHeight), rowCount: shownRows)
  }
}
