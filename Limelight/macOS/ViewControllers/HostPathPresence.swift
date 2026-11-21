import Foundation
import Network
import AppKit
import SystemConfiguration

/// Event-driven presence for the connect menu.
///
/// NWBrowser (Network.framework, macOS 10.15+) browses _nvstream._tcp and wakes probes when the
/// result set or its TXT metadata changes. NWPathMonitor wakes them when the default route changes.
/// Neither call waits on the network from the menu: sections(for:) reads the last probe only.
/// Tailscale's own status command, when it is installed, says whether a 100.64.0.0/10 peer is on a
/// DERP relay; otherwise HostPathRank infers that from the route and the smoothed RTT.
/// The status binary is only ever run as a CLI: a standalone tailscale is preferred, and the executable in
/// the Tailscale app bundle runs with TAILSCALE_BE_CLI=1 (Tailscale CLI reference,
/// tailscale.com/docs/reference/tailscale-cli, retrieved 2026-11-21: without that variable the bundled
/// executable opens the macOS app instead of answering). Probes are coalesced to one at a time, back off
/// 30 s to 10 min after failures, and run only while the app is frontmost unless a connect needs the status.
///
/// Sources: Apple Developer Documentation, NWBrowser, macOS 10.15+ (retrieved 2026-11-10);
/// NWPathMonitor; NSWorkspace.didWakeNotification (register on NSWorkspace.notificationCenter);
/// NSApplication.didBecomeActiveNotification. RFC 8305 sections 4, 5 and 8 (retrieved 2026-11-10):
/// the recommended connection-attempt delay is 250 ms and the recommended minimum is 100 ms, with a
/// 10 ms floor. Presence uses 50 ms because the paths are already resolved and the host must show
/// online within 300 ms. RFC 6598 (100.64.0.0/10).

private struct HostPathRecord {
  var address: String
  var reachable: Bool
  var rttMs: Int
  var jitterMs: Int
  var iface: Int
  var relayed: Bool
  var klass: Int
  /// IPv4 of the egress interface when it is a tunnel, else ""
  var egressSource: String = ""
}

@objc(MLHostPathSignals)
public final class HostPathSignals: NSObject {
  @objc public static let shared = HostPathSignals()

  private let lock = NSLock()
  private var wakeCount = 0
  private var relays: [String: Bool] = [:]
  private var records: [String: [HostPathRecord]] = [:]
  private var browser: NWBrowser?
  private var monitor: NWPathMonitor?
  private var started = false
  private var tailscaleAt = Date.distantPast
  private let queue = DispatchQueue(label: "host-path-presence")
  private var appActive = false
  private var tailscaleProbeQueued = false
  private var tailscaleProbeForced = false
  private let probeGate = TailscaleProbeGate()
  // All probeGate and probeToken access happens on queue; tailscaleAt, relays and appActive go through lock.
  private var probeToken = 0
  private var probeSettled = false
  private var forceRetryPending = false

  private override init() { super.init() }

  @objc public func start() {
    lock.lock()
    let already = started
    if !already { started = true }
    lock.unlock()
    guard !already else { return }
    // The 线路 list is classified by DeckAddressModel (one list for 地址 and 线路, the platform's path vocabulary);
    // this layer only supplies the probe facts (probeFact), so it registers no section of its own any more.
    let parameters = NWParameters.tcp
    parameters.includePeerToPeer = true
    let browser = NWBrowser(for: .bonjour(type: "_nvstream._tcp", domain: nil), using: parameters)
    browser.browseResultsChangedHandler = { [weak self] _, _ in
      self?.bump()
    }
    browser.stateUpdateHandler = { _ in }
    browser.start(queue: queue)
    let monitor = NWPathMonitor()
    monitor.pathUpdateHandler = { [weak self] _ in
      self?.bump()
    }
    monitor.start(queue: queue)
    lock.lock()
    self.browser = browser
    self.monitor = monitor
    lock.unlock()
    let workspace = NSWorkspace.shared.notificationCenter
    workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
      self?.bump()
    }
    // The Tailscale status is only queried while the app is frontmost (or when a connect needs it, see
    // noteConnectNeeded): a probe from the background is what kept bringing the Tailscale app forward.
    NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
      guard let self else { return }
      self.lock.lock()
      self.appActive = true
      self.lock.unlock()
      self.bump()
      self.enqueueTailscaleRefresh(force: false)
    }
    NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: nil) { [weak self] _ in
      guard let self else { return }
      self.lock.lock()
      self.appActive = false
      self.lock.unlock()
    }
    NotificationCenter.default.addObserver(forName: Notification.Name("MoonlightTailscaleDetectionChanged"), object: nil, queue: nil) { [weak self] _ in
      self?.tailscaleDetectionChanged()
    }
    // Seed the activity flag from the real state (start() can run before or after the app is
    // frontmost); NSApp is only touched on the main thread. The observers keep the flag current.
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.lock.lock()
      self.appActive = NSApp.isActive
      self.lock.unlock()
      self.enqueueTailscaleRefresh(force: false)
    }
  }

  /// Wake, focus, and opening a host page ask for a probe now. Backoff stays in the worker.
  @objc public func noteAttention() {
    start()
    bump()
    enqueueTailscaleRefresh(force: false)
  }

  /// A connect is about to rank the addresses of a host: the status query may run now even when the app is
  /// not frontmost. Still one probe at a time, still CLI-only, still subject to the fresh cache.
  @objc public func noteConnectNeeded() {
    start()
    enqueueTailscaleRefresh(force: true)
  }

  @objc public func generation() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return wakeCount
  }

  /// -1 unknown, 0 direct, 1 relayed. Never blocks.
  @objc(relayHintForAddress:)
  public func relayHint(for address: String) -> Int {
    let key = HostPathSignals.hostPart(address)
    lock.lock()
    let stale = Date().timeIntervalSince(tailscaleAt) > 60
    let known = relays[key]
    lock.unlock()
    if stale {
      enqueueTailscaleRefresh(force: false)
    }
    if let known { return known ? 1 : 0 }
    return -1
  }

  @objc(recordProbeForHost:address:reachable:rttMs:jitterMs:iface:relayed:klass:egressSource:)
  public func recordProbe(uuid: String, address: String, reachable: Bool, rttMs: Int, jitterMs: Int,
                          iface: Int, relayed: Bool, klass: Int, egressSource: String) {
    guard !uuid.isEmpty, !address.isEmpty else { return }
    let record = HostPathRecord(address: address, reachable: reachable, rttMs: rttMs, jitterMs: jitterMs,
                                iface: iface, relayed: relayed, klass: klass, egressSource: egressSource)
    lock.lock()
    var list = records[uuid] ?? []
    if let index = list.firstIndex(where: { $0.address == address }) {
      list[index] = record
    } else {
      list.append(record)
    }
    records[uuid] = list
    lock.unlock()
    DispatchQueue.main.async {
      NotificationCenter.default.post(name: DeckConnectMenuRegistry.didChange, object: nil)
    }
  }

  @objc(phraseForHost:active:)
  public func phrase(forHost uuid: String, active: String) -> String {
    guard let record = snapshot(uuid: uuid, active: active) else { return "" }
    return HostPathSignals.phrase(record, markRelay: true)
  }

  @objc(overlayLineForHost:active:)
  public func overlayLine(forHost uuid: String, active: String) -> String {
    guard let record = snapshot(uuid: uuid, active: active) else { return "" }
    var text = HostPathSignals.phrase(record, markRelay: true)
    if record.reachable, record.rttMs >= 0 {
      text += " · \(record.rttMs) ms"
    }
    return text
  }

  /// What the last probe of this address saw: the egress interface (0 unknown, 1 physical, 2 tunnel, 3 loopback), whether the
  /// route is relayed, the smoothed RTT. The classification of the path (DeckPathClassifier) takes these as evidence.
  struct ProbeFact { let iface: Int; let relayed: Bool; let rttMs: Int; let reachable: Bool; let egressSource: String }

  func probeFact(uuid: String, address: String) -> ProbeFact? {
    guard let wanted = DeckEndpoint.parse(address) else { return nil }
    let record = menuRecords(uuid: uuid).first { DeckEndpoint.parse($0.address) == wanted }
    guard let record else { return nil }
    return ProbeFact(iface: record.iface, relayed: record.relayed, rttMs: record.rttMs, reachable: record.reachable, egressSource: record.egressSource)
  }

  fileprivate func menuRecords(uuid: String) -> [HostPathRecord] {
    lock.lock()
    defer { lock.unlock() }
    return records[uuid] ?? []
  }

  /// How many paths the connect menu would show. The address menu hides itself at 2 or more
  /// so the page does not list 线路 twice.
  func measuredRouteCount(uuid: String, active: String) -> Int {
    menuRecords(uuid: uuid).filter { $0.reachable || $0.address == active }.count
  }

  private func snapshot(uuid: String, active: String) -> HostPathRecord? {
    lock.lock()
    defer { lock.unlock() }
    let list = records[uuid] ?? []
    if let exact = list.first(where: { $0.address == active }) { return exact }
    return list.first(where: { $0.reachable }) ?? list.first
  }

  private func bump() {
    lock.lock()
    wakeCount += 1
    lock.unlock()
  }

  /// Many callers can ask for a refresh in one burst (a probe pass asks per address); they collapse into
  /// one queued request, and a forced request upgrades the pending one.
  private func enqueueTailscaleRefresh(force: Bool) {
    lock.lock()
    let needQueue = !tailscaleProbeQueued
    tailscaleProbeQueued = true
    tailscaleProbeForced = tailscaleProbeForced || force
    lock.unlock()
    guard needQueue else { return }
    queue.async { [weak self] in
      guard let self else { return }
      self.lock.lock()
      self.tailscaleProbeQueued = false
      let force = self.tailscaleProbeForced
      self.tailscaleProbeForced = false
      self.lock.unlock()
      self.runTailscaleProbe(force: force)
    }
  }

  private func runTailscaleProbe(force: Bool) {
    guard TailscaleDetection.isEnabled(defaults: .standard) else { return }
    lock.lock()
    let active = appActive
    let last = tailscaleAt
    lock.unlock()
    // Re-check the cache before running: the requests that piled up behind the first one find it fresh.
    if Date().timeIntervalSince(last) <= TailscaleProbePolicy.freshInterval { return }
    if !force, !active { return }
    guard probeGate.begin(now: Date(), force: force) else {
      // A forced request that arrived while a probe was running is retried the moment that one ends.
      if force { forceRetryPending = true }
      return
    }
    probeSettled = false
    probeToken += 1
    let token = probeToken
    let environment = ProcessInfo.processInfo.environment
    guard let cli = TailscaleCLI.select(environment: environment, isExecutable: { FileManager.default.isExecutableFile(atPath: $0) }) else {
      // Nothing to query: not a failure, just nothing new to learn until the cache goes stale again.
      finishTailscaleProbe(token: token, relays: nil, success: true)
      return
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: cli.path)
    process.arguments = TailscaleCLI.statusArguments
    process.environment = TailscaleCLI.environment(for: cli, base: environment)
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do {
      try process.run()
    } catch {
      finishTailscaleProbe(token: token, relays: nil, success: false)
      return
    }
    process.terminationHandler = { [weak self] _ in
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      let parsed = HostPathSignals.parseTailscaleRelays(data)
      self?.queue.async { self?.finishTailscaleProbe(token: token, relays: parsed, success: parsed != nil) }
    }
    // The probe slot stays held until the process has really exited: SIGTERM at the answer deadline,
    // SIGKILL one grace later, and only a lost exit event may settle the attempt without observing
    // the exit. Every wait is scheduled, never blocking the serial queue.
    let schedule = TailscaleProbeTimeout.schedule(startedAt: Date())
    let termDelay = max(0, schedule.terminateAt.timeIntervalSinceNow)
    let killDelay = schedule.killAt.timeIntervalSince(schedule.terminateAt)
    let lastDelay = schedule.lastResortAt.timeIntervalSince(schedule.killAt)
    queue.asyncAfter(deadline: .now() + termDelay) { [weak self, weak process] in
      guard let self, let process, process.isRunning else { return }
      process.terminate()
      self.queue.asyncAfter(deadline: .now() + killDelay) { [weak self, weak process] in
        guard let self, let process, process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
        self.queue.asyncAfter(deadline: .now() + lastDelay) { [weak self] in
          // Reached only when the exit event itself was lost; the exit handler settles normally.
          self?.finishTailscaleProbe(token: token, relays: nil, success: false)
        }
      }
    }
  }

  private func finishTailscaleProbe(token: Int, relays: [String: Bool]?, success: Bool) {
    // One completion per attempt: whichever of the exit handler and the last resort arrives first
    // settles the probe; the other is dropped.
    guard token == probeToken, !probeSettled else { return }
    probeSettled = true
    let outcome = TailscaleProbeOutcome(succeeded: success, detectionEnabled: TailscaleDetection.isEnabled(defaults: .standard))
    probeGate.end(success: outcome.countsAsSuccess, now: Date())
    lock.lock()
    if outcome.publishesAnswer {
      if let relays { self.relays = relays }
      tailscaleAt = Date()
    }
    lock.unlock()
    if forceRetryPending {
      forceRetryPending = false
      enqueueTailscaleRefresh(force: true)
    }
  }

  private func tailscaleDetectionChanged() {
    if TailscaleDetection.isEnabled(defaults: .standard) {
      lock.lock()
      tailscaleAt = .distantPast
      lock.unlock()
      enqueueTailscaleRefresh(force: false)
    } else {
      // Off means no query at all; manually saved Tailscale addresses keep connecting as usual.
      lock.lock()
      relays = [:]
      tailscaleAt = Date()
      lock.unlock()
    }
  }

  private static func parseTailscaleRelays(_ data: Data) -> [String: Bool]? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let peers = object["Peer"] as? [String: [String: Any]] else { return nil }
    var next: [String: Bool] = [:]
    for peer in peers.values {
      let relay = (peer["Relay"] as? String) ?? ""
      let ips = (peer["TailscaleIPs"] as? [String]) ?? []
      for ip in ips {
        next[ip] = !relay.isEmpty
      }
    }
    return next
  }

  static func hostPart(_ address: String) -> String {
    var text = address.trimmingCharacters(in: .whitespaces)
    if text.hasPrefix("["), let end = text.firstIndex(of: "]") {
      text = String(text[text.index(after: text.startIndex)..<end])
    } else {
      let pieces = text.split(separator: ":", omittingEmptySubsequences: false)
      if pieces.count == 2, pieces[1].allSatisfy({ $0.isNumber }) {
        text = String(pieces[0])
      }
    }
    if let zone = text.firstIndex(of: "%") { text = String(text[..<zone]) }
    while text.hasSuffix(".") { text.removeLast() }
    return text
  }
  fileprivate static func phrase(_ record: HostPathRecord, markRelay: Bool) -> String {
    let host = hostPart(record.address)
    let shown = host.count > 42 ? String(host.prefix(39)) + "…" : host
    let title: String
    if record.iface == 2, DeckPathClassifier.addressClass(host) == .publicAddress, DeckNic.isFakeIP(record.egressSource) {
      title = DL("deck.path.proxy")
    } else if host.hasPrefix("169.254.") || host.lowercased().hasPrefix("fe80:") {
      title = DL("deck.route.link")
    } else if record.klass == 2, isTailscale(host) {
      title = DL("deck.route.tailscale")
    } else {
      switch record.klass {
      case 0: title = DL("deck.lan")
      case 1: title = DL("deck.route.public")
      case 2: title = DL("deck.route.tunnel")
      case 3: title = isTailscale(host) ? DL("deck.route.tailscale") : DL("deck.route.tunnel")
      default: title = shown
      }
    }
    var text = title
    if title != shown && !shown.isEmpty { text += " " + shown }
    if markRelay && (record.relayed || record.klass == 3) { text += "（" + DL("deck.route.relay") + "）" }
    return text
  }

  static func isTailscale(_ host: String) -> Bool {
    let parts = host.split(separator: ".")
    if parts.count == 4, let a = Int(parts[0]), let b = Int(parts[1]), a == 100, (64...127).contains(b) {
      return true
    }
    return host.lowercased().hasPrefix("fd7a:115c:a1e0:")
  }
}

final class DeckRouteMenuProvider: DeckConnectMenuSectionProvider {
  static let shared = DeckRouteMenuProvider()
  let order = 100

  func sections(for host: DeckHost) -> [DeckConnectMenuSection] {
    if conceptEnv("MLC_FAKE_ROUTES") != nil { return [] }
    let records = HostPathSignals.shared.menuRecords(uuid: host.id).filter { $0.reachable || $0.address == host.address }
    if records.count < 2 { return [] }
    let settings = SettingsClass.getSettings(for: host.id)
    let method = (settings?["connectionMethod"] as? String) ?? "Auto"
    let automatic = method.isEmpty || method == "Auto"
    var items: [DeckConnectMenuItem] = [
      DeckConnectMenuItem(id: "route.auto", title: DL("deck.route.auto"), selected: automatic) {
        SettingsClass.setConnectionMethod("Auto", for: host.id)
        NotificationCenter.default.post(name: DeckConnectMenuRegistry.didChange, object: nil)
      },
    ]
    let ordered = records.sorted { lhs, rhs in
      if lhs.klass != rhs.klass { return lhs.klass < rhs.klass }
      return lhs.rttMs < rhs.rttMs
    }
    for record in ordered {
      let selected = !automatic && method == record.address
      let trailing = record.reachable && record.rttMs >= 0 ? "\(record.rttMs) ms" : nil
      let badge = (record.relayed || record.klass == 3) ? DL("deck.route.relay") : nil
      let address = record.address
      items.append(DeckConnectMenuItem(id: "route." + address, title: HostPathSignals.phrase(record, markRelay: false),
                                       trailing: trailing, badge: badge, selected: selected) {
        SettingsClass.setConnectionMethod(address, for: host.id)
        host.raw.activeAddress = address
        NotificationCenter.default.post(name: DeckConnectMenuRegistry.didChange, object: nil)
      })
    }
    return [DeckConnectMenuSection(id: "route", title: DL("deck.fact.route"), items: items)]
  }
}

// MARK: - 网卡

/// The machine's interfaces as the 网卡 choice lists them (rules in DeckNic). Wi-Fi is told from Ethernet by SystemConfiguration,
/// not by the name: on a Mac with no Wi-Fi hardware en0 is Ethernet.
enum HostNics {
  static func current() -> [DeckNic.Interface] {
    var wifi = Set<String>()
    if let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
      for item in all {
        if let type = SCNetworkInterfaceGetInterfaceType(item), type as String == kSCNetworkInterfaceTypeIEEE80211 as String,
           let name = SCNetworkInterfaceGetBSDName(item) {
          wifi.insert(name as String)
        }
      }
    }
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let first = head else { return [] }
    defer { freeifaddrs(head) }
    var ipv4: [String: String] = [:]
    var flags: [String: UInt32] = [:]
    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    while let entry = cursor {
      let name = String(cString: entry.pointee.ifa_name)
      flags[name] = entry.pointee.ifa_flags
      if let address = entry.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET) {
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
          var sin = pointer.pointee.sin_addr
          inet_ntop(AF_INET, &sin, &buffer, socklen_t(INET_ADDRSTRLEN))
        }
        if ipv4[name] == nil { ipv4[name] = String(cString: buffer) }
      }
      cursor = entry.pointee.ifa_next
    }
    let raw = flags.map { name, value in
      DeckNic.Raw(name: name, index: if_nametoindex(name), up: value & UInt32(IFF_UP) != 0, running: value & UInt32(IFF_RUNNING) != 0,
                  ipv4: ipv4[name], isWifi: wifi.contains(name))
    }
    return DeckNic.interfaces(raw)
  }

  static func kindWord(_ kind: DeckNic.Kind) -> String {
    switch kind {
    case .wifi: return DL("deck.nic.wifi")
    case .ethernet: return DL("deck.nic.ethernet")
    case .tunnel: return DL("deck.nic.tunnel")
    }
  }

  static func label(_ interface: DeckNic.Interface) -> String { DeckNic.label(interface, kindWord: kindWord(interface.kind)) }

  static func symbol(_ kind: DeckNic.Kind) -> String {
    switch kind {
    case .wifi: return "wifi"
    case .ethernet: return "cable.connector.horizontal"
    case .tunnel: return "lock.shield"
    }
  }
}

/// The 网卡 section of a computer: 自动 and one item per interface; the choice is saved for that computer only. The interface the
/// stream is pinned to has to exist when it starts; when it is gone the item stays chosen and reads 不可用, and the stream says so.
final class DeckNicMenuProvider: DeckConnectMenuSectionProvider {
  static let shared = DeckNicMenuProvider()
  let order = 60

  func sections(for host: DeckHost) -> [DeckConnectMenuSection] {
    guard host.paired else { return [] }
    let list = HostNics.current()
    let choice = DeckNic.choice(saved: ConnectionEndpointStore.networkInterface(forHost: host.id), in: list)
    func set(_ name: String?) -> () -> Void {
      return {
        ConnectionEndpointStore.setNetworkInterface(name, forHost: host.id)
        NotificationCenter.default.post(name: DeckConnectMenuRegistry.didChange, object: nil)
      }
    }
    var automatic = false
    if case .automatic = choice { automatic = true }
    var auto = DeckConnectMenuItem(id: "nic.auto", title: DL("deck.auto"), symbol: "arrow.triangle.branch", selected: automatic, action: set(nil))
    auto.tooltip = DL("deck.nic.auto")
    var items = [auto]
    for interface in list {
      var selected = false
      if case .interface(let hit) = choice, hit == interface { selected = true }
      var item = DeckConnectMenuItem(id: "nic." + interface.name, title: HostNics.label(interface), symbol: HostNics.symbol(interface.kind),
                                     selected: selected, action: set(interface.name))
      item.tooltip = DL(selected ? "deck.nic.pinned" : "deck.nic.pin")
      items.append(item)
    }
    if case .missing(let name) = choice {
      var item = DeckConnectMenuItem(id: "nic." + name, title: name + " · " + DL("deck.nic.unavailable"), symbol: "exclamationmark.triangle",
                                     selected: true, action: set(name))
      item.tooltip = DL("deck.nic.pinned")
      items.append(item)
    }
    // nothing to choose between: 自动 alone is not worth a row
    if items.count < 2 { return [] }
    return [DeckConnectMenuSection(id: "nic", title: DL("deck.nic"), items: items)]
  }
}
