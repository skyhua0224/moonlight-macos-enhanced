//
//  SettingsModel.swift
//  Moonlight SwiftUI
//
//  Created by Michael Kenny on 25/1/2023.
//  Copyright © 2023 Moonlight Game Streaming Project. All rights reserved.
//

import AppKit
import CoreGraphics
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
  case notched = 0
  case highPrecision = 1

  static let defaultMode: Self = .notched

  init(persistedRawValue: Int?) {
    switch persistedRawValue {
    case PhysicalWheelScrollMode.highPrecision.rawValue:
      self = .highPrecision
    default:
      self = .notched
    }
  }

  init(selection: String) {
    self = Self.allCases.first(where: { $0.displayKey == selection }) ?? Self.defaultMode
  }

  var displayKey: String {
    switch self {
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
  static var audioConfigurations: [String] = ["Stereo", "5.1 surround sound", "7.1 surround sound"]
  static var multiControllerModes: [String] = ["Single", "Auto"]

  static var controllerDrivers: [String] = ["HID", "MFi"]
  static var mouseDrivers: [String] = MouseInputDriverStrategy.displayKeys
  static var physicalWheelModes: [String] = PhysicalWheelScrollMode.displayKeys
  static var rewrittenScrollModes: [String] = RewrittenScrollMode.displayKeys
  static var freeMouseMotionModes: [String] = FreeMouseMotionMode.displayKeys
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

  private static let allUpscalingModes: [String] = [
    "Off", "MetalFX Spatial (Quality)", "MetalFX Spatial (Performance)",
  ]

  static var upscalingModes: [String] {
    isMetalFXSupported ? allUpscalingModes : ["Off"]
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
  static let defaultVideoCodec = "H.264"
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
  static let defaultAudioOnPC = false
  static let defaultAudioConfiguration = "Stereo"
  static let defaultEnableVsync = false
  static let defaultShowPerformanceOverlay = false
  static let defaultShowConnectionWarnings = true
  static let defaultCaptureSystemShortcuts = false
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
  static let defaultUpscalingMode = 0
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

  static var av1HardwareDecodeSupported: Bool {
    VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
  }
}
