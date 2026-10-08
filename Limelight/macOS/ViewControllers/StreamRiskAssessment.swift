import AppKit
import CoreWLAN
import CoreGraphics
import Darwin
import VideoToolbox

private func streamRiskLocalized(_ key: String) -> String {
  LanguageManager.shared.localize(key)
}

private func streamRiskLocalizedFormat(_ key: String, _ arguments: CVarArg...) -> String {
  String(format: streamRiskLocalized(key), arguments: arguments)
}

@objc enum StreamRiskRouteTier: Int {
  case unknown = 0
  case lanDirect = 1
  case lanHairpinOrSplitDNS = 2
  case overlayRemote = 3
  case wanRemote = 4

  var label: String {
    switch self {
    case .unknown:
      return streamRiskLocalized("Unknown")
    case .lanDirect:
      return streamRiskLocalized("LAN Direct")
    case .lanHairpinOrSplitDNS:
      return streamRiskLocalized("LAN Hairpin / Split DNS")
    case .overlayRemote:
      return streamRiskLocalized("Overlay Remote")
    case .wanRemote:
      return streamRiskLocalized("WAN Remote")
    }
  }
}

@objc enum StreamRiskLevel: Int {
  case low = 0
  case medium = 1
  case high = 2

  var label: String {
    switch self {
    case .low:
      return streamRiskLocalized("Balanced")
    case .medium:
      return streamRiskLocalized("High-Spec")
    case .high:
      return streamRiskLocalized("Ultra-Spec")
    }
  }
}

private enum StreamCodecKind: String {
  case h264 = "H.264"
  case hevc = "H.265"
  case av1 = "AV1"

  static func from(_ rawValue: String) -> StreamCodecKind {
    let normalized = rawValue
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .uppercased()
      .replacingOccurrences(of: "HEVC", with: "H.265")
      .replacingOccurrences(of: "H265", with: "H.265")
      .replacingOccurrences(of: "H264", with: "H.264")

    if normalized.contains("AV1") {
      return .av1
    }
    if normalized.contains("265") {
      return .hevc
    }
    return .h264
  }

  var displayName: String { rawValue }
}

private struct StreamRiskThresholds {
  let lowRiskBpppf: Double
  let mediumRiskBpppf: Double
}

private struct StreamRiskProfile: Hashable {
  let width: Int
  let height: Int
  let fps: Int
  let codec: StreamCodecKind
  let enableYUV444: Bool
}

private struct StreamRiskEvaluation {
  let routeTier: StreamRiskRouteTier
  let riskLevel: StreamRiskLevel
  let hostRuntimeLabel: String?
  let targetFps: Int
  let pixelRate: Double
  let bitsPerPixelPerFrame: Double
  let decodeSupported: Bool
  let displayRefreshRateHz: Double
  let cadenceLabel: String?
  let wirelessLinkText: String?
  let reasons: [String]
}

private struct StreamCadenceAnalysis {
  let label: String
  let addedRisk: StreamRiskLevel?
  let reason: String?
}

private struct StreamWirelessLinkInfo {
  let text: String
  let addedRisk: StreamRiskLevel?
  let reason: String?
}

private struct StreamHostRuntimeInfo {
  let label: String
}

@objcMembers final class StreamRiskRecommendation: NSObject {
  let width: Int
  let height: Int
  let fps: Int
  let codecName: String
  let enableYUV444: Bool
  let predictedRiskLevelRawValue: Int
  let summaryLine: String

  init(
    width: Int,
    height: Int,
    fps: Int,
    codecName: String,
    enableYUV444: Bool,
    predictedRiskLevel: StreamRiskLevel,
    summaryLine: String
  ) {
    self.width = width
    self.height = height
    self.fps = fps
    self.codecName = codecName
    self.enableYUV444 = enableYUV444
    self.predictedRiskLevelRawValue = predictedRiskLevel.rawValue
    self.summaryLine = summaryLine
  }

  var predictedRiskLevel: StreamRiskLevel {
    StreamRiskLevel(rawValue: predictedRiskLevelRawValue) ?? .high
  }
}

@objcMembers final class StreamRiskAssessment: NSObject {
  let routeTierRawValue: Int
  let riskLevelRawValue: Int
  let routeLabel: String
  let riskLabel: String
  let hostRuntimeLabel: String?
  let codecName: String
  let chromaName: String
  let targetFps: Int
  let pixelRate: Double
  let pixelRateText: String
  let bitsPerPixelPerFrame: Double
  let bpppfText: String
  let decodeSupported: Bool
  let displayRefreshRateHz: Double
  let cadenceLabel: String?
  let wirelessLinkText: String?
  let summaryLine: String
  let reasons: [String]
  let recommendedFallbacks: [StreamRiskRecommendation]
  let autoModeActive: Bool
  let manualExpertMode: Bool
  let targetAddress: String

  init(
    routeTier: StreamRiskRouteTier,
    riskLevel: StreamRiskLevel,
    codecName: String,
    chromaName: String,
    hostRuntimeLabel: String?,
    targetFps: Int,
    pixelRate: Double,
    bitsPerPixelPerFrame: Double,
    decodeSupported: Bool,
    displayRefreshRateHz: Double,
    cadenceLabel: String?,
    wirelessLinkText: String?,
    summaryLine: String,
    reasons: [String],
    recommendedFallbacks: [StreamRiskRecommendation],
    autoModeActive: Bool,
    targetAddress: String
  ) {
    routeTierRawValue = routeTier.rawValue
    riskLevelRawValue = riskLevel.rawValue
    routeLabel = routeTier.label
    riskLabel = riskLevel.label
    self.hostRuntimeLabel = hostRuntimeLabel
    self.codecName = codecName
    self.chromaName = chromaName
    self.targetFps = targetFps
    self.pixelRate = pixelRate
    pixelRateText = StreamRiskAssessor.formatPixelRate(pixelRate)
    self.bitsPerPixelPerFrame = bitsPerPixelPerFrame
    bpppfText = String(format: "%.3f", bitsPerPixelPerFrame)
    self.decodeSupported = decodeSupported
    self.displayRefreshRateHz = displayRefreshRateHz
    self.cadenceLabel = cadenceLabel
    self.wirelessLinkText = wirelessLinkText
    self.summaryLine = summaryLine
    self.reasons = reasons
    self.recommendedFallbacks = recommendedFallbacks
    self.autoModeActive = autoModeActive
    manualExpertMode = !autoModeActive
    self.targetAddress = targetAddress
  }

  var routeTier: StreamRiskRouteTier {
    StreamRiskRouteTier(rawValue: routeTierRawValue) ?? .unknown
  }

  var riskLevel: StreamRiskLevel {
    StreamRiskLevel(rawValue: riskLevelRawValue) ?? .high
  }
}

@objcMembers final class StreamRiskAssessor: NSObject {
  @objc(assessWithHost:targetAddress:connectionMethod:width:height:fps:bitrateKbps:codecName:enableYUV444:autoMode:)
  static func assess(
    host: TemporaryHost?,
    targetAddress: String?,
    connectionMethod: String?,
    width: Int,
    height: Int,
    fps: Int,
    bitrateKbps: Int,
    codecName: String,
    enableYUV444: Bool,
    autoMode: Bool
  ) -> StreamRiskAssessment {
    let resolvedTarget = resolvedTargetAddress(host: host, targetAddress: targetAddress, connectionMethod: connectionMethod)
    let codec = StreamCodecKind.from(codecName)
    let profile = sanitizedProfile(
      width: width,
      height: height,
      fps: fps,
      codec: codec,
      enableYUV444: enableYUV444
    )
    let evaluation = evaluate(
      host: host,
      targetAddress: resolvedTarget,
      profile: profile,
      bitrateKbps: bitrateKbps,
      autoMode: autoMode
    )
    let recommendations = recommendedFallbacks(
      from: profile,
      host: host,
      targetAddress: resolvedTarget,
      bitrateKbps: max(1, bitrateKbps),
      autoMode: autoMode,
      currentRiskLevel: evaluation.riskLevel
    )
    let summaryLine = [
      streamRiskLocalizedFormat("Startup %@", evaluation.riskLevel.label),
      evaluation.routeTier.label,
      formatPixelRate(evaluation.pixelRate),
      String(format: "%.3f bpppf", evaluation.bitsPerPixelPerFrame),
    ].joined(separator: " · ")

    return StreamRiskAssessment(
      routeTier: evaluation.routeTier,
      riskLevel: evaluation.riskLevel,
      codecName: profile.codec.displayName,
      chromaName: profile.enableYUV444 ? "4:4:4" : "4:2:0",
      hostRuntimeLabel: evaluation.hostRuntimeLabel,
      targetFps: evaluation.targetFps,
      pixelRate: evaluation.pixelRate,
      bitsPerPixelPerFrame: evaluation.bitsPerPixelPerFrame,
      decodeSupported: evaluation.decodeSupported,
      displayRefreshRateHz: evaluation.displayRefreshRateHz,
      cadenceLabel: evaluation.cadenceLabel,
      wirelessLinkText: evaluation.wirelessLinkText,
      summaryLine: summaryLine,
      reasons: Array(evaluation.reasons.prefix(5)),
      recommendedFallbacks: recommendations,
      autoModeActive: autoMode,
      targetAddress: resolvedTarget
    )
  }

  private static func evaluate(
    host: TemporaryHost?,
    targetAddress: String,
    profile: StreamRiskProfile,
    bitrateKbps: Int,
    autoMode: Bool
  ) -> StreamRiskEvaluation {
    let routeTier = classifyRouteTier(host: host, targetAddress: targetAddress)
    let hostRuntimeInfo = inferredHostRuntimeInfo(host: host)
    let pixelRate = Double(profile.width) * Double(profile.height) * Double(profile.fps)
    let safeBitrateKbps = max(1, bitrateKbps)
    let bitsPerPixelPerFrame = Double(safeBitrateKbps) * 1000.0 / max(pixelRate, 1.0)
    let decodeSupported = hardwareDecodeSupported(for: profile.codec)
    let displayRefreshRateHz = currentDisplayRefreshRateHz()
    let cadence = cadenceAnalysis(targetFps: profile.fps, displayRefreshRateHz: displayRefreshRateHz)
    let wirelessLinkInfo = currentWirelessLinkInfo(forTarget: targetAddress)

    let thresholds = thresholdsFor(codec: profile.codec)
    let chromaMultiplier = profile.enableYUV444 ? 1.8 : 1.0
    let lowThreshold = thresholds.lowRiskBpppf * chromaMultiplier
    let mediumThreshold = thresholds.mediumRiskBpppf * chromaMultiplier

    var riskLevel = baseRiskLevel(
      bitsPerPixelPerFrame: bitsPerPixelPerFrame,
      lowThreshold: lowThreshold,
      mediumThreshold: mediumThreshold
    )
    var reasons: [String] = []

    if bitsPerPixelPerFrame < mediumThreshold {
      reasons.append(
        streamRiskLocalizedFormat(
          "%@ %@ budget is below the recommended realtime floor (%.3f < %.3f bpppf).",
          profile.codec.displayName,
          profile.enableYUV444 ? "4:4:4" : "4:2:0",
          bitsPerPixelPerFrame,
          mediumThreshold
        ))
    } else if bitsPerPixelPerFrame < lowThreshold {
      reasons.append(
        streamRiskLocalizedFormat(
          "%@ %@ budget is usable but tight for low-latency streaming (%.3f < %.3f bpppf).",
          profile.codec.displayName,
          profile.enableYUV444 ? "4:4:4" : "4:2:0",
          bitsPerPixelPerFrame,
          lowThreshold
        ))
    }

    if profile.enableYUV444 {
      reasons.append(streamRiskLocalized("YUV 4:4:4 increases chroma sample load and usually needs more bitrate or lower FPS to stay clean."))
    }

    if pixelRate >= 1_000_000_000 {
      riskLevel = maxRisk(riskLevel, .high)
      reasons.append(streamRiskLocalized("Pixel throughput is above 1.0 Gpix/s, so encode/decode/render timing becomes very sensitive."))
    } else if pixelRate >= 500_000_000 {
      riskLevel = maxRisk(riskLevel, .medium)
      reasons.append(streamRiskLocalized("Pixel throughput is high enough to stress realtime capture, decode, and render pacing."))
    }

    if !decodeSupported {
      riskLevel = maxRisk(riskLevel, .high)
      reasons.append(streamRiskLocalized("The selected codec does not have confirmed local hardware decode support on this Mac."))
    }

    if displayRefreshRateHz > 0, Double(profile.fps) > displayRefreshRateHz * 1.10 {
      let refreshRisk: StreamRiskLevel = Double(profile.fps) > displayRefreshRateHz * 1.50 ? .high : .medium
      riskLevel = maxRisk(riskLevel, refreshRisk)
      reasons.append(
        streamRiskLocalizedFormat(
          "Target FPS (%d) is above the current display refresh ceiling (%.2f Hz).",
          profile.fps,
          displayRefreshRateHz
        ))
    }

    if let addedRisk = cadence.addedRisk {
      riskLevel = maxRisk(riskLevel, addedRisk)
    }
    if let cadenceReason = cadence.reason {
      reasons.append(cadenceReason)
    }

    if let wirelessLinkInfo {
      if let addedRisk = wirelessLinkInfo.addedRisk {
        riskLevel = maxRisk(riskLevel, addedRisk)
      }
      if let wirelessReason = wirelessLinkInfo.reason {
        reasons.append(wirelessReason)
      }
    }

    if let hostRuntimeInfo,
       let hostTimingReason = hostTimingGuidanceReason(
        hostRuntimeInfo: hostRuntimeInfo,
        targetFps: profile.fps,
        displayRefreshRateHz: displayRefreshRateHz,
        cadence: cadence
       )
    {
      reasons.append(hostTimingReason)
    }

    switch routeTier {
    case .overlayRemote:
      reasons.append(streamRiskLocalized("The selected path is routed through a tunnel or overlay network."))
      if profile.fps >= 120 {
        riskLevel = maxRisk(riskLevel, .medium)
      }
    case .wanRemote:
      reasons.append(streamRiskLocalized("The selected path looks like a public / WAN route rather than direct LAN."))
      if profile.fps >= 120 {
        riskLevel = maxRisk(riskLevel, .medium)
      }
    case .lanHairpinOrSplitDNS:
      reasons.append(streamRiskLocalized("The address looks public, but the route still appears local (hairpin NAT or split DNS)."))
    case .lanDirect:
      reasons.append(streamRiskLocalized("The route looks like direct LAN transport."))
    case .unknown:
      reasons.append(streamRiskLocalized("The route could not be classified confidently before stream start."))
    }

    if autoMode {
      reasons.append(streamRiskLocalized("Auto mode may recommend a steadier startup profile, but it will not block launch."))
    } else {
      reasons.append(streamRiskLocalized("Manual Expert mode keeps your chosen resolution, FPS, codec, and chroma unchanged."))
    }

    return StreamRiskEvaluation(
      routeTier: routeTier,
      riskLevel: riskLevel,
      hostRuntimeLabel: hostRuntimeInfo?.label,
      targetFps: profile.fps,
      pixelRate: pixelRate,
      bitsPerPixelPerFrame: bitsPerPixelPerFrame,
      decodeSupported: decodeSupported,
      displayRefreshRateHz: displayRefreshRateHz,
      cadenceLabel: cadence.label,
      wirelessLinkText: wirelessLinkInfo?.text,
      reasons: reasons
    )
  }

  private static func recommendedFallbacks(
    from current: StreamRiskProfile,
    host: TemporaryHost?,
    targetAddress: String,
    bitrateKbps: Int,
    autoMode: Bool,
    currentRiskLevel: StreamRiskLevel
  ) -> [StreamRiskRecommendation] {
    var candidates: [StreamRiskProfile] = []

    if current.enableYUV444 || current.fps > 120 {
      candidates.append(
        sanitizedProfile(
          width: current.width,
          height: current.height,
          fps: min(current.fps, 120),
          codec: current.codec,
          enableYUV444: false
        ))
    }

    if current.fps > 60 {
      candidates.append(
        sanitizedProfile(
          width: current.width,
          height: current.height,
          fps: min(current.fps, 60),
          codec: current.codec,
          enableYUV444: current.enableYUV444
        ))
    }

    if current.codec != .h264 {
      candidates.append(
        sanitizedProfile(
          width: current.width,
          height: current.height,
          fps: min(current.fps, 120),
          codec: .h264,
          enableYUV444: false
        ))
    }

    if current.width * current.height > 2560 * 1440 {
      candidates.append(scaledDownProfile(from: current, maxWidth: 2560, maxHeight: 1440, maxFps: 120))
    }

    if current.width * current.height > 1920 * 1080 || current.fps > 90 {
      candidates.append(scaledDownProfile(from: current, maxWidth: 1920, maxHeight: 1080, maxFps: 60))
    }

    var seen: Set<StreamRiskProfile> = []
    var recommendations: [StreamRiskRecommendation] = []

    for candidate in candidates where candidate != current {
      guard seen.insert(candidate).inserted else { continue }

      let evaluation = evaluate(
        host: host,
        targetAddress: targetAddress,
        profile: candidate,
        bitrateKbps: bitrateKbps,
        autoMode: autoMode
      )
      guard evaluation.riskLevel.rawValue <= currentRiskLevel.rawValue else { continue }

      let summary = "\(candidate.width)×\(candidate.height) @ \(candidate.fps) · \(candidate.codec.displayName) · \(candidate.enableYUV444 ? "4:4:4" : "4:2:0") · \(streamRiskLocalizedFormat("Startup %@", evaluation.riskLevel.label))"
      recommendations.append(
        StreamRiskRecommendation(
          width: candidate.width,
          height: candidate.height,
          fps: candidate.fps,
          codecName: candidate.codec.displayName,
          enableYUV444: candidate.enableYUV444,
          predictedRiskLevel: evaluation.riskLevel,
          summaryLine: summary
        ))

      if recommendations.count == 3 {
        break
      }
    }

    return recommendations
  }

  private static func sanitizedProfile(
    width: Int,
    height: Int,
    fps: Int,
    codec: StreamCodecKind,
    enableYUV444: Bool
  ) -> StreamRiskProfile {
    let safeWidth = max(2, width & ~1)
    let safeHeight = max(2, height & ~1)
    return .init(
      width: safeWidth,
      height: safeHeight,
      fps: max(1, fps),
      codec: codec,
      enableYUV444: enableYUV444
    )
  }

  private static func scaledDownProfile(
    from current: StreamRiskProfile,
    maxWidth: Int,
    maxHeight: Int,
    maxFps: Int
  ) -> StreamRiskProfile {
    let widthRatio = Double(maxWidth) / Double(max(current.width, 1))
    let heightRatio = Double(maxHeight) / Double(max(current.height, 1))
    let scale = min(1.0, min(widthRatio, heightRatio))
    let scaledWidth = max(2, (Int((Double(current.width) * scale).rounded()) / 2) * 2)
    let scaledHeight = max(2, (Int((Double(current.height) * scale).rounded()) / 2) * 2)
    return sanitizedProfile(
      width: scaledWidth,
      height: scaledHeight,
      fps: min(current.fps, maxFps),
      codec: current.codec,
      enableYUV444: false
    )
  }

  private static func thresholdsFor(codec: StreamCodecKind) -> StreamRiskThresholds {
    switch codec {
    case .h264:
      return .init(lowRiskBpppf: 0.10, mediumRiskBpppf: 0.06)
    case .hevc:
      return .init(lowRiskBpppf: 0.07, mediumRiskBpppf: 0.04)
    case .av1:
      return .init(lowRiskBpppf: 0.055, mediumRiskBpppf: 0.03)
    }
  }

  private static func baseRiskLevel(
    bitsPerPixelPerFrame: Double,
    lowThreshold: Double,
    mediumThreshold: Double
  ) -> StreamRiskLevel {
    if bitsPerPixelPerFrame < mediumThreshold {
      return .high
    }
    if bitsPerPixelPerFrame < lowThreshold {
      return .medium
    }
    return .low
  }

  private static func maxRisk(_ lhs: StreamRiskLevel, _ rhs: StreamRiskLevel) -> StreamRiskLevel {
    lhs.rawValue >= rhs.rawValue ? lhs : rhs
  }

  private static func resolvedTargetAddress(
    host: TemporaryHost?,
    targetAddress: String?,
    connectionMethod: String?
  ) -> String {
    if let targetAddress, !targetAddress.isEmpty {
      return targetAddress
    }
    if let connectionMethod, !connectionMethod.isEmpty, connectionMethod != "Auto" {
      return connectionMethod
    }
    if let active = host?.activeAddress, !active.isEmpty {
      return active
    }
    if let local = host?.localAddress, !local.isEmpty {
      return local
    }
    if let ipv6 = host?.ipv6Address, !ipv6.isEmpty {
      return ipv6
    }
    if let external = host?.externalAddress, !external.isEmpty {
      return external
    }
    if let address = host?.address, !address.isEmpty {
      return address
    }
    return ""
  }

  private static func classifyRouteTier(host: TemporaryHost?, targetAddress: String) -> StreamRiskRouteTier {
    guard !targetAddress.isEmpty else { return .unknown }

    // This assessment runs while the stream window is being created on the
    // main thread. Never synchronously resolve a hostname here: mDNS/DNS can
    // block for several seconds and make the whole app look frozen. Actual
    // transport setup performs its own asynchronous/network-side validation.
    let egressIf = Self.isIpLiteral(targetAddress)
      ? (Utils.outboundInterfaceName(forAddress: targetAddress, sourceAddress: nil) ?? "")
      : ""
    if !egressIf.isEmpty, Utils.isTunnelInterfaceName(egressIf) {
      return .overlayRemote
    }

    if shouldTreatAsKnownLocalHost(targetAddress) {
      return .lanDirect
    }

    let hasKnownLocalCandidate = [host?.localAddress, host?.ipv6Address, host?.address]
      .compactMap { $0 }
      .contains(where: { shouldTreatAsKnownLocalHost($0) })

    if hasKnownLocalCandidate {
      if let external = host?.externalAddress, !external.isEmpty, external == targetAddress {
        return .lanHairpinOrSplitDNS
      }
      if !isIpLiteral(targetAddress) {
        return .lanHairpinOrSplitDNS
      }
    }

    if !egressIf.isEmpty {
      return .wanRemote
    }
    return .unknown
  }

  private static func hardwareDecodeSupported(for codec: StreamCodecKind) -> Bool {
    switch codec {
    case .h264:
      return true
    case .hevc:
      if #available(macOS 10.14, *) {
        return VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
      }
      return false
    case .av1:
      return VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
    }
  }

  private static func currentDisplayRefreshRateHz() -> Double {
    guard let screen = NSScreen.main,
      let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
      let mode = CGDisplayCopyDisplayMode(CGDirectDisplayID(screenNumber.uint32Value))
    else {
      return 0
    }

    let refresh = mode.refreshRate
    if refresh > 0 {
      return refresh
    }
    if #available(macOS 12.0, *) {
      return Double(screen.maximumFramesPerSecond)
    }
    return 0
  }

  private static func cadenceAnalysis(targetFps: Int, displayRefreshRateHz: Double) -> StreamCadenceAnalysis {
    guard targetFps > 0, displayRefreshRateHz > 0 else {
      return StreamCadenceAnalysis(label: streamRiskLocalized("Not Available"), addedRisk: nil, reason: nil)
    }

    let target = Double(targetFps)
    let refresh = displayRefreshRateHz

    if target > refresh + 0.10 {
      if abs(target - refresh) <= 0.20 {
        return StreamCadenceAnalysis(
          label: streamRiskLocalized("Fractional Mismatch"),
          addedRisk: .medium,
          reason: streamRiskLocalizedFormat(
            "Target FPS (%d) is slightly above the current display refresh (%.2f Hz), which can cause periodic cadence hitches.",
            targetFps,
            refresh
          )
        )
      }

      return StreamCadenceAnalysis(
        label: streamRiskLocalized("Display Ceiling"),
        addedRisk: nil,
        reason: nil
      )
    }

    let ratio = refresh / target
    let nearestInteger = round(ratio)
    if nearestInteger >= 1, abs(ratio - nearestInteger) <= 0.03 {
      if Int(nearestInteger) <= 1 {
        return StreamCadenceAnalysis(label: streamRiskLocalized("Matched"), addedRisk: nil, reason: nil)
      }

      return StreamCadenceAnalysis(
        label: streamRiskLocalizedFormat("Even %dx cadence", Int(nearestInteger)),
        addedRisk: nil,
        reason: nil
      )
    }

    return StreamCadenceAnalysis(
      label: streamRiskLocalized("Uneven Cadence"),
      addedRisk: .medium,
      reason: streamRiskLocalizedFormat(
        "Display refresh (%.2f Hz) does not divide evenly into target FPS (%d), so frame pacing may feel uneven.",
        refresh,
        targetFps
      )
    )
  }

  private static func currentWirelessLinkInfo(forTarget targetAddress: String) -> StreamWirelessLinkInfo? {
    guard !targetAddress.isEmpty else { return nil }

    let egressIf = Self.isIpLiteral(targetAddress)
      ? (Utils.outboundInterfaceName(forAddress: targetAddress, sourceAddress: nil) ?? "")
      : ""
    guard !egressIf.isEmpty else { return nil }

    let wifiInterface = CWWiFiClient.shared().interface(withName: egressIf)
    guard let wifiInterface, wifiInterface.powerOn() else { return nil }

    guard let channel = wifiInterface.wlanChannel() else {
      return StreamWirelessLinkInfo(text: streamRiskLocalized("Wi-Fi (channel unavailable)"), addedRisk: nil, reason: nil)
    }

    let channelNumber = Int(channel.channelNumber)
    let bandText: String
    if channelNumber >= 1 && channelNumber <= 14 {
      bandText = "2.4 GHz"
    } else if channelNumber >= 32 && channelNumber <= 196 {
      bandText = "5 GHz"
    } else {
      bandText = streamRiskLocalized("Wi-Fi")
    }

    let text = "\(bandText) · Ch \(channelNumber)"

    if channelNumber >= 1 && channelNumber <= 14 {
      return StreamWirelessLinkInfo(
        text: text,
        addedRisk: .medium,
        reason: streamRiskLocalizedFormat(
          "Wi-Fi is currently on 2.4 GHz (channel %d), which is especially sensitive to AirDrop / AWDL coexistence and jitter.",
          channelNumber
        )
      )
    }

    if channelNumber >= 32 && channelNumber < 149 {
      return StreamWirelessLinkInfo(
        text: text,
        addedRisk: .medium,
        reason: streamRiskLocalizedFormat(
          "Wi-Fi is currently on 5 GHz channel %d. If AirDrop / Handoff is active, AWDL-related jitter is more likely to show up here than on 149+ channels.",
          channelNumber
        )
      )
    }

    return StreamWirelessLinkInfo(text: text, addedRisk: nil, reason: nil)
  }

  fileprivate static func formatPixelRate(_ pixelRate: Double) -> String {
    if pixelRate >= 1_000_000_000 {
      return String(format: "%.2f Gpix/s", pixelRate / 1_000_000_000)
    }
    if pixelRate >= 1_000_000 {
      return String(format: "%.0f Mpix/s", pixelRate / 1_000_000)
    }
    return String(format: "%.0f pix/s", pixelRate)
  }

  private static func shouldTreatAsKnownLocalHost(_ host: String) -> Bool {
    guard !host.isEmpty else { return false }
    let lower = host.lowercased()
    if lower == "localhost" || lower.hasSuffix(".local") {
      return true
    }
    guard isIpLiteral(host) else { return false }
    return isPrivateOrLocalIPv4(host) || isPrivateOrLocalIPv6(host)
  }

  private static func isIpLiteral(_ host: String) -> Bool {
    var addr4 = in_addr()
    let isIPv4 = host.withCString { inet_pton(AF_INET, $0, &addr4) } == 1
    if isIPv4 {
      return true
    }
    var addr6 = in6_addr()
    return host.withCString { inet_pton(AF_INET6, $0, &addr6) } == 1
  }

  private static func isPrivateOrLocalIPv4(_ ip: String) -> Bool {
    var addr = in_addr()
    guard ip.withCString({ inet_pton(AF_INET, $0, &addr) }) == 1 else { return false }
    let hostValue = UInt32(bigEndian: addr.s_addr)
    if (hostValue & 0xFF00_0000) == 0x0A00_0000 { return true }
    if (hostValue & 0xFFF0_0000) == 0xAC10_0000 { return true }
    if (hostValue & 0xFFFF_0000) == 0xC0A8_0000 { return true }
    if (hostValue & 0xFFFF_0000) == 0xA9FE_0000 { return true }
    if (hostValue & 0xFF00_0000) == 0x7F00_0000 { return true }
    return false
  }

  private static func isPrivateOrLocalIPv6(_ ip: String) -> Bool {
    var addr = in6_addr()
    guard ip.withCString({ inet_pton(AF_INET6, $0, &addr) }) == 1 else { return false }
    let bytes = withUnsafeBytes(of: &addr) { Array($0.prefix(16)) }

    if bytes.prefix(15).allSatisfy({ $0 == 0 }) && bytes[15] == 1 {
      return true
    }

    if bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80 {
      return true
    }

    if (bytes[0] & 0xFE) == 0xFC {
      return true
    }

    return false
  }

  private static func inferredHostRuntimeInfo(host: TemporaryHost?) -> StreamHostRuntimeInfo? {
    let haystack = [
      host?.gfeVersion,
      host?.appVersion,
      host?.name,
      host?.displayName,
    ]
    .compactMap { $0?.lowercased() }
    .joined(separator: "\n")

    guard !haystack.isEmpty else { return nil }

    if haystack.contains("apollo") {
      return StreamHostRuntimeInfo(label: "Apollo")
    }
    if haystack.contains("foundation sunshine") || haystack.contains("sunshine foundation") {
      return StreamHostRuntimeInfo(label: "Foundation Sunshine")
    }
    if haystack.contains("sunshine") {
      return StreamHostRuntimeInfo(label: "Sunshine")
    }
    if haystack.contains("geforce") || haystack.contains("gamestream") || haystack.contains("nvidia") {
      return StreamHostRuntimeInfo(label: "GameStream / GFE")
    }
    return nil
  }

  private static func hostTimingGuidanceReason(
    hostRuntimeInfo: StreamHostRuntimeInfo,
    targetFps: Int,
    displayRefreshRateHz: Double,
    cadence: StreamCadenceAnalysis
  ) -> String? {
    let cadenceNeedsGuidance =
      cadence.addedRisk != nil
      || (displayRefreshRateHz > 0 && Double(targetFps) > displayRefreshRateHz + 0.10)

    guard cadenceNeedsGuidance else { return nil }

    switch hostRuntimeInfo.label {
    case "Apollo":
      return streamRiskLocalized("Apollo users usually get steadier pacing from Display Mode Override or a virtual / headless display that matches the stream FPS.")
    case "Foundation Sunshine":
      return streamRiskLocalized("Foundation Sunshine users should try refresh remap, VRR, or a matched virtual display when cadence looks uneven.")
    case "Sunshine":
      return streamRiskLocalized("Sunshine users often get steadier frame pacing from a virtual display or a host display mode that matches the stream FPS.")
    default:
      return nil
    }
  }
}
