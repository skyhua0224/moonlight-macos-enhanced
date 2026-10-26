//
//  SettingsModel+ProfileCopy.swift
//  Moonlight for macOS
//
//  Copyright © 2026 Moonlight Game Streaming Project. All rights reserved.
//

import Foundation

/// What a settings profile is made of, and the operations on whole profiles: copying one into
/// another, resetting a host to follow the Default Profile, presets, files.
///
/// A profile is not one value: there is the `Settings` blob (`<id>-moonlightSettings`) and a
/// number of separate keys suffixed with the profile id. Every part is classified here, once:
///
/// - Shareable: means the same on any host. It describes this Mac, its display, audio
///   devices and controllers, or the stream and input behaviour the user wants. Copies,
///   presets, Use as Default, export and import carry these, and Reset removes them.
/// - Host-only: names, depends on or sets up something on one host. These stay with the host
///   through every operation; a preset has none, a file never holds them.

// MARK: - Classification of the Settings blob

extension Settings {
  struct HostOnlyField {
    let name: String
    let reason: String
    let take: (inout Settings, Settings?) -> Void
  }

  private static func hostOnly<T>(
    _ name: String, _ keyPath: WritableKeyPath<Settings, T?>, _ reason: String
  ) -> HostOnlyField {
    HostOnlyField(name: name, reason: reason) { settings, other in
      settings[keyPath: keyPath] = other?[keyPath: keyPath]
    }
  }

  static let hostOnlyFields: [HostOnlyField] = [
    hostOnly("connectionMethod", \.connectionMethod, "names one of that host's addresses"),
    hostOnly("sunshineTargetDisplayName", \.sunshineTargetDisplayName,
      "a display attached to that host"),
    hostOnly("sunshineUseVirtualDisplay", \.sunshineUseVirtualDisplay,
      "depends on that host's virtual display driver"),
    hostOnly("sunshineScreenMode", \.sunshineScreenMode,
      "how that host arranges its displays for the stream"),
    hostOnly("sunshineTouchKeyboardAutoInvoke", \.sunshineTouchKeyboardAutoInvoke,
      "Foundation Sunshine pops up its on-screen keyboard on that host"),
    hostOnly("sunshineHdrBrightnessOverride", \.sunshineHdrBrightnessOverride,
      "tunes the HDR luminance that host's display is set up with (off sends this Mac's own)"),
    hostOnly("sunshineMaxBrightness", \.sunshineMaxBrightness, "part of that override"),
    hostOnly("sunshineMinBrightness", \.sunshineMinBrightness, "part of that override"),
    hostOnly("sunshineMaxAverageBrightness", \.sunshineMaxAverageBrightness,
      "part of that override"),
    hostOnly("remoteResolution", \.remoteResolution, "changes that host's display mode"),
    hostOnly("remoteResolutionWidth", \.remoteResolutionWidth, "part of that display mode"),
    hostOnly("remoteResolutionHeight", \.remoteResolutionHeight, "part of that display mode"),
    hostOnly("remoteFps", \.remoteFps, "changes that host's display refresh rate"),
    hostOnly("remoteFpsRate", \.remoteFpsRate, "part of that refresh rate"),
    hostOnly("clipboardSyncMode", \.clipboardSyncMode,
      "only Foundation Sunshine hosts sync the clipboard, and the default follows from that"),
  ]

  /// Everything else: this Mac, its devices, the stream and input behaviour wanted. Some are
  /// sent to the host as a request (codec, FEC, audio on host), which any host reads the same.
  static let shareableFieldNames: [String] = [
    "resolution", "matchDisplayResolution", "customResolution", "fps", "customFps",
    "autoAdjustBitrate", "enableYUV444", "ignoreAspectRatio", "showLocalCursor",
    "enableMicrophone", "streamResolutionScale", "streamResolutionScaleRatio",
    "hdrTransferFunction", "hdrMetadataSource", "hdrClientDisplayProfile",
    "hdrManualMaxBrightness", "hdrManualMinBrightness", "hdrManualMaxAverageBrightness",
    "hdrOpticalOutputScale", "hdrHlgViewingEnvironment", "hdrEdrStrategy",
    "hdrToneMappingPolicy", "dynamicHdrPreference", "bitrate", "customBitrate",
    "unlockMaxBitrate", "codec", "videoRendererMode", "hdr", "enable10BitSdr", "framePacing",
    "audioOnPC", "audioConfiguration", "audioOutputMode", "enhancedAudioOutputTarget",
    "enhancedAudioPreset", "enhancedAudioEQLayout", "enhancedAudioSpatialIntensity",
    "enhancedAudioSoundstageWidth", "enhancedAudioReverbAmount", "enhancedAudioEQGains",
    "enhancedAudioExtras", "enableVsync", "showPerformanceOverlay", "showConnectionWarnings",
    "captureSystemShortcuts", "keyboardCompatibilityMode", "volumeLevel", "multiController",
    "swapABXYButtons", "optimize", "autoFullscreen", "displayMode", "rumble", "controllerDriver",
    "mouseDriver", "coreHIDAutoEnabled", "coreHIDMaxMouseReportRate", "freeMouseMotionMode",
    "emulateGuide", "appArtworkDimensions", "dimNonHoveredArtwork", "quitAppAfterStream",
    "swapMouseButtons", "reverseScrollDirection", "touchscreenMode", "gamepadMouseMode",
    "gamepadMouseModeLongPressMenu", "hostPrecisionTouchpad", "hostPrecisionTouchpadMode",
    "imeTextInput", "mouseMode", "pointerSensitivity", "wheelScrollSpeed",
    "rewrittenScrollSpeed", "gestureScrollSpeed", "physicalWheelHighPrecisionScale",
    "smartWheelTailFilter", "physicalWheelMode", "rewrittenScrollMode", "streamShortcuts",
    "upscalingMode", "frameInterpolationMode", "smoothnessLatencyMode", "timingBufferLevel",
    "timingPrioritizeResponsiveness", "displaySyncMode", "frameQueueTarget",
    "videoFecPercentage", "timingResponsivenessBias", "allowDrawableTimeoutMode",
    "timingCompatibilityMode", "timingSdrCompatibilityWorkaround", "enableAdaptiveBitrate",
  ]

  /// Sets the host-only fields to those of `other` (none when nil).
  mutating func takeHostOnlyFields(from other: Settings?) {
    for field in Self.hostOnlyFields {
      field.take(&self, other)
    }
  }

  /// This settings with only its shareable fields.
  var shareableOnly: Settings {
    var settings = self
    settings.takeHostOnlyFields(from: nil)
    return settings
  }

  #if DEBUG
  /// Every stored field is in exactly one of the two lists.
  static func checkFieldClassification(_ sample: Settings) {
    let stored = Set(Mirror(reflecting: sample).children.compactMap { $0.label })
    let hostOnly = Set(hostOnlyFields.map(\.name))
    let shareable = Set(shareableFieldNames)
    assert(
      stored == hostOnly.union(shareable) && hostOnly.isDisjoint(with: shareable),
      "Settings fields not classified: \(stored.symmetricDifference(hostOnly.union(shareable)))")
  }
  #endif
}

// MARK: - Classification of the per-profile keys

extension SettingsModel {
  /// A shareable per-profile key outside the `Settings` blob. `id` names it in exported
  /// files; `fallsBackToDefault` says whether a profile without a value of its own reads
  /// the Default Profile's (see `controllerSettingObject` and SettingsClass).
  struct ProfileKey {
    let id: String
    let key: (String) -> String
    let fallsBackToDefault: Bool
  }

  /// The shareable keys: controllers attached to this Mac, its keyboard and audio output.
  static let profileKeys: [ProfileKey] = [
    // Controller
    ProfileKey(id: "controller.nativeTouchpad",
      key: { controllerNativeTouchpadKeyPrefix + $0 }, fallsBackToDefault: false),
    ProfileKey(id: "controller.dualSensePrecisionTouchpad",
      key: { controllerDualSensePrecisionTouchpadKeyPrefix + $0 }, fallsBackToDefault: false),
    ProfileKey(id: "controller.deadzone",
      key: { controllerDeadzoneKeyPrefix + $0 }, fallsBackToDefault: true),
    ProfileKey(id: "controller.hapticsMode",
      key: { controllerHapticsModeKeyPrefix + $0 }, fallsBackToDefault: true),
    ProfileKey(id: "controller.motionMode",
      key: { controllerMotionModeKeyPrefix + $0 }, fallsBackToDefault: true),
    ProfileKey(id: "controller.feedbackTarget",
      key: { controllerFeedbackTargetKeyPrefix + $0 }, fallsBackToDefault: true),
    ProfileKey(id: "controller.virtualType",
      key: { controllerVirtualTypeKeyPrefix + $0 }, fallsBackToDefault: true),
    // The stick calibration describes the controller on this Mac, not the host.
    ProfileKey(id: "controller.calibration",
      key: { controllerCalibrationKeyPrefix + $0 }, fallsBackToDefault: true),
    ProfileKey(id: "controller.shortcuts",
      key: { controllerShortcutProfileKeyPrefix + $0 }, fallsBackToDefault: true),
    // Keyboard
    ProfileKey(id: "keyboard.keyMappingMode",
      key: { keyMappingModeKeyPrefix + $0 }, fallsBackToDefault: true),
    ProfileKey(id: "keyboard.translationRules",
      key: { keyboardTranslationRulesStorageKey(for: $0) }, fallsBackToDefault: true),
    // Audio
    ProfileKey(id: "audio.codec",
      key: { audioCodecKeyPrefix + $0 }, fallsBackToDefault: true),
    ProfileKey(id: "audio.continuous",
      key: { continuousAudioKeyPrefix + $0 }, fallsBackToDefault: true),
    ProfileKey(id: "audio.dolbyOutput",
      key: { dolbyOutputKeyPrefix + $0 }, fallsBackToDefault: true),
    // Whether the wheel scale in the blob was already moved off its old default: travels
    // with that value, so the destination does not migrate it a second time (or skip it).
    ProfileKey(id: "input.wheelScaleMigrated",
      key: { physicalWheelHighPrecisionScaleMigrationKey(for: $0) }, fallsBackToDefault: false),
  ]

  /// The host-only keys, by prefix (suffixed with the host id), and why each stays.
  static let hostOnlyKeys: [(key: String, reason: String)] = [
    ("manualEndpoints.", "addresses added for that host"),
    ("disabledEndpoints.", "addresses turned off for that host"),
    ("defaultConnectionMethod.", "that host's preferred address"),
    (audioCodecFailureKeyPrefix, "codecs that host failed to deliver"),
    (surround714UnavailableKeyPrefix, "that host had no 7.1.4 audio"),
    (foundationHostKeyPrefix, "whether that host runs Foundation Sunshine"),
    (sunshineVddCapabilityKeyPrefix, "that host's virtual display driver version"),
    (sunshineVddStateKeyPrefix, "that host's virtual display driver state"),
    (perAppTopologyKeyPrefix, "display choices for one app on that host (<host>.<app>)"),
    ("<host>-hideFullscreenControlBall", "the stream control ball, as left in that host's stream"),
    ("<host>-fullscreenControlBallDockSide", "same"),
    ("<host>-fullscreenControlBallVerticalRatio", "same"),
  ]

  /// A profile's preferences as it streams with them: its `Settings` (its own or the one it
  /// takes from the Default Profile) and the separate keys by `ProfileKey.id`. A key that is
  /// missing uses the built-in default.
  struct ProfileSnapshot {
    var settings: Settings
    var keys: [String: Any]
  }

  /// The value of `entry` that `profileId` reads.
  static func effectiveValue(of entry: ProfileKey, for profileId: String) -> Any? {
    let defaults = UserDefaults.standard
    if let value = defaults.object(forKey: entry.key(profileId)) { return value }
    guard entry.fallsBackToDefault, profileId != globalHostId else { return nil }
    return defaults.object(forKey: entry.key(globalHostId))
  }

  /// Nil when the profile has nothing at all (no settings of its own, none in Default).
  static func profileSnapshot(of profileId: String) -> ProfileSnapshot? {
    guard let settings = Settings.getSettings(for: profileId) else { return nil }
    var keys: [String: Any] = [:]
    for entry in profileKeys {
      if let value = effectiveValue(of: entry, for: profileId) { keys[entry.id] = value }
    }
    return ProfileSnapshot(settings: settings, keys: keys)
  }

  /// Makes the shareable part of `snapshot` the settings of `destinationId`. The destination
  /// keeps its host-only ones; a preset has none.
  static func apply(_ snapshot: ProfileSnapshot, to destinationId: String) {
    let destination = isPresetProfile(destinationId) ? nil : Settings.getSettings(for: destinationId)
    var settings = snapshot.settings
    #if DEBUG
    Settings.checkFieldClassification(settings)
    #endif
    settings.takeHostOnlyFields(from: destination)
    SettingsClass.persist(settings, for: destinationId)

    let defaults = UserDefaults.standard
    for entry in profileKeys {
      if let value = snapshot.keys[entry.id] {
        defaults.set(value, forKey: entry.key(destinationId))
      } else {
        // The source uses the built-in default, and so will the destination.
        defaults.removeObject(forKey: entry.key(destinationId))
      }
    }
    invalidateKeyboardTranslationRulesCache()
  }

  /// Replaces the preferences of `destinationId` with those `sourceId` uses now. Returns false
  /// when the source has nothing to copy. Nothing links the two afterwards.
  @discardableResult
  static func copyProfileSettings(from sourceId: String, to destinationId: String) -> Bool {
    guard sourceId != destinationId, let snapshot = profileSnapshot(of: sourceId) else {
      return false
    }
    apply(snapshot, to: destinationId)
    return true
  }

  /// Whether `profileId` has settings of its own; otherwise it follows the Default Profile.
  static func hasOwnSettings(_ profileId: String) -> Bool {
    Settings.persistedSettings(for: profileId) != nil
  }

  /// Lets a host follow the Default Profile again: its shareable settings go (its own
  /// settings and its own values of `profileKeys`). Its host-only settings are kept aside and
  /// still apply while it follows Default; the host-only keys are not touched.
  static func resetProfileToDefault(_ hostId: String) {
    guard hostId != globalHostId, !isPresetProfile(hostId) else { return }
    if let own = Settings.persistedSettings(for: hostId) {
      Settings.keepHostOnlySettings(own, for: hostId)
    }
    SettingsClass.removeProfile(for: hostId)
    let defaults = UserDefaults.standard
    for entry in profileKeys {
      defaults.removeObject(forKey: entry.key(hostId))
    }
    // The wheel scale now comes from the Default Profile, which migrates its own: the host
    // must not migrate it again, which would save it settings of its own at once.
    defaults.set(true, forKey: physicalWheelHighPrecisionScaleMigrationKey(for: hostId))
    invalidateKeyboardTranslationRulesCache()
  }

  /// After a profile operation: the profile shown in the window is read again when it was the
  /// one changed (writing out a pending audio change first, which belongs to the settings
  /// being replaced). Like any reload it announces nothing to a running stream.
  func changeProfile(_ profileId: String, _ change: () -> Void) {
    let shownId = selectedHost?.id ?? Self.globalHostId
    flushPendingEnhancedAudioSave()
    change()
    // Default changes what a host that follows it reads, too.
    if profileId == shownId || (profileId == Self.globalHostId && !Self.hasOwnSettings(shownId)) {
      loadSettings()
      refreshVideoDiagnosticsState()
    }
  }
}

// MARK: - Presets

/// A named profile that belongs to no host. Its settings are stored like a host's, under
/// `id`, so every profile operation works on it unchanged.
struct SettingsPreset: Codable, Hashable, Identifiable {
  let id: String
  var name: String
}

extension SettingsModel {
  static let presetIdPrefix = "__preset__"
  static let presetIndexKey = "settings.profilePresets"

  static func isPresetProfile(_ profileId: String) -> Bool {
    profileId.hasPrefix(presetIdPrefix)
  }

  /// The presets in the order they were made. They are not hosts: nothing that lists hosts
  /// (the host database, the settings profile picker) knows them.
  static var presets: [SettingsPreset] {
    guard let data = UserDefaults.standard.data(forKey: presetIndexKey) else { return [] }
    return (try? PropertyListDecoder().decode([SettingsPreset].self, from: data)) ?? []
  }

  private static func savePresets(_ presets: [SettingsPreset]) {
    if let data = try? PropertyListEncoder().encode(presets) {
      UserDefaults.standard.set(data, forKey: presetIndexKey)
    }
  }

  static func preset(_ id: String) -> SettingsPreset? {
    presets.first { $0.id == id }
  }

  /// A new preset holding `snapshot`.
  @discardableResult
  static func createPreset(named name: String, with snapshot: ProfileSnapshot) -> SettingsPreset {
    let preset = SettingsPreset(id: presetIdPrefix + UUID().uuidString, name: name)
    apply(snapshot, to: preset.id)
    savePresets(presets + [preset])
    return preset
  }

  static func renamePreset(_ id: String, to name: String) {
    savePresets(presets.map { $0.id == id ? SettingsPreset(id: id, name: name) : $0 })
  }

  static func deletePreset(_ id: String) {
    guard isPresetProfile(id) else { return }
    SettingsClass.removeProfile(for: id)
    let defaults = UserDefaults.standard
    for entry in profileKeys {
      defaults.removeObject(forKey: entry.key(id))
    }
    invalidateKeyboardTranslationRulesCache()
    savePresets(presets.filter { $0.id != id })
  }
}

// MARK: - Per-app choices

/// What was chosen for one app of a host (from the app's menu), kept under
/// `Moonlight.SunshinePerAppTopology.<host id>.<app id>` (AppsViewController).
struct PerAppOverride: Identifiable, Hashable {
  let id: String
  let appId: String
  let appName: String?
  let displayName: String?
  let screenMode: Int?
  let useVirtualDisplay: Bool?
}

extension SettingsModel {
  static let perAppTopologyKeyPrefix = "Moonlight.SunshinePerAppTopology."

  static func perAppOverrides(for hostId: String) -> [PerAppOverride] {
    guard hostId != globalHostId, !isPresetProfile(hostId) else { return [] }
    let prefix = perAppTopologyKeyPrefix + hostId + "."
    let defaults = UserDefaults.standard
    let keys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(prefix) }
    guard !keys.isEmpty else { return [] }

    let host = (DataManager().getHosts() as? [TemporaryHost])?.first { $0.uuid == hostId }
    let apps = (host?.appList as? Set<TemporaryApp>) ?? []
    return keys.sorted().compactMap { key in
      guard let saved = defaults.dictionary(forKey: key) else { return nil }
      let appId = String(key.dropFirst(prefix.count))
      return PerAppOverride(
        id: key,
        appId: appId,
        appName: apps.first { $0.id == appId }?.name,
        displayName: saved["displayName"] as? String,
        screenMode: (saved["screenMode"] as? NSNumber)?.intValue,
        useVirtualDisplay: (saved["useVirtualDisplay"] as? NSNumber)?.boolValue)
    }
  }

  static func clearPerAppOverride(_ item: PerAppOverride) {
    UserDefaults.standard.removeObject(forKey: item.id)
  }
}
