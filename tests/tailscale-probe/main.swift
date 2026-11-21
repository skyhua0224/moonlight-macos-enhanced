import Foundation

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
  if !ok { failures += 1 }
  print("\(ok ? "PASS" : "FAIL") \(name)\(ok ? "" : " — " + detail())")
}
let t0 = Date(timeIntervalSince1970: 1_700_000_000)

// 1. Failure backoff: 30 s doubling to the 10-minute ceiling, none before the first failure.
do {
  let schedule = (0...7).map { TailscaleProbePolicy.backoff(afterFailures: $0) }
  check("backoff schedule 0, 30, 60, 120, 240, 480, 600, 600",
        schedule == [0, 30, 60, 120, 240, 480, 600, 600], "\(schedule)")
}

// 2. Coalescing: one probe in flight at a time, whatever asks.
do {
  let gate = TailscaleProbeGate()
  check("first probe may begin", gate.begin(now: t0))
  check("second probe while one runs is refused", !gate.begin(now: t0))
  check("a forced probe while one runs is refused too", !gate.begin(now: t0, force: true))
}

// 3. Backoff gate: after one failure the next probe waits 30 s; force does not wait.
do {
  let gate = TailscaleProbeGate()
  _ = gate.begin(now: t0)
  gate.end(success: false, now: t0)
  check("probe 29 s after a failure is refused", !gate.begin(now: t0.addingTimeInterval(29)))
  check("forced probe right after a failure is allowed", gate.begin(now: t0, force: true))
}
do {
  let gate = TailscaleProbeGate()
  _ = gate.begin(now: t0)
  gate.end(success: false, now: t0)
  check("probe 31 s after the failure is allowed", gate.begin(now: t0.addingTimeInterval(31)))
}

// 4. Success clears the failure history; the backoff grows per consecutive failure.
do {
  let gate = TailscaleProbeGate()
  _ = gate.begin(now: t0)
  gate.end(success: false, now: t0)   // failure 1: blocked 30 s
  _ = gate.begin(now: t0.addingTimeInterval(60), force: true)
  gate.end(success: false, now: t0.addingTimeInterval(60))   // failure 2: blocked 60 s
  check("second consecutive failure blocks for 60 s", !gate.begin(now: t0.addingTimeInterval(60 + 59)))
  check("probe after the doubled wait is allowed", gate.begin(now: t0.addingTimeInterval(60 + 60)))
  gate.end(success: true, now: t0.addingTimeInterval(120))
  check("success resets the backoff", gate.begin(now: t0.addingTimeInterval(120.5)))
}

// 5. A standalone CLI is preferred over the app bundle; the bundle is the fallback; none is nil.
do {
  let env = ["PATH": "/usr/bin:/bin:/opt/homebrew/bin"]
  let bundle = TailscaleCLI.bundledAppExecutable()
  var present = Set([bundle, "/opt/homebrew/bin/tailscale"])
  var picked = TailscaleCLI.select(environment: env, isExecutable: { present.contains($0) })
  check("standalone CLI wins over the app bundle",
        picked == TailscaleCLI.Candidate(path: "/opt/homebrew/bin/tailscale", opensGUIWithoutCLIEnv: false), "\(String(describing: picked))")
  present = [bundle]
  picked = TailscaleCLI.select(environment: env, isExecutable: { present.contains($0) })
  check("app bundle is used when no standalone CLI exists",
        picked == TailscaleCLI.Candidate(path: bundle, opensGUIWithoutCLIEnv: true), "\(String(describing: picked))")
  picked = TailscaleCLI.select(environment: env, isExecutable: { _ in false })
  check("nothing installed picks nothing", picked == nil)
}

// 6. Candidates: PATH entries first, then the well-known prefixes a GUI app's PATH misses, no duplicates.
do {
  let list = TailscaleCLI.standaloneCandidates(environment: ["PATH": "/usr/bin:/opt/homebrew/bin:/usr/bin:"])
  check("candidate list keeps PATH order, adds prefixes, drops duplicates",
        list == ["/usr/bin/tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"], "\(list)")
}

// 7. Environment: the bundled executable is forced into CLI mode, a standalone CLI is not touched.
do {
  let base = ["PATH": "/usr/bin", "HOME": "/Users/demo"]
  let bundled = TailscaleCLI.Candidate(path: TailscaleCLI.bundledAppExecutable(), opensGUIWithoutCLIEnv: true)
  let standalone = TailscaleCLI.Candidate(path: "/opt/homebrew/bin/tailscale", opensGUIWithoutCLIEnv: false)
  let forced = TailscaleCLI.environment(for: bundled, base: base)
  check("bundled binary gets TAILSCALE_BE_CLI=1", forced["TAILSCALE_BE_CLI"] == "1", "\(forced)")
  check("bundled binary keeps the inherited environment", forced["HOME"] == "/Users/demo" && forced["PATH"] == "/usr/bin")
  check("standalone CLI environment is unchanged", TailscaleCLI.environment(for: standalone, base: base) == base)
  check("status runs as 'status --json'", TailscaleCLI.statusArguments == ["status", "--json"])
}

// 8. The detection setting: on by default, explicit off respected, explicit on respected.
do {
  let suiteName = "tailscale-probe-test-\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suiteName)!
  defer { defaults.removePersistentDomain(forName: suiteName) }
  check("detection is on when nothing was set", TailscaleDetection.isEnabled(defaults: defaults))
  defaults.set(false, forKey: TailscaleDetection.defaultsKey)
  check("detection off is read back", !TailscaleDetection.isEnabled(defaults: defaults))
  defaults.set(true, forKey: TailscaleDetection.defaultsKey)
  check("detection on is read back", TailscaleDetection.isEnabled(defaults: defaults))
  check("the setting key is the one the pane writes", TailscaleDetection.defaultsKey == "autoDetectTailscale")
}

// 9. One completion per attempt: a late duplicate (the fallback settled first, the exit handler
//    arrives later) can neither add a second failure nor overwrite the settled result.
do {
  let gate = TailscaleProbeGate()
  _ = gate.begin(now: t0)
  gate.end(success: false, now: t0)   // the fallback settles the attempt as a failure
  check("duplicate completion is not accepted", gate.end(success: true, now: t0) == false)
  check("late duplicate completion does not lift the failure backoff", !gate.begin(now: t0.addingTimeInterval(29)))
  check("late duplicate completion does not hold the slot", gate.begin(now: t0.addingTimeInterval(60), force: true))
  check("the next attempt still completes normally", gate.end(success: true, now: t0.addingTimeInterval(60)) == true)
}

// 10. A probe that finishes after detection was turned off publishes nothing and does not mark the
//     cache fresh; its own success still counts for the backoff.
do {
  let late = TailscaleProbeOutcome(succeeded: true, detectionEnabled: false)
  check("late success with detection off publishes no relays", !late.publishesAnswer)
  check("late success with detection off does not mark the cache fresh", !late.marksCacheFresh)
  check("late success still counts as a successful run", late.countsAsSuccess)
  let live = TailscaleProbeOutcome(succeeded: true, detectionEnabled: true)
  check("success with detection on publishes and marks fresh", live.publishesAnswer && live.marksCacheFresh)
  let failed = TailscaleProbeOutcome(succeeded: false, detectionEnabled: true)
  check("failure publishes and marks nothing", !failed.publishesAnswer && !failed.marksCacheFresh && !failed.countsAsSuccess)
}

// 11. Escalation: SIGTERM at the answer deadline, SIGKILL after the grace, last resort only after
//     the kill grace; nothing but an observed exit releases the slot along the way.
do {
  let schedule = TailscaleProbeTimeout.schedule(startedAt: t0)
  let term = schedule.terminateAt.timeIntervalSince(t0)
  let kill = schedule.killAt.timeIntervalSince(t0)
  let last = schedule.lastResortAt.timeIntervalSince(t0)
  check("escalation order 2 s, 3 s, 3.5 s", term == 2 && kill == 3 && last == 3.5, "\(term) \(kill) \(last)")
  let gate = TailscaleProbeGate()
  check("probe starts", gate.begin(now: t0))
  check("slot still held at the SIGTERM deadline", !gate.begin(now: schedule.terminateAt))
  check("slot still held at the SIGKILL deadline", !gate.begin(now: schedule.killAt))
  gate.end(success: false, now: schedule.lastResortAt)   // the exit is observed right after the kill
  check("the observed exit releases the slot", gate.begin(now: schedule.lastResortAt, force: true))
}

print(failures == 0 ? "tailscale-probe: all cases passed" : "tailscale-probe: \(failures) case(s) failed")
exit(failures == 0 ? 0 : 1)
