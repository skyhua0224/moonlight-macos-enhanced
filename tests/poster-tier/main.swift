import Foundation

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
  if !ok { failures += 1 }
  print("\(ok ? "PASS" : "FAIL") \(name)\(ok ? "" : " — " + detail())")
}

let sha = String(repeating: "ab", count: 32)   // 64 hex digits, like the host's ETag
let quoted = "\"\(sha)\""

// MARK: capability
check("advertised: 1", PosterTier.advertised("1"))
check("advertised: true", PosterTier.advertised(" true "))
check("advertised: absent", !PosterTier.advertised(nil))
check("advertised: empty", !PosterTier.advertised(""))
check("advertised: 0 / false / off", !PosterTier.advertised("0") && !PosterTier.advertised("False") && !PosterTier.advertised("off"))

// MARK: etags
check("normalize strips quotes and W/", PosterTier.normalize("W/\"x1\"") == "x1" && PosterTier.normalize("\"x1\"") == "x1")
check("sameEtag", PosterTier.sameEtag("\"x1\"", "W/\"x1\"") && !PosterTier.sameEtag("\"x1\"", "\"x2\"") && !PosterTier.sameEtag("", ""))
check("fileTag keeps hex", PosterTier.fileTag(quoted) == sha)
check("fileTag drops path characters", PosterTier.fileTag("\"../etc/pass wd\"") == "etcpasswd", PosterTier.fileTag("\"../etc/pass wd\""))
check("fileTag is at most 64", PosterTier.fileTag(String(repeating: "a", count: 200)).count == 64)
check("sha256Hex of a SHA-256 ETag", PosterTier.sha256Hex(ofEtag: quoted) == sha)
check("sha256Hex of other tags is nil", PosterTier.sha256Hex(ofEtag: "\"3344304115-poster\"") == nil && PosterTier.sha256Hex(ofEtag: "\"\(String(repeating: "z", count: 64))\"") == nil)

// MARK: which picture is on screen
check("preview shown when nothing is shown", PosterTier.shouldShowPreview(displayExists: false, knownFullEtag: nil, hostFullEtag: "\"a\""))
check("preview shown when the picture changed", PosterTier.shouldShowPreview(displayExists: true, knownFullEtag: "\"a\"", hostFullEtag: "\"b\""))
check("preview not shown over the same picture (full already there)", !PosterTier.shouldShowPreview(displayExists: true, knownFullEtag: "\"a\"", hostFullEtag: "\"a\""))
check("preview not shown over a picture of unknown origin", !PosterTier.shouldShowPreview(displayExists: true, knownFullEtag: nil, hostFullEtag: "\"a\""))

// MARK: does the full picture need fetching
check("full needed: announced, nothing cached", PosterTier.fullNeeded(hostFullEtag: "\"a\"", cachedFullEtag: nil, cachedComplete: false))
check("full needed: partial copy of the same tag", PosterTier.fullNeeded(hostFullEtag: "\"a\"", cachedFullEtag: "\"a\"", cachedComplete: false))
check("full needed: complete copy of an older tag", PosterTier.fullNeeded(hostFullEtag: "\"b\"", cachedFullEtag: "\"a\"", cachedComplete: true))
check("full skipped: cached full ETag equals the host's", !PosterTier.fullNeeded(hostFullEtag: "\"a\"", cachedFullEtag: "W/\"a\"", cachedComplete: true))
check("full skipped: host announced nothing", !PosterTier.fullNeeded(hostFullEtag: nil, cachedFullEtag: nil, cachedComplete: false))

// MARK: Range and resume
check("range: none for an empty partial", PosterTier.rangeHeader(partialBytes: 0) == nil)
check("range: bytes=N-", PosterTier.rangeHeader(partialBytes: 4000000) == "bytes=4000000-")
let cr = PosterTier.parseContentRange("bytes 4000000-10699999/10700000")
check("content-range parse", cr?.start == 4000000 && cr?.end == 10699999 && cr?.total == 10700000)
check("content-range parse: unknown total", PosterTier.parseContentRange("bytes 0-9/*")?.total == nil)
check("content-range parse: garbage", PosterTier.parseContentRange("items 1-2/3") == nil && PosterTier.parseContentRange("bytes 9-1/20") == nil && PosterTier.parseContentRange(nil) == nil)
check("resume: 206 from the offset appends", PosterTier.resumeAction(status: 206, contentRange: "bytes 100-999/1000", responseEtag: quoted, expectedEtag: quoted, offset: 100) == .append)
check("resume: 206 from another offset is discarded", PosterTier.resumeAction(status: 206, contentRange: "bytes 0-999/1000", responseEtag: quoted, expectedEtag: quoted, offset: 100) == .discard)
check("resume: 206 without Content-Range is discarded", PosterTier.resumeAction(status: 206, contentRange: nil, responseEtag: quoted, expectedEtag: quoted, offset: 100) == .discard)
check("resume: 206 with another ETag = picture changed", PosterTier.resumeAction(status: 206, contentRange: "bytes 100-999/1000", responseEtag: "\"other\"", expectedEtag: quoted, offset: 100) == .changed)
check("resume: 200 (Range ignored) restarts", PosterTier.resumeAction(status: 200, contentRange: nil, responseEtag: quoted, expectedEtag: quoted, offset: 100) == .restart)
check("resume: 200 without a partial file", PosterTier.resumeAction(status: 200, contentRange: nil, responseEtag: quoted, expectedEtag: quoted, offset: 0) == .restart)
check("resume: 200 with another ETag = picture changed", PosterTier.resumeAction(status: 200, contentRange: nil, responseEtag: "\"other\"", expectedEtag: quoted, offset: 0) == .changed)
check("resume: 416 discards the partial file", PosterTier.resumeAction(status: 416, contentRange: "bytes */1000", responseEtag: nil, expectedEtag: quoted, offset: 5000) == .discard)
check("resume: 404 / 503 fail", PosterTier.resumeAction(status: 404, contentRange: nil, responseEtag: nil, expectedEtag: quoted, offset: 0) == .fail && PosterTier.resumeAction(status: 503, contentRange: nil, responseEtag: nil, expectedEtag: quoted, offset: 0) == .fail)
check("resume: a 200 without ETag is accepted (the SHA-256 decides)", PosterTier.resumeAction(status: 200, contentRange: nil, responseEtag: nil, expectedEtag: quoted, offset: 0) == .restart)

// MARK: proof
check("verifies: size and SHA-256", PosterTier.verifies(size: 1000, announcedLength: 1000, etag: quoted, computedSha256: sha))
check("verifies: wrong SHA-256", !PosterTier.verifies(size: 1000, announcedLength: 1000, etag: quoted, computedSha256: String(repeating: "cd", count: 32)))
check("verifies: SHA-256 ETag but no hash computed", !PosterTier.verifies(size: 1000, announcedLength: 1000, etag: quoted, computedSha256: nil))
check("verifies: short file", !PosterTier.verifies(size: 999, announcedLength: 1000, etag: quoted, computedSha256: sha))
check("verifies: other ETag forms need the size only", PosterTier.verifies(size: 1000, announcedLength: 1000, etag: "\"v1\"", computedSha256: nil))
check("verifies: empty file", !PosterTier.verifies(size: 0, announcedLength: 0, etag: "\"v1\"", computedSha256: nil))

// MARK: the registry
let suite = "poster-tier-test-\(ProcessInfo.processInfo.processIdentifier)"
let defaults = UserDefaults(suiteName: suite)!
defaults.removePersistentDomain(forName: suite)
let store = PosterVariantsStore(defaults: defaults, key: "k")
check("registry: unknown host does not support variants", !store.supports("H1"))
store.note("H1", value: "1")
check("registry: advertised", store.supports("H1"))
store.note("H2", value: nil)
check("registry: a serverinfo without the element", !store.supports("H2"))
store.flush()
let reopened = PosterVariantsStore(defaults: defaults, key: "k")
check("registry: remembered between launches", reopened.supports("H1") && !reopened.supports("H2"))
reopened.note("H1", value: nil)
check("registry: a host that stops advertising", !reopened.supports("H1"))

// the first cover pass can run before the first serverinfo of a computer was read
let fresh = PosterVariantsStore(defaults: defaults, key: "k2")
let t0 = Date()
check("state: unknown at first", fresh.state("H3", now: t0) == -1)
check("state: still unknown inside the grace time", fresh.state("H3", now: t0.addingTimeInterval(10)) == -1)
check("state: taken for a host without variants after the grace time", fresh.state("H3", now: t0.addingTimeInterval(16)) == 0)
var heard: String?
let token = NotificationCenter.default.addObserver(forName: PosterVariantsStore.knownNotification, object: nil, queue: nil) { heard = $0.object as? String }
fresh.note("H4", value: "1")
check("note: the first serverinfo of a computer is announced", heard == "H4")
check("state: yes after serverinfo", fresh.state("H4", now: t0) == 1)
heard = nil
fresh.note("H4", value: "1")
check("note: a repeated serverinfo is not announced again", heard == nil)
NotificationCenter.default.removeObserver(token)
check("state: serverinfo without the element = no", { fresh.note("H5", value: nil); return fresh.state("H5", now: t0) == 0 }())
fresh.flush()
defaults.removePersistentDomain(forName: suite)

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
