import Foundation
import Sparkle

@MainActor
final class SparkleUpdateManager: NSObject, ObservableObject, SPUUpdaterDelegate {
  static let shared = SparkleUpdateManager()

  @objc(startIfConfigured)
  static func startIfConfigured() {
    _ = shared
  }

  private let feedURLs = [
    "https://cnb.cool/AlkaidLab/moonlight-macos-enhanced-release/-/raw/main/appcast.xml",
    "https://raw.githubusercontent.com/AlkaidLab/moonlight-macos-enhanced-release/main/appcast.xml",
  ]

  private var controller: SPUStandardUpdaterController?
  private var feedIndex = 0
  private var appcastLoaded = false

  @Published private(set) var isConfigured = false
  @Published private(set) var isChecking = false
  @Published private(set) var lastError: String?

  private override init() {
    super.init()

    guard let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
      !publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !feedURLs.isEmpty
    else {
      // Release builds inject the Sparkle EdDSA public key through the build
      // environment. Development builds remain usable without an update key.
      return
    }

    let updaterController = SPUStandardUpdaterController(
      startingUpdater: false,
      updaterDelegate: self,
      userDriverDelegate: nil
    )
    controller = updaterController
    updaterController.updater.automaticallyChecksForUpdates = true
    updaterController.updater.updateCheckInterval = 86_400
    updaterController.startUpdater()

    isConfigured = true
  }

  var automaticallyChecksForUpdates: Bool {
    get { controller?.updater.automaticallyChecksForUpdates ?? false }
    set { controller?.updater.automaticallyChecksForUpdates = newValue }
  }

  func checkForUpdates() {
    guard let updater = controller?.updater, updater.canCheckForUpdates else {
      return
    }

    feedIndex = 0
    appcastLoaded = false
    isChecking = true
    lastError = nil
    updater.checkForUpdates()
  }

  func checkForUpdatesInBackground() {
    guard let updater = controller?.updater, updater.canCheckForUpdates else {
      return
    }
    feedIndex = 0
    appcastLoaded = false
    updater.checkForUpdatesInBackground()
  }

  func feedURLString(for updater: SPUUpdater) -> String? {
    guard feedIndex < feedURLs.count else { return nil }
    return feedURLs[feedIndex]
  }

  func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
    appcastLoaded = true
    isChecking = false
  }

  func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
    isChecking = false
  }

  func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
    isChecking = false
    lastError = error.localizedDescription

    // Only fall back when the current feed failed before an appcast was
    // loaded. A valid feed with no newer release is already an authoritative
    // answer and should not trigger a second user-facing check.
    guard !appcastLoaded, feedIndex + 1 < feedURLs.count else { return }
    feedIndex += 1
    appcastLoaded = false
    isChecking = true
    DispatchQueue.main.async {
      updater.checkForUpdates()
    }
  }

  func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
    isChecking = false
  }
}
