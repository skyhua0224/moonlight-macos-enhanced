import AppKit
import SwiftUI
import Sparkle

struct AppView: View {
  @EnvironmentObject private var settingsModel: SettingsModel
  @ObservedObject private var languageManager = LanguageManager.shared
  @SwiftUI.State private var showLiveLogViewer = false
  @AppStorage("theme") private var appearance = 0
  @AppStorage("autoDiscoverNewHosts") private var autoDiscoverNewHosts = true
  @AppStorage(TailscaleDetection.defaultsKey) private var autoDetectTailscale = true
  @SwiftUI.State private var classicHome = UserDefaults.standard.string(forKey: "MLConceptVariant") == "classic"

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
          .controllerPicker(
            selection: $appearance,
            choices: [(0, languageManager.localize("System Default")), (1, languageManager.localize("Light")),
                      (2, languageManager.localize("Dark"))])
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
          .controllerPicker(
            selection: $languageManager.currentLanguage, options: AppLanguage.allCases,
            title: { languageManager.localize($0.rawValue) })
          .frame(width: 150, alignment: .trailing)
          .onChange(of: languageManager.currentLanguage) { _ in
            languageManager.applyAppLanguage()
          }
        }

        ToggleCell(title: "Classic Home Page", hintKey: "Classic Home Page detail", boolBinding: Binding(
          get: { classicHome },
          set: { value in
            classicHome = value
            // The key the home reads at launch (DeckVariant.current); the new home is what it is without it.
            if value {
              UserDefaults.standard.set("classic", forKey: "MLConceptVariant")
            } else {
              UserDefaults.standard.removeObject(forKey: "MLConceptVariant")
            }
          }
        ))
        ToggleCell(title: "Optimize Game Settings", boolBinding: $settingsModel.optimize)
        SettingsRow(title: "Custom Artwork Dimensions") {
          DimensionsInputView(widthBinding: $settingsModel.appArtworkWidth, heightBinding: $settingsModel.appArtworkHeight,
            placeholderDimensions: CGSize(width: 300, height: 400))
        }
        ToggleCell(title: "Quit App After Stream", boolBinding: $settingsModel.quitAppAfterStream)
        ToggleCell(title: "Dim Unfocused Artwork", boolBinding: $settingsModel.dimNonHoveredArtwork)
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
        ToggleCell(title: "Automatically Detect Tailscale", hintKey: "Automatically Detect Tailscale detail", boolBinding: Binding(
          get: { autoDetectTailscale },
          set: { value in
            guard value != autoDetectTailscale else { return }
            autoDetectTailscale = value
            NotificationCenter.default.post(name: Notification.Name("MoonlightTailscaleDetectionChanged"), object: nil)
          }
        ))
        ToggleCell(title: "AWDL Stability Helper", hintKey: "AWDL Stability Helper detail", boolBinding: $settingsModel.awdlStabilityHelperEnabled)
        if settingsModel.awdlStabilityHelperEnabled {
          AwdlHelperStatusRow()
        }
        SettingsRow(title: "Input Monitoring", detail: "Input Monitoring purpose") {
          Button(languageManager.localize("Open Settings")) {
            InputMonitoringPermissionManager.sharedManager.openSystemPreferences()
          }
          .controllerButtonStyle(.bordered)
        }
        SettingsRow(title: "Microphone") {
          Button(languageManager.localize("Open Settings")) {
            MicrophoneManager.shared.openSystemPreferences()
          }
          .controllerButtonStyle(.bordered)
        }
      }

      FormSection(title: "Diagnostics") {
        SettingsRow(title: "Recording Detail", detail: "Recording Detail detail") {
          Picker("", selection: $settingsModel.debugLogRecordingDetail) {
            Text(languageManager.localize("Normal")).tag("normal")
            Text(languageManager.localize("Detailed")).tag("detailed")
          }
          .labelsHidden()
          .controllerPicker(
            selection: $settingsModel.debugLogRecordingDetail,
            choices: [("normal", languageManager.localize("Normal")), ("detailed", languageManager.localize("Detailed"))])
          .frame(width: 160, alignment: .trailing)
        }
        ToggleCell(title: "Input Diagnostics", boolBinding: $settingsModel.debugLogInputDiagnostics)
        SettingsRow(title: "View Live Log") {
          Button("Open") { showLiveLogViewer = true }
        }

        HStack {
          Text(languageManager.localize("Diagnostics are written to the application log."))
            .font(.footnote).settingsLineCheck("SettingsAppPane:113")
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

/// Under the AWDL switch: whether the helper is authorized, and the one button that fixes it when it is not. Quiet: it
/// never asks by itself, and a stream starts whatever it says.
private struct AwdlHelperStatusRow: View {
  @ObservedObject private var languageManager = LanguageManager.shared
  @ObservedObject private var awdl = AwdlHelperManager.sharedManager

  var body: some View {
    // Without awdl0 or without a helper in this build there is nothing to authorize.
    if awdl.status != .noInterface && awdl.status != .unsupported {
      SettingsRow(title: "AWDL Helper Status") {
        VStack(alignment: .trailing, spacing: 4) {
          HStack(spacing: 10) {
            Label(
              languageManager.localize(awdl.statusLabelKey),
              systemImage: awdl.status == .ready ? "checkmark.circle.fill" : "minus.circle"
            )
            .foregroundColor(awdl.status == .ready ? .green : .secondary)
            if let titleKey = awdl.actionTitleKey {
              Button(languageManager.localize(titleKey)) {
                awdl.performPrimaryAction()
              }
              .controllerButtonStyle(.bordered)
              .disabled(awdl.isWorking)
            }
          }
          if awdl.status == .failed, !awdl.lastErrorMessage.isEmpty {
            Text(verbatim: awdl.lastErrorMessage)
              .font(.footnote)
              .foregroundStyle(.secondary)
              .multilineTextAlignment(.trailing)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      .onAppear { awdl.refreshAuthorizationStatus() }
    }
  }
}

struct FileMappingSettingsPage: View {
  var body: some View {
    RemoteFileMappingView()
  }
}

struct AboutSettingsPage: View {
  // settings-search: ignore (not shown in the settings window; AboutUpdatesSettingsPage replaced it)
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
  // settings-search: ignore (not shown in the settings window; AboutUpdatesSettingsPage replaced it)
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
          .controllerButtonStyle(.borderedProminent)
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
  private var releaseBuild: Int?

  private let sources = [
    "https://www.alkaidlab.com/release-metadata/moonlight-macos-enhanced.json",
    "https://www.alkaidlab.cn/release-metadata/moonlight-macos-enhanced.json",
  ]

  func check() {
    guard state != .checking else { return }
    state = .checking
    errorMessage = ""
    releaseBuild = nil
    Task {
      if let githubRelease = await fetchGitHubRelease() {
        release = githubRelease
        sourceURL = URL(string: "https://api.github.com/repos/skyhua0224/moonlight-macos-enhanced/releases")
        state = isNewer(githubRelease.version, build: releaseBuild, than: appVersion) ? .updateAvailable : .upToDate
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
          if let channel = channels.max(by: { isLegacyNewer($1.version, than: $0.version) }) {
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
      // Only the newest few eligible releases need a build number; each is one small appcast.
      let eligible = releases
        .filter { UpdateVersionPolicy.isEligible(tag: $0.tagName, prerelease: $0.prerelease, acceptsPrereleases: acceptsPrereleases) }
        .sorted { ($0.publishedAt ?? "") > ($1.publishedAt ?? "") }
        .prefix(4)
      let builds = await withTaskGroup(of: (String, Int?).self) { group in
        for release in eligible {
          group.addTask { (release.tagName, await self.fetchBuildNumber(of: release)) }
        }
        var result: [String: Int] = [:]
        for await (tag, build) in group { if let build { result[tag] = build } }
        return result
      }
      let candidates = eligible.map {
        UpdateVersionPolicy.Release(tag: $0.tagName, prerelease: $0.prerelease, publishedAt: $0.publishedAt, build: builds[$0.tagName])
      }
      guard let chosen = UpdateVersionPolicy.choose(candidates, acceptsPrereleases: acceptsPrereleases,
                                                    legacyNewer: { [self] in isLegacyNewer($0, than: $1) }),
        let release = eligible.first(where: { $0.tagName == chosen.tag }) else { return nil }
      let assets = release.assets.map { asset in
        ReleaseAsset(
          type: asset.name.contains("universal") ? "macos-universal-dmg" : nil,
          name: asset.name,
          url: asset.browserDownloadURL,
          fallbackUrl: UpdateSourcePolicy.mirrorURL(for: URL(string: asset.browserDownloadURL))?.absoluteString)
      }
      releaseBuild = chosen.build
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

  /// The build number of a release, from the appcast attached to it. Nil when there is none or it cannot be read.
  private nonisolated func fetchBuildNumber(of release: GitHubRelease) async -> Int? {
    guard let asset = release.assets.first(where: { $0.name == "appcast.xml" }),
      let url = UpdateVersionPolicy.appcastURL(from: asset.browserDownloadURL) else { return nil }
    do {
      var request = URLRequest(url: url)
      request.timeoutInterval = 15
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
        data.count < 1_000_000 else { return nil }
      return UpdateVersionPolicy.buildNumber(appcast: data, includingBeta: true)
    } catch {
      return nil
    }
  }

  private var appBuild: Int? {
    (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap { Int($0) }
  }

  private func isLegacyNewer(_ candidate: String, than current: String) -> Bool {
    let candidate = UpdateSourcePolicy.metadataVersion(candidate)
    let current = UpdateSourcePolicy.metadataVersion(current)
    return SUStandardVersionComparator.default.compareVersion(candidate, toVersion: current) == .orderedDescending
  }

  private func isNewer(_ candidate: String, build: Int? = nil, than current: String) -> Bool {
    UpdateVersionPolicy.isNewer(
      candidate: candidate, candidateBuild: build, current: current, currentBuild: appBuild,
      legacyNewer: { [self] in isLegacyNewer($0, than: $1) })
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
    SettingsSearchScrollView {
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
        AboutOpenSourceCard()
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

enum ThirdPartyNotices {
  static let sourceURL = URL(string: "https://github.com/skyhua0224/moonlight-macos-enhanced")!

  static func openLicenses() {
    ThirdPartyLicensesWindow.show()
  }
}

private struct AboutOpenSourceCard: View {
  @ObservedObject private var languageManager = LanguageManager.shared

  var body: some View {
    FormSection(title: "Open Source") {
      SettingsRow(title: "License") {
        Text(verbatim: "GPL-3.0")
          .foregroundStyle(.secondary)
      }
      SettingsRow(title: "Source Code") {
        Link("GitHub", destination: ThirdPartyNotices.sourceURL)
      }
      SettingsRow(title: "Third-Party Licenses", detail: "Third-party licenses detail") {
        Button(languageManager.localize("Open")) {
          ThirdPartyNotices.openLicenses()
        }
        .controllerButtonStyle(.bordered)
        .controlSize(.small)
      }
    }
  }
}

private struct AboutHeroCard: View {
  let version: String
  @ObservedObject private var languageManager = LanguageManager.shared

  var body: some View {
    // settings-search: entry "Moonlight macOS Enhanced" detail="About hero subtitle" keywords="version"
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
    .settingsSearchEntry("Moonlight macOS Enhanced")
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
              .controllerButtonStyle(.borderedProminent)
              .disabled(!sparkle.canCheckUpdates)
            } else if let url = preferredDownloadURL(release) {
              Button(languageManager.localize("Download Update")) {
                openURL(url)
              }
              .controllerButtonStyle(.borderedProminent)
            }
          }
        }
        .padding(16)
      }

      Divider()
      // settings-search: entry "Check for Updates" detail="Update Sources detail"
      HStack {
        Text(languageManager.localize("Update Sources detail"))
          .font(.footnote).settingsLineCheck("SettingsAppPane:557")
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Spacer()
        Button(languageManager.localize("Check for Updates")) {
          installUpdate()
        }
        .controllerButtonStyle(.bordered)
        .controlSize(.small)
        .disabled(sparkle.isConfigured ? !sparkle.canCheckUpdates : checker.state == .checking)
      }
      .padding(16)
      .settingsSearchEntry("Check for Updates")
    }
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
  }
}
