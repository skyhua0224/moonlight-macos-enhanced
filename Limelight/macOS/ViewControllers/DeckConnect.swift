//
//  DeckConnect.swift
//  连接 as a split button: the main part connects the way this computer was last connected, the chevron
//  opens 连接方式 (what to connect to) and whatever sections providers add (DeckConnectMenuProvider.swift),
//  then 串流设置.
//
//  连接方式, each only where the host really supports it:
//    桌面         the Desktop app: the host's own screen
//    大屏模式     Foundation Sunshine's big screen entry (FsKind=bigscreen)
//    虚拟显示器   Foundation Sunshine's virtual display (the host reports VddCapabilityVersion; the client
//                 caches it as settings.sunshine.vddCapability.<uuid> when it reads /displays)
//    指定显示器   one of the displays the host lists (/displays, the same list the app context menu uses);
//                 only when the host listed some
//  It is the client's existing per-app topology override (MLSunshinePerAppTopologyDefaults: display name,
//  use virtual display) that carries the choice into the stream, so nothing new travels to the host.
//  The choice is remembered per computer.
//

import AppKit
import SwiftUI

enum DeckConnectMode: String {
  case desktop, bigscreen, vdd, display
}

struct DeckConnectChoice: Equatable {
  var mode: DeckConnectMode
  var displayId: String?
}

enum DeckConnectStore {
  private static func key(_ uuid: String) -> String { "MLConnectMode.\(uuid)" }

  static func last(_ uuid: String) -> DeckConnectChoice? {
    guard let raw = UserDefaults.standard.dictionary(forKey: key(uuid)),
          let mode = (raw["mode"] as? String).flatMap(DeckConnectMode.init(rawValue:)) else { return nil }
    return DeckConnectChoice(mode: mode, displayId: raw["display"] as? String)
  }

  static func set(_ uuid: String, _ choice: DeckConnectChoice) {
    var raw: [String: Any] = ["mode": choice.mode.rawValue]
    if let id = choice.displayId { raw["display"] = id }
    UserDefaults.standard.set(raw, forKey: key(uuid))
  }
}

@available(macOS 14.0, *)
enum DeckConnect {
  struct DisplayChoice: Identifiable { let id: String; let name: String }

  static func vddAvailable(_ host: DeckHost) -> Bool {
    guard host.isFoundation else { return false }
    if conceptEnv("MLC_FAKE_VDD") != nil { return true }
    // the capability the host announced in /serverinfo, or the one read from /displays
    let cached = (UserDefaults.standard.object(forKey: "settings.sunshine.vddCapability.\(host.id)") as? NSNumber)?.intValue ?? 0
    return max(cached, host.facts.vddVersion) > 0
  }

  static func displays(_ host: DeckHost, _ model: DeckAppsModel) -> [DisplayChoice] {
    guard host.isFoundation else { return [] }
    if conceptEnv("MLC_FAKE_DISPLAYS") != nil {
      return [DisplayChoice(id: "\\\\.\\DISPLAY1", name: "DELL U2723QE"), DisplayChoice(id: "\\\\.\\DISPLAY2", name: "LG UltraGear")]
    }
    return (model.actions.displays?() ?? []).compactMap { entry in
      guard let id = entry["device_id"] as? String, !id.isEmpty else { return nil }
      let friendly = (entry["friendly_name"] as? String) ?? ""
      let name = friendly.isEmpty ? ((entry["display_name"] as? String) ?? id) : friendly
      return DisplayChoice(id: id, name: name)
    }
  }

  /// The modes this computer offers, in menu order. 桌面 is always there.
  static func modes(_ host: DeckHost, _ model: DeckAppsModel) -> [DeckConnectMode] {
    var list: [DeckConnectMode] = [.desktop]
    if model.bigScreenApp != nil { list.append(.bigscreen) }
    if vddAvailable(host) { list.append(.vdd) }
    if !displays(host, model).isEmpty { list.append(.display) }
    return list
  }

  /// What the main part of the button does: the last choice, as long as it is still on offer.
  static func effective(_ host: DeckHost, _ model: DeckAppsModel) -> DeckConnectChoice {
    let available = modes(host, model)
    if let forced = conceptEnv("MLC_CONNECT_MODE"), let mode = DeckConnectMode(rawValue: forced), available.contains(mode) {
      return DeckConnectChoice(mode: mode, displayId: nil)
    }
    if let last = DeckConnectStore.last(host.id), available.contains(last.mode) {
      if last.mode != .display || displays(host, model).contains(where: { $0.id == last.displayId }) { return last }
    }
    return DeckConnectChoice(mode: .desktop, displayId: nil)
  }

  /// The filled button: 连接桌面 (a computer with nothing else to choose says 连接).
  static func primaryLabel(_ choice: DeckConnectChoice, host: DeckHost, model: DeckAppsModel) -> String {
    switch choice.mode {
    case .vdd, .display: return label(choice, host: host, model: model)
    default:
      // no Desktop app on this host: the button says what it starts, the first app of the list
      switch model.connectPlan.target {
      case .firstApp(_, let name): return DLf("deck.connectApp", DeckConnectPlan.shortName(name))
      case .none: return DL("deck.connect")
      case .desktop: return DL("deck.connectDesktop")
      }
    }
  }

  static func label(_ choice: DeckConnectChoice, host: DeckHost, model: DeckAppsModel) -> String {
    // a computer that offers only 桌面 just says 连接
    guard modes(host, model).count > 1 else { return DL("deck.connect") }
    switch choice.mode {
    case .desktop: return DL("deck.connectDesktop")
    case .bigscreen: return DL("deck.mode.bigscreen")
    case .vdd: return DL("deck.connectVdd")
    case .display:
      let name = displays(host, model).first { $0.id == choice.displayId }?.name ?? DL("deck.mode.display")
      return DLf("deck.connectDisplay", name)
    }
  }

  /// Harness: the menu as text, so a test can read it (MLC_DUMPMENU); also a stand-in 线路 provider
  /// (MLC_FAKE_ROUTES) that implements the protocol the way enhanced-multipath will.
  static func dump(_ host: DeckHost, _ model: DeckAppsModel) -> String {
    let choice = effective(host, model)
    var lines = ["button: \(label(choice, host: host, model: model))"]
    let mode = modeSection(host, model, choice: choice, running: false) {}
    var all = [mode]
    if !displays(host, model).isEmpty {
      all.append(DeckConnectMenuSection(id: "displays", title: DL("deck.mode.chooseDisplay"),
                                        items: displays(host, model).map { DeckConnectMenuItem(id: $0.id, title: $0.name) {} }))
    }
    all += DeckConnectMenuRegistry.sections(for: host)
    for section in all {
      lines.append("section \(section.id): \(section.title)")
      for item in section.items {
        lines.append("  \(item.selected ? "[x]" : "[ ]") \(item.title)\(item.trailing.map { " " + $0 } ?? "")\(item.badge.map { " <\($0)>" } ?? "")")
      }
    }
    lines.append("footer: \(DL("deck.settings"))")
    return lines.joined(separator: "\n")
  }

  static func connect(_ choice: DeckConnectChoice, host: DeckHost, model: DeckAppsModel) {
    guard model.canStream else { NSSound.beep(); return }
    if model.launching { return }   // a launch is pending: this click is part of it
    DeckConnectStore.set(host.id, choice)
    guard host.isFoundation else {
      // a plain Sunshine / GFE host: 桌面 is the Desktop app (or its first app), nothing else to choose
      if let app = model.defaultApp { model.openApp(app) }
      return
    }
    model.actions.connect?(choice.mode.rawValue, choice.displayId ?? "")
  }

  /// 连接方式 as a menu section; the display list is a submenu of its own (rendered by the button).
  static func modeSection(_ host: DeckHost, _ model: DeckAppsModel, choice: DeckConnectChoice, running: Bool,
                          chosen: @escaping () -> Void) -> DeckConnectMenuSection {
    func pick(_ mode: DeckConnectMode) -> () -> Void {
      return {
        let next = DeckConnectChoice(mode: mode, displayId: nil)
        // while a game runs the choice is only remembered; connecting is what 继续 is for
        if running { DeckConnectStore.set(host.id, next); chosen() } else { connect(next, host: host, model: model); chosen() }
      }
    }
    var items: [DeckConnectMenuItem] = []
    for mode in modes(host, model) where mode != .display {
      let (title, symbol): (String, String)
      switch mode {
      case .desktop: (title, symbol) = (DL("deck.mode.desktop"), "display")
      case .bigscreen: (title, symbol) = (DL("deck.mode.bigscreen"), "tv")
      case .vdd: (title, symbol) = (DL("deck.mode.vdd"), "display.2")
      case .display: continue
      }
      items.append(DeckConnectMenuItem(id: "mode.\(mode.rawValue)", title: title, symbol: symbol, selected: choice.mode == mode, action: pick(mode)))
    }
    return DeckConnectMenuSection(id: "mode", title: DL("deck.connectMode"), items: items)
  }
}

#if MLC_CONCEPT_HARNESS
/// Harness only: a provider written the way enhanced-multipath's will be (a class, `order`, `sections(for:)`,
/// section id "route"): the path kinds the ranker classes.
final class DeckHarnessRouteProvider: DeckConnectMenuSectionProvider {
  static let shared = DeckHarnessRouteProvider()
  var order: Int { 100 }
  func sections(for host: DeckHost) -> [DeckConnectMenuSection] {
    var auto = DeckConnectMenuItem(id: "route.auto", title: "自动", symbol: "arrow.triangle.branch", selected: true) {}
    auto.inUse = false
    var lan = DeckConnectMenuItem(id: "route.lan", title: "局域网", trailing: "1 ms", symbol: "wifi") {}
    lan.inUse = true
    let direct = DeckConnectMenuItem(id: "route.direct", title: "直连 · 公网", trailing: "28 ms", symbol: "globe") {}
    let mesh = DeckConnectMenuItem(id: "route.mesh", title: "组网 · Tailscale", trailing: "35 ms", symbol: "point.3.connected.trianglepath.dotted") {}
    let relay = DeckConnectMenuItem(id: "route.relay", title: "中转", trailing: "86 ms", symbol: "arrow.left.arrow.right") {}
    var tunnel = DeckConnectMenuItem(id: "route.tun", title: "经隧道", symbol: "lock.shield") {}
    tunnel.unreachable = true
    return [DeckConnectMenuSection(id: "route", title: "线路", items: [auto, lan, direct, mesh, relay, tunnel])]
  }
}
#endif
