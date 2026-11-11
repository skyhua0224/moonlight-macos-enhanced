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

@available(macOS 14.0, *)
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

@available(macOS 14.0, *)
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

@available(macOS 14.0, *)
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
    return await Task.detached(priority: .userInitiated) {
      var best: (URL, Date, Bool)?
      for (appId, desktop) in candidates {
        guard let url = StreamBackdropStore.frameURL(host: uuid, app: appId),
              let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { continue }
        if best == nil || (desktop && !best!.2) || (desktop == best!.2 && date > best!.1) { best = (url, date, desktop) }
      }
      let url = best?.0 ?? thumbURL(uuid)
      guard FileManager.default.fileExists(atPath: url.path) else { return nil }
      let key = "frame/\(url.path)/\(modified(url))/\(Int(displayWidth / 100))" as NSString
      if let hit = previews.object(forKey: key) { return hit }
      guard let cg = decode(url, maxPixel: 1280), let image = frosted(cg, radius: 25, displayWidth: displayWidth, saturation: 1.15) else { return nil }
      previews.setObject(image, forKey: key)
      return image
    }.value
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
    let image: NSImage? = await Task.detached(priority: .userInitiated) {
      guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = props[kCGImagePropertyPixelWidth] as? Double,
            let height = props[kCGImagePropertyPixelHeight] as? Double,
            width >= height * 1.2,
            let cg = decode(url, maxPixel: displayWidth < 800 ? 1280 : 2400) else { return nil }
      if Double(cg.width) * 1.5 < Double(displayWidth * scale) {
        return frosted(cg, radius: 8, displayWidth: displayWidth, saturation: 1.05)
      }
      return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }.value
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
    return await Task.detached(priority: .userInitiated) { grayscale(found) }.value
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
@available(macOS 14.0, *)
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
@available(macOS 14.0, *)
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
@available(macOS 14.0, *)
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
@available(macOS 14.0, *)
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

@available(macOS 14.0, *)
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

@available(macOS 14.0, *)
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

@available(macOS 14.0, *)
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

@available(macOS 14.0, *)
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
@available(macOS 14.0, *)
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

