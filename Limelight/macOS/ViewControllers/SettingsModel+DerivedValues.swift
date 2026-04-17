//
//  SettingsModel.swift
//  Moonlight SwiftUI
//
//  Created by Michael Kenny on 25/1/2023.
//  Copyright © 2023 Moonlight Game Streaming Project. All rights reserved.
//

import AppKit
import CoreGraphics
import Metal
import SwiftUI
import VideoToolbox

@objc enum MouseInputDriverStrategy: Int, CaseIterable {
  case compatibility = 0
  case gameController = 1
  case coreHID = 2
  case automatic = 3

  static let defaultStrategy: Self = .automatic

  init(persistedRawValue: Int?) {
    switch persistedRawValue {
    case MouseInputDriverStrategy.gameController.rawValue:
      self = .gameController
    case MouseInputDriverStrategy.coreHID.rawValue:
      self = .coreHID
    case MouseInputDriverStrategy.automatic.rawValue:
      self = .automatic
    default:
      self = .compatibility
    }
  }

  init(selection: String) {
    self =
      Self.allCases.first(where: { $0.displayKey == selection })
      ?? Self.defaultStrategy
  }

  var displayKey: String {
    switch self {
    case .compatibility:
      return "HID"
    case .gameController:
      return "MFI"
    case .coreHID:
      return "CoreHID"
    case .automatic:
      return "Automatic"
    }
  }

  static var displayKeys: [String] {
    displayOrder.map(\.displayKey)
  }

  static let displayOrder: [Self] = [.automatic, .coreHID, .compatibility, .gameController]
}

@objc enum PhysicalWheelScrollMode: Int, CaseIterable {
  case automatic = 2
  case highPrecision = 1
  case notched = 0

  static let defaultMode: Self = .automatic

  init(persistedRawValue: Int?) {
    switch persistedRawValue {
    case PhysicalWheelScrollMode.automatic.rawValue:
      self = .automatic
    case PhysicalWheelScrollMode.highPrecision.rawValue:
      self = .highPrecision
    case PhysicalWheelScrollMode.notched.rawValue:
      self = .notched
    default:
      self = .automatic
    }
  }

  init(selection: String) {
    self = Self.allCases.first(where: { $0.displayKey == selection }) ?? Self.defaultMode
  }

  var displayKey: String {
    switch self {
    case .automatic:
      return "Automatic"
    case .notched:
      return "Notched"
    case .highPrecision:
      return "High Precision"
    }
  }

  static var displayKeys: [String] {
    Self.allCases.map(\.displayKey)
  }
}

@objc enum RewrittenScrollMode: Int, CaseIterable {
  case adaptive = 0
  case notched = 1
  case highPrecision = 2

  static let defaultMode: Self = .adaptive

  init(persistedRawValue: Int?) {
    switch persistedRawValue {
    case RewrittenScrollMode.notched.rawValue:
      self = .notched
    case RewrittenScrollMode.highPrecision.rawValue:
      self = .highPrecision
    default:
      self = .adaptive
    }
  }

  init(selection: String) {
    self = Self.allCases.first(where: { $0.displayKey == selection }) ?? Self.defaultMode
  }

  var displayKey: String {
    switch self {
    case .adaptive:
      return "Automatic"
    case .notched:
      return "Notched"
    case .highPrecision:
      return "High Precision"
    }
  }

  static var displayKeys: [String] {
    Self.allCases.map(\.displayKey)
  }
}

@objc enum FreeMouseMotionMode: Int, CaseIterable {
  case automatic = 0
  case standard = 1
  case highPolling = 2

  static let defaultMode: Self = .automatic

  init(persistedRawValue: Int?) {
    switch persistedRawValue {
    case FreeMouseMotionMode.standard.rawValue:
      self = .standard
    case FreeMouseMotionMode.highPolling.rawValue:
      self = .highPolling
    default:
      self = .automatic
    }
  }

  init(selection: String) {
    self = Self.allCases.first(where: { $0.displayKey == selection }) ?? Self.defaultMode
  }

  var displayKey: String {
    switch self {
    case .automatic:
      return "Automatic"
    case .standard:
      return "Desktop Sync"
    case .highPolling:
      return "Fast Response"
    }
  }

  static var displayKeys: [String] {
    Self.allCases.map(\.displayKey)
  }
}

@objc enum KeyboardCompatibilityMode: Int, CaseIterable {
  case standard = 0
  case commandToControl = 1
  case swapLeftControlAndWin = 2
  case shortcutTranslation = 3
  case hybrid = 4

  static let defaultMode: Self = .standard

  init(persistedRawValue: Int?) {
    switch persistedRawValue {
    case KeyboardCompatibilityMode.commandToControl.rawValue:
      self = .commandToControl
    case KeyboardCompatibilityMode.swapLeftControlAndWin.rawValue:
      self = .swapLeftControlAndWin
    case KeyboardCompatibilityMode.shortcutTranslation.rawValue:
      self = .shortcutTranslation
    case KeyboardCompatibilityMode.hybrid.rawValue:
      self = .hybrid
    default:
      self = .standard
    }
  }

  init(selection: String) {
    self = Self.allCases.first(where: { $0.displayKey == selection }) ?? Self.defaultMode
  }

  var displayKey: String {
    switch self {
    case .standard:
      return "Keep Mac Shortcuts"
    case .commandToControl:
      return "⌘ Always as Ctrl"
    case .swapLeftControlAndWin:
      return "Left Ctrl ↔ Left Win"
    case .shortcutTranslation:
      return "Mac Shortcuts as Windows Shortcuts"
    case .hybrid:
      return "Windows Shortcuts + Left Ctrl ↔ Left Win"
    }
  }

  static var displayKeys: [String] {
    Self.allCases.map(\.displayKey)
  }
}

extension SettingsModel {
  func refreshConnectionCandidates() {
    guard let hostId = selectedHost?.id, hostId != Self.globalHostId else { return }

    let dataMan = DataManager()
    guard let hosts = dataMan.getHosts() as? [TemporaryHost],
      let host = hosts.first(where: { !$0.uuid.isEmpty && $0.uuid == hostId })
    else { return }

    let endpoints = ConnectionEndpointStore.allEndpoints(for: host)
    if endpoints.isEmpty { return }

    DispatchQueue.global(qos: .userInitiated).async {
      let group = DispatchGroup()
      let lock = NSLock()
      let cached = self.latencyCache[hostId]
      var latencies: [String: NSNumber] = cached?["latencies"] as? [String: NSNumber]
        ?? host.addressLatencies ?? [:]
      var states: [String: NSNumber] = cached?["states"] as? [String: NSNumber]
        ?? host.addressStates ?? [:]
      var receivedResponse = false
      var receivedPing = false
      var minLatency = Double.greatestFiniteMagnitude
      var bestAddress: String?

      for address in endpoints {
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
          let pingMs = LatencyProbe.icmpPingMs(forAddress: address)

          let start = Date()
          let hMan = HttpManager(host: address, uniqueId: IdManager.getUniqueId(), serverCert: host.serverCert)
          let serverInfo = ServerInfoResponse()
          if let hMan {
            let request = HttpRequest(
              for: serverInfo,
              with: hMan.newServerInfoRequest(true),
              fallbackError: 401,
              fallbackRequest: hMan.newHttpServerInfoRequest(true)
            )
            hMan.executeRequestSynchronously(request)
          }

          let rtt = -start.timeIntervalSinceNow * 1000.0
          let isOk = serverInfo.isStatusOk()
          let uuid = serverInfo.getStringTag(TAG_UNIQUE_ID)
          let matchesHost = uuid == host.uuid

          lock.lock()
          if let pingMs {
            latencies[address] = pingMs
            receivedPing = true
          }

          if isOk && matchesHost {
            receivedResponse = true
            if latencies[address] == nil {
              latencies[address] = NSNumber(value: Int(rtt))
            }
            states[address] = NSNumber(value: 1)

            let bestMetric = (latencies[address]?.doubleValue) ?? rtt
            if bestMetric < minLatency {
              minLatency = bestMetric
              bestAddress = address
            }
          } else if pingMs != nil {
            // ICMP success implies reachable; treat as online for UI purposes
            states[address] = NSNumber(value: 1)
            let bestMetric = pingMs?.doubleValue ?? rtt
            if bestMetric < minLatency {
              minLatency = bestMetric
              bestAddress = address
            }
          }
          lock.unlock()
          group.leave()
        }
      }

      group.wait()

      DispatchQueue.main.async {
        host.addressLatencies = latencies
        host.addressStates = states
        host.state = (receivedResponse || receivedPing) ? .online : .unknown

        if let best = bestAddress {
          host.activeAddress = best
          DataManager().update(host)
        }

        NotificationCenter.default.post(
          name: Notification.Name("HostLatencyUpdated"),
          object: nil,
          userInfo: ["uuid": hostId, "latencies": latencies, "states": states]
        )

        self.ensureConnectionMethodValid()
        self.objectWillChange.send()
      }
    }
  }

  func ensureConnectionMethodValid() {
    let methods = Set(connectionCandidates.map { $0.id })
    if !methods.contains(selectedConnectionMethod) {
      selectedConnectionMethod = "Auto"
    }
  }

  static var resolutions: [CGSize] = [
    matchDisplayResolutionSentinel,
    CGSizeMake(1280, 720), CGSizeMake(1920, 1080), CGSizeMake(2560, 1440), CGSizeMake(3840, 2160),
    .zero,
  ]
  static var fpss: [Int] = [30, 60, 90, 120, 144, .zero]
  private static var lockedBitrateSteps: [Float] = [
    0.5,
    1,
    1.5,
    2,
    2.5,
    3,
    4,
    5,
    6,
    7,
    8,
    9,
    10,
    12,
    15,
    18,
    20,
    25,
    30,
    40,
    50,
    60,
    70,
    80,
    90,
    100,
    120,
    150,
  ]

  static func bitrateSteps(unlocked: Bool) -> [Float] {
    if !unlocked {
      return lockedBitrateSteps
    }
    return lockedBitrateSteps + [200, 250, 300, 350, 400, 500, 600, 800, 1000]
  }
  static var videoCodecs: [String] = ["H.264", "H.265", "AV1"]
  static var pacingOptions: [String] = ["Lowest Latency", "Smoothest Video"]
  static var audioConfigurations: [String] = [
    "Stereo",
    "5.1 surround sound",
    "7.1 surround sound",
    "7.1.4 surround sound",
  ]
  static var audioOutputModes: [String] = [
    "Default",
    "Audio Enhancement",
  ]
  static var enhancedAudioOutputTargets: [String] = [
    "Headphones",
    "Speakers",
    "Automatic",
  ]
  static var enhancedAudioOutputTargetDisplayOrder: [String] = [
    "Automatic",
    "Headphones",
    "Speakers",
  ]
  static var enhancedAudioPresets: [String] = [
    "Reference",
    "Immersive Gaming",
    "Dialogue Clarity",
    "Bass Boost",
    "Harman Inspired",
    "Music Warmth",
    "Vocal Presence",
    "Air & Detail",
  ]
  static var enhancedAudioEQLayouts: [String] = [
    "12-Band",
    "24-Band",
  ]
  private static let legacyEnhancedAudioEQAnchorFrequencies: [Double] = [
    32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000,
  ]
  private static let enhancedAudioEQFrequencies12Band: [Double] = [
    32, 64, 125, 250, 500, 1000, 2000, 4000, 6000, 8000, 12000, 16000,
  ]
  private static let enhancedAudioEQFrequencies24Band: [Double] = [
    20, 25, 32, 40, 50, 63, 80, 100, 125, 160, 200, 250,
    315, 400, 500, 630, 800, 1000, 1600, 2500, 4000, 6300, 10000, 16000,
  ]
  static var multiControllerModes: [String] = ["Single", "Auto"]

  static var controllerDrivers: [String] = ["HID", "MFi"]
  static var mouseDrivers: [String] = MouseInputDriverStrategy.displayKeys
  static var physicalWheelModes: [String] = PhysicalWheelScrollMode.displayKeys
  static var rewrittenScrollModes: [String] = RewrittenScrollMode.displayKeys
  static var freeMouseMotionModes: [String] = FreeMouseMotionMode.displayKeys
  static var keyboardCompatibilityModes: [String] = KeyboardCompatibilityMode.displayKeys
  static var coreHIDMaxMouseReportRates: [Int] = [1000, 2000, 4000, 8000, 500, 250, 125, 0]
  static var mouseModes: [String] = ["game", "remote"]
  static var touchscreenModes: [String] = ["Trackpad", "Touchscreen"]
  static var displayModes: [String] = ["Windowed", "Fullscreen", "Borderless Windowed"]

  static var isMetalFXSupported: Bool {
    if #available(macOS 13.0, *) {
      return true
    }
    return false
  }

  static var hevcHardwareDecodeSupported: Bool {
    VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
  }

  private static func displayHDRAvailability(for screen: NSScreen?) -> CapabilityAvailability {
    guard let screen else { return .unavailable }

    let currentEDR = screen.maximumExtendedDynamicRangeColorComponentValue
    let potentialEDR = screen.maximumPotentialExtendedDynamicRangeColorComponentValue
    let p3Gamut = NSDisplayGamut(rawValue: 1) ?? NSDisplayGamut(rawValue: 0)!
    let wideGamut = screen.canRepresent(p3Gamut)

    if potentialEDR > 1.0 && wideGamut {
      return .available
    }
    if currentEDR > 1.0 || wideGamut {
      return .limited
    }
    return .unavailable
  }

  private static func enhancedRendererAvailability(
    metalAvailable: Bool,
    displayHDRAvailability: CapabilityAvailability
  ) -> CapabilityAvailability {
    guard metalAvailable else { return .unavailable }
    if displayHDRAvailability == .unavailable {
      return .limited
    }
    return .available
  }

  private static func lowLatencySuperResolutionAvailability() -> CapabilityAvailability {
    if #available(macOS 26.0, *) {
      return VTLowLatencySuperResolutionScalerConfiguration.isSupported ? .available : .unavailable
    }
    return .unavailable
  }

  private static func lowLatencyFrameInterpolationAvailability() -> CapabilityAvailability {
    if #available(macOS 26.0, *) {
      return VTLowLatencyFrameInterpolationConfiguration.isSupported ? .available : .unavailable
    }
    return .unavailable
  }

  private static func qualitySuperResolutionAvailability() -> CapabilityAvailability {
    if #available(macOS 26.0, *) {
      guard VTSuperResolutionScalerConfiguration.isSupported else { return .unavailable }
      let supportedScaleFactors = VTSuperResolutionScalerConfiguration.supportedScaleFactors
      let supports2x = supportedScaleFactors.contains(2)
      guard supports2x else { return .limited }
      guard
        let config = VTSuperResolutionScalerConfiguration(
          frameWidth: 1280,
          frameHeight: 720,
          scaleFactor: 2,
          inputType: .video,
          usePrecomputedFlow: false,
          qualityPrioritization: .normal,
          revision: VTSuperResolutionScalerConfiguration.defaultRevision
        )
      else {
        return .limited
      }

      switch config.configurationModelStatus {
      case .ready:
        return .available
      case .downloadRequired, .downloading:
        return .limited
      @unknown default:
        return .limited
      }
    }
    return .unavailable
  }

  static func currentVideoCapabilityMatrix() -> VideoCapabilityMatrix {
    let screen = NSScreen.main ?? NSScreen.screens.first
    let displayName = screen?.localizedName ?? ""
    let metalAvailable = MTLCreateSystemDefaultDevice() != nil
    let hdrAvailability = displayHDRAvailability(for: screen)

    return VideoCapabilityMatrix(
      displayName: displayName,
      items: [
        VideoCapabilityItem(
          id: "renderer.native",
          titleKey: "Native Renderer",
          availability: .available,
          detailKey: "Native Renderer detail"
        ),
        VideoCapabilityItem(
          id: "renderer.enhanced",
          titleKey: "Enhanced Renderer",
          availability: enhancedRendererAvailability(
            metalAvailable: metalAvailable,
            displayHDRAvailability: hdrAvailability),
          detailKey: "Enhanced Renderer detail"
        ),
        VideoCapabilityItem(
          id: "renderer.compatibility",
          titleKey: "Compatibility Renderer",
          availability: .available,
          detailKey: "Compatibility Renderer detail"
        ),
        VideoCapabilityItem(
          id: "display.hdr",
          titleKey: "HDR Display",
          availability: hdrAvailability,
          detailKey: "HDR Display detail"
        ),
        VideoCapabilityItem(
          id: "decode.av1",
          titleKey: "AV1 Decode",
          availability: av1HardwareDecodeSupported ? .available : .limited,
          detailKey: "AV1 Decode detail"
        ),
        VideoCapabilityItem(
          id: "decode.hevc",
          titleKey: "HEVC Decode",
          availability: hevcHardwareDecodeSupported ? .available : .limited,
          detailKey: "HEVC Decode detail"
        ),
        VideoCapabilityItem(
          id: "enhancement.metalfx",
          titleKey: "MetalFX",
          availability: isMetalFXSupported ? .available : .unavailable,
          detailKey: "MetalFX capability detail"
        ),
        VideoCapabilityItem(
          id: "enhancement.vtLowLatencySR",
          titleKey: "VT Low-Latency Super Resolution",
          availability: lowLatencySuperResolutionAvailability(),
          detailKey: "VT Low-Latency Super Resolution detail"
        ),
        VideoCapabilityItem(
          id: "enhancement.vtLowLatencyFI",
          titleKey: "VT Low-Latency Frame Interpolation",
          availability: lowLatencyFrameInterpolationAvailability(),
          detailKey: "VT Low-Latency Frame Interpolation detail"
        ),
        VideoCapabilityItem(
          id: "enhancement.vtQualitySR",
          titleKey: "VT Quality Super Resolution",
          availability: qualitySuperResolutionAvailability(),
          detailKey: "VT Quality Super Resolution detail"
        ),
        VideoCapabilityItem(
          id: "sunshine.extensions",
          titleKey: "Sunshine Extensions",
          availability: .available,
          detailKey: "Sunshine Extensions detail"
        ),
      ]
    )
  }

  static let upscalingModeOptions: [(title: String, value: Int)] = [
    ("Auto", 6),
    ("VT Low-Latency Super Resolution", 3),
    ("VT Quality Super Resolution", 4),
    ("MetalFX Spatial (Quality)", 1),
    ("MetalFX Spatial (Performance)", 2),
    ("Basic Scaling", 5),
    ("Off", 0),
  ]

  static var upscalingModes: [String] {
    upscalingModeOptions.map(\.title)
  }

  static func upscalingModeRawValue(for title: String) -> Int {
    upscalingModeOptions.first(where: { $0.title == title })?.value ?? defaultUpscalingMode
  }

  static func upscalingModeTitle(for rawValue: Int) -> String {
    upscalingModeOptions.first(where: { $0.value == rawValue })?.title
      ?? upscalingModeOptions.first(where: { $0.value == defaultUpscalingMode })?.title
      ?? "Auto"
  }
  static let frameInterpolationModeOptions: [(title: String, value: Int)] = [
    ("Off", 0),
    ("VT Low-Latency Frame Interpolation", 1),
  ]
  static var frameInterpolationModes: [String] {
    frameInterpolationModeOptions.map(\.title)
  }
  static let defaultFrameInterpolationMode = 0

  static func frameInterpolationModeRawValue(for title: String) -> Int {
    frameInterpolationModeOptions.first(where: { $0.title == title })?.value
      ?? defaultFrameInterpolationMode
  }

  static func frameInterpolationModeSelection(for rawValue: Int?) -> String {
    guard let rawValue else {
      return frameInterpolationModeOptions.first(where: { $0.value == defaultFrameInterpolationMode })?.title
        ?? "Off"
    }
    return frameInterpolationModeOptions.first(where: { $0.value == rawValue })?.title
      ?? frameInterpolationModeOptions.first(where: { $0.value == defaultFrameInterpolationMode })?.title
      ?? "Off"
  }

  static let defaultResolution = CGSizeMake(1920, 1080)
  static let defaultCustomResWidth: CGFloat? = nil
  static let defaultCustomResHeight: CGFloat? = nil
  static let defaultFps = 60
  static let defaultCustomFps: CGFloat? = nil

  static let defaultRemoteResolutionEnabled = false
  static let defaultRemoteResolution = CGSizeMake(1920, 1080)
  static let defaultRemoteCustomResWidth: CGFloat? = nil
  static let defaultRemoteCustomResHeight: CGFloat? = nil
  static let defaultRemoteFpsEnabled = false
  static let defaultRemoteFps = 60
  static let defaultRemoteCustomFps: CGFloat? = nil
  static let hdrTransferFunctionOptions: [(title: String, value: Int)] = [
    ("Auto", 0),
    ("HLG", 2),
    ("PQ", 1),
  ]
  static var hdrTransferFunctions: [String] {
    hdrTransferFunctionOptions.map(\.title)
  }
  static let defaultHdrTransferFunction = "Auto"

  static func hdrTransferFunctionRawValue(for selection: String) -> Int {
    hdrTransferFunctionOptions.first(where: { $0.title == selection })?.value ?? 0
  }

  static func hdrTransferFunctionSelection(for rawValue: Int?) -> String {
    guard let rawValue else { return defaultHdrTransferFunction }
    return hdrTransferFunctionOptions.first(where: { $0.value == rawValue })?.title
      ?? defaultHdrTransferFunction
  }
  static let hdrMetadataSourceOptions: [(title: String, value: Int)] = [
    ("Hybrid", 2),
    ("Host", 0),
    ("Client Override", 1),
  ]
  static var hdrMetadataSources: [String] {
    hdrMetadataSourceOptions.map(\.title)
  }
  static let defaultHdrMetadataSource = "Hybrid"

  static func hdrMetadataSourceRawValue(for selection: String) -> Int {
    hdrMetadataSourceOptions.first(where: { $0.title == selection })?.value ?? 2
  }

  static func hdrMetadataSourceSelection(for rawValue: Int?) -> String {
    guard let rawValue else { return defaultHdrMetadataSource }
    return hdrMetadataSourceOptions.first(where: { $0.value == rawValue })?.title
      ?? defaultHdrMetadataSource
  }

  static let hdrClientDisplayProfileOptions: [(title: String, value: Int)] = [
    ("Auto", 0),
    ("Manual", 1),
  ]
  static var hdrClientDisplayProfiles: [String] {
    hdrClientDisplayProfileOptions.map(\.title)
  }
  static let defaultHdrClientDisplayProfile = "Auto"

  static func hdrClientDisplayProfileRawValue(for selection: String) -> Int {
    hdrClientDisplayProfileOptions.first(where: { $0.title == selection })?.value ?? 0
  }

  static func hdrClientDisplayProfileSelection(for rawValue: Int?) -> String {
    guard let rawValue else { return defaultHdrClientDisplayProfile }
    return hdrClientDisplayProfileOptions.first(where: { $0.value == rawValue })?.title
      ?? defaultHdrClientDisplayProfile
  }
  static let defaultHdrManualMaxBrightness: CGFloat = 1000.0
  static let defaultHdrManualMinBrightness: CGFloat = 0.001
  static let defaultHdrManualMaxAverageBrightness: CGFloat = 1000.0

  static let hdrHlgViewingEnvironmentOptions: [(title: String, value: Int)] = [
    ("Auto", 0),
    ("Reference", 1),
    ("Dim Room", 2),
    ("Office", 3),
    ("Bright Room", 4),
  ]
  static var hdrHlgViewingEnvironments: [String] {
    hdrHlgViewingEnvironmentOptions.map(\.title)
  }
  static let defaultHdrHlgViewingEnvironment = "Auto"

  static func hdrHlgViewingEnvironmentRawValue(for selection: String) -> Int {
    hdrHlgViewingEnvironmentOptions.first(where: { $0.title == selection })?.value ?? 0
  }

  static func hdrHlgViewingEnvironmentSelection(for rawValue: Int?) -> String {
    guard let rawValue else { return defaultHdrHlgViewingEnvironment }
    return hdrHlgViewingEnvironmentOptions.first(where: { $0.value == rawValue })?.title
      ?? defaultHdrHlgViewingEnvironment
  }

  static let hdrEdrStrategyOptions: [(title: String, value: Int)] = [
    ("Auto", 0),
    ("Conservative", 1),
    ("Balanced", 2),
    ("Peak", 3),
  ]
  static var hdrEdrStrategies: [String] {
    hdrEdrStrategyOptions.map(\.title)
  }
  static let defaultHdrEdrStrategy = "Auto"

  static func hdrEdrStrategyRawValue(for selection: String) -> Int {
    hdrEdrStrategyOptions.first(where: { $0.title == selection })?.value ?? 0
  }

  static func hdrEdrStrategySelection(for rawValue: Int?) -> String {
    guard let rawValue else { return defaultHdrEdrStrategy }
    return hdrEdrStrategyOptions.first(where: { $0.value == rawValue })?.title
      ?? defaultHdrEdrStrategy
  }

  static let hdrToneMappingPolicyOptions: [(title: String, value: Int)] = [
    ("Auto", 0),
    ("Preserve Highlights", 1),
    ("Preserve Midtones", 2),
    ("Preserve Shadows", 3),
    ("Reference", 4),
  ]
  static var hdrToneMappingPolicies: [String] {
    hdrToneMappingPolicyOptions.map(\.title)
  }
  static let defaultHdrToneMappingPolicy = "Auto"

  static func hdrToneMappingPolicyRawValue(for selection: String) -> Int {
    hdrToneMappingPolicyOptions.first(where: { $0.title == selection })?.value ?? 0
  }

  static func hdrToneMappingPolicySelection(for rawValue: Int?) -> String {
    guard let rawValue else { return defaultHdrToneMappingPolicy }
    return hdrToneMappingPolicyOptions.first(where: { $0.value == rawValue })?.title
      ?? defaultHdrToneMappingPolicy
  }

  static let displaySyncModeOptions: [(title: String, value: Int)] = [
    ("Auto", 0),
    ("On", 1),
    ("Off", 2),
  ]
  static var displaySyncModes: [String] {
    displaySyncModeOptions.map(\.title)
  }
  static let defaultDisplaySyncMode = "Auto"

  static func displaySyncModeRawValue(for selection: String) -> Int {
    displaySyncModeOptions.first(where: { $0.title == selection })?.value ?? 0
  }

  static func displaySyncModeSelection(for rawValue: Int?) -> String {
    guard let rawValue else { return defaultDisplaySyncMode }
    return displaySyncModeOptions.first(where: { $0.value == rawValue })?.title
      ?? defaultDisplaySyncMode
  }

  static let frameQueueTargetOptions: [(title: String, value: Int)] = [
    ("Auto", -1),
    ("0", 0),
    ("1", 1),
    ("2", 2),
    ("3", 3),
  ]
  static var frameQueueTargets: [String] {
    frameQueueTargetOptions.map(\.title)
  }
  static let defaultFrameQueueTarget = "Auto"

  static func frameQueueTargetRawValue(for selection: String) -> Int {
    frameQueueTargetOptions.first(where: { $0.title == selection })?.value ?? -1
  }

  static func frameQueueTargetSelection(for rawValue: Int?) -> String {
    guard let rawValue else { return defaultFrameQueueTarget }
    return frameQueueTargetOptions.first(where: { $0.value == rawValue })?.title
      ?? defaultFrameQueueTarget
  }

  static let responsivenessBiasOptions: [(title: String, value: Int)] = [
    ("Off", 0),
    ("Mild", 1),
    ("Strong", 2),
  ]
  static var responsivenessBiasModes: [String] {
    responsivenessBiasOptions.map(\.title)
  }
  static let defaultResponsivenessBias = "Off"

  static func responsivenessBiasRawValue(for selection: String) -> Int {
    responsivenessBiasOptions.first(where: { $0.title == selection })?.value ?? 0
  }

  static func responsivenessBiasSelection(for rawValue: Int?) -> String {
    guard let rawValue else { return defaultResponsivenessBias }
    return responsivenessBiasOptions.first(where: { $0.value == rawValue })?.title
      ?? defaultResponsivenessBias
  }

  static let allowDrawableTimeoutOptions: [(title: String, value: Int)] = [
    ("Auto", 0),
    ("On", 1),
    ("Off", 2),
  ]
  static var allowDrawableTimeoutModes: [String] {
    allowDrawableTimeoutOptions.map(\.title)
  }
  static let defaultAllowDrawableTimeoutMode = "Auto"

  static func allowDrawableTimeoutRawValue(for selection: String) -> Int {
    allowDrawableTimeoutOptions.first(where: { $0.title == selection })?.value ?? 0
  }

  static func allowDrawableTimeoutSelection(for rawValue: Int?) -> String {
    guard let rawValue else { return defaultAllowDrawableTimeoutMode }
    return allowDrawableTimeoutOptions.first(where: { $0.value == rawValue })?.title
      ?? defaultAllowDrawableTimeoutMode
  }

  static let sunshineScreenModeOptions: [(title: String, value: Int)] = [
    ("Host Default", -1),
    ("Verify Only", 0),
    ("Activate Display", 1),
    ("Make Primary", 2),
    ("Only Stream Display", 3),
    ("Use As Secondary", 4),
  ]
  static var sunshineScreenModes: [String] {
    sunshineScreenModeOptions.map(\.title)
  }
  static let defaultSunshineTargetDisplayName = ""
  static let defaultSunshineUseVirtualDisplay = false
  static let defaultSunshineScreenMode = "Host Default"
  static let defaultSunshineHdrBrightnessOverride = false
  static let defaultSunshineMaxBrightness: CGFloat = 1000.0
  static let defaultSunshineMinBrightness: CGFloat = 0.001
  static let defaultSunshineMaxAverageBrightness: CGFloat = 1000.0
  static let defaultBitrateSliderValue = {
    var bitrateIndex = 0
    for i in 0..<SettingsModel.lockedBitrateSteps.count {
      if 10000.0 <= SettingsModel.lockedBitrateSteps[i] * 1000.0 {
        bitrateIndex = i
        break
      }
    }
    return Float(bitrateIndex)
  }()
  static let videoRendererModeOptions: [(title: String, value: Int)] = [
    ("Native Renderer (Recommended)", 2),
    ("Metal Renderer", 1),
    ("Compatibility Renderer", 3),
  ]
  static var videoRendererModes: [String] {
    videoRendererModeOptions.map(\.title)
  }
  static func videoRendererModeRawValue(for selection: String) -> Int {
    videoRendererModeOptions.first(where: { $0.title == selection })?.value
      ?? defaultVideoRendererModeRawValue
  }

  static func videoRendererModeSelection(for rawValue: Int?) -> String {
    guard let rawValue else { return defaultVideoRendererMode }
    if rawValue == 0 {
      return defaultVideoRendererMode
    }
    return videoRendererModeOptions.first(where: { $0.value == rawValue })?.title
      ?? defaultVideoRendererMode
  }

  static func normalizedVideoRendererMode(_ value: String?) -> String {
    guard let value else { return defaultVideoRendererMode }
    if let alias = videoRendererModesLegacyAliases[value] {
      return alias
    }
    return videoRendererModes.contains(value) ? value : defaultVideoRendererMode
  }

  static let presentStrategyOptions: [(title: String, value: Int)] = [
    ("Auto", 0),
    ("Lowest Latency", 1),
    ("Balanced", 2),
    ("Smoothest", 3),
  ]
  static var presentStrategies: [String] {
    presentStrategyOptions.map(\.title)
  }

  static let videoRendererModesLegacyAliases = [
    "Auto (Recommended)": "Native Renderer (Recommended)",
    "Enhanced": "Metal Renderer",
    "Native": "Native Renderer (Recommended)",
    "Native Renderer": "Native Renderer (Recommended)",
    "Compatibility": "Compatibility Renderer",
  ]
  static let defaultVideoCodec = "H.264"
  static let defaultVideoRendererMode = "Native Renderer (Recommended)"
  static let defaultVideoRendererModeRawValue = 2
  static let defaultHdr = false
  static let smoothnessLatencyLow = "Low Latency"
  static let smoothnessLatencyBalanced = "Balanced (Recommended)"
  static let smoothnessLatencySmooth = "Smoothness First"
  static let smoothnessLatencyCustom = "Custom"
  static var smoothnessLatencyModes: [String] = [
    smoothnessLatencyLow,
    smoothnessLatencyBalanced,
    smoothnessLatencySmooth,
    smoothnessLatencyCustom,
  ]
  static let timingBufferLow = "Low"
  static let timingBufferStandard = "Standard"
  static let timingBufferHigh = "High"
  static var timingBufferLevels: [String] = [
    timingBufferLow,
    timingBufferStandard,
    timingBufferHigh,
  ]
  static let defaultPacingOptions = "Smoothest Video"
  static let defaultSmoothnessLatencyMode = smoothnessLatencyBalanced
  static let defaultTimingBufferLevel = timingBufferStandard
  static let defaultTimingPrioritizeResponsiveness = false
  static let defaultTimingCompatibilityMode = false
  static let defaultTimingSdrCompatibilityWorkaround = false
  static let defaultHdrOpticalOutputScale: CGFloat = 100.0
  static let defaultAudioOnPC = false
  static let defaultAudioConfiguration = "Stereo"
  static let defaultAudioOutputMode = "Default"
  static let defaultEnhancedAudioOutputTarget = "Automatic"
  static let defaultEnhancedAudioPreset = "Reference"
  static let defaultEnhancedAudioEQLayout = "12-Band"
  static let defaultEnhancedAudioSpatialIntensity: CGFloat = 0.30
  static let defaultEnhancedAudioSoundstageWidth: CGFloat = 0.34
  static let defaultEnhancedAudioReverbAmount: CGFloat = 0.04
  static let defaultEnhancedAudioEQGains: [Double] = [
    0.0, -0.1, -0.2, -0.3, -0.1, 0.5, 1.4, 1.8, 1.6, 1.0, 0.6, 0.3,
  ]
  static let defaultEnableVsync = false
  static let defaultShowPerformanceOverlay = false
  static let defaultShowConnectionWarnings = true
  static let defaultCaptureSystemShortcuts = false
  static let defaultKeyboardCompatibilityMode = KeyboardCompatibilityMode.defaultMode.displayKey
  static let defaultVolumeLevel = 1.0
  static let defaultMultiControllerMode = "Auto"
  static let defaultSwapButtons = false
  static let defaultOptimize = false
  static var defaultDisplayMode: Int {
    let raw = UserDefaults.standard.object(forKey: "defaultDisplayMode") as? Int
    let fallback = UserDefaults.standard.bool(forKey: "autoFullscreen") ? 1 : 0
    let value = raw ?? fallback
    return max(0, min(value, 2))
  }

  static var defaultAutoFullscreen: Bool {
    if UserDefaults.standard.object(forKey: "defaultDisplayMode") != nil {
      return defaultDisplayMode == 1
    }
    return UserDefaults.standard.bool(forKey: "autoFullscreen")
  }
  static let defaultRumble = true
  static let defaultControllerDriver = "HID"
  static let defaultMouseDriver = MouseInputDriverStrategy.defaultStrategy.displayKey
  static let defaultCoreHIDMaxMouseReportRate = 1000
  static let defaultEmulateGuide = false
  static let defaultAppArtworkWidth: CGFloat? = nil
  static let defaultAppArtworkHeight: CGFloat? = nil
  static let defaultQuitAppAfterStream = false
  static let defaultAbsoluteMouseMode = false
  static let defaultSwapMouseButtons = false
  static let defaultReverseScrollDirection = false
  static let defaultPointerSensitivity: CGFloat = 1.0
  static let defaultWheelScrollSpeed: CGFloat = 1.0
  static let defaultRewrittenScrollSpeed: CGFloat = 1.0
  static let defaultGestureScrollSpeed: CGFloat = 1.0
  static let legacyDefaultPhysicalWheelHighPrecisionScale: CGFloat = 4.5
  static let defaultPhysicalWheelHighPrecisionScale: CGFloat = 7.0
  static let defaultSmartWheelTailFilter: CGFloat = 0.0
  static let defaultPhysicalWheelMode = PhysicalWheelScrollMode.defaultMode.displayKey
  static let defaultRewrittenScrollMode = RewrittenScrollMode.defaultMode.displayKey
  static let defaultFreeMouseMotionMode = FreeMouseMotionMode.defaultMode.displayKey
  static let defaultTouchscreenMode = 0
  static let defaultGamepadMouseMode = false
  static let defaultMouseMode = "remote"
  static let defaultUpscalingMode = 6
  static let defaultDimNonHoveredArtwork = true
  static let defaultUnlockMaxBitrate = false

  static let defaultAutoAdjustBitrate = true
  static let defaultEnableYUV444 = false
  static let defaultIgnoreAspectRatio = false
  static let defaultShowLocalCursor = false
  static let defaultEnableMicrophone = false
  static let defaultStreamResolutionScale = false
  static let defaultStreamResolutionScaleRatio = 100
  static let defaultDebugLogMode = "default"
  static let defaultDebugLogMinLevel = "info"
  static let defaultDebugLogShowSystemNoise = false
  static let defaultDebugLogAutoScroll = true
  static let defaultDebugLogTimeScope = "launch"
  static let defaultDebugLogInputDiagnostics = false
  static let defaultAwdlStabilityHelperEnabled = false
  static let defaultAwdlStabilityHelperAcknowledged = false

  static func coreHIDMaxMouseReportRateLabel(_ value: Int) -> String {
    if value == 0 {
      return LanguageManager.shared.localize("Unlimited (Advanced)")
    }
    if value == defaultCoreHIDMaxMouseReportRate {
      return "\(value) Hz · \(LanguageManager.shared.localize("Recommended"))"
    }
    return "\(value) Hz"
  }

  static func percentageLabel(for value: CGFloat) -> String {
    "\(Int((value * 100).rounded()))%"
  }

  static func enhancedAudioEQFrequencies(for layout: String) -> [Double] {
    switch layout {
    case "24-Band":
      return enhancedAudioEQFrequencies24Band
    case "12-Band":
      return enhancedAudioEQFrequencies12Band
    default:
      return enhancedAudioEQFrequencies12Band
    }
  }

  static func normalizedEnhancedAudioEQLayout(_ value: String?) -> String {
    guard let value, enhancedAudioEQLayouts.contains(value) else {
      return defaultEnhancedAudioEQLayout
    }
    return value
  }

  static func sunshineScreenModeRawValue(for selection: String) -> Int {
    sunshineScreenModeOptions.first(where: { $0.title == selection })?.value ?? -1
  }

  static func sunshineScreenModeSelection(for rawValue: Int?) -> String {
    guard let rawValue else { return defaultSunshineScreenMode }
    return sunshineScreenModeOptions.first(where: { $0.value == rawValue })?.title
      ?? defaultSunshineScreenMode
  }

  static func sanitizedEnhancedAudioEQGains(_ gains: [Double]?, layout: String) -> [Double] {
    let targetLayout = normalizedEnhancedAudioEQLayout(layout)
    let targetFrequencies = enhancedAudioEQFrequencies(for: targetLayout)
    guard let gains, !gains.isEmpty else {
      return defaultEnhancedAudioEQGainsForLayout(targetLayout)
    }

    let sourceLayout: String
    switch gains.count {
    case enhancedAudioEQFrequencies24Band.count:
      sourceLayout = "24-Band"
    case enhancedAudioEQFrequencies12Band.count:
      sourceLayout = "12-Band"
    case legacyEnhancedAudioEQAnchorFrequencies.count:
      sourceLayout = "Legacy"
    default:
      sourceLayout = targetLayout
    }

    let sourceFrequencies: [Double]
    switch sourceLayout {
    case "24-Band":
      sourceFrequencies = enhancedAudioEQFrequencies24Band
    case "12-Band":
      sourceFrequencies = enhancedAudioEQFrequencies12Band
    case "Legacy":
      sourceFrequencies = legacyEnhancedAudioEQAnchorFrequencies
    default:
      sourceFrequencies = targetFrequencies
    }

    let clampedGains = gains.map { min(max($0, -12.0), 12.0) }
    if sourceFrequencies.count == targetFrequencies.count && clampedGains.count == targetFrequencies.count {
      return clampedGains
    }

    return interpolatedEQGains(
      from: sourceFrequencies,
      gains: clampedGains,
      to: targetFrequencies)
  }

  static func remappedEnhancedAudioEQGains(
    _ gains: [Double],
    from sourceLayout: String,
    to targetLayout: String
  ) -> [Double] {
    let sourceFrequencies = enhancedAudioEQFrequencies(for: normalizedEnhancedAudioEQLayout(sourceLayout))
    let targetFrequencies = enhancedAudioEQFrequencies(for: normalizedEnhancedAudioEQLayout(targetLayout))
    if sourceFrequencies.count == targetFrequencies.count, gains.count == targetFrequencies.count {
      return gains
    }
    return interpolatedEQGains(from: sourceFrequencies, gains: gains, to: targetFrequencies)
  }

  private static func defaultEnhancedAudioEQGainsForLayout(_ layout: String) -> [Double] {
    interpolatedEQGains(
      from: enhancedAudioEQFrequencies12Band,
      gains: defaultEnhancedAudioEQGains,
      to: enhancedAudioEQFrequencies(for: layout))
  }

  private static func interpolatedEQGains(
    from sourceFrequencies: [Double],
    gains sourceGains: [Double],
    to targetFrequencies: [Double]
  ) -> [Double] {
    guard !sourceFrequencies.isEmpty, sourceFrequencies.count == sourceGains.count else {
      return Array(repeating: 0.0, count: targetFrequencies.count)
    }

    func logFrequency(_ frequency: Double) -> Double {
      log(max(frequency, 1.0))
    }

    return targetFrequencies.map { target in
      let targetLog = logFrequency(target)
      if target <= sourceFrequencies.first ?? target {
        return sourceGains.first ?? 0.0
      }
      if target >= sourceFrequencies.last ?? target {
        return sourceGains.last ?? 0.0
      }

      for index in 1..<sourceFrequencies.count {
        let lowerFrequency = sourceFrequencies[index - 1]
        let upperFrequency = sourceFrequencies[index]
        if target <= upperFrequency {
          let lowerLog = logFrequency(lowerFrequency)
          let upperLog = logFrequency(upperFrequency)
          let progress = upperLog == lowerLog ? 0.0 : (targetLog - lowerLog) / (upperLog - lowerLog)
          let lowerGain = sourceGains[index - 1]
          let upperGain = sourceGains[index]
          return lowerGain + ((upperGain - lowerGain) * progress)
        }
      }

      return sourceGains.last ?? 0.0
    }.map { min(max($0, -12.0), 12.0) }
  }

  private static func mainDisplayPixelSize() -> CGSize? {
    guard let screen = NSScreen.main,
      let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
        as? NSNumber
    else {
      return nil
    }

    let displayID = CGDirectDisplayID(screenNumber.uint32Value)
    guard let mode = CGDisplayCopyDisplayMode(displayID) else { return nil }

    func even(_ v: CGFloat) -> CGFloat {
      let i = Int(v)
      return CGFloat(i - (i % 2))
    }

    return CGSize(width: even(CGFloat(mode.pixelWidth)), height: even(CGFloat(mode.pixelHeight)))
  }

  // Copied from moonlight-qt (StreamingPreferences::getDefaultBitrate)
  static func getDefaultBitrateKbps(width: Int, height: Int, fps: Int, yuv444: Bool) -> Int {
    let fpsf = Float(max(1, fps))
    let frameRateFactor: Float = ((fps <= 60 ? fpsf : (sqrtf(fpsf / 60.0) * 60.0)) / 30.0)

    struct ResEntry {
      let pixels: Int
      let factor: Float
    }

    let table: [ResEntry] = [
      .init(pixels: 640 * 360, factor: 1),
      .init(pixels: 854 * 480, factor: 2),
      .init(pixels: 1280 * 720, factor: 5),
      .init(pixels: 1920 * 1080, factor: 10),
      .init(pixels: 2560 * 1440, factor: 20),
      .init(pixels: 3840 * 2160, factor: 40),
    ]

    let pixels = max(1, width * height)
    var resolutionFactor: Float = table.first?.factor ?? 10

    for i in 0..<table.count {
      if pixels == table[i].pixels {
        resolutionFactor = table[i].factor
        break
      } else if pixels < table[i].pixels {
        if i == 0 {
          resolutionFactor = table[i].factor
        } else {
          let lo = table[i - 1]
          let hi = table[i]
          let t = Float(pixels - lo.pixels) / Float(hi.pixels - lo.pixels)
          resolutionFactor = t * (hi.factor - lo.factor) + lo.factor
        }
        break
      } else if i == table.count - 1 {
        resolutionFactor = table[i].factor
      }
    }

    if yuv444 {
      resolutionFactor *= 2
    }

    return Int(roundf(resolutionFactor * frameRateFactor)) * 1000
  }

  func effectiveResolutionForBitrate() -> CGSize {
    if selectedResolution == Self.matchDisplayResolutionSentinel {
      return Self.mainDisplayPixelSize() ?? Self.defaultResolution
    }

    if selectedResolution == .zero {
      if let w = customResWidth, let h = customResHeight, w > 0, h > 0 {
        return CGSize(width: w, height: h)
      }
      return Self.defaultResolution
    }

    return selectedResolution
  }

  func effectiveFpsForBitrate() -> Int {
    if selectedFps == .zero {
      if let customFps, customFps > 0 {
        return Int(customFps)
      }
      return Self.defaultFps
    }
    return selectedFps
  }

  func applyAutoBitrateIfNeeded(force: Bool = false) {
    guard autoAdjustBitrate else { return }
    guard force || !isAdjustingBitrate else { return }

    let res = effectiveResolutionForBitrate()
    let fps = effectiveFpsForBitrate()
    let kbps = Self.getDefaultBitrateKbps(
      width: Int(res.width), height: Int(res.height), fps: fps, yuv444: enableYUV444)

    let steps = Self.bitrateSteps(unlocked: unlockMaxBitrate)
    var bitrateIndex = 0
    for i in 0..<steps.count {
      if Float(kbps) <= steps[i] * 1000.0 {
        bitrateIndex = i
        break
      }
    }

    isAdjustingBitrate = true
    customBitrate = kbps
    bitrateSliderValue = Float(bitrateIndex)
    isAdjustingBitrate = false
  }

  static func derivedSmoothnessLatencyMode(
    framePacing: Int,
    enableVsync: Bool?,
    timingBufferLevel: Int?,
    timingPrioritizeResponsiveness: Bool?,
    timingCompatibilityMode: Bool?,
    timingSdrCompatibilityWorkaround: Bool?
  ) -> Int {
    let pacing = getString(from: framePacing, in: pacingOptions)
    let vsyncEnabled = enableVsync ?? defaultEnableVsync
    let bufferLevel = getString(
      from: timingBufferLevel ?? getInt(from: defaultTimingBufferLevel, in: timingBufferLevels),
      in: timingBufferLevels)
    let prioritizeResponsiveness =
      timingPrioritizeResponsiveness ?? defaultTimingPrioritizeResponsiveness
    let compatibilityMode = timingCompatibilityMode ?? defaultTimingCompatibilityMode
    let sdrCompatibilityWorkaround =
      timingSdrCompatibilityWorkaround ?? defaultTimingSdrCompatibilityWorkaround

    if pacing == pacingOptions.first,
      !vsyncEnabled,
      bufferLevel == timingBufferLow,
      prioritizeResponsiveness,
      !compatibilityMode,
      !sdrCompatibilityWorkaround
    {
      return getInt(from: smoothnessLatencyLow, in: smoothnessLatencyModes)
    }

    if pacing == defaultPacingOptions,
      !vsyncEnabled,
      bufferLevel == timingBufferStandard,
      !prioritizeResponsiveness,
      !compatibilityMode,
      !sdrCompatibilityWorkaround
    {
      return getInt(from: smoothnessLatencyBalanced, in: smoothnessLatencyModes)
    }

    if pacing == defaultPacingOptions,
      vsyncEnabled,
      bufferLevel == timingBufferHigh,
      !prioritizeResponsiveness,
      !compatibilityMode,
      !sdrCompatibilityWorkaround
    {
      return getInt(from: smoothnessLatencySmooth, in: smoothnessLatencyModes)
    }

    return getInt(from: smoothnessLatencyCustom, in: smoothnessLatencyModes)
  }

  func syncSmoothnessLatencyModeFromTimingDetails() {
    let derivedMode = Self.getString(
      from: Self.derivedSmoothnessLatencyMode(
        framePacing: Self.getInt(from: selectedPacingOptions, in: Self.pacingOptions),
        enableVsync: enableVsync,
        timingBufferLevel: Self.getInt(from: selectedTimingBufferLevel, in: Self.timingBufferLevels),
        timingPrioritizeResponsiveness: timingPrioritizeResponsiveness,
        timingCompatibilityMode: timingCompatibilityMode,
        timingSdrCompatibilityWorkaround: timingSdrCompatibilityWorkaround
      ),
      in: Self.smoothnessLatencyModes
    )

    guard selectedSmoothnessLatencyMode != derivedMode else { return }

    isSyncingSmoothnessLatencyMode = true
    selectedSmoothnessLatencyMode = derivedMode
    isSyncingSmoothnessLatencyMode = false
  }

  func applySmoothnessLatencyPresetIfNeeded() {
    guard selectedSmoothnessLatencyMode != Self.smoothnessLatencyCustom else { return }

    isApplyingSmoothnessLatencyPreset = true
    defer { isApplyingSmoothnessLatencyPreset = false }

    switch selectedSmoothnessLatencyMode {
    case Self.smoothnessLatencyLow:
      selectedPacingOptions = Self.pacingOptions.first ?? Self.defaultPacingOptions
      enableVsync = false
      selectedTimingBufferLevel = Self.timingBufferLow
      timingPrioritizeResponsiveness = true
      timingCompatibilityMode = false
      timingSdrCompatibilityWorkaround = false
    case Self.smoothnessLatencyBalanced:
      selectedPacingOptions = Self.defaultPacingOptions
      enableVsync = false
      selectedTimingBufferLevel = Self.timingBufferStandard
      timingPrioritizeResponsiveness = false
      timingCompatibilityMode = false
      timingSdrCompatibilityWorkaround = false
    case Self.smoothnessLatencySmooth:
      selectedPacingOptions = Self.defaultPacingOptions
      enableVsync = true
      selectedTimingBufferLevel = Self.timingBufferHigh
      timingPrioritizeResponsiveness = false
      timingCompatibilityMode = false
      timingSdrCompatibilityWorkaround = false
    default:
      break
    }
  }

  static func normalizedDebugLogMode(_ value: String?) -> String {
    guard let value else { return defaultDebugLogMode }
    let normalized = value.lowercased()
    switch normalized {
    case "raw":
      return "raw"
    case "curated", "default":
      return "default"
    default:
      return defaultDebugLogMode
    }
  }

  static func normalizedDebugLogMinLevel(_ value: String?) -> String {
    guard let value else { return defaultDebugLogMinLevel }
    switch value.lowercased() {
    case "all", "debug", "info", "warn", "error":
      return value.lowercased()
    default:
      return defaultDebugLogMinLevel
    }
  }

  static func normalizedDebugLogTimeScope(_ value: String?) -> String {
    guard let value else { return defaultDebugLogTimeScope }
    switch value.lowercased() {
    case "all", "launch", "since_clear":
      return value.lowercased()
    default:
      return defaultDebugLogTimeScope
    }
  }

  static func loggerLevel(from stringValue: String) -> LogLevel {
    switch stringValue {
    case "all", "debug":
      return LOG_D
    case "warn":
      return LOG_W
    case "error":
      return LOG_E
    default:
      return LOG_I
    }
  }

  static func getInt(from selectedSetting: String, in settingsArray: [String]) -> Int {
    for (index, setting) in settingsArray.enumerated() {
      if setting == selectedSetting {
        return index
      }
    }

    return 0
  }

  static func getString(from settingInt: Int, in settingsArray: [String]) -> String {
    var settingString = settingsArray.first!
    for (index, setting) in settingsArray.enumerated() {
      if index == settingInt {
        settingString = setting
      }
    }

    return settingString
  }

  static func getBool(from settingInt: Int, in settingsArray: [String]) -> Bool {
    guard settingsArray.count == 2 || settingInt <= 1 else {
      return false
    }

    var settingBool = false
    for (index, _) in settingsArray.enumerated() {
      if index == settingInt {
        settingBool = index == 1
      }
    }

    return settingBool
  }

  static func getBool(from selectedSetting: String, in settingsArray: [String]) -> Bool {
    selectedSetting == settingsArray.last
  }

  static func getString(from settingBool: Bool, in settingsArray: [String]) -> String {
    var settingString = settingsArray.first!
    for (index, setting) in settingsArray.enumerated() {
      let indexBool = index == 1
      if indexBool == settingBool {
        settingString = setting
      }
    }

    return settingString
  }

  static func enhancedAudioPresetValues(
    for preset: String,
    layout: String
  ) -> (spatialIntensity: CGFloat, soundstageWidth: CGFloat, reverbAmount: CGFloat, eqGains: [Double]) {
    let targetFrequencies = enhancedAudioEQFrequencies(for: normalizedEnhancedAudioEQLayout(layout))

    func gains(_ legacyAnchors: [Double]) -> [Double] {
      interpolatedEQGains(
        from: legacyEnhancedAudioEQAnchorFrequencies,
        gains: legacyAnchors,
        to: targetFrequencies)
    }

    switch preset {
    case "Immersive Gaming":
      return (
        0.64,
        0.68,
        0.12,
        gains([1.2, 0.9, 0.5, 0.0, -0.1, 0.3, 1.2, 1.9, 1.5, 0.5])
      )
    case "Dialogue Clarity":
      return (
        0.22,
        0.26,
        0.02,
        gains([-1.0, -0.7, -0.2, 0.2, 0.9, 2.0, 2.8, 2.6, 1.3, 0.2])
      )
    case "Bass Boost":
      return (
        0.32,
        0.34,
        0.05,
        gains([2.4, 2.0, 1.2, 0.5, 0.0, -0.1, 0.2, 0.0, -0.2, -0.2])
      )
    case "Harman Inspired":
      return (
        0.18,
        0.24,
        0.01,
        gains([2.8, 2.2, 1.5, 0.8, 0.1, 0.2, 0.8, 1.5, 1.1, 0.4])
      )
    case "Music Warmth":
      return (
        0.16,
        0.20,
        0.01,
        gains([1.8, 1.4, 0.9, 0.5, 0.1, 0.0, 0.3, 0.6, 0.2, -0.2])
      )
    case "Vocal Presence":
      return (
        0.18,
        0.24,
        0.01,
        gains([-1.2, -0.8, -0.2, 0.2, 0.9, 2.0, 2.4, 1.8, 0.9, 0.1])
      )
    case "Air & Detail":
      return (
        0.24,
        0.30,
        0.02,
        gains([-0.8, -0.6, -0.2, 0.0, 0.2, 0.7, 1.5, 2.2, 2.0, 1.0])
      )
    default:
      return (
        defaultEnhancedAudioSpatialIntensity,
        defaultEnhancedAudioSoundstageWidth,
        defaultEnhancedAudioReverbAmount,
        defaultEnhancedAudioEQGainsForLayout(layout)
      )
    }
  }

  static func enhancedAudioPresetDescription(for preset: String) -> String {
    switch preset {
    case "Immersive Gaming":
      return "Wider positional cues with a little extra ambience for games."
    case "Dialogue Clarity":
      return "Pushes voices and lead detail forward while trimming boominess."
    case "Bass Boost":
      return "Adds fuller low end for music and cinematic impact without going too muddy."
    case "Harman Inspired":
      return "A tasteful bass shelf and upper-mid lift inspired by popular headphone targets."
    case "Music Warmth":
      return "Smoother low mids and gentler highs for relaxed long-session listening."
    case "Vocal Presence":
      return "Lifts vocals and lead instruments for clearer mids and cleaner focus."
    case "Air & Detail":
      return "Opens up treble sparkle and perceived detail with a lighter low end."
    default:
      return "Closest to the stream itself with only light tonal shaping."
    }
  }

  static var av1HardwareDecodeSupported: Bool {
    VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
  }
}
