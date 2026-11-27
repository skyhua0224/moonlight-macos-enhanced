import Foundation

var failures = 0

func check(_ name: String, _ condition: Bool) {
  if condition {
    print("ok   \(name)")
  } else {
    failures += 1
    print("FAIL \(name)")
  }
}

func expect<T: Equatable>(_ name: String, _ actual: T, _ expected: T) {
  if actual == expected {
    print("ok   \(name)")
  } else {
    failures += 1
    print("FAIL \(name): expected \(expected), got \(actual)")
  }
}

// MARK: - The setting's default and what a stored value means

expect("new install, nothing stored: on", AwdlHelperDefault.isEnabled(stored: nil), true)
expect("the user turned it off: stays off", AwdlHelperDefault.isEnabled(stored: false), false)
expect("the user turned it on: stays on", AwdlHelperDefault.isEnabled(stored: true), true)

do {
  // The way the app reads it: through a real preferences domain, where a missing value is nil and a value of another type
  // is not a Bool.
  let suiteName = "awdl-helper-policy-test.\(ProcessInfo.processInfo.processIdentifier)"
  let defaults = UserDefaults(suiteName: suiteName)!
  defaults.removePersistentDomain(forName: suiteName)
  let key = "networkCompatibility.awdlHelperEnabled"
  func read() -> Bool { AwdlHelperDefault.isEnabled(stored: defaults.object(forKey: key) as? Bool) }
  expect("preferences without the key (every existing user who never touched it): on", read(), true)
  defaults.set(false, forKey: key)
  expect("preferences with an explicit off: off", read(), false)
  defaults.set(true, forKey: key)
  expect("preferences with an explicit on: on", read(), true)
  defaults.set("0", forKey: key)
  expect("preferences with a string: not a choice, the default", read(), true)
  defaults.removeObject(forKey: key)
  expect("the key removed again: on", read(), true)
  defaults.removePersistentDomain(forName: suiteName)
}

// MARK: - Helper link

func link(_ handshake: AwdlHelperHandshake, file: Bool = true) -> AwdlHelperLink {
  AwdlHelperLink.evaluate(handshake, installedFilePresent: file, expectedVersion: 2)
}
expect("link: answers with the current version", link(AwdlHelperHandshake(reachable: true, interfaceVersion: 2)), .ready)
expect("link: a newer helper is fine", link(AwdlHelperHandshake(reachable: true, interfaceVersion: 3)), .ready)
expect("link: no answer to the version call (helper of an older build)", link(AwdlHelperHandshake(reachable: true, interfaceVersion: 0)), .outdated)
expect("link: older version", link(AwdlHelperHandshake(reachable: true, interfaceVersion: 1)), .outdated)
expect("link: nothing answers, file there", link(AwdlHelperHandshake(reachable: false), file: true), .notRunning)
expect("link: nothing answers, no file", link(AwdlHelperHandshake(reachable: false), file: false), .notInstalled)

// MARK: - When the authorization is asked for

func setup(
  enabled: Bool = true, supported: Bool = true, interface: Bool = true, sidecar: Bool = false,
  _ link: AwdlHelperLink, _ record: AwdlSetupRecord = AwdlSetupRecord(), build: String = "1.4.0 (1500)"
) -> AwdlSetupAction {
  AwdlSetupRules.action(
    enabled: enabled, supported: supported, interfacePresent: interface, sidecarActive: sidecar,
    link: link, record: record, currentBuild: build)
}
expect("setup: first stream, no helper: explain and install", setup(.notInstalled), .install)
expect("setup: the helper is ready: nothing", setup(.ready), .none)
expect("setup: the switch is off: nothing", setup(enabled: false, .notInstalled), .none)
expect("setup: this build cannot install: nothing", setup(supported: false, .notInstalled), .none)
expect("setup: no awdl0: nothing", setup(interface: false, .notInstalled), .none)
expect("setup: Sidecar connected (awdl0 stays up): nothing", setup(sidecar: true, .notInstalled), .none)
expect("setup: answered once (any button): never again", setup(.notInstalled, AwdlSetupRecord(installAnswered: true)), .none)
expect("setup: answered on an earlier build: still never again", setup(.notInstalled, AwdlSetupRecord(installAnswered: true, updatePromptedBuild: "1.3.9 (1400)"), build: "1.4.1 (1600)"), .none)
expect("setup: helper of an older build: ask to update", setup(.outdated), .update)
expect("setup: updated question answered on this build: not again", setup(.outdated, AwdlSetupRecord(updatePromptedBuild: "1.4.0 (1500)")), .none)
expect("setup: next build, still outdated: ask once more", setup(.outdated, AwdlSetupRecord(updatePromptedBuild: "1.4.0 (1500)"), build: "1.4.1 (1600)"), .update)
expect("setup: install answered does not hide the update", setup(.outdated, AwdlSetupRecord(installAnswered: true)), .update)
expect("setup: installed but not answering: repair offered once per build", setup(.notRunning), .update)
expect("setup: installed but not answering, asked on this build: not again", setup(.notRunning, AwdlSetupRecord(updatePromptedBuild: "1.4.0 (1500)")), .none)

// MARK: - The administrator prompt's answers

expect("prompt: success", AwdlAdminPromptResult.classify(terminationStatus: 0, output: ""), .succeeded)
expect("prompt: cancelled", AwdlAdminPromptResult.classify(terminationStatus: 1, output: "execution error: User canceled. (-128)"), .cancelled)
expect("prompt: no answer", AwdlAdminPromptResult.classify(terminationStatus: 1, output: "  \n"), .noResponse)
expect("prompt: timed out", AwdlAdminPromptResult.classify(terminationStatus: -2, output: "Timed out after 120 seconds"), .timedOut)
expect("prompt: not an administrator", AwdlAdminPromptResult.classify(terminationStatus: 1, output: "Not authorized to send Apple events (-60005)"), .notAdministrator)
expect("prompt: blocked by policy", AwdlAdminPromptResult.classify(terminationStatus: 1, output: "execution error: not permitted (-10004)"), .blocked)
expect("prompt: anything else keeps its text", AwdlAdminPromptResult.classify(terminationStatus: 1, output: "boom\n"), .failed("boom"))

// MARK: - A fake awdl0 and helper

final class FakeProbe: AwdlHelperProbing {
  var snapshot = AwdlInterfaceSnapshot(present: true, up: true)
  var helper = AwdlHelperHandshake(reachable: true, interfaceVersion: 2, buildVersion: "1500")
  var fileThere = true
  var holdError: String?
  var releaseError: String?
  var forceUpError: String?
  /// The helper accepts the down but the interface does not go down.
  var holdLeavesUp = false
  var commands: [String] = []

  var installedFilePresent: Bool { fileThere }
  func handshake() -> AwdlHelperHandshake {
    commands.append("handshake")
    return helper
  }
  func interfaceSnapshot() -> AwdlInterfaceSnapshot { snapshot }
  func holdDown() -> String? {
    commands.append("hold")
    if let holdError { return holdError }
    if !holdLeavesUp { snapshot.up = false }
    return nil
  }
  func releaseHold() -> String? {
    commands.append("release")
    if let releaseError { return releaseError }
    snapshot.up = true
    return nil
  }
  func forceUp() -> String? {
    commands.append("force-up")
    if let forceUpError { return forceUpError }
    snapshot.up = true
    return nil
  }
  func waitForInterface(up: Bool) -> Bool { snapshot.present && snapshot.up == up }

  /// What was asked of awdl0 itself, without the handshakes.
  var changes: [String] { commands.filter { $0 != "handshake" } }
}

final class FakeMarker: AwdlPendingRestoreStoring {
  var required = false
}

// MARK: - Self-check

do {
  let p = FakeProbe()
  expect("self-check: passes and shows awdl0 went down and up", AwdlSelfCheck.run(p), .passed(toggleVerified: true))
  expect("self-check: down, then up", p.changes, ["hold", "release"])
  check("self-check: awdl0 is up afterwards", p.snapshot.up)
}
do {
  let p = FakeProbe()
  p.helper = AwdlHelperHandshake(reachable: false, error: "connection invalid")
  p.fileThere = false
  expect("self-check: helper missing", AwdlSelfCheck.run(p), .failed(.helperNotRunning("connection invalid")))
  expect("self-check: nothing touched", p.changes, [])
}
do {
  let p = FakeProbe()
  p.helper = AwdlHelperHandshake(reachable: true, interfaceVersion: 1)
  expect("self-check: version mismatch", AwdlSelfCheck.run(p), .failed(.helperOutdated(found: 1, expected: AwdlHelperContract.interfaceVersion)))
  expect("self-check: nothing touched on a mismatch", p.changes, [])
}
do {
  let p = FakeProbe()
  p.holdError = "ifconfig: interface does not permit"
  expect("self-check: helper refuses", AwdlSelfCheck.run(p), .failed(.holdRejected("ifconfig: interface does not permit")))
  check("self-check: still up", p.snapshot.up && p.changes == ["hold"])
}
do {
  let p = FakeProbe()
  p.holdLeavesUp = true
  expect("self-check: awdl0 does not go down", AwdlSelfCheck.run(p), .failed(.downNotObserved))
  check("self-check: the hold is released", p.changes == ["hold", "release"] && p.snapshot.up)
}
do {
  let p = FakeProbe()
  p.releaseError = "helper restarted"
  expect("self-check: release fails, brought up directly", AwdlSelfCheck.run(p), .passed(toggleVerified: true))
  expect("self-check: release then force-up", p.changes, ["hold", "release", "force-up"])
}
do {
  let p = FakeProbe()
  p.releaseError = "gone"
  p.forceUpError = "no"
  expect("self-check: awdl0 cannot be brought back", AwdlSelfCheck.run(p), .failed(.notRestored))
}
do {
  let p = FakeProbe()
  p.snapshot.up = false
  expect("self-check: awdl0 down already, handshake only", AwdlSelfCheck.run(p), .passed(toggleVerified: false))
  expect("self-check: down already, nothing touched", p.changes, [])
}
do {
  let p = FakeProbe()
  expect("self-check: no toggle while a stream or Sidecar uses awdl0", AwdlSelfCheck.run(p, allowToggle: false), .passed(toggleVerified: false))
  expect("self-check: no toggle, nothing touched", p.changes, [])
}
do {
  let p = FakeProbe()
  p.snapshot.present = false
  expect("self-check: no awdl0", AwdlSelfCheck.run(p), .noInterface)
}
check("self-check: every failure has a message key", [
  AwdlSelfCheckFailure.helperNotRunning(""), .helperOutdated(found: 0, expected: 2), .holdRejected(""), .downNotObserved, .notRestored,
].allSatisfy { !$0.messageKey.isEmpty })

// MARK: - Stream session

func engine(_ p: FakeProbe, _ m: FakeMarker) -> AwdlSessionEngine {
  AwdlSessionEngine(probe: p, pending: m)
}

do {
  // The ownership cases of the old window-cleanup test, now against the real engine.
  let p = FakeProbe(), m = FakeMarker()
  let e = engine(p, m)
  expect("session: begins", e.begin(enabled: true, sidecarActive: false, generation: 1, ownerID: "old"), .active)
  check("session: awdl0 down, marker written", !p.snapshot.up && m.required && e.isActive)
  expect("session: the owner ends it", e.end(forOwner: "old", reason: "begin-stop:old"), .restored)
  check("session: awdl0 up, marker gone", p.snapshot.up && !m.required && !e.isActive)
  expect("session: a replacement with the same generation number begins", e.begin(enabled: true, sidecarActive: false, generation: 1, ownerID: "current"), .active)
  expect("session: a late cleanup of the replaced stream does nothing", e.end(forOwner: "old", reason: "stream-view-controller-dealloc"), .notOwner)
  check("session: the replacement is untouched", e.isActive && !p.snapshot.up && e.generation == 1)
  expect("session: a missing owner does nothing", e.end(forOwner: nil, reason: "never-started"), .notOwner)
  check("session: still the replacement", e.ownerID == "current" && !p.snapshot.up)
  expect("session: the current owner ends it", e.end(forOwner: "current", reason: "begin-stop:current"), .restored)
  check("session: closed", !e.isActive && e.ownerID == nil && p.snapshot.up)
  let count = p.changes.count
  expect("session: repeated cleanup", e.end(forOwner: "current", reason: "repeated-cleanup"), .notOwner)
  check("session: repeated cleanup asks for nothing", p.changes.count == count)
  expect("session: switch off", e.begin(enabled: false, sidecarActive: false, generation: 2, ownerID: "disabled"), .disabled)
  expect("session: switch off, its cleanup", e.end(forOwner: "disabled", reason: "disabled-close"), .notOwner)
  check("session: switch off asks for nothing", p.changes.count == count)
}
do {
  let p = FakeProbe(), m = FakeMarker()
  let e = engine(p, m)
  _ = e.begin(enabled: true, sidecarActive: false, generation: 1, ownerID: "first")
  expect("session: a new stream supersedes one that never ended", e.begin(enabled: true, sidecarActive: false, generation: 2, ownerID: "second"), .active)
  expect("session: the old one is released before the new one", p.changes, ["hold", "release", "hold"])
  check("session: the new owner holds", e.ownerID == "second" && !p.snapshot.up)
}
do {
  let p = FakeProbe(), m = FakeMarker()
  let e = engine(p, m)
  _ = e.begin(enabled: true, sidecarActive: false, generation: 1, ownerID: "a")
  expect("session: Sidecar connected for the next stream: the earlier hold is given back", e.begin(enabled: true, sidecarActive: true, generation: 2, ownerID: "b"), .sidecar)
  check("session: Sidecar leaves awdl0 up", p.snapshot.up && !m.required && !e.isActive)
}
for (name, helper, file, link) in [
  ("not installed", AwdlHelperHandshake(reachable: false), false, AwdlHelperLink.notInstalled),
  ("installed, not answering", AwdlHelperHandshake(reachable: false), true, AwdlHelperLink.notRunning),
  ("older than the app", AwdlHelperHandshake(reachable: true, interfaceVersion: 1), true, AwdlHelperLink.outdated),
  ("of a build before the version call", AwdlHelperHandshake(reachable: true, interfaceVersion: 0), true, AwdlHelperLink.outdated),
] {
  let p = FakeProbe(), m = FakeMarker()
  p.helper = helper
  p.fileThere = file
  let e = engine(p, m)
  expect("session: helper \(name): the stream goes on, awdl0 untouched", e.begin(enabled: true, sidecarActive: false, generation: 1, ownerID: "a"), .helperNotReady(link))
  check("session: helper \(name): no command, no marker, no session", p.changes.isEmpty && !m.required && !e.isActive && p.snapshot.up)
}
do {
  let p = FakeProbe(), m = FakeMarker()
  p.snapshot.present = false
  expect("session: no awdl0", engine(p, m).begin(enabled: true, sidecarActive: false, generation: 1, ownerID: "a"), .noInterface)
}
do {
  let p = FakeProbe(), m = FakeMarker()
  p.snapshot.up = false
  let e = engine(p, m)
  expect("session: awdl0 down before the stream: left alone", e.begin(enabled: true, sidecarActive: false, generation: 1, ownerID: "a"), .alreadyDown)
  check("session: and not brought up afterwards", p.changes.isEmpty && !m.required && e.end(forOwner: "a", reason: "x") == .notOwner && !p.snapshot.up)
}
do {
  let p = FakeProbe(), m = FakeMarker()
  p.holdError = "denied"
  expect("session: the helper refuses", engine(p, m).begin(enabled: true, sidecarActive: false, generation: 1, ownerID: "a"), .holdFailed("denied"))
  check("session: no marker is left", !m.required && p.snapshot.up)
}
do {
  let p = FakeProbe(), m = FakeMarker()
  p.holdLeavesUp = true
  expect("session: awdl0 stays up after the helper said down", engine(p, m).begin(enabled: true, sidecarActive: false, generation: 1, ownerID: "a"), .holdFailed("awdl0 stayed up"))
  check("session: the hold is given back and no marker is left", !m.required && p.snapshot.up && p.changes == ["hold", "release"])
}

// Restore paths
do {
  let p = FakeProbe(), m = FakeMarker()
  let e = engine(p, m)
  _ = e.begin(enabled: true, sidecarActive: false, generation: 1, ownerID: "a")
  p.releaseError = "connection invalid"
  expect("restore: the release fails, awdl0 is brought up directly", e.end(forOwner: "a", reason: "stream-ended"), .restored)
  check("restore: up, marker gone", p.snapshot.up && !m.required)
}
do {
  let p = FakeProbe(), m = FakeMarker()
  let e = engine(p, m)
  _ = e.begin(enabled: true, sidecarActive: false, generation: 1, ownerID: "a")
  p.releaseError = "gone"
  p.forceUpError = "helper not running"
  expect("restore: nothing works: reported", e.end(forOwner: "a", reason: "stream-ended"), .restoreFailed("helper not running"))
  check("restore: the marker stays for the next launch", m.required && !p.snapshot.up && !e.isActive)
  p.releaseError = nil
  p.forceUpError = nil
  expect("restore: next launch finds the marker and brings awdl0 up", e.restorePending(reason: "launch"), .restored)
  check("restore: up, marker gone", p.snapshot.up && !m.required)
}
do {
  // Crash or force quit: a new process, a marker on disk, awdl0 down.
  let p = FakeProbe(), m = FakeMarker()
  m.required = true
  p.snapshot.up = false
  expect("restore: after a crash", engine(p, m).restorePending(reason: "launch"), .restored)
  check("restore: after a crash: up, marker gone", p.snapshot.up && !m.required && p.changes == ["force-up"])
}
do {
  let p = FakeProbe(), m = FakeMarker()
  m.required = true
  p.snapshot.up = false
  p.helper = AwdlHelperHandshake(reachable: false, error: "no helper")
  expect("restore: helper cannot be reached", engine(p, m).restorePending(reason: "launch"), .cannotRestore("no helper"))
  check("restore: the marker stays", m.required && p.changes.isEmpty)
}
do {
  let p = FakeProbe(), m = FakeMarker()
  m.required = true
  p.snapshot.up = false
  p.forceUpError = "busy"
  expect("restore: awdl0 refuses", engine(p, m).restorePending(reason: "wake"), .cannotRestore("busy"))
  check("restore: the marker stays when awdl0 refuses", m.required)
}
do {
  let p = FakeProbe(), m = FakeMarker()
  m.required = true
  expect("restore: the helper (or the system) brought awdl0 up already: only the marker goes", engine(p, m).restorePending(reason: "launch"), .alreadyUp)
  check("restore: nothing asked of awdl0", !m.required && p.changes.isEmpty)
}
do {
  let p = FakeProbe(), m = FakeMarker()
  expect("restore: nothing pending", engine(p, m).restorePending(reason: "launch"), .nothingPending)
}
do {
  let p = FakeProbe(), m = FakeMarker()
  let e = engine(p, m)
  _ = e.begin(enabled: true, sidecarActive: false, generation: 1, ownerID: "a")
  expect("restore: not under a running stream (wake)", e.restorePending(reason: "wake"), .sessionActive)
  check("restore: the running stream keeps awdl0 down", !p.snapshot.up && m.required)
}
do {
  // An earlier run left awdl0 down and the marker; the helper is there: restore first, then the new stream takes it.
  let p = FakeProbe(), m = FakeMarker()
  m.required = true
  p.snapshot.up = false
  let e = engine(p, m)
  expect("restore: a new stream after a crash", e.begin(enabled: true, sidecarActive: false, generation: 1, ownerID: "a"), .active)
  expect("restore: it brings awdl0 up first, so that 'up' is what is given back", p.changes, ["force-up", "hold"])
  expect("restore: the end gives back up", e.end(forOwner: "a", reason: "x"), .restored)
  check("restore: awdl0 up at the end", p.snapshot.up)
}
do {
  let p = FakeProbe(), m = FakeMarker()
  let e = engine(p, m)
  _ = e.begin(enabled: true, sidecarActive: false, generation: 1, ownerID: "a")
  expect("quit: the app restores awdl0", e.shutdown(reason: "app-will-terminate"), .restored)
  check("quit: up, marker gone, session closed", p.snapshot.up && !m.required && !e.isActive)
  expect("quit: with no stream there is nothing", e.shutdown(reason: "app-will-terminate"), .nothingToRestore)
}
do {
  let p = FakeProbe(), m = FakeMarker()
  let e = engine(p, m)
  check("wake: no stream, nothing to turn off again", !e.reassertIfActive(reason: "wake"))
  _ = e.begin(enabled: true, sidecarActive: false, generation: 1, ownerID: "a")
  check("wake: awdl0 still down, nothing to do", !e.reassertIfActive(reason: "wake"))
  p.snapshot.up = true
  check("wake: the system brought awdl0 up under the stream: down again", e.reassertIfActive(reason: "wake") && !p.snapshot.up)
  p.holdError = "gone"
  p.snapshot.up = true
  check("wake: the helper is gone: reported as not done", !e.reassertIfActive(reason: "wake"))
}

// The marker as a file
do {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("awdl-marker-test-\(ProcessInfo.processInfo.processIdentifier)")
  let url = dir.appendingPathComponent("nested/awdl-restore-pending")
  try? FileManager.default.removeItem(at: dir)
  let marker = AwdlPendingRestoreFile(url: url)
  check("marker file: absent at first", !marker.required)
  marker.required = true
  check("marker file: written (survives a new instance)", AwdlPendingRestoreFile(url: url).required)
  marker.required = false
  check("marker file: cleared", !AwdlPendingRestoreFile(url: url).required)
  marker.required = false
  check("marker file: clearing twice is harmless", !marker.required)
  try? FileManager.default.removeItem(at: dir)
}

if failures > 0 {
  print("\(failures) failed")
  exit(1)
}
print("all passed")
