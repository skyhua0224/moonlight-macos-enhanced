//
//  SettingsStore.swift
//  Moonlight for macOS
//
//  Created by Michael Kenny on 16/1/2024.
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//
import AppKit
import CoreGraphics
import Foundation

struct Settings: Encodable, Decodable {
  let resolution: CGSize
  let matchDisplayResolution: Bool?
  let customResolution: CGSize?
  let fps: Int
  let customFps: CGFloat?

  // Streaming preferences parity with moonlight-qt
  let autoAdjustBitrate: Bool?
  let enableYUV444: Bool?
  let ignoreAspectRatio: Bool?
  let showLocalCursor: Bool?
  let enableMicrophone: Bool?
  let streamResolutionScale: Bool?
  let streamResolutionScaleRatio: Int?

  // Remote host display mode override (affects /launch mode parameter)
  let remoteResolution: Bool?
  let remoteResolutionWidth: Int?
  let remoteResolutionHeight: Int?
  let remoteFps: Bool?
  let remoteFpsRate: Int?

  let bitrate: Int
  let customBitrate: Int?
  let unlockMaxBitrate: Bool?
  let codec: Int
  let hdr: Bool
  let framePacing: Int
  let audioOnPC: Bool
  let audioConfiguration: Int
  let enableVsync: Bool?
  let showPerformanceOverlay: Bool?
  let showConnectionWarnings: Bool?
  let captureSystemShortcuts: Bool?
  let volumeLevel: CGFloat?
  let multiController: Bool
  let swapABXYButtons: Bool
  let optimize: Bool

  let autoFullscreen: Bool
  let displayMode: Int?
  let rumble: Bool
  let controllerDriver: Int
  let mouseDriver: Int
  let coreHIDAutoEnabled: Bool?
  let coreHIDMaxMouseReportRate: Int?
  let freeMouseMotionMode: Int?

  let emulateGuide: Bool
  let appArtworkDimensions: CGSize?
  let dimNonHoveredArtwork: Bool

  // Host Settings
  let quitAppAfterStream: Bool?

  // Input Settings
  let absoluteMouseMode: Bool?
  let swapMouseButtons: Bool?
  let reverseScrollDirection: Bool?
  let touchscreenMode: Int?
  let gamepadMouseMode: Bool?
  let mouseMode: Int?
  let pointerSensitivity: CGFloat?
  let wheelScrollSpeed: CGFloat?
  let rewrittenScrollSpeed: CGFloat?
  let gestureScrollSpeed: CGFloat?
  let physicalWheelHighPrecisionScale: CGFloat?
  let smartWheelTailFilter: CGFloat?
  let physicalWheelMode: Int?
  let rewrittenScrollMode: Int?
  let streamShortcuts: [String: StreamShortcut]?
  let upscalingMode: Int?
  let connectionMethod: String?
  let smoothnessLatencyMode: Int?
  let timingBufferLevel: Int?
  let timingPrioritizeResponsiveness: Bool?
  let timingCompatibilityMode: Bool?
  let timingSdrCompatibilityWorkaround: Bool?

  private static func globalProfileKey() -> String {
    SettingsClass.profileKey(for: SettingsModel.globalHostId)
  }

  private func inheritedSettingsForHostProfile() -> Self {
    Settings(
      resolution: resolution,
      matchDisplayResolution: matchDisplayResolution,
      customResolution: customResolution,
      fps: fps,
      customFps: customFps,
      autoAdjustBitrate: autoAdjustBitrate,
      enableYUV444: enableYUV444,
      ignoreAspectRatio: ignoreAspectRatio,
      showLocalCursor: showLocalCursor,
      enableMicrophone: enableMicrophone,
      streamResolutionScale: streamResolutionScale,
      streamResolutionScaleRatio: streamResolutionScaleRatio,
      remoteResolution: remoteResolution,
      remoteResolutionWidth: remoteResolutionWidth,
      remoteResolutionHeight: remoteResolutionHeight,
      remoteFps: remoteFps,
      remoteFpsRate: remoteFpsRate,
      bitrate: bitrate,
      customBitrate: customBitrate,
      unlockMaxBitrate: unlockMaxBitrate,
      codec: codec,
      hdr: hdr,
      framePacing: framePacing,
      audioOnPC: audioOnPC,
      audioConfiguration: audioConfiguration,
      enableVsync: enableVsync,
      showPerformanceOverlay: showPerformanceOverlay,
      showConnectionWarnings: showConnectionWarnings,
      captureSystemShortcuts: captureSystemShortcuts,
      volumeLevel: volumeLevel,
      multiController: multiController,
      swapABXYButtons: swapABXYButtons,
      optimize: optimize,
      autoFullscreen: autoFullscreen,
      displayMode: displayMode,
      rumble: rumble,
      controllerDriver: controllerDriver,
      mouseDriver: mouseDriver,
      coreHIDAutoEnabled: coreHIDAutoEnabled,
      coreHIDMaxMouseReportRate: coreHIDMaxMouseReportRate,
      freeMouseMotionMode: freeMouseMotionMode,
      emulateGuide: emulateGuide,
      appArtworkDimensions: appArtworkDimensions,
      dimNonHoveredArtwork: dimNonHoveredArtwork,
      quitAppAfterStream: quitAppAfterStream,
      absoluteMouseMode: absoluteMouseMode,
      swapMouseButtons: swapMouseButtons,
      reverseScrollDirection: reverseScrollDirection,
      touchscreenMode: touchscreenMode,
      gamepadMouseMode: gamepadMouseMode,
      mouseMode: mouseMode,
      pointerSensitivity: pointerSensitivity,
      wheelScrollSpeed: wheelScrollSpeed,
      rewrittenScrollSpeed: rewrittenScrollSpeed,
      gestureScrollSpeed: gestureScrollSpeed,
      physicalWheelHighPrecisionScale: physicalWheelHighPrecisionScale,
      smartWheelTailFilter: smartWheelTailFilter,
      physicalWheelMode: physicalWheelMode,
      rewrittenScrollMode: rewrittenScrollMode,
      streamShortcuts: streamShortcuts,
      upscalingMode: upscalingMode,
      connectionMethod: nil,
      smoothnessLatencyMode: smoothnessLatencyMode,
      timingBufferLevel: timingBufferLevel,
      timingPrioritizeResponsiveness: timingPrioritizeResponsiveness,
      timingCompatibilityMode: timingCompatibilityMode,
      timingSdrCompatibilityWorkaround: timingSdrCompatibilityWorkaround
    )
  }

  static func getSettings(for key: String) -> Self? {
    if let data = UserDefaults.standard.data(forKey: SettingsClass.profileKey(for: key)) {
      if let settings = (try? PropertyListDecoder().decode(Settings.self, from: data)) ?? nil {
        return settings
      }
    }

    // Fallback to global settings when no host-specific settings exist
    if let data = UserDefaults.standard.data(forKey: globalProfileKey()) {
      if let settings = (try? PropertyListDecoder().decode(Settings.self, from: data)) ?? nil {
        if key == SettingsModel.globalHostId {
          return settings
        }
        return settings.inheritedSettingsForHostProfile()
      }
    }

    return nil
  }
}

extension SettingsClass {
  static func profileKey(for hostId: String) -> String {
    let profileKey = "\(hostId)-moonlightSettings"

    return profileKey
  }

  static func persist(_ settings: Settings, for key: String) {
    if let data = try? PropertyListEncoder().encode(settings) {
      UserDefaults.standard.set(data, forKey: SettingsClass.profileKey(for: key))
    }
  }

  static func copy(
    _ settings: Settings,
    resolution: CGSize? = nil,
    matchDisplayResolution: Bool? = nil,
    customResolution: CGSize?? = nil,
    fps: Int? = nil,
    customFps: CGFloat?? = nil,
    autoAdjustBitrate: Bool? = nil,
    enableYUV444: Bool? = nil,
    streamResolutionScale: Bool? = nil,
    streamResolutionScaleRatio: Int? = nil,
    remoteResolution: Bool? = nil,
    remoteResolutionWidth: Int?? = nil,
    remoteResolutionHeight: Int?? = nil,
    remoteFps: Bool? = nil,
    remoteFpsRate: Int?? = nil,
    bitrate: Int? = nil,
    customBitrate: Int?? = nil,
    codec: Int? = nil,
    hdr: Bool? = nil,
    connectionMethod: String? = nil,
    mouseMode: Int? = nil,
    volumeLevel: CGFloat? = nil,
    streamShortcuts: [String: StreamShortcut]? = nil
  ) -> Settings {
    Settings(
      resolution: resolution ?? settings.resolution,
      matchDisplayResolution: matchDisplayResolution ?? settings.matchDisplayResolution,
      customResolution: customResolution != nil ? customResolution! : settings.customResolution,
      fps: fps ?? settings.fps,
      customFps: customFps != nil ? customFps! : settings.customFps,

      autoAdjustBitrate: autoAdjustBitrate ?? settings.autoAdjustBitrate,
      enableYUV444: enableYUV444 ?? settings.enableYUV444,
      ignoreAspectRatio: settings.ignoreAspectRatio,
      showLocalCursor: settings.showLocalCursor,
      enableMicrophone: settings.enableMicrophone,
      streamResolutionScale: streamResolutionScale ?? settings.streamResolutionScale,
      streamResolutionScaleRatio: streamResolutionScaleRatio ?? settings.streamResolutionScaleRatio,

      remoteResolution: remoteResolution ?? settings.remoteResolution,
      remoteResolutionWidth: remoteResolutionWidth != nil ? remoteResolutionWidth! : settings.remoteResolutionWidth,
      remoteResolutionHeight: remoteResolutionHeight != nil ? remoteResolutionHeight! : settings.remoteResolutionHeight,
      remoteFps: remoteFps ?? settings.remoteFps,
      remoteFpsRate: remoteFpsRate != nil ? remoteFpsRate! : settings.remoteFpsRate,

      bitrate: bitrate ?? settings.bitrate,
      customBitrate: customBitrate != nil ? customBitrate! : settings.customBitrate,
      unlockMaxBitrate: settings.unlockMaxBitrate,
      codec: codec ?? settings.codec,
      hdr: hdr ?? settings.hdr,
      framePacing: settings.framePacing,
      audioOnPC: settings.audioOnPC,
      audioConfiguration: settings.audioConfiguration,
      enableVsync: settings.enableVsync,
      showPerformanceOverlay: settings.showPerformanceOverlay,
      showConnectionWarnings: settings.showConnectionWarnings,
      captureSystemShortcuts: settings.captureSystemShortcuts,
      volumeLevel: volumeLevel ?? settings.volumeLevel,
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
      mouseMode: mouseMode ?? settings.mouseMode,
      pointerSensitivity: settings.pointerSensitivity,
      wheelScrollSpeed: settings.wheelScrollSpeed,
      rewrittenScrollSpeed: settings.rewrittenScrollSpeed,
      gestureScrollSpeed: settings.gestureScrollSpeed,
      physicalWheelHighPrecisionScale: settings.physicalWheelHighPrecisionScale,
      smartWheelTailFilter: settings.smartWheelTailFilter,
      physicalWheelMode: settings.physicalWheelMode,
      rewrittenScrollMode: settings.rewrittenScrollMode,
      streamShortcuts: streamShortcuts ?? settings.streamShortcuts,
      upscalingMode: settings.upscalingMode,
      connectionMethod: connectionMethod ?? settings.connectionMethod,
      smoothnessLatencyMode: settings.smoothnessLatencyMode,
      timingBufferLevel: settings.timingBufferLevel,
      timingPrioritizeResponsiveness: settings.timingPrioritizeResponsiveness,
      timingCompatibilityMode: settings.timingCompatibilityMode,
      timingSdrCompatibilityWorkaround: settings.timingSdrCompatibilityWorkaround
    )
  }

}
