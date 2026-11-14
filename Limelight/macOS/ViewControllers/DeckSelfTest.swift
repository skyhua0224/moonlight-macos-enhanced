//
//  DeckSelfTest.swift
//  Harness only (compiled with MLC_CONCEPT_HARNESS). Checks the Foundation Sunshine fallback against a REAL
//  /serverinfo taken from a 2026.1110.165906 host (it sends VddCapabilityVersion and SunshineVersion but not
//  the Fs* fields or FsKind): MLC_SELFTEST=<path to that xml>.
//

#if MLC_CONCEPT_HARNESS
import AppKit

@available(macOS 14.0, *)
@objc(MLDeckSelfTest)
public final class DeckSelfTest: NSObject {
  private static var failures = 0

  private static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if !ok { failures += 1 }
    fputs("SELFTEST \(ok ? "PASS" : "FAIL") \(name)\(ok ? "" : " — " + detail())\n", stderr)
  }

  private static func app(_ id: String, _ name: String, host: TemporaryHost, extras: [String: String] = [:]) -> TemporaryApp {
    let a = TemporaryApp()
    a.id = id
    a.name = name
    a.host = host
    a.fsExtras = extras
    return a
  }

  @objc public static func run(xmlPath: String) -> Bool {
    failures = 0
    guard let data = FileManager.default.contents(atPath: xmlPath) else {
      fputs("SELFTEST FAIL cannot read \(xmlPath)\n", stderr)
      return false
    }
    // 1. the real serverinfo through the real parser
    let response = ServerInfoResponse()
    response.populate(with: data)
    let host = TemporaryHost()
    response.populateHost(host)
    check("serverinfo parsed (uuid)", !host.uuid.isEmpty, host.uuid)
    let facts = DeckFactsStore.facts(for: host.uuid)
    check("VddCapabilityVersion read", facts.vddVersion == 1, "\(facts.vddVersion)")
    check("SunshineVersion read", facts.sunshineVersion.contains("2026.1110.165906"), facts.sunshineVersion)
    check("no Fs* fields on this build", facts.fsVersion == 0, "\(facts.fsVersion)")
    DeckFactsStore.invalidateFoundationCache()
    check("DeckFactsStore.isFoundation", DeckFactsStore.isFoundation(host.uuid))
    check("all-zero MAC is not a MAC", !DeckHost.isValidMAC(host.mac), host.mac ?? "nil")
    check("a real MAC is", DeckHost.isValidMAC("00:00:5e:00:53:03"))

    // 2. its app list (names as a 165906 host ships them; no FsKind)
    let desktop = app("1", "Desktop", host: host)
    let big = app("2", "大屏", host: host)
    let steam = app("3", "Steam Big Picture", host: host)
    let game = app("4", "Slay the Spire 2", host: host)
    host.appList = Set<AnyHashable>([desktop, big, steam, game])
    check("kind of 大屏 = bigscreen", big.deckInfo.kind == "bigscreen", big.deckInfo.kind ?? "nil")
    check("kind of Desktop = desktop", desktop.deckInfo.kind == "desktop", desktop.deckInfo.kind ?? "nil")
    check("Steam Big Picture is not either", steam.deckInfo.kind == nil, steam.deckInfo.kind ?? "nil")
    check("deckIsBigScreen(大屏)", deckIsBigScreen(big))
    check("deckIsDesktopLike(Desktop)", deckIsDesktopLike(desktop))
    let english = app("5", "Big Screen", host: host)
    check("English name too", english.deckInfo.kind == "bigscreen")

    // 3. the page's lists and the connect menu
    let deckHost = DeckHost(host)
    check("DeckHost.isFoundation", deckHost.isFoundation)
    let model = DeckAppsModel(style: .computer, actions: DeckAppsActions())
    model.host = deckHost
    model.apps = [desktop, big, steam, game]
    let library = model.libraryApps.map { $0.name ?? "" }
    check("应用 omits 大屏 and Desktop", library == ["Slay the Spire 2", "Steam Big Picture"], "\(library)")
    check("最近使用 omits them", !model.recentApps.contains { $0.id == "1" || $0.id == "2" })
    check("固定 omits them", !model.pinnedApps.contains { $0.id == "1" || $0.id == "2" })
    let modes = DeckConnect.modes(deckHost, model).map { $0.rawValue }
    check("menu offers 桌面 + 大屏模式 + 虚拟显示器", modes == ["desktop", "bigscreen", "vdd"], "\(modes)")
    check("primary label", DeckConnect.label(DeckConnect.effective(deckHost, model), host: deckHost, model: model) == DL("deck.connectDesktop"))

    // 4. FsKind, when sent, always wins over the name
    let fsGame = app("6", "Desktop", host: host, extras: ["FsKind": "game"])
    check("FsKind wins over the name", fsGame.deckInfo.kind == "game" && !deckIsDesktopLike(fsGame))

    // 5. a plain Sunshine (no VddCapabilityVersion): nothing is hidden or offered
    let plain = TemporaryHost()
    plain.uuid = "PLAIN-SELFTEST"
    plain.name = "Plain"
    DeckFactsStore.invalidateFoundationCache()
    let pDesktop = app("1", "Desktop", host: plain)
    let pBig = app("2", "大屏", host: plain)
    plain.appList = Set<AnyHashable>([pDesktop, pBig])
    check("plain host: no kind guessed", pBig.deckInfo.kind == nil && pDesktop.deckInfo.kind == nil)
    let pm = DeckAppsModel(style: .computer, actions: DeckAppsActions())
    pm.host = DeckHost(plain)
    pm.apps = [pDesktop, pBig]
    check("plain host keeps both in 应用", pm.libraryApps.count == 2, "\(pm.libraryApps.count)")
    check("plain host: only 桌面", DeckConnect.modes(pm.host!, pm).map { $0.rawValue } == ["desktop"])
    fputs("SELFTEST \(failures == 0 ? "ALL PASS" : "\(failures) FAILED")\n", stderr)
    return failures == 0
  }
}

// MARK: - Host capability 2 / capability 1

/// MLC_SELFTEST_CAP=<host-cap2-serverinfo.xml>,<host-cap1-serverinfo.xml>,<host-cap2-applist.xml>: the real parsers and the
/// real facts store against a capability 2 host (events long-poll, FsEventSeq, FsSessionStarted, FsHostAvatarVersion, per-app
/// FsSession and FsLaunchMode) and a capability 1 host (none of it). tests/host-events has the same fixtures for the pure rules.
@available(macOS 14.0, *)
extension DeckSelfTest {
  @objc public static func runCapability(spec: String) -> Bool {
    failures = 0
    let paths = spec.split(separator: ",").map(String.init)
    guard paths.count == 3,
          let data2 = FileManager.default.contents(atPath: paths[0]),
          let data1 = FileManager.default.contents(atPath: paths[1]),
          let apps2 = FileManager.default.contents(atPath: paths[2]) else {
      fputs("SELFTEST FAIL bad MLC_SELFTEST_CAP spec \(spec)\n", stderr)
      return false
    }
    // capability 2 host
    let r2 = ServerInfoResponse()
    r2.populate(with: data2)
    let h2 = TemporaryHost()
    r2.populateHost(h2)
    let f2 = DeckFactsStore.facts(for: h2.uuid)
    DeckFactsStore.invalidateFoundationCache()
    check("cap2: FsCapabilityVersion 2 read", f2.fsVersion == 2, "\(f2.fsVersion)")
    check("cap2: Foundation by capability", DeckFactsStore.isFoundation(h2.uuid))
    check("cap2: the cap 2 tags come through the real parser",
          r2.getStringTag("FsEventSeq") == "7" && r2.getStringTag("FsSessionStarted") == "1794400000" &&
          r2.getStringTag("FsHostAvatarVersion") == "3" && (r2.getStringTag("FsFeatures") ?? "").contains("events"))
    check("cap2: the events long-poll is on", HostEventsRules.eventsEnabled(capability: r2.getStringTag("FsCapabilityVersion"), features: r2.getStringTag("FsFeatures")))
    let d2 = DeckHost(h2)
    check("cap2: not told to update", d2.fsUpdateReason(kindSeen: true) == nil && d2.fsUpdateReason(kindSeen: nil) == nil)
    check("cap2: label shows three parts, hover the whole string",
          DeckFs.softwareText(d2) == DeckHostSoftware.title(d2.software, names: DeckFs.names()) &&
          DeckFs.softwareText(d2).hasSuffix("2026.1112.025657") && DeckFs.softwareDetail(d2).hasSuffix("2026.1112.025657.杂鱼"),
          "\(DeckFs.softwareText(d2)) | \(DeckFs.softwareDetail(d2))")
    check("cap2: update token is the short version", d2.fsUpdateToken() == "2026.1112.025657", d2.fsUpdateToken())
    // its app list: FsSession (running since), FsLaunchMode, FsKind
    let list = AppListResponse()
    list.populate(with: apps2)
    let apps = (list.getAppList() as? Set<TemporaryApp> ?? []).sorted { ($0.id ?? "") < ($1.id ?? "") }
    for a in apps { a.host = h2 }
    check("cap2: two apps read", apps.count == 2, "\(apps.count)")
    if apps.count == 2 {
      let desktop = apps[0], game = apps[1]
      check("cap2: FsLaunchMode read per app", desktop.deckInfo.launch == "direct" && game.deckInfo.launch == "launcher", "\(String(describing: desktop.deckInfo.launch)) \(String(describing: game.deckInfo.launch))")
      check("cap2: FsSession is the session start of the running app", game.deckInfo.sessionStart != nil && desktop.deckInfo.sessionStart == nil)
      check("cap2: FsKind wins", desktop.deckInfo.kind == "desktop" && game.deckInfo.kind == "game")
    }
    // capability 1 host
    let r1 = ServerInfoResponse()
    r1.populate(with: data1)
    let h1 = TemporaryHost()
    r1.populateHost(h1)
    let f1 = DeckFactsStore.facts(for: h1.uuid)
    DeckFactsStore.invalidateFoundationCache()
    check("cap1: FsCapabilityVersion 1 read", f1.fsVersion == 1, "\(f1.fsVersion)")
    check("cap1: none of the cap 2 tags", r1.getStringTag("FsEventSeq") == nil && r1.getStringTag("FsSessionStarted") == nil && r1.getStringTag("FsHostAvatarVersion") == nil)
    check("cap1: the events long-poll stays off", !HostEventsRules.eventsEnabled(capability: r1.getStringTag("FsCapabilityVersion"), features: r1.getStringTag("FsFeatures")))
    let d1 = DeckHost(h1)
    check("cap1: Foundation, current, label with three parts",
          DeckFactsStore.isFoundation(h1.uuid) && d1.fsUpdateReason(kindSeen: true) == nil && DeckFs.softwareText(d1).hasSuffix("2026.1111.001644"), DeckFs.softwareText(d1))
    check("cap1: quiet refresh interval", HostEventsRules.refreshInterval(eventsEnabled: false) == 30)
    fputs("SELFTEST-CAP \(failures == 0 ? "ALL PASS" : "\(failures) FAILED")\n", stderr)
    return failures == 0
  }
}

// MARK: - Lock stress (regression test of the DeckFactsStore deadlock)

/// MLC_FACTSSTRESS=<serverinfo.xml>,<seconds>. Several threads do what discovery does (read a /serverinfo answer into a
/// host, which ingests the Fs* fields into DeckFactsStore) while the main thread does what the apps page does (setIcon,
/// recordConnected, facts reads), with an NSUserDefaultsDidChangeNotification observer on the main queue like
/// StreamViewController's. A watchdog asks the main queue every 100 ms; it answering later than 1 s is a failure.
@available(macOS 14.0, *)
extension DeckSelfTest {
  private final class Counter {
    private let lock = NSLock()
    private var value = 0
    func add() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    private var maxValue = 0.0
    func note(_ x: Double) { lock.lock(); maxValue = Swift.max(maxValue, x); lock.unlock() }
    var peak: Double { lock.lock(); defer { lock.unlock() }; return maxValue }
  }

  @objc public static func stress(spec: String) {
    let parts = spec.split(separator: ",").map(String.init)
    guard parts.count >= 2, let data = FileManager.default.contents(atPath: parts[0]), let seconds = Double(parts[1]) else {
      fputs("FACTSSTRESS FAIL bad spec \(spec)\n", stderr); exit(3)
    }
    // optional third field: the number of discovery-like threads (8 by default; fewer on a sanitizer build, whose
    // slowed main thread otherwise misses the 1 s mark by rendering alone, with no lock involved)
    let threads = parts.count > 2 ? (Int(parts[2]) ?? 8) : 8
    let start = Date(), stop = start.addingTimeInterval(seconds)
    let ingests = Counter(), mainTicks = Counter(), observed = Counter(), pings = Counter(), slow = Counter()
    let observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in observed.add() }

    let workers = OperationQueue()
    workers.maxConcurrentOperationCount = threads
    for _ in 0..<threads {
      workers.addOperation {
        while Date() < stop {
          let response = ServerInfoResponse()
          response.populate(with: data)
          let host = TemporaryHost()
          response.populateHost(host)   // DeckActivity.ingestServerInfo on this thread, like DiscoveryWorker
          ingests.add()
          Thread.sleep(forTimeInterval: 0.001)   // ~1000 per second per thread: orders of magnitude above real discovery, yet not a CPU starvation test
        }
      }
    }
    // what the apps page does on the main thread
    let timer = Timer(timeInterval: 0.002, repeats: true) { _ in
      DeckFactsStore.setIcon(uuid: "stress-main", symbol: "desktopcomputer", color: "blue")
      DeckActivity.recordConnected(hostUUID: "stress-main", appId: "1", appName: "App")
      _ = DeckFactsStore.facts(for: "stress-main")
      _ = DeckFactsStore.isFoundation("stress-main")
      mainTicks.add()
    }
    RunLoop.main.add(timer, forMode: .common)

    // watchdog (not on the main thread)
    let watchdog = Thread {
      while Date() < stop {
        let asked = Date()
        let answered = DispatchSemaphore(value: 0)
        DispatchQueue.main.async { answered.signal() }
        if answered.wait(timeout: .now() + 1.0) == .timedOut {
          // over 1 s: counted. A busy main thread (SwiftUI layout, a sanitizer's slowdown) answers a little later; a deadlock never
          // does, so the test fails only when the main queue has not answered 5 s after the question
          slow.add()
          if answered.wait(timeout: .now() + 4.0) == .timedOut {
            fputs("FACTSSTRESS FAIL main thread did not answer for 5 s at t=\(Int(Date().timeIntervalSince(start))) s (ingests=\(ingests.count) mainTicks=\(mainTicks.count) slowOver1s=\(slow.count))\n", stderr)
            // MLC_FACTSSTRESS_HOLD: stay hung for that many seconds so `sample` can be taken
            if let hold = ProcessInfo.processInfo.environment["MLC_FACTSSTRESS_HOLD"].flatMap(Double.init) { Thread.sleep(forTimeInterval: hold) }
            exit(1)
          }
        }
        pings.note(Date().timeIntervalSince(asked) * 1000)
        pings.add()
        Thread.sleep(forTimeInterval: 0.1)
      }
    }
    watchdog.start()
    func finish() {
      // never wait for the workers here: one of them may be posting a notification that only this thread can answer
      if workers.operationCount > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { finish() }; return }
      timer.invalidate()
      NotificationCenter.default.removeObserver(observer)
      DeckFactsStore.flush()
      let ok = ingests.count > 100 && mainTicks.count > 100
      fputs("FACTSSTRESS \(ok ? "PASS" : "FAIL few iterations") seconds=\(Int(seconds)) ingests=\(ingests.count) mainTicks=\(mainTicks.count) defaultsObserverCalls=\(observed.count) watchdogPings=\(pings.count) answeredLaterThan1s=\(slow.count) maxMainLatencyMs=\(String(format: "%.1f", pings.peak))\n", stderr)
      exit(ok ? 0 : 1)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 0.5) { finish() }
  }
}
#endif
