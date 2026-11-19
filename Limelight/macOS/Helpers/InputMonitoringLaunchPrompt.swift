//
//  InputMonitoringLaunchPrompt.swift
//  Moonlight for macOS
//
//  What the app does about Input Monitoring when it starts. Foundation only, so a test can build it alone
//  (tests/input-monitoring-launch).
//

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
