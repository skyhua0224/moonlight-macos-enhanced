//
//  Settings.swift
//  Moonlight for macOS
//
//  Created by Michael Kenny on 16/1/2024.
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

import AppKit
import Carbon.HIToolbox
import CoreGraphics
import SwiftUI

@objcMembers
final class StreamShortcut: NSObject, Codable {
  static let noKeyCode = -1

  let keyCode: Int
  let modifierFlagsRaw: UInt
  let modifierOnly: Bool

  init(keyCode: Int = StreamShortcut.noKeyCode, modifierFlags: NSEvent.ModifierFlags, modifierOnly: Bool = false) {
    self.keyCode = keyCode
    self.modifierFlagsRaw = StreamShortcutProfile.relevantModifierFlags(modifierFlags).rawValue
    self.modifierOnly = modifierOnly
    super.init()
  }

  var modifierFlags: NSEvent.ModifierFlags {
    NSEvent.ModifierFlags(rawValue: modifierFlagsRaw)
  }

  var hasKeyCode: Bool {
    keyCode != StreamShortcut.noKeyCode
  }

  override func isEqual(_ object: Any?) -> Bool {
    guard let other = object as? StreamShortcut else { return false }
    return keyCode == other.keyCode
      && modifierFlagsRaw == other.modifierFlagsRaw
      && modifierOnly == other.modifierOnly
  }

  override var hash: Int {
    var hasher = Hasher()
    hasher.combine(keyCode)
    hasher.combine(modifierFlagsRaw)
    hasher.combine(modifierOnly)
    return hasher.finalize()
  }
}

@objcMembers
final class StreamShortcutProfile: NSObject {
  static let releaseMouseCaptureAction = "releaseMouseCapture"
  static let togglePerformanceOverlayAction = "togglePerformanceOverlay"
  static let toggleMouseModeAction = "toggleMouseMode"
  static let toggleFullscreenControlBallAction = "toggleFullscreenControlBall"
  static let disconnectStreamAction = "disconnectStream"
  static let closeAndQuitAppAction = "closeAndQuitApp"
  static let openControlCenterAction = "openControlCenter"
  static let toggleBorderlessWindowedAction = "toggleBorderlessWindowed"

  private static let orderedActions = [
    releaseMouseCaptureAction,
    togglePerformanceOverlayAction,
    toggleMouseModeAction,
    toggleFullscreenControlBallAction,
    disconnectStreamAction,
    closeAndQuitAppAction,
    openControlCenterAction,
    toggleBorderlessWindowedAction,
  ]

  private static let supportedKeySymbols: [Int: String] = [
    kVK_ANSI_A: "A",
    kVK_ANSI_B: "B",
    kVK_ANSI_C: "C",
    kVK_ANSI_D: "D",
    kVK_ANSI_E: "E",
    kVK_ANSI_F: "F",
    kVK_ANSI_G: "G",
    kVK_ANSI_H: "H",
    kVK_ANSI_I: "I",
    kVK_ANSI_J: "J",
    kVK_ANSI_K: "K",
    kVK_ANSI_L: "L",
    kVK_ANSI_M: "M",
    kVK_ANSI_N: "N",
    kVK_ANSI_O: "O",
    kVK_ANSI_P: "P",
    kVK_ANSI_Q: "Q",
    kVK_ANSI_R: "R",
    kVK_ANSI_S: "S",
    kVK_ANSI_T: "T",
    kVK_ANSI_U: "U",
    kVK_ANSI_V: "V",
    kVK_ANSI_W: "W",
    kVK_ANSI_X: "X",
    kVK_ANSI_Y: "Y",
    kVK_ANSI_Z: "Z",
    kVK_ANSI_0: "0",
    kVK_ANSI_1: "1",
    kVK_ANSI_2: "2",
    kVK_ANSI_3: "3",
    kVK_ANSI_4: "4",
    kVK_ANSI_5: "5",
    kVK_ANSI_6: "6",
    kVK_ANSI_7: "7",
    kVK_ANSI_8: "8",
    kVK_ANSI_9: "9",
  ]

  private static let modifierDisplayOrder: [(NSEvent.ModifierFlags, String)] = [
    (.control, "⌃"),
    (.option, "⌥"),
    (.shift, "⇧"),
    (.command, "⌘"),
    (.function, "fn"),
  ]

  @objc static func relevantModifierFlags(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
    flags.intersection([.control, .option, .shift, .command, .function])
  }

  @objc static func actionOrder() -> [String] {
    orderedActions
  }

  @objc static func defaultShortcuts() -> [String: StreamShortcut] {
    [
      releaseMouseCaptureAction: StreamShortcut(modifierFlags: [.control, .option], modifierOnly: true),
      togglePerformanceOverlayAction: StreamShortcut(keyCode: kVK_ANSI_S, modifierFlags: [.control, .option]),
      toggleMouseModeAction: StreamShortcut(keyCode: kVK_ANSI_M, modifierFlags: [.control, .option]),
      toggleFullscreenControlBallAction: StreamShortcut(keyCode: kVK_ANSI_G, modifierFlags: [.control, .option]),
      disconnectStreamAction: StreamShortcut(keyCode: kVK_ANSI_W, modifierFlags: [.control, .option]),
      closeAndQuitAppAction: StreamShortcut(keyCode: kVK_ANSI_W, modifierFlags: [.control, .shift]),
      openControlCenterAction: StreamShortcut(keyCode: kVK_ANSI_C, modifierFlags: [.control, .option]),
      toggleBorderlessWindowedAction: StreamShortcut(keyCode: kVK_ANSI_B, modifierFlags: [.control, .option, .command]),
    ]
  }

  @objc static func defaultShortcut(for action: String) -> StreamShortcut {
    if let shortcut = defaultShortcuts()[action] {
      return StreamShortcut(
        keyCode: shortcut.keyCode,
        modifierFlags: shortcut.modifierFlags,
        modifierOnly: shortcut.modifierOnly)
    }

    return StreamShortcut(modifierFlags: [.control, .option], modifierOnly: true)
  }

  @objc static func normalizedShortcuts(_ shortcuts: [String: StreamShortcut]?) -> [String: StreamShortcut] {
    var merged = defaultShortcuts()
    guard let shortcuts else { return merged }

    for action in orderedActions {
      guard let shortcut = shortcuts[action] else { continue }
      merged[action] = StreamShortcut(
        keyCode: shortcut.keyCode,
        modifierFlags: shortcut.modifierFlags,
        modifierOnly: shortcut.modifierOnly)
    }

    return merged
  }

  @objc static func displayTokens(for shortcut: StreamShortcut) -> [String] {
    var tokens = modifierDisplayOrder.compactMap { shortcut.modifierFlags.contains($0.0) ? $0.1 : nil }

    if !shortcut.modifierOnly, let key = keySymbol(for: shortcut.keyCode) {
      tokens.append(key)
    }

    return tokens
  }

  @objc static func menuKeyEquivalent(for shortcut: StreamShortcut) -> String {
    guard !shortcut.modifierOnly, let key = keySymbol(for: shortcut.keyCode) else {
      return ""
    }

    return key.lowercased()
  }

  @objc static func menuModifierMask(for shortcut: StreamShortcut) -> UInt {
    guard !shortcut.modifierOnly else { return 0 }
    return shortcut.modifierFlags.rawValue
  }

  @objc static func isModifierOnlyAction(_ action: String) -> Bool {
    action == releaseMouseCaptureAction
  }

  @objc static func validationErrorKey(
    for candidate: StreamShortcut,
    action: String,
    shortcuts: [String: StreamShortcut]
  ) -> String? {
    let modifiers = relevantModifierFlags(candidate.modifierFlags)

    if isModifierOnlyAction(action) {
      if !candidate.modifierOnly || candidate.hasKeyCode {
        return "Shortcut modifiers only required"
      }
      if modifierCount(modifiers) < 2 {
        return "Shortcut requires two modifiers"
      }
    } else {
      if candidate.modifierOnly || !candidate.hasKeyCode {
        return "Shortcut must include regular key"
      }
      if modifierCount(modifiers) < 2 {
        return "Shortcut requires two modifiers"
      }
      if keySymbol(for: candidate.keyCode) == nil {
        return "Shortcut key unsupported"
      }
    }

    if isReserved(candidate) {
      return "Shortcut reserved by system"
    }

    let normalized = normalizedShortcuts(shortcuts)
    for (otherAction, otherShortcut) in normalized where otherAction != action {
      if otherShortcut.isEqual(candidate) {
        return "Shortcut already in use"
      }
    }

    return nil
  }

  private static func modifierCount(_ flags: NSEvent.ModifierFlags) -> Int {
    modifierDisplayOrder.reduce(into: 0) { count, item in
      if flags.contains(item.0) {
        count += 1
      }
    }
  }

  private static func isReserved(_ shortcut: StreamShortcut) -> Bool {
    let modifiers = relevantModifierFlags(shortcut.modifierFlags)
    let keyCode = shortcut.keyCode

    if shortcut.modifierOnly {
      return false
    }

    return (keyCode == kVK_ANSI_W && modifiers == [.command])
      || (keyCode == kVK_ANSI_F && modifiers == [.control, .command])
      || (keyCode == kVK_ANSI_F && modifiers == [.function])
      || (keyCode == kVK_ANSI_1 && modifiers == [.command])
      || (keyCode == kVK_ANSI_H && modifiers == [.command])
      || (keyCode == kVK_ANSI_Grave && modifiers == [.command])
  }

  private static func keySymbol(for keyCode: Int) -> String? {
    supportedKeySymbols[keyCode]
  }
}

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
  let streamShortcuts: [String: StreamShortcut]?
  let upscalingMode: Int?
  let connectionMethod: String?

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
      streamShortcuts: streamShortcuts,
      upscalingMode: upscalingMode,
      connectionMethod: nil
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

class SettingsClass: NSObject {
  static func profileKey(for hostId: String) -> String {
    let profileKey = "\(hostId)-moonlightSettings"

    return profileKey
  }

  private static func persist(_ settings: Settings, for key: String) {
    if let data = try? PropertyListEncoder().encode(settings) {
      UserDefaults.standard.set(data, forKey: SettingsClass.profileKey(for: key))
    }
  }

  private static func copy(
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
      streamShortcuts: streamShortcuts ?? settings.streamShortcuts,
      upscalingMode: settings.upscalingMode,
      connectionMethod: connectionMethod ?? settings.connectionMethod
    )
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
        "displayMode": settings.displayMode ?? (settings.autoFullscreen ? 1 : 0),
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
        "gamepadMouseMode": settings.gamepadMouseMode,
        "mouseMode": settings.mouseMode,
        "touchscreenMode": settings.touchscreenMode,
        "pointerSensitivity": settings.pointerSensitivity ?? SettingsModel.defaultPointerSensitivity,
        "streamShortcuts": StreamShortcutProfile.normalizedShortcuts(settings.streamShortcuts),
        "upscalingMode": settings.upscalingMode,
        // Single source of truth: Settings.connectionMethod (persisted by SettingsModel)
        "connectionMethod": settings.connectionMethod ?? "Auto",
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

      bitrate: settings.bitrate,
      customBitrate: settings.customBitrate,
      unlockMaxBitrate: settings.unlockMaxBitrate,
      codec: settings.codec,
      hdr: settings.hdr,
      framePacing: settings.framePacing,
      audioOnPC: settings.audioOnPC,
      audioConfiguration: settings.audioConfiguration,
      enableVsync: settings.enableVsync,
      showPerformanceOverlay: settings.showPerformanceOverlay,
      showConnectionWarnings: settings.showConnectionWarnings,
      captureSystemShortcuts: settings.captureSystemShortcuts,
      volumeLevel: settings.volumeLevel,
      multiController: settings.multiController,
      swapABXYButtons: settings.swapABXYButtons,
      optimize: settings.optimize,

      autoFullscreen: settings.autoFullscreen,
      displayMode: settings.displayMode,
      rumble: settings.rumble,
      controllerDriver: settings.controllerDriver,
      mouseDriver: settings.mouseDriver,

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
      streamShortcuts: settings.streamShortcuts,
      upscalingMode: settings.upscalingMode,
      connectionMethod: settings.connectionMethod
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
        bitrate: newBitrate,  // Update calculated bitrate
        customBitrate: nil,  // Clear custom since auto is on
        unlockMaxBitrate: updated.unlockMaxBitrate,
        codec: updated.codec,
        hdr: updated.hdr,
        framePacing: updated.framePacing,
        audioOnPC: updated.audioOnPC,
        audioConfiguration: updated.audioConfiguration,
        enableVsync: updated.enableVsync,
        showPerformanceOverlay: updated.showPerformanceOverlay,
        showConnectionWarnings: updated.showConnectionWarnings,
        captureSystemShortcuts: updated.captureSystemShortcuts,
        volumeLevel: updated.volumeLevel,
        multiController: updated.multiController,
        swapABXYButtons: updated.swapABXYButtons,
        optimize: updated.optimize,
        autoFullscreen: updated.autoFullscreen,
        displayMode: updated.displayMode,
        rumble: updated.rumble,
        controllerDriver: updated.controllerDriver,
        mouseDriver: updated.mouseDriver,
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
        streamShortcuts: updated.streamShortcuts,
        upscalingMode: updated.upscalingMode,
        connectionMethod: updated.connectionMethod
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

      bitrate: settings.bitrate,
      customBitrate: settings.customBitrate,
      unlockMaxBitrate: settings.unlockMaxBitrate,
      codec: settings.codec,
      hdr: settings.hdr,
      framePacing: settings.framePacing,
      audioOnPC: settings.audioOnPC,
      audioConfiguration: settings.audioConfiguration,
      enableVsync: settings.enableVsync,
      showPerformanceOverlay: settings.showPerformanceOverlay,
      showConnectionWarnings: settings.showConnectionWarnings,
      captureSystemShortcuts: settings.captureSystemShortcuts,
      volumeLevel: settings.volumeLevel,
      multiController: settings.multiController,
      swapABXYButtons: settings.swapABXYButtons,
      optimize: settings.optimize,

      autoFullscreen: settings.autoFullscreen,
      displayMode: settings.displayMode,
      rumble: settings.rumble,
      controllerDriver: settings.controllerDriver,
      mouseDriver: settings.mouseDriver,

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
      streamShortcuts: settings.streamShortcuts,
      upscalingMode: settings.upscalingMode,
      connectionMethod: settings.connectionMethod
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
      hdr: codec == 1 ? settings.hdr : false
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
    if let settings = Settings.getSettings(for: key) {
      return settings.mouseDriver
    }

    return SettingsModel.getInt(
      from: SettingsModel.defaultMouseDriver, in: SettingsModel.mouseDrivers)
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

  @objc static func upscalingMode(for key: String) -> Int {
    if let settings = Settings.getSettings(for: key) {
      return settings.upscalingMode ?? SettingsModel.defaultUpscalingMode
    }
    return SettingsModel.defaultUpscalingMode
  }
}
