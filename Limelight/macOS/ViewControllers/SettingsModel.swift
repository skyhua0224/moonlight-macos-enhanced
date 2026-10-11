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

enum SunshineDisplayCapabilityState: Equatable {
  case unknown
  case loading
  case available
  case unavailable

  var titleKey: String {
    switch self {
    case .unknown: return "Display Capability Unknown"
    case .loading: return "Display Capability Loading"
    case .available: return "Display Topology Available"
    case .unavailable: return "Display Topology Unavailable"
    }
  }

  var systemImage: String {
    switch self {
    case .unknown: return "questionmark.circle"
    case .loading: return "arrow.triangle.2.circlepath"
    case .available: return "checkmark.circle.fill"
    case .unavailable: return "exclamationmark.triangle.fill"
    }
  }

  var tint: Color {
    switch self {
    case .unknown, .loading: return .secondary
    case .available: return .green
    case .unavailable: return .orange
    }
  }
}

enum SunshineVddState: String, Equatable {
  case ready
  case driverMissing = "driver_missing"
  case driverUnreachable = "driver_unreachable"
  case unsupportedPlatform = "unsupported_platform"
  case unknown

  init(wireValue: String?) {
    self = Self(rawValue: wireValue ?? "") ?? .unknown
  }

  var titleKey: String {
    switch self {
    case .ready: return "VDD Ready"
    case .driverMissing: return "VDD Driver Missing"
    case .driverUnreachable: return "VDD Driver Unreachable"
    case .unsupportedPlatform: return "VDD Unsupported Platform"
    case .unknown: return "VDD State Unknown"
    }
  }

  var tint: Color {
    switch self {
    case .ready: return .green
    case .driverMissing, .driverUnreachable, .unknown: return .orange
    case .unsupportedPlatform: return .secondary
    }
  }
}

struct SunshineDisplayOption: Identifiable, Equatable {
  let id: String
  let value: String
  let title: String
  let displayName: String
  let friendlyName: String
  let index: Int
  let isPrimary: Bool
  let currentScalePercent: Int?
  let recommendedScalePercent: Int?
  let supportedScalePercents: [Int]
  let scaleSetSupported: Bool

  init(id: String,
       value: String,
       title: String,
       displayName: String,
       friendlyName: String,
       index: Int,
       isPrimary: Bool = false,
       currentScalePercent: Int? = nil,
       recommendedScalePercent: Int? = nil,
       supportedScalePercents: [Int] = [],
       scaleSetSupported: Bool = false) {
    self.id = id
    self.value = value
    self.title = title
    self.displayName = displayName
    self.friendlyName = friendlyName
    self.index = index
    self.isPrimary = isPrimary
    self.currentScalePercent = currentScalePercent
    self.recommendedScalePercent = recommendedScalePercent
    self.supportedScalePercents = supportedScalePercents
    self.scaleSetSupported = scaleSetSupported
  }
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

  var systemImage: String {
    switch self {
    case .available: return "checkmark.circle.fill"
    case .limited: return "minus.circle.fill"
    case .unavailable: return "xmark.circle.fill"
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
  static let controllerNativeTouchpadKeyPrefix = "settings.controller.nativeTouchpad."
  static let controllerDualSensePrecisionTouchpadKeyPrefix = "settings.controller.dualSensePrecisionTouchpad."
  static let controllerDeadzoneKeyPrefix = "settings.controller.deadzone."
  static let controllerHapticsModeKeyPrefix = "settings.controller.hapticsMode."
  static let controllerMotionModeKeyPrefix = "settings.controller.motionMode."
  static let controllerFeedbackTargetKeyPrefix = "settings.controller.feedbackTarget."
  static let controllerVirtualTypeKeyPrefix = "settings.controller.virtualType."
  static let controllerCalibrationKeyPrefix = "settings.controller.calibration."
  static let keyMappingModeKeyPrefix = "settings.keyboard.keyMappingMode."
  static let controllerShortcutProfileKeyPrefix = "settings.controller.shortcuts."
  static let audioCodecKeyPrefix = "settings.audio.codec."
  static let audioCodecFailureKeyPrefix = "settings.audio.codecFailure."
  static let surround714UnavailableKeyPrefix = "settings.audio.surround714Unavailable."
  static let continuousAudioKeyPrefix = "settings.audio.continuous."
  static let dolbyOutputKeyPrefix = "settings.audio.dolbyOutput."
  static let foundationHostKeyPrefix = "settings.sunshine.foundationHost."
  static let audioCodecFailureChangedNotification = Notification.Name("MoonlightAudioCodecFailureDidChange")
  static let sunshineVddCapabilityKeyPrefix = "settings.sunshine.vddCapability."
  static let sunshineVddStateKeyPrefix = "settings.sunshine.vddState."
  static let mouseSettingsChangedNotification = Notification.Name("MoonlightMouseSettingsDidChange")
  static let controllerSettingsChangedNotification =
    Notification.Name("MoonlightControllerSettingsDidChange")
  static let streamShortcutsChangedNotification = Notification.Name("MoonlightStreamShortcutsDidChange")
  static let matchDisplayResolutionSentinel = CGSize(width: -1, height: -1)
  // The five keys up to debugLogTimeScopeKey are legacy: before the recording and viewing options
  // were separated they held both the logger's settings and the log window's filters. They are
  // no longer written; they are only read to seed the recording detail and the log viewer's own
  // preferences.
  static let debugLogModeKey = "debugLog.mode"
  static let debugLogMinLevelKey = "debugLog.minLevel"
  static let debugLogShowSystemNoiseKey = "debugLog.showSystemNoise"
  static let debugLogAutoScrollKey = "debugLog.autoScroll"
  static let debugLogTimeScopeKey = "debugLog.timeScope"
  /// What the logger records ("normal" or "detailed").
  static let debugLogRecordingDetailKey = "debugLog.recordingDetail"
  static let debugLogInputDiagnosticsKey = "debugLog.inputDiagnostics"
  static let awdlStabilityHelperEnabledKey = "networkCompatibility.awdlHelperEnabled"
  static let awdlStabilityHelperAcknowledgedKey = "networkCompatibility.awdlHelperAcknowledged"

  static func keyboardTranslationRulesStorageKey(for hostId: String) -> String {
    "\(hostId)-moonlightKeyboardTranslationRules"
  }

  var latencyCache: [String: [String: Any]] = [:]
  var selectedProfileObserver: NSObjectProtocol?
  var settingsWindowObserver: NSObjectProtocol?
  // Settings.storeGeneration when this model last read or wrote its profile.
  var seenStoreGeneration = -1
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

  /// Posts a controller-setting change for the selected host or the global profile.
  ///
  /// Observers are invoked synchronously on the posting thread unless they specify a queue.
  /// Call from main-thread settings mutations; this method does not save the setting.
  /// - Parameter setting: Changed setting identifier included with `hostId` in the notification.
  private func postControllerSettingsChanged(_ setting: String) {
    let hostId = selectedHost?.id ?? Self.globalHostId
    NotificationCenter.default.post(
      name: Self.controllerSettingsChangedNotification,
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
    willSet {
      // A change that is still waiting to be written belongs to the profile being left.
      flushPendingEnhancedAudioSave()
    }
    didSet {
      guard !isLoading else { return }
      UserDefaults.standard.set(selectedHost?.id, forKey: "selectedSettingsProfile")
      loadSettings()
      refreshVideoDiagnosticsState()
      refreshSunshineDisplays(force: false)
    }
  }

  /// What the logger records: "normal" (Info and above) or "detailed" (also Debug).
  /// What the log viewer shows is a separate matter (see DebugLogViewerPreferences).
  @Published var debugLogRecordingDetail: String {
    didSet {
      UserDefaults.standard.set(debugLogRecordingDetail, forKey: Self.debugLogRecordingDetailKey)
      LoggerSetMinimumLevel(Self.loggerLevel(forRecordingDetail: debugLogRecordingDetail))
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
  /// True while the model announces something that is not an edit of the settings: a
  /// measurement, the state of a stream. The settings window keeps its pages through those.
  private(set) var isAnnouncingStatus = false

  func announceStatus(_ change: () -> Void) {
    let was = isAnnouncingStatus
    isAnnouncingStatus = true
    change()
    isAnnouncingStatus = was
  }
  var isAdjustingBitrate = false
  var isApplyingSmoothnessLatencyPreset = false
  var isSyncingSmoothnessLatencyMode = false
  var isApplyingEnhancedAudioPreset = false
  // Audio enhancement changes come in bursts (a drag, a preset that sets five values): they are
  // written and announced together. See saveEnhancedAudioSettings().
  var enhancedAudioSavePending = false
  var lastEnhancedAudioSave = DispatchTime(uptimeNanoseconds: 0)
  // The fixed bands and the custom bands each have a preamp; this is the one of the kind that
  // is not showing.
  var enhancedAudioEQInactivePreamp: CGFloat = 0
  // EnhancedAudioExtras.eqInSync, and set while the model itself rewrites one set of bands
  // from the other (which is not an edit).
  var enhancedAudioEQInSync = false
  var isSyncingEnhancedAudioEQ = false
  // The equalizer as it was before a preset was applied, for Remove. Not kept across launches.
  var enhancedAudioEQBeforePreset: EnhancedAudioEQSnapshot?
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
  @Published var sunshineTouchKeyboardAutoInvoke: Bool {
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
  @Published var selectedDynamicHdrPreference: String {
    didSet {
      guard !isLoading else { return }
      applyAutoBitrateIfNeeded(force: true)
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

  @Published var enableAdaptiveBitrate: Bool {
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
      refreshVideoCapabilityMatrix()
      saveSettings()
    }
  }
  @Published var bitrateSliderValue: Float {
    didSet {
      guard !isLoading, !isAdjustingBitrate else { return }
      let steps = Self.bitrateSteps(unlocked: unlockMaxBitrate)
      let index = max(0, min(Int(bitrateSliderValue.rounded()), steps.count - 1))
      isAdjustingBitrate = true
      customBitrate = Int(steps[index] * 1000)
      isAdjustingBitrate = false
      saveSettings()
    }
  }
  @Published var customBitrate: Int? {
    didSet {
      guard !isLoading, !isAdjustingBitrate else { return }
      if let kbps = customBitrate {
        let clamped = Self.clampedBitrateKbps(kbps, unlocked: unlockMaxBitrate)
        isAdjustingBitrate = true
        customBitrate = clamped
        bitrateSliderValue = Float(Self.bitrateIndex(forKbps: clamped, unlocked: unlockMaxBitrate))
        isAdjustingBitrate = false
      }
      saveSettings()
    }
  }
  @Published var unlockMaxBitrate: Bool {
    didSet {
      guard !isLoading else { return }
      // Preserve the actual bitrate, not the slider index, when changing scale.
      let clamped = Self.clampedBitrateKbps(effectiveBitrateKbps, unlocked: unlockMaxBitrate)
      isAdjustingBitrate = true
      customBitrate = clamped
      bitrateSliderValue = Float(Self.bitrateIndex(forKbps: clamped, unlocked: unlockMaxBitrate))
      isAdjustingBitrate = false
      applyAutoBitrateIfNeeded()
      saveSettings()
    }
  }
  @Published var selectedVideoCodec: String {
    didSet {
      guard !isLoading else { return }
      applyAutoBitrateIfNeeded(force: true)
      saveSettings()
    }
  }
  @Published var hdr: Bool {
    didSet {
      guard !isLoading else { return }
      applyAutoBitrateIfNeeded(force: true)
      saveSettings()
    }
  }
  @Published var enable10BitSdr: Bool {
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
      // Choosing a layout again is the way to retry 7.1.4 on a host that had no audio for it.
      SettingsClass.clearSurround714Unavailable(for: selectedHost?.id ?? Self.globalHostId)
      if surround714Unavailable { surround714Unavailable = false }
    }
  }
  // Per-host audio transport settings. Stored in UserDefaults next to the
  // controller settings (host key with a global fallback), not in Core Data.
  @Published var selectedAudioCodec: String = SettingsModel.defaultAudioCodec {
    didSet {
      guard !isLoading, oldValue != selectedAudioCodec else { return }
      persistAudioCodecSettings()
      // Choosing a codec again is the way to retry one the host rejected.
      clearAudioCodecFailures()
    }
  }
  // Ask the host to keep sending silence while nothing plays.
  @Published var continuousAudio: Bool = SettingsModel.defaultContinuousAudio {
    didSet {
      guard !isLoading else { return }
      persistAudioCodecSettings()
    }
  }
  // Whether AC3 / E-AC3 may go to the output device untouched when it accepts them.
  @Published var selectedDolbyOutput: String = SettingsModel.defaultDolbyOutput {
    didSet {
      guard !isLoading, oldValue != selectedDolbyOutput else { return }
      persistAudioCodecSettings()
    }
  }
  // Codec ids (AUDIO_CODEC_*) this host failed to deliver in an earlier session.
  @Published var audioCodecFailedIds: [Int] = []
  /// An earlier stream got no audio for 7.1.4 from this host; streams use 7.1 meanwhile.
  @Published var surround714Unavailable = false
  @Published var audioHostIsFoundation: Bool? = nil
  @Published var selectedAudioOutputMode: String {
    didSet {
      guard !isLoading else { return }
      saveSettings()
    }
  }
  @Published var selectedEnhancedAudioOutputTarget: String {
    didSet {
      guard !isLoading else { return }
      saveEnhancedAudioSettings()
    }
  }
  @Published var selectedEnhancedAudioPreset: String {
    didSet {
      guard !isLoading, !isApplyingEnhancedAudioPreset else { return }
      applyEnhancedAudioPresetIfNeeded()
      saveEnhancedAudioSettings()
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

      // The same curve on the other set of bands: fitted, not read off band by band.
      if oldValue != selectedEnhancedAudioEQLayout, !isSyncingEnhancedAudioEQ {
        let before = EnhancedAudioEQ.graphicFilters(
          frequencies: Self.enhancedAudioEQFrequencies(for: oldValue), gains: enhancedAudioEQGains)
        let wasInSync = enhancedAudioEQInSync
        isSyncingEnhancedAudioEQ = true
        enhancedAudioEQGains = EnhancedAudioEQ.fittedGraphicGains(
          frequencies: Self.enhancedAudioEQFrequencies(for: selectedEnhancedAudioEQLayout),
          following: before)
        isSyncingEnhancedAudioEQ = false
        enhancedAudioEQInSync = wasInSync
      }
      saveEnhancedAudioSettings()
    }
  }
  @Published var enhancedAudioSpatialIntensity: CGFloat {
    didSet {
      guard !isLoading else { return }
      saveEnhancedAudioSettings()
    }
  }
  @Published var enhancedAudioSoundstageWidth: CGFloat {
    didSet {
      guard !isLoading else { return }
      saveEnhancedAudioSettings()
    }
  }
  @Published var enhancedAudioReverbAmount: CGFloat {
    didSet {
      guard !isLoading else { return }
      saveEnhancedAudioSettings()
    }
  }
  @Published var enhancedAudioEQGains: [Double] {
    didSet {
      guard !isLoading else { return }
      // Edited by hand: the custom bands no longer describe this curve.
      if !isSyncingEnhancedAudioEQ, oldValue != enhancedAudioEQGains { enhancedAudioEQInSync = false }
      saveEnhancedAudioSettings()
    }
  }
  @Published var selectedEnhancedAudioSpatialMode: String = EnhancedAudioSpatialMode.automatic.title {
    didSet {
      guard !isLoading, oldValue != selectedEnhancedAudioSpatialMode else { return }
      saveEnhancedAudioSettings()
    }
  }
  @Published var enhancedAudioEQEnabled: Bool = true {
    didSet {
      guard !isLoading, oldValue != enhancedAudioEQEnabled else { return }
      saveEnhancedAudioSettings()
    }
  }
  // "Graphic" keeps the fixed bands above; "Parametric" uses enhancedAudioEQBands.
  @Published var selectedEnhancedAudioEQMode: String = EnhancedAudioEQ.Mode.graphic.title {
    didSet {
      guard !isLoading, oldValue != selectedEnhancedAudioEQMode else { return }
      // The two change places. Not a change of level: the preamp must not take the other
      // one along here, or both end up the same.
      let wasSyncing = isSyncingEnhancedAudioEQ
      isSyncingEnhancedAudioEQ = true
      let otherPreamp = enhancedAudioEQInactivePreamp
      enhancedAudioEQInactivePreamp = enhancedAudioEQPreamp
      enhancedAudioEQPreamp = otherPreamp
      isSyncingEnhancedAudioEQ = wasSyncing
      // One curve, three ways to edit it. Unless both sets of bands already describe it, the
      // one being switched to is made from the one being left: custom bands are the fixed
      // ones as they are, fixed bands are fitted to the custom curve. The preamps follow,
      // with the trim the fixed bands take off themselves.
      if !isSyncingEnhancedAudioEQ, !enhancedAudioEQInSync {
        let frequencies = Self.enhancedAudioEQFrequencies(for: selectedEnhancedAudioEQLayout)
        isSyncingEnhancedAudioEQ = true
        if EnhancedAudioEQ.Mode(title: selectedEnhancedAudioEQMode) == .parametric {
          let fixed = EnhancedAudioEQ.graphicFilters(
            frequencies: frequencies, gains: enhancedAudioEQGains)
          enhancedAudioEQBands = fixed.map {
            EnhancedAudioEQBand(
              kind: .peak, frequency: $0.frequency, gain: $0.gain,
              q: ($0.q * 100).rounded() / 100)
          }
          enhancedAudioEQPreamp =
            enhancedAudioEQInactivePreamp
            - CGFloat(EnhancedAudioEQ.graphicTrim(enhancedAudioEQGains))
          enhancedAudioEQProfileName = nil
        } else {
          let fitted = EnhancedAudioEQ.fittedGraphicGains(
            frequencies: frequencies,
            following: EnhancedAudioEQ.parametricFilters(enhancedAudioEQBands))
          enhancedAudioEQGains = fitted
          enhancedAudioEQPreamp =
            enhancedAudioEQInactivePreamp + CGFloat(EnhancedAudioEQ.graphicTrim(fitted))
        }
        isSyncingEnhancedAudioEQ = false
        enhancedAudioEQInSync = true
      }
      saveEnhancedAudioSettings()
    }
  }
  @Published var enhancedAudioEQPreamp: CGFloat = 0 {
    didSet {
      guard !isLoading, oldValue != enhancedAudioEQPreamp else { return }
      // The same curve on the other kind of bands is turned up or down with it.
      if enhancedAudioEQInSync, !isSyncingEnhancedAudioEQ {
        enhancedAudioEQInactivePreamp += enhancedAudioEQPreamp - oldValue
      }
      saveEnhancedAudioSettings()
    }
  }
  @Published var enhancedAudioEQBands: [EnhancedAudioEQBand] = [] {
    didSet {
      guard !isLoading, oldValue != enhancedAudioEQBands else { return }
      // Edited by hand: the fixed bands no longer describe this curve.
      if !isSyncingEnhancedAudioEQ { enhancedAudioEQInSync = false }
      saveEnhancedAudioSettings()
    }
  }
  // Name of the correction the bands came from; kept until they are reset or replaced.
  @Published var enhancedAudioEQProfileName: String? = nil {
    didSet {
      guard !isLoading, oldValue != enhancedAudioEQProfileName else { return }
      saveEnhancedAudioSettings()
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
  @Published var selectedVideoFecPercentage: String {
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
  @Published var selectedKeyMappingMode: String {
    didSet {
      guard !isLoading else { return }
      persistKeyMappingMode()
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
  /// Allows controller input while unfocused; edits save and notify the selected profile.
  /// Loading a profile suppresses these side effects. Mutate on the main thread.
  @Published var backgroundControllerInput: Bool {
    didSet {
      guard !isLoading else { return }
      saveSettings()
      postControllerSettingsChanged("backgroundControllerInput")
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
      postMouseSettingsChanged("reverseScrollDirection")
    }
  }
  @Published var pointerSensitivity: CGFloat {
    didSet {
      guard !isLoading else { return }
      saveSettings()
      postMouseSettingsChanged("pointerSensitivity")
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
      postMouseSettingsChanged("gestureScrollSpeed")
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
      postMouseSettingsChanged("gamepadMouseMode")
    }
  }
  @Published var nativeTouchpad: Bool {
    didSet {
      guard !isLoading else { return }
      let hostId = selectedHost?.id ?? Self.globalHostId
      UserDefaults.standard.set(
        nativeTouchpad,
        forKey: Self.controllerNativeTouchpadKeyPrefix + hostId)
      NotificationCenter.default.post(name: Notification.Name("ControllerTouchpadModeDidChange"), object: nil,
        userInfo: ["hostId": hostId, "native": nativeTouchpad])
    }
  }
  // Send the DualSense touchpad to the host as a Windows precision touchpad instead of controller touch input.
  @Published var dualSensePrecisionTouchpad: Bool {
    didSet {
      guard !isLoading else { return }
      let hostId = selectedHost?.id ?? Self.globalHostId
      UserDefaults.standard.set(
        dualSensePrecisionTouchpad,
        forKey: Self.controllerDualSensePrecisionTouchpadKeyPrefix + hostId)
      NotificationCenter.default.post(name: Notification.Name("ControllerDualSensePrecisionTouchpadDidChange"), object: nil,
        userInfo: ["hostId": hostId, "precision": dualSensePrecisionTouchpad])
    }
  }
  @Published var controllerDeadzone: Double {
    didSet {
      guard !isLoading else { return }
      persistControllerSettings()
    }
  }
  @Published var controllerShortcuts: ControllerShortcutProfile = .defaults() {
    didSet {
      guard !isLoading else { return }
      persistControllerSettings()
      postMouseSettingsChanged("controllerShortcuts")
    }
  }
  @Published var selectedControllerHapticsMode: String {
    didSet {
      guard !isLoading else { return }
      persistControllerSettings()
    }
  }
  @Published var selectedControllerMotionMode: String {
    didSet {
      guard !isLoading else { return }
      persistControllerSettings()
    }
  }
  @Published var selectedControllerFeedbackTarget: String {
    didSet {
      guard !isLoading else { return }
      persistControllerSettings()
    }
  }
  @Published var selectedControllerVirtualType: String {
    didSet {
      guard !isLoading else { return }
      persistControllerSettings()
    }
  }
  @Published var controllerCalibration: ControllerCalibration {
    didSet {
      guard !isLoading else { return }
      persistControllerSettings()
    }
  }
  @Published var gamepadMouseModeLongPressMenu: Bool {
    didSet {
      guard !isLoading else { return }
      saveSettings()
      postMouseSettingsChanged("gamepadMouseModeLongPressMenu")
    }
  }
  // Send the trackpad's raw multi-finger contacts so Windows sees a precision touchpad.
  // 0 off, 1 touchpad only (blocks the Mac pointer path), 2 both.
  @Published var hostPrecisionTouchpadMode: Int {
    didSet {
      guard !isLoading else { return }
      saveSettings()
      postMouseSettingsChanged("hostPrecisionTouchpadMode")
    }
  }
  // Compose text with the Mac input method and send the committed text as UTF-8.
  @Published var imeTextInput: Bool {
    didSet {
      guard !isLoading else { return }
      saveSettings()
      postMouseSettingsChanged("imeTextInput")
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
  @Published var selectedClipboardSyncMode: String {
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
  @Published var sunshineDisplayCapabilityState: SunshineDisplayCapabilityState
  @Published var sunshineDisplayCapabilityMessage: String
  @Published var sunshineVddCapabilityVersion: Int?
  @Published var sunshineVddState: SunshineVddState
  @Published var sunshineDisplayCount: Int
  @Published var sunshineDisplayRuntimeStateKey: String
  @Published var sunshineDisplayRuntimeDetail: String
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
        title: LanguageManager.shared.localize("Host Default"),
        displayName: "",
        friendlyName: "",
        index: -1)
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
        SunshineDisplayOption(
          id: "__saved_\(trimmedSelection)",
          value: trimmedSelection,
          title: trimmedSelection,
          displayName: trimmedSelection,
          friendlyName: trimmedSelection,
          index: -1))
    }

    return options
  }

  var sunshineVddSupportsSelection: Bool {
    // VDD is a host capability. Keep the control disabled until the current
    // Foundation endpoint explicitly reports a usable driver; an unknown or
    // missing response must not look like a selectable feature.
    return sunshineVddState == .ready && (sunshineVddCapabilityVersion ?? 0) > 0
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

  /// Return an endpoint that can answer capability requests. A manually
  /// selected connection method remains the streaming route, but capability
  /// pages may use a reachable alternate endpoint so one broken route does
  /// not make the whole host's topology appear unavailable.
  private func sunshineCapabilityAddress(for host: TemporaryHost) -> String? {
    let endpoints = ConnectionEndpointStore.allEndpoints(for: host)
    let states = host.addressStates ?? [:]
    let ordered = [host.activeAddress].compactMap { $0 } + endpoints

    if let reachable = ordered.first(where: { states[$0]?.intValue == 1 }) {
      return reachable
    }

    return ordered.first(where: { !$0.isEmpty })
  }

  func refreshSunshineDisplays(force: Bool = false) {
    guard let host = currentTemporaryHost() else {
      if !availableSunshineDisplays.isEmpty || isLoadingSunshineDisplays {
        availableSunshineDisplays = []
        isLoadingSunshineDisplays = false
      }
      loadedSunshineDisplaysHostId = nil
      sunshineDisplayCapabilityState = .unavailable
      sunshineDisplayCapabilityMessage = LanguageManager.shared.localize("No Sunshine host selected")
      sunshineVddCapabilityVersion = nil
      sunshineVddState = .unknown
      sunshineDisplayCount = 0
      return
    }

    let address = sunshineCapabilityAddress(for: host)
    guard let address, !address.isEmpty, host.serverCert != nil else {
      availableSunshineDisplays = []
      isLoadingSunshineDisplays = false
      loadedSunshineDisplaysHostId = nil
      sunshineDisplayCapabilityState = .unavailable
      sunshineDisplayCapabilityMessage = LanguageManager.shared.localize("Sunshine display endpoint unavailable")
      sunshineVddCapabilityVersion = nil
      sunshineVddState = .unknown
      sunshineDisplayCount = 0
      return
    }

    if !force && loadedSunshineDisplaysHostId == host.uuid && !availableSunshineDisplays.isEmpty {
      return
    }
    // The host display endpoint may enumerate the Windows topology and VDD
    // driver synchronously. Do not start overlapping requests when the page,
    // host selection, and refresh button arrive together.
    if isLoadingSunshineDisplays {
      return
    }

    sunshineDisplayFetchGeneration += 1
    let fetchGeneration = sunshineDisplayFetchGeneration
    let hostId = host.uuid
    let serverCert = host.serverCert
    isLoadingSunshineDisplays = true
    sunshineDisplayCapabilityState = .loading
    sunshineDisplayCapabilityMessage = LanguageManager.shared.localize("Loading Foundation display topology")

    DispatchQueue.global(qos: .userInitiated).async(execute: DispatchWorkItem {
      let httpManager = HttpManager(
        host: address,
        uniqueId: IdManager.getUniqueId(),
        serverCert: serverCert)
      let snapshot = (httpManager?.fetchSunshineDisplaySnapshot() as? [String: Any]) ?? [:]
      let statusCode = (snapshot["statusCode"] as? NSNumber)?.intValue ?? 0
      let statusMessage = snapshot["statusMessage"] as? String ?? ""
      let count = (snapshot["count"] as? NSNumber)?.intValue ?? 0
      let vdd = snapshot["vdd"] as? [String: Any]
      let vddVersion = (vdd?["capability_version"] as? NSNumber)?.intValue
      let vddState = SunshineVddState(wireValue: vdd?["state"] as? String)
      let rawEntries = (snapshot["displays"] as? [[String: Any]]) ?? []
      let resolvedOptions = rawEntries.compactMap { entry -> SunshineDisplayOption? in
        let deviceId = entry["device_id"] as? String ?? ""
        guard !deviceId.isEmpty else { return nil }
        let displayName = entry["display_name"] as? String ?? ""
        let friendlyName = entry["friendly_name"] as? String ?? deviceId
        let index = (entry["index"] as? NSNumber)?.intValue ?? 0
        let supportedScales = (entry["supported_scale_percents"] as? [NSNumber])?.map(\.intValue) ?? []
        return SunshineDisplayOption(
          id: deviceId,
          value: deviceId,
          title: Self.sunshineDisplayLabel(from: entry),
          displayName: displayName,
          friendlyName: friendlyName,
          index: index,
          isPrimary: (entry["is_primary"] as? NSNumber)?.boolValue ?? false,
          currentScalePercent: (entry["current_scale_percent"] as? NSNumber)?.intValue,
          recommendedScalePercent: (entry["recommended_scale_percent"] as? NSNumber)?.intValue,
          supportedScalePercents: supportedScales,
          scaleSetSupported: (entry["scale_set_supported"] as? NSNumber)?.boolValue ?? false)
      }

      DispatchQueue.main.async {
        guard self.sunshineDisplayFetchGeneration == fetchGeneration else { return }
        guard self.selectedHost?.id == hostId else { return }
        self.availableSunshineDisplays = resolvedOptions
        self.sunshineDisplayCount = max(count, resolvedOptions.count)
        self.sunshineVddCapabilityVersion = vddVersion
        self.sunshineVddState = vddState
        if statusCode == 200 {
          UserDefaults.standard.set(
            vddVersion as Any?, forKey: Self.sunshineVddCapabilityKeyPrefix + hostId)
          UserDefaults.standard.set(
            vddState.rawValue, forKey: Self.sunshineVddStateKeyPrefix + hostId)
        }
        self.isLoadingSunshineDisplays = false
        self.loadedSunshineDisplaysHostId = hostId
        self.sunshineDisplayCapabilityState = statusCode == 200 ? .available : .unavailable
        self.sunshineDisplayCapabilityMessage = statusCode == 200
          ? LanguageManager.shared.localize("Foundation display topology endpoint ready")
          : (statusMessage.isEmpty
            ? LanguageManager.shared.localize("Sunshine display endpoint unavailable")
            : statusMessage)
      }
    })
  }

  /// Initializes UI settings, restores the selected profile identity and registers observers.
  ///
  /// Starts published settings from defaults, including disabled background controller input,
  /// applies persisted logging preferences and refreshes diagnostics/display discovery. Persisted
  /// profile values are loaded separately. Construct on main for UI state and observer setup.
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

    debugLogRecordingDetail = Self.storedDebugLogRecordingDetail()
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
    selectedDynamicHdrPreference = Self.defaultDynamicHdrPreference

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
    enableAdaptiveBitrate = Self.defaultEnableAdaptiveBitrate
    streamResolutionScale = Self.defaultStreamResolutionScale
    streamResolutionScaleRatio = Self.defaultStreamResolutionScaleRatio

    selectedVideoRendererMode = Self.defaultVideoRendererMode
    selectedVideoCodec = Self.defaultVideoCodec
    hdr = Self.defaultHdr
    enable10BitSdr = Self.defaultEnable10BitSdr
    selectedPacingOptions = Self.defaultPacingOptions
    selectedSmoothnessLatencyMode = Self.defaultSmoothnessLatencyMode
    selectedDisplaySyncMode = Self.defaultDisplaySyncMode
    selectedFrameQueueTarget = Self.defaultFrameQueueTarget
    selectedVideoFecPercentage = Self.defaultVideoFecPercentage
    selectedResponsivenessBias = Self.defaultResponsivenessBias
    selectedAllowDrawableTimeoutMode = Self.defaultAllowDrawableTimeoutMode

    audioOnPC = Self.defaultAudioOnPC
    selectedAudioConfiguration = Self.defaultAudioConfiguration
    selectedAudioCodec = Self.defaultAudioCodec
    continuousAudio = Self.defaultContinuousAudio
    selectedDolbyOutput = Self.defaultDolbyOutput
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
    selectedKeyMappingMode = Self.defaultKeyMappingMode
    keyboardTranslationRules = KeyboardTranslationProfile.defaultRules()
    volumeLevel = Self.defaultVolumeLevel

    selectedMultiControllerMode = Self.defaultMultiControllerMode
    swapButtons = Self.defaultSwapButtons

    optimize = Self.defaultOptimize

    autoFullscreen = Self.defaultAutoFullscreen
    selectedDisplayMode = Self.getString(from: Self.defaultDisplayMode, in: Self.displayModes)
    rumble = Self.defaultRumble
    backgroundControllerInput = Self.defaultBackgroundControllerInput
    selectedControllerDriver = Self.defaultControllerDriver
    selectedMouseDriver = Self.defaultMouseDriver
    coreHIDMaxMouseReportRate = Self.defaultCoreHIDMaxMouseReportRate
    selectedFreeMouseMotionMode = Self.defaultFreeMouseMotionMode

    quitAppAfterStream = Self.defaultQuitAppAfterStream
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
    nativeTouchpad = true
    dualSensePrecisionTouchpad = false
    controllerDeadzone = Self.defaultControllerDeadzone
    selectedControllerHapticsMode = Self.defaultControllerHapticsMode
    selectedControllerMotionMode = Self.defaultControllerMotionMode
    selectedControllerFeedbackTarget = Self.defaultControllerFeedbackTarget
    selectedControllerVirtualType = Self.defaultControllerVirtualType
    controllerCalibration = .default
    gamepadMouseModeLongPressMenu = Self.defaultGamepadMouseModeLongPressMenu
    hostPrecisionTouchpadMode = Self.defaultHostPrecisionTouchpadMode
    imeTextInput = Self.defaultImeTextInput
    mouseMode = Self.defaultMouseMode
    selectedUpscalingMode = Self.upscalingModeTitle(for: Self.defaultUpscalingMode)
    selectedFrameInterpolationMode = Self.frameInterpolationModeSelection(
      for: Self.defaultFrameInterpolationMode)
    selectedClipboardSyncMode = Self.clipboardSyncModeSelection(
      for: Self.defaultClipboardSyncMode)
    selectedConnectionMethod = "Auto"
    availableSunshineDisplays = []
    isLoadingSunshineDisplays = false
    sunshineDisplayCapabilityState = .unknown
    sunshineDisplayCapabilityMessage = LanguageManager.shared.localize("Display capability has not been queried")
    sunshineTouchKeyboardAutoInvoke = Self.defaultSunshineTouchKeyboardAutoInvoke
    sunshineVddCapabilityVersion = nil
    sunshineVddState = .unknown
    sunshineDisplayCount = 0
    sunshineDisplayRuntimeStateKey = "Sunshine Display Runtime Idle"
    sunshineDisplayRuntimeDetail = ""
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

    NotificationCenter.default.addObserver(
      self, selector: #selector(handleSunshineDisplayRuntimeUpdate),
      name: NSNotification.Name("MoonlightSunshineDisplayRuntimeDidChange"), object: nil)

    Self.applyStoredLoggerSettings()

    selectedProfileObserver = NotificationCenter.default.addObserver(
      forName: Notification.Name("MoonlightSelectedSettingsProfileChanged"),
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let hostId = notification.userInfo?["hostId"] as? String else { return }
      self?.selectHost(id: hostId)
    }

    // The settings window is kept between uses. When it is shown again the profile may have
    // changed in the store (a stream, the control center), so it is read again.
    settingsWindowObserver = NotificationCenter.default.addObserver(
      forName: Notification.Name("MoonlightSettingsWindowWillShow"),
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let self, let hostId = notification.userInfo?["hostId"] as? String else { return }
      self.flushPendingEnhancedAudioSave()
      let before = self.selectedHost?.id
      self.selectHost(id: hostId)
      if self.selectedHost?.id == before, self.seenStoreGeneration != Settings.storeGeneration {
        // Same profile, and something (a stream, the control center) wrote settings while
        // the window was closed: selecting the profile did not load it again.
        self.loadSettings()
        self.refreshVideoDiagnosticsState()
        self.refreshSunshineDisplays(force: false)
      }
    }

    refreshVideoDiagnosticsState()
    refreshSunshineDisplays(force: false)
  }

  deinit {
    if let selectedProfileObserver {
      NotificationCenter.default.removeObserver(selectedProfileObserver)
    }
    if let settingsWindowObserver {
      NotificationCenter.default.removeObserver(settingsWindowObserver)
    }
  }

  @objc func handleHostLatencyUpdate(_ notification: Notification) {
    guard let userInfo = notification.userInfo,
      let uuid = userInfo["uuid"] as? String
    else { return }

    DispatchQueue.main.async {
      self.latencyCache[uuid] = userInfo as? [String: Any]
      if self.selectedHost?.id == uuid {
        self.reloadIfStoreChanged()
        self.announceStatus {
          self.ensureConnectionMethodValid()
          self.objectWillChange.send()
        }
      }
    }
  }

  @objc func handleEndpointUpdate(_ notification: Notification) {
    guard let userInfo = notification.userInfo,
      let uuid = userInfo["uuid"] as? String
    else { return }

    DispatchQueue.main.async {
      if self.selectedHost?.id == uuid {
        self.reloadIfStoreChanged()
        self.announceStatus {
          self.ensureConnectionMethodValid()
          self.objectWillChange.send()
        }
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
        self.reloadIfStoreChanged()
        self.announceStatus {
          self.selectedConnectionMethod = method
          self.ensureConnectionMethodValid()
          self.objectWillChange.send()
        }
      }
    }
  }

  @objc func handleScreenParametersUpdate(_ notification: Notification) {
    DispatchQueue.main.async {
      self.announceStatus { self.refreshVideoCapabilityMatrix() }
    }
  }

  @objc func handleVideoRuntimeStatusUpdate(_ notification: Notification) {
    let hostKey = notification.userInfo?["hostKey"] as? String
    // Posted from a stream's threads too; the model is only read on the main thread.
    DispatchQueue.main.async {
      let selectedHostId = self.selectedHost?.id ?? Self.globalHostId
      guard hostKey == nil || hostKey == selectedHostId || hostKey == Self.globalHostId else {
        return
      }
      self.announceStatus { self.refreshVideoRuntimeStatus() }
    }
  }

  @objc func handleSunshineDisplayRuntimeUpdate(_ notification: Notification) {
    let hostKey = notification.userInfo?["hostKey"] as? String

    let phase = notification.userInfo?["phase"] as? String ?? "idle"
    let displayName = notification.userInfo?["displayName"] as? String ?? ""
    let useVdd = notification.userInfo?["useVdd"] as? Bool ?? false
    let screenMode = notification.userInfo?["screenMode"] as? Int ?? -1
    DispatchQueue.main.async {
      let selectedHostId = self.selectedHost?.id ?? Self.globalHostId
      guard hostKey == nil || hostKey == selectedHostId else { return }
      self.announceStatus {
        switch phase {
        case "active":
          self.sunshineDisplayRuntimeStateKey = "Sunshine Display Runtime Active"
        case "reconnected":
          self.sunshineDisplayRuntimeStateKey = "Sunshine Display Runtime Reconnected"
        case "failed":
          self.sunshineDisplayRuntimeStateKey = "Sunshine Display Runtime Failed"
        default:
          self.sunshineDisplayRuntimeStateKey = "Sunshine Display Runtime Idle"
        }
        self.sunshineDisplayRuntimeDetail = String(
          format: "display=%@ · useVdd=%@ · customScreenMode=%d",
          displayName.isEmpty ? "Host Default" : displayName,
          useVdd ? "true" : "false",
          screenMode)
      }
    }
  }

  func refreshVideoDiagnosticsState() {
    announceStatus {
      refreshVideoCapabilityMatrix()
      refreshVideoRuntimeStatus()
    }
  }

  /// The model outlives the settings window now, and what it holds is written back whole.
  /// Before something other than the user changes it, a profile that the stream or the
  /// control center wrote in the meantime is read again.
  func reloadIfStoreChanged() {
    if seenStoreGeneration != Settings.storeGeneration { loadSettings() }
  }

  func refreshVideoCapabilityMatrix() {
    let updated = Self.currentVideoCapabilityMatrix(rendererSelection: selectedVideoRendererMode)
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
    // A preset is a curve of the fixed bands, so it is what plays from here on. The fixed
    // bands are switched to first, and as they are: switching after the gains were set
    // would fit them to the custom bands again, and the preset would be gone.
    let wasSyncing = isSyncingEnhancedAudioEQ
    isSyncingEnhancedAudioEQ = true
    selectedEnhancedAudioEQMode = EnhancedAudioEQ.Mode.graphic.title
    isSyncingEnhancedAudioEQ = wasSyncing
    enhancedAudioSpatialIntensity = values.spatialIntensity
    enhancedAudioSoundstageWidth = values.soundstageWidth
    enhancedAudioReverbAmount = values.reverbAmount
    enhancedAudioEQGains = values.eqGains
    isApplyingEnhancedAudioPreset = false
  }

  /// Saves, then lets a running stream pick the audio enhancement up again. Changes made in
  /// the same moment are written once, and a continuous one (a drag) at most 25 times a
  /// second: writing a profile is the expensive part of a change.
  func saveEnhancedAudioSettings() {
    guard !isLoading, !enhancedAudioSavePending else { return }
    enhancedAudioSavePending = true
    let elapsed =
      Double(DispatchTime.now().uptimeNanoseconds &- lastEnhancedAudioSave.uptimeNanoseconds) / 1e9
    DispatchQueue.main.asyncAfter(deadline: .now() + max(0, 0.04 - elapsed)) { [weak self] in
      self?.flushPendingEnhancedAudioSave()
    }
  }

  func flushPendingEnhancedAudioSave() {
    guard enhancedAudioSavePending else { return }
    enhancedAudioSavePending = false
    lastEnhancedAudioSave = .now()
    saveSettings()
    NotificationCenter.default.post(
      name: Notification.Name("enhancedAudioSettingChanged"), object: nil)
  }

  /// The equalizer that is playing, as custom bands: what a saved preset holds. The fixed
  /// bands become peaks, with the trim they give themselves added to the preamp.
  var enhancedAudioEQAsProfile: EnhancedAudioEQ.ImportedProfile {
    if EnhancedAudioEQ.Mode(title: selectedEnhancedAudioEQMode) == .parametric {
      return EnhancedAudioEQ.ImportedProfile(
        preamp: Double(enhancedAudioEQPreamp), bands: enhancedAudioEQBands, skippedLines: 0)
    }
    let fixed = EnhancedAudioEQ.graphicFilters(
      frequencies: Self.enhancedAudioEQFrequencies(for: selectedEnhancedAudioEQLayout),
      gains: enhancedAudioEQGains)
    let trim = EnhancedAudioEQ.graphicTrim(enhancedAudioEQGains)
    return EnhancedAudioEQ.ImportedProfile(
      preamp: ((Double(enhancedAudioEQPreamp) - trim) * 10).rounded() / 10,
      bands: fixed.map {
        EnhancedAudioEQBand(
          kind: .peak, frequency: $0.frequency, gain: $0.gain, q: ($0.q * 100).rounded() / 100)
      }, skippedLines: 0)
  }

  private var enhancedAudioEQSnapshot: EnhancedAudioEQSnapshot {
    EnhancedAudioEQSnapshot(
      layout: selectedEnhancedAudioEQLayout, mode: selectedEnhancedAudioEQMode,
      gains: enhancedAudioEQGains, bands: enhancedAudioEQBands, preamp: enhancedAudioEQPreamp,
      inactivePreamp: enhancedAudioEQInactivePreamp, name: enhancedAudioEQProfileName,
      inSync: enhancedAudioEQInSync)
  }

  private func restoreEnhancedAudioEQ(_ snapshot: EnhancedAudioEQSnapshot) {
    isSyncingEnhancedAudioEQ = true
    // First the layout and kind of bands the values belong to.
    selectedEnhancedAudioEQLayout = snapshot.layout
    selectedEnhancedAudioEQMode = snapshot.mode
    enhancedAudioEQGains = snapshot.gains
    enhancedAudioEQBands = snapshot.bands
    enhancedAudioEQPreamp = snapshot.preamp
    enhancedAudioEQInactivePreamp = snapshot.inactivePreamp
    enhancedAudioEQProfileName = snapshot.name
    isSyncingEnhancedAudioEQ = false
    enhancedAudioEQInSync = snapshot.inSync
    saveEnhancedAudioSettings()
  }

  /// Applies a preset to the kind of bands that is showing, and to the other kind as well,
  /// so that changing between 12, 24 and custom bands afterwards shows the same curve: the
  /// custom bands are the preset as it is, the fixed bands are fitted to it.
  func applyImportedEnhancedAudioEQ(_ imported: EnhancedAudioEQ.ImportedProfile, name: String?) {
    if (enhancedAudioEQProfileName ?? "").isEmpty || enhancedAudioEQBeforePreset == nil {
      // What Remove goes back to: the state before the first of a row of presets.
      enhancedAudioEQBeforePreset = enhancedAudioEQSnapshot
    }
    let fitted = EnhancedAudioEQ.fittedGraphicGains(
      frequencies: Self.enhancedAudioEQFrequencies(for: selectedEnhancedAudioEQLayout),
      following: EnhancedAudioEQ.parametricFilters(imported.bands))
    let customPreamp = CGFloat(imported.preamp)
    let fixedPreamp = CGFloat(imported.preamp + EnhancedAudioEQ.graphicTrim(fitted))
    let custom = EnhancedAudioEQ.Mode(title: selectedEnhancedAudioEQMode) == .parametric

    isSyncingEnhancedAudioEQ = true
    enhancedAudioEQBands = imported.bands
    enhancedAudioEQGains = fitted
    enhancedAudioEQPreamp = custom ? customPreamp : fixedPreamp
    enhancedAudioEQInactivePreamp = custom ? fixedPreamp : customPreamp
    enhancedAudioEQProfileName = name
    enhancedAudioEQEnabled = true
    isSyncingEnhancedAudioEQ = false
    enhancedAudioEQInSync = true
    saveEnhancedAudioSettings()
  }

  /// Takes the preset off: the equalizer as it was before one was applied, or flat when that
  /// is no longer known.
  func removeEnhancedAudioEQPreset() {
    if let before = enhancedAudioEQBeforePreset {
      enhancedAudioEQBeforePreset = nil
      restoreEnhancedAudioEQ(before)
      return
    }
    let count = Self.enhancedAudioEQFrequencies(for: selectedEnhancedAudioEQLayout).count
    restoreEnhancedAudioEQ(
      EnhancedAudioEQSnapshot(
        layout: selectedEnhancedAudioEQLayout, mode: selectedEnhancedAudioEQMode,
        gains: [Double](repeating: 0, count: count), bands: EnhancedAudioEQ.starterBands(),
        preamp: 0, inactivePreamp: 0, name: nil, inSync: false))
  }

  func setEnhancedAudioEQGain(_ value: Double, at index: Int) {
    guard enhancedAudioEQGains.indices.contains(index) else { return }
    var updated = enhancedAudioEQGains
    updated[index] = value
    enhancedAudioEQGains = updated
  }
}
