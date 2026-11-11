import AppKit
import GameController
import SwiftUI

// Controller focus for AppKit/SwiftUI windows that were built for the pointer.
//
// SwiftUI backs switches, sliders, pop-ups, segmented pickers, steppers, text
// fields and lists with AppKit controls, which the navigator finds in the view
// tree. Controls SwiftUI draws itself, such as buttons, are marked with
// ControllerFocusAnchorView so the navigator can reach them too.

/// Navigation commands, mapped from controller buttons by ControllerNavigation.
@objc enum ControllerFocusInput: Int {
  case up, down, left, right, accept, back, previousColumn, nextColumn
  // Used by the on-screen keyboard: X, Y and the Menu button.
  case delete, space, done
  // Deck: the Menu button lists the focused item's context menu.
  case contextMenu
  // LT / RT: the previous / next section of the page (a page's worth of controls where the window has no sections).
  case previousSection, nextSection
}

// MARK: - SwiftUI anchors

/// Options of a SwiftUI picker, read when the controller opens its list.
struct ControllerFocusChoices {
  let titles: [String]
  let selectedIndex: Int
  let select: (Int) -> Void
}

/// Invisible marker behind a SwiftUI-drawn control; A runs `trigger`. Pickers
/// and sliders also carry what the navigator needs to change their binding.
final class ControllerFocusAnchorView: NSView {
  var trigger: (() -> Void)?
  var adjust: ((Int) -> Void)?
  var choices: (() -> ControllerFocusChoices)?
  /// Builds the NSMenu (submenus and checkmarks included) A lists in the controller menu.
  var menuProvider: (() -> (title: String, menu: NSMenu))?
  var isTargetEnabled = true
  /// Identity of the control across SwiftUI rebuilds ("app:<id>", "primary"): a page that is rebuilt (a stream
  /// ended, the host list refreshed) gets new marker views, and the focus finds its control again by this key.
  var focusKey: String?
  /// Corner radius of the focus ring; negative: a pill for controls up to 64 pt high, 12 pt for bigger ones.
  var ringRadius: CGFloat = -1
  /// What the Menu button lists while this control is focused, or while the focus is inside this region.
  var contextMenu: (() -> (title: String, menu: NSMenu))?
  /// False: the marker only supplies `contextMenu` for the region it covers and never takes the focus.
  var isFocusable = true
  /// The page section the control is in (see `controllerSection`): LT / RT jump between sections.
  var section: String?
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Whether a game controller is connected, which is when ControllerNavigation drives the
/// focus (it uses the same list of controllers).
final class ControllerPresence: ObservableObject {
  static let shared = ControllerPresence()

  @Published private(set) var isConnected = !GCController.controllers().isEmpty
  private var observers: [NSObjectProtocol] = []
  /// A DualSense that only the raw HID bridge sees, and the harness's scripted pad.
  private var rawPad = false
  private var simulated = false

  private init() {
    for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
      observers.append(
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
          [weak self] _ in self?.refresh()
        })
    }
  }

  private func refresh() {
    let connected = !GCController.controllers().isEmpty || rawPad || simulated
    if isConnected != connected { isConnected = connected }
  }

  func setRawPad(_ on: Bool) { rawPad = on; refresh() }
  func setSimulated(_ on: Bool) { simulated = on; refresh() }

  /// Whether the buttons shown are a PlayStation pad's: GameController says so, or the raw bridge is the only source.
  var rawPadOnly: Bool { rawPad && GCController.controllers().isEmpty }
}

/// What ControllerNavigation.m sets: which sources of pad input exist besides GameController.
@objc final class ControllerPresenceBridge: NSObject {
  @objc static func setRawPad(_ on: Bool) { ControllerPresence.shared.setRawPad(on) }
  @objc static func setSimulated(_ on: Bool) { ControllerPresence.shared.setSimulated(on) }
}

/// The marker behind a control, present only while a controller is connected. Every marker
/// is an AppKit view inside the SwiftUI tree, and a settings page has one per control: they
/// are much of what building the page, scrolling it and finding what is under the pointer
/// cost. Without a controller nothing looks for them.
private struct ControllerFocusKeyEnvironment: EnvironmentKey { static let defaultValue: String? = nil }
private struct ControllerRingRadiusEnvironment: EnvironmentKey { static let defaultValue: CGFloat = -1 }
private struct ControllerSectionEnvironment: EnvironmentKey { static let defaultValue: String? = nil }

extension EnvironmentValues {
  var controllerFocusKey: String? {
    get { self[ControllerFocusKeyEnvironment.self] }
    set { self[ControllerFocusKeyEnvironment.self] = newValue }
  }
  var controllerRingRadius: CGFloat {
    get { self[ControllerRingRadiusEnvironment.self] }
    set { self[ControllerRingRadiusEnvironment.self] = newValue }
  }
  var controllerSection: String? {
    get { self[ControllerSectionEnvironment.self] }
    set { self[ControllerSectionEnvironment.self] = newValue }
  }
}

private struct ControllerFocusAnchor: View {
  let enabled: Bool
  var trigger: (() -> Void)?
  var adjust: ((Int) -> Void)?
  var choices: (() -> ControllerFocusChoices)?
  var menuProvider: (() -> (title: String, menu: NSMenu))?
  var key: String?
  var radius: CGFloat = -1
  var context: (() -> (title: String, menu: NSMenu))?
  var focusable = true
  @ObservedObject private var presence = ControllerPresence.shared
  @Environment(\.controllerFocusKey) private var environmentKey
  @Environment(\.controllerRingRadius) private var environmentRadius
  @Environment(\.controllerSection) private var environmentSection

  var body: some View {
    if presence.isConnected {
      ControllerFocusAnchorRepresentable(
        enabled: enabled, trigger: trigger, adjust: adjust, choices: choices,
        menuProvider: menuProvider, key: key ?? environmentKey, radius: radius >= 0 ? radius : environmentRadius,
        context: context, focusable: focusable, section: environmentSection
      )
      // The marker never takes a click; saying so keeps it out of pointer hit testing.
      .allowsHitTesting(false)
    }
  }
}

private struct ControllerFocusAnchorRepresentable: NSViewRepresentable {
  let enabled: Bool
  var trigger: (() -> Void)?
  var adjust: ((Int) -> Void)?
  var choices: (() -> ControllerFocusChoices)?
  var menuProvider: (() -> (title: String, menu: NSMenu))?
  var key: String?
  var radius: CGFloat = -1
  var context: (() -> (title: String, menu: NSMenu))?
  var focusable = true
  var section: String?

  func makeNSView(context: Context) -> ControllerFocusAnchorView {
    let view = ControllerFocusAnchorView()
    updateNSView(view, context: context)
    return view
  }

  func updateNSView(_ view: ControllerFocusAnchorView, context: Context) {
    view.trigger = trigger
    view.adjust = adjust
    view.choices = choices
    view.menuProvider = menuProvider
    view.isTargetEnabled = enabled
    view.focusKey = key
    view.ringRadius = radius
    view.contextMenu = self.context
    view.isFocusable = focusable
    view.section = section
  }
}

private struct ControllerFocusButtonBody<Base: PrimitiveButtonStyle>: View {
  let configuration: PrimitiveButtonStyleConfiguration
  let base: Base
  @Environment(\.isEnabled) private var isEnabled

  var body: some View {
    Button(configuration)
      .buttonStyle(base)
      .background(ControllerFocusAnchor(enabled: isEnabled, trigger: configuration.trigger))
  }
}

/// Renders buttons with `base` unchanged and makes them controller targets.
struct ControllerFocusButtonStyle<Base: PrimitiveButtonStyle>: PrimitiveButtonStyle {
  let base: Base

  func makeBody(configuration: Configuration) -> some View {
    ControllerFocusButtonBody(configuration: configuration, base: base)
  }
}

private struct ControllerFocusPlainButtonBody<Base: ButtonStyle>: View {
  let configuration: PrimitiveButtonStyleConfiguration
  let base: Base
  @Environment(\.isEnabled) private var isEnabled

  var body: some View {
    Button(configuration)
      .buttonStyle(base)
      .background(ControllerFocusAnchor(enabled: isEnabled, trigger: configuration.trigger))
  }
}

/// The same for a custom `ButtonStyle` (the Deck capsules and glass buttons).
struct ControllerFocusCustomButtonStyle<Base: ButtonStyle>: PrimitiveButtonStyle {
  let base: Base

  func makeBody(configuration: Configuration) -> some View {
    ControllerFocusPlainButtonBody(configuration: configuration, base: base)
  }
}

extension View {
  /// Drop-in for `.buttonStyle(_:)` that keeps the button reachable by controller.
  func controllerButtonStyle<S: PrimitiveButtonStyle>(_ style: S) -> some View {
    buttonStyle(ControllerFocusButtonStyle(base: style))
  }

  /// Same for a custom `ButtonStyle`.
  func controllerButtonStyle<S: ButtonStyle>(_ style: S) -> some View {
    buttonStyle(ControllerFocusCustomButtonStyle(base: style))
  }

  /// Makes a gesture-driven control reachable by controller; A runs `action`. `key` is its identity
  /// across page rebuilds, `radius` the corner radius of its focus ring (tiles and cards), `context`
  /// what the Menu button lists for it.
  func controllerFocusTarget(
    enabled: Bool = true, key: String? = nil, radius: CGFloat = -1,
    context: (() -> (title: String, menu: NSMenu))? = nil, _ action: @escaping () -> Void
  ) -> some View {
    background(ControllerFocusAnchor(enabled: enabled, trigger: action, key: key, radius: radius, context: context))
  }

  /// Marks the controls inside as one section of the page: LT / RT jump from section to section.
  func controllerSection(_ id: String) -> some View {
    environment(\.controllerSection, id)
  }

  /// Names the controller targets inside (a stable identity for the focus, and the name in harness logs).
  func controllerKey(_ key: String, radius: CGFloat = -1) -> some View {
    environment(\.controllerFocusKey, key).environment(\.controllerRingRadius, radius)
  }

  /// A region whose Menu-button list is `menu` while the focus is inside it (an inner region wins). It takes no focus itself.
  func controllerContextMenu(_ menu: @escaping () -> (title: String, menu: NSMenu)) -> some View {
    background(ControllerFocusAnchor(enabled: true, context: menu, focusable: false))
  }

  /// A menu control: A lists `menu`, the Menu button lists it too.
  func controllerFocusMenu(key: String? = nil, radius: CGFloat = -1, _ menu: @escaping () -> (title: String, menu: NSMenu)) -> some View {
    background(ControllerFocusAnchor(enabled: true, menuProvider: menu, key: key, radius: radius))
  }

  /// Makes a picker reachable by controller. SwiftUI no longer backs menu
  /// pickers with an NSPopUpButton on every macOS version, so the anchor
  /// carries the binding: D-pad steps through `options`, A lists them.
  func controllerPicker<T: Equatable>(
    selection: Binding<T>, options: [T], title: @escaping (T) -> String
  ) -> some View {
    modifier(ControllerPickerModifier(selection: selection, options: options, title: title))
  }

  /// Same for options that carry their own titles.
  func controllerPicker<T: Equatable>(selection: Binding<T>, choices: [(value: T, title: String)]) -> some View {
    controllerPicker(selection: selection, options: choices.map(\.value), title: { value in
      choices.first { $0.value == value }?.title ?? ""
    })
  }

  /// Makes a SwiftUI `Menu` reachable by controller. SwiftUI does not always back
  /// it with an NSPopUpButton, so the anchor builds an equivalent NSMenu on demand
  /// (see `ControllerMenuBuilder`); A lists it, submenus open with A or right.
  func controllerMenu(_ menu: @escaping () -> (title: String, menu: NSMenu)) -> some View {
    modifier(ControllerMenuModifier(menu: menu))
  }

  /// Makes a slider reachable by controller; D-pad left/right changes the value
  /// by `step`, or a twentieth of the range.
  func controllerSlider<V: BinaryFloatingPoint>(
    value: Binding<V>, in range: ClosedRange<V>, step: V? = nil
  ) -> some View {
    modifier(ControllerSliderModifier(value: value, range: range, step: step))
  }
}

private struct ControllerPickerModifier<T: Equatable>: ViewModifier {
  let selection: Binding<T>
  let options: [T]
  let title: (T) -> String
  @Environment(\.isEnabled) private var isEnabled

  func body(content: Content) -> some View {
    content.background(ControllerFocusAnchor(
      enabled: isEnabled,
      adjust: { delta in
        guard !options.isEmpty else { return }
        let current = options.firstIndex(of: selection.wrappedValue)
        let next = current.map { $0 + delta } ?? (delta > 0 ? 0 : options.count - 1)
        guard next >= 0, next < options.count, next != current else { return }
        selection.wrappedValue = options[next]
      },
      choices: {
        ControllerFocusChoices(
          titles: options.map(title),
          selectedIndex: options.firstIndex(of: selection.wrappedValue) ?? -1,
          select: { index in
            guard index >= 0, index < options.count else { return }
            selection.wrappedValue = options[index]
          })
      }))
  }
}

private struct ControllerMenuModifier: ViewModifier {
  let menu: () -> (title: String, menu: NSMenu)
  @Environment(\.isEnabled) private var isEnabled

  func body(content: Content) -> some View {
    content.background(ControllerFocusAnchor(enabled: isEnabled, menuProvider: menu))
  }
}

/// Builds the NSMenu items `controllerMenu(_:)` hands to the controller menu.
enum ControllerMenuBuilder {
  /// A menu item that runs `action` when chosen. The item retains its target.
  static func item(
    title: String, checked: Bool = false, enabled: Bool = true, action: @escaping () -> Void
  ) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: #selector(ControllerChoiceTarget.choose(_:)), keyEquivalent: "")
    let target = ControllerChoiceTarget(action)
    item.target = target
    item.representedObject = target
    item.state = checked ? .on : .off
    item.isEnabled = enabled
    return item
  }

  /// An item that opens `submenu`; `checked` marks it when something inside is on.
  static func submenuItem(title: String, checked: Bool = false, submenu: NSMenu) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.submenu = submenu
    item.state = checked ? .on : .off
    return item
  }
}

private struct ControllerSliderModifier<V: BinaryFloatingPoint>: ViewModifier {
  let value: Binding<V>
  let range: ClosedRange<V>
  let step: V?
  @Environment(\.isEnabled) private var isEnabled

  func body(content: Content) -> some View {
    content.background(ControllerFocusAnchor(
      enabled: isEnabled,
      adjust: { delta in
        let span = Double(range.upperBound - range.lowerBound)
        let increment = step.map { Double($0) } ?? span / 20
        let next = Double(value.wrappedValue) + increment * Double(delta)
        value.wrappedValue = V(min(max(next, Double(range.lowerBound)), Double(range.upperBound)))
      }))
  }
}

// MARK: - Focus ring

/// A dark hairline, a white halo and the accent colour: one of the three always stands out, on a
/// light page, a dark page and a poster alike. The ring is a child window around the control, so
/// showing it moves nothing in the page.
private final class ControllerFocusRingView: NSView {
  var radius: CGFloat = 10 { didSet { if radius != oldValue { needsDisplay = true } } }

  override func draw(_ dirtyRect: NSRect) {
    let rect = bounds.insetBy(dx: 4.5, dy: 4.5)
    let corner = min(max(radius, 3), min(rect.width, rect.height) / 2)
    func stroke(_ width: CGFloat, _ color: NSColor) {
      let path = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)
      path.lineWidth = width
      color.setStroke()
      path.stroke()
    }
    stroke(8, NSColor.black.withAlphaComponent(0.28))
    stroke(5.5, NSColor.white.withAlphaComponent(0.95))
    stroke(3, NSColor.controlAccentColor)
  }
}

private final class ControllerFocusRing {
  private var panel: NSPanel?
  private weak var parent: NSWindow?

  var isVisible: Bool { panel?.isVisible == true }

  func show(_ frame: NSRect, in window: NSWindow, radius: CGFloat) {
    // never into a window that is off screen: a child window brings its parent back
    guard window.isVisible else { return hide() }
    let rect = frame.insetBy(dx: -5, dy: -5).integral
    let panel = self.panel ?? makePanel()
    self.panel = panel
    if parent !== window {
      parent?.removeChildWindow(panel)
      window.addChildWindow(panel, ordered: .above)
      parent = window
    }
    if let ring = panel.contentView as? ControllerFocusRingView {
      ring.radius = radius + 5
    }
    if panel.frame != rect {
      panel.setFrame(rect, display: true)
    }
    if !panel.isVisible {
      panel.orderFront(nil)
    }
  }

  func hide() {
    guard let panel else { return }
    parent?.removeChildWindow(panel)
    panel.orderOut(nil)
    parent = nil
  }

  private func makePanel() -> NSPanel {
    let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
    panel.contentView = ControllerFocusRingView()
    return panel
  }
}

// MARK: - Back actions

/// What B does before it goes back a column: a page that has something to cancel (a connection
/// being made) registers it while that is the case; the newest registration answers first.
final class ControllerBackRegistry {
  static let shared = ControllerBackRegistry()
  private var entries: [(id: UUID, action: () -> Bool)] = []

  func register(_ id: UUID, _ action: @escaping () -> Bool) {
    entries.removeAll { $0.id == id }
    entries.append((id, action))
  }

  func remove(_ id: UUID) { entries.removeAll { $0.id == id } }

  var count: Int { entries.count }

  /// Runs the newest action that takes the press (an action returns false when it has nothing to do any more,
  /// as a popover that is already closed); false when none does.
  @discardableResult
  func fire() -> Bool {
    for entry in entries.reversed() where entry.action() {
      LogMessage(LOG_I, "[controller-ui] B ran a registered back action (\(entries.count) registered)")
      return true
    }
    return false
  }
}

private struct ControllerBackModifier: ViewModifier {
  let active: Bool
  let action: () -> Bool
  @SwiftUI.State private var id = UUID()

  func body(content: Content) -> some View {
    content
      // runs when the view appears and every time `active` changes
      .task(id: active) { sync() }
      .onDisappear { ControllerBackRegistry.shared.remove(id) }
  }

  private func sync() {
    if active { ControllerBackRegistry.shared.register(id, action) } else { ControllerBackRegistry.shared.remove(id) }
  }
}

extension View {
  /// While `active`, B runs `action` (cancel a connection) instead of going back.
  func controllerBackAction(active: Bool, _ action: @escaping () -> Void) -> some View {
    modifier(ControllerBackModifier(active: active, action: { action(); return true }))
  }

  /// Same, for an action that says whether it took the press.
  func controllerBackHandler(active: Bool, _ action: @escaping () -> Bool) -> some View {
    modifier(ControllerBackModifier(active: active, action: action))
  }
}

// MARK: - Navigator

/// Moves a focus ring over a window's controls. Windows with a sidebar split
/// into two columns; LB/RB pick the column, the D-pad moves within it.
@objc final class ControllerFocusNavigator: NSObject {
  private enum Kind { case press, slider, stepper, popUp, menu, segments, text, row, anchor }
  private enum Column { case sidebar, detail }

  private struct Target {
    let kind: Kind
    let view: NSView
    var row = -1

    func same(as other: Target) -> Bool { view === other.view && row == other.row }
    var key: String? { (view as? ControllerFocusAnchorView)?.focusKey ?? (row >= 0 ? "row:\(row)" : nil) }
  }

  /// Where the focus was in the main window when a sheet, a popover or a stream took the screen.
  private struct Memory {
    let key: String?
    let kind: Kind
    let center: NSPoint
    let column: Column
  }

  /// The Deck page's own menu (Menu button where the focused control has none), set by the computer list.
  static var pageMenu: (() -> (title: String, menu: NSMenu)?)?

  private weak var window: NSWindow?
  private var column: Column = .detail
  private var current: Target?
  private let ring = ControllerFocusRing()
  private var pendingDirection: ControllerFocusInput?
  private var pendingTicks = 0
  private var pendingRetries = 0
  private var pendingKeyboardTicks = 0
  /// The Deck main window (and the sheets, alerts and popovers over it): LB/RB switch computers, the Menu button lists
  /// the context menu, B cancels what is pending. Set by ControllerNavigation before every call.
  @objc var isDeck = false
  private var currentCenter: NSPoint?
  /// The control last focused in each section of the page: a jump back into the section returns there.
  private var sectionMemory: [String: (view: NSView, row: Int)] = [:]
  private var memory: Memory?
  private var restoreTicks = 0
  private var pendingInitialTicks = 0
  private var staleTicks = 0
  /// polls left before the page default takes the focus when no control of the page matches the remembered one
  private var initialRetries = 0
  private static let mainIdentifier = "MainWindow"

  override init() {
    super.init()
    // the LB / RB feedback listens from the start
    _ = ControllerHostToast.shared
  }

  /// The Deck main window: its computer sidebar is never part of the focus graph (LB / RB switch computers).
  private func isDeckMain(_ window: NSWindow) -> Bool {
    isDeck && window.sheetParent == nil && window.identifier?.rawValue == Self.mainIdentifier
  }

  // MARK: Entry points

  /// Returns false when the input was not used (B with nowhere to go back to).
  @objc(handleInput:window:)
  @discardableResult
  func handle(_ input: ControllerFocusInput, window: NSWindow) -> Bool {
    if self.window !== window {
      enter(window, showFocus: false)
    }
    pendingDirection = nil
    pendingInitialTicks = 0

    var targets = collectTargets(in: window)
    if let old = current, !targets.contains(where: { $0.same(as: old) }) {
      current = relocate(old, key: old.key, center: currentCenter, in: targets)
    }

    switch input {
    case .contextMenu:
      presentContextMenu(in: window)
      return true
    case .previousColumn, .nextColumn:
      if isDeck && window.sheetParent == nil && window.identifier?.rawValue == Self.mainIdentifier {
        // LB/RB: the previous / next computer in the sidebar order. The page behind is rebuilt, so the focus
        // is placed again a moment later (the connect button, or the selected row when the sidebar has it).
        NotificationCenter.default.post(name: .init("MLDeckPadSwitchHost"), object: nil,
                                        userInfo: ["delta": input == .previousColumn ? -1 : 1])
        current = nil
        column = .detail
        pendingInitialTicks = 24
        initialRetries = 4
        return true
      }
      let wanted: Column = input == .previousColumn ? .sidebar : .detail
      if sidebarFrame(in: window) != nil && column != wanted {
        switchColumn(to: wanted, targets: targets, window: window)
      } else if current == nil {
        focusInitial(targets, window: window)
      }
      return true
    case .back:
      if endTextEditing(in: window) {
        return true
      }
      if isDeck && ControllerBackRegistry.shared.fire() {
        return true
      }
      if !isDeckMain(window), column == .detail && sidebarFrame(in: window) != nil {
        switchColumn(to: .sidebar, targets: targets, window: window)
        return true
      }
      return false
    default:
      break
    }

    guard let current else {
      focusInitial(targets, window: window)
      return true
    }

    switch input {
    case .up, .down:
      endTextEditing(in: window)
      if let next = neighbor(of: current, toward: input, in: targets) {
        focus(next, window: window)
      } else if column == .detail, pageScroll(toward: input, from: current) {
        // Lazy stacks only build what is on screen; look again after scrolling.
        pendingDirection = input
        pendingTicks = 3
        pendingRetries = 2
      }
    case .left, .right:
      if adjust(current, forward: input == .right) {
        return true
      }
      if let next = neighbor(of: current, toward: input, in: targets) {
        focus(next, window: window)
      } else if pageScroll(toward: input, from: current) {
        pendingDirection = input
        pendingTicks = 3
        pendingRetries = 2
      } else if !isDeckMain(window), sidebarFrame(in: window) != nil {
        if input == .left && column == .detail {
          switchColumn(to: .sidebar, targets: targets, window: window)
        } else if input == .right && column == .sidebar {
          targets = collectTargets(in: window)
          switchColumn(to: .detail, targets: targets, window: window)
        }
      }
    case .accept:
      activate(current, window: window)
    case .previousSection, .nextSection:
      endTextEditing(in: window)
      let hasSections = targets.contains { ($0.view as? ControllerFocusAnchorView)?.section != nil }
      if !jumpSection(from: current, forward: input == .nextSection, targets: targets, window: window),
         !hasSections || input == .previousSection {
        // Nothing to jump to among the controls that are on screen. A long list without sections: the controls a page
        // further are not built yet. A page with sections: the sections above (the hero) are scrolled away. Scroll, then
        // look again. Going on past the last section does nothing: no wrap, and the focus is not scrolled off screen.
        if pageScroll(toward: input == .nextSection ? .down : .up, from: current) {
          pendingDirection = input
          pendingTicks = 3
          pendingRetries = 2
        }
      }
    default:
      break
    }
    return true
  }

  /// LT / RT: the previous / next section of the page, where the page has sections; else a page's worth of controls
  /// further. Returns false when there is nowhere to go with the controls that exist now.
  @discardableResult
  private func jumpSection(from current: Target, forward: Bool, targets: [Target], window: NSWindow) -> Bool {
    var items: [PadSectionItem] = []
    var byID: [String: Target] = [:]
    var pageItems: [PadPageItem] = []
    for (index, target) in targets.enumerated() {
      guard let f = frame(of: target) else { continue }
      let id = "\(index)"
      byID[id] = target
      items.append(PadSectionItem(id: id, section: (target.view as? ControllerFocusAnchorView)?.section,
                                  top: Double(-f.maxY), left: Double(f.minX),
                                  isEntry: target.key == "primary" || target.key?.hasPrefix("app:") == true))
      pageItems.append(PadPageItem(id: id, midX: Double(f.midX), midY: Double(-f.midY)))
    }
    guard let here = targets.firstIndex(where: { $0.same(as: current) }).map({ "\($0)" }) else { return false }
    var preferred: [String: String] = [:]
    for (section, remembered) in sectionMemory {
      if let match = targets.enumerated().first(where: { $0.element.view === remembered.view && $0.element.row == remembered.row }) {
        preferred[section] = "\(match.offset)"
      }
    }
    var destination = PadSectionJump.target(items: items, current: here, forward: forward, preferred: preferred)
    if destination == nil, !items.contains(where: { $0.section != nil }) {
      let page = Double(visibleFrame(of: current, in: window).height)
      destination = PadPageJump.target(items: pageItems, current: here, pageHeight: page, forward: forward)
    }
    guard let destination, let target = byID[destination] else { return false }
    focus(target, window: window)
    return true
  }

  /// Focuses the settings search field after the View button raised it.
  @objc(focusSearchFieldInWindow:)
  func focusSearchField(in window: NSWindow) {
    self.window = window
    if isDeckMain(window) {
      // The search field sits in the computer sidebar: View raises its keyboard, the focus stays on the page.
      column = .detail
      let search = collectTargets(in: window, ignoreScope: true).first { $0.view is NSSearchField }
      if let field = search?.view as? NSControl, window.makeFirstResponder(field) {
        pendingKeyboardTicks = 30
      }
      return
    }
    column = sidebarFrame(in: window) != nil ? .sidebar : .detail
    let targets = collectTargets(in: window)
    if let search = targets.first(where: { $0.view is NSSearchField }) {
      current = search
    }
    // The search field takes focus a moment later; the keyboard follows it.
    pendingKeyboardTicks = 30
  }

  /// Called every poll; keeps the ring on the focused control.
  @objc(updateWithWindow:showRing:)
  func update(window: NSWindow?, showRing: Bool) {
    if pendingKeyboardTicks > 0 {
      pendingKeyboardTicks -= 1
      if let window, window === self.window, !ControllerKeyboardPanel.shared.isPresented,
         (window.firstResponder as? NSTextView)?.isFieldEditor == true {
        pendingKeyboardTicks = 0
        ControllerKeyboardPanel.shared.present(in: window)
      }
    }
    if let window, isDeck, window !== self.window {
      enter(window, showFocus: showRing)
    }
    if let window, let old = self.window, window !== old, !isDeck {
      // The settings window (a window of its own) took the pad: the page keeps its place for the way back, also when
      // the pad has not moved anything in the new window yet.
      rememberFocus(leaving: old)
    }
    guard let window, window === self.window else {
      ring.hide()
      pendingDirection = nil
      return
    }

    if restoreTicks > 0, let memory {
      restoreTicks -= 1
      column = isDeckMain(window) ? .detail : memory.column
      let targets = collectTargets(in: window)
      let found = relocate(Target(kind: memory.kind, view: window.contentView ?? NSView()), key: memory.key,
                           center: memory.center, in: targets, kind: memory.kind)
      switch PadFocusReturn.step(found: found != nil, ticksLeft: restoreTicks) {
      case .restore:
        current = found
        self.memory = nil
        restoreTicks = 0
      case .pageDefault:
        // The control that opened the window is gone from the page: the page's own first control, not the sidebar.
        self.memory = nil
        restoreTicks = 0
        focusInitial(targets, window: window)
      case .wait:
        break
      }
    }

    if pendingInitialTicks > 0 {
      pendingInitialTicks -= 1
      if pendingInitialTicks == 0 {
        let targets = collectTargets(in: window)
        // After LB / RB the page is rebuilt for the new computer: a control that was only a stand-in (the first one found
        // before the primary button exists) is replaced by the primary button as soon as the page has it.
        let settled = current?.key == "primary"
        if let old = current, settled || (initialRetries == 0 && targets.contains(where: { $0.same(as: old) })) {
          // still there
        } else {
          focusInitial(targets, window: window)
          if current?.key != "primary", initialRetries > 0 {
            initialRetries -= 1
            pendingInitialTicks = 12
          }
        }
      }
    }

    guard showRing, let current else {
      ring.hide()
      return
    }

    if let direction = pendingDirection {
      pendingTicks -= 1
      if pendingTicks <= 0 {
        let targets = collectTargets(in: window)
        if direction == .previousSection || direction == .nextSection {
          if jumpSection(from: current, forward: direction == .nextSection, targets: targets, window: window) {
            pendingDirection = nil
          } else if pendingRetries > 0 {
            pendingRetries -= 1
            pendingTicks = 3
          } else {
            pendingDirection = nil
          }
        } else if let next = neighbor(of: current, toward: direction, in: targets) {
          pendingDirection = nil
          focus(next, window: window)
        } else if pendingRetries > 0 {
          pendingRetries -= 1
          pendingTicks = 3
        } else {
          pendingDirection = nil
        }
      }
    }

    guard let focused = self.current, let frame = frame(of: focused) else {
      ring.hide()
      // The page was rebuilt under the focus: find the control again by its key or place.
      staleTicks += 1
      if isDeck, staleTicks % 6 == 1, let old = self.current {
        let targets = collectTargets(in: window)
        self.current = relocate(old, key: old.key, center: currentCenter, in: targets)
      }
      return
    }
    staleTicks = 0
    currentCenter = NSPoint(x: frame.midX, y: frame.midY)
    let visible = frame.intersection(visibleFrame(of: focused, in: window))
    if visible.height < 6 || visible.width < 6 {
      ring.hide()
    } else {
      ring.show(visible, in: window, radius: ringRadius(of: focused, frame: frame))
    }
  }

  @objc func reset() {
    ring.hide()
    window = nil
    current = nil
    currentCenter = nil
    memory = nil
    restoreTicks = 0
    pendingDirection = nil
    pendingKeyboardTicks = 0
    pendingInitialTicks = 0
    initialRetries = 0
    sectionMemory = [:]
    ControllerKeyboardPanel.shared.dismiss()
  }

  /// A line for the harness: where the focus is, in window coordinates (top left origin).
  @objc func debugState() -> String {
    guard let window else { return "window=none focus=none" }
    let name = window.identifier?.rawValue ?? NSStringFromClass(type(of: window))
    let kind = window.sheetParent != nil ? "sheet" : (name == Self.mainIdentifier ? "main" : "other")
    let columnName = column == .sidebar ? "sidebar" : "detail"
    guard let current, let frame = frame(of: current) else {
      return "window=\(kind) column=\(columnName) focus=none ring=\(ring.isVisible ? 1 : 0) back=\(ControllerBackRegistry.shared.count)"
    }
    let local = window.convertFromScreen(frame)
    let top = window.contentView.map { $0.bounds.height - local.maxY } ?? 0
    let box = "\(Int(local.minX)),\(Int(top)),\(Int(local.width))x\(Int(local.height))"
    return "window=\(kind) column=\(columnName) kind=\(current.kind) key=\(current.key ?? "-") frame=\(box) ring=\(ring.isVisible ? 1 : 0) back=\(ControllerBackRegistry.shared.count)"
  }

  /// Every control the pad can reach in the window now, for the harness (a line per control).
  @objc func debugTargets() -> String {
    guard let window else { return "window=none" }
    return collectTargets(in: window).map { target -> String in
      let f = frame(of: target).map { window.convertFromScreen($0) } ?? .zero
      let section = (target.view as? ControllerFocusAnchorView)?.section.map { " §" + $0 } ?? ""
      return "\(target.kind) \(target.key ?? "-") \(Int(f.minX)),\(Int((window.contentView?.bounds.height ?? 0) - f.maxY)),\(Int(f.width))x\(Int(f.height))\(section)"
    }.joined(separator: " ; ")
  }

  /// The key of the focused control (the harness walks by it).
  @objc var focusedKey: String { current?.key ?? "" }

  // MARK: Window changes and rebuilds

  /// Where the focus was in the main window when something else took the pad: a sheet, a popover, the settings window.
  /// Nothing is taken when the pad had no focus there (the page default is placed on the way back).
  private func rememberFocus(leaving old: NSWindow) {
    guard old.identifier?.rawValue == Self.mainIdentifier, old.sheetParent == nil, let current else { return }
    memory = Memory(key: current.key, kind: current.kind, center: currentCenter ?? .zero, column: .detail)
  }

  private func enter(_ window: NSWindow, showFocus: Bool) {
    if let old = self.window {
      rememberFocus(leaving: old)
    }
    self.window = window
    current = nil
    currentCenter = nil
    pendingDirection = nil
    column = !isDeckMain(window) && sidebarFrame(in: window) != nil ? .sidebar : .detail
    if isDeck, window.identifier?.rawValue == Self.mainIdentifier, window.sheetParent == nil, memory != nil {
      restoreTicks = 120
    } else if isDeck, showFocus {
      // A sheet, alert or popover the pad opened: its first control is focused once it has laid out.
      pendingInitialTicks = 8
    }
  }

  /// The same control in a rebuilt page: by key, else the nearest of the same kind.
  private func relocate(_ old: Target, key: String?, center: NSPoint?, in targets: [Target], kind: Kind? = nil) -> Target? {
    if kind == nil, let same = targets.first(where: { $0.same(as: old) }) { return same }
    if let key {
      // the same app can sit in two shelves: of the controls with the key, the one nearest where the focus was
      let matches = targets.filter { $0.key == key && (kind == nil || $0.kind == kind) }
      if matches.count == 1 { return matches[0] }
      if let center, matches.count > 1 {
        return matches.compactMap { target -> (Target, CGFloat)? in
          guard let f = frame(of: target) else { return nil }
          return (target, hypot(f.midX - center.x, f.midY - center.y))
        }.min { $0.1 < $1.1 }?.0
      }
      if let first = matches.first { return first }
    }
    guard let center else { return nil }
    let wanted = kind ?? old.kind
    return targets.filter { $0.kind == wanted }
      .compactMap { target -> (Target, CGFloat)? in
        guard let f = frame(of: target) else { return nil }
        return (target, hypot(f.midX - center.x, f.midY - center.y))
      }
      .filter { $0.1 < 160 }
      .min { $0.1 < $1.1 }?.0
  }

  private func ringRadius(of target: Target, frame: NSRect) -> CGFloat {
    if let anchor = target.view as? ControllerFocusAnchorView, anchor.ringRadius >= 0 { return anchor.ringRadius }
    if target.kind == .row { return 8 }
    if target.kind == .anchor || target.kind == .press {
      return frame.height <= 64 ? frame.height / 2 : 12
    }
    return 8
  }

  // MARK: Collection

  private func collectTargets(in window: NSWindow, ignoreScope: Bool = false) -> [Target] {
    guard let content = window.contentView else { return [] }
    var targets: [Target] = []
    collect(in: content, into: &targets)

    let layout = window.convertToScreen(window.contentLayoutRect)
    let sidebar = sidebarFrame(in: window)

    // Where SwiftUI still backs a picker or slider with an AppKit control, the
    // anchor wins so each control is reached once.
    let carrierFrames = targets.compactMap { target -> NSRect? in
      guard let anchor = target.view as? ControllerFocusAnchorView,
            anchor.adjust != nil || anchor.choices != nil || anchor.menuProvider != nil else { return nil }
      return frame(of: target)?.insetBy(dx: -8, dy: -8)
    }
    targets.removeAll { target in
      guard target.kind == .popUp || target.kind == .menu || target.kind == .slider,
            let frame = frame(of: target) else { return false }
      return carrierFrames.contains { $0.contains(frame) }
    }

    // A button the page also marks with an anchor of its own size is one target, the anchor.
    let triggerFrames = targets.compactMap { target -> NSRect? in
      guard let anchor = target.view as? ControllerFocusAnchorView, anchor.trigger != nil else { return nil }
      return frame(of: target)
    }
    targets.removeAll { target in
      guard target.kind == .press, let frame = frame(of: target), frame.width * frame.height > 0 else { return false }
      return triggerFrames.contains { anchor in
        let overlap = anchor.intersection(frame)
        return overlap.width * overlap.height > 0.6 * frame.width * frame.height
          && overlap.width * overlap.height > 0.6 * anchor.width * anchor.height
      }
    }

    return targets.filter { target in
      guard let frame = frame(of: target), frame.width > 1, frame.height > 1 else { return false }
      // Controls in a row that scrolls sideways may be off the window's edge until the row scrolls.
      let sideways = Self.scrollsHorizontally(target.view)
      guard sideways || (frame.midX >= layout.minX && frame.midX <= layout.maxX), frame.midY <= layout.maxY else { return false }
      if ignoreScope { return true }
      return PadFocusScope.includes(midX: frame.midX, sidebarMaxX: sidebar?.maxX, sidebarColumn: column == .sidebar,
                                    deckMain: isDeckMain(window))
    }
  }

  private func collect(in view: NSView, into targets: inout [Target]) {
    guard !view.isHidden, view.alphaValue > 0 else { return }
    if let anchor = view as? ControllerFocusAnchorView {
      if anchor.isTargetEnabled && anchor.isFocusable {
        targets.append(Target(kind: .anchor, view: anchor))
      }
      return
    }
    if let table = view as? NSTableView {
      for row in 0..<table.numberOfRows {
        if table.delegate?.tableView?(table, isGroupRow: row) == true { continue }
        if table.delegate?.tableView?(table, shouldSelectRow: row) == false { continue }
        if let rowView = table.rowView(atRow: row, makeIfNecessary: false) {
          // SwiftUI lists mark their section titles as group-style rows
          if rowView.isGroupRowStyle { continue }
          // a row that holds a button of its own (清理旧记录) is that button, not a selectable row
          var inner: [ControllerFocusAnchorView] = []
          Self.anchors(in: rowView, into: &inner)
          let actions = inner.filter { $0.isTargetEnabled && $0.isFocusable && $0.trigger != nil }
          if !actions.isEmpty {
            targets.append(contentsOf: actions.map { Target(kind: .anchor, view: $0) })
            continue
          }
        } else if table.rect(ofRow: row).height < 24 {
          continue
        }
        targets.append(Target(kind: .row, view: table, row: row))
      }
      return
    }
    if let control = view as? NSControl, !(control is NSScroller) {
      if let kind = Self.kind(of: control), control.isEnabled {
        targets.append(Target(kind: kind, view: control))
      }
      if !(control is NSTextField) || Self.kind(of: control) != nil {
        return
      }
    }
    for subview in view.subviews {
      collect(in: subview, into: &targets)
    }
  }

  private static func kind(of control: NSControl) -> Kind? {
    switch control {
    case let popUp as NSPopUpButton: return popUp.pullsDown ? .menu : .popUp
    case is NSButton, is NSSwitch: return .press
    case is NSSlider: return .slider
    case is NSStepper: return .stepper
    case is NSSegmentedControl: return .segments
    case let field as NSTextField: return field.isEditable ? .text : nil
    default: return nil
    }
  }

  private static func scrollsHorizontally(_ view: NSView) -> Bool {
    var scrollView = view.enclosingScrollView
    while let current = scrollView {
      if let document = current.documentView, document.frame.width > current.contentView.bounds.width + 1 { return true }
      scrollView = current.superview?.enclosingScrollView
    }
    return false
  }

  /// The nearest enclosing scroll view that can scroll along the axis.
  private static func scrollView(for view: NSView, vertical: Bool) -> NSScrollView? {
    var scrollView = view.enclosingScrollView
    while let current = scrollView {
      if let document = current.documentView {
        let content = current.contentView.bounds
        if vertical ? document.frame.height > content.height + 1 : document.frame.width > content.width + 1 { return current }
      }
      scrollView = current.superview?.enclosingScrollView
    }
    return nil
  }

  // MARK: Geometry

  private func frame(of target: Target) -> NSRect? {
    let view = target.view
    guard let window = view.window, !view.isHiddenOrHasHiddenAncestor else { return nil }
    if target.kind == .row, let table = view as? NSTableView {
      guard target.row >= 0, target.row < table.numberOfRows else { return nil }
      return window.convertToScreen(table.convert(table.rect(ofRow: target.row), to: nil))
    }
    return window.convertToScreen(view.convert(view.bounds, to: nil))
  }

  private func sidebarFrame(in window: NSWindow) -> NSRect? {
    guard window.sheetParent == nil, let content = window.contentView,
          let split = Self.outermostSplitView(in: content), split.isVertical else { return nil }
    let panes = split.arrangedSubviews.isEmpty ? split.subviews : split.arrangedSubviews
    guard panes.count >= 2, let sidebar = panes.first, !sidebar.isHidden, sidebar.frame.width > 40 else { return nil }
    return window.convertToScreen(sidebar.convert(sidebar.bounds, to: nil))
  }

  private static func outermostSplitView(in root: NSView) -> NSSplitView? {
    var queue: [NSView] = [root]
    while !queue.isEmpty {
      let view = queue.removeFirst()
      if let split = view as? NSSplitView { return split }
      queue.append(contentsOf: view.subviews)
    }
    return nil
  }

  private func visibleFrame(of target: Target, in window: NSWindow) -> NSRect {
    guard let scrollView = target.view.enclosingScrollView else {
      return window.frame
    }
    return window.convertToScreen(scrollView.convert(scrollView.bounds, to: nil))
  }

  /// Spatial neighbour. Vertically: the nearest row of controls, then the one
  /// closest horizontally, which follows how settings forms read.
  private func neighbor(of current: Target, toward direction: ControllerFocusInput, in targets: [Target]) -> Target? {
    guard let origin = frame(of: current) else { return nil }
    let candidates = targets.filter { !$0.same(as: current) }.compactMap { target -> (Target, NSRect)? in
      frame(of: target).map { (target, $0) }
    }
    switch direction {
    case .down, .up:
      var ahead = candidates.filter { _, frame in
        direction == .down ? frame.maxY <= origin.midY : frame.minY >= origin.midY
      }
      // A list that scrolls is finished before the focus leaves it: what is ahead inside the same scroll view
      // (a row below the visible part) comes before a control outside it that happens to be nearer.
      if let scroller = current.view.enclosingScrollView {
        let inside = ahead.filter { $0.0.view.enclosingScrollView === scroller }
        if !inside.isEmpty { ahead = inside }
      }
      // Distance to the edge facing us picks the nearest row band.
      func edgeDistance(_ frame: NSRect) -> CGFloat {
        direction == .down ? origin.minY - frame.maxY : frame.minY - origin.maxY
      }
      guard let nearest = ahead.map({ edgeDistance($0.1) }).min() else { return nil }
      let band = ahead.filter { edgeDistance($0.1) <= max(nearest, 0) + 12 }
      return band.min { abs($0.1.midX - origin.midX) < abs($1.1.midX - origin.midX) }?.0
    case .left, .right:
      let ahead = candidates.filter { _, frame in
        let overlaps = frame.minY < origin.maxY - 2 && frame.maxY > origin.minY + 2
        return overlaps && (direction == .right ? frame.minX >= origin.midX : frame.maxX <= origin.midX)
      }
      return ahead.min { lhs, rhs in
        abs(lhs.1.midX - origin.midX) + abs(lhs.1.midY - origin.midY) * 2 <
          abs(rhs.1.midX - origin.midX) + abs(rhs.1.midY - origin.midY) * 2
      }?.0
    default:
      return nil
    }
  }

  // MARK: Focus

  private func focusInitial(_ targets: [Target], window: NSWindow) {
    if column == .sidebar,
       let selected = targets.first(where: {
         $0.kind == .row && ($0.view as? NSTableView)?.selectedRow == $0.row
       }) {
      focus(selected, window: window)
      return
    }
    let visible = targets.filter { target in
      guard let frame = frame(of: target) else { return false }
      return frame.intersects(visibleFrame(of: target, in: window))
    }
    if isDeck, column == .detail, let primary = visible.first(where: { $0.key == "primary" }) {
      focus(primary, window: window)
      return
    }
    let pool = visible.isEmpty ? targets : visible
    let top = pool.max { lhs, rhs in
      let l = frame(of: lhs) ?? .zero
      let r = frame(of: rhs) ?? .zero
      return l.maxY == r.maxY ? l.minX > r.minX : l.maxY < r.maxY
    }
    if let top {
      focus(top, window: window)
    }
  }

  private func switchColumn(to target: Column, targets: [Target], window: NSWindow) {
    endTextEditing(in: window)
    column = isDeckMain(window) ? .detail : target
    current = nil
    focusInitial(collectTargets(in: window), window: window)
  }

  private func focus(_ target: Target, window: NSWindow) {
    current = target
    if let section = (target.view as? ControllerFocusAnchorView)?.section {
      sectionMemory[section] = (target.view, target.row)
    }
    if target.kind == .row, let table = target.view as? NSTableView {
      if table.selectedRow != target.row {
        table.selectRowIndexes(IndexSet(integer: target.row), byExtendingSelection: false)
      }
      table.scrollRowToVisible(target.row)
      if window.firstResponder !== table {
        window.makeFirstResponder(table)
      }
      return
    }
    reveal(target)
  }

  /// Scrolls every enclosing scroll view so the target is on screen. SwiftUI
  /// scroll views follow their clip view but ignore -scrollToVisible:.
  private func reveal(_ target: Target) {
    guard let frame = frame(of: target), let window = target.view.window else { return }
    var view: NSView = target.view
    while let scrollView = view.enclosingScrollView {
      if let document = scrollView.documentView {
        let rect = document.convert(window.convertFromScreen(frame), from: nil).insetBy(dx: 0, dy: -36)
        let clip = scrollView.contentView
        var bounds = clip.bounds
        if document.frame.height > bounds.height + 1 {
          if rect.height >= bounds.height || rect.minY < bounds.minY {
            bounds.origin.y = rect.minY
          } else if rect.maxY > bounds.maxY {
            bounds.origin.y = rect.maxY - bounds.height
          }
        }
        if document.frame.width > bounds.width + 1 {
          let wide = rect.insetBy(dx: -36, dy: 0)
          if wide.width >= bounds.width || wide.minX < bounds.minX {
            bounds.origin.x = wide.minX
          } else if wide.maxX > bounds.maxX {
            bounds.origin.x = wide.maxX - bounds.width
          }
        }
        scroll(scrollView, to: bounds)
      }
      view = scrollView
    }
  }

  private func scroll(_ scrollView: NSScrollView, to bounds: NSRect) {
    let clip = scrollView.contentView
    let origin = clip.constrainBoundsRect(bounds).origin
    guard origin != clip.bounds.origin else { return }
    clip.scroll(to: origin)
    scrollView.reflectScrolledClipView(clip)
  }

  /// Scrolls the column a page (a row sideways); returns false at the end of the content.
  private func pageScroll(toward direction: ControllerFocusInput, from current: Target) -> Bool {
    let vertical = direction == .up || direction == .down
    guard let scrollView = Self.scrollView(for: current.view, vertical: vertical),
          let document = scrollView.documentView else {
      return false
    }
    let clip = scrollView.contentView
    let before = clip.bounds.origin
    if vertical {
      let step = clip.bounds.height * 0.6
      let delta = (document.isFlipped == (direction == .down)) ? step : -step
      scroll(scrollView, to: clip.bounds.offsetBy(dx: 0, dy: delta))
    } else {
      let step = clip.bounds.width * 0.6
      scroll(scrollView, to: clip.bounds.offsetBy(dx: direction == .right ? step : -step, dy: 0))
    }
    return clip.bounds.origin != before
  }

  // MARK: Context menu

  /// The Menu button: the menu of the focused control, else of the smallest marked region around it.
  private func presentContextMenu(in window: NSWindow) {
    let pagePanel = {
      if self.isDeckMain(window), let page = Self.pageMenu?() {
        ControllerMenuPanel.shared.present(menu: page.menu, title: page.title, in: window,
                                           selectedIndex: -1, firstIndex: 0, onClose: nil)
      }
    }
    guard let current, let frame = frame(of: current), let content = window.contentView else {
      pagePanel()
      return
    }
    if let anchor = current.view as? ControllerFocusAnchorView {
      if let provider = anchor.contextMenu ?? anchor.menuProvider {
        let built = provider()
        ControllerMenuPanel.shared.present(menu: built.menu, title: built.title, in: window,
                                           selectedIndex: -1, firstIndex: 0, onClose: nil)
        return
      }
    }
    var anchors: [ControllerFocusAnchorView] = []
    Self.anchors(in: content, into: &anchors)
    let point = NSPoint(x: frame.midX, y: frame.midY)
    let best = anchors
      .filter { $0.contextMenu != nil }
      .compactMap { anchor -> (ControllerFocusAnchorView, CGFloat)? in
        guard let f = self.frame(of: Target(kind: .anchor, view: anchor)), f.contains(point) else { return nil }
        return (anchor, f.width * f.height)
      }
      .min { $0.1 < $1.1 }?.0
    if let provider = best?.contextMenu {
      let built = provider()
      ControllerMenuPanel.shared.present(menu: built.menu, title: built.title, in: window,
                                         selectedIndex: -1, firstIndex: 0, onClose: nil)
    } else {
      pagePanel()
    }
  }

  private static func anchors(in view: NSView, into out: inout [ControllerFocusAnchorView]) {
    guard !view.isHidden else { return }
    if let anchor = view as? ControllerFocusAnchorView {
      out.append(anchor)
      return
    }
    for subview in view.subviews { anchors(in: subview, into: &out) }
  }

  @discardableResult
  private func endTextEditing(in window: NSWindow) -> Bool {
    guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else { return false }
    window.makeFirstResponder(nil)
    return true
  }

  // MARK: Actions

  /// D-pad left/right on a value control changes the value instead of moving.
  private func adjust(_ target: Target, forward: Bool) -> Bool {
    switch target.view {
    case let anchor as ControllerFocusAnchorView:
      guard let adjust = anchor.adjust else { return false }
      adjust(forward ? 1 : -1)
      return true
    case let slider as NSSlider:
      let range = slider.maxValue - slider.minValue
      var step = range / 20
      if slider.numberOfTickMarks > 1 {
        step = range / Double(slider.numberOfTickMarks - 1)
      } else if slider.altIncrementValue > 0 {
        step = slider.altIncrementValue
      }
      setValue(of: slider, to: slider.doubleValue + (forward ? step : -step))
      return true
    case let stepper as NSStepper:
      setValue(of: stepper, to: stepper.doubleValue + (forward ? stepper.increment : -stepper.increment))
      return true
    case let segments as NSSegmentedControl:
      selectSegment(in: segments, step: forward ? 1 : -1, wrap: false)
      return true
    case let popUp as NSPopUpButton where !popUp.pullsDown:
      stepPopUp(popUp, forward: forward)
      return true
    default:
      return false
    }
  }

  private func setValue(of control: NSControl, to value: Double) {
    var minimum = -Double.greatestFiniteMagnitude
    var maximum = Double.greatestFiniteMagnitude
    if let slider = control as? NSSlider {
      minimum = slider.minValue
      maximum = slider.maxValue
    } else if let stepper = control as? NSStepper {
      minimum = stepper.minValue
      maximum = stepper.maxValue
    }
    control.doubleValue = min(max(value, minimum), maximum)
    control.sendAction(control.action, to: control.target)
  }

  private func activate(_ target: Target, window: NSWindow) {
    switch target.view {
    case let anchor as ControllerFocusAnchorView:
      if let provider = anchor.menuProvider {
        let built = provider()
        ControllerMenuPanel.shared.present(
          menu: built.menu, title: built.title, in: window,
          selectedIndex: -1, firstIndex: 0, onClose: nil)
      } else if let choices = anchor.choices {
        presentChoices(choices(), in: window)
      } else {
        anchor.trigger?()
      }
    case let popUp as NSPopUpButton:
      guard let menu = popUp.menu else { return }
      ControllerMenuPanel.shared.present(
        menu: menu, title: popUp.pullsDown ? "" : (popUp.titleOfSelectedItem ?? ""), in: window,
        selectedIndex: popUp.pullsDown ? -1 : popUp.indexOfSelectedItem,
        firstIndex: popUp.pullsDown ? 1 : 0, onClose: nil)
    case let button as NSButton:
      button.performClick(nil)
    case let toggle as NSSwitch:
      toggle.performClick(nil)
    case let stepper as NSStepper:
      setValue(of: stepper, to: stepper.doubleValue + stepper.increment)
    case let segments as NSSegmentedControl:
      selectSegment(in: segments, step: 1, wrap: true)
    case let field as NSTextField:
      if window.makeFirstResponder(field) {
        ControllerKeyboardPanel.shared.present(in: window)
      }
    case is NSTableView:
      switchColumn(to: .detail, targets: [], window: window)
    default:
      break
    }
  }

  /// Lists a SwiftUI picker's options in the controller menu.
  private func presentChoices(_ choices: ControllerFocusChoices, in window: NSWindow) {
    let menu = NSMenu()
    menu.autoenablesItems = false
    for (index, title) in choices.titles.enumerated() {
      let item = NSMenuItem(title: title, action: #selector(ControllerChoiceTarget.choose(_:)), keyEquivalent: "")
      let target = ControllerChoiceTarget { choices.select(index) }
      item.target = target
      item.representedObject = target
      menu.addItem(item)
    }
    let selected = choices.titles.indices.contains(choices.selectedIndex) ? choices.selectedIndex : -1
    ControllerMenuPanel.shared.present(
      menu: menu, title: selected >= 0 ? choices.titles[selected] : "", in: window,
      selectedIndex: selected, firstIndex: 0, onClose: nil)
  }

  private func selectSegment(in control: NSSegmentedControl, step: Int, wrap: Bool) {
    let count = control.segmentCount
    guard count > 0 else { return }
    let selected = max(control.selectedSegment, 0)
    var next = selected
    for _ in 0..<count {
      next += step
      if wrap {
        next = (next + count) % count
      } else if next < 0 || next >= count {
        return
      }
      if control.isEnabled(forSegment: next) { break }
    }
    guard next != selected else { return }
    control.selectedSegment = next
    control.sendAction(control.action, to: control.target)
  }

  private func stepPopUp(_ popUp: NSPopUpButton, forward: Bool) {
    guard let menu = popUp.menu else { return }
    var index = popUp.indexOfSelectedItem
    repeat {
      index += forward ? 1 : -1
    } while index >= 0 && index < menu.numberOfItems &&
      (menu.item(at: index)?.isSeparatorItem == true || menu.item(at: index)?.isEnabled == false ||
       menu.item(at: index)?.isHidden == true)
    guard index >= 0 && index < menu.numberOfItems else { return }
    // SwiftUI pickers update their binding from the item's own action.
    menu.performActionForItem(at: index)
  }
}

/// Menu item target for a picker option; the item retains it.
final class ControllerChoiceTarget: NSObject {
  private let action: () -> Void
  init(_ action: @escaping () -> Void) { self.action = action }
  @objc func choose(_ sender: Any?) { action() }
}

// MARK: - Controller menu panel

/// A console-style list that presents any NSMenu for controller use: the
/// stream control center, and pop-ups or pull-downs in settings.
@objc final class ControllerMenuPanel: NSObject {
  @objc static let shared = ControllerMenuPanel()

  private var panel: NSPanel?
  private var host: NSHostingView<ControllerMenuView>?
  private let model = ControllerMenuModel()
  private var onClose: ((Bool) -> Void)?
  private var closeObserver: NSObjectProtocol?
  @objc private(set) weak var parentWindow: NSWindow?

  @objc var isPresented: Bool { panel != nil }

  @objc(presentMenu:title:inWindow:selectedIndex:firstIndex:onClose:)
  func present(menu: NSMenu, title: String, in window: NSWindow, selectedIndex: Int, firstIndex: Int,
               onClose: ((Bool) -> Void)?) {
    dismiss(performed: false)
    menu.update()
    model.reset(menu: menu, title: title, selectedIndex: selectedIndex, firstIndex: firstIndex)
    model.onActivate = { [weak self] menu, index in self?.perform(menu: menu, index: index) }
    model.onLayoutChange = { [weak self] in self?.layout() }
    self.onClose = onClose

    let host = NSHostingView(rootView: ControllerMenuView(model: model))
    let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
    panel.contentView = host
    self.panel = panel
    self.host = host
    parentWindow = window
    layout()
    window.addChildWindow(panel, ordered: .above)
    panel.orderFront(nil)
    closeObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: window, queue: .main
    ) { [weak self] _ in self?.dismiss(performed: false) }
  }

  @objc(handleInput:)
  func handle(_ input: ControllerFocusInput) {
    guard isPresented else { return }
    switch input {
    case .up: model.moveFocus(by: -1)
    case .down: model.moveFocus(by: 1)
    case .left: model.left()
    case .right: model.right()
    case .accept: model.accept()
    case .back:
      if !model.pop(source: "back") {
        dismiss(performed: false)
      }
    case .previousColumn: model.moveFocus(by: -6)
    case .nextColumn: model.moveFocus(by: 6)
    case .delete, .space, .done, .contextMenu, .previousSection, .nextSection: break
    }
  }

  @objc func dismiss() {
    dismiss(performed: false)
  }

  private func dismiss(performed: Bool) {
    guard let panel else { return }
    LogMessage(LOG_I, "[diag] controller-panel closed performed=\(performed) depth=\(model.levels.count)")
    if let closeObserver {
      NotificationCenter.default.removeObserver(closeObserver)
    }
    closeObserver = nil
    parentWindow?.removeChildWindow(panel)
    panel.orderOut(nil)
    self.panel = nil
    host = nil
    parentWindow = nil
    let onClose = self.onClose
    self.onClose = nil
    onClose?(performed)
  }

  private func perform(menu: NSMenu, index: Int) {
    // Close first so whatever the item presents is not covered by the panel.
    dismiss(performed: true)
    menu.performActionForItem(at: index)
  }

  private func layout() {
    guard let panel, let host, let parent = parentWindow else { return }
    let width: CGFloat = 460
    let maxHeight = max(240, parent.frame.height * 0.8)
    let height = min(maxHeight, model.preferredHeight)
    let frame = NSRect(x: parent.frame.midX - width / 2, y: parent.frame.midY - height / 2,
                       width: width, height: height)
    host.frame = NSRect(origin: .zero, size: frame.size)
    panel.setFrame(frame, display: true)
  }
}

final class ControllerMenuModel: ObservableObject {
  struct Level {
    let menu: NSMenu
    let title: String
    let selectedIndex: Int
    let firstIndex: Int
    var focus: Int
  }

  enum RowKind { case item, separator, header, slider }

  struct Row: Identifiable {
    let index: Int
    let kind: RowKind
    let title: String
    let detail: String
    let image: NSImage?
    let checked: Bool
    let enabled: Bool
    let hasSubmenu: Bool
    let fraction: Double
    var id: Int { index }
    var focusable: Bool { enabled && (kind == .item || kind == .slider) }
  }

  @Published private(set) var levels: [Level] = []
  @Published private(set) var revision = 0
  var onActivate: ((NSMenu, Int) -> Void)?
  var onLayoutChange: (() -> Void)?

  var title: String { levels.map(\.title).filter { !$0.isEmpty }.joined(separator: "  ›  ") }
  var canGoBack: Bool { levels.count > 1 }
  var focus: Int { levels.last?.focus ?? -1 }

  var rows: [Row] {
    guard let level = levels.last else { return [] }
    return (level.firstIndex..<level.menu.numberOfItems).compactMap { index in
      guard let item = level.menu.item(at: index), !item.isHidden else { return nil }
      return Self.row(for: item, index: index, selected: index == level.selectedIndex)
    }
  }

  var preferredHeight: CGFloat {
    let content = rows.reduce(CGFloat(0)) { height, row in
      switch row.kind {
      case .item: return height + 40
      case .separator: return height + 11
      case .header: return height + 28
      case .slider: return height + 58
      }
    }
    return content + 96
  }

  func reset(menu: NSMenu, title: String, selectedIndex: Int, firstIndex: Int) {
    levels = [Level(menu: menu, title: title, selectedIndex: selectedIndex, firstIndex: firstIndex, focus: -1)]
    levels[0].focus = initialFocus()
  }

  func moveFocus(by delta: Int) {
    let focusable = rows.filter(\.focusable).map(\.index)
    guard !focusable.isEmpty, !levels.isEmpty else { return }
    let position = focusable.firstIndex(of: focus) ?? 0
    let next = min(max(position + delta, 0), focusable.count - 1)
    levels[levels.count - 1].focus = focusable[next]
  }

  func left() {
    if let row = focusedRow, row.kind == .slider {
      adjustSlider(row, forward: false)
    } else {
      _ = pop(source: "left")
    }
  }

  func right() {
    guard let row = focusedRow else { return }
    if row.kind == .slider {
      adjustSlider(row, forward: true)
    } else if row.hasSubmenu {
      push(row)
    }
  }

  func accept() {
    guard let row = focusedRow, let level = levels.last else { return }
    switch row.kind {
    case .item where row.hasSubmenu:
      push(row)
    case .item:
      onActivate?(level.menu, row.index)
    default:
      break
    }
  }

  func activate(index: Int) {
    guard let level = levels.last else { return }
    levels[levels.count - 1].focus = index
    accept()
    _ = level
  }

  /// source names the input that went back, so a log shows what moved the user up a level.
  func pop(source: String) -> Bool {
    guard levels.count > 1 else { return false }
    let closed = levels.removeLast()
    LogMessage(LOG_I, "[diag] controller-panel level popped by \(source): closed=\"\(closed.title)\" depth=\(levels.count)")
    onLayoutChange?()
    return true
  }

  private var focusedRow: Row? {
    rows.first { $0.index == focus }
  }

  private func initialFocus() -> Int {
    let rows = self.rows
    if let selected = rows.first(where: { $0.checked && $0.focusable }) {
      return selected.index
    }
    return rows.first(where: \.focusable)?.index ?? -1
  }

  private func push(_ row: Row) {
    guard let level = levels.last, let item = level.menu.item(at: row.index), let submenu = item.submenu else { return }
    submenu.update()
    LogMessage(LOG_I, "[diag] controller-panel level pushed: \"\(row.title)\" items=\(submenu.numberOfItems) depth=\(levels.count + 1)")
    levels.append(Level(menu: submenu, title: row.title, selectedIndex: -1, firstIndex: 0, focus: -1))
    levels[levels.count - 1].focus = initialFocus()
    onLayoutChange?()
  }

  private func adjustSlider(_ row: Row, forward: Bool) {
    guard let level = levels.last, let view = level.menu.item(at: row.index)?.view,
          let slider = Self.firstSubview(of: NSSlider.self, in: view) else { return }
    let range = slider.maxValue - slider.minValue
    var step = range / 20
    if slider.numberOfTickMarks > 1 {
      step = range / Double(slider.numberOfTickMarks - 1)
    } else if slider.altIncrementValue > 0 {
      step = slider.altIncrementValue
    }
    slider.doubleValue = min(max(slider.doubleValue + (forward ? step : -step), slider.minValue), slider.maxValue)
    slider.sendAction(slider.action, to: slider.target)
    revision += 1
  }

  private static func row(for item: NSMenuItem, index: Int, selected: Bool) -> Row {
    if item.isSeparatorItem {
      return Row(index: index, kind: .separator, title: "", detail: "", image: nil, checked: false,
                 enabled: false, hasSubmenu: false, fraction: 0)
    }
    if let view = item.view {
      let labels = textFields(in: view).map(\.stringValue).filter { !$0.isEmpty }
      if let slider = firstSubview(of: NSSlider.self, in: view) {
        let range = slider.maxValue - slider.minValue
        let fraction = range > 0 ? (slider.doubleValue - slider.minValue) / range : 0
        return Row(index: index, kind: .slider, title: labels.first ?? item.title,
                   detail: labels.dropFirst().joined(separator: " "), image: item.image, checked: false,
                   enabled: slider.isEnabled, hasSubmenu: false, fraction: fraction)
      }
      return Row(index: index, kind: .header, title: labels.joined(separator: " "), detail: "", image: nil,
                 checked: false, enabled: false, hasSubmenu: false, fraction: 0)
    }
    var isHeader = false
    if #available(macOS 14.0, *) {
      isHeader = item.isSectionHeader
    }
    let title = item.attributedTitle?.string ?? item.title
    return Row(index: index, kind: isHeader ? .header : .item, title: title, detail: "",
               image: item.image, checked: selected || item.state == .on,
               enabled: item.isEnabled && !isHeader, hasSubmenu: item.hasSubmenu, fraction: 0)
  }

  private static func firstSubview<T: NSView>(of type: T.Type, in view: NSView) -> T? {
    if let match = view as? T { return match }
    for subview in view.subviews {
      if let match = firstSubview(of: type, in: subview) { return match }
    }
    return nil
  }

  private static func textFields(in view: NSView) -> [NSTextField] {
    var fields: [NSTextField] = []
    if let field = view as? NSTextField, !field.isEditable, !field.isHidden {
      fields.append(field)
    }
    for subview in view.subviews {
      fields.append(contentsOf: textFields(in: subview))
    }
    return fields.sorted { $0.frame.minX < $1.frame.minX }
  }
}

struct ControllerMenuView: View {
  @ObservedObject var model: ControllerMenuModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        if model.canGoBack {
          Image(systemName: "chevron.left")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
        }
        Text(model.title)
          .font(.headline)
          .lineLimit(1)
        Spacer()
      }
      .padding(.horizontal, 18)
      .padding(.vertical, 14)

      Divider()

      ScrollViewReader { proxy in
        ScrollView {
          VStack(spacing: 2) {
            ForEach(model.rows) { row in
              rowView(row)
                .id(row.index)
            }
          }
          .padding(8)
          .id(model.revision)
        }
        .onChange(of: model.focus) { focus in
          withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(focus, anchor: .center) }
        }
        .onAppear { proxy.scrollTo(model.focus, anchor: .center) }
      }
    }
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
  }

  @ViewBuilder
  private func rowView(_ row: ControllerMenuModel.Row) -> some View {
    let focused = row.index == model.focus
    switch row.kind {
    case .separator:
      Divider().padding(.vertical, 5).padding(.horizontal, 6)
    case .header:
      Text(row.title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
    case .slider:
      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Text(row.title)
          Spacer()
          Text(row.detail).foregroundStyle(focused ? Color.white.opacity(0.85) : .secondary)
        }
        HStack(spacing: 8) {
          Image(systemName: "chevron.left").font(.system(size: 10, weight: .bold))
          ProgressView(value: row.fraction)
            .tint(focused ? .white : .accentColor)
          Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
        }
        .foregroundStyle(focused ? Color.white.opacity(0.85) : .secondary)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .foregroundStyle(focused ? Color.white : Color.primary)
      .background(highlight(focused))
    case .item:
      HStack(spacing: 10) {
        Group {
          if let image = row.image {
            Image(nsImage: image).renderingMode(.template)
          } else {
            Color.clear
          }
        }
        .frame(width: 20, height: 20)
        Text(row.title).lineLimit(1)
        Spacer(minLength: 8)
        if row.checked {
          Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold))
        }
        if row.hasSubmenu {
          Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
            .foregroundStyle(focused ? Color.white.opacity(0.85) : .secondary)
        }
      }
      .padding(.horizontal, 12)
      .frame(height: 38)
      .foregroundStyle(focused ? Color.white : Color.primary)
      .opacity(row.enabled ? 1 : 0.4)
      .background(highlight(focused))
      .contentShape(Rectangle())
      .onTapGesture { if row.enabled { model.activate(index: row.index) } }
    }
  }

  private func highlight(_ focused: Bool) -> some View {
    RoundedRectangle(cornerRadius: 9, style: .continuous)
      .fill(focused ? Color.accentColor : Color.clear)
  }
}
