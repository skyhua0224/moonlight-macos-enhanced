//
//  NetworkQuiet.swift
//  What may use the network while a computer is being connected to or streamed from, and how a failing background
//  fetch backs off. Foundation only, so tests/net-quiet compiles it on its own.
//
//  Why (a user's Mac log, over an overlay at about 10 Mbit/s):
//   - The Desktop cover of the host is a 10.7 MB picture. Every fetch of it was cut after 7 s (a whole-response wait on
//     a 5 s idle timeout) and asked again at once, by four workers, by every discovery round: the picture never
//     arrived and the link carried it all the time, also while idle. /serverinfo to the LAN address of the host timed
//     out; during a stream 9 of 10 video packets were lost.
//   - 连接桌面 asks /serverinfo first. Each click made its own request, nothing held a second click back, and when the
//     answers came (10 s later) every click opened a stream window: seven in eight seconds.
//  The rules here are the ones the callers ask:
//   - ForegroundActivity: a launch is pending or a stream window is open => no background traffic (art, discovery
//     probes, latency probes, events, mDNS search).
//   - TransferLedger: one fetch per key at a time, exponential backoff with a cap, give up after a few failures until
//     the key is reset (the host's art version changed, the app was started again).
//   - LaunchGate: one launch per computer; a second click is absorbed by the pending one.
//

import Foundation

/// Tokens of the work that owns the network. A token that is not renewed or ended expires, so a window that was lost
/// without telling cannot keep the app quiet for ever.
final class ForegroundActivity {
  private var tokens: [String: Date] = [:]
  private let lock = NSLock()
  let expiry: TimeInterval

  init(expiry: TimeInterval = 120) { self.expiry = expiry }

  /// Starts (or renews) a token.
  func begin(_ key: String, now: Date = Date()) {
    lock.lock(); tokens[key] = now; lock.unlock()
  }

  func end(_ key: String) {
    lock.lock(); tokens.removeValue(forKey: key); lock.unlock()
  }

  /// A stream that is running renews its token; a pending launch does not (it ends or expires).
  func isQuiet(now: Date = Date()) -> Bool {
    lock.lock(); defer { lock.unlock() }
    for (key, started) in tokens where now.timeIntervalSince(started) > expiry { tokens.removeValue(forKey: key) }
    return !tokens.isEmpty
  }

  var count: Int { lock.lock(); defer { lock.unlock() }; return tokens.count }
}

/// One fetch per key at a time; after a failure the key waits 2^n times the base, up to a cap; after `giveUpAfter`
/// failures it is left alone until `reset`.
final class TransferLedger {
  enum Verdict: Equatable {
    case go
    case inFlight
    case wait(until: Date)
    case gaveUp
  }

  private struct Entry { var failures = 0; var next = Date.distantPast; var inFlight = false }
  private var entries: [String: Entry] = [:]
  private let lock = NSLock()
  let base: TimeInterval, cap: TimeInterval, giveUpAfter: Int

  init(base: TimeInterval = 30, cap: TimeInterval = 900, giveUpAfter: Int = 6) {
    self.base = base; self.cap = cap; self.giveUpAfter = giveUpAfter
  }

  func delay(afterFailures n: Int) -> TimeInterval {
    guard n > 0 else { return 0 }
    return min(cap, base * pow(2, Double(n - 1)))
  }

  /// Asks for the key and, on `.go`, takes it: the caller must end with `succeed` or `fail` (or `release`).
  func claim(_ key: String, now: Date = Date()) -> Verdict {
    lock.lock(); defer { lock.unlock() }
    var e = entries[key] ?? Entry()
    if e.inFlight { return .inFlight }
    if e.failures >= giveUpAfter { return .gaveUp }
    if now < e.next { return .wait(until: e.next) }
    e.inFlight = true
    entries[key] = e
    return .go
  }

  func succeed(_ key: String) {
    lock.lock(); entries.removeValue(forKey: key); lock.unlock()
  }

  func fail(_ key: String, now: Date = Date()) {
    lock.lock()
    var e = entries[key] ?? Entry()
    e.failures += 1
    e.inFlight = false
    e.next = now.addingTimeInterval(delay(afterFailures: e.failures))
    entries[key] = e
    lock.unlock()
  }

  /// Ends a claim without counting it (cancelled because a stream started, nothing was wrong with the host).
  func release(_ key: String) {
    lock.lock()
    if var e = entries[key] { e.inFlight = false; entries[key] = e }
    lock.unlock()
  }

  func reset(_ key: String) { lock.lock(); entries.removeValue(forKey: key); lock.unlock() }
  func resetAll() { lock.lock(); entries.removeAll(); lock.unlock() }
  func failures(_ key: String) -> Int { lock.lock(); defer { lock.unlock() }; return entries[key]?.failures ?? 0 }
}

/// One launch per computer. A click while one is pending is absorbed; a pending launch older than `expiry` is
/// forgotten so a launch that never reported cannot block the button for ever.
final class LaunchGate {
  private var pending: [String: Date] = [:]
  private let lock = NSLock()
  let expiry: TimeInterval

  init(expiry: TimeInterval = 90) { self.expiry = expiry }

  /// true: this call starts the launch. false: one is pending already.
  func claim(_ host: String, now: Date = Date()) -> Bool {
    lock.lock(); defer { lock.unlock() }
    if let started = pending[host], now.timeIntervalSince(started) <= expiry { return false }
    pending[host] = now
    return true
  }

  func release(_ host: String) { lock.lock(); pending.removeValue(forKey: host); lock.unlock() }

  func isPending(_ host: String, now: Date = Date()) -> Bool {
    lock.lock(); defer { lock.unlock() }
    guard let started = pending[host] else { return false }
    if now.timeIntervalSince(started) > expiry { pending.removeValue(forKey: host); return false }
    return true
  }

  func since(_ host: String) -> Date? { lock.lock(); defer { lock.unlock() }; return pending[host] }
}

// MARK: - Process-wide instances for the Objective-C callers

/// The one answer to 「may background traffic run now」, and the hooks that stop what already runs.
@objc(MLNetworkQuiet)
final class NetworkQuiet: NSObject {
  private static let activity = ForegroundActivity()
  private static let hooksLock = NSLock()
  private static var hooks: [String: () -> Void] = [:]
  private static var idleHooks: [String: () -> Void] = [:]
  /// How long the app has been free of launches and streams before work that was stopped starts again.
  static let idleSettle: TimeInterval = 3

  /// Background work asks this before it starts, and between its steps.
  @objc static var isQuiet: Bool { activity.isQuiet() }

  /// A launch begins: background traffic stops and what is in flight is cancelled. The token expires after
  /// `ForegroundActivity.expiry` when nobody ends it (a launch that never reported).
  @objc static func begin(_ key: String) {
    activity.begin(key)
    cancelInFlight()
  }

  /// A stream window is open: the same, and the token lasts until `end` (the window owner ends it when it goes).
  @objc static func beginStream(_ key: String) {
    activity.begin(key, now: Date.distantFuture)
    cancelInFlight()
  }

  private static func cancelInFlight() {
    hooksLock.lock(); let all = Array(hooks.values); hooksLock.unlock()
    for hook in all { hook() }
  }

  @objc static func end(_ key: String) {
    activity.end(key)
    if !activity.isQuiet() { scheduleIdleHooks() }
  }

  /// Work that was stopped by a launch or a stream (a poster download) registers how to start again: called
  /// `idleSettle` seconds after the last launch or stream ended, when nothing has begun in between.
  @objc static func onIdle(_ name: String, resume: @escaping () -> Void) {
    hooksLock.lock(); idleHooks[name] = resume; hooksLock.unlock()
  }

  private static func scheduleIdleHooks() {
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + idleSettle) {
      guard !activity.isQuiet() else { return }
      hooksLock.lock(); let all = Array(idleHooks.values); hooksLock.unlock()
      for hook in all { hook() }
    }
  }

  /// Work that holds a connection (an art download) registers how to cancel it; called on every `begin`.
  @objc static func onQuiet(_ name: String, cancel: @escaping () -> Void) {
    hooksLock.lock(); hooks[name] = cancel; hooksLock.unlock()
  }
}

@objc(MLLaunchGate)
final class LaunchGateShared: NSObject {
  private static let gate = LaunchGate()
  @objc static func claim(_ hostUUID: String) -> Bool { gate.claim(hostUUID) }
  @objc static func release(_ hostUUID: String) { gate.release(hostUUID) }
  @objc static func isPending(_ hostUUID: String) -> Bool { gate.isPending(hostUUID) }
}

@objc(MLArtLedger)
final class ArtLedgerShared: NSObject {
  private static let ledger = TransferLedger()
  /// 0 go, 1 in flight, 2 waiting for its backoff, 3 gave up.
  @objc static func claim(_ key: String) -> Int {
    switch ledger.claim(key) {
    case .go: return 0
    case .inFlight: return 1
    case .wait: return 2
    case .gaveUp: return 3
    }
  }
  @objc static func succeed(_ key: String) { ledger.succeed(key) }
  @objc static func fail(_ key: String) { ledger.fail(key) }
  @objc static func release(_ key: String) { ledger.release(key) }
  @objc static func reset(_ key: String) { ledger.reset(key) }
  @objc static func resetAll() { ledger.resetAll() }
}
