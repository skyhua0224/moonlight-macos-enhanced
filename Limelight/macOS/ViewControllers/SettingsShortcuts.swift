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
  static let showDisconnectOptionsAction = "showDisconnectOptions"
  static let disconnectStreamAction = "disconnectStream"
  static let closeAndQuitAppAction = "closeAndQuitApp"
  static let reconnectStreamAction = "reconnectStream"
  static let openControlCenterAction = "openControlCenter"
  static let toggleBorderlessWindowedAction = "toggleBorderlessWindowed"

  private static let orderedActions = [
    releaseMouseCaptureAction,
    togglePerformanceOverlayAction,
    toggleMouseModeAction,
    toggleFullscreenControlBallAction,
    showDisconnectOptionsAction,
    disconnectStreamAction,
    closeAndQuitAppAction,
    reconnectStreamAction,
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
    kVK_ANSI_Minus: "-",
    kVK_ANSI_Equal: "=",
    kVK_ANSI_LeftBracket: "[",
    kVK_ANSI_RightBracket: "]",
    kVK_ANSI_Backslash: "\\",
    kVK_ANSI_Semicolon: ";",
    kVK_ANSI_Quote: "'",
    kVK_ANSI_Comma: ",",
    kVK_ANSI_Period: ".",
    kVK_ANSI_Slash: "/",
    kVK_ANSI_Grave: "`",
    kVK_Space: "Space",
    kVK_Tab: "Tab",
    kVK_Return: "Return",
    kVK_Delete: "Delete",
    kVK_ForwardDelete: "Forward Delete",
    kVK_Escape: "Esc",
    kVK_Home: "Home",
    kVK_End: "End",
    kVK_PageUp: "Page Up",
    kVK_PageDown: "Page Down",
    kVK_LeftArrow: "←",
    kVK_RightArrow: "→",
    kVK_UpArrow: "↑",
    kVK_DownArrow: "↓",
    kVK_F1: "F1",
    kVK_F2: "F2",
    kVK_F3: "F3",
    kVK_F4: "F4",
    kVK_F5: "F5",
    kVK_F6: "F6",
    kVK_F7: "F7",
    kVK_F8: "F8",
    kVK_F9: "F9",
    kVK_F10: "F10",
    kVK_F11: "F11",
    kVK_F12: "F12",
    kVK_F13: "F13",
    kVK_F14: "F14",
    kVK_F15: "F15",
    kVK_F16: "F16",
    kVK_F17: "F17",
    kVK_F18: "F18",
    kVK_F19: "F19",
    kVK_F20: "F20",
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
      showDisconnectOptionsAction: StreamShortcut(keyCode: kVK_ANSI_W, modifierFlags: [.command]),
      disconnectStreamAction: StreamShortcut(keyCode: kVK_ANSI_W, modifierFlags: [.control, .option]),
      closeAndQuitAppAction: StreamShortcut(keyCode: kVK_ANSI_W, modifierFlags: [.control, .shift]),
      reconnectStreamAction: StreamShortcut(keyCode: kVK_ANSI_R, modifierFlags: [.control, .option]),
      openControlCenterAction: StreamShortcut(keyCode: kVK_ANSI_C, modifierFlags: [.control, .option]),
      toggleBorderlessWindowedAction: StreamShortcut(keyCode: kVK_ANSI_B, modifierFlags: [.control, .option, .command]),
    ]
  }

  static func migratedShortcuts(_ shortcuts: [String: StreamShortcut]?) -> ([String: StreamShortcut], Bool) {
    var normalized = normalizedShortcuts(shortcuts)
    guard let shortcuts else { return (normalized, false) }

    var didMigrate = false

    if shortcuts[showDisconnectOptionsAction] == nil {
      normalized[showDisconnectOptionsAction] = defaultShortcut(for: showDisconnectOptionsAction)
      didMigrate = true

      if let disconnectShortcut = shortcuts[disconnectStreamAction],
        disconnectShortcut.isEqual(StreamShortcut(keyCode: kVK_ANSI_W, modifierFlags: [.command]))
      {
        normalized[disconnectStreamAction] = defaultShortcut(for: disconnectStreamAction)
      }
    }

    if shortcuts[reconnectStreamAction] == nil {
      normalized[reconnectStreamAction] = defaultShortcut(for: reconnectStreamAction)
      didMigrate = true
    }

    return (normalized, didMigrate)
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
    shortcuts: [String: StreamShortcut],
    keyboardTranslationRules: [KeyboardTranslationRule]
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
      let minimumModifierCount = allowsSingleModifierShortcut(for: action) ? 1 : 2
      if modifierCount(modifiers) < minimumModifierCount {
        return minimumModifierCount == 1 ? "Shortcut requires modifier" : "Shortcut requires two modifiers"
      }
      if keySymbol(for: candidate.keyCode) == nil {
        return "Shortcut key unsupported"
      }
    }

    if isReserved(candidate, action: action) {
      return "Shortcut reserved by system"
    }

    let normalized = normalizedShortcuts(shortcuts)
    for (otherAction, otherShortcut) in normalized where otherAction != action {
      if otherShortcut.isEqual(candidate) {
        return "Shortcut already in use"
      }
    }

    for rule in KeyboardTranslationProfile.normalizedRules(keyboardTranslationRules) {
      if rule.trigger.isEqual(candidate) {
        return "Shortcut already in use"
      }
    }

    return nil
  }

  static func modifierCount(_ flags: NSEvent.ModifierFlags) -> Int {
    modifierDisplayOrder.reduce(into: 0) { count, item in
      if flags.contains(item.0) {
        count += 1
      }
    }
  }

  private static func allowsSingleModifierShortcut(for action: String) -> Bool {
    action == showDisconnectOptionsAction || action == closeAndQuitAppAction
  }

  private static func isReserved(_ shortcut: StreamShortcut, action: String) -> Bool {
    let modifiers = relevantModifierFlags(shortcut.modifierFlags)
    let keyCode = shortcut.keyCode

    if shortcut.modifierOnly {
      return false
    }

    if keyCode == kVK_ANSI_W && modifiers == [.command] {
      return action != showDisconnectOptionsAction
    }

    return (keyCode == kVK_ANSI_F && modifiers == [.control, .command])
      || (keyCode == kVK_ANSI_F && modifiers == [.function])
      || (keyCode == kVK_ANSI_1 && modifiers == [.command])
      || (keyCode == kVK_ANSI_H && modifiers == [.command])
      || (keyCode == kVK_ANSI_Grave && modifiers == [.command])
  }

  @objc static func keySymbol(for keyCode: Int) -> String? {
    supportedKeySymbols[keyCode]
  }

  @objc static func remoteDisplayTokens(for shortcut: StreamShortcut) -> [String] {
    var tokens: [String] = []
    let modifiers = relevantModifierFlags(shortcut.modifierFlags)

    if modifiers.contains(.control) {
      tokens.append("Ctrl")
    }
    if modifiers.contains(.option) {
      tokens.append("Alt")
    }
    if modifiers.contains(.shift) {
      tokens.append("Shift")
    }
    if modifiers.contains(.command) {
      tokens.append("Win")
    }
    if modifiers.contains(.function) {
      tokens.append("Fn")
    }

    if !shortcut.modifierOnly, let key = keySymbol(for: shortcut.keyCode) {
      tokens.append(key)
    }

    return tokens
  }
}

@objc enum KeyboardTranslationOutputKind: Int, CaseIterable {
  case remoteShortcut = 0
  case localAction = 1

  var displayKey: String {
    switch self {
    case .remoteShortcut:
      return "Remote Shortcut"
    case .localAction:
      return "Moonlight Action"
    }
  }
}

@objcMembers
final class KeyboardTranslationRule: NSObject, Codable, Identifiable {
  let id: String
  let trigger: StreamShortcut
  let outputKindRaw: Int
  let outputShortcut: StreamShortcut?
  let localAction: String?

  init(
    id: String = UUID().uuidString,
    trigger: StreamShortcut,
    outputShortcut: StreamShortcut
  ) {
    self.id = id
    self.trigger = StreamShortcut(
      keyCode: trigger.keyCode,
      modifierFlags: trigger.modifierFlags,
      modifierOnly: trigger.modifierOnly)
    self.outputKindRaw = KeyboardTranslationOutputKind.remoteShortcut.rawValue
    self.outputShortcut = StreamShortcut(
      keyCode: outputShortcut.keyCode,
      modifierFlags: outputShortcut.modifierFlags,
      modifierOnly: outputShortcut.modifierOnly)
    self.localAction = nil
    super.init()
  }

  init(
    id: String = UUID().uuidString,
    trigger: StreamShortcut,
    localAction: String
  ) {
    self.id = id
    self.trigger = StreamShortcut(
      keyCode: trigger.keyCode,
      modifierFlags: trigger.modifierFlags,
      modifierOnly: trigger.modifierOnly)
    self.outputKindRaw = KeyboardTranslationOutputKind.localAction.rawValue
    self.outputShortcut = nil
    self.localAction = localAction
    super.init()
  }

  var outputKind: KeyboardTranslationOutputKind {
    KeyboardTranslationOutputKind(rawValue: outputKindRaw) ?? .remoteShortcut
  }

  override func isEqual(_ object: Any?) -> Bool {
    guard let other = object as? KeyboardTranslationRule else { return false }
    let outputsEqual: Bool
    if let outputShortcut, let otherOutputShortcut = other.outputShortcut {
      outputsEqual = outputShortcut.isEqual(otherOutputShortcut)
    } else {
      outputsEqual = outputShortcut == nil && other.outputShortcut == nil
    }

    return id == other.id
      && trigger.isEqual(other.trigger)
      && outputKindRaw == other.outputKindRaw
      && outputsEqual
      && localAction == other.localAction
  }

  override var hash: Int {
    var hasher = Hasher()
    hasher.combine(id)
    hasher.combine(trigger.hash)
    hasher.combine(outputKindRaw)
    hasher.combine(outputShortcut?.hash)
    hasher.combine(localAction)
    return hasher.finalize()
  }
}

@objcMembers
final class KeyboardTranslationProfile: NSObject {
  static let localActionReleaseMouseCapture = StreamShortcutProfile.releaseMouseCaptureAction
  static let localActionTogglePerformanceOverlay =
    StreamShortcutProfile.togglePerformanceOverlayAction
  static let localActionToggleMouseMode = StreamShortcutProfile.toggleMouseModeAction
  static let localActionToggleFullscreenControlBall =
    StreamShortcutProfile.toggleFullscreenControlBallAction
  static let localActionShowDisconnectOptions = StreamShortcutProfile.showDisconnectOptionsAction
  static let localActionDisconnectStream = StreamShortcutProfile.disconnectStreamAction
  static let localActionCloseAndQuitApp = StreamShortcutProfile.closeAndQuitAppAction
  static let localActionReconnectStream = StreamShortcutProfile.reconnectStreamAction
  static let localActionOpenControlCenter = StreamShortcutProfile.openControlCenterAction
  static let localActionToggleBorderlessWindowed =
    StreamShortcutProfile.toggleBorderlessWindowedAction

  private static let orderedLocalActions = [
    localActionShowDisconnectOptions,
    localActionDisconnectStream,
    localActionCloseAndQuitApp,
    localActionReconnectStream,
    localActionOpenControlCenter,
    localActionReleaseMouseCapture,
    localActionToggleMouseMode,
    localActionTogglePerformanceOverlay,
    localActionToggleFullscreenControlBall,
    localActionToggleBorderlessWindowed,
  ]

  @objc static func defaultRules() -> [KeyboardTranslationRule] {
    []
  }

  @objc static func normalizedRules(_ rules: [KeyboardTranslationRule]?) -> [KeyboardTranslationRule] {
    guard let rules else { return defaultRules() }

    var normalized: [KeyboardTranslationRule] = []
    var seenIds = Set<String>()

    for rule in rules {
      let ruleId = seenIds.contains(rule.id) ? UUID().uuidString : rule.id
      seenIds.insert(ruleId)

      switch rule.outputKind {
      case .remoteShortcut:
        guard let outputShortcut = rule.outputShortcut else { continue }
        normalized.append(
          KeyboardTranslationRule(
            id: ruleId,
            trigger: rule.trigger,
            outputShortcut: outputShortcut))
      case .localAction:
        guard let localAction = rule.localAction else { continue }
        normalized.append(
          KeyboardTranslationRule(
            id: ruleId,
            trigger: rule.trigger,
            localAction: localAction))
      }
    }

    return normalized
  }

  @objc static func outputKinds() -> [String] {
    KeyboardTranslationOutputKind.allCases.map(\.displayKey)
  }

  @objc static func localActionOrder() -> [String] {
    orderedLocalActions
  }

  @objc static func localActionTitleKey(for action: String) -> String {
    switch action {
    case localActionReleaseMouseCapture:
      return "Release mouse capture"
    case localActionTogglePerformanceOverlay:
      return "Toggle performance overlay"
    case localActionToggleMouseMode:
      return "Toggle mouse mode"
    case localActionToggleFullscreenControlBall:
      return "Toggle fullscreen control ball"
    case localActionShowDisconnectOptions:
      return "Show Disconnect Options"
    case localActionDisconnectStream:
      return "Disconnect from Stream"
    case localActionCloseAndQuitApp:
      return "Close and Quit App"
    case localActionReconnectStream:
      return "Reconnect Stream"
    case localActionOpenControlCenter:
      return "Open control center"
    case localActionToggleBorderlessWindowed:
      return "Toggle borderless / windowed (advanced)"
    default:
      return action
    }
  }

  @objc static func displayTokens(forTrigger shortcut: StreamShortcut) -> [String] {
    StreamShortcutProfile.displayTokens(for: shortcut)
  }

  @objc static func displayTokens(forRemoteOutput shortcut: StreamShortcut) -> [String] {
    StreamShortcutProfile.remoteDisplayTokens(for: shortcut)
  }

  @objc static func validationErrorKey(
    forTrigger shortcut: StreamShortcut,
    editingRuleId: String?,
    rules: [KeyboardTranslationRule],
    streamShortcuts: [String: StreamShortcut]
  ) -> String? {
    let modifiers = StreamShortcutProfile.relevantModifierFlags(shortcut.modifierFlags)

    if shortcut.modifierOnly || !shortcut.hasKeyCode {
      return "Shortcut must include regular key"
    }
    if StreamShortcutProfile.modifierCount(modifiers) < 1 {
      return "Shortcut requires modifier"
    }
    if StreamShortcutProfile.keySymbol(for: shortcut.keyCode) == nil {
      return "Shortcut key unsupported"
    }

    for rule in normalizedRules(rules) where rule.id != editingRuleId {
      if rule.trigger.isEqual(shortcut) {
        return "Shortcut already in use"
      }
    }

    let normalizedShortcuts = StreamShortcutProfile.normalizedShortcuts(streamShortcuts)
    for (_, streamShortcut) in normalizedShortcuts {
      if streamShortcut.isEqual(shortcut) {
        return "Shortcut already in use"
      }
    }

    return nil
  }

  @objc static func validationErrorKey(forRemoteOutput shortcut: StreamShortcut) -> String? {
    if shortcut.modifierOnly || !shortcut.hasKeyCode {
      return "Shortcut must include regular key"
    }
    if StreamShortcutProfile.keySymbol(for: shortcut.keyCode) == nil {
      return "Shortcut key unsupported"
    }
    return nil
  }
}
