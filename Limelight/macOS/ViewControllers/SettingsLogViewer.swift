// Restored from this project's v1.3.8 diagnostics (existing GPL application code).
import AppKit
import SwiftUI
import UniformTypeIdentifiers

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

struct SettingsLogViewer: View {
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
      return languageManager.localize("Curated Log")
    case .raw:
      return languageManager.localize("Raw Log")
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
      return languageManager.localize("No Filter")
    }
    if selectedCategoryFilters.count == 1 {
      return selectedCategoryDescriptors.first?.displayName
        ?? String(format: languageManager.localize("%d Selected"), 1)
    }
    return String(format: languageManager.localize("%d Selected"), selectedCategoryFilters.count)
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
    return selected.isEmpty ? languageManager.localize("No Filter (Showing All)") : selected.joined(separator: " | ")
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
          Text(languageManager.localize("Curated Log")).tag("default")
          Text(languageManager.localize("Raw Log")).tag("raw")
        }
        .pickerStyle(.segmented)
        .frame(width: 260)

        Picker("", selection: $settingsModel.debugLogMinLevel) {
          Text(languageManager.localize("All")).tag("all")
          Text(languageManager.localize("Debug")).tag("debug")
          Text(languageManager.localize("Info")).tag("info")
          Text(languageManager.localize("Warn")).tag("warn")
          Text(languageManager.localize("Error")).tag("error")
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
        TextField(languageManager.localize("Search terms / host / error code / category"), text: $searchText)
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

        DebugLogStatBadge(label: languageManager.localize("Debug"), value: visibleDebugCount, color: .gray)
        DebugLogStatBadge(label: languageManager.localize("Info"), value: visibleInfoCount, color: .blue)
        DebugLogStatBadge(label: languageManager.localize("Warn"), value: visibleWarnCount, color: .orange)
        DebugLogStatBadge(label: languageManager.localize("Error"), value: visibleErrorCount, color: .red)
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


private struct DebugLogCategoryFilterMenuButton: View {
  @ObservedObject private var languageManager = LanguageManager.shared
  let title: String
  let domainOptions: [MLLogCategoryDescriptor]
  let selectedFilters: Set<String>
  let detailProvider: (MLLogCategoryDescriptor) -> [MLLogCategoryDescriptor]
  let onToggleDomain: (String) -> Void
  let onToggleCategory: (String) -> Void
  let onClear: () -> Void
  var body: some View {
    Menu {
      Button(languageManager.localize("Clear Category Filters"), action: onClear).disabled(selectedFilters.isEmpty)
      ForEach(domainOptions, id: \.categoryKey) { domain in
        Menu(domain.displayName) {
          Toggle(languageManager.localize("All"), isOn: Binding(get: { selectedFilters.contains(domain.categoryKey) }, set: { _ in onToggleDomain(domain.categoryKey) }))
          ForEach(detailProvider(domain), id: \.categoryKey) { detail in
            Toggle(detail.displayName, isOn: Binding(get: { selectedFilters.contains(detail.categoryKey) }, set: { _ in onToggleCategory(detail.categoryKey) }))
          }
        }
      }
    } label: { Label(title, systemImage: "line.3.horizontal.decrease.circle") }
  }
}
private struct DebugLogEntryDetailView: View {
  let entry: DebugLogEntry
  @ObservedObject private var languageManager = LanguageManager.shared
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 12) {
      HStack {
        Text(languageManager.localize("Log Detail"))
          .font(.headline)
        Spacer()
        Button(languageManager.localize("Close")) {
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
        Text(languageManager.localize("Curated View"))
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
        Text(languageManager.localize("Parsed Message"))
          .font(.caption)
          .foregroundColor(.secondary)
        Text(entry.message.isEmpty ? entry.rawLine : entry.message)
          .font(.system(size: 12, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      Divider()

      VStack(alignment: .leading, spacing: 6) {
        Text(languageManager.localize("Raw Line"))
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
