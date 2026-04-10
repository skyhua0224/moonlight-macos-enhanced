//
//  SettingsView.swift
//  Moonlight for macOS
//
//  Created by Michael Kenny on 15/1/2024.
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

import AVFoundation
import AppKit
import Carbon.HIToolbox
import CoreGraphics
import SwiftUI

private let discoveryPreferencesChangedNotification = Notification.Name("MoonlightDiscoveryPreferencesChanged")

private enum AppAppearanceOption: Int, CaseIterable, Identifiable {
  case system = 0
  case light = 1
  case dark = 2

  var id: Int { rawValue }

  var titleKey: String {
    switch self {
    case .system:
      return "Match System"
    case .light:
      return "Light"
    case .dark:
      return "Dark"
    }
  }
}

// From: https://medium.com/@jakir/use-hex-color-in-swiftui-c19e6ab79220

struct AppView: View {
  @EnvironmentObject private var settingsModel: SettingsModel
  @ObservedObject var languageManager = LanguageManager.shared
  @ObservedObject private var awdlManager = AwdlHelperManager.sharedManager
  @AppStorage("theme") private var appAppearanceRawValue = AppAppearanceOption.system.rawValue
  @AppStorage("autoDiscoverNewHosts") private var autoDiscoverNewHosts = true
  @SwiftUI.State private var showLiveLogViewer = false
  @SwiftUI.State private var showAwdlHelperWarning = false
  @SwiftUI.State private var awdlEnableAfterWarning = true
  @SwiftUI.State private var showHostResetConfirm = false
  @SwiftUI.State private var showFullResetConfirm = false
  @SwiftUI.State private var showResetDone = false
  @SwiftUI.State private var resetDoneMessageKey = ""

  private var appAppearanceBinding: Binding<AppAppearanceOption> {
    Binding(
      get: {
        AppAppearanceOption(rawValue: appAppearanceRawValue) ?? .system
      },
      set: { newValue in
        appAppearanceRawValue = newValue.rawValue
        (NSApp.delegate as? AppDelegateForAppKit)?.applyThemePreference(newValue.rawValue)
      })
  }

  private var autoDiscoverNewHostsBinding: Binding<Bool> {
    Binding(
      get: {
        autoDiscoverNewHosts
      },
      set: { newValue in
        guard autoDiscoverNewHosts != newValue else { return }
        autoDiscoverNewHosts = newValue
        NotificationCenter.default.post(
          name: discoveryPreferencesChangedNotification, object: nil)
      })
  }

  private func debugLogFileURL(fileName: String) -> URL? {
    guard let libraryDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
    else {
      return nil
    }
    return libraryDir
      .appendingPathComponent("Logs", isDirectory: true)
      .appendingPathComponent("Moonlight", isDirectory: true)
      .appendingPathComponent(fileName, isDirectory: false)
  }

  private func rawDebugLogFileURL() -> URL? {
    debugLogFileURL(fileName: "moonlight-debug.log")
  }

  private func curatedDebugLogFileURL() -> URL? {
    debugLogFileURL(fileName: "moonlight-debug-curated.log")
  }

  @MainActor
  private func openDebugLogFolder() {
    guard let logURL = rawDebugLogFileURL() else { return }
    let dirURL = logURL.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
    NSWorkspace.shared.activateFileViewerSelecting([dirURL])
  }

  @MainActor
  private func viewDebugLog() {
    showLiveLogViewer = true
  }

  @MainActor
  private func exportRawDebugLog() {
    guard let logURL = rawDebugLogFileURL() else { return }
    let dirURL = logURL.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

    if !FileManager.default.fileExists(atPath: logURL.path) {
      try? "".write(to: logURL, atomically: true, encoding: .utf8)
    }

    let panel = NSSavePanel()
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = "moonlight-debug.log"
    if #available(macOS 11.0, *) {
      panel.allowedContentTypes = [.plainText]
    } else {
      panel.allowedFileTypes = ["log", "txt"]
    }

    let saveAction: (URL) -> Void = { destinationURL in
      do {
        if FileManager.default.fileExists(atPath: destinationURL.path) {
          try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: logURL, to: destinationURL)
      } catch {
        NSApp.presentError(error)
      }
    }

    let response = panel.runModal()
    if response == .OK, let destinationURL = panel.url {
      saveAction(destinationURL)
    }
  }

  @MainActor
  private func openDebugLogInExternalEditor() {
    let fileName = settingsModel.debugLogMode == "raw" ? "moonlight-debug.log" : "moonlight-debug-curated.log"
    guard let logURL = debugLogFileURL(fileName: fileName) else { return }
    let dirURL = logURL.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

    if !FileManager.default.fileExists(atPath: logURL.path) {
      try? "".write(to: logURL, atomically: true, encoding: .utf8)
    }

    NSWorkspace.shared.open(logURL)
  }

  private func clearPairingAndCacheFiles() {
    let fileManager = FileManager.default
    var targets: [URL] = []

    if let documentsDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
      targets.append(documentsDir.appendingPathComponent("client.crt", isDirectory: false))
      targets.append(documentsDir.appendingPathComponent("client.key", isDirectory: false))
      targets.append(documentsDir.appendingPathComponent("client.p12", isDirectory: false))
    }

    if let appSupportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
      let moonlightDir = appSupportDir.appendingPathComponent("Moonlight", isDirectory: true)
      targets.append(moonlightDir.appendingPathComponent("Moonlight_macOS.sqlite", isDirectory: false))
      targets.append(moonlightDir.appendingPathComponent("Moonlight_macOS.sqlite-shm", isDirectory: false))
      targets.append(moonlightDir.appendingPathComponent("Moonlight_macOS.sqlite-wal", isDirectory: false))
    }

    for fileURL in targets where fileManager.fileExists(atPath: fileURL.path) {
      try? fileManager.removeItem(at: fileURL)
    }
  }

  private func clearAllHosts() {
    let dataManager = DataManager()
    guard let hosts = dataManager.getHosts() as? [TemporaryHost] else { return }

    for host in hosts {
      dataManager.remove(host)
    }
  }

  @MainActor
  private func restartApplication() {
    let appURL = Bundle.main.bundleURL
    let configuration = NSWorkspace.OpenConfiguration()

    NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, _ in
      DispatchQueue.main.async {
        NSApp.terminate(nil)
      }
    }
  }

  private func requestAwdlAuthorization(enableOnSuccess: Bool) {
    awdlManager.requestAuthorization { granted in
      if enableOnSuccess {
        settingsModel.awdlStabilityHelperEnabled = granted
      }
    }
  }

  var body: some View {
    ScrollView {
      VStack {
        FormSection(title: "Behaviour") {
          FormCell(title: "Appearance", contentWidth: 170) {
            Picker("", selection: appAppearanceBinding) {
              ForEach(AppAppearanceOption.allCases) { option in
                Text(languageManager.localize(option.titleKey)).tag(option)
              }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .trailing)
          }

          Divider()

          ToggleCell(
            title: "Automatically Discover New Hosts",
            hintKey: "Automatically Discover New Hosts hint",
            boolBinding: autoDiscoverNewHostsBinding)

          Divider()

          ToggleCell(
            title: "Quit App After Stream",
            boolBinding: $settingsModel.quitAppAfterStream)

          Divider()

          DetailedToggleSettingRow(
            title: "Optimize Game Settings",
            descriptionKey: "Optimize Game Settings detail",
            boolBinding: $settingsModel.optimize
          )
        }

        Spacer()
          .frame(height: 32)

        FormSection(title: "Visuals") {
          ToggleCell(
            title: "Dim Non-Hovered Apps", boolBinding: $settingsModel.dimNonHoveredArtwork)

          Divider()

          FormCell(
            title: "Custom Artwork Dimensions", contentWidth: 0,
            content: {
              DimensionsInputView(
                widthBinding: $settingsModel.appArtworkWidth,
                heightBinding: $settingsModel.appArtworkHeight,
                placeholderDimensions: CGSize(width: 300, height: 400))
            })
        }

        Spacer()
          .frame(height: 32)

        FormSection(title: "Advanced") {
          AwdlNetworkCompatibilitySettingsSection(
            awdlManager: awdlManager,
            showWarning: $showAwdlHelperWarning,
            enableAfterWarning: $awdlEnableAfterWarning,
            requestAuthorization: { enableOnSuccess in
              requestAwdlAuthorization(enableOnSuccess: enableOnSuccess)
            })

          Divider()

          FormCell(title: "Debug Log", contentWidth: 0) {
            HStack(spacing: 8) {
              Button(languageManager.localize("View Log")) {
                Task { @MainActor in
                  viewDebugLog()
                }
              }
              Button(languageManager.localize("Open Folder")) {
                Task { @MainActor in
                  openDebugLogFolder()
                }
              }
              Button(languageManager.localize("Open in Editor")) {
                Task { @MainActor in
                  openDebugLogInExternalEditor()
                }
              }
              Button(languageManager.localize("Export Raw Log…")) {
                exportRawDebugLog()
              }
            }
          }

          Divider()

          FormCell(title: "Reset Hosts", contentWidth: 0) {
            Button(role: .destructive) {
              showHostResetConfirm = true
            } label: {
              Text(languageManager.localize("Reset Hosts (Recommended)"))
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
          }

          SettingDescriptionRow(textKey: "Reset Hosts detail")

          Divider()

          FormCell(title: "Full Reset", contentWidth: 0) {
            Button(role: .destructive) {
              showFullResetConfirm = true
            } label: {
              Text(languageManager.localize("Full Reset (Pairing + Cache)"))
            }
            .buttonStyle(.bordered)
            .tint(.red)
          }

          SettingDescriptionRow(textKey: "Full Reset detail")
        }
      }
      .padding()
    }
    .sheet(isPresented: $showLiveLogViewer) {
      DebugLogLiveView(rawLogURL: rawDebugLogFileURL(), curatedLogURL: curatedDebugLogFileURL())
        .environmentObject(settingsModel)
    }
    .alert(languageManager.localize("AWDL Helper Warning Title"), isPresented: $showAwdlHelperWarning) {
      Button(languageManager.localize("Cancel"), role: .cancel) {}
      Button(languageManager.localize("Enable"), role: .destructive) {
        settingsModel.awdlStabilityHelperAcknowledged = true
        requestAwdlAuthorization(enableOnSuccess: awdlEnableAfterWarning)
      }
    } message: {
      Text(languageManager.localize("AWDL Helper Warning Message"))
    }
    .alert(languageManager.localize("Dangerous Operation"), isPresented: $showHostResetConfirm) {
      Button(languageManager.localize("Cancel"), role: .cancel) {}
      Button(languageManager.localize("I Understand, Continue"), role: .destructive) {
        clearAllHosts()
        resetDoneMessageKey = "Hosts reset completed message"
        showResetDone = true
      }
    } message: {
      Text(languageManager.localize("Reset Hosts Confirm Message"))
    }
    .alert(languageManager.localize("Dangerous Operation"), isPresented: $showFullResetConfirm) {
      Button(languageManager.localize("Cancel"), role: .cancel) {}
      Button(languageManager.localize("I Understand, Continue"), role: .destructive) {
        clearAllHosts()
        clearPairingAndCacheFiles()
        resetDoneMessageKey = "Full reset completed message"
        showResetDone = true
      }
    } message: {
      Text(languageManager.localize("Full Reset Confirm Message"))
    }
    .alert(languageManager.localize("Reset Completed"), isPresented: $showResetDone) {
      Button(languageManager.localize("Restart App")) {
        restartApplication()
      }
    } message: {
      Text(languageManager.localize(resetDoneMessageKey))
    }
  }
}

private struct AwdlNetworkCompatibilitySettingsSection: View {
  @EnvironmentObject private var settingsModel: SettingsModel
  @ObservedObject var awdlManager: AwdlHelperManager
  @ObservedObject var languageManager = LanguageManager.shared
  @Binding var showWarning: Bool
  @Binding var enableAfterWarning: Bool
  let requestAuthorization: (Bool) -> Void

  private var helperBinding: Binding<Bool> {
    Binding(
      get: {
        settingsModel.awdlStabilityHelperEnabled
      },
      set: { newValue in
        guard newValue != settingsModel.awdlStabilityHelperEnabled else { return }

        if newValue {
          guard settingsModel.awdlStabilityHelperAcknowledged else {
            enableAfterWarning = true
            showWarning = true
            return
          }

          switch awdlManager.authorizationState {
          case .ready:
            settingsModel.awdlStabilityHelperEnabled = true
          case .notDetermined, .failed:
            requestAuthorization(true)
          case .unavailable:
            settingsModel.awdlStabilityHelperEnabled = false
          }
        } else {
          settingsModel.awdlStabilityHelperEnabled = false
        }
      })
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ToggleCell(
        title: "AWDL Stability Helper",
        boolBinding: helperBinding
      )

      SettingDescriptionRow(textKey: "Stream-Only AWDL Stability Helper detail")

      Divider()

      AwdlPermissionRow(
        awdlManager: awdlManager,
        requestAuthorization: {
          if settingsModel.awdlStabilityHelperAcknowledged {
            requestAuthorization(false)
          } else {
            enableAfterWarning = false
            showWarning = true
          }
        })

      if awdlManager.authorizationState == .failed,
         !awdlManager.lastErrorMessage.isEmpty
      {
        Text(
          String(
            format: languageManager.localize("AWDL Helper Last Error %@"),
            awdlManager.lastErrorMessage
          )
        )
          .font(.footnote)
          .foregroundColor(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .onAppear {
      awdlManager.refreshAuthorizationStatus()
    }
  }
}

private struct AwdlPermissionRow: View {
  @ObservedObject var awdlManager: AwdlHelperManager
  let requestAuthorization: () -> Void
  @ObservedObject var languageManager = LanguageManager.shared

  var body: some View {
    HStack {
      Text(languageManager.localize("AWDL Helper Privilege"))
      Spacer()

      if awdlManager.isRequestingAuthorization {
        ProgressView()
          .controlSize(.small)
      } else {
        switch awdlManager.authorizationState {
        case .ready:
          Label(languageManager.localize("AWDL Helper Ready"), systemImage: "checkmark.circle.fill")
            .foregroundColor(.green)
            .font(.callout)
        case .failed:
          HStack(spacing: 8) {
            Label(languageManager.localize("AWDL Helper Failed"), systemImage: "xmark.circle.fill")
              .foregroundColor(.red)
              .font(.callout)
            Button(languageManager.localize("Retry")) {
              requestAuthorization()
            }
            .controlSize(.small)
          }
        case .notDetermined:
          HStack(spacing: 8) {
            Text(languageManager.localize("Not Determined"))
              .foregroundColor(.secondary)
              .font(.callout)
            Button(languageManager.localize("Request")) {
              requestAuthorization()
            }
            .controlSize(.small)
          }
        case .unavailable:
          Text(languageManager.localize("Not Available"))
            .foregroundColor(.secondary)
            .font(.callout)
        @unknown default:
          Text(languageManager.localize("Not Determined"))
            .foregroundColor(.secondary)
            .font(.callout)
        }
      }
    }
  }
}

private enum DebugLogViewMode: String {
  case defaultLog
  case raw
}

private enum DebugLogTimeScope: String {
  case all
  case launch = "launch"
  case sinceClear = "since_clear"
}

private final class DebugLogLiveModel: ObservableObject {
  @Published var refreshToken = UUID()

  private let rawLogURL: URL
  private let curatedLogURL: URL
  private let maxRetainedLines = 3000
  private let initialTailBytes: UInt64 = 1_024 * 1_024
  private var rawText: String = ""
  private var curatedText: String = ""
  private var rawFileSize: UInt64 = 0
  private var curatedFileSize: UInt64 = 0
  private var rawEntries: [DebugLogEntry] = []
  private var defaultEntries: [DebugLogEntry] = []
  private var timer: Timer?

  init(rawLogURL: URL, curatedLogURL: URL) {
    self.rawLogURL = rawLogURL
    self.curatedLogURL = curatedLogURL
  }

  func start() {
    ensureLogFileExists(at: rawLogURL)
    ensureLogFileExists(at: curatedLogURL)
    reloadAll()

    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
      self?.pollForUpdates()
    }
    if let timer {
      RunLoop.main.add(timer, forMode: .common)
    }
  }

  func stop() {
    timer?.invalidate()
    timer = nil
  }

  func entries(
    mode: DebugLogViewMode,
    minimumLevel: DebugLogLevel,
    showSystemNoise: Bool
  ) -> [DebugLogEntry] {
    let baseEntries: [DebugLogEntry]
    switch mode {
    case .raw:
      baseEntries = rawEntries
    case .defaultLog:
      if showSystemNoise {
        baseEntries = rawEntries
      } else {
        baseEntries = defaultEntries
      }
    }

    guard minimumLevel != .all else {
      return baseEntries
    }

    return baseEntries.filter {
      DebugLogParser.matchesMinimumLevel($0.level, minimumLevel: minimumLevel)
    }
  }

  private func ensureLogFileExists(at url: URL) {
    let dirURL = url.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: url.path) {
      try? "".write(to: url, atomically: true, encoding: .utf8)
    }
  }

  private func reloadAll() {
    rawText = readTailText(from: rawLogURL, maxBytes: initialTailBytes)
    curatedText = readTailText(from: curatedLogURL, maxBytes: initialTailBytes)
    rawFileSize = fileSize(of: rawLogURL)
    curatedFileSize = fileSize(of: curatedLogURL)
    rebuildEntryCaches(rawChanged: true, curatedChanged: true)
    refreshToken = UUID()
  }

  private func pollForUpdates() {
    var changed = false
    var rawChanged = false
    var curatedChanged = false

    let latestRawSize = fileSize(of: rawLogURL)
    if latestRawSize < rawFileSize {
      rawText = readTailText(from: rawLogURL, maxBytes: initialTailBytes)
      rawFileSize = latestRawSize
      rawChanged = true
      changed = true
    } else if latestRawSize > rawFileSize {
      if let delta = readDeltaText(from: rawLogURL, startOffset: rawFileSize) {
        rawText = trimToLastLines(rawText + delta, maxLines: maxRetainedLines)
      }
      rawFileSize = latestRawSize
      rawChanged = true
      changed = true
    }

    let latestCuratedSize = fileSize(of: curatedLogURL)
    if latestCuratedSize < curatedFileSize {
      curatedText = readTailText(from: curatedLogURL, maxBytes: initialTailBytes)
      curatedFileSize = latestCuratedSize
      curatedChanged = true
      changed = true
    } else if latestCuratedSize > curatedFileSize {
      if let delta = readDeltaText(from: curatedLogURL, startOffset: curatedFileSize) {
        curatedText = trimToLastLines(curatedText + delta, maxLines: maxRetainedLines)
      }
      curatedFileSize = latestCuratedSize
      curatedChanged = true
      changed = true
    }

    if changed {
      rebuildEntryCaches(rawChanged: rawChanged, curatedChanged: curatedChanged)
      refreshToken = UUID()
    }
  }

  private func rebuildEntryCaches(rawChanged: Bool, curatedChanged: Bool) {
    if rawChanged {
      rawEntries = DebugLogParser.parseEntries(from: rawText)
    }

    let hasCuratedText = !curatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    if hasCuratedText {
      if curatedChanged {
        defaultEntries = DebugLogParser.parseEntries(from: curatedText)
      }
    } else if rawChanged || curatedChanged {
      defaultEntries = DebugLogParser.curatedEntries(
        fromRawText: rawText,
        minimumLevel: .all,
        showSystemNoise: false
      )
    }
  }

  private func fileSize(of url: URL) -> UInt64 {
    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
  }

  private func readTailText(from url: URL, maxBytes: UInt64) -> String {
    let size = fileSize(of: url)
    guard let file = try? FileHandle(forReadingFrom: url) else {
      return ""
    }
    defer { try? file.close() }

    do {
      if size > maxBytes {
        try file.seek(toOffset: size - maxBytes)
      } else {
        try file.seek(toOffset: 0)
      }
      let data = try file.readToEnd() ?? Data()
      return trimToLastLines(String(decoding: data, as: UTF8.self), maxLines: maxRetainedLines)
    } catch {
      return ""
    }
  }

  private func readDeltaText(from url: URL, startOffset: UInt64) -> String? {
    guard let file = try? FileHandle(forReadingFrom: url) else {
      return nil
    }
    defer { try? file.close() }

    do {
      try file.seek(toOffset: startOffset)
      let data = try file.readToEnd() ?? Data()
      guard !data.isEmpty else { return nil }
      return String(decoding: data, as: UTF8.self)
    } catch {
      return nil
    }
  }

  private func trimToLastLines(_ text: String, maxLines: Int) -> String {
    guard maxLines > 0 else { return text }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    guard lines.count > maxLines else { return text }
    return lines.suffix(maxLines).joined(separator: "\n")
  }
}

private struct DebugLogLevelBadge: View {
  let level: DebugLogLevel

  private var color: Color {
    switch level {
    case .debug:
      return .gray
    case .info:
      return .blue
    case .warn:
      return .orange
    case .error:
      return .red
    case .all, .unknown:
      return .secondary
    }
  }

  var body: some View {
    Text(level.displayText.uppercased())
      .font(.system(size: 10, weight: .bold, design: .monospaced))
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .foregroundColor(.white)
      .background(RoundedRectangle(cornerRadius: 4).fill(color))
  }
}

private struct DebugLogCategoryBadge: View {
  let category: MLLogCategoryDescriptor

  private var color: Color {
    switch category.domainKey {
    case "discovery":
      return .teal
    case "network":
      return .indigo
    case "pairing":
      return .purple
    case "stream":
      return .cyan
    case "input":
      return .green
    case "video":
      return .pink
    case "audio":
      return .mint
    case "ui":
      return .brown
    case "system":
      return .orange
    default:
      return .secondary
    }
  }

  var body: some View {
    Text(category.badgeText)
      .font(.system(size: 10, weight: .semibold, design: .rounded))
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .foregroundColor(color)
      .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.12)))
      .overlay(
        RoundedRectangle(cornerRadius: 4)
          .stroke(color.opacity(0.18), lineWidth: 1)
      )
  }
}

private struct DebugLogStatBadge: View {
  let label: String
  let value: Int
  let color: Color

  var body: some View {
    HStack(spacing: 4) {
      Circle()
        .fill(color)
        .frame(width: 7, height: 7)
      Text("\(label) \(value)")
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .foregroundColor(.secondary)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(
      RoundedRectangle(cornerRadius: 6)
        .fill(color.opacity(0.08))
    )
  }
}

private struct DebugLogRowView: View {
  let entry: DebugLogEntry
  let mode: DebugLogViewMode

  private var primaryText: String {
    switch mode {
    case .defaultLog:
      return entry.defaultTitle.isEmpty ? (entry.message.isEmpty ? entry.rawLine : entry.message) : entry.defaultTitle
    case .raw:
      return entry.rawLine
    }
  }

  private var secondaryText: String? {
    switch mode {
    case .defaultLog:
      guard let detail = entry.defaultDetail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty else {
        return nil
      }
      return detail == primaryText ? nil : detail
    case .raw:
      return nil
    }
  }

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Text(entry.timestampText ?? "--")
        .font(.system(size: 11, design: .monospaced))
        .foregroundColor(.secondary)
        .frame(width: 170, alignment: .leading)

      DebugLogLevelBadge(level: entry.level)
        .frame(width: 58, alignment: .leading)

      VStack(alignment: .leading, spacing: 2) {
        if entry.category.categoryKey != "other" {
          DebugLogCategoryBadge(category: entry.category)
        }

        Text(primaryText)
          .font(mode == .raw ? .system(size: 12, design: .monospaced) : .system(size: 12, weight: .medium))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)

        if let secondaryText {
          Text(secondaryText)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        if entry.count > 1 {
          Text("×\(entry.count)")
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundColor(.secondary)
        }
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(
      entry.isNoiseSummary ? Color.orange.opacity(0.07) : Color.clear
    )
    .cornerRadius(4)
  }
}

private struct DebugLogLiveView: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var settingsModel: SettingsModel
  @ObservedObject var languageManager = LanguageManager.shared
  @StateObject private var model: DebugLogLiveModel
  @SwiftUI.State private var searchText: String = ""
  @SwiftUI.State private var appliedSearchText: String = ""
  @SwiftUI.State private var selectedCategoryFilters: Set<String> = []
  @SwiftUI.State private var renderedEntries: [DebugLogEntry] = []
  @SwiftUI.State private var totalRows: Int = 0
  @SwiftUI.State private var detailEntry: DebugLogEntry?
  @SwiftUI.State private var clearFromDate: Date?
  @SwiftUI.State private var appLaunchDate: Date = NSRunningApplication.current.launchDate ?? Date()
  @SwiftUI.State private var pendingSearchRefresh: DispatchWorkItem?

  private static let domainOptions = MLLogCategoryClassifier.domainFilterOptions()
  private static let detailOptions = MLLogCategoryClassifier.filterOptions().filter {
    $0.categoryKey != $0.domainKey
  }

  init(rawLogURL: URL?, curatedLogURL: URL?) {
    let baseDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
      .appendingPathComponent("Logs", isDirectory: true)
      .appendingPathComponent("Moonlight", isDirectory: true)
      ?? URL(fileURLWithPath: NSTemporaryDirectory())
    let fallbackRaw = baseDir.appendingPathComponent("moonlight-debug.log")
    let fallbackCurated = baseDir.appendingPathComponent("moonlight-debug-curated.log")
    _model = SwiftUI.StateObject(
      wrappedValue: DebugLogLiveModel(
        rawLogURL: rawLogURL ?? fallbackRaw,
        curatedLogURL: curatedLogURL ?? fallbackCurated
      ))
  }

  private var currentMode: DebugLogViewMode {
    settingsModel.debugLogMode == "raw" ? .raw : .defaultLog
  }

  private var currentModeDisplayName: String {
    switch currentMode {
    case .defaultLog:
      return "默认日志 / Default Log"
    case .raw:
      return "原始日志 / Raw"
    }
  }

  private var currentMinimumLevel: DebugLogLevel {
    switch settingsModel.debugLogMinLevel {
    case "all": return .all
    case "debug": return .debug
    case "warn": return .warn
    case "error": return .error
    default: return .info
    }
  }

  private var currentTimeScope: DebugLogTimeScope {
    DebugLogTimeScope(rawValue: settingsModel.debugLogTimeScope) ?? .launch
  }

  private var effectiveStartDate: Date? {
    switch currentTimeScope {
    case .all:
      return nil
    case .launch:
      return appLaunchDate
    case .sinceClear:
      return clearFromDate ?? appLaunchDate
    }
  }

  private static let logTimestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return formatter
  }()

  private var selectedCategoryDescriptors: [MLLogCategoryDescriptor] {
    (Self.domainOptions + Self.detailOptions).filter { selectedCategoryFilters.contains($0.categoryKey) }
  }

  private func detailOptions(for domain: MLLogCategoryDescriptor) -> [MLLogCategoryDescriptor] {
    MLLogCategoryClassifier.detailFilterOptions(forDomainFilterKey: domain.domainKey)
  }

  private func toggleDomainFilter(_ domainKey: String) {
    let domainDetailKeys = Set(
      Self.detailOptions
        .filter { $0.domainKey == domainKey }
        .map(\.categoryKey)
    )

    if selectedCategoryFilters.contains(domainKey) {
      selectedCategoryFilters.remove(domainKey)
    } else {
      selectedCategoryFilters.subtract(domainDetailKeys)
      selectedCategoryFilters.insert(domainKey)
    }
    refreshRenderedEntries()
  }

  private var categoryMenuTitle: String {
    if selectedCategoryFilters.isEmpty {
      return "未筛选 / No Filter"
    }
    if selectedCategoryFilters.count == 1 {
      return selectedCategoryDescriptors.first?.displayName ?? "1 Selected"
    }
    return "已选 \(selectedCategoryFilters.count) 项 / \(selectedCategoryFilters.count) Selected"
  }

  private var selectedCategorySummary: String? {
    guard !selectedCategoryFilters.isEmpty else { return nil }
    let names = selectedCategoryDescriptors.map(\.badgeText)
    guard !names.isEmpty else { return nil }
    let preview = names.prefix(4).joined(separator: " · ")
    let suffix = names.count > 4 ? " +\(names.count - 4)" : ""
    return preview + suffix
  }

  private var visibleDebugCount: Int {
    renderedEntries.reduce(0) { $0 + ($1.level == .debug ? max(1, $1.count) : 0) }
  }

  private var visibleInfoCount: Int {
    renderedEntries.reduce(0) { $0 + ($1.level == .info ? max(1, $1.count) : 0) }
  }

  private var visibleWarnCount: Int {
    renderedEntries.reduce(0) { $0 + ($1.level == .warn ? max(1, $1.count) : 0) }
  }

  private var visibleErrorCount: Int {
    renderedEntries.reduce(0) { $0 + ($1.level == .error ? max(1, $1.count) : 0) }
  }

  private func filterEntriesByTimeScope(_ entries: [DebugLogEntry]) -> [DebugLogEntry] {
    guard let startDate = effectiveStartDate else {
      return entries
    }
    return entries.filter { entry in
      if let ts = entry.timestamp {
        return ts >= startDate
      }
      if let text = entry.timestampText, let parsed = Self.logTimestampFormatter.date(from: text) {
        return parsed >= startDate
      }
      return false
    }
  }

  private func refreshRenderedEntries() {
    let base = model.entries(
      mode: currentMode,
      minimumLevel: currentMinimumLevel,
      showSystemNoise: settingsModel.debugLogShowSystemNoise
    )
    let scopedBase = filterEntriesByTimeScope(base)
    let foldedBase = DebugLogParser.foldConsecutiveDuplicates(scopedBase)
    totalRows = foldedBase.count

    let keyword = appliedSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    renderedEntries = foldedBase.filter { entry in
      return entry.matchesKeyword(keyword)
        && matchesSelectedCategoryFilters(entry)
    }
  }

  private func matchesSelectedCategoryFilters(_ entry: DebugLogEntry) -> Bool {
    selectedCategoryFilters.isEmpty || selectedCategoryFilters.contains { entry.matchesCategoryFilter($0) }
  }

  private func toggleCategoryFilter(_ filterKey: String) {
    let descriptor = MLLogCategoryClassifier.descriptor(forCategoryKey: filterKey)
    if selectedCategoryFilters.contains(filterKey) {
      selectedCategoryFilters.remove(filterKey)
    } else {
      if descriptor.categoryKey != descriptor.domainKey {
        selectedCategoryFilters.remove(descriptor.domainKey)
      }
      selectedCategoryFilters.insert(filterKey)
    }
    refreshRenderedEntries()
  }

  private func clearCategoryFilters() {
    guard !selectedCategoryFilters.isEmpty else { return }
    selectedCategoryFilters.removeAll()
    refreshRenderedEntries()
  }

  private func categoryFilterExportSummary() -> String {
    let selected = selectedCategoryDescriptors.map(\.displayName)
    return selected.isEmpty ? "未筛选（显示全部） / No Filter (Showing All)" : selected.joined(separator: " | ")
  }

  private func scheduleSearchRefresh() {
    pendingSearchRefresh?.cancel()

    let normalized = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    let appliedNormalized = appliedSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    if normalized == appliedNormalized {
      return
    }

    if normalized.isEmpty {
      appliedSearchText = ""
      refreshRenderedEntries()
      return
    }

    let workItem = DispatchWorkItem {
      appliedSearchText = searchText
      refreshRenderedEntries()
    }
    pendingSearchRefresh = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: workItem)
  }

  private func copyFilteredEntries() {
    let text = renderedEntries.map(\.rawLine).joined(separator: "\n")
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  private func exportFilteredEntries() {
    let snapshotEntries = renderedEntries
    let snapshotMode = settingsModel.debugLogMode
    let snapshotMinLevel = settingsModel.debugLogMinLevel
    let snapshotShowNoise = settingsModel.debugLogShowSystemNoise
    let snapshotSearch = searchText
    let snapshotCategories = categoryFilterExportSummary()
    let snapshotTotalRows = totalRows
    let snapshotTimeScope = settingsModel.debugLogTimeScope
    let snapshotStartDate = effectiveStartDate

    let panel = NSSavePanel()
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = "moonlight-debug-filtered.log"
    if #available(macOS 11.0, *) {
      panel.allowedContentTypes = [.plainText]
    } else {
      panel.allowedFileTypes = ["log", "txt"]
    }

    let header = """
      # Moonlight Filtered Log
      # Generated: \(ISO8601DateFormatter().string(from: Date()))
      # Log Mode: \(snapshotMode == "raw" ? "raw" : "default")
      # Min Level: \(snapshotMinLevel)
      # Show System Noise: \(snapshotShowNoise)
      # Search: \(snapshotSearch.isEmpty ? "(empty)" : snapshotSearch)
      # Categories: \(snapshotCategories)
      # Time Scope: \(snapshotTimeScope)
      # Start At: \(snapshotStartDate.map { ISO8601DateFormatter().string(from: $0) } ?? "(none)")
      # Filtered Rows: \(snapshotEntries.count)
      # Total Rows: \(snapshotTotalRows)

      """
    let body = snapshotEntries.map(\.rawLine).joined(separator: "\n")
    let content = header + body + "\n"

    let saveAction: (URL) -> Void = { destinationURL in
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          try content.write(to: destinationURL, atomically: true, encoding: .utf8)
        } catch {
          DispatchQueue.main.async {
            NSApp.presentError(error)
          }
        }
      }
    }

    if let window = NSApp.keyWindow ?? NSApp.mainWindow {
      panel.beginSheetModal(for: window) { response in
        if response == .OK, let destinationURL = panel.url {
          saveAction(destinationURL)
        }
      }
    } else if panel.runModal() == .OK, let destinationURL = panel.url {
      saveAction(destinationURL)
    }
  }

  var body: some View {
    VStack(spacing: 12) {
      HStack {
        Text(languageManager.localize("Live Debug Log"))
          .font(.headline)
        Spacer()
        Button(languageManager.localize("Export Filtered Log…")) {
          exportFilteredEntries()
        }
        Button(languageManager.localize("Copy All")) {
          copyFilteredEntries()
        }
        Button(languageManager.localize("Close")) {
          dismiss()
        }
      }

      HStack(spacing: 8) {
        Text(languageManager.localize("Log Mode"))
          .font(.caption)
          .foregroundColor(.secondary)
        Picker("", selection: $settingsModel.debugLogMode) {
          Text("默认日志 / Default").tag("default")
          Text("原始日志 / Raw").tag("raw")
        }
        .pickerStyle(.segmented)
        .frame(width: 260)

        Picker("", selection: $settingsModel.debugLogMinLevel) {
          Text("All").tag("all")
          Text("Debug").tag("debug")
          Text("Info").tag("info")
          Text("Warn").tag("warn")
          Text("Error").tag("error")
        }
        .frame(width: 140)

        Toggle(languageManager.localize("Show System Noise"), isOn: $settingsModel.debugLogShowSystemNoise)
          .toggleStyle(.checkbox)
          .frame(width: 180, alignment: .leading)
          .disabled(currentMode == .raw)

        Toggle(languageManager.localize("Input Diagnostics"), isOn: $settingsModel.debugLogInputDiagnostics)
          .toggleStyle(.checkbox)
          .frame(width: 180, alignment: .leading)

        Toggle(languageManager.localize("Auto Scroll"), isOn: $settingsModel.debugLogAutoScroll)
          .toggleStyle(.checkbox)
          .frame(width: 130, alignment: .leading)
      }

      HStack(spacing: 8) {
        Text(languageManager.localize("Log Range"))
          .font(.caption)
          .foregroundColor(.secondary)
        Picker("", selection: $settingsModel.debugLogTimeScope) {
          Text(languageManager.localize("All History")).tag("all")
          Text(languageManager.localize("This Launch")).tag("launch")
          Text(languageManager.localize("Since Clear")).tag("since_clear")
        }
        .pickerStyle(.segmented)
        .frame(width: 280)

        Button(languageManager.localize("Clear From Now")) {
          clearFromDate = Date()
          settingsModel.debugLogTimeScope = DebugLogTimeScope.sinceClear.rawValue
          refreshRenderedEntries()
        }

        if let startDate = effectiveStartDate, currentTimeScope != .all {
          Text("\(languageManager.localize("Since")): \(Self.logTimestampFormatter.string(from: startDate))")
            .font(.caption)
            .foregroundColor(.secondary)
        }

        Spacer()
      }

      HStack(spacing: 8) {
        TextField("搜索关键词 / 主机 / 错误码 / 分类", text: $searchText)
          .textFieldStyle(.roundedBorder)

        DebugLogCategoryFilterMenuButton(
          title: categoryMenuTitle,
          domainOptions: Self.domainOptions,
          selectedFilters: selectedCategoryFilters,
          detailProvider: detailOptions(for:),
          onToggleDomain: toggleDomainFilter(_:),
          onToggleCategory: toggleCategoryFilter(_:),
          onClear: clearCategoryFilters
        )
        .frame(width: 260, height: 28)

        Text("\(languageManager.localize("Filtered Rows")): \(renderedEntries.count)")
          .font(.caption)
          .foregroundColor(.secondary)
        Text("\(languageManager.localize("Total Rows")): \(totalRows)")
          .font(.caption)
          .foregroundColor(.secondary)
      }

      HStack(spacing: 8) {
        Text(currentModeDisplayName)
          .font(.system(size: 11, weight: .semibold, design: .rounded))
          .foregroundColor(.secondary)
          .padding(.horizontal, 10)
          .padding(.vertical, 4)
          .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))

        if let selectedCategorySummary {
          Text(selectedCategorySummary)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundColor(.secondary)
            .lineLimit(1)
        }

        DebugLogStatBadge(label: "Debug", value: visibleDebugCount, color: .gray)
        DebugLogStatBadge(label: "Info", value: visibleInfoCount, color: .blue)
        DebugLogStatBadge(label: "Warn", value: visibleWarnCount, color: .orange)
        DebugLogStatBadge(label: "Error", value: visibleErrorCount, color: .red)
        Spacer()
      }

      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 2) {
            if renderedEntries.isEmpty {
              Text(languageManager.localize("(No logs yet)"))
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 16)
            } else {
              ForEach(renderedEntries) { entry in
                DebugLogRowView(entry: entry, mode: currentMode)
                  .id(entry.id)
                  .contentShape(Rectangle())
                  .onTapGesture(count: 2) {
                    detailEntry = entry
                  }
              }
            }
            Color.clear
              .frame(height: 1)
              .id("log-end")
          }
          .padding(.vertical, 4)
        }
        .background(Color(NSColor.textBackgroundColor))
        .overlay(
          RoundedRectangle(cornerRadius: 6)
            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
        .onChange(of: renderedEntries.count) { _ in
          guard settingsModel.debugLogAutoScroll else { return }
          withAnimation(.easeOut(duration: 0.12)) {
            proxy.scrollTo("log-end", anchor: .bottom)
          }
        }
      }
    }
    .padding(16)
    .frame(minWidth: 980, minHeight: 560)
    .onAppear {
      appLaunchDate = NSRunningApplication.current.launchDate ?? Date()
      appliedSearchText = searchText
      model.start()
      refreshRenderedEntries()
    }
    .onDisappear {
      pendingSearchRefresh?.cancel()
      model.stop()
    }
    .onReceive(model.$refreshToken) { _ in
      refreshRenderedEntries()
    }
    .onChange(of: settingsModel.debugLogMode) { _ in
      refreshRenderedEntries()
    }
    .onChange(of: settingsModel.debugLogShowSystemNoise) { _ in
      refreshRenderedEntries()
    }
    .onChange(of: searchText) { _ in
      scheduleSearchRefresh()
    }
    .onChange(of: settingsModel.debugLogMinLevel) { _ in
      refreshRenderedEntries()
    }
    .onChange(of: settingsModel.debugLogTimeScope) { _ in
      if currentTimeScope == .sinceClear && clearFromDate == nil {
        clearFromDate = Date()
      }
      refreshRenderedEntries()
    }
    .sheet(item: $detailEntry) { entry in
      DebugLogEntryDetailView(entry: entry)
    }
  }
}

private struct DebugLogCategoryFilterMenuButton: NSViewRepresentable {
  let title: String
  let domainOptions: [MLLogCategoryDescriptor]
  let selectedFilters: Set<String>
  let detailProvider: (MLLogCategoryDescriptor) -> [MLLogCategoryDescriptor]
  let onToggleDomain: (String) -> Void
  let onToggleCategory: (String) -> Void
  let onClear: () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(parent: self)
  }

  func makeNSView(context: Context) -> NSButton {
    let button = NSButton(title: title, target: context.coordinator, action: #selector(Coordinator.presentMenu(_:)))
    button.bezelStyle = .rounded
    button.imagePosition = .imageLeading
    button.controlSize = .small
    button.font = .systemFont(ofSize: 12, weight: .regular)
    button.lineBreakMode = .byTruncatingTail
    if #available(macOS 11.0, *) {
      button.image = NSImage(
        systemSymbolName: "line.3.horizontal.decrease.circle",
        accessibilityDescription: "Category Filter"
      )
    }
    return button
  }

  func updateNSView(_ nsView: NSButton, context: Context) {
    context.coordinator.parent = self
    nsView.title = title
    nsView.menu = context.coordinator.buildMenu()
  }

  final class Coordinator: NSObject {
    var parent: DebugLogCategoryFilterMenuButton

    init(parent: DebugLogCategoryFilterMenuButton) {
      self.parent = parent
    }

    @objc func presentMenu(_ sender: NSButton) {
      let menu = buildMenu()
      sender.menu = menu
      menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    func buildMenu() -> NSMenu {
      let menu = NSMenu(title: "LogCategoryFilter")

      let statusItem = NSMenuItem(
        title: parent.selectedFilters.isEmpty
          ? "当前未筛选（显示全部） / No Filter Applied"
          : "清空分类筛选 / Clear Category Filters",
        action: parent.selectedFilters.isEmpty ? nil : #selector(handleClearAction(_:)),
        keyEquivalent: ""
      )
      statusItem.target = self
      statusItem.isEnabled = !parent.selectedFilters.isEmpty
      menu.addItem(statusItem)
      menu.addItem(.separator())

      for domain in parent.domainOptions {
        let item = NSMenuItem(title: domain.displayName, action: nil, keyEquivalent: "")
        item.image = systemImage(named: domain.systemImageName)

        let submenu = NSMenu(title: domain.displayName)
        let allItem = NSMenuItem(title: "全部 / All", action: #selector(handleDomainAction(_:)), keyEquivalent: "")
        allItem.target = self
        allItem.representedObject = domain.categoryKey
        allItem.state = parent.selectedFilters.contains(domain.categoryKey) ? .on : .off
        allItem.image = systemImage(named: domain.systemImageName)
        submenu.addItem(allItem)

        let details = parent.detailProvider(domain)
        if !details.isEmpty {
          submenu.addItem(.separator())
        }

        for detail in details {
          let detailItem = NSMenuItem(title: detail.displayName, action: #selector(handleCategoryAction(_:)), keyEquivalent: "")
          detailItem.target = self
          detailItem.representedObject = detail.categoryKey
          detailItem.state = parent.selectedFilters.contains(detail.categoryKey) ? .on : .off
          detailItem.image = systemImage(named: detail.systemImageName)
          submenu.addItem(detailItem)
        }

        item.submenu = submenu
        menu.addItem(item)
      }

      return menu
    }

    private func systemImage(named name: String) -> NSImage? {
      if #available(macOS 11.0, *) {
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)
      }
      return nil
    }

    @objc private func handleClearAction(_ sender: NSMenuItem) {
      parent.onClear()
    }

    @objc private func handleDomainAction(_ sender: NSMenuItem) {
      guard let key = sender.representedObject as? String else { return }
      parent.onToggleDomain(key)
    }

    @objc private func handleCategoryAction(_ sender: NSMenuItem) {
      guard let key = sender.representedObject as? String else { return }
      parent.onToggleCategory(key)
    }
  }
}

private struct DebugLogEntryDetailView: View {
  let entry: DebugLogEntry
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 12) {
      HStack {
        Text("日志详情 / Log Detail")
          .font(.headline)
        Spacer()
        Button("关闭 / Close") {
          dismiss()
        }
      }

      HStack(spacing: 8) {
        DebugLogLevelBadge(level: entry.level)
        if entry.category.categoryKey != "other" {
          DebugLogCategoryBadge(category: entry.category)
        }
        Text(entry.timestampText ?? "--")
          .font(.system(size: 12, design: .monospaced))
          .foregroundColor(.secondary)
        if entry.count > 1 {
          Text("×\(entry.count)")
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundColor(.secondary)
        }
        Spacer()
      }

      VStack(alignment: .leading, spacing: 6) {
        Text("默认视图 / Default View")
          .font(.caption)
          .foregroundColor(.secondary)
        Text(entry.defaultTitle)
          .font(.system(size: 13, weight: .medium))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
        if let detail = entry.defaultDetail, !detail.isEmpty {
          Text(detail)
            .font(.system(size: 12, design: .monospaced))
            .foregroundColor(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }

      Divider()

      VStack(alignment: .leading, spacing: 6) {
        Text("解析消息 / Parsed Message")
          .font(.caption)
          .foregroundColor(.secondary)
        Text(entry.message.isEmpty ? entry.rawLine : entry.message)
          .font(.system(size: 12, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      Divider()

      VStack(alignment: .leading, spacing: 6) {
        Text("原始行 / Raw Line")
          .font(.caption)
          .foregroundColor(.secondary)
        ScrollView {
          Text(entry.rawLine)
            .font(.system(size: 12, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      Spacer()
    }
    .padding(16)
    .frame(minWidth: 760, minHeight: 360)
  }
}

struct LegacyView: View {
  var body: some View {
    EmptyView()
  }
}
