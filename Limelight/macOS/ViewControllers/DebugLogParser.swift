import Foundation

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
  let id = UUID()
  let timestamp: Date?
  let timestampText: String?
  let level: DebugLogLevel
  let message: String
  let rawLine: String
  let count: Int
  let noiseCategory: DebugNoiseCategory?
  let isNoiseSummary: Bool

  var searchableText: String {
    "\(message)\n\(rawLine)"
  }
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
    return rows.map(parseSingleLine)
  }

  static func curatedEntries(
    fromRawText text: String,
    minimumLevel: DebugLogLevel,
    showSystemNoise: Bool,
    aggregationWindowSeconds: TimeInterval = 5.0
  ) -> [DebugLogEntry] {
    var result: [DebugLogEntry] = []
    let entries = parseEntries(from: text)
    var pending: PendingNoiseAggregation?

    func flushPending(force: Bool, now: Date?) {
      guard let current = pending else { return }
      if !force, let now, now.timeIntervalSince(current.startTime) < aggregationWindowSeconds {
        return
      }
      let summaryLine: String
      switch current.category {
      case .discoveryChatter:
        if current.target == "resolved-address" {
          summaryLine =
            "\(current.category.displayName): \(Int(aggregationWindowSeconds))s, \(current.count) lines (\(current.reason) address repeats)"
        } else {
          summaryLine =
            "\(current.category.displayName): \(Int(aggregationWindowSeconds))s, \(current.count) lines (\(current.reason), \(current.target))"
        }
      case .hostIdentityMismatch:
        var details: [String] = []
        if current.certificateMismatchCount > 0 {
          details.append("证书不匹配 \(current.certificateMismatchCount) 次")
        }
        if current.incorrectHostCount > 0 {
          details.append("错误主机 \(current.incorrectHostCount) 次")
        }
        if let expected = DebugLogNoiseClassifier.shortHostIdentity(current.expectedHostIdentity) {
          details.append("期望 \(expected)")
        }
        if let actual = DebugLogNoiseClassifier.shortHostIdentity(current.actualHostIdentity) {
          details.append("收到 \(actual)")
        }
        let detailText = details.isEmpty ? "主机身份校验失败" : details.joined(separator: ", ")
        summaryLine =
          "\(current.category.displayName): \(Int(aggregationWindowSeconds))s, \(current.count) lines (\(detailText))"
      default:
        summaryLine =
          "\(current.category.displayName): \(Int(aggregationWindowSeconds))s, \(current.count) lines (\(current.reason), target \(current.target))"
      }
      let summary = DebugLogEntry(
        timestamp: current.lastTimestamp ?? current.startTime,
        timestampText: current.timestampText,
        level: .warn,
        message: summaryLine,
        rawLine: summaryLine,
        count: current.count,
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
              ?? (entry.rawLine.localizedCaseInsensitiveContains("Resolved address:")
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
            current.reason = "主机身份校验"
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
            ? "主机身份校验"
          : DebugLogNoiseClassifier.extractErrorCodeDescription(from: entry.rawLine),
        target: category == .discoveryChatter
          ? (DebugLogNoiseClassifier.extractDiscoveryState(from: entry.rawLine)
            ?? (entry.rawLine.localizedCaseInsensitiveContains("Resolved address:")
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
      let startEntry = DebugLogEntry(
        timestamp: entry.timestamp,
        timestampText: entry.timestampText,
        level: .info,
        message: startLine,
        rawLine: startLine,
        count: 1,
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
        timestamp: current.timestamp,
        timestampText: current.timestampText,
        level: current.level,
        message: current.message,
        rawLine: current.rawLine,
        count: repeatCount,
        noiseCategory: current.noiseCategory,
        isNoiseSummary: current.isNoiseSummary
      )
      folded.append(merged)
    }

    for next in entries.dropFirst() {
      let isSameKind =
        current.level == next.level
        && current.message == next.message
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

  private static func parseSingleLine(_ line: String) -> DebugLogEntry {
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

    return DebugLogEntry(
      timestamp: timestamp,
      timestampText: timestampText,
      level: level,
      message: message,
      rawLine: line,
      count: 1,
      noiseCategory: nil,
      isNoiseSummary: false
    )
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
