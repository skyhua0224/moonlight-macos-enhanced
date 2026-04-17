//
//  SettingsObjCBridge.swift
//  Moonlight for macOS
//
//  Created by Michael Kenny on 16/1/2024.
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//
import AppKit
import Carbon.HIToolbox
import CoreGraphics
import SwiftUI

extension Notification.Name {
  static let moonlightMouseSettingsDidChange =
    Notification.Name("MoonlightMouseSettingsDidChange")
  static let moonlightInputRuntimeStatusDidChange =
    Notification.Name("MoonlightInputRuntimeStatusDidChange")
  static let moonlightVideoRuntimeStatusDidChange =
    Notification.Name("MoonlightVideoRuntimeStatusDidChange")
}

class SettingsClass: NSObject {
  private struct InputRuntimeStatusSnapshot {
    let summaryKey: String
    let detailKey: String?
  }

  private static let inputRuntimeStatusLock = NSLock()
  private static var mouseRuntimeStatusByHost: [String: InputRuntimeStatusSnapshot] = [:]
  private static var scrollRuntimeStatusByHost: [String: InputRuntimeStatusSnapshot] = [:]
  private static var videoRuntimeStatusByHost: [String: InputRuntimeStatusSnapshot] = [:]
  private static var videoEnhancementRuntimeStatusByHost: [String: InputRuntimeStatusSnapshot] = [:]
  private static var videoFrameInterpolationRuntimeStatusByHost: [String: InputRuntimeStatusSnapshot] =
    [:]

  private static func mouseInputStrategy(for key: String) -> MouseInputDriverStrategy {
    if let settings = Settings.getSettings(for: key) {
      return MouseInputDriverStrategy(persistedRawValue: settings.mouseDriver)
    }

    return MouseInputDriverStrategy.defaultStrategy
  }

  @objc static func getSettings(for key: String) -> [String: Any]? {
    if let settings = Settings.getSettings(for: key) {
      let objcSettings: [String: Any?] = [
        "resolution": settings.resolution,
        "matchDisplayResolution": settings.matchDisplayResolution,
        "customResolution": settings.customResolution,
        "fps": settings.fps,
        "customFps": settings.customFps,
        "autoAdjustBitrate": settings.autoAdjustBitrate ?? true,
        "yuv444": settings.enableYUV444 ?? false,
        "ignoreAspectRatio": settings.ignoreAspectRatio ?? true,
        "showLocalCursor": settings.showLocalCursor ?? false,
        "microphone": settings.enableMicrophone ?? false,
        "streamResolutionScale": settings.streamResolutionScale ?? false,
        "streamResolutionScaleRatio": settings.streamResolutionScaleRatio ?? 100,
        "remoteResolution": settings.remoteResolution ?? false,
        "remoteResolutionWidth": settings.remoteResolutionWidth ?? 0,
        "remoteResolutionHeight": settings.remoteResolutionHeight ?? 0,
        "remoteFps": settings.remoteFps ?? false,
        "remoteFpsRate": settings.remoteFpsRate ?? 0,
        "hdrTransferFunction": settings.hdrTransferFunction
          ?? SettingsModel.hdrTransferFunctionRawValue(
            for: SettingsModel.defaultHdrTransferFunction),
        "hdrMetadataSource": settings.hdrMetadataSource
          ?? SettingsModel.hdrMetadataSourceRawValue(
            for: SettingsModel.defaultHdrMetadataSource),
        "hdrClientDisplayProfile": settings.hdrClientDisplayProfile
          ?? SettingsModel.hdrClientDisplayProfileRawValue(
            for: SettingsModel.defaultHdrClientDisplayProfile),
        "hdrManualMaxBrightness":
          settings.hdrManualMaxBrightness ?? SettingsModel.defaultHdrManualMaxBrightness,
        "hdrManualMinBrightness":
          settings.hdrManualMinBrightness ?? SettingsModel.defaultHdrManualMinBrightness,
        "hdrManualMaxAverageBrightness":
          settings.hdrManualMaxAverageBrightness ?? SettingsModel.defaultHdrManualMaxAverageBrightness,
        "hdrOpticalOutputScale":
          settings.hdrOpticalOutputScale ?? SettingsModel.defaultHdrOpticalOutputScale,
        "hdrHlgViewingEnvironment": settings.hdrHlgViewingEnvironment
          ?? SettingsModel.hdrHlgViewingEnvironmentRawValue(
            for: SettingsModel.defaultHdrHlgViewingEnvironment),
        "hdrEdrStrategy": settings.hdrEdrStrategy
          ?? SettingsModel.hdrEdrStrategyRawValue(
            for: SettingsModel.defaultHdrEdrStrategy),
        "hdrToneMappingPolicy": settings.hdrToneMappingPolicy
          ?? SettingsModel.hdrToneMappingPolicyRawValue(
            for: SettingsModel.defaultHdrToneMappingPolicy),
        "sunshineTargetDisplayName":
          settings.sunshineTargetDisplayName ?? SettingsModel.defaultSunshineTargetDisplayName,
        "sunshineUseVirtualDisplay":
          settings.sunshineUseVirtualDisplay ?? SettingsModel.defaultSunshineUseVirtualDisplay,
        "sunshineScreenMode":
          settings.sunshineScreenMode
          ?? SettingsModel.sunshineScreenModeRawValue(for: SettingsModel.defaultSunshineScreenMode),
        "sunshineHdrBrightnessOverride":
          settings.sunshineHdrBrightnessOverride ?? SettingsModel.defaultSunshineHdrBrightnessOverride,
        "sunshineMaxBrightness":
          settings.sunshineMaxBrightness ?? SettingsModel.defaultSunshineMaxBrightness,
        "sunshineMinBrightness":
          settings.sunshineMinBrightness ?? SettingsModel.defaultSunshineMinBrightness,
        "sunshineMaxAverageBrightness":
          settings.sunshineMaxAverageBrightness ?? SettingsModel.defaultSunshineMaxAverageBrightness,
        "bitrate": settings.bitrate,
        "customBitrate": settings.customBitrate,
        "unlockMaxBitrate": settings.unlockMaxBitrate,
        "codec": settings.codec,
        "videoRendererMode": SettingsModel.videoRendererModeRawValue(
          for: SettingsModel.videoRendererModeSelection(
            for: settings.videoRendererMode
          )),
        "hdr": settings.hdr,
        "framePacing": settings.framePacing,
        "audioOnPC": settings.audioOnPC,
        "audioConfiguration": settings.audioConfiguration,
        "audioOutputMode": settings.audioOutputMode ?? SettingsModel.getInt(
          from: SettingsModel.defaultAudioOutputMode, in: SettingsModel.audioOutputModes),
        "enhancedAudioOutputTarget": settings.enhancedAudioOutputTarget ?? SettingsModel.getInt(
          from: SettingsModel.defaultEnhancedAudioOutputTarget,
          in: SettingsModel.enhancedAudioOutputTargets),
        "enhancedAudioPreset": settings.enhancedAudioPreset ?? SettingsModel.getInt(
          from: SettingsModel.defaultEnhancedAudioPreset, in: SettingsModel.enhancedAudioPresets),
        "enhancedAudioEQLayout": settings.enhancedAudioEQLayout ?? SettingsModel.getInt(
          from: SettingsModel.defaultEnhancedAudioEQLayout, in: SettingsModel.enhancedAudioEQLayouts),
        "enhancedAudioSpatialIntensity":
          settings.enhancedAudioSpatialIntensity ?? SettingsModel.defaultEnhancedAudioSpatialIntensity,
        "enhancedAudioSoundstageWidth":
          settings.enhancedAudioSoundstageWidth ?? SettingsModel.defaultEnhancedAudioSoundstageWidth,
        "enhancedAudioReverbAmount":
          settings.enhancedAudioReverbAmount ?? SettingsModel.defaultEnhancedAudioReverbAmount,
        "enhancedAudioEQGains":
          settings.enhancedAudioEQGains ?? SettingsModel.defaultEnhancedAudioEQGains,
        "enableVsync": settings.enableVsync,
        "showPerformanceOverlay": settings.showPerformanceOverlay,
        "showConnectionWarnings": settings.showConnectionWarnings,
        "captureSystemShortcuts": settings.captureSystemShortcuts,
        "keyboardCompatibilityMode":
          settings.keyboardCompatibilityMode ?? KeyboardCompatibilityMode.defaultMode.rawValue,
        "volumeLevel": settings.volumeLevel,
        "multiController": settings.multiController,
        "swapABXYButtons": settings.swapABXYButtons,
        "optimize": settings.optimize,
        "autoFullscreen": settings.autoFullscreen,
        "displayMode": settings.displayMode ?? (settings.autoFullscreen ? 1 : 0),
        "rumble": settings.rumble,
        "controllerDriver": settings.controllerDriver,
        "mouseDriver": settings.mouseDriver,
        "coreHIDMaxMouseReportRate": settings.coreHIDMaxMouseReportRate
          ?? SettingsModel.defaultCoreHIDMaxMouseReportRate,
        "freeMouseMotionMode":
          settings.freeMouseMotionMode ?? FreeMouseMotionMode.defaultMode.rawValue,
        "emulateGuide": settings.emulateGuide,
        "appArtworkDimensions": settings.appArtworkDimensions,
        "dimNonHoveredArtwork": settings.dimNonHoveredArtwork,
        "quitAppAfterStream": settings.quitAppAfterStream,
        "absoluteMouseMode": settings.absoluteMouseMode,
        "swapMouseButtons": settings.swapMouseButtons,
        "reverseScrollDirection": settings.reverseScrollDirection,
        "gamepadMouseMode": settings.gamepadMouseMode,
        "mouseMode": settings.mouseMode,
        "touchscreenMode": settings.touchscreenMode,
        "pointerSensitivity": settings.pointerSensitivity ?? SettingsModel.defaultPointerSensitivity,
        "wheelScrollSpeed": settings.wheelScrollSpeed ?? SettingsModel.defaultWheelScrollSpeed,
        "rewrittenScrollSpeed":
          settings.rewrittenScrollSpeed ?? SettingsModel.defaultRewrittenScrollSpeed,
        "gestureScrollSpeed": settings.gestureScrollSpeed ?? SettingsModel.defaultGestureScrollSpeed,
        "physicalWheelHighPrecisionScale":
          settings.physicalWheelHighPrecisionScale
          ?? SettingsModel.defaultPhysicalWheelHighPrecisionScale,
        "smartWheelTailFilter":
          settings.smartWheelTailFilter ?? SettingsModel.defaultSmartWheelTailFilter,
        "physicalWheelMode":
          settings.physicalWheelMode ?? PhysicalWheelScrollMode.defaultMode.rawValue,
        "rewrittenScrollMode":
          settings.rewrittenScrollMode ?? RewrittenScrollMode.defaultMode.rawValue,
        "streamShortcuts": StreamShortcutProfile.normalizedShortcuts(settings.streamShortcuts),
        "upscalingMode": settings.upscalingMode,
        "frameInterpolationMode": settings.frameInterpolationMode
          ?? SettingsModel.defaultFrameInterpolationMode,
        // Single source of truth: Settings.connectionMethod (persisted by SettingsModel)
        "connectionMethod": settings.connectionMethod ?? "Auto",
        "smoothnessLatencyMode": settings.smoothnessLatencyMode,
        "timingBufferLevel": settings.timingBufferLevel,
        "timingPrioritizeResponsiveness": settings.timingPrioritizeResponsiveness,
        "displaySyncMode": settings.displaySyncMode
          ?? SettingsModel.displaySyncModeRawValue(
            for: SettingsModel.defaultDisplaySyncMode),
        "frameQueueTarget": settings.frameQueueTarget
          ?? SettingsModel.frameQueueTargetRawValue(
            for: SettingsModel.defaultFrameQueueTarget),
        "timingResponsivenessBias": settings.timingResponsivenessBias
          ?? SettingsModel.responsivenessBiasRawValue(
            for: SettingsModel.defaultResponsivenessBias),
        "allowDrawableTimeoutMode": settings.allowDrawableTimeoutMode
          ?? SettingsModel.allowDrawableTimeoutRawValue(
            for: SettingsModel.defaultAllowDrawableTimeoutMode),
        "timingCompatibilityMode": settings.timingCompatibilityMode,
        "timingSdrCompatibilityWorkaround": settings.timingSdrCompatibilityWorkaround,
      ]

      return objcSettings.compactMapValues { $0 }
    }

    return nil
  }

  @objc static func setConnectionMethod(_ method: String, for key: String) {
    guard let settings = Settings.getSettings(for: key) else {
      return
    }

    let updated = copy(settings, connectionMethod: method)
    persist(updated, for: key)
  }

  // Menu-driven bitrate choice.
  // - When autoAdjust = true, customBitrate is cleared.
  // - When autoAdjust = false, customBitrate should be a Kbps value (e.g. 20000).
  @objc static func setBitrateMode(
    _ autoAdjust: Bool, customBitrateKbps: NSNumber?, for key: String
  ) {
    guard let settings = Settings.getSettings(for: key) else {
      return
    }

    if autoAdjust {
      let updated = copy(settings, autoAdjustBitrate: true, customBitrate: .some(nil))
      persist(updated, for: key)
      return
    }

    let kbps = max(0, customBitrateKbps?.intValue ?? settings.bitrate)
    let updated = copy(
      settings, autoAdjustBitrate: false, bitrate: kbps, customBitrate: .some(kbps))
    persist(updated, for: key)
  }

  // Menu-driven resolution/fps choice.
  // - resolution=MatchDisplayResolutionSentinel means match local display.
  // - resolution=0x0 means custom (not supported via this quick helper yet).
  // - fps=0 means custom (not supported via this quick helper yet).
  @objc static func setResolutionAndFps(
    _ width: Int, _ height: Int, _ fps: Int, matchDisplay: Bool, for key: String
  ) {
    guard let settings = Settings.getSettings(for: key) else { return }

    let newRes =
      matchDisplay
      ? SettingsModel.matchDisplayResolutionSentinel : CGSize(width: width, height: height)
    var updated = Settings(
      resolution: newRes,
      matchDisplayResolution: matchDisplay,
      customResolution: settings.customResolution,
      fps: fps,
      customFps: settings.customFps,

      autoAdjustBitrate: settings.autoAdjustBitrate,  // Preserve auto bitrate setting
      enableYUV444: settings.enableYUV444,
      ignoreAspectRatio: settings.ignoreAspectRatio,
      showLocalCursor: settings.showLocalCursor,
      enableMicrophone: settings.enableMicrophone,
      streamResolutionScale: settings.streamResolutionScale,
      streamResolutionScaleRatio: settings.streamResolutionScaleRatio,

      remoteResolution: settings.remoteResolution,
      remoteResolutionWidth: settings.remoteResolutionWidth,
      remoteResolutionHeight: settings.remoteResolutionHeight,
      remoteFps: settings.remoteFps,
      remoteFpsRate: settings.remoteFpsRate,
      hdrTransferFunction: settings.hdrTransferFunction,
      hdrManualMaxBrightness: settings.hdrManualMaxBrightness,
      hdrManualMinBrightness: settings.hdrManualMinBrightness,
      hdrManualMaxAverageBrightness: settings.hdrManualMaxAverageBrightness,
      sunshineTargetDisplayName: settings.sunshineTargetDisplayName,
      sunshineUseVirtualDisplay: settings.sunshineUseVirtualDisplay,
      sunshineScreenMode: settings.sunshineScreenMode,
      sunshineHdrBrightnessOverride: settings.sunshineHdrBrightnessOverride,
      sunshineMaxBrightness: settings.sunshineMaxBrightness,
      sunshineMinBrightness: settings.sunshineMinBrightness,
      sunshineMaxAverageBrightness: settings.sunshineMaxAverageBrightness,

      bitrate: settings.bitrate,
      customBitrate: settings.customBitrate,
      unlockMaxBitrate: settings.unlockMaxBitrate,
      codec: settings.codec,
      videoRendererMode: settings.videoRendererMode,
      hdr: settings.hdr,
      framePacing: settings.framePacing,
      audioOnPC: settings.audioOnPC,
      audioConfiguration: settings.audioConfiguration,
      audioOutputMode: settings.audioOutputMode,
      enhancedAudioOutputTarget: settings.enhancedAudioOutputTarget,
      enhancedAudioPreset: settings.enhancedAudioPreset,
      enhancedAudioEQLayout: settings.enhancedAudioEQLayout,
      enhancedAudioSpatialIntensity: settings.enhancedAudioSpatialIntensity,
      enhancedAudioSoundstageWidth: settings.enhancedAudioSoundstageWidth,
      enhancedAudioReverbAmount: settings.enhancedAudioReverbAmount,
      enhancedAudioEQGains: settings.enhancedAudioEQGains,
      enableVsync: settings.enableVsync,
      showPerformanceOverlay: settings.showPerformanceOverlay,
      showConnectionWarnings: settings.showConnectionWarnings,
      captureSystemShortcuts: settings.captureSystemShortcuts,
      keyboardCompatibilityMode: settings.keyboardCompatibilityMode,
      volumeLevel: settings.volumeLevel,
      multiController: settings.multiController,
      swapABXYButtons: settings.swapABXYButtons,
      optimize: settings.optimize,

      autoFullscreen: settings.autoFullscreen,
      displayMode: settings.displayMode,
      rumble: settings.rumble,
      controllerDriver: settings.controllerDriver,
      mouseDriver: settings.mouseDriver,
      coreHIDAutoEnabled: settings.coreHIDAutoEnabled,
      coreHIDMaxMouseReportRate: settings.coreHIDMaxMouseReportRate,
      freeMouseMotionMode: settings.freeMouseMotionMode,

      emulateGuide: settings.emulateGuide,
      appArtworkDimensions: settings.appArtworkDimensions,
      dimNonHoveredArtwork: settings.dimNonHoveredArtwork,

      quitAppAfterStream: settings.quitAppAfterStream,

      absoluteMouseMode: settings.absoluteMouseMode,
      swapMouseButtons: settings.swapMouseButtons,
      reverseScrollDirection: settings.reverseScrollDirection,
      touchscreenMode: settings.touchscreenMode,
      gamepadMouseMode: settings.gamepadMouseMode,
      mouseMode: settings.mouseMode,
      pointerSensitivity: settings.pointerSensitivity,
      wheelScrollSpeed: settings.wheelScrollSpeed,
      rewrittenScrollSpeed: settings.rewrittenScrollSpeed,
      gestureScrollSpeed: settings.gestureScrollSpeed,
      physicalWheelHighPrecisionScale: settings.physicalWheelHighPrecisionScale,
      smartWheelTailFilter: settings.smartWheelTailFilter,
      physicalWheelMode: settings.physicalWheelMode,
      rewrittenScrollMode: settings.rewrittenScrollMode,
      streamShortcuts: settings.streamShortcuts,
      upscalingMode: settings.upscalingMode,
      frameInterpolationMode: settings.frameInterpolationMode,
      connectionMethod: settings.connectionMethod,
      smoothnessLatencyMode: settings.smoothnessLatencyMode,
      timingBufferLevel: settings.timingBufferLevel,
      timingPrioritizeResponsiveness: settings.timingPrioritizeResponsiveness,
      timingCompatibilityMode: settings.timingCompatibilityMode,
      timingSdrCompatibilityWorkaround: settings.timingSdrCompatibilityWorkaround
    )

    // Recalculate bitrate if auto is enabled, since resolution changed
    if updated.autoAdjustBitrate == true {
      // If matchDisplay is true, we should try to determine real size, otherwise default to 1080p for calc.
      // We can't easily get display size here without risk, so 1920x1080 is a safe bet for bitrate calc.
      let w = (matchDisplay || width == 0) ? 1920 : width
      let h = (matchDisplay || height == 0) ? 1080 : height
      let newBitrate = SettingsModel.getDefaultBitrateKbps(
        width: w, height: h, fps: fps, yuv444: updated.enableYUV444 ?? false)
      updated = Settings(
        resolution: updated.resolution,
        matchDisplayResolution: updated.matchDisplayResolution,
        customResolution: updated.customResolution,
        fps: updated.fps,
        customFps: updated.customFps,
        autoAdjustBitrate: updated.autoAdjustBitrate,
        enableYUV444: updated.enableYUV444,
        ignoreAspectRatio: updated.ignoreAspectRatio,
        showLocalCursor: updated.showLocalCursor,
        enableMicrophone: updated.enableMicrophone,
        streamResolutionScale: updated.streamResolutionScale,
        streamResolutionScaleRatio: updated.streamResolutionScaleRatio,
        remoteResolution: updated.remoteResolution,
        remoteResolutionWidth: updated.remoteResolutionWidth,
        remoteResolutionHeight: updated.remoteResolutionHeight,
        remoteFps: updated.remoteFps,
        remoteFpsRate: updated.remoteFpsRate,
        hdrTransferFunction: updated.hdrTransferFunction,
        hdrManualMaxBrightness: updated.hdrManualMaxBrightness,
        hdrManualMinBrightness: updated.hdrManualMinBrightness,
        hdrManualMaxAverageBrightness: updated.hdrManualMaxAverageBrightness,
        sunshineTargetDisplayName: updated.sunshineTargetDisplayName,
        sunshineUseVirtualDisplay: updated.sunshineUseVirtualDisplay,
        sunshineScreenMode: updated.sunshineScreenMode,
        sunshineHdrBrightnessOverride: updated.sunshineHdrBrightnessOverride,
        sunshineMaxBrightness: updated.sunshineMaxBrightness,
        sunshineMinBrightness: updated.sunshineMinBrightness,
        sunshineMaxAverageBrightness: updated.sunshineMaxAverageBrightness,
        bitrate: newBitrate,  // Update calculated bitrate
        customBitrate: nil,  // Clear custom since auto is on
        unlockMaxBitrate: updated.unlockMaxBitrate,
        codec: updated.codec,
        videoRendererMode: updated.videoRendererMode,
        hdr: updated.hdr,
        framePacing: updated.framePacing,
        audioOnPC: updated.audioOnPC,
        audioConfiguration: updated.audioConfiguration,
        audioOutputMode: updated.audioOutputMode,
        enhancedAudioOutputTarget: updated.enhancedAudioOutputTarget,
        enhancedAudioPreset: updated.enhancedAudioPreset,
        enhancedAudioEQLayout: updated.enhancedAudioEQLayout,
        enhancedAudioSpatialIntensity: updated.enhancedAudioSpatialIntensity,
        enhancedAudioSoundstageWidth: updated.enhancedAudioSoundstageWidth,
        enhancedAudioReverbAmount: updated.enhancedAudioReverbAmount,
        enhancedAudioEQGains: updated.enhancedAudioEQGains,
        enableVsync: updated.enableVsync,
        showPerformanceOverlay: updated.showPerformanceOverlay,
        showConnectionWarnings: updated.showConnectionWarnings,
        captureSystemShortcuts: updated.captureSystemShortcuts,
        keyboardCompatibilityMode: updated.keyboardCompatibilityMode,
        volumeLevel: updated.volumeLevel,
        multiController: updated.multiController,
        swapABXYButtons: updated.swapABXYButtons,
        optimize: updated.optimize,
        autoFullscreen: updated.autoFullscreen,
        displayMode: updated.displayMode,
        rumble: updated.rumble,
        controllerDriver: updated.controllerDriver,
        mouseDriver: updated.mouseDriver,
        coreHIDAutoEnabled: updated.coreHIDAutoEnabled,
        coreHIDMaxMouseReportRate: updated.coreHIDMaxMouseReportRate,
        freeMouseMotionMode: updated.freeMouseMotionMode,
        emulateGuide: updated.emulateGuide,
        appArtworkDimensions: updated.appArtworkDimensions,
        dimNonHoveredArtwork: updated.dimNonHoveredArtwork,
        quitAppAfterStream: updated.quitAppAfterStream,
        absoluteMouseMode: updated.absoluteMouseMode,
        swapMouseButtons: updated.swapMouseButtons,
        reverseScrollDirection: updated.reverseScrollDirection,
        touchscreenMode: updated.touchscreenMode,
        gamepadMouseMode: updated.gamepadMouseMode,
        mouseMode: updated.mouseMode,
        pointerSensitivity: updated.pointerSensitivity,
        wheelScrollSpeed: updated.wheelScrollSpeed,
        rewrittenScrollSpeed: updated.rewrittenScrollSpeed,
        gestureScrollSpeed: updated.gestureScrollSpeed,
        physicalWheelHighPrecisionScale: updated.physicalWheelHighPrecisionScale,
        smartWheelTailFilter: updated.smartWheelTailFilter,
        physicalWheelMode: updated.physicalWheelMode,
        rewrittenScrollMode: updated.rewrittenScrollMode,
        streamShortcuts: updated.streamShortcuts,
        upscalingMode: updated.upscalingMode,
        frameInterpolationMode: updated.frameInterpolationMode,
        connectionMethod: updated.connectionMethod,
        smoothnessLatencyMode: updated.smoothnessLatencyMode,
        timingBufferLevel: updated.timingBufferLevel,
        timingPrioritizeResponsiveness: updated.timingPrioritizeResponsiveness,
        timingCompatibilityMode: updated.timingCompatibilityMode,
        timingSdrCompatibilityWorkaround: updated.timingSdrCompatibilityWorkaround
      )
    }

    persist(updated, for: key)
  }

  @objc static func setCustomResolution(
    _ width: Int, _ height: Int, _ fps: Int, for key: String
  ) {
    guard let settings = Settings.getSettings(for: key) else { return }

    let updated = Settings(
      resolution: .zero,  // Sentinel for custom
      matchDisplayResolution: false,
      customResolution: CGSize(width: width, height: height),
      fps: 0,  // Sentinel for custom
      customFps: CGFloat(fps),

      autoAdjustBitrate: settings.autoAdjustBitrate,
      enableYUV444: settings.enableYUV444,
      ignoreAspectRatio: settings.ignoreAspectRatio,
      showLocalCursor: settings.showLocalCursor,
      enableMicrophone: settings.enableMicrophone,
      streamResolutionScale: settings.streamResolutionScale,
      streamResolutionScaleRatio: settings.streamResolutionScaleRatio,

      remoteResolution: settings.remoteResolution,
      remoteResolutionWidth: settings.remoteResolutionWidth,
      remoteResolutionHeight: settings.remoteResolutionHeight,
      remoteFps: settings.remoteFps,
      remoteFpsRate: settings.remoteFpsRate,
      hdrTransferFunction: settings.hdrTransferFunction,
      hdrManualMaxBrightness: settings.hdrManualMaxBrightness,
      hdrManualMinBrightness: settings.hdrManualMinBrightness,
      hdrManualMaxAverageBrightness: settings.hdrManualMaxAverageBrightness,
      sunshineTargetDisplayName: settings.sunshineTargetDisplayName,
      sunshineUseVirtualDisplay: settings.sunshineUseVirtualDisplay,
      sunshineScreenMode: settings.sunshineScreenMode,
      sunshineHdrBrightnessOverride: settings.sunshineHdrBrightnessOverride,
      sunshineMaxBrightness: settings.sunshineMaxBrightness,
      sunshineMinBrightness: settings.sunshineMinBrightness,
      sunshineMaxAverageBrightness: settings.sunshineMaxAverageBrightness,

      bitrate: settings.bitrate,
      customBitrate: settings.customBitrate,
      unlockMaxBitrate: settings.unlockMaxBitrate,
      codec: settings.codec,
      videoRendererMode: settings.videoRendererMode,
      hdr: settings.hdr,
      framePacing: settings.framePacing,
      audioOnPC: settings.audioOnPC,
      audioConfiguration: settings.audioConfiguration,
      audioOutputMode: settings.audioOutputMode,
      enhancedAudioOutputTarget: settings.enhancedAudioOutputTarget,
      enhancedAudioPreset: settings.enhancedAudioPreset,
      enhancedAudioEQLayout: settings.enhancedAudioEQLayout,
      enhancedAudioSpatialIntensity: settings.enhancedAudioSpatialIntensity,
      enhancedAudioSoundstageWidth: settings.enhancedAudioSoundstageWidth,
      enhancedAudioReverbAmount: settings.enhancedAudioReverbAmount,
      enhancedAudioEQGains: settings.enhancedAudioEQGains,
      enableVsync: settings.enableVsync,
      showPerformanceOverlay: settings.showPerformanceOverlay,
      showConnectionWarnings: settings.showConnectionWarnings,
      captureSystemShortcuts: settings.captureSystemShortcuts,
      keyboardCompatibilityMode: settings.keyboardCompatibilityMode,
      volumeLevel: settings.volumeLevel,
      multiController: settings.multiController,
      swapABXYButtons: settings.swapABXYButtons,
      optimize: settings.optimize,

      autoFullscreen: settings.autoFullscreen,
      displayMode: settings.displayMode,
      rumble: settings.rumble,
      controllerDriver: settings.controllerDriver,
      mouseDriver: settings.mouseDriver,
      coreHIDAutoEnabled: settings.coreHIDAutoEnabled,
      coreHIDMaxMouseReportRate: settings.coreHIDMaxMouseReportRate,
      freeMouseMotionMode: settings.freeMouseMotionMode,

      emulateGuide: settings.emulateGuide,
      appArtworkDimensions: settings.appArtworkDimensions,
      dimNonHoveredArtwork: settings.dimNonHoveredArtwork,

      quitAppAfterStream: settings.quitAppAfterStream,

      absoluteMouseMode: settings.absoluteMouseMode,
      swapMouseButtons: settings.swapMouseButtons,
      reverseScrollDirection: settings.reverseScrollDirection,
      touchscreenMode: settings.touchscreenMode,
      gamepadMouseMode: settings.gamepadMouseMode,
      mouseMode: settings.mouseMode,
      pointerSensitivity: settings.pointerSensitivity,
      wheelScrollSpeed: settings.wheelScrollSpeed,
      rewrittenScrollSpeed: settings.rewrittenScrollSpeed,
      gestureScrollSpeed: settings.gestureScrollSpeed,
      physicalWheelHighPrecisionScale: settings.physicalWheelHighPrecisionScale,
      smartWheelTailFilter: settings.smartWheelTailFilter,
      physicalWheelMode: settings.physicalWheelMode,
      rewrittenScrollMode: settings.rewrittenScrollMode,
      streamShortcuts: settings.streamShortcuts,
      upscalingMode: settings.upscalingMode,
      frameInterpolationMode: settings.frameInterpolationMode,
      connectionMethod: settings.connectionMethod,
      smoothnessLatencyMode: settings.smoothnessLatencyMode,
      timingBufferLevel: settings.timingBufferLevel,
      timingPrioritizeResponsiveness: settings.timingPrioritizeResponsiveness,
      timingCompatibilityMode: settings.timingCompatibilityMode,
      timingSdrCompatibilityWorkaround: settings.timingSdrCompatibilityWorkaround
    )

    // Recalculate bitrate if auto is enabled
    if updated.autoAdjustBitrate == true {
      // Logic to update bitrate was incomplete and causing unused variable warnings.
      // Leaving this block empty as the original implementation did not persist changes.
    }

    persist(updated, for: key)
  }

  @objc static func applyStreamRecommendation(_ recommendation: StreamRiskRecommendation, for key: String) {
    guard let settings = Settings.getSettings(for: key) else {
      return
    }

    let codec = SettingsModel.getInt(from: recommendation.codecName, in: SettingsModel.videoCodecs)
    let remoteResolutionEnabled = settings.remoteResolution ?? false
    let remoteFpsEnabled = settings.remoteFps ?? false
    let customResolution = CGSize(width: recommendation.width, height: recommendation.height)
    let explicitCustomResolution: CGSize? = customResolution
    let explicitCustomFps: CGFloat? = CGFloat(recommendation.fps)
    let explicitRemoteWidth: Int? = remoteResolutionEnabled ? recommendation.width : nil
    let explicitRemoteHeight: Int? = remoteResolutionEnabled ? recommendation.height : nil
    let explicitRemoteFps: Int? = remoteFpsEnabled ? recommendation.fps : nil

    let updated = copy(
      settings,
      resolution: .zero,
      matchDisplayResolution: false,
      customResolution: .some(explicitCustomResolution),
      fps: 0,
      customFps: .some(explicitCustomFps),
      enableYUV444: recommendation.enableYUV444,
      streamResolutionScale: false,
      streamResolutionScaleRatio: 100,
      remoteResolution: remoteResolutionEnabled,
      remoteResolutionWidth: .some(explicitRemoteWidth),
      remoteResolutionHeight: .some(explicitRemoteHeight),
      remoteFps: remoteFpsEnabled,
      remoteFpsRate: .some(explicitRemoteFps),
      codec: codec,
      hdr: codec != 0 ? settings.hdr : false
    )

    persist(updated, for: key)
  }

  @objc static func setVolumeLevel(_ level: CGFloat, for key: String) {
    guard let settings = Settings.getSettings(for: key) else {
      return
    }

    let clamped = min(1.0, max(0.0, level))
    let updated = copy(settings, volumeLevel: clamped)
    persist(updated, for: key)

    // Keep behavior aligned with SettingsModel (Connection listens for this).
    NotificationCenter.default.post(name: Notification.Name("volumeSettingChanged"), object: nil)
  }

  @objc static func loadMoonlightSettings(for key: String) {
    if let settings = Settings.getSettings(for: key) {
      let dataMan = DataManager()

      func even(_ v: CGFloat) -> CGFloat {
        let i = Int(v.rounded(.down))
        return CGFloat(i - (i % 2))
      }

      func pixelSize(for rect: NSRect, screen: NSScreen) -> CGSize {
        let scale = max(1.0, screen.backingScaleFactor)
        return CGSize(width: even(rect.width * scale), height: even(rect.height * scale))
      }

      func displayPixelSize(fullscreenSafe: Bool) -> CGSize? {
        guard let screen = NSScreen.main else { return nil }
        // Use the display's native pixel size. This matches the panel's physical resolution
        // (e.g. 3840x2160) even when macOS is running in HiDPI scaled mode.

        if fullscreenSafe {
          if #available(macOS 12.0, *) {
            let insets = screen.safeAreaInsets
            let safeFrame = NSRect(
              x: screen.frame.origin.x + insets.left,
              y: screen.frame.origin.y + insets.bottom,
              width: max(0.0, screen.frame.size.width - insets.left - insets.right),
              height: max(0.0, screen.frame.size.height - insets.top - insets.bottom)
            )
            if safeFrame.size.width > 0.0 && safeFrame.size.height > 0.0 {
              return pixelSize(for: safeFrame, screen: screen)
            }
          }
        }

        let displayID: CGDirectDisplayID?
        if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
          as? NSNumber
        {
          displayID = CGDirectDisplayID(screenNumber.uint32Value)
        } else {
          displayID = nil
        }

        guard let displayID, let mode = CGDisplayCopyDisplayMode(displayID) else { return nil }

        let size = CGSize(width: mode.pixelWidth, height: mode.pixelHeight)
        return CGSize(width: even(size.width), height: even(size.height))
      }

      let usingMatchDisplayResolution = settings.matchDisplayResolution ?? false
      let displayMode = settings.displayMode ?? (settings.autoFullscreen ? 1 : 0)
      let fullscreenSafeSize = displayMode == 1 ? displayPixelSize(fullscreenSafe: true) : nil
      let nativeDisplaySize = displayPixelSize(fullscreenSafe: false)

      let dataResolutionWidth: CGFloat
      let dataResolutionHeight: CGFloat
      if usingMatchDisplayResolution, let size = fullscreenSafeSize ?? nativeDisplaySize {
        dataResolutionWidth = size.width
        dataResolutionHeight = size.height
      } else {
        var explicitWidth =
          settings.resolution == .zero
          ? (settings.customResolution?.width ?? 1280) : settings.resolution.width
        var explicitHeight =
          settings.resolution == .zero
          ? (settings.customResolution?.height ?? 720) : settings.resolution.height

        if displayMode == 1,
          let nativeDisplaySize,
          let fullscreenSafeSize,
          Int(explicitWidth) == Int(nativeDisplaySize.width),
          Int(explicitHeight) == Int(nativeDisplaySize.height)
        {
          explicitWidth = fullscreenSafeSize.width
          explicitHeight = fullscreenSafeSize.height
        }

        dataResolutionWidth = explicitWidth
        dataResolutionHeight = explicitHeight
      }
      let dataFps = settings.fps == .zero ? Int(settings.customFps ?? 60.0) : settings.fps
      let dataBitrate = settings.bitrate
      let dataCodec = settings.codec != 0

      // TODO: Add this back when VideoDecoderRenderer gets merged, with frame pacing setting check
      //            let dataFramePacing = SettingsModel.getBool(from: settings.framePacing, in: SettingsModel.pacingOptions)

      dataMan.saveSettings(
        withBitrate: dataBitrate,
        framerate: dataFps,
        height: Int(dataResolutionHeight),
        width: Int(dataResolutionWidth),
        onscreenControls: 0,
        remote: false,
        optimizeGames: settings.optimize,
        multiController: settings.multiController,
        audioOnPC: settings.audioOnPC,
        useHevc: dataCodec,
        enableHdr: settings.hdr,
        btMouseSupport: false
      )
    }
  }

  @objc static func getHostUUID(from address: String) -> String? {
    if let hosts = DataManager().getHosts() as? [TemporaryHost] {
      // Try exact match first
      if let matchingHost = hosts.first(where: { host in
        guard !host.uuid.isEmpty else { return false }
        return host.activeAddress == address
          || host.localAddress == address
          || host.externalAddress == address
          || host.ipv6Address == address
          || host.address == address
      }) {
        return matchingHost.uuid
      }

      // Strip port and try again (activeAddress may include port like "host:57989")
      let strippedAddress = Self.stripPort(from: address)
      if strippedAddress != address {
        if let matchingHost = hosts.first(where: { host in
          guard !host.uuid.isEmpty else { return false }
          let fields = [host.activeAddress, host.localAddress, host.externalAddress, host.ipv6Address, host.address]
          return fields.contains(where: { field in
            guard let field = field else { return false }
            return field == strippedAddress || Self.stripPort(from: field) == strippedAddress
          })
        }) {
          return matchingHost.uuid
        }
      }
    }

    return nil
  }

  private static func stripPort(from address: String) -> String {
    // Handle IPv6 bracket notation [::1]:port
    if address.hasPrefix("["), let closeBracket = address.lastIndex(of: "]") {
      let afterBracket = address[address.index(after: closeBracket)...]
      if afterBracket.hasPrefix(":") {
        return String(address[...closeBracket])
      }
      return address
    }
    // hostname:port or IPv4:port — only strip if there's exactly one colon
    let parts = address.split(separator: ":", maxSplits: 2)
    if parts.count == 2, let _ = Int(parts[1]) {
      return String(parts[0])
    }
    return address
  }

  @objc static func autoFullscreen(for key: String) -> Bool {
    if let settings = Settings.getSettings(for: key) {
      return settings.autoFullscreen
    }

    return SettingsModel.defaultAutoFullscreen
  }

  @objc static func displayMode(for key: String) -> Int {
    if let settings = Settings.getSettings(for: key) {
      if let mode = settings.displayMode {
        return mode
      }
      return settings.autoFullscreen ? 1 : 0
    }

    return SettingsModel.defaultDisplayMode
  }

  @objc static func rumble(for key: String) -> Bool {
    if let settings = Settings.getSettings(for: key) {
      return settings.rumble
    }

    return SettingsModel.defaultRumble
  }

  @objc static func controllerDriver(for key: String) -> Int {
    if let settings = Settings.getSettings(for: key) {
      return settings.controllerDriver
    }

    return SettingsModel.getInt(
      from: SettingsModel.defaultControllerDriver, in: SettingsModel.controllerDrivers)
  }

  @objc static func mouseDriver(for key: String) -> Int {
    mouseInputStrategy(for: key).rawValue
  }

  @objc static func shouldUseGameControllerMouse(for key: String) -> Bool {
    mouseInputStrategy(for: key) == .gameController
  }

  @objc static func shouldAllowCoreHIDMouse(for key: String) -> Bool {
    let strategy = mouseInputStrategy(for: key)
    return strategy == .coreHID || strategy == .automatic
  }

  @objc static func shouldUseCompatibilityMouse(for key: String) -> Bool {
    mouseInputStrategy(for: key) == .compatibility
  }

  @objc static func coreHIDMaxMouseReportRate(for key: String) -> Int {
    if let settings = Settings.getSettings(for: key) {
      return settings.coreHIDMaxMouseReportRate ?? SettingsModel.defaultCoreHIDMaxMouseReportRate
    }
    return SettingsModel.defaultCoreHIDMaxMouseReportRate
  }

  @objc static func freeMouseMotionMode(for key: String) -> Int {
    if let settings = Settings.getSettings(for: key) {
      return settings.freeMouseMotionMode ?? FreeMouseMotionMode.defaultMode.rawValue
    }
    return FreeMouseMotionMode.defaultMode.rawValue
  }

  @objc static func shouldUseHybridFreeMouseMotion(for key: String) -> Bool {
    let mode = FreeMouseMotionMode(persistedRawValue: freeMouseMotionMode(for: key))
    switch mode {
    case .standard:
      return false
    case .highPolling:
      return !shouldUseGameControllerMouse(for: key)
    case .automatic:
      return shouldAllowCoreHIDMouse(for: key) && !shouldUseGameControllerMouse(for: key)
    }
  }

  @objc static func wheelScrollSpeed(for key: String) -> CGFloat {
    if let settings = Settings.getSettings(for: key) {
      return settings.wheelScrollSpeed ?? SettingsModel.defaultWheelScrollSpeed
    }
    return SettingsModel.defaultWheelScrollSpeed
  }

  @objc static func rewrittenScrollSpeed(for key: String) -> CGFloat {
    if let settings = Settings.getSettings(for: key) {
      return settings.rewrittenScrollSpeed ?? SettingsModel.defaultRewrittenScrollSpeed
    }
    return SettingsModel.defaultRewrittenScrollSpeed
  }

  @objc static func gestureScrollSpeed(for key: String) -> CGFloat {
    if let settings = Settings.getSettings(for: key) {
      return settings.gestureScrollSpeed ?? SettingsModel.defaultGestureScrollSpeed
    }
    return SettingsModel.defaultGestureScrollSpeed
  }

  @objc static func physicalWheelHighPrecisionScale(for key: String) -> CGFloat {
    if let settings = Settings.getSettings(for: key) {
      return
        settings.physicalWheelHighPrecisionScale
        ?? SettingsModel.defaultPhysicalWheelHighPrecisionScale
    }
    return SettingsModel.defaultPhysicalWheelHighPrecisionScale
  }

  @objc static func smartWheelTailFilter(for key: String) -> CGFloat {
    if let settings = Settings.getSettings(for: key) {
      return settings.smartWheelTailFilter ?? SettingsModel.defaultSmartWheelTailFilter
    }
    return SettingsModel.defaultSmartWheelTailFilter
  }

  @objc static func physicalWheelMode(for key: String) -> Int {
    if let settings = Settings.getSettings(for: key) {
      return settings.physicalWheelMode ?? PhysicalWheelScrollMode.defaultMode.rawValue
    }
    return PhysicalWheelScrollMode.defaultMode.rawValue
  }

  @objc static func rewrittenScrollMode(for key: String) -> Int {
    if let settings = Settings.getSettings(for: key) {
      return settings.rewrittenScrollMode ?? RewrittenScrollMode.defaultMode.rawValue
    }
    return RewrittenScrollMode.defaultMode.rawValue
  }

  @objc(updateMouseInputRuntimeStatusFor:summaryKey:detailKey:)
  static func updateMouseInputRuntimeStatus(
    for key: String, summaryKey: String, detailKey: String?
  ) {
    updateRuntimeStatus(
      store: &mouseRuntimeStatusByHost,
      hostKey: key,
      summaryKey: summaryKey,
      detailKey: detailKey,
      notificationName: .moonlightInputRuntimeStatusDidChange
    )
  }

  @objc(updateScrollInputRuntimeStatusFor:summaryKey:detailKey:)
  static func updateScrollInputRuntimeStatus(
    for key: String, summaryKey: String, detailKey: String?
  ) {
    updateRuntimeStatus(
      store: &scrollRuntimeStatusByHost,
      hostKey: key,
      summaryKey: summaryKey,
      detailKey: detailKey,
      notificationName: .moonlightInputRuntimeStatusDidChange
    )
  }

  @objc(updateVideoRuntimeStatusFor:summaryKey:detailKey:)
  static func updateVideoRuntimeStatus(
    for key: String, summaryKey: String, detailKey: String?
  ) {
    updateRuntimeStatus(
      store: &videoRuntimeStatusByHost,
      hostKey: key,
      summaryKey: summaryKey,
      detailKey: detailKey,
      notificationName: .moonlightVideoRuntimeStatusDidChange
    )
  }

  @objc(updateVideoEnhancementRuntimeStatusFor:summaryKey:detailKey:)
  static func updateVideoEnhancementRuntimeStatus(
    for key: String, summaryKey: String, detailKey: String?
  ) {
    updateRuntimeStatus(
      store: &videoEnhancementRuntimeStatusByHost,
      hostKey: key,
      summaryKey: summaryKey,
      detailKey: detailKey,
      notificationName: .moonlightVideoRuntimeStatusDidChange
    )
  }

  @objc(updateVideoFrameInterpolationRuntimeStatusFor:summaryKey:detailKey:)
  static func updateVideoFrameInterpolationRuntimeStatus(
    for key: String, summaryKey: String, detailKey: String?
  ) {
    updateRuntimeStatus(
      store: &videoFrameInterpolationRuntimeStatusByHost,
      hostKey: key,
      summaryKey: summaryKey,
      detailKey: detailKey,
      notificationName: .moonlightVideoRuntimeStatusDidChange
    )
  }

  @objc static func mouseInputRuntimeStatusSummaryKey(for key: String) -> String {
    runtimeStatus(for: key, from: mouseRuntimeStatusByHost)?.summaryKey ?? "Mouse Runtime Path Idle"
  }

  @objc static func mouseInputRuntimeStatusDetailKey(for key: String) -> String {
    runtimeStatus(for: key, from: mouseRuntimeStatusByHost)?.detailKey ?? "Mouse Runtime Detail Idle"
  }

  @objc static func scrollInputRuntimeStatusSummaryKey(for key: String) -> String {
    runtimeStatus(for: key, from: scrollRuntimeStatusByHost)?.summaryKey ?? "Scroll Runtime Path Idle"
  }

  @objc static func scrollInputRuntimeStatusDetailKey(for key: String) -> String {
    runtimeStatus(for: key, from: scrollRuntimeStatusByHost)?.detailKey ?? "Scroll Runtime Detail Idle"
  }

  @objc static func videoRuntimeStatusSummaryKey(for key: String) -> String {
    runtimeStatus(for: key, from: videoRuntimeStatusByHost)?.summaryKey ?? "Video Runtime Path Idle"
  }

  @objc static func videoRuntimeStatusDetailKey(for key: String) -> String {
    runtimeStatus(for: key, from: videoRuntimeStatusByHost)?.detailKey ?? "Video Runtime Detail Idle"
  }

  @objc static func videoEnhancementRuntimeStatusSummaryKey(for key: String) -> String {
    runtimeStatus(for: key, from: videoEnhancementRuntimeStatusByHost)?.summaryKey ?? "Off"
  }

  @objc static func videoEnhancementRuntimeStatusDetailKey(for key: String) -> String {
    runtimeStatus(for: key, from: videoEnhancementRuntimeStatusByHost)?.detailKey
      ?? "Video Enhancement Runtime Detail Idle"
  }

  @objc static func videoFrameInterpolationRuntimeStatusSummaryKey(for key: String) -> String {
    runtimeStatus(for: key, from: videoFrameInterpolationRuntimeStatusByHost)?.summaryKey ?? "Off"
  }

  @objc static func videoFrameInterpolationRuntimeStatusDetailKey(for key: String) -> String {
    runtimeStatus(for: key, from: videoFrameInterpolationRuntimeStatusByHost)?.detailKey
      ?? "Video Frame Interpolation Runtime Detail Idle"
  }

  @objc static func mouseMode(for key: String) -> String {
    if let settings = Settings.getSettings(for: key) {
      if let mode = settings.mouseMode {
        return SettingsModel.getString(from: mode, in: SettingsModel.mouseModes)
      }
    }
    return SettingsModel.defaultMouseMode
  }

  @objc static func setMouseMode(_ mode: String, for key: String) {
    guard let settings = Settings.getSettings(for: key) else { return }

    let modeVal = SettingsModel.getInt(from: mode, in: SettingsModel.mouseModes)
    let updated = copy(settings, mouseMode: modeVal)
    persist(updated, for: key)
  }

  @objc static func appArtworkDimensions(for key: String) -> CGSize {
    if let settings = Settings.getSettings(for: key) {
      if let dimensions = settings.appArtworkDimensions {
        return dimensions
      }
    }

    return CGSizeMake(300, 400)
  }

  @objc static func dimNonHoveredArtwork(for key: String) -> Bool {
    if let settings = Settings.getSettings(for: key) {
      return settings.dimNonHoveredArtwork
    }

    return SettingsModel.defaultDimNonHoveredArtwork
  }

  @objc static func volumeLevel(for key: String) -> CGFloat {
    if let settings = Settings.getSettings(for: key) {
      return settings.volumeLevel ?? SettingsModel.defaultVolumeLevel
    }

    return SettingsModel.defaultVolumeLevel
  }

  @objc static func audioConfiguration(for key: String) -> Int {
    if let settings = Settings.getSettings(for: key) {
      return settings.audioConfiguration
    }
    return 0  // Stereo default
  }

  @objc static func audioOutputMode(for key: String) -> Int {
    if let settings = Settings.getSettings(for: key) {
      return settings.audioOutputMode
        ?? SettingsModel.getInt(
          from: SettingsModel.defaultAudioOutputMode, in: SettingsModel.audioOutputModes)
    }
    return SettingsModel.getInt(
      from: SettingsModel.defaultAudioOutputMode, in: SettingsModel.audioOutputModes)
  }

  @objc static func enhancedAudioOutputTarget(for key: String) -> Int {
    if let settings = Settings.getSettings(for: key) {
      return settings.enhancedAudioOutputTarget
        ?? SettingsModel.getInt(
          from: SettingsModel.defaultEnhancedAudioOutputTarget,
          in: SettingsModel.enhancedAudioOutputTargets)
    }
    return SettingsModel.getInt(
      from: SettingsModel.defaultEnhancedAudioOutputTarget,
      in: SettingsModel.enhancedAudioOutputTargets)
  }

  @objc static func enhancedAudioPreset(for key: String) -> Int {
    if let settings = Settings.getSettings(for: key) {
      return settings.enhancedAudioPreset
        ?? SettingsModel.getInt(
          from: SettingsModel.defaultEnhancedAudioPreset, in: SettingsModel.enhancedAudioPresets)
    }
    return SettingsModel.getInt(
      from: SettingsModel.defaultEnhancedAudioPreset, in: SettingsModel.enhancedAudioPresets)
  }

  @objc static func enhancedAudioSpatialIntensity(for key: String) -> CGFloat {
    if let settings = Settings.getSettings(for: key) {
      return settings.enhancedAudioSpatialIntensity
        ?? SettingsModel.defaultEnhancedAudioSpatialIntensity
    }
    return SettingsModel.defaultEnhancedAudioSpatialIntensity
  }

  @objc static func enhancedAudioSoundstageWidth(for key: String) -> CGFloat {
    if let settings = Settings.getSettings(for: key) {
      return settings.enhancedAudioSoundstageWidth
        ?? SettingsModel.defaultEnhancedAudioSoundstageWidth
    }
    return SettingsModel.defaultEnhancedAudioSoundstageWidth
  }

  @objc static func enhancedAudioReverbAmount(for key: String) -> CGFloat {
    if let settings = Settings.getSettings(for: key) {
      return settings.enhancedAudioReverbAmount
        ?? SettingsModel.defaultEnhancedAudioReverbAmount
    }
    return SettingsModel.defaultEnhancedAudioReverbAmount
  }

  @objc static func enhancedAudioEQGains(for key: String) -> [NSNumber] {
    let gains =
      Settings.getSettings(for: key)?.enhancedAudioEQGains
      ?? SettingsModel.defaultEnhancedAudioEQGains
    return gains.map { NSNumber(value: $0) }
  }

  @objc static func videoCodec(for key: String) -> Int {
    if let settings = Settings.getSettings(for: key) {
      return settings.codec
    }

    return SettingsModel.getInt(
      from: SettingsModel.defaultVideoCodec,
      in: SettingsModel.videoCodecs)
  }

  @objc static func enableVsync(for key: String) -> Bool {
    if let settings = Settings.getSettings(for: key) {
      return settings.enableVsync ?? SettingsModel.defaultEnableVsync
    }
    return SettingsModel.defaultEnableVsync
  }

  @objc static func framePacing(for key: String) -> Int {
    if let settings = Settings.getSettings(for: key) {
      return settings.framePacing
    }
    return SettingsModel.getInt(
      from: SettingsModel.defaultPacingOptions,
      in: SettingsModel.pacingOptions)
  }

  @objc static func smoothnessLatencyMode(for key: String) -> Int {
    if let settings = Settings.getSettings(for: key) {
      return settings.smoothnessLatencyMode
        ?? SettingsModel.getInt(
          from: SettingsModel.defaultSmoothnessLatencyMode,
          in: SettingsModel.smoothnessLatencyModes)
    }
    return SettingsModel.getInt(
      from: SettingsModel.defaultSmoothnessLatencyMode,
      in: SettingsModel.smoothnessLatencyModes)
  }

  @objc static func timingBufferLevel(for key: String) -> Int {
    if let settings = Settings.getSettings(for: key) {
      return settings.timingBufferLevel
        ?? SettingsModel.getInt(
          from: SettingsModel.defaultTimingBufferLevel,
          in: SettingsModel.timingBufferLevels)
    }
    return SettingsModel.getInt(
      from: SettingsModel.defaultTimingBufferLevel,
      in: SettingsModel.timingBufferLevels)
  }

  @objc static func timingPrioritizeResponsiveness(for key: String) -> Bool {
    if let settings = Settings.getSettings(for: key) {
      return settings.timingPrioritizeResponsiveness
        ?? SettingsModel.defaultTimingPrioritizeResponsiveness
    }
    return SettingsModel.defaultTimingPrioritizeResponsiveness
  }

  @objc static func timingCompatibilityMode(for key: String) -> Bool {
    if let settings = Settings.getSettings(for: key) {
      return settings.timingCompatibilityMode ?? SettingsModel.defaultTimingCompatibilityMode
    }
    return SettingsModel.defaultTimingCompatibilityMode
  }

  @objc static func timingSdrCompatibilityWorkaround(for key: String) -> Bool {
    if let settings = Settings.getSettings(for: key) {
      return settings.timingSdrCompatibilityWorkaround
        ?? SettingsModel.defaultTimingSdrCompatibilityWorkaround
    }
    return SettingsModel.defaultTimingSdrCompatibilityWorkaround
  }

  private static func updateRuntimeStatus(
    store: inout [String: InputRuntimeStatusSnapshot],
    hostKey: String,
    summaryKey: String,
    detailKey: String?,
    notificationName: Notification.Name
  ) {
    inputRuntimeStatusLock.lock()
    let previous = store[hostKey]
    if previous?.summaryKey == summaryKey && previous?.detailKey == detailKey {
      inputRuntimeStatusLock.unlock()
      return
    }
    store[hostKey] = InputRuntimeStatusSnapshot(summaryKey: summaryKey, detailKey: detailKey)
    inputRuntimeStatusLock.unlock()

    DispatchQueue.main.async {
      NotificationCenter.default.post(
        name: notificationName,
        object: nil,
        userInfo: ["hostKey": hostKey]
      )
    }
  }

  private static func runtimeStatus(
    for key: String,
    from store: [String: InputRuntimeStatusSnapshot]
  ) -> InputRuntimeStatusSnapshot? {
    inputRuntimeStatusLock.lock()
    let snapshot = store[key] ?? store[SettingsModel.globalHostId]
    inputRuntimeStatusLock.unlock()
    return snapshot
  }

  @objc static func showPerformanceOverlay(for key: String) -> Bool {
    if let settings = Settings.getSettings(for: key) {
      return settings.showPerformanceOverlay ?? SettingsModel.defaultShowPerformanceOverlay
    }
    return SettingsModel.defaultShowPerformanceOverlay
  }

  @objc static func showConnectionWarnings(for key: String) -> Bool {
    if let settings = Settings.getSettings(for: key) {
      return settings.showConnectionWarnings ?? SettingsModel.defaultShowConnectionWarnings
    }
    return SettingsModel.defaultShowConnectionWarnings
  }

  @objc static func awdlStabilityHelperEnabled() -> Bool {
    if UserDefaults.standard.object(forKey: SettingsModel.awdlStabilityHelperEnabledKey) != nil {
      return UserDefaults.standard.bool(forKey: SettingsModel.awdlStabilityHelperEnabledKey)
    }
    return SettingsModel.defaultAwdlStabilityHelperEnabled
  }

  @objc static func inputDiagnosticsEnabled() -> Bool {
    if UserDefaults.standard.object(forKey: SettingsModel.debugLogInputDiagnosticsKey) != nil {
      return UserDefaults.standard.bool(forKey: SettingsModel.debugLogInputDiagnosticsKey)
    }
    return SettingsModel.defaultDebugLogInputDiagnostics
  }

  @objc static func awdlStabilityHelperAcknowledged() -> Bool {
    if UserDefaults.standard.object(forKey: SettingsModel.awdlStabilityHelperAcknowledgedKey) != nil {
      return UserDefaults.standard.bool(forKey: SettingsModel.awdlStabilityHelperAcknowledgedKey)
    }
    return SettingsModel.defaultAwdlStabilityHelperAcknowledged
  }

  @objc static func captureSystemShortcuts(for key: String) -> Bool {
    if let settings = Settings.getSettings(for: key) {
      return settings.captureSystemShortcuts ?? SettingsModel.defaultCaptureSystemShortcuts
    }
    return SettingsModel.defaultCaptureSystemShortcuts
  }

  @objc static func keyboardCompatibilityMode(for key: String) -> Int {
    if let settings = Settings.getSettings(for: key) {
      return settings.keyboardCompatibilityMode ?? KeyboardCompatibilityMode.defaultMode.rawValue
    }
    return KeyboardCompatibilityMode.defaultMode.rawValue
  }

  @objc static func quitAppAfterStream(for key: String) -> Bool {
    if let settings = Settings.getSettings(for: key) {
      return settings.quitAppAfterStream ?? SettingsModel.defaultQuitAppAfterStream
    }
    return SettingsModel.defaultQuitAppAfterStream
  }

  @objc static func absoluteMouseMode(for key: String) -> Bool {
    if let settings = Settings.getSettings(for: key) {
      return settings.absoluteMouseMode ?? SettingsModel.defaultAbsoluteMouseMode
    }
    return SettingsModel.defaultAbsoluteMouseMode
  }

  @objc static func swapMouseButtons(for key: String) -> Bool {
    if let settings = Settings.getSettings(for: key) {
      return settings.swapMouseButtons ?? SettingsModel.defaultSwapMouseButtons
    }
    return SettingsModel.defaultSwapMouseButtons
  }

  @objc static func reverseScrollDirection(for key: String) -> Bool {
    if let settings = Settings.getSettings(for: key) {
      return settings.reverseScrollDirection ?? SettingsModel.defaultReverseScrollDirection
    }
    return SettingsModel.defaultReverseScrollDirection
  }

  @objc static func touchscreenMode(for key: String) -> Int {
    if let settings = Settings.getSettings(for: key) {
      return settings.touchscreenMode ?? SettingsModel.defaultTouchscreenMode
    }
    return SettingsModel.defaultTouchscreenMode
  }

  @objc static func gamepadMouseMode(for key: String) -> Bool {
    if let settings = Settings.getSettings(for: key) {
      return settings.gamepadMouseMode ?? SettingsModel.defaultGamepadMouseMode
    }
    return SettingsModel.defaultGamepadMouseMode
  }

  @objc static func pointerSensitivity(for key: String) -> CGFloat {
    if let settings = Settings.getSettings(for: key) {
      return settings.pointerSensitivity ?? SettingsModel.defaultPointerSensitivity
    }
    return SettingsModel.defaultPointerSensitivity
  }

  @objc static func streamShortcuts(for key: String) -> [String: StreamShortcut] {
    if let settings = Settings.getSettings(for: key) {
      return StreamShortcutProfile.normalizedShortcuts(settings.streamShortcuts)
    }
    return StreamShortcutProfile.defaultShortcuts()
  }

  @objc static func keyboardTranslationRules(for key: String) -> [KeyboardTranslationRule] {
    SettingsModel.loadKeyboardTranslationRules(for: key)
  }

  @objc static func upscalingMode(for key: String) -> Int {
    if let settings = Settings.getSettings(for: key) {
      return settings.upscalingMode ?? SettingsModel.defaultUpscalingMode
    }
    return SettingsModel.defaultUpscalingMode
  }
}
