//
//  DeckConnectPlan.swift
//  The one place that decides what the 连接 button and the 大屏模式 button are, and which apps the 应用 grid hides.
//  Foundation only, so tests/connect-plan compiles it on its own.
//
//  Rules:
//  1. 大屏模式 exists only on a Foundation Sunshine host that has an app with FsKind=bigscreen. On any other host an
//     app called "Big Picture" or "大屏" is an ordinary app in the grid. Names are never guessed here: `kind` is what
//     the caller found (FsKind, or, for a Foundation Sunshine host older than FsKind, its two default names).
//  2. Foundation Sunshine host: 桌面 (FsKind=desktop) and 大屏 are carried by the buttons and are not in the grid.
//  3. Other host with a Desktop-like app (desktop, 桌面, remote desktop): 连接桌面 starts it, and, as on a Foundation
//     Sunshine host, that app is not repeated in the grid (only the one the button starts; a second one stays).
//  4. Other host without one: 连接 <first app> (the first of the list), and the grid shows every app, that one too.
//  5. No apps: the button is disabled (and says why, once).
//

import Foundation

struct DeckPlanApp: Equatable {
  var id: String
  var name: String
  /// FsKind ("bigscreen", "desktop", "game" ...), nil on hosts that do not send one.
  var kind: String?
}

struct DeckQuitEntry: Equatable {
  /// 桌面 and 大屏模式 are named by what they are (退出桌面, 退出大屏模式); every other app by its own name (退出 X).
  enum Role: Equatable { case desktop, bigScreen, app }
  var appId: String
  var name: String?
  var role: Role = .app
}

enum DeckConnectTarget: Equatable {
  /// 连接桌面: starts this app.
  case desktop(id: String)
  /// 连接 <name>: the first app of the list.
  case firstApp(id: String, name: String)
  /// Nothing to start: the button is disabled.
  case none

  var appId: String? {
    switch self {
    case .desktop(let id): return id
    case .firstApp(let id, _): return id
    case .none: return nil
    }
  }
}

struct DeckConnectPlan: Equatable {
  var bigScreenId: String?
  var target: DeckConnectTarget
  var hiddenFromGrid: Set<String>

  /// Foundation Sunshine says what an entry is (FsKind); every other host is matched by name (沿用现有规则).
  static func isDesktopLike(_ app: DeckPlanApp) -> Bool {
    if let kind = app.kind { return kind == "desktop" }
    let name = app.name.lowercased()
    return name == "desktop" || name == "桌面" || name.contains("remote desktop")
  }

  static func make(isFoundation: Bool, apps: [DeckPlanApp]) -> DeckConnectPlan {
    guard !apps.isEmpty else { return DeckConnectPlan(bigScreenId: nil, target: .none, hiddenFromGrid: []) }
    let desktop = apps.first(where: isDesktopLike)
    if isFoundation {
      let big = apps.first { $0.kind == "bigscreen" }
      let hidden = Set(apps.filter { $0.kind == "bigscreen" || isDesktopLike($0) }.map { $0.id })
      // no Desktop entry: the first app that is not the 大屏 entry (that one has its own button)
      let first = apps.first { $0.kind != "bigscreen" } ?? apps[0]
      let target: DeckConnectTarget = desktop.map { .desktop(id: $0.id) } ?? .firstApp(id: first.id, name: first.name)
      return DeckConnectPlan(bigScreenId: big?.id, target: target, hiddenFromGrid: hidden)
    }
    if let desktop {
      return DeckConnectPlan(bigScreenId: nil, target: .desktop(id: desktop.id), hiddenFromGrid: [desktop.id])
    }
    return DeckConnectPlan(bigScreenId: nil, target: .firstApp(id: apps[0].id, name: apps[0].name), hiddenFromGrid: [])
  }

  /// 连接桌面 next to 继续 while an app runs: the Desktop entry's id, nil when there is none to offer (no Desktop
  /// entry on this host, or the one running is the Desktop). The host answers /launch with 400 "An app is already
  /// running on this host" (Foundation Sunshine src/nvhttp.cpp launch): it keeps one app and one session, so the
  /// desktop cannot be attached while the app runs; the running app is quit first, after the question that every
  /// switch of apps asks.
  static func desktopWhileRunning(plan: DeckConnectPlan, runningId: String?) -> String? {
    guard let runningId, !runningId.isEmpty, case .desktop(let id) = plan.target, id != runningId else { return nil }
    return id
  }

  /// 退出 <app>: the app the host runs now, whichever it is (桌面, 大屏模式 or an ordinary app). Nil when nothing
  /// runs, when the computer is not reachable and paired, or when the running id is not in the list (nothing to quit).
  /// `name` is nil when the host gave none, so the caller writes 退出正在运行的应用.
  static func quitEntry(runningId: String?, apps: [DeckPlanApp], reachable: Bool) -> DeckQuitEntry? {
    guard reachable, let runningId, !runningId.isEmpty, runningId != "0",
          let app = apps.first(where: { $0.id == runningId }) else { return nil }
    let name = app.name.trimmingCharacters(in: .whitespacesAndNewlines)
    let role: DeckQuitEntry.Role = app.kind == "bigscreen" ? .bigScreen : (isDesktopLike(app) ? .desktop : .app)
    return DeckQuitEntry(appId: app.id, name: name.isEmpty ? nil : name, role: role)
  }

  /// A name for the button: cut at `limit` characters.
  static func shortName(_ name: String, limit: Int = 16) -> String {
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    guard trimmed.count > limit else { return trimmed }
    return String(trimmed.prefix(limit - 1)) + "…"
  }
}
