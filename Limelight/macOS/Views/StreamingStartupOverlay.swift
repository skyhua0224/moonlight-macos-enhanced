import AppKit
import CoreImage

/// Dimmed backdrop with a spinning indicator, shown over the stream view until
/// the first frame is presented. Plain AppKit on purpose: the indicator animates
/// on its own thread, so a busy main thread during startup cannot freeze it, and
/// it does not depend on a SwiftUI hosting view surviving the stream view's
/// re-parenting, window changes and full-screen transitions.
private final class StartupOverlayView: NSView {
  private let spinner = NSProgressIndicator()
  /// The blurred last frame of this app, or its box art, behind the spinner.
  private let backdrop = CALayer()
  /// Darkens the backdrop further when the Mac is in dark mode.
  private let backdropDim = CALayer()
  private var appearanceObservation: NSKeyValueObservation?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.backgroundColor = NSColor.black.withAlphaComponent(0.2).cgColor
    appearance = NSAppearance(named: .darkAqua)

    backdrop.contentsGravity = .resizeAspectFill
    backdrop.masksToBounds = true
    backdrop.isHidden = true
    layer?.addSublayer(backdrop)
    backdropDim.backgroundColor = NSColor.black.cgColor
    backdrop.addSublayer(backdropDim)
    updateBackdropDim()
    // The overlay itself is always dark; the Mac's own appearance decides the dimming.
    appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
      DispatchQueue.main.async { self?.updateBackdropDim() }
    }

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
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    backdrop.frame = bounds
    backdropDim.frame = backdrop.bounds
    CATransaction.commit()
    centerSpinner()
  }

  private func updateBackdropDim() {
    let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    backdropDim.opacity = dark ? 0.38 : 0
    CATransaction.commit()
  }

  func setBackdrop(_ image: NSImage?) {
    guard let image, let blurred = Self.frosted(image) else {
      backdrop.contents = nil
      backdrop.isHidden = true
      return
    }
    backdrop.contents = blurred
    backdrop.isHidden = false
  }

  /// Frosted like Screen Sharing: soft enough that the last screen is still recognisable, with
  /// brightness nudged toward the middle so the spinner reads on dark and bright pictures alike.
  private static func frosted(_ image: NSImage) -> CGImage? {
    guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    let input = CIImage(cgImage: source)
    let context = CIContext()
    let luminance = averageLuminance(of: input, context: context) ?? 0.4
    // Dark pictures are lifted a little, bright ones toned down a little.
    let brightness = luminance < 0.3 ? (0.3 - luminance) * 0.35 : luminance > 0.7 ? -(luminance - 0.7) * 0.4 : 0
    let frosted = input.clampedToExtent()
      .applyingGaussianBlur(sigma: max(4, input.extent.width / 150))
      .cropped(to: input.extent)
      .applyingFilter("CIColorControls", parameters: [
        kCIInputBrightnessKey: brightness, kCIInputSaturationKey: 1.25, kCIInputContrastKey: 0.92,
      ])
    return context.createCGImage(frosted, from: input.extent)
  }

  private static func averageLuminance(of image: CIImage, context: CIContext) -> CGFloat? {
    guard let average = CIFilter(name: "CIAreaAverage", parameters: [
      kCIInputImageKey: image, kCIInputExtentKey: CIVector(cgRect: image.extent),
    ])?.outputImage else { return nil }
    var pixel = [UInt8](repeating: 0, count: 4)
    context.render(average, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                   format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
    return (0.2126 * CGFloat(pixel[0]) + 0.7152 * CGFloat(pixel[1]) + 0.0722 * CGFloat(pixel[2])) / 255
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

  @objc static func setBackdrop(_ image: NSImage?, on view: NSView) {
    (view as? StartupOverlayView)?.setBackdrop(image)
  }
}

/// The last frame of each host's app, kept on this Mac as the backdrop of its next start.
@objc final class StreamBackdropStore: NSObject {
  private static let queue = DispatchQueue(label: "moonlight.stream-backdrop", qos: .utility)

  private static func url(host: String, app: String) -> URL? {
    guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    else { return nil }
    let safe = { (value: String) in value.filter { $0.isLetter || $0.isNumber || $0 == "-" } }
    return support.appendingPathComponent("Moonlight/LastFrames", isDirectory: true)
      .appendingPathComponent("\(safe(host))-\(safe(app)).jpg")
  }

  /// Writes the frame in the background.
  @objc static func save(_ image: CGImage, host: String, app: String) {
    guard let url = url(host: host, app: app) else { return }
    queue.async {
      let rep = NSBitmapImageRep(cgImage: image)
      guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.72]) else { return }
      try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? data.write(to: url, options: .atomic)
    }
  }

  /// This app's last frame, else its box art.
  @objc static func backdrop(host: String, app: String, boxArtPath: String?) -> NSImage? {
    if let url = url(host: host, app: app), let image = NSImage(contentsOf: url) {
      return image
    }
    if let boxArtPath, let image = NSImage(contentsOfFile: boxArtPath) {
      return image
    }
    return nil
  }
}
