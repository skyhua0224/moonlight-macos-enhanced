import Foundation
var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
  if !ok { failures += 1 }
  print("\(ok ? "PASS" : "FAIL") \(name)\(ok ? "" : " — " + detail())")
}
func ep(_ raw: String) -> DeckEndpoint { DeckEndpoint.parse(raw)! }
func verdict(_ raw: String, _ tweak: (inout DeckPathFacts) -> Void = { _ in }) -> DeckPathVerdict {
  var facts = DeckPathFacts(endpoint: ep(raw)); tweak(&facts); return DeckPathClassifier.classify(facts)
}

// ---- time
do {
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  check("time: missing is unknown", DeckTimeRules.valid(nil, now: now) == nil)
  check("time: epoch 0 (1970) is unknown", DeckTimeRules.fromEpoch(0, now: now) == nil)
  check("time: 56 years ago is unknown", DeckTimeRules.valid(Date(timeIntervalSince1970: 100_000_000), now: now) == nil)
  check("time: a real date stays", DeckTimeRules.fromEpoch(1_799_000_000, now: now) != nil)
  check("time: the far future is unknown", DeckTimeRules.fromEpoch(4_000_000_000, now: now) == nil)
  check("time: NaN is unknown", DeckTimeRules.fromEpoch(Double.nan, now: now) == nil)
}

// ---- 最近使用: only what was really used
do {
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  func d(_ t: Double) -> Date { Date(timeIntervalSince1970: t) }
  let list = [
    DeckRecentCandidate(id: "steam", hostLastPlayed: d(0), ownLastStart: nil),                 // never started: the host says 0
    DeckRecentCandidate(id: "xbox", hostLastPlayed: nil, ownLastStart: nil),                   // no time at all
    DeckRecentCandidate(id: "old", hostLastPlayed: d(100_000_000), ownLastStart: nil),         // 1973: not a real time
    DeckRecentCandidate(id: "hades", hostLastPlayed: d(1_799_000_000), ownLastStart: nil),     // the host says it ran
    DeckRecentCandidate(id: "genshin", hostLastPlayed: nil, ownLastStart: d(1_799_500_000)),   // this Mac launched it
    DeckRecentCandidate(id: "both", hostLastPlayed: d(1_798_000_000), ownLastStart: d(1_799_800_000)),
  ]
  let recent = DeckRecentRules.recent(list, now: now)
  check("recent: never-started apps (time 0 or none) are not in it", !recent.contains("steam") && !recent.contains("xbox") && !recent.contains("old"), "\(recent)")
  check("recent: host-reported and own sessions are, newest first", recent == ["both", "genshin", "hades"], "\(recent)")
  check("recent: nothing used at all gives an empty list (the section hides)", DeckRecentRules.recent(Array(list.prefix(3)), now: now).isEmpty)
  check("recent: no candidates gives an empty list", DeckRecentRules.recent([], now: now).isEmpty)
  let many = (0..<30).map { DeckRecentCandidate(id: "a\($0)", hostLastPlayed: d(1_700_000_000 + Double($0)), ownLastStart: nil) }
  check("recent: at most ten", DeckRecentRules.recent(many, now: now).count == 10 && DeckRecentRules.recent(many, now: now).first == "a29")
  check("recent: the order of the app list is not used to fill up", DeckRecentRules.recent([DeckRecentCandidate(id: "first", hostLastPlayed: nil, ownLastStart: nil), DeckRecentCandidate(id: "second", hostLastPlayed: nil, ownLastStart: nil)], now: now).isEmpty)
}
// ---- art
check("art: Steam header 460x215 fills", DeckArtRules.treatment(width: 460, height: 215) == .fill)
check("art: 16:9 fills", DeckArtRules.treatment(width: 1920, height: 1080) == .fill)
check("art: 1.4:1 fills", DeckArtRules.treatment(width: 1400, height: 1000) == .fill)
check("art: portrait poster is centred on blur", DeckArtRules.treatment(width: 600, height: 900) == .centredOnBlur)
check("art: square is centred on blur", DeckArtRules.treatment(width: 512, height: 512) == .centredOnBlur)
check("art: unknown size is centred on blur", DeckArtRules.treatment(width: 0, height: 0) == .centredOnBlur)

// ---- endpoints: parse
check("parse: bare IPv4 gets the default port", ep("10.100.0.133").display == "10.100.0.133:47989")
check("parse: custom port kept", ep("10.100.0.133:57989").display == "10.100.0.133:57989")
check("parse: domain with trailing dot", ep("Gaming-PC.local.:57989").display == "gaming-pc.local:57989")
check("parse: IPv6 with port is bracketed", ep("[fd00:db8::4c4d]:57989").display == "[fd00:db8::4c4d]:57989")
check("parse: bare IPv6 is bracketed with the default port", ep("fd00:db8::4c4d").display == "[fd00:db8::4c4d]:47989")
check("parse: nonsense is rejected", DeckEndpoint.parse("") == nil && DeckEndpoint.parse("a b") == nil && DeckEndpoint.parse("host:99999") == nil && DeckEndpoint.parse("[::1") == nil)
check("parse: the default port is written out, not omitted", ep("pc.example.net").display == "pc.example.net:47989")

// ---- address book
do {
  let entries = DeckAddressBook.merge(preset: ["10.100.0.133", "Gaming-PC.local.:57989", nil, "[fd00:db8::4c4d]"], manual: [], discovered: ["10.100.0.133:57989", "pc.example.net:57989", "10.100.0.133"])
  let keys = entries.map { $0.endpoint.key }
  check("book: same host on two ports is two entries", keys.contains("10.100.0.133:47989") && keys.contains("10.100.0.133:57989"), "\(keys)")
  check("book: a domain and an IP are not merged", keys.contains("pc.example.net:57989") && keys.contains("10.100.0.133:57989"))
  check("book: IPv6 keeps its brackets", keys.contains("[fd00:db8::4c4d]:47989"))
  check("book: a repeated address is listed once", keys.filter { $0 == "10.100.0.133:47989" }.count == 1, "\(keys)")
  check("book: discovered domain is in the list (not only the preset fields)", entries.first { $0.endpoint.host == "pc.example.net" } != nil)
  check("book: preset entries cannot be deleted", entries.filter { $0.sources.contains(.preset) }.allSatisfy { !$0.deletable })
  check("book: a discovered-only entry cannot be deleted", entries.first { $0.endpoint.host == "pc.example.net" }?.deletable == false)
}
// manual: appears in both views (one list), disappears from both when removed
do {
  var manual = ["tunnel.example.net:6000"]
  let preset: [String?] = ["10.100.0.133"]
  let withManual = DeckAddressBook.merge(preset: preset, manual: manual, discovered: [])
  check("book: a manual address is in the one list (地址 and 线路 read it)", withManual.contains { $0.endpoint.key == "tunnel.example.net:6000" && $0.deletable })
  manual.removeAll()
  let after = DeckAddressBook.merge(preset: preset, manual: manual, discovered: [])
  check("book: removed, it is gone from the one list", !after.contains { $0.endpoint.key == "tunnel.example.net:6000" })
  let disabled = DeckAddressBook.merge(preset: ["10.0.0.5"], manual: [], discovered: [], disabled: ["10.0.0.5:47989"])
  check("book: a disabled preset is not listed", disabled.isEmpty)
}
// results: looked up by host and port
do {
  let entries = DeckAddressBook.merge(preset: ["10.100.0.133", "10.100.0.133:57989"], manual: [], discovered: [])
  let results: [String: Int] = ["10.100.0.133": 1, "10.100.0.133:57989": 38]
  check("lookup: default port result", DeckAddressBook.lookup(results, entries[0]) == 1)
  check("lookup: custom port result", DeckAddressBook.lookup(results, entries[1]) == 38)
  let explicit: [String: Int] = ["10.100.0.133:47989": 7]
  check("lookup: a key with the explicit default port matches the bare entry", DeckAddressBook.lookup(explicit, entries[0]) == 7)
}

// ---- path classes
check("class: private LAN address", DeckPathClassifier.addressClass("10.100.0.133") == .privateLAN)
check("class: 100.64/10 is overlay private", DeckPathClassifier.addressClass("100.101.2.3") == .overlayPrivate)
check("class: public", DeckPathClassifier.addressClass("203.0.113.9") == .publicAddress)
check("class: link-local v6 is private", DeckPathClassifier.addressClass("fe80::1") == .privateLAN)
check("class: global v6 is public", DeckPathClassifier.addressClass("2001:db8::1") == .publicAddress)

do {   // a relay server on a public IP is not "direct"
  let none = verdict("203.0.113.50:7000")
  check("relay server's public IP with no evidence is NOT direct", none.pathClass != .publicDirect && none.pathClass == .unknown && none.confidence == .low, "\(none)")
  check("relay server's public IP with no evidence is named by what it is (IP), not by a class", DeckPathWords.word(none, ep("203.0.113.50:7000")) == .ip)
  let declared = verdict("203.0.113.50:7000") { $0.declared = .relay }
  check("relay server declared by the user is RELAY, HIGH", declared.pathClass == .relay && declared.confidence == .high && declared.evidence == .userDeclared)
  let reported = verdict("203.0.113.50:7000") { $0.relayReported = true }
  check("relay reported by the host or us is RELAY", reported.pathClass == .relay && reported.confidence == .high)
}
do {   // a port-forwarded domain on a custom port
  let forward = verdict("pc.example.net:57989") { $0.resolvedIPs = ["203.0.113.79"]; $0.hostPublicIP = "203.0.113.79"; $0.tested = true }
  check("domain resolving to the host's public IP on a custom port is a port forward", forward.pathClass == .publicForward && forward.evidence == .matchesHostPublicIP(ip: "203.0.113.79"), "\(forward)")
  let upnp = verdict("203.0.113.79") { $0.hostPublicIP = "203.0.113.79"; $0.upnpMappingRecorded = true }
  check("same IP on the standard port with a UPnP record is a port forward", upnp.pathClass == .publicForward, "\(upnp)")
  let standardNoRecord = verdict("203.0.113.79") { $0.hostPublicIP = "203.0.113.79" }
  check("same IP on the standard port and no UPnP record: not confirmed", standardNoRecord.pathClass == .unknown, "\(standardNoRecord)")
  let other = verdict("home.example.org:57989") { $0.resolvedIPs = ["198.51.100.4"]; $0.hostPublicIP = "203.0.113.79" }
  check("a domain that resolves elsewhere is not a forward", other.pathClass == .unknown, "\(other)")
}
do {
  let overlay = verdict("100.101.2.3:57989")
  check("100.64/10 is OVERLAY_ROUTE", overlay.pathClass == .overlayRoute && overlay.addressClass == .overlayPrivate && overlay.confidence == .medium)
  let tun = verdict("10.5.0.5") { $0.egressIsTunnel = true; $0.rttMs = 3 }
  check("a private address leaving by a tunnel is OVERLAY_ROUTE, not LAN", tun.pathClass == .overlayRoute && tun.confidence == .high, "\(tun)")
  let lan = verdict("10.100.0.133") { $0.egressIsTunnel = false; $0.rttMs = 1 }
  check("private + physical egress + LAN RTT is LAN", lan.pathClass == .lan && lan.confidence == .high, "\(lan)")
  let slowPrivate = verdict("10.100.0.133") { $0.egressIsTunnel = false; $0.rttMs = 95 }
  check("private but 95 ms is not LAN", slowPrivate.pathClass == .unknown, "\(slowPrivate)")
  let v6 = verdict("[2001:db8::1]:57989")
  check("a global IPv6 literal is PUBLIC_DIRECT", v6.pathClass == .publicDirect && v6.evidence == .ipv6Global, "\(v6)")
  let own = verdict("203.0.113.9") { $0.hostInterfaceIPs = ["203.0.113.9"] }
  check("an IP configured on the host's NIC is PUBLIC_DIRECT", own.pathClass == .publicDirect && own.confidence == .high, "\(own)")
}
do {   // a tunnel is an overlay, never a relay (a utun route to a private LAN address)
  for rtt in [2, 56, 120, 400] {
    let v = verdict("10.100.0.133:47989") { $0.egressIsTunnel = true; $0.rttMs = rtt }
    check("utun egress + private address at \(rtt) ms is OVERLAY_ROUTE, not RELAY", v.pathClass == .overlayRoute && v.confidence == .high, "\(v)")
  }
  let hinted = verdict("10.100.0.133:47989") { $0.egressIsTunnel = true; $0.relayReported = true }
  check("only an explicit relay report makes a tunnel path a relay", hinted.pathClass == .relay)
  let unreported = verdict("10.100.0.133:47989") { $0.egressIsTunnel = true; $0.relayReported = false }
  check("a path reported as not relayed stays overlay", unreported.pathClass == .overlayRoute)
}
do {   // no evidence → unconfirmed, never guessed
  let u1 = verdict("198.51.100.77")
  check("no evidence: no class, named IP", !u1.isConfirmed && DeckPathWords.word(u1, ep("198.51.100.77")) == .ip)
  let u2 = verdict("10.100.0.200")
  check("private and never measured: not LAN, named 内网", !u2.isConfirmed && DeckPathWords.word(u2, ep("10.100.0.200")) == .privateAddress)
  let domain = verdict("never-resolved.example.net:57989")
  check("an unresolved domain has no class and is named 域名", !domain.isConfirmed && DeckPathWords.word(domain, ep("never-resolved.example.net:57989")) == .domain, "\(domain)")
  check("a .local name with no evidence is named 内网", DeckPathWords.word(verdict("gaming-pc.local:47989"), ep("gaming-pc.local:47989")) == .privateAddress)
  let resolvedUnknown = verdict("somewhere.example.net") { $0.resolvedIPs = ["198.51.100.9"]; $0.tested = true }
  check("a resolved but unproven domain has no class", !resolvedUnknown.isConfirmed)
}
do {   // the user's declaration beats the guess
  let guessed = verdict("100.101.2.3")
  check("auto says overlay", guessed.pathClass == .overlayRoute)
  let said = verdict("100.101.2.3") { $0.declared = .relay }
  check("user declaration beats the automatic verdict", said.pathClass == .relay && said.confidence == .high && said.evidence == .userDeclared)
  let host = verdict("203.0.113.9") { $0.declared = .host }
  check("declared 'the host itself' on a public IP is direct", host.pathClass == .publicDirect && host.confidence == .high)
  let fwd = verdict("example.net:6000") { $0.declared = .forward }
  check("declared forward", fwd.pathClass == .publicForward)
  check("a declared domain that was never resolved is not 'untested': the user said what it is", !fwd.untested)
  let ov = verdict("203.0.113.9") { $0.declared = .overlay }
  check("declared overlay", ov.pathClass == .overlayRoute)
}
// ---- chips group by PATH class, not address class
do {
  let rows: [(endpoint: DeckEndpoint, verdict: DeckPathVerdict)] = [
    (ep("10.100.0.133:47989"), verdict("10.100.0.133") { $0.egressIsTunnel = false; $0.rttMs = 1 }),
    (ep("10.100.0.133:57989"), verdict("10.100.0.133:57989") { $0.egressIsTunnel = false; $0.rttMs = 1 }),
    (ep("pc.example.net:57989"), verdict("pc.example.net:57989") { $0.resolvedIPs = ["203.0.113.79"]; $0.hostPublicIP = "203.0.113.79" }),
    (ep("203.0.113.50:7000"), verdict("203.0.113.50:7000") { $0.declared = .relay }),
    (ep("203.0.113.9:47989"), verdict("203.0.113.9")),
    (ep("somewhere.example.net:47989"), verdict("somewhere.example.net:47989")),
  ]
  let groups = DeckChipBuilder.groups(rows)
  check("chips: LAN, forward, relay, then the addresses with no evidence by what they are (IP, 域名)", groups.map { $0.word } == [.lan, .publicForward, .relay, .ip, .domain], "\(groups.map { $0.word })")
  check("chips: two ports of the LAN IP are one LAN chip with both endpoints", groups[0].endpoints.count == 2)
  check("chips: a relay server on a public IP is not in the direct group", !groups.contains { $0.word == .publicDirect })
  // what a chip shows: the address in use, else the fastest, else the first, with +N
  let lan = groups[0]
  let inUse = DeckChipBuilder.shown(lan, inUse: ep("10.100.0.133:57989")) { _ in 5 }
  check("chip shows the address in use and +1", inUse.endpoint.key == "10.100.0.133:57989" && inUse.more == 1, "\(inUse)")
  let fastest = DeckChipBuilder.shown(lan, inUse: nil) { $0.port == 57989 ? 2 : 9 }
  check("chip shows the lowest-latency address when none is in use", fastest.endpoint.port == 57989 && fastest.more == 1)
  let first = DeckChipBuilder.shown(lan, inUse: nil) { _ in nil }
  check("chip shows the first address when nothing has a latency", first.endpoint.port == 47989)
  let single = DeckChipBuilder.shown(groups[1], inUse: nil) { _ in 64 }
  check("a chip with one address has no +N", single.more == 0 && single.endpoint.display == "pc.example.net:57989")
}
// ---- long hosts are cut in the middle, the port stays
do {
  let long = ep("a-very-long-subdomain.of.some.provider.example.org:57989")
  let cut = long.shortDisplay(maxHostLength: 24)
  check("long host cut in the middle, port kept", cut.hasSuffix(":57989") && cut.contains("…") && cut.hasPrefix("a-very-long") && cut.count < long.display.count, cut)
  check("a short host is untouched", ep("pc.example.net:57989").shortDisplay() == "pc.example.net:57989")
  check("IPv6 keeps its brackets when cut", ep("[2001:db8:1234:5678:9abc:def0:1111:2222]:47989").shortDisplay(maxHostLength: 16).hasPrefix("[") )
}
// ---- host software and the recommendation
do {
  typealias S = DeckHostSoftware
  let fs = S.classify(isFoundation: true, sunshineVersion: "Foundation Sunshine 2026.1110.165906", gfeVersion: "3.23.0.74", state: "SUNSHINE_SERVER_FREE", platform: "")
  check("software: Foundation Sunshine with its version", S.title(fs, names: S.Names()) == "Foundation Sunshine 2026.1110.165906", S.title(fs, names: S.Names()))
  let sun = S.classify(isFoundation: false, sunshineVersion: "", gfeVersion: "3.23.0.74", state: "SUNSHINE_SERVER_FREE", platform: "")
  check("software: Sunshine's constant GfeVersion 3.23.0.74 is not GeForce Experience", sun.kind == .sunshine(version: ""), "\(sun.kind)")
  check("software: no version is invented", S.title(sun, names: S.Names()) == "Sunshine")
  let gfe = S.classify(isFoundation: false, sunshineVersion: "", gfeVersion: "3.28.0.417", state: "MJOLNIR_STATE_SERVER_AVAILABLE", platform: "")
  check("software: MJOLNIR state + GfeVersion is GeForce Experience, Windows", S.title(gfe, names: S.Names()) == "GeForce Experience 3.28.0.417" && gfe.windows == .yes)
  let gfeNoVer = S.classify(isFoundation: false, sunshineVersion: "", gfeVersion: "", state: "MJOLNIR_STATE_SERVER_BUSY", platform: "")
  check("software: GFE without a version number says GeForce Experience only", S.title(gfeNoVer, names: S.Names()) == "GeForce Experience")
  let other = S.classify(isFoundation: false, sunshineVersion: "", gfeVersion: "3.23.0.74", state: "", platform: "")
  check("software: nothing to go on is a compatible host", other.kind == .compatible && S.title(other, names: S.Names()) == "GameStream")
  let apollo = S.classify(isFoundation: false, sunshineVersion: "Apollo 0.4.6", gfeVersion: "3.23.0.74", state: "SUNSHINE_SERVER_FREE", platform: "")
  check("software: a SunshineVersion on another fork is shown as sent, version only", apollo.kind == .sunshine(version: "0.4.6"))
  check("version number parsing", S.versionNumber("v0.23.1") == "0.23.1" && S.versionNumber("Sunshine") == "" && S.versionNumber("") == "")
  // the version is shown as its first three numeric parts; the whole string is the hover text
  let cases: [(String, String, String)] = [   // raw serverinfo SunshineVersion, shown, hover version
    ("Sunshine 2026.1112.025657", "2026.1112.025657", "2026.1112.025657"),
    ("Sunshine 2026.1112.025657.杂鱼", "2026.1112.025657", "2026.1112.025657.杂鱼"),
    ("2026.823.50647.杂鱼", "2026.823.50647", "2026.823.50647.杂鱼"),
    ("v2026.1103.21122.杂鱼", "2026.1103.21122", "2026.1103.21122.杂鱼"),
    ("Sunshine 2026.1112.025657.970e0298b", "2026.1112.025657", "2026.1112.025657.970e0298b"),
    ("Sunshine 2026.1112.025657.970e0298b.杂鱼", "2026.1112.025657", "2026.1112.025657.970e0298b.杂鱼"),
    ("2026.1112.025657.のうち", "2026.1112.025657", "2026.1112.025657.のうち"),
    ("2026.1112.025657.🙂", "2026.1112.025657", "2026.1112.025657.🙂"),
    ("2026.1112.025657.🙂杂鱼🙂", "2026.1112.025657", "2026.1112.025657.🙂杂鱼🙂"),
    ("Sunshine 2026.1112.025657.8123456", "2026.1112.025657", "2026.1112.025657.8123456"),     // an all-digit short commit is a suffix too
    ("Sunshine 2026.1112.025657.dirty", "2026.1112.025657", "2026.1112.025657.dirty"),
    ("Sunshine 0.23.1", "0.23.1", "0.23.1"),
    ("v0.23.1", "0.23.1", "0.23.1"),
    ("Sunshine 2026.1112", "2026.1112", "2026.1112"),                                              // fewer than three parts: what there is
    ("Sunshine 2026", "2026", "2026"),
    ("Sunshine 2026.1112.025657.", "2026.1112.025657", "2026.1112.025657."),                       // a stray trailing dot
    ("Sunshine 2026..1112", "2026", "2026..1112"),                                                 // an empty part ends the number
    ("manual-20261112-025657", "", "manual-20261112-025657"),                                      // a manual CI build: no version, tag in the hover
    ("manual-20261112-025657-dev", "", "manual-20261112-025657-dev"),
    ("Sunshine manual-20261112-025657-dev", "", "manual-20261112-025657-dev"),
    ("杂鱼", "", ""),
    ("Sunshine", "", ""),
    ("", "", ""),
    ("Sunshine 2026.1112.025657. 杂鱼", "2026.1112.025657", "2026.1112.025657. 杂鱼"),             // a space after the dot (not a real form)
    ("Sunshine \u{0663}.1", "", "\u{0663}.1"),                                                   // a non-ASCII digit is not a version
  ]
  for (raw, shown, hover) in cases {
    let info = S.classify(isFoundation: true, sunshineVersion: raw, gfeVersion: "", state: "SUNSHINE_SERVER_FREE", platform: "")
    let title = S.title(info, names: S.Names())
    check("version \"\(raw)\" shows \"\(shown)\"", S.versionNumber(raw) == shown && info.kind == .foundation(version: shown) && title == (shown.isEmpty ? "Foundation Sunshine" : "Foundation Sunshine \(shown)"), title)
    check("version \"\(raw)\" hover has \"\(hover)\"", info.fullVersion == hover && S.detail(info, names: S.Names()) == (hover.isEmpty ? "Foundation Sunshine" : "Foundation Sunshine \(hover)"), S.detail(info, names: S.Names()))
    check("version \"\(raw)\": the shown version is never longer than three parts", S.versionNumber(raw).split(separator: ".").count <= 3)
  }
  check("version: no suffix, no difference between the label and the hover", S.detail(fs, names: S.Names()) == S.title(fs, names: S.Names()))
  check("version: plain Sunshine with a version shows three parts, hover the whole", {
    let i = S.classify(isFoundation: false, sunshineVersion: "Sunshine 2026.1112.025657.杂鱼", gfeVersion: "3.23.0.74", state: "SUNSHINE_SERVER_FREE", platform: "")
    return S.title(i, names: S.Names()) == "Sunshine 2026.1112.025657" && S.detail(i, names: S.Names()) == "Sunshine 2026.1112.025657.杂鱼" }())
  check("version: GFE keeps its four-part number", S.title(gfe, names: S.Names()) == "GeForce Experience 3.28.0.417" && S.detail(gfe, names: S.Names()) == "GeForce Experience 3.28.0.417")
  check("version: compatible host has nothing to hover", S.detail(other, names: S.Names()) == "GameStream")
  // the same build in every form gives one title: nothing flips with the suffix
  let forms = ["Sunshine 2026.1112.025657", "Sunshine 2026.1112.025657.杂鱼", "v2026.1112.025657.杂鱼", "2026.1112.025657.970e0298b.杂鱼"]
  check("version: every suffix form of one build has one title", Set(forms.map { S.title(S.classify(isFoundation: true, sunshineVersion: $0, gfeVersion: "", state: "", platform: ""), names: S.Names()) }).count == 1)
  // update token: first three parts only, so the "do not remind me" record survives a suffix change
  typealias UT = DeckFsUpdateRules
  let tokens = Set(forms.map { UT.token(version: S.versionNumber($0), fsCapability: 0) })
  check("version: the update token is the same for every suffix form of one build", tokens == ["2026.1112.025657"], "\(tokens)")
  check("version: a manual build's token is its capability level", UT.token(version: S.versionNumber("manual-20261112-025657"), fsCapability: 1) == "cap1")
  check("version: the token changes with a new build", UT.token(version: S.versionNumber("2026.1113.010000.杂鱼"), fsCapability: 0) != tokens.first!)
  // windows
  check("windows: GFE and Foundation are Windows; Sunshine alone is unknown", gfe.windows == .yes && fs.windows == .yes && sun.windows == .unknown)
  let linux = S.classify(isFoundation: false, sunshineVersion: "", gfeVersion: "", state: "SUNSHINE_SERVER_FREE", platform: "linux")
  check("windows: a host that reports another OS is not Windows", linux.windows == .no)
  // banner
  typealias P = DeckFsPromoRules
  check("promo: Sunshine of unknown OS gets the 'if Windows' wording", P.banner(sun, dismissed: false, shownBefore: false, shownThisLaunch: false) == .ifWindows)
  check("promo: GFE gets the plain banner", P.banner(gfe, dismissed: false, shownBefore: false, shownThisLaunch: false) == .windows)
  check("promo: Foundation never", P.banner(fs, dismissed: false, shownBefore: false, shownThisLaunch: false) == .none)
  check("promo: a host known not to be Windows is not sold anything", P.banner(linux, dismissed: false, shownBefore: false, shownThisLaunch: false) == .none && !P.recommends(linux))
  check("promo: dismissed stays dismissed", P.banner(gfe, dismissed: true, shownBefore: false, shownThisLaunch: false) == .none)
  check("promo: shown on an earlier launch does not come back", P.banner(gfe, dismissed: false, shownBefore: true, shownThisLaunch: false) == .none)
  check("promo: shown this launch stays until dismissed", P.banner(gfe, dismissed: false, shownBefore: true, shownThisLaunch: true) == .windows)
}
// ---- Foundation Sunshine update hint
do {
  typealias U = DeckFsUpdateRules
  check("update: a host with no Fs* capability (2026.1110.165906) is behind", U.reason(isFoundation: true, fsCapability: 0, kindSeen: nil) == .oldCapability)
  check("update: a host on 2026.1111.001644 (capability 1, FsKind) is not behind", U.reason(isFoundation: true, fsCapability: 1, kindSeen: true) == nil)
  check("update: capability current but the app list has no FsKind is behind", U.reason(isFoundation: true, fsCapability: 1, kindSeen: false) == .noFsKind)
  check("update: app list not read yet does not decide", U.reason(isFoundation: true, fsCapability: 1, kindSeen: nil) == nil)
  check("update: other software is never told to update Foundation", U.reason(isFoundation: false, fsCapability: 0, kindSeen: false) == nil)
  check("update: the date of the version is not used", U.reason(isFoundation: true, fsCapability: 1, kindSeen: true) == U.reason(isFoundation: true, fsCapability: 1, kindSeen: true))
  let tok = U.token(version: "2026.1110.165906", fsCapability: 0)
  check("update: shown once, not again on a later launch", U.shouldShow(reason: .oldCapability, token: tok, dismissedFor: nil, shownFor: tok, shownThisLaunch: false) == false)
  check("update: stays this launch until dismissed", U.shouldShow(reason: .oldCapability, token: tok, dismissedFor: nil, shownFor: tok, shownThisLaunch: true))
  check("update: dismissed for this version", !U.shouldShow(reason: .oldCapability, token: tok, dismissedFor: tok, shownFor: tok, shownThisLaunch: true))
  let next = U.token(version: "2026.1111.001644", fsCapability: 0)
  check("update: dismissed for an older version, behind again on a newer one: comes back", U.shouldShow(reason: .noFsKind, token: next, dismissedFor: tok, shownFor: tok, shownThisLaunch: false))
  check("update: token falls back to the capability level", U.token(version: "", fsCapability: 0) == "cap0")
}
// ---- coloured tile on the selection
do {
  typealias Sel = DeckSelectionRules
  func rgb(_ r: Double, _ g: Double, _ b: Double) -> Sel.RGB { Sel.RGB(r: r / 255, g: g / 255, b: b / 255) }
  let accent = rgb(10, 132, 255)           // systemBlue, the default accent (light appearance: 0,122,255)
  let accentLight = rgb(0, 122, 255)
  let palette: [(String, Sel.RGB, Bool)] = [   // name, system colour (light), expected lift
    ("blue", rgb(0, 122, 255), true), ("teal", rgb(48, 176, 199), false), ("indigo", rgb(88, 86, 214), true),
    ("green", rgb(52, 199, 89), false), ("orange", rgb(255, 149, 0), false), ("red", rgb(255, 59, 48), false),
    ("yellow", rgb(255, 204, 0), false), ("pink", rgb(255, 45, 85), false), ("purple", rgb(175, 82, 222), true), ("gray", rgb(142, 142, 147), false)]
  for (name, color, lift) in palette {
    let e = Sel.deltaE(color, Sel.blend(color, over: accentLight, alpha: 0.16))
    print(String(format: "  info: %@ on the blue selection: dE76 = %.1f", name, e))
    check("selection: \(name) lift = \(lift)", Sel.needsLift(tint: color, selection: accentLight) == lift)
  }
  check("selection: same colour has dE 0", Sel.deltaE(accent, accent) == 0)
  check("selection: a green accent lifts the green tile, not the blue one", Sel.needsLift(tint: rgb(52, 199, 89), selection: rgb(48, 209, 88)) && !Sel.needsLift(tint: rgb(0, 122, 255), selection: rgb(48, 209, 88)))
}
// ---- app list refresh
do {
  typealias A = DeckAppListRules
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  func ago(_ s: Double) -> Date { now.addingTimeInterval(-s) }
  check("applist: the etag changed on the host: fetch", A.due(online: true, wasOnline: true, seenEtag: "2071564129", fetchedEtag: "2255081545", lastFetch: ago(30), now: now) == .etagChanged)
  check("applist: same etag: nothing", A.due(online: true, wasOnline: true, seenEtag: "5", fetchedEtag: "5", lastFetch: ago(500), now: now) == nil)
  check("applist: an etag change is not retried every tick", A.due(online: true, wasOnline: true, seenEtag: "6", fetchedEtag: "5", lastFetch: ago(3), now: now) == nil)
  check("applist: host with no etag: fetched every 60 s", A.due(online: true, wasOnline: true, seenEtag: nil, fetchedEtag: nil, lastFetch: ago(61), now: now) == .interval)
  check("applist: host with no etag, fetched 20 s ago: not yet", A.due(online: true, wasOnline: true, seenEtag: nil, fetchedEtag: nil, lastFetch: ago(20), now: now) == nil)
  check("applist: offline to online fetches", A.due(online: true, wasOnline: false, seenEtag: "5", fetchedEtag: "5", lastFetch: ago(5), now: now) == .online)
  check("applist: offline asks nothing", A.due(online: false, wasOnline: false, seenEtag: "6", fetchedEtag: "5", lastFetch: nil, now: now) == nil)
  check("applist: never fetched and an etag is known: fetch", A.due(online: true, wasOnline: true, seenEtag: "6", fetchedEtag: nil, lastFetch: nil, now: now) == .etagChanged)
}
// ---- cold start
do {
  typealias P = DeckPresenceRules
  check("presence: unknown and last seen on shows on", P.shownOnline(state: 0, lastOnline: true))
  check("presence: unknown and never seen shows off", !P.shownOnline(state: 0, lastOnline: false))
  check("presence: found off shows off whatever was before", !P.shownOnline(state: 1, lastOnline: true))
  check("presence: online shows on", P.shownOnline(state: 2, lastOnline: false))
  check("hero: not grey while the answer is out", !P.greyHero(state: 0))
  check("hero: grey only when found off", P.greyHero(state: 1) && !P.greyHero(state: 2))
}
do {
  typealias S = DeckChipStability
  func chip(_ id: String, _ title: String, _ trailing: String? = nil, unreachable: Bool = false) -> DeckChipSnap {
    DeckChipSnap(id: id, title: title, symbol: "wifi", trailing: trailing, unreachable: unreachable, target: id, members: [id])
  }
  let keys = ["a:1", "b:2", "c:3"]
  let memory = DeckChipMemoryEntry(keys: keys, chips: [chip("route.auto", "自动"), chip("route.1", "局域网 a", "3 ms"), chip("route.2", "域名 b", "20 ms"), chip("route.3", "内网 c", nil, unreachable: true)])
  // the first answer is in, the paths are classified from less than they will be, the slow one is out
  let early = [chip("route.auto", "自动"), chip("route.0", "组网 a", nil), chip("route.2", "域名 b", "20 ms"), chip("route.3", "内网 c")]
  let held = S.choose(live: early, liveKeys: keys, remembered: memory, complete: false, waited: 1)
  check("chips: while answers are out the remembered ones are drawn", held.fromMemory && held.chips == memory.chips && held.pending)
  check("chips: the order of the remembered ones is kept", held.chips.map { $0.id } == ["route.auto", "route.1", "route.2", "route.3"])
  let done = S.choose(live: early, liveKeys: keys, remembered: memory, complete: true, waited: 2)
  check("chips: once everything is in the live ones replace them", !done.fromMemory && done.chips == early && !done.pending)
  let late = S.choose(live: early, liveKeys: keys, remembered: memory, complete: false, waited: 9)
  check("chips: an address that never answers does not hold the row for ever", !late.fromMemory && !late.pending)
  let added = S.choose(live: early, liveKeys: keys + ["d:4"], remembered: memory, complete: false, waited: 1)
  check("chips: a changed set of addresses is not hidden behind the old row", !added.fromMemory)
  let none = S.choose(live: early, liveKeys: keys, remembered: nil, complete: false, waited: 1)
  check("chips: no memory draws the live ones, pending", !none.fromMemory && none.pending && none.chips == early)
  check("chips: key order does not matter", S.choose(live: early, liveKeys: ["c:3", "a:1", "b:2"], remembered: memory, complete: false, waited: 1).fromMemory)
  check("chips: save when complete and nothing stored", S.shouldSave(live: early, liveKeys: keys, remembered: nil, complete: true, sinceLastSave: 0))
  check("chips: no save before the results are in", !S.shouldSave(live: early, liveKeys: keys, remembered: memory, complete: false, sinceLastSave: 60))
  check("chips: no save of the same row", !S.shouldSave(live: memory.chips, liveKeys: keys, remembered: memory, complete: true, sinceLastSave: 60))
  check("chips: a changed row is saved, but not every second", S.shouldSave(live: early, liveKeys: keys, remembered: memory, complete: true, sinceLastSave: 60) && !S.shouldSave(live: early, liveKeys: keys, remembered: memory, complete: true, sinceLastSave: 1))
  check("chips: a chip survives the trip through the plist", DeckChipMemoryEntry(dictionary: memory.dictionary) == memory)
  check("chips: nothing awaited from a computer found off", S.evidenceComplete(offline: true, rows: [(false, false, false, false, false)]))
  check("chips: a row without a result is not complete", !S.evidenceComplete(offline: false, rows: [(true, false, true, false, false), (false, false, false, false, false)]))
  check("chips: an answer whose round trip is still out is not complete", !S.evidenceComplete(offline: false, rows: [(true, false, false, false, false)]))
  check("chips: an unresolved name is not complete", !S.evidenceComplete(offline: false, rows: [(true, false, true, true, false)]))
  check("chips: all in is complete", S.evidenceComplete(offline: false, rows: [(true, false, true, true, true), (false, true, false, false, false)]))
}
do {
  typealias R = DeckArtRecheckRules
  check("art: a host updated since the picture was recorded: ask again", R.hostSoftwareChanged(recorded: "Sunshine 2026.1110", current: "Sunshine 2026.1111"))
  check("art: same software: no extra ask", !R.hostSoftwareChanged(recorded: "Sunshine 2026.1111", current: "Sunshine 2026.1111"))
  check("art: recorded before the software was noted: asked once", R.hostSoftwareChanged(recorded: nil, current: "Sunshine 2026.1111"))
  check("art: the host did not say: no extra ask", !R.hostSoftwareChanged(recorded: "Sunshine 2026.1111", current: ""))
}
// ---- the running app's green
do {
  typealias G = DeckRunGreenRules
  let white: G.RGB = (1, 1, 1), lightScrim: G.RGB = (0.96, 0.96, 0.97), darkPage: G.RGB = (0.118, 0.118, 0.125), black: G.RGB = (0, 0, 0)
  // the card band: black from 58 % to 82 % over the art, about 70 % at the title; the brightest art is white
  let worstBand: G.RGB = (0.30, 0.30, 0.30)   // white under 70 % black
  check("green: on the dark scrim >= 3 against the lightest art under the band (a graphic)", G.contrast(G.onDarkScrim, worstBand) >= 3, "\(G.contrast(G.onDarkScrim, worstBand))")
  check("green: on the dark scrim against black", G.contrast(G.onDarkScrim, black) >= 4.5)
  check("green: light page >= 3 against white (a graphic)", G.contrast(G.onLightPage, white) >= 3, "\(G.contrast(G.onLightPage, white))")
  check("green: light page >= 4.5 against white (beside text)", G.contrast(G.onLightPage, white) >= 4.5, "\(G.contrast(G.onLightPage, white))")
  check("green: light page >= 3 against the grey window", G.contrast(G.onLightPage, lightScrim) >= 3)
  check("green: dark page >= 4.5 against the dark window", G.contrast(G.onDarkPage, darkPage) >= 4.5)
}
// ---- 网卡
do {
  func raw(_ name: String, _ index: UInt32, ipv4: String?, wifi: Bool = false, up: Bool = true, running: Bool = true) -> DeckNic.Raw {
    DeckNic.Raw(name: name, index: index, up: up, running: running, ipv4: ipv4, isWifi: wifi)
  }
  let system = [
    raw("lo0", 1, ipv4: "127.0.0.1"), raw("utun0", 5, ipv4: nil), raw("utun3", 8, ipv4: nil), raw("awdl0", 9, ipv4: nil),
    raw("bridge0", 12, ipv4: nil), raw("en0", 14, ipv4: "10.200.0.12", wifi: true), raw("en10", 20, ipv4: "10.1.0.8"),
    raw("en5", 18, ipv4: "10.0.0.4"), raw("en6", 19, ipv4: "169.254.3.3"), raw("en7", 21, ipv4: "10.1.1.1", up: false),
    raw("en8", 22, ipv4: "10.1.1.2", running: false), raw("utun10", 30, ipv4: "198.18.0.1"), raw("utun4", 31, ipv4: "100.64.0.9"),
  ]
  let list = DeckNic.interfaces(system)
  check("nic: list is physical first (numeric name order), then tunnels", list.map { $0.name } == ["en0", "en5", "en10", "utun4", "utun10"], "\(list.map { $0.name })")
  check("nic: loopback, awdl, bridge, link-local, down and not-running interfaces are not listed", !list.contains { ["lo0", "awdl0", "bridge0", "en6", "en7", "en8", "utun0", "utun3"].contains($0.name) })
  check("nic: the one flagged Wi-Fi is Wi-Fi, other en* are Ethernet", list[0].kind == .wifi && list[1].kind == .ethernet && list[2].kind == .ethernet)
  check("nic: label of Wi-Fi is type + name + IPv4", DeckNic.label(list[0], kindWord: "Wi-Fi") == "Wi-Fi en0 · 10.200.0.12")
  check("nic: label of an Ethernet interface", DeckNic.label(list[1], kindWord: "以太网") == "以太网 en5 · 10.0.0.4")
  check("nic: label of a tunnel has no address", DeckNic.label(list[4], kindWord: "隧道") == "隧道 utun10")
  check("nic: indexes are carried", list[0].index == 14 && list[4].index == 30)
  check("nic: nothing saved is 自动", DeckNic.choice(saved: nil, in: list) == .automatic && DeckNic.choice(saved: "", in: list) == .automatic && DeckNic.choice(saved: "Auto", in: list) == .automatic)
  check("nic: a saved name that is listed is that interface", DeckNic.choice(saved: "en5", in: list) == .interface(list[1]))
  check("nic: a saved name that is gone stays chosen and missing (no swap to another)", DeckNic.choice(saved: "en9", in: list) == .missing("en9"))
  check("nic: the index changing across runs does not change the choice (the name is the identity)",
        DeckNic.choice(saved: "en0", in: DeckNic.interfaces([raw("en0", 99, ipv4: "10.200.0.12", wifi: true)])) == .interface(DeckNic.Interface(name: "en0", index: 99, kind: .wifi, ipv4: "10.200.0.12")))
}
// ---- 经代理: a PUBLIC address through a fake-IP TUN; a private address through a TUN is the user's own 组网
do {
  check("proxy: 198.18.0.1 and 198.19.255.254 are fake-IP, 198.20.0.1 and 198.17.255.255 are not", DeckNic.isFakeIP("198.18.0.1") && DeckNic.isFakeIP("198.19.255.254") && !DeckNic.isFakeIP("198.20.0.1") && !DeckNic.isFakeIP("198.17.255.255"))
  check("proxy: nil and nonsense are not fake-IP", !DeckNic.isFakeIP(nil) && !DeckNic.isFakeIP("") && !DeckNic.isFakeIP("utun10"))
  let publicProxy = verdict("203.0.113.79:57989") { $0.egressIsTunnel = true; $0.egressSourceIPv4 = "198.18.0.1"; $0.tested = true }
  check("proxy: public address + TUN with a 198.18/15 address is 经代理", publicProxy.evidence == .proxyTunnel && DeckPathWords.word(publicProxy, ep("203.0.113.79:57989")) == .proxy)
  let domainProxy = verdict("pc.example.net:57989") { $0.resolvedIPs = ["203.0.113.79"]; $0.egressIsTunnel = true; $0.egressSourceIPv4 = "198.18.0.1" }
  check("proxy: a domain that resolves to a public address counts the same", DeckPathWords.word(domainProxy, ep("pc.example.net:57989")) == .proxy)
  let privateOverTun = verdict("10.100.0.133:57989") { $0.egressIsTunnel = true; $0.egressSourceIPv4 = "198.18.0.1"; $0.tested = true }
  check("proxy: a PRIVATE address through the same TUN stays 组网 (a Hysteria2 mesh)", privateOverTun.evidence == .tunnelInterface && DeckPathWords.word(privateOverTun, ep("10.100.0.133:57989")) == .overlay)
  let publicOtherTun = verdict("203.0.113.79:57989") { $0.egressIsTunnel = true; $0.egressSourceIPv4 = "10.8.0.2" }
  check("proxy: a public address through a TUN that is not fake-IP is not called a proxy", publicOtherTun.evidence == .tunnelInterface)
  let publicNoSource = verdict("203.0.113.79:57989") { $0.egressIsTunnel = true }
  check("proxy: no source address known: not called a proxy", publicNoSource.evidence == .tunnelInterface)
  let publicPhysical = verdict("203.0.113.79:57989") { $0.egressIsTunnel = false; $0.egressSourceIPv4 = "198.18.0.1" }
  check("proxy: a physical egress is never a proxy whatever the source says", publicPhysical.evidence != .proxyTunnel)
}
// ---- latency figures: a sentinel is never a number
do {
  check("latency: -1 (reachable, no number) is not shown", DeckLatencyRules.valid(-1) == nil)
  check("latency: -2 (could not measure) is not shown", DeckLatencyRules.valid(-2) == nil)
  check("latency: 0 is not shown", DeckLatencyRules.valid(0) == nil)
  check("latency: nil is not shown", DeckLatencyRules.valid(nil) == nil)
  check("latency: 1 and 22 are real", DeckLatencyRules.valid(1) == 1 && DeckLatencyRules.valid(22) == 22)
}
print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
