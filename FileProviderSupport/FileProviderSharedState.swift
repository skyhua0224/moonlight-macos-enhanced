import Foundation

/// State shared by the signed application and its File Provider extension.
/// The extension never reads the application's database directly.
struct FileProviderSharedState: Codable {
  let hostIdentifier: String
  let hostName: String
  let hostAddress: String
  let serverCertificate: Data
  let clientIdentity: Data
  let capability: Data
  let updatedAt: Date
}

enum FileProviderSharedStateStore {
  static let appGroupIdentifier = "group.std.skyhua.MoonlightMacEnhanced"
  private static let filename = "remote-file-provider-state.json"

  static func write(_ state: FileProviderSharedState) -> Bool {
    guard let directory = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: appGroupIdentifier
    ) else {
      return false
    }
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let url = directory.appendingPathComponent(filename)
      let data = try JSONEncoder().encode(state)
      try data.write(to: url, options: [.atomic, .completeFileProtection])
      return true
    } catch {
      return false
    }
  }

  static func read() -> FileProviderSharedState? {
    guard let directory = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: appGroupIdentifier
    ) else {
      return nil
    }
    let url = directory.appendingPathComponent(filename)
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(FileProviderSharedState.self, from: data)
  }
}
