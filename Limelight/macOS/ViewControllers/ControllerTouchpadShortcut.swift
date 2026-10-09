import AppKit
import Foundation
import GameController

struct ControllerTouchpadShortcut: Codable, Equatable {
  enum Button: Int, Codable, CaseIterable, Identifiable {
    case view, menu, leftStick, rightStick, leftShoulder, rightShoulder
    case a, b, x, y, up, down, left, right, touchpad, leftTrigger, rightTrigger
    var id: Int { rawValue }
    var titleKey: String {
      switch self {
      case .view: "Controller Button View"
      case .menu: "Controller Button Menu"
      case .leftStick: "Controller Button L3"
      case .rightStick: "Controller Button R3"
      case .leftShoulder: "Controller Button LB"
      case .rightShoulder: "Controller Button RB"
      case .a: "Controller Button A"
      case .b: "Controller Button B"
      case .x: "Controller Button X"
      case .y: "Controller Button Y"
      case .up: "Controller Button Dpad Up"
      case .down: "Controller Button Dpad Down"
      case .left: "Controller Button Dpad Left"
      case .right: "Controller Button Dpad Right"
      case .touchpad: "Controller Button Touchpad"
      case .leftTrigger: "Controller Button LT"
      case .rightTrigger: "Controller Button RT"
      }
    }
  }
  var buttons: [Button] = []
  var holdSeconds: Double = 0
  var preserveOriginal = false
  static let disabled = Self()
  var buttonMask: UInt32 { buttons.reduce(0) { $0 | (1 << $1.rawValue) } }
  var normalized: Self {
    Self(buttons: Button.allCases.filter { buttons.contains($0) },
         holdSeconds: holdSeconds.isFinite ? min(5, max(0, holdSeconds)) : 0,
         preserveOriginal: preserveOriginal)
  }
}

struct ControllerShortcutProfile: Codable, Equatable {
  static let gamepadMouseAction = "toggleGamepadMouseMode"
  static let touchpadAction = "controllerTouchpadButton"
  static let fullscreenAction = "toggleFullscreen"
  static let captureAction = "captureMouse"
  static var actions: [String] {
    [touchpadAction, gamepadMouseAction] + StreamShortcutProfile.actionOrder() + [fullscreenAction, captureAction]
  }
  var bindings: [String: ControllerTouchpadShortcut] = [:]
  var priorities: [String] = []
  static func defaults(menuEnabled: Bool = true) -> Self {
    var profile = Self()
    if menuEnabled {
      profile.bindings[gamepadMouseAction] = .init(buttons: [.menu], holdSeconds: 2, preserveOriginal: true)
    }
    profile.bindings[StreamShortcutProfile.disconnectStreamAction] =
      .init(buttons: [.view, .menu, .leftShoulder, .rightShoulder], preserveOriginal: true)
    // Both stick clicks held together are rare in games and clear of the
    // disconnect combination.
    profile.bindings[StreamShortcutProfile.openControlCenterAction] =
      .init(buttons: [.leftStick, .rightStick], holdSeconds: 1)
    return profile
  }

  /// Adds defaults introduced after this profile was saved. An action the
  /// user cleared is stored as `.disabled`, so only never-set actions change.
  func addingNewDefaults(menuEnabled: Bool) -> Self {
    var profile = self
    for (action, trigger) in Self.defaults(menuEnabled: menuEnabled).bindings
    where profile.bindings[action] == nil && profile.conflicts(for: action, with: trigger).isEmpty {
      profile.bindings[action] = trigger
    }
    return profile
  }
  func conflicts(for action: String, with trigger: ControllerTouchpadShortcut) -> [String] {
    let mask = trigger.buttonMask
    guard mask != 0 else { return [] }
    return Self.actions.filter { other in
      guard other != action, let existing = bindings[other], existing.buttonMask != 0 else { return false }
      let shared = existing.buttonMask & mask
      return shared == mask || shared == existing.buttonMask
    }
  }
  mutating func assign(_ trigger: ControllerTouchpadShortcut, to action: String, replacing conflicts: [String]) {
    guard Self.actions.contains(action) else { return }
    for other in conflicts { bindings[other] = .disabled }
    bindings[action] = trigger.normalized
    priorities.removeAll { $0 == action }
    priorities.insert(action, at: 0)
  }
  static func titleKey(for action: String) -> String {
    switch action {
    case gamepadMouseAction: "Toggle controller mouse mode"
    case touchpadAction: "Touchpad Button Shortcut"
    case fullscreenAction: "Toggle fullscreen"
    case captureAction: "Restore stream input"
    default: StreamShortcutProfile.actionTitleKey(for: action)
    }
  }
}

/// Which button vocabulary the interface shows for the connected controller.
enum ControllerGlyphFamily {
  case xbox, playStation

  static var connectedPad: GCExtendedGamepad? {
    (GCController.current ?? GCController.controllers().first)?.extendedGamepad
  }

  static var current: ControllerGlyphFamily {
    let pad = connectedPad
    return pad is GCDualSenseGamepad || pad is GCDualShockGamepad ? .playStation : .xbox
  }
}

extension ControllerTouchpadShortcut.Button {
  /// The controller's own element; Apple supplies its glyph per model.
  func element(in pad: GCExtendedGamepad) -> GCControllerButtonInput? {
    switch self {
    case .view: pad.buttonOptions
    case .menu: pad.buttonMenu
    case .leftStick: pad.leftThumbstickButton
    case .rightStick: pad.rightThumbstickButton
    case .leftShoulder: pad.leftShoulder
    case .rightShoulder: pad.rightShoulder
    case .a: pad.buttonA
    case .b: pad.buttonB
    case .x: pad.buttonX
    case .y: pad.buttonY
    case .up: pad.dpad.up
    case .down: pad.dpad.down
    case .left: pad.dpad.left
    case .right: pad.dpad.right
    case .touchpad:
      (pad as? GCDualSenseGamepad)?.touchpadButton ?? (pad as? GCDualShockGamepad)?.touchpadButton
    case .leftTrigger: pad.leftTrigger
    case .rightTrigger: pad.rightTrigger
    }
  }

  /// Same trigger threshold as the input backends (30 of 255).
  func isPressed(in pad: GCExtendedGamepad) -> Bool {
    guard let element = element(in: pad) else { return false }
    switch self {
    case .leftTrigger, .rightTrigger: return element.value >= 30.0 / 255.0
    default: return element.isPressed
    }
  }

  fileprivate func fallbackSymbol(_ family: ControllerGlyphFamily) -> String {
    let playStation = family == .playStation
    switch self {
    case .view: return playStation ? "capsule.portrait" : "rectangle.fill.on.rectangle.fill"
    case .menu: return "line.3.horizontal"
    case .leftStick: return "l.joystick.press.down"
    case .rightStick: return "r.joystick.press.down"
    case .leftShoulder: return playStation ? "l1.rectangle.roundedbottom" : "lb.rectangle.roundedbottom"
    case .rightShoulder: return playStation ? "r1.rectangle.roundedbottom" : "rb.rectangle.roundedbottom"
    case .a: return playStation ? "xmark.circle" : "a.circle"
    case .b: return playStation ? "circle.circle" : "b.circle"
    case .x: return playStation ? "square.circle" : "x.circle"
    case .y: return playStation ? "triangle.circle" : "y.circle"
    case .up: return "dpad.up.filled"
    case .down: return "dpad.down.filled"
    case .left: return "dpad.left.filled"
    case .right: return "dpad.right.filled"
    case .touchpad: return "rectangle.and.hand.point.up.left"
    case .leftTrigger: return playStation ? "l2.rectangle.roundedtop" : "lt.rectangle.roundedtop"
    case .rightTrigger: return playStation ? "r2.rectangle.roundedtop" : "rt.rectangle.roundedtop"
    }
  }

  /// Text used when no symbol exists on this macOS release, and for accessibility.
  func displayName(_ family: ControllerGlyphFamily) -> String {
    guard family == .playStation else {
      return LanguageManager.shared.localize(titleKey)
    }
    switch self {
    case .view: return "Create"
    case .menu: return "Options"
    case .leftStick: return "L3"
    case .rightStick: return "R3"
    case .leftShoulder: return "L1"
    case .rightShoulder: return "R1"
    case .a: return "✕"
    case .b: return "○"
    case .x: return "□"
    case .y: return "△"
    case .leftTrigger: return "L2"
    case .rightTrigger: return "R2"
    default: return LanguageManager.shared.localize(titleKey)
    }
  }

  /// SF Symbol for this button on the connected controller, else a family default.
  func symbolName(_ family: ControllerGlyphFamily = .current) -> String? {
    if family == ControllerGlyphFamily.current, let pad = ControllerGlyphFamily.connectedPad,
       let name = element(in: pad)?.sfSymbolsName,
       NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil {
      return name
    }
    let fallback = fallbackSymbol(family)
    return NSImage(systemSymbolName: fallback, accessibilityDescription: nil) != nil ? fallback : nil
  }
}
