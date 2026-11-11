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

