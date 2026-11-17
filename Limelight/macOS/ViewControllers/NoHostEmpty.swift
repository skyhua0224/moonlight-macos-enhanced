//
//  NoHostEmpty.swift
//  The no-host page, drawn as a system empty state (Apple HIG "empty states"): a centred symbol, a title, one line, one prominent button and
//  one link. It handles the three real states of NoHostState.swift and never draws a computer.
//
//  When discovery finds a computer (or one is added) the page does not just vanish. In order: the badge on the symbol turns into a check
//  mark (the system's replace effect and a bounce, a scale-in before macOS 14), about 0.3 s; then the page eases back a little and fades while
//  HostsViewController brings the host list up from slightly below with a spring and fades the page out under it; then the computer's icon in
//  the sidebar gives one small pulse (DeckArrivalMark). Reduce Motion: the check mark appears without an effect and everything else is a fade.
//
//  Only system fonts and colours (the user's accent colour for the symbol and the prominent button), the window background, SF Symbols.
//  A faint accent glow sits behind the symbol; it is off with Reduce Transparency, Increase Contrast, or the user default noHostAccentGlow = NO.
//

import AppKit
import Combine
import SwiftUI

struct NoHostEmpty: View {
  let hosts: [NoHostFound]
  let actions: NoHostActions
  @SwiftUI.State private var started = Date()
  @SwiftUI.State private var now = Date()
  @SwiftUI.State private var found = false
  @SwiftUI.State private var leaving = false
  @SwiftUI.State private var tipsOpen = NoHostPreview.tipsOpen
  @SwiftUI.State private var bounce = 0
  @StateObject private var probe = NoHostLocalNetworkProbe()
  @AppStorage("noHostAccentGlow") private var glow = true
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast
  private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

  private var still: Bool { reduceMotion || NoHostCaps.forceReduceMotion }
  private var phase: NoHostPhase {
    NoHostPreview.phase ?? NoHostRules.phase(elapsed: now.timeIntervalSince(started), denied: probe.denied)
  }

  var body: some View {
    ZStack {
      Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
      if glow, !reduceTransparency, contrast != .increased { glowView }
      VStack(spacing: 0) {
        Spacer(minLength: 0)
        content
          .id(phase)
          .transition(.opacity.combined(with: .scale(scale: still ? 1 : 0.97)))
        Spacer(minLength: 0)
      }
      .padding(.top, 40).padding(.bottom, 24)
      .opacity(leaving ? 0 : 1)
      .scaleEffect(leaving && !still ? 0.96 : 1)
    }
    .animation(still ? .easeInOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 0.85), value: phase)
    .onReceive(timer) { now = $0 }
    .onAppear { started = Date(); now = Date(); bounce += 1; if let first = hosts.first?.id { arrive(first) } }
    // the new value, not `hosts`: inside this closure `hosts` is still the old list
    .onChange(of: hosts.map { $0.id }) { ids in if let first = ids.first { arrive(first) } }
    .onChange(of: phase) { _ in bounce += 1 }
  }

  // MARK: A computer turned up

  /// Found: first the check mark, then the page gives way. Roughly 0.3 s for the first and 0.25 s for the second; HostsViewController's spring
  /// on the host list takes about 0.45 s and starts with the second, so the whole change is a little under 0.8 s.
  private func arrive(_ id: String) {
    guard !found else { return }
    withAnimation(still ? .easeOut(duration: 0.12) : .spring(response: 0.34, dampingFraction: 0.58)) { found = true; bounce += 1 }
    DispatchQueue.main.asyncAfter(deadline: .now() + (still ? 0.12 : 0.30)) { leave(id) }
  }

  private func leave(_ id: String) {
    guard !leaving else { return }
    withAnimation(.easeIn(duration: still ? 0.2 : 0.24)) { leaving = true }
    if NoHostPreview.active {
      NotificationCenter.default.post(name: NSNotification.Name("MLDeckSelectHost"), object: nil, userInfo: ["uuid": NoHostPreview.mockHostUUID])
    } else if !actions.select(id) {
      // the computer went away during the check mark: the page stays, and a computer that turns up later starts the hand-over again
      withAnimation(.easeOut(duration: 0.2)) { leaving = false; found = false }
    }
  }

  private var glowView: some View {
    GeometryReader { geo in
      RadialGradient(gradient: Gradient(stops: [.init(color: Color.accentColor.opacity(0.12), location: 0), .init(color: Color.accentColor.opacity(0.05), location: 0.45), .init(color: Color.accentColor.opacity(0), location: 1)]),
                     center: .center, startRadius: 0, endRadius: 460)
        .frame(width: 920, height: 920)
        .position(x: geo.size.width / 2, y: geo.size.height * 0.40)
        .allowsHitTesting(false)
    }
    .accessibilityHidden(true)
  }

  // MARK: Texts

  private var title: String {
    switch phase {
    case .searching: return DL("nohost.search.title")
    case .notFound: return DL("nohost.notfound.title")
    case .denied: return DL("nohost.denied.title")
    }
  }

  private var line: String {
    switch phase {
    case .searching: return DL("nohost.search.line")
    case .notFound: return DL("nohost.notfound.line")
    case .denied: return DL("nohost.denied.line")
    }
  }

  // MARK: Layout

  private var content: some View {
    VStack(spacing: 28) {
      NoHostGlyph(phase: phase, found: found, still: still, bounce: bounce)
      VStack(spacing: 10) {
        Text(title)
          .font(.system(size: 44, weight: .bold, design: .rounded))
          .multilineTextAlignment(.center)
        Text(line)
          .font(.system(size: 18))
          .foregroundColor(.secondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }
      VStack(spacing: 18) { buttons; if phase == .notFound { tips }; learn }
    }
    .frame(maxWidth: 540)
    .padding(.horizontal, 40)
  }

  // MARK: Actions

  @ViewBuilder private var buttons: some View {
    if phase == .denied {
      HStack(spacing: 12) {
        Button { NoHostRules.openLocalNetworkSettings() } label: { Text(DL("nohost.denied.button")).padding(.horizontal, 6) }
          .controllerButtonStyle(.borderedProminent).noHostExtraLarge()
        Button(action: actions.add) { Text(DL("deck.firstRun.byAddress")).padding(.horizontal, 4) }
          .controllerButtonStyle(.bordered).noHostExtraLarge()
          .keyboardShortcut("n", modifiers: .command)
      }
    } else {
      Button(action: actions.add) { Label(DL("deck.firstRun.byAddress"), systemImage: "plus").padding(.horizontal, 6) }
        .controllerButtonStyle(.borderedProminent).noHostExtraLarge()
        .keyboardShortcut("n", modifiers: .command)
    }
  }

  /// The troubleshooting tips: a button that opens a narrow column, both centred under the buttons.
  private var tips: some View {
    VStack(spacing: 10) {
      Button {
        withAnimation(still ? .easeInOut(duration: 0.15) : .spring(response: 0.4, dampingFraction: 0.85)) { tipsOpen.toggle() }
      } label: {
        HStack(spacing: 5) {
          Text(DL("nohost.tips.title")).font(.callout)
          Image(systemName: still && tipsOpen ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .bold))
            .rotationEffect(.degrees(tipsOpen && !still ? 90 : 0))
        }
        .foregroundColor(.secondary)
        .contentShape(Rectangle())
      }
      .controllerButtonStyle(.plain)
      .accessibilityValue(DL(tipsOpen ? "nohost.tips.expanded" : "nohost.tips.collapsed"))
      if tipsOpen {
        VStack(alignment: .leading, spacing: 9) {
          Label(DL("nohost.tip.network"), systemImage: "wifi")
          Label(DL("nohost.tip.host"), systemImage: "desktopcomputer")
          Label(DL("nohost.tip.firewall"), systemImage: "flame")
        }
        .font(.callout).foregroundColor(.secondary)
        .padding(.horizontal, 18).padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.06)))
        .transition(still ? .opacity : .opacity.combined(with: .move(edge: .top)))
      }
    }
  }

  @ViewBuilder private var learn: some View {
    if phase != .denied {
      Button(action: actions.learn) { Text(DL("nohost.fs.learn")).font(.callout) }
        .buttonStyle(.link)
    }
  }
}

// MARK: - The symbol

/// A display with a badge for the state: the antenna waves while searching, a question mark when nothing was found, a lock when the
/// Local Network permission is off, a check mark when a computer has turned up.
struct NoHostGlyph: View {
  let phase: NoHostPhase
  let found: Bool
  let still: Bool
  let bounce: Int

  private var badge: String { found ? "checkmark" : Self.badge(phase) }

  var body: some View {
    ZStack(alignment: .topTrailing) {
      Image(systemName: "display")
        .font(.system(size: 148, weight: .regular))
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(Color.secondary)
        .padding(.trailing, 6)
      Image(systemName: badge)
        .font(.system(size: 60, weight: .semibold))
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(found ? Color.green : Color.accentColor)
        .noHostBadgeChange(badge, still: still)
        .noHostSymbolEffects(searching: phase == .searching && !found && !still, bounce: still ? 0 : bounce)
        .padding(12)
        .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
        .offset(x: 18, y: -22)
    }
    .accessibilityHidden(true)
  }

  static func badge(_ phase: NoHostPhase) -> String {
    switch phase {
    case .searching: return "wifi"
    case .notFound: return "questionmark"
    case .denied: return "lock.fill"
    }
  }
}
