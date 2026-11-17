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
          .modifier(DeckPairNudge(hostID: host.id))
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

/// A tiny drawing of what each 主页样式 looks like, so the difference is visible before choosing.
@available(macOS 14.0, *)
struct DeckPresetCard: View {
  let style: DeckHomeStyle
  let selected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(spacing: 5) {
        thumbnail
          .frame(width: 62, height: 46)
          .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
          .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: selected ? 2 : 0.5))
        Text(style.title).font(.system(size: 11, weight: selected ? .semibold : .regular)).foregroundStyle(selected ? Color.accentColor : Color.primary)
      }
    }
    .controllerButtonStyle(.plain)
  }

  private func block(_ w: CGFloat, _ h: CGFloat, _ color: Color = Color.secondary.opacity(0.45), radius: CGFloat = 1.5) -> some View {
    RoundedRectangle(cornerRadius: radius, style: .continuous).fill(color).frame(width: w, height: h)
  }

  @ViewBuilder
  private var thumbnail: some View {
    let accent = Color.accentColor
    switch style {
    case .simple:
      // small computer card, then a dense grid of small portrait tiles
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 3) { block(10, 10, accent.opacity(0.7), radius: 2.5); block(18, 4); Spacer(minLength: 0); block(16, 10, accent.opacity(0.35), radius: 2) }
        HStack(spacing: 2.5) { ForEach(0..<6, id: \.self) { _ in block(6.5, 9) } }
        HStack(spacing: 2.5) { ForEach(0..<6, id: \.self) { _ in block(6.5, 9) } }
      }
      .padding(6)
    case .games:
      // a hero over the top, a shelf of landscape cards, large tiles
      VStack(alignment: .leading, spacing: 3) {
        RoundedRectangle(cornerRadius: 2, style: .continuous).fill(LinearGradient(colors: [accent.opacity(0.75), accent.opacity(0.2)], startPoint: .topLeading, endPoint: .bottomTrailing))
          .frame(height: 17)
        HStack(spacing: 2.5) { block(17, 9, accent.opacity(0.45)); block(17, 9, accent.opacity(0.45)); block(17, 9, accent.opacity(0.45)) }
        HStack(spacing: 3) { block(12, 11); block(12, 11); block(12, 11); block(12, 11) }
      }
      .padding(.horizontal, 5).padding(.vertical, 4)
    case .auto:
      ZStack {
        HStack(spacing: 0) {
          VStack(alignment: .leading, spacing: 3) { block(18, 8, accent.opacity(0.5)); block(18, 8); block(18, 8) }.padding(.leading, 6)
          Spacer(minLength: 0)
          VStack(alignment: .leading, spacing: 3) { block(26, 12, accent.opacity(0.3)); HStack(spacing: 2) { block(8, 10); block(8, 10); block(8, 10) } }.padding(.trailing, 6)
        }
        Image(systemName: "sparkles").font(.system(size: 13, weight: .semibold)).foregroundStyle(accent)
      }
    case .custom:
      VStack(alignment: .leading, spacing: 4) {
        ForEach(0..<3, id: \.self) { index in
          HStack(spacing: 4) {
            block(5, 5, index == 1 ? Color.secondary.opacity(0.25) : accent.opacity(0.6), radius: 1)
            block(index == 0 ? 30 : 22, 5)
            Spacer(minLength: 0)
            Image(systemName: "line.3.horizontal").font(.system(size: 6, weight: .bold)).foregroundStyle(.tertiary)
          }
        }
      }
      .padding(7)
    }
  }
}

// MARK: - Arrangements of the offline page

enum DeckOfflineLayout: String {
  case today, a, b, c, d
  static var current: DeckOfflineLayout {
    conceptEnv("MLC_OFFLINE").flatMap { DeckOfflineLayout(rawValue: $0.lowercased()) } ?? .b
  }
}

/// The info form(s) of an offline page for the arrangement in use (today and A: one column; B: two columns,
/// 地址 | 状态 + 设备, one column when narrow; D: three columns 地址 | 状态 | 设备 on wide windows, two on
/// medium, one on narrow; C is drawn by the card itself).
@available(macOS 14.0, *)
struct DeckOfflineBlock: View {
  let host: DeckHost
  @ObservedObject var model: DeckAppsModel
  let contentWidth: CGFloat
  var maxWidth: CGFloat = 640

  var body: some View {
    switch DeckOfflineLayout.current {
    case .b where contentWidth >= 860:
      HStack(alignment: .top, spacing: 8) {
        DeckOfflineInfo(host: host, model: model, parts: .addresses, maxWidth: .infinity)
        DeckOfflineInfo(host: host, model: model, parts: .rest, maxWidth: .infinity)
      }
    case .d where contentWidth >= 1400:
      HStack(alignment: .top, spacing: 8) {
        DeckOfflineInfo(host: host, model: model, parts: .addresses, maxWidth: .infinity)
        DeckOfflineInfo(host: host, model: model, parts: .status, maxWidth: .infinity)
        DeckOfflineInfo(host: host, model: model, parts: .device, maxWidth: .infinity)
      }
    case .d where contentWidth >= 860:
      HStack(alignment: .top, spacing: 8) {
        DeckOfflineInfo(host: host, model: model, parts: .addresses, maxWidth: .infinity)
        DeckOfflineInfo(host: host, model: model, parts: .rest, maxWidth: .infinity)
      }
    default:
      DeckOfflineInfo(host: host, model: model, parts: .all, maxWidth: maxWidth)
    }
  }
}

/// LabeledContent in a plain stack puts the value next to the label; in a form it sits at the trailing edge.
/// This style gives the form look: label on the left, value on the right in secondary colour.
struct DeckTrailingValueStyle: LabeledContentStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(alignment: .firstTextBaseline) {
      configuration.label
      Spacer(minLength: 24)
      configuration.content.foregroundStyle(.secondary).multilineTextAlignment(.trailing)
    }
  }
}

// MARK: - Addresses: test and default

extension Notification.Name { static let deckAddressChanged = Notification.Name("MLDeckAddressChanged") }

/// 自动: no address is pinned; the client ranks them (latency, reachability).
@available(macOS 14.0, *)
struct DeckAutoAddressRow: View {
  let host: DeckHost
  @ObservedObject var model: DeckAppsModel
  @SwiftUI.State private var tick = 0

  var body: some View {
    let _ = tick
    let chosen = model.actions.defaultAddress?(host.id) ?? ""
    let isAuto = chosen.isEmpty || chosen == "Auto"
    HStack(spacing: 8) {
      Label(DL("deck.auto"), systemImage: "arrow.triangle.branch")
      Spacer(minLength: 12)
      Text(DL("deck.addr.autoHint")).foregroundStyle(.secondary).font(.system(size: 12))
      Button {
        model.actions.setDefaultAddress?(host.id, "")
        NotificationCenter.default.post(name: .deckAddressChanged, object: nil)
      } label: {
        Image(systemName: isAuto ? "checkmark.circle.fill" : "circle").foregroundStyle(isAuto ? Color.accentColor : Color.secondary)
      }
      .controllerButtonStyle(.borderless)
      .deckTouchTarget()
      .deckHelp(DL("deck.addr.useAuto"))
    }
    .onReceive(NotificationCenter.default.publisher(for: .deckAddressChanged)) { _ in tick += 1 }
  }
}

/// One address: what it is (a path class when evidence has settled it, otherwise what the address itself is: IP, 域名, 内网),
/// the full host:port (the port is always written), 测试, 设为默认, and, in a menu, 编辑 in place (host:port and type; the
/// computer's own fields only change type), 上移 / 下移 (the order automatic connection prefers) and 删除 (only for an address the
/// user added). The tooltip carries the evidence.
@available(macOS 14.0, *)
struct DeckAddressRow: View {
  let host: DeckHost
  @ObservedObject var model: DeckAppsModel
  let row: DeckAddressModel.Row
  let canMoveUp: Bool
  let canMoveDown: Bool
  @SwiftUI.State private var state: ProbeState = .idle
  @SwiftUI.State private var tick = 0
  @SwiftUI.State private var editing = false
  @SwiftUI.State private var draft = ""
  @SwiftUI.State private var draftKind = ""
  @SwiftUI.State private var draftError = false

  enum ProbeState: Equatable { case idle, testing, ok(Int), failed }

  private var address: String { row.entry.endpoint.display }

  private var isDefault: Bool {
    let chosen = model.actions.defaultAddress?(host.id) ?? ""
    return DeckEndpoint.parse(chosen) == row.entry.endpoint && !chosen.isEmpty && chosen != "Auto"
  }

  var body: some View {
    let _ = tick
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Label(row.isDomain ? DL("deck.label.domain") : DeckAddressModel.title(row.word),
              systemImage: row.isDomain ? "network" : DeckAddressModel.symbol(row.word))
          .deckHelp(evidenceHelp)
        Spacer(minLength: 12)
        Text(address).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        if row.isDomain && row.verdict.isConfirmed {
          Text(DeckAddressModel.title(row.word)).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        if isDefault {
          Text(DL("deck.addr.default")).font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.accentColor)
            .padding(.horizontal, 6).padding(.vertical, 2).background(Color.accentColor.opacity(0.14), in: Capsule())
        }
        result
        Button { test() } label: { Text(DL("deck.addr.test")).font(.system(size: 12)) }
          .controllerButtonStyle(.borderless).foregroundStyle(Color.accentColor).disabled(state == .testing)
        Button {
          model.actions.setDefaultAddress?(host.id, isDefault ? "" : address)
          NotificationCenter.default.post(name: .deckAddressChanged, object: nil)
        } label: {
          Image(systemName: isDefault ? "checkmark.circle.fill" : "circle").foregroundStyle(isDefault ? Color.accentColor : Color.secondary)
        }
        .controllerButtonStyle(.borderless)
        .deckTouchTarget()
        .deckHelp(isDefault ? DL("deck.addr.useAuto") : DL("deck.addr.setDefault"))
        Menu {
          Button(DL("deck.addr.edit")) { beginEdit() }
          Button(DL("deck.addr.moveUp")) { DeckAddressModel.move(host, key: row.entry.endpoint.key, by: -1) }.disabled(!canMoveUp)
          Button(DL("deck.addr.moveDown")) { DeckAddressModel.move(host, key: row.entry.endpoint.key, by: 1) }.disabled(!canMoveDown)
          Divider()
          Button(DL("deck.copy")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(address, forType: .string) }
          if row.entry.deletable { Button(DL("deck.addr.remove"), role: .destructive) { remove() } }
        } label: { Image(systemName: "ellipsis.circle") }
          .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().deckTouchTarget().deckHelp(DL("deck.more"))
          .controllerFocusMenu(key: "addr.more") { (title: address, menu: padMenu) }
      }
      if editing { editor }
    }
    .contextMenu {
      Button(DL("deck.addr.edit")) { beginEdit() }
      Button(DL("deck.addr.test")) { test() }
      Button(DL("deck.addr.setDefault")) { model.actions.setDefaultAddress?(host.id, address); NotificationCenter.default.post(name: .deckAddressChanged, object: nil) }
      Button(DL("deck.addr.moveUp")) { DeckAddressModel.move(host, key: row.entry.endpoint.key, by: -1) }.disabled(!canMoveUp)
      Button(DL("deck.addr.moveDown")) { DeckAddressModel.move(host, key: row.entry.endpoint.key, by: 1) }.disabled(!canMoveDown)
      Button(DL("deck.copy")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(address, forType: .string) }
      if row.entry.deletable { Button(DL("deck.addr.remove"), role: .destructive) { remove() } }
    }
    .onReceive(NotificationCenter.default.publisher(for: .deckAddressChanged)) { _ in tick += 1 }
    .onReceive(NotificationCenter.default.publisher(for: .init("ConnectionEndpointsUpdated"))) { _ in tick += 1 }
    .onReceive(NotificationCenter.default.publisher(for: .init("HostLatencyUpdated"))) { _ in tick += 1 }
    .onAppear {
      if conceptEnv("MLC_ADDR_TEST") == address { state = .testing }
      if let v = conceptEnv("MLC_ADDR_RESULT"), conceptEnv("MLC_ADDR_TEST") == address {
        state = v == "fail" ? .failed : .ok(Int(v) ?? 12)
      }
      if conceptEnv("MLC_ADDR_EDIT") == address { beginEdit() }
    }
  }

  /// The row's menu for the pad (the same items as the ⋯ menu and the context menu).
  private var padMenu: NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.addItem(ControllerMenuBuilder.item(title: DL("deck.addr.edit")) { beginEdit() })
    menu.addItem(ControllerMenuBuilder.item(title: DL("deck.addr.test")) { test() })
    menu.addItem(ControllerMenuBuilder.item(title: DL("deck.addr.setDefault")) {
      model.actions.setDefaultAddress?(host.id, address); NotificationCenter.default.post(name: .deckAddressChanged, object: nil)
    })
    menu.addItem(ControllerMenuBuilder.item(title: DL("deck.addr.moveUp"), enabled: canMoveUp) { DeckAddressModel.move(host, key: row.entry.endpoint.key, by: -1) })
    menu.addItem(ControllerMenuBuilder.item(title: DL("deck.addr.moveDown"), enabled: canMoveDown) { DeckAddressModel.move(host, key: row.entry.endpoint.key, by: 1) })
    menu.addItem(ControllerMenuBuilder.item(title: DL("deck.copy")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(address, forType: .string) })
    if row.entry.deletable { menu.addItem(ControllerMenuBuilder.item(title: DL("deck.addr.remove")) { remove() }) }
    return menu
  }

  // MARK: edit in place

  private static let kinds: [(String, String)] = [("", "Path: automatic"), ("host", "Path: the computer itself"), ("forward", "Path: port forward"),
                                                   ("relay", "Path: relay server"), ("overlay", "Path: VPN / mesh")]

  private func beginEdit() {
    draft = address
    draftKind = ConnectionEndpointStore.declaredPath(forEndpoint: address, forHost: host.id) ?? ""
    draftError = false
    editing = true
  }

  private var editor: some View {
    HStack(spacing: 8) {
      TextField("host:port", text: $draft)
        .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
        .disabled(!row.entry.deletable)   // the computer's own fields keep their address; only their type can be declared
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.red, lineWidth: draftError ? 1 : 0))
      Picker("", selection: $draftKind) {
        ForEach(Self.kinds, id: \.0) { Text(DL($0.1)).tag($0.0) }
      }
      .labelsHidden().fixedSize()
      .controllerPicker(selection: $draftKind, choices: Self.kinds.map { (value: $0.0, title: DL($0.1)) })
      Button(DL("deck.done")) { commitEdit() }.keyboardShortcut(.defaultAction).controllerButtonStyle(.automatic)
      Button(DL("deck.cancel")) { editing = false }.keyboardShortcut(.cancelAction).controllerButtonStyle(.automatic)
    }
  }

  private func commitEdit() {
    guard let parsed = DeckEndpoint.parse(draft) else { draftError = true; return }
    var target = address
    if row.entry.deletable, parsed != row.entry.endpoint, let raw = DeckAddressModel.manualRaw(host, row.entry) {
      guard ConnectionEndpointStore.replaceManualEndpoint(raw, with: parsed.display, forHost: host.id) else { draftError = true; return }
      target = parsed.display
    }
    ConnectionEndpointStore.setDeclaredPath(draftKind.isEmpty ? nil : draftKind, forEndpoint: target, forHost: host.id)
    editing = false
    NotificationCenter.default.post(name: .deckAddressChanged, object: nil)
    NotificationCenter.default.post(name: DeckConnectMenuRegistry.didChange, object: nil)
    DeckAddressModel.probeMissing(host, actions: model.actions)
  }

  /// "端口转发 · 解析到 203.0.113.79,与主机公网地址一致 (可信度 中)": the confidence is said only here, in the tooltip.
  private var evidenceHelp: String {
    var text = DeckAddressModel.title(row.word)
    if !row.verdict.resolvedIPs.isEmpty && row.isDomain { text += "\n" + row.verdict.resolvedIPs.joined(separator: ", ") }
    text += "\n" + DeckAddressModel.evidence(row.verdict)
    if row.verdict.isConfirmed { text += " · " + DeckAddressModel.confidenceText(row.verdict.confidence) }
    return text
  }

  @ViewBuilder
  private var result: some View {
    switch state {
    case .idle:
      if let ms = DeckLatencyRules.valid(row.latency) { Text(DLf("deck.addr.reachable", ms)).font(.system(size: 12, weight: .medium)).foregroundStyle(.green) }
      else if row.answered { Text(DL("deck.addr.reachableNoMs")).font(.system(size: 12, weight: .medium)).foregroundStyle(.green) }
      else if row.failed { Text(DL("deck.addr.noAnswer")).font(.system(size: 12, weight: .medium)).foregroundStyle(.red) }
    case .testing: HStack(spacing: 4) { ProgressView().controlSize(.mini); Text(DL("deck.addr.testing")).font(.system(size: 12)).foregroundStyle(.secondary) }
    case .ok(let measured):
      if let ms = DeckLatencyRules.valid(measured) { Text(DLf("deck.addr.reachable", ms)).font(.system(size: 12, weight: .medium)).foregroundStyle(.green) }
      else { Text(DL("deck.addr.reachableNoMs")).font(.system(size: 12, weight: .medium)).foregroundStyle(.green) }
    case .failed: Text(DL("deck.addr.noAnswer")).font(.system(size: 12, weight: .medium)).foregroundStyle(.red)
    }
  }

  private func test() {
    guard let probe = model.actions.probeAddress else { state = .failed; return }
    state = .testing
    probe(address, 4.0) { ms in
      DispatchQueue.main.async { state = ms.map { .ok($0.intValue) } ?? .failed }
    }
  }

  /// Gone from the store, so gone from this list and from the 线路 chips at once.
  private func remove() {
    if let raw = DeckAddressModel.manualRaw(host, row.entry) { ConnectionEndpointStore.removeManualEndpoint(raw, forHost: host.id) }
    if isDefault { model.actions.setDefaultAddress?(host.id, "") }
    NotificationCenter.default.post(name: .deckAddressChanged, object: nil)
    NotificationCenter.default.post(name: DeckConnectMenuRegistry.didChange, object: nil)
  }
}

/// The 线路 section: 自动 and one item per PATH class (局域网, 公网直连, 端口转发, 组网, 中转, 未确认), built from the same
/// list as the 地址 group (DeckAddressModel). Several addresses of one class are one chip with every host:port in its
/// tooltip, the evidence for the class under them, and a port hint on the chip when they use a non-standard port.
/// Results come from discovery's per-address probes (matched by host AND port); an address discovery has not reported
/// on gets an independent 1.5 s probe. A path is never called direct, forwarded or relayed without evidence.
@available(macOS 14.0, *)
final class DeckAddressRouteProvider: DeckConnectMenuSectionProvider {
  static let shared = DeckAddressRouteProvider()
  weak var actions: DeckAppsActions?
  var order: Int { 50 }

  func sections(for host: DeckHost) -> [DeckConnectMenuSection] {
    guard let actions else { return [] }
    let chosenRaw = actions.defaultAddress?(host.id) ?? ""
    let automatic = chosenRaw.isEmpty || chosenRaw == "Auto"
    let chosen = automatic ? nil : DeckEndpoint.parse(chosenRaw)
    let live = DeckLive.host(host.id) ?? host.raw
    let active = live.activeAddress.flatMap { DeckEndpoint.parse($0) }
    func set(_ value: String) -> () -> Void {
      return {
        actions.setDefaultAddress?(host.id, value)
        NotificationCenter.default.post(name: .deckAddressChanged, object: nil)
        NotificationCenter.default.post(name: DeckConnectMenuRegistry.didChange, object: nil)
      }
    }

    let rows = DeckAddressModel.rows(host)
    let groups = DeckChipBuilder.groups(rows.map { ($0.entry.endpoint, $0.verdict) })
    var items = [DeckConnectMenuItem(id: "route.auto", title: DL("deck.auto"), symbol: "arrow.triangle.branch", selected: automatic, action: set(""))]
    var snaps = [DeckChipSnap(id: "route.auto", title: DL("deck.auto"), symbol: "arrow.triangle.branch", target: "")]
    for group in groups {
      let members = rows.filter { row in group.endpoints.contains(row.entry.endpoint) }
      var best: Int?
      var answered = false, failed = false
      for row in members {
        if row.answered { answered = true; if let ms = row.latency { best = min(best ?? ms, ms) } }
        if row.failed { failed = true }
      }
      // nothing from discovery for this class: an independent probe of its first address, then its result
      var probing = false
      if !answered && !failed && host.online {
        let target = members.first { !$0.entry.endpoint.isLocalName }.map { $0.entry.endpoint.display } ?? members[0].entry.endpoint.display
        if let result = DeckProbe.result(host.id, target) {
          if result.reachable { answered = true; best = result.ms } else { failed = true }
          if Date().timeIntervalSince(result.when) > 8 { DeckProbe.request(host: host.id, address: target, using: actions.probeAddress) }
        } else {
          DeckProbe.request(host: host.id, address: target, using: actions.probeAddress)
          probing = true
        }
      }
      let target = (members.first { !$0.entry.endpoint.isLocalName } ?? members[0]).entry.endpoint
      // what the chip shows: the address in use, else the fastest, else the first; "+N" for the others of the group
      let pick = DeckChipBuilder.shown(group, inUse: active) { endpoint in members.first { $0.entry.endpoint == endpoint }?.latency }
      let latencyOfPick = members.first { $0.entry.endpoint == pick.endpoint }?.latency ?? best
      let word = DeckAddressModel.title(group.word)
      let shown = latencyOfPick.flatMap { DeckLatency.display(key: host.id + "|path|" + pick.endpoint.key, raw: $0) }
      var item = DeckConnectMenuItem(id: "route.\(group.group)", title: word + " " + pick.endpoint.shortDisplay() + (pick.more > 0 ? " +\(pick.more)" : ""),
                                     trailing: shown.map { "\($0) ms" },
                                     symbol: DeckAddressModel.symbol(group.word),
                                     selected: !automatic && chosen.map { c in group.endpoints.contains(c) } == true,
                                     action: set(target.display))
      item.unreachable = !answered && failed
      item.testing = probing || (!answered && !failed && host.online && DeckProbe.isRunning(host.id, target.display))
      item.inUse = automatic && active.map { a in group.endpoints.contains(a) } == true && !item.unreachable
      // every host:port of the group, then the evidence for the first member that has one
      let evidence = members.first { $0.verdict.isConfirmed }.map { DeckAddressModel.evidence($0.verdict) } ?? members.first.map { DeckAddressModel.evidence($0.verdict) } ?? ""
      // a stream on this address failed in the last 30 minutes: the chip says so, the tooltip says why
      var failureNote = ""
      if let failure = StreamPathHealth.recentFailure(forHost: host.id, address: pick.endpoint.display) {
        let reason = (failure["reason"] as? String) == "loss" ? DLf("deck.path.failedLoss", (failure["detail"] as? String) ?? "") : DL("deck.path.failedControl")
        failureNote = DLf("deck.path.failedWhy", reason)
        item.badge = DL("deck.path.failedMark")
      }
      var streamNote = ""
      if let measured = members.first(where: { $0.entry.endpoint == pick.endpoint }), let ms = measured.streamMs, let when = measured.streamWhen {
        streamNote = DLf("deck.latency.stream", ms, DateFormatter.localizedString(from: when, dateStyle: .medium, timeStyle: .short))
      }
      item.tooltip = (group.endpoints.map { $0.display } + [failureNote, streamNote, evidence]).filter { !$0.isEmpty }.joined(separator: "\n")
      items.append(item)
      snaps.append(DeckChipSnap(id: item.id, title: item.title, symbol: item.symbol, trailing: item.trailing, badge: item.badge, unreachable: item.unreachable,
                                inUse: item.inUse, target: target.display, members: group.endpoints.map { $0.key }, tooltip: item.tooltip ?? ""))
    }
    // The first frames of a launch: the answers are still out and the paths would be drawn from less than they will be. Until
    // they are in, the chips are the remembered ones (same addresses, same order); then the live ones, which replace them
    // only where something really differs (DeckChipStability).
    let keys = rows.map { $0.entry.endpoint.key }
    let waited = DeckChipMemory.waited(host.id)
    let complete = DeckChipStability.evidenceComplete(offline: host.settledOffline, rows: rows.map {
      // the path class also reads the interface evidence of the path probe (HostPathSignals), which comes a moment after the
      // round trip: counted as in after a short grace if it never comes
      (answered: $0.answered, failed: $0.failed,
       measured: waited >= 5 || ($0.latency != nil && HostPathSignals.shared.probeFact(uuid: host.id, address: $0.entry.endpoint.display) != nil),
       isDomain: $0.isDomain,
       resolved: !$0.isDomain || DeckResolver.addresses($0.entry.endpoint.host) != nil)
    })
    let remembered = DeckChipMemory.entry(host.id)
    let choice = DeckChipStability.choose(live: snaps, liveKeys: keys, remembered: remembered, complete: complete, waited: waited)
    if DeckChipStability.shouldSave(live: snaps, liveKeys: keys, remembered: remembered, complete: complete, sinceLastSave: DeckChipMemory.sinceLastSave(host.id)) {
      DeckChipMemory.save(host.id, DeckChipMemoryEntry(keys: keys, chips: snaps))
    }
    if choice.fromMemory {
      items = choice.chips.map { snap in
        var item = DeckConnectMenuItem(id: snap.id, title: snap.title, trailing: snap.trailing, badge: snap.badge, symbol: snap.symbol,
                                       selected: snap.id == "route.auto" ? automatic : (!automatic && chosen.map { snap.members.contains($0.key) } == true),
                                       action: set(snap.target))
        item.unreachable = snap.unreachable
        // the address in use is known as soon as discovery has one; until then the last one carries the mark
        item.inUse = automatic && (active.map { a in snap.members.contains(a.key) } ?? snap.inUse) && !snap.unreachable
        item.tooltip = snap.tooltip
        item.pending = true
        return item
      }
    } else if choice.pending {
      for index in items.indices { items[index].pending = true }
    }
    return [DeckConnectMenuSection(id: "route", title: DL("deck.route"), items: items)]
  }
}

// MARK: - Menus: the old right-click menus as real NSMenus

enum DeckMenuPresenter {
  static func pop(_ menu: NSMenu) {
    menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
  }
}

/// A menu item that runs a closure.
final class DeckBlockMenuItem: NSMenuItem {
  private var block: (() -> Void)?

  init(_ title: String, symbol: String? = nil, checked: Bool = false, enabled: Bool = true, _ block: @escaping () -> Void) {
    super.init(title: title, action: #selector(fire), keyEquivalent: "")
    self.block = block
    target = self
    state = checked ? .on : .off
    isEnabled = enabled
    if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
  }

  required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

  @objc private func fire() { block?() }
}

/// A transparent layer that takes only right clicks (and control-clicks) and shows the old NSMenu; everything
/// else passes through to the tile beneath it. SwiftUI's own contextMenu cannot show the old menu with its
/// submenus built by the old code.
struct DeckContextMenuLayer: NSViewRepresentable {
  let provider: () -> NSMenu?

  func makeNSView(context: Context) -> DeckMenuView { DeckMenuView() }
  func updateNSView(_ view: DeckMenuView, context: Context) { view.provider = provider }

  final class DeckMenuView: NSView {
    var provider: (() -> NSMenu?)?

    override func hitTest(_ point: NSPoint) -> NSView? {
      guard let event = NSApp.currentEvent else { return nil }
      let secondary = event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
      return secondary ? super.hitTest(point) : nil
    }

    // A long press with a finger opens the same menu (macOS 27 touch): see DeckTouchLongPress.
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard #available(macOS 14.0, *) else { return }
      if window != nil {
        DeckTouchLongPress.shared.register(self) { [weak self] in self?.provider?() }
      } else {
        DeckTouchLongPress.shared.unregister(self)
      }
    }

    override func rightMouseDown(with event: NSEvent) { show(event) }
    override func mouseDown(with event: NSEvent) { if event.modifierFlags.contains(.control) { show(event) } }

    private func show(_ event: NSEvent) {
      if let menu = provider?() { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }
  }
}

@available(macOS 14.0, *)
extension View {
  /// The full old app menu on right-click.
  func deckAppContextMenu(_ app: TemporaryApp, _ model: DeckAppsModel) -> some View {
    Group { if conceptEnv("MLC_NOMENULAYER") != nil { self } else { overlay(DeckContextMenuLayer { model.actions.appMenu?(app) }) } }
  }
}

/// The ⋯ menu of a computer: 线路 and the connection modes first, then the old host menu with all its items.
@available(macOS 14.0, *)
enum DeckMoreMenu {
  static func menu(_ snapshot: DeckHost, _ model: DeckAppsModel) -> NSMenu {
    // the computer as it is now: its software (and so what is greyed here) is known only after a serverinfo answer was read
    let host = DeckHost(snapshot.raw, live: DeckLive.host(snapshot.id))
    let menu = model.actions.hostMenu?(model.defaultApp) ?? NSMenu()
    var head: [NSMenuItem] = []

    for section in DeckConnectMenuRegistry.sections(for: host) {
      head.append(NSMenuItem.sectionHeader(title: section.title))
      for item in section.items {
        let text = item.title + (item.trailing.map { "   " + $0 } ?? "") + (item.unreachable ? "   " + DL("deck.path.timeout") : (item.testing ? "   " + DL("deck.path.testing") : ""))
        head.append(DeckBlockMenuItem(text, checked: item.selected, enabled: item.enabled && !(item.unreachable && !item.selected)) { item.action() })
      }
    }
    var modes: [NSMenuItem] = []
    if model.canStream && DeckConnect.vddAvailable(host) {
      modes.append(DeckBlockMenuItem(DL("deck.more.vdd"), symbol: "display.2") {
        DeckConnect.connect(DeckConnectChoice(mode: .vdd, displayId: nil), host: host, model: model)
      })
    }
    let displays = model.canStream ? DeckConnect.displays(host, model) : []
    if !displays.isEmpty {
      let sub = NSMenu()
      for display in displays {
        sub.addItem(DeckBlockMenuItem(display.name) {
          DeckConnect.connect(DeckConnectChoice(mode: .display, displayId: display.id), host: host, model: model)
        })
      }
      let parent = NSMenuItem(title: DL("deck.mode.chooseDisplay"), action: nil, keyEquivalent: "")
      parent.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: nil)
      parent.submenu = sub
      modes.append(parent)
    }
    // a computer without Foundation Sunshine: the modes it cannot offer stay in the menu, greyed, with the reason
    if host.paired && host.softwareKnown && !host.isFoundation {
      let why = DeckFs.requirement(host)
      modes.append(DeckBlockMenuItem(DL("deck.mode.bigscreen") + "   " + why, symbol: "tv", enabled: false) {})
      modes.append(DeckBlockMenuItem(DL("deck.more.vdd.short") + "   " + why, symbol: "display.2", enabled: false) {})
      if DeckFsPromoRules.recommends(host.software) {
        modes.append(DeckBlockMenuItem(DL("deck.fs.learnFull"), symbol: "sun.max") { DeckFs.learn() })
      }
    }
    if !modes.isEmpty {
      head.append(NSMenuItem.sectionHeader(title: DL("deck.connectMode")))
      head.append(contentsOf: modes)
    }
    if !head.isEmpty { head.append(.separator()) }
    for (index, item) in head.enumerated() { menu.insertItem(item, at: index) }
    return menu
  }
}

// MARK: - The connect area: separate buttons

enum DeckConnectLook { case card, hero }

/// 连接桌面 (filled), 大屏模式 (Foundation Sunshine hosts), the round 串流设置 and 更多 buttons; while a game
/// runs the filled one is 继续 <app> with 退出应用 beside it. No split button, no dropdown.
@available(macOS 14.0, *)
struct DeckConnectBar: View {
  let host: DeckHost
  @ObservedObject var model: DeckAppsModel
  let look: DeckConnectLook
  var game: TemporaryApp?

  private var hero: Bool { look == .hero }
  private var height: CGFloat { hero ? 46 : 44 }

  var body: some View {
    let choice = DeckConnect.effective(host, model)
    let shown = choice.mode == .bigscreen ? DeckConnectChoice(mode: .desktop, displayId: nil) : choice
    let title = game.map { DLf("deck.resumeApp", $0.name ?? "") } ?? DeckConnect.primaryLabel(shown, host: host, model: model)
    let nothingToStart = game == nil && model.connectPlan.target == .none
    VStack(alignment: .leading, spacing: 8) {
    // the buttons wrap onto a second row when the column is narrow (a large page scale), never truncate
    DeckFlowLayout(spacing: 10) {
      primary(title: model.launching ? DL("deck.connecting") : title, choice: shown)
      if model.launching {
        secondary(DL("deck.cancelConnect"), symbol: "xmark") { model.actions.cancelLaunch?() }
      }
      if let game {
        secondary(DL("deck.quit"), symbol: "xmark") { model.quitApp(game) }
        // 连接桌面 while an app runs: the host keeps one app, so this asks to quit the running one first (the help
        // line says so); DeckConnectPlan.desktopWhileRunning decides whether it is offered
        if DeckConnectPlan.desktopWhileRunning(plan: model.connectPlan, runningId: game.id) != nil {
          secondary(DL("deck.connectDesktop"), symbol: "display", help: DLf("deck.desktopWhileRunning", game.name ?? "")) {
            DeckConnect.connect(DeckConnectChoice(mode: .desktop, displayId: nil), host: host, model: model)
          }
        }
      }
      if let big = model.bigScreenApp {
        secondary(DL("deck.mode.bigscreen"), symbol: "tv") {
          guard model.canStream else { NSSound.beep(); return }
          DeckConnectStore.set(host.id, DeckConnectChoice(mode: .bigscreen, displayId: nil))
          if host.isFoundation { model.actions.connect?("bigscreen", "") } else { model.openApp(big) }
        }
      }
      DeckHeroRound(symbol: "slider.horizontal.3", help: DL("deck.settings"), onDark: hero, size: height) { model.actions.settings?() }
      DeckHeroRound(symbol: "ellipsis", help: DL("deck.more"), onDark: hero, size: height, padMenu: { DeckMoreMenu.menu(host, model) }) { DeckMenuPresenter.pop(DeckMoreMenu.menu(host, model)) }
    }
    if nothingToStart {
      Text(DL("deck.noApps")).font(.system(size: 12)).foregroundStyle(hero ? Color.white.opacity(0.8) : Color.secondary)
    }
    }
    // B while a connection is being made cancels it, as 取消 does
    .controllerBackAction(active: model.launching) { model.actions.cancelLaunch?() }
  }

  @ViewBuilder
  private func primary(title: String, choice: DeckConnectChoice) -> some View {
    let action: () -> Void = {
      if model.launching { return }
      if let game { model.openApp(game) } else { DeckConnect.connect(choice, host: host, model: model) }
    }
    let icon = Group {
      if model.launching { ProgressView().controlSize(.small) } else { Image(systemName: "play.fill") }
    }
    if hero {
      Button(action: action) { Label { Text(title) } icon: { icon }.lineLimit(1) }
        .controllerButtonStyle(DeckHeroPrimaryStyle())
        .controllerKey("primary")
        .disabled(game == nil && model.connectPlan.target == .none)
    } else {
      Button(action: action) { Label { Text(title) } icon: { icon } }
        .controllerButtonStyle(DeckCardButtonStyle(prominent: true, height: height))
        .controllerKey("primary")
        .disabled(game == nil && model.connectPlan.target == .none)
    }
  }

  @ViewBuilder
  private func secondary(_ title: String, symbol: String, help: String? = nil, action: @escaping () -> Void) -> some View {
    Group {
      if hero {
        Button(action: action) {
          Label(title, systemImage: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
            .padding(.horizontal, 20).frame(height: height).deckGlass(Capsule()).contentShape(Capsule())
        }
        .controllerButtonStyle(.plain)
      } else {
        Button(action: action) { Label(title, systemImage: symbol) }
          .controllerButtonStyle(DeckCardButtonStyle(height: height))
      }
    }
    .controllerKey("secondary:\(symbol)")
    .help(help ?? "")
  }
}

// MARK: - 线路 chips

/// A wrapping row layout.
@available(macOS 13.0, *)
struct DeckFlowLayout: Layout {
  var spacing: CGFloat = 8

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    layout(in: proposal.width ?? 600, subviews: subviews).size
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let result = layout(in: bounds.width, subviews: subviews)
    for (index, point) in result.points.enumerated() {
      // every item sits on the centre line of its row, so a taller and a shorter button never end up top-aligned
      subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y + result.offsets[index]),
                            proposal: .unspecified)
    }
  }

  private func layout(in width: CGFloat, subviews: Subviews) -> (size: CGSize, points: [CGPoint], offsets: [CGFloat]) {
    var points: [CGPoint] = []
    var heights: [CGFloat] = []
    var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
    var rowOfItem: [Int] = []
    var rows: [CGFloat] = []
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if x > 0, x + size.width > width { rows.append(rowHeight); x = 0; y += rowHeight + spacing; rowHeight = 0 }
      points.append(CGPoint(x: x, y: y))
      heights.append(size.height)
      rowOfItem.append(rows.count)
      x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
      widest = max(widest, x - spacing)
    }
    rows.append(rowHeight)
    let offsets = heights.enumerated().map { (rows[rowOfItem[$0.offset]] - $0.element) / 2 }
    return (CGSize(width: widest, height: y + rowHeight), points, offsets)
  }
}

/// The 线路 row: one chip per distinct PATH the provider knows (自动 first; the .local name and the LAN address
/// are one path), each with its result: 「· 12 ms」, 「· 超时」 or 「· 测试中…」. The pinned one is filled; while 自动
/// is on, the one the stream takes carries 使用中. A path that timed out is greyed out and cannot be chosen
/// (tooltip 无响应); when the computer is off every chip is disabled except the pinned one, which shows its
/// last result. Clicking pins that path for this computer; 自动 unpins it (the same pin as 默认 in 地址).
@available(macOS 14.0, *)
struct DeckPathChips: View {
  let host: DeckHost
  @ObservedObject var model: DeckAppsModel
  var onDark = false
  /// the section the chips show: 线路 ("route") or 网卡 ("nic", same look, its own label)
  var sectionID = "route"
  var labelKey = "deck.route"
  @SwiftUI.State private var tick = 0

  private var items: [DeckConnectMenuItem] {
    let sections = DeckConnectMenuRegistry.sections(for: host)
    // a provider's own 线路 section wins over the local fallback
    let section = sections.first { $0.id == sectionID } ?? (sectionID == "route" ? sections.first { $0.id == "route.local" } : nil)
    return section?.items ?? []
  }

  var body: some View {
    let _ = tick
    let list = items
    if list.count > 1 {
      // the label sits beside the first row; every row of chips starts at the left edge of the first chip
      HStack(alignment: .top, spacing: 8) {
        Text(DL(labelKey)).font(.system(size: 12, weight: .semibold)).foregroundStyle(onDark ? .white.opacity(0.8) : .secondary)
          .frame(height: 26)
        DeckFlowLayout(spacing: 6) {
          ForEach(list) { item in chip(item) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      // while a row is the remembered one (or the answers are out) look again now and then: the hold ends by the clock, not by a notification
      .task(id: list.contains { $0.pending }) {
        guard list.contains(where: { $0.pending }) else { return }
        while !Task.isCancelled {
          try? await Task.sleep(nanoseconds: 700_000_000)
          if !Task.isCancelled { tick += 1 }
        }
      }
      // an automatic switch of address shows here and nowhere else: the 使用中 mark moves, softly. A new latency or a
      // result is not animated (a chip changes only when its value really changes, and the rest stays still)
      .animation(.easeInOut(duration: 0.3), value: list.map { "\($0.id)\($0.inUse)\($0.selected)" })
      .onReceive(NotificationCenter.default.publisher(for: DeckConnectMenuRegistry.didChange)) { _ in tick += 1 }
      .onReceive(NotificationCenter.default.publisher(for: .deckAddressChanged)) { _ in tick += 1 }
      .onReceive(NotificationCenter.default.publisher(for: .init("HostLatencyUpdated"))) { _ in tick += 1 }
      .onReceive(NotificationCenter.default.publisher(for: .init("HostAutoAddressSwitched"))) { _ in tick += 1 }
      // an address added, removed or declared (添加连接方式): the chips follow at once, and the new address is probed now
      .onReceive(NotificationCenter.default.publisher(for: .init("ConnectionEndpointsUpdated"))) { _ in
        tick += 1
        DeckAddressModel.probeMissing(host, actions: model.actions)
      }
    }
  }

  private func chip(_ item: DeckConnectMenuItem) -> some View {
    let selected = item.selected
    // a 网卡 is chosen for the next stream, so it can be changed while the computer is off
    let blocked = !selected && (item.unreachable || (!host.online && sectionID == "route"))
    let fill: Color = selected ? Color.accentColor : (onDark ? Color.white.opacity(0.16) : Color.primary.opacity(0.07))
    let text: Color = selected ? .white : (onDark ? .white : .primary)
    return Button { if !blocked { item.action() } } label: {
      HStack(spacing: 5) {
        if let symbol = item.symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
        Text(item.title).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
        if item.testing {
          ProgressView().controlSize(.mini)
          Text(DL("deck.path.testing")).font(.system(size: 11)).opacity(0.8)
        } else if item.unreachable {
          Text("· " + DL("deck.path.timeout")).font(.system(size: 11)).opacity(0.85)
        } else if let trailing = item.trailing {
          Text("· " + trailing).font(.system(size: 11)).opacity(0.85)
        }
        if let badge = item.badge {
          Text(badge).font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Color.orange.opacity(0.22), in: Capsule())
            .foregroundStyle(onDark ? Color.orange.opacity(0.95) : Color.orange)
        }
        if item.inUse && !item.unreachable {
          Text(DL("deck.path.inUse")).font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background((selected ? Color.white.opacity(0.25) : Color.green.opacity(0.18)), in: Capsule())
            .foregroundStyle(selected ? Color.white : Color.green)
        }
      }
      .foregroundStyle(text)
      .padding(.horizontal, 10).padding(.vertical, 5)
      .background(fill, in: Capsule())
      .opacity(blocked ? 0.4 : 1)
      // a row still being checked: one small mark in the corner, nothing in the layout moves
      .overlay(alignment: .topTrailing) {
        if item.pending { DeckPendingDot(onDark: onDark).offset(x: -2, y: 3) }
      }
    }
    .controllerButtonStyle(.plain)
    .disabled(blocked)
    .deckTouchTarget()
    .deckHelp(blocked ? (item.unreachable ? DL("deck.addr.noAnswer") : DL("deck.path.offlineChip")) : (item.tooltip ?? (selected ? DL("deck.path.pinned") : DL("deck.path.pin"))))
  }
}

/// The 网卡 row: 自动 and one chip per interface of this Mac; the chosen one is where every stream socket of this computer is bound.
@available(macOS 14.0, *)
struct DeckNicChips: View {
  let host: DeckHost
  @ObservedObject var model: DeckAppsModel
  var onDark = false

  var body: some View {
    DeckPathChips(host: host, model: model, onDark: onDark, sectionID: "nic", labelKey: "deck.nic")
  }
}

/// The mark of a 线路 chip that is still being checked: a 4 pt dot that breathes. It sits in the chip's corner and takes no room.
@available(macOS 14.0, *)
struct DeckPendingDot: View {
  var onDark = false
  @SwiftUI.State private var dim = false

  var body: some View {
    Circle().fill(onDark ? Color.white : Color.secondary).frame(width: 4, height: 4)
      .opacity(dim ? 0.25 : 0.8)
      .onAppear { withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { dim = true } }
      .allowsHitTesting(false)
  }
}
