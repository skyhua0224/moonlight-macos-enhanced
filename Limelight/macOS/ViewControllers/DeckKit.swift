//
//  DeckKit.swift
//  Shared pieces of the hosts and apps page redesign: variant switch, host facts, display
//  models, small views (glyph tile, chips, posters) and the card look. The look follows the
//  Settings window: tinted symbol tiles, grouped cards with continuous 10-14 pt corners.
//

import AppKit
import SwiftUI

/// Concept-build switches (MLC_* environment): honoured only in builds made with MLC_CONCEPT_HARNESS.
func conceptEnv(_ key: String) -> String? {
  #if MLC_CONCEPT_HARNESS
  return DeckEnvCache.value(key)
  #else
  return nil
  #endif
}

#if MLC_CONCEPT_HARNESS
/// The environment does not change while the app runs; reading it builds a dictionary every time.
enum DeckEnvCache {
  private static let table = ProcessInfo.processInfo.environment
  static func value(_ key: String) -> String? { table[key] }
}
#endif

// MARK: - Variant

/// Which design the build shows. Concept builds read `MLC_VARIANT` from the environment,
/// then the hidden defaults key `MLConceptVariant` ("A", "B" or "classic").
@objc(MLDeckVariant)
public final class DeckVariant: NSObject {
  @objc public static var current: String {
    let known = ["A", "A0", "A1", "A3", "B"]
    if let value = conceptEnv("MLC_VARIANT"), known.contains(value) {
      return value
    }
    // The computer-first home (A0) is the home. The only stored value that counts is the escape hatch:
    //   defaults write std.skyhua.MoonlightMacEnhanced MLConceptVariant classic
    // Anything else a concept build once wrote there (A, A1, A3, B) is ignored, so an old value cannot
    // bring back the host-list page.
    if UserDefaults.standard.string(forKey: "MLConceptVariant") == "classic" {
      return "classic"
    }
    return "A0"
  }
  /// Round 2 content variants inside the sidebar layout: A1 Games, A2 TV, A3 Quiet.
  @objc public static var isPolished: Bool { isDeck && ["A0", "A1", "A3"].contains(current) }
  @objc public static var isQuiet: Bool { isDeck && current == "A3" }
  /// The computer-first page has its own toolbar button (自定义主页).
  @objc public static var isComputerPage: Bool { isDeck && current == "A0" }
  /// A0 and A3 carry the host's name in the page itself; A1 uses the window title.
  @objc public static var titleHidden: Bool { isDeck && ["A0", "A3"].contains(current) }
  @objc public static var isDeck: Bool {
    if #available(macOS 14.0, *) { return current != "classic" }
    return false
  }
  @objc public static var isSidebarVariant: Bool { isDeck && current.hasPrefix("A") }
  @objc public static var isCardsVariant: Bool { isDeck && current == "B" }
}

func DL(_ key: String) -> String { LanguageManager.shared.localize(key) }
func DLf(_ key: String, _ args: CVarArg...) -> String {
  String(format: LanguageManager.shared.localize(key), arguments: args)
}

// MARK: - Host facts the protocol does not carry

/// What the client records about each host itself: when it last connected, which apps it
/// played, when it was last seen online. The platform and vendor are what a host could
/// report in its server info; until then they are filled in by hand (the concept seeds them).
struct DeckSession {
  var appId: String
  /// The app's name when it was started, for a list shown while the host (and its app list) is off.
  var name: String?
  var start: Date
  var seconds: Int
}

struct DeckFacts {
  var platform = ""
  var vendor = ""
  var lastConnected: Date?
  var lastSeen: Date?
  /// Whether the computer answered the last time discovery had an answer for it (a cold launch draws this until the first round is in).
  var lastOnline = false
  var lastApp: String?
  var recents: [String] = []
  /// Streams started from this client, newest first (the host may send a fuller history).
  var sessions: [DeckSession] = []
  // Foundation Sunshine host profile (serverinfo Fs* fields); empty for other hosts.
  var fsVersion = 0
  /// VddCapabilityVersion from /serverinfo: Foundation Sunshine builds that do not send the Fs* fields yet
  /// (2026.1110.165906) already send this one, and no other Sunshine does.
  var vddVersion = 0
  var sunshineVersion = ""
  /// /serverinfo `state` (SUNSHINE_SERVER_FREE, MJOLNIR_STATE_SERVER_AVAILABLE ...) and `GfeVersion`: tell Sunshine from GeForce Experience.
  var serverState = ""
  var gfeVersion = ""
  var osVersion = ""
  var gpu = ""
  var displayModes = ""
  var hostIcon = ""
  /// Icon the user chose for this host ("symbol" + "color", or "image" = a picture on disk).
  var icon: [String: String]?
}

enum DeckFactsStore {
  private static let key = "MLHostFacts"

  // Lock discipline (a deadlock otherwise): `stateLock` guards `store`, `foundation` and `writePending` and
  // NOTHING ELSE. While it is held the code touches only those three dictionaries / flags: no UserDefaults call
  // (writing posts NSUserDefaultsDidChangeNotification, and StreamViewController observes that on the main queue,
  // so the posting thread waits for the main thread), no notification, no callback, no dispatch_sync, no file I/O.
  // The main thread reads a copied snapshot; every write to UserDefaults happens on `writer`, after the lock is released.
  private static let stateLock = NSLock()
  private static var store: [String: [String: Any]]?
  /// Whether a host is Foundation Sunshine, asked for every app tile: remembered, dropped when its serverinfo is read again.
  private static var foundation: [String: Bool] = [:]
  private static var writePending = false
  private static let writer = DispatchQueue(label: "std.skyhua.deck.facts-writer", qos: .utility)
  private static let terminateObserver: NSObjectProtocol = NotificationCenter.default.addObserver(
    forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in DeckFactsStore.flush() }

  static func invalidateFoundationCache() {
    stateLock.lock(); foundation.removeAll(); stateLock.unlock()
  }

  static func isFoundation(_ uuid: String) -> Bool {
    stateLock.lock()
    let hit = foundation[uuid]
    stateLock.unlock()
    if let hit { return hit }
    let facts = DeckFactsStore.facts(for: uuid)
    let value = DeckHostSoftware.isFoundation(fsCapability: facts.fsVersion, vddCapability: facts.vddVersion)
    stateLock.lock(); foundation[uuid] = value; stateLock.unlock()
    return value
  }

  /// Reads UserDefaults once (outside the lock) so that every later access is memory only.
  private static func ensureLoaded() {
    stateLock.lock()
    let loaded = store != nil
    stateLock.unlock()
    if loaded { return }
    let fromDisk = UserDefaults.standard.dictionary(forKey: key) as? [String: [String: Any]] ?? [:]
    _ = terminateObserver
    stateLock.lock()
    if store == nil { store = fromDisk }
    stateLock.unlock()
  }

  /// One host's entry, copied out under the lock (the subscript runs under the lock, the caller gets its own value).
  private static func entry(_ uuid: String) -> [String: Any] {
    ensureLoaded()
    stateLock.lock(); defer { stateLock.unlock() }
    return store?[uuid] ?? [:]
  }

  static func facts(for uuid: String) -> DeckFacts {
    let raw = entry(uuid)
    var facts = DeckFacts()
    facts.platform = raw["platform"] as? String ?? ""
    facts.vendor = raw["vendor"] as? String ?? ""
    facts.lastConnected = DeckTimeRules.fromEpoch(raw["lastConnected"] as? Double)
    facts.lastSeen = DeckTimeRules.fromEpoch(raw["lastSeen"] as? Double)
    facts.lastOnline = raw["lastOnline"] as? Bool ?? false
    facts.lastApp = raw["lastApp"] as? String
    facts.recents = raw["recents"] as? [String] ?? []
    facts.sessions = (raw["sessions"] as? [[String: Any]] ?? []).compactMap { entry in
      guard let app = entry["app"] as? String, let start = DeckTimeRules.fromEpoch(entry["start"] as? Double) else { return nil }
      return DeckSession(appId: app, name: entry["name"] as? String, start: start, seconds: entry["seconds"] as? Int ?? 0)
    }
    facts.fsVersion = (raw["fsVersion"] as? Int) ?? Int(raw["fsVersion"] as? String ?? "") ?? 0
    facts.vddVersion = (raw["vddVersion"] as? Int) ?? 0
    facts.sunshineVersion = raw["sunshineVersion"] as? String ?? ""
    facts.serverState = raw["serverState"] as? String ?? ""
    facts.gfeVersion = raw["gfeVersion"] as? String ?? ""
    facts.osVersion = raw["osVersion"] as? String ?? ""
    facts.gpu = raw["gpu"] as? String ?? ""
    facts.displayModes = raw["displayModes"] as? String ?? ""
    facts.hostIcon = raw["hostIcon"] as? String ?? ""
    facts.icon = raw["icon"] as? [String: String]
    return facts
  }

  static func string(_ uuid: String, _ key: String) -> String {
    ensureLoaded()
    stateLock.lock(); defer { stateLock.unlock() }
    return (store?[uuid]?[key] as? String) ?? ""
  }

  static func setString(_ uuid: String, _ key: String, _ value: String) {
    update(uuid) { $0[key] = value }
  }

  static func setIcon(uuid: String, symbol: String, color: String) {
    update(uuid) { $0["icon"] = ["symbol": symbol, "color": color] }
  }

  static func setIconImage(uuid: String, data: Data) {
    let url = iconImageURL(uuid)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: url)
    update(uuid) { $0["icon"] = ["image": "1", "color": "gray"] }
  }

  static func clearIcon(uuid: String) {
    try? FileManager.default.removeItem(at: iconImageURL(uuid))
    update(uuid) { $0.removeValue(forKey: "icon") }
  }

  static func iconImageURL(_ uuid: String) -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
    return base.appendingPathComponent("Moonlight/HostIcons/\(uuid).png")
  }

  /// What a Foundation Sunshine host reports in /serverinfo (FsCapabilityVersion and friends).
  static func ingest(uuid: String, fields: [String: String]) {
    update(uuid, dropFoundationCache: true) { entry in
      entry["fsVersion"] = Int(fields["FsCapabilityVersion"] ?? "") ?? 0
      entry["vddVersion"] = Int(fields["VddCapabilityVersion"] ?? "") ?? 0
      if let v = fields["SunshineVersion"] { entry["sunshineVersion"] = v }
      if let v = fields["state"] { entry["serverState"] = v }
      // an answer without the tag means the host does not send one (and then the page asks on a timer): an old value must not stay
      entry["appListEtagSeen"] = fields["appListEtag"] ?? ""
      if let v = fields["GfeVersion"] { entry["gfeVersion"] = v }
      entry["vendor"] = DeckHostSoftware.isFoundation(fsCapability: fields["FsCapabilityVersion"], vddCapability: fields["VddCapabilityVersion"]) ? "foundation" : ""
      if let v = fields["FsPlatform"] { entry["platform"] = v }
      if let v = fields["FsOsVersion"] { entry["osVersion"] = v }
      if let v = fields["FsGpu"] { entry["gpu"] = v }
      if let v = fields["FsDisplayModes"] { entry["displayModes"] = v }
      if let v = fields["FsHostIcon"] { entry["hostIcon"] = v }
    }
  }

  /// Read-modify-write of one host's entry, one at a time. `change` runs under `stateLock`: it must only edit the
  /// dictionary it is given (every caller is in this file). The UserDefaults write is scheduled, never done here.
  private static func update(_ uuid: String, dropFoundationCache: Bool = false, _ change: (inout [String: Any]) -> Void) {
    ensureLoaded()
    stateLock.lock()
    var entry = store?[uuid] ?? [:]
    change(&entry)
    store?[uuid] = entry
    if dropFoundationCache { foundation.removeAll() }
    let schedule = !writePending
    writePending = true
    stateLock.unlock()
    if schedule { writer.asyncAfter(deadline: .now() + 0.1) { flush() } }
  }

  /// Writes the current store to UserDefaults. Never called with `stateLock` held.
  static func flush() {
    stateLock.lock()
    // a new top-level dictionary built under the lock, so nothing the writer reads is shared with a later mutation
    let copy = store.map { Dictionary(uniqueKeysWithValues: $0.map { ($0.key, $0.value) }) }
    writePending = false
    stateLock.unlock()
    if let copy { UserDefaults.standard.set(copy, forKey: key) }
  }

  static func recordConnected(uuid: String, appId: String, appName: String = "") {
    update(uuid) { entry in
      entry["lastConnected"] = Date().timeIntervalSince1970
      entry["lastApp"] = appId
      var recents = (entry["recents"] as? [String] ?? []).filter { $0 != appId }
      recents.insert(appId, at: 0)
      entry["recents"] = Array(recents.prefix(8))
      var sessions = entry["sessions"] as? [[String: Any]] ?? []
      var session: [String: Any] = ["app": appId, "start": Date().timeIntervalSince1970, "seconds": 0]
      if !appName.isEmpty { session["name"] = appName }
      sessions.insert(session, at: 0)
      entry["sessions"] = Array(sessions.prefix(20))
    }
  }

  /// A stream ended: the newest session of that app gets its duration.
  static func recordEnded(uuid: String, appId: String) {
    update(uuid) { entry in
      var sessions = entry["sessions"] as? [[String: Any]] ?? []
      guard let index = sessions.firstIndex(where: { ($0["app"] as? String) == appId }),
            let start = sessions[index]["start"] as? Double else { return }
      sessions[index]["seconds"] = max(0, Int(Date().timeIntervalSince1970 - start))
      entry["sessions"] = sessions
    }
  }

  static func recordSeen(uuid: String) {
    update(uuid) { $0["lastSeen"] = Date().timeIntervalSince1970 }
  }

  /// What discovery found (TemporaryHost.state: 1 offline, 2 online; 0 = no answer yet, nothing to remember). Written only
  /// when it changed, so calling it on every refresh costs a dictionary read.
  static func noteReachability(uuid: String, state: Int) {
    guard state == 1 || state == 2 else { return }
    let online = state == 2
    if (entry(uuid)["lastOnline"] as? Bool) == online { return }
    update(uuid) { $0["lastOnline"] = online }
  }
}

@objc(MLDeckActivity)
public final class DeckActivity: NSObject {
  /// Called when a stream is started from the apps page.
  @objc public static func recordConnected(hostUUID: String, appId: String, appName: String) {
    DeckFactsStore.recordConnected(uuid: hostUUID, appId: appId, appName: appName)
  }
  /// Whether this is a Foundation Sunshine host (the client asks it for hero art even before an app list has announced it).
  @objc public static func isFoundation(hostUUID: String) -> Bool { DeckFactsStore.isFoundation(hostUUID) }
  /// "bigscreen" / "desktop" for the default Foundation Sunshine entries by name, "" otherwise.
  @objc public static func kind(forName name: String) -> String { deckKindFromName(name) ?? "" }
  /// Called when the stream of an app ends.
  @objc public static func recordEnded(hostUUID: String, appId: String) {
    DeckFactsStore.recordEnded(uuid: hostUUID, appId: appId)
  }
  /// The same rule as DeckHost.isFoundation, for the stream manager's serverinfo tags (strings, nil when absent).
  @objc public static func isFoundationServerInfo(fsCapability: String?, vddCapability: String?) -> Bool {
    DeckHostSoftware.isFoundation(fsCapability: fsCapability, vddCapability: vddCapability)
  }
  /// The software the host reported in its last /serverinfo ("" if it never did).
  @objc public static func sunshineVersion(hostUUID: String) -> String { DeckFactsStore.string(hostUUID, "sunshineVersion") }
  /// Called whenever discovery finds the host online.
  @objc public static func recordSeen(hostUUID: String) {
    DeckFactsStore.recordSeen(uuid: hostUUID)
  }
  /// The appListEtag the host's last /serverinfo carried ("" if it sends none), and the one saved when the app list was last fetched.
  @objc public static func appListEtagSeen(hostUUID: String) -> String { DeckFactsStore.string(hostUUID, "appListEtagSeen") }
  @objc public static func appListEtagFetched(hostUUID: String) -> String { DeckFactsStore.string(hostUUID, "appListEtagFetched") }
  /// Called after an app list was fetched: `etag` is what the host's /serverinfo said BEFORE the fetch started.
  @objc public static func markAppListFetched(hostUUID: String, etag: String) { DeckFactsStore.setString(hostUUID, "appListEtagFetched", etag) }
  /// Called with the Fs* fields of every /serverinfo answer (empty on other hosts).
  @objc public static func ingestServerInfo(hostUUID: String, fields: [String: String]) {
    DeckFactsStore.ingest(uuid: hostUUID, fields: fields)
  }
}

// MARK: - Display model

struct DeckHost: Identifiable {
  enum Route { case lan, remote, unknown }

  let id: String
  let name: String
  /// TemporaryHost.state as discovery has it: 0 no answer since launch, 1 offline, 2 online.
  let state: Int
  /// What is drawn: online, or (no answer yet) as it was when last seen. The thing that may start a stream is `verified`.
  let online: Bool
  let paired: Bool
  let platform: String
  let route: Route
  let rtt: Int?
  let address: String?
  let codecs: [String]
  let hdr: Bool
  let canWake: Bool
  let facts: DeckFacts
  let runningAppId: String?
  let appCount: Int
  var stale = false
  let raw: TemporaryHost
  var icon: DeckIconSpec
  /// Discovery has really answered that the computer is on.
  var verified: Bool { state == 2 }
  /// Discovery has really answered that the computer is off.
  var settledOffline: Bool { state == 1 }
  /// Foundation Sunshine: the Fs* fields, or (a build before them) the virtual display capability that
  /// only Foundation Sunshine announces.
  var isFoundation: Bool { DeckHostSoftware.isFoundation(fsCapability: facts.fsVersion, vddCapability: facts.vddVersion) }
  /// What /serverinfo says the other side runs (DeckHostSoftware: nothing is guessed, no version is invented).
  var software: DeckHostSoftware.Info {
    DeckHostSoftware.classify(isFoundation: isFoundation, sunshineVersion: facts.sunshineVersion, gfeVersion: facts.gfeVersion,
                              state: facts.serverState, platform: facts.platform)
  }
  /// Foundation Sunshine behind what this client knows (capability, not date); nil = up to date or not Foundation.
  func fsUpdateReason(kindSeen: Bool?) -> DeckFsUpdateRules.Reason? {
    DeckFsUpdateRules.reason(isFoundation: isFoundation, fsCapability: facts.fsVersion, kindSeen: kindSeen)
  }
  func fsUpdateToken() -> String {
    DeckFsUpdateRules.token(version: DeckHostSoftware.versionNumber(facts.sunshineVersion), fsCapability: facts.fsVersion)
  }
  /// The serverinfo of this computer has been read (a state tag is in every GameStream answer): the software is known.
  var softwareKnown: Bool { isFoundation || !facts.serverState.isEmpty }

  var lastActivity: Date? { facts.lastConnected ?? facts.lastSeen }
  var isNearbyUnpaired: Bool { online && !paired }

  /// `live` is the computer as the sidebar and discovery see it right now: the page snapshot takes its state
  /// (online, pairing, address, latency, running app) from it, so page and sidebar always agree.
  init(_ host: TemporaryHost, live: TemporaryHost? = nil) {
    let state = live ?? host
    raw = host
    id = host.uuid
    name = host.displayName
    self.state = Int(state.state.rawValue)
    paired = Int(state.pairState.rawValue) == 2
    let facts = DeckFactsStore.facts(for: host.uuid)
    online = DeckPresenceRules.shownOnline(state: Int(state.state.rawValue), lastOnline: facts.lastOnline)
    self.facts = facts
    icon = DeckIconSpec.resolve(uuid: host.uuid, facts: facts)
    platform = facts.platform
    let active = state.activeAddress
    address = active ?? host.localAddress ?? host.address ?? host.externalAddress
    // the shown latency is smoothed and steady: it moves only by a few ms or 10 %, and a probe round that
    // brings nothing keeps the last value for a while instead of blanking it
    let rawLatency = active.flatMap { (DeckAddress.lookup(state.addressLatencies, $0) as NSNumber?)?.intValue }
    // the round trip of the last real stream on this address first, the application-layer probe where there is none
    let streamMs = active.flatMap { DeckAddressModel.streamMeasured(host.uuid, $0)?.ms }
    rtt = DeckLatency.display(key: host.uuid + "|" + (active ?? ""), raw: DeckLatencyRules.valid(streamMs) ?? DeckLatencyRules.valid(rawLatency))
    if let active, !active.isEmpty {
      if let external = host.externalAddress, !external.isEmpty, external == active, host.localAddress != active {
        route = .remote
      } else if DeckHost.isPrivate(active) {
        route = .lan
      } else {
        route = .remote
      }
    } else {
      route = .unknown
    }
    let flags = Int(state.serverCodecModeSupport)
    var list: [String] = []
    if flags & 0x100 != 0 { list.append("HEVC") }
    if flags & 0x30000 != 0 { list.append("AV1") }
    codecs = list
    hdr = flags & (0x200 | 0x20000) != 0
    canWake = DeckHost.isValidMAC(host.mac) || DeckHost.isValidMAC(state.mac)
    let current = state.currentGame ?? "0"
    runningAppId = current == "0" || current.isEmpty ? nil : current
    appCount = host.appList.count
  }

  /// A MAC is six hex pairs and not all zeros (00:00:00:00:00:00 is what an unknown MAC looks like).
  static func isValidMAC(_ mac: String?) -> Bool {
    let digits = (mac ?? "").filter { $0.isHexDigit }
    return digits.count == 12 && digits.contains { $0 != "0" } && digits.lowercased() != "ffffffffffff"
  }

  /// The kind of way the stream would take now, from the address in use (nil when none is known).
  var activeKind: DeckPathKind? {
    guard let address, !address.isEmpty else { return nil }
    return DeckAddress.kind(address, rtt: rtt)
  }

  /// What changes what the page shows, to redraw only when something did.
  var signature: String {
    let plan = online && paired ? DeckStreamPlan.plan(for: self) : DeckStreamPlan()
    return "\(online)|\(state)|\(paired)|\(rtt ?? -1)|\(address ?? "")|\(runningAppId ?? "")|\(canWake)|\(codecs.joined())|\(hdr)|\(name)|\(plan.summary)"
  }

  static func isPrivate(_ address: String) -> Bool {
    let bare = address.split(separator: ":").first.map(String.init) ?? address
    if bare.hasPrefix("192.168.") || bare.hasPrefix("10.") || bare.hasPrefix("169.254.") { return true }
    if bare.hasPrefix("172.") {
      let parts = bare.split(separator: ".")
      if parts.count > 1, let second = Int(parts[1]), (16...31).contains(second) { return true }
    }
    return bare.hasSuffix(".local")
  }

  func app(id appId: String?) -> TemporaryApp? {
    guard let appId else { return nil }
    return raw.appList.compactMap { $0 as? TemporaryApp }.first { $0.id == appId }
  }
}

enum DeckHostList {
  /// Hosts are keyed by uuid, so a reinstalled host shows up again under a new uuid with the
  /// same name and MAC. Within a group of the same name (or MAC) the live, paired, most recently
  /// used record is kept and any other record that is offline is flagged as stale.
  static func build(_ hosts: [TemporaryHost]) -> [DeckHost] {
    var list = hosts.filter { !$0.uuid.isEmpty }.map { DeckHost($0) }
    var groups: [String: [Int]] = [:]
    for (index, host) in list.enumerated() {
      groups["name:" + host.name.trimmingCharacters(in: .whitespaces).lowercased(), default: []].append(index)
      if let mac = host.raw.mac, !mac.isEmpty { groups["mac:" + mac.lowercased(), default: []].append(index) }
    }
    for (_, members) in groups where members.count > 1 {
      func rank(_ i: Int) -> (Int, Int, TimeInterval) {
        (list[i].online ? 1 : 0, list[i].paired ? 1 : 0, list[i].lastActivity?.timeIntervalSince1970 ?? 0)
      }
      guard let keep = members.max(by: { rank($0) < rank($1) }) else { continue }
      for i in members where i != keep && !list[i].online { list[i].stale = true }
    }
    return list
  }

  static func sorted(_ hosts: [DeckHost]) -> [DeckHost] {
    hosts.sorted { a, b in
      let ar = (a.online ? 0 : 1, a.name.localizedLowercase)
      let br = (b.online ? 0 : 1, b.name.localizedLowercase)
      return ar < br
    }
  }

  static func preferred(_ hosts: [DeckHost]) -> DeckHost? {
    let live = hosts.filter { $0.online && $0.paired && !$0.stale }
    if let last = live.max(by: { ($0.facts.lastConnected ?? .distantPast) < ($1.facts.lastConnected ?? .distantPast) }) {
      return last
    }
    // nothing online yet (a cold launch, discovery has not answered): the computer used last, not just the first one
    let known = hosts.filter { !$0.stale }
    if let last = known.filter({ $0.facts.lastConnected != nil }).max(by: { ($0.facts.lastConnected ?? .distantPast) < ($1.facts.lastConnected ?? .distantPast) }) {
      return last
    }
    return live.first ?? known.first ?? hosts.first
  }
}

// MARK: - Time

enum DeckTime {
  static var locale: Locale {
    switch LanguageManager.shared.currentLanguage {
    case .chinese: return Locale(identifier: "zh-Hans")
    case .english: return Locale(identifier: "en")
    case .system: return Locale.current
    }
  }

  /// nil when the time is unknown (missing, 0 = 1970, or from the future): "上次玩 56 年前" is never shown.
  static func relative(_ date: Date?) -> String? {
    guard let date = DeckTimeRules.valid(date) else { return nil }
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = locale
    formatter.unitsStyle = .short
    return formatter.localizedString(for: date, relativeTo: Date())
  }
}

// MARK: - Look

enum DeckLook {
  static func tint(_ platform: String) -> Color {
    switch platform {
    case "windows": return .blue
    case "macos": return .purple
    case "linux": return .orange
    default: return .gray
    }
  }

  static func symbol(_ platform: String) -> String {
    switch platform {
    case "windows": return "pc"
    case "macos": return "macmini.fill"
    case "linux": return "server.rack"
    default: return "display"
    }
  }

  static func platformName(_ platform: String) -> String {
    switch platform {
    case "windows": return "Windows"
    case "macos": return "macOS"
    case "linux": return "Linux"
    default: return ""
    }
  }
}

extension View {
  /// A glass capsule or card on macOS 26, a material elsewhere.
  @ViewBuilder
  func deckGlass<S: Shape>(_ shape: S, tint: Color? = nil) -> some View {
    if #available(macOS 26.0, *) {
      if let tint {
        self.glassEffect(.regular.tint(tint.opacity(0.35)), in: shape)
      } else {
        self.glassEffect(.regular, in: shape)
      }
    } else {
      self.background(.ultraThinMaterial, in: shape)
    }
  }

  /// The grouped-card surface used by the Settings window.
  /// A grouped box like the ones in System Settings: the quaternary fill (visible on the page colour in light
  /// and dark, over a wallpaper too) and a hairline.
  func deckCard(radius: CGFloat = 14, stroke: Color = Color(nsColor: .separatorColor).opacity(0.7)) -> some View {
    self
      .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(stroke, lineWidth: 0.5))
  }
}

/// Tinted symbol tile, the same shape as the page icons in Settings.
struct DeckGlyph: View {
  let platform: String
  var size: CGFloat = 44
  var muted = false

  var body: some View {
    let tint = muted ? Color.gray : DeckLook.tint(platform)
    Image(systemName: DeckLook.symbol(platform))
      .font(.system(size: size * 0.5, weight: .medium))
      .foregroundStyle(tint)
      .frame(width: size, height: size)
      .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
  }
}

private struct DeckChipsOnDarkKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
  /// Chips drawn over a hero backdrop: white text on a tinted translucent capsule.
  var deckChipsOnDark: Bool {
    get { self[DeckChipsOnDarkKey.self] }
    set { self[DeckChipsOnDarkKey.self] = newValue }
  }
}

struct DeckChip: View {
  let text: String
  var symbol: String?
  var tint: Color = .secondary
  var strong = false
  @Environment(\.colorScheme) private var scheme
  @Environment(\.deckChipsOnDark) private var onDark

  var body: some View {
    HStack(spacing: 4) {
      if let symbol {
        Image(systemName: symbol).font(.system(size: 9.5, weight: .bold))
      }
      Text(text).font(.system(size: 11, weight: .semibold)).lineLimit(1)
    }
    .foregroundStyle(strong || onDark ? Color.white : tint)
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .background(Capsule().fill(strong ? tint : tint.opacity(onDark ? 0.42 : (scheme == .dark ? 0.3 : 0.14))))
    .fixedSize()
  }
}

struct DeckStatusChip: View {
  let host: DeckHost

  var body: some View {
    if host.runningAppId != nil && host.online {
      DeckChip(text: DL("deck.running"), symbol: "play.fill", tint: .green)
    } else if host.online && host.paired {
      DeckChip(text: DL("deck.online"), symbol: "circle.fill", tint: .green)
    } else if host.online {
      DeckChip(text: DL("deck.unpaired"), symbol: "link.badge.plus", tint: .orange)
    } else {
      DeckChip(text: DL("deck.offline"), symbol: "moon.zzz.fill", tint: .gray)
    }
  }
}

/// Route, latency, codecs, HDR and platform as chips, in a fixed order.
struct DeckHostChips: View {
  let host: DeckHost
  var showStatus = true
  var showPlatform = true

  var body: some View {
    HStack(spacing: 6) {
      if showStatus { DeckStatusChip(host: host) }
      if host.online {
        switch host.route {
        case .lan:
          DeckChip(text: host.rtt.map { "\(DL("deck.lan")) · \($0) ms" } ?? DL("deck.lan"), symbol: "wifi", tint: .secondary)
        case .remote:
          DeckChip(text: host.rtt.map { "\(DL("deck.remote")) · \($0) ms" } ?? DL("deck.remote"), symbol: "globe", tint: .secondary)
        case .unknown:
          EmptyView()
        }
        EmptyView()
        if host.hdr { DeckChip(text: "HDR", tint: .pink) }
      }
      if showPlatform, !DeckLook.platformName(host.platform).isEmpty {
        DeckChip(text: DeckLook.platformName(host.platform), tint: DeckLook.tint(host.platform))
      }
    }
  }
}

// MARK: - Posters

/// Art a host can provide per app. The poster is what every host has; the others come from
/// Foundation Sunshine and are simply absent on other hosts.
enum DeckArtKind: String {
  case poster = ""
  case hero = "_hero.jpg"
  case logo = "_logo.png"
  case icon = "_icon.png"
}

