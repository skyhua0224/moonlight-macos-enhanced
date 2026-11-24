//
//  DeckComputer.swift
//  A0 "电脑优先": the page of a computer leads with the computer itself (icon, name, one quiet
//  status line, 连接 and 串流设置, the desktop thumbnail). Everything else is the same page with
//  small changes:
//    - a running app is part of the computer card: the primary button becomes 继续, 退出 and 桌面
//      sit beside it; R2 turns the thumbnail into the game's art, R3 keeps the desktop thumbnail
//      and puts the running app first in 继续 with a ring
//    - Foundation Sunshine hosts add 大屏模式: a button on the card and a tile in 应用
//  The page is built from sections the user can show, hide and reorder (自定义主页):
//    电脑 / 继续 / 固定 / 应用 / 主机信息 / 最近串流   (电脑 and 应用 are always on)
//  主页样式 picks which sections show: 自动, 简洁, 游戏库, or 自定义 (any edit switches to it).
//  The style and the custom layout are global app preferences kept in the defaults
//  (MLHomeStyle, MLHomeLayout).
//

import AppKit
import CoreImage
import SwiftUI

// MARK: - Sections and style

enum DeckHomeStyle: String, CaseIterable {
  case auto, simple, games, custom
  var title: String { DL("deck.style.\(rawValue)") }
}

/// 主页布局: the computer card with the preview beside it (default), or a full-width hero over
/// the host's wallpaper in the style of the Apple TV app.
enum DeckHomeLayout: String, CaseIterable {
  case card, hero
  var title: String { DL("deck.layout.\(rawValue)") }
}

/// 主机预览: what the preview image of a computer shows. Each falls back to the other, then to a placeholder.
enum DeckHostPreview: String, CaseIterable {
  case wallpaper, lastFrame
  var title: String { DL("deck.preview.\(rawValue)") }
}

/// 应用卡片: portrait posters (default) or 16:9 cards.
enum DeckTileStyle: String, CaseIterable {
  case portrait, landscape
  var title: String { DL("deck.tiles.\(rawValue)") }
}

enum DeckToolbar {
  /// The toolbar's height plus a margin, in window points: where page content may start under a full-bleed hero.
  static let clearance: CGFloat = 66
}

enum DeckColumn {
  /// The widest the page content gets (margins not counted), centred in wider windows.
  static var maxContent: CGFloat { conceptEnv("MLC_COLCAP") == "0" ? .greatestFiniteMagnitude / 4 : 1160 }
}

enum DeckInset {
  /// Leading and trailing space of every content row, from the edge next to the floating sidebar.
  static let page: CGFloat = 40
}

/// How a running app shows on the computer card (concept: both are drawn, one is picked).
enum DeckRunningStyle: String {
  case art = "r2"     // R2: the thumbnail becomes the game's art with a 运行中 badge
  case first = "r3"   // R3: the thumbnail stays the desktop; the app is first in 继续, ringed

  static var current: DeckRunningStyle {
    if let v = conceptEnv("MLC_RUNNING_STYLE"), let style = DeckRunningStyle(rawValue: v) { return style }
    return DeckRunningStyle(rawValue: UserDefaults.standard.string(forKey: "MLRunningStyle") ?? "") ?? .first
  }
}

enum DeckSectionID: String, CaseIterable, Codable {
  case computer, continuePlaying, pinned, apps, hostInfo, recentSessions
  /// Always on, so the page is never empty; 电脑 can be turned off (just the apps, like the old page).
  var isRequired: Bool { self == .apps }
  var title: String { DL("deck.section.\(rawValue)") }
  var symbol: String {
    switch self {
    case .computer: return "display"
    case .continuePlaying: return "clock.arrow.circlepath"
    case .pinned: return "pin"
    case .apps: return "square.grid.2x2"
    case .hostInfo: return "info.circle"
    case .recentSessions: return "list.bullet"
    }
  }
}

struct DeckSectionEntry: Codable, Equatable, Identifiable {
  var id: DeckSectionID
  var visible: Bool
}

final class DeckHomeConfig: ObservableObject {
  static let shared = DeckHomeConfig()
  private static let styleKey = "MLHomeStyle"
  private static let layoutKey = "MLHomeLayout"
  private static let layoutModeKey = "MLHomeLayoutMode"
  private static let previewKey = "MLHostPreview"
  private static let tilesKey = "MLAppTileStyle"
  private static let tileSizeKey = "MLTileSize"
  private static let pageScaleKey = "MLPageScale"
  private static let adaptivePageKey = "MLAdaptivePage"
  private static let adaptiveTilesKey = "MLAdaptiveTiles"
  /// Harness runs force sizes from the environment; those must not be written into the user's defaults.
  private static var harnessOverride: Bool { conceptEnv("MLC_PAGESCALE") != nil || conceptEnv("MLC_TILESIZE") != nil }

  @Published var style: DeckHomeStyle {
    didSet { UserDefaults.standard.set(style.rawValue, forKey: Self.styleKey) }
  }
  @Published var custom: [DeckSectionEntry] {
    didSet { UserDefaults.standard.set(try? JSONEncoder().encode(custom), forKey: Self.layoutKey) }
  }
  @Published var layoutMode: DeckHomeLayout {
    didSet { UserDefaults.standard.set(layoutMode.rawValue, forKey: Self.layoutModeKey) }
  }
  @Published var preview: DeckHostPreview {
    didSet { UserDefaults.standard.set(preview.rawValue, forKey: Self.previewKey) }
  }
  @Published var tiles: DeckTileStyle {
    didSet { UserDefaults.standard.set(tiles.rawValue, forKey: Self.tilesKey) }
  }
  /// Width of a portrait app tile in points (the slider in 自定义主页); landscape tiles scale with it.
  /// Kept globally.
  @Published var tileSize: Double {
    didSet { if !Self.harnessOverride { UserDefaults.standard.set(tileSize, forKey: Self.tileSizeKey) } }
  }
  /// Zoom of the whole host page (header, preview, form, shelves, grid and their text), 0.85 to 1.3.
  /// Kept globally; the sidebar is not part of it.
  @Published var pageScale: Double {
    didSet { if !Self.harnessOverride { UserDefaults.standard.set(pageScale, forKey: Self.pageScaleKey) } }
  }
  /// 自适应大小 (on by default): the page scale and the tile size follow the window. Moving a slider by hand
  /// turns it off for that one; 自动 (or ⌘0 for the page) brings it back.
  @Published var adaptivePage: Bool {
    didSet { if !Self.harnessOverride { UserDefaults.standard.set(adaptivePage, forKey: Self.adaptivePageKey) } }
  }
  @Published var adaptiveTiles: Bool {
    didSet { if !Self.harnessOverride { UserDefaults.standard.set(adaptiveTiles, forKey: Self.adaptiveTilesKey) } }
  }
  /// What the automatic mode currently comes to (written by the page), so the sliders can show it.
  /// Not @Published: they change on every frame of a window drag, and publishing them would run the whole
  /// page's body a second time per frame. The popover reads them when it draws.
  var autoPageScale: Double = 1.0
  var autoTileSize: Double = 132
  var adaptive: Bool { adaptiveTiles }

  static var defaultLayout: [DeckSectionEntry] {
    DeckSectionID.allCases.map { DeckSectionEntry(id: $0, visible: [.computer, .continuePlaying, .pinned, .apps].contains($0)) }
  }

  init() {
    var style = DeckHomeStyle(rawValue: UserDefaults.standard.string(forKey: Self.styleKey) ?? "") ?? .auto
    var custom = (UserDefaults.standard.data(forKey: Self.layoutKey).flatMap { try? JSONDecoder().decode([DeckSectionEntry].self, from: $0) })
      ?? Self.defaultLayout
    // Concept shots: MLC_HOMESTYLE and MLC_LAYOUT (visible sections in order, comma separated).
    if let value = conceptEnv("MLC_HOMESTYLE"), let forced = DeckHomeStyle(rawValue: value) { style = forced }
    if let layout = conceptEnv("MLC_LAYOUT") {
      let ids = layout.split(separator: ",").compactMap { DeckSectionID(rawValue: String($0)) }
      custom = ids.map { DeckSectionEntry(id: $0, visible: true) }
        + DeckSectionID.allCases.filter { !ids.contains($0) }.map { DeckSectionEntry(id: $0, visible: false) }
      style = .custom
    }
    // 大图 is the default 主页布局. A stored choice is always the user's own: the key is written only when the
    // user picks a layout or presses 恢复默认, so a missing key is "never set" and gets the new default; "card" stays card.
    var mode = DeckHomeLayout(rawValue: UserDefaults.standard.string(forKey: Self.layoutModeKey) ?? "") ?? .hero
    var preview = DeckHostPreview(rawValue: UserDefaults.standard.string(forKey: Self.previewKey) ?? "") ?? .wallpaper
    var tiles = DeckTileStyle(rawValue: UserDefaults.standard.string(forKey: Self.tilesKey) ?? "") ?? .portrait
    if let v = conceptEnv("MLC_HOMELAYOUT"), let forced = DeckHomeLayout(rawValue: v) { mode = forced }
    if let v = conceptEnv("MLC_PREVIEW"), let forced = DeckHostPreview(rawValue: v) { preview = forced }
    if let v = conceptEnv("MLC_TILES"), let forced = DeckTileStyle(rawValue: v) { tiles = forced }
    self.style = style
    self.custom = custom
    self.layoutMode = mode
    self.preview = preview
    self.tiles = tiles
    let stored = UserDefaults.standard.double(forKey: Self.tileSizeKey)
    self.tileSize = stored >= 90 ? min(stored, 260) : 132
    let page = UserDefaults.standard.double(forKey: Self.pageScaleKey)
    self.pageScale = page >= 0.85 ? min(page, 1.3) : 1.0
    self.adaptivePage = UserDefaults.standard.object(forKey: Self.adaptivePageKey) as? Bool ?? true
    self.adaptiveTiles = UserDefaults.standard.object(forKey: Self.adaptiveTilesKey) as? Bool ?? true
    if let v = conceptEnv("MLC_PAGESCALE"), let d = Double(v) { self.pageScale = d; self.adaptivePage = false }
    if let v = conceptEnv("MLC_TILESIZE"), let d = Double(v) { self.tileSize = d; self.adaptiveTiles = false }
  }

  func reset() {
    style = .auto
    custom = Self.defaultLayout
    layoutMode = .hero
    preview = .wallpaper
    tiles = .portrait
    tileSize = 132
    pageScale = 1.0
    adaptivePage = true
    adaptiveTiles = true
  }
}

/// Foundation Sunshine says what an entry is (FsKind); other hosts are matched by name.
func deckIsDesktopLike(_ app: TemporaryApp) -> Bool {
  if let kind = app.deckInfo.kind { return kind == "desktop" }
  let name = (app.name ?? "").lowercased()
  return name == "desktop" || name == "桌面" || name.contains("remote desktop")
}

/// 大屏模式: only a Foundation Sunshine host says so (FsKind=bigscreen); never guessed from the name.
func deckIsBigScreen(_ app: TemporaryApp) -> Bool { app.deckInfo.kind == "bigscreen" }

/// "局域网 · 2 ms · 2560×1440 · 120 帧 · HDR": the way to the computer, then what the next stream would be
/// with the current settings (DeckStreamPlan). The codec is only named when it differs from the choice or
/// needs software decoding. What the computer is able to do is in 主机信息, not here. The way is the kind
/// word of the address in use; when the measured route (HostPathSignals) says tunnel, Tailscale, link-local
/// or relayed, that phrase is said instead, because a private address can be reached over a tunnel.
func deckStatusLine(_ host: DeckHost) -> String {
  var parts: [String] = []
  // the way in a word: the path class of the address in use (DeckAddressModel: evidence decides, the shape of the address
  // only hints); an unconfirmed address gets no word rather than a wrong one
  if let word = DeckAddressModel.activeWord(host) { parts.append(word) }
  if let rtt = host.rtt { parts.append("\(rtt) ms") }
  let plan = DeckStreamPlan.plan(for: host).summary
  if !plan.isEmpty { parts.append(plan) }
  return parts.joined(separator: " · ")
}

/// What a style comes to for one host: which sections, which layout, which tiles, how dense.
struct DeckResolvedHome {
  var entries: [DeckSectionEntry]
  var layout: DeckHomeLayout
  var tiles: DeckTileStyle
  /// 简洁: a small computer card and small tiles.
  var compact: Bool
  /// 游戏库: large tiles.
  var large: Bool
}

extension DeckAppsModel {
  /// 自动 is the default page, and 大图 is the default layout: it resolves to 游戏库 (the 大图 hero) for every computer, off,
  /// unpaired or with few apps too. 简洁 (the compact card layout) stays one tap away in 自定义主页.
  var autoStyle: DeckHomeStyle { .games }

  /// 简洁 is compact (card layout, small computer card, small portrait tiles, no hero). 游戏库 is rich
  /// (the 大图 wallpaper hero, a 最近使用 shelf of landscape cards, large tiles, landscape where the host
  /// sends landscape art). 自定义 is exactly what the user set.
  func resolveHome(_ config: DeckHomeConfig) -> DeckResolvedHome {
    let style = config.style == .auto ? autoStyle : config.style
    switch style {
    case .simple, .auto:
      return DeckResolvedHome(entries: presetSections(.simple, custom: config.custom), layout: .card, tiles: .portrait, compact: true, large: false)
    case .games:
      let landscapeArt = apps.contains { ($0.fsExtras["FsArt"] ?? "").contains("hero") }
      return DeckResolvedHome(entries: presetSections(.games, custom: config.custom), layout: .hero,
                              tiles: landscapeArt ? .landscape : .portrait, compact: false, large: true)
    case .custom:
      return DeckResolvedHome(entries: presetSections(.custom, custom: config.custom), layout: config.layoutMode, tiles: config.tiles,
                              compact: false, large: false)
    }
  }

  /// Every decision about 连接, 大屏模式 and what the grid hides is made by DeckConnectPlan (one function, tested on its own).
  var connectPlan: DeckConnectPlan {
    // the order of the 应用 grid (by name): "the first app" is the first tile the user sees
    let listed = apps.sorted { ($0.name ?? "").localizedCaseInsensitiveCompare($1.name ?? "") == .orderedAscending }
    return DeckConnectPlan.make(isFoundation: host?.isFoundation == true,
                                apps: listed.map { DeckPlanApp(id: $0.id ?? "", name: $0.name ?? "", kind: $0.deckInfo.kind) })
  }

  /// What 连接 starts: the Desktop app, or the first app of the list.
  var defaultApp: TemporaryApp? { connectPlan.target.appId.flatMap { id in apps.first { $0.id == id } } }

  var runningGame: TemporaryApp? {
    guard let runningId, let app = apps.first(where: { $0.id == runningId }), !deckIsDesktopLike(app) else { return nil }
    return app
  }

  /// 退出 <app> for whatever runs now, 桌面 and 大屏模式 included (DeckConnectPlan.quitEntry decides): the app to quit
  /// and the words of the button.
  func quitTarget(reachable: Bool) -> (app: TemporaryApp, title: String)? {
    let planApps = apps.map { DeckPlanApp(id: $0.id ?? "", name: $0.name ?? "", kind: $0.deckInfo.kind) }
    guard let entry = DeckConnectPlan.quitEntry(runningId: runningId, apps: planApps, reachable: reachable),
          let app = apps.first(where: { $0.id == entry.appId }) else { return nil }
    let title: String
    switch entry.role {
    case .desktop: title = DL("deck.quitDesktop")
    case .bigScreen: title = DL("deck.quitBigScreen")
    case .app: title = entry.name.map { DLf("deck.quitNamed", DeckConnectPlan.shortName($0, limit: 24)) } ?? DL("deck.quitRunning")
    }
    return (app, title)
  }

  /// Only on a Foundation Sunshine host that has an app with FsKind=bigscreen.
  var bigScreenApp: TemporaryApp? { connectPlan.bigScreenId.flatMap { id in apps.first { $0.id == id } } }

  /// 继续: most recent first; in R3 the running app leads.
  func continueApps(runningFirst: Bool) -> [TemporaryApp] {
    var list = recentApps
    if runningFirst, let running = runningGame, !isConnectEntry(running) {
      list.removeAll { $0.id == running.id }
      list.insert(running, at: 0)
    }
    return list
  }

  /// The sections each preset shows, in the standard order. 自定义 is the user's list. 电脑 and 应用 are always on.
  func presetSections(_ style: DeckHomeStyle, custom: [DeckSectionEntry]) -> [DeckSectionEntry] {
    func entries(_ visible: Set<DeckSectionID>) -> [DeckSectionEntry] {
      DeckSectionID.allCases.map { DeckSectionEntry(id: $0, visible: visible.contains($0)) }
    }
    switch style {
    case .custom:
      let known = Set(custom.map { $0.id })
      var list = custom + DeckSectionID.allCases.filter { !known.contains($0) }.map { DeckSectionEntry(id: $0, visible: false) }
      for index in list.indices where list[index].id.isRequired { list[index].visible = true }
      return list
    case .simple:
      return entries([.computer, .continuePlaying, .apps])
    case .games:
      return entries([.computer, .continuePlaying, .pinned, .apps])
    case .auto:
      return presetSections(autoStyle, custom: custom)
    }
  }
}

// MARK: - Pairing state (inline in the card, no alert)

final class DeckPairingState: ObservableObject {
  static let shared = DeckPairingState()
  /// Pairing was started for these hosts (waiting for the PIN).
  @Published var started: Set<String> = []
  @Published var pins: [String: String] = [:]
  @Published var failures: [String: String] = [:]
  private var observers: [NSObjectProtocol] = []

  init() {
    let center = NotificationCenter.default
    observers.append(center.addObserver(forName: .init("MLDeckPairingPIN"), object: nil, queue: .main) { [weak self] note in
      guard let self, let uuid = note.userInfo?["uuid"] as? String else { return }
      let pin = (note.userInfo?["pin"] as? String) ?? ""
      if pin.isEmpty { self.pins.removeValue(forKey: uuid); self.started.remove(uuid) }
      else { self.pins[uuid] = pin; self.started.insert(uuid); self.failures.removeValue(forKey: uuid) }
    })
    observers.append(center.addObserver(forName: .init("MLDeckPairingFailed"), object: nil, queue: .main) { [weak self] note in
      guard let self, let uuid = note.userInfo?["uuid"] as? String else { return }
      self.pins.removeValue(forKey: uuid); self.started.remove(uuid)
      self.failures[uuid] = (note.userInfo?["message"] as? String) ?? ""
    })
  }

  func begin(_ uuid: String) { failures.removeValue(forKey: uuid); started.insert(uuid) }
  func cancel(_ uuid: String) { started.remove(uuid); pins.removeValue(forKey: uuid) }
}

// MARK: - Desktop thumbnail and running art

extension DeckArt {
  /// The host's own thumbnail (Foundation Sunshine, later): the second fallback.
  static func thumbURL(_ uuid: String) -> URL {
    let caches = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first ?? NSTemporaryDirectory()
    return URL(fileURLWithPath: caches).appendingPathComponent(Bundle.main.bundleIdentifier ?? "").appendingPathComponent(uuid).appendingPathComponent("_desktop.jpg")
  }

  private static let previews = NSCache<NSString, NSImage>()
  private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

  /// A frosted copy of a picture, made once and cached (never blurred while drawing): Gaussian blur of
  /// `radius` points at a display width of `displayWidth` points, saturation lifted a little.
  private static func frosted(_ cg: CGImage, radius: CGFloat, displayWidth: CGFloat, saturation: CGFloat) -> NSImage? {
    let px = radius * CGFloat(cg.width) / max(displayWidth, 200)
    let input = CIImage(cgImage: cg)
    guard let blur = CIFilter(name: "CIGaussianBlur") else { return nil }
    blur.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
    blur.setValue(max(1, px), forKey: kCIInputRadiusKey)
    guard var out = blur.outputImage else { return nil }
    if let tone = CIFilter(name: "CIColorControls") {
      tone.setValue(out, forKey: kCIInputImageKey)
      tone.setValue(saturation, forKey: kCIInputSaturationKey)
      out = tone.outputImage ?? out
    }
    guard let result = ciContext.createCGImage(out.cropped(to: input.extent), from: input.extent) else { return nil }
    return NSImage(cgImage: result, size: NSSize(width: result.width, height: result.height))
  }

  private static func decode(_ url: URL, maxPixel: Int) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixel,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
  }

  private static func modified(_ url: URL) -> TimeInterval {
    ((try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate)?.timeIntervalSince1970 ?? 0
  }

  /// The client's own last frame (StreamBackdropStore, saved when a stream ends): the desktop's if there
  /// is one, otherwise the newest of the host's apps; then the host-provided thumbnail. It is stored as a
  /// 960 px JPEG, which looks soft when shown large, so it is shown frosted: blurred (about 25 pt at the
  /// displayed size) with a little more saturation, rendered once and cached by file and size.
  static func loadLastFrame(_ host: DeckHost, displayWidth: CGFloat) async -> NSImage? {
    let apps = host.raw.appList.compactMap { $0 as? TemporaryApp }
    let uuid = host.id
    let candidates: [(String, Bool)] = apps.map { ($0.id ?? "", deckIsDesktopLike($0)) }
    let loaded: DeckSendable<NSImage>? = await Task.detached(priority: .userInitiated) { () -> DeckSendable<NSImage>? in
      var best: (URL, Date, Bool)?
      for (appId, desktop) in candidates {
        guard let url = StreamBackdropStore.frameURL(host: uuid, app: appId),
              let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { continue }
        if best == nil || (desktop && !best!.2) || (desktop == best!.2 && date > best!.1) { best = (url, date, desktop) }
      }
      let url = best?.0 ?? thumbURL(uuid)
      guard FileManager.default.fileExists(atPath: url.path) else { return nil }
      let key = "frame/\(url.path)/\(modified(url))/\(Int(displayWidth / 100))" as NSString
      if let hit = previews.object(forKey: key) { return DeckSendable(hit) }
      guard let cg = decode(url, maxPixel: 1280), let image = frosted(cg, radius: 25, displayWidth: displayWidth, saturation: 1.15) else { return nil }
      previews.setObject(image, forKey: key)
      return DeckSendable(image)
    }.value
    return loaded?.value
  }

  /// The host's wallpaper: the poster of its Desktop app. A Foundation Sunshine host on Windows serves
  /// the real wallpaper there (apps.json image-path "desktop", resolved in process.cpp
  /// validate_app_image_path); any other host serves its generic portrait desktop.png, which is not a
  /// wallpaper, so only a landscape picture counts. The Desktop app is FsKind=desktop, else named
  /// Desktop / 桌面 (deckIsDesktopLike). It stays sharp, unless it has fewer than 1/1.5 of the pixels
  /// the display needs: then a light blur (8 pt) hides the softness.
  static func loadWallpaper(_ host: DeckHost, displayWidth: CGFloat) async -> NSImage? {
    guard let app = host.raw.appList.compactMap({ $0 as? TemporaryApp }).first(where: deckIsDesktopLike) else { return nil }
    let file = path(app)
    guard !file.isEmpty else { return nil }
    let url = URL(fileURLWithPath: file)
    let scale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2 }
    let key = "wall/\(file)/\(modified(url))/\(Int(displayWidth / 100))" as NSString
    if let hit = previews.object(forKey: key) { return hit }
    let loaded: DeckSendable<NSImage>? = await Task.detached(priority: .userInitiated) { () -> DeckSendable<NSImage>? in
      guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = props[kCGImagePropertyPixelWidth] as? Double,
            let height = props[kCGImagePropertyPixelHeight] as? Double,
            width >= height * 1.2,
            let cg = decode(url, maxPixel: displayWidth < 800 ? 1280 : 2400) else { return nil }
      if Double(cg.width) * 1.5 < Double(displayWidth * scale) {
        return frosted(cg, radius: 8, displayWidth: displayWidth, saturation: 1.05).map { DeckSendable($0) }
      }
      return DeckSendable(NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)))
    }.value
    let image = loaded?.value
    if let image { previews.setObject(image, forKey: key) }
    return image
  }

  /// What is already decoded in memory for this computer's picture, found without touching the disk beyond one stat: the first
  /// frame of a page that was drawn before (switching computers, a window opened again) shows it at once. nil = not decoded yet.
  static func peekPreview(_ host: DeckHost, preference: DeckHostPreview, displayWidth: CGFloat, grey: Bool) -> NSImage? {
    guard !grey, preference == .wallpaper,
          let app = host.raw.appList.compactMap({ $0 as? TemporaryApp }).first(where: deckIsDesktopLike) else { return nil }
    let file = path(app)
    guard !file.isEmpty else { return nil }
    let url = URL(fileURLWithPath: file)
    let key = "wall/\(file)/\(modified(url))/\(Int(displayWidth / 100))" as NSString
    if let hit = previews.object(forKey: key) { return hit }
    // Not decoded in this run yet (a cold launch): the first frame still draws the picture. A quick decode at screen size, once
    // (about 20 ms for a wallpaper); the full decode that follows replaces it with a cross-fade, which is not visible.
    let quickKey = "wallq/\(file)/\(modified(url))" as NSString
    if let hit = previews.object(forKey: quickKey) { return hit }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = props[kCGImagePropertyPixelWidth] as? Double, let height = props[kCGImagePropertyPixelHeight] as? Double,
          width >= height * 1.2, let cg = decode(url, maxPixel: 1280) else { return nil }
    let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    previews.setObject(image, forKey: quickKey)
    return image
  }

  /// The preview image of a computer, in the order the user chose; nil = the caller draws the placeholder.
  /// `displayWidth` is the width in points it will be shown at (the blur is scaled to it).
  static func loadPreview(_ host: DeckHost, preference: DeckHostPreview, displayWidth: CGFloat, desaturate: Bool = false) async -> NSImage? {
    var found: NSImage?
    switch preference {
    case .wallpaper:
      found = await loadWallpaper(host, displayWidth: displayWidth)
      if found == nil { found = await loadLastFrame(host, displayWidth: displayWidth) }
    case .lastFrame:
      found = await loadLastFrame(host, displayWidth: displayWidth)
      if found == nil { found = await loadWallpaper(host, displayWidth: displayWidth) }
    }
    // A computer that is off shows its picture in grey. Done to the picture itself, once: a live saturation
    // filter on a page that is drawn scaled came out at the wrong size.
    guard desaturate, let found else { return found }
    let source = DeckSendable(found)
    return await Task.detached(priority: .userInitiated) { DeckSendable(grayscale(source.value)) }.value.value
  }

  private static func grayscale(_ image: NSImage) -> NSImage {
    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
          let tone = CIFilter(name: "CIColorControls") else { return image }
    tone.setValue(CIImage(cgImage: cg), forKey: kCIInputImageKey)
    tone.setValue(0, forKey: kCIInputSaturationKey)
    tone.setValue(-0.08, forKey: kCIInputBrightnessKey)
    guard let out = tone.outputImage, let result = ciContext.createCGImage(out, from: out.extent) else { return image }
    // the paler look of a computer that is off is part of the picture too (alpha), not a live opacity on a
    // view that is drawn scaled
    let size = NSSize(width: result.width, height: result.height)
    let faded = NSImage(size: size)
    faded.lockFocus()
    NSImage(cgImage: result, size: size).draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 0.5)
    faded.unlockFocus()
    return faded
  }
}

/// What you will see when you connect. Without a thumbnail a small card with the platform glyph.
struct DeckDesktopThumb: View {
  let host: DeckHost
  var version = 0
  @ObservedObject private var config = DeckHomeConfig.shared
  @SwiftUI.State private var image: NSImage?
  @SwiftUI.State private var loaded = false

  var body: some View {
    Group {
      if let image {
        DeckFilledImage(image: image, aspect: 16.0 / 9.0)
          .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
          .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
          .shadow(color: .black.opacity(0.14), radius: 12, y: 6)
      } else if loaded {
        placeholder
      } else {
        Color.clear.aspectRatio(16.0 / 9.0, contentMode: .fit)
      }
    }
    .task(id: "\(host.id)/\(version)/\(config.preview.rawValue)/\(host.settledOffline)") {
      // grey only for a computer found off; a load that was replaced meanwhile does not write (see DeckHeroHeader)
      let next = await DeckArt.loadPreview(host, preference: config.preview, displayWidth: 560, desaturate: DeckPresenceRules.greyHero(state: host.state))
      guard !Task.isCancelled else { return }
      image = next
      loaded = true
    }
  }

  /// No thumbnail: a card of the same size and place, the host's icon large on a soft gradient of its colour.
  private var placeholder: some View {
    let color = (!host.online || host.icon.colorName == "gray") ? (host.online ? Color.accentColor : Color.gray) : DeckPalette.color(host.icon.colorName)
    return ZStack {
      LinearGradient(colors: [color.opacity(0.34), color.opacity(0.10)], startPoint: .topLeading, endPoint: .bottomTrailing)
      Circle().fill(color.opacity(0.10)).frame(width: 340, height: 340).offset(x: 150, y: -90)
      if let picture = host.icon.image {
        Image(nsImage: picture).resizable().scaledToFill().frame(width: 128, height: 128)
          .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
      } else {
        Image(systemName: host.icon.symbol.isEmpty ? "display" : host.icon.symbol)
          .font(.system(size: 100, weight: .light)).foregroundStyle(color.opacity(0.9))
      }
    }
    .aspectRatio(16.0 / 9.0, contentMode: .fit)
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
    .shadow(color: .black.opacity(0.16), radius: 18, y: 9)
  }
}

/// Pairing in progress, in the place of the thumbnail: a clear title, the PIN in large digit boxes
/// (the way Apple shows a verification code), and where to enter it.
struct DeckPairingPanel: View {
  let host: DeckHost
  let pin: String?

  var body: some View {
    let tint = Color.orange
    ZStack {
      LinearGradient(colors: [tint.opacity(0.30), tint.opacity(0.10)], startPoint: .topLeading, endPoint: .bottomTrailing)
      VStack(spacing: 18) {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text(DL("deck.pairingTitle")).font(.system(size: 24, weight: .bold))
        }
        HStack(spacing: 12) {
          ForEach(Array((pin ?? "    ").enumerated()), id: \.offset) { _, digit in
            Text(String(digit).trimmingCharacters(in: .whitespaces))
              .font(.system(size: 60, weight: .bold, design: .monospaced))
              .frame(width: 74, height: 96)
              .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
              .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.18), lineWidth: 1))
              .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
          }
        }
        Text(DLf("deck.pinWeb", host.name)).font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
          .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 330)
      }
      .padding(20)
    }
    .aspectRatio(16.0 / 9.0, contentMode: .fit)
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
    .shadow(color: .black.opacity(0.16), radius: 18, y: 9)
  }
}

/// R2: the running game in the thumbnail's place: the host's landscape art, or the poster enlarged.
struct DeckRunningArt: View {
  let app: TemporaryApp
  var version = 0

  var body: some View {
    DeckLandscapeArt(app: app, version: version, posterFraction: 0.82)
      .aspectRatio(16.0 / 9.0, contentMode: .fit)
      .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
      .overlay(alignment: .topLeading) {
        HStack(spacing: 5) {
          Circle().fill(Color.green).frame(width: 7, height: 7)
          Text(DL("deck.running")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .deckGlass(Capsule(), tint: .green)
        .padding(12)
      }
      .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
      .shadow(color: .black.opacity(0.22), radius: 18, y: 9)
  }
}

// MARK: - The computer card

/// The one quiet line under a computer's name, in every state and both layouts.
func deckCardStatus(_ host: DeckHost, pairing: DeckPairingState) -> String {
  if !host.online {
    // 离线 · 上次在线 3 小时前, or 从未连接
    if DeckTime.relative(host.facts.lastSeen ?? host.facts.lastConnected) == nil { return DL("deck.neverConnected") }
    return DL("deck.offline") + " · " + deckSubtitle(host)
  }
  if !host.paired {
    if pairing.started.contains(host.id) || pairing.pins[host.id] != nil { return DLf("deck.waitingConfirm", host.name) }
    return [host.address, DL("deck.unpaired")].compactMap { $0 }.joined(separator: " · ")
  }
  return deckStatusLine(host)
}

struct DeckComputerCard: View {
  let host: DeckHost
  @ObservedObject var model: DeckAppsModel
  /// 简洁: a smaller card.
  var compact = false
  /// The width the card has to fill (page width less the margins), to size the preview.
  var contentWidth: CGFloat = 900
  /// Variant C of the offline page: content under the text column (地址) and under the preview (状态 + 设备).
  var leftExtra: AnyView?
  var rightExtra: AnyView?

  @ObservedObject private var pairing = DeckPairingState.shared
  private var game: TemporaryApp? { host.online && host.paired ? model.runningGame : nil }
  private var style: DeckRunningStyle { DeckRunningStyle.current }

  var body: some View {
    // the preview is the larger half of the card: 42 % of the width, 360...680 pt, 16:9
    let previewWidth = min(680, max(360, floor(contentWidth * 0.42)))
    HStack(alignment: .top, spacing: DeckInset.page) {
      VStack(alignment: .leading, spacing: compact ? 8 : 14) {
        DeckEditableHostIcon(host: host, model: model, size: compact ? 56 : 76).shadow(color: .black.opacity(0.12), radius: 8, y: 4)
        Text(host.name).font(.system(size: compact ? 30 : 38, weight: .bold)).lineLimit(2)
        Text(statusText).font(.system(size: 14)).foregroundStyle(.secondary)
        if host.paired { DeckPathChips(host: host, model: model) }
        if host.paired { DeckNicChips(host: host, model: model) }
        stateButtons.padding(.top, compact ? 2 : 8)
        if let leftExtra { leftExtra.padding(.top, 12) }
      }
      // the text column never takes the width the picture (or the PIN boxes) needs
      .frame(minWidth: 240, maxWidth: .infinity, alignment: .leading)
      VStack(alignment: .leading, spacing: 16) {
        preview(previewWidth)
        if let rightExtra { rightExtra }
      }
      .frame(width: rightExtra == nil ? nil : previewWidth)
    }
  }

  @ViewBuilder
  private func preview(_ previewWidth: CGFloat) -> some View {
    if let game, style == .art {
      DeckRunningArt(app: game, version: model.artVersion).frame(width: previewWidth)
        .onTapGesture { model.openApp(game) }
        .controllerFocusTarget(key: "preview", radius: 16) { model.openApp(game) }
    } else if !host.paired && (pairing.started.contains(host.id) || pairing.pins[host.id] != nil) {
      DeckPairingPanel(host: host, pin: pairing.pins[host.id]).frame(width: max(previewWidth, 380))
    } else {
      if model.canStream {
        DeckDesktopThumb(host: host, version: model.artVersion)
          // both sides fixed: an aspect-fit box otherwise fits itself to whatever height it is offered
          .frame(width: previewWidth, height: (previewWidth * 9 / 16).rounded())
          .onTapGesture { connect() }
          .controllerFocusTarget(key: "preview", radius: 12) { connect() }
          .accessibilityAddTraits(.isButton)
          .accessibilityLabel(DL("deck.connect"))
      } else {
        // off or not paired: a picture, not a control (no click, no focus, no button role)
        DeckDesktopThumb(host: host, version: model.artVersion)
          .frame(width: previewWidth, height: (previewWidth * 9 / 16).rounded())
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
    }
  }

  private var statusText: String { deckCardStatus(host, pairing: pairing) }

  @ViewBuilder
  private var stateButtons: some View {
    if !host.online { offlineButtons }
    else if !host.paired { pairingButtons }
    else { buttons }
  }

  /// Offline: 唤醒 with a real MAC. Without one (none stored, or all zeros) the button says 无法唤醒, is
  /// disabled, and one line says why; 唤醒 is never offered without a MAC.
  private var offlineButtons: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        Button { model.actions.wake?() } label: {
          Label(host.canWake ? DL("deck.wake") : DL("deck.noMac"), systemImage: host.canWake ? "power" : "power.dotted").frame(minWidth: 106)
        }
        .controllerButtonStyle(DeckCardButtonStyle(prominent: true))
        .controllerKey("primary")
        .disabled(!host.canWake)
        DeckHeroRound(symbol: "slider.horizontal.3", help: DL("deck.settings"), onDark: false, size: 44) { model.actions.settings?() }
        DeckHeroRound(symbol: "ellipsis", help: DL("deck.more"), onDark: false, size: 44, padMenu: { DeckMoreMenu.menu(host, model) }) { DeckMenuPresenter.pop(DeckMoreMenu.menu(host, model)) }
      }
      if !host.canWake {
        Text(DL("deck.noMacReason")).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  /// Unpaired: 配对; once pressed the PIN shows here, no alert.
  @ViewBuilder
  private var pairingButtons: some View {
    let started = pairing.started.contains(host.id) || pairing.pins[host.id] != nil
    VStack(alignment: .leading, spacing: 10) {
      if started {
        // the PIN itself is large in the panel on the right; here: that it is waiting, and a way out
        HStack(spacing: 10) {
          ProgressView().controlSize(.small)
          Button(DL("deck.cancel")) { cancelPairing() }.controllerButtonStyle(DeckCardButtonStyle()).controllerKey("primary")
            .controllerBackAction(active: true) { cancelPairing() }
        }
        .frame(height: 44)
      } else {
        HStack(spacing: 10) {
          Button { pairing.begin(host.id); model.actions.pair?() } label: {
            Label(pairing.failures[host.id] == nil ? DL("deck.pair") : DL("deck.retry"), systemImage: "link").frame(minWidth: 106)
          }
          .controllerButtonStyle(DeckCardButtonStyle(prominent: true))
          .controllerKey("primary")
          .deckPairNudge(hostID: host.id)
          DeckHeroRound(symbol: "slider.horizontal.3", help: DL("deck.settings"), onDark: false, size: 44) { model.actions.settings?() }
          DeckHeroRound(symbol: "ellipsis", help: DL("deck.more"), onDark: false, size: 44, padMenu: { DeckMoreMenu.menu(host, model) }) { DeckMenuPresenter.pop(DeckMoreMenu.menu(host, model)) }
        }
        if let failure = pairing.failures[host.id] {
          Label(failure.isEmpty ? DL("deck.pairFailed") : failure, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 12.5)).foregroundStyle(.red).lineLimit(2).frame(maxWidth: 300, alignment: .leading)
        }
      }
    }
  }

  private func cancelPairing() {
    pairing.cancel(host.id)
    model.actions.cancelPair?()
  }

  /// 连接桌面 (filled), 大屏模式 on Foundation Sunshine hosts, the round 串流设置 and 更多: separate buttons,
  /// no dropdown. 退出应用 beside 继续 <app> while a game runs.
  private var buttons: some View {
    DeckConnectBar(host: host, model: model, look: .card, game: game)
  }

  private func primary() {
    if let game { model.openApp(game) } else { connect() }
  }

  private func connect() {
    DeckConnect.connect(DeckConnect.effective(host, model), host: host, model: model)
  }
}

// MARK: - Host info and recent sessions

struct DeckHostInfoCard: View {
  let host: DeckHost
  var kindSeen: Bool?

  private var rows: [(String, String)] {
    var rows: [(String, String)] = []
    let route = deckRouteText(host)
    if !route.isEmpty { rows.append((DL("deck.fact.route"), route)) }
    if !host.facts.osVersion.isEmpty { rows.append((DL("deck.fact.platform"), host.facts.osVersion)) }
    if !host.facts.gpu.isEmpty { rows.append((DL("deck.fact.gpu"), host.facts.gpu)) }
    rows.append((DL("deck.fact.codecs"), deckCapabilityText(host)))
    let modes = Self.modes(host.facts.displayModes)
    if !modes.isEmpty { rows.append((DL("deck.fact.modes"), modes)) }
    rows.append((DL("deck.wake"), host.canWake ? DL("deck.wake.ok") : DL("deck.wake.no")))
    return rows
  }

  /// "3840x2160@120,2560x1440@165" -> "3840×2160 120 Hz · 2560×1440 165 Hz"
  static func modes(_ raw: String) -> String {
    raw.split(separator: ",").map { mode -> String in
      let parts = mode.split(separator: "@")
      let size = (parts.first.map(String.init) ?? "").replacingOccurrences(of: "x", with: "×")
      return parts.count > 1 ? "\(size) \(parts[1]) Hz" : size
    }.joined(separator: " · ")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      VStack(spacing: 0) {
        if host.softwareKnown {
          HStack(alignment: .top) {
            Text(DL("deck.fact.software"))
            Spacer(minLength: 24)
            DeckSoftwareValue(host: host, kindSeen: kindSeen).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
          }
          .font(.system(size: 13))
          .padding(.vertical, 10)
          Divider()
        }
        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
          if index > 0 { Divider() }
          HStack(alignment: .top) {
            Text(row.0)
            Spacer(minLength: 24)
            Text(row.1).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
          }
          .font(.system(size: 13))
          .padding(.vertical, 10)
        }
      }
      .padding(.horizontal, 14)
      .deckCard(radius: 12)
      DeckFsFeatureGroup(host: host)
    }
  }
}

struct DeckRecentSessions: View {
  let host: DeckHost
  @ObservedObject var model: DeckAppsModel

  var body: some View {
    VStack(spacing: 0) {
      ForEach(Array(host.facts.sessions.prefix(5).enumerated()), id: \.offset) { index, session in
        if index > 0 { Divider() }
        if let app = model.apps.first(where: { $0.id == session.appId }) {
          HStack(spacing: 12) {
            DeckAppIcon(app: app, size: 30, version: model.artVersion)
            Text(app.name ?? "").font(.system(size: 13, weight: .medium))
            Spacer()
            Text(detail(session)).font(.system(size: 12)).foregroundStyle(.secondary)
          }
          .padding(.vertical, 8)
        } else if let name = session.name, !name.isEmpty {
          // the host is off and its app list is not cached: the name kept with the session
          HStack(spacing: 12) {
            Text(name).font(.system(size: 13, weight: .medium))
            Spacer()
            Text(detail(session)).font(.system(size: 12)).foregroundStyle(.secondary)
          }
          .padding(.vertical, 8)
        }
      }
    }
    .padding(.horizontal, 14)
    .deckCard(radius: 12)
  }

  private func detail(_ session: DeckSession) -> String {
    var text = DeckTime.relative(session.start) ?? ""
    if session.seconds > 0 { text += " · " + DeckTime.duration(TimeInterval(session.seconds)) }
    return text
  }
}

// MARK: - The page

final class DeckHomeEditState: ObservableObject {
  static let shared = DeckHomeEditState()
  /// While a row is being dragged: which one, and the row it would be dropped before.
  @Published var dragging: DeckSectionID?
  @Published var dropBefore: DeckSectionID?
  private var observer: NSObjectProtocol?

  init() {
    observer = NotificationCenter.default.addObserver(forName: .init("MLDeckCustomize"), object: nil, queue: .main) { [weak self] note in
      self?.dragging = (note.userInfo?["drag"] as? String).flatMap(DeckSectionID.init)
      self?.dropBefore = (note.userInfo?["drop"] as? String).flatMap(DeckSectionID.init)
      DeckHomeCustomizer.shared.show()
    }
  }
}

/// The page. The width comes straight from the live layout, not from a copy kept in state: a copy
/// that missed a window resize left the content wider than the window and pushed it under the sidebar.
struct DeckComputerView: View {
  @ObservedObject var model: DeckAppsModel

  var body: some View {
    GeometryReader { proxy in DeckComputerBody(model: model, windowWidth: proxy.size.width) }
  }
}

private struct DeckContentHeightKey: PreferenceKey {
  static var defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct DeckComputerBody: View {
  @ObservedObject var model: DeckAppsModel
  /// The real width of the page area.
  let windowWidth: CGFloat
  @ObservedObject private var config = DeckHomeConfig.shared
  @Environment(\.dynamicTypeSize) private var typeSize
  @SwiftUI.State private var contentHeight: CGFloat = 1200
  /// The page is laid out at windowWidth / scale and drawn scaled by `scale`: everything on it (text
  /// included) grows together and a larger page uses more of a wide window (the column cap scales too).
  /// The user's 页面大小 times the system text size where macOS exposes one.
  /// Follows the live width, continuously: the scale is a piecewise-linear function of it (no steps), and a
  /// scale change is a transform, so there is nothing to wait for or to ease.
  /// There is no page scale: a scale transform around the page draws every card layer at its base size and
  /// enlarges the picture of it. The page is laid out at the real window width; the card size alone follows the window
  /// (DeckAdaptive tile factor), as real layout sizes.
  private var pageScaleValue: Double { 1.0 }
  private var scale: CGFloat { 1 }
  /// The live width of the content area. A layout pass that offers a sliver (zero or partial width, as the
  /// toolbar or a popover can briefly cause) is ignored: the last sane width stands.
  @SwiftUI.State private var goodWidth: CGFloat = 0
  private var stableWidth: CGFloat { windowWidth >= DeckLayoutProbe.minimumWidth ? windowWidth : max(goodWidth, DeckLayoutProbe.minimumWidth) }
  /// The width the page is laid out at (what the rest of this view calls the width).
  private var width: CGFloat { stableWidth / max(scale, 0.1) }

  /// What the style comes to is asked for many times per layout pass (every tile rule, every section): worked
  /// out once per change of its inputs.
  @SwiftUI.State private var homeMemo = DeckHomeMemo()
  private var resolved: DeckResolvedHome {
    let key = "\(config.style.rawValue)|\(config.layoutMode.rawValue)|\(config.tiles.rawValue)|\(model.apps.count)|\(model.host?.signature ?? "")|\(config.custom.map { "\($0.id.rawValue)\($0.visible)" }.joined())"
    if homeMemo.key == key, let value = homeMemo.value { return value }
    let value = model.resolveHome(config)
    homeMemo.key = key; homeMemo.value = value
    return value
  }
  private var entries: [DeckSectionEntry] { resolved.entries }
  private var computerVisible: Bool { entries.first(where: { $0.id == .computer })?.visible ?? true }
  private var continueVisible: Bool { entries.first(where: { $0.id == .continuePlaying })?.visible ?? false }
  /// The running app is ringed and first when R3 is the style, or when there is no computer card to say it is running.
  private var ringRunning: Bool { DeckRunningStyle.current == .first || !computerVisible }
  private var heroMode: Bool { resolved.layout == .hero && computerVisible && model.host != nil }
  private var heroHeight: CGFloat { min(500, max(340, width * 0.36)) }
  private var landscapeTiles: Bool { resolved.tiles == .landscape }

  /// One tile size for every host and state. Manual: the slider's width. Automatic: the manual default times a
  /// factor that is a LINEAR function of the content width, 1.0 at 800 pt and 1.35 at 1160 pt (the column's
  /// cap), clamped outside: the tile only ever grows with the window and shrinks with it, with no step
  /// anywhere. The columns are then however many fit (floor); what is left stays on the right, left aligned.
  /// Landscape cards are 1.9 times as wide and use the same factor, as does the 最近使用 row.
  private func tileLayout(landscape: Bool) -> (size: CGFloat, count: Int) {
    let home = resolved
    let mult: CGFloat = home.compact ? 0.92 : (home.large ? 1.15 : 1)
    let content = max(300, colWidth - DeckInset.page * 2)
    let gap: CGFloat = 24
    #if MLC_CONCEPT_HARNESS
    if conceptEnv("MLC_OLDTILES") != nil, config.adaptiveTiles { return tileLayoutOld(landscape: landscape, mult: mult, content: content, gap: gap) }
    #endif
    let m = tileMetrics(landscape: landscape)
    return (m.base * m.factor, m.count)
  }

  /// A tile is laid out at its base width and drawn scaled by `factor` (a transform), so while the window is
  /// dragged only the transform changes: the tiles' own view trees are not laid out again on every frame.
  private func tileMetrics(landscape: Bool) -> (base: CGFloat, factor: CGFloat, count: Int) {
    let home = resolved
    let mult: CGFloat = home.compact ? 0.92 : (home.large ? 1.15 : 1)
    let content = max(300, colWidth - DeckInset.page * 2)
    let gap: CGFloat = 24
    var base: CGFloat
    var factor: CGFloat = 1
    if config.adaptiveTiles {
      factor = 1 + 0.35 * min(1, max(0, (content - 800) / (1160 - 800)))
      base = 132 * mult
    } else {
      base = CGFloat(config.tileSize) * mult
    }
    base = floor(landscape ? base * 1.9 : base)
    let count = max(1, Int(((content + gap) / (base * factor + gap)).rounded(.down)))
    return (base, factor, count)
  }

  #if MLC_CONCEPT_HARNESS
  /// The whole-column rule, kept only to draw the "before" curve: whole columns fitted to the width.
  private func tileLayoutOld(landscape: Bool, mult: CGFloat, content: CGFloat, gap: CGFloat) -> (size: CGFloat, count: Int) {
    let low: CGFloat = (landscape ? 132 * 1.9 : 132) * mult
    let high = low * 1.35
    let target = low * 1.12
    let mostColumns = max(1, Int((content + gap) / (low + gap)))
    let fewestColumns = max(1, Int(ceil((content + gap) / (high + gap))))
    var count = Int(((content + gap) / (target + gap)).rounded())
    count = min(max(count, fewestColumns), max(fewestColumns, mostColumns))
    count = max(1, min(count, mostColumns))
    let fitted = (content + gap) / CGFloat(count) - gap
    return (floor(min(max(fitted, low), high)), count)
  }
  #endif
  private func tileSize(landscape: Bool) -> CGFloat { tileLayout(landscape: landscape).size }
  private func tileBase(landscape: Bool) -> CGFloat { tileMetrics(landscape: landscape).base }
  private func tileFactor(landscape: Bool) -> CGFloat { tileMetrics(landscape: landscape).factor }
  private func tileCount(landscape: Bool) -> Int { tileLayout(landscape: landscape).count }
  /// The portrait tile width the automatic mode comes to, on the slider's scale (presets taken out).
  private var autoTileValue: Double {
    let home = resolved
    let mult: Double = home.compact ? 0.92 : (home.large ? 1.15 : 1)
    return min(240, max(100, Double(tileLayout(landscape: false).size) / mult))
  }
  private var tileSize: CGFloat { tileSize(landscape: false) }
  private func tileColumns(landscape: Bool) -> [GridItem] {
    Array(repeating: GridItem(.fixed(tileSize(landscape: landscape)), spacing: 24, alignment: .top), count: tileCount(landscape: landscape))
  }

  /// 主机信息 and 最近串流 side by side when they are next to each other.
  private enum Row: Identifiable {
    case single(DeckSectionID)
    case pair
    var id: String { switch self { case .single(let s): return s.rawValue; case .pair: return "pair" } }
  }

  private var rows: [Row] {
    // A computer that is off or not paired has one set of host information: the grouped form (DeckOfflineInfo).
    // The 主机信息 section is for the live page; it is not drawn next to the form, whatever the user switched on.
    let offlinePage = model.host.map { !$0.online || !$0.paired } ?? false
    let visible = entries.filter { $0.visible && !($0.id == .computer && heroMode) && !($0.id == .hostInfo && offlinePage) }.map { $0.id }
    var rows: [Row] = []
    var index = 0
    while index < visible.count {
      let id = visible[index]
      if id == .hostInfo, index + 1 < visible.count, visible[index + 1] == .recentSessions, colWidth >= 900 {
        rows.append(.pair); index += 2
      } else {
        rows.append(.single(id)); index += 1
      }
    }
    return rows
  }

  /// All page content lives in one column, at most DeckColumn.maxContent wide plus the margins, centred in
  /// the window: a 2560 pt window shows the page of a 1280 pt one, with the side margins grown evenly.
  private var colWidth: CGFloat { min(max(width, 320), DeckColumn.maxContent + DeckInset.page * 2) }
  private var sideMargin: CGFloat { max(0, (width - colWidth) / 2) }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 34) {
        // the 大图 picture may run edge to edge; its text and buttons line up with the column's leading edge
        if heroMode, let host = model.host {
          DeckHeroHeader(host: host, model: model, height: heroHeight, width: width, leadingInset: sideMargin + DeckInset.page,
                         topInset: DeckToolbar.clearance / max(scale, 0.1))
            .controllerSection(DeckSectionID.computer.rawValue)
        }
        VStack(alignment: .leading, spacing: 34) {
          if let host = model.host { DeckFsBanner(snapshot: host, model: model).padding(.horizontal, DeckInset.page).controllerSection(DeckSectionID.computer.rawValue) }
          if heroMode, let host = model.host { offlineInfo(host).controllerSection(DeckSectionID.computer.rawValue) }
          ForEach(rows) { row in
            switch row {
            case .single(let id): sectionContent(id)
            case .pair: pair
            }
          }
        }
        .frame(width: colWidth, alignment: .leading)
        .frame(width: max(width, 320))
      }
      // the content starts below the toolbar (about 52 pt of the window, whatever the page scale) plus a margin
      .padding(.top, heroMode ? 0 : max(40, DeckToolbar.clearance / max(scale, 0.1)))
      .padding(.bottom, 60)
      // never wider than the window, whatever the shelves hold (a wide shelf once pushed the page sideways)
      .frame(width: max(width, 320), alignment: .leading)
      .background(GeometryReader { proxy in Color.clear.preference(key: DeckContentHeightKey.self, value: proxy.size.height) })
      .modifier(DeckPageScaleModifier(scale: scale, windowWidth: stableWidth, contentHeight: contentHeight))
      .background(GeometryReader { proxy in
        Color.clear
          .onAppear { DeckLayoutProbe.record(proxy.frame(in: .global)) }
          .deckOnChange(of: proxy.frame(in: .global)) { _, frame in DeckLayoutProbe.record(frame) }
      })
    }
    .onPreferenceChange(DeckContentHeightKey.self) { if $0 > 0 { contentHeight = $0 } }
    .onAppear {
      if conceptEnv("MLC_DUMPMENUS") != nil {
        // harness: the real menus' items, so a test can read them
        DispatchQueue.main.asyncAfter(deadline: .now() + 7.0) {
          func dump(_ title: String, _ menu: NSMenu?, _ depth: Int = 0) {
            guard let menu else { fputs("MENUDUMP \(title): nil\n", stderr); return }
            if depth == 0 { fputs("MENUDUMP == \(title)\n", stderr) }
            for item in menu.items {
              fputs("MENUDUMP \(String(repeating: "  ", count: depth))\(item.isSeparatorItem ? "-----" : item.title)\(item.isEnabled ? "" : " (disabled)")\(item.state == .on ? " ✓" : "")\n", stderr)
              if let sub = item.submenu { dump(title, sub, depth + 1) }
            }
          }
          if let app = model.libraryApps.first { dump("app menu: \(app.name ?? "")", model.actions.appMenu?(app)) }
          if let app = model.runningGame { dump("running app menu: \(app.name ?? "")", model.actions.appMenu?(app)) }
          if let host = model.host { dump("more menu", DeckMoreMenu.menu(host, model)) }
        }
      }
    }
    .onAppear {
      // harness: open the running app's right-click menu so a picture of the screen shows it
      if conceptEnv("MLC_POPAPPMENU") != nil {
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
          guard let app = model.runningGame, let menu = model.actions.appMenu?(app) else { return }
          // the menu runs its own tracking loop: a timer in the common modes takes the picture while it is open
          let shot = Timer(timeInterval: 1.5, repeats: false) { _ in
            let out = conceptEnv("MLC_MENUOUT") ?? "/tmp/apps-concept/out/menu.png"
            _ = (NSClassFromString("ConceptHarness") as AnyObject).perform(NSSelectorFromString("padShot:"), with: out)
            exit(0)
          }
          RunLoop.main.add(shot, forMode: .common)
          if let content = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })?.contentView {
            menu.popUp(positioning: nil, at: NSPoint(x: 560, y: content.bounds.height - 330), in: content)
          } else {
            DeckMenuPresenter.pop(menu)
          }
        }
      }
    }
    .onAppear {
      // harness: open the ⋯ menu of the computer so a picture of the screen shows it
      if conceptEnv("MLC_POPMOREMENU") != nil {
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
          guard let host = model.host else { return }
          let menu = DeckMoreMenu.menu(host, model)
          let shot = Timer(timeInterval: 1.5, repeats: false) { _ in
            let out = conceptEnv("MLC_MENUOUT") ?? "/tmp/apps-concept/out/menu.png"
            _ = (NSClassFromString("ConceptHarness") as AnyObject).perform(NSSelectorFromString("padShot:"), with: out)
            exit(0)
          }
          RunLoop.main.add(shot, forMode: .common)
          if let content = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })?.contentView {
            menu.popUp(positioning: nil, at: NSPoint(x: 560, y: content.bounds.height - 330), in: content)
          } else {
            DeckMenuPresenter.pop(menu)
          }
        }
      }
    }
    .onAppear { goodWidth = windowWidth >= DeckLayoutProbe.minimumWidth ? windowWidth : goodWidth; config.autoPageScale = pageScaleValue; config.autoTileSize = autoTileValue }
    .deckOnChange(of: windowWidth) { _, new in
      guard new >= DeckLayoutProbe.minimumWidth else { return }   // a transient sliver is not a resize
      goodWidth = new
      #if MLC_CONCEPT_HARNESS
      if conceptEnv("MLC_TILELOG") != nil {
        let t = tileLayout(landscape: false), l = tileLayout(landscape: true)
        fputs(String(format: "TILELOG w=%.0f scale=%.4f tile=%.0f count=%d screen=%.2f landscape=%.0f lcount=%d lscreen=%.2f\n", new, scale, t.size, t.count, t.size * scale, l.size, l.count, l.size * scale), stderr)
      }
      #endif
    }
    // the shown "automatic" values are only for the sliders; written when they really moved
    .deckOnChange(of: pageScaleValue) { _, value in if abs(config.autoPageScale - value) > 0.002 { config.autoPageScale = value } }
    .deckOnChange(of: autoTileValue) { _, value in if abs(config.autoTileSize - value) > 0.5 { config.autoTileSize = value } }
    .deckScrollClipDisabled(heroMode)
    .deckNoTopEdgeEffect(heroMode)
    .background(Color(nsColor: .windowBackgroundColor))
    .ignoresSafeArea(.container, edges: heroMode ? .top : [])
    .onAppear { _ = DeckHomeEditState.shared; DeckHomeCustomizer.shared.resolvedProvider = { model.resolveHome(config) } }
    .contextMenu {
      Button(DL("deck.customize")) { DeckHomeCustomizer.shared.show() }
    }
  }

  // MARK: sections

  @ViewBuilder
  private func sectionContent(_ id: DeckSectionID) -> some View {
    let host = model.host
    if id != .computer, let host, !host.paired {
      EmptyView()   // an unpaired host has no app list to show
    } else {
      sectionBody(id).controllerSection(id.rawValue).opacity(id != .computer && host?.online == false ? 0.4 : 1)
        .allowsHitTesting(id == .computer || host?.online != false)
    }
  }

  @ViewBuilder
  private func sectionBody(_ id: DeckSectionID) -> some View {
    let host = model.host
    switch id {
    case .computer:
      if let host { computerBlock(host) }
    case .continuePlaying:
      // 最近使用 is always a row of 16:9 cards, whatever 应用卡片 is; it follows the same adaptive size logic
      shelf(DL("deck.section.continuePlaying"), model.continueApps(runningFirst: ringRunning), landscape: true,
            ringRunning: ringRunning, controls: !computerVisible)
    case .pinned:
      shelf(DL("deck.section.pinned"), model.pinnedApps, landscape: landscapeTiles)
    case .apps:
      appsSection
    case .hostInfo:
      if let host, host.online, host.paired {
        section(DL("deck.section.hostInfo")) {
          VStack(alignment: .leading, spacing: 18) {
            DeckOfflineInfo(host: host, model: model, parts: .addresses, maxWidth: 620)
            DeckHostInfoCard(host: host, kindSeen: model.fsKindSeen).frame(maxWidth: 620)
          }
        }
      }
    case .recentSessions:
      if let host, !host.facts.sessions.isEmpty {
        section(DL("deck.section.recentSessions")) { DeckRecentSessions(host: host, model: model).frame(maxWidth: 620) }
      }
    }
  }

  @ViewBuilder
  private var pair: some View {
    if let host = model.host {
      HStack(alignment: .top, spacing: 28) {
        section(DL("deck.section.hostInfo")) {
          VStack(alignment: .leading, spacing: 18) {
            DeckOfflineInfo(host: host, model: model, parts: .addresses, maxWidth: .infinity)
            DeckHostInfoCard(host: host, kindSeen: model.fsKindSeen)
          }
        }
        if !host.facts.sessions.isEmpty {
          section(DL("deck.section.recentSessions")) { DeckRecentSessions(host: host, model: model) }
        }
      }
      .padding(.horizontal, DeckInset.page)
    }
  }

  private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(title).font(.system(size: 20, weight: .bold))
      content()
    }
    .padding(.horizontal, DeckInset.page)
  }

  @ViewBuilder
  private func shelf(_ title: String, _ apps: [TemporaryApp], landscape: Bool, ringRunning: Bool = false, controls: Bool = false) -> some View {
    if !apps.isEmpty {
      DeckShelf(title: title, apps: apps, model: model, landscape: landscape,
                tile: tileBase(landscape: landscape), factor: tileFactor(landscape: landscape), columns: tileColumns(landscape: landscape),
                ringRunning: ringRunning, controls: controls)
    }
  }

  /// 应用: a grid of the one tile size, for any number of apps.
  @ViewBuilder
  private var appsSection: some View {
    var apps = model.libraryApps
    let _ = {
      if !computerVisible, let running = model.runningGame, let index = apps.firstIndex(where: { $0.id == running.id }) {
        apps.insert(apps.remove(at: index), at: 0)
      }
    }()
    let appControls = !computerVisible && !continueVisible
    let repeated = continueVisible && model.runningGame.map { running in model.continueApps(runningFirst: ringRunning).contains { $0.id == running.id } } == true
    if !apps.isEmpty {
      VStack(alignment: .leading, spacing: 14) {
        HStack(alignment: .center) {
          DeckSectionTitle(title: DL("deck.section.apps"))
          Spacer(minLength: 12)
          DeckTileZoom()
        }
        // One flat list of tiles in a layout of ours (not a lazy grid: the page is drawn scaled; not rows of
        // stacks: a tile keeps its identity when the column count changes, so it slides to its new place).
        let columnCount = tileCount(landscape: landscapeTiles)
        let tile = tileBase(landscape: landscapeTiles)
        let factor = tileFactor(landscape: landscapeTiles)
        // the cells are LAID OUT at tile * factor (real sizes, drawn by the system at that size), not scaled afterwards
        DeckTiles(items: apps, id: \.deckKey, tile: tile * factor, columns: columnCount) { app in
          DeckAppCell(app: app, model: model,
                      subtitle: resolved.large && !landscapeTiles ? deckFacts(for: app, model: model, running: false, includeSource: false) : [],
                      highlightRunning: ringRunning, suppressRunning: repeated, runningControls: appControls,
                      landscape: landscapeTiles)
            .environment(\.deckScale, factor)
            .frame(width: tile * factor)
        }
        // only a change of the column count is eased (short, interruptible spring); the size follows the window
        .animation(.spring(response: 0.28, dampingFraction: 0.9), value: columnCount)
      }
      .padding(.horizontal, DeckInset.page)
      .animation(.spring(response: 0.35, dampingFraction: 0.82), value: config.tileSize)
    }
  }

  private func isOffline(_ host: DeckHost) -> Bool { !host.online || !host.paired }

  /// The computer's header and, when it is off or not paired, its info. Four arrangements are drawn for the
  /// offline page (MLC_OFFLINE in the harness): today, A centred column, B two columns, C under the
  /// preview, D columns by width.
  @ViewBuilder
  private func computerBlock(_ host: DeckHost) -> some View {
    let layout = DeckOfflineLayout.current
    let inner = colWidth - DeckInset.page * 2
    if isOffline(host), layout == .a {
      let column = min(inner, 800)
      VStack(alignment: .leading, spacing: 34) {
        DeckComputerCard(host: host, model: model, compact: resolved.compact, contentWidth: column)
        DeckOfflineBlock(host: host, model: model, contentWidth: column, maxWidth: column)
      }
      .frame(width: column)
      .frame(maxWidth: .infinity)
    } else if isOffline(host), layout == .c {
      DeckComputerCard(host: host, model: model, compact: resolved.compact, contentWidth: inner,
                       leftExtra: AnyView(DeckOfflineInfo(host: host, model: model, parts: .addresses, maxWidth: 560)),
                       rightExtra: AnyView(DeckOfflineInfo(host: host, model: model, parts: .rest, maxWidth: 680)))
        .padding(.horizontal, DeckInset.page)
    } else {
      VStack(alignment: .leading, spacing: 34) {
        DeckComputerCard(host: host, model: model, compact: resolved.compact, contentWidth: inner)
        if isOffline(host) { DeckOfflineBlock(host: host, model: model, contentWidth: inner, maxWidth: 640) }
      }
      .padding(.horizontal, DeckInset.page)
    }
  }

  @ViewBuilder
  private func offlineInfo(_ host: DeckHost) -> some View {
    if isOffline(host) {
      DeckOfflineBlock(host: host, model: model, contentWidth: colWidth - DeckInset.page * 2, maxWidth: 640).padding(.horizontal, DeckInset.page)
    }
  }
}

// MARK: - 自定义主页 (Safari's start-page customise popover)

/// Owns the popover. It hangs off a button in the window toolbar (top right), so it opens downward
/// inside the window instead of sticking out of it.
@objc(MLDeckHomeCustomizer)
public final class DeckHomeCustomizer: NSObject, NSPopoverDelegate {
  @objc public static let shared = DeckHomeCustomizer()
  /// The toolbar button, set when the toolbar item is made.
  @objc public weak var anchor: NSView?
  var resolvedProvider: (() -> DeckResolvedHome)?
  private var popover: NSPopover?

  @objc public func toggle(_ sender: Any?) {
    if let popover, popover.isShown { popover.performClose(sender); return }
    show()
  }

  /// B on the pad: false when the popover is not up.
  func close() -> Bool {
    guard let popover, popover.isShown else { return false }
    popover.performClose(nil)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak popover] in
      guard let popover, popover.isShown else { return }
      // a popover that stays (an app that is not in front does not finish the close) is closed without its animation
      popover.animates = false
      popover.close()
      popover.animates = true
      LogMessage(LOG_I, "[controller-ui] 自定义主页 popover still up after performClose: closed directly, shown=\(popover.isShown)")
    }
    return true
  }

  @objc public func show() {
    guard let anchor, anchor.window != nil else { return }
    if popover?.isShown == true { return }
    // the most height: the visible frame of the screen the window is on, less room for the toolbar and the arrow
    let screenHeight = anchor.window?.screen?.visibleFrame.height ?? NSScreen.main?.visibleFrame.height ?? 800
    let maxHeight = max(300, screenHeight - 120)
    let pop = NSPopover()
    let panel = DeckCustomizePanel(config: DeckHomeConfig.shared, edit: DeckHomeEditState.shared, resolvedProvider: { [weak self] in
      self?.resolvedProvider?() ?? DeckResolvedHome(entries: DeckHomeConfig.defaultLayout, layout: .hero, tiles: .portrait, compact: false, large: false)
    }, maxHeight: maxHeight, onContentHeight: { [weak pop] height in
      // set from the measured content, never by the hosting controller on its own: nothing is resized half way through a layout
      guard let pop, height > 1 else { return }
      let target = min(height, maxHeight)
      if abs(pop.contentSize.height - target) > 0.5 || pop.contentSize.width != DeckCustomizePanel.width {
        pop.contentSize = NSSize(width: DeckCustomizePanel.width, height: target)
      }
    })
    let controller = NSHostingController(rootView: panel)
    let fitHeight: CGFloat
    if #available(macOS 13.0, *) {
      controller.sizingOptions = []
      fitHeight = controller.sizeThatFits(in: CGSize(width: DeckCustomizePanel.width, height: maxHeight)).height
    } else {
      // before macOS 13 the hosting view reports its size itself
      fitHeight = controller.view.fittingSize.height
    }
    pop.contentSize = NSSize(width: DeckCustomizePanel.width, height: min(max(fitHeight, 200), maxHeight))
    pop.behavior = .transient
    pop.contentViewController = controller
    pop.delegate = self
    pop.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    popover = pop
  }
}

struct DeckCustomizePanel: View {
  @ObservedObject var config: DeckHomeConfig
  @ObservedObject var edit: DeckHomeEditState
  let resolvedProvider: () -> DeckResolvedHome

  /// Fixed: the popover is its own window and neither the page scale nor the window under it changes it.
  static let width: CGFloat = 380
  /// The most height the popover may take (the screen it is on, less margins); beyond it the content scrolls.
  var maxHeight: CGFloat = 640
  var onContentHeight: (CGFloat) -> Void = { _ in }

  private var resolved: DeckResolvedHome { resolvedProvider() }
  private var entries: [DeckSectionEntry] { resolved.entries }

  /// The content has one width and is measured for its height; when it does not fit the screen it scrolls inside the
  /// popover. It is never squeezed, never moved: the size the popover takes is set from this measurement by its owner.
  var body: some View {
    ScrollView(.vertical, showsIndicators: false) {
      content
        .background(GeometryReader { proxy in Color.clear.preference(key: DeckCustomizeHeightKey.self, value: proxy.size.height) })
    }
    .deckBounceBasedOnSize()
    .controllerBackHandler(active: true) { DeckHomeCustomizer.shared.close() }
    .frame(width: Self.width)
    .frame(maxHeight: maxHeight)
    .onPreferenceChange(DeckCustomizeHeightKey.self) { onContentHeight($0) }
  }

  private var content: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 8) {
        ForEach(DeckHomeStyle.allCases, id: \.self) { style in
          DeckPresetCard(style: style, selected: config.style == style) { config.style = style }
        }
      }

      HStack(spacing: 8) {
        Text(DL("deck.opt.size")).font(.system(size: 13))
        Spacer(minLength: 8)
        Image(systemName: "square.grid.3x3").font(.system(size: 10)).foregroundStyle(.secondary)
        Slider(value: Binding(get: { config.adaptiveTiles ? config.autoTileSize : config.tileSize },
                              set: { v in withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { config.tileSize = v; config.adaptiveTiles = false } }), in: 100...240)
          .frame(width: 130).controlSize(.small)
        Image(systemName: "square.grid.2x2").font(.system(size: 12)).foregroundStyle(.secondary)
      }

      Toggle(isOn: Binding(get: { config.adaptive }, set: { on in
        withAnimation(.smooth(duration: 0.25)) { config.adaptiveTiles = on }
      })) {
        Label(DL("deck.opt.adaptive"), systemImage: "arrow.up.left.and.arrow.down.right").font(.system(size: 13))
      }
      .toggleStyle(.switch)
      .controlSize(.small)

      VStack(alignment: .leading, spacing: 8) {
        optionRow(DL("deck.opt.layout"), selection: Binding(get: { resolved.layout }, set: { makeCustom(layout: $0) }), DeckHomeLayout.allCases) { $0.title }
        optionRow(DL("deck.opt.preview"), selection: $config.preview, DeckHostPreview.allCases) { $0.title }
        optionRow(DL("deck.opt.tiles"), selection: Binding(get: { resolved.tiles }, set: { makeCustom(tiles: $0) }), DeckTileStyle.allCases) { $0.title }
      }

      VStack(spacing: 0) {
        ForEach(entries) { entry in
          VStack(spacing: 0) {
            if edit.dropBefore == entry.id && edit.dragging != entry.id {
              Capsule().fill(Color.accentColor).frame(height: 3).padding(.horizontal, 4).padding(.vertical, 1)
            }
            row(entry)
          }
        }
      }

      HStack {
        Button(DL("deck.reset")) { config.reset() }.controllerButtonStyle(.borderless).foregroundStyle(.secondary)
        Spacer()
      }
      .font(.system(size: 12))
    }
    .padding(16)
    .frame(width: Self.width, alignment: .leading)
  }

  private func optionRow<T: Hashable>(_ title: String, selection: Binding<T>, _ all: [T], label: @escaping (T) -> String) -> some View {
    // the label and the segments side by side when they fit the width, the segments under the label when they do not
    // (a longer language, a wider system font): the row never grows past the popover and never loses its label
    let picker = Picker("", selection: selection) {
      ForEach(all, id: \.self) { Text(label($0)).tag($0) }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    let beside = HStack(spacing: 10) {
      Text(title).font(.system(size: 13)).lineLimit(1).fixedSize()
      Spacer(minLength: 8)
      picker.fixedSize()
    }
    let below = VStack(alignment: .leading, spacing: 6) {
      Text(title).font(.system(size: 13))
      picker.frame(maxWidth: .infinity)
    }
    // ViewThatFits (macOS 13) measures; before it the width is estimated from the texts: the label, and every segment with its padding
    let font = NSFont.systemFont(ofSize: 13)
    func width(_ text: String) -> CGFloat { (text as NSString).size(withAttributes: [.font: font]).width }
    let needed = width(title) + 18 + all.reduce(CGFloat(0)) { $0 + width(label($1)) + 24 }
    return deckFitsBesideOrBelow(beside: beside, below: below, estimatedFit: needed <= Self.width - 32)
  }

  private func row(_ entry: DeckSectionEntry) -> some View {
    let lifted = edit.dragging == entry.id
    return HStack(spacing: 10) {
      Toggle(isOn: Binding(get: { entry.visible }, set: { toggle(entry.id, $0) })) {
        Label(entry.id.title, systemImage: entry.id.symbol).font(.system(size: 13))
      }
      .toggleStyle(.checkbox)
      .disabled(entry.id.isRequired)
      Spacer(minLength: 0)
      Image(systemName: "line.3.horizontal").font(.system(size: 12, weight: .semibold)).foregroundStyle(.tertiary)
        .frame(width: 24, height: 24).contentShape(Rectangle())
        .deckTouchTarget()
        .deckDraggable(entry.id.rawValue) { DeckDragChip(title: entry.id.title, symbol: entry.id.symbol) }
        .controllerFocusMenu(key: "section:\(entry.id.rawValue)", radius: 8) { (title: entry.id.title, menu: reorderMenu(entry)) }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(lifted ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.18) : Color.clear))
    .scaleEffect(lifted ? 1.03 : 1)
    .shadow(color: .black.opacity(lifted ? 0.3 : 0), radius: 8, y: 4)
    .deckDropString { raw in
      if let id = DeckSectionID(rawValue: raw) { move(id, before: entry.id) }
      edit.dropBefore = nil
    } isTargeted: { targeted in
      edit.dropBefore = targeted ? entry.id : (edit.dropBefore == entry.id ? nil : edit.dropBefore)
    }
  }

  /// Any edit turns the style into 自定义, starting from what the page shows now.
  private func makeCustom(entries list: [DeckSectionEntry]? = nil, layout: DeckHomeLayout? = nil, tiles: DeckTileStyle? = nil) {
    let shown = resolved
    config.custom = list ?? shown.entries
    config.layoutMode = layout ?? shown.layout
    config.tiles = tiles ?? shown.tiles
    config.style = .custom
  }

  private func commit(_ list: [DeckSectionEntry]) { makeCustom(entries: list) }

  private func toggle(_ id: DeckSectionID, _ visible: Bool) {
    var list = entries
    if let index = list.firstIndex(where: { $0.id == id }) { list[index].visible = visible }
    commit(list)
  }

  /// The pad's way to drag a section: 上移 / 下移 (the pointer drags the handle).
  private func reorderMenu(_ entry: DeckSectionEntry) -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    let list = entries
    let index = list.firstIndex { $0.id == entry.id } ?? 0
    menu.addItem(ControllerMenuBuilder.item(title: DL("deck.addr.moveUp"), enabled: index > 0) { move(entry.id, before: list[index - 1].id) })
    menu.addItem(ControllerMenuBuilder.item(title: DL("deck.addr.moveDown"), enabled: index + 1 < list.count) {
      if index + 2 < list.count { move(entry.id, before: list[index + 2].id) } else { moveToEnd(entry.id) }
    })
    return menu
  }

  private func moveToEnd(_ id: DeckSectionID) {
    var list = entries
    guard let from = list.firstIndex(where: { $0.id == id }) else { return }
    list.append(list.remove(at: from))
    commit(list)
  }

  private func move(_ id: DeckSectionID, before target: DeckSectionID) {
    guard id != target else { return }
    var list = entries
    guard let from = list.firstIndex(where: { $0.id == id }) else { return }
    let item = list.remove(at: from)
    let to = list.firstIndex(where: { $0.id == target }) ?? list.endIndex
    list.insert(item, at: to)
    commit(list)
  }
}

private struct DeckCustomizeHeightKey: PreferenceKey {
  static var defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct DeckDragChip: View {
  let title: String
  let symbol: String

  var body: some View {
    Label(title, systemImage: symbol).font(.system(size: 13, weight: .semibold))
      .padding(.horizontal, 12).padding(.vertical, 7)
      .background(Capsule().fill(.regularMaterial))
  }
}

// MARK: - Size controls

/// The small zoom control at the right end of the 应用 header (Finder / Photos): two grid glyphs and a
/// slider. It is the same setting as 卡片大小 in 自定义主页, so the two always agree.
struct DeckTileZoom: View {
  @ObservedObject private var config = DeckHomeConfig.shared

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "square.grid.3x3").font(.system(size: 10)).foregroundStyle(.secondary)
      Slider(value: Binding(get: { config.adaptiveTiles ? config.autoTileSize : config.tileSize },
                            set: { v in withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { config.tileSize = v; config.adaptiveTiles = false } }), in: 100...240)
        .frame(width: 96).controlSize(.mini)
      Image(systemName: "square.grid.2x2").font(.system(size: 12)).foregroundStyle(.secondary)
      if !config.adaptiveTiles {
        Button(DL("deck.auto")) { withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { config.adaptiveTiles = true } }
          .controllerButtonStyle(.borderless).font(.system(size: 11)).foregroundStyle(Color.accentColor)
      }
    }
    .deckHelp(DL("deck.opt.size"))
  }
}

/// Steps for the View menu: 放大卡片 / 缩小卡片 (⌘= / ⌘−), 实际大小 / 放大页面 / 缩小页面 (⌘0 / ⌘⌥= / ⌘⌥−).
@objc(MLDeckZoom)
public final class DeckZoom: NSObject {
  @objc public static func stepTiles(_ direction: Int) {
    let config = DeckHomeConfig.shared
    let base = config.adaptiveTiles ? config.autoTileSize : config.tileSize
    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
      config.tileSize = min(240, max(100, base + Double(direction) * 14))
      config.adaptiveTiles = false
    }
  }

  /// The page has no scale any more (it was a transform that blurred every card); these stay for the menu's selectors.
  @objc public static func stepPage(_ direction: Int) {}
  @objc public static func resetPage() {}

  /// The system text size, where macOS reports one through Dynamic Type (normally .large = 1).
  static func typeFactor(_ size: DynamicTypeSize) -> CGFloat {
    switch size {
    case .xSmall: return 0.88
    case .small: return 0.94
    case .medium: return 0.97
    case .large: return 1.0
    case .xLarge: return 1.06
    case .xxLarge: return 1.12
    case .xxxLarge: return 1.18
    default: return 1.3
    }
  }

  @objc public static func title(forAction name: String) -> String {
    switch name {
    case "tiles+": return DL("deck.menu.tilesIncrease")
    case "tiles-": return DL("deck.menu.tilesDecrease")
    case "page0": return DL("deck.menu.pageActual")
    case "page+": return DL("deck.menu.pageIncrease")
    default: return DL("deck.menu.pageDecrease")
    }
  }
}

/// 自适应大小: the page scale as a smooth function of the width of the page area (the window less the
/// sidebar). Piecewise linear through the points below, so there is no step anywhere; clamped to 0.9...1.3.
/// 1032 pt is a 1280 window (1.00), 1480 a 1728 window (1.10), 1672 a 1920 window (1.18), 2312 a 2560 window
/// (1.30). The slope is steeper at the start because the first 450 pt of extra width are what a laptop
/// screen has, and the type should grow there before the margins do.
enum DeckAdaptive {
  private static let curve: [(CGFloat, Double)] = [(800, 0.90), (1032, 1.00), (1480, 1.10), (1672, 1.18), (2312, 1.30)]

  /// The scale in steps of 0.01: a step is 1 % of the page (invisible as a jump, and monotone), and the page
  /// is not transformed afresh on every frame of a window drag, which cost most of a frame.
  static func pageScale(forWidth width: CGFloat) -> Double {
    (continuousPageScale(forWidth: width) * 100).rounded() / 100
  }

  static func continuousPageScale(forWidth width: CGFloat) -> Double {
    guard let first = curve.first, let last = curve.last else { return 1 }
    if width <= first.0 { return first.1 }
    if width >= last.0 { return last.1 }
    for index in 1..<curve.count where width <= curve[index].0 {
      let (x0, y0) = curve[index - 1], (x1, y1) = curve[index]
      return y0 + (y1 - y0) * Double((width - x0) / (x1 - x0))
    }
    return last.1
  }
}

/// Draws the page scaled. At exactly 1 it does nothing at all (no transform layer), since a scale transform
/// around the page makes the system render group effects (the greyed offline sections) through an offscreen
/// layer that can come out at the wrong size.
private struct DeckPageScaleModifier: ViewModifier {
  let scale: CGFloat
  let windowWidth: CGFloat
  let contentHeight: CGFloat

  func body(content: Content) -> some View {
    // The page takes its natural height whatever it is offered: a height-limited offer inside the frame made aspect-fit
    // pictures (tiles, preview) shrink to fit it. No transform of any kind: everything is drawn at its real size.
    content.fixedSize(horizontal: false, vertical: true).frame(width: windowWidth, alignment: .topLeading)
  }
}

/// The page's content frame, for the popover test (open and close it 50 times; the frame must not move) and
/// the guard for transient widths.
@objc(MLDeckLayoutProbe)
public final class DeckLayoutProbe: NSObject {
  static let minimumWidth: CGFloat = 420
  @objc public static var frameString = ""
  private static var frame = CGRect.zero
  static func record(_ rect: CGRect) {
    frame = rect
    frameString = String(format: "%.1f,%.1f,%.1f,%.1f", rect.minX, rect.minY, rect.width, rect.height)
  }
}

/// The tile grid of the home: DeckTileGrid (a Layout, macOS 13), and on macOS 12 rows of stacks with the same pitch.
/// The tiles line up the same way; before macOS 13 they do not slide when the column count changes.
struct DeckTiles<Item, ID: Hashable, Cell: View>: View {
  let items: [Item]
  let id: KeyPath<Item, ID>
  let tile: CGFloat
  let columns: Int
  let cell: (Item) -> Cell

  init(items: [Item], id: KeyPath<Item, ID>, tile: CGFloat, columns: Int, @ViewBuilder cell: @escaping (Item) -> Cell) {
    self.items = items
    self.id = id
    self.tile = tile
    self.columns = columns
    self.cell = cell
  }

  var body: some View {
    if #available(macOS 13.0, *), DeckOS.level >= 13 {
      DeckTileGrid(tile: tile, factor: 1, columns: columns) {
        ForEach(items, id: id) { cell($0) }
      }
    } else {
      let cols = max(1, columns)
      let rows = stride(from: 0, to: items.count, by: cols).map { Array(items[$0..<min($0 + cols, items.count)]) }
      VStack(alignment: .leading, spacing: 28) {
        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
          HStack(alignment: .top, spacing: 24) {
            ForEach(row, id: id) { cell($0) }
          }
        }
      }
    }
  }
}

/// A grid of tiles of one width: item i goes to column i % columns, row i / columns, left aligned, standard
/// gaps. Row height is the tallest tile of the row. Being a Layout it moves tiles by position, so a change of
/// the column count (animated by the caller) slides every tile to its new place instead of rebuilding rows.
@available(macOS 13.0, *)
struct DeckTileGrid: Layout {
  /// The tiles' own (unscaled) width; each is drawn scaled by `factor` by the caller (scaleEffect, top leading),
  /// and the grid places them on the scaled pitch.
  var tile: CGFloat
  var factor: CGFloat = 1
  var columns: Int
  var spacing: CGFloat = 24
  var rowSpacing: CGFloat = 28
  /// Items past `rows` rows are not placed (callers pass only what is shown).
  var rows: Int = 100_000

  /// The tiles' heights at this width, measured once per layout pass (every ancestor asks for the size several
  /// times, and each ask would otherwise walk every tile's view tree again).
  struct Cache { var heights: [CGFloat]? }

  func makeCache(subviews: Subviews) -> Cache { Cache(heights: nil) }

  private func heights(_ subviews: Subviews, _ cache: inout Cache) -> [CGFloat] {
    if let known = cache.heights, known.count == subviews.count { return known }
    let proposal = ProposedViewSize(width: tile, height: nil)
    let measured = subviews.map { $0.sizeThatFits(proposal).height }
    cache.heights = measured
    return measured
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
    let h = heights(subviews, &cache)
    let cols = max(1, columns)
    let shown = min(h.count, cols * rows)
    guard shown > 0 else { return .zero }
    var total: CGFloat = 0
    var index = 0
    var rowCount = 0
    while index < shown {
      total += h[index..<min(index + cols, shown)].max() ?? 0
      index += cols; rowCount += 1
    }
    let width = CGFloat(min(cols, shown)) * tile * factor + CGFloat(min(cols, shown) - 1) * spacing
    return CGSize(width: width, height: total * factor + CGFloat(rowCount - 1) * rowSpacing)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
    let h = heights(subviews, &cache)
    let cols = max(1, columns)
    var y = bounds.minY
    var index = 0
    var log = ""
    while index < subviews.count {
      let row = index / cols
      let end = min(index + cols, subviews.count)
      let rowHeight = h[index..<end].max() ?? 0
      for i in index..<end {
        let x = bounds.minX + CGFloat(i - index) * (tile * factor + spacing)
        if row < rows {
          subviews[i].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: tile, height: nil))
          #if MLC_CONCEPT_HARNESS
          log += String(format: "%.0f,%.0f;", x, y)
          #endif
        } else {
          // beyond the visible rows: kept in the tree at the last row's place, invisible, so no tile pops in or out
          subviews[i].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: 0, height: 0))
        }
      }
      if row < rows { y += rowHeight * factor + rowSpacing }
      index = end
    }
    #if MLC_CONCEPT_HARNESS
    if conceptEnv("MLC_GRIDLOG") != nil && subviews.count >= 20 { fputs("GRIDLOG tile=\(Int(tile)) cols=\(cols) pos=\(log)\n", stderr) }
    #endif
  }
}

final class DeckHomeMemo {
  var key = ""
  var value: DeckResolvedHome?
}
