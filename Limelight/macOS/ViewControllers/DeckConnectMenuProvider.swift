//
//  DeckConnectMenuProvider.swift
//  The model of the 连接 dropdown (the chevron next to 连接 in the computer card and the 大图 hero), and
//  the one extension point for it: a provider hands over extra SECTIONS for a host.
//
//  The dropdown is built as
//      连接方式   (built in: 桌面 / 大屏模式 / 虚拟显示器 / 指定显示器…, each only when the host supports it)
//      线路       (from a provider: 自动 and one item per path, with its RTT and a relay mark)
//      ---
//      串流设置
//
//  The 线路 section belongs to enhanced-multipath. That code implements `DeckConnectMenuSectionProvider`
//  (a class, say `DeckRouteMenuProvider`) and registers one instance at startup:
//
//      DeckConnectMenuRegistry.register(DeckRouteMenuProvider.shared)
//
//  and posts `DeckConnectMenuRegistry.didChange` whenever paths or RTTs change, so an open page redraws.
//  The page asks `sections(for:)` while building the menu, on the main thread, so it must answer from
//  already-known state and never wait on the network.
//
//  The 线路 section is drawn twice: as the chip row under the host's status line (every item a chip) and in
//  the ⋯ menu. For the chips, give the section id "route" and per item: title = the path kind in words
//  (局域网 / 直连 / 组网 · Tailscale / 中转 / 经隧道), trailing = "28 ms", symbol = the kind glyph
//  (wifi, globe, point.3.connected.trianglepath.dotted, arrow.left.arrow.right, lock.shield), selected = the
//  path the user pinned (the 自动 item when none), inUse = the path the stream takes now, unreachable = no
//  answer. The item's action pins that path. Item id "route.auto" is 自动.
//
//  Nothing here knows about paths: a section is a title and a list of items. An item is a checkable row
//  with an optional trailing text (the RTT, "12 ms") and an optional badge ("中继"), and an action.
//

import Foundation

/// One row of a section.
struct DeckConnectMenuItem: Identifiable {
  let id: String
  var title: String
  /// Small text after the title, e.g. "12 ms".
  var trailing: String?
  /// A short mark, e.g. "中继" for a relayed path. Shown after the trailing text.
  var badge: String?
  /// An SF Symbol, optional.
  var symbol: String?
  /// The checkmark: the item that is in use now (for 线路: the path the user pinned).
  var selected: Bool
  /// 线路: this is the path the stream actually takes right now (shown as 使用中 while 自动 is on).
  var inUse = false
  /// 线路: nothing answered on this path (shown dimmed, 超时, not selectable).
  var unreachable = false
  /// 线路: no result for this path yet (shown as 测试中…).
  var testing = false
  /// 线路: the row is the remembered one while this launch's answers are still out (drawn with a small mark, nothing else changes).
  var pending = false
  /// The addresses behind a 线路 item, one per line (the chip's tooltip).
  var tooltip: String?
  var enabled: Bool
  /// Runs on the main thread when the row is chosen.
  var action: () -> Void

  init(id: String, title: String, trailing: String? = nil, badge: String? = nil, symbol: String? = nil,
       selected: Bool = false, enabled: Bool = true, action: @escaping () -> Void) {
    self.id = id
    self.title = title
    self.trailing = trailing
    self.badge = badge
    self.symbol = symbol
    self.selected = selected
    self.enabled = enabled
    self.action = action
  }
}

/// A titled group of rows. An empty `items` list hides the section.
struct DeckConnectMenuSection: Identifiable {
  let id: String
  var title: String
  var items: [DeckConnectMenuItem]
}

/// Implemented by anything that adds sections to the 连接 dropdown. `order` decides where the sections
/// go among the providers' (the built-in 连接方式 is always first, 串流设置 always last); lower is higher up.
protocol DeckConnectMenuSectionProvider: AnyObject {
  var order: Int { get }
  /// The sections for this host; return an empty array for "nothing to show" (a host without the
  /// capability, one path only, and so on).
  func sections(for host: DeckHost) -> [DeckConnectMenuSection]
}

enum DeckConnectMenuRegistry {
  /// Posted (any thread) by a provider when what it would answer has changed.
  static let didChange = Notification.Name("MLDeckConnectMenuChanged")

  private static var registered: [DeckConnectMenuSectionProvider] = []
  private static let lock = NSLock()

  static func register(_ provider: DeckConnectMenuSectionProvider) {
    lock.lock(); defer { lock.unlock() }
    if !registered.contains(where: { $0 === provider }) { registered.append(provider) }
  }

  static func unregister(_ provider: DeckConnectMenuSectionProvider) {
    lock.lock(); defer { lock.unlock() }
    registered.removeAll { $0 === provider }
  }

  static func sections(for host: DeckHost, excluding: DeckConnectMenuSectionProvider? = nil) -> [DeckConnectMenuSection] {
    lock.lock()
    let providers = registered.sorted { $0.order < $1.order }.filter { $0 !== excluding }
    lock.unlock()
    return providers.flatMap { $0.sections(for: host) }.filter { !$0.items.isEmpty }
  }
}
