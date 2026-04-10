//
//  SettingsShortcuts.swift
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

