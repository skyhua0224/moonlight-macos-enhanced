import Foundation

/// Compiled regular expressions, shared by every log line. Compiling a pattern
/// per line used to dominate the cost of parsing a few thousand lines.
private final class DebugLogRegexCache {
  static let shared = DebugLogRegexCache()

  private let lock = NSLock()
  private var cache: [String: NSRegularExpression] = [:]

  func regex(for pattern: String) -> NSRegularExpression? {
    lock.lock()
    defer { lock.unlock() }
    if let cached = cache[pattern] {
      return cached
    }
    guard let compiled = try? NSRegularExpression(pattern: pattern) else {
      return nil
    }
    cache[pattern] = compiled
    return compiled
  }
}

/// Localisation for the text the parser builds on its background queue.
///
/// This must go through `LanguageManager`: it applies the language chosen inside the app,
/// while `NSLocalizedString` / `String(localized:)` follow the system language and would
/// show English for a user who picked Chinese in Moonlight but runs a system in English.
/// Lookups are cached per language because they run for every parsed line.
private final class DebugLogText {
  static let shared = DebugLogText()

  private let lock = NSLock()
  private var cache: [String: String] = [:]
  private var cachedLanguage = ""

  func localized(_ key: String) -> String {
    let language = LanguageManager.shared.currentLanguage.rawValue
    lock.lock()
    defer { lock.unlock() }
    if language != cachedLanguage {
      cache.removeAll(keepingCapacity: true)
      cachedLanguage = language
    }
    if let hit = cache[key] {
      return hit
    }
    let value = LanguageManager.shared.localize(key)
    cache[key] = value
    return value
  }
}

/// The localised text for `key`.
private func tr(_ key: String) -> String {
  DebugLogText.shared.localized(key)
}

/// The localised format for `key`, filled with `arguments` (all of them are shown as text).
private func tr(_ key: String, _ arguments: String...) -> String {
  let boxed: [CVarArg] = arguments.map { $0 as NSString }
  return String(format: DebugLogText.shared.localized(key), arguments: boxed)
}

extension String {
  /// Plain case-insensitive substring test. Unlike `localizedCaseInsensitiveContains`
  /// it does not go through locale-aware collation, which is far slower per line.
  fileprivate func mlContainsCaseInsensitive(_ needle: String) -> Bool {
    range(of: needle, options: .caseInsensitive) != nil
  }
}

@objcMembers
final class MLLogCategoryDescriptor: NSObject {
  let domainKey: String
  let categoryKey: String
  private let displayNameKey: String
  private let badgeTextKey: String

  var displayName: String { LanguageManager.shared.localize(displayNameKey) }
  var badgeText: String { LanguageManager.shared.localize(badgeTextKey) }

  init(domainKey: String, categoryKey: String, displayName: String, badgeText: String) {
    self.domainKey = domainKey
    self.categoryKey = categoryKey
    self.displayNameKey = displayName
    self.badgeTextKey = badgeText
  }

  var searchableText: String {
    "\(displayName)\n\(badgeText)\n\(domainKey)\n\(categoryKey)"
  }

  var systemImageName: String {
    switch categoryKey {
    case "discovery":
      return "dot.radiowaves.left.and.right"
    case "discovery.mdns":
      return "wave.3.right.circle"
    case "network":
      return "network"
    case "network.http":
      return "arrow.left.arrow.right.circle"
    case "network.transport":
      return "point.3.connected.trianglepath.dotted"
    case "network.tls":
      return "lock.shield"
    case "pairing":
      return "person.2.badge.key"
    case "pairing.identity":
      return "person.crop.rectangle.badge.checkmark"
    case "stream":
      return "play.tv"
    case "stream.lifecycle":
      return "arrow.triangle.2.circlepath"
    case "input":
      return "cursorarrow"
    case "input.scroll":
      return "arrow.up.and.down.circle"
    case "input.mouse":
      return "cursorarrow.motionlines"
    case "input.click":
      return "cursorarrow.click"
    case "input.capture":
      return "lock.open"
    case "video":
      return "video"
    case "video.decoder":
      return "film"
    case "audio":
      return "speaker.wave.2"
    case "audio.pipeline":
      return "waveform.path"
    case "ui":
      return "macwindow"
    case "ui.window":
      return "rectangle.on.rectangle"
    case "system":
      return "gearshape.2"
    case "system.noise":
      return "speaker.slash"
    default:
      return "ellipsis.circle"
    }
  }

  func matchesFilterKey(_ filterKey: String?) -> Bool {
    guard let filterKey, !filterKey.isEmpty, filterKey != "all" else {
      return true
    }
    if categoryKey == filterKey || domainKey == filterKey {
      return true
    }
    return categoryKey.hasPrefix(filterKey + ".")
  }
}

@objcMembers
final class MLLogCategoryClassifier: NSObject {
  private static let descriptors: [String: MLLogCategoryDescriptor] = [
    "discovery": .init(
      domainKey: "discovery",
      categoryKey: "discovery",
      displayName: "Discovery",
      badgeText: "Discovery"
    ),
    "discovery.mdns": .init(
      domainKey: "discovery",
      categoryKey: "discovery.mdns",
      displayName: "Discovery · mDNS",
      badgeText: "Discovery/mDNS"
    ),
    "network": .init(
      domainKey: "network",
      categoryKey: "network",
      displayName: "Network",
      badgeText: "Network"
    ),
    "network.http": .init(
      domainKey: "network",
      categoryKey: "network.http",
      displayName: "Network · Request",
      badgeText: "Network/Request"
    ),
    "network.transport": .init(
      domainKey: "network",
      categoryKey: "network.transport",
      displayName: "Network · Transport",
      badgeText: "Network/Transport"
    ),
    "network.tls": .init(
      domainKey: "network",
      categoryKey: "network.tls",
      displayName: "Network · TLS",
      badgeText: "Network/TLS"
    ),
    "pairing": .init(
      domainKey: "pairing",
      categoryKey: "pairing",
      displayName: "Pairing",
      badgeText: "Pairing"
    ),
    "pairing.identity": .init(
      domainKey: "pairing",
      categoryKey: "pairing.identity",
      displayName: "Pairing · Identity",
      badgeText: "Pairing/Identity"
    ),
    "stream": .init(
      domainKey: "stream",
      categoryKey: "stream",
      displayName: "Stream",
      badgeText: "Stream"
    ),
    "stream.lifecycle": .init(
      domainKey: "stream",
      categoryKey: "stream.lifecycle",
      displayName: "Stream · Lifecycle",
      badgeText: "Stream/Lifecycle"
    ),
    "input": .init(
      domainKey: "input",
      categoryKey: "input",
      displayName: "Input",
      badgeText: "Input"
    ),
    "input.scroll": .init(
      domainKey: "input",
      categoryKey: "input.scroll",
      displayName: "Input · Scroll",
      badgeText: "Input/Scroll"
    ),
    "input.mouse": .init(
      domainKey: "input",
      categoryKey: "input.mouse",
      displayName: "Input · Mouse",
      badgeText: "Input/Mouse"
    ),
    "input.click": .init(
      domainKey: "input",
      categoryKey: "input.click",
      displayName: "Input · Click",
      badgeText: "Input/Click"
    ),
    "input.capture": .init(
      domainKey: "input",
      categoryKey: "input.capture",
      displayName: "Input · Capture",
      badgeText: "Input/Capture"
    ),
    "video": .init(
      domainKey: "video",
      categoryKey: "video",
      displayName: "Video",
      badgeText: "Video"
    ),
    "video.decoder": .init(
      domainKey: "video",
      categoryKey: "video.decoder",
      displayName: "Video · Decoder",
      badgeText: "Video/Decoder"
    ),
    "audio": .init(
      domainKey: "audio",
      categoryKey: "audio",
      displayName: "Audio",
      badgeText: "Audio"
    ),
    "audio.pipeline": .init(
      domainKey: "audio",
      categoryKey: "audio.pipeline",
      displayName: "Audio · Pipeline",
      badgeText: "Audio/Pipeline"
    ),
    "ui": .init(
      domainKey: "ui",
      categoryKey: "ui",
      displayName: "UI",
      badgeText: "UI"
    ),
    "ui.window": .init(
      domainKey: "ui",
      categoryKey: "ui.window",
      displayName: "UI · Window",
      badgeText: "UI/Window"
    ),
    "system": .init(
      domainKey: "system",
      categoryKey: "system",
      // Not plain "System": that key is the language option and reads "系统默认" in Chinese.
      displayName: "System Log",
      badgeText: "System Log"
    ),
    "system.noise": .init(
      domainKey: "system",
      categoryKey: "system.noise",
      displayName: "System · Noise",
      badgeText: "System/Noise"
    ),
    "other": .init(
      domainKey: "other",
      categoryKey: "other",
      displayName: "Other",
      badgeText: "Other"
    ),
  ]

  private static let orderedFilterKeys: [String] = [
    "discovery",
    "discovery.mdns",
    "network",
    "network.http",
    "network.transport",
    "network.tls",
    "pairing",
    "pairing.identity",
    "stream",
    "stream.lifecycle",
    "input",
    "input.scroll",
    "input.mouse",
    "input.click",
    "input.capture",
    "video",
    "video.decoder",
    "audio",
    "audio.pipeline",
    "ui",
    "ui.window",
    "system",
    "system.noise",
    "other",
  ]

  private static let orderedDomainKeys: [String] = [
    "discovery",
    "network",
    "pairing",
    "stream",
    "input",
    "video",
    "audio",
    "ui",
    "system",
    "other",
  ]

  static func filterOptions() -> [MLLogCategoryDescriptor] {
    orderedFilterKeys.compactMap { descriptors[$0] }
  }

  static func domainFilterOptions() -> [MLLogCategoryDescriptor] {
    orderedDomainKeys.compactMap { descriptors[$0] }
  }

  static func detailFilterOptions(forDomainFilterKey filterKey: String?) -> [MLLogCategoryDescriptor] {
    let normalized = (filterKey ?? "all").lowercased()
    if normalized == "all" || normalized.isEmpty {
      return orderedFilterKeys.compactMap { key in
        guard let descriptor = descriptors[key] else { return nil }
        return descriptor.categoryKey == descriptor.domainKey ? nil : descriptor
      }
    }

    if normalized == "other" {
      return descriptors["other"].map { [ $0 ] } ?? []
    }

    return orderedFilterKeys.compactMap { key in
      guard let descriptor = descriptors[key] else { return nil }
      guard descriptor.domainKey == normalized else { return nil }
      return descriptor.categoryKey == descriptor.domainKey ? nil : descriptor
    }
  }

  static func descriptor(forCategoryKey categoryKey: String) -> MLLogCategoryDescriptor {
    descriptors[categoryKey] ?? descriptors["other"]!
  }

  static func displayName(forFilterKey filterKey: String?) -> String {
    guard let filterKey, !filterKey.isEmpty, filterKey != "all" else {
      return LanguageManager.shared.localize("All")
    }
    return descriptor(forCategoryKey: filterKey).displayName
  }

  static func descriptor(forNoiseCategory noiseCategory: DebugNoiseCategory) -> MLLogCategoryDescriptor {
    switch noiseCategory {
    case .appKitMenuInconsistency:
      return descriptor(forCategoryKey: "system.noise")
    case .networkStackNoise, .systemTransportFallback:
      return descriptor(forCategoryKey: "network.transport")
    case .discoveryChatter:
      return descriptor(forCategoryKey: "discovery.mdns")
    case .hostIdentityMismatch:
      return descriptor(forCategoryKey: "pairing.identity")
    }
  }

  static func descriptor(forLine line: String) -> MLLogCategoryDescriptor {
    descriptor(forCategoryKey: categoryKey(forLine: line))
  }

  /// The "[tag]" that opens the message of a line "[time] <LEVEL> [tag] text", lowercased.
  private static func leadingTag(ofLine line: String) -> String? {
    guard let levelEnd = line.range(of: "> "),
      line.distance(from: line.startIndex, to: levelEnd.lowerBound) < 40
    else { return nil }
    let rest = line[levelEnd.upperBound...]
    guard rest.first == "[", let close = rest.firstIndex(of: "]") else { return nil }
    let tag = rest[rest.index(after: rest.startIndex)..<close]
    guard tag.count <= 16 else { return nil }
    return tag.lowercased()
  }

  /// Where the newer tagged lines belong. Tags without an entry keep the text based rules below.
  private static func categoryKey(forTag tag: String) -> String? {
    switch tag {
    case "audio": return "audio.pipeline"
    case "video", "hdr": return "video.decoder"
    case "keyboard", "controller", "touchpad": return "input"
    case "startup", "live", "display-scale", "sunshine": return "stream.lifecycle"
    case "fec", "perf": return "stream"
    case "netprobe": return "network"
    case "discovery": return "discovery"
    default: return nil
    }
  }

  private static func categoryKey(forLine line: String) -> String {
    if let tag = leadingTag(ofLine: line), let key = categoryKey(forTag: tag) {
      return key
    }

    let normalized = line.lowercased()

    if normalized.contains("[clickdiag]") {
      return "input.click"
    }

    if normalized.contains("[inputdiag]") {
      if normalized.contains("scroll") {
        return "input.scroll"
      }
      if normalized.contains("mouse-button") {
        return "input.click"
      }
      if containsAny(normalized, [
        "sendabsolutemouseposition",
        "absolute pos=",
        "moves=",
        "rawδ=",
        "sentδ=",
        "remotetarget=(",
      ]) {
        return "input.mouse"
      }
    }

    if containsAny(normalized, [
      "capturemouse armed",
      "mouse uncapture",
      "mouse exit event",
      "rearming mouse capture",
      "rearm skipped",
      "mouse-entered-view",
      "mouse-exited-view",
      "free mouse uncaptured",
      "window became key; rearming input capture",
    ]) {
      return "input.capture"
    }

    if containsAny(normalized, [
      "starting discovery",
      "stopping discovery",
      "starting mdns discovery",
      "stopping mdns discovery",
      "restarting mdns search",
      "resolved address:",
      "discovery summary for ",
      "found service:",
      "found new host:",
      "found existing host through mdns",
      "found host through mdns",
    ]) {
      return "discovery.mdns"
    }

    if containsAny(normalized, [
      "server certificate mismatch",
      "received response from incorrect host:",
      "client certificate imported",
    ]) {
      return "pairing.identity"
    }

    if containsAny(normalized, [
      "tls错误",
      "tls error",
      "code=-1200",
      "code=-1202",
      "certificate is invalid",
      "证书无效",
    ]) {
      return "network.tls"
    }

    if containsAny(normalized, [
      "making request:",
      "received response:",
      "requesting:",
      "request failed with error",
      "app list successfully retreived",
      "app list successfully retrieved",
    ]) {
      return "network.http"
    }

    if containsAny(normalized, [
      "nsurlerrordomain",
      "connection error:",
      "网络连接已中断",
      "请求超时",
      "无法连接服务器",
      "finished with error",
      "failed to connect",
      "nw_",
      "tcp_input",
    ]) {
      return "network.transport"
    }

    if containsAny(normalized, [
      "microphone",
      "audio data shards",
      "surroundaudioinfo",
    ]) {
      return "audio.pipeline"
    }

    if containsAny(normalized, [
      "got sps",
      "got pps",
      "constructing new h264 format description",
      "pull renderer dequeued frame",
      "renderer pacing target updated",
      "requested idr",
    ]) {
      return "video.decoder"
    }

    if containsAny(normalized, [
      "window-will-enter-fullscreen",
      "window-did-enter-fullscreen",
      "window-will-exit-fullscreen",
      "window-did-exit-fullscreen",
      "window-resigned-key",
      "other-window-became-key",
      "startup display mode",
      "performclosestreamwindow",
      "active space change decision",
    ]) {
      return "ui.window"
    }

    if normalized.contains("> stage "), normalized.contains(" failed:") {
      return "stream.lifecycle"
    }

    if containsAny(normalized, [
      "stream target selection",
      "stream target classification",
      "stream risk assessment",
      "recommended fallback",
      "stream timing config",
      "resume?",
      "listartconnectionctx",
      "clconnectionstarted",
      "connectionstarted",
      "input stream established",
      "disconnect requested",
      "connection terminated:",
      "begin-stop:",
      "stream stop took",
      "cancel pending reconnect",
      "connection status update:",
      "reconnect requested:",
      "reconnect stop took",
      "disconnect-from-stream",
      "performclose invoked",
    ]) {
      return "stream.lifecycle"
    }

    if let noiseCategory = DebugLogNoiseClassifier.category(for: line) {
      return descriptor(forNoiseCategory: noiseCategory).categoryKey
    }

    return "other"
  }

  private static func containsAny(_ line: String, _ needles: [String]) -> Bool {
    needles.contains { line.contains($0) }
  }
}

enum DebugNoiseCategory: String, CaseIterable {
  case appKitMenuInconsistency
  case networkStackNoise
  case systemTransportFallback
  case discoveryChatter
  case hostIdentityMismatch

  var displayName: String {
    switch self {
    case .appKitMenuInconsistency:
      return "AppKit Menu Inconsistency"
    case .networkStackNoise:
      return "Network Stack Noise"
    case .systemTransportFallback:
      return "System Transport Fallback"
    case .discoveryChatter:
      return "Discovery Chatter"
    case .hostIdentityMismatch:
      return "Host Identity Mismatch"
    }
  }

  /// `displayName` in the app language (the raw value is what the logger writes).
  var localizedName: String { tr(displayName) }
}

extension DebugNoiseCategory {
  /// Maps `MLLogNoiseCategory` (LogBuffer.h) as delivered by the logger; 0 means "not noise".
  init?(loggerValue: Int) {
    switch loggerValue {
    case 1: self = .appKitMenuInconsistency
    case 2: self = .networkStackNoise
    case 3: self = .systemTransportFallback
    case 4: self = .discoveryChatter
    case 5: self = .hostIdentityMismatch
    default: return nil
    }
  }
}

enum DebugLogNoiseClassifier {
  static func category(for line: String) -> DebugNoiseCategory? {
    if line.mlContainsCaseInsensitive("Discovery summary for ")
      || line.mlContainsCaseInsensitive("Resolved address:")
    {
      return .discoveryChatter
    }

    if isServerCertificateMismatchLine(line) || isIncorrectHostLine(line) {
      return .hostIdentityMismatch
    }

    if line.mlContainsCaseInsensitive("Internal inconsistency in menus") {
      return .appKitMenuInconsistency
    }

    if line.mlContainsCaseInsensitive("NSURLErrorDomain")
      && (line.contains("-1001") || line.contains("-1004") || line.contains("-1005"))
    {
      return .systemTransportFallback
    }

    if line.mlContainsCaseInsensitive("nw_")
      || line.mlContainsCaseInsensitive("tcp_input")
      || line.mlContainsCaseInsensitive("Request failed with error")
      || (line.mlContainsCaseInsensitive("Connection ")
        && line.mlContainsCaseInsensitive("failed"))
      || (line.mlContainsCaseInsensitive("Task <")
        && line.mlContainsCaseInsensitive("finished with error"))
    {
      return .networkStackNoise
    }

    return nil
  }

  static func isServerCertificateMismatchLine(_ line: String) -> Bool {
    line.mlContainsCaseInsensitive("Server certificate mismatch")
  }

  static func isIncorrectHostLine(_ line: String) -> Bool {
    line.mlContainsCaseInsensitive("Received response from incorrect host:")
  }

  static func extractErrorCodeDescription(from line: String) -> String {
    if let code = firstMatch(in: line, pattern: #"Code=(-?\d+)"#) {
      return "error \(code)"
    }
    if let code = firstMatch(in: line, pattern: #"(-1001|-1004|-1005)"#) {
      return "error \(code)"
    }
    return "error unknown"
  }

  static func extractTarget(from line: String) -> String {
    if let endpoint = firstMatch(in: line, pattern: #"((?:\d{1,3}\.){3}\d{1,3}:\d+)"#) {
      return endpoint
    }
    if let endpoint = firstMatch(in: line, pattern: #"(\[[0-9a-fA-F:]+\]:\d+)"#) {
      return endpoint
    }
    if let host = firstMatch(in: line, pattern: #"https?://([^\s/]+)"#) {
      return host
    }
    return "unknown target"
  }

  static func extractDiscoveryHost(from line: String) -> String {
    if let host = firstMatch(in: line, pattern: #"Discovery summary for\s+([^:]+):"#) {
      return host
    }
    if let host = firstMatch(in: line, pattern: #"Resolved address:\s+([^\s]+)\s+->"#) {
      return host
    }
    return "unknown"
  }

  static func extractDiscoveryState(from line: String) -> String? {
    firstMatch(in: line, pattern: #":\s*(\d+\s+online,\s*\d+\s+offline)"#)
  }

  static func extractIncorrectHost(from line: String) -> String? {
    firstMatch(in: line, pattern: #"incorrect host:\s*([^\s]+)"#)
  }

  static func extractExpectedHost(from line: String) -> String? {
    firstMatch(in: line, pattern: #"expected:\s*([^\s]+)"#)
  }

  static func shortHostIdentity(_ identity: String?) -> String? {
    guard let identity, !identity.isEmpty else { return nil }
    guard identity.count > 8 else { return identity }
    return String(identity.prefix(8)) + "…"
  }

  private static func firstMatch(in text: String, pattern: String) -> String? {
    guard let regex = DebugLogRegexCache.shared.regex(for: pattern) else {
      return nil
    }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, options: [], range: range) else {
      return nil
    }
    let captureIndex = match.numberOfRanges > 1 ? 1 : 0
    let captureRange = match.range(at: captureIndex)
    guard
      let swiftRange = Range(captureRange, in: text),
      !swiftRange.isEmpty
    else {
      return nil
    }
    return String(text[swiftRange])
  }
}

enum DebugLogLevel: String, CaseIterable {
  case all
  case debug
  case info
  case warn
  case error
  case unknown

  var rank: Int {
    switch self {
    case .all: return -1
    case .debug: return 0
    case .info: return 1
    case .warn: return 2
    case .error: return 3
    case .unknown: return 0
    }
  }

  var displayText: String {
    switch self {
    case .all: return "All"
    case .debug: return "Debug"
    case .info: return "Info"
    case .warn: return "Warn"
    case .error: return "Error"
    case .unknown: return "Unknown"
    }
  }
}

struct DebugLogEntry: Identifiable {
  let id: String
  let timestamp: Date?
  let timestampText: String?
  let level: DebugLogLevel
  let message: String
  let defaultTitle: String
  let defaultDetail: String?
  let rawLine: String
  let count: Int
  let category: MLLogCategoryDescriptor
  let searchIndex: String
  let noiseCategory: DebugNoiseCategory?
  let isNoiseSummary: Bool

  var searchableText: String {
    searchIndex
  }

  func matchesCategoryFilter(_ filterKey: String) -> Bool {
    category.matchesFilterKey(filterKey)
  }

  func matchesKeyword(_ keyword: String) -> Bool {
    keyword.isEmpty || searchIndex.contains(keyword)
  }
}

private struct DebugLogPresentation {
  let title: String
  let detail: String?
}

enum DebugLogParser {
  private static let loggerDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return formatter
  }()

  private static let timestampPrefixRegex = try? NSRegularExpression(
    pattern: #"^\[([^\]]+)\]\s*(.*)$"#)
  private static let levelPrefixRegex = try? NSRegularExpression(
    pattern: #"^(<DEBUG>|<INFO>|<WARN>|<ERROR>)\s*(.*)$"#)

  static func parseEntries(from text: String) -> [DebugLogEntry] {
    let rows = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    return rows.map { parseSingleLine($0, entryID: nil, category: nil, categorySearchText: nil) }
  }

  /// Parses complete log lines once. Every entry gets the unique id
  /// `idPrefix` + running sequence number, so ids stay unique and stable while the
  /// viewer appends lines, even when many lines share a timestamp and text.
  /// `startSequence` is the number of lines already parsed for this prefix.
  static func parseLines(
    _ lines: [String],
    idPrefix: String,
    startSequence: Int
  ) -> [DebugLogEntry] {
    var searchTextByCategory: [String: String] = [:]
    var result: [DebugLogEntry] = []
    result.reserveCapacity(lines.count)
    var sequence = startSequence
    for line in lines {
      let category = MLLogCategoryClassifier.descriptor(forLine: line)
      let searchText: String
      if let cached = searchTextByCategory[category.categoryKey] {
        searchText = cached
      } else {
        // Localised names are looked up once per batch, not once per line.
        searchText = category.searchableText
        searchTextByCategory[category.categoryKey] = searchText
      }
      result.append(
        parseSingleLine(
          line, entryID: "\(idPrefix)\(sequence)", category: category,
          categorySearchText: searchText))
      sequence += 1
    }
    return result
  }

  /// Turns entries delivered by the logger into viewer entries. Level, time, message and the
  /// noise classification come from the logger as fields; only the display category and the
  /// friendly title are still derived from the text, once per entry.
  static func entries(from structured: [MLLogEntry]) -> [DebugLogEntry] {
    var searchTextByCategory: [String: String] = [:]
    var result: [DebugLogEntry] = []
    result.reserveCapacity(structured.count)
    for source in structured {
      result.append(entry(from: source, searchTextByCategory: &searchTextByCategory))
    }
    return result
  }

  private static func debugLevel(for level: LogLevel) -> DebugLogLevel {
    if level == LOG_D { return .debug }
    if level == LOG_I { return .info }
    if level == LOG_W { return .warn }
    if level == LOG_E { return .error }
    return .unknown
  }

  private static func entry(
    from source: MLLogEntry,
    searchTextByCategory: inout [String: String]
  ) -> DebugLogEntry {
    let level = debugLevel(for: source.level)
    let message = source.message
    let rawLine = source.fileLine
    let noiseCategory = DebugNoiseCategory(loggerValue: source.noiseCategory)
    let isNoiseSummary = source.isSummary && noiseCategory != nil

    let category: MLLogCategoryDescriptor
    let presentation: DebugLogPresentation
    if isNoiseSummary, let noiseCategory = noiseCategory {
      category = MLLogCategoryClassifier.descriptor(forNoiseCategory: noiseCategory)
      presentation =
        generatedSummaryPresentation(message: message, noiseCategory: noiseCategory)
        ?? DebugLogPresentation(title: message, detail: nil)
    } else if source.isSummary,
      let repeated = generatedSummaryPresentation(message: message, noiseCategory: nil)
    {
      category = MLLogCategoryClassifier.descriptor(forLine: rawLine)
      presentation = repeated
    } else {
      category = MLLogCategoryClassifier.descriptor(forLine: rawLine)
      presentation = defaultPresentation(
        forMessage: message,
        rawLine: rawLine,
        level: level,
        category: category,
        isNoiseSummary: false
      )
    }

    let searchText: String
    if let cached = searchTextByCategory[category.categoryKey] {
      searchText = cached
    } else {
      // Localised names are looked up once per batch, not once per line.
      searchText = category.searchableText
      searchTextByCategory[category.categoryKey] = searchText
    }

    return DebugLogEntry(
      id: "\(source.sequence)",
      timestamp: Date(timeIntervalSince1970: source.timestamp),
      timestampText: source.timestampText,
      level: level,
      message: message,
      defaultTitle: presentation.title,
      defaultDetail: presentation.detail,
      rawLine: rawLine,
      count: 1,
      category: category,
      searchIndex: makeSearchIndex(
        category: category,
        categorySearchText: searchText,
        defaultTitle: presentation.title,
        defaultDetail: presentation.detail,
        message: message,
        rawLine: rawLine
      ),
      noiseCategory: isNoiseSummary ? noiseCategory : nil,
      isNoiseSummary: isNoiseSummary
    )
  }

  static func curatedEntries(
    fromRawText text: String,
    minimumLevel: DebugLogLevel,
    showSystemNoise: Bool,
    aggregationWindowSeconds: TimeInterval = 5.0
  ) -> [DebugLogEntry] {
    curatedEntries(
      fromEntries: parseEntries(from: text),
      minimumLevel: minimumLevel,
      showSystemNoise: showSystemNoise,
      aggregationWindowSeconds: aggregationWindowSeconds
    )
  }

  /// Same as `curatedEntries(fromRawText:...)` for lines that are already parsed.
  static func curatedEntries(
    fromEntries entries: [DebugLogEntry],
    minimumLevel: DebugLogLevel,
    showSystemNoise: Bool,
    aggregationWindowSeconds: TimeInterval = 5.0
  ) -> [DebugLogEntry] {
    var result: [DebugLogEntry] = []
    var pending: PendingNoiseAggregation?
    var summarySequence = 0

    func flushPending(force: Bool, now: Date?) {
      guard let current = pending else { return }
      if !force, let now, now.timeIntervalSince(current.startTime) < aggregationWindowSeconds {
        return
      }
      // The text is written the way the logger words its own summaries; the friendly title and
      // detail are derived from it, so both sources are shown the same way.
      let window = Int(aggregationWindowSeconds)
      let summaryDetail: String
      switch current.category {
      case .discoveryChatter:
        if current.target == "resolved-address" {
          summaryDetail = "repeated address resolution: \(current.reason)"
        } else {
          summaryDetail = "\(current.reason), \(current.target)"
        }
      case .hostIdentityMismatch:
        var details: [String] = []
        if current.certificateMismatchCount > 0 {
          details.append("certificate mismatches: \(current.certificateMismatchCount)")
        }
        if current.incorrectHostCount > 0 {
          details.append("incorrect hosts: \(current.incorrectHostCount)")
        }
        if let expected = DebugLogNoiseClassifier.shortHostIdentity(current.expectedHostIdentity) {
          details.append("expected \(expected)")
        }
        if let actual = DebugLogNoiseClassifier.shortHostIdentity(current.actualHostIdentity) {
          details.append("received \(actual)")
        }
        summaryDetail = details.isEmpty ? "host identity verification failed" : details.joined(separator: ", ")
      default:
        summaryDetail = "primary cause: \(current.reason), target: \(current.target)"
      }
      let summaryLine =
        "\(current.category.displayName): in \(window)s, \(current.count) occurrences (\(summaryDetail))"
      let summaryPresentation = noiseSummaryPresentation(
        category: current.category, seconds: "\(window)", count: "\(current.count)", detail: summaryDetail)
      summarySequence += 1
      let summary = DebugLogEntry(
        id: "s\(summarySequence)|" + makeStableID(
          timestampText: current.timestampText,
          rawLine: summaryLine,
          category: MLLogCategoryClassifier.descriptor(forNoiseCategory: current.category),
          noiseCategory: current.category,
          isNoiseSummary: true
        ),
        timestamp: current.lastTimestamp ?? current.startTime,
        timestampText: current.timestampText,
        level: .warn,
        message: summaryLine,
        defaultTitle: summaryPresentation.title,
        defaultDetail: summaryPresentation.detail,
        rawLine: summaryLine,
        count: current.count,
        category: MLLogCategoryClassifier.descriptor(forNoiseCategory: current.category),
        searchIndex: makeSearchIndex(
          category: MLLogCategoryClassifier.descriptor(forNoiseCategory: current.category),
          defaultTitle: summaryPresentation.title,
          defaultDetail: summaryPresentation.detail,
          message: summaryLine,
          rawLine: summaryLine
        ),
        noiseCategory: current.category,
        isNoiseSummary: true
      )
      if matchesMinimumLevel(summary.level, minimumLevel: minimumLevel) {
        result.append(summary)
      }
      pending = nil
    }

    for entry in entries {
      let category = DebugLogNoiseClassifier.category(for: entry.rawLine)

      if showSystemNoise {
        flushPending(force: true, now: entry.timestamp)
        if matchesMinimumLevel(entry.level, minimumLevel: minimumLevel) {
          result.append(entry)
        }
        continue
      }

      guard let category else {
        flushPending(force: true, now: entry.timestamp)
        if matchesMinimumLevel(entry.level, minimumLevel: minimumLevel) {
          result.append(entry)
        }
        continue
      }

      if var current = pending, current.category == category {
        let shouldContinueWindow: Bool
        if let now = entry.timestamp, let last = current.lastTimestamp {
          shouldContinueWindow = now.timeIntervalSince(last) <= aggregationWindowSeconds
        } else {
          shouldContinueWindow = true
        }

        if shouldContinueWindow {
          current.count += 1
          current.lastTimestamp = entry.timestamp ?? current.lastTimestamp
          current.timestampText = entry.timestampText ?? current.timestampText
          if category == .discoveryChatter {
            current.reason = DebugLogNoiseClassifier.extractDiscoveryHost(from: entry.rawLine)
            current.target =
              DebugLogNoiseClassifier.extractDiscoveryState(from: entry.rawLine)
              ?? (entry.rawLine.mlContainsCaseInsensitive("Resolved address:")
                ? "resolved-address" : "state changed")
          } else if category == .hostIdentityMismatch {
            if DebugLogNoiseClassifier.isServerCertificateMismatchLine(entry.rawLine) {
              current.certificateMismatchCount += 1
            }
            if DebugLogNoiseClassifier.isIncorrectHostLine(entry.rawLine) {
              current.incorrectHostCount += 1
            }
            if let actual = DebugLogNoiseClassifier.extractIncorrectHost(from: entry.rawLine) {
              current.actualHostIdentity = actual
            }
            if let expected = DebugLogNoiseClassifier.extractExpectedHost(from: entry.rawLine) {
              current.expectedHostIdentity = expected
            }
            current.reason = "Host identity verification"
            current.target = "cert-or-host-mismatch"
          } else {
            current.reason = DebugLogNoiseClassifier.extractErrorCodeDescription(from: entry.rawLine)
            current.target = DebugLogNoiseClassifier.extractTarget(from: entry.rawLine)
          }
          pending = current
          continue
        }
      }

      flushPending(force: true, now: entry.timestamp)
      let startTime = entry.timestamp ?? Date()
      pending = PendingNoiseAggregation(
        category: category,
        count: 1,
        startTime: startTime,
        lastTimestamp: entry.timestamp,
        timestampText: entry.timestampText,
        reason: category == .discoveryChatter
          ? DebugLogNoiseClassifier.extractDiscoveryHost(from: entry.rawLine)
          : category == .hostIdentityMismatch
            ? "Host identity verification"
          : DebugLogNoiseClassifier.extractErrorCodeDescription(from: entry.rawLine),
        target: category == .discoveryChatter
          ? (DebugLogNoiseClassifier.extractDiscoveryState(from: entry.rawLine)
            ?? (entry.rawLine.mlContainsCaseInsensitive("Resolved address:")
              ? "resolved-address" : "state changed"))
          : category == .hostIdentityMismatch
            ? "cert-or-host-mismatch"
          : DebugLogNoiseClassifier.extractTarget(from: entry.rawLine)
        ,
        certificateMismatchCount: DebugLogNoiseClassifier.isServerCertificateMismatchLine(entry.rawLine) ? 1 : 0,
        incorrectHostCount: DebugLogNoiseClassifier.isIncorrectHostLine(entry.rawLine) ? 1 : 0,
        actualHostIdentity: DebugLogNoiseClassifier.extractIncorrectHost(from: entry.rawLine),
        expectedHostIdentity: DebugLogNoiseClassifier.extractExpectedHost(from: entry.rawLine)
      )

      let startLine =
        "\(category.displayName): aggregating for \(Int(aggregationWindowSeconds))s window"
      let startTitle = tr(
        "%@: aggregating for %@ s window", category.localizedName, "\(Int(aggregationWindowSeconds))")
      summarySequence += 1
      let startEntry = DebugLogEntry(
        id: "s\(summarySequence)|" + makeStableID(
          timestampText: entry.timestampText,
          rawLine: startLine,
          category: MLLogCategoryClassifier.descriptor(forNoiseCategory: category),
          noiseCategory: category,
          isNoiseSummary: true
        ),
        timestamp: entry.timestamp,
        timestampText: entry.timestampText,
        level: .info,
        message: startLine,
        defaultTitle: startTitle,
        defaultDetail: nil,
        rawLine: startLine,
        count: 1,
        category: MLLogCategoryClassifier.descriptor(forNoiseCategory: category),
        searchIndex: makeSearchIndex(
          category: MLLogCategoryClassifier.descriptor(forNoiseCategory: category),
          defaultTitle: startTitle,
          defaultDetail: nil,
          message: startLine,
          rawLine: startLine
        ),
        noiseCategory: category,
        isNoiseSummary: true
      )
      if matchesMinimumLevel(startEntry.level, minimumLevel: minimumLevel) {
        result.append(startEntry)
      }
    }

    flushPending(force: true, now: Date())
    return result
  }

  static func matchesMinimumLevel(_ level: DebugLogLevel, minimumLevel: DebugLogLevel) -> Bool {
    if minimumLevel == .all {
      return true
    }
    return level.rank >= minimumLevel.rank
  }

  static func foldConsecutiveDuplicates(_ entries: [DebugLogEntry]) -> [DebugLogEntry] {
    guard !entries.isEmpty else { return [] }

    var folded: [DebugLogEntry] = []
    var current = entries[0]
    var repeatCount = max(1, current.count)

    func flushCurrent() {
      let merged = DebugLogEntry(
        id: current.id,
        timestamp: current.timestamp,
        timestampText: current.timestampText,
        level: current.level,
        message: current.message,
        defaultTitle: current.defaultTitle,
        defaultDetail: current.defaultDetail,
        rawLine: current.rawLine,
        count: repeatCount,
        category: current.category,
        searchIndex: current.searchIndex,
        noiseCategory: current.noiseCategory,
        isNoiseSummary: current.isNoiseSummary
      )
      folded.append(merged)
    }

    for next in entries.dropFirst() {
      let isSameKind =
        current.level == next.level
        && current.message == next.message
        && current.category.categoryKey == next.category.categoryKey
        && current.noiseCategory == next.noiseCategory
        && current.isNoiseSummary == next.isNoiseSummary
      if isSameKind {
        repeatCount += max(1, next.count)
      } else {
        flushCurrent()
        current = next
        repeatCount = max(1, next.count)
      }
    }
    flushCurrent()
    return folded
  }

  private static func parseSingleLine(
    _ line: String,
    entryID: String?,
    category knownCategory: MLLogCategoryDescriptor?,
    categorySearchText: String?
  ) -> DebugLogEntry {
    var remaining = line
    var timestampText: String?
    var timestamp: Date?

    if let matched = matchLine(remaining, regex: timestampPrefixRegex), matched.count >= 2 {
      timestampText = matched[0]
      remaining = matched[1]
      if let ts = timestampText {
        timestamp = loggerDateFormatter.date(from: ts)
      }
    }

    var level: DebugLogLevel = .unknown
    var message = remaining
    if let matched = matchLine(remaining, regex: levelPrefixRegex), matched.count >= 2 {
      switch matched[0] {
      case "<DEBUG>": level = .debug
      case "<INFO>": level = .info
      case "<WARN>": level = .warn
      case "<ERROR>": level = .error
      default: level = .unknown
      }
      message = matched[1]
    }

    let category = knownCategory ?? MLLogCategoryClassifier.descriptor(forLine: line)
    let presentation = defaultPresentation(
      forMessage: message,
      rawLine: line,
      level: level,
      category: category,
      isNoiseSummary: false
    )

    return DebugLogEntry(
      id: entryID
        ?? makeStableID(
          timestampText: timestampText,
          rawLine: line,
          category: category,
          noiseCategory: nil,
          isNoiseSummary: false
        ),
      timestamp: timestamp,
      timestampText: timestampText,
      level: level,
      message: message,
      defaultTitle: presentation.title,
      defaultDetail: presentation.detail,
      rawLine: line,
      count: 1,
      category: category,
      searchIndex: makeSearchIndex(
        category: category,
        categorySearchText: categorySearchText,
        defaultTitle: presentation.title,
        defaultDetail: presentation.detail,
        message: message,
        rawLine: line
      ),
      noiseCategory: nil,
      isNoiseSummary: false
    )
  }

  private static func defaultPresentation(
    forMessage message: String,
    rawLine: String,
    level: DebugLogLevel,
    category: MLLogCategoryDescriptor,
    isNoiseSummary: Bool
  ) -> DebugLogPresentation {
    if isNoiseSummary {
      return DebugLogPresentation(title: message, detail: nil)
    }

    // Tagged lines are matched on their own text, whatever category they were filed under.
    if let tagged = taggedPresentation(message: message) {
      return tagged
    }

    let normalized = message.lowercased()
    let cleaned = stripTechnicalPrefix(from: message)

    switch category.categoryKey {
    case "discovery.mdns":
      if normalized == "starting discovery" {
        return .init(title: tr("Started scanning for hosts"), detail: tr("Preparing to probe known hosts and local network discovery services"))
      }
      if normalized == "starting mdns discovery" {
        return .init(title: tr("Started mDNS discovery"), detail: nil)
      }
      if normalized == "stopping discovery" {
        return .init(title: tr("Stopped scanning for hosts"), detail: nil)
      }
      if normalized == "stopping mdns discovery" {
        return .init(title: tr("Stopped mDNS discovery"), detail: nil)
      }
      if normalized == "updating hosts..." {
        return .init(title: tr("Updating host list"), detail: nil)
      }
      if let host = firstCapture(in: message, pattern: #"Found new host:\s*(.+)$"#) {
        return .init(title: tr("Discovered a new host"), detail: host)
      }
      if let host = firstCapture(in: message, pattern: #"Found existing host through MDNS:\s*(.+)$"#) {
        return .init(title: tr("mDNS discovered a known host"), detail: host)
      }
      if let captures = captures(in: message, pattern: #"Resolved address:\s*([^\s]+)\s*->\s*(.+)$"#), captures.count >= 2 {
        return .init(title: tr("Resolved host address"), detail: "\(captures[0]) → \(captures[1])")
      }
      if let captures = captures(in: message, pattern: #"Discovery summary for\s+([^:]+):\s*(.+)$"#), captures.count >= 2 {
        return .init(title: tr("Host probe result"), detail: "\(captures[0]): \(captures[1])")
      }
      if let host = firstCapture(in: message, pattern: #"Found service:\s+.+\.\s([^ ]+)\s+-?\d+$"#) {
        return .init(title: tr("Discovered broadcast service"), detail: host)
      }
      return .init(title: cleaned, detail: nil)

    case "pairing.identity":
      if normalized.contains("server certificate mismatch") {
        return .init(title: tr("Server certificate does not match the saved identity"), detail: tr("This usually means the wrong host was reached or the host certificate changed"))
      }
      if normalized.contains("client certificate imported in memory without keychain access") {
        return .init(title: tr("Client certificate loaded into memory"), detail: tr("This connection will not write to Keychain"))
      }
      if let captures = captures(in: message, pattern: #"incorrect host:\s*([^\s]+)\s+expected:\s*([^\s]+)"#), captures.count >= 2 {
        let actual = DebugLogNoiseClassifier.shortHostIdentity(captures[0]) ?? captures[0]
        let expected = DebugLogNoiseClassifier.shortHostIdentity(captures[1]) ?? captures[1]
        return .init(title: tr("Received a response from a host with a mismatched identity"), detail: tr("Actual %@ · Expected %@", actual, expected))
      }
      return .init(title: cleaned, detail: nil)

    case "network.tls":
      if let code = firstCapture(in: message, pattern: #"error\s+(-?\d+)"#) ?? firstCapture(in: message, pattern: #"Code=(-?\d+)"#) {
        return .init(title: tr("TLS / certificate handshake failed"), detail: tr("Error code %@", code))
      }
      return .init(title: tr("TLS / certificate verification failed"), detail: cleaned)

    case "network.http", "network.transport":
      if let code = firstCapture(in: message, pattern: #"Request failed with error\s+(-?\d+)"#) {
        return .init(title: friendlyNetworkFailureTitle(for: code), detail: tr("Error code %@", code))
      }
      if normalized.contains("app list successfully retreived") || normalized.contains("app list successfully retrieved") {
        let tries = firstCapture(in: message, pattern: #"took\s+(\d+)\s+tries"#) ?? "0"
        return .init(title: tr("App list retrieved"), detail: tr("Retry count %@", tries))
      }
      if normalized.contains("stun failed to get wan address") {
        let code = firstCapture(in: message, pattern: #":\s*(-?\d+)$"#) ?? "unknown"
        return .init(title: tr("STUN failed to obtain the public address"), detail: tr("Error code %@", code))
      }
      if normalized.contains("requesting:") && normalized.contains("/resume?") {
        return .init(title: tr("Requesting stream session resume"), detail: nil)
      }
      if normalized.contains("received response:") {
        return .init(title: tr("Received host response"), detail: nil)
      }
      if normalized.contains("making request:") {
        return .init(title: tr("Sending host request"), detail: nil)
      }
      return .init(title: cleaned, detail: nil)

    case "stream.lifecycle":
      if normalized.contains("stream target selection:") {
        let active = value(forKey: "active", in: message)
        return .init(title: tr("Stream target selected"), detail: active)
      }
      if normalized.contains("stream target classification:") {
        let reason = value(forKey: "reason", in: message)
        return .init(title: tr("Stream route classification completed"), detail: reason)
      }
      if let detail = suffix(in: cleaned, after: "Stream risk assessment:") {
        return .init(title: tr("Stream specification assessment"), detail: detail)
      }
      if let detail = suffix(in: cleaned, after: "Recommended fallback:") {
        return .init(title: tr("Recommended fallback configuration"), detail: detail)
      }
      if let detail = suffix(in: cleaned, after: "Stream timing config:") {
        return .init(title: tr("Stream timing configuration applied"), detail: detail)
      }
      if normalized.contains("listartconnectionctx") {
        return .init(title: tr("Starting stream connection"), detail: nil)
      }
      if normalized.contains("clconnectionstarted") || normalized.contains("connectionstarted") {
        return .init(title: tr("Stream connection started"), detail: cleaned)
      }
      if normalized.contains("input stream established") {
        return .init(title: tr("Input path established"), detail: nil)
      }
      if normalized.contains("performclose invoked") {
        return .init(title: tr("User requested the stream window to close"), detail: nil)
      }
      if normalized.contains("disconnect requested") {
        return .init(title: tr("Received stream disconnect request"), detail: cleaned)
      }
      if normalized.contains("stream stop took") {
        return .init(title: tr("Stream stopped"), detail: cleaned)
      }
      if normalized.contains("input summary") {
        return .init(title: tr("Input statistics summary"), detail: suffixAfterFirstColon(in: cleaned) ?? cleaned)
      }
      return .init(title: cleaned, detail: nil)

    case "input.scroll":
      if normalized.contains("scroll-trace start") {
        return .init(title: tr("Scroll input started"), detail: cleaned)
      }
      if normalized.contains("scroll-trace render") {
        return .init(title: tr("Scroll effect displayed"), detail: cleaned)
      }
      return .init(title: cleaned, detail: nil)

    case "input.mouse":
      if normalized.contains("absolute pos=") {
        return .init(title: tr("Sent absolute mouse position"), detail: cleaned)
      }
      if normalized.contains("relative raw=") {
        return .init(title: tr("Sent relative mouse movement"), detail: cleaned)
      }
      return .init(title: cleaned, detail: nil)

    case "input.click":
      return .init(title: tr("Mouse click event"), detail: cleaned)

    case "input.capture":
      if let reason = value(forKey: "reason", in: message) {
        return .init(title: tr("Mouse capture state changed"), detail: reason)
      }
      return .init(title: tr("Mouse capture state changed"), detail: cleaned)

    case "video.decoder":
      if normalized.contains("got sps") || normalized.contains("got pps") {
        return .init(title: tr("Video stream parameters updated"), detail: cleaned)
      }
      if normalized.contains("constructing new h264 format description") {
        return .init(title: tr("Rebuilt H.264 decode format"), detail: nil)
      }
      if normalized.contains("renderer pacing target updated") {
        return .init(title: tr("Render pacing target updated"), detail: cleaned)
      }
      return .init(title: cleaned, detail: nil)

    case "audio.pipeline":
      if normalized.contains("microphone disabled in settings") {
        return .init(title: tr("Microphone disabled in Settings"), detail: nil)
      }
      if normalized.contains("microphone setting:") {
        return .init(title: tr("Microphone configuration applied"), detail: cleaned)
      }
      return .init(title: cleaned, detail: nil)

    case "ui.window":
      if normalized.contains("startup display mode requesting fullscreen toggle") {
        return .init(title: tr("Requested fullscreen"), detail: nil)
      }
      if normalized.contains("window-did-enter-fullscreen") {
        return .init(title: tr("Window entered fullscreen"), detail: nil)
      }
      if normalized.contains("window-did-exit-fullscreen") {
        return .init(title: tr("Window exited fullscreen"), detail: nil)
      }
      return .init(title: cleaned, detail: nil)

    default:
      return .init(title: cleaned, detail: nil)
    }
  }

  private static func stripTechnicalPrefix(from message: String) -> String {
    var result = message
    for prefix in ["[diag] ", "[inputdiag] ", "[clickdiag] "] {
      if result.hasPrefix(prefix) {
        result.removeFirst(prefix.count)
        break
      }
    }
    return result
  }

  private static func friendlyNetworkFailureTitle(for code: String) -> String {
    switch code {
    case "-1202":
      return tr("Certificate validation failed; preparing fallback")
    case "-1200":
      return tr("TLS secure connection failed; preparing fallback")
    case "-1001":
      return tr("Request timed out; preparing fallback")
    case "-1004":
      return tr("Could not connect to the server; preparing fallback")
    case "-1005":
      return tr("Network connection interrupted")
    default:
      return tr("Network request failed; preparing fallback")
    }
  }

  // MARK: Tagged lines

  private static func pres(_ title: String, _ detail: String? = nil) -> DebugLogPresentation {
    DebugLogPresentation(title: title, detail: detail)
  }

  /// Friendly form of the "[tag] ..." lines and of a few untagged stream-failure lines. Every
  /// title and detail goes through `tr`, so the app's own language override applies. Lines
  /// without a rule return nil and stay exactly as logged, instead of being half translated.
  private static func taggedPresentation(message: String) -> DebugLogPresentation? {
    guard let tagged = splitTag(message) else {
      return plainLinePresentation(message)
    }
    switch tagged.tag {
    case "audio": return audioPresentation(tagged.body)
    case "display-scale": return displayScalePresentation(tagged.body)
    case "startup": return startupPresentation(tagged.body)
    case "hdr": return hdrPresentation(tagged.body)
    case "video": return videoPresentation(tagged.body)
    case "keyboard": return keyboardPresentation(tagged.body)
    case "controller": return controllerPresentation(tagged.body)
    case "live": return livePresentation(tagged.body)
    case "netprobe": return netProbePresentation(tagged.body)
    case "fec": return fecPresentation(tagged.body)
    case "perf": return perfPresentation(tagged.body)
    case "sunshine": return sunshinePresentation(tagged.body)
    case "discovery": return discoveryTagPresentation(tagged.body)
    default: return nil
    }
  }

  /// Splits "[tag] body" into its parts. The tag is at most a few characters, so a message
  /// that merely starts with a bracket is not mistaken for one.
  private static func splitTag(_ message: String) -> (tag: String, body: String)? {
    guard message.first == "[", let close = message.firstIndex(of: "]") else { return nil }
    let tag = message[message.index(after: message.startIndex)..<close]
    guard !tag.isEmpty, tag.count <= 16 else { return nil }
    let body = message[message.index(after: close)...].drop(while: { $0 == " " })
    return (String(tag), String(body))
  }

  /// Range of `key=` where it starts a token, so "valid=" does not match inside "invalid=".
  private static func fieldStart(_ key: String, in text: String) -> Range<String.Index>? {
    let needle = key + "="
    var from = text.startIndex
    while from < text.endIndex, let found = text.range(of: needle, range: from..<text.endIndex) {
      if found.lowerBound == text.startIndex { return found }
      let before = text[text.index(before: found.lowerBound)]
      if before == " " || before == "(" { return found }
      from = found.upperBound
    }
    return nil
  }

  /// Value of `key=` up to the next space or closing bracket (and comma, unless a list is expected).
  private static func field(_ key: String, in text: String, list: Bool = false) -> String? {
    guard let found = fieldStart(key, in: text) else { return nil }
    var end = found.upperBound
    while end < text.endIndex {
      let character = text[end]
      if character == " " || character == ")" || character == ";" || (!list && character == ",") {
        break
      }
      end = text.index(after: end)
    }
    let value = text[found.upperBound..<end]
    return value.isEmpty ? nil : String(value)
  }

  /// Text between `start` and the next `end`, or the rest of the text when `end` is nil.
  private static func between(_ text: String, _ start: String, _ end: String?) -> String? {
    guard let begin = text.range(of: start) else { return nil }
    var stop = text.endIndex
    if let end = end, let found = text.range(of: end, range: begin.upperBound..<text.endIndex) {
      stop = found.lowerBound
    }
    let value = text[begin.upperBound..<stop].trimmingCharacters(in: .whitespaces)
    return value.isEmpty ? nil : value
  }

  /// A number logged as "125" or "125%", without the percent sign (the localised formats add it).
  private static func num(_ value: String?) -> String {
    guard let value = value, !value.isEmpty else { return "?" }
    return value.hasSuffix("%") ? String(value.dropLast()) : value
  }

  private static func audioPresentation(_ body: String) -> DebugLogPresentation? {
    if body.hasPrefix("Stream start:") {
      let codec = field("effective", in: body) ?? field("requested", in: body) ?? "?"
      let channels = field("channels", in: body) ?? "?"
      let passthrough = between(body, "passthrough=", nil) ?? ""
      let detail: String
      if passthrough.hasPrefix("planned") {
        detail = tr("Codec %@ · %@ channels · passthrough planned", codec, channels)
      } else if passthrough.hasPrefix("no(") {
        detail = tr(
          "Codec %@ · %@ channels · passthrough unavailable (%@)", codec, channels,
          String(passthrough.dropFirst(3).dropLast()))
      } else {
        detail = tr("Codec %@ · %@ channels", codec, channels)
      }
      return pres(tr("Audio stream started"), detail)
    }
    if let marker = body.range(of: " decoder ready:") {
      return pres(
        tr("Audio decoder ready"),
        tr("%@ · %@ channels", String(body[..<marker.lowerBound]), field("channels", in: body) ?? "?"))
    }
    if body.hasPrefix("Output started on attempt") {
      // "Output started on attempt N after Mms: backend=X"
      let parts = body.split(separator: " ")
      let attempt = parts.count > 4 ? String(parts[4]) : "?"
      let elapsed = parts.count > 6 ? parts[6].replacingOccurrences(of: "ms:", with: "") : "?"
      let backend = field("backend", in: body) ?? "?"
      return pres(
        backend.contains("passthrough") ? tr("Audio output started (passthrough)") : tr("Audio output started"),
        tr("Attempt %@ · %@ ms · %@", attempt, elapsed, backend))
    }
    if body.hasPrefix("Output start attempt") {
      // "Output start attempt N failed: status=S (CODE) device=NAME elapsedMs=M; ...; retry in Ns"
      let parts = body.split(separator: " ")
      let attempt = parts.count > 3 ? String(parts[3]) : "?"
      let retry = (between(body, "retry in ", nil) ?? "?").trimmingCharacters(in: CharacterSet(charactersIn: "s"))
      return pres(
        tr("Audio output failed to start; retrying"),
        tr(
          "Attempt %@ · device %@ · status %@ · retry in %@ s", attempt,
          between(body, "device=", " elapsedMs=") ?? "?", field("status", in: body) ?? "?", retry))
    }
    if body.hasPrefix("Passthrough started:") {
      return pres(
        tr("Audio passthrough started"),
        tr("Device %@ · codec %@", between(body, "device=", " codec=") ?? "?", between(body, "codec=", " burst=") ?? "?"))
    }
    if body.hasPrefix("Passthrough stopped:") {
      return pres(
        tr("Audio passthrough stopped; decoding on this Mac"),
        between(body, "Passthrough stopped:", ". Falling back"))
    }
    if body.hasPrefix("Passthrough could not start (") {
      return pres(tr("Audio passthrough could not start"), between(body, "start (", ");"))
    }
    if body.hasPrefix("Passthrough not used:") {
      return pres(tr("Audio passthrough not used"), between(body, "not used:", "; decoding"))
    }
    if body.hasPrefix("No audio packet has arrived") {
      return pres(
        tr("No audio received from the host"),
        tr(
          "No audio packet in the first 12 s (codec %@, %@ channels). The host may be streaming without audio.",
          field("codec", in: body) ?? "?", field("channels", in: body) ?? "?"))
    }
    if body.hasPrefix("Audio devices changed while") {
      let retry = (between(body, "retrying in ", nil) ?? "?").trimmingCharacters(in: CharacterSet(charactersIn: "s"))
      return pres(tr("Audio device changed; retrying output"), tr("Retry in %@ s", retry))
    }
    if body.contains(" packets since last report:") {
      return pres(
        tr("Audio packets lost or invalid"),
        tr(
          "Valid %@ · invalid %@ · lost %@ · overflow %@", field("valid", in: body) ?? "?",
          field("invalid", in: body) ?? "?", field("lossPlaceholders", in: body) ?? "?",
          field("fifoOverflows", in: body) ?? "?"))
    }
    if body.hasPrefix("Passthrough bursts since last report:") {
      return pres(
        tr("Audio passthrough is losing data"),
        tr(
          "Played %@ of %@ · dropped %@ · invalid %@", field("played", in: body) ?? "?",
          field("enqueued", in: body) ?? "?", field("dropped", in: body) ?? "?", field("invalid", in: body) ?? "?"))
    }
    if body.hasPrefix("First PCM packet validated") || (body.hasPrefix("First ") && body.contains(" frame received:")) {
      return pres(
        tr("First audio packet received"),
        tr("%@ bytes · %@ channels", field("bytes", in: body) ?? "?", field("channels", in: body) ?? "?"))
    }
    if body.hasPrefix("Output start scheduled in the background") {
      return pres(tr("Audio output starting in the background"), tr("The stream does not wait for the audio device"))
    }
    if body.hasPrefix("Requested codec "), body.contains(" replaced by opus:") {
      return pres(tr("Audio codec replaced by Opus"), between(body, "replaced by opus:", nil))
    }
    if body.contains("muted for this session") {
      return pres(tr("Audio is muted for this session"), body)
    }
    return nil
  }

  private static func displayScalePresentation(_ body: String) -> DebugLogPresentation? {
    if body.hasPrefix("options ") {
      let status = field("status", in: body) ?? "?"
      if status != "200" || field("setSupported", in: body) == "0" {
        return pres(
          tr("Host display scale unavailable"),
          tr("Status %@ · %@", status, field("errorCode", in: body) ?? "-"))
      }
      return pres(
        tr("Host display scale options"),
        tr(
          "Current %@%% · recommended %@%% · supported %@", num(field("current", in: body)),
          num(field("recommended", in: body)), field("supported", in: body, list: true) ?? "?"))
    }
    if body.hasPrefix("ignored stale request") {
      return pres(
        tr("Stale display scale request ignored"),
        tr(
          "Source %@ · request %@ · current %@", field("source", in: body) ?? "?",
          field("generation", in: body) ?? "?", field("current", in: body) ?? "?"))
    }
    if body.hasPrefix("start: ") {
      let rest = String(body.dropFirst(7))
      if rest.hasPrefix("host does not offer a settable scale") {
        return pres(
          tr("Host display scale unavailable"),
          tr("Status %@ · %@", field("status", in: rest) ?? "?", field("errorCode", in: rest) ?? "-"))
      }
      if rest.hasPrefix("no change requested") {
        return pres(tr("Display scale left unchanged"), tr("Current %@%%", num(field("current", in: rest))))
      }
      if rest.hasPrefix("host reported no recommended scale") {
        return pres(tr("Display scale left unchanged"), tr("The host reported no recommended scale"))
      }
      if rest.contains("is not supported by this display") {
        return pres(
          tr("Display scale left unchanged"),
          tr("%@%% is not supported by this display", String(rest.prefix(while: { $0.isNumber }))))
      }
      if rest.hasPrefix("scale is already") {
        return pres(
          tr("Display scale left unchanged"), tr("Already at %@%%", between(rest, "already ", "%") ?? "?"))
      }
      return nil
    }
    if body.hasPrefix("set source=") {
      let confirmed = field("result", in: body) == field("requested", in: body)
      return pres(
        confirmed ? tr("Host display scale applied") : tr("Host display scale change not confirmed"),
        tr("%@%% → %@%%", num(field("previous", in: body)), num(field("result", in: body))))
    }
    if body.hasPrefix("restore (") {
      let reason = between(body, "restore (", ")") ?? "-"
      if body.contains(" requested="), body.contains(" result=") {
        let target = num(field("requested", in: body))
        let confirmed = field("result", in: body) == field("requested", in: body)
        return pres(
          confirmed
            ? tr("Host display scale restored to %@%%", target)
            : tr("Host display scale restore not confirmed"),
          tr("From %@%% · reason %@", num(field("previous", in: body)), reason))
      }
      if let skipped = between(body, " skipped:", nil) {
        return pres(
          tr("Host display scale restore skipped"),
          skipped.hasPrefix("nothing to restore") ? tr("Nothing to restore") : skipped)
      }
      if let dropped = between(body, " dropped:", nil) {
        return pres(tr("Host display scale restore dropped"), dropped)
      }
      if let postponed = between(body, " postponed:", nil) {
        return pres(tr("Host display scale restore postponed"), postponed)
      }
      return nil
    }
    if body.hasPrefix("restore skipped (") {
      return pres(tr("Host display scale restore skipped"), between(body, "):", nil))
    }
    if body.hasPrefix("restore after streaming is off;") {
      return pres(
        tr("Host display scale kept after the stream"),
        tr("%@%% stays applied", between(body, "the ", "%") ?? "?"))
    }
    if body.hasPrefix("scale is back at") {
      return pres(tr("Host display scale is back at %@%%", between(body, "back at ", "%") ?? "?"))
    }
    if body.hasPrefix("pending restore saved:") {
      return pres(
        tr("Display scale restore saved"),
        between(body, "saved:", " device=")?.replacingOccurrences(of: " -> ", with: " → "))
    }
    if body.hasPrefix("launch recovery skipped") {
      let detail: String?
      if body.contains("not in the saved list") {
        detail = tr("The host is not in the saved list")
      } else if body.contains("no known host address") {
        detail = tr("No known host address")
      } else {
        detail = nil
      }
      return pres(tr("Display scale recovery skipped"), detail)
    }
    return nil
  }

  private static func startupPresentation(_ body: String) -> DebugLogPresentation? {
    if body.hasPrefix("Renderer warmup") {
      return pres(tr("Renderer warmed up"), tr("Took %@", field("total", in: body) ?? "?"))
    }
    if body.hasPrefix("Network prep") {
      return pres(
        tr("Network preparation finished"),
        tr(
          "Total %@ · crypto %@ · server info %@ · host launch %@", field("total", in: body) ?? "?",
          field("crypto", in: body) ?? "?", field("serverInfo", in: body) ?? "?",
          field("hostLaunch", in: body) ?? "?"))
    }
    if body.hasPrefix("Main bind") {
      return pres(
        tr("Stream window prepared"),
        tr(
          "Total %@ · renderer ready %@ · connection %@", field("total", in: body) ?? "?",
          field("rendererWarmupReady", in: body) ?? "?", field("connectionQueue", in: body) ?? "?"))
    }
    if body.hasPrefix("Enhanced drawable prewarm skipped") {
      return pres(tr("Renderer prewarm skipped"), tr("No drawable is available yet"))
    }
    if body.hasPrefix("Enhanced drawable prewarm committed") {
      return pres(tr("Renderer prewarmed"))
    }
    return nil
  }

  private static func hdrPresentation(_ body: String) -> DebugLogPresentation? {
    if body.hasPrefix("Dolby Vision negotiated") {
      return pres(tr("Dolby Vision negotiated"), tr("Starting on the HDR10 base layer until the host sends Dolby Vision data"))
    }
    if body.hasPrefix("Dolby Vision RPU first seen") {
      return pres(tr("Switching to the Dolby Vision decoder"), tr("Requested a key frame to switch decoders"))
    }
    if body.hasPrefix("Format description rebuilt") {
      let detail: String?
      if field("dolbyVision", in: body) == "1" {
        detail = tr("Dolby Vision profile %@", field("profile", in: body) ?? "?")
      } else if field("dynamicHdr", in: body) == "1" {
        detail = tr("Dynamic HDR on")
      } else {
        detail = nil
      }
      return pres(tr("Video format rebuilt"), detail)
    }
    if body.hasPrefix("HDR10+ dynamic metadata observed") {
      return pres(tr("HDR10+ metadata detected"), tr("Frames %@", field("frames", in: body) ?? "?"))
    }
    if body.hasPrefix("HDR10+ negotiated but no per-frame metadata") {
      return pres(
        tr("HDR10+ negotiated but no metadata received"), tr("The host may not be sending T.35 SEI"))
    }
    if body.hasPrefix("HEVC prefix SEI preservation enabled") {
      return pres(tr("HDR10+ metadata kept in the stream"))
    }
    if body.hasPrefix("Host HDR mode update") {
      return pres(field("enabled", in: body) == "1" ? tr("Host HDR turned on") : tr("Host HDR turned off"))
    }
    if body.hasPrefix("Renderer HDR state changed") {
      return pres(tr("Renderer HDR state changed"), between(body, "changed:", " transfer=")?.replacingOccurrences(of: "->", with: "→"))
    }
    if body.hasPrefix("Session mastering metadata received") {
      return pres(
        tr("HDR mastering metadata received"),
        tr("MaxCLL %@ · MaxFALL %@", field("MaxCLL", in: body) ?? "?", field("MaxFALL", in: body) ?? "?"))
    }
    if body.hasPrefix("SDR white update nits=") {
      return pres(tr("SDR white level updated"), tr("%@ nits", field("nits", in: body) ?? "?"))
    }
    if body.hasPrefix("SDR white update not sent") {
      return pres(tr("SDR white level not sent"), tr("The host does not advertise dynamic SDR white"))
    }
    return nil
  }

  private static func videoPresentation(_ body: String) -> DebugLogPresentation? {
    if body.hasPrefix("VT decode session ready") {
      let renderer = field("renderer", in: body) ?? "?"
      let hardware = field("hardware", in: body)
      let detail: String
      if hardware == "1" {
        detail = tr("Hardware decoding · renderer %@", renderer)
      } else if hardware == "0" {
        detail = tr("Software decoding · renderer %@", renderer)
      } else {
        detail = tr("Renderer %@", renderer)
      }
      return pres(tr("Video decoder ready"), detail)
    }
    if body.hasPrefix("renderer requested=") {
      return pres(
        tr("Video renderer selected"),
        tr("Active %@ · requested %@", field("active", in: body) ?? "?", field("requested", in: body) ?? "?"))
    }
    if body.hasPrefix("Falling back to Compatibility renderer") {
      return pres(tr("Fell back to the Compatibility renderer"), between(body, "renderer:", nil))
    }
    if body.hasPrefix("Native display layer backpressure detected") {
      return pres(
        tr("Frame dropped: the display is behind"), tr("Count %@", field("count", in: body) ?? "?"))
    }
    if body.hasPrefix("Native display layer appears stalled") {
      return pres(tr("Display layer stalled; flushing queued frames"))
    }
    if body.hasPrefix("Native display layer entered failed state") {
      return pres(tr("Display layer failed; recovering"))
    }
    if body.hasPrefix("Enhanced inflight backpressure") {
      return pres(
        tr("Renderer is falling behind"),
        tr("Count %@ · depth %@", field("count", in: body) ?? "?", field("depth", in: body) ?? "?"))
    }
    if body.hasPrefix("Dolby Vision decoder format:") {
      return pres(
        tr("Dolby Vision decoder switched"),
        tr(
          "Profile %@ · level %@ · %@", field("profile", in: body) ?? "?", field("level", in: body) ?? "?",
          field("dimensions", in: body) ?? "?"))
    }
    if body.hasPrefix("Dolby Vision output unavailable") {
      return pres(tr("Dolby Vision unavailable; using the HDR base layer"), between(body, "unavailable (", ");"))
    }
    if body.hasPrefix("Asynchronous video decoder error") {
      return pres(tr("Video decoder error"), tr("Error %@", between(body, "error:", nil) ?? "?"))
    }
    if body.hasPrefix("Enhanced first present") {
      return pres(tr("First video frame presented"), tr("Startup %@", field("startup", in: body) ?? "?"))
    }
    return nil
  }

  private static func keyboardPresentation(_ body: String) -> DebugLogPresentation? {
    if body.hasPrefix("key mapping=") {
      return pres(
        field("key mapping", in: body) == "typed"
          ? tr("Keyboard mapping: typed characters") : tr("Keyboard mapping: physical key position"),
        tr("Layout %@", field("layout", in: body) ?? "?"))
    }
    return nil
  }

  private static func controllerPresentation(_ body: String) -> DebugLogPresentation? {
    if body.hasPrefix("Host controller type setting=") {
      let label: String
      switch field("setting", in: body) ?? "" {
      case "1": label = tr("Xbox 360")
      case "2": label = tr("DualShock 4 (PS4)")
      case "3": label = tr("DualSense (PS5)")
      default: label = tr("Automatic")
      }
      let declared = field("gamepad", in: body)
      let detail =
        (declared == nil || body.contains("gamepad=(none)"))
        ? tr("Nothing declared; the host decides")
        : tr("Declared to the host as %@", declared ?? "?")
      return pres(tr("Host controller type: %@", label), detail)
    }
    if body.hasPrefix("Neutral input sent before pausing") {
      return pres(tr("Controller input reset before pausing"))
    }
    return nil
  }

  private static func livePresentation(_ body: String) -> DebugLogPresentation? {
    if body.hasPrefix("Stream resolution is now") {
      return pres(tr("Stream resolution changed"), between(body, "now", nil))
    }
    if body.hasPrefix("Host resolution changed") {
      return pres(tr("Host resolution changed"), between(body, "changed:", nil))
    }
    if body.hasPrefix("Ignoring invalid host resolution") {
      return pres(tr("Invalid host resolution ignored"), between(body, "resolution", nil))
    }
    if body.hasPrefix("resolution ") {
      return pres(
        tr("Resolution change requested"),
        tr("%@ · result %@", body.split(separator: " ").dropFirst().first.map(String.init) ?? "?", field("result", in: body) ?? "?"))
    }
    if body.hasPrefix("bitrate ") {
      return pres(
        tr("Bitrate change requested"),
        tr("%@ kbps · result %@", body.split(separator: " ").dropFirst().first.map(String.init) ?? "?", field("result", in: body) ?? "?"))
    }
    if body.hasPrefix("framerate ") {
      return pres(
        tr("Frame rate change requested"),
        tr("%@ fps · result %@", body.split(separator: " ").dropFirst().first.map(String.init) ?? "?", field("result", in: body) ?? "?"))
    }
    if body.contains("not applied"), body.contains("falling back to reconnect") {
      return pres(tr("Live change not applied; reconnecting"), body.components(separatedBy: " not applied").first)
    }
    return nil
  }

  private static func netProbePresentation(_ body: String) -> DebugLogPresentation? {
    if body.hasPrefix("capping bitrate") {
      // "capping bitrate A -> Bkbps"
      let parts = body.split(separator: " ")
      let from = parts.count > 2 ? String(parts[2]) : "?"
      let to = parts.count > 4 ? parts[4].replacingOccurrences(of: "kbps", with: "") : "?"
      return pres(tr("Bitrate capped by the network test"), tr("%@ → %@ kbps", from, to))
    }
    if body.hasPrefix("bandwidth=") {
      return pres(
        tr("Network test finished"),
        tr(
          "Bandwidth %@ · latency %@ · jitter %@", field("bandwidth", in: body) ?? "?",
          field("latency", in: body) ?? "?", field("jitter", in: body) ?? "?"))
    }
    if body.hasPrefix("skipped") {
      return pres(tr("Network test skipped"), field("reason", in: body))
    }
    if body.hasPrefix("audio uses") {
      // "audio uses Nkbps beyond the host reserve: video ceiling A -> Bkbps"
      return pres(
        tr("Video bitrate ceiling lowered for audio"),
        between(body, "video ceiling", nil)?.replacingOccurrences(of: "->", with: "→"))
    }
    return nil
  }

  private static func fecPresentation(_ body: String) -> DebugLogPresentation? {
    if body.hasPrefix("Client FEC preference requested") {
      let value = between(body, "requested:", " (") ?? "?"
      return pres(
        tr("Error correction (FEC) preference requested"),
        value == "-1" ? tr("Automatic") : "\(value)%")
    }
    return nil
  }

  private static func perfPresentation(_ body: String) -> DebugLogPresentation? {
    if body.hasPrefix("fps ") {
      return pres(
        tr("Performance sample"),
        tr(
          "Received %@ · decoded %@ · rendered %@ fps", field("rx", in: body) ?? "?",
          field("de", in: body) ?? "?", field("rd", in: body) ?? "?"))
    }
    return nil
  }

  private static func sunshinePresentation(_ body: String) -> DebugLogPresentation? {
    if body.hasPrefix("Loaded ") && body.contains(" host displays") {
      return pres(tr("Host displays loaded"), tr("%@ displays", between(body, "Loaded ", " host") ?? "?"))
    }
    if body.hasPrefix("Display list request failed") {
      return pres(tr("Host display list request failed"), between(body, "failed:", nil))
    }
    return nil
  }

  private static func discoveryTagPresentation(_ body: String) -> DebugLogPresentation? {
    if body.hasPrefix("First verified endpoint") {
      return pres(
        tr("Host is reachable"),
        tr("%@ · %@ ms", between(body, "host=", " elapsedMs=") ?? "?", field("elapsedMs", in: body) ?? "?"))
    }
    return nil
  }

  /// Untagged lines that only deserve a friendly form because they explain a failed stream.
  private static func plainLinePresentation(_ message: String) -> DebugLogPresentation? {
    if message.hasPrefix("Stage "), message.contains(" failed:") {
      let stage = between(message, "Stage ", " failed:") ?? "?"
      return pres(
        tr("Stream setup failed"),
        tr("Stage: %@ · error %@", stageName(stage), between(message, "failed:", nil) ?? "?"))
    }
    if message.hasPrefix("Connection terminated:") {
      return pres(tr("Stream connection terminated"), tr("Code %@", between(message, "terminated:", nil) ?? "?"))
    }
    return nil
  }

  /// Names of the connection stages as the protocol library reports them. An unknown name is shown as logged.
  private static func stageName(_ name: String) -> String {
    switch name {
    case "platform initialization": return tr("Stage platform initialization")
    case "name resolution": return tr("Stage name resolution")
    case "audio stream initialization": return tr("Stage audio stream initialization")
    case "RTSP handshake": return tr("Stage RTSP handshake")
    case "control stream initialization": return tr("Stage control stream initialization")
    case "video stream initialization": return tr("Stage video stream initialization")
    case "input stream initialization": return tr("Stage input stream initialization")
    case "control stream establishment": return tr("Stage control stream establishment")
    case "video stream establishment": return tr("Stage video stream establishment")
    case "audio stream establishment": return tr("Stage audio stream establishment")
    case "input stream establishment": return tr("Stage input stream establishment")
    default: return name
    }
  }

  // MARK: Generated summaries

  /// "5.0s" or "5s" as logged, shown as a bare number of seconds.
  private static func seconds(_ value: String) -> String {
    value.trimmingCharacters(in: CharacterSet(charactersIn: "s "))
  }

  /// Title and detail of one noise summary. `detail` is the parenthesised part as the logger
  /// wrote it; its known fragments are translated, anything else is kept as logged.
  private static func noiseSummaryPresentation(
    category: DebugNoiseCategory, seconds window: String, count: String, detail: String?
  ) -> DebugLogPresentation {
    pres(
      tr("%@: %@ in %@ s", category.localizedName, count, window),
      detail.map(localizedNoiseDetail))
  }

  private static func localizedNoiseDetail(_ detail: String) -> String {
    if detail.hasPrefix("repeated address resolution:") {
      return tr("Repeated address resolution: %@", between(detail, "resolution:", nil) ?? "?")
    }
    if detail.hasPrefix("primary cause:"), let target = detail.range(of: ", target: ") {
      let cause = String(detail[detail.index(detail.startIndex, offsetBy: 14)..<target.lowerBound])
        .trimmingCharacters(in: .whitespaces)
      return tr(
        "Primary cause: %@ · Target: %@", cause, String(detail[target.upperBound...]))
    }
    let known = [
      "certificate mismatches: ": "Certificate mismatches: %@",
      "incorrect hosts: ": "Incorrect hosts: %@",
      "expected ": "Expected %@",
      "received ": "Received %@",
    ]
    var parts: [String] = []
    for piece in detail.components(separatedBy: ", ") {
      if piece.lowercased() == "host identity verification failed" {
        parts.append(tr("Host identity verification failed"))
        continue
      }
      var translated: String?
      for (prefix, format) in known where piece.lowercased().hasPrefix(prefix) {
        translated = tr(format, String(piece.dropFirst(prefix.count)))
        break
      }
      guard let translated = translated else {
        // A host name or state the logger wrote; part of a plain list, so keep the whole text.
        return detail
      }
      parts.append(translated)
    }
    return parts.joined(separator: " · ")
  }

  /// The summary lines the logger writes itself ("<Noise>: in 5s, N occurrences (...)" and
  /// "[curated] repeated for 5.0s: N times (last: ...)"), shown in the app language.
  private static func generatedSummaryPresentation(
    message: String, noiseCategory: DebugNoiseCategory?
  ) -> DebugLogPresentation? {
    if let noiseCategory = noiseCategory, let marker = message.range(of: ": in ") {
      let rest = message[marker.upperBound...]
      let parts = rest.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
      guard parts.count >= 3, parts[0].hasSuffix("s,") else { return nil }
      var detail: String?
      if let open = rest.firstIndex(of: "("), let close = rest.lastIndex(of: ")"), open < close {
        detail = String(rest[rest.index(after: open)..<close])
      }
      return noiseSummaryPresentation(
        category: noiseCategory, seconds: seconds(String(parts[0].dropLast())), count: String(parts[1]), detail: detail)
    }
    if message.hasPrefix("[curated] repeated for ") {
      guard let window = between(message, "repeated for ", ": "),
        let count = between(message, ": ", " times")
      else { return nil }
      return pres(
        tr("Repeated %@ times within %@ s", count, seconds(window)),
        between(message, "(last:", nil).map { tr("Last: %@", String($0.dropLast())) })
    }
    return nil
  }

  private static func suffix(in text: String, after needle: String) -> String? {
    guard let range = text.range(of: needle) else { return nil }
    let suffix = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
    return suffix.isEmpty ? nil : String(suffix)
  }

  private static func suffixAfterFirstColon(in text: String) -> String? {
    guard let index = text.firstIndex(of: ":") else { return nil }
    let suffix = text[text.index(after: index)...].trimmingCharacters(in: .whitespacesAndNewlines)
    return suffix.isEmpty ? nil : String(suffix)
  }

  private static func value(forKey key: String, in text: String) -> String? {
    firstCapture(in: text, pattern: #"(?<![A-Za-z0-9_])\#(key)=([^\s]+)"#)
  }

  private static func firstCapture(in text: String, pattern: String) -> String? {
    captures(in: text, pattern: pattern)?.first
  }

  private static func captures(in text: String, pattern: String) -> [String]? {
    guard let regex = DebugLogRegexCache.shared.regex(for: pattern) else {
      return nil
    }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, options: [], range: range) else {
      return nil
    }

    var results: [String] = []
    for index in 1..<match.numberOfRanges {
      let captureRange = match.range(at: index)
      guard let swiftRange = Range(captureRange, in: text), !swiftRange.isEmpty else {
        results.append("")
        continue
      }
      results.append(String(text[swiftRange]))
    }
    return results.isEmpty ? nil : results
  }

  private static func makeSearchIndex(
    category: MLLogCategoryDescriptor,
    categorySearchText: String? = nil,
    defaultTitle: String,
    defaultDetail: String?,
    message: String,
    rawLine: String
  ) -> String {
    "\(categorySearchText ?? category.searchableText)\n\(defaultTitle)\n\(defaultDetail ?? "")\n\(message)\n\(rawLine)".lowercased()
  }

  private static func makeStableID(
    timestampText: String?,
    rawLine: String,
    category: MLLogCategoryDescriptor,
    noiseCategory: DebugNoiseCategory?,
    isNoiseSummary: Bool
  ) -> String {
    "\(timestampText ?? "")|\(category.categoryKey)|\(noiseCategory?.rawValue ?? "none")|\(isNoiseSummary ? "1" : "0")|\(rawLine)"
  }

  private static func matchLine(_ input: String, regex: NSRegularExpression?) -> [String]? {
    guard let regex else { return nil }
    let nsRange = NSRange(input.startIndex..<input.endIndex, in: input)
    guard let match = regex.firstMatch(in: input, options: [], range: nsRange) else { return nil }
    var captures: [String] = []
    for index in 1..<match.numberOfRanges {
      let range = match.range(at: index)
      guard let swiftRange = Range(range, in: input) else {
        captures.append("")
        continue
      }
      captures.append(String(input[swiftRange]))
    }
    return captures
  }
}

private struct PendingNoiseAggregation {
  let category: DebugNoiseCategory
  var count: Int
  let startTime: Date
  var lastTimestamp: Date?
  var timestampText: String?
  var reason: String
  var target: String
  var certificateMismatchCount: Int
  var incorrectHostCount: Int
  var actualHostIdentity: String?
  var expectedHostIdentity: String?
}
