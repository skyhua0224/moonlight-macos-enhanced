//
//  SettingsHostingController.swift
//  Moonlight for macOS
//
//  Created by Michael Kenny on 15/1/2024.
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

import Cocoa
import AVFoundation
import Combine
import SwiftUI
import GameController

private final class SettingsControllerInputBoundary: GCEventViewController {
  private let contentController: NSViewController

  init(contentController: NSViewController) {
    self.contentController = contentController
    super.init(nibName: nil, bundle: nil)
    controllerUserInteractionEnabled = false
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("Use init(contentController:)") }

  override func loadView() {
    view = NSView()
    addChild(contentController)
    let content = contentController.view
    content.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(content)
    NSLayoutConstraint.activate([
      content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      content.topAnchor.constraint(equalTo: view.topAnchor),
      content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
  }
}

class SettingsHostingController<RootView: View>: NSWindowController {
  private var languageObserver: Any?

  convenience init(rootView: RootView) {
    let hostingController = NSHostingController(rootView: rootView)
    if #available(macOS 13.0, *) {
      // The window has a size of its own. Left on, the hosting view asks the whole settings
      // tree for its ideal size, more than once, while the window is being set up.
      hostingController.sizingOptions = []
    }

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: true)
    // The window is kept and shown again (see AppDelegateForAppKit).
    window.isReleasedWhenClosed = false
    window.contentViewController = SettingsControllerInputBoundary(
      contentController: hostingController)
    window.identifier = NSUserInterfaceItemIdentifier("ClientSettingsWindow")
    window.collectionBehavior = [.fullScreenNone]
    window.tabbingMode = .disallowed
    window.isOpaque = true
    window.backgroundColor = .windowBackgroundColor
    window.setContentSize(NSSize(width: 960, height: 680))
    window.minSize = NSSize(width: 820, height: 560)
    window.center()
    window.title = LanguageManager.shared.localize("Settings")
    if #available(macOS 26.0, *) {
      window.titlebarAppearsTransparent = true
      window.toolbarStyle = .unified
    }

    self.init(window: window)

    languageObserver = NotificationCenter.default.addObserver(
      forName: .init("LanguageChanged"), object: nil, queue: .main
    ) { [weak window] _ in
      window?.title = LanguageManager.shared.localize("Settings")
    }
  }

  deinit {
    if let languageObserver {
      NotificationCenter.default.removeObserver(languageObserver)
    }
  }
}

private enum WelcomePermissionsState {
  static let defaultsKey = "welcome.permissions.shown.v1"

  static func markShown() {
    UserDefaults.standard.set(true, forKey: defaultsKey)
  }

  static func shouldShowOnLaunch() -> Bool {
    guard !UserDefaults.standard.bool(forKey: defaultsKey) else {
      return false
    }

    let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    let inputState = InputMonitoringPermissionManager.sharedManager.authorizationState
    let awdlState = AwdlHelperManager.sharedManager.authorizationState
    let needsMic = micStatus != .authorized
    let needsInput = inputState != .unsupported &&
      inputState != .granted &&
      inputState != .grantedNeedsReentry
    let needsAwdl = awdlState == .notDetermined || awdlState == .failed
    return needsMic || needsInput || needsAwdl
  }
}

private struct WelcomePermissionsView: View {
  @ObservedObject private var languageManager = LanguageManager.shared
  @ObservedObject private var microphoneManager = MicrophoneManager.shared
  @ObservedObject private var inputMonitoringManager = InputMonitoringPermissionManager.sharedManager
  @ObservedObject private var awdlManager = AwdlHelperManager.sharedManager
  let onContinue: () -> Void

  private var microphoneStatus: AVAuthorizationStatus {
    microphoneManager.permissionStatus
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack(alignment: .top, spacing: 16) {
        Image(nsImage: NSApp.applicationIconImage)
          .resizable()
          .interpolation(.high)
          .frame(width: 72, height: 72)
          .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

        VStack(alignment: .leading, spacing: 8) {
          Text(languageManager.localize("Welcome to Moonlight macOS Enhanced"))
            .font(.system(size: 28, weight: .semibold, design: .rounded))
          Text(languageManager.localize("Welcome Permissions Subtitle"))
            .foregroundColor(.secondary)

          Link(languageManager.localize("GitHub Repository"), destination: githubURL)
            .font(.callout.weight(.medium))
        }
      }

      GroupBox {
        VStack(alignment: .leading, spacing: 16) {
          if inputMonitoringManager.authorizationState != .unsupported {
            permissionRow(
              title: "Input Monitoring",
              subtitle: "Input Monitoring detail",
              stateLabel: inputStatusText,
              isGranted: inputMonitoringManager.isGranted,
              supplementalMessageKey: inputMonitoringManager.supplementalStatusMessageKey,
              actionTitle: inputActionTitle,
              action: inputAction
            )
          }

          permissionRow(
            title: "AWDL Stability Helper",
            subtitle: "Welcome AWDL detail",
            stateLabel: awdlStatusText,
            isGranted: awdlGrantedState,
            actionTitle: awdlActionTitle,
            action: awdlAction
          )

          permissionRow(
            title: "Microphone",
            subtitle: "Microphone Permission detail",
            stateLabel: microphoneStatusText,
            isGranted: microphoneStatus == .authorized,
            actionTitle: microphoneActionTitle,
            action: microphoneAction
          )
        }
        .padding(.vertical, 8)
      }

      HStack {
        Spacer()
        Button(languageManager.localize("Continue")) {
          onContinue()
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(24)
    .frame(width: 560)
    .onAppear {
      microphoneManager.refreshPermissionStatus()
      inputMonitoringManager.refreshAuthorizationStatus()
      awdlManager.refreshAuthorizationStatus()
    }
  }

  private var githubURL: URL {
    URL(string: "https://github.com/skyhua0224/moonlight-macos-enhanced")!
  }

  @ViewBuilder
  private func permissionRow(
    title: String,
    subtitle: String,
    stateLabel: String,
    isGranted: Bool,
    supplementalMessageKey: String? = nil,
    actionTitle: String?,
    action: (() -> Void)?
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .center, spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
          Text(languageManager.localize(title))
            .font(.headline)
          Text(languageManager.localize(subtitle))
            .font(.footnote)
            .foregroundColor(.secondary)
        }

        Spacer(minLength: 12)

        Label(
          languageManager.localize(stateLabel),
          systemImage: isGranted ? "checkmark.circle.fill" : "minus.circle"
        )
        .foregroundColor(isGranted ? .green : .secondary)
        .font(.callout)

        if let actionTitle, let action {
          Button(languageManager.localize(actionTitle)) {
            action()
          }
          .controlSize(.small)
        }
      }

      if let supplementalMessageKey {
        Text(languageManager.localize(supplementalMessageKey))
          .font(.footnote)
          .foregroundColor(.secondary)
      }
    }
  }

  private var inputStatusText: String {
    inputMonitoringManager.displayStatusLabelKey
  }

  private var inputActionTitle: String? {
    inputMonitoringManager.primaryActionTitleKey
  }

  private func inputAction() {
    switch inputMonitoringManager.primaryActionTitleKey {
    case "Request":
      inputMonitoringManager.requestAuthorization()
    case "Open Settings":
      inputMonitoringManager.openSystemPreferences()
    default:
      break
    }
  }

  private var microphoneStatusText: String {
    switch microphoneStatus {
    case .authorized:
      return "Granted"
    case .denied, .restricted:
      return "Denied"
    case .notDetermined:
      return "Not Granted"
    @unknown default:
      return "Not Granted"
    }
  }

  private var microphoneActionTitle: String? {
    switch microphoneStatus {
    case .authorized:
      return nil
    case .denied, .restricted:
      return "Open Settings"
    case .notDetermined:
      return "Request"
    @unknown default:
      return "Request"
    }
  }

  private func microphoneAction() {
    switch microphoneStatus {
    case .denied, .restricted:
      microphoneManager.openSystemPreferences()
    case .notDetermined:
      microphoneManager.requestPermission()
    case .authorized:
      break
    @unknown default:
      microphoneManager.requestPermission()
    }
  }

  private var awdlStatusText: String {
    switch awdlManager.helperInstallState {
    case .installed:
      return "Installed"
    case .notReady:
      return "Not Ready"
    case .adminPromptOnly:
      return "Admin Prompt Only"
    case .unavailable:
      return "Unavailable"
    case .unknown:
      return "Checking"
    @unknown default:
      return "Checking"
    }
  }

  private var awdlActionTitle: String? {
    if awdlManager.supportsPersistentHelperInstallation,
       awdlManager.helperInstallState != .installed
    {
      return "Install Persistent Helper"
    }

    switch awdlManager.authorizationState {
    case .ready, .unavailable:
      return nil
    case .failed, .notDetermined:
      return "Request"
    @unknown default:
      return "Request"
    }
  }

  private func awdlAction() {
    if awdlManager.supportsPersistentHelperInstallation,
       awdlManager.helperInstallState != .installed
    {
      awdlManager.installPersistentHelper()
    } else {
      awdlManager.requestAuthorization()
    }
  }

  private var awdlGrantedState: Bool {
    awdlManager.helperInstallState == .installed
  }
}

final class WelcomePermissionsHostingController: NSWindowController, NSWindowDelegate {
  convenience init() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
      styleMask: [.titled, .closable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
    let hostingController = NSHostingController(
      rootView: WelcomePermissionsView {
        if let sheetParent = window.sheetParent {
          sheetParent.endSheet(window, returnCode: .OK)
        } else {
          WelcomePermissionsState.markShown()
          window.performClose(nil)
        }
      }
    )
    window.contentViewController = hostingController
    window.styleMask = [.titled, .closable, .miniaturizable]
    window.collectionBehavior = [.fullScreenNone]
    window.tabbingMode = .disallowed
    window.title = LanguageManager.shared.localize("Permissions")
    window.isReleasedWhenClosed = false

    self.init(window: window)
    window.delegate = self
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if let sheetParent = sender.sheetParent {
      sheetParent.endSheet(sender, returnCode: .cancel)
      return false
    }
    return true
  }

  func windowWillClose(_ notification: Notification) {
    WelcomePermissionsState.markShown()
  }
}

@objc class SettingsWindowObjCBridge: NSView {
  @objc class func makeSettingsWindow(hostId: String?) -> NSWindowController {
    let settingsView = SettingsView(hostId: hostId)
    return SettingsHostingController(rootView: settingsView)
  }

  /// The window that already exists is about to be shown again: select the profile of this
  /// host and read it from the store again.
  /// The host the window was last asked to show. The window may be built ahead of its first
  /// use, so its view takes the host from here when it first appears.
  static var requestedHostId: String?

  /// Builds one settings page that has not been shown yet. False when there is none left
  /// (or no settings window that keeps pages).
  @objc class func prewarmNextSettingsPage() -> Bool {
    SettingsPaneContainerView.current?.prewarmNextPage() ?? false
  }

  /// Lets the pages that were built ahead go. For the time of a stream: every kept page
  /// works each status the stream announces through, on the main thread.
  @objc class func releaseSettingsPagesNotShowing() {
    SettingsPaneContainerView.current?.releasePagesNotShowing()
  }

  /// Makes the file dialog of the equalizer ahead of its first use.
  @objc class func prewarmImportPanel() {
    _ = EqualizerImportPanel.shared
  }

  @objc class func prepareSettingsWindowForShowing(hostId: String?) {
    let resolvedHostId = (hostId?.isEmpty == false ? hostId : nil) ?? SettingsModel.globalHostId
    requestedHostId = resolvedHostId
    UserDefaults.standard.set(resolvedHostId, forKey: "selectedSettingsProfile")
    NotificationCenter.default.post(
      name: Notification.Name("MoonlightSettingsWindowWillShow"), object: nil,
      userInfo: ["hostId": resolvedHostId])
  }

  /// The window stays alive while it is closed, and so do its views: what is only worth
  /// doing while they are seen is stopped here.
  @objc class func settingsWindowVisibilityChanged(_ visible: Bool) {
    EnhancedAudioSpectrum.shared.setWindowVisible(visible)
    if !visible {
      MicrophoneManager.shared.stopTest()
    }
    SettingsPaneContainerView.current?.windowVisibilityChanged(visible)
  }

  @objc class func syncSelectedProfile(hostId: String?) {
    let resolvedHostId: String
    if let hostId, !hostId.isEmpty {
      resolvedHostId = hostId
    } else {
      resolvedHostId = SettingsModel.globalHostId
    }

    UserDefaults.standard.set(resolvedHostId, forKey: "selectedSettingsProfile")
    NotificationCenter.default.post(
      name: Notification.Name("MoonlightSelectedSettingsProfileChanged"),
      object: nil,
      userInfo: ["hostId": resolvedHostId]
    )
  }
}

@objc class WelcomePermissionsWindowObjCBridge: NSView {
  @objc class func shouldShowWelcomeWindow() -> Bool {
    WelcomePermissionsState.shouldShowOnLaunch()
  }

  @objc class func markWelcomeWindowShown() {
    WelcomePermissionsState.markShown()
  }

  @objc class func makeWelcomeWindow() -> NSWindowController {
    WelcomePermissionsHostingController()
  }
}
