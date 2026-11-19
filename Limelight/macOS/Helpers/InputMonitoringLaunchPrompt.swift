//
//  InputMonitoringLaunchPrompt.swift
//  Moonlight for macOS
//
//  What the app does about Input Monitoring when it starts, and how a permission alert is put on screen. AppKit and
//  Foundation only, so a test can build it alone (tests/input-monitoring-launch, tests/permission-alert-nonblocking).
//

import AppKit
import Foundation

/// What the system reports for Input Monitoring (IOHIDCheckAccess / CGPreflightListenEventAccess), read without asking.
enum InputMonitoringLaunchAccess: Equatable {
  case granted
  /// The user, or a profile, said no; or an old entry no longer matches this build.
  case denied
  /// Never asked for this build.
  case unknown
}

enum InputMonitoringLaunchAction: Equatable {
  case nothing
  /// Ask the system for access: it shows its own dialog once.
  case requestAccess
  /// Tell the user to turn Moonlight on in System Settings, with a button that opens the pane.
  case showAlert
}

enum InputMonitoringLaunchRules {
  /// - Parameters:
  ///   - usesCoreHID: a profile that will be used for a stream takes mouse input from CoreHID.
  ///   - coreHIDSupported: this macOS has CoreHID (15 or later).
  ///   - everGranted: Input Monitoring was allowed for this app before. With no answer from the system now, that means
  ///     the entry went stale (a build signed differently), and the system dialog would not appear.
  ///   - promptedVersion: the build the user was last asked on (or chose "Later" on).
  static func action(
    usesCoreHID: Bool,
    coreHIDSupported: Bool,
    access: InputMonitoringLaunchAccess,
    everGranted: Bool,
    promptedVersion: String?,
    currentVersion: String
  ) -> InputMonitoringLaunchAction {
    guard coreHIDSupported, usesCoreHID, access != .granted else { return .nothing }
    guard promptedVersion != currentVersion else { return .nothing }
    if access == .unknown && !everGranted {
      return .requestAccess
    }
    return .showAlert
  }
}

/// Puts a permission alert on screen without ever blocking the main thread or the stream.
///
/// NSAlert.runModal runs a modal session on the main thread, and a block dispatched to the main queue does not run
/// until the session ends. The stream start binds its connection in such a block, so a runModal alert raised while a
/// stream is starting (CoreHID found without Input Monitoring) left the stream stuck at "Starting", with the alert
/// behind the stream window and the disconnect shortcut unable to run. A permission alert is therefore
///  - never shown while a stream window is on screen (the caller keeps it and shows it when the stream window closes),
///  - and when it is shown, it is a sheet on an ordinary window of the app, which does not take over the main thread.
enum PermissionAlertPresenter {
  /// Name of the stream window class (StreamViewController.m).
  static let streamWindowClassName = "ClientWindow"

  static func isStreamWindow(_ window: NSWindow, streamWindowClass: AnyClass? = NSClassFromString(streamWindowClassName)) -> Bool {
    guard let streamWindowClass else { return false }
    return window.isKind(of: streamWindowClass)
  }

  /// A stream window exists and is on screen or in the Dock: a stream is starting, running or being left.
  static func streamWindowVisible(
    windows: [NSWindow] = NSApp.windows,
    streamWindowClass: AnyClass? = NSClassFromString(streamWindowClassName)
  ) -> Bool {
    windows.contains { isStreamWindow($0, streamWindowClass: streamWindowClass) && ($0.isVisible || $0.isMiniaturized) }
  }

  /// The window the sheet goes on: the main window if it is an ordinary one, else the first ordinary visible window.
  static func hostWindow(
    windows: [NSWindow] = NSApp.windows,
    mainWindow: NSWindow? = NSApp.mainWindow,
    streamWindowClass: AnyClass? = NSClassFromString(streamWindowClassName)
  ) -> NSWindow? {
    func usable(_ w: NSWindow) -> Bool {
      w.isVisible && !w.isMiniaturized && !(w is NSPanel) && w.attachedSheet == nil && w.sheetParent == nil
        && !isStreamWindow(w, streamWindowClass: streamWindowClass)
    }
    if let mainWindow, usable(mainWindow) { return mainWindow }
    return windows.first(where: usable)
  }

  /// Shows the alert as a sheet and calls `completion` with the answer. Returns false, and shows nothing, when a stream
  /// window is on screen or there is no window to put it on; the caller decides when to try again.
  @discardableResult
  static func presentWithoutBlocking(
    _ alert: NSAlert,
    windows: [NSWindow] = NSApp.windows,
    mainWindow: NSWindow? = NSApp.mainWindow,
    streamWindowClass: AnyClass? = NSClassFromString(streamWindowClassName),
    completion: @escaping (NSApplication.ModalResponse) -> Void
  ) -> Bool {
    guard !streamWindowVisible(windows: windows, streamWindowClass: streamWindowClass),
      let host = hostWindow(windows: windows, mainWindow: mainWindow, streamWindowClass: streamWindowClass)
    else { return false }
    alert.beginSheetModal(for: host, completionHandler: completion)
    return true
  }
}

/// Tells the user why a stream could not start, on the host window, once the stream window has gone. It waits for that
/// window (it may be leaving full screen) and gives up after a few seconds.
@objc final class StreamFailureNotice: NSObject {
  @objc static func show(title: String, message: String, buttonTitle: String) {
    present(title: title, message: message, buttonTitle: buttonTitle, attemptsLeft: 12)
  }

  private static func present(title: String, message: String, buttonTitle: String, attemptsLeft: Int) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: buttonTitle)
    if PermissionAlertPresenter.presentWithoutBlocking(alert, completion: { _ in }) || attemptsLeft <= 0 { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
      present(title: title, message: message, buttonTitle: buttonTitle, attemptsLeft: attemptsLeft - 1)
    }
  }
}
