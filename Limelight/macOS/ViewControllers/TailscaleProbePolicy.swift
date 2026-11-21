import Foundation

/// The decision layer of the Tailscale status probe: which binary runs, with which environment, and when
/// a probe may run at all. Foundation only, so tests/tailscale-probe compiles this file on its own.
///
/// Sources: Tailscale CLI reference (tailscale.com/docs/reference/tailscale-cli, retrieved 2026-11-21).
/// The macOS client bundles the CLI inside the application executable and picks GUI or CLI from its
/// environment (SHLVL, TERM, TERM_PROGRAM, PS1); a script that parses `tailscale status` must set
/// TAILSCALE_BE_CLI=1 so the macOS app is not opened. The Standalone variant's CLI integration installs
/// a launcher at /usr/local/bin/tailscale; the App Store variant runs the executable inside the app bundle.

enum TailscaleProbePolicy {
  /// How long a completed status answer stays authoritative (the relay hint reads it without probing).
  static let freshInterval: TimeInterval = 60
  /// First wait after a failed probe; doubles with each consecutive failure.
  static let minBackoff: TimeInterval = 30
  /// Ceiling of the failure backoff: 30 s, 60 s, 120 s, 240 s, 480 s, then 10 minutes.
  static let maxBackoff: TimeInterval = 600

  static func backoff(afterFailures count: Int) -> TimeInterval {
    guard count > 0 else { return 0 }
    return min(minBackoff * pow(2, Double(count - 1)), maxBackoff)
  }
}

enum TailscaleCLI {
  struct Candidate: Equatable {
    let path: String
    /// True only for the executable inside the Tailscale app bundle: without TAILSCALE_BE_CLI=1 it opens
    /// the GUI app instead of answering on stdout.
    let opensGUIWithoutCLIEnv: Bool
  }

  static let statusArguments = ["status", "--json"]

  /// A standalone CLI never opens the GUI app, so it is preferred over the bundled executable: `tailscale`
  /// on PATH, then the Standalone variant's /usr/local/bin launcher and Homebrew's /opt/homebrew/bin. A GUI
  /// app inherits the minimal launchd PATH, so the well-known prefixes are always checked, not just PATH.
  static func standaloneCandidates(environment: [String: String]) -> [String] {
    var candidates: [String] = []
    for directory in (environment["PATH"] ?? "").split(separator: ":") where !directory.isEmpty {
      candidates.append("\(directory)/tailscale")
    }
    candidates.append("/usr/local/bin/tailscale")
    candidates.append("/opt/homebrew/bin/tailscale")
    var seen = Set<String>()
    return candidates.filter { seen.insert($0).inserted }
  }

  static func bundledAppExecutable() -> String {
    "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
  }

  static func select(environment: [String: String], isExecutable: (String) -> Bool) -> Candidate? {
    for path in standaloneCandidates(environment: environment) where isExecutable(path) {
      return Candidate(path: path, opensGUIWithoutCLIEnv: false)
    }
    let bundled = bundledAppExecutable()
    if isExecutable(bundled) {
      return Candidate(path: bundled, opensGUIWithoutCLIEnv: true)
    }
    return nil
  }

  /// TAILSCALE_BE_CLI=1 only for the bundled executable; the standalone launcher already runs as a CLI.
  static func environment(for candidate: Candidate, base: [String: String]) -> [String: String] {
    guard candidate.opensGUIWithoutCLIEnv else { return base }
    var environment = base
    environment["TAILSCALE_BE_CLI"] = "1"
    return environment
  }
}

/// One probe at a time, and a failing probe retried on an exponential schedule. The clock is injected, so
/// the tests never sleep. Not thread-safe by itself: the owner runs it on one serial queue.
final class TailscaleProbeGate {
  private(set) var inFlight = false
  private(set) var consecutiveFailures = 0
  private var blockedUntil = Date.distantPast

  /// A probe may start when none is running and the failure backoff has passed. `force` (a connect needs
  /// the status now) skips only the backoff, never the one-in-flight rule.
  func begin(now: Date, force: Bool = false) -> Bool {
    if inFlight { return false }
    if !force, now < blockedUntil { return false }
    inFlight = true
    return true
  }

  func end(success: Bool, now: Date) {
    inFlight = false
    if success {
      consecutiveFailures = 0
      blockedUntil = .distantPast
    } else {
      consecutiveFailures += 1
      blockedUntil = now.addingTimeInterval(TailscaleProbePolicy.backoff(afterFailures: consecutiveFailures))
    }
  }
}

enum TailscaleDetection {
  static let defaultsKey = "autoDetectTailscale"

  /// On unless the user turned it off. object(forKey:) tells "set to off" from "never set".
  static func isEnabled(defaults: UserDefaults) -> Bool {
    defaults.object(forKey: defaultsKey) == nil ? true : defaults.bool(forKey: defaultsKey)
  }
}
