//
//  SettingsProfileDifferences.swift
//  Moonlight for macOS
//
//  Copyright © 2026 Moonlight Game Streaming Project. All rights reserved.
//

import SwiftUI

/// Where a setting is edited, for grouping differences.
enum ProfileSettingCategory: CaseIterable, Hashable {
  case stream, video, audio, controller, input, shortcuts, other

  var titleKey: String {
    switch self {
    case .stream: return SettingsPaneType.stream.titleKey
    case .video: return SettingsPaneType.video.titleKey
    case .audio: return "Audio"
    case .controller: return SettingsPaneType.input.titleKey
    case .input: return SettingsPaneType.keyboard.titleKey
    case .shortcuts: return "Shortcuts"
    case .other: return "Other"
    }
  }

  var symbol: String {
    switch self {
    case .stream: return SettingsPaneType.stream.symbol
    case .video: return SettingsPaneType.video.symbol
    case .audio: return SettingsPaneType.audio.symbol
    case .controller: return SettingsPaneType.input.symbol
    case .input: return SettingsPaneType.keyboard.symbol
    case .shortcuts: return "command"
    case .other: return SettingsPaneType.app.symbol
    }
  }

  var tint: Color {
    switch self {
    case .stream: return SettingsPaneType.stream.color
    case .video: return SettingsPaneType.video.color
    case .audio: return SettingsPaneType.audio.color
    case .controller: return SettingsPaneType.input.color
    case .input: return SettingsPaneType.keyboard.color
    case .shortcuts: return .purple
    case .other: return SettingsPaneType.app.color
    }
  }
}

/// One setting that reads differently in two profiles, worded as the settings window words it.
struct ProfileDifference: Identifiable, Hashable {
  let id: String
  let category: ProfileSettingCategory
  let titleKey: String
  let value: String
  let otherValue: String
}

/// Compares what two profiles stream with, setting by setting. Titles are the keys of the
/// rows that edit the setting; values are what those rows show.
enum SettingsProfileDifferences {
  /// A profile's values as they are read: `settings` nil and no keys are the built-in
  /// defaults.
  struct Values {
    let settings: Settings?
    let keys: [String: Any]

    static let builtIn = Values(settings: nil, keys: [:])

    init(settings: Settings?, keys: [String: Any]) {
      self.settings = settings
      self.keys = keys
    }

    init(_ snapshot: SettingsModel.ProfileSnapshot?) {
      self.init(settings: snapshot?.settings, keys: snapshot?.keys ?? [:])
    }

    func key<T>(_ id: String, as type: T.Type) -> T? {
      keys[id] as? T
    }
  }

  /// How one setting reads: the text shown, and what decides whether two profiles differ
  /// (the text, unless a setting has more to it than its text says).
  private struct Reading {
    let text: String
    let identity: String

    init(_ text: String, identity: String? = nil) {
      self.text = text
      self.identity = identity ?? text
    }
  }

  private struct Field {
    let titleKey: String
    let read: (Values) -> Reading
  }

  /// The shareable settings of `values` that read differently in `other`. Host-only settings
  /// are not compared: they belong to one host and no profile operation touches them.
  static func differences(_ values: Values, from other: Values) -> [ProfileDifference] {
    fields.flatMap { group -> [ProfileDifference] in
      group.fields.compactMap { field in
        let mine = field.read(values)
        let theirs = field.read(other)
        guard mine.identity != theirs.identity else { return nil }
        // Same words for different values (an equalizer curve, a set of shortcuts).
        let text = mine.text == theirs.text ? localize("Different Values") : mine.text
        return ProfileDifference(
          id: field.titleKey, category: group.category, titleKey: field.titleKey,
          value: text, otherValue: theirs.text)
      }
    }
  }

  // MARK: Wording

  private static func localize(_ key: String) -> String {
    LanguageManager.shared.localize(key)
  }

  private static func onOff(_ value: Bool) -> Reading {
    Reading(localize(value ? "On" : "Off"))
  }

  private static func option(_ key: String) -> Reading {
    Reading(localize(key))
  }

  private static func number(_ value: CGFloat, suffix: String = "") -> Reading {
    Reading(String(format: "%g", Double(value)) + suffix)
  }

  private static func percent(_ value: CGFloat) -> Reading {
    Reading(SettingsModel.percentageLabel(for: value))
  }

  private static func size(_ width: CGFloat, _ height: CGFloat) -> String {
    "\(Int(width)) × \(Int(height))"
  }

  /// A value with no short wording: whether it was changed from the built-in one, and the
  /// value itself to tell two changed ones apart.
  private static func custom(_ identity: String?, builtIn: String?) -> Reading {
    guard let identity, identity != builtIn else { return Reading(localize("Standard")) }
    return Reading(localize("Customized"), identity: identity)
  }

  private static func encoded<T: Encodable>(_ value: T?) -> String? {
    guard let value else { return nil }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return (try? encoder.encode(value)).map { $0.base64EncodedString() }
  }

  private static func dataIdentity(_ data: Data?) -> String? {
    data?.base64EncodedString()
  }

  // MARK: Fields

  /// The settings by category, each worded as its row in the settings window.
  private static let fields: [(category: ProfileSettingCategory, fields: [Field])] = [
    (.stream, streamFields), (.video, videoFields), (.audio, audioFields),
    (.controller, controllerFields), (.input, inputFields), (.shortcuts, shortcutFields),
    (.other, otherFields),
  ]

  private static let streamFields: [Field] = [
    Field(titleKey: "Resolution") { v in
      guard let s = v.settings else {
        return Reading(size(SettingsModel.defaultResolution.width, SettingsModel.defaultResolution.height))
      }
      if s.matchDisplayResolution ?? false { return option("Match Display") }
      if let custom = s.customResolution, custom.width > 0, custom.height > 0 {
        return Reading(size(custom.width, custom.height))
      }
      let resolution = s.resolution == .zero ? SettingsModel.defaultResolution : s.resolution
      return Reading(size(resolution.width, resolution.height))
    },
    Field(titleKey: "Frame Rate") { v in
      let fps: Int
      if let custom = v.settings?.customFps, custom > 0 {
        fps = Int(custom)
      } else if let stored = v.settings?.fps, stored > 0 {
        fps = stored
      } else {
        fps = SettingsModel.defaultFps
      }
      return Reading("\(fps) Hz")
    },
    Field(titleKey: "Resolution Scale") { v in
      onOff(v.settings?.streamResolutionScale ?? SettingsModel.defaultStreamResolutionScale)
    },
    Field(titleKey: "Resolution Scale Ratio") { v in
      Reading("\(v.settings?.streamResolutionScaleRatio ?? SettingsModel.defaultStreamResolutionScaleRatio)%")
    },
    Field(titleKey: "Auto Adjust Bitrate") { v in
      onOff(v.settings?.autoAdjustBitrate ?? SettingsModel.defaultAutoAdjustBitrate)
    },
    Field(titleKey: "Bitrate") { v in
      guard let s = v.settings, !(s.autoAdjustBitrate ?? SettingsModel.defaultAutoAdjustBitrate) else {
        return option("Automatic")
      }
      return Reading(String(format: "%g Mbps", Double(s.customBitrate ?? s.bitrate) / 1000))
    },
    Field(titleKey: "Unlock max bitrate (1000 Mbps)") { v in
      onOff(v.settings?.unlockMaxBitrate ?? SettingsModel.defaultUnlockMaxBitrate)
    },
    Field(titleKey: "Adaptive Bitrate") { v in
      onOff(v.settings?.enableAdaptiveBitrate ?? SettingsModel.defaultEnableAdaptiveBitrate)
    },
    Field(titleKey: "Ignore Aspect Ratio") { v in
      onOff(v.settings?.ignoreAspectRatio ?? SettingsModel.defaultIgnoreAspectRatio)
    },
    Field(titleKey: "Show Local Cursor") { v in
      onOff(v.settings?.showLocalCursor ?? SettingsModel.defaultShowLocalCursor)
    },
    Field(titleKey: "Video FEC") { v in
      option(SettingsModel.videoFecPercentageSelection(for: v.settings?.videoFecPercentage))
    },
    Field(titleKey: "Default Display Mode") { v in
      let mode = v.settings.map { $0.displayMode ?? ($0.autoFullscreen ? 1 : 0) }
        ?? SettingsModel.defaultDisplayMode
      return option(SettingsModel.getString(from: mode, in: SettingsModel.displayModes))
    },
  ]

  private static let videoFields: [Field] = [
    Field(titleKey: "Video Codec") { v in
      option(v.settings.map { SettingsModel.getString(from: $0.codec, in: SettingsModel.videoCodecs) }
        ?? SettingsModel.defaultVideoCodec)
    },
    Field(titleKey: "Renderer Mode") { v in
      option(SettingsModel.videoRendererModeSelection(
        for: v.settings?.videoRendererMode ?? SettingsModel.defaultVideoRendererModeRawValue))
    },
    Field(titleKey: "HDR") { v in onOff(v.settings?.hdr ?? SettingsModel.defaultHdr) },
    Field(titleKey: "YUV 4:4:4") { v in
      onOff(v.settings?.enableYUV444 ?? SettingsModel.defaultEnableYUV444)
    },
    Field(titleKey: "10-bit SDR") { v in
      onOff(v.settings?.enable10BitSdr ?? SettingsModel.defaultEnable10BitSdr)
    },
    Field(titleKey: "Transfer Function") { v in
      option(SettingsModel.hdrTransferFunctionSelection(
        for: v.settings?.hdrTransferFunction
          ?? SettingsModel.hdrTransferFunctionRawValue(for: SettingsModel.defaultHdrTransferFunction)))
    },
    Field(titleKey: "Dynamic HDR Preference") { v in
      option(SettingsModel.dynamicHdrPreferenceSelection(for: v.settings?.dynamicHdrPreference))
    },
    Field(titleKey: "Upscaling") { v in
      option(SettingsModel.upscalingModeTitle(
        for: v.settings?.upscalingMode ?? SettingsModel.defaultUpscalingMode))
    },
    Field(titleKey: "Frame Interpolation") { v in
      option(SettingsModel.frameInterpolationModeSelection(for: v.settings?.frameInterpolationMode))
    },
    Field(titleKey: "Metadata Source") { v in
      option(SettingsModel.hdrMetadataSourceSelection(for: v.settings?.hdrMetadataSource))
    },
    Field(titleKey: "Client Display Profile") { v in
      option(SettingsModel.hdrClientDisplayProfileSelection(for: v.settings?.hdrClientDisplayProfile))
    },
    Field(titleKey: "EDR Strategy") { v in
      option(SettingsModel.hdrEdrStrategySelection(for: v.settings?.hdrEdrStrategy))
    },
    Field(titleKey: "Tone Mapping") { v in
      option(SettingsModel.hdrToneMappingPolicySelection(for: v.settings?.hdrToneMappingPolicy))
    },
    Field(titleKey: "Max Brightness") { v in
      number(v.settings?.hdrManualMaxBrightness ?? SettingsModel.defaultHdrManualMaxBrightness)
    },
    Field(titleKey: "Min Brightness") { v in
      number(v.settings?.hdrManualMinBrightness ?? SettingsModel.defaultHdrManualMinBrightness)
    },
    Field(titleKey: "Max Average Brightness") { v in
      number(v.settings?.hdrManualMaxAverageBrightness
        ?? SettingsModel.defaultHdrManualMaxAverageBrightness)
    },
    Field(titleKey: "Optical Output Scale") { v in
      number(v.settings?.hdrOpticalOutputScale ?? SettingsModel.defaultHdrOpticalOutputScale)
    },
    Field(titleKey: "HLG Viewing Environment") { v in
      option(SettingsModel.hdrHlgViewingEnvironmentSelection(for: v.settings?.hdrHlgViewingEnvironment))
    },
    Field(titleKey: "Display Sync") { v in
      option(SettingsModel.displaySyncModeSelection(for: v.settings?.displaySyncMode))
    },
    Field(titleKey: "Allow Drawable Timeout") { v in
      option(SettingsModel.allowDrawableTimeoutSelection(for: v.settings?.allowDrawableTimeoutMode))
    },
    Field(titleKey: "Pacing") { v in
      option(v.settings.map { SettingsModel.getString(from: $0.framePacing, in: SettingsModel.pacingOptions) }
        ?? SettingsModel.defaultPacingOptions)
    },
    Field(titleKey: "Smoothness / Latency") { v in
      guard let s = v.settings else { return option(SettingsModel.defaultSmoothnessLatencyMode) }
      return option(SettingsModel.getString(
        from: s.smoothnessLatencyMode
          ?? SettingsModel.derivedSmoothnessLatencyMode(
            framePacing: s.framePacing,
            enableVsync: s.enableVsync,
            timingBufferLevel: s.timingBufferLevel,
            timingPrioritizeResponsiveness: s.timingPrioritizeResponsiveness,
            timingCompatibilityMode: s.timingCompatibilityMode,
            timingSdrCompatibilityWorkaround: s.timingSdrCompatibilityWorkaround),
        in: SettingsModel.smoothnessLatencyModes))
    },
    Field(titleKey: "VSync") { v in
      onOff(v.settings?.enableVsync ?? SettingsModel.defaultEnableVsync)
    },
    Field(titleKey: "Buffer Level") { v in
      guard let level = v.settings?.timingBufferLevel else {
        return option(SettingsModel.defaultTimingBufferLevel)
      }
      return option(SettingsModel.getString(from: level, in: SettingsModel.timingBufferLevels))
    },
    Field(titleKey: "Prioritize Responsiveness") { v in
      onOff(v.settings?.timingPrioritizeResponsiveness
        ?? SettingsModel.defaultTimingPrioritizeResponsiveness)
    },
    Field(titleKey: "Frame Queue Target") { v in
      option(SettingsModel.frameQueueTargetSelection(for: v.settings?.frameQueueTarget))
    },
    Field(titleKey: "Responsiveness Bias") { v in
      let legacy = (v.settings?.timingPrioritizeResponsiveness ?? false) ? 1 : 0
      return option(SettingsModel.responsivenessBiasSelection(
        for: v.settings?.timingResponsivenessBias ?? legacy))
    },
    Field(titleKey: "Compatibility Mode") { v in
      onOff(v.settings?.timingCompatibilityMode ?? SettingsModel.defaultTimingCompatibilityMode)
    },
    Field(titleKey: "SDR Compatibility Workaround") { v in
      onOff(v.settings?.timingSdrCompatibilityWorkaround
        ?? SettingsModel.defaultTimingSdrCompatibilityWorkaround)
    },
  ]

  private static let audioFields: [Field] = [
    Field(titleKey: "Play Sound on Host") { v in
      onOff(v.settings?.audioOnPC ?? SettingsModel.defaultAudioOnPC)
    },
    Field(titleKey: "Audio Configuration") { v in
      option(v.settings.map {
        SettingsModel.getString(from: $0.audioConfiguration, in: SettingsModel.audioConfigurations)
      } ?? SettingsModel.defaultAudioConfiguration)
    },
    Field(titleKey: "Audio Codec") { v in
      option(AudioCodecChoice(
        selection: v.key("audio.codec", as: String.self) ?? SettingsModel.defaultAudioCodec).displayKey)
    },
    Field(titleKey: "Dolby Output") { v in
      let stored = v.key("audio.dolbyOutput", as: String.self)
      return option(stored.flatMap { SettingsModel.dolbyOutputModes.contains($0) ? $0 : nil }
        ?? SettingsModel.defaultDolbyOutput)
    },
    Field(titleKey: "Keep Audio Stream Active During Silence") { v in
      onOff(v.key("audio.continuous", as: Bool.self) ?? SettingsModel.defaultContinuousAudio)
    },
    Field(titleKey: "Sound Mode") { v in
      option(v.settings?.audioOutputMode.map {
        SettingsModel.getString(from: $0, in: SettingsModel.audioOutputModes)
      } ?? SettingsModel.defaultAudioOutputMode)
    },
    Field(titleKey: "Volume") { v in
      percent(v.settings?.volumeLevel ?? SettingsModel.defaultVolumeLevel)
    },
    Field(titleKey: "Listening Device") { v in
      option(v.settings?.enhancedAudioOutputTarget.map {
        SettingsModel.getString(from: $0, in: SettingsModel.enhancedAudioOutputTargets)
      } ?? SettingsModel.defaultEnhancedAudioOutputTarget)
    },
    Field(titleKey: "Spatial Audio") { v in
      let mode = v.settings?.enhancedAudioExtras?.spatialMode
        ?? EnhancedAudioSpatialMode.automatic.rawValue
      return option((EnhancedAudioSpatialMode(rawValue: mode) ?? .automatic).title)
    },
    Field(titleKey: "Spatial Intensity") { v in
      percent(v.settings?.enhancedAudioSpatialIntensity
        ?? SettingsModel.defaultEnhancedAudioSpatialIntensity)
    },
    Field(titleKey: "Soundstage Width") { v in
      percent(v.settings?.enhancedAudioSoundstageWidth
        ?? SettingsModel.defaultEnhancedAudioSoundstageWidth)
    },
    Field(titleKey: "Reverb") { v in
      percent(v.settings?.enhancedAudioReverbAmount ?? SettingsModel.defaultEnhancedAudioReverbAmount)
    },
    Field(titleKey: "Enable Equalizer") { v in
      onOff((v.settings?.enhancedAudioExtras ?? EnhancedAudioExtras()).eqEnabled)
    },
    Field(titleKey: "EQ") { v in
      let extras = v.settings?.enhancedAudioExtras ?? EnhancedAudioExtras()
      let gains = v.settings?.enhancedAudioEQGains ?? SettingsModel.defaultEnhancedAudioEQGains
      let mode = EnhancedAudioEQ.Mode(rawValue: extras.eqMode) ?? .graphic
      let name = extras.eqProfileName.flatMap { $0.isEmpty ? nil : $0 }
      // The curve: the mode, both preamps, the fixed gains and the custom bands.
      let identity = [
        "\(extras.eqMode)", "\(extras.eqPreamp)", "\(extras.eqInactivePreamp)",
        gains.map { "\($0)" }.joined(separator: ","),
        encoded(extras.eqBands) ?? "",
      ].joined(separator: "|")
      return Reading(name ?? localize(mode.title), identity: identity)
    },
    Field(titleKey: "Enable Microphone") { v in
      onOff(v.settings?.enableMicrophone ?? SettingsModel.defaultEnableMicrophone)
    },
  ]

  private static let controllerFields: [Field] = [
    Field(titleKey: "Controller Driver") { v in
      option(v.settings.map {
        SettingsModel.getString(from: $0.controllerDriver, in: SettingsModel.controllerDrivers)
      } ?? SettingsModel.defaultControllerDriver)
    },
    Field(titleKey: "Controller Count") { v in
      option(v.settings.map {
        SettingsModel.getString(from: $0.multiController, in: SettingsModel.multiControllerModes)
      } ?? SettingsModel.defaultMultiControllerMode)
    },
    Field(titleKey: "Rumble") { v in onOff(v.settings?.rumble ?? SettingsModel.defaultRumble) },
    Field(titleKey: "Swap Buttons") { v in
      onOff(v.settings?.swapABXYButtons ?? SettingsModel.defaultSwapButtons)
    },
    Field(titleKey: "DualSense Touchpad Mode") { v in
      option((v.key("controller.nativeTouchpad", as: Bool.self) ?? true)
        ? "Host Touchpad" : "Mac-style Trackpad")
    },
    Field(titleKey: "DualSense Touchpad Output") { v in
      option((v.key("controller.dualSensePrecisionTouchpad", as: Bool.self) ?? false)
        ? "DualSense Touchpad Output Precision" : "DualSense Touchpad Output Controller")
    },
    Field(titleKey: "Haptic Feedback") { v in
      option(SettingsModel.ControllerHapticsMode(
        selection: v.key("controller.hapticsMode", as: String.self)
          ?? SettingsModel.defaultControllerHapticsMode).displayKey)
    },
    Field(titleKey: "Motion Sensor") { v in
      option(SettingsModel.ControllerMotionMode(
        selection: v.key("controller.motionMode", as: String.self)
          ?? SettingsModel.defaultControllerMotionMode).displayKey)
    },
    Field(titleKey: "Feedback Target") { v in
      option(SettingsModel.ControllerFeedbackTarget(
        selection: v.key("controller.feedbackTarget", as: String.self)
          ?? SettingsModel.defaultControllerFeedbackTarget).displayKey)
    },
    Field(titleKey: "Controller Deadzone") { v in
      let deadzone = min(0.30, max(0.0, v.key("controller.deadzone", as: Double.self)
        ?? SettingsModel.defaultControllerDeadzone))
      return Reading(String(format: "%.0f%%", deadzone * 100))
    },
    Field(titleKey: "Emulate Guide Button") { v in
      onOff(v.settings?.emulateGuide ?? SettingsModel.defaultEmulateGuide)
    },
    Field(titleKey: "Gamepad Mouse Emulation") { v in
      onOff(v.settings?.gamepadMouseMode ?? SettingsModel.defaultGamepadMouseMode)
    },
    Field(titleKey: "Host Controller Type") { v in
      option(SettingsModel.ControllerVirtualType(
        selection: v.key("controller.virtualType", as: String.self)
          ?? SettingsModel.defaultControllerVirtualType).displayKey)
    },
    Field(titleKey: "Stick Calibration") { v in
      let calibration = v.key("controller.calibration", as: Data.self).flatMap {
        try? PropertyListDecoder().decode(SettingsModel.ControllerCalibration.self, from: $0)
      }?.normalized
      return custom(encoded(calibration), builtIn: encoded(SettingsModel.ControllerCalibration.default))
    },
  ]

  private static let inputFields: [Field] = [
    Field(titleKey: "Mouse Mode") { v in
      let mode = v.settings?.mouseMode.map {
        SettingsModel.getString(from: $0, in: SettingsModel.mouseModes)
      } ?? SettingsModel.defaultMouseMode
      return option(mode == "game" ? "Locked Mouse" : "Free Mouse")
    },
    Field(titleKey: "Mouse Driver") { v in
      option(v.settings.map { MouseInputDriverStrategy(persistedRawValue: $0.mouseDriver).displayKey }
        ?? SettingsModel.defaultMouseDriver)
    },
    Field(titleKey: "Keyboard Translation") { v in
      option(KeyboardCompatibilityMode(persistedRawValue: v.settings?.keyboardCompatibilityMode)
        .displayKey)
    },
    Field(titleKey: "Key Mapping") { v in
      option(KeyMappingMode(persistedRawValue: v.key("keyboard.keyMappingMode", as: Int.self))
        .displayKey)
    },
    Field(titleKey: "Capture System Shortcuts") { v in
      onOff(v.settings?.captureSystemShortcuts ?? SettingsModel.defaultCaptureSystemShortcuts)
    },
    Field(titleKey: "Swap Mouse Buttons") { v in
      onOff(v.settings?.swapMouseButtons ?? SettingsModel.defaultSwapMouseButtons)
    },
    Field(titleKey: "Reverse Scroll Direction") { v in
      onOff(v.settings?.reverseScrollDirection ?? SettingsModel.defaultReverseScrollDirection)
    },
    Field(titleKey: "Precision Touchpad") { v in
      let mode = SettingsModel.precisionTouchpadMode(
        mode: v.settings?.hostPrecisionTouchpadMode, legacyEnabled: v.settings?.hostPrecisionTouchpad)
      let keys = ["Precision Touchpad Off", "Precision Touchpad Block", "Precision Touchpad Both"]
      return option(keys[min(max(mode, 0), keys.count - 1)])
    },
    Field(titleKey: "Type Text with the macOS Input Method") { v in
      onOff(v.settings?.imeTextInput ?? SettingsModel.defaultImeTextInput)
    },
    Field(titleKey: "Pointer Speed") { v in
      number(v.settings?.pointerSensitivity ?? SettingsModel.defaultPointerSensitivity, suffix: "×")
    },
    Field(titleKey: "Scroll Mode") { v in
      option(PhysicalWheelScrollMode(persistedRawValue: v.settings?.physicalWheelMode).displayKey)
    },
    Field(titleKey: "Free Mouse Movement") { v in
      option(FreeMouseMotionMode(persistedRawValue: v.settings?.freeMouseMotionMode).displayKey)
    },
    Field(titleKey: "Physical Wheel Speed") { v in
      number(v.settings?.wheelScrollSpeed ?? SettingsModel.defaultWheelScrollSpeed, suffix: "×")
    },
    Field(titleKey: "High Precision Wheel Speed") { v in
      number(v.settings?.physicalWheelHighPrecisionScale
        ?? SettingsModel.defaultPhysicalWheelHighPrecisionScale, suffix: "×")
    },
    Field(titleKey: "Smooth Wheel Mode") { v in
      option(RewrittenScrollMode(persistedRawValue: v.settings?.rewrittenScrollMode).displayKey)
    },
    Field(titleKey: "Smooth Wheel Speed") { v in
      number(v.settings?.rewrittenScrollSpeed ?? SettingsModel.defaultRewrittenScrollSpeed, suffix: "×")
    },
    Field(titleKey: "Smooth Wheel Tail Filter") { v in
      number(v.settings?.smartWheelTailFilter ?? SettingsModel.defaultSmartWheelTailFilter)
    },
    Field(titleKey: "Trackpad Speed") { v in
      number(v.settings?.gestureScrollSpeed ?? SettingsModel.defaultGestureScrollSpeed, suffix: "×")
    },
    Field(titleKey: "CoreHID Max Mouse Report Rate") { v in
      Reading(SettingsModel.coreHIDMaxMouseReportRateLabel(
        v.settings?.coreHIDMaxMouseReportRate ?? SettingsModel.defaultCoreHIDMaxMouseReportRate))
    },
    Field(titleKey: "Touchscreen Mode") { v in
      option(SettingsModel.getString(
        from: v.settings?.touchscreenMode ?? SettingsModel.defaultTouchscreenMode,
        in: SettingsModel.touchscreenModes))
    },
  ]

  private static let shortcutFields: [Field] = [
    Field(titleKey: "Controller Shortcuts") { v in
      custom(dataIdentity(v.key("controller.shortcuts", as: Data.self)), builtIn: nil)
    },
    Field(titleKey: "Shortcut Translation Rules") { v in
      custom(dataIdentity(v.key("keyboard.translationRules", as: Data.self)), builtIn: nil)
    },
    Field(titleKey: "Stream Shortcuts") { v in
      custom(
        encoded(StreamShortcutProfile.normalizedShortcuts(
          v.settings?.streamShortcuts ?? StreamShortcutProfile.defaultShortcuts())),
        builtIn: encoded(StreamShortcutProfile.normalizedShortcuts(
          StreamShortcutProfile.defaultShortcuts())))
    },
  ]

  private static let otherFields: [Field] = [
    Field(titleKey: "Optimize Game Settings") { v in
      onOff(v.settings?.optimize ?? SettingsModel.defaultOptimize)
    },
    Field(titleKey: "Custom Artwork Dimensions") { v in
      guard let artwork = v.settings?.appArtworkDimensions, artwork.width > 0, artwork.height > 0
      else { return onOff(false) }
      return Reading(size(artwork.width, artwork.height))
    },
    Field(titleKey: "Quit App After Stream") { v in
      onOff(v.settings?.quitAppAfterStream ?? SettingsModel.defaultQuitAppAfterStream)
    },
    Field(titleKey: "Dim Unfocused Artwork") { v in
      onOff(v.settings?.dimNonHoveredArtwork ?? SettingsModel.defaultDimNonHoveredArtwork)
    },
    Field(titleKey: "Show Performance Overlay") { v in
      onOff(v.settings?.showPerformanceOverlay ?? SettingsModel.defaultShowPerformanceOverlay)
    },
    Field(titleKey: "Show Connection Warnings") { v in
      onOff(v.settings?.showConnectionWarnings ?? SettingsModel.defaultShowConnectionWarnings)
    },
  ]
}
