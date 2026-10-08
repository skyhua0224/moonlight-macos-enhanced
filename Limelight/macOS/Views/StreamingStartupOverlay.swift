import AppKit
import SwiftUI

private struct StreamingStartupContent: View {
  var body: some View {
    ProgressView()
      .progressViewStyle(.circular)
      .controlSize(.regular)
      .tint(.white)
      .scaleEffect(1.3)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color.black.opacity(0.2))
      .accessibilityLabel(Text("Connecting"))
  }
}

private final class StartupHostingView: NSHostingView<StreamingStartupContent> {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@objc final class StreamingStartupOverlayFactory: NSObject {
  @objc static func makeView() -> NSView {
    StartupHostingView(rootView: StreamingStartupContent())
  }
}
