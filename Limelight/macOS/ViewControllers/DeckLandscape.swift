//
//  DeckLandscape.swift
//  Additions to the computer-first apps page:
//    - 16:9 app cards in the style of the Apple TV app (art fills the card, a dark band inside the
//      bottom with a play mark, one quiet line and a ⋯ menu), used by the 继续 shelf in both card
//      modes and by 应用 / 固定 when 应用卡片 is 横版
//    - shelves with a bold title and a chevron that opens the shelf as a grid
//    - 主页布局 大图: a full-width hero over the host's wallpaper, the computer's name and 连接 on it
//    - what an offline or unpaired computer shows instead of an empty page
//

import AppKit
import SwiftUI

// MARK: - 16:9 card

/// Landscape art for an app, tuned for a card whose bottom band is dark: the host's hero when it has
/// one, otherwise the poster enlarged and blurred with the poster itself above the band.
@available(macOS 14.0, *)
struct DeckCardArt: View {
  let app: TemporaryApp
  var version = 0
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
            .frame(width: geo.size.width * 1.7, height: geo.size.height * 1.7)
            .blur(radius: 26).saturation(1.4)
            .frame(width: geo.size.width, height: geo.size.height).clipped()
            .overlay(Color.black.opacity(0.18))
          Image(nsImage: poster).resizable().aspectRatio(contentMode: .fit)
            .frame(maxWidth: geo.size.width * 0.9, maxHeight: geo.size.height * 0.68)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
            .offset(y: -geo.size.height * 0.07)
        } else {
          LinearGradient(colors: [Color.gray.opacity(0.35), Color.gray.opacity(0.15)], startPoint: .topLeading, endPoint: .bottomTrailing)
          Text(String((app.name ?? "?").prefix(1)))
            .font(.system(size: 40, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
            .offset(y: -geo.size.height * 0.08)
        }
      }
      .frame(width: geo.size.width, height: geo.size.height)
    }
    .task(id: "\(app.deckKey)/\(version)") {
      hero = nil
      poster = nil
      // decoded at the pixels the card is drawn at (up to 440 pt wide, on a 2x or 3x screen), never a small picture enlarged
      if DeckArt.exists(app, .hero) { hero = await DeckArt.load(app, kind: .hero, maxPixel: 1600) }
      if hero == nil { poster = await DeckArt.load(app, kind: .poster, maxPixel: 1200) }
      // a picture that is already landscape (Steam header.jpg) fills the card: no small copy on a blurred background
      if hero == nil, let p = poster, DeckArtRules.treatment(width: p.size.width, height: p.size.height) == .fill { hero = p; poster = nil }
    }
  }
}

/// One line under the title of a card: while it runs, how long; otherwise when it was last played and for how long.
@available(macOS 14.0, *)
func deckCardLine(_ app: TemporaryApp, running: Bool, sessions: [DeckSession] = []) -> String {
  let info = app.deckInfo
  // a host that does not send last-played times (plain Sunshine): what this client recorded
  let own = sessions.first { $0.appId == app.id }
  if running {
    if let start = info.sessionStart { return DLf("deck.runFor", DeckTime.duration(Date().timeIntervalSince(start))) }
    return ""
  }
  var parts: [String] = []
  if let when = DeckTime.relative(info.lastPlayed ?? own?.start) { parts.append(DLf("deck.lastPlayed", when)) }
  if let seconds = info.playSeconds ?? own?.seconds, seconds >= 60 { parts.append(DeckTime.duration(TimeInterval(seconds))) }
  if parts.isEmpty, let name = info.sourceName { parts.append(name) }
  return parts.joined(separator: " · ")
}

@available(macOS 14.0, *)
struct DeckLandscapeTile: View {
  let app: TemporaryApp
  @ObservedObject var model: DeckAppsModel
  var radius: CGFloat = 12
  /// The running app is marked (a green play glyph left of the title, no frame) only where the page does not already say so elsewhere.
  var markRunning = true
  @SwiftUI.State private var hovering = false
  @Environment(\.deckScale) private var s

  private var running: Bool { markRunning && model.runningId == app.id }

  var body: some View {
    ZStack(alignment: .bottom) {
      DeckCardArt(app: app, version: model.artVersion)
      band
    }
    .aspectRatio(16.0 / 9.0, contentMode: .fit)
    .clipShape(RoundedRectangle(cornerRadius: radius * s, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: radius * s, style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
    .overlay(RoundedRectangle(cornerRadius: radius * s, style: .continuous).strokeBorder(Color.accentColor, lineWidth: model.selectedId == app.id && !running ? 3 * s : 0))
    .shadow(color: .black.opacity(hovering ? 0.34 : 0.2), radius: (hovering ? 16 : 8) * s, y: (hovering ? 8 : 4) * s)
    .opacity(app.hidden ? 0.4 : 1)
    .offset(y: hovering ? -2 : 0)
    .animation(.smooth(duration: 0.18), value: hovering)
    .onHover { hovering = $0 }
    .contentShape(RoundedRectangle(cornerRadius: radius * s, style: .continuous))
    .onTapGesture(count: 2) { model.openApp(app) }
    .onTapGesture { model.selectedId = app.id }
    .deckPadTarget(app, model, radius: radius * s)
    .deckAppContextMenu(app, model)
  }

  /// The dark band inside the bottom of the card: play mark, title, one line, a thin bar while it runs, ⋯.
  private var band: some View {
    let line = deckCardLine(app, running: running, sessions: model.host?.facts.sessions ?? [])
    return HStack(alignment: .center, spacing: 10 * s) {
      Button { model.openApp(app) } label: {
        Image(systemName: "play.fill").font(.system(size: 11 * s, weight: .bold)).foregroundStyle(.white)
          .frame(width: 26 * s, height: 26 * s).background(Circle().fill(Color.white.opacity(0.22)))
      }
      .buttonStyle(.plain)
      .deckTouchTarget()
      .deckHelp(running ? DL("deck.resume") : DL("deck.play"))
      VStack(alignment: .leading, spacing: 3 * s) {
        HStack(spacing: 0) {
          DeckRunningGlyph(running: running, size: 11 * s, onDark: true)
          Text(app.name ?? "").font(.system(size: 13 * s, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
        }
        if !line.isEmpty {
          Text(line).font(.system(size: 11 * s, weight: .medium)).foregroundStyle(.white.opacity(running ? 0.92 : 0.7)).lineLimit(1)
        }
      }
      Spacer(minLength: 4)
      Button {
        if let menu = model.actions.appMenu?(app) { DeckMenuPresenter.pop(menu) }
      } label: {
        Image(systemName: "ellipsis").font(.system(size: 13 * s, weight: .bold)).foregroundStyle(.white)
          .frame(width: 26 * s, height: 26 * s).contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .deckTouchTarget()
      .deckHelp(DL("deck.more"))
    }
    .padding(.horizontal, 10 * s)
    .padding(.top, 26 * s)
    .padding(.bottom, 9 * s)
    .frame(maxWidth: .infinity)
    .background(
      LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black.opacity(0.58), location: 0.4), .init(color: .black.opacity(0.82), location: 1)],
                     startPoint: .top, endPoint: .bottom)
    )
  }
}

/// The 大屏模式 entry as a 16:9 card, with its name inside the bottom like the others.
@available(macOS 14.0, *)
struct DeckBigScreenCard: View {
  let app: TemporaryApp
  @ObservedObject var model: DeckAppsModel
  var radius: CGFloat = 12
  @SwiftUI.State private var hovering = false
  @Environment(\.deckScale) private var s

  var body: some View {
    ZStack(alignment: .bottomLeading) {
      LinearGradient(colors: [Color(red: 0.36, green: 0.30, blue: 0.86), Color(red: 0.62, green: 0.27, blue: 0.78)],
                     startPoint: .topLeading, endPoint: .bottomTrailing)
      Image(systemName: "tv").font(.system(size: 54 * s, weight: .light)).foregroundStyle(.white.opacity(0.92))
        .frame(maxWidth: .infinity, maxHeight: .infinity).offset(y: -12 * s)
      HStack(spacing: 10 * s) {
        Image(systemName: "play.fill").font(.system(size: 11 * s, weight: .bold)).foregroundStyle(.white)
          .frame(width: 26 * s, height: 26 * s).background(Circle().fill(Color.white.opacity(0.22)))
        Text(DL("deck.bigscreen")).font(.system(size: 13 * s, weight: .semibold)).foregroundStyle(.white)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 10 * s).padding(.bottom, 9 * s).padding(.top, 22 * s)
      .frame(maxWidth: .infinity)
      .background(LinearGradient(colors: [.clear, .black.opacity(0.4)], startPoint: .top, endPoint: .bottom))
    }
    .aspectRatio(16.0 / 9.0, contentMode: .fit)
    .clipShape(RoundedRectangle(cornerRadius: radius * s, style: .continuous))
    .shadow(color: .black.opacity(hovering ? 0.34 : 0.2), radius: (hovering ? 16 : 8) * s, y: (hovering ? 8 : 4) * s)
    .offset(y: hovering ? -2 : 0)
    .animation(.smooth(duration: 0.18), value: hovering)
    .onHover { hovering = $0 }
    .contentShape(Rectangle())
    .onTapGesture(count: 2) { model.openApp(app) }
    .deckPadTarget(app, model, radius: radius * s)
  }
}

@available(macOS 14.0, *)
extension View {
  /// A tile of the app wall for the pad: A opens the app, Menu lists the old app menu.
  func deckPadTarget(_ app: TemporaryApp, _ model: DeckAppsModel, radius: CGFloat) -> some View {
    // an offline computer's tiles take no click (allowsHitTesting is off for them), so the pad skips them too
    controllerFocusTarget(enabled: model.host?.online != false, key: "app:\(app.deckKey)", radius: radius, context: {
      (title: app.name ?? "", menu: model.actions.appMenu?(app) ?? NSMenu())
    }) { model.openApp(app) }
  }
}

// MARK: - Shelf

/// A bold title with a chevron, and one row of tiles that scrolls sideways (the last one cut off at the
/// edge). The chevron opens the whole shelf as a grid.
@available(macOS 14.0, *)
struct DeckShelf: View {
  let title: String
  let apps: [TemporaryApp]
  @ObservedObject var model: DeckAppsModel
  let landscape: Bool
  let tile: CGFloat
  /// The cards are drawn at `tile` wide and scaled by this (a transform; see DeckTileGrid).
  var factor: CGFloat = 1
  let columns: [GridItem]
  var ringRunning = false
  var controls = false
  @SwiftUI.State private var expanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Button { withAnimation(.smooth(duration: 0.2)) { expanded.toggle() } } label: {
        HStack(spacing: 5) {
          Text(title).font(.system(size: 22, weight: .bold))
          Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(.secondary)
            .rotationEffect(.degrees(expanded ? 90 : 0))
        }
        .contentShape(Rectangle())
      }
      .controllerButtonStyle(.plain)
      .padding(.horizontal, DeckInset.page)
      let count = max(1, columns.count)
      // the same grid as 应用 (one row, or all rows when the › is open): one list of cards in one layout, so a
      // change of the column count slides the cards instead of rebuilding rows
      // real sizes: the cards are laid out at tile * factor and draw their own metrics at that size (no scale transform)
      DeckTileGrid(tile: tile * factor, factor: 1, columns: count) {
        ForEach(expanded ? apps : Array(apps.prefix(count)), id: \.deckKey) { app in cell(app).environment(\.deckScale, factor).frame(width: tile * factor) }
      }
      .padding(.horizontal, DeckInset.page)
      .animation(.spring(response: 0.28, dampingFraction: 0.9), value: count)
    }
  }

  @ViewBuilder
  private func cell(_ app: TemporaryApp) -> some View {
    if landscape {
      DeckAppCell(app: app, model: model, highlightRunning: ringRunning, runningControls: controls, landscape: true)
    } else {
      DeckAppCell(app: app, model: model, highlightRunning: ringRunning, runningControls: controls)
    }
  }
}

// MARK: - 大图 layout

private struct DeckHeroPrimaryBody: View {
  let configuration: ButtonStyleConfiguration
  @Environment(\.isEnabled) private var enabled

  var body: some View {
    configuration.label
      .font(.system(size: 17, weight: .semibold))
      .foregroundStyle(Color.black)
      .padding(.horizontal, 26)
      .frame(height: 46)
      .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.78 : 1)))
      .opacity(enabled ? 1 : 0.5)
  }
}

/// The connect buttons of the card layout (连接桌面, 继续, 退出应用, 大屏模式, 唤醒, 配对, 取消): capsules of exactly the
/// height of the round 串流设置 / 更多 buttons beside them (the system's own control sizes are not that height), the
/// round ones in the same glass. Filled with the accent colour when prominent.
struct DeckCardButtonStyle: ButtonStyle {
  var prominent = false
  var height: CGFloat = 44
  func makeBody(configuration: Configuration) -> some View {
    DeckCardButtonBody(configuration: configuration, prominent: prominent, height: height)
  }
}

private struct DeckCardButtonBody: View {
  let configuration: ButtonStyleConfiguration
  let prominent: Bool
  let height: CGFloat
  @Environment(\.isEnabled) private var enabled

  var body: some View {
    let label = configuration.label
      .font(.system(size: 15, weight: .semibold))
      .foregroundStyle(prominent ? Color.white : Color.primary)
      .lineLimit(1)
      .fixedSize(horizontal: true, vertical: false)
      .padding(.horizontal, 22)
      .frame(height: height)
    Group {
      if prominent {
        label.background(Capsule().fill(Color.accentColor.opacity(configuration.isPressed ? 0.8 : 1)))
      } else {
        label.deckGlass(Capsule()).opacity(configuration.isPressed ? 0.7 : 1)
      }
    }
    .contentShape(Capsule())
    .opacity(enabled ? 1 : 0.5)
  }
}

/// The white capsule of the Apple TV app's hero.
struct DeckHeroPrimaryStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    DeckHeroPrimaryBody(configuration: configuration)
  }
}

/// A round glass button next to the primary one (串流设置, 更多): the same height as the connect button, a
/// tooltip, and an accessibility label.
@available(macOS 14.0, *)
struct DeckHeroRound: View {
  let symbol: String
  let help: String
  var onDark = true
  var size: CGFloat = 46
  /// For the pad: the NSMenu this button pops up, listed in the controller menu instead of popping at the pointer.
  var padMenu: (() -> NSMenu)?
  let action: () -> Void

  var body: some View {
    let button = Button(action: action) {
      Image(systemName: symbol).font(.system(size: size * 0.37, weight: .semibold))
        .foregroundStyle(onDark ? Color.white : Color.primary)
        .frame(width: size, height: size).deckGlass(Circle()).contentShape(Circle())
    }
    .help(help)
    .accessibilityLabel(help)
    if let padMenu {
      button.buttonStyle(.plain).controllerFocusMenu(key: symbol == "ellipsis" ? "more" : symbol) { (title: help, menu: padMenu()) }
    } else {
      button.controllerButtonStyle(.plain).controllerKey(symbol == "slider.horizontal.3" ? "settings" : symbol)
    }
  }
}

/// 大图: the host's wallpaper runs across the top and fades into the page; the computer's icon, name, one
/// line and 连接 sit on it, bottom left. Offline or unpaired the picture is dimmed and 唤醒 / 配对 leads.
@available(macOS 14.0, *)
struct DeckHeroHeader: View {
  let host: DeckHost
  @ObservedObject var model: DeckAppsModel
  let height: CGFloat
  /// The page width in points, which is the width the picture is shown at.
  let width: CGFloat
  /// Where the text block starts: the leading edge of the page's content column.
  var leadingInset: CGFloat = DeckInset.page
  /// Where content may start: the toolbar's height plus a margin, in the page's own (scaled) units.
  var topInset: CGFloat = 66

  @ObservedObject private var pairing = DeckPairingState.shared
  @ObservedObject private var config = DeckHomeConfig.shared
  @SwiftUI.State private var image: NSImage?
  /// The picture has been looked for (a computer with none then shows its colour card; before that a quiet dark base).
  @SwiftUI.State private var loaded = false
  /// The backdrop runs past the hero's frame, under the floating sidebar and the toolbar.
  // The picture runs up under the toolbar, but never left under the sidebar: the sidebar keeps one uniform
  // material from top to bottom whatever the wallpaper is.
  private let extendLeading: CGFloat = 0
  private let extendTop: CGFloat = 80

  private var game: TemporaryApp? { host.online && host.paired ? model.runningGame : nil }
  private var pairingStarted: Bool { pairing.started.contains(host.id) || pairing.pins[host.id] != nil }
  private var live: Bool { host.online && host.paired }

  var body: some View {
    // The text block decides the hero's height (never less than `height`): its top starts below the toolbar,
    // so the icon is never under it, at any page scale. The picture is the background and runs under the toolbar.
    VStack(alignment: .leading, spacing: 12) {
      DeckEditableHostIcon(host: host, model: model, size: 60).shadow(color: .black.opacity(0.35), radius: 8, y: 4)
      Text(host.name).font(.system(size: 46, weight: .heavy)).lineLimit(2).foregroundStyle(.white)
        .shadow(color: .black.opacity(0.45), radius: 8)
      HStack(spacing: 10) {
        Text(deckCardStatus(host, pairing: pairing)).font(.system(size: 15, weight: .medium)).foregroundStyle(.white.opacity(0.82))
        if host.isFoundation && host.paired { DeckFsLabel(host: host, onDark: true) }
      }
      if host.paired { DeckPathChips(host: host, model: model, onDark: true) }
      if host.paired { DeckNicChips(host: host, model: model, onDark: true) }
      controls.padding(.top, 8)
    }
    .padding(.top, topInset)
    .padding(.leading, leadingInset)
    .padding(.trailing, DeckInset.page)
    .padding(.bottom, 44)
    .frame(maxWidth: .infinity, minHeight: height, alignment: .bottomLeading)
    .environment(\.colorScheme, .dark)
    .background { backdrop }
    .task(id: "\(host.id)/\(model.artVersion)/\(config.preview.rawValue)/\(Int(width / 100))/\(host.settledOffline)") {
      // Cache first: the last picture of this computer is drawn at once, found or not (a computer whose answer is still out
      // is drawn as it was last seen, never grey). Grey is for a computer discovery found OFF only, and it is part of the id
      // so that the picture follows it. A load that was replaced meanwhile (the id changed) must not write, or a
      // slow grey load that finishes after the coloured one keeps the picture grey until some art arrives.
      let next = await DeckArt.loadPreview(host, preference: config.preview, displayWidth: width, desaturate: DeckPresenceRules.greyHero(state: host.state))
      guard !Task.isCancelled else { return }
      loaded = true
      // swapped with a cross-fade, and only when it really is another picture
      if next !== image { withAnimation(.easeInOut(duration: 0.3)) { image = next } }
    }
  }

  @ViewBuilder
  private var backdrop: some View {
    GeometryReader { geo in
      let size = CGSize(width: geo.size.width + extendLeading, height: geo.size.height + extendTop)
      let tint = (!host.online || host.icon.colorName == "gray") ? Color.accentColor : DeckPalette.color(host.icon.colorName)
      // where the text sits (bottom left of the visible hero), in the backdrop's own coordinates
      let textCentre = UnitPoint(x: (extendLeading + geo.size.width * 0.18) / size.width, y: (extendTop + geo.size.height * 0.62) / size.height)
      ZStack {
        if let shown = image ?? (loaded ? nil : DeckArt.peekPreview(host, preference: config.preview, displayWidth: width, grey: DeckPresenceRules.greyHero(state: host.state))) {
          // the wallpaper in its own colours; offline it is only desaturated and a little darker
          Image(nsImage: shown).resizable().scaledToFill()
            .frame(width: size.width, height: size.height, alignment: .top).clipped()
            .id(ObjectIdentifier(shown))
            .transition(.opacity)
        } else if !loaded {
          // the picture is being read from disk: neither a colour card nor grey, so nothing flashes
          Color(white: 0.09)
        } else {
          LinearGradient(colors: [tint.opacity(0.9), tint.opacity(0.5)], startPoint: .topLeading, endPoint: .bottomTrailing)
          Image(systemName: host.icon.symbol.isEmpty ? "display" : host.icon.symbol)
            .font(.system(size: 220, weight: .ultraLight)).foregroundStyle(.white.opacity(0.22))
            .frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 90)
        }
        // only behind the text block: a soft pool of shade, low opacity, about the left 45 % and the lower 40 %
        RadialGradient(stops: [.init(color: .black.opacity(host.online ? 0.5 : 0.55), location: 0),
                               .init(color: .black.opacity(host.online ? 0.32 : 0.38), location: 0.45),
                               .init(color: .black.opacity(0.08), location: 0.8),
                               .init(color: .clear, location: 1)],
                       center: textCentre, startRadius: 0, endRadius: min(size.width * 0.42, 720))
      }
      .frame(width: size.width, height: size.height)
      .clipped()
      .offset(x: -extendLeading, y: -extendTop)
    }
  }

  // MARK: buttons

  @ViewBuilder
  private var controls: some View {
    if !host.online { offlineControls }
    else if !host.paired { pairingControls }
    else { liveControls }
  }

  private var liveControls: some View {
    DeckConnectBar(host: host, model: model, look: .hero, game: game)
  }

  private var offlineControls: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 12) {
        Button { model.actions.wake?() } label: { Label(host.canWake ? DL("deck.wake") : DL("deck.noMac"), systemImage: host.canWake ? "power" : "power.dotted") }
          .controllerButtonStyle(DeckHeroPrimaryStyle())
          .controllerKey("primary")
          .disabled(!host.canWake)
        DeckHeroRound(symbol: "slider.horizontal.3", help: DL("deck.settings")) { model.actions.settings?() }
        DeckHeroRound(symbol: "ellipsis", help: DL("deck.more"), padMenu: { DeckMoreMenu.menu(host, model) }) { DeckMenuPresenter.pop(DeckMoreMenu.menu(host, model)) }
      }
      if !host.canWake {
        Text(DL("deck.noMacReason")).font(.system(size: 13)).foregroundStyle(.white.opacity(0.8)).shadow(color: .black.opacity(0.4), radius: 3)
      }
    }
  }

  @ViewBuilder
  private var pairingControls: some View {
    if pairingStarted {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 8) {
          ForEach(Array((pairing.pins[host.id] ?? "    ").enumerated()), id: \.offset) { _, digit in
            Text(String(digit).trimmingCharacters(in: .whitespaces))
              .font(.system(size: 34, weight: .bold, design: .monospaced)).foregroundStyle(.black)
              .frame(width: 48, height: 62)
              .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white))
          }
          ProgressView().controlSize(.small).padding(.leading, 6)
          Button(DL("deck.cancel")) { pairing.cancel(host.id); model.actions.cancelPair?() }
            .buttonStyle(.plain).foregroundStyle(.white.opacity(0.85)).padding(.leading, 6)
            .controllerFocusTarget(key: "primary") { pairing.cancel(host.id); model.actions.cancelPair?() }
            .controllerBackAction(active: true) { pairing.cancel(host.id); model.actions.cancelPair?() }
        }
        Text(DLf("deck.pinWeb", host.name)).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.8))
      }
    } else {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 12) {
          Button { pairing.begin(host.id); model.actions.pair?() } label: {
            Label(pairing.failures[host.id] == nil ? DL("deck.pair") : DL("deck.retry"), systemImage: "link")
          }
          .controllerButtonStyle(DeckHeroPrimaryStyle())
          .controllerKey("primary")
          DeckHeroRound(symbol: "slider.horizontal.3", help: DL("deck.settings")) { model.actions.settings?() }
          DeckHeroRound(symbol: "ellipsis", help: DL("deck.more"), padMenu: { DeckMoreMenu.menu(host, model) }) { DeckMenuPresenter.pop(DeckMoreMenu.menu(host, model)) }
        }
        if let failure = pairing.failures[host.id] {
          Label(failure.isEmpty ? DL("deck.pairFailed") : failure, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 12.5)).foregroundStyle(.red).lineLimit(2)
        }
      }
    }
  }

  private func primary() {
    if let game { model.openApp(game) } else { connect() }
  }

  private func connect() {
    if let app = model.defaultApp { model.openApp(app) }
  }
}

// MARK: - Offline and unpaired: what the client knows

extension View {
  /// macOS 26 draws a soft scroll-edge effect under the toolbar where content scrolls beneath it; over a
  /// full-bleed hero that reads as a dark band across the top of the picture, so it is turned off there.
  @ViewBuilder func deckNoTopEdgeEffect(_ off: Bool) -> some View {
    if #available(macOS 26.0, *), off { self.scrollEdgeEffectHidden(true, for: .top) } else { self }
  }
}

/// A computer that is off or not paired, in a native grouped form (the System Settings look): 地址, 状态,
/// 设备, each a section of labelled rows with SF Symbols. Values are selectable and can be copied with the
/// small button or the context menu.
@available(macOS 14.0, *)
struct DeckOfflineInfo: View {
  enum Parts { case all, addresses, rest, status, device }
  let host: DeckHost
  @ObservedObject var model: DeckAppsModel
  var parts: Parts = .all
  var maxWidth: CGFloat = 640
  @SwiftUI.State private var addressTick = 0

  private var lastStream: String {
    guard let when = DeckTime.relative(host.facts.lastConnected) else { return DL("deck.never") }
    let name = host.facts.lastApp.flatMap { id in model.apps.first { $0.id == id }?.name ?? host.facts.sessions.first { $0.appId == id }?.name }
    return [name, when].compactMap { $0 }.joined(separator: " · ")
  }

  private var platform: String {
    [DeckLook.platformName(host.platform), host.facts.osVersion].filter { !$0.isEmpty }.joined(separator: " · ")
  }

  private var showAddresses: Bool { parts == .all || parts == .addresses }
  private var showStatus: Bool { parts == .all || parts == .rest || parts == .status }
  private var showDevice: Bool { parts == .all || parts == .rest || parts == .device }

  /// The grouped-form look (section header, rounded group of LabeledContent rows with hairlines), built from
  /// plain SwiftUI so it scales with the page: the system Form is backed by an AppKit table, which does not
  /// survive being drawn inside a scaled page.
  var body: some View {
    let _ = addressTick
    VStack(alignment: .leading, spacing: 22) {
      if showAddresses {
        group(DL("deck.info.addresses")) {
          row { DeckAutoAddressRow(host: host, model: model) }
          // the one list (DeckAddressModel): the computer's fields, the addresses the user added, what discovery found
          let addressRows = DeckAddressModel.rows(host)
          ForEach(Array(addressRows.enumerated()), id: \.element.id) { index, entry in
            row { DeckAddressRow(host: host, model: model, row: entry, canMoveUp: index > 0, canMoveDown: index < addressRows.count - 1) }
          }
          row {
            Button { model.actions.addConnection?() } label: { Label(DL("deck.addr.add"), systemImage: "plus.circle") }
              .controllerButtonStyle(.borderless).foregroundStyle(Color.accentColor).deckTouchTarget()
          }
        }
      }
      if showStatus {
        group(DL("deck.info.status")) {
          row { LabeledContent { Text(DeckTime.relative(host.facts.lastSeen ?? host.facts.lastConnected) ?? DL("deck.neverConnected")) } label: { Label(DL("deck.fact.lastOnline"), systemImage: "clock") } }
          row { LabeledContent { Text(lastStream) } label: { Label(DL("deck.fact.lastStream"), systemImage: "play.circle") } }
          row { LabeledContent { Text(host.paired ? DL("deck.paired") : DL("deck.unpaired")) } label: { Label(DL("deck.info.pairing"), systemImage: host.paired ? "link" : "link.badge.plus") } }
          row { LabeledContent { Text(model.apps.isEmpty ? DL("deck.none") : DLf("deck.appCount", model.apps.count)) } label: { Label(DL("deck.info.cachedApps"), systemImage: "square.grid.2x2") } }
        }
      }
      if showDevice {
        group(DL("deck.info.device")) {
          row {
            LabeledContent {
              if host.canWake { copyable((host.raw.mac ?? "").uppercased(), monospaced: true) } else { Text(DL("deck.unknown")) }
            } label: { Label(DL("deck.fact.mac"), systemImage: "network") }
          }
          if !platform.isEmpty {
            row { LabeledContent { Text(platform) } label: { Label(DL("deck.fact.platform"), systemImage: "desktopcomputer") } }
          }
          // what the 主机信息 section would have said, here, once
          if !host.facts.gpu.isEmpty {
            row { LabeledContent { Text(host.facts.gpu) } label: { Label(DL("deck.fact.gpu"), systemImage: "cpu") } }
          }
          if host.raw.serverCodecModeSupport != 0 {
            row { LabeledContent { Text(deckCapabilityText(host)) } label: { Label(DL("deck.fact.codecs"), systemImage: "film") } }
          }
          let modes = DeckHostInfoCard.modes(host.facts.displayModes)
          if !modes.isEmpty {
            row { LabeledContent { Text(modes) } label: { Label(DL("deck.fact.modes"), systemImage: "display") } }
          }
          if host.softwareKnown {
            row { LabeledContent { DeckSoftwareValue(host: host, kindSeen: model.fsKindSeen) } label: { Label(DL("deck.fact.software"), systemImage: "shippingbox") } }
          }
        }
      }
      if showDevice { DeckFsFeatureGroup(host: host) }
    }
    .frame(maxWidth: maxWidth, alignment: .leading)
    .onReceive(NotificationCenter.default.publisher(for: .init("ConnectionEndpointsUpdated"))) { _ in
      addressTick += 1
      DeckAddressModel.probeMissing(host, actions: model.actions)
    }
    .onReceive(NotificationCenter.default.publisher(for: .deckAddressChanged)) { _ in addressTick += 1 }
  }

  private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(.system(size: 13, weight: .semibold)).padding(.leading, 10)
      VStack(spacing: 0, content: content)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 0.5))
    }
  }

  private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    content()
      .labeledContentStyle(DeckTrailingValueStyle())
      .font(.system(size: 13))
      .padding(.horizontal, 12).padding(.vertical, 9)
      .frame(maxWidth: .infinity, alignment: .leading)
      .overlay(alignment: .bottom) { Divider().padding(.leading, 12) }
  }

  /// A value that can be selected and copied: a borderless button beside it, and 拷贝 in the context menu.
  private func copyable(_ value: String, monospaced: Bool) -> some View {
    HStack(spacing: 6) {
      Text(value).font(monospaced ? .system(.body, design: .monospaced) : .body)
      Button {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
      } label: {
        Image(systemName: "doc.on.doc")
      }
      .controllerButtonStyle(.borderless)
      .deckTouchTarget()
      .deckHelp(DL("deck.copy"))
    }
    .contextMenu {
      Button(DL("deck.copy")) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
      }
    }
  }
}

// MARK: - Preset cards in the 自定义主页 popover

