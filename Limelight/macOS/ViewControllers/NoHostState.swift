//
//  NoHostState.swift
//  What the no-host page is in. The page is only ever shown while there is no computer at all: it never draws one. When discovery finds a
//  computer, or one is added, the window goes on to the normal host list (HostsViewController's own transition).
//
//  Three real states:
//    searching  discovery is running and has found nothing yet.
//    notFound   it has found nothing for NoHostRules.notFoundAfter seconds. Discovery keeps going in the background (MDNSManager restarts
//               the browse every 5 seconds at first, then less often), so the page says it is still searching.
//    denied     the Local Network privacy permission (macOS 15 and later) is off, so discovery cannot work at all.
//
//  How "denied" is known (Apple TN3179, "Understanding local network privacy"): there is no general API for it. For Bonjour the
//  operation waits with kDNSServiceErr_PolicyDenied (-65570); the probe below runs an NWBrowser for the same service type next to the
//  existing NSNetServiceBrowser and reads that error from its state. Before macOS 15 the permission does not exist, so the probe does not run.
//

import AppKit
import Network
import SwiftUI

enum NoHostPhase: String {
  case searching, notFound, denied
}

enum NoHostRules {
  /// MDNSManager restarts the browse every 5 seconds for the first 30 seconds; three rounds without a result is "not found".
  static let browseInterval: TimeInterval = 5
  static let notFoundAfter: TimeInterval = browseInterval * 3

  /// kDNSServiceErr_PolicyDenied: the system refused the Bonjour operation for want of Local Network access.
  static let policyDenied = -65570

  static func phase(elapsed: TimeInterval, denied: Bool) -> NoHostPhase {
    if denied { return .denied }
    return elapsed >= notFoundAfter ? .notFound : .searching
  }

  /// True when a browser's waiting error is the "no local network access" one.
  static func isPolicyDenied(_ error: NWError) -> Bool {
    if case .dns(let code) = error { return Int(code) == policyDenied }
    return false
  }

  /// Where 打开系统设置 goes: the Local Network list in Privacy & Security; if that anchor is refused, the Privacy & Security pane itself.
  static let settingsURLs: [String] = [
    "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_LocalNetwork",
    "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork",
    "x-apple.systempreferences:com.apple.preference.security",
  ]

  static func openLocalNetworkSettings() {
    for text in settingsURLs {
      if let url = URL(string: text), NSWorkspace.shared.open(url) { return }
    }
  }
}

/// Watches whether the Local Network permission is off (macOS 15 and later).
final class NoHostLocalNetworkProbe: ObservableObject {
  @Published private(set) var denied = false
  private var browser: NWBrowser?
  private var observer: NSObjectProtocol?

  init() {
    // the concept harness has no real network, and the permission does not exist before macOS 15
    if NoHostCaps.harness && ProcessInfo.processInfo.environment["MLC_REAL_NET"] == nil { return }
    if #available(macOS 15.0, *) {
      // The probe is a Bonjour browse too: with 自动发现新主机 off it does not run, and it follows the switch.
      reconcile()
      observer = NotificationCenter.default.addObserver(forName: DiscoveryPreference.changedNotification, object: nil, queue: .main) { [weak self] _ in
        self?.reconcile()
      }
    }
  }

  deinit {
    if let observer { NotificationCenter.default.removeObserver(observer) }
    browser?.cancel()
  }

  private func reconcile() {
    if DiscoveryPreference.isEnabled() {
      if browser == nil { start() }
    } else {
      browser?.cancel()
      browser = nil
      // a denial seen before the switch went off says nothing about the permission now
      denied = false
    }
  }

  private func start() {
    let browser = NWBrowser(for: .bonjour(type: "_nvstream._tcp", domain: nil), using: .tcp)
    browser.stateUpdateHandler = { [weak self] state in
      DispatchQueue.main.async { self?.handle(state) }
    }
    browser.browseResultsChangedHandler = { _, _ in }
    browser.start(queue: .main)
    self.browser = browser
  }

  private func handle(_ state: NWBrowser.State) {
    switch state {
    case .waiting(let error): if NoHostRules.isPolicyDenied(error) { denied = true }
    case .ready: denied = false     // granted in System Settings: the system retries and the browser becomes ready
    default: break
    }
  }
}
