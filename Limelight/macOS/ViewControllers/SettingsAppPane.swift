import AppKit
import SwiftUI

struct AppView: View {
  @EnvironmentObject private var settingsModel: SettingsModel
  @ObservedObject private var languageManager = LanguageManager.shared
  @State private var showLiveLogViewer = false
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
  Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.3.9"
}

private struct ReleaseAsset: Decodable, Identifiable {
  let type: String?
  let name: String?
  let url: String?
  let fallbackUrl: String?

  var id: String { name ?? url ?? UUID().uuidString }

  var downloadURL: URL? {
    if let url, let value = URL(string: url) { return value }
    if let fallbackUrl, let value = URL(string: fallbackUrl) { return value }
    return nil
  }
}

private struct ReleaseChannel: Decodable {
  let version: String
  let prerelease: Bool?
  let publishedAt: String?
  let releaseNotes: String?
  let assets: [ReleaseAsset]?
}

private struct ReleaseMetadataDocument: Decodable {
  let channels: [String: ReleaseChannel]
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
private final class ReleaseUpdateChecker: ObservableObject {
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
      for rawSource in sources {
        guard let source = URL(string: rawSource) else { continue }
        do {
          var request = URLRequest(url: source)
          request.timeoutInterval = 15
          let (data, _) = try await URLSession.shared.data(for: request)
          let document = try JSONDecoder().decode(ReleaseMetadataDocument.self, from: data)
          if let channel = document.channels["latest"] {
            release = channel
            sourceURL = source
            state = isNewer(channel.version, than: appVersion) ? .updateAvailable : .upToDate
            return
          }
        } catch {
          errorMessage = error.localizedDescription
        }
      }

      // Keep GitHub as a second metadata authority in addition to the CNB
      // mirrors. The release assets still carry the CNB-first fallback URLs
      // used by the download UI, while Sparkle handles signed installation.
      if let githubRelease = await fetchGitHubRelease() {
        release = githubRelease
        sourceURL = URL(string: "https://api.github.com/repos/skyhua0224/moonlight-macos-enhanced/releases/latest")
        state = isNewer(githubRelease.version, than: appVersion) ? .updateAvailable : .upToDate
        return
      }
      state = .unavailable
    }
  }

  private func fetchGitHubRelease() async -> ReleaseChannel? {
    guard let url = URL(string: "https://api.github.com/repos/skyhua0224/moonlight-macos-enhanced/releases/latest") else {
      return nil
    }

    do {
      var request = URLRequest(url: url)
      request.timeoutInterval = 15
      request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
      request.setValue("MoonlightEnhanced/\(appVersion)", forHTTPHeaderField: "User-Agent")
      let (data, _) = try await URLSession.shared.data(for: request)
      let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
      let assets = release.assets.map { asset in
        ReleaseAsset(
          type: asset.name.contains("universal") ? "macos-universal-dmg" : nil,
          name: asset.name,
          url: asset.browserDownloadURL,
          fallbackUrl: nil)
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
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.3.9"
  }

  private func isNewer(_ candidate: String, than current: String) -> Bool {
    let lhs = numbers(candidate)
    let rhs = numbers(current)
    let count = max(lhs.count, rhs.count)
    for index in 0..<count {
      let left = index < lhs.count ? lhs[index] : 0
      let right = index < rhs.count ? rhs[index] : 0
      if left != right { return left > right }
    }
    return false
  }

  private func numbers(_ value: String) -> [Int] {
    value
      .replacingOccurrences(of: "v", with: "")
      .split(separator: ".")
      .map { Int($0.filter(\.isNumber)) ?? 0 }
  }
}

struct AboutUpdatesSettingsPage: View {
  @ObservedObject private var languageManager = LanguageManager.shared
  @ObservedObject private var sparkle = SparkleUpdateManager.shared
  @StateObject private var checker = ReleaseUpdateChecker()
  @AppStorage("updates.automaticCheck") private var automaticCheck = true

  private var appVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.3.9"
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        AboutHeroCard(version: appVersion)
        AboutUpdateCard(
          checker: checker,
          sparkle: sparkle,
          automaticCheck: $automaticCheck,
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
      sparkle.automaticallyChecksForUpdates = automaticCheck
      if automaticCheck && checker.state == .idle {
        checker.check()
      }
    }
    .onChange(of: automaticCheck) { enabled in
      sparkle.automaticallyChecksForUpdates = enabled
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
              Text(notes)
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .frame(maxHeight: 190)
          }
          HStack {
            Spacer()
            if sparkle.isConfigured {
              Button(languageManager.localize("Install Update")) {
                installUpdate()
              }
              .buttonStyle(.borderedProminent)
            } else if let url = preferredDownloadURL(release) {
              Button(languageManager.localize("Open Download")) {
                NSWorkspace.shared.open(url)
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
          checker.check()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(checker.state == .checking)
      }
      .padding(16)
    }
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
  }
}
