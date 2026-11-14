import Foundation
var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
  if !ok { failures += 1 }
  print("\(ok ? "PASS" : "FAIL") \(name)\(ok ? "" : " — " + detail())")
}

/// The flat tags of a serverinfo answer, the way ServerInfoResponse.getStringTag sees them.
final class Tags: NSObject, XMLParserDelegate {
  var values: [String: String] = [:]
  private var stack: [String] = []
  private var text = ""
  func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
    stack.append(name); text = ""
  }
  func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
  func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
    if stack.count == 2 { values[name] = text }
    stack.removeLast(); text = ""
  }
  static func read(_ path: String) -> [String: String] {
    let parser = XMLParser(data: FileManager.default.contents(atPath: path)!)
    let tags = Tags(); parser.delegate = tags
    precondition(parser.parse(), "fixture \(path) is not valid XML: \(String(describing: parser.parserError))")
    return tags.values
  }
}

typealias R = HostEventsRules
typealias S = DeckHostSoftware
let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "tests/fixtures"
let cap2 = Tags.read("\(dir)/host-cap2-serverinfo.xml")
let cap1 = Tags.read("\(dir)/host-cap1-serverinfo.xml")
let real165906 = Tags.read("\(dir)/gaming-pc-serverinfo-165906.xml")

func events(_ t: [String: String]) -> Bool { R.eventsEnabled(capability: t["FsCapabilityVersion"], features: t["FsFeatures"]) }

// ---- the fixtures say what they should
check("cap2 fixture: capability 2, events listed, counter, session start, avatar version",
      cap2["FsCapabilityVersion"] == "2" && cap2["FsFeatures"]!.contains("events") && cap2["FsEventSeq"] == "7" &&
      cap2["FsSessionStarted"] == "1794400000" && cap2["FsHostAvatarVersion"] == "3")
check("cap1 fixture: capability 1 and none of the cap 2 fields",
      cap1["FsCapabilityVersion"] == "1" && cap1["FsEventSeq"] == nil && cap1["FsSessionStarted"] == nil && cap1["FsHostAvatarVersion"] == nil && !cap1["FsFeatures"]!.contains("events"))
check("the real 2026.1110.165906 serverinfo has no Fs* tag at all", real165906.keys.filter { $0.hasPrefix("Fs") }.isEmpty)

// ---- is the events long-poll on
check("cap2 host with events: on", events(cap2))
check("cap1 host: off", !events(cap1))
check("real 165906 host (no Fs*): off", !events(real165906))
check("capability 2 without the events feature: off", !R.eventsEnabled(capability: "2", features: "profile,appfacts,art"))
check("capability 3 with events: on", R.eventsEnabled(capability: "3", features: "events"))
check("feature match ignores case and neighbours", R.eventsEnabled(capability: "2", features: "Profile,EVENTS"))
check("capability 1 listing events is still off (no capability, no events)", !R.eventsEnabled(capability: "1", features: "events"))
check("garbage capability is off", !R.eventsEnabled(capability: "two", features: "events") && !R.eventsEnabled(capability: "", features: "events") && !R.eventsEnabled(capability: nil, features: nil))
check("a counter and a capability read like the Objective-C integerValue", R.integer("7") == 7 && R.integer("") == 0 && R.integer(nil) == 0 && R.integer("x") == 0 && R.integer("2abc") == 2)

// ---- how often an online host is asked
check("events host: long-poll re-arms every second", R.refreshInterval(eventsEnabled: events(cap2)) == 1.0)
check("cap1 host: quiet refresh every 30 s (the fallback)", R.refreshInterval(eventsEnabled: events(cap1)) == 30.0)

// ---- one long-poll answer
func answer(_ t: [String: String]?, previous: Int, elapsed: Double) -> HostEventsAnswer {
  R.answer(valid: t != nil, previousSeq: previous, answeredSeq: R.integer(t?["FsEventSeq"]), elapsed: elapsed)
}
do {
  let a = answer(cap2, previous: 5, elapsed: 12)
  check("counter moved after a real wait: news, counter follows, events stay on", a.accepted && a.changed && a.nextSeq == 7 && a.eventsStillEnabled)
  let b = answer(cap2, previous: 7, elapsed: 25)
  check("same counter after the full wait: nothing new, events stay on", b.accepted && !b.changed && b.nextSeq == 7 && b.eventsStillEnabled)
  let c = answer(cap2, previous: 7, elapsed: 0.05)
  check("same counter answered at once: the host ignored fsWait, fall back to the quiet refresh", c.accepted && !c.changed && c.nextSeq == 7 && !c.eventsStillEnabled)
  let d = answer(cap2, previous: 0, elapsed: 0.05)
  check("first poll (counter 0) answered at once with a counter: that is news, events stay on", d.changed && d.nextSeq == 7 && d.eventsStillEnabled)
  let e = answer(cap2, previous: 9, elapsed: 3)
  check("host restarted (counter went down): news, the lower counter is the new one", e.changed && e.nextSeq == 7 && e.eventsStillEnabled)
  var noSeq = cap2; noSeq["FsEventSeq"] = nil
  let f = answer(noSeq, previous: 7, elapsed: 20)
  check("an answer without a counter keeps the old one and is not news", !f.changed && f.nextSeq == 7 && f.eventsStillEnabled)
  let g = answer(noSeq, previous: 7, elapsed: 0.1)
  check("an instant answer without a counter: fall back", !g.changed && !g.eventsStillEnabled)
  let h = answer(cap1, previous: 0, elapsed: 0.2)
  check("a cap1 host answering the long-poll URL as a plain serverinfo: no news, fall back", h.accepted && !h.changed && h.nextSeq == 0 && !h.eventsStillEnabled)
  let i = answer(nil, previous: 7, elapsed: 0.1)
  check("failure within a second: the host does not know the request, fall back", !i.accepted && i.nextSeq == 7 && !i.eventsStillEnabled)
  let j = answer(nil, previous: 7, elapsed: 30)
  check("failure after a long wait (link dropped): events stay on, the round retries", !j.accepted && j.nextSeq == 7 && j.eventsStillEnabled)
  let wrongHost = R.answer(valid: false, previousSeq: 7, answeredSeq: 0, elapsed: 5)
  check("an answer from another host is not accepted and does not move the counter", !wrongHost.accepted && wrongHost.nextSeq == 7)
}

// ---- a whole run of the worker's decisions: cap2 then the host stops sending events; cap1 from the start
do {
  var seq = 0, on = events(cap2)
  var script: [(Double, Int)] = [(0.2, 7), (20, 8), (25, 8), (30, 9), (0.1, 9)]   // elapsed, answered counter
  var newsCount = 0
  while on, let (elapsed, answered) = script.first {
    script.removeFirst()
    let a = R.answer(valid: true, previousSeq: seq, answeredSeq: answered, elapsed: elapsed)
    seq = a.nextSeq; on = a.eventsStillEnabled
    if a.changed { newsCount += 1 }
  }
  check("cap2 run: news on the first answer, two more counter moves, then an instant answer ends the events", newsCount == 3 && seq == 9 && !on && R.refreshInterval(eventsEnabled: on) == 30)
  check("cap1 run: never starts the long-poll", !events(cap1) && R.refreshInterval(eventsEnabled: events(cap1)) == 30)
}

// ---- what the client reads from the two hosts, with the rules it applies (DeckRules)
do {
  let isFoundation2 = (Int(cap2["FsCapabilityVersion"] ?? "") ?? 0) > 0 || (Int(cap2["VddCapabilityVersion"] ?? "") ?? 0) > 0
  let isFoundation1 = (Int(cap1["FsCapabilityVersion"] ?? "") ?? 0) > 0 || (Int(cap1["VddCapabilityVersion"] ?? "") ?? 0) > 0
  check("both are recognised as Foundation Sunshine by capability", isFoundation1 && isFoundation2)
  let i2 = S.classify(isFoundation: true, sunshineVersion: cap2["SunshineVersion"]!, gfeVersion: cap2["GfeVersion"]!, state: cap2["state"]!, platform: "")
  check("cap2 host label: three numeric parts, hover has the 杂鱼", S.title(i2, names: S.Names()) == "Foundation Sunshine 2026.1112.025657" && S.detail(i2, names: S.Names()) == "Foundation Sunshine 2026.1112.025657.杂鱼")
  check("cap2 host is not told to update (capability above what the client knows)", DeckFsUpdateRules.reason(isFoundation: true, fsCapability: 2, kindSeen: true) == nil)
  check("cap2 host before its app list is read: not told to update either", DeckFsUpdateRules.reason(isFoundation: true, fsCapability: 2, kindSeen: nil) == nil)
  check("cap1 host is current too", DeckFsUpdateRules.reason(isFoundation: true, fsCapability: 1, kindSeen: true) == nil)
  check("a host without Fs* (165906) is still behind", DeckFsUpdateRules.reason(isFoundation: true, fsCapability: 0, kindSeen: nil) == .oldCapability)
}

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
