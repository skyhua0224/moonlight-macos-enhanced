import Foundation

enum DebugNoiseCategory: String, CaseIterable {
  case appKitMenuInconsistency
  case networkStackNoise
  case systemTransportFallback
  case discoveryChatter
  case hostIdentityMismatch

  var displayName: String {
    switch self {
    case .appKitMenuInconsistency:
      return "AppKit 菜单噪音 / AppKit Menu Inconsistency"
    case .networkStackNoise:
      return "系统网络噪音 / Network Stack Noise"
    case .systemTransportFallback:
      return "系统传输回退噪音 / System Transport Fallback"
    case .discoveryChatter:
      return "发现服务噪音 / Discovery Chatter"
    case .hostIdentityMismatch:
      return "主机身份不匹配 / Host Identity Mismatch"
    }
  }
}

enum DebugLogNoiseClassifier {
  static func category(for line: String) -> DebugNoiseCategory? {
    if line.localizedCaseInsensitiveContains("Discovery summary for ")
      || line.localizedCaseInsensitiveContains("Resolved address:")
    {
      return .discoveryChatter
    }

    if isServerCertificateMismatchLine(line) || isIncorrectHostLine(line) {
      return .hostIdentityMismatch
    }

    if line.localizedCaseInsensitiveContains("Internal inconsistency in menus") {
      return .appKitMenuInconsistency
    }

    if line.localizedCaseInsensitiveContains("NSURLErrorDomain")
      && (line.contains("-1001") || line.contains("-1004") || line.contains("-1005"))
    {
      return .systemTransportFallback
    }

    if line.localizedCaseInsensitiveContains("nw_")
      || line.localizedCaseInsensitiveContains("tcp_input")
      || line.localizedCaseInsensitiveContains("Request failed with error")
      || (line.localizedCaseInsensitiveContains("Connection ")
        && line.localizedCaseInsensitiveContains("failed"))
      || (line.localizedCaseInsensitiveContains("Task <")
        && line.localizedCaseInsensitiveContains("finished with error"))
    {
      return .networkStackNoise
    }

    return nil
  }

  static func isServerCertificateMismatchLine(_ line: String) -> Bool {
    line.localizedCaseInsensitiveContains("Server certificate mismatch")
  }

  static func isIncorrectHostLine(_ line: String) -> Bool {
    line.localizedCaseInsensitiveContains("Received response from incorrect host:")
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
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
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
