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

extension SettingsModel {
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
    streamShortcuts = StreamShortcutProfile.defaultShortcuts()
    selectedTouchscreenMode = Self.getString(
      from: Self.defaultTouchscreenMode, in: Self.touchscreenModes)
    selectedMouseDriver = Self.defaultMouseDriver
    coreHIDMaxMouseReportRate = Self.defaultCoreHIDMaxMouseReportRate
    selectedFreeMouseMotionMode = Self.defaultFreeMouseMotionMode
    wheelScrollSpeed = Self.defaultWheelScrollSpeed
    rewrittenScrollSpeed = Self.defaultRewrittenScrollSpeed
    gestureScrollSpeed = Self.defaultGestureScrollSpeed
    physicalWheelHighPrecisionScale = Self.defaultPhysicalWheelHighPrecisionScale
    smartWheelTailFilter = Self.defaultSmartWheelTailFilter
    selectedPhysicalWheelMode = Self.defaultPhysicalWheelMode
    selectedRewrittenScrollMode = Self.defaultRewrittenScrollMode

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
    var shouldPersistMigratedMouseSettings = false
    isLoading = true
    defer {
      isLoading = false
      if shouldPersistMigratedMouseSettings {
        saveSettings()
      }
    }

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
      selectedMouseDriver = MouseInputDriverStrategy(persistedRawValue: settings.mouseDriver)
        .displayKey
      coreHIDMaxMouseReportRate =
        settings.coreHIDMaxMouseReportRate ?? Self.defaultCoreHIDMaxMouseReportRate
      selectedFreeMouseMotionMode = FreeMouseMotionMode(
        persistedRawValue: settings.freeMouseMotionMode
      ).displayKey

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
      wheelScrollSpeed = settings.wheelScrollSpeed ?? Self.defaultWheelScrollSpeed
      rewrittenScrollSpeed = settings.rewrittenScrollSpeed ?? Self.defaultRewrittenScrollSpeed
      gestureScrollSpeed = settings.gestureScrollSpeed ?? Self.defaultGestureScrollSpeed
      let highPrecisionMigrationKey =
        "settings.input.physicalWheelHighPrecisionScaleMigration.v1.\(hostId)"
      let storedHighPrecisionScale = settings.physicalWheelHighPrecisionScale
      if let storedHighPrecisionScale,
        abs(storedHighPrecisionScale - Self.legacyDefaultPhysicalWheelHighPrecisionScale) < 0.001,
        !UserDefaults.standard.bool(forKey: highPrecisionMigrationKey)
      {
        physicalWheelHighPrecisionScale = Self.defaultPhysicalWheelHighPrecisionScale
        UserDefaults.standard.set(true, forKey: highPrecisionMigrationKey)
        shouldPersistMigratedMouseSettings = true
      } else {
        physicalWheelHighPrecisionScale =
          storedHighPrecisionScale ?? Self.defaultPhysicalWheelHighPrecisionScale
      }
      smartWheelTailFilter = settings.smartWheelTailFilter ?? Self.defaultSmartWheelTailFilter
      selectedPhysicalWheelMode = PhysicalWheelScrollMode(
        persistedRawValue: settings.physicalWheelMode
      ).displayKey
      selectedRewrittenScrollMode = RewrittenScrollMode(
        persistedRawValue: settings.rewrittenScrollMode
      ).displayKey
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
    let mouseDriver = MouseInputDriverStrategy(selection: selectedMouseDriver).rawValue
    let persistedCoreHIDMaxMouseReportRate = coreHIDMaxMouseReportRate
    let persistedFreeMouseMotionMode = FreeMouseMotionMode(
      selection: selectedFreeMouseMotionMode
    ).rawValue
    let persistedPhysicalWheelMode = PhysicalWheelScrollMode(selection: selectedPhysicalWheelMode)
      .rawValue
    let persistedRewrittenScrollMode = RewrittenScrollMode(
      selection: selectedRewrittenScrollMode
    ).rawValue

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
      coreHIDAutoEnabled: true,
      coreHIDMaxMouseReportRate: persistedCoreHIDMaxMouseReportRate,
      freeMouseMotionMode: persistedFreeMouseMotionMode,
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
      wheelScrollSpeed: wheelScrollSpeed,
      rewrittenScrollSpeed: rewrittenScrollSpeed,
      gestureScrollSpeed: gestureScrollSpeed,
      physicalWheelHighPrecisionScale: physicalWheelHighPrecisionScale,
      smartWheelTailFilter: smartWheelTailFilter,
      physicalWheelMode: persistedPhysicalWheelMode,
      rewrittenScrollMode: persistedRewrittenScrollMode,
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
}
