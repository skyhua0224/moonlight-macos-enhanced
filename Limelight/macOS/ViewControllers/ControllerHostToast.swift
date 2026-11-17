import AppKit
import SwiftUI

// What LB / RB did: a small pill over the page that names the computer now selected ("‹  Name  2/5  ›").
// It lives in a child window of the Deck window, so nothing in the page moves or re-lays out, and it goes away
// by itself. The page behind is rebuilt for the new computer; this is the feedback that the press was taken
// even where the list ends and the selection does not change.

private struct ControllerHostToastView: View {
  let name: String
  let index: Int
  let count: Int

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "chevron.left").opacity(index > 0 ? 1 : 0.3)
      Text(name).lineLimit(1).truncationMode(.tail)
      Text("\(index + 1)/\(count)").monospacedDigit().foregroundStyle(.secondary)
      Image(systemName: "chevron.right").opacity(index < count - 1 ? 1 : 0.3)
    }
    .font(.system(size: 15, weight: .semibold))
    .padding(.horizontal, 18)
    .frame(height: 40)
    .background(.regularMaterial, in: Capsule())
    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
    .fixedSize()
  }
}

@objc final class ControllerHostToast: NSObject {
  @objc static let shared = ControllerHostToast()
  static let notification = Notification.Name("MLDeckPadHostSwitched")

  private var panel: NSPanel?
  private weak var parent: NSWindow?
  private var hideWork: DispatchWorkItem?
  private var observer: NSObjectProtocol?
  /// the line now shown, for the harness
  @objc private(set) var shownText = ""

  private override init() {
    super.init()
    observer = NotificationCenter.default.addObserver(forName: Self.notification, object: nil, queue: .main) { [weak self] note in
      guard let info = note.userInfo, let name = info["name"] as? String,
            let index = info["index"] as? Int, let count = info["count"] as? Int else { return }
      self?.show(name: name, index: index, count: count)
    }
  }

  @objc func dismiss() {
    hideWork?.cancel()
    shownText = ""
    guard let panel else { return }
    parent?.removeChildWindow(panel)
    panel.orderOut(nil)
    parent = nil
  }

  private func mainWindow() -> NSWindow? {
    NSApp.windows.first { $0.identifier?.rawValue == "MainWindow" && $0.isVisible }
  }

  private func show(name: String, index: Int, count: Int) {
    guard let window = mainWindow(), let content = window.contentView else { return }
    let hosting = NSHostingView(rootView: ControllerHostToastView(name: name, index: index, count: count))
    let size = hosting.fittingSize
    let panel = self.panel ?? makePanel()
    self.panel = panel
    panel.contentView = hosting
    // top centre of the page (right of the sidebar), under the title bar
    let layout = window.convertToScreen(window.contentLayoutRect)
    let sidebarEdge: CGFloat = content.subviews.first { $0 is NSSplitView }.flatMap { split in
      (split as? NSSplitView)?.arrangedSubviews.first.map { window.convertToScreen($0.convert($0.bounds, to: nil)).maxX }
    } ?? layout.minX
    let region = NSRect(x: sidebarEdge, y: layout.minY, width: max(layout.maxX - sidebarEdge, size.width), height: layout.height)
    let origin = NSPoint(x: (region.midX - size.width / 2).rounded(), y: (region.maxY - size.height - 14).rounded())
    panel.setFrame(NSRect(origin: origin, size: size), display: true)
    if parent !== window {
      parent?.removeChildWindow(panel)
      window.addChildWindow(panel, ordered: .above)
      parent = window
    }
    panel.orderFront(nil)
    shownText = "\(name) \(index + 1)/\(count)"
    hideWork?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.dismiss() }
    hideWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
  }

  private func makePanel() -> NSPanel {
    let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.ignoresMouseEvents = true
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
    return panel
  }
}
