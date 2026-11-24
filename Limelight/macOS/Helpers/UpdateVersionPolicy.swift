import Foundation

/// Which release counts as an update, decided on Foundation only so it can be tested without the app.
///
/// Stable releases are numbered 1.3.9, 2.0.0, ... Test builds carry the timestamp version of the commit
/// (2026.1124.103317, see scripts/release_info.py). A timestamp is larger than any stable number, so versions
/// cannot be compared across the two kinds. The build number (CFBundleVersion, `sparkle:version` in the appcast)
/// only grows and is what Sparkle itself compares, so it decides whenever both sides have one.
enum UpdateVersionPolicy {
  /// `v2026.1124.103317` or `2026.1124.103317`.
  static func isTimestampVersion(_ version: String) -> Bool {
    version.range(of: #"^v?[0-9]{4}\.[0-9]{3,4}\.[0-9]{1,6}$"#, options: .regularExpression) != nil
  }

  /// A stable build never sees pre-releases or timestamp builds, even one published without the pre-release flag.
  static func isEligible(tag: String, prerelease: Bool, acceptsPrereleases: Bool) -> Bool {
    acceptsPrereleases || (!prerelease && !isTimestampVersion(tag))
  }

  /// Feed order: a test build reads the branch feed first (it lists the newest test build and the stable release),
  /// everything else keeps the given order.
  static func orderedFeeds(_ feeds: [String], branchFeed: String, acceptsPrereleases: Bool) -> [String] {
    acceptsPrereleases ? [branchFeed] + feeds.filter { $0 != branchFeed } : feeds
  }

  /// The appcast asset of a release, only from this product's GitHub release downloads.
  static func appcastURL(from urlString: String) -> URL? {
    guard let url = URL(string: urlString), url.scheme == "https", url.host?.lowercased() == "github.com",
      url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil
    else { return nil }
    let parts = url.pathComponents.filter { $0 != "/" }
    guard parts.count == 6, parts[0] == "skyhua0224", parts[1] == "moonlight-macos-enhanced",
      parts[2] == "releases", parts[3] == "download", parts[5] == "appcast.xml"
    else { return nil }
    return url
  }

  /// Highest `sparkle:version` of the appcast, as an element or as an enclosure attribute. Items of the beta channel
  /// count only when `includingBeta` is set.
  static func buildNumber(appcast: Data, includingBeta: Bool) -> Int? {
    let reader = AppcastBuildReader()
    let parser = XMLParser(data: appcast)
    parser.delegate = reader
    guard parser.parse() else { return nil }
    return reader.items.filter { includingBeta || $0.channel == nil }.compactMap(\.build).max()
  }

  struct Release: Equatable {
    var tag: String
    var prerelease: Bool
    var publishedAt: String?
    var build: Int?
  }

  /// The release to offer: the highest build number among the eligible releases; when none has one, the highest
  /// version by the legacy comparison (`legacyNewer(a, b)`: a is newer than b).
  static func choose(_ releases: [Release], acceptsPrereleases: Bool, legacyNewer: (String, String) -> Bool) -> Release? {
    let eligible = releases.filter { isEligible(tag: $0.tag, prerelease: $0.prerelease, acceptsPrereleases: acceptsPrereleases) }
    let withBuild = eligible.filter { $0.build != nil }
    if let best = withBuild.max(by: { ($0.build ?? 0) < ($1.build ?? 0) }) { return best }
    return eligible.max(by: { legacyNewer($1.tag, $0.tag) })
  }

  /// Whether the candidate is an update for the running app.
  static func isNewer(candidate: String, candidateBuild: Int?, current: String, currentBuild: Int?,
                      legacyNewer: (String, String) -> Bool) -> Bool {
    if let candidateBuild, let currentBuild { return candidateBuild > currentBuild }
    return legacyNewer(candidate, current)
  }
}

private final class AppcastBuildReader: NSObject, XMLParserDelegate {
  struct Item { var build: Int?; var channel: String? }
  var items: [Item] = []
  private var current: Item?
  private var text = ""

  func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
              qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
    text = ""
    switch elementName {
    case "item": current = Item()
    case "enclosure":
      if let value = attributeDict["sparkle:version"], let build = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
        record(build)
      }
    default: break
    }
  }

  private func record(_ build: Int) {
    guard var item = current else { return }
    item.build = max(item.build ?? build, build)
    current = item
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

  func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    switch elementName {
    case "sparkle:version":
      if let build = Int(value) { record(build) }
    case "sparkle:channel": current?.channel = value
    case "item":
      if let item = current { items.append(item) }
      current = nil
    default: break
    }
    text = ""
  }
}
