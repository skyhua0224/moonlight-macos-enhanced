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

