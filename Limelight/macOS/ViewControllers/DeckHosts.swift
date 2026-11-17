//
//  DeckHosts.swift
//  Host selection, in two shapes that share one model: rich cards (variant B) and a
//  sidebar list plus a state pane (variant A).
//

import AppKit
import SwiftUI

// MARK: - Actions and model

/// What the pages ask the owner of the host list to do. Set from Objective-C.
@objc(MLDeckHostsActions)
public final class DeckHostsActions: NSObject {
  @objc public var open: ((TemporaryHost) -> Void)?
  @objc public var resume: ((TemporaryHost, TemporaryApp) -> Void)?
  @objc public var wake: ((TemporaryHost) -> Void)?
  @objc public var pair: ((TemporaryHost) -> Void)?
  @objc public var select: ((TemporaryHost) -> Void)?
  /// "rename", "details", "editor", "settings", "sleep", "showHidden", "remove"
  @objc public var menu: ((TemporaryHost, String) -> Void)?
  @objc public var cleanup: (([TemporaryHost]) -> Void)?
  @objc public var add: (() -> Void)?
  @objc public var resumeApp: ((TemporaryHost, TemporaryApp) -> Void)?
  @objc public var quitApp: ((TemporaryHost, TemporaryApp) -> Void)?
}

final class DeckHostsModel: ObservableObject {
  @Published var hosts: [DeckHost] = []
  @Published var filter = ""
  @Published var pins: [String: String] = [:]
  @Published var selected: String?
  @Published var iconPickerHost: String?
  /// The computer that has just arrived from the no-host page (HostsViewController posts MLDeckHostArrived once its home is up): its icon pulses once.
  @Published var arrivedID: String?
  @Published var arrivedToken = 0
  private var pickerObserver: NSObjectProtocol?
  private var arrivedObserver: NSObjectProtocol?
  private var arrivalRecorder: NSObjectProtocol?
  var provider: () -> [TemporaryHost] = { [] }
  let actions: DeckHostsActions

  init(actions: DeckHostsActions) {
    self.actions = actions
    pickerObserver = NotificationCenter.default.addObserver(forName: .init("MLDeckIconPicker"), object: nil, queue: .main) { [weak self] note in
      self?.iconPickerHost = note.userInfo?["uuid"] as? String
    }
    arrivedObserver = NotificationCenter.default.addObserver(forName: .init("MLDeckHostArrived"), object: nil, queue: .main) { [weak self] note in
      guard let self else { return }
      self.arrivedID = note.userInfo?["uuid"] as? String
      self.arrivedToken += 1
    }
    arrivalRecorder = NotificationCenter.default.addObserver(forName: .init("MLDeckHostArrived"), object: nil, queue: .main) { note in
      DeckArrival.latest = ((note.userInfo?["uuid"] as? String) ?? "", Date())
    }
    // LB / RB: the previous / next computer in the order the sidebar shows them
    padObserver = NotificationCenter.default.addObserver(forName: .init("MLDeckPadSwitchHost"), object: nil, queue: .main) { [weak self] note in
      self?.stepSelection(by: (note.userInfo?["delta"] as? Int) ?? 1)
    }
  }

  private var padObserver: NSObjectProtocol?

  /// The Menu button on the page where nothing under the focus has a menu of its own: what the sidebar offers that the
  /// pad cannot reach there, 添加电脑 and 清理旧记录.
  func padPageMenu() -> (title: String, menu: NSMenu) {
    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.addItem(ControllerMenuBuilder.item(title: DL("deck.addHost")) { [weak self] in self?.actions.add?() })
    let old = stale
    if !old.isEmpty {
      menu.addItem(ControllerMenuBuilder.item(title: DLf("deck.cleanupCount", old.count)) { [weak self] in
        self?.actions.cleanup?(old.map { $0.raw })
      })
    }
    return (DL("deck.addHost"), menu)
  }

  /// The computers in sidebar order (online, nearby, offline), without the old records.
  var padOrder: [DeckHost] { ready + nearby + offline }

  func stepSelection(by delta: Int) {
    let order = padOrder
    guard let step = PadHostSwitch.step(order: order.map { $0.id }, selected: selected, delta: delta) else { return }
    if step.moved { selected = step.id }
    // the feedback names the computer now selected, also at either end of the list
    NotificationCenter.default.post(name: ControllerHostToast.notification, object: nil, userInfo: [
      "name": order[step.index].name, "index": step.index, "count": step.count,
    ])
  }

  /// A running app on any online host, shown as the now-playing accessory.
  var nowPlaying: (DeckHost, TemporaryApp)? {
    for host in hosts where host.online && !host.stale {
      if let app = host.app(id: host.runningAppId) { return (host, app) }
    }
    return nil
  }

  func reload() {
    hosts = DeckHostList.sorted(DeckHostList.build(provider()))
    for host in hosts { DeckFactsStore.noteReachability(uuid: host.id, state: host.state) }
    if selected == nil { selected = DeckHostList.preferred(hosts.filter { !$0.stale })?.id }
  }

  private func matches(_ host: DeckHost) -> Bool {
    filter.isEmpty || host.name.localizedCaseInsensitiveContains(filter)
  }

  private var live: [DeckHost] { hosts.filter { !$0.stale && matches($0) } }
  var ready: [DeckHost] { live.filter { $0.online && $0.paired } }
  var nearby: [DeckHost] { live.filter { $0.online && !$0.paired } }
  var offline: [DeckHost] { live.filter { !$0.online } }
  var stale: [DeckHost] { hosts.filter { $0.stale } }
  var hero: DeckHost? {
    guard filter.isEmpty else { return nil }
    return DeckHostList.preferred(hosts.filter { !$0.stale && $0.online && $0.paired })
  }
  var staleSummary: String {
    let names = Set(stale.map { $0.name })
    return names.count == 1 ? DLf("deck.staleNamed", names.first ?? "", stale.count) : DLf("deck.stale", stale.count)
  }
}

@objc(MLDeckHostsController)
public final class DeckHostsController: NSObject {
  let model: DeckHostsModel
  private let hosting: NSHostingController<AnyView>
  @objc public var viewController: NSViewController { hosting }

  /// style: "cards" (full page) or "sidebar" (host list for the split view).
  @objc public init(style: String, actions: DeckHostsActions, provider: @escaping () -> [TemporaryHost]) {
    let model = DeckHostsModel(actions: actions)
    model.provider = provider
    if style == "sidebar" {
      DeckLive.provider = provider
      ControllerFocusNavigator.pageMenu = { [weak model] in model?.padPageMenu() }
    }
    self.model = model
    if style == "sidebar" {
      hosting = NSHostingController(rootView: AnyView(DeckSidebarView(model: model)))
    } else {
      hosting = NSHostingController(rootView: AnyView(DeckHostsView(model: model)))
    }
    if #available(macOS 13.0, *) { hosting.sizingOptions = [] }
    super.init()
    model.reload()
  }

  @objc public func reload() { model.reload() }
  @objc public func setFilter(_ text: String) { model.filter = text }
  @objc public func setPairingPIN(_ pin: String?, forHostUUID uuid: String) {
    if let pin, !pin.isEmpty { model.pins[uuid] = pin } else { model.pins.removeValue(forKey: uuid) }
  }
  @objc public func select(hostUUID: String) { model.selected = hostUUID }
  /// The host the window should open on: the last one used that is online and paired.
  @objc public var preferredHost: TemporaryHost? {
    DeckHostList.preferred(model.hosts.filter { !$0.stale })?.raw
  }
  @objc public func hostState(forUUID uuid: String) -> Int {
    guard let host = model.hosts.first(where: { $0.id == uuid }) else { return 0 }
    if host.online && host.paired { return 2 }
    return host.online ? 1 : 0
  }
}

// MARK: - Shared bits

extension View {
  @ViewBuilder func deckProminent() -> some View {
    if #available(macOS 26.0, *), DeckOS.level >= 26 { controllerButtonStyle(.glassProminent).buttonBorderShape(.capsule) } else { controllerButtonStyle(.borderedProminent).deckCapsuleBorder() }
  }
  @ViewBuilder func deckSecondary() -> some View {
    if #available(macOS 26.0, *), DeckOS.level >= 26 { controllerButtonStyle(.glass).buttonBorderShape(.capsule) } else { controllerButtonStyle(.bordered).deckCapsuleBorder() }
  }
}

struct DeckPinView: View {
  let pin: String
  let hostName: String

  var body: some View {
    HStack(spacing: 14) {
      Text(pin.map(String.init).joined(separator: " "))
        .font(.system(size: 26, weight: .bold, design: .monospaced))
        .foregroundStyle(.orange)
      VStack(alignment: .leading, spacing: 4) {
        Text(DLf("deck.pinEnter", hostName)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        ProgressView().controlSize(.small)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }
}

func deckSubtitle(_ host: DeckHost, withRoute: Bool = true) -> String {
  if host.online {
    if !host.paired || !withRoute { return host.address ?? DL("deck.unpaired") }
    // reachability only: "局域网 · 2 ms", or what is running; no codec, no HDR
    if let id = host.runningAppId, let app = host.app(id: id)?.name, !app.isEmpty { return DLf("deck.runningApp", app) }
    var parts: [String] = []
    if let word = DeckAddressModel.activeWord(host) { parts.append(word) }
    if let rtt = host.rtt { parts.append("\(rtt) ms") } else if parts.isEmpty { parts.append(host.address ?? "") }
    return parts.joined(separator: " · ")
  }
  if let when = DeckTime.relative(host.facts.lastSeen ?? host.facts.lastConnected) {
    return DLf("deck.lastOnline", when)
  }
  return DL("deck.neverConnected")
}

// MARK: - Variant B: cards

struct DeckHostsView: View {
  @ObservedObject var model: DeckHostsModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 28) {
        if let hero = model.hero { DeckHostHero(host: hero, model: model) }
        grid(title: DL("deck.online"), hosts: model.ready.filter { $0.id != model.hero?.id })
        grid(title: DL("deck.nearby"), hosts: model.nearby)
        grid(title: DL("deck.offline"), hosts: model.offline)
        if !model.stale.isEmpty { DeckStaleSection(model: model) }
      }
      .padding(.horizontal, 32)
      .padding(.vertical, 26)
      .frame(maxWidth: 1180)
      .frame(maxWidth: .infinity)
    }
    .background(Color(nsColor: .windowBackgroundColor))
  }

  @ViewBuilder
  private func grid(title: String, hosts: [DeckHost]) -> some View {
    if !hosts.isEmpty {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 6) {
          Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
          Text("\(hosts.count)").font(.system(size: 12)).foregroundStyle(.tertiary)
        }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300, maximum: 460), spacing: 16)], spacing: 16) {
          ForEach(hosts) { DeckHostCard(host: $0, model: model) }
        }
      }
    }
  }
}

struct DeckHostHero: View {
  let host: DeckHost
  @ObservedObject var model: DeckHostsModel

  private var focusApp: TemporaryApp? { host.app(id: host.runningAppId ?? host.facts.lastApp) }
  private var recents: [TemporaryApp] { host.facts.recents.compactMap { host.app(id: $0) }.prefix(4).map { $0 } }

  var body: some View {
    HStack(alignment: .bottom, spacing: 24) {
        VStack(alignment: .leading, spacing: 14) {
          HStack(spacing: 14) {
            DeckGlyph(platform: host.platform, size: 56)
              .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
              Text(host.name).font(.system(size: 30, weight: .bold)).lineLimit(1)
              if let when = DeckTime.relative(host.facts.lastConnected) {
                Text(DLf("deck.lastStream", when)).font(.callout).foregroundStyle(.white.opacity(0.7))
              }
            }
          }
          DeckHostChips(host: host)
          if host.isFoundation && host.paired { DeckFsLabel(host: host, onDark: true) }
          HStack(spacing: 10) {
            if let app = focusApp {
              Button { model.actions.resume?(host.raw, app) } label: {
                Label(host.runningAppId != nil ? DLf("deck.resumeApp", app.name ?? "") : DLf("deck.playApp", app.name ?? ""),
                      systemImage: "play.fill").lineLimit(1)
              }
              .deckProminent()
            }
            Button { model.actions.open?(host.raw) } label: { Text(DL("deck.connect")) }
              .deckSecondary()
          }
          .controlSize(.large)
        }
        Spacer(minLength: 24)
        HStack(alignment: .bottom, spacing: 12) {
          ForEach(recents, id: \.id) { app in
            Button { model.actions.resume?(host.raw, app) } label: {
              DeckPoster(app: app, radius: 12)
                .frame(width: 92)
                .shadow(color: .black.opacity(0.4), radius: 10, y: 5)
            }
            .buttonStyle(.plain)
            .controllerFocusTarget { model.actions.resume?(host.raw, app) }
            .deckHelp(app.name ?? "")
          }
        }
      }
    .padding(26)
    .frame(maxWidth: .infinity, alignment: .leading)
    .frame(height: 224)
    .background { DeckHeroBackdrop(app: focusApp, tint: DeckLook.tint(host.platform)) }
    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
    .environment(\.colorScheme, .dark)
    .environment(\.deckChipsOnDark, true)
  }
}

struct DeckHostCard: View {
  let host: DeckHost
  @ObservedObject var model: DeckHostsModel
  @ObservedObject private var touch = DeckTouchState.shared
  @SwiftUI.State private var hovering = false

  private var cardMenu: (title: String, menu: NSMenu) {
    let menu = NSMenu()
    menu.autoenablesItems = false
    for (title, action) in [(DL("deck.menu.rename"), "rename"), (DL("deck.menu.details"), "details"), (DL("deck.menu.editor"), "editor"), (DL("deck.menu.settings"), "settings")] {
      menu.addItem(ControllerMenuBuilder.item(title: title) { model.actions.menu?(host.raw, action) })
    }
    if host.online && host.paired { menu.addItem(ControllerMenuBuilder.item(title: DL("deck.menu.sleep")) { model.actions.menu?(host.raw, "sleep") }) }
    menu.addItem(.separator())
    menu.addItem(ControllerMenuBuilder.item(title: DL("deck.menu.remove")) { model.actions.menu?(host.raw, "remove") })
    return (host.name, menu)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 12) {
        DeckGlyph(platform: host.platform, size: 44, muted: !host.online)
        VStack(alignment: .leading, spacing: 2) {
          Text(host.name).font(.headline).lineLimit(1)
          Text(deckSubtitle(host, withRoute: false)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        Spacer(minLength: 0)
        Menu {
          Button(DL("deck.menu.rename")) { model.actions.menu?(host.raw, "rename") }
          Button(DL("deck.menu.details")) { model.actions.menu?(host.raw, "details") }
          Button(DL("deck.menu.editor")) { model.actions.menu?(host.raw, "editor") }
          Button(DL("deck.menu.settings")) { model.actions.menu?(host.raw, "settings") }
          if host.online && host.paired { Button(DL("deck.menu.sleep")) { model.actions.menu?(host.raw, "sleep") } }
          Divider()
          Button(DL("deck.menu.remove"), role: .destructive) { model.actions.menu?(host.raw, "remove") }
        } label: {
          Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold)).frame(width: 26, height: 26)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .deckTouchTarget()
        .controllerFocusMenu(key: "card.more:\(host.id)") { cardMenu }
        .opacity(hovering || touch.hasTouch ? 1 : 0.55)
      }
      DeckHostChips(host: host, showStatus: false)
      if host.isFoundation && host.paired { DeckFsLabel(host: host) }
      Spacer(minLength: 0)
      footer
    }
    .padding(16)
    .controlSize(.large)
    .frame(height: 164)
    .deckCard(radius: 16, stroke: host.isNearbyUnpaired ? Color.orange.opacity(0.5) : Color(nsColor: .separatorColor).opacity(0.5))
    .overlay(alignment: .topTrailing) {
      if host.runningAppId != nil && host.online {
        DeckChip(text: DL("deck.running"), symbol: "play.fill", tint: .green, strong: true).padding(10).offset(x: 0, y: -22)
      }
    }
    .opacity(host.online ? 1 : 0.7)
    .offset(y: hovering ? -1 : 0)
    .shadow(color: .black.opacity(hovering ? 0.16 : 0.06), radius: hovering ? 14 : 5, y: hovering ? 6 : 2)
    .animation(.smooth(duration: 0.2), value: hovering)
    .onHover { hovering = $0 }
  }

  @ViewBuilder
  private var footer: some View {
    if let pin = model.pins[host.id] {
      DeckPinView(pin: pin, hostName: host.name)
    } else if host.online && host.paired {
      HStack {
        Button { model.actions.open?(host.raw) } label: { Text(DL("deck.connect")).frame(minWidth: 64) }
          .deckProminent()
        Spacer()
        Text(DLf("deck.appCount", host.appCount)).font(.caption).foregroundStyle(.secondary)
      }
    } else if host.online {
      HStack {
        Button { model.actions.pair?(host.raw) } label: { Text(DL("deck.pair")).frame(minWidth: 64) }
          .deckProminent()
        Spacer()
      }
    } else {
      HStack {
        Button { model.actions.wake?(host.raw) } label: { Label(DL("deck.wake"), systemImage: "power").frame(minWidth: 64) }
          .deckSecondary()
          .disabled(!host.canWake)
        Spacer()
        if !host.canWake { DeckChip(text: DL("deck.noMac"), tint: .gray) }
      }
    }
  }
}

struct DeckStaleSection: View {
  @ObservedObject var model: DeckHostsModel

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        Image(systemName: "square.on.square.dashed").font(.system(size: 18)).foregroundStyle(.secondary)
        Text(model.staleSummary).font(.system(size: 13, weight: .semibold))
        Spacer()
        Button(DL("deck.cleanup")) { model.actions.cleanup?(model.stale.map { $0.raw }) }.deckSecondary()
      }
      ForEach(model.stale) { host in
        HStack(spacing: 10) {
          DeckGlyph(platform: host.platform, size: 26, muted: true)
          Text(host.name).font(.callout)
          Text(host.address ?? "").font(.caption).foregroundStyle(.secondary)
          Spacer()
          Text(deckSubtitle(host)).font(.caption).foregroundStyle(.tertiary)
        }
      }
    }
    .padding(16)
    .deckCard(radius: 16)
  }
}

// MARK: - Variant A: sidebar and state pane

struct DeckSidebarView: View {
  @ObservedObject var model: DeckHostsModel

  var body: some View {
    VStack(spacing: 0) {
      DeckSearchField(text: $model.filter, placeholder: DL("deck.searchHosts"))
        .frame(height: 24)
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 4)

      List(selection: Binding(get: { model.selected }, set: { model.selected = $0 })) {
        section(DL("deck.online"), model.ready)
        section(DL("deck.nearby"), model.nearby)
        section(DL("deck.offline"), model.offline)
        if !model.stale.isEmpty {
          Section(DL("deck.staleTitle")) {
            ForEach(model.stale) { row($0).tag($0.id) }
            Button { model.actions.cleanup?(model.stale.map { $0.raw }) } label: {
              Label(DLf("deck.cleanupCount", model.stale.count), systemImage: "trash")
                .font(.system(size: 12, weight: .medium))
            }
            .controllerButtonStyle(.plain)
            .controllerKey("cleanup")
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)
          }
        }
      }
      .listStyle(.sidebar)
      .deckListBackgroundHidden()
      .deckOnChange(of: model.selected) { _, uuid in
        if let uuid, let host = model.hosts.first(where: { $0.id == uuid }) { model.actions.select?(host.raw) }
      }

      Button { model.actions.add?() } label: {
        Label(DL("deck.addHost"), systemImage: "plus").font(.system(size: 13, weight: .medium))
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .buttonStyle(.borderless)
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      .controllerFocusTarget(key: "add") { model.actions.add?() }
    }
    .frame(minWidth: 230)
    // the system sidebar material, so the sidebar keeps its vibrancy and stays readable over any desktop,
    // active or not; every label inside uses the semantic colours
    // one material from the very top edge (the traffic-light zone included) to the bottom: the background
    // ignores the titlebar inset, so the strip behind the traffic lights is not a different tint
    .background(DeckSidebarMaterial().ignoresSafeArea())
  }

  @ViewBuilder
  private func section(_ title: String, _ hosts: [DeckHost]) -> some View {
    if !hosts.isEmpty {
      Section(title) { ForEach(hosts) { row($0).tag($0.id) } }
    }
  }

  /// The row's context menu for the pad (the Menu button), the same items as the pointer's.
  private func padMenu(_ host: DeckHost) -> (title: String, menu: NSMenu) {
    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.addItem(ControllerMenuBuilder.item(title: DL("deck.changeIcon")) { model.iconPickerHost = host.id })
    if host.canWake && !host.online { menu.addItem(ControllerMenuBuilder.item(title: DL("deck.wake")) { model.actions.wake?(host.raw) }) }
    menu.addItem(ControllerMenuBuilder.item(title: DL("deck.menu.rename")) { model.actions.menu?(host.raw, "rename") })
    menu.addItem(ControllerMenuBuilder.item(title: DL("deck.menu.details")) { model.actions.menu?(host.raw, "details") })
    menu.addItem(.separator())
    menu.addItem(ControllerMenuBuilder.item(title: DL("deck.menu.remove")) { model.actions.menu?(host.raw, "remove") })
    return (host.name, menu)
  }

  private func row(_ host: DeckHost) -> some View {
    // the selected row: its icon is set off from the selection and its marks carry no backplate (see DeckHostIcon, DeckRowBadge)
    let selected = model.selected == host.id
    return HStack(spacing: 10) {
      DeckHostIcon(host: host, size: 32, muted: !host.online, selected: selected)
        .modifier(DeckArrivalMark(token: model.arrivedID == host.id && host.paired ? model.arrivedToken : 0))
      VStack(alignment: .leading, spacing: 1) {
        Text(host.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
        Text(deckSubtitle(host)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer(minLength: 0)
      if host.isFoundation { DeckFsMark(host: host) }
      if host.online && host.runningAppId != nil {
        DeckRowBadge(symbol: "play.circle.fill", tint: .green, onAccent: selected)
      } else if host.isNearbyUnpaired {
        DeckRowBadge(symbol: "link.badge.plus", tint: .orange, onAccent: selected)
      }
    }
    .padding(.vertical, 3)
    .controllerContextMenu { padMenu(host) }
    .controllerBackAction(active: model.iconPickerHost == host.id) { model.iconPickerHost = nil }
    .opacity(host.online || model.selected == host.id ? 1 : 0.62)
    .popover(isPresented: Binding(get: { model.iconPickerHost == host.id }, set: { if !$0 { model.iconPickerHost = nil } }),
             arrowEdge: .trailing) {
      DeckIconPicker(host: host) { model.reload() }
        .deckPopoverContent()
    }
    .contextMenu {
      Button(DL("deck.changeIcon")) { model.iconPickerHost = host.id }
      if host.canWake && !host.online { Button(DL("deck.wake")) { model.actions.wake?(host.raw) } }
      Button(DL("deck.menu.rename")) { model.actions.menu?(host.raw, "rename") }
      Button(DL("deck.menu.details")) { model.actions.menu?(host.raw, "details") }
      Divider()
      Button(DL("deck.menu.remove"), role: .destructive) { model.actions.menu?(host.raw, "remove") }
    }
  }
}

/// Shown in the content area for a host that has no apps page yet: unpaired or offline.
struct DeckHostStatePane: View {
  let host: DeckHost
  let pin: String?
  let onPair: () -> Void
  let onWake: () -> Void

  var body: some View {
    ScrollView {
      VStack(spacing: 22) {
        if DeckVariant.isPolished {
          DeckHostIcon(host: host, size: 88, muted: !host.online)
        } else {
          DeckGlyph(platform: host.platform, size: 88, muted: !host.online)
        }
        VStack(spacing: 10) {
          Text(host.name).font(.system(size: 30, weight: .bold))
          if DeckVariant.isPolished {
            Text(host.online ? (host.paired ? deckStatusLine(host) : DL("deck.unpaired")) : DL("deck.offline"))
              .font(.system(size: 14)).foregroundStyle(.secondary)
          } else {
            DeckHostChips(host: host)
          }
        }
        VStack(spacing: 0) {
          fact(DL("deck.fact.address"), host.address ?? "—")
          Divider()
          fact(DL("deck.fact.route"), routeText)
          Divider()
          if let when = DeckTime.relative(host.online ? host.facts.lastConnected : (host.facts.lastSeen ?? host.facts.lastConnected)) {
            fact(host.online ? DL("deck.fact.lastStream") : DL("deck.fact.lastOnline"), when)
            Divider()
          }
          fact(DL("deck.fact.codecs"), deckCapabilityText(host))
        }
        .padding(.horizontal, 14)
        .deckCard(radius: 12)
        if let pin {
          DeckPinView(pin: pin, hostName: host.name)
        } else if host.online {
          Button(action: onPair) { Text(DL("deck.pair")).frame(minWidth: 120) }.deckProminent().controlSize(.large)
        } else {
          Button(action: onWake) { Label(DL("deck.wake"), systemImage: "power").frame(minWidth: 120) }
            .deckProminent().controlSize(.large).disabled(!host.canWake)
          if !host.canWake { DeckChip(text: DL("deck.noMac"), tint: .gray) }
        }
      }
      .frame(maxWidth: 440)
      .padding(.vertical, 48)
      .frame(maxWidth: .infinity)
    }
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private var routeText: String {
    switch host.route {
    case .lan: return DL("deck.lan")
    case .remote: return DL("deck.remote")
    case .unknown: return "—"
    }
  }

  private func fact(_ label: String, _ value: String) -> some View {
    HStack {
      Text(label)
      Spacer()
      Text(value).foregroundStyle(.secondary)
    }
    .font(.system(size: 13))
    .padding(.vertical, 10)
  }
}

@objc(MLDeckStatePaneFactory)
public final class DeckStatePaneFactory: NSObject {
  @objc public static func make(host: TemporaryHost, pin: String?, onPair: @escaping () -> Void, onWake: @escaping () -> Void) -> NSViewController {
    NSHostingController(rootView: DeckHostStatePane(host: DeckHost(host), pin: pin, onPair: onPair, onWake: onWake))
  }
}

/// The standard AppKit search field.
struct DeckSearchField: NSViewRepresentable {
  @Binding var text: String
  let placeholder: String

  func makeNSView(context: Context) -> NSSearchField {
    let field = NSSearchField()
    field.placeholderString = placeholder
    field.delegate = context.coordinator
    field.controlSize = .regular
    return field
  }

  func updateNSView(_ field: NSSearchField, context: Context) {
    if field.stringValue != text { field.stringValue = text }
  }

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  final class Coordinator: NSObject, NSSearchFieldDelegate {
    let parent: DeckSearchField
    init(_ parent: DeckSearchField) { self.parent = parent }
    func controlTextDidChange(_ notification: Notification) {
      if let field = notification.object as? NSSearchField { parent.text = field.stringValue }
    }
  }
}

/// The standard sidebar material (what Finder, Music and TV use), following the window's active state.
struct DeckSidebarMaterial: NSViewRepresentable {
  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = .sidebar
    view.blendingMode = .behindWindow
    view.state = .followsWindowActiveState
    return view
  }

  func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// One pulse on a sidebar icon when its computer has just arrived from the no-host page: the icon grows a little and settles back with a spring,
/// and a ring leaves it and fades. Increase Contrast: a thicker, solid ring. Reduce Motion: only the ring's fade, the icon does not move.
@available(macOS 14.0, *)
struct DeckArrivalMark: ViewModifier {
  let token: Int
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorSchemeContrast) private var contrast

  struct Pulse {
    var scale = 1.0
    var ring = 0.0
  }

  func body(content: Content) -> some View {
    let still = reduceMotion || NoHostCaps.forceReduceMotion
    let strong = contrast == .increased
    return content.keyframeAnimator(initialValue: Pulse(), trigger: token) { view, pulse in
      view
        .scaleEffect(pulse.scale)
        .overlay(
          Circle()
            .strokeBorder(Color.primary.opacity(strong ? 1 : 0.6), lineWidth: strong ? 3 : 2)
            .scaleEffect(1 + (1 - pulse.ring) * (still ? 0 : 0.5))
            .opacity(pulse.ring)
            .allowsHitTesting(false)
        )
    } keyframes: { _ in
      KeyframeTrack(\.scale) {
        CubicKeyframe(still ? 1 : 1.24, duration: 0.14)
        SpringKeyframe(1, duration: 0.55, spring: .bouncy)
      }
      KeyframeTrack(\.ring) {
        LinearKeyframe(1, duration: 0.05)
        CubicKeyframe(0, duration: 0.85)
      }
    }
  }
}

/// One nudge on the 配对 button when an unpaired computer has just arrived from the no-host page (HostsViewController posts MLDeckHostArrived
/// once its home is up): the button grows a little and settles with a spring, and a ring leaves it and fades, so the eye goes to the one thing
/// to do. Increase Contrast: a thicker, solid ring. Reduce Motion: only the ring's fade, the button does not move.
@available(macOS 14.0, *)
struct DeckPairNudge: ViewModifier {
  let hostID: String
  @SwiftUI.State private var token = 0
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorSchemeContrast) private var contrast

  struct Pulse {
    var scale = 1.0
    var ring = 0.0
  }

  func body(content: Content) -> some View {
    let still = reduceMotion || NoHostCaps.forceReduceMotion
    let strong = contrast == .increased
    return content
      .keyframeAnimator(initialValue: Pulse(), trigger: token) { view, pulse in
        view
          .scaleEffect(pulse.scale)
          .overlay(
            Capsule()
              .strokeBorder(Color.white.opacity(strong ? 1 : 0.9), lineWidth: strong ? 4 : 3)
              .scaleEffect(x: 1 + (1 - pulse.ring) * (still ? 0 : 0.26), y: 1 + (1 - pulse.ring) * (still ? 0 : 0.7))
              .opacity(pulse.ring)
              .allowsHitTesting(false)
          )
      } keyframes: { _ in
        KeyframeTrack(\.scale) {
          CubicKeyframe(still ? 1 : 1.1, duration: 0.16)
          SpringKeyframe(1, duration: 0.6, spring: .bouncy)
        }
        KeyframeTrack(\.ring) {
          LinearKeyframe(1, duration: 0.05)
          CubicKeyframe(0.6, duration: 0.3)
          LinearKeyframe(0, duration: 0.7)
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("MLDeckHostArrived"))) { note in
        if (note.userInfo?["uuid"] as? String) == hostID { token += 1 }
      }
      // the button may appear after the notification was posted: then the record of the arrival says it is still fresh
      .onAppear {
        if let arrival = DeckArrival.latest, arrival.id == hostID, Date().timeIntervalSince(arrival.at) < 1.2 { token += 1 }
      }
  }
}

/// The computer that arrived from the no-host page last, and when (set on MLDeckHostArrived).
enum DeckArrival {
  nonisolated(unsafe) static var latest: (id: String, at: Date)?
}
