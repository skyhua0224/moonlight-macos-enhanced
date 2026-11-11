//
//  DeckAddressModel.swift
//  The one list of addresses behind the 地址 group and the 线路 chips, built from DeckRules (DeckAddressBook,
//  DeckPathClassifier): the computer's own fields, the endpoints the user added (ConnectionEndpointStore), and what
//  discovery found, each as host:port. 线路 chips group them by PATH class (局域网, 公网直连, 端口转发, 组网, 中转, 未确认).
//

import AppKit
import SwiftUI

enum DeckAddressModel {
  struct Row: Identifiable {
    var id: String { entry.endpoint.key }
    let entry: DeckEndpointEntry
    let verdict: DeckPathVerdict
    var latency: Int?
    /// The round trip Moonlight measured in the last real stream on this address (preferred over the probe's figure).
    var streamMs: Int?
    var streamWhen: Date?
    var answered: Bool
    var failed: Bool
    var isDomain: Bool { entry.endpoint.isDomain }
    var word: DeckPathWords.Word { DeckPathWords.word(verdict, entry.endpoint) }
  }

  // MARK: the one list

  static func entries(_ host: DeckHost) -> [DeckEndpointEntry] {
    let live = DeckLive.host(host.id) ?? host.raw
    let preset = [live.localAddress, live.externalAddress, live.ipv6Address, live.address]
    let manual = ConnectionEndpointStore.manualEndpoints(forHost: host.id)
    var discovered: [String] = ConnectionEndpointStore.allEndpoints(for: live)
    discovered += (live.addressStates?.keys.map { $0 } ?? [])
    discovered += (live.addressLatencies?.keys.map { $0 } ?? [])
    if let active = live.activeAddress { discovered.append(active) }
    let disabled = Set(ConnectionEndpointStore.disabledEndpoints(forHost: host.id).compactMap { DeckEndpoint.parse($0)?.key })
    let merged = DeckAddressBook.merge(preset: preset, manual: manual, discovered: discovered, disabled: disabled)
    // the order the user gave (the store lists it first for automatic connection too)
    let order = ConnectionEndpointStore.endpointOrder(forHost: host.id).compactMap { DeckEndpoint.parse($0)?.key }
    guard !order.isEmpty else { return merged }
    let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
    return merged.enumerated().sorted { a, b in
      let ra = rank[a.element.endpoint.key] ?? Int.max, rb = rank[b.element.endpoint.key] ?? Int.max
      return ra != rb ? ra < rb : a.offset < b.offset
    }.map { $0.element }
  }

  /// The string under which the store keeps a manual address (it may be bare, without the default port).
  static func manualRaw(_ host: DeckHost, _ entry: DeckEndpointEntry) -> String? {
    ConnectionEndpointStore.manualEndpoints(forHost: host.id).first { DeckEndpoint.parse($0) == entry.endpoint }
  }

  /// Saves the order of the rows as shown (top first): automatic connection prefers it.
  static func saveOrder(_ host: DeckHost, _ rows: [DeckEndpointEntry]) {
    ConnectionEndpointStore.setEndpointOrder(rows.map { $0.endpoint.display }, forHost: host.id)
  }

  static func move(_ host: DeckHost, key: String, by delta: Int) {
    var list = entries(host)
    guard let index = list.firstIndex(where: { $0.endpoint.key == key }) else { return }
    let target = index + delta
    guard list.indices.contains(target) else { return }
    list.swapAt(index, target)
    saveOrder(host, list)
  }

  /// The control-stream RTT of the last stream over this address (LatencyProbe.noteStreamRtt), for at most 7 days.
  static func streamMeasured(_ uuid: String, _ address: String) -> (ms: Int, when: Date)? {
    guard let entry = LatencyProbe.lastStreamRtt(forHost: uuid, address: address),
          let ms = (entry["ms"] as? NSNumber)?.intValue, ms > 0, let when = entry["when"] as? Date,
          Date().timeIntervalSince(when) < 7 * 86400 else { return nil }
    return (ms, when)
  }

  // MARK: path of one address

  static func facts(_ host: DeckHost, _ entry: DeckEndpointEntry) -> DeckPathFacts {
    let live = DeckLive.host(host.id) ?? host.raw
    let endpoint = entry.endpoint
    var facts = DeckPathFacts(endpoint: endpoint)
    if endpoint.isDomain {
      // asks the resolver (off the main thread, remembered): nil until it has answered
      facts.resolvedIPs = DeckResolver.addresses(endpoint.host)
    }
    // the public IP the computer reports for itself (its externalAddress), when that is an IP
    if let external = live.externalAddress.flatMap({ DeckEndpoint.parse($0) }), !external.isDomain { facts.hostPublicIP = external.host }
    let state: NSNumber? = DeckAddressBook.lookup(live.addressStates as? [String: NSNumber], entry)
    let rtt: NSNumber? = DeckAddressBook.lookup(live.addressLatencies as? [String: NSNumber], entry)
    if let state { facts.tested = true; if state.boolValue, let rtt, rtt.intValue >= 0 { facts.rttMs = rtt.intValue } }
    if let signal = HostPathSignals.shared.probeFact(uuid: host.id, address: endpoint.display) {
      if signal.iface == 2 { facts.egressIsTunnel = true } else if signal.iface == 1 { facts.egressIsTunnel = false }
      if signal.iface == 2 && !signal.egressSource.isEmpty { facts.egressSourceIPv4 = signal.egressSource }
      if signal.relayed { facts.relayReported = true }
      if facts.rttMs == nil, signal.reachable, signal.rttMs >= 0 { facts.rttMs = signal.rttMs }
      facts.tested = true
    }
    if let declared = ConnectionEndpointStore.declaredPath(forEndpoint: endpoint.display, forHost: host.id), let kind = DeckDeclaredPath(rawValue: declared) {
      facts.declared = kind
    }
    return facts
  }

  static func rows(_ host: DeckHost) -> [Row] {
    let live = DeckLive.host(host.id) ?? host.raw
    return entries(host).map { entry in
      let verdict = DeckPathClassifier.classify(facts(host, entry))
      let state: NSNumber? = DeckAddressBook.lookup(live.addressStates as? [String: NSNumber], entry)
      let rtt: NSNumber? = DeckAddressBook.lookup(live.addressLatencies as? [String: NSNumber], entry)
      var answered = state?.boolValue == true
      var failed = state != nil && !answered
      var latency = answered ? rtt.map { $0.intValue }.flatMap { $0 >= 0 ? $0 : nil } : nil
      if state == nil, let result = DeckProbe.result(host.id, entry.endpoint.display) {
        if result.reachable { answered = true; latency = result.ms } else { failed = true }
      }
      if let ms = latency, ms < 0 { latency = nil }
      // a stream measured on this address is the truth about it: it wins over the probe, which only fills in where there was none
      let stream = DeckAddressModel.streamMeasured(host.id, entry.endpoint.display)
      if let stream { latency = stream.ms; answered = answered || true }
      return Row(entry: entry, verdict: verdict, latency: latency, streamMs: stream?.ms, streamWhen: stream?.when, answered: answered, failed: failed && stream == nil)
    }
  }

  // MARK: words

  static func title(_ word: DeckPathWords.Word) -> String {
    switch word {
    case .lan: return DL("deck.path.lan")
    case .publicDirect: return DL("deck.path.publicDirect")
    case .publicForward: return DL("deck.path.forward")
    case .overlay: return DL("deck.path.overlay")
    case .relay: return DL("deck.path.relay")
    case .proxy: return DL("deck.path.proxy")
    case .ip: return DL("deck.label.ip")
    case .domain: return DL("deck.label.domain")
    case .privateAddress: return DL("deck.label.private")
    }
  }

  static func symbol(_ word: DeckPathWords.Word) -> String {
    switch word {
    case .lan: return "wifi"
    case .publicDirect: return "globe"
    case .publicForward: return "arrow.left.arrow.right"
    case .overlay: return "point.3.connected.trianglepath.dotted"
    case .relay: return "arrow.triangle.swap"
    case .proxy: return "lock.shield"
    case .ip: return "number"
    case .domain: return "network"
    case .privateAddress: return "house"
    }
  }

  /// "解析到 203.0.113.79,与主机公网地址一致", "用户声明", ...
  static func evidence(_ verdict: DeckPathVerdict) -> String {
    switch verdict.evidence {
    case .userDeclared: return DL("deck.evidence.user")
    case .relayReported: return DL("deck.evidence.relay")
    case .tunnelInterface: return DL("deck.evidence.tunnel")
    case .proxyTunnel: return DL("deck.evidence.proxy")
    case .overlayRange: return DL("deck.evidence.overlayRange")
    case .matchesHostPublicIP(let ip): return DLf("deck.evidence.matchesPublic", ip)
    case .hostOwnsPublicAddress(let ip): return DLf("deck.evidence.hostNic", ip)
    case .ipv6Global: return DL("deck.evidence.ipv6")
    case .physicalPrivateFast(let rtt): return DLf("deck.evidence.lanFast", rtt)
    case .none: return DL("deck.evidence.none")
    }
  }

  static func confidenceText(_ confidence: DeckConfidence) -> String {
    switch confidence {
    case .low: return DL("deck.confidence.low")
    case .medium: return DL("deck.confidence.medium")
    case .high: return DL("deck.confidence.high")
    }
  }

  /// The word for the address the stream uses now, nil while it is unconfirmed.
  static func activeWord(_ host: DeckHost) -> String? {
    let live = DeckLive.host(host.id) ?? host.raw
    guard let active = (live.activeAddress ?? host.address).flatMap({ DeckEndpoint.parse($0) }) else { return nil }
    guard let row = rows(host).first(where: { $0.entry.endpoint == active }), row.verdict.isConfirmed else { return nil }   // no class without evidence, so no word
    return title(row.word)
  }

  // MARK: refresh and probe

  /// Probes every address that has no result yet, now (a new address is tested at once).
  static func probeMissing(_ host: DeckHost, actions: DeckAppsActions?) {
    guard let actions, host.online else { return }
    for row in rows(host) where !row.answered && !row.failed {
      DeckProbe.request(host: host.id, address: row.entry.endpoint.display, using: actions.probeAddress)
    }
  }
}

// MARK: - The remembered 线路 chips

/// The chips of each computer as they were last drawn with every result in. The first frame of the next launch draws them (see
/// DeckChipStability). Memory only inside the lock; the UserDefaults write is on `writer`, after the lock is released.
enum DeckChipMemory {
  private static let key = "MLDeckChipMemory"
  private static let lock = NSLock()
  private static var entries: [String: DeckChipMemoryEntry]?
  private static var firstAsked: [String: Date] = [:]
  private static var lastSaved: [String: Date] = [:]
  private static let writer = DispatchQueue(label: "std.skyhua.deck.chips-writer", qos: .utility)

  private static func ensureLoaded() {
    lock.lock(); let loaded = entries != nil; lock.unlock()
    if loaded { return }
    let raw = UserDefaults.standard.dictionary(forKey: key) as? [String: [String: Any]] ?? [:]
    let parsed = raw.compactMapValues { DeckChipMemoryEntry(dictionary: $0) }
    lock.lock(); if entries == nil { entries = parsed }; lock.unlock()
  }

  static func entry(_ uuid: String) -> DeckChipMemoryEntry? {
    ensureLoaded()
    lock.lock(); defer { lock.unlock() }
    return entries?[uuid]
  }

  /// Seconds since the chips of this computer were first asked for in this run.
  static func waited(_ uuid: String) -> TimeInterval {
    lock.lock(); defer { lock.unlock() }
    if let first = firstAsked[uuid] { return Date().timeIntervalSince(first) }
    firstAsked[uuid] = Date()
    return 0
  }

  static func sinceLastSave(_ uuid: String) -> TimeInterval {
    lock.lock(); defer { lock.unlock() }
    return lastSaved[uuid].map { Date().timeIntervalSince($0) } ?? .infinity
  }

  static func save(_ uuid: String, _ entry: DeckChipMemoryEntry) {
    ensureLoaded()
    lock.lock()
    entries?[uuid] = entry
    lastSaved[uuid] = Date()
    let snapshot = entries?.mapValues { $0.dictionary } ?? [:]
    lock.unlock()
    writer.async { UserDefaults.standard.set(snapshot, forKey: key) }
  }
}
