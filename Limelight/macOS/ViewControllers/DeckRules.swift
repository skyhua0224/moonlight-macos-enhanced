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

