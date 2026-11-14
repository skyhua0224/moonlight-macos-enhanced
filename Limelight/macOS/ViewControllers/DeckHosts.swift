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

@available(macOS 14.0, *)
final class DeckHostsModel: ObservableObject {
  @Published var hosts: [DeckHost] = []
  @Published var filter = ""
  @Published var pins: [String: String] = [:]
  @Published var selected: String?
  @Published var iconPickerHost: String?
  private var pickerObserver: NSObjectProtocol?
  var provider: () -> [TemporaryHost] = { [] }
  let actions: DeckHostsActions

  init(actions: DeckHostsActions) {
    self.actions = actions
    pickerObserver = NotificationCenter.default.addObserver(forName: .init("MLDeckIconPicker"), object: nil, queue: .main) { [weak self] note in
      self?.iconPickerHost = note.userInfo?["uuid"] as? String
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

@available(macOS 14.0, *)
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
  @available(macOS 14.0, *) @ViewBuilder func deckProminent() -> some View {
    if #available(macOS 26.0, *) { controllerButtonStyle(.glassProminent).buttonBorderShape(.capsule) } else { controllerButtonStyle(.borderedProminent).buttonBorderShape(.capsule) }
  }
  @available(macOS 14.0, *) @ViewBuilder func deckSecondary() -> some View {
    if #available(macOS 26.0, *) { controllerButtonStyle(.glass).buttonBorderShape(.capsule) } else { controllerButtonStyle(.bordered).buttonBorderShape(.capsule) }
  }
}

@available(macOS 14.0, *)
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

@available(macOS 14.0, *)
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

@available(macOS 14.0, *)
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

@available(macOS 14.0, *)
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

