import Foundation

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
  if !ok { failures += 1 }
  print("\(ok ? "PASS" : "FAIL") \(name)\(ok ? "" : " — " + detail())")
}

typealias P = UpdateVersionPolicy

// The legacy comparison: numeric, dot-separated, 1.3.9-rc.N below 1.3.9 (what Sparkle's version comparator gives).
func parts(_ v: String) -> [Int] {
  var s = v.hasPrefix("v") ? String(v.dropFirst()) : v
  var pre = Int.max
  if let r = s.range(of: #"-(rc|beta|alpha)[.-]([0-9]+)$"#, options: .regularExpression) {
    pre = Int(s[r].split(whereSeparator: { !$0.isNumber }).last ?? "") ?? 0
    s = String(s[s.startIndex..<r.lowerBound])
  }
  return s.split(separator: ".").map { Int($0) ?? 0 } + [pre]
}
func legacyNewer(_ a: String, _ b: String) -> Bool { parts(a).lexicographicallyPrecedes(parts(b)) == false && parts(a) != parts(b) }

let ts1 = "v2026.1124.103317"
let ts2 = "v2026.1201.90000"

// MARK: timestamp versions
check("timestamp tag", P.isTimestampVersion(ts1) && P.isTimestampVersion("2026.1124.103317") && P.isTimestampVersion("v2026.105.5"))
check("not timestamp", !P.isTimestampVersion("v1.3.9") && !P.isTimestampVersion("v2.0.0") && !P.isTimestampVersion("v1.3.9-rc.10")
  && !P.isTimestampVersion("v2026.1124") && !P.isTimestampVersion("v2026.1124.1033170"))

// MARK: channel filter (a)
check("stable build skips pre-release", !P.isEligible(tag: "v1.3.9-rc.10", prerelease: true, acceptsPrereleases: false))
check("stable build skips timestamp build", !P.isEligible(tag: ts1, prerelease: true, acceptsPrereleases: false))
check("stable build skips timestamp build even without the pre-release flag", !P.isEligible(tag: ts1, prerelease: false, acceptsPrereleases: false))
check("stable build sees stable", P.isEligible(tag: "v2.0.0", prerelease: false, acceptsPrereleases: false))
check("beta build sees everything", P.isEligible(tag: ts1, prerelease: true, acceptsPrereleases: true) && P.isEligible(tag: "v2.0.0", prerelease: false, acceptsPrereleases: true))

// MARK: appcast parsing
func appcast(_ items: String) -> Data {
  Data("""
  <?xml version="1.0" standalone="yes"?>
  <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel><title>t</title>\(items)</channel></rss>
  """.utf8)
}
let betaItem = """
<item><title>2026.1124.103317</title><sparkle:version>1740</sparkle:version><sparkle:shortVersionString>2026.1124.103317</sparkle:shortVersionString>
<sparkle:channel>beta</sparkle:channel><description><![CDATA[<p>x &amp; y</p>]]></description>
<enclosure url="https://github.com/skyhua0224/moonlight-macos-enhanced/releases/download/v2026.1124.103317/Moonlight-macOS-Enhanced-universal.dmg" length="1" type="application/octet-stream" sparkle:edSignature="x"/></item>
"""
let stableItem = """
<item><title>1.3.9</title><sparkle:version>1726</sparkle:version><sparkle:shortVersionString>1.3.9</sparkle:shortVersionString>
<enclosure url="https://github.com/skyhua0224/moonlight-macos-enhanced/releases/download/v1.3.9/Moonlight-macOS-Enhanced-universal.dmg" length="1" type="application/octet-stream"/></item>
"""
let attrItem = """
<item><title>1.3.8</title><enclosure url="https://x/y.dmg" sparkle:version="1650" sparkle:shortVersionString="1.3.8" length="1" type="a"/></item>
"""
check("beta appcast build", P.buildNumber(appcast: appcast(betaItem), includingBeta: true) == 1740)
check("stable build ignores a beta item", P.buildNumber(appcast: appcast(betaItem), includingBeta: false) == nil)
check("stable appcast build", P.buildNumber(appcast: appcast(stableItem), includingBeta: false) == 1726)
check("highest of several items", P.buildNumber(appcast: appcast(stableItem + betaItem), includingBeta: true) == 1740)
check("beta channel off keeps the stable item", P.buildNumber(appcast: appcast(stableItem + betaItem), includingBeta: false) == 1726)
check("enclosure attribute form", P.buildNumber(appcast: appcast(attrItem), includingBeta: false) == 1650)
check("garbage is nil", P.buildNumber(appcast: Data("not xml <".utf8), includingBeta: true) == nil)
check("no items is nil", P.buildNumber(appcast: appcast(""), includingBeta: true) == nil)

// MARK: appcast URL
let base = "https://github.com/skyhua0224/moonlight-macos-enhanced/releases/download"
check("appcast url ok", P.appcastURL(from: "\(base)/\(ts1)/appcast.xml") != nil)
check("appcast url rejects other repo", P.appcastURL(from: "https://github.com/evil/moonlight-macos-enhanced/releases/download/v1/appcast.xml") == nil)
check("appcast url rejects other host", P.appcastURL(from: "https://example.com/skyhua0224/moonlight-macos-enhanced/releases/download/v1/appcast.xml") == nil)
check("appcast url rejects other file", P.appcastURL(from: "\(base)/\(ts1)/Moonlight-macOS-Enhanced-universal.dmg") == nil)
check("appcast url rejects http and query", P.appcastURL(from: "http://github.com/skyhua0224/moonlight-macos-enhanced/releases/download/v1/appcast.xml") == nil
  && P.appcastURL(from: "\(base)/v1/appcast.xml?x=1") == nil)

// MARK: isNewer
func newer(_ cand: String, _ cb: Int?, _ cur: String, _ curb: Int?) -> Bool {
  P.isNewer(candidate: cand, candidateBuild: cb, current: cur, currentBuild: curb, legacyNewer: legacyNewer)
}
check("legacy compare sanity: timestamp > 1.3.9", legacyNewer(ts1, "1.3.9"))
check("legacy compare sanity: timestamp > 2.0.0 (the problem)", legacyNewer(ts1, "v2.0.0"))
// (b) a user on the timestamp build gets 2.0.0 although its version is smaller
check("(b) timestamp beta -> 2.0.0 by build", newer("v2.0.0", 1900, ts1, 1740))
check("timestamp beta does not downgrade to 1.3.9", !newer("v1.3.9", 1726, ts1, 1740))
check("timestamp beta -> next timestamp beta", newer(ts2, 1760, ts1, 1740))
check("same build is not an update", !newer(ts1, 1740, ts1, 1740))
// (c) old rc users get the first timestamp beta
check("(c) 1.3.9-rc.10 -> timestamp beta by build", newer(ts1, 1740, "1.3.9-rc.10", 1690))
check("(c) 1.3.9-rc.10 -> timestamp beta by version when no build", newer(ts1, nil, "1.3.9-rc.10", 1690))
check("stable 1.3.9 -> 2.0.0", newer("v2.0.0", 1900, "1.3.9", 1726))
check("stable 1.3.9 is current", !newer("v1.3.9", 1726, "1.3.9", 1726))
check("no build falls back to version", newer("v2.0.0", nil, "1.3.9", 1726) && !newer("v1.3.9", nil, "1.3.9", 1726))

// MARK: choose
func rel(_ tag: String, _ pre: Bool, _ build: Int?) -> P.Release { P.Release(tag: tag, prerelease: pre, publishedAt: nil, build: build) }
let list = [rel("v1.3.9", false, 1726), rel("v1.3.9-rc.10", true, 1690), rel(ts1, true, 1740)]
check("stable channel never picks the timestamp beta", P.choose(list, acceptsPrereleases: false, legacyNewer: legacyNewer)?.tag == "v1.3.9")
check("beta channel picks the timestamp beta", P.choose(list, acceptsPrereleases: true, legacyNewer: legacyNewer)?.tag == ts1)
let withStable2 = list + [rel("v2.0.0", false, 1900)]
check("beta channel picks 2.0.0 over an older timestamp beta", P.choose(withStable2, acceptsPrereleases: true, legacyNewer: legacyNewer)?.tag == "v2.0.0")
check("stable channel picks 2.0.0", P.choose(withStable2, acceptsPrereleases: false, legacyNewer: legacyNewer)?.tag == "v2.0.0")
let noBuilds = [rel("v1.3.9", false, nil), rel("v1.3.9-rc.10", true, nil), rel(ts1, true, nil)]
check("no builds: legacy order", P.choose(noBuilds, acceptsPrereleases: true, legacyNewer: legacyNewer)?.tag == ts1
  && P.choose(noBuilds, acceptsPrereleases: false, legacyNewer: legacyNewer)?.tag == "v1.3.9")
let mixed = [rel("v2.0.0", false, 1900), rel(ts1, true, nil)]
check("a known build beats an unknown one", P.choose(mixed, acceptsPrereleases: true, legacyNewer: legacyNewer)?.tag == "v2.0.0")
check("nothing eligible", P.choose([rel(ts1, true, 1740)], acceptsPrereleases: false, legacyNewer: legacyNewer) == nil)

// MARK: feed order
let feedList = ["gh", "cnb", "branch"]
check("beta build reads the branch feed first", P.orderedFeeds(feedList, branchFeed: "branch", acceptsPrereleases: true) == ["branch", "gh", "cnb"])
check("stable build keeps the order", P.orderedFeeds(feedList, branchFeed: "branch", acceptsPrereleases: false) == feedList)

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
