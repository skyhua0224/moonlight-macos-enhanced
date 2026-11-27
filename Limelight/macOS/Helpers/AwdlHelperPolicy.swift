//
//  AwdlHelperPolicy.swift
//  Moonlight for macOS
//
//  The rules of the AWDL stability helper, without AppKit, XPC or the system: the default of the setting, when the app
//  asks for the administrator authorization, the self-check after an install, and the session that puts awdl0 down for
//  a stream and gives it back. Foundation only, so tests/awdl-helper-policy builds it alone; AwdlHelperManager
//  (MicrophoneManager.swift) supplies the real interface and helper behind `AwdlHelperProbing`.
//

import Foundation

// MARK: - Setting

enum AwdlHelperDefault {
  /// Streams turn awdl0 off by default. A value the user set is kept: only a missing value takes the default.
  static let enabledByDefault = true

  static func isEnabled(stored: Bool?) -> Bool {
    stored ?? enabledByDefault
  }
}

// MARK: - Helper contract and link

enum AwdlHelperContract {
  /// MLAwdlPrivilegedHelperInterfaceVersion in AwdlPrivilegedHelperProtocol.h. tests/awdl-helper-policy checks that the
  /// two numbers are the same.
  static let interfaceVersion = 2
}

/// What the helper answered when the app contacted it.
struct AwdlHelperHandshake: Equatable {
  /// It answered the awdl0 query.
  var reachable: Bool
  /// 0 when the version call got no answer: the helper of an older build does not have it.
  var interfaceVersion: Int
  var buildVersion: String
  var error: String

  init(reachable: Bool, interfaceVersion: Int = 0, buildVersion: String = "", error: String = "") {
    self.reachable = reachable
    self.interfaceVersion = interfaceVersion
    self.buildVersion = buildVersion
    self.error = error
  }
}

enum AwdlHelperLink: Equatable {
  /// Answers, with a version this app can work with.
  case ready
  /// Not installed.
  case notInstalled
  /// Installed, but nothing answers: launchd refused it (signature), or it was disabled in System Settings.
  case notRunning
  /// Answers, but is older than this app expects.
  case outdated

  static func evaluate(
    _ handshake: AwdlHelperHandshake,
    installedFilePresent: Bool,
    expectedVersion: Int = AwdlHelperContract.interfaceVersion
  ) -> AwdlHelperLink {
    if handshake.reachable {
      // A newer helper keeps every call an older app makes.
      return handshake.interfaceVersion >= expectedVersion ? .ready : .outdated
    }
    return installedFilePresent ? .notRunning : .notInstalled
  }
}

// MARK: - When the app asks for the authorization

/// What was asked before. The answers are remembered so that the system dialog never comes twice for the same reason.
struct AwdlSetupRecord: Equatable {
  /// The user was asked to install the helper and answered: authorized, cancelled, or "Not Now".
  var installAnswered: Bool = false
  /// The build on which the user was last asked to update (or repair) the helper.
  var updatePromptedBuild: String? = nil
}

enum AwdlSetupAction: Equatable {
  case none
  /// Explain, then ask the system for the administrator password to install the helper.
  case install
  /// The same for a helper that is installed but older than the app, or that does not answer.
  case update
}

enum AwdlSetupRules {
  /// Decided before a stream starts. Never while a stream is running: the system dialog would land on top of it.
  /// - Parameters:
  ///   - supported: the build can install the helper (not sandboxed, a helper is bundled).
  ///   - sidecarActive: a Sidecar display is connected; this stream leaves awdl0 alone, so there is nothing to set up.
  static func action(
    enabled: Bool,
    supported: Bool,
    interfacePresent: Bool,
    sidecarActive: Bool,
    link: AwdlHelperLink,
    record: AwdlSetupRecord,
    currentBuild: String
  ) -> AwdlSetupAction {
    guard enabled, supported, interfacePresent, !sidecarActive else { return .none }
    switch link {
    case .ready:
      return .none
    case .notInstalled:
      return record.installAnswered ? .none : .install
    case .notRunning, .outdated:
      return record.updatePromptedBuild == currentBuild ? .none : .update
    }
  }
}

// MARK: - The interface and the helper, as the rules see them

struct AwdlInterfaceSnapshot: Equatable {
  var present: Bool
  var up: Bool
}

enum AwdlReleaseResult: Equatable {
  /// This client's hold is over and awdl0 is the helper's to bring up.
  case released
  /// Another client holds awdl0 down: it stays down, and bringing it up would be wrong.
  case stillHeld
  case failed(String)
}

protocol AwdlHelperProbing: AnyObject {
  func handshake() -> AwdlHelperHandshake
  /// Whether awdl0 exists and is up. Needs no privilege.
  func interfaceSnapshot() -> AwdlInterfaceSnapshot
  /// Each call below returns nil on success, otherwise why not.
  func holdDown() -> String?
  func releaseHold() -> AwdlReleaseResult
  /// awdl0 up without a hold behind it.
  func forceUp() -> String?
  /// Waits a moment for the interface to change; false when it did not.
  func waitForInterface(up: Bool) -> Bool
  /// Whether the installed helper file exists (read-only).
  var installedFilePresent: Bool { get }
}

// MARK: - The administrator prompt

enum AwdlAdminPromptResult: Equatable {
  case succeeded
  /// The user closed the system dialog. Not an error: nothing is shown in red.
  case cancelled
  case timedOut
  /// No answer from the system at all (no dialog could be shown).
  case noResponse
  /// The account cannot authorize (not an administrator), or the dialog did not complete.
  case notAdministrator
  /// A policy (MDM, a profile) refused the request.
  case blocked
  case failed(String)

  /// `output` is what `osascript` wrote (stderr, else stdout).
  static func classify(terminationStatus: Int32, output: String) -> AwdlAdminPromptResult {
    if terminationStatus == 0 { return .succeeded }
    let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty { return .noResponse }
    if text.contains("(-128)") { return .cancelled }
    if text.localizedCaseInsensitiveContains("timed out") { return .timedOut }
    if text.contains("(-60005)") { return .notAdministrator }
    if text.contains("(-10004)")
      || text.localizedCaseInsensitiveContains("not authorized")
      || text.localizedCaseInsensitiveContains("not permitted")
    {
      return .blocked
    }
    return .failed(text)
  }
}

// MARK: - Self-check

enum AwdlSelfCheckFailure: Equatable {
  case helperNotRunning(String)
  case helperOutdated(found: Int, expected: Int)
  case holdRejected(String)
  case downNotObserved
  case notRestored

  /// Key of the user-facing sentence (Localizable.strings); the detail, if any, is appended by the caller.
  var messageKey: String {
    switch self {
    case .helperNotRunning: return "AWDL helper does not respond"
    case .helperOutdated: return "AWDL helper is older than this app"
    case .holdRejected: return "AWDL helper could not turn awdl0 off"
    case .downNotObserved: return "awdl0 stayed on after the helper turned it off"
    case .notRestored: return "awdl0 could not be turned back on"
    }
  }

  var detail: String {
    switch self {
    case .helperNotRunning(let detail), .holdRejected(let detail): return detail
    case .helperOutdated(let found, let expected): return "\(found) < \(expected)"
    case .downNotObserved, .notRestored: return ""
    }
  }
}

enum AwdlSelfCheckOutcome: Equatable {
  /// The helper answers with the right version. `toggleVerified`: awdl0 was turned down and up again and both were seen;
  /// false when awdl0 was down already (nothing to turn off) and only the handshake was checked.
  case passed(toggleVerified: Bool)
  case noInterface
  case failed(AwdlSelfCheckFailure)
}

enum AwdlSelfCheck {
  /// Handshake, then awdl0 down and up again. awdl0 is brought back whatever happens in between; when that fails, the
  /// marker stays, so that the next launch, wake or check brings it back. `marker` is written before awdl0 goes down.
  static func run(
    _ probe: AwdlHelperProbing, allowToggle: @autoclosure () -> Bool = true, marker: AwdlPendingRestoreStoring? = nil
  ) -> AwdlSelfCheckOutcome {
    let handshake = probe.handshake()
    switch AwdlHelperLink.evaluate(handshake, installedFilePresent: probe.installedFilePresent) {
    case .notInstalled, .notRunning:
      return .failed(.helperNotRunning(handshake.error))
    case .outdated:
      return .failed(.helperOutdated(found: handshake.interfaceVersion, expected: AwdlHelperContract.interfaceVersion))
    case .ready:
      break
    }

    let before = probe.interfaceSnapshot()
    guard before.present else { return .noInterface }
    // Down already (by the user or another tool) or a stream is using it: there is nothing to turn off and back on.
    // `allowToggle` is read here, right before awdl0 is touched: a Sidecar display may have connected since the check began.
    guard before.up, allowToggle() else { return .passed(toggleVerified: false) }

    // Without a marker on disk awdl0 is not touched: a helper that dies with awdl0 down would leave no record.
    marker?.required = true
    if let marker, !marker.required {
      return .failed(.holdRejected("the recovery marker could not be written"))
    }
    if let error = probe.holdDown() {
      // A hold that failed without an answer may still have taken effect.
      if !probe.interfaceSnapshot().up {
        var restored: Bool
        switch probe.releaseHold() {
        case .released: restored = probe.waitForInterface(up: true)
        case .stillHeld: restored = true
        case .failed: restored = false
        }
        if !restored { restored = probe.forceUp() == nil && probe.waitForInterface(up: true) }
        guard restored else { return .failed(.notRestored) }
      }
      marker?.required = false
      return .failed(.holdRejected(error))
    }
    let wentDown = probe.waitForInterface(up: false)
    var cameBack: Bool
    switch probe.releaseHold() {
    case .released: cameBack = probe.waitForInterface(up: true)
    case .stillHeld: cameBack = true
    case .failed: cameBack = false
    }
    if !cameBack {
      cameBack = probe.forceUp() == nil && probe.waitForInterface(up: true)
    }
    guard cameBack else { return .failed(.notRestored) }
    marker?.required = false
    guard wentDown else { return .failed(.downNotObserved) }
    return .passed(toggleVerified: true)
  }
}

// MARK: - Stream session

protocol AwdlPendingRestoreStoring: AnyObject {
  /// awdl0 was turned off for a stream and has not been seen up again. Survives a crash and a force quit.
  var required: Bool { get set }
}

/// The marker as a file: unlike a UserDefaults write it posts no notification, whose main-queue observers make the
/// writing thread wait for the main thread.
final class AwdlPendingRestoreFile: AwdlPendingRestoreStoring {
  private let url: URL

  init(url: URL) {
    self.url = url
  }

  var required: Bool {
    get { FileManager.default.fileExists(atPath: url.path) }
    set {
      if newValue {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data())
      } else {
        try? FileManager.default.removeItem(at: url)
      }
    }
  }
}

enum AwdlSessionBegin: Equatable {
  case disabled
  /// A Sidecar display needs awdl0.
  case sidecar
  case noInterface
  /// awdl0 was down before the stream: not ours to touch, and not ours to bring back.
  case alreadyDown
  case helperNotReady(AwdlHelperLink)
  case holdFailed(String)
  case active
}

enum AwdlSessionEnd: Equatable {
  /// Another stream owns the session, or none is running.
  case notOwner
  case nothingToRestore
  case restored
  /// Another client holds awdl0 down; the helper brings it up when that one lets go.
  case heldByOthers
  case restoreFailed(String)
}

enum AwdlRestoreOutcome: Equatable {
  case nothingPending
  /// A session is running; it restores at its end.
  case sessionActive
  /// awdl0 is up already.
  case alreadyUp
  case restored
  case cannotRestore(String)
}

/// One stream at a time owns awdl0. Not thread-safe: the caller runs it on one serial queue.
final class AwdlSessionEngine {
  private let probe: AwdlHelperProbing
  private let pending: AwdlPendingRestoreStoring
  private let log: (String) -> Void

  private(set) var ownerID: String?
  private(set) var generation: UInt = 0
  private var holding = false

  init(probe: AwdlHelperProbing, pending: AwdlPendingRestoreStoring, log: @escaping (String) -> Void = { _ in }) {
    self.probe = probe
    self.pending = pending
    self.log = log
  }

  var isActive: Bool { holding }

  func begin(enabled: Bool, sidecarActive: Bool, generation: UInt, ownerID: String) -> AwdlSessionBegin {
    // A stream that never reported its end is superseded: its awdl0 goes back first.
    _ = restoreHold(reason: "superseded-by-new-stream")
    reset()

    guard enabled else { return .disabled }
    // Sidecar carries its picture and touches over awdl0: with a Sidecar iPad connected its video link times out within
    // seconds when awdl0 goes down.
    guard !sidecarActive else { return .sidecar }

    let snapshot = probe.interfaceSnapshot()
    guard snapshot.present else { return .noInterface }

    // No dialog here: a helper that is not installed, not current or not answering leaves awdl0 alone and the stream
    // goes on. The authorization is asked for before the stream starts (AwdlHelperSetup), never in the middle of it.
    let handshake = probe.handshake()
    let link = AwdlHelperLink.evaluate(handshake, installedFilePresent: probe.installedFilePresent)
    guard link == .ready else { return .helperNotReady(link) }

    // An earlier stream left awdl0 down (the helper could not be reached to bring it back): bring it back first, so
    // that "up before this stream" is what is remembered.
    _ = restorePending(reason: "before-stream")

    let current = probe.interfaceSnapshot()
    guard current.up else { return .alreadyDown }

    // The marker first: a crash between the two steps must still find it. Without a marker on disk awdl0 is not touched.
    pending.required = true
    guard pending.required else { return .holdFailed("the recovery marker could not be written") }
    if let error = probe.holdDown() {
      // A hold that failed without an answer (the helper went away mid-call) may still have taken effect: awdl0 is
      // looked at, and if it is down the marker stays until it is seen up.
      if probe.interfaceSnapshot().up {
        pending.required = false
      } else {
        _ = restoreHold(reason: "hold-failed", forceHolding: true)
      }
      return .holdFailed(error)
    }
    guard probe.waitForInterface(up: false) else {
      _ = restoreHold(reason: "hold-not-observed", forceHolding: true)
      return .holdFailed("awdl0 stayed up")
    }

    holding = true
    self.ownerID = ownerID
    self.generation = generation
    return .active
  }

  /// The end of a stream. A late call from a stream that was replaced does nothing.
  func end(forOwner owner: String?, reason: String) -> AwdlSessionEnd {
    guard let owner, ownerID == owner else { return .notOwner }
    let outcome = restoreHold(reason: reason)
    reset()
    return outcome
  }

  /// The app quits.
  func shutdown(reason: String) -> AwdlSessionEnd {
    let outcome = restoreHold(reason: reason)
    reset()
    return outcome
  }

  /// A hold from an earlier run that was never given back (a crash, a force quit while the helper could not be reached).
  /// Does nothing while a stream is running.
  func restorePending(reason: String) -> AwdlRestoreOutcome {
    guard !holding else { return .sessionActive }
    guard pending.required else { return .nothingPending }

    let snapshot = probe.interfaceSnapshot()
    // A failed query looks like an absent interface: only an interface seen up ends the obligation.
    guard snapshot.present else { return .cannotRestore("awdl0 is not available") }
    if snapshot.up {
      pending.required = false
      return .alreadyUp
    }

    let handshake = probe.handshake()
    guard handshake.reachable else {
      log("[diag] AWDL helper cannot restore awdl0 (\(reason)): the helper does not respond")
      return .cannotRestore(handshake.error)
    }
    if let error = probe.forceUp() {
      log("[diag] AWDL helper failed to restore awdl0 (\(reason)): \(error)")
      return .cannotRestore(error)
    }
    guard probe.waitForInterface(up: true) else {
      return .cannotRestore("awdl0 stayed down")
    }
    pending.required = false
    log("[diag] AWDL helper restored awdl0 left down by an earlier run: reason=\(reason)")
    return .restored
  }

  /// The system can bring awdl0 up again under a running stream (after wake); the stream wants it down.
  func reassertIfActive(reason: String) -> Bool {
    guard holding else { return false }
    let snapshot = probe.interfaceSnapshot()
    guard snapshot.present, snapshot.up else { return false }
    if let error = probe.holdDown() {
      log("[diag] AWDL helper could not turn awdl0 off again (\(reason)): \(error)")
      return false
    }
    log("[diag] AWDL helper turned awdl0 off again: reason=\(reason)")
    return true
  }

  // MARK: Private

  private func reset() {
    holding = false
    ownerID = nil
    generation = 0
  }

  private func restoreHold(reason: String, forceHolding: Bool = false) -> AwdlSessionEnd {
    guard holding || forceHolding else { return .nothingToRestore }

    var failure: String?
    switch probe.releaseHold() {
    case .stillHeld:
      // Another client keeps awdl0 down: the helper brings it up when that one lets go. The marker stays (the other
      // client may share it); the next run clears it when it sees awdl0 up.
      log("[diag] AWDL helper released its hold, another stream still holds awdl0: reason=\(reason)")
      return .heldByOthers
    case .failed(let error):
      failure = error
    case .released:
      if !probe.waitForInterface(up: true) { failure = "awdl0 stayed down" }
    }
    // The hold may be gone already (the helper restarted): then the release has nothing to give back, and awdl0 is
    // brought up directly.
    if failure != nil {
      if let error = probe.forceUp() {
        failure = error
      } else if probe.waitForInterface(up: true) {
        failure = nil
      }
    }

    if let failure {
      log("[diag] AWDL helper failed to restore pre-stream state: reason=\(reason) error=\(failure)")
      return .restoreFailed(failure)
    }
    pending.required = false
    log("[diag] AWDL helper restored pre-stream state: reason=\(reason)")
    return .restored
  }
}
