//
//  DeckIcons.swift
//  Host icons: a Reminders-style coloured circle with an SF Symbol, or a picture. The user's
//  choice wins, then the icon the host reports (Foundation Sunshine), then the platform glyph.
//

import AppKit
import SwiftUI

enum DeckPalette {
  static let names = ["red", "orange", "yellow", "green", "teal", "blue", "indigo", "purple", "pink", "gray"]

  static func color(_ name: String) -> Color {
    switch name {
    case "red": return .red
    case "orange": return .orange
    case "yellow": return .yellow
    case "green": return .green
    case "teal": return .teal
    case "blue": return .blue
    case "indigo": return .indigo
    case "purple": return .purple
    case "pink": return .pink
    default: return .gray
    }
  }
}

enum DeckSymbols {
  static let all = [
    "desktopcomputer", "display", "laptopcomputer", "pc", "macmini.fill", "server.rack",
    "gamecontroller.fill", "tv.fill", "house.fill", "bed.double.fill", "sofa.fill", "briefcase.fill",
    "bolt.fill", "flame.fill", "moon.fill", "sun.max.fill", "star.fill", "heart.fill",
    "leaf.fill", "cloud.fill", "globe", "airplane", "car.fill", "graduationcap.fill",
    "paintbrush.fill", "film.fill", "music.note", "headphones", "cpu", "memorychip",
    "externaldrive.fill", "network", "wifi", "person.fill", "cube.fill", "sparkles",
  ]
}

struct DeckIconSpec {
  var symbol: String
  var colorName: String
  var image: NSImage?
  var custom: Bool

  static func platformDefault(_ platform: String) -> DeckIconSpec {
    switch platform {
    case "windows": return DeckIconSpec(symbol: "pc", colorName: "blue", image: nil, custom: false)
    case "macos": return DeckIconSpec(symbol: "macmini.fill", colorName: "purple", image: nil, custom: false)
    case "linux": return DeckIconSpec(symbol: "server.rack", colorName: "orange", image: nil, custom: false)
    default: return DeckIconSpec(symbol: "display", colorName: "gray", image: nil, custom: false)
    }
  }

  /// A plain Sunshine host does not say what it runs, and nothing honest in its answers does either
  /// (the app list and version strings are the same on Windows and Linux). So an unknown platform gets a
  /// neutral monitor glyph on a pleasant tint taken from a hash of the host's id: coloured, stable, and
  /// never claiming a platform.
  static func neutralTint(_ uuid: String) -> String {
    let tints = ["teal", "indigo", "pink", "green", "orange", "blue", "purple"]
    var hash: UInt32 = 5381
    for byte in uuid.utf8 { hash = (hash &* 33) &+ UInt32(byte) }
    return tints[Int(hash % UInt32(tints.count))]
  }

  static func resolve(uuid: String, facts: DeckFacts) -> DeckIconSpec {
    if let icon = facts.icon {
      if icon["image"] != nil, let image = NSImage(contentsOf: DeckFactsStore.iconImageURL(uuid)) {
        return DeckIconSpec(symbol: "", colorName: "gray", image: image, custom: true)
      }
      if let symbol = icon["symbol"] {
        return DeckIconSpec(symbol: symbol, colorName: icon["color"] ?? "blue", image: nil, custom: true)
      }
    }
    let parts = facts.hostIcon.split(separator: ":").map(String.init)
    if parts.count == 2 {
      return DeckIconSpec(symbol: parts[0], colorName: parts[1], image: nil, custom: false)
    }
    let platform = platformDefault(facts.platform)
    if platform.colorName == "gray" { return DeckIconSpec(symbol: platform.symbol, colorName: neutralTint(uuid), image: nil, custom: false) }
    return platform
  }
}

/// The icon in the sidebar and in headers.
struct DeckHostIcon: View {
  let host: DeckHost
  var size: CGFloat = 22
  var muted = false
  /// On the sidebar's selected row: the tile is set off from the selection (see DeckSelectionRules).
  var selected = false
  @Environment(\.colorScheme) private var scheme
  /// `.increased` on the accent fill of an emphasized selection; the grey selection of an unfocused list or inactive window is not.
  /// The fill the tile is judged against: the accent. (Whether the list is focused or the window active is not knowable from a row,
  /// and the lighter tile and the edge read on the grey selection as well.)
  private var selectionFill: NSColor { NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue }

  private func rgb(_ color: Color) -> DeckSelectionRules.RGB {
    let c = NSColor(color).usingColorSpace(.sRGB) ?? .gray
    return DeckSelectionRules.RGB(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent))
  }

  var body: some View {
    let spec = host.icon
    let color = DeckPalette.color(spec.colorName)
    let fill = selectionFill
    // lifted: the glyph and its tile are about the colour of the selection itself (a blue tile on the blue selection)
    let lifted = selected && spec.image == nil
      && DeckSelectionRules.needsLift(tint: rgb(color), selection: DeckSelectionRules.RGB(r: Double(fill.redComponent), g: Double(fill.greenComponent), b: Double(fill.blueComponent)))
    // light appearance on the accent fill: every colour gets a light tile (a green glyph on a green tile over blue selection
    // measured dark and muddy), `lifted` ones a lighter one still
    let onAccent = selected
    let lightTile = onAccent && scheme == .light && !lifted && spec.image == nil
    // The round-1 look: a light tile in the colour, the glyph in the same colour at full strength.
    // Offline and old records keep their hue, desaturated.
    ZStack {
      if lifted { Color.white.opacity(0.94) } else if lightTile { Color.white.opacity(0.74) }
      if let image = spec.image {
        Image(nsImage: image).resizable().scaledToFill()
      } else {
        color.opacity(0.16)
        Image(systemName: spec.symbol)
          .font(.system(size: size * 0.5, weight: .medium))
          .foregroundStyle(color)
      }
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
    .saturation(muted ? 0.35 : 1)
    .opacity(muted ? 0.8 : 1)
  }
}

/// Small popover in the style of the Reminders / Shortcuts list icon picker: a preview, a row of
/// colours, a grid of symbols, and a way to use a picture or go back to the default.
@available(macOS 14.0, *)
struct DeckIconPicker: View {
  let host: DeckHost
  let onChange: () -> Void
  @SwiftUI.State private var symbol: String
  @SwiftUI.State private var color: String

  init(host: DeckHost, onChange: @escaping () -> Void) {
    self.host = host
    self.onChange = onChange
    let spec = host.icon
    _symbol = SwiftUI.State(initialValue: spec.symbol.isEmpty ? "desktopcomputer" : spec.symbol)
    _color = SwiftUI.State(initialValue: spec.colorName)
  }

  var body: some View {
    VStack(spacing: 14) {
      DeckHostIcon(host: previewHost, size: 64)
        .shadow(color: .black.opacity(0.12), radius: 6, y: 3)

      HStack(spacing: 8) {
        ForEach(DeckPalette.names, id: \.self) { name in
          Button {
            color = name
            commit()
          } label: {
            Circle().fill(DeckPalette.color(name)).frame(width: 20, height: 20)
              .overlay(Circle().strokeBorder(Color.primary.opacity(color == name ? 0.7 : 0), lineWidth: 2).padding(-3))
          }
          .controllerButtonStyle(.plain)
          .deckTouchTarget()
        }
      }

      LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 6), count: 6), spacing: 6) {
        ForEach(DeckSymbols.all, id: \.self) { name in
          Button {
            symbol = name
            commit()
          } label: {
            Image(systemName: name).font(.system(size: 15)).frame(width: 34, height: 34)
              .background(Circle().fill(symbol == name ? Color.primary.opacity(0.14) : Color.clear))
          }
          .controllerButtonStyle(.plain)
        }
      }

      Divider()
      HStack {
        Button(DL("deck.icon.choose")) { choosePicture() }.controllerButtonStyle(.automatic)
        Spacer()
        Button(DL("deck.icon.reset")) {
          DeckFactsStore.clearIcon(uuid: host.id)
          onChange()
        }
        .controllerButtonStyle(.automatic)
        .disabled(!host.icon.custom)
      }
      .controlSize(.small)
    }
    .padding(16)
    .frame(width: 280)
  }

  /// The host as it would look with the current choice, for the preview.
  private var previewHost: DeckHost {
    var spec = host.icon
    spec.image = nil
    spec.symbol = symbol
    spec.colorName = color
    var copy = host
    copy.icon = spec
    return copy
  }

  private func commit() {
    DeckFactsStore.setIcon(uuid: host.id, symbol: symbol, color: color)
    onChange()
  }

  private func choosePicture() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.png, .jpeg, .heic]
    panel.allowsMultipleSelection = false
    if panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) {
      DeckFactsStore.setIconImage(uuid: host.id, data: data)
      onChange()
    }
  }
}

/// The big icon at the top of a host's page. Clicking it (or 更改图标… in its context menu) opens the icon
/// picker (SF Symbol and colour, or a picture), and the choice is the one the sidebar tile uses too. A
/// pencil badge shows on hover. The small icons in the info rows are plain system symbols and are not
/// editable.
@available(macOS 14.0, *)
struct DeckEditableHostIcon: View {
  let host: DeckHost
  @ObservedObject var model: DeckAppsModel
  @ObservedObject private var touch = DeckTouchState.shared
  let size: CGFloat
  @SwiftUI.State private var hovering = false
  @SwiftUI.State private var picking = false

  var body: some View {
    DeckHostIcon(host: host, size: size, muted: !host.online)
      .overlay(alignment: .bottomTrailing) {
        Image(systemName: "pencil").font(.system(size: max(9, size * 0.16), weight: .bold)).foregroundStyle(.white)
          .frame(width: max(18, size * 0.3), height: max(18, size * 0.3))
          .background(Circle().fill(Color.accentColor))
          .overlay(Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5))
          .offset(x: 5, y: 5)
          .opacity(hovering || picking || touch.hasTouch ? 1 : 0)
      }
      .contentShape(Rectangle())
      .onHover { hovering = $0 }
      .onTapGesture { picking = true }
      .controllerFocusTarget(key: "hostIcon", radius: size * 0.22) { picking = true }
      .controllerBackAction(active: picking) { picking = false }
      .deckHelp(DL("deck.changeIcon"))
      .accessibilityLabel(DL("deck.changeIcon"))
      .contextMenu { Button(DL("deck.changeIcon")) { picking = true } }
      .animation(.easeOut(duration: 0.12), value: hovering)
      .onReceive(NotificationCenter.default.publisher(for: .init("MLDeckPageIcon"))) { note in
        if (note.userInfo?["uuid"] as? String) == host.id { picking = true }
      }
      .onAppear {
        if conceptEnv("MLC_BIGICON") != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { picking = true } }
      }
      .popover(isPresented: $picking, arrowEdge: .bottom) {
        DeckIconPicker(host: host) {
          // the page and the sidebar read the choice from the same record
          model.host = DeckHost(host.raw)
          NotificationCenter.default.post(name: .init("MLDeckHostsChanged"), object: nil)
        }
        .deckPopoverContent()
      }
  }
}
