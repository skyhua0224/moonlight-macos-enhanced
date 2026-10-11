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
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Whether a game controller is connected, which is when ControllerNavigation drives the
/// focus (it uses the same list of controllers).
final class ControllerPresence: ObservableObject {
  static let shared = ControllerPresence()

  @Published private(set) var isConnected = !GCController.controllers().isEmpty
  private var observers: [NSObjectProtocol] = []

  private init() {
    for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
      observers.append(
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
          [weak self] _ in
          let connected = !GCController.controllers().isEmpty
          if self?.isConnected != connected { self?.isConnected = connected }
        })
    }
  }
}

/// The marker behind a control, present only while a controller is connected. Every marker
/// is an AppKit view inside the SwiftUI tree, and a settings page has one per control: they
/// are much of what building the page, scrolling it and finding what is under the pointer
/// cost. Without a controller nothing looks for them.
private struct ControllerFocusAnchor: View {
  let enabled: Bool
  var trigger: (() -> Void)?
  var adjust: ((Int) -> Void)?
  var choices: (() -> ControllerFocusChoices)?
  var menuProvider: (() -> (title: String, menu: NSMenu))?
  @ObservedObject private var presence = ControllerPresence.shared

  var body: some View {
    if presence.isConnected {
      ControllerFocusAnchorRepresentable(
        enabled: enabled, trigger: trigger, adjust: adjust, choices: choices,
        menuProvider: menuProvider
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

extension View {
  /// Drop-in for `.buttonStyle(_:)` that keeps the button reachable by controller.
  func controllerButtonStyle<S: PrimitiveButtonStyle>(_ style: S) -> some View {
    buttonStyle(ControllerFocusButtonStyle(base: style))
  }

  /// Makes a gesture-driven control reachable by controller; A runs `action`.
  func controllerFocusTarget(enabled: Bool = true, _ action: @escaping () -> Void) -> some View {
    background(ControllerFocusAnchor(enabled: enabled, trigger: action))
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

private final class ControllerFocusRingView: NSView {
  override func draw(_ dirtyRect: NSRect) {
    let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8)
    path.lineWidth = 3
    NSColor.controlAccentColor.setStroke()
    path.stroke()
  }
}

private final class ControllerFocusRing {
  private var panel: NSPanel?
  private weak var parent: NSWindow?

  func show(_ frame: NSRect, in window: NSWindow) {
    let rect = frame.insetBy(dx: -5, dy: -5).integral
    let panel = self.panel ?? makePanel()
    self.panel = panel
    if parent !== window {
      parent?.removeChildWindow(panel)
      window.addChildWindow(panel, ordered: .above)
      parent = window
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
  }

  private weak var window: NSWindow?
  private var column: Column = .detail
  private var current: Target?
  private let ring = ControllerFocusRing()
  private var pendingDirection: ControllerFocusInput?
  private var pendingTicks = 0
  private var pendingRetries = 0
  private var pendingKeyboardTicks = 0

  // MARK: Entry points

  /// Returns false when the input was not used (B with nowhere to go back to).
  @objc(handleInput:window:)
  @discardableResult
  func handle(_ input: ControllerFocusInput, window: NSWindow) -> Bool {
    if self.window !== window {
      self.window = window
      current = nil
      column = sidebarFrame(in: window) != nil ? .sidebar : .detail
    }
    pendingDirection = nil

    var targets = collectTargets(in: window)
    if let current, !targets.contains(where: { $0.same(as: current) }) {
      self.current = nil
    }

    switch input {
    case .previousColumn, .nextColumn:
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
      if column == .detail && sidebarFrame(in: window) != nil {
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
      } else if sidebarFrame(in: window) != nil {
        if input == .left && column == .detail {
          switchColumn(to: .sidebar, targets: targets, window: window)
        } else if input == .right && column == .sidebar {
          targets = collectTargets(in: window)
          switchColumn(to: .detail, targets: targets, window: window)
        }
      }
    case .accept:
      activate(current, window: window)
    default:
      break
    }
    return true
  }

  /// Focuses the settings search field after the View button raised it.
  @objc(focusSearchFieldInWindow:)
  func focusSearchField(in window: NSWindow) {
    self.window = window
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
    guard let window, window === self.window, showRing, let current else {
      ring.hide()
      if window == nil || window !== self.window {
        pendingDirection = nil
      }
      return
    }

    if let direction = pendingDirection {
      pendingTicks -= 1
      if pendingTicks <= 0 {
        let targets = collectTargets(in: window)
        if let next = neighbor(of: current, toward: direction, in: targets) {
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
      return
    }
    let visible = frame.intersection(visibleFrame(of: focused, in: window))
    if visible.height < 6 || visible.width < 6 {
      ring.hide()
    } else {
      ring.show(visible, in: window)
    }
  }

  @objc func reset() {
    ring.hide()
    window = nil
    current = nil
    pendingDirection = nil
    pendingKeyboardTicks = 0
    ControllerKeyboardPanel.shared.dismiss()
  }

  // MARK: Collection

  private func collectTargets(in window: NSWindow) -> [Target] {
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

    return targets.filter { target in
      guard let frame = frame(of: target), frame.width > 1, frame.height > 1 else { return false }
      guard frame.midX >= layout.minX, frame.midX <= layout.maxX, frame.midY <= layout.maxY else { return false }
      guard let sidebar else { return true }
      let inSidebar = frame.midX < sidebar.maxX
      return (column == .sidebar) == inSidebar
    }
  }

  private func collect(in view: NSView, into targets: inout [Target]) {
    guard !view.isHidden, view.alphaValue > 0 else { return }
    if let anchor = view as? ControllerFocusAnchorView {
      if anchor.isTargetEnabled {
        targets.append(Target(kind: .anchor, view: anchor))
      }
      return
    }
    if let table = view as? NSTableView {
      for row in 0..<table.numberOfRows {
        if table.delegate?.tableView?(table, isGroupRow: row) == true { continue }
        if table.delegate?.tableView?(table, shouldSelectRow: row) == false { continue }
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
      let ahead = candidates.filter { _, frame in
        direction == .down ? frame.maxY <= origin.midY : frame.minY >= origin.midY
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
    column = target
    current = nil
    focusInitial(collectTargets(in: window), window: window)
  }

  private func focus(_ target: Target, window: NSWindow) {
    current = target
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
        if rect.height >= bounds.height || rect.minY < bounds.minY {
          bounds.origin.y = rect.minY
        } else if rect.maxY > bounds.maxY {
          bounds.origin.y = rect.maxY - bounds.height
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

  /// Scrolls the column a page; returns false at the end of the content.
  private func pageScroll(toward direction: ControllerFocusInput, from current: Target) -> Bool {
    guard let scrollView = current.view.enclosingScrollView, let document = scrollView.documentView else {
      return false
    }
    let clip = scrollView.contentView
    let step = clip.bounds.height * 0.6
    let delta = (document.isFlipped == (direction == .down)) ? step : -step
    let before = clip.bounds.origin
    scroll(scrollView, to: clip.bounds.offsetBy(dx: 0, dy: delta))
    return clip.bounds.origin != before
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
    case .delete, .space, .done: break
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
