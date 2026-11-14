//
//  DeckContent.swift
//  Round 2 content areas for the apps page, inside the sidebar layout:
//    A1 "Games"  a Games-app Home: featured hero on the Landmarks pattern, a Continue Playing
//                shelf of landscape cards, a Library grid with small facts.
//    A2 "TV"     a taller featured hero, then poster shelves and a grid.
//    A3 "Quiet"  no hero; large titles and a clean grid; the running app is a now-playing
//                accessory in the sidebar.
//  The backdrop of a hero is the host's landscape art when a Foundation Sunshine host sends
//  it, and is otherwise derived from the poster: enlarged, blurred, with the poster on top.
//

import AppKit
import SwiftUI

// MARK: - App facts (Foundation Sunshine /applist fields; empty on other hosts)

struct DeckAppInfo {
  /// Foundation Sunshine: bigscreen | desktop | game | tool.
  var kind: String?
  var source: String?
  var launch: String?
  var lastPlayed: Date?
  var playSeconds: Int?
  var sessionStart: Date?

  var sourceName: String? {
    switch source {
    case "steam": return "Steam"
    case "sparxie": return "Sparxie"
    case "xbox": return "Xbox"
    default: return nil
    }
  }

  var launchSymbol: String? {
    switch launch {
    case "touch": return "hand.tap"
    case "kbm": return "gamecontroller"
    default: return nil
    }
  }

  var launchName: String? {
    switch launch {
    case "touch": return DL("deck.touch")
    case "kbm": return DL("deck.kbm")
    default: return nil
    }
  }
}

extension TemporaryApp {
  /// A Foundation Sunshine host before the FsKind field (2026.1110.165906) still ships its default entries
  /// by name: 大屏 / Big Screen and Desktop / 桌面. FsKind, when the host sends it, always wins (this is
  /// only asked when it is absent). Other hosts: nothing guessed.
  var fallbackKind: String? {
    guard let uuid = host?.uuid, !uuid.isEmpty, DeckFactsStore.isFoundation(uuid) else { return nil }
    return deckKindFromName(name ?? "")
  }

  var deckInfo: DeckAppInfo {
    let e = fsExtras
    func date(_ key: String) -> Date? { DeckTimeRules.fromEpoch(Double(e[key] ?? "")) }
    return DeckAppInfo(kind: e["FsKind"] ?? fallbackKind, source: e["FsSource"], launch: e["FsLaunchMode"], lastPlayed: date("FsLastPlayed"),
                       playSeconds: Int(e["FsPlaySeconds"] ?? ""), sessionStart: date("FsSession"))
  }
}

extension DeckTime {
  static func duration(_ seconds: TimeInterval) -> String {
    var calendar = Calendar.current
    calendar.locale = locale
    let formatter = DateComponentsFormatter()
    formatter.calendar = calendar
    formatter.unitsStyle = .abbreviated
    formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
    formatter.maximumUnitCount = 2
    return formatter.string(from: max(60, seconds)) ?? ""
  }
}

// MARK: - Model views

@available(macOS 14.0, *)
extension DeckAppsModel {
  func lastPlayed(_ app: TemporaryApp) -> Date? { app.deckInfo.lastPlayed }

  /// Most recently played first: the host's last-played times when it sends them, otherwise the
  /// order this client recorded.
  /// The entries the 连接 / 大屏模式 buttons carry are not repeated in the grid (DeckConnectPlan.hiddenFromGrid): on a
  /// Foundation Sunshine host 桌面 and 大屏; on another host the Desktop app the button starts. A host with no Desktop
  /// app hides nothing: 连接 <first app> and the grid still lists it.
  func isConnectEntry(_ app: TemporaryApp) -> Bool {
    connectPlan.hiddenFromGrid.contains(app.id ?? "")
  }

  /// 最近使用: only apps that were really used (DeckRecentRules): the host's last-played time or a session this Mac
  /// recorded, each a valid date. Not the app list's order, not an entry without a time.
  var recentApps: [TemporaryApp] {
    let sessions = host?.facts.sessions ?? []
    let candidates = apps.filter { !isConnectEntry($0) }.map { app in
      DeckRecentCandidate(id: app.id ?? "", hostLastPlayed: app.deckInfo.lastPlayed,
                          ownLastStart: sessions.first { $0.appId == app.id }?.start)
    }
    return DeckRecentRules.recent(candidates).compactMap { id in apps.first { $0.id == id } }
  }
  var pinnedApps: [TemporaryApp] { items.filter { $0.pinned && !isConnectEntry($0) } }
  /// 应用: 大屏模式 first, then by name.
  var libraryApps: [TemporaryApp] {
    if let cachedLibrary { return cachedLibrary }
    let sorted = apps.filter { !isConnectEntry($0) }.sorted { a, b in
      let (ba, bb) = (deckIsBigScreen(a), deckIsBigScreen(b))
      if ba != bb { return ba }
      return (a.name ?? "").localizedCaseInsensitiveCompare(b.name ?? "") == .orderedAscending
    }
    cachedLibrary = sorted
    return sorted
  }
  var featured: TemporaryApp? { hero ?? recentApps.first }
  var isRunningFeatured: Bool { featured.map { $0.id == runningId } ?? false }
}

// MARK: - Shared pieces

extension View {
  /// Lets a hero image run under the floating sidebar and toolbar (macOS 26 background extension).
  @ViewBuilder func deckBackgroundExtension() -> some View {
    if #available(macOS 26.0, *) { self.backgroundExtensionEffect() } else { self }
  }
}

/// Small facts in secondary text, each with an SF Symbol; no pills.
struct DeckFactItem: Identifiable {
  let id = UUID()
  var symbol: String?
  var text: String
  var tint: Color?
}

struct DeckFactsRow: View {
  let items: [DeckFactItem]
  var onArt = false
  var size: CGFloat = 12

  var body: some View {
    HStack(spacing: 12) {
      ForEach(items) { item in
        HStack(spacing: 4) {
          if let symbol = item.symbol {
            Image(systemName: symbol).font(.system(size: size - 1, weight: .semibold)).foregroundStyle(item.tint ?? base)
          }
          Text(item.text).font(.system(size: size, weight: .medium)).foregroundStyle(base)
        }
      }
    }
    .lineLimit(1)
  }

  private var base: Color { onArt ? Color.white.opacity(0.82) : Color.secondary }
}

@available(macOS 14.0, *)
func deckFacts(for app: TemporaryApp, model: DeckAppsModel, running: Bool, includeSource: Bool = true) -> [DeckFactItem] {
  let info = app.deckInfo
  var items: [DeckFactItem] = []
  if running {
    var text = DL("deck.running")
    if let start = info.sessionStart { text += " · " + DLf("deck.runFor", DeckTime.duration(Date().timeIntervalSince(start))) }
    items.append(DeckFactItem(symbol: "play.circle.fill", text: text, tint: .green))
  } else if let when = DeckTime.relative(info.lastPlayed) {
    items.append(DeckFactItem(symbol: "clock", text: DLf("deck.lastPlayed", when), tint: nil))
  }
  if includeSource, let name = info.sourceName { items.append(DeckFactItem(symbol: nil, text: name, tint: nil)) }
  if let symbol = info.launchSymbol, let name = info.launchName { items.append(DeckFactItem(symbol: symbol, text: name, tint: nil)) }
  if app.hdrSupported { items.append(DeckFactItem(symbol: "sun.max.fill", text: "HDR", tint: nil)) }
  return items
}

/// A square app icon: the host's icon art when it has one, otherwise the poster, cropped.
@available(macOS 14.0, *)
struct DeckAppIcon: View {
  let app: TemporaryApp
  var size: CGFloat = 34
  var version = 0
  @SwiftUI.State private var image: NSImage?

  var body: some View {
    ZStack {
      if let image {
        Image(nsImage: image).resizable().scaledToFill()
      } else {
        Color.gray.opacity(0.2)
      }
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
    .task(id: "\(app.deckKey)/\(version)") {
      image = nil
      if DeckArt.exists(app, .icon) { image = await DeckArt.load(app, kind: .icon, maxPixel: 256) }
      if image == nil { image = await DeckArt.load(app, kind: .poster, maxPixel: 256) }
    }
  }
}

/// Landscape art for an app: the host's hero when present, otherwise the poster blown up and
/// blurred with the poster itself in front.
@available(macOS 14.0, *)
struct DeckLandscapeArt: View {
  let app: TemporaryApp
  var version = 0
  var posterFraction: CGFloat = 0.8
  @SwiftUI.State private var hero: NSImage?
  @SwiftUI.State private var poster: NSImage?

  var body: some View {
    GeometryReader { geo in
      ZStack {
        if let hero {
          Image(nsImage: hero).resizable().scaledToFill()
            .frame(width: geo.size.width, height: geo.size.height).clipped()
        } else if let poster {
          Image(nsImage: poster).resizable().scaledToFill()
            .frame(width: geo.size.width * 1.6, height: geo.size.height * 1.6)   // bigger frame, not a transform: the blur bleeds past the edges
            .blur(radius: 24).saturation(1.35)
            .frame(width: geo.size.width, height: geo.size.height).clipped()
            .overlay(Color.black.opacity(0.14))
          Image(nsImage: poster).resizable().aspectRatio(contentMode: .fit)
            .frame(maxWidth: geo.size.width * 0.9, maxHeight: geo.size.height * posterFraction)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
        } else {
          Color.gray.opacity(0.18)
        }
      }
      .frame(width: geo.size.width, height: geo.size.height)
    }
    .task(id: "\(app.deckKey)/\(version)") {
      hero = nil
      poster = nil
      if DeckArt.exists(app, .hero) { hero = await DeckArt.load(app, kind: .hero, maxPixel: 900) }
      if hero == nil { poster = await DeckArt.load(app, kind: .poster, maxPixel: 600) }
      // a picture that is already landscape (Steam header.jpg) fills the card: no small copy on a blurred background
      if hero == nil, let p = poster, DeckArtRules.treatment(width: p.size.width, height: p.size.height) == .fill { hero = p; poster = nil }
    }
  }
}

/// Poster with at most one badge on it: a play mark while the app runs.
@available(macOS 14.0, *)
/// How a running app is marked on its tile.
enum DeckRunBadge { case none, legacy, styled }

/// The two treatments drawn for review: (a) a glass capsule with a "now playing" symbol, no outline;
/// (b) the art dimmed under a centred glass 继续 button, like a paused-media overlay.
enum DeckRunIndicator: String {
  case badge = "a", pause = "b"
  static var current: DeckRunIndicator {
    if let v = conceptEnv("MLC_RUN_INDICATOR"), let s = DeckRunIndicator(rawValue: v) { return s }
    return DeckRunIndicator(rawValue: UserDefaults.standard.string(forKey: "MLRunIndicator") ?? "") ?? .badge
  }
}

/// The mark of the running app: a small green play glyph immediately left of its title. It is always in the row; when the app is
/// not running its width is 0 and it is invisible, and the width animates, so the title never jumps when the state changes.
/// Replaces the blue frame and the capsule badges. `onDark`: the title sits on a card's dark scrim, not on the page.
@available(macOS 14.0, *)
struct DeckRunningGlyph: View {
  let running: Bool
  /// Font size in points (already scaled).
  var size: CGFloat = 11
  var onDark = false
  @Environment(\.colorScheme) private var scheme

  private var color: Color {
    let c = (onDark || scheme == .dark) ? DeckRunGreenRules.onDarkScrim : DeckRunGreenRules.onLightPage
    return Color(red: c.r, green: c.g, blue: c.b)
  }

  var body: some View {
    Image(systemName: "play.fill")
      .font(.system(size: size, weight: .bold))
      .foregroundStyle(color)
      .fixedSize()
      .frame(width: running ? size + 6 : 0, alignment: .leading)
      .clipped()
      .opacity(running ? 1 : 0)
      .animation(.smooth(duration: 0.22), value: running)
      .accessibilityLabel(running ? DL("deck.running") : "")
      .accessibilityHidden(!running)
  }
}

@available(macOS 14.0, *)
struct DeckPosterTile: View {
  let app: TemporaryApp
  @ObservedObject var model: DeckAppsModel
  var radius: CGFloat = 14
  var subtitle: [DeckFactItem] = []
  var badge: DeckRunBadge = .legacy
  @SwiftUI.State private var hovering = false
  @Environment(\.deckScale) private var s

  private var running: Bool { model.runningId == app.id }

  var body: some View {
    VStack(alignment: .leading, spacing: 8 * s) {
      ZStack(alignment: .topLeading) {
        DeckPoster(app: app, version: model.artVersion, radius: radius * s)
      }
      .shadow(color: .black.opacity(conceptEnv("MLC_NOTILESHADOW") != nil ? 0 : (hovering ? 0.3 : 0.16)),
              radius: (conceptEnv("MLC_NOTILESHADOW") != nil ? 0.001 : (hovering ? 14 : 7)) * s, y: (hovering ? 8 : 3) * s)
      HStack(spacing: 0) {
        DeckRunningGlyph(running: running && badge != .none, size: 10 * s)
        Text(app.name ?? "").font(.system(size: 13 * s, weight: .medium)).lineLimit(1)
      }
      if !subtitle.isEmpty { DeckFactsRow(items: subtitle, size: 11 * s) }
    }
    .opacity(app.hidden ? 0.4 : 1)
    // hover: a lift in whole points, never a scale (a scale would draw the tile small and enlarge the picture of it)
    .offset(y: hovering ? -2 : 0)
    .animation(.smooth(duration: 0.18), value: hovering)
    .onHover { hovering = $0 }
    .contentShape(Rectangle())
    .onTapGesture(count: 2) { model.openApp(app) }
    .onTapGesture { model.selectedId = app.id }
    .overlay(alignment: .top) {
      RoundedRectangle(cornerRadius: (radius + 3) * s, style: .continuous)
        .strokeBorder(Color.accentColor, lineWidth: model.selectedId == app.id && !running ? 3 * s : 0)
        .aspectRatio(0.75, contentMode: .fit).padding(-3 * s)
    }
    .deckPadTarget(app, model, radius: radius * s)
    .deckAppContextMenu(app, model)
  }
}

@available(macOS 14.0, *)
struct DeckAppMenu: View {
  let app: TemporaryApp
  @ObservedObject var model: DeckAppsModel

  var body: some View {
    Button(DL(app.pinned ? "Unpin App" : "Pin App")) { model.actions.pin?(app) }
    Button(DL(app.hidden ? "Show App" : "Hide App")) { model.actions.hide?(app) }
    if model.runningId == app.id { Divider(); Button(DL("Quit App")) { model.quitApp(app) } }
  }
}

struct DeckSectionTitle: View {
  let title: String
  var chevron = false

  var body: some View {
    HStack(spacing: 5) {
      Text(title).font(.system(size: 22, weight: .bold))
      if chevron { Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(.secondary) }
    }
  }
}

// MARK: - Featured hero (Landmarks pattern)

/// Settings in the host header of the computer-first page.
@available(macOS 14.0, *)
struct DeckHeroIdentity {
  let host: DeckHost
  let onDesktop: () -> Void
}

