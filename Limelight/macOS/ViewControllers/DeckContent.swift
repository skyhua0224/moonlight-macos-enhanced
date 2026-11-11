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

@available(macOS 14.0, *)
struct DeckFeaturedHero: View {
  let app: TemporaryApp
  @ObservedObject var model: DeckAppsModel
  let height: CGFloat
  /// The computer-first page puts the computer's identity over the art.
  var identity: DeckHeroIdentity?
  @SwiftUI.State private var hero: NSImage?
  @SwiftUI.State private var poster: NSImage?
  @SwiftUI.State private var logo: NSImage?

  private var running: Bool { model.runningId == app.id }
  /// How far the backdrop runs past the hero's frame, under the floating sidebar and the toolbar.
  private let extendLeading: CGFloat = 340
  private let extendTop: CGFloat = 80

  var body: some View {
    ZStack(alignment: .bottomLeading) {
      backdrop
      if let identity {
        VStack(alignment: .leading, spacing: 0) {
          HStack(spacing: 12) {
            DeckHostIcon(host: identity.host, size: 44)
            VStack(alignment: .leading, spacing: 2) {
              Text(identity.host.name).font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
              Text(deckStatusLine(identity.host)).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white.opacity(0.78))
            }
          }
          .shadow(color: .black.opacity(0.35), radius: 6)
          .padding(.leading, 36).padding(.top, 78)
          Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
      VStack(alignment: .leading, spacing: 14) {
        HStack(alignment: .bottom, spacing: 16) {
          DeckAppIcon(app: app, size: 64, version: model.artVersion).shadow(color: .black.opacity(0.35), radius: 8, y: 4)
          VStack(alignment: .leading, spacing: 8) {
            if let logo {
              Image(nsImage: logo).resizable().scaledToFit().frame(height: 64, alignment: .leading)
                .shadow(color: .black.opacity(0.4), radius: 8)
            } else {
              Text(app.name ?? "").font(.system(size: 34, weight: .heavy)).foregroundStyle(.white)
                .lineLimit(2).shadow(color: .black.opacity(0.45), radius: 8)
            }
            DeckFactsRow(items: deckFacts(for: app, model: model, running: running), onArt: true, size: 13)
          }
        }
        HStack(spacing: 10) {
          Button { model.openApp(app) } label: {
            Label(running ? DL("deck.resume") : DL("deck.play"), systemImage: "play.fill").frame(minWidth: 76)
          }
          .deckProminent()
          if running {
            Button { model.quitApp(app) } label: { Text(DL("deck.quit")).frame(minWidth: 56) }
              .deckSecondary()
          }
          if let identity {
            Button { identity.onDesktop() } label: { Label(DL("deck.desktop"), systemImage: "display") }
              .deckSecondary()
          }
        }
        .controlSize(.large)
      }
      .padding(.horizontal, 36)
      .padding(.bottom, 56)
      .environment(\.colorScheme, .dark)
    }
    .frame(height: height)
    .task(id: "\(app.deckKey)/\(model.artVersion)") {
      hero = nil; poster = nil; logo = nil
      if DeckArt.exists(app, .hero) { hero = await DeckArt.load(app, kind: .hero, maxPixel: 2200) }
      if hero == nil { poster = await DeckArt.load(app, kind: .poster, maxPixel: 900) }
      // a picture that is already landscape (Steam header.jpg) fills the card: no small copy on a blurred background
      if hero == nil, let p = poster, DeckArtRules.treatment(width: p.size.width, height: p.size.height) == .fill { hero = p; poster = nil }
      if DeckArt.exists(app, .logo) { logo = await DeckArt.load(app, kind: .logo, maxPixel: 900) }
    }
  }

  private var fade: LinearGradient {
    LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.62), .init(color: .clear, location: 1)],
                   startPoint: .top, endPoint: .bottom)
  }

  /// The art fills a rectangle that is larger than the hero: it runs under the floating sidebar and
  /// the toolbar, so the hero reads as edge to edge behind the glass.
  @ViewBuilder
  private var backdrop: some View {
    GeometryReader { geo in
      let size = CGSize(width: geo.size.width + extendLeading, height: geo.size.height + extendTop)
      ZStack(alignment: .trailing) {
        if let hero {
          Image(nsImage: hero).resizable().scaledToFill()
            .frame(width: size.width, height: size.height, alignment: .top).clipped()
        } else if let poster {
          Image(nsImage: poster).resizable().scaledToFill()
            .frame(width: size.width * 1.7, height: size.height * 1.7)
            .blur(radius: 52).saturation(1.4)
            .frame(width: size.width, height: size.height).clipped()
            .overlay(Color.black.opacity(0.2))
          Image(nsImage: poster).resizable().aspectRatio(contentMode: .fit)
            .frame(maxWidth: geo.size.width * 0.5, maxHeight: geo.size.height * 0.66)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.45), radius: 22, y: 10)
            .padding(.trailing, 64).padding(.top, 40)
        }
        LinearGradient(colors: [.black.opacity(0.62), .black.opacity(0.2), .clear], startPoint: .leading, endPoint: .trailing)
        LinearGradient(colors: [.black.opacity(0.35), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.35))
      }
      .frame(width: size.width, height: size.height)
      .mask(fade)
      .offset(x: -extendLeading, y: -extendTop)
    }
  }
}

// MARK: - A1 Games

@available(macOS 14.0, *)
struct DeckGamesView: View {
  @ObservedObject var model: DeckAppsModel
  @SwiftUI.State private var width: CGFloat = 1000

  private var heroHeight: CGFloat { min(520, max(380, width * 0.34)) }
  private var cardWidth: CGFloat { width > 1400 ? 340 : 280 }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 30) {
        if let app = model.featured { DeckFeaturedHero(app: app, model: model, height: heroHeight) }

        if !model.recentApps.isEmpty {
          VStack(alignment: .leading, spacing: 14) {
            DeckSectionTitle(title: DL("deck.continuePlaying"), chevron: true).padding(.horizontal, 36)
            ScrollView(.horizontal, showsIndicators: false) {
              LazyHStack(alignment: .top, spacing: 20) {
                ForEach(model.recentApps, id: \.deckKey) { app in DeckContinueCard(app: app, model: model, width: cardWidth) }
              }
              .padding(.horizontal, 36)
            }
          }
        }

        VStack(alignment: .leading, spacing: 14) {
          DeckSectionTitle(title: DL("deck.library"), chevron: true)
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 168, maximum: 240), spacing: 24, alignment: .top)], spacing: 28) {
            ForEach(model.libraryApps, id: \.deckKey) { app in
              DeckPosterTile(app: app, model: model, subtitle: deckFacts(for: app, model: model, running: false, includeSource: false))
            }
          }
        }
        .padding(.horizontal, 36)
        .padding(.bottom, 40)
      }
    }
    .background(GeometryReader { proxy in Color.clear.onAppear { width = proxy.size.width }.onChange(of: proxy.size.width) { _, new in width = new } })
    .scrollClipDisabled()
    .background(Color(nsColor: .windowBackgroundColor))
    .ignoresSafeArea(.container, edges: .top)
  }
}

@available(macOS 14.0, *)
struct DeckContinueCard: View {
  let app: TemporaryApp
  @ObservedObject var model: DeckAppsModel
  let width: CGFloat
  @SwiftUI.State private var hovering = false

  private var running: Bool { model.runningId == app.id }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ZStack(alignment: .topLeading) {
        DeckLandscapeArt(app: app, version: model.artVersion)
          .frame(width: width, height: width * 9 / 16)
          .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
      }
      .shadow(color: .black.opacity(hovering ? 0.3 : 0.16), radius: hovering ? 16 : 8, y: hovering ? 8 : 4)
      HStack(spacing: 10) {
        DeckAppIcon(app: app, size: 36, version: model.artVersion)
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 0) {
            DeckRunningGlyph(running: running, size: 11)
            Text(app.name ?? "").font(.system(size: 13, weight: .semibold)).lineLimit(1)
          }
          DeckFactsRow(items: Array(deckFacts(for: app, model: model, running: running, includeSource: false).prefix(1)), size: 11)
        }
      }
    }
    .frame(width: width)
    .offset(y: hovering ? -2 : 0)
    .animation(.smooth(duration: 0.18), value: hovering)
    .onHover { hovering = $0 }
    .contentShape(Rectangle())
    .onTapGesture(count: 2) { model.openApp(app) }
    .onTapGesture { model.selectedId = app.id }
    .deckPadTarget(app, model, radius: 18)
    .deckAppContextMenu(app, model)
  }
}

// MARK: - A3 Quiet

@available(macOS 14.0, *)
struct DeckQuietView: View {
  @ObservedObject var model: DeckAppsModel
  @SwiftUI.State private var width: CGFloat = 1000

  private var host: DeckHost? { model.host }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 34) {
        header
        if !model.pinnedApps.isEmpty { section(DL("deck.pinned"), model.pinnedApps) }
        section(DL("deck.allApps"), model.libraryApps.filter { !$0.pinned })
      }
      .padding(.horizontal, 36)
      .padding(.top, 8)
      .padding(.bottom, 44)
    }
    .background(GeometryReader { proxy in Color.clear.onAppear { width = proxy.size.width }.onChange(of: proxy.size.width) { _, new in width = new } })
    .background(Color(nsColor: .windowBackgroundColor))
  }

  @ViewBuilder
  private var header: some View {
    if let host {
      HStack(alignment: .center, spacing: 16) {
        DeckHostIcon(host: host, size: 56, muted: !host.online)
        VStack(alignment: .leading, spacing: 4) {
          Text(host.name).font(.system(size: 34, weight: .bold)).lineLimit(1)
          Text(deckHostFactsLine(host)).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
        }
        Spacer()
      }
    }
  }

  private func section(_ title: String, _ apps: [TemporaryApp]) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(title).font(.system(size: 22, weight: .bold))
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 176, maximum: 250), spacing: 28, alignment: .top)], spacing: 32) {
        ForEach(apps, id: \.deckKey) { app in
          DeckPosterTile(app: app, model: model, radius: 16,
                         subtitle: deckFacts(for: app, model: model, running: model.runningId == app.id, includeSource: true).prefix(1).map { $0 })
        }
      }
    }
  }
}

/// One quiet line of host facts: platform and version, GPU, route, codecs.
func deckHostFactsLine(_ host: DeckHost) -> String {
  var parts: [String] = []
  if !host.facts.osVersion.isEmpty { parts.append(host.facts.osVersion) } else if !DeckLook.platformName(host.platform).isEmpty { parts.append(DeckLook.platformName(host.platform)) }
  if !host.facts.gpu.isEmpty { parts.append(host.facts.gpu) }
  parts.append(deckRouteText(host))
  parts.append(deckCapabilityText(host))
  return parts.joined(separator: " · ")
}

/// The measured path when one is known, otherwise only the latency.
func deckRouteText(_ host: DeckHost) -> String {
  let live = HostPathSignals.shared.phrase(forHost: host.id, active: host.address ?? "")
  if !live.isEmpty {
    if let rtt = host.rtt { return live + " " + "\(rtt) ms" }
    return live
  }
  return host.rtt.map { "\($0) ms" } ?? ""
}

/// The window subtitle of the apps page for a host: where it is and how fast.
@objc(MLDeckWindowText)
public final class DeckWindowText: NSObject {
  @objc public static func subtitle(forHost host: TemporaryHost) -> String {
    let deck = DeckHost(host)
    let live = HostPathSignals.shared.phrase(forHost: deck.id, active: deck.address ?? "")
    var parts: [String] = []
    if live.isEmpty, let address = deck.address, !address.isEmpty { parts.append(address) }
    let route = deckRouteText(deck)
    if !route.isEmpty { parts.append(route) }
    return parts.joined(separator: " · ")
  }
}

/// 大屏模式 (Foundation Sunshine hosts, windows): a tile of its own, not a poster.
@available(macOS 14.0, *)
struct DeckBigScreenTile: View {
  let app: TemporaryApp
  @ObservedObject var model: DeckAppsModel
  @SwiftUI.State private var hovering = false
  @Environment(\.deckScale) private var s

  var body: some View {
    VStack(alignment: .leading, spacing: 8 * s) {
      ZStack {
        LinearGradient(colors: [Color(red: 0.36, green: 0.30, blue: 0.86), Color(red: 0.62, green: 0.27, blue: 0.78)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
        VStack(spacing: 10 * s) {
          Image(systemName: "tv").font(.system(size: 44 * s, weight: .light)).foregroundStyle(.white)
          Text(DL("deck.bigscreen")).font(.system(size: 15 * s, weight: .bold)).foregroundStyle(.white)
        }
        Image(systemName: "sparkles").font(.system(size: 13 * s)).foregroundStyle(.white.opacity(0.8))
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(10 * s)
      }
      .aspectRatio(0.75, contentMode: .fit)
      .clipShape(RoundedRectangle(cornerRadius: 14 * s, style: .continuous))
      .shadow(color: .black.opacity(hovering ? 0.3 : 0.16), radius: (hovering ? 14 : 7) * s, y: (hovering ? 8 : 3) * s)
      Text(DL("deck.bigscreen")).font(.system(size: 13 * s, weight: .medium)).lineLimit(1)
    }
    .offset(y: hovering ? -2 : 0)
    .animation(.smooth(duration: 0.18), value: hovering)
    .onHover { hovering = $0 }
    .contentShape(Rectangle())
    .onTapGesture(count: 2) { model.openApp(app) }
    .deckPadTarget(app, model, radius: 14 * s)
  }
}

/// A poster tile, or the 大屏模式 tile for the host's big screen entry.
@available(macOS 14.0, *)
struct DeckAppCell: View {
  let app: TemporaryApp
  @ObservedObject var model: DeckAppsModel
  var subtitle: [DeckFactItem] = []
  var highlightRunning = false
  /// The running app is already marked in 继续, so 应用 does not repeat it.
  var suppressRunning = false
  /// With no computer card: 继续 / 退出 on the running app's own tile.
  var runningControls = false
  /// 应用卡片 横版: 16:9 cards instead of posters.
  var landscape = false

  var body: some View {
    if deckIsBigScreen(app) {
      if landscape { DeckBigScreenCard(app: app, model: model) } else { DeckBigScreenTile(app: app, model: model) }
    } else if landscape {
      VStack(alignment: .leading, spacing: 8) {
        DeckLandscapeTile(app: app, model: model, markRunning: !suppressRunning)
        if runningControls && model.runningId == app.id {
          HStack(spacing: 6) {
            Button { model.openApp(app) } label: { Label(DL("deck.resume"), systemImage: "play.fill").font(.system(size: 11, weight: .semibold)).lineLimit(1) }
              .deckProminent().controlSize(.small)
            Button { model.quitApp(app) } label: { Text(DL("deck.quit")).font(.system(size: 11)).lineLimit(1) }
              .deckSecondary().controlSize(.small)
          }
        }
      }
    } else {
      VStack(alignment: .leading, spacing: 8) {
        DeckPosterTile(app: app, model: model, subtitle: subtitle, badge: suppressRunning ? .none : (highlightRunning ? .styled : .legacy))
        if runningControls && model.runningId == app.id {
          HStack(spacing: 6) {
            Button { model.openApp(app) } label: { Label(DL("deck.resume"), systemImage: "play.fill").font(.system(size: 11, weight: .semibold)).lineLimit(1) }
              .deckProminent().controlSize(.small)
            Button { model.quitApp(app) } label: { Text(DL("deck.quit")).font(.system(size: 11)).lineLimit(1) }
              .deckSecondary().controlSize(.small)
          }
        }
      }
    }
  }
}

/// The default Foundation Sunshine entries by name (only used for a Foundation Sunshine host that sends no FsKind).
func deckKindFromName(_ name: String) -> String? {
  let n = name.trimmingCharacters(in: .whitespaces).lowercased()
  if ["大屏", "大屏模式", "big screen", "bigscreen", "big-screen"].contains(n) { return "bigscreen" }
  if ["desktop", "桌面"].contains(n) { return "desktop" }
  return nil
}
