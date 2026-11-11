//
//  BandwidthProbeRules.swift
//  The ceiling the pre-stream bandwidth probe may put on the bitrate. Foundation only, so tests/probe-ceiling compiles it on its
//  own.
//
//  A constant 150 Mbps ceiling is too low: on a 10 GbE LAN a link that carries gigabits was still held to 150.
//  Now: a host that states its own ceiling in /api/network/capabilities (bandwidthProbe.maxBitrateKbps, or maxBitrateKbps at the
//  top) decides; otherwise the advanced setting "probeMaxBitrateMbps" (default 150) does. Current Foundation Sunshine states none
//  (its capabilities answer has version, features and bandwidthProbe {version, endpoint, minBytes, maxBytes, cooldownMs}).
//

import Foundation

@objc(MLBandwidthProbeRules)
final class BandwidthProbeRules: NSObject {
  @objc static let defaultCeilingMbps = 150
  @objc static let settingKey = "probeMaxBitrateMbps"
  /// What the setting accepts (the app's own bitrate range ends at 1000 Mbps when unlocked).
  static let settingRangeMbps = 10...1000
  @objc static let stepKbps = 500
  @objc static let safeFraction = 0.65

  /// The ceiling the host states in its capabilities answer, in kbps; 0 when it states none or states nonsense.
  @objc static func hostOfferedCeilingKbps(capabilities: NSDictionary?) -> Int {
    guard let root = capabilities else { return 0 }
    func kbps(_ value: Any?) -> Int {
      let number: Double
      if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { number = n.doubleValue }
      else if let s = value as? String, let d = Double(s.trimmingCharacters(in: .whitespaces)) { number = d }
      else { return 0 }
      guard number.isFinite, number >= Double(stepKbps), number <= 100_000_000 else { return 0 }
      return Int(number)
    }
    let probe = root["bandwidthProbe"] as? NSDictionary
    let fromProbe = kbps(probe?["maxBitrateKbps"])
    return fromProbe > 0 ? fromProbe : kbps(root["maxBitrateKbps"])
  }

  /// The setting as stored (Mbps), or the default when it is missing or outside the range.
  @objc static func settingCeilingKbps(storedMbps: Int) -> Int {
    (settingRangeMbps.contains(storedMbps) ? storedMbps : defaultCeilingMbps) * 1000
  }

  /// The ceiling in kbps: the host's when it offers one, else the setting.
  @objc static func ceilingKbps(hostOfferedKbps: Int, storedMbps: Int) -> Int {
    hostOfferedKbps >= stepKbps ? hostOfferedKbps : settingCeilingKbps(storedMbps: storedMbps)
  }

  /// What a measured throughput lets a video stream use: 65 % of it, no more than the ceiling, in whole steps.
  @objc static func safeBitrateKbps(measuredMbps: Double, ceilingKbps: Int) -> Int {
    guard measuredMbps.isFinite, measuredMbps > 0 else { return 0 }
    let raw = Int((measuredMbps * 1000 * safeFraction).rounded(.down))
    return min(raw, ceilingKbps) / stepKbps * stepKbps
  }
}
