// Checks that a permission alert never blocks the main queue, with the production presenter
// (Limelight/macOS/Helpers/InputMonitoringLaunchPrompt.swift). Needs a window server session; run by hand:
//   sh tests/permission-alert-nonblocking/run.sh
import AppKit

final class FakeStreamWindow: NSWindow {}

var failures = 0
func check(_ ok: Bool, _ name: String) {
  print(ok ? "ok   \(name)" : "FAIL \(name)")
  if !ok { failures += 1 }
}
func ordinaryWindow(_ cls: NSWindow.Type = NSWindow.self) -> NSWindow {
  let w = cls.init(contentRect: NSRect(x: 100, y: 100, width: 400, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
  w.orderFront(nil)
  return w
}
func makeAlert() -> NSAlert {
  let a = NSAlert()
  a.messageText = "Input Monitoring access needed"
  a.addButton(withTitle: "Open")
  a.addButton(withTitle: "Later")
  return a
}
func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

_ = NSApplication.shared
NSApp.setActivationPolicy(.accessory)
let host = ordinaryWindow()
spin(0.2)
check(host.isVisible, "host window is on screen")

// How the app raised the alert before: from a block on the main queue (the CoreHID callback hops to the main queue).
// A modal session started inside a main-queue block does not let the next main-queue block run until it ends. The
// stream start binds its connection in such a block. (Informational: the premise of the fix.)
do {
  var ran = false
  var ranWhileModal = false
  DispatchQueue.main.async {
    DispatchQueue.main.async { ran = true }                 // what the stream start queues
    let abort = Timer(timeInterval: 0.6, repeats: false) { _ in ranWhileModal = ran; NSApp.abortModal() }
    RunLoop.main.add(abort, forMode: .modalPanel)
    _ = makeAlert().runModal()
  }
  spin(1.2)
  print("info runModal inside a main-queue block: the next main-queue block ran while the alert was up: \(ranWhileModal) (ran after it: \(ran))")
}

// The presenter, called the same way: the next main-queue block runs while the alert is up.
do {
  var ran = false
  var answered = false
  var shown = false
  let alert = makeAlert()
  DispatchQueue.main.async {
    shown = PermissionAlertPresenter.presentWithoutBlocking(alert, windows: [host], mainWindow: host, streamWindowClass: FakeStreamWindow.self) { _ in answered = true }
    DispatchQueue.main.async { ran = true }
  }
  spin(0.4)
  check(shown, "presenter shows the alert on an ordinary window")
  check(ran, "the next main-queue block runs while the alert is up")
  check(host.attachedSheet != nil, "the alert is a sheet of the window")
  host.endSheet(host.attachedSheet!, returnCode: .alertFirstButtonReturn)
  spin(0.2)
  check(answered, "the answer reaches the completion handler")
}

// A stream window on screen: nothing is shown.
do {
  let stream = ordinaryWindow(FakeStreamWindow.self)
  spin(0.1)
  var called = false
  let shown = PermissionAlertPresenter.presentWithoutBlocking(makeAlert(), windows: [host, stream], mainWindow: host, streamWindowClass: FakeStreamWindow.self) { _ in called = true }
  check(!shown && host.attachedSheet == nil && !called, "no alert while a stream window is on screen")
  check(PermissionAlertPresenter.streamWindowVisible(windows: [host, stream], streamWindowClass: FakeStreamWindow.self), "the stream window is seen")
  stream.close()
  spin(0.1)
  check(!PermissionAlertPresenter.streamWindowVisible(windows: [host, stream], streamWindowClass: FakeStreamWindow.self), "a closed stream window is not seen")
  let shownAfter = PermissionAlertPresenter.presentWithoutBlocking(makeAlert(), windows: [host, stream], mainWindow: host, streamWindowClass: FakeStreamWindow.self) { _ in }
  check(shownAfter, "the alert is shown once the stream window has closed")
  if let sheet = host.attachedSheet { host.endSheet(sheet) }
  spin(0.2)
}

// No window to put it on, a stream window as the only window.
do {
  let stream = ordinaryWindow(FakeStreamWindow.self)
  spin(0.1)
  let shown = PermissionAlertPresenter.presentWithoutBlocking(makeAlert(), windows: [stream], mainWindow: stream, streamWindowClass: FakeStreamWindow.self) { _ in }
  check(!shown, "no window to put the alert on: nothing is shown")
  stream.close()
}

if failures > 0 { print("\(failures) failed"); exit(1) }
print("all passed")
