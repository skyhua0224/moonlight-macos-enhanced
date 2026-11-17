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

@available(macOS 14.0, *)
enum DeckArt {
  private static let cache = NSCache<NSString, NSImage>()

  static func path(_ app: TemporaryApp, _ kind: DeckArtKind = .poster) -> String {
    guard (app.host?.uuid ?? "").isEmpty == false, (app.id ?? "").isEmpty == false else { return "" }
    let poster: String = AppAssetManager.boxArtPath(for: app) ?? ""
    if kind == .poster { return poster }
    return (poster as NSString).deletingPathExtension + kind.rawValue
  }

  static func exists(_ app: TemporaryApp, _ kind: DeckArtKind) -> Bool {
    FileManager.default.fileExists(atPath: path(app, kind))
  }

  private static func key(_ app: TemporaryApp, _ kind: DeckArtKind = .poster) -> NSString {
    "\(app.host?.uuid ?? "")/\(app.id ?? "")/\(kind.rawValue)" as NSString
  }

  static func cached(_ app: TemporaryApp, _ kind: DeckArtKind) -> NSImage? { cache.object(forKey: key(app, kind)) }

  static func load(_ app: TemporaryApp, kind: DeckArtKind, maxPixel: Int = 1600) async -> NSImage? {
    if let hit = cached(app, kind) { return hit }
    let file = path(app, kind)
    let cacheKey = key(app, kind)
    let image: NSImage? = await Task.detached(priority: .userInitiated) {
      guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: file) as CFURL, nil) else { return nil }
      let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixel,
      ]
      guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
      return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }.value
    if let image { cache.setObject(image, forKey: cacheKey) }
    return image
  }

  /// The art's average colour, lifted a little in saturation, for tinting a page background.
  static func dominantColor(_ image: NSImage) -> Color? {
    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    var pixel = [UInt8](repeating: 0, count: 4)
    guard let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.interpolationQuality = .medium
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    let color = NSColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
    var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    color.usingColorSpace(.deviceRGB)?.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
    return Color(hue: Double(h), saturation: Double(min(1, s * 1.35)), brightness: Double(max(0.35, min(0.85, b))))
  }

  static func cached(_ app: TemporaryApp) -> NSImage? { cache.object(forKey: key(app)) }

  static func invalidate(_ app: TemporaryApp, except kept: DeckArtKind? = nil) {
    for kind in [DeckArtKind.poster, .hero, .logo, .icon] where kind != kept { cache.removeObject(forKey: key(app, kind)) }
  }

  /// What `refreshPoster` needs, read on the caller's thread.
  static func posterRefreshTarget(_ app: TemporaryApp) -> (key: String, path: String) {
    (key(app) as String, AppAssetManager.boxArtPath(for: app) ?? "")
  }

  /// Replaces the cached poster with the file that is on disk now (decoded off the main thread). A file that cannot be
  /// read leaves the cache empty, as before.
  static func refreshPoster(key: String, path: String, maxPixel: Int = 900) async {
    let image: NSImage? = await Task.detached(priority: .userInitiated) {
      guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
      let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixel,
      ]
      guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
      return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }.value
    if let image { cache.setObject(image, forKey: key as NSString) } else { cache.removeObject(forKey: key as NSString) }
  }

  /// Decodes a downsampled copy off the main thread so scrolling never waits on a PNG.
  static func load(_ app: TemporaryApp, maxPixel: Int = 560) async -> NSImage? {
    if let hit = cached(app) { return hit }
    let path: String = AppAssetManager.boxArtPath(for: app) ?? ""
    let cacheKey = key(app)
    let image: NSImage? = await Task.detached(priority: .userInitiated) {
      let url = URL(fileURLWithPath: path)
      guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
      let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixel,
      ]
      guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
      return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }.value
    if let image { cache.setObject(image, forKey: cacheKey) }
    return image
  }
}

/// Poster art at the box-art aspect ratio, with the app's initial as a stand-in while it loads.
/// Art of any shape in a box of a fixed aspect. The box is laid out first (a clear shape of the
/// aspect), the picture is drawn over it and cut off at its edge: the picture's own size and aspect
/// never reach the layout, so a wide wallpaper or a square icon cannot widen its tile or its column.
struct DeckFilledImage: View {
  let image: NSImage
  let aspect: CGFloat

  var body: some View {
    Color.clear
      .aspectRatio(aspect, contentMode: .fit)
      .overlay { Image(nsImage: image).resizable().scaledToFill() }
      .clipped()
  }
}

@available(macOS 14.0, *)
struct DeckPoster: View {
  let app: TemporaryApp
  var version = 0
  var radius: CGFloat = 14
  @SwiftUI.State private var image: NSImage?
  @Environment(\.deckScale) private var s

  var body: some View {
    Group {
      if let image {
        DeckFilledImage(image: image, aspect: 0.75)
      } else {
        ZStack {
          Rectangle().fill(Color.gray.opacity(0.18))
          Text(String((app.name ?? "?").prefix(1)))
            .font(.system(size: 34 * s, weight: .bold, design: .rounded))
            .foregroundStyle(.secondary)
        }
        .aspectRatio(0.75, contentMode: .fit)
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    .task(id: "\(app.deckKey)/\(version)") {
      // the picture on screen stays until the next one is decoded (a poster is replaced by its lossless picture)
      if let hit = DeckArt.cached(app) { image = hit }
      // decoded for the largest tile on a 2x screen with the adaptive factor (240 pt * 1.35 * 2 = 650 px) and more
      image = await DeckArt.load(app, maxPixel: 900)
    }
  }
}

extension TemporaryApp {
  /// App ids repeat across hosts, so identity needs the host as well.
  var deckKey: String { "\(host?.uuid ?? "")/\(id ?? "")" }
}

/// The blurred, darkened poster behind a hero card; falls back to the platform tint.
@available(macOS 14.0, *)
struct DeckHeroBackdrop: View {
  let app: TemporaryApp?
  let tint: Color
  var version = 0
  @SwiftUI.State private var image: NSImage?

  var body: some View {
    Color.clear
      .overlay {
        GeometryReader { geo in
          ZStack {
            LinearGradient(colors: [tint.opacity(0.55), tint.opacity(0.18)], startPoint: .topLeading, endPoint: .bottomTrailing)
            if let image {
              Image(nsImage: image)
                .resizable().scaledToFill()
                .frame(width: geo.size.width * 1.3, height: geo.size.height * 1.3)   // a bigger frame, not a transform
                .blur(radius: 38)
                .saturation(1.3)
                .frame(width: geo.size.width, height: geo.size.height).clipped()
            }
            LinearGradient(colors: [.black.opacity(0.62), .black.opacity(0.28), .black.opacity(0.38)],
                           startPoint: .leading, endPoint: .trailing)
          }
        }
      }
      .clipped()
    .task(id: "\(app?.deckKey ?? "")/\(version)") {
      image = nil
      if let app { image = await DeckArt.load(app, maxPixel: 320) }
    }
  }
}

/// Which host the sidebar variant opens on.
@objc(MLDeckHostPicker)
public final class DeckHostPicker: NSObject {
  @objc public static func preferred(from hosts: [TemporaryHost]) -> TemporaryHost? {
    DeckHostList.preferred(DeckHostList.build(hosts).filter { !$0.stale })?.raw
  }
}

/// The computers as discovery has them right now (set by the sidebar's controller).
enum DeckLive {
  static var provider: (() -> [TemporaryHost])?
  static func host(_ uuid: String) -> TemporaryHost? { provider?().first { $0.uuid == uuid } }
}

// MARK: - Paths and addresses

/// What kind of way to a computer an address is, as far as the address alone says. A private address over a
/// tunnel cannot be told from a real LAN by its number, so the page only calls it 局域网 when it also answers fast.
enum DeckPathKind {
  case lan, direct, overlay, relay, tunnel, ipv6, ipv6lan, mdns, hostname, privateUnknown

  var symbol: String {
    switch self {
    case .lan, .ipv6lan, .privateUnknown: return "wifi"
    case .direct, .ipv6: return "globe"
    case .overlay: return "point.3.connected.trianglepath.dotted"
    case .relay: return "arrow.left.arrow.right"
    case .tunnel: return "lock.shield"
    case .mdns: return "dot.radiowaves.left.and.right"
    case .hostname: return "network"
    }
  }

  var title: String {
    switch self {
    case .lan: return DL("deck.path.lan")
    case .direct: return DL("deck.path.direct")
    case .overlay: return DL("deck.path.overlay")
    case .relay: return DL("deck.path.relay")
    case .tunnel: return DL("deck.path.tunnel")
    case .ipv6: return DL("deck.addr.ipv6")
    case .ipv6lan: return DL("deck.addr.ipv6lan")
    case .mdns: return DL("deck.addr.mdns")
    case .hostname: return DL("deck.addr.hostname")
    case .privateUnknown: return DL("deck.path.private")
    }
  }
}

enum DeckAddress {
  /// The address as shown: surrounding spaces and the trailing dot of a DNS name removed
  /// ("Gaming-PC.local.:57989" -> "Gaming-PC.local:57989").
  static func normalized(_ raw: String) -> String {
    var text = raw.trimmingCharacters(in: .whitespaces)
    if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
      let inner = String(text[text.index(after: text.startIndex)..<close])
      let rest = String(text[text.index(after: close)...])
      return "[" + inner.trimmingCharacters(in: CharacterSet(charactersIn: ".")) + "]" + rest
    }
    if text.filter({ $0 == ":" }).count == 1, let colon = text.firstIndex(of: ":") {
      let host = String(text[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "."))
      return host + String(text[colon...])
    }
    if text.filter({ $0 == ":" }).isEmpty { text = text.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
    return text
  }

  /// The host part, without port or brackets.
  static func hostPart(_ raw: String) -> String {
    let text = normalized(raw)
    if text.hasPrefix("["), let close = text.firstIndex(of: "]") { return String(text[text.index(after: text.startIndex)..<close]) }
    if text.filter({ $0 == ":" }).count == 1, let colon = text.firstIndex(of: ":") { return String(text[..<colon]) }
    return text
  }

  /// The host part, lowercased: the key that ties an address to discovery's results, whatever port or trailing
  /// dot either side carries ("192.0.2.133:57989" and "192.0.2.133" are the same address).
  static func key(_ raw: String) -> String { hostPart(raw).lowercased() }

  /// A value from discovery's dictionaries (keyed by its own endpoint strings) for an address, by host part.
  static func lookup<T>(_ dict: [AnyHashable: Any]?, _ raw: String) -> T? {
    guard let dict else { return nil }
    if let hit = dict[raw] as? T { return hit }
    let wanted = key(raw)
    for (k, v) in dict { if let name = k as? String, key(name) == wanted, let hit = v as? T { return hit } }
    return nil
  }

  static func kind(_ raw: String, rtt: Int? = nil) -> DeckPathKind {
    let host = hostPart(raw).lowercased()
    if host.contains(":") {
      // IPv6: fd00::/8 unique local is a LAN, fe80 link local too
      if host.hasPrefix("fd") || host.hasPrefix("fc") || host.hasPrefix("fe80") { return .ipv6lan }
      return .ipv6
    }
    if host.hasSuffix(".local") { return .mdns }
    if host.contains(where: { $0.isLetter }) {
      // a DNS name: what it resolves to says what path it is (a DDNS name for the public address is a direct path)
      if let ip = DeckResolver.addresses(host)?.first { return kind(ip, rtt: rtt) }
      return .hostname
    }
    let parts = host.split(separator: ".").compactMap { Int($0) }
    guard parts.count == 4 else { return .hostname }
    if parts[0] == 100, (64...127).contains(parts[1]) { return .overlay }
    if DeckHost.isPrivate(host) {
      if let rtt, rtt > 40 { return .privateUnknown }
      return .lan
    }
    return .direct
  }
}

/// The latency as shown: an exponentially smoothed value that changes the text only when it has moved by
/// 3 ms or 10 %, and survives a probe round that returned nothing for 20 s.
enum DeckLatency {
  private static let lock = NSLock()
  private static var smoothed: [String: Double] = [:]
  private static var shown: [String: (value: Int, when: Date)] = [:]

  static func display(key: String, raw rawValue: Int?) -> Int? {
    lock.lock(); defer { lock.unlock() }
    let raw = DeckLatencyRules.valid(rawValue)   // -1 (reachable, no number) is nothing to show: the last valid figure stays
    let now = Date()
    guard let raw else {
      if let last = shown[key], now.timeIntervalSince(last.when) < 20 { return last.value }
      return nil
    }
    let value = smoothed[key].map { 0.7 * $0 + 0.3 * Double(raw) } ?? Double(raw)
    smoothed[key] = value
    let target = Int(value.rounded())
    if let last = shown[key] {
      let delta = abs(target - last.value)
      let moved = delta >= 3 || Double(delta) >= Double(last.value) * 0.10
      shown[key] = (moved ? target : last.value, now)
      return shown[key]?.value
    }
    shown[key] = (target, now)
    return target
  }
}

/// "H.264 / H.265 / AV1 · HDR": what the computer can do (H.264 is always there). Shown in 主机信息, not in the status line.
func deckCapabilityText(_ host: DeckHost) -> String {
  var names = ["H.264"]
  if host.codecs.contains("HEVC") { names.append("H.265") }
  if host.codecs.contains("AV1") { names.append("AV1") }
  var text = names.joined(separator: " / ")
  if host.hdr { text += " · HDR" }
  return text
}

/// Resolves a DNS name to its addresses off the main thread, remembers the answer, and tells the page (so a
/// name that points at the public address is called 直连 once known). `addresses` answers at once from the cache.
enum DeckResolver {
  private static let lock = NSLock()
  private static var cache: [String: [String]] = [:]
  private static var started: [String: Date] = [:]

  static func addresses(_ name: String) -> [String]? {
    let key = name.lowercased()
    // MLC_RESOLVE="name=ip,name=ip": what a name resolves to in the shots (harness only)
    if let table = conceptEnv("MLC_RESOLVE") {
      for pair in table.split(separator: ",") {
        let parts = pair.split(separator: "=").map(String.init)
        if parts.count == 2, parts[0].lowercased() == key { return [parts[1]] }
      }
    }
    lock.lock()
    if let hit = cache[key] { lock.unlock(); return hit }
    let recent = started[key].map { Date().timeIntervalSince($0) < 60 } ?? false
    if !recent { started[key] = Date() }
    lock.unlock()
    if !recent {
      DispatchQueue.global(qos: .utility).async {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        var found: [String] = []
        if getaddrinfo(name, nil, &hints, &result) == 0 {
          var cursor = result
          while let info = cursor {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
              let text = String(cString: buffer)
              if !found.contains(text) { found.append(text) }
            }
            cursor = info.pointee.ai_next
          }
          freeaddrinfo(result)
        }
        // IPv4 first: the stream prefers it and the kinds read more naturally
        found.sort { ($0.contains(":") ? 1 : 0) < ($1.contains(":") ? 1 : 0) }
        lock.lock(); cache[key] = found; lock.unlock()
        if !found.isEmpty { DispatchQueue.main.async { NotificationCenter.default.post(name: DeckConnectMenuRegistry.didChange, object: nil) } }
      }
    }
    return nil
  }
}

/// Independent reachability results for addresses discovery has not reported on yet (the 线路 chips ask for
/// one when a path has no result): a serverinfo probe with a 1.5 s timeout that never touches discovery's state.
enum DeckProbe {
  /// reachable: the host answered; ms: the application round trip when one was measured, never negative
  struct Result { let reachable: Bool; let ms: Int?; let when: Date }
  private static let lock = NSLock()
  private static var results: [String: Result] = [:]
  private static var running: Set<String> = []
  private static var lastTry: [String: Date] = [:]

  /// host:port (the same host on two ports is two addresses)
  static func endpointKey(_ address: String) -> String { DeckEndpoint.parse(address)?.key ?? address.lowercased() }

  static func result(_ host: String, _ address: String) -> Result? {
    lock.lock(); defer { lock.unlock() }
    return results[host + "|" + DeckProbe.endpointKey(address)]
  }

  static func isRunning(_ host: String, _ address: String) -> Bool {
    lock.lock(); defer { lock.unlock() }
    return running.contains(host + "|" + DeckProbe.endpointKey(address))
  }

  /// Starts a probe if none ran for this address in the last 8 s.
  static func request(host: String, address: String, using probe: ((String, Double, @escaping (NSNumber?) -> Void) -> Void)?) {
    guard let probe else { return }
    let key = host + "|" + DeckProbe.endpointKey(address)
    lock.lock()
    if running.contains(key) || (lastTry[key].map { Date().timeIntervalSince($0) < 8 } ?? false) { lock.unlock(); return }
    running.insert(key); lastTry[key] = Date()
    lock.unlock()
    probe(address, 1.5) { ms in
      lock.lock()
      results[key] = Result(reachable: ms != nil, ms: DeckLatencyRules.valid(ms?.intValue), when: Date())
      running.remove(key)
      lock.unlock()
      DispatchQueue.main.async { NotificationCenter.default.post(name: DeckConnectMenuRegistry.didChange, object: nil) }
    }
  }
}


// MARK: - Real-size scaling

/// The factor the adaptive size makes a card bigger by. It is a LAYOUT number: the tile views multiply their own metrics
/// (fonts, spacing, radii, shadows) by it, so the system lays out and draws them at the target size. A scale transform
/// (scaleEffect) draws a card at its base size and enlarges the picture of it: soft text and edges. A transform is only
/// used for transient hover feedback, never for a resting size.
private struct DeckScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }
extension EnvironmentValues {
  var deckScale: CGFloat {
    get { self[DeckScaleKey.self] }
    set { self[DeckScaleKey.self] = newValue }
  }
}


// MARK: - Popovers drawn over a forced-dark header

/// The real appearance of the window. A header drawn over a wallpaper forces `.dark` for its own text; a popover or sheet opened
/// from inside it inherits that, and its text and symbols (.primary = white) land on the system's LIGHT popover material:
/// white on white, the icon picker in light mode. Anything presented from there sets the real scheme again.
enum DeckAppearance {
  static var scheme: ColorScheme {
    NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
  }
}

extension View {
  func deckPopoverContent() -> some View { self.environment(\.colorScheme, DeckAppearance.scheme) }
}


// MARK: - Foundation Sunshine: the mark, the label, the one-time recommendation

/// Where Foundation Sunshine is described (its own About page and tray menu use this address).
let deckFoundationSunshineURL = URL(string: "https://github.com/AlkaidLab/foundation-sunshine")!
/// Its releases, where the Foundation Sunshine panel itself looks for updates.
let deckFoundationSunshineReleasesURL = URL(string: "https://github.com/AlkaidLab/foundation-sunshine/releases/latest")!

@available(macOS 14.0, *)
enum DeckFs {
  static func names() -> DeckHostSoftware.Names {
    DeckHostSoftware.Names(foundation: DL("deck.fs.name"), sunshine: DL("deck.software.sunshine"),
                           gfe: DL("deck.software.gfe"), compatible: DL("deck.software.compatible"))
  }
  /// The 主机软件 row text.
  static func softwareText(_ host: DeckHost) -> String { DeckHostSoftware.title(host.software, names: names()) }
  /// The hover text: the same with the version string exactly as the host sent it (".杂鱼", ".<commit>", a manual build's tag).
  static func softwareDetail(_ host: DeckHost) -> String { DeckHostSoftware.detail(host.software, names: names()) }

  static func learn() { NSWorkspace.shared.open(deckFoundationSunshineURL) }
  static func learnUpdate() { NSWorkspace.shared.open(deckFoundationSunshineReleasesURL) }

  /// The functions that exist only with Foundation Sunshine (each one reads a Fs* field or a Foundation endpoint).
  static let features: [(symbol: String, key: String)] = [
    ("tv", "deck.fs.feat.bigscreen"),             // FsKind=bigscreen
    ("display.2", "deck.fs.feat.vdd"),            // VddCapabilityVersion + /displays
    ("photo.on.rectangle", "deck.fs.feat.art"),   // FsArt: hero, logo, icon
    ("cpu", "deck.fs.feat.hardware"),             // FsGpu, FsOsVersion, FsDisplayModes
    ("macwindow.badge.plus", "deck.fs.feat.icon"),// FsHostIcon
    ("clock.arrow.circlepath", "deck.fs.feat.played"), // FsLastPlayed, FsPlaySeconds, FsSession
  ]

  /// Why a function is greyed: on a computer known not to be Windows the text says it is Windows-only.
  static func requirement(_ host: DeckHost) -> String {
    host.software.windows == .no ? DL("deck.fs.requiresWindows") : DL("deck.fs.requires")
  }

  static func promoKey(_ host: DeckHost, _ what: String) -> String { "deck.fsPromo.\(what).\(host.id)" }
  nonisolated(unsafe) static var shownThisLaunch = Set<String>()
}

/// The small sun in the sidebar: a Foundation Sunshine computer, monochrome, with its version as the tooltip.
@available(macOS 14.0, *)
struct DeckFsMark: View {
  let host: DeckHost
  /// `.secondary` inside a list row: the list turns it white on the accent fill of the selected row (measured 5.4:1 light, 6.3:1
  /// dark against the fill) and keeps it grey on the grey selection of an unfocused or inactive window.
  var body: some View {
    Image(systemName: "sun.max.fill")
      .font(.system(size: 10, weight: .semibold))
      .foregroundStyle(.secondary)
      .deckHelp(DeckFs.softwareDetail(host))
      .accessibilityLabel(DeckFs.softwareText(host))
  }
}

/// A low-key label ("Foundation Sunshine 2026.1110.165906") on the card and in the hero; opens 主机信息.
@available(macOS 14.0, *)
struct DeckFsLabel: View {
  let host: DeckHost
  var onDark = false
  var body: some View {
    Button {
      NotificationCenter.default.post(name: .init("MLDeckHostCommand"), object: nil,
                                      userInfo: ["command": "menu", "host": host.raw, "action": "details"])
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "sun.max.fill").font(.system(size: 9, weight: .semibold))
        Text(DeckFs.softwareText(host)).font(.system(size: 11, weight: .medium)).lineLimit(1)
      }
      .foregroundStyle(onDark ? Color.white.opacity(0.9) : Color.secondary)
      .padding(.horizontal, 8).padding(.vertical, 3)
      .background { if onDark { Color.clear.deckGlass(Capsule()) } else { Capsule().fill(Color.primary.opacity(0.06)) } }
      .contentShape(Capsule())
    }
    .controllerButtonStyle(.plain)
    .deckHelp(DeckFs.softwareDetail(host) == DeckFs.softwareText(host) ? DL("deck.fs.openInfo") : "\(DeckFs.softwareDetail(host))\n\(DL("deck.fs.openInfo"))")
  }
}

/// The recommendation under the hero of a computer that does not run Foundation Sunshine: once per computer, no modal.
@available(macOS 14.0, *)
struct DeckFsBanner: View {
  let snapshot: DeckHost
  @ObservedObject var model: DeckAppsModel
  @SwiftUI.State private var tick = 0

  /// The computer as it is now: its software is only known once a serverinfo answer has been read, which may be after the page was built.
  private var host: DeckHost { let _ = tick; return DeckHost(snapshot.raw, live: DeckLive.host(snapshot.id)) }

  private var updateShown: Bool {
    let defaults = UserDefaults.standard
    return host.paired && DeckFsUpdateRules.shouldShow(
      reason: host.fsUpdateReason(kindSeen: model.fsKindSeen), token: host.fsUpdateToken(),
      dismissedFor: defaults.string(forKey: DeckFs.promoKey(host, "updateDismissed")),
      shownFor: defaults.string(forKey: DeckFs.promoKey(host, "updateShown")),
      shownThisLaunch: DeckFs.shownThisLaunch.contains(host.id + "#update"))
  }

  private var banner: DeckFsPromoRules.Banner {
    let defaults = UserDefaults.standard
    guard host.paired, host.softwareKnown else { return .none }
    return DeckFsPromoRules.banner(host.software,
                                   dismissed: defaults.bool(forKey: DeckFs.promoKey(host, "dismissed")),
                                   shownBefore: defaults.bool(forKey: DeckFs.promoKey(host, "shown")),
                                   shownThisLaunch: DeckFs.shownThisLaunch.contains(host.id))
  }

  private var text: String {
    switch banner {
    case .windows:
      let name: String
      switch host.software.kind {
      case .gfe: name = DL("deck.software.gfe")
      case .compatible: name = DL("deck.software.compatibleShort")
      default: name = DL("deck.software.sunshineShort")
      }
      return DLf("deck.fs.banner.windows", name)
    case .ifWindows: return DL("deck.fs.banner.ifWindows")
    case .none: return ""
    }
  }

  var body: some View {
    let _ = tick
    #if MLC_CONCEPT_HARNESS
    if conceptEnv("MLC_BANNERLOG") != nil {
      let _ = fputs("BANNER paired=\(host.paired) known=\(host.softwareKnown) state=\(host.facts.serverState) fs=\(host.isFoundation) windows=\(host.software.windows) banner=\(banner) update=\(updateShown) dismissed=\(UserDefaults.standard.bool(forKey: DeckFs.promoKey(host, "dismissed"))) shown=\(UserDefaults.standard.bool(forKey: DeckFs.promoKey(host, "shown"))) thisLaunch=\(DeckFs.shownThisLaunch.contains(host.id)) id=\(host.id)\n", stderr)
    }
    #endif
    Group {
    if updateShown {
      bar(text: DL("deck.fs.update.banner"), primary: DL("deck.fs.update.learn"), action: { DeckFs.learnUpdate() }, dismiss: {
        UserDefaults.standard.set(host.fsUpdateToken(), forKey: DeckFs.promoKey(host, "updateDismissed"))
      }, appeared: {
        DeckFs.shownThisLaunch.insert(host.id + "#update")
        UserDefaults.standard.set(host.fsUpdateToken(), forKey: DeckFs.promoKey(host, "updateShown"))
      })
    } else if banner != .none {
      bar(text: text, primary: DL("deck.fs.learnFull"), action: { DeckFs.learn() }, dismiss: {
        UserDefaults.standard.set(true, forKey: DeckFs.promoKey(host, "dismissed"))
      }, appeared: {
        // shown: remembered, so it does not come back on a later launch (it stays on this page until dismissed)
        DeckFs.shownThisLaunch.insert(host.id)
        if !UserDefaults.standard.bool(forKey: DeckFs.promoKey(host, "shown")) { UserDefaults.standard.set(true, forKey: DeckFs.promoKey(host, "shown")) }
      })
    }
    }
    .onReceive(NotificationCenter.default.publisher(for: .init("HostLatencyUpdated"))) { _ in tick += 1 }
    .onReceive(NotificationCenter.default.publisher(for: .init("MLDeckHostsChanged"))) { _ in tick += 1 }
  }

  private func bar(text: String, primary: String, action: @escaping () -> Void, dismiss: @escaping () -> Void, appeared: @escaping () -> Void) -> some View {
    VStack {
      HStack(alignment: .center, spacing: 14) {
        Image(systemName: "sun.max.fill").font(.system(size: 18, weight: .semibold)).foregroundStyle(.secondary)
        Text(text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
        Button(primary, action: action).controlSize(.regular)
        Button(DL("deck.fs.dismiss")) { dismiss(); tick += 1 }.controllerButtonStyle(.borderless).foregroundStyle(.secondary).controlSize(.regular)
      }
      .padding(.horizontal, 14).padding(.vertical, 11)
      .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 0.5))
      .frame(maxWidth: 760, alignment: .leading)
      .onAppear(perform: appeared)
    }
  }
}

/// 主机信息 on a computer without Foundation Sunshine: what Foundation Sunshine adds, greyed, with the reason.
@available(macOS 14.0, *)
struct DeckFsFeatureGroup: View {
  let host: DeckHost
  var body: some View {
    if host.softwareKnown && !host.isFoundation {
      VStack(alignment: .leading, spacing: 8) {
        Text(DL("deck.fs.group")).font(.system(size: 13, weight: .semibold)).padding(.leading, 10)
        VStack(spacing: 0) {
          ForEach(Array(DeckFs.features.enumerated()), id: \.offset) { index, feature in
            HStack {
              Label(DL(feature.key), systemImage: feature.symbol)
              Spacer(minLength: 16)
              Text(DeckFs.requirement(host))
            }
            .font(.system(size: 13)).foregroundStyle(.tertiary)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .overlay(alignment: .bottom) { if index < DeckFs.features.count - 1 { Divider().padding(.leading, 12) } }
            .accessibilityElement(children: .combine)
          }
        }
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 0.5))
      }
    }
  }
}

/// The 主机软件 value with its 了解 link (the link is only there when Foundation Sunshine is an option for this computer).
@available(macOS 14.0, *)
struct DeckSoftwareValue: View {
  let host: DeckHost
  var kindSeen: Bool?
  var body: some View {
    HStack(spacing: 8) {
      Text(DeckFs.softwareText(host)).deckHelp(DeckFs.softwareDetail(host))
      if host.fsUpdateReason(kindSeen: kindSeen) != nil {
        // always there while the host is behind, whether or not the banner was dismissed
        Button(DL("deck.fs.update.mark")) { DeckFs.learnUpdate() }
          .controllerButtonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.accentColor)
          .padding(.horizontal, 7).padding(.vertical, 2)
          .background(Capsule().fill(Color.accentColor.opacity(0.14)))
          .deckHelp(DL("deck.fs.update.tip"))
      }
      if DeckFsPromoRules.recommends(host.software) {
        Button(DL("deck.fs.learn")) { DeckFs.learn() }.controllerButtonStyle(.borderless).foregroundStyle(Color.accentColor)
      }
    }
  }
}


@available(macOS 14.0, *)
extension DeckAppsModel {
  /// Whether any app of this computer carries FsKind. nil until the app list has been read.
  var fsKindSeen: Bool? {
    apps.isEmpty ? nil : apps.contains { !($0.fsExtras["FsKind"] ?? "").isEmpty }
  }
}


/// A status mark at the trailing end of a sidebar row (running, nearby and unpaired ...). On the selected row's accent fill it
/// sits on a white disc so orange and green stay legible on blue.
@available(macOS 14.0, *)
struct DeckRowBadge: View {
  let symbol: String
  let tint: Color
  /// The row is the selected one. No backplate and no ring in either appearance (a white disc reads as a white ring in dark
  /// mode, a palette symbol as one in light). The mark keeps itself legible on the accent fill and on the grey selection by
  /// its own colour: a deep, saturated disc with a white glyph, or plain white for a glyph that has no disc of its own.
  var onAccent = false
  /// Deep variants of the two status colours used on the selected row (the pale dark-mode green is not legible on blue).
  static func deep(_ color: Color) -> Color {
    color == .green ? Color(red: 28 / 255, green: 128 / 255, blue: 58 / 255)
      : (color == .orange ? Color(red: 176 / 255, green: 88 / 255, blue: 0) : color)
  }
  var body: some View {
    if symbol.hasSuffix(".circle.fill") {
      // A disc drawn as a shape with the glyph cut out in white. An SF Symbol in palette mode inside a selected list row is
      // re-coloured by the list (a light-mode row showed a white ring around the mark); a shape is not.
      Circle().fill(onAccent ? Self.deep(tint) : tint)
        .frame(width: 15, height: 15)
        .overlay {
          Image(systemName: String(symbol.dropLast(".circle.fill".count)) + ".fill")
            .font(.system(size: 7, weight: .bold)).foregroundColor(.white).offset(x: 0.5)
        }
    } else if onAccent {
      Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.white)
    } else {
      Image(systemName: symbol).foregroundStyle(tint)
    }
  }
}


/// The decision of the page's app-list timer, for Objective-C (DeckAppListRules is the rule and is tested on its own).
@objc(MLDeckAppListTick)
public final class DeckAppListTick: NSObject {
  @objc public static func reason(online: Bool, wasOnline: Bool, seenEtag: String, fetchedEtag: String, lastFetch: Date?) -> String {
    DeckAppListRules.due(online: online, wasOnline: wasOnline, seenEtag: seenEtag, fetchedEtag: fetchedEtag, lastFetch: lastFetch, now: Date())?.rawValue ?? ""
  }
}
