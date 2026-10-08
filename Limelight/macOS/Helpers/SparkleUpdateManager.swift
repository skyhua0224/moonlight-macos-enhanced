import Foundation
import Sparkle

/// Mirrors only this product's signed release archives, never arbitrary URLs.
enum UpdateSourcePolicy {
  static let githubFeed = "https://raw.githubusercontent.com/skyhua0224/moonlight-macos-enhanced/refs/heads/chore/update-feed/appcast.xml"
  static let feeds = [
    githubFeed,
    "https://www.alkaidlab.com/release-metadata/moonlight-macos-enhanced-appcast.xml",
    "https://www.alkaidlab.cn/release-metadata/moonlight-macos-enhanced-appcast.xml",
  ]

  static func metadataVersion(_ tag: String) -> String {
    let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    let withoutBuild = String(version.split(separator: "+", maxSplits: 1).first ?? "")
    // Sparkle uses the native "1.3.9rc1" form for prerelease comparison.
    return withoutBuild.replacingOccurrences(
      of: #"-(rc|alpha|beta)[.-]([0-9]+)$"#, with: "$1$2", options: .regularExpression)
  }

  static func mirrorURL(for url: URL?) -> URL? {
    guard let url, url.scheme == "https", url.host?.lowercased() == "github.com",
      url.user == nil, url.password == nil, url.port == nil,
      url.query == nil, url.fragment == nil
    else { return nil }
    let parts = url.pathComponents.filter { $0 != "/" }
    guard parts.count == 6,
      parts[0] == "skyhua0224", parts[1] == "moonlight-macos-enhanced",
      parts[2] == "releases", parts[3] == "download",
      parts[4].range(of: #"^v[0-9]+\.[0-9]+\.[0-9]+(?:-(?:rc|alpha|beta)[.-][0-9]+)?$"#,
                     options: .regularExpression) != nil,
      ["Moonlight-macOS-Enhanced-arm64.dmg", "Moonlight-macOS-Enhanced-x86_64.dmg",
       "Moonlight-macOS-Enhanced-universal.dmg"].contains(parts[5])
    else { return nil }
    return URL(string: "https://cnb.cool/AlkaidLab/moonlight-macos-enhanced-release/-/releases/download/\(parts[4])/\(parts[5])")
  }

  static func isCancelled(_ error: Error) -> Bool {
    let error = error as NSError
    if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled { return true }
    if error.domain == SUSparkleErrorDomain && error.code == SUError.installationCanceledError.rawValue { return true }
    return (error.userInfo[NSUnderlyingErrorKey] as? Error).map(isCancelled) ?? false
  }
}

@MainActor
private final class MirroredUpdateUserDriver: SPUStandardUserDriver {
  var recoverError: ((Error) -> Bool)?
  var acceptedProperties: NSDictionary?
  var retryProperties: NSDictionary?

  override func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
    if recoverError?(error) == true {
      acknowledgement()
    } else {
      super.showUpdaterError(error, acknowledgement: acknowledgement)
    }
  }

  override func showUpdateFound(with item: SUAppcastItem, state: SPUUserUpdateState,
                                reply: @escaping (SPUUserUpdateChoice) -> Void) {
    let properties = item.propertiesDictionary as NSDictionary
    // Consent is reused only for an identical appcast item. Signature checking
    // remains Sparkle's responsibility, including on the mirror download.
    if let retryProperties, retryProperties.isEqual(properties) {
      self.retryProperties = nil
      reply(.install)
      return
    }
    super.showUpdateFound(with: item, state: state) { [weak self] choice in
      self?.acceptedProperties = choice == .install ? properties : nil
      reply(choice)
    }
  }
}

@MainActor
final class SparkleUpdateManager: NSObject, ObservableObject, SPUUpdaterDelegate {
  static let shared = SparkleUpdateManager()

  @objc(startIfConfigured)
  static func startIfConfigured() { _ = shared }

  private var updater: SPUUpdater?
  private var userDriver: MirroredUpdateUserDriver?
  private var feedIndex = 0
  private var appcastLoaded = false
  private var mirrorAttempted = false
  private var failedItem: SUAppcastItem?
  private var retryPending = false
  private var userInitiated = false

  @Published private(set) var isConfigured = false
  @Published private(set) var isChecking = false
  @Published private(set) var lastError: String?

  private override init() {
    super.init()
    guard let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
      let keyData = Data(base64Encoded: publicKey), keyData.count == 32
    else { return }

    let driver = MirroredUpdateUserDriver(hostBundle: .main, delegate: nil)
    driver.recoverError = { [weak self] error in self?.prepareRetry(for: error) ?? false }
    let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
    self.userDriver = driver
    self.updater = updater
    do {
      try updater.start()
      isConfigured = true
    } catch {
      lastError = error.localizedDescription
    }
  }

  var automaticallyChecksForUpdates: Bool {
    get { updater?.automaticallyChecksForUpdates ?? false }
    set { updater?.automaticallyChecksForUpdates = newValue }
  }

  func checkForUpdates() {
    guard let updater, updater.canCheckForUpdates else { return }
    resetCycle()
    userInitiated = true
    isChecking = true
    updater.checkForUpdates()
  }

  func checkForUpdatesInBackground() {
    guard let updater, updater.canCheckForUpdates else { return }
    resetCycle()
    updater.checkForUpdatesInBackground()
  }

  func allowedChannels(for updater: SPUUpdater) -> Set<String> {
    Bundle.main.object(forInfoDictionaryKey: "UpdateChannel") as? String == "beta" ? ["beta"] : []
  }

  func feedURLString(for updater: SPUUpdater) -> String? { UpdateSourcePolicy.feeds[feedIndex] }

  func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) { appcastLoaded = true }

  func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) { isChecking = false }

  func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
    request.timeoutInterval = 20
    if mirrorAttempted, let failedItem,
      (item.propertiesDictionary as NSDictionary).isEqual(failedItem.propertiesDictionary),
      let mirror = UpdateSourcePolicy.mirrorURL(for: item.fileURL) {
      request.url = mirror
    }
  }

  func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
    if !UpdateSourcePolicy.isCancelled(error), !mirrorAttempted,
      UpdateSourcePolicy.mirrorURL(for: item.fileURL) != nil { failedItem = item }
  }

  func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
    if !prepareRetry(for: error) {
      let nsError = error as NSError
      if !(nsError.domain == SUSparkleErrorDomain && nsError.code == SUError.noUpdateError.rawValue)
        && !UpdateSourcePolicy.isCancelled(error) { lastError = error.localizedDescription }
    }
  }

  func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
    isChecking = false
    guard retryPending else { resetCycle(keepingError: true); return }
    retryPending = false
    // The old driver must finish before starting the next Sparkle cycle.
    DispatchQueue.main.async { [weak self, weak updater] in
      guard let self, let updater, updater.canCheckForUpdates else { return }
      self.isChecking = true
      if self.userInitiated { updater.checkForUpdates() }
      else { updater.checkForUpdatesInBackground() }
    }
  }

  private func prepareRetry(for error: Error) -> Bool {
    guard !UpdateSourcePolicy.isCancelled(error) else { return false }
    if retryPending { return true }
    let error = error as NSError
    guard error.domain == SUSparkleErrorDomain else { return false }
    if !appcastLoaded,
      [Int(SUError.appcastError.rawValue), Int(SUError.appcastParseError.rawValue)].contains(error.code),
      feedIndex + 1 < UpdateSourcePolicy.feeds.count {
      feedIndex += 1
      retryPending = true
      lastError = nil
      return true
    }
    if error.code == SUError.downloadError.rawValue, !mirrorAttempted, let failedItem {
      mirrorAttempted = true
      let properties = failedItem.propertiesDictionary as NSDictionary
      if userDriver?.acceptedProperties?.isEqual(properties) == true {
        userDriver?.retryProperties = properties
      }
      retryPending = true
      lastError = nil
      return true
    }
    return false
  }

  private func resetCycle(keepingError: Bool = false) {
    feedIndex = 0
    appcastLoaded = false
    mirrorAttempted = false
    failedItem = nil
    retryPending = false
    userInitiated = false
    userDriver?.acceptedProperties = nil
    userDriver?.retryProperties = nil
    if !keepingError { lastError = nil }
  }
}
