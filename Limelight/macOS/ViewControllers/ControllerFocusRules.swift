//
//  ControllerFocusRules.swift
//  Pure rules of the pad focus in the Deck window. Foundation only, so tests/pad-focus compiles it on its own.
//    - PadFocusScope    which controls of a window are in the focus graph (the Deck computer sidebar never is)
//    - PadFocusReturn   how the focus comes back to where it was when a sheet, a window or a stream gave the screen back
//    - PadHostSwitch    LB / RB: the computer one step before or after the selected one, in sidebar order
//    - PadSectionJump   LT / RT: the previous / next section of the page; PadPageJump: a page further where there are none
//

import Foundation

enum PadFocusScope {
  /// Whether a control whose centre is at `midX` is a focus target.
  /// - sidebarMaxX: right edge of the window sidebar, nil when it has none.
  /// - sidebarColumn: the column the focus is in (windows whose sidebar is a column of the graph: Settings).
  /// - deckMain: the Deck main window. Its sidebar lists the computers; they are switched with LB / RB, so the
  ///   D-pad and the stick never reach it, whatever column the navigator thinks it is in.
  static func includes(midX: CGFloat, sidebarMaxX: CGFloat?, sidebarColumn: Bool, deckMain: Bool) -> Bool {
    guard let sidebarMaxX else { return true }
    let inSidebar = midX < sidebarMaxX
    if deckMain { return !inSidebar }
    return sidebarColumn == inSidebar
  }
}

enum PadFocusReturn {
  enum Step: Equatable {
    /// the page is still being rebuilt: look again next poll
    case wait
    /// the remembered control is back
    case restore
    /// it did not come back in time: the first control of the page (the primary button) takes the focus
    case pageDefault
  }

  /// One poll of the return. `found`: the remembered control (or one in its place) is on the page again;
  /// `ticksLeft`: polls left before the page default takes over (a poll is 1/60 s).
  static func step(found: Bool, ticksLeft: Int) -> Step {
    if found { return .restore }
    return ticksLeft > 0 ? .wait : .pageDefault
  }
}

struct PadHostStep: Equatable {
  let id: String
  let index: Int
  let count: Int
  /// false at either end of the list: the selection stays, the feedback still names the computer
  let moved: Bool
}

enum PadHostSwitch {
  static func step(order: [String], selected: String?, delta: Int) -> PadHostStep? {
    guard !order.isEmpty else { return nil }
    let current = selected.flatMap { id in order.firstIndex(of: id) } ?? (delta > 0 ? -1 : order.count)
    let next = min(max(current + delta, 0), order.count - 1)
    return PadHostStep(id: order[next], index: next, count: order.count, moved: order[next] != selected)
  }
}

/// One reachable control, as the section jump sees it: `top` grows downwards (smaller is higher on the page).
struct PadSectionItem: Equatable {
  let id: String
  /// the section the page marks it with (nil: a loose control such as the tile-size slider)
  let section: String?
  let top: Double
  let left: Double
  /// the control a jump into the section lands on when it was not visited before (the hero's primary button)
  let isEntry: Bool
}

enum PadSectionJump {
  /// LT / RT: the control the focus jumps to in the previous or next section of the page, or nil when the page has
  /// fewer than two sections or `current` is in the first / last one (no wrap).
  /// - preferred: per section, the id of the control last focused in it (the jump returns there).
  /// A control without a section belongs to the one above it (the first section when nothing is above).
  static func target(items: [PadSectionItem], current: String, forward: Bool, preferred: [String: String] = [:]) -> String? {
    let ordered = items.sorted { $0.top == $1.top ? $0.left < $1.left : $0.top < $1.top }
    guard let firstSection = ordered.compactMap({ $0.section }).first else { return nil }
    var assigned: [(item: PadSectionItem, section: String)] = []
    var running = firstSection
    for item in ordered {
      if let own = item.section { running = own }
      assigned.append((item, running))
    }
    var sections: [String] = []
    for entry in assigned where !sections.contains(entry.section) { sections.append(entry.section) }
    guard sections.count >= 2,
          let here = assigned.first(where: { $0.item.id == current })?.section,
          let index = sections.firstIndex(of: here) else { return nil }
    let next = index + (forward ? 1 : -1)
    guard sections.indices.contains(next) else { return nil }
    let members = assigned.filter { $0.section == sections[next] }.map { $0.item }
    if let id = preferred[sections[next]], members.contains(where: { $0.id == id }) { return id }
    return (members.first { $0.isEntry } ?? members.first)?.id
  }
}

struct PadPageItem: Equatable {
  let id: String
  let midX: Double
  let midY: Double
}

enum PadPageJump {
  /// LT / RT where the window has no sections (Settings, long lists): the control about a page below or above the
  /// current one (`pageHeight`, the visible height); at the end of the list the last or first control; nil when the
  /// focus already is the last or first one.
  static func target(items: [PadPageItem], current: String, pageHeight: Double, forward: Bool) -> String? {
    guard let here = items.first(where: { $0.id == current }) else { return nil }
    let sign = forward ? 1.0 : -1.0
    let ahead = items.filter { ($0.midY - here.midY) * sign > 1 }
    guard !ahead.isEmpty else { return nil }
    let far = ahead.filter { ($0.midY - here.midY) * sign >= pageHeight * 0.8 }
    guard !far.isEmpty else {
      // less than a page left: the end of the list
      return ahead.max { ($0.midY * sign, -abs($0.midX - here.midX)) < ($1.midY * sign, -abs($1.midX - here.midX)) }?.id
    }
    let nearest = far.map { ($0.midY - here.midY) * sign }.min() ?? 0
    let band = far.filter { ($0.midY - here.midY) * sign <= nearest + 12 }
    return band.min { abs($0.midX - here.midX) < abs($1.midX - here.midX) }?.id
  }
}
