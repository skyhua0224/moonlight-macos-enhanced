//
//  DeckRules.swift
//  Pure rules of the computer page. Foundation only, so tests/deck-rules compiles it on its own.
//    - DeckTimeRules   a missing or zero timestamp is "unknown", never 1970 ("上次玩 56 年前")
//    - DeckArtRules    how a picture is drawn in a 16:9 card, from its decoded size
//    - DeckEndpoint / DeckAddressBook   the one list of addresses (名称 host:port) behind 地址 and 线路
//    - DeckPathClassifier   what path an address is, in the vocabulary of the platform's network.reachability slot
//
//  The path vocabulary is the one of alkaidlab-platform sdk/c/include/alkaidlab/network_reachability/reachability_slot.h:
//  AlkNetAddressClass (where the address is: PRIVATE_LAN, OVERLAY_PRIVATE, PUBLIC) is kept apart from AlkNetPathClass
//  (how the traffic gets there: LAN, PUBLIC_DIRECT, PUBLIC_FORWARD, OVERLAY_ROUTE, RELAY) and AlkNetConfidence. The
//  path is decided by evidence; the shape of the address is only a hint, so a relay server on a public IP is not
//  "direct". RELAY maps to the RFC 8445 candidate type RELAY of session_core.h, the others to HOST / SERVER_REFLEXIVE.
//

import Foundation

// MARK: - Time

enum DeckTimeRules {
  /// Nothing real happened before this; a zero or tiny epoch value means "not recorded".
  static let earliest = Date(timeIntervalSince1970: 946_684_800)   // 2000-01-01

  /// The date when it can be real, nil when it is missing, zero (1970) or from the future.
  static func valid(_ date: Date?, now: Date = Date()) -> Date? {
    guard let date, date >= earliest, date <= now.addingTimeInterval(24 * 3600) else { return nil }
    return date
  }

  static func fromEpoch(_ seconds: Double?, now: Date = Date()) -> Date? {
    guard let seconds, seconds.isFinite else { return nil }
    return valid(Date(timeIntervalSince1970: seconds), now: now)
  }
}

// MARK: - Art

enum DeckArtRules {
  enum Treatment: Equatable {
    /// aspect-fill, cropped, nothing behind it
    case fill
    /// the picture centred on a blurred, enlarged copy of itself
    case centredOnBlur
  }

  /// A picture that is already landscape (Steam's header.jpg is about 460x215, 2.14:1; a 16:9 card is 1.78:1) fills the
  /// card. Only a portrait or square picture is shown small on a blurred background. Read from the decoded size.
  static let landscapeAtLeast = 1.4

  static func treatment(width: Double, height: Double) -> Treatment {
    guard width > 0, height > 0 else { return .centredOnBlur }
    return width / height >= landscapeAtLeast ? .fill : .centredOnBlur
  }
}

// MARK: - Endpoints

struct DeckEndpoint: Hashable {
  /// lowercased, no trailing dot, no brackets
  let host: String
  let port: Int

  static let defaultPort = 47989
  static let standardPorts: Set<Int> = [47989, 47984]

  var isIPv6: Bool { host.contains(":") }
  var isIPv4: Bool {
    let parts = host.split(separator: ".", omittingEmptySubsequences: false)
    return parts.count == 4 && parts.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
  }
  var isDomain: Bool { !isIPv4 && !isIPv6 }
  var isLocalName: Bool { host.hasSuffix(".local") }
  /// host:port, IPv6 as [addr]:port; the port is always there
  var display: String { isIPv6 ? "[\(host)]:\(port)" : "\(host):\(port)" }
  var key: String { display }
  var hasCustomPort: Bool { !DeckEndpoint.standardPorts.contains(port) }

  /// "host", "host:port", "[v6]:port", "v6" (bare, several colons). A missing port is 47989.
  static func parse(_ raw: String, defaultPort: Int = DeckEndpoint.defaultPort) -> DeckEndpoint? {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    var host = text
    var port = defaultPort
    if text.hasPrefix("[") {
      guard let close = text.firstIndex(of: "]") else { return nil }
      host = String(text[text.index(after: text.startIndex)..<close])
      let rest = String(text[text.index(after: close)...])
      if rest.hasPrefix(":") {
        guard let value = Int(rest.dropFirst()), (1...65535).contains(value) else { return nil }
        port = value
      } else if !rest.isEmpty { return nil }
    } else if text.filter({ $0 == ":" }).count == 1, let colon = text.firstIndex(of: ":") {
      host = String(text[..<colon])
      guard let value = Int(text[text.index(after: colon)...]), (1...65535).contains(value) else { return nil }
      port = value
    } else if text.filter({ $0 == ":" }).count > 1 {
      host = text   // a bare IPv6 address
    }
    text = host
    // a scope id (%en0) is not part of the identity
    if let zone = host.firstIndex(of: "%") { host = String(host[..<zone]) }
    host = host.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
    guard !host.isEmpty, !host.contains(" "), !host.contains("/") else { return nil }
    return DeckEndpoint(host: host, port: port)
  }
}

enum DeckEndpointSource: Int, Comparable {
  /// the fields every computer record has (本地, 外部, IPv6, 主地址)
  case preset = 0
  /// added by the user, kept in ConnectionEndpointStore
  case manual = 1
  /// came up during discovery (the address in use, a name mDNS or a probe reported)
  case discovered = 2
  static func < (a: DeckEndpointSource, b: DeckEndpointSource) -> Bool { a.rawValue < b.rawValue }
}

struct DeckEndpointEntry: Equatable {
  var endpoint: DeckEndpoint
  var sources: Set<DeckEndpointSource>
  /// the strings under which discovery's dictionaries know it (for the lookup of results)
  var raws: [String]
  var isManual: Bool { sources.contains(.manual) }
  /// Only an address the user added can be removed; the computer's own fields cannot.
  var deletable: Bool { isManual }
}

enum DeckAddressBook {
  /// The one list: preset fields, saved manual endpoints, and what discovery found, each address once, keyed by host AND port
  /// (the same host on two ports is two entries; a name and its IP are two entries; IPv6 keeps its brackets).
  static func merge(preset: [String?], manual: [String], discovered: [String], disabled: Set<String> = []) -> [DeckEndpointEntry] {
    var order: [DeckEndpoint] = []
    var table: [DeckEndpoint: DeckEndpointEntry] = [:]
    func add(_ raw: String?, _ source: DeckEndpointSource) {
      guard let raw, let endpoint = DeckEndpoint.parse(raw) else { return }
      if disabled.contains(endpoint.key) && source != .manual { return }
      if var entry = table[endpoint] {
        entry.sources.insert(source)
        if !entry.raws.contains(raw) { entry.raws.append(raw) }
        table[endpoint] = entry
      } else {
        order.append(endpoint)
        table[endpoint] = DeckEndpointEntry(endpoint: endpoint, sources: [source], raws: [raw])
      }
    }
    for raw in preset { add(raw, .preset) }
    for raw in manual { add(raw, .manual) }
    for raw in discovered { add(raw, .discovered) }
    return order.compactMap { table[$0] }
  }

  /// A value of discovery's dictionaries (keyed by its own strings, with or without port) for an endpoint: the entry with
  /// the same host AND port; a key with no port is the default port.
  static func lookup<T>(_ dict: [String: T]?, _ entry: DeckEndpointEntry) -> T? {
    guard let dict else { return nil }
    for raw in entry.raws { if let hit = dict[raw] { return hit } }
    for (key, value) in dict where DeckEndpoint.parse(key) == entry.endpoint { return value }
    return nil
  }
}

// MARK: - Path classification (alkaidlab-platform network.reachability vocabulary)

enum DeckAddressClass: Int { case unknown = 0, privateLAN = 1, overlayPrivate = 2, publicAddress = 3 }
enum DeckPathClass: Int { case unknown = 0, lan = 1, publicDirect = 2, publicForward = 3, overlayRoute = 4, relay = 5 }
enum DeckConfidence: Int { case low = 0, medium = 1, high = 2 }

/// What the user said about an address when adding it. Wins over every guess.
enum DeckDeclaredPath: String, CaseIterable {
  case host        // the computer itself (its own address: LAN or public IP)
  case forward     // a port forward / UPnP mapping to it
  case relay       // a relay / forwarding server in between
  case overlay     // a VPN / mesh (WireGuard, Tailscale ...)
}

enum DeckEvidence: Equatable {
  case userDeclared
  case relayReported                         // we or the host say the traffic goes through a relay
  case tunnelInterface                       // the egress interface is a tunnel (utun, TUN)
  case proxyTunnel                           // a public address reached through a TUN whose own address is in 198.18.0.0/15 (fake-IP proxy)
  case overlayRange                          // 100.64.0.0/10 and similar
  case matchesHostPublicIP(ip: String)       // resolves to the public IP the host reports, on a custom port / UPnP
  case hostOwnsPublicAddress(ip: String)     // the address is configured on the host's NIC
  case ipv6Global                            // a global IPv6 literal
  case physicalPrivateFast(rttMs: Int)       // private address, physical egress, LAN-like RTT
  case none
}

struct DeckPathVerdict: Equatable {
  var addressClass: DeckAddressClass
  var pathClass: DeckPathClass
  var confidence: DeckConfidence
  var evidence: DeckEvidence
  /// a domain that did not resolve, or an address never tested
  var untested: Bool
  var resolvedIPs: [String]

  var isConfirmed: Bool { pathClass != .unknown }
}

/// Everything the decision may look at. Nothing here is guessed by the classifier.
struct DeckPathFacts {
  var endpoint: DeckEndpoint
  /// what the name resolves to (empty for an IP literal, or nil when not resolved yet)
  var resolvedIPs: [String]? = nil
  /// the public IP the computer reports for itself (STUN / IGD / serverinfo ExternalIP)
  var hostPublicIP: String? = nil
  /// addresses configured on the computer's own NICs, when it says
  var hostInterfaceIPs: [String] = []
  /// the egress interface of the probe: true tunnel, false physical, nil unknown
  var egressIsTunnel: Bool? = nil
  /// the IPv4 address of the egress interface, kept only for a tunnel (a capture-all proxy TUN has an address in 198.18.0.0/15)
  var egressSourceIPv4: String? = nil
  /// true when we or the computer know the traffic is relayed (Tailscale DERP, TURN, a relay we allocated), nil unknown
  var relayReported: Bool? = nil
  var rttMs: Int? = nil
  var upnpMappingRecorded = false
  var declared: DeckDeclaredPath? = nil
  var tested = false
  /// extra overlay ranges a deployment declares (IPv4 prefix, mask in host byte order)
  var overlayRanges: [(prefix: UInt32, mask: UInt32)] = []
}

enum DeckPathClassifier {
  static func ipv4(_ text: String) -> UInt32? {
    let parts = text.split(separator: ".", omittingEmptySubsequences: false).compactMap { UInt32($0) }
    guard parts.count == 4, parts.allSatisfy({ $0 <= 255 }) else { return nil }
    return parts[0] << 24 | parts[1] << 16 | parts[2] << 8 | parts[3]
  }

  /// Where the address lives (the AlkNetAddressClass): RFC 1918, link-local, fc00::/7, loopback = private LAN;
  /// 100.64.0.0/10 (RFC 6598) = overlay private; everything else public.
  static func addressClass(_ ip: String, overlayRanges: [(prefix: UInt32, mask: UInt32)] = []) -> DeckAddressClass {
    let text = ip.lowercased()
    if text.contains(":") {
      if text.hasPrefix("fe80") || text.hasPrefix("fc") || text.hasPrefix("fd") || text == "::1" { return .privateLAN }
      if text.hasPrefix("fd7a:115c:a1e0") { return .overlayPrivate }   // Tailscale's ULA
      return .publicAddress
    }
    guard let v4 = ipv4(text) else { return .unknown }
    if (v4 & 0xFFC0_0000) == 0x6440_0000 { return .overlayPrivate }
    for range in overlayRanges where (v4 & range.mask) == range.prefix { return .overlayPrivate }
    if (v4 & 0xFF00_0000) == 0x0A00_0000 || (v4 & 0xFFF0_0000) == 0xAC10_0000 || (v4 & 0xFFFF_0000) == 0xC0A8_0000
        || (v4 & 0xFFFF_0000) == 0xA9FE_0000 || (v4 & 0xFF00_0000) == 0x7F00_0000 { return .privateLAN }
    return .publicAddress
  }

  static func classify(_ facts: DeckPathFacts) -> DeckPathVerdict {
    let endpoint = facts.endpoint
    // the IPs the traffic is aimed at: the literal, or what the name resolves to
    let ips: [String] = endpoint.isDomain ? (facts.resolvedIPs ?? []) : [endpoint.host]
    let primary = ips.first
    let addressClass = primary.map { classifyAddress($0, facts) } ?? .unknown
    func verdict(_ path: DeckPathClass, _ confidence: DeckConfidence, _ evidence: DeckEvidence) -> DeckPathVerdict {
      DeckPathVerdict(addressClass: addressClass, pathClass: path, confidence: confidence, evidence: evidence,
                      untested: facts.declared == nil && !facts.tested && endpoint.isDomain && facts.resolvedIPs == nil, resolvedIPs: ips)
    }

    // 1. the user's word
    if let declared = facts.declared {
      switch declared {
      case .host: return verdict(addressClass == .privateLAN ? .lan : (addressClass == .overlayPrivate ? .overlayRoute : .publicDirect), .high, .userDeclared)
      case .forward: return verdict(.publicForward, .high, .userDeclared)
      case .relay: return verdict(.relay, .high, .userDeclared)
      case .overlay: return verdict(.overlayRoute, .high, .userDeclared)
      }
    }
    // 2. a relay is a relay whatever IP it has
    if facts.relayReported == true { return verdict(.relay, .high, .relayReported) }
    // 3. overlay: a tunnel interface, or an address in an overlay range
    if facts.egressIsTunnel == true {
      // 经代理: a PUBLIC address through a fake-IP TUN. A private address through a TUN is the user's own 组网, not a proxy.
      if addressClass == .publicAddress, DeckNic.isFakeIP(facts.egressSourceIPv4) { return verdict(.overlayRoute, .high, .proxyTunnel) }
      return verdict(.overlayRoute, .high, .tunnelInterface)
    }
    if addressClass == .overlayPrivate { return verdict(.overlayRoute, .medium, .overlayRange) }
    // 4. a public IP: what is behind it is decided by what the computer says about itself
    if addressClass == .publicAddress, let ip = primary {
      if ip.contains(":") {
        // a global IPv6 address is the computer's own (no NAT) unless something says otherwise
        return verdict(.publicDirect, .medium, .ipv6Global)
      }
      if let host = facts.hostPublicIP, host == ip, endpoint.hasCustomPort || facts.upnpMappingRecorded {
        return verdict(.publicForward, endpoint.hasCustomPort && facts.upnpMappingRecorded ? .high : .medium, .matchesHostPublicIP(ip: ip))
      }
      if facts.hostInterfaceIPs.contains(ip) { return verdict(.publicDirect, .high, .hostOwnsPublicAddress(ip: ip)) }
      return verdict(.unknown, .low, .none)   // 公网 · 未确认
    }
    // 5. a private address: LAN only when the egress is physical and the round trip looks like a LAN
    if addressClass == .privateLAN {
      if facts.egressIsTunnel == false, let rtt = facts.rttMs, rtt <= 40 { return verdict(.lan, .high, .physicalPrivateFast(rttMs: rtt)) }
      if facts.egressIsTunnel == nil, let rtt = facts.rttMs, rtt <= 40 { return verdict(.lan, .medium, .physicalPrivateFast(rttMs: rtt)) }
      return verdict(.unknown, .low, .none)
    }
    return verdict(.unknown, .low, .none)
  }

  private static func classifyAddress(_ ip: String, _ facts: DeckPathFacts) -> DeckAddressClass {
    addressClass(ip, overlayRanges: facts.overlayRanges)
  }
}

/// The words of 地址 rows and 线路 chips. A path that evidence has settled is named by its class: 局域网, 公网直连, 端口转发, 组网,
/// 中转. An address with no evidence is not given a class (and no "unconfirmed" word is ever shown): it is named by what the
/// address itself is: IP, 域名, or 内网.
enum DeckPathWords {
  enum Word: Equatable {
    case lan, publicDirect, publicForward, overlay, relay
    /// a public address through a fake-IP proxy TUN (the word is 经代理)
    case proxy
    /// no evidence about the path: the nature of the address itself
    case ip, domain, privateAddress
  }

  static func word(_ verdict: DeckPathVerdict, _ endpoint: DeckEndpoint) -> Word {
    switch verdict.pathClass {
    case .lan: return .lan
    case .publicDirect: return .publicDirect
    case .publicForward: return .publicForward
    case .overlayRoute: return verdict.evidence == .proxyTunnel ? .proxy : .overlay
    case .relay: return .relay
    case .unknown:
      if endpoint.isDomain { return endpoint.isLocalName ? .privateAddress : .domain }
      return verdict.addressClass == .privateLAN || verdict.addressClass == .overlayPrivate ? .privateAddress : .ip
    }
  }

  /// The group a 线路 chip stands for: by PATH class; addresses with no evidence group by what they are.
  static func chipGroup(_ verdict: DeckPathVerdict, _ endpoint: DeckEndpoint) -> Int {
    switch word(verdict, endpoint) {
    case .lan: return 1
    case .publicDirect: return 2
    case .publicForward: return 3
    case .overlay: return 4
    case .proxy: return 6
    case .relay: return 5
    case .ip: return 100
    case .domain: return 101
    case .privateAddress: return 102
    }
  }
}

extension DeckEndpoint {
  /// host:port with a long host cut in the middle ("gaming-pc.exa…example.net:57989"); the port always stays.
  func shortDisplay(maxHostLength: Int = 28) -> String {
    guard host.count > maxHostLength, maxHostLength > 6 else { return display }
    let keepFront = (maxHostLength - 1) / 2 + (maxHostLength - 1) % 2
    let keepBack = (maxHostLength - 1) / 2
    let cut = String(host.prefix(keepFront)) + "…" + String(host.suffix(keepBack))
    return isIPv6 ? "[\(cut)]:\(port)" : "\(cut):\(port)"
  }
}

/// The chips: one per path group, in a fixed order, with the endpoints of that group.
struct DeckChipGroup: Equatable {
  var word: DeckPathWords.Word
  var group: Int
  var endpoints: [DeckEndpoint]
}

enum DeckChipBuilder {
  static func groups(_ items: [(endpoint: DeckEndpoint, verdict: DeckPathVerdict)]) -> [DeckChipGroup] {
    var order: [Int] = []
    var members: [Int: [(DeckEndpoint, DeckPathVerdict)]] = [:]
    for item in items {
      let g = DeckPathWords.chipGroup(item.verdict, item.endpoint)
      if members[g] == nil { order.append(g) }
      members[g, default: []].append((item.endpoint, item.verdict))
    }
    order.sort()
    return order.map { g in
      let list = members[g] ?? []
      return DeckChipGroup(word: DeckPathWords.word(list[0].1, list[0].0), group: g, endpoints: list.map { $0.0 })
    }
  }

  /// What a chip shows of its group: the address in use, else the one with the lowest latency, else the first; "+N" for the rest.
  static func shown(_ group: DeckChipGroup, inUse: DeckEndpoint?, latency: (DeckEndpoint) -> Int?) -> (endpoint: DeckEndpoint, more: Int) {
    let pick: DeckEndpoint
    if let inUse, group.endpoints.contains(inUse) { pick = inUse }
    else if let best = group.endpoints.compactMap({ e in latency(e).map { (e, $0) } }).min(by: { $0.1 < $1.1 }) { pick = best.0 }
    else { pick = group.endpoints[0] }
    return (pick, group.endpoints.count - 1)
  }
}


// MARK: - Latency figures

/// A latency that may be shown. -1 and -2 are internal answers ("reachable, no number", "could not measure"), never numbers.
enum DeckLatencyRules {
  static func valid(_ ms: Int?) -> Int? {
    guard let ms, ms >= 1 else { return nil }
    return ms
  }
}

// MARK: - 网卡 (the network interface a computer's stream is pinned to)

/// The rules of the per-computer 网卡 choice (Enhanced keeps the minimum: a choice, the list it is made from, the words, 经代理).
/// Pure: the enumeration of the machine's interfaces is HostNics (HostPathPresence.swift).
enum DeckNic {
  enum Kind: Equatable { case wifi, ethernet, tunnel }

  /// One interface as the system reports it.
  struct Raw {
    var name: String
    var index: UInt32
    var up: Bool
    var running: Bool
    var ipv4: String?
    var isWifi: Bool
  }

  struct Interface: Equatable {
    var name: String
    var index: UInt32
    var kind: Kind
    var ipv4: String?
  }

  /// What the saved word means against today's list.
  enum Choice: Equatable {
    case automatic
    case interface(Interface)
    /// the saved interface is not there now (unplugged, Wi-Fi off): shown as chosen and unavailable, never swapped for another
    case missing(String)
  }

  /// Physical interfaces (en*) that are up and have an IPv4 address that is not link-local, and tunnels (utun, tun, ipsec, ppp)
  /// that are up and carry an IPv4 address (the system's own utun0-3 have only a link-local IPv6 one, so they are not listed).
  /// Physical first, then tunnels, each by name with numbers in numeric order (en1 before en10).
  static func interfaces(_ raw: [Raw]) -> [Interface] {
    var list: [Interface] = []
    for item in raw where item.up && item.running && item.index != 0 {
      guard let v4 = item.ipv4, !v4.isEmpty, !v4.hasPrefix("169.254.") else { continue }
      if item.name.hasPrefix("en") {
        list.append(Interface(name: item.name, index: item.index, kind: item.isWifi ? .wifi : .ethernet, ipv4: v4))
      } else if ["utun", "tun", "ipsec", "ppp"].contains(where: { item.name.hasPrefix($0) }) {
        list.append(Interface(name: item.name, index: item.index, kind: .tunnel, ipv4: v4))
      }
    }
    return list.sorted { a, b in
      if (a.kind == .tunnel) != (b.kind == .tunnel) { return b.kind == .tunnel }
      return a.name.compare(b.name, options: .numeric) == .orderedAscending
    }
  }

  /// 「Wi-Fi en0 · 192.0.2.12」, 「以太网 en5 · 192.0.2.8」, 「隧道 utun10」: type word, name, and the IPv4 of a physical interface.
  static func label(_ interface: Interface, kindWord: String) -> String {
    var text = kindWord + " " + interface.name
    if interface.kind != .tunnel, let v4 = interface.ipv4, !v4.isEmpty { text += " · " + v4 }
    return text
  }

  static func choice(saved: String?, in list: [Interface]) -> Choice {
    guard let saved, !saved.isEmpty, saved != "Auto" else { return .automatic }
    if let hit = list.first(where: { $0.name == saved }) { return .interface(hit) }
    return .missing(saved)
  }

  /// 198.18.0.0/15 (RFC 2544 benchmarking range, RFC 6890): the range a fake-IP proxy hands its TUN, so an address of it on a
  /// tunnel is evidence of a capture-all proxy. Evidence only; it does not prove a VPN.
  static func isFakeIP(_ ipv4: String?) -> Bool {
    guard let ipv4, let v4 = DeckPathClassifier.ipv4(ipv4) else { return false }
    return (v4 & 0xFFFE_0000) == 0xC612_0000
  }
}

// MARK: - Host software (what is running on the other computer) and the Foundation Sunshine recommendation

/// What /serverinfo lets the client say about the software on the other side, and nothing more.
///
/// Facts (host source read 2026-11-11; Sunshine docs: `GFE_VERSION` "identifies the GameStream version Sunshine imitates", 3.23.0.74):
///  - Foundation Sunshine sends FsCapabilityVersion / VddCapabilityVersion and `SunshineVersion` ("<name> <version>").
///  - Sunshine (and forks) send `GfeVersion` = the constant 3.23.0.74 and `state` = SUNSHINE_SERVER_FREE|BUSY. So a GfeVersion
///    on its own is NOT evidence of GeForce Experience.
///  - GeForce Experience sends `state` = MJOLNIR_STATE_SERVER_AVAILABLE|BUSY and its real GfeVersion; it exists on Windows only.
///  - No field of /serverinfo names the operating system of a non-Foundation host (FsPlatform is Foundation-only).
/// Nothing here invents a version.
enum DeckHostSoftware {
  enum Kind: Equatable {
    case foundation(version: String)
    case sunshine(version: String)
    case gfe(version: String)
    case compatible
  }
  enum Windows: Equatable { case yes, no, unknown }

  struct Info: Equatable {
    var kind: Kind
    var windows: Windows
    /// The version string as the host sent it ("2026.1112.025657.杂鱼", "manual-20261112-025657-dev"), for the hover text.
    /// `kind` carries only the short form.
    var fullVersion = ""
    var isFoundation: Bool { if case .foundation = kind { return true } else { return false } }
  }

  /// Where the version starts in what the host sent: the first word that begins with a digit (after a leading v), else the
  /// last word if it has a digit in it. "Sunshine 2026.1112.025657.杂鱼" -> "2026.1112.025657.杂鱼"; "v0.23.1" -> "0.23.1";
  /// "manual-20261112-025657" stays whole; "Sunshine", "杂鱼" and "" -> "". The product word is never part of it.
  static func fullVersion(_ raw: String) -> String {
    let words = raw.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    func stripped(_ w: String) -> String {
      let rest = w.dropFirst()
      return (w.hasPrefix("v") || w.hasPrefix("V")) && rest.first?.isASCII == true && rest.first?.isNumber == true ? String(rest) : w
    }
    guard let last = words.last else { return "" }
    if let i = words.firstIndex(where: { stripped($0).first?.isASCII == true && stripped($0).first?.isNumber == true }) {
      return ([stripped(words[i])] + words[(i + 1)...]).joined(separator: " ")
    }
    // no word begins with a digit: a build tag such as "manual-20261112-025657" is kept for the hover text, a bare word
    // ("Sunshine", "杂鱼") is not a version
    return last.contains(where: { $0.isASCII && $0.isNumber }) ? stripped(last) : ""
  }

  /// The version as shown: its first `maxParts` numeric parts, nothing after them. The date builds of Foundation Sunshine are
  /// `YYYY.MDD.HMMSS` plus optional suffixes (".杂鱼", ".<commit>", a dirty mark): "2026.1112.025657.杂鱼" -> "2026.1112.025657",
  /// "Sunshine 2026.823.50647.970e0298b" -> "2026.823.50647", "v0.23.1" -> "0.23.1". A version that does not begin with a digit
  /// ("manual-20261112-025657", "杂鱼", "") shows nothing: a version is never invented. GeForce Experience's own four-part
  /// version is kept whole by its caller (maxParts 4). Suffixes only appear in the hover text (`fullVersion`).
  static func versionNumber(_ raw: String, maxParts: Int = 3) -> String {
    let token = fullVersion(raw).split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
    guard token.first?.isASCII == true, token.first?.isNumber == true else { return "" }
    var parts: [Substring] = []
    for part in token.split(separator: ".", omittingEmptySubsequences: false) {
      guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }) else { break }
      parts.append(part)
      if parts.count == maxParts { break }
    }
    return parts.joined(separator: ".")
  }

  /// The one rule for "this host is Foundation Sunshine": FsCapabilityVersion or VddCapabilityVersion above 0, read as the
  /// plain integers they are (a missing, empty, non-numeric or 0 tag does not count). DeckHost, the facts store and the
  /// stream manager all use it, so the page and the stream never disagree.
  static func isFoundation(fsCapability: Int, vddCapability: Int) -> Bool { fsCapability > 0 || vddCapability > 0 }
  static func isFoundation(fsCapability: String?, vddCapability: String?) -> Bool {
    func number(_ text: String?) -> Int { Int((text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 }
    return isFoundation(fsCapability: number(fsCapability), vddCapability: number(vddCapability))
  }

  /// `state` is the serverinfo state tag ("SUNSHINE_SERVER_FREE", "MJOLNIR_STATE_SERVER_AVAILABLE"); only its family counts.
  static func classify(isFoundation: Bool, sunshineVersion: String, gfeVersion: String, state: String, platform: String) -> Info {
    let family = state.uppercased()
    let platformWords = platform.lowercased()
    let osKnown: Windows = platformWords.isEmpty ? .unknown : (platformWords.contains("win") ? .yes : .no)
    if isFoundation {
      return Info(kind: .foundation(version: versionNumber(sunshineVersion)), windows: .yes, fullVersion: fullVersion(sunshineVersion))
    }
    if family.hasPrefix("MJOLNIR") {
      return Info(kind: .gfe(version: versionNumber(gfeVersion, maxParts: 4)), windows: .yes, fullVersion: fullVersion(gfeVersion))
    }
    if family.hasPrefix("SUNSHINE") || !sunshineVersion.isEmpty {
      return Info(kind: .sunshine(version: versionNumber(sunshineVersion)), windows: osKnown, fullVersion: fullVersion(sunshineVersion))
    }
    return Info(kind: .compatible, windows: osKnown)
  }

  /// The row text. Unknown stays unknown: a version is only shown when the host sent one.
  /// `names` carries the localised words so the rules stay free of the language layer.
  struct Names { var foundation = "Foundation Sunshine", sunshine = "Sunshine", gfe = "GeForce Experience", compatible = "GameStream" }
  static func title(_ info: Info, names: Names) -> String {
    func join(_ name: String, _ version: String) -> String { version.isEmpty ? name : "\(name) \(version)" }
    switch info.kind {
    case .foundation(let v): return join(names.foundation, v)
    case .sunshine(let v): return join(names.sunshine, v)
    case .gfe(let v): return join(names.gfe, v)
    case .compatible: return names.compatible
    }
  }

  /// The hover text: the title with the version string the host sent, suffixes and all. Equal to the title when there is
  /// nothing more to say.
  static func detail(_ info: Info, names: Names) -> String {
    let short = title(info, names: names)
    guard !info.fullVersion.isEmpty else { return short }
    let name: String
    switch info.kind {
    case .foundation: name = names.foundation
    case .sunshine: name = names.sunshine
    case .gfe: name = names.gfe
    case .compatible: return short
    }
    return "\(name) \(info.fullVersion)"
  }
}

/// When the one-time recommendation banner shows on a computer's page.
enum DeckFsPromoRules {
  enum Banner: Equatable {
    case none
    /// The computer is Windows (or GeForce Experience): the plain text.
    case windows
    /// Cannot tell the operating system: the text says "if this computer is Windows".
    case ifWindows
  }

  /// - dismissed: 「不再提示」 was chosen for this computer.
  /// - shownBefore: the banner was shown on an earlier launch of the app (at most once per computer: it does not come back).
  /// - shownThisLaunch: it was shown during this launch (it stays until dismissed or the app quits, so it does not vanish on a reload).
  static func banner(_ info: DeckHostSoftware.Info, dismissed: Bool, shownBefore: Bool, shownThisLaunch: Bool) -> Banner {
    if info.isFoundation || dismissed { return .none }
    if shownBefore && !shownThisLaunch { return .none }
    switch info.windows {
    case .yes: return .windows
    case .no: return .none
    case .unknown: return .ifWindows
    }
  }

  /// Foundation Sunshine only runs on Windows: a computer known not to be Windows is told what is limited, not sold anything.
  static func recommends(_ info: DeckHostSoftware.Info) -> Bool { !info.isFoundation && info.windows != .no }
}


/// A Foundation Sunshine computer that lacks functions the client knows: told by capability, not by a date.
/// Signals: no Fs* capability at all (FsCapabilityVersion absent or below what this client knows), or an app list in which
/// no app carries FsKind (big screen, covers by kind and the like depend on it). The version's date is never used to decide.
enum DeckFsUpdateRules {
  /// The newest FsCapabilityVersion this client knows (host src/client_interface.h, capability_version).
  static let latestCapability = 1
  enum Reason: Equatable { case oldCapability, noFsKind }

  /// - kindSeen: nil when the app list has not been read yet (then only the capability counts).
  static func reason(isFoundation: Bool, fsCapability: Int, kindSeen: Bool?) -> Reason? {
    guard isFoundation else { return nil }
    if fsCapability < latestCapability { return .oldCapability }
    if kindSeen == false { return .noFsKind }
    return nil
  }

  /// What "not again" is remembered against: the host's version, or its capability level when it sends no version.
  /// After the host is updated and is behind again the token differs and the banner may come back once.
  static func token(version: String, fsCapability: Int) -> String { version.isEmpty ? "cap\(fsCapability)" : version }

  static func shouldShow(reason: Reason?, token: String, dismissedFor: String?, shownFor: String?, shownThisLaunch: Bool) -> Bool {
    guard reason != nil, dismissedFor != token else { return false }
    if shownFor == token && !shownThisLaunch { return false }
    return true
  }
}

// MARK: - 最近使用

/// Only what was really used: an app the host says it ran (FsLastPlayed) or this Mac launched, each with a valid time.
/// Never the order of the app list, never an entry with no time. Newest first. (Apple TV's 继续观看 and Apple Music's
/// 最近播放 are simply not there when there is nothing to put in them: the section hides.)
struct DeckRecentCandidate: Equatable {
  var id: String
  /// FsLastPlayed from a Foundation Sunshine host
  var hostLastPlayed: Date?
  /// the start of the newest session this client recorded
  var ownLastStart: Date?
}

enum DeckRecentRules {
  static func recent(_ candidates: [DeckRecentCandidate], limit: Int = 10, now: Date = Date()) -> [String] {
    var dated: [(id: String, when: Date)] = []
    for c in candidates {
      let times = [DeckTimeRules.valid(c.hostLastPlayed, now: now), DeckTimeRules.valid(c.ownLastStart, now: now)].compactMap { $0 }
      if let newest = times.max() { dated.append((c.id, newest)) }
    }
    return dated.sorted { $0.when > $1.when }.prefix(limit).map { $0.id }
  }
}


// MARK: - A coloured tile on the sidebar's selection

/// A host's icon is a pale tile of its colour with the glyph in the colour itself. On the selected row the selection fill is the
/// system accent (blue by default): a blue tile with a blue glyph melts into it. System Settings lifts its coloured squares off the
/// selection with a light edge; here the edge is always added on a light appearance, and when the glyph and the tile it sits on are
/// too alike (colour difference below `similar`) the tile is lifted to a light base as well.
enum DeckSelectionRules {
  struct RGB: Equatable { var r: Double, g: Double, b: Double }   // sRGB, 0...1

  /// CIE76 colour difference in L*a*b* (D65). One just-noticeable difference is about 2.3; two hues that are clearly different
  /// as small shapes start around 35-40.
  static func deltaE(_ a: RGB, _ b: RGB) -> Double {
    let la = lab(a), lb = lab(b)
    return ((la.l - lb.l) * (la.l - lb.l) + (la.a - lb.a) * (la.a - lb.a) + (la.b - lb.b) * (la.b - lb.b)).squareRoot()
  }

  /// The threshold of the lift. Palette check (macOS 26 system colours on the default blue accent, tile 16 %): dE76 of the glyph
  /// against its tile is blue 0, indigo 17, purple 39 (all lifted); teal 61, gray 63, pink 112, green 121, red 127, orange 133,
  /// yellow 137 (not lifted).
  static let similar = 40.0

  static func blend(_ top: RGB, over bottom: RGB, alpha: Double) -> RGB {
    RGB(r: top.r * alpha + bottom.r * (1 - alpha), g: top.g * alpha + bottom.g * (1 - alpha), b: top.b * alpha + bottom.b * (1 - alpha))
  }

  /// - tint: the icon colour; `tileAlpha` is how strongly the tile shows it; `selection` the row's selection fill.
  static func needsLift(tint: RGB, selection: RGB, tileAlpha: Double = 0.16) -> Bool {
    deltaE(tint, blend(tint, over: selection, alpha: tileAlpha)) < similar
  }

  private static func lab(_ c: RGB) -> (l: Double, a: Double, b: Double) {
    func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    let r = lin(c.r), g = lin(c.g), b = lin(c.b)
    let x = (0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047
    let y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
    let z = (0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / 1.08883
    func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16.0 / 116.0 }
    return (116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
  }
}


// MARK: - When the app list is fetched again

/// The apps of a computer change on the host (a Sparxie app added, apps.json edited) without the client being told, so the client
/// looks: when the page opens, when the computer comes online, when its /serverinfo says the list changed (appListEtag differs
/// from the value saved with the last fetch), and, for a host that sends no etag, every 60 s while the page is visible.
enum DeckAppListRules {
  enum Reason: String { case pageOpen = "page-open", etagChanged = "etag-changed", interval, online }
  static let interval: TimeInterval = 60
  /// The shortest time between two fetches that an etag may trigger (a host whose list cannot be fetched is not asked every tick).
  static let etagThrottle: TimeInterval = 15

  static func etagDiffers(seen: String?, fetched: String?) -> Bool {
    guard let seen, !seen.isEmpty else { return false }
    return seen != fetched
  }

  /// Called every few seconds while the computer's page is visible.
  static func due(online: Bool, wasOnline: Bool, seenEtag: String?, fetchedEtag: String?, lastFetch: Date?, now: Date) -> Reason? {
    guard online else { return nil }
    if !wasOnline { return .online }
    let since = lastFetch.map { now.timeIntervalSince($0) }
    if etagDiffers(seen: seenEtag, fetched: fetchedEtag), since == nil || since! >= etagThrottle { return .etagChanged }
    // no etag from this host: it cannot tell, so ask on a timer
    if (seenEtag ?? "").isEmpty, since == nil || since! >= interval { return .interval }
    return nil
  }
}

// MARK: - Cold start: what is drawn before discovery has answered

/// A cold launch knows nothing of the network yet. The first frame shows what was true when the app was last open
/// (the computer was on, its 线路 chips read like this), and discovery's answers then update it in place.
enum DeckPresenceRules {
  /// `state` is TemporaryHost.state: 0 unknown (no answer since launch), 1 offline (every address failed), 2 online.
  /// An unknown computer is drawn as it was last seen; a computer found off is drawn off.
  static func shownOnline(state: Int, lastOnline: Bool) -> Bool { state == 2 || (state == 0 && lastOnline) }
  /// The hero's picture goes grey only for a computer that was found off. Never while the answer is still out.
  static func greyHero(state: Int) -> Bool { state == 1 }
}

/// One 线路 chip as it is drawn (what a chip shows, without its action): the thing the next launch draws first.
struct DeckChipSnap: Equatable {
  var id: String
  var title: String
  var symbol: String?
  var trailing: String?
  var badge: String?
  var unreachable = false
  var inUse = false
  /// What pinning the chip sets ("" = 自动).
  var target = ""
  /// The addresses behind the chip (endpoint keys): the chip is selected when the pinned address is one of them.
  var members: [String] = []
  var tooltip = ""

  init(id: String, title: String, symbol: String? = nil, trailing: String? = nil, badge: String? = nil, unreachable: Bool = false,
       inUse: Bool = false, target: String = "", members: [String] = [], tooltip: String = "") {
    self.id = id; self.title = title; self.symbol = symbol; self.trailing = trailing; self.badge = badge
    self.unreachable = unreachable; self.inUse = inUse; self.target = target; self.members = members; self.tooltip = tooltip
  }

  var dictionary: [String: Any] {
    var d: [String: Any] = ["id": id, "title": title, "unreachable": unreachable, "inUse": inUse, "target": target, "members": members, "tooltip": tooltip]
    if let symbol { d["symbol"] = symbol }
    if let trailing { d["trailing"] = trailing }
    if let badge { d["badge"] = badge }
    return d
  }

  init?(dictionary d: [String: Any]) {
    guard let id = d["id"] as? String, let title = d["title"] as? String else { return nil }
    self.init(id: id, title: title, symbol: d["symbol"] as? String, trailing: d["trailing"] as? String, badge: d["badge"] as? String,
              unreachable: d["unreachable"] as? Bool ?? false, inUse: d["inUse"] as? Bool ?? false, target: d["target"] as? String ?? "",
              members: d["members"] as? [String] ?? [], tooltip: d["tooltip"] as? String ?? "")
  }
}

/// The chips of one computer as last drawn with every result in, and the addresses they were made from.
struct DeckChipMemoryEntry: Equatable {
  var keys: [String]
  var chips: [DeckChipSnap]

  var dictionary: [String: Any] { ["keys": keys, "chips": chips.map { $0.dictionary }] }
  init(keys: [String], chips: [DeckChipSnap]) { self.keys = keys.sorted(); self.chips = chips }
  init?(dictionary d: [String: Any]) {
    guard let keys = d["keys"] as? [String], let list = d["chips"] as? [[String: Any]] else { return nil }
    self.init(keys: keys, chips: list.compactMap { DeckChipSnap(dictionary: $0) })
  }
}

/// The 线路 chips must not flicker at launch. Until every address has answered (and every name resolved), the evidence is
/// partial and the paths are classified from less than they will be: the first answer would draw 局域网, the last 组网; the
/// slow address arrives as 超时 seconds later. So while the answers are out the chips are the remembered ones (same
/// addresses), in the remembered order, with a small mark that they are being checked; when everything is in the live ones
/// replace them. A chip with the same value is not touched.
enum DeckChipStability {
  /// The longest a remembered row is held while an address still has not answered.
  static let holdSeconds: TimeInterval = 8
  /// The most often a changed row is written to disk.
  static let saveEvery: TimeInterval = 5

  struct Choice: Equatable {
    var chips: [DeckChipSnap]
    var pending: Bool
    var fromMemory: Bool
  }

  static func choose(live: [DeckChipSnap], liveKeys: [String], remembered: DeckChipMemoryEntry?, complete: Bool, waited: TimeInterval) -> Choice {
    if !complete, waited < holdSeconds, let remembered, !remembered.chips.isEmpty, remembered.keys == liveKeys.sorted() {
      return Choice(chips: remembered.chips, pending: true, fromMemory: true)
    }
    // the mark is for the first moments: an address that never answers does not keep it on for ever
    return Choice(chips: live, pending: !complete && waited < holdSeconds, fromMemory: false)
  }

  /// Worth writing: every result is in and it differs from what is stored (the last-used mark alone is not).
  static func shouldSave(live: [DeckChipSnap], liveKeys: [String], remembered: DeckChipMemoryEntry?, complete: Bool, sinceLastSave: TimeInterval) -> Bool {
    guard complete, !live.isEmpty else { return false }
    guard let remembered else { return true }
    if sinceLastSave < saveEvery { return false }
    return remembered != DeckChipMemoryEntry(keys: liveKeys, chips: live)
  }

  /// Every address has a result WITH its round trip (the path class uses it: a fast private address is 局域网 only with a number) or has
  /// failed, and every name has been resolved. `measured` is false for an answered address whose round trip is still out; the caller
  /// counts it as measured after a short grace (an answer without a number: the host did not give one). A computer found off will not
  /// answer: nothing is awaited.
  static func evidenceComplete(offline: Bool, rows: [(answered: Bool, failed: Bool, measured: Bool, isDomain: Bool, resolved: Bool)]) -> Bool {
    if offline { return true }
    return rows.allSatisfy { ($0.failed || ($0.answered && $0.measured)) && (!$0.isDomain || $0.resolved) }
  }
}

// MARK: - Art that a host update fixes

enum DeckArtRecheckRules {
  /// A picture is asked for again when the host's software changed since the answer on disk was recorded: a fixed host
  /// (the placeholder cover of Sparxie apps) serves the right picture under the same path and the same art version.
  static func hostSoftwareChanged(recorded: String?, current: String) -> Bool {
    guard !current.isEmpty else { return false }
    // a picture recorded before the host's software was noted (older builds) is asked for once: a conditional request, a 304 when it is right
    guard let recorded, !recorded.isEmpty else { return true }
    return recorded != current
  }
}

// MARK: - The running app's mark: a green play glyph left of the title

/// The green of the glyph, by the surface the title sits on. On a card's dark scrim (the band, the hero) a bright system green;
/// under a poster, on the page, light mode takes a deeper green. Both are checked to hold 3:1 (the bar for a graphic) on the
/// surfaces they are drawn on, 4.5:1 where it sits next to text.
enum DeckRunGreenRules {
  typealias RGB = (r: Double, g: Double, b: Double)
  static let onDarkScrim: RGB = (0.19, 0.82, 0.35)
  static let onLightPage: RGB = (0.09, 0.52, 0.22)
  static let onDarkPage: RGB = (0.19, 0.82, 0.35)

  static func luminance(_ c: RGB) -> Double {
    func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
  }
  static func contrast(_ a: RGB, _ b: RGB) -> Double {
    let la = luminance(a), lb = luminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
  }
}
