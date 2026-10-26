//
//  StreamDisplay.swift
//  Moonlight for macOS
//
//  This Mac's screens as the resolution and frame rate choices see them, and the
//  size and frame rate a stream asks for on a given screen.
//

import AppKit
import CoreGraphics

/// How the stream window is shown. Stored as `Settings.displayMode`.
enum StreamDisplayMode: Int {
  /// A window locked to the stream's shape; the picture scales with it.
  case fixedWindow = 0
  case fullscreen = 1
  case borderless = 2
  /// A window of any shape; the host resolution follows it.
  case freeWindow = 3
}

/// Whether a borderless stream covers the notch. Stored as `Settings.notchMode`.
enum StreamNotchMode: Int {
  case avoid = 0
  case fill = 1
}

/// How a free window's size becomes a resolution. Stored as `Settings.freeWindowScaleMode`.
enum FreeWindowScaleMode: Int {
  /// Every screen pixel; the host's display scaling follows the Mac's.
  case pixels = 0
  /// One host pixel per point: less to encode, softer on Retina screens.
  case points = 1
}

/// One of this Mac's screens. Remembered by display UUID, so a screen keeps its own
/// choice whichever port it is plugged into.
struct StreamScreen: Codable, Equatable, Identifiable {
  let id: String
  let name: String
  let isBuiltin: Bool
  /// The whole panel in pixels, notch area included.
  let fullPixels: CGSize
  /// The panel below the camera housing in pixels; nil when there is no notch.
  let belowNotchPixels: CGSize?
  let maxRefreshHz: Int
  /// Lowest refresh rate of a screen that varies it (ProMotion, Adaptive-Sync).
  let minRefreshHz: Int?

  var hasNotch: Bool { belowNotchPixels != nil }
  var isVariableRefresh: Bool { minRefreshHz != nil }

  init?(screen: NSScreen) {
    guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    else { return nil }
    let displayID = CGDirectDisplayID(number.uint32Value)
    guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
      let mode = CGDisplayCopyDisplayMode(displayID)
    else { return nil }

    id = CFUUIDCreateString(nil, uuid) as String
    name = screen.localizedName
    isBuiltin = CGDisplayIsBuiltin(displayID) != 0
    fullPixels = CGSize(width: Self.even(CGFloat(mode.pixelWidth)), height: Self.even(CGFloat(mode.pixelHeight)))

    let topInset = screen.safeAreaInsets.top
    if topInset > 0 {
      let scale = max(1, screen.backingScaleFactor)
      belowNotchPixels = CGSize(
        width: fullPixels.width,
        height: Self.even((screen.frame.height - topInset) * scale))
    } else {
      belowNotchPixels = nil
    }

    maxRefreshHz = screen.maximumFramesPerSecond > 0 ? screen.maximumFramesPerSecond : 60
    let shortest = screen.minimumRefreshInterval
    let longest = screen.maximumRefreshInterval
    if shortest > 0, longest > shortest + 0.0005 {
      minRefreshHz = Int((1 / longest).rounded())
    } else {
      minRefreshHz = nil
    }
  }

  static func even(_ value: CGFloat) -> CGFloat {
    let i = Int(value.rounded(.down))
    return CGFloat(i - (i % 2))
  }
}

/// The screens this Mac has shown a stream or the settings on.
enum StreamScreens {
  private static let knownKey = "streamScreens.known"

  /// Screens connected now, built-in first. Each one is also remembered.
  static func connected() -> [StreamScreen] {
    let screens = NSScreen.screens.compactMap(StreamScreen.init(screen:))
      .sorted { $0.isBuiltin && !$1.isBuiltin }
    remember(screens)
    return screens
  }

  /// Connected screens first, then the ones seen before.
  static func known() -> [StreamScreen] {
    let now = connected()
    let ids = Set(now.map(\.id))
    return now + remembered().filter { !ids.contains($0.id) }
  }

  static func forget(_ id: String) {
    store(remembered().filter { $0.id != id })
  }

  static func screen(for screen: NSScreen?) -> StreamScreen? {
    guard let screen else { return nil }
    let info = StreamScreen(screen: screen)
    if let info { remember([info]) }
    return info
  }

  /// The screen the settings are looked at on, for labels such as "Match Display (3024 × 1890)".
  static func current() -> StreamScreen? {
    screen(for: NSApp.keyWindow?.screen ?? NSScreen.main)
  }

  /// The screen a new stream window opens on: the one under the pointer, like the window itself.
  static func streamTargetScreen() -> NSScreen? {
    let mouse = NSEvent.mouseLocation
    return NSScreen.screens.first { NSPointInRect(mouse, $0.frame) } ?? NSScreen.main
  }

  private static func remembered() -> [StreamScreen] {
    guard let data = UserDefaults.standard.data(forKey: knownKey),
      let screens = try? JSONDecoder().decode([StreamScreen].self, from: data)
    else { return [] }
    return screens
  }

  private static func remember(_ screens: [StreamScreen]) {
    guard !screens.isEmpty else { return }
    var all = remembered()
    for screen in screens {
      if let index = all.firstIndex(where: { $0.id == screen.id }) {
        if all[index] == screen { continue }
        all[index] = screen
      } else {
        all.append(screen)
      }
    }
    store(all)
  }

  private static func store(_ screens: [StreamScreen]) {
    if let data = try? JSONEncoder().encode(screens), UserDefaults.standard.data(forKey: knownKey) != data {
      UserDefaults.standard.set(data, forKey: knownKey)
    }
  }
}

/// Resolution and frame rate lists, and what a stream asks for.
enum StreamResolution {
  /// Stored in `Settings.fps` for "Match Display".
  static let matchDisplayFps = -1

  static let presetGroups: [(ratio: String, sizes: [CGSize])] = [
    ("16:9", [CGSize(width: 1280, height: 720), CGSize(width: 1920, height: 1080),
              CGSize(width: 2560, height: 1440), CGSize(width: 3840, height: 2160)]),
    ("16:10", [CGSize(width: 1440, height: 900), CGSize(width: 1920, height: 1200),
               CGSize(width: 2560, height: 1600), CGSize(width: 2880, height: 1800)]),
    ("21:9", [CGSize(width: 2560, height: 1080), CGSize(width: 3440, height: 1440)]),
  ]

  static var presets: [CGSize] { presetGroups.flatMap(\.sizes) }

  static func isPreset(_ size: CGSize) -> Bool { presets.contains(size) }

  static func shortName(_ size: CGSize) -> String? {
    switch (Int(size.width), Int(size.height)) {
    case (1280, 720): return "720p"
    case (1920, 1080): return "1080p"
    case (2560, 1440): return "1440p"
    case (3840, 2160): return "4K"
    default: return nil
    }
  }

  static func label(_ size: CGSize) -> String {
    let dimensions = "\(Int(size.width)) × \(Int(size.height))"
    guard let short = shortName(size) else { return dimensions }
    return "\(dimensions)  \(short)"
  }

  static func refreshLabel(_ screen: StreamScreen) -> String {
    guard let low = screen.minRefreshHz else { return "\(screen.maxRefreshHz) Hz" }
    let kind = screen.isBuiltin ? "ProMotion" : "VRR"
    return "\(kind) \(low)–\(screen.maxRefreshHz) Hz"
  }

  /// What "Match Display" is on this screen. A notch is avoided except where a
  /// borderless window is told to cover it; a window uses the area a fullscreen
  /// stream would, so switching to fullscreen keeps the same picture.
  static func matchDisplaySize(on screen: StreamScreen, mode: StreamDisplayMode, notch: StreamNotchMode) -> CGSize {
    if mode == .borderless && notch == .fill {
      return screen.fullPixels
    }
    return screen.belowNotchPixels ?? screen.fullPixels
  }

  /// The resolution chosen for this screen: its own choice if it has one.
  static func choice(in settings: Settings, screenID: String?) -> CGSize {
    if let screenID, let own = settings.screenResolutions?[screenID] {
      return own
    }
    if settings.matchDisplayResolution ?? false || settings.resolution == SettingsModel.matchDisplayResolutionSentinel {
      return SettingsModel.matchDisplayResolutionSentinel
    }
    if settings.resolution == .zero {
      return settings.customResolution ?? SettingsModel.defaultResolution
    }
    return settings.resolution
  }

  static func displayMode(of settings: Settings) -> StreamDisplayMode {
    StreamDisplayMode(rawValue: settings.displayMode ?? (settings.autoFullscreen ? 1 : 0)) ?? .fixedWindow
  }

  static func notchMode(of settings: Settings) -> StreamNotchMode {
    StreamNotchMode(rawValue: settings.notchMode ?? 0) ?? .avoid
  }

  /// The size a stream asks for on this screen (before resolution scaling).
  static func streamSize(for settings: Settings, mode: StreamDisplayMode, on screen: StreamScreen?) -> CGSize {
    let choice = choice(in: settings, screenID: screen?.id)
    guard let screen else {
      return choice == SettingsModel.matchDisplayResolutionSentinel ? SettingsModel.defaultResolution : choice
    }
    if choice == SettingsModel.matchDisplayResolutionSentinel {
      return matchDisplaySize(on: screen, mode: mode, notch: notchMode(of: settings))
    }
    // The whole panel cannot be shown in fullscreen on a notched screen.
    if mode == .fullscreen, choice == screen.fullPixels, let below = screen.belowNotchPixels {
      return below
    }
    return choice
  }

  static func frameRate(for settings: Settings, on screen: StreamScreen?) -> Int {
    switch settings.fps {
    case matchDisplayFps:
      return min(240, max(30, screen?.maxRefreshHz ?? 60))
    case 0:
      return Int(settings.customFps ?? 60)
    default:
      return settings.fps
    }
  }
}

/// Sizes picked by hand that are not in the preset list, newest first.
enum RecentStreamResolutions {
  private static let key = "streamResolution.recent"
  private static let limit = 3

  static func list() -> [CGSize] {
    (UserDefaults.standard.stringArray(forKey: key) ?? []).compactMap { entry in
      let parts = entry.split(separator: "x").compactMap { Int($0) }
      guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
      return CGSize(width: parts[0], height: parts[1])
    }
  }

  static func note(_ size: CGSize) {
    guard size.width > 0, size.height > 0, !StreamResolution.isPreset(size) else { return }
    var sizes = list().filter { $0 != size }
    sizes.insert(size, at: 0)
    let entries = sizes.prefix(limit).map { "\(Int($0.width))x\(Int($0.height))" }
    UserDefaults.standard.set(Array(entries), forKey: key)
  }
}

/// Free window geometry. The content size is remembered in points across streams.
enum FreeWindowGeometry {
  private static let lastContentSizeKey = "freeWindow.lastContentSize"
  static let minimumContentSize = CGSize(width: 480, height: 270)

  static func lastContentSize() -> CGSize? {
    guard let string = UserDefaults.standard.string(forKey: lastContentSizeKey) else { return nil }
    let size = NSSizeFromString(string)
    return size.width >= minimumContentSize.width && size.height >= minimumContentSize.height ? size : nil
  }

  static func noteContentSize(_ size: CGSize) {
    guard size.width >= minimumContentSize.width, size.height >= minimumContentSize.height else { return }
    UserDefaults.standard.set(NSStringFromSize(size), forKey: lastContentSizeKey)
  }

  static func scaleMode(of settings: Settings) -> FreeWindowScaleMode {
    FreeWindowScaleMode(rawValue: settings.freeWindowScaleMode ?? 0) ?? .pixels
  }

  /// Host pixels per window point.
  static func pixelsPerPoint(for settings: Settings, on screen: NSScreen?) -> CGFloat {
    scaleMode(of: settings) == .pixels ? max(1, screen?.backingScaleFactor ?? 1) : 1
  }

  /// The window's content size, in points, when a stream starts.
  static func initialContentSize(for settings: Settings, on screen: NSScreen?) -> CGSize {
    let visible = screen?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
    let limit = CGSize(width: visible.width * 0.92, height: (visible.height - 28) * 0.92)
    var size: CGSize
    if (settings.freeWindowInitialSize ?? 0) == 0, let last = lastContentSize() {
      size = last
    } else {
      let info = StreamScreens.screen(for: screen)
      let pixels = StreamResolution.streamSize(for: settings, mode: .freeWindow, on: info)
      let scale = pixelsPerPoint(for: settings, on: screen)
      size = CGSize(width: pixels.width / scale, height: pixels.height / scale)
    }
    if size.width > limit.width || size.height > limit.height {
      let factor = min(limit.width / size.width, limit.height / size.height)
      size = CGSize(width: (size.width * factor).rounded(), height: (size.height * factor).rounded())
    }
    return CGSize(
      width: max(minimumContentSize.width, size.width),
      height: max(minimumContentSize.height, size.height))
  }

  /// The stream size for a free window's content size: even, within what encoders take.
  static func streamSize(forContentSize content: CGSize, pixelsPerPoint scale: CGFloat) -> CGSize {
    let width = min(7680, max(64, StreamScreen.even(content.width * scale)))
    let height = min(4320, max(64, StreamScreen.even(content.height * scale)))
    return CGSize(width: width, height: height)
  }
}

// MARK: - Objective-C entry points used when a stream starts

extension SettingsClass {
  /// Size and frame rate for a stream about to open on `screen`, in the profile's display mode.
  @objc static func streamSize(for key: String, screen: NSScreen?) -> CGSize {
    guard let settings = Settings.getSettings(for: key) else { return SettingsModel.defaultResolution }
    let mode = StreamResolution.displayMode(of: settings)
    if mode == .freeWindow {
      let content = FreeWindowGeometry.initialContentSize(for: settings, on: screen)
      return FreeWindowGeometry.streamSize(
        forContentSize: content, pixelsPerPoint: FreeWindowGeometry.pixelsPerPoint(for: settings, on: screen))
    }
    return StreamResolution.streamSize(for: settings, mode: mode, on: StreamScreens.screen(for: screen))
  }

  @objc static func streamFrameRate(for key: String, screen: NSScreen?) -> Int {
    guard let settings = Settings.getSettings(for: key) else { return SettingsModel.defaultFps }
    return StreamResolution.frameRate(for: settings, on: StreamScreens.screen(for: screen))
  }

  @objc static func freeWindowInitialContentSize(for key: String, screen: NSScreen?) -> CGSize {
    guard let settings = Settings.getSettings(for: key) else { return CGSize(width: 1280, height: 720) }
    return FreeWindowGeometry.initialContentSize(for: settings, on: screen)
  }

  @objc static func freeWindowPixelsPerPoint(for key: String, screen: NSScreen?) -> CGFloat {
    guard let settings = Settings.getSettings(for: key) else { return 1 }
    return FreeWindowGeometry.pixelsPerPoint(for: settings, on: screen)
  }

  @objc static func freeWindowUsesPixels(for key: String) -> Bool {
    guard let settings = Settings.getSettings(for: key) else { return true }
    return FreeWindowGeometry.scaleMode(of: settings) == .pixels
  }

  @objc static func freeWindowStreamSize(forContentSize content: CGSize, pixelsPerPoint scale: CGFloat) -> CGSize {
    FreeWindowGeometry.streamSize(forContentSize: content, pixelsPerPoint: scale)
  }

  @objc static func noteFreeWindowContentSize(_ size: CGSize) {
    FreeWindowGeometry.noteContentSize(size)
  }

  /// Whether a borderless window should stay below the notch of `screen`.
  @objc static func borderlessAvoidsNotch(for key: String, screen: NSScreen?) -> Bool {
    guard let settings = Settings.getSettings(for: key),
      let info = StreamScreens.screen(for: screen), info.hasNotch
    else { return false }
    return StreamResolution.notchMode(of: settings) == .avoid
  }

  /// A host seen before that is not Foundation Sunshine cannot follow a free window.
  @objc static func hostKnownNotFoundation(for key: String) -> Bool {
    (UserDefaults.standard.object(forKey: SettingsModel.foundationHostKeyPrefix + key) as? Bool) == false
  }

  /// The window mode picked in the stream menu is the profile's from now on.
  @objc static func setDisplayMode(_ mode: Int, for key: String) {
    guard let settings = Settings.getSettings(for: key), settings.displayMode != mode else { return }
    persist(copy(settings, displayMode: mode), for: key)
  }

  /// A resolution picked in the stream menu: the screen's own choice when it has one,
  /// otherwise the profile's.
  @objc static func setStreamResolution(_ size: CGSize, matchDisplay: Bool, for key: String, screen: NSScreen?) {
    guard let settings = Settings.getSettings(for: key) else { return }
    if let id = StreamScreens.screen(for: screen)?.id, settings.screenResolutions?[id] != nil {
      var updated = copy(settings)
      updated.screenResolutions?[id] = matchDisplay ? SettingsModel.matchDisplayResolutionSentinel : size
      persist(updated, for: key)
      return
    }
    setResolutionAndFps(Int(size.width), Int(size.height), settings.fps, matchDisplay: matchDisplay, for: key)
  }

  @objc static func screenHasOwnResolution(for key: String, screen: NSScreen?) -> Bool {
    guard let id = StreamScreens.screen(for: screen)?.id else { return false }
    return Settings.getSettings(for: key)?.screenResolutions?[id] != nil
  }

  @objc static func setStreamFrameRate(_ fps: Int, for key: String) {
    guard let settings = Settings.getSettings(for: key), settings.fps != fps else { return }
    persist(copy(settings, fps: fps), for: key)
  }

  /// The stream menu's resolution groups: recent sizes, then the presets by aspect ratio.
  /// Each is ["title": String, "sizes": [NSValue]].
  @objc static func resolutionMenuGroups() -> [[String: Any]] {
    var groups: [[String: Any]] = []
    let recent = RecentStreamResolutions.list()
    if !recent.isEmpty {
      groups.append(["title": LanguageManager.shared.localize("Recently Used"),
                     "sizes": recent.map { NSValue(size: $0) }])
    }
    for group in StreamResolution.presetGroups {
      groups.append(["title": group.ratio, "sizes": group.sizes.map { NSValue(size: $0) }])
    }
    return groups
  }

  @objc static func resolutionLabel(_ size: CGSize) -> String {
    StreamResolution.label(size)
  }

  @objc static func matchDisplayFrameRateTitle(screen: NSScreen?) -> String {
    let title = LanguageManager.shared.localize("Match Display")
    guard let info = StreamScreens.screen(for: screen) else { return title }
    return "\(title) · \(StreamResolution.refreshLabel(info))"
  }

  @objc static func noteRecentResolution(_ size: CGSize) {
    RecentStreamResolutions.note(size)
  }

  @objc static func matchDisplayMenuSize(for key: String, screen: NSScreen?) -> CGSize {
    guard let info = StreamScreens.screen(for: screen) else { return .zero }
    let settings = Settings.getSettings(for: key)
    let mode = settings.map(StreamResolution.displayMode(of:)) ?? .fixedWindow
    let notch = settings.map(StreamResolution.notchMode(of:)) ?? .avoid
    return StreamResolution.matchDisplaySize(on: info, mode: mode, notch: notch)
  }
}
