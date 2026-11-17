//
//  NoHostKit.swift
//  What the no-host page is drawn from, and what it may use on this system. Everything compiles for macOS 12; what is newer is behind
//  `#available` and named in NoHostCaps, so the page can ask "may I use this?" and fall back.
//

import AppKit
import SwiftUI

/// A computer the network search has found. The page never draws one: it only needs to know that there is one.
struct NoHostFound: Identifiable {
  let id: String
}

struct NoHostActions {
  var add: () -> Void
  var learn: () -> Void
  var select: (String) -> Void
}

// MARK: - What this system can draw

enum NoHostCaps {
  private static let env = ProcessInfo.processInfo.environment
  /// The concept harness (concept builds only) can show a state, fake a discovery and force the macOS 12 look.
  static let harness = env["MLC_HARNESS"] != nil
  static let simulateLegacy = harness && env["MLC_NOHOST_LEGACY"] != nil
  /// Harness only: behave as if 减少动态效果 were on.
  static let forceReduceMotion = harness && env["MLC_NOHOST_REDUCE"] != nil

  /// The system symbol effects, and a symbol that changes into another with an effect (macOS 14).
  static var symbolEffects: Bool {
    if simulateLegacy { return false }
    if #available(macOS 14.0, *) { return true }
    return false
  }

  /// Symbols that arrived with SF Symbols 4 (macOS 13).
  static var sfSymbols4: Bool {
    if simulateLegacy { return false }
    if #available(macOS 13.0, *) { return true }
    return false
  }
}

extension View {
  /// The system symbol effects (macOS 14): the waves of a searching symbol run through their levels; a badge that has just changed
  /// (not found, found) bounces once. Before macOS 14 the symbol is still.
  @ViewBuilder func noHostSymbolEffects(searching: Bool, bounce: Int) -> some View {
    if NoHostCaps.symbolEffects, #available(macOS 14.0, *) {
      self
        .symbolEffect(.variableColor.iterative.reversing, options: .repeating, isActive: searching)
        .symbolEffect(.bounce, value: bounce)
    } else {
      self
    }
  }

  /// A badge that changes into another symbol: the system's replace effect (macOS 14); before it the new one scales and fades in.
  @ViewBuilder func noHostBadgeChange(_ symbol: String, still: Bool) -> some View {
    if NoHostCaps.symbolEffects, #available(macOS 14.0, *) {
      self.contentTransition(still ? .identity : .symbolEffect(.replace))
    } else {
      self.id(symbol).transition(still ? .opacity : .scale(scale: 0.4).combined(with: .opacity))
    }
  }

  /// One size above large (macOS 14); before it large.
  @ViewBuilder func noHostExtraLarge() -> some View {
    if !NoHostCaps.simulateLegacy, #available(macOS 14.0, *) { controlSize(.extraLarge) } else { controlSize(.large) }
  }
}

// MARK: - The concept harness's fake discovery

enum NoHostPreview {
  private static let env = ProcessInfo.processInfo.environment
  /// MLC_NOHOST_SCRIPT=1: discovery "finds" one computer after a moment, to record the change to the host list.
  static let scripted = NoHostCaps.harness && env["MLC_NOHOST_SCRIPT"] != nil
  static var active: Bool { scripted }
  /// MLC_NOHOST_STATE=searching|notfound|denied shows that state of the page; MLC_NOHOST_TIPS=1 opens the troubleshooting tips.
  static let phase: NoHostPhase? = NoHostCaps.harness ? env["MLC_NOHOST_STATE"].flatMap { NoHostPhase(rawValue: $0 == "notfound" ? "notFound" : $0) } : nil
  static let tipsOpen = NoHostCaps.harness && env["MLC_NOHOST_TIPS"] != nil
  /// The computer the fake discovery "finds": one of the seeded mock hosts, which the real transition then opens.
  static let mockHostUUID = env["MLC_HOST"] ?? "0A11-GAMINGPC-LIVE"

  static func hosts(elapsed: TimeInterval) -> [NoHostFound] {
    elapsed < 2.8 ? [] : [NoHostFound(id: mockHostUUID)]
  }
}
