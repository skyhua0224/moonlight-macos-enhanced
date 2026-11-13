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

struct OverlayValue {
  var text: String
  var unit: String
  var level: OverlayLevel = .normal
  /// Widest text this value normally takes (digits only): the slot is reserved, so a number that gains or loses
  /// a digit does not move the rest of the line. Empty for text that does not change width.
  var slot = ""
}

extension OverlayHealthLevel {
  var overlayLevel: OverlayLevel { self == .bad ? .bad : (self == .high ? .high : .normal) }
}

/// The reserved width (as a string of digits) of each field's number: the digits it normally has (a stream of
/// 144 fps needs three for the frame rate, one of 60 two), and never fewer than it has had in this stream, so a
/// number that gains a digit widens its slot once and the line does not move again.
func overlaySlot(_ field: OverlayField, text: String, metrics m: OverlayMetrics) -> String {
  let fpsDigits = String(max(m.configuredFps, 1)).count
  let (base, decimals): (Int, Int)
  switch field {
  case .fps, .onePercentLow: (base, decimals) = (fpsDigits, 0)
  case .fpsReceived, .fpsDecoded: (base, decimals) = (fpsDigits, 1)
  // wide enough for the values these reach in bad moments (a latency over 100 ms), so the panel never changes width
  case .streamLatency, .rtt, .battery: (base, decimals) = (3, 0)
  case .bitrate, .renderP99: (base, decimals) = (3, 1)
  case .pipeline, .hostEncode, .decode, .queue: (base, decimals) = (2, 1)
  case .loss, .netLoss, .jitter, .pacing: (base, decimals) = (2, 1)
  case .stalls: (base, decimals) = (2, 0)
  case .parity, .fec, .elapsed, .clock, .route, .quality, .resolution, .codec, .chroma, .hdr: return ""
  }
  let digits = max(base, m.slotDigits[field] ?? 0)
  return (text.hasPrefix("~") ? "~" : "") + String(repeating: "0", count: digits) + (decimals > 0 ? "." + String(repeating: "0", count: decimals) : "")
}

/// Integer digits of a number text ("~27" -> 2, "45.8" -> 2, "--" -> 0).
func overlayIntegerDigits(_ text: String) -> Int {
  text.drop(while: { !$0.isNumber }).prefix(while: { $0.isNumber }).count
}

func overlayDuration(_ seconds: Double) -> String {
  let s = max(0, Int(seconds))
  return String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
}

func overlayValue(_ field: OverlayField, _ m: OverlayMetrics) -> OverlayValue? {
  guard var value = overlayValueUnslotted(field, m) else { return nil }
  if value.text != "--" { value.slot = overlaySlot(field, text: value.text, metrics: m) }
  return value
}

func overlayValueUnslotted(_ field: OverlayField, _ m: OverlayMetrics) -> OverlayValue? {
  func lvl(_ v: Float, high: Float, bad: Float) -> OverlayLevel { v >= bad ? .bad : (v >= high ? .high : .normal) }
  switch field {
  case .elapsed:
    return m.elapsedSeconds >= 0 ? OverlayValue(text: overlayDuration(m.elapsedSeconds), unit: "") : nil
  case .route:
    if m.route == "lan" { return OverlayValue(text: DL("deck.lan"), unit: "") }
    if m.route == "remote" { return OverlayValue(text: DL("deck.remote"), unit: "") }
    if !m.route.isEmpty { return OverlayValue(text: m.route, unit: "") }
    return nil
  case .quality:
    guard m.width > 0 else { return nil }
    var text = "\(m.width)×\(m.height)"
    if m.configuredFps > 0 { text += "@\(m.configuredFps)" }
    return OverlayValue(text: text, unit: m.autoBitrateKnown ? (m.autoBitrate ? DL("ov.auto") : DL("ov.fixed")) : "")
  case .clock: return m.clientTime.isEmpty ? nil : OverlayValue(text: m.clientTime, unit: "")
  case .battery:
    guard m.clientBatteryPercent >= 0 else { return nil }
    return OverlayValue(text: "\(m.clientBatteryPercent)", unit: m.clientCharging ? "% ⚡︎" : "%",
                        level: (!m.clientCharging && m.clientBatteryPercent <= 15) ? .bad : ((!m.clientCharging && m.clientBatteryPercent <= 25) ? .high : .normal))
  case .resolution:
    return m.width > 0 ? OverlayValue(text: "\(m.width)×\(m.height)", unit: "") : nil
  case .codec: return m.codec.isEmpty ? nil : OverlayValue(text: m.codec, unit: "")
  case .chroma: return m.chroma.isEmpty ? nil : OverlayValue(text: m.chroma, unit: "")
  case .hdr:
    guard !m.hdrName.isEmpty else { return nil }
    return OverlayValue(text: m.hdrName, unit: m.hdrFallback)
  case .fps:
    // judged against what the host sent, not against the configured rate (see OverlayHealth.swift)
    return OverlayValue(text: String(format: "%.0f", m.renderedFps), unit: "fps",
                        level: OverlayHealth.fpsLevel(rendered: m.renderedFps, received: m.receivedFps).overlayLevel)
  case .fpsReceived: return OverlayValue(text: String(format: "%.1f", m.receivedFps), unit: "fps")
  case .fpsDecoded: return OverlayValue(text: String(format: "%.1f", m.decodedFps), unit: "fps")
  case .onePercentLow:
    guard m.onePercentLow > 0 else { return OverlayValue(text: "--", unit: "") }
    let level = OverlayHealth.onePercentLowLevel(low: m.onePercentLow, baseline: m.fpsBaseline, configured: Float(m.configuredFps))
    return OverlayValue(text: String(format: "%.0f", m.onePercentLow), unit: "fps", level: level.overlayLevel)
  case .streamLatency:
    guard m.streamLatencyAvailable else { return OverlayValue(text: "--", unit: "") }
    return OverlayValue(text: (m.streamLatencyApproximate ? "~" : "") + String(format: "%.0f", m.streamLatencyMs), unit: "ms",
                        level: lvl(m.streamLatencyMs, high: 40, bad: 80))
  case .rtt: return m.rttAvailable ? OverlayValue(text: String(format: "%.0f", m.rttMs), unit: "ms", level: lvl(m.rttMs, high: 50, bad: 120)) : nil
  case .loss:
    // the 10 s figure when the model has one: the 3 s window of the stream library jumps on a single frame
    let percent = (!m.netAvailable && m.lossSmoothedPercent >= 0) ? m.lossSmoothedPercent : m.lossPercent
    return OverlayValue(text: String(format: "%.1f", percent), unit: "%", level: OverlayHealth.lossLevel(percent).overlayLevel)
  case .netLoss:
    guard m.netAvailable else { return nil }
    let percent = m.lossSmoothedPercent >= 0 ? m.lossSmoothedPercent : m.netLossPercent
    return OverlayValue(text: String(format: "%.1f", percent), unit: "%", level: OverlayHealth.lossLevel(percent).overlayLevel)
  case .fec:
    guard m.netAvailable, m.fecRecovered > 0 || m.fecFailed > 0 else { return nil }
    return OverlayValue(text: "+\(m.fecRecovered) / −\(m.fecFailed)", unit: "", level: m.fecFailed > 0 ? .high : .normal)
  case .parity:
    guard m.netAvailable, m.fecFeedbackActive else { return nil }
    return OverlayValue(text: "\(m.blockParityPercent)", unit: "%  \(m.fecFeedbackMissing)/\(m.fecFeedbackData)")
  case .jitter: return OverlayValue(text: String(format: "%.1f", m.jitterMs), unit: "ms", level: lvl(m.jitterMs, high: 15, bad: 40))
  case .bitrate: return OverlayValue(text: String(format: "%.1f", m.bitrateMbps), unit: "Mbps")
  case .pacing: return OverlayValue(text: String(format: "%.1f", m.pacingJitterMs), unit: "ms", level: lvl(m.pacingJitterMs, high: 3, bad: 8))
  case .renderP99:
    // The intervals the viewer saw, a host that sends only changed frames included: no colour of its own.
    return OverlayValue(text: String(format: "%.1f", m.renderP99Ms), unit: "ms")
  case .stalls: return OverlayValue(text: "\(m.clientStallRecent)", unit: "", level: m.clientStallRecent >= 3 ? .high : .normal)
  case .pipeline: return OverlayValue(text: String(format: "%.1f", m.pipelineMs), unit: "ms", level: lvl(m.pipelineMs, high: 25, bad: 50))
  case .hostEncode: return OverlayValue(text: String(format: "%.1f", m.hostMs), unit: "ms")
  case .decode: return OverlayValue(text: String(format: "%.1f", m.decodeMs), unit: "ms", level: lvl(m.decodeMs, high: 8, bad: 16))
  case .queue: return OverlayValue(text: String(format: "%.1f", m.queueMs), unit: "ms", level: lvl(m.queueMs, high: 8, bad: 16))
  }
}

// MARK: - The client Mac: clock and battery (not the host)

enum OverlayClient {
  private static var cache: (Date, (Int, Bool))?

  /// Percent and charging of this Mac's internal battery; nil on a Mac without one.
  static func battery() -> (Int, Bool)? {
    if let (when, value) = cache, Date().timeIntervalSince(when) < 30 { return value.0 < 0 ? nil : value }
    var result: (Int, Bool) = (-1, false)
    if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
       let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
      for source in list {
        guard let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
              (info[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
              let current = info[kIOPSCurrentCapacityKey] as? Int, let max = info[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
        let charging = (info[kIOPSIsChargingKey] as? Bool) ?? false
        result = (current * 100 / max, charging)
      }
    }
    cache = (Date(), result)
    return result.0 < 0 ? nil : result
  }

  static func timeText(_ date: Date = Date()) -> String {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.dateFormat = "HH:mm"
    return f.string(from: date)
  }

  /// Fills the client fields unless the caller (the concept fixture) set them.
  static func fill(_ m: OverlayMetrics) {
    if m.clientTime.isEmpty { m.clientTime = timeText() }
    if m.clientBatteryPercent == -2 {
      if let (percent, charging) = battery() { m.clientBatteryPercent = percent; m.clientCharging = charging }
      else { m.clientBatteryPercent = -1 }
    }
  }
}

// MARK: - Camera housing (notch): the two ears of the top band

/// Widths and band height, in points, of the usable areas beside the camera housing.
struct OverlayNotch: Equatable {
  var leftWidth: CGFloat
  var gap: CGFloat
  var rightWidth: CGFloat
  var height: CGFloat
  /// Where the band starts in the view (SwiftUI coordinates: from the left, from the top).
  var originX: CGFloat = 0
  var topOffset: CGFloat = 0
}

/// Geometry of the ears in the parent view's coordinates (origin bottom left).
struct OverlayNotchGeometry {
  var left: NSRect
  var right: NSRect
  /// Concept fixture only: a simulated screen (the Mac the shots are taken on has no notch).
  static var simulated: OverlayNotchGeometry?

  /// Real geometry: NSScreen.safeAreaInsets / auxiliaryTopLeftArea / auxiliaryTopRightArea (macOS 12+,
  /// https://developer.apple.com/documentation/appkit/nsscreen/auxiliarytopleftarea). Only when the
  /// window covers the top band, i.e. the view reaches the ears (borderless full screen); in native
  /// full screen the content starts below the band, the ears fall outside the view, and this returns nil.
  static func resolve(for parent: NSView) -> OverlayNotchGeometry? {
    if let simulated { return simulated }
    guard #available(macOS 12.0, *), let window = parent.window, let screen = window.screen,
          screen.safeAreaInsets.top > 0,
          let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea, !l.isEmpty, !r.isEmpty else { return nil }
    func local(_ rect: NSRect) -> NSRect { parent.convert(window.convertFromScreen(rect), from: nil) }
    let left = local(l), right = local(r)
    let visible = parent.bounds
    guard visible.contains(NSPoint(x: left.midX, y: left.midY)), visible.contains(NSPoint(x: right.midX, y: right.midY)) else { return nil }
    return OverlayNotchGeometry(left: left, right: right)
  }
}

// MARK: - Model (history ring buffers, anomaly detection)

struct OverlayRing {
  private(set) var values: [Double] = []
  let capacity: Int
  init(capacity: Int = 60) { self.capacity = capacity }
  mutating func append(_ v: Double) {
    values.append(v)
    if values.count > capacity { values.removeFirst(values.count - capacity) }
  }
}

@available(macOS 14.0, *)
final class OverlayModel: ObservableObject {
  @Published var m = OverlayMetrics()
  @Published var hasData = false
  @Published var poor = false
  @Published var healthLevel = OverlayHealthLevel.normal
  @Published var anomalies: [String] = []
  @Published var faded = false
  /// Set by the settings preview only: the panel reports its size (OverlayPanelSizeKey).
  var reportsSize = false
  /// The size of the view the panel sits in; set when the stream view changes size, never by a tick.
  @Published var geometry = OverlayGeometry()
  /// Set when the overlay is split into the two ears beside a camera housing.
  @Published var notch: OverlayNotch?
  @Published var fps = OverlayRing()
  @Published var latency = OverlayRing()
  @Published var bitrate = OverlayRing()
  @Published var loss = OverlayRing()
  @Published var pipeline = OverlayRing()
  @Published var interval = OverlayRing()
  private let detector = OverlayHealthDetector()
  private var slotDigits: [OverlayField: Int] = [:]
  private var quietSince: Date = Date()

  /// The text of a warning, in the user's language.
  static func text(_ warning: OverlayWarning) -> String {
    switch warning {
    case .netLoss(let p): return DLf("ov.an.netLoss", String(format: "%.1f", p))
    case .clientLoss(let p): return DLf("ov.an.loss", String(format: "%.1f", p))
    case .stalls(let n): return DLf("ov.an.stall", n)
    case .lowPacing(let fps): return DLf("ov.an.low", String(format: "%.0f", fps))
    case .noData(let seconds): return DLf("ov.an.noData", seconds)
    case .frozen(let seconds): return DLf("ov.an.frozen", seconds)
    case .poor: return DL("ov.an.poor")
    }
  }

  func apply(_ new: OverlayMetrics, now: Date = Date()) {
    OverlayClient.fill(new)
    // Warnings come from the detector: counts and rates over a 10 s window, kept for 4 s (OverlayHealth.swift).
    let state = detector.ingest(OverlayHealthSample(
      time: now.timeIntervalSinceReferenceDate, renderedFps: new.renderedFps, receivedFps: new.receivedFps,
      onePercentLow: new.onePercentLow, netAvailable: new.netAvailable, netLossPercent: new.netLossPercent,
      clientDropPercent: new.lossPercent, clientStallTotal: new.clientStallTotal,
      noPayloadSeconds: new.noPayloadStreakSeconds, frozenSeconds: new.frozenStatsStreakSeconds, poor: poor))
    new.lossSmoothedPercent = state.lossPercent
    new.clientStallRecent = state.recentStalls
    new.fpsBaseline = state.baselineFps
    for field in OverlayField.allCases {
      if let value = overlayValueUnslotted(field, new) { slotDigits[field] = max(slotDigits[field] ?? 0, overlayIntegerDigits(value.text)) }
    }
    new.slotDigits = slotDigits
    if !state.warnings.isEmpty { quietSince = now }

    m = new
    healthLevel = state.level
    hasData = true
    fps.append(Double(new.renderedFps))
    latency.append(new.streamLatencyAvailable ? Double(new.streamLatencyMs) : 0)
    bitrate.append(new.bitrateMbps)
    loss.append(Double(state.lossPercent))
    pipeline.append(Double(new.pipelineMs))
    interval.append(Double(new.renderP99Ms))
    let lines = state.warnings.map(Self.text)
    if lines != anomalies { anomalies = lines }
    faded = now.timeIntervalSince(quietSince) > 5
  }

  /// The worst level among the metrics that matter, for the status dot.
  var overall: OverlayLevel {
    // the detector's verdict, plus the latency colour; single-window colours do not turn the dot
    var level = healthLevel.overlayLevel
    if let v = overlayValue(.streamLatency, m) { level = max(level, v.level) }
    if poor { level = .bad }
    return level
  }
}

// MARK: - Presenter (the one object the stream controller talks to)

/// Click-through container: it never takes a mouse event or focus, so the stream underneath behaves
/// exactly as if the overlay were not there.
public final class OverlayHostView: NSView {
  public override func hitTest(_ point: NSPoint) -> NSView? { nil }
  public override var acceptsFirstResponder: Bool { false }
  public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }
}

@available(macOS 14.0, *)
final class OverlayHostingView: NSHostingView<OverlayRoot> {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override var acceptsFirstResponder: Bool { false }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }
}

/// The presenter only keeps the hosting view the size of the stream view and tells the model about that size. It never
/// measures the panel and never moves it: SwiftUI aligns the panel to its anchor inside the view (StreamOverlayViews.swift).
@available(macOS 14.0, *)
@objc(MLOverlayPresenter)
public final class OverlayPresenter: NSObject {
  /// Add this to the stream view; it resizes itself.
  @objc public let view = OverlayHostView()
  let model = OverlayModel()
  private let prefs = OverlayPrefs.shared
  private let hosting: OverlayHostingView
  private var observer: NSObjectProtocol?
  #if MLC_CONCEPT_HARNESS
  /// Harness: how many times the container's frame was set after the first time (a steady stream: 0).
  var frameSets = 0
  #endif

  @objc public override init() {
    hosting = OverlayHostingView(rootView: OverlayRoot(model: model, prefs: OverlayPrefs.shared))
    super.init()
    // the panel's margins are its own (OverlayGeometry); the hosting view must not add the notch inset on top
    if #available(macOS 13.3, *) { hosting.safeAreaRegions = [] }
    view.wantsLayer = true
    view.autoresizesSubviews = false
    hosting.autoresizingMask = []
    view.addSubview(hosting)
    view.isHidden = true
    view.setAccessibilityElement(false)
    observer = NotificationCenter.default.addObserver(forName: OverlayPrefs.changed, object: nil, queue: .main) { [weak self] _ in
      self?.relayout()
    }
  }

  deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

  @objc public func update(_ metrics: OverlayMetrics) {
    model.apply(metrics)
    relayout()
  }

  /// The old 「网络不佳」 warning, folded into the overlay.
  @objc public func setPoorConnection(_ poor: Bool) {
    model.poor = poor
    if poor { model.apply(model.m) }
    relayout()
  }

  @objc public var hasWarningHandled: Bool { true }

  /// Cheap and idempotent: nothing is assigned unless the stream view's size, the top inset or the camera housing changed.
  @objc public func relayout() {
    guard let parent = view.superview else { return }
    let visible = prefs.style != .legacy && (model.hasData || model.poor)
    if view.isHidden == visible { view.isHidden = !visible }
    guard visible else { return }

    let bounds = parent.bounds
    if view.frame != bounds {
      #if MLC_CONCEPT_HARNESS
      if view.frame.size != .zero { frameSets += 1 }
      #endif
      view.frame = bounds
    }
    if hosting.frame != view.bounds { hosting.frame = view.bounds }

    // Borderless full screen on a notched display: two groups in the ears beside the camera housing.
    var notch: OverlayNotch?
    if prefs.notchSplit, let g = OverlayNotchGeometry.resolve(for: parent) {
      notch = OverlayNotch(leftWidth: g.left.width, gap: g.right.minX - g.left.maxX, rightWidth: g.right.width, height: g.left.height,
                           originX: g.left.minX, topOffset: bounds.height - g.left.maxY)
    }
    if model.notch != notch { model.notch = notch }
    let geometry = OverlayGeometry(width: bounds.width, height: bounds.height, safeTop: parent.safeAreaInsets.top)
    if model.geometry != geometry { model.geometry = geometry }
  }
}

// MARK: - Sample data (also what the harness fixture draws)

enum OverlaySample {
  /// A steady 60 fps session with small jitter; `anomaly` adds a loss burst and a stall (from tick 79 on).
  static func metrics(tick: Int, anomaly: Bool) -> OverlayMetrics {
    let m = OverlayMetrics()
    let t = Double(tick)
    m.width = 3840; m.height = 2160; m.configuredFps = 60
    m.codec = "HEVC 10-bit"; m.chroma = "4:4:4"; m.hdrName = "HDR10"
    m.renderedFps = Float(60 - (anomaly && tick > 78 ? 9 : 0) - Float(abs(sin(t * 0.7)) * 0.9))
    m.receivedFps = 60; m.decodedFps = 60
    m.onePercentLow = anomaly ? 24 : 57
    m.streamLatencyMs = Float(26 + sin(t * 0.4) * 3 + (anomaly && tick > 78 ? 18 : 0)); m.streamLatencyAvailable = true
    m.rttMs = 9; m.rttAvailable = true
    m.lossPercent = anomaly && tick > 78 ? 3.4 : 0.0
    m.netAvailable = true
    m.netLossPercent = anomaly && tick > 78 ? 3.2 : 0.0
    m.fecRecovered = 12; m.fecFailed = anomaly ? 2 : 0
    m.fecFeedbackActive = true; m.blockParityPercent = 20; m.fecFeedbackMissing = 1; m.fecFeedbackData = 210
    m.jitterMs = Float(1.2 + abs(sin(t * 0.9)) * 0.8 + (anomaly && tick > 78 ? 7 : 0))
    m.bitrateMbps = 48 + sin(t * 0.5) * 6
    m.pacingJitterMs = Float(0.6 + abs(sin(t * 0.3)) * 0.4)
    m.renderP99Ms = Float(17.6 + abs(sin(t * 0.8)) * 2.4 + (anomaly && tick > 78 ? 26 : 0))
    m.stallCount = anomaly && tick > 78 ? UInt32(tick - 78) : 0
    m.clientStallTotal = anomaly && tick > 78 ? UInt32((tick - 78) / 2) : 0
    m.pipelineMs = Float(14.8 + sin(t * 0.35) * 1.4)
    m.hostMs = 6.2; m.decodeMs = 4.6; m.queueMs = 4.0
    m.transportMs = 4.5; m.transportAvailable = true
    m.clientTime = "23:14"; m.clientBatteryPercent = 78; m.clientCharging = false
    m.elapsedSeconds = 42 * 60 + 14
    m.route = "lan"
    m.autoBitrateKnown = true; m.autoBitrate = true
    return m
  }
}

#if MLC_CONCEPT_HARNESS
// MARK: - Fixture (concept builds only): mock numbers over a frame, through the real views

@objc(MLOverlayFixture)
public final class OverlayFixture: NSObject {
  /// Mock numbers: a steady 60 fps session with small jitter; `anomaly` adds a loss burst and a stall.
  @objc public static func mockMetrics(tick: Int, anomaly: Bool) -> OverlayMetrics {
    let m = OverlaySample.metrics(tick: tick, anomaly: anomaly)
    let t = Double(tick)
    if conceptEnv("MLC_OV_LIMITED") == "1" {
      // A recorded stream: configured 144, the game limits itself to about 60 (received == rendered),
      // the host sends only changed frames on a quiet screen, and one frame is lost now and then.
      m.configuredFps = 144
      let rate = Float(60 - abs(sin(t * 0.7)) * 1.5)
      m.receivedFps = rate; m.decodedFps = rate; m.renderedFps = rate
      m.onePercentLow = 54
      m.netLossPercent = (tick % 24) < 6 ? 1.3 : 0.0
      m.lossPercent = m.netLossPercent
      m.stallCount = 26; m.renderP99Ms = 93.8
      m.bitrateMbps = 9.4 + sin(t * 0.5) * 6
    }
    return m
  }

  /// Puts the real overlay over `parent` and feeds it `ticks` mock updates (the history fills like a session would).
  /// Simulated camera housing for a 14-inch MacBook Pro screen, 1512×982 points: a 38 pt band and a ~200 pt notch,
  /// the ears 656 pt wide each. The real values must be read from NSScreen on the machine; these are approximate.
  @objc public static func simulateNotch(screenWidth: CGFloat, screenHeight: CGFloat, band: CGFloat, notchWidth: CGFloat) {
    let ear = (screenWidth - notchWidth) / 2
    OverlayNotchGeometry.simulated = OverlayNotchGeometry(
      left: NSRect(x: 0, y: screenHeight - band, width: ear, height: band),
      right: NSRect(x: screenWidth - ear, y: screenHeight - band, width: ear, height: band))
  }

  @objc public static func attach(to parent: NSView, anomaly: Bool) -> NSObject? {
    guard #available(macOS 14.0, *) else { return nil }
    let presenter = OverlayPresenter()
    parent.addSubview(presenter.view, positioned: .above, relativeTo: nil)
    for tick in 0..<96 { presenter.model.apply(mockMetrics(tick: tick, anomaly: anomaly), now: Date().addingTimeInterval(Double(tick) * 0.5 - 48)) }
    presenter.relayout()
    return presenter
  }

  /// Values that change as much as they can: every field crosses a digit boundary many times in `seconds` (a tick every
  /// 0.5 s, like the real stats). With `warnings`, a loss burst in the middle brings the warning item and takes it away.
  static func stabilityMetrics(tick: Int, warnings: Bool) -> OverlayMetrics {
    let m = OverlaySample.metrics(tick: tick, anomaly: false)
    // a deterministic generator, so a run can be repeated
    var seed = UInt64(tick &* 2654435761 &+ 12345)
    func next() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double((seed >> 33) & 0xFFFFF) / Double(0xFFFFF) }
    m.configuredFps = 144
    let rates: [Float] = [144, 98, 59, 61, 9, 120, 7, 143, 100, 33]
    m.renderedFps = rates[tick % rates.count]; m.receivedFps = m.renderedFps; m.decodedFps = m.renderedFps
    m.onePercentLow = Float(next() * 140)
    m.streamLatencyMs = Float(1 + next() * 160)
    m.rttMs = Float(1 + next() * 140)
    m.bitrateMbps = 0.4 + next() * 230
    m.jitterMs = Float(next() * 30)
    m.pacingJitterMs = Float(next() * 12)
    m.renderP99Ms = Float(4 + next() * 140)
    m.pipelineMs = Float(2 + next() * 90)
    m.hostMs = Float(next() * 30); m.decodeMs = Float(next() * 25); m.queueMs = Float(next() * 20)
    m.lossPercent = Float(next() * 3); m.netLossPercent = m.lossPercent
    m.clientStallTotal = UInt32(tick / 6)
    m.elapsedSeconds = Double(tick) * 0.5 + 9 * 60 + 59.5 - 0.5
    m.clientTime = String(format: "%02d:%02d", 23, (14 + tick / 120) % 60)
    if warnings && tick >= 24 && tick < 44 { m.netLossPercent = 18; m.lossPercent = 18 }
    return m
  }

  /// Feeds `seconds` of changing values to the overlay in real time and writes the measured panel frames to `path`:
  /// the number of distinct frames, and the minimum and maximum of x, y, width and height (window coordinates).
  @objc public static func runStability(on presenterObject: NSObject, seconds: Int, warnings: Bool, path: String) {
    guard #available(macOS 14.0, *), let presenter = presenterObject as? OverlayPresenter else { return }
    var tick = 96
    // The first tick brings this run's configured rate and number widths (the mock history of attachTo is a 60 fps stream);
    // the frames are counted from one second later, when the panel has settled: what follows is a steady stream.
    presenter.update(stabilityMetrics(tick: tick, warnings: warnings))
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { OverlayStability.shared.reset() }
    let start = Date().addingTimeInterval(1.0)
    let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
      tick += 1
      presenter.update(stabilityMetrics(tick: tick, warnings: warnings))
      if warnings {
        // a warning item for ticks 24 ... 43 of the run: what the detector would show in a loss burst, set directly
        let n = tick - 96
        presenter.model.anomalies = (n >= 24 && n < 44) ? [OverlayModel.text(.netLoss(percent: 18))] : []
      }
      if Date().timeIntervalSince(start) >= Double(seconds) {
        timer.invalidate()
        let frames = OverlayStability.shared.frames
        let distinct = Set(frames.map { "\($0.origin.x),\($0.origin.y),\($0.width),\($0.height)" })
        func range(_ f: (CGRect) -> CGFloat) -> String { String(format: "%.2f .. %.2f", frames.map(f).min() ?? 0, frames.map(f).max() ?? 0) }
        let report = """
        stability: seconds=\(seconds) (after 1 s of settling) ticks=\(tick - 96) warnings=\(warnings) panel-frame-changes=\(frames.count) distinct-frames=\(distinct.count)
          x      \(range { $0.minX })
          maxX   \(range { $0.maxX })
          y      \(range { $0.minY })
          width  \(range { $0.width })
          height \(range { $0.height })
          container-frame-sets-after-first=\(presenter.frameSets)
        \(distinct.sorted().map { "  frame \($0)" }.joined(separator: "\n"))

        """
        fputs(report, stderr)
        try? report.write(toFile: path, atomically: true, encoding: .utf8)
      }
    }
    RunLoop.main.add(timer, forMode: .common)
  }
}

#endif
