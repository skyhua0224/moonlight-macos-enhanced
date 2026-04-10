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
  static let mouseSettingsChangedNotification = Notification.Name("MoonlightMouseSettingsDidChange")
  static let matchDisplayResolutionSentinel = CGSize(width: -1, height: -1)
  static let debugLogModeKey = "debugLog.mode"
  static let debugLogMinLevelKey = "debugLog.minLevel"
  static let debugLogShowSystemNoiseKey = "debugLog.showSystemNoise"
  static let debugLogAutoScrollKey = "debugLog.autoScroll"
  static let debugLogTimeScopeKey = "debugLog.timeScope"
  static let debugLogInputDiagnosticsKey = "debugLog.inputDiagnostics"
  static let awdlStabilityHelperEnabledKey = "networkCompatibility.awdlHelperEnabled"
  static let awdlStabilityHelperAcknowledgedKey = "networkCompatibility.awdlHelperAcknowledged"

  var latencyCache: [String: [String: Any]] = [:]
  var selectedProfileObserver: NSObjectProtocol?

  private func postMouseSettingsChanged(_ setting: String) {
    let hostId = selectedHost?.id ?? Self.globalHostId
    NotificationCenter.default.post(
      name: Self.mouseSettingsChangedNotification,
      object: nil,
      userInfo: [
        "hostId": hostId,
        "setting": setting,
      ])
  }

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
      LoggerSetInputDiagnosticsEnabled(debugLogInputDiagnostics)
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

  var isLoading = false
  var isAdjustingBitrate = false
  var isApplyingSmoothnessLatencyPreset = false
  var isSyncingSmoothnessLatencyMode = false

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
      postMouseSettingsChanged("mouseDriver")
    }
  }
  @Published var coreHIDMaxMouseReportRate: Int {
    didSet {
      guard !isLoading else { return }
      saveSettings()
      postMouseSettingsChanged("coreHIDMaxMouseReportRate")
    }
  }
  @Published var selectedFreeMouseMotionMode: String {
    didSet {
      guard !isLoading else { return }
      saveSettings()
      postMouseSettingsChanged("freeMouseMotionMode")
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
  @Published var wheelScrollSpeed: CGFloat {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var rewrittenScrollSpeed: CGFloat {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var gestureScrollSpeed: CGFloat {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var physicalWheelHighPrecisionScale: CGFloat {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var smartWheelTailFilter: CGFloat {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var selectedPhysicalWheelMode: String {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var selectedRewrittenScrollMode: String {
    didSet {
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
      postMouseSettingsChanged("touchscreenMode")
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
      postMouseSettingsChanged("mouseMode")
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
    coreHIDMaxMouseReportRate = Self.defaultCoreHIDMaxMouseReportRate
    selectedFreeMouseMotionMode = Self.defaultFreeMouseMotionMode

    quitAppAfterStream = Self.defaultQuitAppAfterStream
    absoluteMouseMode = Self.defaultAbsoluteMouseMode
    swapMouseButtons = Self.defaultSwapMouseButtons
    reverseScrollDirection = Self.defaultReverseScrollDirection
    pointerSensitivity = Self.defaultPointerSensitivity
    wheelScrollSpeed = Self.defaultWheelScrollSpeed
    rewrittenScrollSpeed = Self.defaultRewrittenScrollSpeed
    gestureScrollSpeed = Self.defaultGestureScrollSpeed
    physicalWheelHighPrecisionScale = Self.defaultPhysicalWheelHighPrecisionScale
    smartWheelTailFilter = Self.defaultSmartWheelTailFilter
    selectedPhysicalWheelMode = Self.defaultPhysicalWheelMode
    selectedRewrittenScrollMode = Self.defaultRewrittenScrollMode
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
    LoggerSetInputDiagnosticsEnabled(debugLogInputDiagnostics)

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
}
