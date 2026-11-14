import Foundation

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
  if !ok { failures += 1 }
  print("\(ok ? "PASS" : "FAIL") \(name)\(ok ? "" : " — " + detail())")
}

// MARK: - a host and a client, as AppAssetManager.retrieveAssetsFromHost + AppAssetRetriever.main work

/// The host: what its app list announces, and what /appasset serves under which ETag. ETag = "<version>-hero".
struct Host {
  var software = "Sunshine 2026.1111.200000"
  var listVersion = "100"
  var listArt = "hero"
  var servedBytes = "OLD-HERO"
  var servedVersion = "100"        // the version in the ETag the host answers with
  var requests = 0

  struct Response { var status: Int; var etag: String?; var modified: String?; var bytes: String? }

  /// The host compares If-None-Match with the ETag it would send now: a match is a 304.
  mutating func appasset(ifNoneMatch: String?) -> Response {
    requests += 1
    let etag = "\"\(servedVersion)-hero\""
    if let sent = ifNoneMatch, sent == etag { return Response(status: 304, etag: etag, modified: "Wed, 11 Nov 2026 13:45:36 GMT", bytes: nil) }
    return Response(status: 200, etag: etag, modified: "Wed, 11 Nov 2026 13:45:36 GMT", bytes: servedBytes)
  }
}

/// The client's cache of one hero: the file on disk and its entry in art-meta.plist.
struct Cache {
  var file: String?
  var entry: NSDictionary?
}

/// What one app-list pass does for one picture with the new rules. Returns whether a request was made.
@discardableResult
func pass(_ cache: inout Cache, host: inout Host, at now: Date, listVersion: String? = nil) -> Bool {
  let version = listVersion ?? host.listVersion
  guard AppArtPolicy.needsFetch(entry: cache.entry, fileExists: cache.file != nil, listVersion: version, listArt: host.listArt,
                                hostSoftware: host.software, recheckSeconds: 6 * 3600, now: now) else { return false }
  let afterHostUpdate = cache.entry != nil && cache.entry?["hostSoftware"] as? String != host.software
  var forceFull = false
  var attempts = 0
  while attempts < 5 {
    attempts += 1
    let conditional = !forceFull && AppArtPolicy.canUseValidators(entry: cache.entry, fileExists: cache.file != nil, listVersion: version, hostSoftware: host.software)
    let response = host.appasset(ifNoneMatch: conditional ? cache.entry?["etag"] as? String : nil)
    if response.status == 304 && cache.file != nil && conditional {
      guard let next = AppArtPolicy.entryAfterNotModified(previous: cache.entry!, sentEtag: cache.entry?["etag"] as? String, responseEtag: response.etag,
                                                          responseModified: response.modified, listVersion: version, listArt: host.listArt,
                                                          hostSoftware: host.software, now: now) else { forceFull = true; continue }
      cache.entry = next
      return true
    }
    if response.status == 200, let bytes = response.bytes {
      if cache.file != bytes { cache.file = bytes }
      cache.entry = AppArtPolicy.entryAfterPicture(etag: response.etag, modified: response.modified, sha: "sha-" + bytes, listVersion: version,
                                                   listArt: host.listArt, hostSoftware: host.software, afterHostUpdate: afterHostUpdate, now: now)
      return true
    }
  }
  return true
}

/// The older rules, for the same sequence (conditional whenever the stored version equals the list's;
/// asked again once when the host software differs, conditionally; the 304 written down as seen).
@discardableResult
func legacyPass(_ cache: inout Cache, host: inout Host, at now: Date) -> Bool {
  let version = host.listVersion
  var need = false
  if let e = cache.entry {
    if cache.file == nil { need = true }
    else if !version.isEmpty && e["version"] as? String != version { need = true }
    else if e["hostSoftware"] as? String != host.software { need = true }
    else if now.timeIntervalSince(e["checked"] as! Date) > 6 * 3600 { need = true }
  } else { need = true }
  guard need else { return false }
  let conditional = cache.file != nil && cache.entry != nil && (cache.entry?["version"] as? String == version)
  let response = host.appasset(ifNoneMatch: conditional ? cache.entry?["etag"] as? String : nil)
  if response.status == 304 {
    var next = (cache.entry as? [String: Any]) ?? [:]
    next["etag"] = response.etag; next["version"] = version; next["hostSoftware"] = host.software; next["checked"] = now
    cache.entry = next as NSDictionary
  } else if let bytes = response.bytes {
    cache.file = bytes
    cache.entry = ["etag": response.etag ?? "", "version": version, "hostSoftware": host.software, "checked": now, "sha": "sha-" + bytes] as NSDictionary
  }
  return true
}

let t0 = Date(timeIntervalSince1970: 1_794_000_000)   // 21:45:42 CST
func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

// MARK: - the reported sequence

// 21:45:42 the old host serves the old hero (version 100). 21:46:00 the new host is up. 21:46:54 and
// 21:48:46 app lists follow. A: the host reloads its apps.json at 21:47:30 and the list announces version 200.
do {
  var host = Host(); var cache = Cache()
  pass(&cache, host: &host, at: at(0))
  check("21:45:42 first fetch: old hero on disk, entry version 100", cache.file == "OLD-HERO" && cache.entry?["version"] as? String == "100")

  host.software = "Sunshine 2026.1111.211729"          // 21:46:00: restarted, apps.json not read yet
  let before = host.requests
  pass(&cache, host: &host, at: at(18))
  check("21:46:00 after the host update the first request carries no validators (a 200, not a 304)", host.requests == before + 1 && cache.entry?["provisional"] as? Bool == true)
  let r1 = host.requests
  pass(&cache, host: &host, at: at(72))                 // 21:46:54
  check("21:46:54 (54 s later, list unchanged): nothing is asked", host.requests == r1)

  host.listVersion = "200"; host.servedVersion = "200"; host.servedBytes = "NEW-HERO"   // 21:47:30 apps.json read
  pass(&cache, host: &host, at: at(184))                // 21:48:46 etag-changed list with the new version
  check("21:48:46 list with the new FsArtVersion: the new hero is fetched", cache.file == "NEW-HERO" && cache.entry?["version"] as? String == "200", "\(cache.file ?? "nil") \(String(describing: cache.entry))")
}

// B: the same, the list announces the SAME version after the host reloaded (a host that does not change it)
do {
  var host = Host(); var cache = Cache()
  pass(&cache, host: &host, at: at(0))
  host.software = "Sunshine 2026.1111.211729"
  pass(&cache, host: &host, at: at(18))
  host.servedBytes = "NEW-HERO"                          // reloaded, ETag version unchanged
  pass(&cache, host: &host, at: at(72))
  check("B: 54 s after the host update the provisional picture is not yet asked again", cache.file == "OLD-HERO")
  pass(&cache, host: &host, at: at(184))
  check("B: after a minute one more unconditional fetch finds the new hero under the same version", cache.file == "NEW-HERO" && cache.entry?["provisional"] == nil, "\(cache.file ?? "nil")")
  let r = host.requests
  pass(&cache, host: &host, at: at(300))
  check("B: and then nothing more is asked", host.requests == r)
}

// C: what the log shows: the picture on disk is old, but the stored ETag/version are those of the NEW file
// (written while the old host process answered with the new file's validators). The new host answers a
// conditional request with 304.
do {
  var host = Host(); var cache = Cache()
  host.servedBytes = "OLD-HERO"; host.servedVersion = "200"; host.listVersion = "200"   // old bytes under the new file's ETag
  pass(&cache, host: &host, at: at(0))
  check("C: setup, old bytes on disk with ETag 200-hero", cache.file == "OLD-HERO" && cache.entry?["etag"] as? String == "\"200-hero\"")
  host.software = "Sunshine 2026.1111.211729"; host.servedBytes = "NEW-HERO"             // new host, new bytes, same ETag
  var legacy = cache
  var legacyHost = host
  legacyPass(&legacy, host: &legacyHost, at: at(18))
  legacyPass(&legacy, host: &legacyHost, at: at(72)); legacyPass(&legacy, host: &legacyHost, at: at(184))
  check("C: the old rules stay on the old picture (304 on the conditional request) — this is the bug", legacy.file == "OLD-HERO", "\(legacy.file ?? "nil")")
  pass(&cache, host: &host, at: at(18))
  check("C: the new rules fetch without validators after the host update and get the new picture", cache.file == "NEW-HERO", "\(cache.file ?? "nil")")
}

// D: a 304 that is about some other file than the list announces is not taken as seen
do {
  var host = Host(); var cache = Cache()
  pass(&cache, host: &host, at: at(0))                  // version 100 on disk
  // the host (not reloaded, same software) answers a conditional request for 100 with 304 but names ETag 200
  let previous = cache.entry!
  let next = AppArtPolicy.entryAfterNotModified(previous: previous, sentEtag: "\"100-hero\"", responseEtag: "\"200-hero\"", responseModified: nil,
                                                listVersion: "100", listArt: "hero", hostSoftware: host.software, now: at(10))
  check("D: 304 whose ETag is another version than the list's: nil, fetch in full", next == nil)
  let other = AppArtPolicy.entryAfterNotModified(previous: previous, sentEtag: "\"100-hero\"", responseEtag: "\"100-hero\"", responseModified: nil,
                                                 listVersion: "100", listArt: "hero", hostSoftware: host.software, now: at(10))
  check("D: 304 with the list's ETag is recorded as seen", other?["version"] as? String == "100")
  // a 304 for a list that says 200 while the entry is 100 cannot even be asked conditionally
  check("D: no validators when the list's version differs from the entry's",
        !AppArtPolicy.canUseValidators(entry: previous, fileExists: true, listVersion: "200", hostSoftware: host.software))
  // the list announces 200, the stored version says "unknown" (a 304 that did not verify): the next list fetches
  let unverified = AppArtPolicy.entryAfterNotModified(previous: ["etag": "\"100-hero\"", "version": "100", "hostSoftware": "old", "checked": at(0)] as NSDictionary,
                                                      sentEtag: nil, responseEtag: nil, responseModified: nil, listVersion: "100", listArt: "hero", hostSoftware: "new", now: at(1))
  check("D: a 304 without an ETag still counts for the version it was asked with", unverified?["version"] as? String == "100")
}

// E: the other triggers
do {
  let e: NSDictionary = ["etag": "\"100-hero\"", "version": "100", "art": "hero", "hostSoftware": "s", "checked": at(0), "sha": "x"]
  func need(_ e: NSDictionary?, exists: Bool = true, version: String = "100", art: String = "hero", software: String = "s", after: Double = 10) -> Bool {
    AppArtPolicy.needsFetch(entry: e, fileExists: exists, listVersion: version, listArt: art, hostSoftware: software, recheckSeconds: 6 * 3600, now: at(after))
  }
  check("nothing changed: not asked", !need(e))
  check("never fetched: asked", need(nil))
  check("file missing: asked", need(e, exists: false))
  check("version differs: asked", need(e, version: "101"))
  check("art types differ (a logo is announced now): asked", need(e, art: "hero,logo"))
  check("art types differ (the hero is gone from the list): asked", need(e, art: ""))
  // a Mac after the install: entries of older builds have no "art"; their validators proved nothing
  let oldEntry: NSDictionary = ["etag": "\"1020121028-hero\"", "version": "1020121028", "hostSoftware": "Sunshine 2026.1111.211729", "checked": at(0), "sha": "x"]
  check("entry written before the art list was kept: asked once, same version and software or not",
        need(oldEntry, version: "1020121028", art: "hero", software: "Sunshine 2026.1111.211729"))
  check("... and without validators", !AppArtPolicy.canUseValidators(entry: oldEntry, fileExists: true, listVersion: "1020121028", hostSoftware: "Sunshine 2026.1111.211729"))
  var migrated = Cache(file: "OLD-HERO", entry: oldEntry)
  var migHost = Host(); migHost.software = "Sunshine 2026.1111.211729"; migHost.listVersion = "1020121028"; migHost.servedVersion = "1020121028"; migHost.servedBytes = "NEW-HERO"
  pass(&migrated, host: &migHost, at: at(0))
  check("a cache after the update (old bytes, entry says current): the new hero comes", migrated.file == "NEW-HERO" && migrated.entry?["art"] as? String == "hero", "\(migrated.file ?? "nil")")
  let rq = migHost.requests
  pass(&migrated, host: &migHost, at: at(100))
  check("... once", migHost.requests == rq)
  check("host software differs: asked", need(e, software: "s2"))
  check("recheck interval over: asked", need(e, after: 6 * 3600 + 1))
  let provisional: NSDictionary = ["etag": "\"100-hero\"", "version": "100", "art": "hero", "hostSoftware": "s", "checked": at(0), "provisional": true]
  check("provisional, 30 s: not yet", !need(provisional, after: 30))
  check("provisional, 61 s: asked", need(provisional, after: 61))
  check("provisional entries carry no validators", !AppArtPolicy.canUseValidators(entry: provisional, fileExists: true, listVersion: "100", hostSoftware: "s"))
  check("a stored ETag that is not the stored version's carries no validators",
        !AppArtPolicy.canUseValidators(entry: ["etag": "\"200-hero\"", "version": "100", "hostSoftware": "s"] as NSDictionary, fileExists: true, listVersion: "100", hostSoftware: "s"))
  check("ETag version parsing", AppArtPolicy.etagVersion("\"1020121028-hero\"") == "1020121028" && AppArtPolicy.etagVersion("W/\"7-logo\"") == "7" && AppArtPolicy.etagVersion("abc") == "" && AppArtPolicy.etagVersion(nil) == "")
}

// A host update between two builds that both keep the art version honest does not make a held picture stale.
// A Desktop picture is 10.7 MB; it was fetched in full again after every host update, on a 10 Mbit/s link.
do {
  let before = "Sunshine 2026.1112.025657", after = "Sunshine 2026.1112.165752", broken = "Sunshine 2026.1111.211729"
  check("both builds honest: software not changed", !AppArtPolicy.hostSoftwareChanged(stored: before, current: after))
  check("an older build that hashed paths only: changed", AppArtPolicy.hostSoftwareChanged(stored: broken, current: after))
  check("... and the other way", AppArtPolicy.hostSoftwareChanged(stored: after, current: broken))
  check("no software stamp known: changed (asked as before)", AppArtPolicy.hostSoftwareChanged(stored: "", current: after))
  check("the host says nothing: not changed", !AppArtPolicy.hostSoftwareChanged(stored: before, current: ""))
  let held: NSDictionary = ["etag": "\"3344304115-poster\"", "version": "3344304115", "art": "poster,hero", "hostSoftware": before, "checked": at(0), "sha": "x"]
  check("a poster entry after the 16:57 host update is not asked again",
        !AppArtPolicy.needsFetch(entry: held, fileExists: true, listVersion: "3344304115", listArt: "poster,hero", hostSoftware: after, recheckSeconds: 12 * 3600, now: at(60)))
  check("... and a recheck later carries validators",
        AppArtPolicy.canUseValidators(entry: held, fileExists: true, listVersion: "3344304115", hostSoftware: after))
  check("a new art version is asked",
        AppArtPolicy.needsFetch(entry: held, fileExists: true, listVersion: "999", listArt: "poster,hero", hostSoftware: after, recheckSeconds: 12 * 3600, now: at(60)))
}

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
