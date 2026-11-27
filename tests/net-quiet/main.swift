// tests/net-quiet: the rules of NetworkQuiet.swift (launch gate, quiet while connecting or streaming, backoff).
import Foundation

var failures = 0
func check(_ name: String, _ ok: Bool) {
  if ok { print("ok   \(name)") } else { print("FAIL \(name)"); failures += 1 }
}
let t0 = Date(timeIntervalSince1970: 1_000_000)
func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

// --- ForegroundActivity
do {
  let a = ForegroundActivity(expiry: 90)
  check("quiet: nothing running is not quiet", !a.isQuiet(now: at(0)))
  a.begin("launch:h1", now: at(0))
  check("quiet: a pending launch is quiet", a.isQuiet(now: at(10)))
  check("quiet: a launch nobody ended expires", !a.isQuiet(now: at(91)))
  a.begin("stream:v1", now: Date.distantFuture)
  check("quiet: a stream does not expire", a.isQuiet(now: at(100_000)))
  a.begin("launch:h2", now: at(100_000))
  a.end("stream:v1")
  check("quiet: ending the stream leaves the launch", a.isQuiet(now: at(100_001)))
  a.end("launch:h2")
  check("quiet: all ended is not quiet", !a.isQuiet(now: at(100_002)))
  a.begin("a", now: at(0)); a.begin("b", now: at(0)); a.end("a")
  check("quiet: two owners, one ends, still quiet", a.isQuiet(now: at(1)))
}

// --- TransferLedger
do {
  let l = TransferLedger(base: 30, cap: 900, giveUpAfter: 6)
  check("ledger: delays 30 60 120 240 480 900", [1, 2, 3, 4, 5, 6].map { l.delay(afterFailures: $0) } == [30, 60, 120, 240, 480, 900])
  check("ledger: first claim goes", l.claim("k", now: at(0)) == .go)
  check("ledger: a second claim of the same key is in flight", l.claim("k", now: at(1)) == .inFlight)
  check("ledger: another key goes", l.claim("other", now: at(1)) == .go)
  l.fail("k", now: at(7))
  check("ledger: after a failure the key waits", l.claim("k", now: at(20)) == .wait(until: at(37)))
  check("ledger: ... and goes when the wait is over", l.claim("k", now: at(37)) == .go)
  l.fail("k", now: at(40))
  check("ledger: the second failure waits 60 s", l.claim("k", now: at(99)) == .wait(until: at(100)))
  l.succeed("k")
  check("ledger: success forgets the failures", l.failures("k") == 0 && l.claim("k", now: at(100)) == .go)
  l.release("k")
  check("ledger: release is not a failure", l.failures("k") == 0 && l.claim("k", now: at(100)) == .go)
  l.release("k")

  let g = TransferLedger(base: 1, cap: 4, giveUpAfter: 3)
  var now = at(0)
  for _ in 0..<3 { _ = g.claim("x", now: now); g.fail("x", now: now); now = now.addingTimeInterval(100) }
  check("ledger: gives up after the limit", g.claim("x", now: now) == .gaveUp)
  check("ledger: ... for ever", g.claim("x", now: now.addingTimeInterval(1e6)) == .gaveUp)
  g.reset("x")
  check("ledger: reset (new art version) starts again", g.claim("x", now: now) == .go)
  check("ledger: cap holds", g.delay(afterFailures: 40) == 4)
}

// --- DiscoveryPreference
do {
  let d = UserDefaults(suiteName: "net-quiet-test-discovery")!
  d.removePersistentDomain(forName: "net-quiet-test-discovery")
  check("discovery switch: absent means on", DiscoveryPreference.isEnabled(d))
  d.set(false, forKey: DiscoveryPreference.key)
  check("discovery switch: off is off", !DiscoveryPreference.isEnabled(d))
  d.set(true, forKey: DiscoveryPreference.key)
  check("discovery switch: on is on", DiscoveryPreference.isEnabled(d))
  check("discovery switch: the key is the one the settings page writes", DiscoveryPreference.key == "autoDiscoverNewHosts")
  d.removePersistentDomain(forName: "net-quiet-test-discovery")
}

// --- LaunchGate
do {
  let g = LaunchGate(expiry: 90)
  check("gate: the first click launches", g.claim("h", now: at(0)))
  var absorbed = 0
  for i in 1...6 where !g.claim("h", now: at(Double(i))) { absorbed += 1 }
  check("gate: six more clicks are absorbed", absorbed == 6)
  check("gate: another computer is independent", g.claim("h2", now: at(3)))
  check("gate: pending shows", g.isPending("h", now: at(8)))
  g.release("h")
  check("gate: released, the next click launches", !g.isPending("h", now: at(9)) && g.claim("h", now: at(9)))
  check("gate: a launch that never reported is forgotten", g.claim("h", now: at(9 + 91)))
}

// --- the 17:21 click storm: 7 clicks inside the 10 s the first serverinfo hung => one window
do {
  let g = LaunchGate()
  var windows = 0
  for i in 0..<7 where g.claim("0A11F00D", now: at(Double(i) * 1.4)) { windows += 1 }
  check("storm: seven clicks in ten seconds open one window", windows == 1)
}

// --- a poster download that was stopped starts again a few seconds after the last launch / stream ended
do {
  var resumed = 0
  let lock = NSLock()
  NetworkQuiet.onIdle("test") { lock.lock(); resumed += 1; lock.unlock() }
  NetworkQuiet.beginStream("win1")
  NetworkQuiet.end("win1")
  Thread.sleep(forTimeInterval: NetworkQuiet.idleSettle - 1)
  lock.lock(); check("idle: not before the settle time", resumed == 0); lock.unlock()
  Thread.sleep(forTimeInterval: 2)
  lock.lock(); check("idle: once after the settle time", resumed == 1); lock.unlock()
  // a new stream inside the settle time cancels it
  NetworkQuiet.beginStream("win2")
  NetworkQuiet.end("win2")
  Thread.sleep(forTimeInterval: 1)
  NetworkQuiet.begin("launch")
  Thread.sleep(forTimeInterval: NetworkQuiet.idleSettle)
  lock.lock(); check("idle: not while a launch is pending", resumed == 1); lock.unlock()
  NetworkQuiet.end("launch")
  Thread.sleep(forTimeInterval: NetworkQuiet.idleSettle + 1)
  lock.lock(); check("idle: after the launch ended, once more", resumed >= 2); lock.unlock()
}

if failures > 0 { print("\(failures) failed"); exit(1) }
print("all passed")
