//
//  PosterTier.swift
//  Tiered posters: a compressed preview first, the lossless full picture later, when the link is idle.
//  Foundation only, so tests/poster-tier compiles it on its own.
//
//  The rule: when posters are sent or synced, a compressed one comes first; the full one is fetched only when
//  the link is idle, and it is lossless HD. The host side (Foundation Sunshine, branch fix/host-poster-keyframe-pacing):
//   - serverinfo carries `poster_variants`; a host without it (old Foundation Sunshine, stock Sunshine) serves one
//     picture and the background-work rules apply unchanged;
//   - `/appasset?...&fsVariant=preview` answers a small picture with X-FS-Poster-Variant, ETag, X-FS-Poster-Full-ETag
//     and X-FS-Poster-Full-Length;
//   - `/appasset` without the parameter answers the lossless picture, with ETag (the SHA-256 of the served bytes) and
//     Accept-Ranges, 304 to If-None-Match, 206 to Range.
//  What lives here: the decisions that do not touch the network (is the host a variants host, which picture goes on
//  screen, does the full picture need fetching, what to do with the answer to a resumed request), and the registry of
//  which hosts advertise the capability.
//

import Foundation

@objc(MLPosterResume)
enum PosterResume: Int {
  /// 206 from the offset asked for: append the body to the partial file.
  case append = 0
  /// 200 with the expected ETag: the host sent the whole picture; start the file again.
  case restart = 1
  /// The partial file cannot be continued (416, a range that does not start where the file ends, another ETag on a 206):
  /// delete it. The next pass starts from zero.
  case discard = 2
  /// The full picture changed on the host (200 or 206 with another ETag): the partial file belongs to the old one.
  case changed = 3
  /// Anything else (404, 5xx ...).
  case fail = 4
}

@objc(MLPosterTier)
final class PosterTier: NSObject {
  /// The preview is small enough to arrive in a moment; the picture is the full one when the host says so.
  @objc static let previewVariant = "preview"

  /// serverinfo `poster_variants`: present and not an explicit no.
  @objc static func advertised(_ value: String?) -> Bool {
    guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !v.isEmpty else { return false }
    return !["0", "false", "no", "off", "none"].contains(v)
  }

  /// `"abc"` and `W/"abc"` are the same tag.
  @objc static func normalize(_ etag: String?) -> String {
    guard var e = etag?.trimmingCharacters(in: .whitespaces), !e.isEmpty else { return "" }
    if e.hasPrefix("W/") { e.removeFirst(2) }
    return e.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
  }

  @objc static func sameEtag(_ a: String?, _ b: String?) -> Bool {
    let x = normalize(a), y = normalize(b)
    return !x.isEmpty && x == y
  }

  /// A file-name safe form of an ETag (letters, digits, - and _ only, at most 64 characters).
  @objc static func fileTag(_ etag: String?) -> String {
    let e = normalize(etag)
    var out = String.UnicodeScalarView()
    for s in e.unicodeScalars where CharacterSet.alphanumerics.contains(s) || s == "-" || s == "_" {
      if out.count >= 64 { break }
      out.append(s)
    }
    return String(out)
  }

  /// The host's ETag of the full picture is the SHA-256 of its bytes (64 hex digits): then the bytes can be proven.
  @objc static func sha256Hex(ofEtag etag: String?) -> String? {
    let e = normalize(etag).lowercased()
    guard e.count == 64, e.allSatisfy({ $0.isHexDigit }) else { return nil }
    return e
  }

  /// Whether the preview is written to the picture file now. The picture file is what the app shows; once the full
  /// picture is there it is never replaced by the preview of the same picture.
  ///  - nothing is shown yet: yes;
  ///  - something is shown and the host's full ETag is a different one from the last we knew: the picture changed, yes;
  ///  - something is shown and we never knew the full ETag (a picture fetched by an older build): no, it stays
  ///    until the full picture replaces it (its bytes are checked against the full ETag by the caller).
  @objc static func shouldShowPreview(displayExists: Bool, knownFullEtag: String?, hostFullEtag: String?) -> Bool {
    if !displayExists { return true }
    let known = normalize(knownFullEtag), host = normalize(hostFullEtag)
    if known.isEmpty || host.isEmpty { return false }
    return known != host
  }

  /// The full picture is wanted: the host announced an ETag and the copy that is cached and complete is another one.
  @objc static func fullNeeded(hostFullEtag: String?, cachedFullEtag: String?, cachedComplete: Bool) -> Bool {
    let host = normalize(hostFullEtag)
    if host.isEmpty { return false }
    return !(cachedComplete && normalize(cachedFullEtag) == host)
  }

  /// `Range` for a partial file of `bytes` bytes; nil when there is none (an ordinary request).
  @objc static func rangeHeader(partialBytes bytes: Int64) -> String? { bytes > 0 ? "bytes=\(bytes)-" : nil }

  /// "bytes 1000-1999/2000" -> (1000, 1999, 2000); total nil for "*".
  static func parseContentRange(_ value: String?) -> (start: Int64, end: Int64, total: Int64?)? {
    guard let value, value.lowercased().hasPrefix("bytes ") else { return nil }
    let rest = value.dropFirst(6).trimmingCharacters(in: .whitespaces)
    let halves = rest.split(separator: "/", maxSplits: 1).map(String.init)
    guard halves.count == 2 else { return nil }
    let span = halves[0].split(separator: "-").map(String.init)
    guard span.count == 2, let s = Int64(span[0]), let e = Int64(span[1]), s <= e else { return nil }
    return (s, e, halves[1] == "*" ? nil : Int64(halves[1]))
  }

  /// What the answer to the (maybe resumed) full-picture request means for the file on disk.
  /// `offset` is the number of bytes already there (0 for a first request).
  @objc static func resumeAction(status: Int, contentRange: String?, responseEtag: String?, expectedEtag: String, offset: Int64) -> PosterResume {
    let hasEtag = !normalize(responseEtag).isEmpty
    let etagOK = !hasEtag || sameEtag(responseEtag, expectedEtag)
    switch status {
    case 206:
      guard offset > 0, let range = parseContentRange(contentRange), range.start == offset else { return .discard }
      return etagOK ? .append : .changed
    case 200:
      return etagOK ? .restart : .changed
    case 416:
      return .discard
    default:
      return .fail
    }
  }

  /// A finished file is the picture: the size is the announced one (when announced) and, when the ETag is a SHA-256,
  /// the bytes hash to it (`computedSha256` is nil when the caller has no hash to offer).
  @objc static func verifies(size: Int64, announcedLength: Int64, etag: String, computedSha256: String?) -> Bool {
    if announcedLength > 0 && size != announcedLength { return false }
    if size <= 0 { return false }
    if let proof = sha256Hex(ofEtag: etag) {
      guard let computed = computedSha256 else { return false }
      return computed.lowercased() == proof
    }
    return true
  }
}

/// Which computers advertise `poster_variants`. Remembered between launches, so the first cover pass of a session does
/// not ask a variants host for the 10 MB picture before its serverinfo has been read again.
final class PosterVariantsStore {
  private let defaults: UserDefaults
  private let key: String
  private let lock = NSLock()
  private var hosts: [String: Bool]?
  private let writer = DispatchQueue(label: "std.skyhua.poster-variants", qos: .utility)

  init(defaults: UserDefaults = .standard, key: String = "MLPosterVariantsHosts") {
    self.defaults = defaults; self.key = key
  }

  // Lock discipline as DeckFactsStore: the lock guards `hosts` only; UserDefaults is read before and written
  // after it, on `writer`.
  private func loadIfNeeded() {
    lock.lock(); let loaded = hosts != nil; lock.unlock()
    if loaded { return }
    let disk = (defaults.dictionary(forKey: key) as? [String: Bool]) ?? [:]
    lock.lock(); if hosts == nil { hosts = disk }; lock.unlock()
  }

  func supports(_ uuid: String) -> Bool {
    loadIfNeeded()
    lock.lock(); defer { lock.unlock() }
    return hosts?[uuid] ?? false
  }

  /// How long a host whose serverinfo has not been read is waited for before it is taken for one without variants.
  let unknownGrace: TimeInterval = 15
  private var asked: [String: Date] = [:]

  /// 1 the host advertises variants, 0 it does not (serverinfo said so, or none was read within `unknownGrace` of the
  /// first question), -1 not known yet: the cover pass runs before the first serverinfo of this computer was read, and
  /// asks again when `note` has been called.
  func state(_ uuid: String, now: Date = Date()) -> Int {
    loadIfNeeded()
    lock.lock(); defer { lock.unlock() }
    if let known = hosts?[uuid] { return known ? 1 : 0 }
    guard let first = asked[uuid] else { asked[uuid] = now; return -1 }
    return now.timeIntervalSince(first) > unknownGrace ? 0 : -1
  }

  /// serverinfo was read: `value` is the text of the `poster_variants` element, nil when there was none.
  func note(_ uuid: String, value: String?) {
    guard !uuid.isEmpty else { return }
    loadIfNeeded()
    let now = PosterTier.advertised(value)
    lock.lock()
    let before = hosts?[uuid]
    hosts?[uuid] = now
    let snapshot = hosts ?? [:]
    lock.unlock()
    if before != now { writer.async { self.defaults.set(snapshot, forKey: self.key) } }
    if before == nil { NotificationCenter.default.post(name: PosterVariantsStore.knownNotification, object: uuid) }
  }

  static let knownNotification = Notification.Name("MLPosterVariantsKnown")

  func flush() { writer.sync {} }
}

@objc(MLPosterVariants)
final class PosterVariants: NSObject {
  private static let store = PosterVariantsStore()
  @objc static func supports(hostUUID: String) -> Bool { store.supports(hostUUID) }
  /// 1 yes, 0 no, -1 not known yet (see PosterVariantsStore.state).
  @objc static func state(hostUUID: String) -> Int { store.state(hostUUID) }
  /// Posted (object = the host UUID) the first time a computer's serverinfo has been read.
  @objc static let knownNotification = PosterVariantsStore.knownNotification.rawValue
  @objc static func note(hostUUID: String, value: String?) { store.note(hostUUID, value: value) }
}
