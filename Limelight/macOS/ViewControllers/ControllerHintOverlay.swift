import AppKit
import SwiftUI

/// Where controller navigation is acting, which decides the legend shown.
@objc enum ControllerHintContext: Int {
  case none
  case library
  case settings
  case menu
}

private struct ControllerHintItem: Identifiable {
  let symbols: [String]
  let fallback: String
  let labelKey: String
  var id: String { labelKey }
}

private struct ControllerHintView: View {
  @ObservedObject private var languageManager = LanguageManager.shared
  let items: [ControllerHintItem]

  var body: some View {
    HStack(spacing: 14) {
      ForEach(items) { item in
        HStack(spacing: 5) {
          if !item.symbols.isEmpty {
            ForEach(item.symbols, id: \.self) { symbol in
              Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
            }
          } else {
            Text(item.fallback)
              .font(.system(size: 13, weight: .semibold, design: .rounded))
          }
          Text(languageManager.localize(item.labelKey))
            .font(.callout)
        }
      }
    }
    .foregroundColor(.primary)
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .background(.regularMaterial, in: Capsule())
    .overlay(Capsule().stroke(Color.secondary.opacity(0.18), lineWidth: 1))
    .fixedSize()
  }
}

/// Bottom-right legend of controller actions while a controller drives the interface.
@objc final class ControllerHintPresenter: NSObject {
  private static let margin: CGFloat = 16

  private var panel: NSPanel?
  private weak var parent: NSWindow?
  private var context: ControllerHintContext = .none
  private var family: ControllerGlyphFamily?
  private var parentFrame: NSRect = .zero

  @objc(updateWithWindow:context:)
  func update(window: NSWindow?, context: ControllerHintContext) {
    guard let window, context != .none, window.isVisible else {
      hide()
      return
    }
    let family = ControllerGlyphFamily.current
    if window !== parent || context != self.context || family != self.family || panel == nil {
      show(in: window, context: context, family: family)
    } else if window.frame != parentFrame {
      position()
    }
  }

  @objc func hide() {
    if let panel {
      panel.parent?.removeChildWindow(panel)
      panel.orderOut(nil)
    }
    panel = nil
    parent = nil
    context = .none
    family = nil
  }

  private func show(in window: NSWindow, context: ControllerHintContext, family: ControllerGlyphFamily) {
    hide()
    let host = NSHostingView(rootView: ControllerHintView(items: Self.items(for: context, family: family)))
    let size = host.fittingSize
    let panel = NSPanel(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: true)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.ignoresMouseEvents = true
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
    panel.contentView = host
    self.panel = panel
    self.parent = window
    self.context = context
    self.family = family
    position()
    window.addChildWindow(panel, ordered: .above)
    panel.orderFront(nil)
  }

  private func position() {
    guard let panel, let parent else { return }
    parentFrame = parent.frame
    let size = panel.frame.size
    let origin = NSPoint(
      x: parentFrame.maxX - size.width - Self.margin,
      y: parentFrame.minY + Self.margin)
    panel.setFrameOrigin(origin)
  }

  private static func items(for context: ControllerHintContext, family: ControllerGlyphFamily)
    -> [ControllerHintItem]
  {
    func symbol(_ name: String) -> [String] {
      NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil ? [name] : []
    }
    func button(_ button: ControllerTouchpadShortcut.Button, _ key: String) -> ControllerHintItem {
      ControllerHintItem(symbols: button.symbolName(family).map { [$0] } ?? [],
                         fallback: button.displayName(family), labelKey: key)
    }
    let move = ControllerHintItem(symbols: symbol("dpad"), fallback: "✥", labelKey: "Controller Hint Move")
    let adjust = ControllerHintItem(
      symbols: symbol("dpad.left.filled") + symbol("dpad.right.filled"), fallback: "◀▶",
      labelKey: "Controller Hint Adjust")
    switch context {
    case .library:
      return [move, button(.a, "Controller Hint Open"), button(.b, "Controller Hint Back"),
              button(.menu, "Controller Hint Settings"), button(.view, "Controller Hint Search")]
    case .settings:
      let shoulders = [ControllerTouchpadShortcut.Button.leftShoulder, .rightShoulder].compactMap { $0.symbolName(family) }
      let column = ControllerHintItem(
        symbols: shoulders.count == 2 ? shoulders : [],
        fallback: family == .playStation ? "L1 R1" : "LB RB", labelKey: "Controller Hint Column")
      return [move, adjust, button(.a, "Controller Hint Select"), button(.b, "Controller Hint Back"), column,
              button(.view, "Controller Hint Search")]
    case .menu:
      return [move, adjust, button(.a, "Controller Hint Confirm"), button(.b, "Controller Hint Back")]
    case .none:
      return []
    }
  }
}
