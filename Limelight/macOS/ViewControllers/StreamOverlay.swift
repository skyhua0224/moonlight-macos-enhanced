//
//  StreamOverlay.swift
//  The in-stream performance overlay, in several styles the user picks from.
//
//  Data: only what StreamViewController+Diagnostics.m (updateStats) already computes. It hands an
//  OverlayMetrics snapshot over once per stats tick (0.5 s); nothing here runs per frame. History for
//  the sparklines is a small ring buffer filled at that same rate.
//
//  Not in the way of the stream: the whole overlay is click-through (hitTest returns nil for the
//  container and for every view in it), never becomes first responder, sits clear of the title bar /
//  notch (safe-area top inset) and keeps a 64 pt inset above the bottom edge, where the remote
//  Windows taskbar / macOS Dock live. There is no bottom strip.
//

import AppKit
import IOKit.ps
import SwiftUI

// MARK: - Metrics (filled by updateStats)

@objc(MLOverlayMetrics)
public final class OverlayMetrics: NSObject {
  @objc public var width = 0
  @objc public var height = 0
  @objc public var configuredFps = 0
  @objc public var codec = ""
  @objc public var chroma = ""
  @objc public var hdrName = ""
  @objc public var hdrFallback = ""
  @objc public var receivedFps: Float = 0
  @objc public var decodedFps: Float = 0
  @objc public var renderedFps: Float = 0
  @objc public var onePercentLow: Float = 0
  @objc public var streamLatencyMs: Float = 0
  @objc public var streamLatencyAvailable = false
  @objc public var streamLatencyApproximate = false
  @objc public var rttMs: Float = 0
  @objc public var rttAvailable = false
  @objc public var lossPercent: Float = 0
  @objc public var netLossPercent: Float = 0
  @objc public var netAvailable = false
  @objc public var fecRecovered: UInt32 = 0
  @objc public var fecFailed: UInt32 = 0
  @objc public var fecFeedbackActive = false
  @objc public var blockParityPercent: UInt32 = 0
  @objc public var fecFeedbackMissing: UInt32 = 0
  @objc public var fecFeedbackData: UInt32 = 0
  @objc public var jitterMs: Float = 0
  @objc public var bitrateMbps: Double = 0
  @objc public var pacingJitterMs: Float = 0
  @objc public var renderP99Ms: Float = 0
  @objc public var stallCount: UInt32 = 0
  @objc public var pipelineMs: Float = 0
  @objc public var hostMs: Float = 0
  @objc public var decodeMs: Float = 0
  @objc public var queueMs: Float = 0
  /// Seconds since the stream started; negative when unknown.
  @objc public var elapsedSeconds: Double = -1
  /// "lan" or "remote" from the address the stream connects to; empty when unknown.
  @objc public var route = ""
  /// The saved setting, not a measurement: automatic or fixed bitrate.
  @objc public var autoBitrateKnown = false
  @objc public var autoBitrate = false
  /// One-way network share of the stream latency (RTT / 2, or the path probe), and the other three parts
  /// are hostMs (encode), decodeMs and queueMs: together they are streamLatencyMs.
  @objc public var transportMs: Float = 0
  @objc public var transportAvailable = false
  /// The Mac the client runs on (not the host). -2 = not provided, ask the system; -1 = no battery.
  @objc public var clientBatteryPercent = -2
  @objc public var clientCharging = false
  @objc public var clientTime = ""
  @objc public var noPayloadStreakSeconds = 0
  @objc public var frozenStatsStreakSeconds = 0
  /// Render intervals over 100 ms that the client added itself (not a host that sent nothing), since the stream
  /// started; the stall figure and warning are built from the difference between ticks.
  @objc public var clientStallTotal: UInt32 = 0
  /// Filled by the overlay model from its 10 s window, not by the stream controller: frames lost in percent,
  /// client stalls and the stream's own typical fps (-1 / 0 while nothing is known yet).
  var lossSmoothedPercent: Float = -1
  var clientStallRecent = 0
  var fpsBaseline: Float = 0
  /// The most integer digits each field's number has had in this stream: its slot never gets narrower.
  var slotDigits: [OverlayField: Int] = [:]
}

// MARK: - Styles, fields, settings

enum OverlayStyle: String, CaseIterable {
  /// legacy is the unchanged one-line overlay of the old code. It is not offered in settings; it is the
  /// fallback below macOS 14 (no SwiftUI path) and what the concept fixture draws for "today".
  /// textBar = compact (one row), cornerList = corner (icons and values), chartHUD = chart (big frame rate and graphs).
  case legacy, textBar, cornerList, chartHUD
  /// The styles the settings page offers, in the order the cycle shortcut visits them.
  static var choosable: [OverlayStyle] { [.textBar, .cornerList, .chartHUD] }
  /// What an older build stored: the dropped styles (full-width strips, capsule, detailed, anomaly-only) become compact.
  static func stored(_ raw: String?) -> OverlayStyle {
    guard let raw else { return .textBar }
    return OverlayStyle(rawValue: raw) ?? .textBar
  }
  var title: String { DL("ov.style.\(rawValue)") }
  var defaultPosition: OverlayPosition {
    switch self {
    case .cornerList, .chartHUD: return .topRight
    default: return .topCenter
    }
  }
  var hasPosition: Bool { self != .legacy }

  /// Fields only a part of the styles has room for.
  private var onlyFields: Set<OverlayField>? {
    switch self {
    case .chartHUD: return [.resolution, .codec, .chroma, .hdr, .fps, .renderP99, .streamLatency, .bitrate, .loss, .netLoss, .pipeline]
    default: return nil
    }
  }

  /// Why this style cannot show a selected (or selectable) field; nil when it can.
  func reason(for field: OverlayField, selection: [OverlayField]) -> String? {
    if self == .legacy { return nil }
    if let only = onlyFields, !only.contains(field) { return DL("ov.why.\(rawValue)") }
    return nil
  }

  /// The selected fields this style really shows, in the order the user gave them (the list on the settings page).
  func shown(_ selection: [OverlayField]) -> [OverlayField] {
    if self == .legacy { return [] }
    let allowed = onlyFields
    var seen = Set<OverlayField>()
    return selection.filter { (allowed?.contains($0) ?? true) && seen.insert($0).inserted }
  }
}

enum OverlayPosition: String, CaseIterable {
  case topLeft, topCenter, topRight, bottomLeft, bottomCenter, bottomRight
  var title: String { DL("ov.pos.\(rawValue)") }
  var isBottom: Bool { self == .bottomLeft || self == .bottomCenter || self == .bottomRight }
}

enum OverlayGroup: String, CaseIterable {
  case session, video, rate, network, present, pipeline
  var title: String { DL("ov.group.\(rawValue)") }
}

enum OverlayField: String, CaseIterable {
  case elapsed, route, quality, clock, battery
  case resolution, codec, chroma, hdr
  case fps, fpsReceived, fpsDecoded, onePercentLow
  case streamLatency, rtt, loss, netLoss, fec, parity, jitter, bitrate
  case pacing, renderP99, stalls
  case pipeline, hostEncode, decode, queue

  var group: OverlayGroup {
    switch self {
    case .elapsed, .route, .quality, .clock, .battery: return .session
    case .resolution, .codec, .chroma, .hdr: return .video
    case .fps, .fpsReceived, .fpsDecoded, .onePercentLow: return .rate
    case .streamLatency, .rtt, .loss, .netLoss, .fec, .parity, .jitter, .bitrate: return .network
    case .pacing, .renderP99, .stalls: return .present
    case .pipeline, .hostEncode, .decode, .queue: return .pipeline
    }
  }
  var title: String { DL("ov.field.\(rawValue)") }
  /// 最少 / 常用 / 全部: start points for the one shared picker.
  static let minimal: [OverlayField] = [.fps, .streamLatency]
  static let usual: [OverlayField] = [.resolution, .codec, .fps, .onePercentLow, .streamLatency, .loss, .bitrate, .elapsed, .clock]
}

enum OverlayLevel: Int, Comparable {
  case normal, high, bad
  static func < (a: OverlayLevel, b: OverlayLevel) -> Bool { a.rawValue < b.rawValue }
  var color: Color {
    switch self {
    case .normal: return Color.white.opacity(0.96)
    case .high: return Color(red: 1.0, green: 0.80, blue: 0.30)
    case .bad: return Color(red: 1.0, green: 0.42, blue: 0.40)
    }
  }
  var dot: Color {
    switch self {
    case .normal: return Color(red: 0.30, green: 0.85, blue: 0.45)
    case .high: return Color(red: 1.0, green: 0.76, blue: 0.25)
    case .bad: return Color(red: 1.0, green: 0.38, blue: 0.36)
    }
  }
}

/// The saved choices. Global app preferences (UserDefaults), changed from the settings page or the
/// cycle shortcut; the overlay re-reads them when MLOverlaySettingsChanged is posted.
final class OverlayPrefs: ObservableObject {
  static let shared = OverlayPrefs()
  static let changed = Notification.Name("MLOverlaySettingsChanged")
  private let d = UserDefaults.standard
  /// The tint of an older panel stored a whole-overlay opacity (0.3 ... 1); the panel's own is below.
  static let defaultPlateOpacity = 0.55
  static let plateRange: ClosedRange<Double> = 0.15...0.9
  static let scaleRange: ClosedRange<Double> = 0.8...1.5

  @Published var style: OverlayStyle { didSet { save() } }
  @Published var positionRaw: String { didSet { save() } }   // "auto" or a position
  /// One selection and one order for every style: switching style keeps them.
  @Published var fields: [OverlayField] { didSet { save() } }
  /// How dark the panel is (black tint over the material): the text stays fully opaque.
  @Published var plateOpacity: Double { didSet { save() } }
  /// Size of everything in the HUD, 1 = the Metal HUD's own size.
  @Published var scale: Double { didSet { save() } }
  @Published var autoFade: Bool { didSet { save() } }
  @Published var expandOnAnomaly: Bool { didSet { save() } }
  /// Full screen on a Mac with a camera housing: the overlay splits into two groups beside the notch.
  @Published var notchSplit: Bool { didSet { save() } }

  init() {
    var style = OverlayStyle.stored(d.string(forKey: "MLOverlayStyle"))
    if let v = conceptEnv("MLC_OV_STYLE"), let forced = OverlayStyle(rawValue: v) { style = forced }
    self.style = style
    var position = d.string(forKey: "MLOverlayPosition") ?? "auto"
    if let v = conceptEnv("MLC_OV_POS") { position = v }
    positionRaw = position
    var fields = (d.array(forKey: "MLOverlayFields") as? [String])?.compactMap(OverlayField.init(rawValue:)) ?? OverlayField.usual
    if let v = conceptEnv("MLC_OV_FIELDS") {
      fields = v == "all" ? OverlayField.allCases : (v == "min" ? OverlayField.minimal : v.split(separator: ",").compactMap { OverlayField(rawValue: String($0)) })
    }
    self.fields = fields
    let storedPlate = d.object(forKey: "MLOverlayPlateOpacity") as? Double ?? Self.defaultPlateOpacity
    plateOpacity = min(max(Double(conceptEnv("MLC_OV_TINT") ?? "") ?? storedPlate, Self.plateRange.lowerBound), Self.plateRange.upperBound)
    let storedScale = d.object(forKey: "MLOverlayScale") as? Double ?? 1.0
    scale = min(max(Double(conceptEnv("MLC_OV_SCALE") ?? "") ?? storedScale, Self.scaleRange.lowerBound), Self.scaleRange.upperBound)
    autoFade = d.object(forKey: "MLOverlayAutoFade") as? Bool ?? false
    expandOnAnomaly = d.object(forKey: "MLOverlayExpandOnAnomaly") as? Bool ?? true
    notchSplit = conceptEnv("MLC_OV_NOTCH") != nil ? conceptEnv("MLC_OV_NOTCH") == "1" : (d.object(forKey: "MLOverlayNotchSplit") as? Bool ?? true)
  }

  var position: OverlayPosition {
    if positionRaw == "auto" { return style.defaultPosition }
    return OverlayPosition(rawValue: positionRaw) ?? style.defaultPosition
  }

  private func save() {
    d.set(style.rawValue, forKey: "MLOverlayStyle")
    d.set(positionRaw, forKey: "MLOverlayPosition")
    d.set(fields.map { $0.rawValue }, forKey: "MLOverlayFields")
    d.set(plateOpacity, forKey: "MLOverlayPlateOpacity")
    d.set(scale, forKey: "MLOverlayScale")
    d.set(autoFade, forKey: "MLOverlayAutoFade")
    d.set(expandOnAnomaly, forKey: "MLOverlayExpandOnAnomaly")
    d.set(notchSplit, forKey: "MLOverlayNotchSplit")
    NotificationCenter.default.post(name: Self.changed, object: nil)
  }

  func choose(_ preset: [OverlayField]) { fields = preset }

  /// Back to what a fresh install has.
  func resetToDefaults() {
    style = .textBar
    positionRaw = "auto"
    fields = OverlayField.usual
    plateOpacity = Self.defaultPlateOpacity
    scale = 1
    autoFade = false
    expandOnAnomaly = true
    notchSplit = true
  }

  func has(_ field: OverlayField) -> Bool { fields.contains(field) }
  /// Adds a field at the end of the list, or takes it out.
  func toggle(_ field: OverlayField) {
    if let i = fields.firstIndex(of: field) { fields.remove(at: i) } else { fields.append(field) }
  }

  /// Drag and drop in the list: the order is the order of the items in the HUD.
  func moveFields(from source: IndexSet, to destination: Int) {
    var list = fields
    list.move(fromOffsets: source, toOffset: destination)
    fields = list
  }
}

@objc(MLOverlayPrefs)
public final class OverlayPrefsBridge: NSObject {
  /// Which style the overlay uses now: "legacy" keeps the old single-line overlay.
  @objc public static var styleName: String { OverlayPrefs.shared.style.rawValue }
  @objc public static var isLegacy: Bool { OverlayPrefs.shared.style == .legacy }
  /// Moves to the next style (the shortcut), wrapping around.
  @objc public static func cycleStyle() {
    let all = OverlayStyle.choosable
    let prefs = OverlayPrefs.shared
    let next = all[((all.firstIndex(of: prefs.style) ?? -1) + 1) % all.count]
    prefs.style = next
  }
}

// MARK: - Values

