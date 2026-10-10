import AppKit

/// Dimmed backdrop with a spinning indicator, shown over the stream view until
/// the first frame is presented. Plain AppKit on purpose: the indicator animates
/// on its own thread, so a busy main thread during startup cannot freeze it, and
/// it does not depend on a SwiftUI hosting view surviving the stream view's
/// re-parenting, window changes and full-screen transitions.
private final class StartupOverlayView: NSView {
  private let spinner = NSProgressIndicator()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.backgroundColor = NSColor.black.withAlphaComponent(0.2).cgColor
    appearance = NSAppearance(named: .darkAqua)

    spinner.style = .spinning
    spinner.controlSize = .large
    spinner.isIndeterminate = true
    spinner.usesThreadedAnimation = true
    spinner.isDisplayedWhenStopped = false
    spinner.sizeToFit()
    spinner.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
    addSubview(spinner)
    centerSpinner()

    setAccessibilityElement(true)
    setAccessibilityRole(.progressIndicator)
    setAccessibilityLabel(NSLocalizedString("Connecting", comment: ""))
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override var isHidden: Bool {
    didSet { updateAnimation() }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    updateAnimation()
  }

  override func layout() {
    super.layout()
    centerSpinner()
  }

  private func centerSpinner() {
    let size = spinner.frame.size
    spinner.frame = NSRect(
      x: ((bounds.width - size.width) / 2).rounded(),
      y: ((bounds.height - size.height) / 2).rounded(),
      width: size.width,
      height: size.height)
  }

  private func updateAnimation() {
    if isHidden || window == nil {
      spinner.stopAnimation(nil)
    } else {
      spinner.startAnimation(nil)
    }
  }
}

@objc final class StreamingStartupOverlayFactory: NSObject {
  @objc static func makeView() -> NSView {
    StartupOverlayView(frame: .zero)
  }
}
