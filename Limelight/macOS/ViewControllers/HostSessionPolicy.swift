//
//  HostSessionPolicy.swift
//  Quitting an app on the host, and keeping "which app is running" in step with the host. Foundation only, so
//  tests/host-session compiles it on its own.
//
//  Why: VoidLink can quit an app another client started; Moonlight answered
//  「如果此应用是由其他设备启动的，您需要从该设备退出」. Foundation Sunshine's /cancel accepts any authenticated
//  client and answers 200 at once, then cancels asynchronously (the encoder and the app may take seconds to go).
//  The client asked /serverinfo right after the 200, saw SERVER_BUSY and turned the answer into 599: a GFE-only
//  workaround (GFE answers 200 and does nothing when another client's app is running). And when another client
//  quit or started an app, the page kept 继续游戏: the running app was only read at a few moments.
//

import Foundation

@objc(MLHostSessionPolicy)
final class HostSessionPolicy: NSObject {
  /// How long and how often /serverinfo is asked after /cancel answered 200, on a Sunshine-family host.
  @objc static let quitPollInterval: Double = 0.3
  @objc static let quitPollLimit: Double = 10

  /// GFE says "MJOLNIR_STATE_SERVER_BUSY", Sunshine and Foundation Sunshine "SUNSHINE_SERVER_BUSY".
  @objc static func isBusy(state: String?) -> Bool { (state ?? "").hasSuffix("_SERVER_BUSY") }
  @objc static func isSunshineFamily(state: String?, isFoundation: Bool) -> Bool { isFoundation || (state ?? "").hasPrefix("SUNSHINE") }

  /// The app a /serverinfo answer says is running: nil when the host is not busy or names no app.
  @objc static func runningAppId(state: String?, currentGame: String?) -> String? {
    guard isBusy(state: state) else { return nil }
    let id = (currentGame ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return id.isEmpty || id == "0" ? nil : id
  }

  enum QuitResult: Equatable {
    case quit
    /// still running when the time was up (the message must not say another device has to quit it)
    case stillRunning
    /// GFE: 200 but the app is still there, which is what it does for an app another client started
    case otherClientOnGFE
  }

  /// After /cancel answered 200. `firstState` is /serverinfo's state right after (nil when it could not be read);
  /// `poll` asks again. Sunshine-family hosts cancel asynchronously: poll every `quitPollInterval` until the host
  /// is free, at most `quitPollLimit`. GFE keeps the old reading of a busy answer.
  static func finishQuit(isFoundation: Bool, firstState: String?, poll: () -> String?, wait: (Double) -> Void) -> QuitResult {
    if !isBusy(state: firstState) && firstState != nil { return .quit }
    guard isSunshineFamily(state: firstState, isFoundation: isFoundation) else { return .otherClientOnGFE }
    let rounds = Int((quitPollLimit / quitPollInterval).rounded())
    for _ in 0..<rounds {
      wait(quitPollInterval)
      let state = poll()
      if state != nil && !isBusy(state: state) { return .quit }
    }
    return .stillRunning
  }

  // ObjC bridge: 1 quit, 2 still running, 3 other client on GFE.
  @objc static func quitOutcome(isFoundation: Bool, firstState: String?, poll: () -> String?, wait: (Double) -> Void) -> Int {
    switch finishQuit(isFoundation: isFoundation, firstState: firstState, poll: poll, wait: wait) {
    case .quit: return 1
    case .stillRunning: return 2
    case .otherClientOnGFE: return 3
    }
  }

  /// What starting `appId` does on a host in this state. The host being busy is not "resume": it is resume only when
  /// the app that runs is this one. Another app running is for the user to decide (quit it first), never a silent
  /// resume of the wrong app (大屏模式 started while Steam ran was taken as resuming Steam).
  /// 1 launch, 2 resume, 3 another app is running.
  @objc static func launchDecision(state: String?, currentGame: String?, appId: String?) -> Int {
    guard isBusy(state: state) else { return 1 }
    guard let running = runningAppId(state: state, currentGame: currentGame) else {
      // busy and the host names no app: as before, resume (an older host that sends no currentgame)
      return 2
    }
    return running == (appId ?? "") ? 2 : 3
  }

  /// What the page does with a /serverinfo answer for its running-app mark. `reachable` false (the request failed)
  /// changes nothing: an unreachable host does not mean the app quit.
  struct RunningChange: Equatable {
    var runningId: String?
    var changed: Bool
  }

  static func reconcile(current: String?, reachable: Bool, state: String?, currentGame: String?) -> RunningChange {
    guard reachable else { return RunningChange(runningId: current, changed: false) }
    let reported = runningAppId(state: state, currentGame: currentGame)
    return RunningChange(runningId: reported, changed: reported != current)
  }

  /// ObjC: the id to show (nil: none), and whether it differs from `current`.
  @objc static func reconciledRunningId(current: String?, reachable: Bool, state: String?, currentGame: String?, changed: UnsafeMutablePointer<ObjCBool>?) -> String? {
    let change = reconcile(current: current, reachable: reachable, state: state, currentGame: currentGame)
    changed?.pointee = ObjCBool(change.changed)
    return change.runningId
  }
}
