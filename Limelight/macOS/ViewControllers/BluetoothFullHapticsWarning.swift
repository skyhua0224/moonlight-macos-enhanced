//
//  BluetoothFullHapticsWarning.swift
//  Moonlight for macOS
//
//  The warning shown every time Full Bluetooth Haptics is turned on: a sheet on the settings window whose
//  "Turn On Anyway" button stays disabled and counts down for 5 seconds. Cancel is the default and Esc.
//

import AppKit

@objc(MLBluetoothFullHapticsWarning)
final class BluetoothFullHapticsWarning: NSObject {
  static let delaySeconds = 5
  private static var isPresenting = false

  /// Shows the warning; `completion` gets true only when the user pressed "Turn On Anyway" after the delay.
  /// A request while one is showing is answered with false. Without a window the sheet goes on the key, main or
  /// first visible window, and only when the app has none it runs as a modal alert.
  @objc static func present(on window: NSWindow?, completion: @escaping (Bool) -> Void) {
    guard !isPresenting else { completion(false); return }
    isPresenting = true
    let language = LanguageManager.shared
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = language.localize("Experimental: Full Bluetooth Haptics")
    alert.informativeText = language.localize("Full Bluetooth Haptics warning")
    let cancel = alert.addButton(withTitle: language.localize("Cancel"))   // default: Return
    let proceed = alert.addButton(withTitle: proceedTitle(remaining: delaySeconds))
    proceed.isEnabled = false
    // AppKit gives a button titled "Cancel" the Escape key and no Return; Cancel is the default here whatever its title.
    cancel.keyEquivalent = "\r"
    proceed.keyEquivalent = ""
    alert.window.initialFirstResponder = cancel
    // Esc is Cancel whatever the app language is (AppKit only maps it for a button titled with the system's "Cancel").
    let escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      guard event.keyCode == 53, event.window === alert.window else { return event }
      cancel.performClick(nil)
      return nil
    }

    let start = ProcessInfo.processInfo.systemUptime
    let timer = Timer(timeInterval: 0.2, repeats: true) { _ in
      let elapsed = ProcessInfo.processInfo.systemUptime - start
      if elapsed >= Double(delaySeconds) {
        proceed.title = language.localize("Turn On Anyway")
        proceed.isEnabled = true
      } else {
        proceed.title = proceedTitle(remaining: delaySeconds - Int(elapsed))
      }
    }
    RunLoop.main.add(timer, forMode: .common)

    let finish: (NSApplication.ModalResponse) -> Void = { response in
      timer.invalidate()
      if let escape { NSEvent.removeMonitor(escape) }
      isPresenting = false
      completion(response == .alertSecondButtonReturn && proceed.isEnabled)
    }
    let host = window ?? NSApp.keyWindow ?? NSApp.mainWindow
      ?? NSApp.orderedWindows.first { $0.isVisible && $0.sheetParent == nil && !($0 is NSPanel) }
    if let host, host.isVisible {
      alert.beginSheetModal(for: host, completionHandler: finish)
    } else {
      finish(alert.runModal())
    }
  }

  private static func proceedTitle(remaining: Int) -> String {
    String(format: LanguageManager.shared.localize("Turn On Anyway (%d)"), remaining)
  }
}
