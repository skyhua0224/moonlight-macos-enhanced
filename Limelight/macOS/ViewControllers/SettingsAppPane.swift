import AppKit
import SwiftUI
import Sparkle

struct AppView: View {
  @EnvironmentObject private var settingsModel: SettingsModel
  @ObservedObject private var languageManager = LanguageManager.shared
  @SwiftUI.State private var showLiveLogViewer = false
  @AppStorage("theme") private var appearance = 0
  @AppStorage("autoDiscoverNewHosts") private var autoDiscoverNewHosts = true

  var body: some View {
    SettingsContent {
      SettingsPageHero(
        title: "App & Diagnostics",
        subtitle: "App diagnostics settings subtitle",
        symbol: "gearshape.2.fill",
        tint: .pink
      )

      FormSection(title: "Application") {
        SettingsRow(title: "Appearance") {
          Picker("", selection: $appearance) {
            Text("System Default").tag(0)
            Text("Light").tag(1)
            Text("Dark").tag(2)
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .frame(width: 150, alignment: .trailing)
          .onChange(of: appearance) { value in
            (NSApp.delegate as? AppDelegateForAppKit)?.applyThemePreference(value)
          }
        }
        SettingsRow(title: "Language") {
          Picker("", selection: $languageManager.currentLanguage) {
            ForEach(AppLanguage.allCases) { value in
              Text(languageManager.localize(value.rawValue)).tag(value)
            }
          }
          .labelsHidden()
          .frame(width: 150, alignment: .trailing)
          .onChange(of: languageManager.currentLanguage) { _ in
            languageManager.applyAppLanguage()
          }
        }

        ToggleCell(title: "Optimize Game Settings", boolBinding: $settingsModel.optimize)
        SettingsRow(title: "Custom Artwork Dimensions") {
          DimensionsInputView(widthBinding: $settingsModel.appArtworkWidth, heightBinding: $settingsModel.appArtworkHeight,
            placeholderDimensions: CGSize(width: 300, height: 400))
        }
        ToggleCell(title: "Quit App After Stream", boolBinding: $settingsModel.quitAppAfterStream)
        ToggleCell(title: "Dim Unfocused Artwork", boolBinding: $settingsModel.dimNonHoveredArtwork)
        ToggleCell(title: "Show Performance Overlay", boolBinding: $settingsModel.showPerformanceOverlay)
        ToggleCell(title: "Show Connection Warnings", boolBinding: $settingsModel.showConnectionWarnings)
      }

      FormSection(title: "Network Compatibility") {
        ToggleCell(title: "Automatically Discover New Hosts", boolBinding: Binding(
          get: { autoDiscoverNewHosts },
          set: { value in
            guard value != autoDiscoverNewHosts else { return }
            autoDiscoverNewHosts = value
            NotificationCenter.default.post(name: Notification.Name("MoonlightDiscoveryPreferencesChanged"), object: nil)
          }
        ))
        ToggleCell(title: "AWDL Stability Helper", hintKey: "AWDL Stability Helper detail", boolBinding: $settingsModel.awdlStabilityHelperEnabled)
        SettingsRow(title: "Input Monitoring") {
          Button(languageManager.localize("Open Settings")) {
            InputMonitoringPermissionManager.sharedManager.openSystemPreferences()
          }
          .buttonStyle(.bordered)
        }
        SettingsRow(title: "Microphone") {
          Button(languageManager.localize("Open Settings")) {
            MicrophoneManager.shared.openSystemPreferences()
          }
          .buttonStyle(.bordered)
        }
      }

      FormSection(title: "Diagnostics") {
        SettingsRow(title: "Log Mode") {
          Picker("", selection: $settingsModel.debugLogMode) {
            Text(languageManager.localize("Curated")).tag("curated")
            Text(languageManager.localize("Raw")).tag("raw")
          }
          .labelsHidden()
          .frame(width: 160, alignment: .trailing)
        }
        SettingsRow(title: "Minimum Log Level") {
          Picker("", selection: $settingsModel.debugLogMinLevel) {
            ForEach(["Error", "Warning", "Info", "Debug"], id: \.self) { value in
              Text(languageManager.localize(value)).tag(value)
            }
          }
          .labelsHidden()
          .frame(width: 150, alignment: .trailing)
        }
        ToggleCell(title: "Show System Noise", boolBinding: $settingsModel.debugLogShowSystemNoise)
        ToggleCell(title: "Auto Scroll Logs", boolBinding: $settingsModel.debugLogAutoScroll)
        ToggleCell(title: "Input Diagnostics", boolBinding: $settingsModel.debugLogInputDiagnostics)
        SettingsRow(title: "View Live Log") {
          Button("Open") { showLiveLogViewer = true }
        }

        HStack {
          Text(languageManager.localize("Diagnostics are written to the application log."))
            .font(.footnote)
            .foregroundStyle(.secondary)
          Spacer()
        }
        .padding(.vertical, 7)
      }
    }
    .sheet(isPresented: $showLiveLogViewer) {
      SettingsLogViewer(rawLogURL: nil, curatedLogURL: nil).environmentObject(settingsModel)
    }
  }
}

struct FileMappingSettingsPage: View {
  var body: some View {
    RemoteFileMappingView()
  }
}

struct AboutSettingsPage: View {
  @ObservedObject private var languageManager = LanguageManager.shared

  var body: some View {
    SettingsContent {
      SettingsPageHero(
        title: "About",
        subtitle: "About settings subtitle",
        symbol: "info.circle.fill",
        tint: .gray
      )

      FormSection(title: "About") {
        SettingsRow(title: "Version") {
          Text(appVersion)
            .foregroundStyle(.secondary)
        }
        SettingsRow(title: "Project") {
          Link("Moonlight macOS Enhanced", destination: URL(string: "https://github.com/skyhua0224/moonlight-macos-enhanced")!)
        }
        SettingsRow(title: "License") {
          Text("GPL-3.0")
            .foregroundStyle(.secondary)
        }
      }
    }
  }
}

struct UpdatesSettingsPage: View {
  @ObservedObject private var languageManager = LanguageManager.shared

  var body: some View {
    SettingsContent {
      SettingsPageHero(
        title: "Updates",
        subtitle: "Updates settings subtitle",
        symbol: "arrow.down.circle.fill",
        tint: .blue
      )

      FormSection(title: "Updates") {
        SettingsRow(title: "Current Version") {
          Text(appVersion)
            .foregroundStyle(.secondary)
        }
        HStack {
          Spacer()
          Button(languageManager.localize("Check for Updates")) {
            NSWorkspace.shared.open(URL(string: "https://github.com/skyhua0224/moonlight-macos-enhanced/releases")!)
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
        }
        .frame(minHeight: 40)
      }
    }
  }
}

private var appVersion: String {
  Bundle.main.object(forInfoDictionaryKey: "UpdateDisplayVersion") as? String
    ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.3.9"
}

struct ReleaseAsset: Decodable, Identifiable {
  let type: String?
  let name: String?
  let url: String?
  let fallbackUrl: String?

  var id: String { name ?? url ?? UUID().uuidString }

  var downloadURL: URL? {
    let candidates = [url, fallbackUrl].compactMap { $0 }.compactMap(URL.init(string:))
    return candidates.first(where: { $0.scheme == "https" && $0.host == "github.com" })
      ?? candidates.first(where: { $0.scheme == "https" })
  }
}

struct ReleaseChannel: Decodable {
  let version: String
  let prerelease: Bool?
  let publishedAt: String?
  let releaseNotes: String?
  let assets: [ReleaseAsset]?
}

private struct ReleaseMetadataDocument: Decodable {
  let channels: [String: ReleaseChannel?]
}

private struct GitHubReleaseAsset: Decodable {
  let name: String
  let browserDownloadURL: String

  enum CodingKeys: String, CodingKey {
    case name
    case browserDownloadURL = "browser_download_url"
  }
}

private struct GitHubRelease: Decodable {
  let tagName: String
  let prerelease: Bool
  let publishedAt: String?
  let body: String?
  let assets: [GitHubReleaseAsset]

  enum CodingKeys: String, CodingKey {
    case tagName = "tag_name"
    case prerelease
    case publishedAt = "published_at"
    case body
    case assets
  }
}

@MainActor
final class ReleaseUpdateChecker: ObservableObject {
  static let shared = ReleaseUpdateChecker()
  enum State: Equatable {
    case idle
    case checking
    case upToDate
    case updateAvailable
    case unavailable
  }

  @Published private(set) var state: State = .idle
  @Published private(set) var release: ReleaseChannel?
  @Published private(set) var sourceURL: URL?
  @Published private(set) var errorMessage = ""

  private let sources = [
    "https://www.alkaidlab.com/release-metadata/moonlight-macos-enhanced.json",
    "https://www.alkaidlab.cn/release-metadata/moonlight-macos-enhanced.json",
  ]

  func check() {
    guard state != .checking else { return }
    state = .checking
    errorMessage = ""
    Task {
      if let githubRelease = await fetchGitHubRelease() {
        release = githubRelease
        sourceURL = URL(string: "https://api.github.com/repos/skyhua0224/moonlight-macos-enhanced/releases")
        state = isNewer(githubRelease.version, than: appVersion) ? .updateAvailable : .upToDate
        return
      }
      for rawSource in sources {
        guard let source = URL(string: rawSource) else { continue }
        do {
          var request = URLRequest(url: source)
          request.timeoutInterval = 15
          let (data, response) = try await URLSession.shared.data(for: request)
          guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode)
          else { throw URLError(.badServerResponse) }
          let document = try JSONDecoder().decode(ReleaseMetadataDocument.self, from: data)
          let keys = acceptsPrereleases ? ["latest", "pre-latest"] : ["latest"]
          let channels = keys.compactMap { document.channels[$0] ?? nil }
          if let channel = channels.max(by: { isNewer($1.version, than: $0.version) }) {
            release = channel
            sourceURL = source
            state = isNewer(channel.version, than: appVersion) ? .updateAvailable : .upToDate
            return
          }
        } catch {
          errorMessage = error.localizedDescription
        }
      }

      state = .unavailable
    }
  }

  private func fetchGitHubRelease() async -> ReleaseChannel? {
    guard let url = URL(string: "https://api.github.com/repos/skyhua0224/moonlight-macos-enhanced/releases?per_page=20") else {
      return nil
    }

    do {
      var request = URLRequest(url: url)
      request.timeoutInterval = 15
      request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
      request.setValue("MoonlightEnhanced/\(appVersion)", forHTTPHeaderField: "User-Agent")
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode)
      else { throw URLError(.badServerResponse) }
      let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
      guard let release = releases.filter({ !$0.prerelease || acceptsPrereleases })
        .max(by: { isNewer($1.tagName, than: $0.tagName) }) else { return nil }
      let assets = release.assets.map { asset in
        ReleaseAsset(
          type: asset.name.contains("universal") ? "macos-universal-dmg" : nil,
          name: asset.name,
          url: asset.browserDownloadURL,
          fallbackUrl: UpdateSourcePolicy.mirrorURL(for: URL(string: asset.browserDownloadURL))?.absoluteString)
      }
      return ReleaseChannel(
        version: release.tagName,
        prerelease: release.prerelease,
        publishedAt: release.publishedAt,
        releaseNotes: release.body,
        assets: assets)
    } catch {
      return nil
    }
  }

  private var appVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "UpdateDisplayVersion") as? String
      ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.3.9"
  }

  private var acceptsPrereleases: Bool {
    Bundle.main.object(forInfoDictionaryKey: "UpdateChannel") as? String == "beta"
  }

  private func isNewer(_ candidate: String, than current: String) -> Bool {
    let candidate = UpdateSourcePolicy.metadataVersion(candidate)
    let current = UpdateSourcePolicy.metadataVersion(current)
    return SUStandardVersionComparator.default.compareVersion(candidate, toVersion: current) == .orderedDescending
  }

}

struct AboutUpdatesSettingsPage: View {
  @ObservedObject private var languageManager = LanguageManager.shared
  @ObservedObject private var sparkle = SparkleUpdateManager.shared
  @ObservedObject private var checker = ReleaseUpdateChecker.shared

  private var appVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "UpdateDisplayVersion") as? String
      ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.3.9"
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        AboutHeroCard(version: appVersion)
        AboutUpdateCard(
          checker: checker,
          sparkle: sparkle,
          automaticCheck: Binding(
            get: { sparkle.automaticChecksEnabled },
            set: { sparkle.automaticallyChecksForUpdates = $0 }
          ),
          statusText: statusText,
          statusColor: statusColor,
          preferredDownloadURL: preferredDownloadURL,
          installUpdate: {
            sparkle.checkForUpdates()
          }
        )
      }
      .frame(maxWidth: 760, alignment: .leading)
      .padding(.horizontal, 28)
      .padding(.vertical, 24)
      .frame(maxWidth: .infinity, alignment: .center)
    }
    .onAppear {
      if checker.state == .idle {
        checker.check()
      }
    }
  }

  private var statusText: String {
    switch checker.state {
    case .idle: return languageManager.localize("Not Checked")
    case .checking: return languageManager.localize("Checking for Updates")
    case .upToDate: return languageManager.localize("Up to Date")
    case .updateAvailable: return languageManager.localize("Update Available")
    case .unavailable: return checker.errorMessage.isEmpty
      ? languageManager.localize("Update Check Unavailable") : checker.errorMessage
    }
  }

  private var statusColor: Color {
    switch checker.state {
    case .upToDate: return .green
    case .updateAvailable: return .blue
    case .unavailable: return .orange
    default: return .secondary
    }
  }

  private func preferredDownloadURL(from release: ReleaseChannel) -> URL? {
    let assets = release.assets ?? []
    let preferred = assets.first(where: { $0.type == "macos-universal-dmg" })
      ?? assets.first(where: { $0.name?.contains("universal") == true })
      ?? assets.first
    return preferred?.downloadURL
  }
}

private struct AboutHeroCard: View {
  let version: String
  @ObservedObject private var languageManager = LanguageManager.shared

  var body: some View {
    VStack(spacing: 8) {
      Image(nsImage: NSApp.applicationIconImage)
        .resizable()
        .interpolation(.high)
        .frame(width: 82, height: 82)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
      Text("Moonlight macOS Enhanced")
        .font(.title.weight(.semibold))
      Text(languageManager.localize("Version") + " " + version)
        .font(.callout)
        .foregroundStyle(.secondary)
      Text("About hero subtitle")
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 24)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
  }
}

private struct AboutUpdateCard: View {
  @Environment(\.openURL) private var openURL
  @ObservedObject private var languageManager = LanguageManager.shared
  @ObservedObject var checker: ReleaseUpdateChecker
  @ObservedObject var sparkle: SparkleUpdateManager
  @Binding var automaticCheck: Bool
  let statusText: String
  let statusColor: Color
  let preferredDownloadURL: (ReleaseChannel) -> URL?
  let installUpdate: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text(languageManager.localize("Updates"))
          .font(.headline)
        Spacer()
        Text(statusText)
          .foregroundStyle(statusColor)
          .font(.callout)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 13)

      Divider()

      ToggleCell(title: "Check Automatically", boolBinding: $automaticCheck)
        .padding(.horizontal, 16)

      if let release = checker.release, checker.state == .updateAvailable {
        Divider()
        VStack(alignment: .leading, spacing: 9) {
          Text(release.version)
            .font(.title3.weight(.semibold))
          if let notes = release.releaseNotes, !notes.isEmpty {
            ScrollView {
              ReleaseNotesView(markdown: notes)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .frame(maxHeight: 190)
          }
          HStack {
            Spacer()
            if sparkle.hasInstallableUpdate {
              Button(languageManager.localize("Install Update")) {
                installUpdate()
              }
              .buttonStyle(.borderedProminent)
              .disabled(!sparkle.canCheckUpdates)
            } else if let url = preferredDownloadURL(release) {
              Button(languageManager.localize("Download Update")) {
                openURL(url)
              }
              .buttonStyle(.borderedProminent)
            }
          }
        }
        .padding(16)
      }

      Divider()
      HStack {
        Text(languageManager.localize("Update Sources detail"))
          .font(.footnote)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Spacer()
        Button(languageManager.localize("Check for Updates")) {
          installUpdate()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(checker.state == .checking || (sparkle.isConfigured && !sparkle.canCheckUpdates))
      }
      .padding(16)
    }
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
  }
}
