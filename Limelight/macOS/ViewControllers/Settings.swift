//
//  Settings.swift
//  Moonlight for macOS
//
//  Created by Michael Kenny on 16/1/2024.
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

import AppKit
import CoreGraphics
import SwiftUI

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
  let rumble: Bool
  let controllerDriver: Int
  let mouseDriver: Int

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

  private static func globalProfileKey() -> String {
    SettingsClass.profileKey(for: SettingsModel.globalHostId)
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
        return settings
      }
    }

    return nil
  }
}

class SettingsClass: NSObject {
  static func profileKey(for hostId: String) -> String {
    let profileKey = "\(hostId)-moonlightSettings"

    return profileKey
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
        "bitrate": settings.bitrate,
        "customBitrate": settings.customBitrate,
        "unlockMaxBitrate": settings.unlockMaxBitrate,
        "codec": settings.codec,
        "hdr": settings.hdr,
        "framePacing": settings.framePacing,
        "audioOnPC": settings.audioOnPC,
        "audioConfiguration": settings.audioConfiguration,
        "enableVsync": settings.enableVsync,
        "showPerformanceOverlay": settings.showPerformanceOverlay,
        "showConnectionWarnings": settings.showConnectionWarnings,
        "captureSystemShortcuts": settings.captureSystemShortcuts,
        "volumeLevel": settings.volumeLevel,
        "multiController": settings.multiController,
        "swapABXYButtons": settings.swapABXYButtons,
        "optimize": settings.optimize,
        "autoFullscreen": settings.autoFullscreen,
        "rumble": settings.rumble,
        "controllerDriver": settings.controllerDriver,
        "mouseDriver": settings.mouseDriver,
        "emulateGuide": settings.emulateGuide,
        "appArtworkDimensions": settings.appArtworkDimensions,
        "dimNonHoveredArtwork": settings.dimNonHoveredArtwork,
        "quitAppAfterStream": settings.quitAppAfterStream,
        "absoluteMouseMode": settings.absoluteMouseMode,
        "swapMouseButtons": settings.swapMouseButtons,
        "reverseScrollDirection": settings.reverseScrollDirection,
        "touchscreenMode": settings.touchscreenMode,
      ]

      return objcSettings
    }

    return nil
  }

  @objc static func loadMoonlightSettings(for key: String) {
    if let settings = Settings.getSettings(for: key) {
      let dataMan = DataManager()

      func displayPixelSize() -> CGSize? {
        guard let screen = NSScreen.main else { return nil }
        // Use the display's native pixel size. This matches the panel's physical resolution
        // (e.g. 3840x2160) even when macOS is running in HiDPI scaled mode.

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

        func even(_ v: CGFloat) -> CGFloat {
          let i = Int(v)
          return CGFloat(i - (i % 2))
        }

        return CGSize(width: even(size.width), height: even(size.height))
      }

      let usingMatchDisplayResolution = settings.matchDisplayResolution ?? false

      let dataResolutionWidth: CGFloat
      let dataResolutionHeight: CGFloat
      if usingMatchDisplayResolution, let size = displayPixelSize() {
        dataResolutionWidth = size.width
        dataResolutionHeight = size.height
      } else {
        dataResolutionWidth =
          settings.resolution == .zero
          ? settings.customResolution!.width : settings.resolution.width
        dataResolutionHeight =
          settings.resolution == .zero
          ? settings.customResolution!.height : settings.resolution.height
      }
      let dataFps = settings.fps == .zero ? Int(settings.customFps!) : settings.fps
      let dataBitrate = settings.bitrate
      let dataCodec = SettingsModel.getBool(from: settings.codec, in: SettingsModel.videoCodecs)

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
      if let matchingHost = hosts.first(where: { host in
        return host.activeAddress == address
          || host.localAddress == address
          || host.externalAddress == address
          || host.ipv6Address == address
          || host.address == address
      }) {
        return matchingHost.uuid
      }
    }

    return nil
  }

  @objc static func autoFullscreen(for key: String) -> Bool {
    if let settings = Settings.getSettings(for: key) {
      return settings.autoFullscreen
    }

    return SettingsModel.defaultAutoFullscreen
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
    if let settings = Settings.getSettings(for: key) {
      return settings.mouseDriver
    }

    return SettingsModel.getInt(
      from: SettingsModel.defaultMouseDriver, in: SettingsModel.mouseDrivers)
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

  @objc static func enableVsync(for key: String) -> Bool {
    if let settings = Settings.getSettings(for: key) {
      return settings.enableVsync ?? SettingsModel.defaultEnableVsync
    }
    return SettingsModel.defaultEnableVsync
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

  @objc static func captureSystemShortcuts(for key: String) -> Bool {
    if let settings = Settings.getSettings(for: key) {
      return settings.captureSystemShortcuts ?? SettingsModel.defaultCaptureSystemShortcuts
    }
    return SettingsModel.defaultCaptureSystemShortcuts
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
}
