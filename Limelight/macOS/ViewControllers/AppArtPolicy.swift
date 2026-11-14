//
//  AppArtPolicy.swift
//  When a cached cover / hero / logo / icon of a host's app is asked for again, and what a "304 not modified"
//  may be taken to mean. Foundation only, so tests/app-art compiles it on its own.
//
//  Why (from a user log): the host (Foundation Sunshine 2026.1111.211729) moved the hero
//  of every Sparxie app to a new picture. The client asked again right after the host restart, conditionally, got
//  304 "not modified" for every hero and poster, wrote the host's new version stamp down as "checked", and asked
//  nothing more at 21:46:54 and 21:48:46: the old pictures stayed. The rules now:
//   - a picture is asked again when the art version of the app list, its list of art types, or the host software
//     differ from what the picture was stored with;
//   - after a host update the first fetch carries no validators (the host may still serve the old file under the
//     old validators) and is marked provisional: one more unconditional fetch follows after a minute;
//   - a 304 is taken as "seen" for the announced version only when its ETag is that version's ETag; otherwise the
//     version is left unknown, so the next app list with a version fetches the picture again.
//

import Foundation

@objc(MLAppArtPolicy)
final class AppArtPolicy: NSObject {
  /// Seconds after which a provisional picture (fetched right after a host update) is fetched once more.
  @objc static let provisionalSeconds: Double = 60

  /// Foundation Sunshine's ETag is "<art version>-<type>"; anything else gives "".
  @objc static func etagVersion(_ etag: String?) -> String {
    guard var e = etag?.trimmingCharacters(in: .whitespaces), !e.isEmpty else { return "" }
    if e.hasPrefix("W/") { e.removeFirst(2) }
    e = e.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    guard let dash = e.lastIndex(of: "-"), dash != e.startIndex else { return "" }
    let version = String(e[e.startIndex..<dash])
    return version.allSatisfy({ $0.isNumber }) ? version : ""
  }

  /// Foundation Sunshine builds from this one on put the size and the time of every art file into the art version
  /// ("the application list tag follows each app's live art version"): a replaced file is a new
  /// version, so the version in the list and the ETag are proof enough for a picture already held. Builds before it
  /// hashed the paths only (an older build). The software string ends in "yyyy.mmdd.hhmmss".
  private static let contentVersionFloor = "2026.1111.220000"

  @objc static func hostTracksContent(_ software: String) -> Bool {
    guard let last = software.split(separator: " ").last else { return false }
    let stamp = String(last)
    guard stamp.count == contentVersionFloor.count, stamp.filter({ $0 == "." }).count == 2 else { return false }
    return stamp >= contentVersionFloor
  }

  /// The host software differs from what a picture was stored with, in a way that matters: not between two builds
  /// that both keep the art version honest. A 10.7 MB Desktop picture was fetched in full again after every
  /// host update, on a 10 Mbit/s link.
  @objc static func hostSoftwareChanged(stored: String, current: String) -> Bool {
    if current.isEmpty || stored == current { return false }
    return !(hostTracksContent(stored) && hostTracksContent(current))
  }

  private static func string(_ entry: NSDictionary?, _ key: String) -> String { (entry?[key] as? String) ?? "" }
  private static func flag(_ entry: NSDictionary?, _ key: String) -> Bool { (entry?[key] as? Bool) ?? ((entry?[key] as? NSNumber)?.boolValue ?? false) }

  /// Whether the picture is to be asked for in this pass.
  @objc static func needsFetch(entry: NSDictionary?, fileExists: Bool, listVersion: String, listArt: String,
                               hostSoftware: String, recheckSeconds: Double, now: Date) -> Bool {
    guard let entry else { return true }                         // never fetched, or cached before validators were kept
    if !fileExists && !flag(entry, "absent") { return true }
    if !listVersion.isEmpty && string(entry, "version") != listVersion { return true }   // the host says the art changed
    // the art types of the app changed (a hero or logo announced that was not, or the other way round). An entry
    // without the list was written by a build that took a 304 as proof (older builds): its validators may
    // belong to a file the client does not hold, so it is asked once, without validators.
    guard let stored = entry["art"] as? String else { return true }
    if stored != listArt { return true }
    if hostSoftwareChanged(stored: string(entry, "hostSoftware"), current: hostSoftware) { return true }
    let age = (entry["checked"] as? Date).map { now.timeIntervalSince($0) } ?? .infinity
    if flag(entry, "provisional") && age > provisionalSeconds { return true }
    return age > recheckSeconds
  }

  /// Whether the request may carry If-None-Match / If-Modified-Since. Not after a host update, not while the
  /// entry is provisional, not when the version differs from the list, and not when the stored ETag is not the
  /// ETag of the stored version (it then belongs to some other file).
  @objc static func canUseValidators(entry: NSDictionary?, fileExists: Bool, listVersion: String, hostSoftware: String) -> Bool {
    guard let entry, fileExists, !flag(entry, "absent"), !flag(entry, "provisional"), entry["art"] is String else { return false }
    let etag = string(entry, "etag"), modified = string(entry, "modified")
    if etag.isEmpty && modified.isEmpty { return false }
    let stored = string(entry, "version")
    if !listVersion.isEmpty && stored != listVersion { return false }
    if hostSoftwareChanged(stored: string(entry, "hostSoftware"), current: hostSoftware) { return false }
    let fromEtag = etagVersion(etag)
    if !fromEtag.isEmpty && !stored.isEmpty && fromEtag != stored { return false }
    return true
  }

  /// A 304 whose ETag is not the one that was sent, or is not the version the list announced, tells the client
  /// nothing about the bytes it holds: nil, and the picture is fetched in full. Otherwise the entry after it: the
  /// version and the host software are written down as seen only when the host's own ETag says so.
  @objc static func entryAfterNotModified(previous: NSDictionary, sentEtag: String?, responseEtag: String?, responseModified: String?,
                                          listVersion: String, listArt: String, hostSoftware: String, now: Date) -> NSDictionary? {
    if let response = responseEtag, !response.isEmpty {
      if let sent = sentEtag, !sent.isEmpty, sent != response { return nil }
      let version = etagVersion(response)
      if !listVersion.isEmpty && !version.isEmpty && version != listVersion { return nil }
    }
    var next: [String: Any] = [:]
    let etag = (responseEtag?.isEmpty == false ? responseEtag : nil) ?? string(previous, "etag")
    let modified = (responseModified?.isEmpty == false ? responseModified : nil) ?? string(previous, "modified")
    if !etag.isEmpty { next["etag"] = etag }
    if !modified.isEmpty { next["modified"] = modified }
    if let sha = previous["sha"] as? String { next["sha"] = sha }
    let seen = listVersion.isEmpty || etagVersion(etag).isEmpty || etagVersion(etag) == listVersion
    next["version"] = seen ? listVersion : ""
    next["hostSoftware"] = seen ? hostSoftware : string(previous, "hostSoftware")
    next["art"] = listArt
    next["checked"] = now
    if flag(previous, "provisional") { next["provisional"] = true }
    return next as NSDictionary
  }

  /// The entry after a picture (200) was received; `afterHostUpdate` when the fetch was made because the host
  /// software changed since the previous one.
  @objc static func entryAfterPicture(etag: String?, modified: String?, sha: String, listVersion: String, listArt: String,
                                      hostSoftware: String, afterHostUpdate: Bool, now: Date) -> NSDictionary {
    var next: [String: Any] = [:]
    if let etag, !etag.isEmpty { next["etag"] = etag }
    if let modified, !modified.isEmpty { next["modified"] = modified }
    if !sha.isEmpty { next["sha"] = sha }
    next["version"] = listVersion
    next["hostSoftware"] = hostSoftware
    next["art"] = listArt
    next["checked"] = now
    if afterHostUpdate { next["provisional"] = true }
    return next as NSDictionary
  }

  /// The entry for a picture the host announced but does not serve (404).
  @objc static func entryAbsent(listVersion: String, listArt: String, hostSoftware: String, now: Date) -> NSDictionary {
    ["absent": true, "version": listVersion, "art": listArt, "hostSoftware": hostSoftware, "checked": now] as NSDictionary
  }
}
