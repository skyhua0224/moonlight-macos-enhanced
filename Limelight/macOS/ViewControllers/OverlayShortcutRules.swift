//
//  OverlayShortcutRules.swift
//  Who else wants a stream shortcut: the system's own shortcuts, a few well-known global ones, and who sits in the key path.
//
//  Why: a user's Control-Option-S never reached the app while Control-Option-Shift-S, -W and -A did (in the
//  user's log). A key another process swallows is gone before any local event monitor sees it. Another app's
//  global hotkey cannot be asked for by registering the same one (RegisterEventHotKey answers noErr to a second process,
//  checked on macOS 27), but the list of event taps can be read (CGGetEventTapList, no permission needed): it names every
//  process that sits in the key event path with an active tap. On that Mac the list was Raycast, WeType (the input
//  method), openlogi-agent, BetterDisplay and ghostty, and this app's own shortcut tap was not installed at all.
//  https://developer.apple.com/documentation/coregraphics/1454426-cgrgetventtaplist
//
//  Foundation, AppKit and Carbon only, so tests/overlay compiles it on its own.
//

import AppKit
import Carbon.HIToolbox

enum OverlayShortcutRules {
  enum Kind: Equatable {
    /// Another action of this app already has the combination.
    case stream
    /// A shortcut of macOS itself (System Settings > Keyboard > Keyboard Shortcuts).
    case system
    /// A global shortcut of a popular app that is usually installed.
    case knownApp
  }

  struct Conflict: Equatable {
    var kind: Kind
    /// What to tell the user: the action, the system function, the app, or "another app".
    var owner: String
  }

  // MARK: - Modifier bits

  /// NSEvent modifier flags to the Carbon mask RegisterEventHotKey wants.
  static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
    var mask: UInt32 = 0
    if flags.contains(.command) { mask |= UInt32(cmdKey) }
    if flags.contains(.option) { mask |= UInt32(optionKey) }
    if flags.contains(.control) { mask |= UInt32(controlKey) }
    if flags.contains(.shift) { mask |= UInt32(shiftKey) }
    return mask
  }

  static let comparedModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

  static func same(_ a: NSEvent.ModifierFlags, _ b: NSEvent.ModifierFlags) -> Bool {
    a.intersection(comparedModifiers) == b.intersection(comparedModifiers)
  }

  // MARK: - macOS shortcuts (com.apple.symbolichotkeys)

  /// One enabled entry of AppleSymbolicHotKeys: id, key code and modifier flags in NSEvent's raw layout.
  struct SystemHotKey: Equatable {
    var id: Int
    var keyCode: Int
    var modifiers: UInt
  }

  /// Reads the enabled entries. `source` is the AppleSymbolicHotKeys dictionary (the live one when nil).
  static func systemHotKeys(from source: [String: Any]? = nil) -> [SystemHotKey] {
    var dict = source
    if dict == nil {
      dict = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString) as? [String: Any]
    }
    guard let dict else { return [] }
    var result: [SystemHotKey] = []
    for (key, raw) in dict {
      guard let id = Int(key), let entry = raw as? [String: Any], (entry["enabled"] as? NSNumber)?.boolValue == true,
            let value = entry["value"] as? [String: Any], let parameters = value["parameters"] as? [Any], parameters.count >= 3,
            let keyCode = (parameters[1] as? NSNumber)?.intValue, let mods = (parameters[2] as? NSNumber)?.uintValue,
            keyCode != 65535 else { continue }
      result.append(SystemHotKey(id: id, keyCode: keyCode, modifiers: mods))
    }
    return result.sorted { $0.id < $1.id }
  }

  /// Names of the symbolic hot key ids that are common; anything else is "macOS shortcut #n".
  static func systemName(_ id: Int) -> String {
    switch id {
    case 28, 29, 30, 31: return "Screenshot"
    case 32, 34: return "Mission Control"
    case 33, 35: return "Application windows"
    case 36, 37: return "Show Desktop"
    case 52: return "Dock hiding"
    case 60, 61: return "Input source switching"
    case 64: return "Spotlight"
    case 65: return "Finder search"
    case 79, 80, 81, 82: return "Move between Spaces"
    case 118...126: return "Switch to Desktop"
    case 163: return "Notification Center"
    case 175: return "Do Not Disturb"
    case 184: return "Screenshot options"
    case 190: return "Quick Note"
    default: return "macOS shortcut #\(id)"
    }
  }

  static func systemConflict(keyCode: Int, flags: NSEvent.ModifierFlags, hotKeys: [SystemHotKey]) -> Conflict? {
    for entry in hotKeys where entry.keyCode == keyCode && same(NSEvent.ModifierFlags(rawValue: entry.modifiers), flags) {
      return Conflict(kind: .system, owner: systemName(entry.id))
    }
    return nil
  }

  // MARK: - Well-known global shortcuts of popular apps

  struct KnownHotKey {
    var app: String
    var keyCode: Int
    var flags: NSEvent.ModifierFlags
  }

  /// Not an inventory of the Mac: the defaults of the launchers and clipboard tools most people have running.
  static let knownApps: [KnownHotKey] = [
    KnownHotKey(app: "Raycast / Alfred", keyCode: kVK_Space, flags: [.option]),
    KnownHotKey(app: "Spotlight", keyCode: kVK_Space, flags: [.command]),
    KnownHotKey(app: "Paste", keyCode: kVK_ANSI_V, flags: [.command, .shift]),
    KnownHotKey(app: "Maccy", keyCode: kVK_ANSI_C, flags: [.command, .shift]),
    KnownHotKey(app: "Rectangle", keyCode: kVK_LeftArrow, flags: [.control, .option]),
    KnownHotKey(app: "Rectangle", keyCode: kVK_RightArrow, flags: [.control, .option]),
    KnownHotKey(app: "Rectangle", keyCode: kVK_Return, flags: [.control, .option]),
  ]

  static func knownConflict(keyCode: Int, flags: NSEvent.ModifierFlags) -> Conflict? {
    for entry in knownApps where entry.keyCode == keyCode && same(entry.flags, flags) {
      return Conflict(kind: .knownApp, owner: entry.app)
    }
    return nil
  }

  // MARK: - This app's own shortcuts

  static func streamConflict(keyCode: Int, flags: NSEvent.ModifierFlags, action: String, shortcuts: [String: StreamShortcut]) -> Conflict? {
    for (other, shortcut) in StreamShortcutProfile.normalizedShortcuts(shortcuts).sorted(by: { $0.key < $1.key })
    where other != action && !shortcut.modifierOnly && shortcut.keyCode == keyCode && same(shortcut.modifierFlags, flags) {
      return Conflict(kind: .stream, owner: StreamShortcutProfile.actionTitleKey(for: other))
    }
    return nil
  }

  // MARK: - Who is in the key path

  /// One installed event tap, as CGGetEventTapList reports it.
  struct TapInfo: Equatable {
    var pid: Int32
    var name: String
    /// An active tap may swallow events; a listen-only one only watches.
    var active: Bool
    var enabled: Bool
    var keyDown: Bool
  }

  /// The processes whose active, enabled tap includes key-down events: the ones that can take a shortcut away.
  /// This process and duplicates are left out; sorted by name.
  static func keyTapOwners(_ taps: [TapInfo], excluding ownPid: Int32) -> [String] {
    let names = taps.filter { $0.active && $0.enabled && $0.keyDown && $0.pid != ownPid }.map { $0.name }
    return Array(Set(names)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
  }

  /// The live list. Names come from the running application when there is one, else from the process name.
  static func installedTaps() -> [TapInfo] {
    var count: UInt32 = 0
    guard CGGetEventTapList(0, nil, &count) == .success, count > 0 else { return [] }
    var list = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
    guard CGGetEventTapList(count, &list, &count) == .success else { return [] }
    let keyDownBit: UInt64 = 1 << UInt64(CGEventType.keyDown.rawValue)
    return list.prefix(Int(count)).map { info in
      let pid = info.tappingProcess
      var name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? ""
      if name.isEmpty {
        var buffer = [CChar](repeating: 0, count: 256)
        proc_name(pid, &buffer, UInt32(buffer.count))
        name = String(cString: buffer)
      }
      return TapInfo(pid: pid, name: name.isEmpty ? "pid \(pid)" : name, active: info.options == .defaultTap, enabled: info.enabled,
                     keyDown: info.eventsOfInterest & keyDownBit != 0)
    }
  }

  /// Every check, the cheap ones first. `action` is excluded from the stream check (a shortcut does not clash with itself).
  static func conflict(keyCode: Int, flags: NSEvent.ModifierFlags, action: String, shortcuts: [String: StreamShortcut],
                       hotKeys: [SystemHotKey]? = nil) -> Conflict? {
    if let c = streamConflict(keyCode: keyCode, flags: flags, action: action, shortcuts: shortcuts) { return c }
    if let c = systemConflict(keyCode: keyCode, flags: flags, hotKeys: hotKeys ?? systemHotKeys()) { return c }
    return knownConflict(keyCode: keyCode, flags: flags)
  }

  /// The outcome of pressing a shortcut while the page listens for it.
  enum TestResult: Equatable {
    case arrived
    case missing(candidates: [String])
  }

  static func testResult(arrived: Bool, taps: [TapInfo], ownPid: Int32) -> TestResult {
    arrived ? .arrived : .missing(candidates: keyTapOwners(taps, excluding: ownPid))
  }

  /// One log line for the stream start: who sits in the key path, so a shortcut that never arrives can be explained.
  static func logLine(owners: [String]) -> String {
    "[shortcut] active key taps held by other processes: " + (owners.isEmpty ? "none" : owners.joined(separator: ", "))
  }
}
