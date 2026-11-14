//
//  DeckApps.swift
//  The apps page of a host as a poster wall: a hero for the running or last-played app,
//  a sort switch, and a grid of large posters. Two arrangements share it: embedded beside
//  the host sidebar (variant A) and standalone with a host header (variant B).
//

import AppKit
import SwiftUI

@objc(MLDeckAppsActions)
public final class DeckAppsActions: NSObject {
  @objc public var open: ((TemporaryApp) -> Void)?
  @objc public var quit: ((TemporaryApp) -> Void)?
  @objc public var pin: ((TemporaryApp) -> Void)?
  @objc public var hide: ((TemporaryApp) -> Void)?
  @objc public var settings: (() -> Void)?
  /// 添加连接方式…: opens the existing 编辑连接 sheet of this computer (ConnectionEditorViewController).
  @objc public var addConnection: (() -> Void)?
  @objc public var wake: (() -> Void)?
  @objc public var pair: (() -> Void)?
  @objc public var cancelPair: (() -> Void)?
  /// 连接 with a mode: "desktop", "bigscreen", "vdd" or "display" (and the display's device id, "" if none).
  @objc public var connect: ((String, String) -> Void)?
  /// 取消 while a launch is pending (the page shows 正在连接… from the click on).
  @objc public var cancelLaunch: (() -> Void)?
  /// The displays the host lists (/displays): dictionaries with device_id, friendly_name, display_name.
  @objc public var displays: (() -> [[String: Any]])?
  /// The old app context menu (启动/继续, 固定, 隐藏, 退出, the Sunshine overrides, SuperCmds) as a real NSMenu.
  @objc public var appMenu: ((TemporaryApp) -> NSMenu)?
  /// The old host menu (唤醒, 休眠, 显示隐藏应用, 重命名, 移除, 设置, 连接详情, 编辑连接, overrides, SuperCmds).
  @objc public var hostMenu: ((TemporaryApp?) -> NSMenu)?
  /// The computer came online: load its apps.
  @objc public var hostBecameOnline: ((String) -> Void)?
  /// The address the user chose as the default way to reach a computer ("" = 自动), by host uuid.
  @objc public var defaultAddress: ((String) -> String)?
  /// Sets it (the client's per-host connection method); "" = 自动.
  @objc public var setDefaultAddress: ((String, String) -> Void)?
  /// Asks the address for its /serverinfo now (HTTP, the given timeout in seconds): milliseconds taken, or nil if nothing answered.
  @objc public var probeAddress: ((String, Double, @escaping (NSNumber?) -> Void) -> Void)?
}

@available(macOS 14.0, *)
final class DeckAppsModel: ObservableObject {
  enum Style { case embedded, standalone, games, computer, quiet }
  enum Sort: Hashable { case recent, name }

  let style: Style
  let actions: DeckAppsActions
  @Published var host: DeckHost? { didSet { cachedLibrary = nil } }
  @Published var apps: [TemporaryApp] = [] { didSet { cachedLibrary = nil } }
  /// 应用 sorted: worked out once per change of the app list, not on every layout pass.
  var cachedLibrary: [TemporaryApp]?
  @Published var runningId: String?
  /// A launch of this computer is pending (from the click on 连接 until its stream window is gone or the launch is
  /// cancelled): the connect button says 正在连接… and offers 取消; clicks on it are absorbed (MLLaunchGate).
  @Published var launching = false
  @Published var sort: Sort = .recent
  @Published var artVersion = 0
  /// Bumped when the host's display list (or its virtual-display capability) has been read.
  @Published var displaysVersion = 0
  @Published var selectedId: String?

  init(style: Style, actions: DeckAppsActions) {
    self.style = style
    self.actions = actions
    DeckAddressRouteProvider.shared.actions = actions
    DeckConnectMenuRegistry.register(DeckAddressRouteProvider.shared)
    DeckConnectMenuRegistry.register(DeckNicMenuProvider.shared)
    #if MLC_CONCEPT_HARNESS
    if conceptEnv("MLC_FAKE_ROUTES") != nil { DeckConnectMenuRegistry.register(DeckHarnessRouteProvider.shared) }
    #endif
    let center = NotificationCenter.default
    for name in ["HostLatencyUpdated", "MLDeckHostsChanged", "MLDeckAddressChanged"] {
      observers.append(center.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in self?.refreshHost() })
    }
    observers.append(center.addObserver(forName: .init("MLLaunchStateChanged"), object: nil, queue: .main) { [weak self] _ in
      guard let self else { return }
      self.launching = LaunchGateShared.isPending(self.host?.id ?? "")
    })
    // discovery can finish between notifications: look again now and then
    liveTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.refreshHost() }
  }

  private var observers: [NSObjectProtocol] = []
  private var liveTimer: Timer?

  deinit {
    liveTimer?.invalidate()
    observers.forEach { NotificationCenter.default.removeObserver($0) }
  }

  /// The page uses the state the sidebar uses: online, pairing, latency, address and running app are read
  /// from discovery's live computer, not from the snapshot taken when the page was made.
  func refreshHost() {
    guard let current = host else { return }
    let fresh = DeckHost(current.raw, live: DeckLive.host(current.id))
    DeckFactsStore.noteReachability(uuid: fresh.id, state: fresh.state)
    guard fresh.signature != current.signature else { return }
    host = fresh
    if fresh.verified && !current.verified { actions.hostBecameOnline?(fresh.id) }
  }

  var recents: [String] { host?.facts.recents ?? [] }

  /// A stream can start only on a computer that is on and paired. Every Deck entry that starts or quits one
  /// goes through openApp / quitApp / connect below, so a stray click, key or menu item on an off or
  /// not-yet-paired computer does nothing (the client's own openApp: refuses too).
  var canStream: Bool { host.map { $0.verified && $0.paired } ?? false }

  func openApp(_ app: TemporaryApp) {
    guard canStream else { NSSound.beep(); return }
    if launching { return }
    actions.open?(app)
  }

  func quitApp(_ app: TemporaryApp) {
    guard canStream else { NSSound.beep(); return }
    actions.quit?(app)
  }

  func lastRank(_ app: TemporaryApp) -> Int { recents.firstIndex(of: app.id ?? "") ?? Int.max }

  var items: [TemporaryApp] {
    apps.sorted { a, b in
      if a.pinned != b.pinned { return a.pinned }
      if sort == .recent {
        let (ra, rb) = (lastRank(a), lastRank(b))
        if ra != rb { return ra < rb }
      }
      return (a.name ?? "").localizedCaseInsensitiveCompare(b.name ?? "") == .orderedAscending
    }
  }

  var hero: TemporaryApp? {
    if let runningId, let app = apps.first(where: { $0.id == runningId }) { return app }
    if let last = host?.facts.lastApp, let app = apps.first(where: { $0.id == last }) { return app }
    return nil
  }
}

@available(macOS 14.0, *)
@objc(MLDeckAppsController)
public final class DeckAppsController: NSObject {
  let model: DeckAppsModel
  private let hosting: NSHostingController<DeckAppsRoot>
  @objc public var viewController: NSViewController { hosting }

  /// style: "embedded" (beside the sidebar) or "standalone" (own window).
  @objc public init(style: String, actions: DeckAppsActions) {
    let mapped: DeckAppsModel.Style
    switch style {
    case "standalone": mapped = .standalone
    case "games": mapped = .games
    case "computer": mapped = .computer
    case "quiet": mapped = .quiet
    default: mapped = .embedded
    }
    let model = DeckAppsModel(style: mapped, actions: actions)
    self.model = model
    hosting = NSHostingController(rootView: DeckAppsRoot(model: model))
    if #available(macOS 13.0, *) { hosting.sizingOptions = [] }
    super.init()
  }

  @objc public func update(host: TemporaryHost, apps: [TemporaryApp], running: TemporaryApp?) {
    let shown = DeckHost(host, live: DeckLive.host(host.uuid))
    DeckFactsStore.noteReachability(uuid: shown.id, state: shown.state)
    model.host = shown
    model.apps = apps
    model.runningId = running?.id
  }

  /// The display list was read from the host.
  @objc public func displaysChanged() { model.displaysVersion += 1 }

  /// Box art arrived on disk: forget the stale copy and redraw.
  /// A poster arrives twice (the preview, then the lossless picture). The new poster is decoded off the main
  /// thread and put in the cache before the tiles are told, so a tile keeps the picture it shows until the next one
  /// is ready: no empty frame, and the box does not change (the tile keeps its aspect).
  @objc public func artArrived(for app: TemporaryApp) {
    DeckArt.invalidate(app, except: .poster)
    let target = DeckArt.posterRefreshTarget(app)
    Task { @MainActor [model] in
      await DeckArt.refreshPoster(key: target.key, path: target.path)
      model.artVersion += 1
    }
  }
}

@available(macOS 14.0, *)
struct DeckAppsRoot: View {
  @ObservedObject var model: DeckAppsModel

  var body: some View {
    switch model.style {
    case .games: DeckGamesView(model: model)
    case .computer: DeckComputerView(model: model)
    case .quiet: DeckQuietView(model: model)
    default: DeckAppsView(model: model)
    }
  }
}

@available(macOS 14.0, *)
struct DeckAppsView: View {
  @ObservedObject var model: DeckAppsModel
  @SwiftUI.State private var width: CGFloat = 1000

  private var minTile: CGFloat { model.style == .standalone ? 172 : 152 }
  private let spacing: CGFloat = 24

  private var columns: Int {
    max(1, Int((width - 64 + spacing) / (minTile + spacing)))
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 26) {
        header
        if let app = model.hero { DeckAppHero(app: app, model: model) }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minTile, maximum: 260), spacing: spacing, alignment: .top)], spacing: 26) {
          ForEach(model.items, id: \.deckKey) { app in
            DeckAppTile(app: app, model: model)
          }
        }
      }
      .padding(.horizontal, 32)
      .padding(.top, 20)
      .padding(.bottom, 34)
      .frame(maxWidth: 1400)
      .frame(maxWidth: .infinity)
    }
    .background(GeometryReader { proxy in Color.clear.onAppear { width = proxy.size.width }.onChange(of: proxy.size.width) { _, new in width = new } })
    .background(Color(nsColor: .windowBackgroundColor))
    .focusable()
    .onMoveCommand { move($0) }
    .onKeyPress(.return) {
      if let id = model.selectedId, let app = model.items.first(where: { $0.id == id }) { model.openApp(app) }
      return .handled
    }
  }

  private func move(_ direction: MoveCommandDirection) {
    let items = model.items
    guard !items.isEmpty else { return }
    let current = items.firstIndex { $0.id == model.selectedId } ?? -1
    var next = current
    switch direction {
    case .left: next = max(0, current - 1)
    case .right: next = min(items.count - 1, current + 1)
    case .up: next = current < 0 ? 0 : max(0, current - columns)
    case .down: next = current < 0 ? 0 : min(items.count - 1, current + columns)
    @unknown default: break
    }
    model.selectedId = items[next].id
  }

  @ViewBuilder
  private var header: some View {
    HStack(alignment: .center, spacing: 16) {
      if model.style == .standalone, let host = model.host {
        DeckGlyph(platform: host.platform, size: 60, muted: !host.online)
        VStack(alignment: .leading, spacing: 8) {
          Text(host.name).font(.system(size: 28, weight: .bold)).lineLimit(1)
          DeckHostChips(host: host)
        }
      } else if let host = model.host {
        VStack(alignment: .leading, spacing: 8) {
          Text(host.name).font(.title2.weight(.semibold)).lineLimit(1)
          DeckHostChips(host: host, showStatus: false, showPlatform: false)
        }
      }
      Spacer(minLength: 12)
      Picker("", selection: $model.sort) {
        Text(DL("deck.sort.recent")).tag(DeckAppsModel.Sort.recent)
        Text(DL("deck.sort.name")).tag(DeckAppsModel.Sort.name)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(width: 150)
    }
  }
}

@available(macOS 14.0, *)
struct DeckAppHero: View {
  let app: TemporaryApp
  @ObservedObject var model: DeckAppsModel

  private var running: Bool { model.runningId == app.id }
  private var tall: Bool { model.style == .standalone }

  var body: some View {
    HStack(spacing: 24) {
        DeckPoster(app: app, version: model.artVersion, radius: 14)
          .frame(width: tall ? 124 : 98)
          .shadow(color: .black.opacity(0.45), radius: 14, y: 7)
        VStack(alignment: .leading, spacing: 10) {
          HStack(spacing: 6) {
            if app.hdrSupported { DeckChip(text: "HDR", tint: .pink) }
            if !running, let when = DeckTime.relative(model.host?.facts.lastConnected) {
              DeckChip(text: DLf("deck.lastStream", when), symbol: "clock", tint: .white)
            }
          }
          HStack(spacing: 0) {
            DeckRunningGlyph(running: running, size: tall ? 24 : 19, onDark: true)
            Text(app.name ?? "").font(.system(size: tall ? 32 : 26, weight: .bold)).lineLimit(2)
          }
          HStack(spacing: 10) {
            Button { model.openApp(app) } label: {
              Label(running ? DL("deck.resume") : DL("deck.play"), systemImage: "play.fill").frame(minWidth: 72)
            }
            .deckProminent()
            if running {
              Button { model.quitApp(app) } label: { Text(DL("deck.quit")) }.deckSecondary()
            }
          }
          .controlSize(.large)
        }
        Spacer(minLength: 0)
    }
    .padding(tall ? 26 : 20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .frame(height: tall ? 214 : 160)
    .background { DeckHeroBackdrop(app: app, tint: .accentColor, version: model.artVersion) }
    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    .shadow(color: .black.opacity(0.16), radius: 16, y: 7)
    .environment(\.colorScheme, .dark)
    .environment(\.deckChipsOnDark, true)
  }
}

@available(macOS 14.0, *)
struct DeckAppTile: View {
  let app: TemporaryApp
  @ObservedObject var model: DeckAppsModel
  @SwiftUI.State private var hovering = false

  private var running: Bool { model.runningId == app.id }
  private var selected: Bool { model.selectedId == app.id }

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      ZStack {
        DeckPoster(app: app, version: model.artVersion, radius: 16)
        VStack {
          HStack(alignment: .top, spacing: 5) {
            Spacer()
            if app.hdrSupported { DeckChip(text: "HDR", tint: .pink, strong: true) }
            if app.pinned {
              Image(systemName: "pin.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                .frame(width: 22, height: 22).deckGlass(Circle())
            }
          }
          Spacer()
        }
        .padding(9)
        if hovering {
          Image(systemName: "play.fill").font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
            .frame(width: 54, height: 54).deckGlass(Circle())
            .transition(.scale(scale: 0.85).combined(with: .opacity))
        }
      }
      .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
        .strokeBorder(Color.accentColor, lineWidth: selected && !running ? 3 : 0))
      .shadow(color: .black.opacity(hovering ? 0.34 : 0.2), radius: hovering ? 16 : 8, y: hovering ? 9 : 4)
      HStack(spacing: 0) {
        DeckRunningGlyph(running: running, size: 10)
        Text(app.name ?? "").font(.system(size: 13, weight: .medium)).lineLimit(1)
          .foregroundStyle(selected && !running ? Color.accentColor : Color.primary)
      }
    }
    .opacity(app.hidden ? 0.4 : 1)
    .offset(y: hovering ? -2 : 0)
    .animation(.smooth(duration: 0.18), value: hovering)
    .onHover { hovering = $0 }
    .contentShape(Rectangle())
    .onTapGesture(count: 2) { model.openApp(app) }
    .onTapGesture { model.selectedId = app.id }
    .deckPadTarget(app, model, radius: 16)
    .contextMenu {
      Button(DL(app.pinned ? "Unpin App" : "Pin App")) { model.actions.pin?(app) }
      Button(DL(app.hidden ? "Show App" : "Hide App")) { model.actions.hide?(app) }
      if running { Divider(); Button(DL("Quit App")) { model.quitApp(app) } }
    }
  }
}
