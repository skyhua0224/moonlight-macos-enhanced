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

struct Host: Identifiable, Hashable {
  let id: String
  let name: String
}

struct ConnectionCandidate: Identifiable {
  let id: String
  let label: String
  let state: Int
}

class SettingsModel: ObservableObject {
  static let globalHostId = "__global__"
  static let matchDisplayResolutionSentinel = CGSize(width: -1, height: -1)
  static let debugLogModeKey = "debugLog.mode"
  static let debugLogMinLevelKey = "debugLog.minLevel"
  static let debugLogShowSystemNoiseKey = "debugLog.showSystemNoise"
  static let debugLogAutoScrollKey = "debugLog.autoScroll"
  static let debugLogTimeScopeKey = "debugLog.timeScope"
  static let debugLogInputDiagnosticsKey = "debugLog.inputDiagnostics"
  static let awdlStabilityHelperEnabledKey = "networkCompatibility.awdlHelperEnabled"
  static let awdlStabilityHelperAcknowledgedKey = "networkCompatibility.awdlHelperAcknowledged"

  private var latencyCache: [String: [String: Any]] = [:]
  private var selectedProfileObserver: NSObjectProtocol?

  // Remote host display mode override (affects /launch mode parameter)
  static var remoteResolutions: [CGSize] = [
    CGSizeMake(1280, 720), CGSizeMake(1920, 1080), CGSizeMake(2560, 1440), CGSizeMake(3840, 2160),
    .zero,
  ]

  static var hosts: [Host?]? {
    let global = Host(id: globalHostId, name: "Global")

    let dataMan = DataManager()
    dataMan.removeHostsWithEmptyUuid()
    if let tempHosts = dataMan.getHosts() as? [TemporaryHost] {
      let hosts = tempHosts
        .filter { !$0.uuid.isEmpty }
        .sorted { lhs, rhs in
          lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
        .map { host in
          Host(id: host.uuid, name: host.displayName)
      }

      return [global] + hosts
    }

    return [global]
  }

  @Published var selectedHost: Host? {
    didSet {
      guard !isLoading else { return }
      UserDefaults.standard.set(selectedHost?.id, forKey: "selectedSettingsProfile")
      loadSettings()
    }
  }

  @Published var debugLogMode: String {
    didSet {
      UserDefaults.standard.set(debugLogMode, forKey: Self.debugLogModeKey)
      LoggerSetCuratedModeEnabled(debugLogMode != "raw")
    }
  }
  @Published var debugLogMinLevel: String {
    didSet {
      UserDefaults.standard.set(debugLogMinLevel, forKey: Self.debugLogMinLevelKey)
      LoggerSetMinimumLevel(Self.loggerLevel(from: debugLogMinLevel))
    }
  }
  @Published var debugLogShowSystemNoise: Bool {
    didSet {
      UserDefaults.standard.set(debugLogShowSystemNoise, forKey: Self.debugLogShowSystemNoiseKey)
    }
  }
  @Published var debugLogAutoScroll: Bool {
    didSet {
      UserDefaults.standard.set(debugLogAutoScroll, forKey: Self.debugLogAutoScrollKey)
    }
  }
  @Published var debugLogTimeScope: String {
    didSet {
      UserDefaults.standard.set(debugLogTimeScope, forKey: Self.debugLogTimeScopeKey)
    }
  }
  @Published var debugLogInputDiagnostics: Bool {
    didSet {
      UserDefaults.standard.set(debugLogInputDiagnostics, forKey: Self.debugLogInputDiagnosticsKey)
    }
  }
  @Published var awdlStabilityHelperEnabled: Bool {
    didSet {
      UserDefaults.standard.set(
        awdlStabilityHelperEnabled, forKey: Self.awdlStabilityHelperEnabledKey)
    }
  }
  @Published var awdlStabilityHelperAcknowledged: Bool {
    didSet {
      UserDefaults.standard.set(
        awdlStabilityHelperAcknowledged, forKey: Self.awdlStabilityHelperAcknowledgedKey)
    }
  }

  func selectHost(id: String?) {
    if let id {
      if let host = Self.hosts?.compactMap({ $0 }).first(where: { $0.id == id }) {
        selectedHost = host
      }
    } else {
      if let host = Self.hosts?.compactMap({ $0 }).first(where: { $0.id == Self.globalHostId }) {
        selectedHost = host
      }
    }
  }

  private var isLoading = false
  private var isAdjustingBitrate = false
  private var isApplyingSmoothnessLatencyPreset = false
  private var isSyncingSmoothnessLatencyMode = false

  var resolutionChangedCallback: (() -> Void)?
  var fpsChangedCallback: (() -> Void)?

  @Published var selectedResolution: CGSize {
    didSet {
      guard !isLoading else { return }
      applyAutoBitrateIfNeeded()
      saveSettings()
      resolutionChangedCallback?()
    }
  }
  @Published var selectedFps: Int {
    didSet {
      guard !isLoading else { return }
      applyAutoBitrateIfNeeded()
      saveSettings()
      fpsChangedCallback?()
    }
  }

  // Remote host overrides (enabled only when toggled)
  @Published var remoteResolutionEnabled: Bool {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var selectedRemoteResolution: CGSize {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var remoteCustomResWidth: CGFloat? {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var remoteCustomResHeight: CGFloat? {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var remoteFpsEnabled: Bool {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var selectedRemoteFps: Int {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var remoteCustomFps: CGFloat? {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var customFps: CGFloat? {
    didSet {
      guard !isLoading else { return }
      applyAutoBitrateIfNeeded()
      saveSettings()
    }
  }
  @Published var customResWidth: CGFloat? {
    didSet {
      guard !isLoading else { return }
      applyAutoBitrateIfNeeded()
      saveSettings()
    }
  }
  @Published var customResHeight: CGFloat? {
    didSet {
      guard !isLoading else { return }
      applyAutoBitrateIfNeeded()
      saveSettings()
    }
  }

  // moonlight-qt parity (P0)
  @Published var autoAdjustBitrate: Bool {
    didSet {
      guard !isLoading else { return }
      applyAutoBitrateIfNeeded(force: true)
      saveSettings()
    }
  }

  @Published var enableYUV444: Bool {
    didSet {
      guard !isLoading else { return }
      applyAutoBitrateIfNeeded(force: true)
      saveSettings()
    }
  }

  @Published var ignoreAspectRatio: Bool {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }

  @Published var showLocalCursor: Bool {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }

  @Published var enableMicrophone: Bool {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }

  @Published var streamResolutionScale: Bool {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }

  @Published var streamResolutionScaleRatio: Int {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var bitrateSliderValue: Float {
    didSet {
      guard !isLoading else { return }
      let steps = Self.bitrateSteps(unlocked: unlockMaxBitrate)
      let index = max(0, min(Int(bitrateSliderValue), steps.count - 1))
      let kbps = Int(steps[index] * 1000.0)

      if !isAdjustingBitrate {
        isAdjustingBitrate = true
        customBitrate = kbps
        isAdjustingBitrate = false
      }

      saveSettings()
    }
  }
  @Published var customBitrate: Int? {
    didSet {
      guard !isLoading else { return }
      guard !isAdjustingBitrate else {
        saveSettings()
        return
      }

      // Keep slider roughly in sync with typed value
      if let customBitrate {
        let steps = Self.bitrateSteps(unlocked: unlockMaxBitrate)
        var bitrateIndex = 0
        for i in 0..<steps.count {
          if Float(customBitrate) <= steps[i] * 1000.0 {
            bitrateIndex = i
            break
          }
        }
        isAdjustingBitrate = true
        bitrateSliderValue = Float(bitrateIndex)
        isAdjustingBitrate = false
      }

      saveSettings()
    }
  }

  @Published var unlockMaxBitrate: Bool {
    didSet {
      guard !isLoading else { return }
      // Clamp slider to new range
      let steps = Self.bitrateSteps(unlocked: unlockMaxBitrate)
      let maxIndex = Float(max(0, steps.count - 1))
      if bitrateSliderValue > maxIndex {
        bitrateSliderValue = maxIndex
      }

      // Recompute bitrate value from slider under new scale
      let index = max(0, min(Int(bitrateSliderValue), steps.count - 1))
      let kbps = Int(steps[index] * 1000.0)
      isAdjustingBitrate = true
      customBitrate = kbps
      isAdjustingBitrate = false

      saveSettings()
    }
  }
  @Published var selectedVideoCodec: String {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var hdr: Bool {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var selectedPacingOptions: String {
    didSet {
      guard !isLoading, !isApplyingSmoothnessLatencyPreset else { return }
      syncSmoothnessLatencyModeFromTimingDetails()
      saveSettings()
    }
  }
  @Published var selectedSmoothnessLatencyMode: String {
    didSet {
      guard !isLoading, !isSyncingSmoothnessLatencyMode else { return }
      applySmoothnessLatencyPresetIfNeeded()
      saveSettings()
    }
  }
  @Published var audioOnPC: Bool {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var selectedAudioConfiguration: String {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var enableVsync: Bool {
    didSet {
      guard !isLoading, !isApplyingSmoothnessLatencyPreset else { return }
      if selectedSmoothnessLatencyMode == Self.smoothnessLatencyCustom {
        saveSettings()
        return
      }
      syncSmoothnessLatencyModeFromTimingDetails()
      saveSettings()
    }
  }
  @Published var selectedTimingBufferLevel: String {
    didSet {
      guard !isLoading, !isApplyingSmoothnessLatencyPreset else { return }
      if selectedSmoothnessLatencyMode == Self.smoothnessLatencyCustom {
        saveSettings()
        return
      }
      syncSmoothnessLatencyModeFromTimingDetails()
      saveSettings()
    }
  }
  @Published var timingPrioritizeResponsiveness: Bool {
    didSet {
      guard !isLoading, !isApplyingSmoothnessLatencyPreset else { return }
      if selectedSmoothnessLatencyMode == Self.smoothnessLatencyCustom {
        saveSettings()
        return
      }
      syncSmoothnessLatencyModeFromTimingDetails()
      saveSettings()
    }
  }
  @Published var timingCompatibilityMode: Bool {
    didSet {
      guard !isLoading, !isApplyingSmoothnessLatencyPreset else { return }
      if selectedSmoothnessLatencyMode == Self.smoothnessLatencyCustom {
        saveSettings()
        return
      }
      syncSmoothnessLatencyModeFromTimingDetails()
      saveSettings()
    }
  }
  @Published var timingSdrCompatibilityWorkaround: Bool {
    didSet {
      guard !isLoading, !isApplyingSmoothnessLatencyPreset else { return }
      if selectedSmoothnessLatencyMode == Self.smoothnessLatencyCustom {
        saveSettings()
        return
      }
      syncSmoothnessLatencyModeFromTimingDetails()
      saveSettings()
    }
  }
  @Published var showPerformanceOverlay: Bool {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var showConnectionWarnings: Bool {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var captureSystemShortcuts: Bool {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var volumeLevel: CGFloat {
    didSet {
      guard !isLoading else { return }
      saveSettings()
      NotificationCenter.default.post(name: Notification.Name("volumeSettingChanged"), object: nil)
    }
  }
  @Published var selectedMultiControllerMode: String {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var swapButtons: Bool {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var optimize: Bool {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }

  @Published var autoFullscreen: Bool {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var selectedDisplayMode: String {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var rumble: Bool {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var selectedControllerDriver: String {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var selectedMouseDriver: String {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }

  @Published var emulateGuide: Bool {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var appArtworkWidth: CGFloat? {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var appArtworkHeight: CGFloat? {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var dimNonHoveredArtwork: Bool {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }

  // Host Settings
  @Published var quitAppAfterStream: Bool {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }

  // Input Settings
  @Published var absoluteMouseMode: Bool {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var swapMouseButtons: Bool {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var reverseScrollDirection: Bool {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var pointerSensitivity: CGFloat {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var coreHIDMaxMouseReportRate: Int {
    didSet {
      let normalized = Self.normalizedCoreHIDMaxMouseReportRate(coreHIDMaxMouseReportRate)
      if coreHIDMaxMouseReportRate != normalized {
        coreHIDMaxMouseReportRate = normalized
        return
      }
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var streamShortcuts: [String: StreamShortcut] {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var selectedTouchscreenMode: String {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var gamepadMouseMode: Bool {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var mouseMode: String {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var selectedUpscalingMode: String {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var selectedConnectionMethod: String {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }

  var connectionCandidates: [ConnectionCandidate] {
    var candidates: [ConnectionCandidate] = []
    candidates.append(ConnectionCandidate(id: "Auto", label: LanguageManager.shared.localize("Auto (Recommended)"), state: 1))

    guard let hostId = selectedHost?.id, hostId != Self.globalHostId else {
      return candidates
    }

    let dataMan = DataManager()
    if let hosts = dataMan.getHosts() as? [TemporaryHost],
      let host = hosts.first(where: { !$0.uuid.isEmpty && $0.uuid == hostId })
    {
      var latencies: [String: NSNumber] = [:]
      var states: [String: NSNumber] = [:]

      if let cached = latencyCache[hostId] {
        latencies = cached["latencies"] as? [String: NSNumber] ?? [:]
        states = cached["states"] as? [String: NSNumber] ?? [:]
      } else {
        latencies = host.addressLatencies ?? [:]
        states = host.addressStates ?? [:]
      }

      let endpoints = ConnectionEndpointStore.allEndpoints(for: host)
      for addr in endpoints {
        let stateVal = states[addr]?.intValue
        let latency = latencies[addr]?.intValue ?? -1

        let effectiveState: Int
        if let stateVal {
          effectiveState = stateVal
        } else if latency >= 0 {
          effectiveState = 1
        } else {
          effectiveState = -1
        }

        var label = addr
        if effectiveState == 1 {
          if latency >= 0 {
            label += " (\(max(1, latency))ms)"
          } else {
            label += " (\(LanguageManager.shared.localize("Online")))"
          }
        } else if effectiveState == 0 {
          label += " (\(LanguageManager.shared.localize("Offline")))"
        } else {
          label += " (\(LanguageManager.shared.localize("Unknown")))"
        }

        candidates.append(ConnectionCandidate(id: addr, label: label, state: effectiveState))
      }
    }
    return candidates
  }

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

  private func ensureConnectionMethodValid() {
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
    // Extended steps up to 1000 Mbps (avoid too many slider ticks)
    return lockedBitrateSteps + [200, 250, 300, 350, 400, 500, 600, 800, 1000]
  }

  static let coreHIDMaxMouseReportRateLimit = 8000
  static let coreHIDMaxMouseReportRateStep = 100

  static func normalizedCoreHIDMaxMouseReportRate(_ value: Int) -> Int {
    let clamped = max(0, min(value, coreHIDMaxMouseReportRateLimit))
    if clamped == 0 {
      return 0
    }
    let roundedStep = Int(
      (Double(clamped) / Double(coreHIDMaxMouseReportRateStep)).rounded()
    ) * coreHIDMaxMouseReportRateStep
    return max(coreHIDMaxMouseReportRateStep, min(roundedStep, coreHIDMaxMouseReportRateLimit))
  }

  static var videoCodecs: [String] = ["H.264", "H.265", "AV1"]
  static var pacingOptions: [String] = ["Lowest Latency", "Smoothest Video"]
  static var audioConfigurations: [String] = ["Stereo", "5.1 surround sound", "7.1 surround sound"]
  static var multiControllerModes: [String] = ["Single", "Auto"]

  static var controllerDrivers: [String] = ["HID", "MFi"]
  static var mouseDrivers: [String] = ["HID", "MFi", "CoreHID"]
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
    // Keep compatibility with the historical autoFullscreen key.
    if UserDefaults.standard.object(forKey: "defaultDisplayMode") != nil {
      return defaultDisplayMode == 1
    }
    return UserDefaults.standard.bool(forKey: "autoFullscreen")
  }
  static let defaultRumble = true
  static let defaultControllerDriver = "HID"
  static let defaultMouseDriver = "HID"
  static let defaultEmulateGuide = false
  static let defaultAppArtworkWidth: CGFloat? = nil
  static let defaultAppArtworkHeight: CGFloat? = nil
  static let defaultQuitAppAfterStream = false
  static let defaultAbsoluteMouseMode = false
  static let defaultSwapMouseButtons = false
  static let defaultReverseScrollDirection = false
  static let defaultPointerSensitivity: CGFloat = 1.0
  static let defaultCoreHIDMaxMouseReportRate = 0
  static let defaultTouchscreenMode = 0  // Trackpad
  static let defaultGamepadMouseMode = false
  static let defaultMouseMode = "remote"
  static let defaultUpscalingMode = 0
  static let defaultDimNonHoveredArtwork = true
  static let defaultUnlockMaxBitrate = false

  // moonlight-qt defaults (tuned for macOS)
  static let defaultAutoAdjustBitrate = true
  static let defaultEnableYUV444 = false
  static let defaultIgnoreAspectRatio = false
  static let defaultShowLocalCursor = false
  static let defaultEnableMicrophone = false
  static let defaultStreamResolutionScale = false
  static let defaultStreamResolutionScaleRatio = 100
  static let defaultDebugLogMode = "curated"
  static let defaultDebugLogMinLevel = "info"
  static let defaultDebugLogShowSystemNoise = false
  static let defaultDebugLogAutoScroll = true
  static let defaultDebugLogTimeScope = "launch"
  static let defaultDebugLogInputDiagnostics = false
  static let defaultAwdlStabilityHelperEnabled = false
  static let defaultAwdlStabilityHelperAcknowledged = false

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

  private func effectiveResolutionForBitrate() -> CGSize {
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

  private func effectiveFpsForBitrate() -> Int {
    if selectedFps == .zero {
      if let customFps, customFps > 0 {
        return Int(customFps)
      }
      return Self.defaultFps
    }
    return selectedFps
  }

  private func applyAutoBitrateIfNeeded(force: Bool = false) {
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

  private static func derivedSmoothnessLatencyMode(
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

  private func syncSmoothnessLatencyModeFromTimingDetails() {
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

  private func applySmoothnessLatencyPresetIfNeeded() {
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

  private static func normalizedDebugLogMode(_ value: String?) -> String {
    guard let value else { return defaultDebugLogMode }
    let normalized = value.lowercased()
    return normalized == "raw" ? "raw" : "curated"
  }

  private static func normalizedDebugLogMinLevel(_ value: String?) -> String {
    guard let value else { return defaultDebugLogMinLevel }
    switch value.lowercased() {
    case "all", "debug", "info", "warn", "error":
      return value.lowercased()
    default:
      return defaultDebugLogMinLevel
    }
  }

  private static func normalizedDebugLogTimeScope(_ value: String?) -> String {
    guard let value else { return defaultDebugLogTimeScope }
    switch value.lowercased() {
    case "all", "launch", "since_clear":
      return value.lowercased()
    default:
      return defaultDebugLogTimeScope
    }
  }

  private static func loggerLevel(from stringValue: String) -> LogLevel {
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

  init() {
    if let hosts = Self.hosts {
      let selectedProfile = UserDefaults.standard.string(forKey: "selectedSettingsProfile")
      if let selectedProfile,
        let match = hosts.compactMap({ $0 }).first(where: { $0.id == selectedProfile })
      {
        selectedHost = match
      } else {
        selectedHost = hosts.compactMap({ $0 }).first(where: { $0.id == Self.globalHostId })
      }
    } else {
      selectedHost = Host(id: Self.globalHostId, name: "Global")
    }

    let persistedLogMode = UserDefaults.standard.string(forKey: Self.debugLogModeKey)
    let envLogMode = ProcessInfo.processInfo.environment["MOONLIGHT_LOG_VIEW"]
    debugLogMode = Self.normalizedDebugLogMode(persistedLogMode ?? envLogMode)
    debugLogMinLevel = Self.normalizedDebugLogMinLevel(
      UserDefaults.standard.string(forKey: Self.debugLogMinLevelKey))
    if UserDefaults.standard.object(forKey: Self.debugLogShowSystemNoiseKey) != nil {
      debugLogShowSystemNoise = UserDefaults.standard.bool(forKey: Self.debugLogShowSystemNoiseKey)
    } else {
      debugLogShowSystemNoise = Self.defaultDebugLogShowSystemNoise
    }
    if UserDefaults.standard.object(forKey: Self.debugLogAutoScrollKey) != nil {
      debugLogAutoScroll = UserDefaults.standard.bool(forKey: Self.debugLogAutoScrollKey)
    } else {
      debugLogAutoScroll = Self.defaultDebugLogAutoScroll
    }
    debugLogTimeScope = Self.normalizedDebugLogTimeScope(
      UserDefaults.standard.string(forKey: Self.debugLogTimeScopeKey))
    if UserDefaults.standard.object(forKey: Self.debugLogInputDiagnosticsKey) != nil {
      debugLogInputDiagnostics = UserDefaults.standard.bool(forKey: Self.debugLogInputDiagnosticsKey)
    } else {
      debugLogInputDiagnostics = Self.defaultDebugLogInputDiagnostics
    }
    if UserDefaults.standard.object(forKey: Self.awdlStabilityHelperEnabledKey) != nil {
      awdlStabilityHelperEnabled = UserDefaults.standard.bool(
        forKey: Self.awdlStabilityHelperEnabledKey)
    } else {
      awdlStabilityHelperEnabled = Self.defaultAwdlStabilityHelperEnabled
    }
    if UserDefaults.standard.object(forKey: Self.awdlStabilityHelperAcknowledgedKey) != nil {
      awdlStabilityHelperAcknowledged = UserDefaults.standard.bool(
        forKey: Self.awdlStabilityHelperAcknowledgedKey)
    } else {
      awdlStabilityHelperAcknowledged = Self.defaultAwdlStabilityHelperAcknowledged
    }

    selectedResolution = Self.defaultResolution
    customResWidth = Self.defaultCustomResWidth
    customResHeight = Self.defaultCustomResHeight
    selectedFps = Self.defaultFps
    customFps = Self.defaultCustomFps

    remoteResolutionEnabled = Self.defaultRemoteResolutionEnabled
    selectedRemoteResolution = Self.defaultRemoteResolution
    remoteCustomResWidth = Self.defaultRemoteCustomResWidth
    remoteCustomResHeight = Self.defaultRemoteCustomResHeight
    remoteFpsEnabled = Self.defaultRemoteFpsEnabled
    selectedRemoteFps = Self.defaultRemoteFps
    remoteCustomFps = Self.defaultRemoteCustomFps

    bitrateSliderValue = Self.defaultBitrateSliderValue
    customBitrate = Int(
      Self.bitrateSteps(unlocked: Self.defaultUnlockMaxBitrate)[Int(Self.defaultBitrateSliderValue)]
        * 1000.0)
    unlockMaxBitrate = Self.defaultUnlockMaxBitrate

    autoAdjustBitrate = Self.defaultAutoAdjustBitrate
    enableYUV444 = Self.defaultEnableYUV444
    ignoreAspectRatio = Self.defaultIgnoreAspectRatio
    showLocalCursor = Self.defaultShowLocalCursor
    enableMicrophone = Self.defaultEnableMicrophone
    streamResolutionScale = Self.defaultStreamResolutionScale
    streamResolutionScaleRatio = Self.defaultStreamResolutionScaleRatio

    selectedVideoCodec = Self.defaultVideoCodec
    hdr = Self.defaultHdr
    selectedPacingOptions = Self.defaultPacingOptions
    selectedSmoothnessLatencyMode = Self.defaultSmoothnessLatencyMode

    audioOnPC = Self.defaultAudioOnPC
    selectedAudioConfiguration = Self.defaultAudioConfiguration
    enableVsync = Self.defaultEnableVsync
    selectedTimingBufferLevel = Self.defaultTimingBufferLevel
    timingPrioritizeResponsiveness = Self.defaultTimingPrioritizeResponsiveness
    timingCompatibilityMode = Self.defaultTimingCompatibilityMode
    timingSdrCompatibilityWorkaround = Self.defaultTimingSdrCompatibilityWorkaround
    showPerformanceOverlay = Self.defaultShowPerformanceOverlay
    showConnectionWarnings = Self.defaultShowConnectionWarnings
    captureSystemShortcuts = Self.defaultCaptureSystemShortcuts
    volumeLevel = Self.defaultVolumeLevel

    selectedMultiControllerMode = Self.defaultMultiControllerMode
    swapButtons = Self.defaultSwapButtons

    optimize = Self.defaultOptimize

    autoFullscreen = Self.defaultAutoFullscreen
    selectedDisplayMode = Self.getString(from: Self.defaultDisplayMode, in: Self.displayModes)
    rumble = Self.defaultRumble
    selectedControllerDriver = Self.defaultControllerDriver
    selectedMouseDriver = Self.defaultMouseDriver

    quitAppAfterStream = Self.defaultQuitAppAfterStream
    absoluteMouseMode = Self.defaultAbsoluteMouseMode
    swapMouseButtons = Self.defaultSwapMouseButtons
    reverseScrollDirection = Self.defaultReverseScrollDirection
    pointerSensitivity = Self.defaultPointerSensitivity
    coreHIDMaxMouseReportRate = Self.defaultCoreHIDMaxMouseReportRate
    streamShortcuts = StreamShortcutProfile.defaultShortcuts()
    selectedTouchscreenMode = Self.getString(
      from: Self.defaultTouchscreenMode, in: Self.touchscreenModes)

    emulateGuide = Self.defaultEmulateGuide
    appArtworkWidth = Self.defaultAppArtworkWidth
    appArtworkHeight = Self.defaultAppArtworkHeight
    dimNonHoveredArtwork = Self.defaultDimNonHoveredArtwork
    gamepadMouseMode = Self.defaultGamepadMouseMode
    mouseMode = Self.defaultMouseMode
    selectedUpscalingMode = Self.getString(from: Self.defaultUpscalingMode, in: Self.upscalingModes)
    selectedConnectionMethod = "Auto"

    NotificationCenter.default.addObserver(
      self, selector: #selector(handleHostLatencyUpdate),
      name: NSNotification.Name("HostLatencyUpdated"), object: nil)

    NotificationCenter.default.addObserver(
      self, selector: #selector(handleEndpointUpdate),
      name: NSNotification.Name("ConnectionEndpointsUpdated"), object: nil)

    NotificationCenter.default.addObserver(
      self, selector: #selector(handleConnectionMethodUpdate),
      name: NSNotification.Name("ConnectionMethodUpdated"), object: nil)

    LoggerSetCuratedModeEnabled(debugLogMode != "raw")
    LoggerSetMinimumLevel(Self.loggerLevel(from: debugLogMinLevel))

    selectedProfileObserver = NotificationCenter.default.addObserver(
      forName: Notification.Name("MoonlightSelectedSettingsProfileChanged"),
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let hostId = notification.userInfo?["hostId"] as? String else { return }
      self?.selectHost(id: hostId)
    }
  }

  deinit {
    if let selectedProfileObserver {
      NotificationCenter.default.removeObserver(selectedProfileObserver)
    }
  }

  @objc func handleHostLatencyUpdate(_ notification: Notification) {
    guard let userInfo = notification.userInfo,
      let uuid = userInfo["uuid"] as? String
    else { return }

    DispatchQueue.main.async {
      self.latencyCache[uuid] = userInfo as? [String: Any]
      if self.selectedHost?.id == uuid {
        self.ensureConnectionMethodValid()
        self.objectWillChange.send()
      }
    }
  }

  @objc func handleEndpointUpdate(_ notification: Notification) {
    guard let userInfo = notification.userInfo,
      let uuid = userInfo["uuid"] as? String
    else { return }

    DispatchQueue.main.async {
      if self.selectedHost?.id == uuid {
        self.ensureConnectionMethodValid()
        self.objectWillChange.send()
      }
    }
  }

  @objc func handleConnectionMethodUpdate(_ notification: Notification) {
    guard let userInfo = notification.userInfo,
      let uuid = userInfo["uuid"] as? String,
      let method = userInfo["method"] as? String
    else { return }

    DispatchQueue.main.async {
      if self.selectedHost?.id == uuid {
        self.selectedConnectionMethod = method
        self.ensureConnectionMethodValid()
        self.objectWillChange.send()
      }
    }
  }

  func loadDefaultSettings() {
    isLoading = true
    defer { isLoading = false }

    selectedResolution = Self.defaultResolution
    customResWidth = Self.defaultCustomResWidth
    customResHeight = Self.defaultCustomResHeight
    selectedFps = Self.defaultFps
    customFps = Self.defaultCustomFps

    remoteResolutionEnabled = Self.defaultRemoteResolutionEnabled
    selectedRemoteResolution = Self.defaultRemoteResolution
    remoteCustomResWidth = Self.defaultRemoteCustomResWidth
    remoteCustomResHeight = Self.defaultRemoteCustomResHeight
    remoteFpsEnabled = Self.defaultRemoteFpsEnabled
    selectedRemoteFps = Self.defaultRemoteFps
    remoteCustomFps = Self.defaultRemoteCustomFps

    bitrateSliderValue = Self.defaultBitrateSliderValue
    customBitrate = Int(
      Self.bitrateSteps(unlocked: Self.defaultUnlockMaxBitrate)[Int(Self.defaultBitrateSliderValue)]
        * 1000.0)
    unlockMaxBitrate = Self.defaultUnlockMaxBitrate

    autoAdjustBitrate = Self.defaultAutoAdjustBitrate
    enableYUV444 = Self.defaultEnableYUV444
    ignoreAspectRatio = Self.defaultIgnoreAspectRatio
    showLocalCursor = Self.defaultShowLocalCursor
    enableMicrophone = Self.defaultEnableMicrophone
    streamResolutionScale = Self.defaultStreamResolutionScale
    streamResolutionScaleRatio = Self.defaultStreamResolutionScaleRatio

    selectedVideoCodec = Self.defaultVideoCodec
    hdr = Self.defaultHdr
    selectedPacingOptions = Self.defaultPacingOptions
    selectedSmoothnessLatencyMode = Self.defaultSmoothnessLatencyMode

    audioOnPC = Self.defaultAudioOnPC
    selectedAudioConfiguration = Self.defaultAudioConfiguration
    enableVsync = Self.defaultEnableVsync
    selectedTimingBufferLevel = Self.defaultTimingBufferLevel
    timingPrioritizeResponsiveness = Self.defaultTimingPrioritizeResponsiveness
    timingCompatibilityMode = Self.defaultTimingCompatibilityMode
    timingSdrCompatibilityWorkaround = Self.defaultTimingSdrCompatibilityWorkaround
    showPerformanceOverlay = Self.defaultShowPerformanceOverlay
    showConnectionWarnings = Self.defaultShowConnectionWarnings
    captureSystemShortcuts = Self.defaultCaptureSystemShortcuts
    volumeLevel = Self.defaultVolumeLevel

    selectedMultiControllerMode = Self.defaultMultiControllerMode
    swapButtons = Self.defaultSwapButtons

    optimize = Self.defaultOptimize

    autoFullscreen = Self.defaultAutoFullscreen
    selectedDisplayMode = Self.getString(from: Self.defaultDisplayMode, in: Self.displayModes)
    rumble = Self.defaultRumble
    selectedControllerDriver = Self.defaultControllerDriver

    quitAppAfterStream = Self.defaultQuitAppAfterStream
    absoluteMouseMode = Self.defaultAbsoluteMouseMode
    swapMouseButtons = Self.defaultSwapMouseButtons
    reverseScrollDirection = Self.defaultReverseScrollDirection
    pointerSensitivity = Self.defaultPointerSensitivity
    coreHIDMaxMouseReportRate = Self.defaultCoreHIDMaxMouseReportRate
    streamShortcuts = StreamShortcutProfile.defaultShortcuts()
    selectedTouchscreenMode = Self.getString(
      from: Self.defaultTouchscreenMode, in: Self.touchscreenModes)
    selectedMouseDriver = Self.defaultMouseDriver

    emulateGuide = Self.defaultEmulateGuide
    appArtworkWidth = Self.defaultAppArtworkWidth
    appArtworkHeight = Self.defaultAppArtworkHeight
    dimNonHoveredArtwork = Self.defaultDimNonHoveredArtwork
    gamepadMouseMode = Self.defaultGamepadMouseMode
    mouseMode = Self.defaultMouseMode
    selectedUpscalingMode = Self.getString(from: Self.defaultUpscalingMode, in: Self.upscalingModes)
    selectedConnectionMethod = "Auto"
  }

  func loadAndSaveDefaultSettings() {
    loadDefaultSettings()
    saveSettings()
  }

  func loadSettings() {
    isLoading = true
    defer { isLoading = false }

    let hostId = selectedHost?.id ?? Self.globalHostId
    if let settings = Settings.getSettings(for: hostId) {
      selectedResolution = settings.resolution

      if settings.matchDisplayResolution ?? false {
        selectedResolution = Self.matchDisplayResolutionSentinel
      }

      let customResolution = loadNillableDimensionSetting(
        inputDimensions: settings.customResolution)
      customResWidth = customResolution != nil ? customResolution!.width : nil
      customResHeight = customResolution != nil ? customResolution!.height : nil
      if customResolution == nil {
        if selectedResolution == .zero {
          selectedResolution = Self.defaultResolution
        }
      }

      selectedFps = settings.fps
      customFps = settings.customFps
      if customFps == nil {
        if selectedFps == 0 {
          selectedFps = Self.defaultFps
        }
      }

      unlockMaxBitrate = settings.unlockMaxBitrate ?? Self.defaultUnlockMaxBitrate

      autoAdjustBitrate = settings.autoAdjustBitrate ?? Self.defaultAutoAdjustBitrate
      enableYUV444 = settings.enableYUV444 ?? Self.defaultEnableYUV444
      ignoreAspectRatio = settings.ignoreAspectRatio ?? Self.defaultIgnoreAspectRatio
      showLocalCursor = settings.showLocalCursor ?? Self.defaultShowLocalCursor
      enableMicrophone = settings.enableMicrophone ?? Self.defaultEnableMicrophone
      streamResolutionScale = settings.streamResolutionScale ?? Self.defaultStreamResolutionScale
      streamResolutionScaleRatio =
        settings.streamResolutionScaleRatio ?? Self.defaultStreamResolutionScaleRatio

      let effectiveBitrateKbps = settings.customBitrate ?? settings.bitrate
      customBitrate = effectiveBitrateKbps
      let steps = Self.bitrateSteps(unlocked: unlockMaxBitrate)
      var bitrateIndex = 0
      for i in 0..<steps.count {
        if Float(effectiveBitrateKbps) <= steps[i] * 1000.0 {
          bitrateIndex = i
          break
        }
      }
      bitrateSliderValue = Float(bitrateIndex)

      applyAutoBitrateIfNeeded(force: true)

      selectedVideoCodec = Self.getString(from: settings.codec, in: Self.videoCodecs)
      hdr = settings.hdr
      selectedPacingOptions = Self.getString(from: settings.framePacing, in: Self.pacingOptions)
      selectedSmoothnessLatencyMode = Self.getString(
        from: settings.smoothnessLatencyMode
          ?? Self.derivedSmoothnessLatencyMode(
            framePacing: settings.framePacing,
            enableVsync: settings.enableVsync,
            timingBufferLevel: settings.timingBufferLevel,
            timingPrioritizeResponsiveness: settings.timingPrioritizeResponsiveness,
            timingCompatibilityMode: settings.timingCompatibilityMode,
            timingSdrCompatibilityWorkaround: settings.timingSdrCompatibilityWorkaround
          ),
        in: Self.smoothnessLatencyModes)

      audioOnPC = settings.audioOnPC
      selectedAudioConfiguration = Self.getString(
        from: settings.audioConfiguration, in: Self.audioConfigurations)
      enableVsync = settings.enableVsync ?? SettingsModel.defaultEnableVsync
      selectedTimingBufferLevel = Self.getString(
        from: settings.timingBufferLevel ?? Self.getInt(from: Self.defaultTimingBufferLevel, in: Self.timingBufferLevels),
        in: Self.timingBufferLevels)
      timingPrioritizeResponsiveness =
        settings.timingPrioritizeResponsiveness ?? Self.defaultTimingPrioritizeResponsiveness
      timingCompatibilityMode =
        settings.timingCompatibilityMode ?? Self.defaultTimingCompatibilityMode
      timingSdrCompatibilityWorkaround =
        settings.timingSdrCompatibilityWorkaround ?? Self.defaultTimingSdrCompatibilityWorkaround
      showPerformanceOverlay =
        settings.showPerformanceOverlay ?? SettingsModel.defaultShowPerformanceOverlay
      showConnectionWarnings =
        settings.showConnectionWarnings ?? SettingsModel.defaultShowConnectionWarnings
      captureSystemShortcuts =
        settings.captureSystemShortcuts ?? SettingsModel.defaultCaptureSystemShortcuts
      volumeLevel = settings.volumeLevel ?? SettingsModel.defaultVolumeLevel

      selectedMultiControllerMode = Self.getString(
        from: settings.multiController, in: Self.multiControllerModes)
      swapButtons = settings.swapABXYButtons

      optimize = settings.optimize

      autoFullscreen = settings.autoFullscreen
      selectedDisplayMode = Self.getString(
        from: settings.displayMode ?? (settings.autoFullscreen ? 1 : 0), in: Self.displayModes)
      rumble = settings.rumble
      selectedControllerDriver = Self.getString(
        from: settings.controllerDriver, in: Self.controllerDrivers)
      selectedMouseDriver = Self.getString(from: settings.mouseDriver, in: Self.mouseDrivers)

      emulateGuide = settings.emulateGuide

      let appArtworkDimensions = loadNillableDimensionSetting(
        inputDimensions: settings.appArtworkDimensions)
      appArtworkWidth = appArtworkDimensions != nil ? appArtworkDimensions!.width : nil
      appArtworkHeight = appArtworkDimensions != nil ? appArtworkDimensions!.height : nil

      dimNonHoveredArtwork = settings.dimNonHoveredArtwork

      quitAppAfterStream = settings.quitAppAfterStream ?? Self.defaultQuitAppAfterStream
      absoluteMouseMode = settings.absoluteMouseMode ?? Self.defaultAbsoluteMouseMode
      swapMouseButtons = settings.swapMouseButtons ?? Self.defaultSwapMouseButtons
      reverseScrollDirection =
        settings.reverseScrollDirection ?? Self.defaultReverseScrollDirection
      pointerSensitivity = settings.pointerSensitivity ?? Self.defaultPointerSensitivity
      coreHIDMaxMouseReportRate = Self.normalizedCoreHIDMaxMouseReportRate(
        settings.coreHIDMaxMouseReportRate ?? Self.defaultCoreHIDMaxMouseReportRate
      )
      streamShortcuts = StreamShortcutProfile.normalizedShortcuts(settings.streamShortcuts)
      selectedTouchscreenMode = Self.getString(
        from: settings.touchscreenMode ?? Self.defaultTouchscreenMode, in: Self.touchscreenModes)
      gamepadMouseMode = settings.gamepadMouseMode ?? Self.defaultGamepadMouseMode
      mouseMode = Self.getString(from: settings.mouseMode ?? (Self.defaultMouseMode == "game" ? 0 : 1), in: Self.mouseModes)
      selectedUpscalingMode = Self.getString(
        from: settings.upscalingMode ?? Self.defaultUpscalingMode, in: Self.upscalingModes)
      selectedConnectionMethod = settings.connectionMethod ?? "Auto"

      remoteResolutionEnabled = settings.remoteResolution ?? Self.defaultRemoteResolutionEnabled
      if remoteResolutionEnabled,
        let w = settings.remoteResolutionWidth,
        let h = settings.remoteResolutionHeight,
        w > 0,
        h > 0
      {
        let remoteSize = CGSize(width: CGFloat(w), height: CGFloat(h))
        if Self.remoteResolutions.contains(remoteSize) {
          selectedRemoteResolution = remoteSize
          remoteCustomResWidth = nil
          remoteCustomResHeight = nil
        } else {
          selectedRemoteResolution = .zero
          remoteCustomResWidth = CGFloat(w)
          remoteCustomResHeight = CGFloat(h)
        }
      } else {
        selectedRemoteResolution = Self.defaultRemoteResolution
        remoteCustomResWidth = Self.defaultRemoteCustomResWidth
        remoteCustomResHeight = Self.defaultRemoteCustomResHeight
      }

      remoteFpsEnabled = settings.remoteFps ?? Self.defaultRemoteFpsEnabled
      if remoteFpsEnabled {
        let rate = settings.remoteFpsRate ?? 0
        if Self.fpss.contains(rate), rate != 0 {
          selectedRemoteFps = rate
          remoteCustomFps = nil
        } else {
          selectedRemoteFps = .zero
          remoteCustomFps = rate > 0 ? CGFloat(rate) : nil
        }
      } else {
        selectedRemoteFps = Self.defaultRemoteFps
        remoteCustomFps = Self.defaultRemoteCustomFps
      }

      func loadNillableDimensionSetting(inputDimensions: CGSize?) -> CGSize? {
        let finalSize: CGSize?

        if let nonNilDimensions = inputDimensions {
          if nonNilDimensions.width == .zero || nonNilDimensions.height == .zero {
            finalSize = nil
          } else {
            finalSize = nonNilDimensions
          }
        } else {
          finalSize = nil
        }

        return finalSize
      }
    } else {
      loadAndSaveDefaultSettings()
    }
  }

  func saveSettings() {
    guard !isLoading else { return }

    let hostId = selectedHost?.id ?? Self.globalHostId

    // Ensure customBitrate is nil if it matches the slider value to keep it clean,
    // but if user typed it, we prefer customBitrate.
    // Actually, logic: use customBitrate if not nil, else use slider.

    let matchDisplayResolution = selectedResolution == Self.matchDisplayResolutionSentinel

    var customResolution: CGSize? = nil
    if !matchDisplayResolution {
      if let customResWidth, let customResHeight {
        if customResWidth == 0 || customResHeight == 0 {
          customResolution = nil
        } else {
          customResolution = CGSizeMake(CGFloat(customResWidth), CGFloat(customResHeight))
        }
      }
    }

    var finalCustomFps: CGFloat? = nil
    if let customFps {
      if customFps == 0 {
        finalCustomFps = nil
      } else {
        finalCustomFps = customFps
      }
    }

    let touchscreenMode = Self.getInt(from: selectedTouchscreenMode, in: Self.touchscreenModes)
    let mouseModeVal = Self.getInt(from: mouseMode, in: Self.mouseModes)

    // Persist Off on unsupported systems to avoid saving an unusable mode.
    let rawUpscalingMode = Self.getInt(from: selectedUpscalingMode, in: Self.upscalingModes)
    let upscalingMode = Self.isMetalFXSupported ? rawUpscalingMode : 0

    var remoteResolutionWidth: Int? = nil
    var remoteResolutionHeight: Int? = nil
    if remoteResolutionEnabled {
      if selectedRemoteResolution == .zero {
        if let w = remoteCustomResWidth, let h = remoteCustomResHeight, w > 0, h > 0 {
          remoteResolutionWidth = Int(w)
          remoteResolutionHeight = Int(h)
        }
      } else {
        remoteResolutionWidth = Int(selectedRemoteResolution.width)
        remoteResolutionHeight = Int(selectedRemoteResolution.height)
      }
    }

    var remoteFpsRate: Int? = nil
    if remoteFpsEnabled {
      if selectedRemoteFps == .zero {
        if let v = remoteCustomFps, v > 0 {
          remoteFpsRate = Int(v)
        }
      } else {
        remoteFpsRate = selectedRemoteFps
      }
    }

    let steps = Self.bitrateSteps(unlocked: unlockMaxBitrate)
    let index = max(0, min(Int(bitrateSliderValue), steps.count - 1))
    let effectiveBitrate = customBitrate ?? Int(steps[index] * 1000)

    // If enabled, recompute bitrate using the moonlight-qt algorithm.
    let bitrate: Int
    if autoAdjustBitrate {
      let res = effectiveResolutionForBitrate()
      let fps = effectiveFpsForBitrate()
      bitrate = Self.getDefaultBitrateKbps(
        width: Int(res.width), height: Int(res.height), fps: fps, yuv444: enableYUV444)
    } else {
      bitrate = effectiveBitrate
    }
    let codec = Self.getInt(from: selectedVideoCodec, in: Self.videoCodecs)
    let framePacing = Self.getInt(from: selectedPacingOptions, in: Self.pacingOptions)
    let smoothnessLatencyMode = Self.getInt(
      from: selectedSmoothnessLatencyMode, in: Self.smoothnessLatencyModes)
    let timingBufferLevel = Self.getInt(
      from: selectedTimingBufferLevel, in: Self.timingBufferLevels)
    let audioConfig = Self.getInt(from: selectedAudioConfiguration, in: Self.audioConfigurations)
    let multiController = Self.getBool(
      from: selectedMultiControllerMode, in: Self.multiControllerModes)
    let displayMode = Self.getInt(from: selectedDisplayMode, in: Self.displayModes)
    let controllerDriver = Self.getInt(from: selectedControllerDriver, in: Self.controllerDrivers)
    let mouseDriver = Self.getInt(from: selectedMouseDriver, in: Self.mouseDrivers)
    let normalizedCoreHIDMaxMouseReportRate = Self.normalizedCoreHIDMaxMouseReportRate(
      self.coreHIDMaxMouseReportRate
    )

    var appArtworkDimensions: CGSize? = nil
    if let appArtworkWidth, let appArtworkHeight {
      if appArtworkWidth == 0 || appArtworkHeight == 0 {
        appArtworkDimensions = nil
      } else {
        appArtworkDimensions = CGSizeMake(CGFloat(appArtworkWidth), CGFloat(appArtworkHeight))
      }
    }

    let settings = Settings(
      resolution: matchDisplayResolution ? Self.defaultResolution : selectedResolution,
      matchDisplayResolution: matchDisplayResolution,
      customResolution: customResolution,
      fps: selectedFps,
      customFps: finalCustomFps,

      autoAdjustBitrate: autoAdjustBitrate,
      enableYUV444: enableYUV444,
      ignoreAspectRatio: ignoreAspectRatio,
      showLocalCursor: showLocalCursor,
      enableMicrophone: enableMicrophone,
      streamResolutionScale: streamResolutionScale,
      streamResolutionScaleRatio: streamResolutionScaleRatio,

      remoteResolution: remoteResolutionEnabled,
      remoteResolutionWidth: remoteResolutionWidth,
      remoteResolutionHeight: remoteResolutionHeight,
      remoteFps: remoteFpsEnabled,
      remoteFpsRate: remoteFpsRate,

      bitrate: bitrate,
      customBitrate: autoAdjustBitrate ? nil : customBitrate,
      unlockMaxBitrate: unlockMaxBitrate,
      codec: codec,
      hdr: hdr,
      framePacing: framePacing,
      audioOnPC: audioOnPC,
      audioConfiguration: audioConfig,
      enableVsync: enableVsync,
      showPerformanceOverlay: showPerformanceOverlay,
      showConnectionWarnings: showConnectionWarnings,
      captureSystemShortcuts: captureSystemShortcuts,
      volumeLevel: volumeLevel,
      multiController: multiController,
      swapABXYButtons: swapButtons,
      optimize: optimize,
      autoFullscreen: autoFullscreen,
      displayMode: displayMode,
      rumble: rumble,
      controllerDriver: controllerDriver,
      mouseDriver: mouseDriver,
      coreHIDMaxMouseReportRate: normalizedCoreHIDMaxMouseReportRate,
      emulateGuide: emulateGuide,
      appArtworkDimensions: appArtworkDimensions,
      dimNonHoveredArtwork: dimNonHoveredArtwork,
      quitAppAfterStream: quitAppAfterStream,
      absoluteMouseMode: absoluteMouseMode,
      swapMouseButtons: swapMouseButtons,
      reverseScrollDirection: reverseScrollDirection,
      touchscreenMode: touchscreenMode,
      gamepadMouseMode: gamepadMouseMode,
      mouseMode: mouseModeVal,
      pointerSensitivity: pointerSensitivity,
      streamShortcuts: StreamShortcutProfile.normalizedShortcuts(streamShortcuts),
      upscalingMode: upscalingMode,
      connectionMethod: selectedConnectionMethod,
      smoothnessLatencyMode: smoothnessLatencyMode,
      timingBufferLevel: timingBufferLevel,
      timingPrioritizeResponsiveness: timingPrioritizeResponsiveness,
      timingCompatibilityMode: timingCompatibilityMode,
      timingSdrCompatibilityWorkaround: timingSdrCompatibilityWorkaround
    )

    if let data = try? PropertyListEncoder().encode(settings) {
      UserDefaults.standard.set(data, forKey: SettingsClass.profileKey(for: hostId))
    }
  }

  func shortcut(for action: String) -> StreamShortcut {
    streamShortcuts[action] ?? StreamShortcutProfile.defaultShortcut(for: action)
  }

  func setShortcut(_ shortcut: StreamShortcut, for action: String) {
    var updated = StreamShortcutProfile.normalizedShortcuts(streamShortcuts)
    updated[action] = StreamShortcut(
      keyCode: shortcut.keyCode,
      modifierFlags: shortcut.modifierFlags,
      modifierOnly: shortcut.modifierOnly)
    streamShortcuts = StreamShortcutProfile.normalizedShortcuts(updated)
  }

  func resetShortcut(for action: String) {
    var updated = StreamShortcutProfile.normalizedShortcuts(streamShortcuts)
    updated[action] = StreamShortcutProfile.defaultShortcut(for: action)
    streamShortcuts = updated
  }

  func isDefaultShortcut(for action: String) -> Bool {
    shortcut(for: action).isEqual(StreamShortcutProfile.defaultShortcut(for: action))
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

extension SettingsModel {
  var streamRiskAssessment: StreamRiskAssessment {
    let mode = effectiveStreamingModeForRiskAssessment()
    let bitrateKbps = effectiveBitrateKbpsForRiskAssessment(
      width: mode.width,
      height: mode.height,
      fps: mode.fps
    )
    return StreamRiskAssessor.assess(
      host: selectedTemporaryHostForRiskAssessment(),
      targetAddress: nil,
      connectionMethod: selectedConnectionMethod,
      width: mode.width,
      height: mode.height,
      fps: mode.fps,
      bitrateKbps: bitrateKbps,
      codecName: selectedVideoCodec,
      enableYUV444: enableYUV444,
      autoMode: autoAdjustBitrate
    )
  }

  private func selectedTemporaryHostForRiskAssessment() -> TemporaryHost? {
    guard let hostId = selectedHost?.id, hostId != Self.globalHostId else {
      return nil
    }

    let dataManager = DataManager()
    guard let hosts = dataManager.getHosts() as? [TemporaryHost] else {
      return nil
    }

    return hosts.first(where: { !$0.uuid.isEmpty && $0.uuid == hostId })
  }

  private func effectiveStreamingModeForRiskAssessment() -> (width: Int, height: Int, fps: Int) {
    var resolution = effectiveResolutionForBitrate()

    if streamResolutionScale,
      streamResolutionScaleRatio > 0,
      streamResolutionScaleRatio != 100
    {
      let scaledWidth = Int(resolution.width) * streamResolutionScaleRatio / 100
      let scaledHeight = Int(resolution.height) * streamResolutionScaleRatio / 100
      resolution = CGSize(
        width: CGFloat((scaledWidth / 8) * 8),
        height: CGFloat((scaledHeight / 8) * 8)
      )
    }

    var width = max(2, Int(resolution.width))
    var height = max(2, Int(resolution.height))
    var fps = max(1, effectiveFpsForBitrate())

    if remoteResolutionEnabled {
      if selectedRemoteResolution == .zero {
        if let remoteCustomResWidth, let remoteCustomResHeight,
          remoteCustomResWidth > 0, remoteCustomResHeight > 0
        {
          width = Int(remoteCustomResWidth)
          height = Int(remoteCustomResHeight)
        }
      } else {
        width = Int(selectedRemoteResolution.width)
        height = Int(selectedRemoteResolution.height)
      }
    }

    if remoteFpsEnabled {
      if selectedRemoteFps == .zero {
        if let remoteCustomFps, remoteCustomFps > 0 {
          fps = Int(remoteCustomFps)
        }
      } else {
        fps = selectedRemoteFps
      }
    }

    width &= ~1
    height &= ~1

    return (max(2, width), max(2, height), max(1, fps))
  }

  private func effectiveBitrateKbpsForRiskAssessment(width: Int, height: Int, fps: Int) -> Int {
    if autoAdjustBitrate {
      return Self.getDefaultBitrateKbps(
        width: width,
        height: height,
        fps: fps,
        yuv444: enableYUV444
      )
    }

    let steps = Self.bitrateSteps(unlocked: unlockMaxBitrate)
    let index = max(0, min(Int(bitrateSliderValue), steps.count - 1))
    return customBitrate ?? Int(steps[index] * 1000.0)
  }
}
