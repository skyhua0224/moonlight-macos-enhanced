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

struct SunshineDisplayOption: Identifiable, Equatable {
  let id: String
  let value: String
  let title: String
}

enum CapabilityAvailability: Int {
  case available = 0
  case limited = 1
  case unavailable = 2

  var localizationKey: String {
    switch self {
    case .available:
      return "Available"
    case .limited:
      return "Limited"
    case .unavailable:
      return "Unavailable"
    }
  }

  var tint: Color {
    switch self {
    case .available:
      return .green
    case .limited:
      return .orange
    case .unavailable:
      return .secondary
    }
  }
}

struct VideoCapabilityItem: Identifiable, Equatable {
  let id: String
  let titleKey: String
  let availability: CapabilityAvailability
  let detailKey: String?
}

struct VideoCapabilityMatrix: Equatable {
  let displayName: String
  let items: [VideoCapabilityItem]

  static let empty = VideoCapabilityMatrix(displayName: "", items: [])
}

class SettingsModel: ObservableObject {
  static let globalHostId = "__global__"
  static let mouseSettingsChangedNotification = Notification.Name("MoonlightMouseSettingsDidChange")
  static let streamShortcutsChangedNotification = Notification.Name("MoonlightStreamShortcutsDidChange")
  static let matchDisplayResolutionSentinel = CGSize(width: -1, height: -1)
  static let debugLogModeKey = "debugLog.mode"
  static let debugLogMinLevelKey = "debugLog.minLevel"
  static let debugLogShowSystemNoiseKey = "debugLog.showSystemNoise"
  static let debugLogAutoScrollKey = "debugLog.autoScroll"
  static let debugLogTimeScopeKey = "debugLog.timeScope"
  static let debugLogInputDiagnosticsKey = "debugLog.inputDiagnostics"
  static let awdlStabilityHelperEnabledKey = "networkCompatibility.awdlHelperEnabled"
  static let awdlStabilityHelperAcknowledgedKey = "networkCompatibility.awdlHelperAcknowledged"

  static func keyboardTranslationRulesStorageKey(for hostId: String) -> String {
    "\(hostId)-moonlightKeyboardTranslationRules"
  }

  var latencyCache: [String: [String: Any]] = [:]
  var selectedProfileObserver: NSObjectProtocol?
  var hasLoadedPersistedSettings = false

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

  private func postStreamShortcutsChanged() {
    let hostId = selectedHost?.id ?? Self.globalHostId
    NotificationCenter.default.post(
      name: Self.streamShortcutsChangedNotification,
      object: nil,
      userInfo: [
        "hostId": hostId,
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
      refreshVideoDiagnosticsState()
      refreshSunshineDisplays(force: false)
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
    let currentHostId = selectedHost?.id
    if let id {
      if currentHostId == id {
        ensureSettingsLoadedIfNeeded()
        return
      }
      if let host = Self.hosts?.compactMap({ $0 }).first(where: { $0.id == id }) {
        selectedHost = host
      }
    } else {
      if currentHostId == Self.globalHostId {
        ensureSettingsLoadedIfNeeded()
        return
      }
      if let host = Self.hosts?.compactMap({ $0 }).first(where: { $0.id == Self.globalHostId }) {
        selectedHost = host
      }
    }
  }

  var isLoading = false
  var isAdjustingBitrate = false
  var isApplyingSmoothnessLatencyPreset = false
  var isSyncingSmoothnessLatencyMode = false
  var isApplyingEnhancedAudioPreset = false
  var sunshineDisplayFetchGeneration = 0
  var loadedSunshineDisplaysHostId: String?

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
  @Published var selectedHdrTransferFunction: String {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var sunshineTargetDisplayName: String {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var sunshineUseVirtualDisplay: Bool {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var selectedSunshineScreenMode: String {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var sunshineHdrBrightnessOverride: Bool {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var sunshineMaxBrightness: CGFloat? {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var sunshineMinBrightness: CGFloat? {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var sunshineMaxAverageBrightness: CGFloat? {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var selectedHdrMetadataSource: String {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var selectedHdrClientDisplayProfile: String {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var hdrManualMaxBrightness: CGFloat? {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var hdrManualMinBrightness: CGFloat? {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var hdrManualMaxAverageBrightness: CGFloat? {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var hdrOpticalOutputScale: CGFloat {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var selectedHdrHlgViewingEnvironment: String {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var selectedHdrEdrStrategy: String {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var selectedHdrToneMappingPolicy: String {
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
  @Published var selectedVideoRendererMode: String {
    didSet {
      guard !isLoading else { return }
      let normalized = Self.normalizedVideoRendererMode(selectedVideoRendererMode)
      if normalized != selectedVideoRendererMode {
        selectedVideoRendererMode = normalized
        return
      }
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
  @Published var selectedAudioOutputMode: String {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var selectedEnhancedAudioOutputTarget: String {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var selectedEnhancedAudioPreset: String {
    didSet {
      guard !isLoading, !isApplyingEnhancedAudioPreset else { return }
      applyEnhancedAudioPresetIfNeeded()
      saveSettings()
    }
  }
  @Published var selectedEnhancedAudioEQLayout: String {
    didSet {
      guard !isLoading else { return }
      let normalizedLayout = Self.normalizedEnhancedAudioEQLayout(selectedEnhancedAudioEQLayout)
      if selectedEnhancedAudioEQLayout != normalizedLayout {
        selectedEnhancedAudioEQLayout = normalizedLayout
        return
      }

      let remapped = Self.remappedEnhancedAudioEQGains(
        enhancedAudioEQGains,
        from: oldValue,
        to: selectedEnhancedAudioEQLayout)
      if remapped != enhancedAudioEQGains {
        enhancedAudioEQGains = remapped
      }
      saveSettings()
    }
  }
  @Published var enhancedAudioSpatialIntensity: CGFloat {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var enhancedAudioSoundstageWidth: CGFloat {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var enhancedAudioReverbAmount: CGFloat {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var enhancedAudioEQGains: [Double] {
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
  @Published var selectedDisplaySyncMode: String {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var selectedFrameQueueTarget: String {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var selectedResponsivenessBias: String {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var selectedAllowDrawableTimeoutMode: String {
    didSet {
      guard !isLoading else { return }
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
  @Published var selectedKeyboardCompatibilityMode: String {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var keyboardTranslationRules: [KeyboardTranslationRule] {
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
      postStreamShortcutsChanged()
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
  @Published var selectedFrameInterpolationMode: String {
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
  @Published var availableSunshineDisplays: [SunshineDisplayOption]
  @Published var isLoadingSunshineDisplays: Bool
  @Published var videoCapabilityMatrix: VideoCapabilityMatrix
  @Published var videoRuntimeStatusSummaryKey: String
  @Published var videoRuntimeStatusDetailKey: String
  @Published var videoEnhancementRuntimeStatusSummaryKey: String
  @Published var videoEnhancementRuntimeStatusDetailKey: String
  @Published var videoFrameInterpolationRuntimeStatusSummaryKey: String
  @Published var videoFrameInterpolationRuntimeStatusDetailKey: String

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

  var sunshineDisplayPickerOptions: [SunshineDisplayOption] {
    var options: [SunshineDisplayOption] = [
      SunshineDisplayOption(
        id: "__host_default__",
        value: Self.defaultSunshineTargetDisplayName,
        title: LanguageManager.shared.localize("Host Default"))
    ]

    for option in availableSunshineDisplays {
      if option.value.isEmpty {
        continue
      }
      if !options.contains(where: { $0.value == option.value }) {
        options.append(option)
      }
    }

    let trimmedSelection = sunshineTargetDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedSelection.isEmpty && !options.contains(where: { $0.value == trimmedSelection }) {
      options.append(
        SunshineDisplayOption(id: "__saved_\(trimmedSelection)", value: trimmedSelection, title: trimmedSelection))
    }

    return options
  }

  private static func sunshineDisplayLabel(from rawEntry: [String: Any]) -> String {
    let deviceId = rawEntry["device_id"] as? String ?? ""
    let friendlyName = rawEntry["friendly_name"] as? String ?? deviceId
    let displayName = rawEntry["display_name"] as? String ?? deviceId

    if !friendlyName.isEmpty &&
      friendlyName != deviceId &&
      friendlyName != displayName
    {
      return "\(friendlyName) (\(deviceId))"
    }

    if !friendlyName.isEmpty {
      return friendlyName
    }

    return deviceId
  }

  private func currentTemporaryHost() -> TemporaryHost? {
    guard let hostId = selectedHost?.id, hostId != Self.globalHostId else { return nil }
    let dataMan = DataManager()
    guard let hosts = dataMan.getHosts() as? [TemporaryHost] else { return nil }
    return hosts.first(where: { !$0.uuid.isEmpty && $0.uuid == hostId })
  }

  func refreshSunshineDisplays(force: Bool = false) {
    guard let host = currentTemporaryHost() else {
      if !availableSunshineDisplays.isEmpty || isLoadingSunshineDisplays {
        availableSunshineDisplays = []
        isLoadingSunshineDisplays = false
      }
      loadedSunshineDisplaysHostId = nil
      return
    }

    let address =
      host.activeAddress ?? host.localAddress ?? host.address ?? host.externalAddress
      ?? host.ipv6Address
    guard let address, !address.isEmpty, host.serverCert != nil else {
      availableSunshineDisplays = []
      isLoadingSunshineDisplays = false
      loadedSunshineDisplaysHostId = nil
      return
    }

    if !force && loadedSunshineDisplaysHostId == host.uuid && !availableSunshineDisplays.isEmpty {
      return
    }
    if isLoadingSunshineDisplays && !force {
      return
    }

    sunshineDisplayFetchGeneration += 1
    let fetchGeneration = sunshineDisplayFetchGeneration
    let hostId = host.uuid
    let serverCert = host.serverCert
    isLoadingSunshineDisplays = true

    DispatchQueue.global(qos: .userInitiated).async {
      let httpManager = HttpManager(
        host: address,
        uniqueId: IdManager.getUniqueId(),
        serverCert: serverCert)
      let rawEntries = (httpManager?.fetchSunshineDisplays() as? [[String: Any]]) ?? []
      let resolvedOptions = rawEntries.compactMap { entry -> SunshineDisplayOption? in
        let deviceId = entry["device_id"] as? String ?? ""
        guard !deviceId.isEmpty else { return nil }
        return SunshineDisplayOption(
          id: deviceId,
          value: deviceId,
          title: Self.sunshineDisplayLabel(from: entry))
      }

      DispatchQueue.main.async {
        guard self.sunshineDisplayFetchGeneration == fetchGeneration else { return }
        guard self.selectedHost?.id == hostId else { return }
        self.availableSunshineDisplays = resolvedOptions
        self.isLoadingSunshineDisplays = false
        self.loadedSunshineDisplaysHostId = hostId
      }
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
    selectedHdrTransferFunction = Self.defaultHdrTransferFunction
    sunshineTargetDisplayName = Self.defaultSunshineTargetDisplayName
    sunshineUseVirtualDisplay = Self.defaultSunshineUseVirtualDisplay
    selectedSunshineScreenMode = Self.defaultSunshineScreenMode
    sunshineHdrBrightnessOverride = Self.defaultSunshineHdrBrightnessOverride
    sunshineMaxBrightness = Self.defaultSunshineMaxBrightness
    sunshineMinBrightness = Self.defaultSunshineMinBrightness
    sunshineMaxAverageBrightness = Self.defaultSunshineMaxAverageBrightness
    selectedHdrMetadataSource = Self.defaultHdrMetadataSource
    selectedHdrClientDisplayProfile = Self.defaultHdrClientDisplayProfile
    hdrManualMaxBrightness = Self.defaultHdrManualMaxBrightness
    hdrManualMinBrightness = Self.defaultHdrManualMinBrightness
    hdrManualMaxAverageBrightness = Self.defaultHdrManualMaxAverageBrightness
    hdrOpticalOutputScale = Self.defaultHdrOpticalOutputScale
    selectedHdrHlgViewingEnvironment = Self.defaultHdrHlgViewingEnvironment
    selectedHdrEdrStrategy = Self.defaultHdrEdrStrategy
    selectedHdrToneMappingPolicy = Self.defaultHdrToneMappingPolicy

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

    selectedVideoRendererMode = Self.defaultVideoRendererMode
    selectedVideoCodec = Self.defaultVideoCodec
    hdr = Self.defaultHdr
    selectedPacingOptions = Self.defaultPacingOptions
    selectedSmoothnessLatencyMode = Self.defaultSmoothnessLatencyMode
    selectedDisplaySyncMode = Self.defaultDisplaySyncMode
    selectedFrameQueueTarget = Self.defaultFrameQueueTarget
    selectedResponsivenessBias = Self.defaultResponsivenessBias
    selectedAllowDrawableTimeoutMode = Self.defaultAllowDrawableTimeoutMode

    audioOnPC = Self.defaultAudioOnPC
    selectedAudioConfiguration = Self.defaultAudioConfiguration
    selectedAudioOutputMode = Self.defaultAudioOutputMode
    selectedEnhancedAudioOutputTarget = Self.defaultEnhancedAudioOutputTarget
    selectedEnhancedAudioPreset = Self.defaultEnhancedAudioPreset
    selectedEnhancedAudioEQLayout = Self.defaultEnhancedAudioEQLayout
    enhancedAudioSpatialIntensity = Self.defaultEnhancedAudioSpatialIntensity
    enhancedAudioSoundstageWidth = Self.defaultEnhancedAudioSoundstageWidth
    enhancedAudioReverbAmount = Self.defaultEnhancedAudioReverbAmount
    enhancedAudioEQGains = Self.defaultEnhancedAudioEQGains
    enableVsync = Self.defaultEnableVsync
    selectedTimingBufferLevel = Self.defaultTimingBufferLevel
    timingPrioritizeResponsiveness = Self.defaultTimingPrioritizeResponsiveness
    timingCompatibilityMode = Self.defaultTimingCompatibilityMode
    timingSdrCompatibilityWorkaround = Self.defaultTimingSdrCompatibilityWorkaround
    showPerformanceOverlay = Self.defaultShowPerformanceOverlay
    showConnectionWarnings = Self.defaultShowConnectionWarnings
    captureSystemShortcuts = Self.defaultCaptureSystemShortcuts
    selectedKeyboardCompatibilityMode = Self.defaultKeyboardCompatibilityMode
    keyboardTranslationRules = KeyboardTranslationProfile.defaultRules()
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
    selectedUpscalingMode = Self.upscalingModeTitle(for: Self.defaultUpscalingMode)
    selectedFrameInterpolationMode = Self.frameInterpolationModeSelection(
      for: Self.defaultFrameInterpolationMode)
    selectedConnectionMethod = "Auto"
    availableSunshineDisplays = []
    isLoadingSunshineDisplays = false
    videoCapabilityMatrix = Self.currentVideoCapabilityMatrix()
    videoRuntimeStatusSummaryKey = "Video Runtime Path Idle"
    videoRuntimeStatusDetailKey = "Video Runtime Detail Idle"
    videoEnhancementRuntimeStatusSummaryKey = "Off"
    videoEnhancementRuntimeStatusDetailKey = "Video Enhancement Runtime Detail Idle"
    videoFrameInterpolationRuntimeStatusSummaryKey = "Off"
    videoFrameInterpolationRuntimeStatusDetailKey = "Video Frame Interpolation Runtime Detail Idle"

    NotificationCenter.default.addObserver(
      self, selector: #selector(handleHostLatencyUpdate),
      name: NSNotification.Name("HostLatencyUpdated"), object: nil)

    NotificationCenter.default.addObserver(
      self, selector: #selector(handleEndpointUpdate),
      name: NSNotification.Name("ConnectionEndpointsUpdated"), object: nil)

    NotificationCenter.default.addObserver(
      self, selector: #selector(handleConnectionMethodUpdate),
      name: NSNotification.Name("ConnectionMethodUpdated"), object: nil)

    NotificationCenter.default.addObserver(
      self, selector: #selector(handleScreenParametersUpdate),
      name: NSApplication.didChangeScreenParametersNotification, object: nil)

    NotificationCenter.default.addObserver(
      self, selector: #selector(handleVideoRuntimeStatusUpdate),
      name: .moonlightVideoRuntimeStatusDidChange, object: nil)

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

    refreshVideoDiagnosticsState()
    refreshSunshineDisplays(force: false)
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

  @objc func handleScreenParametersUpdate(_ notification: Notification) {
    DispatchQueue.main.async {
      self.refreshVideoCapabilityMatrix()
    }
  }

  @objc func handleVideoRuntimeStatusUpdate(_ notification: Notification) {
    let hostKey = notification.userInfo?["hostKey"] as? String
    let selectedHostId = selectedHost?.id ?? Self.globalHostId
    guard hostKey == nil || hostKey == selectedHostId || hostKey == Self.globalHostId else {
      return
    }

    DispatchQueue.main.async {
      self.refreshVideoRuntimeStatus()
    }
  }

  func refreshVideoDiagnosticsState() {
    refreshVideoCapabilityMatrix()
    refreshVideoRuntimeStatus()
  }

  func refreshVideoCapabilityMatrix() {
    let updated = Self.currentVideoCapabilityMatrix()
    if updated != videoCapabilityMatrix {
      videoCapabilityMatrix = updated
    }
  }

  func refreshVideoRuntimeStatus() {
    let hostId = selectedHost?.id ?? Self.globalHostId
    videoRuntimeStatusSummaryKey = SettingsClass.videoRuntimeStatusSummaryKey(for: hostId)
    videoRuntimeStatusDetailKey = SettingsClass.videoRuntimeStatusDetailKey(for: hostId)
    videoEnhancementRuntimeStatusSummaryKey = SettingsClass.videoEnhancementRuntimeStatusSummaryKey(
      for: hostId)
    videoEnhancementRuntimeStatusDetailKey = SettingsClass.videoEnhancementRuntimeStatusDetailKey(
      for: hostId)
    videoFrameInterpolationRuntimeStatusSummaryKey =
      SettingsClass.videoFrameInterpolationRuntimeStatusSummaryKey(for: hostId)
    videoFrameInterpolationRuntimeStatusDetailKey =
      SettingsClass.videoFrameInterpolationRuntimeStatusDetailKey(for: hostId)
  }

  func applyEnhancedAudioPresetIfNeeded() {
    let values = Self.enhancedAudioPresetValues(
      for: selectedEnhancedAudioPreset,
      layout: selectedEnhancedAudioEQLayout)
    isApplyingEnhancedAudioPreset = true
    enhancedAudioSpatialIntensity = values.spatialIntensity
    enhancedAudioSoundstageWidth = values.soundstageWidth
    enhancedAudioReverbAmount = values.reverbAmount
    enhancedAudioEQGains = values.eqGains
    isApplyingEnhancedAudioPreset = false
  }

  func setEnhancedAudioEQGain(_ value: Double, at index: Int) {
    guard enhancedAudioEQGains.indices.contains(index) else { return }
    var updated = enhancedAudioEQGains
    updated[index] = value
    enhancedAudioEQGains = updated
  }
}
