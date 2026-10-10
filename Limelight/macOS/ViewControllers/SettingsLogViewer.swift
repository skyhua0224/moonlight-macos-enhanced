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

/// What the viewer currently wants to see. Built on the main thread and applied
/// on the model's own queue, so filtering never runs on the UI thread.
private struct DebugLogQuery: Equatable {
  var mode: DebugLogViewMode = .defaultLog
  var minimumLevel: DebugLogLevel = .info
  var showSystemNoise: Bool = false
  var startDate: Date?
  /// Also show what the log files hold from before this launch's in-memory log ("All History").
  var includeHistory: Bool = false
  var keyword: String = ""
  var categoryFilters: Set<String> = []
}

/// One immutable, already filtered and folded view of the log.
private struct DebugLogSnapshot {
  var revision: Int = 0
  var rows: [DebugLogEntry] = []
  var totalRows: Int = 0
  var debugCount: Int = 0
  var infoCount: Int = 0
  var warnCount: Int = 0
  var errorCount: Int = 0
}

/// Reads the end of one log file once and parses each line exactly once. It only serves the
/// "All History" scope (lines older than the logger's in-memory log); the live view never
/// reads files. Not thread-safe; the owner confines it to one queue.
private final class DebugLogFileTail {
  private let url: URL
  private let idPrefix: String
  private let maxLines: Int
  private let tailBytes: UInt64

  private(set) var entries: [DebugLogEntry] = []

  init(url: URL, idPrefix: String, maxLines: Int, tailBytes: UInt64) {
    self.url = url
    self.idPrefix = idPrefix
    self.maxLines = maxLines
    self.tailBytes = tailBytes
  }

  /// Drops everything and reads the last `tailBytes` of the file.
  func reload() {
    entries = []
    let size = currentSize()
    let start = size > tailBytes ? size - tailBytes : 0
    guard let data = readData(from: start, upTo: size) else { return }
    ingest(data, dropLeadingPartialLine: start > 0)
  }

  private func ingest(_ data: Data, dropLeadingPartialLine: Bool) {
    var data = data
    if dropLeadingPartialLine {
      // Reading started in the middle of the file, so the first line may be cut off.
      guard let firstNewline = data.firstIndex(of: 0x0A) else { return }
      data = Data(data[data.index(after: firstNewline)...])
    }

    let text = String(decoding: data, as: UTF8.self)
    var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    guard !lines.isEmpty else { return }
    if lines.count > maxLines {
      // Only the newest lines are kept, so there is no point parsing the rest.
      lines = Array(lines.suffix(maxLines))
    }
    entries = DebugLogParser.parseLines(lines, idPrefix: idPrefix, startSequence: 0)
  }

  private func currentSize() -> UInt64 {
    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
  }

  private func readData(from start: UInt64, upTo end: UInt64) -> Data? {
    guard end > start, let file = try? FileHandle(forReadingFrom: url) else {
      return nil
    }
    defer { try? file.close() }

    do {
      try file.seek(toOffset: start)
      return try file.read(upToCount: Int(end - start)) ?? Data()
    } catch {
      return nil
    }
  }
}

/// Follows the logger's structured entries and publishes filtered snapshots.
///
/// The live data is the logger's in-memory log (`LogBuffer`): the model subscribes to its
/// coalesced change signal and, on each signal, pulls the entries with a higher sequence
/// number on its own queue. Nothing is parsed back from text and no file is read, except
/// for the "All History" scope, which adds the older part of the log files once.
/// Filtering, folding and counting happen on `queue`; results reach the main thread as a
/// single latest-wins snapshot.
private final class DebugLogLiveModel: ObservableObject {
  /// Main thread only.
  @Published private(set) var snapshot = DebugLogSnapshot()

  private static let maxRetainedLines = 5000
  private static let trimSlack = 500
  private static let historyTailBytes: UInt64 = 1_024 * 1_024
  private static let historyMaxLines = 3000

  private let queue = DispatchQueue(label: "com.moonlight.logviewer.model", qos: .utility)

  // Everything in this block is read and written on `queue` only.
  private let rawHistoryTail: DebugLogFileTail
  private let curatedHistoryTail: DebugLogFileTail
  private var query = DebugLogQuery()
  private var isPaused = false
  private var revision = 0
  private var subscription: NSObjectProtocol?
  private var lastSequence: UInt = 0
  private var rawEntries: [DebugLogEntry] = []
  private var curatedEntries: [DebugLogEntry] = []
  private var historyLoaded = false
  private var rawHistory: [DebugLogEntry] = []
  private var curatedHistory: [DebugLogEntry] = []

  // Hand-off to the main thread; every access holds `deliveryLock`.
  private let deliveryLock = NSLock()
  private var undeliveredSnapshot: DebugLogSnapshot?
  private var deliveryScheduled = false

  init(rawLogURL: URL, curatedLogURL: URL) {
    rawHistoryTail = DebugLogFileTail(
      url: rawLogURL, idPrefix: "hr", maxLines: DebugLogLiveModel.historyMaxLines,
      tailBytes: DebugLogLiveModel.historyTailBytes)
    curatedHistoryTail = DebugLogFileTail(
      url: curatedLogURL, idPrefix: "hc", maxLines: DebugLogLiveModel.historyMaxLines,
      tailBytes: DebugLogLiveModel.historyTailBytes)
  }

  deinit {
    if let subscription = subscription {
      LogBuffer.shared().removeChangeObserver(subscription)
    }
  }

  func start(query initialQuery: DebugLogQuery) {
    queue.async { [weak self] in
      guard let self = self else { return }
      self.query = initialQuery
      self.subscribeToLogChanges()
      self.rawEntries = []
      self.curatedEntries = []
      self.lastSequence = 0
      self.ingest(LogBuffer.shared().lastEntries(UInt(DebugLogLiveModel.maxRetainedLines)))
      self.loadHistoryIfNeeded()
      self.publishCurrentSnapshot()
    }
  }

  func stop() {
    queue.async { [weak self] in
      guard let self = self else { return }
      if let subscription = self.subscription {
        LogBuffer.shared().removeChangeObserver(subscription)
      }
      self.subscription = nil
    }
  }

  func updateQuery(_ newQuery: DebugLogQuery) {
    queue.async { [weak self] in
      guard let self = self, self.query != newQuery else { return }
      self.query = newQuery
      self.loadHistoryIfNeeded()
      self.publishCurrentSnapshot()
    }
  }

  /// While paused the log is still followed (so nothing is lost and memory stays bounded),
  /// but the visible snapshot only changes when the filters change.
  func setPaused(_ paused: Bool) {
    queue.async { [weak self] in
      guard let self = self, self.isPaused != paused else { return }
      self.isPaused = paused
      if !paused {
        self.publishCurrentSnapshot()
      }
    }
  }

  // MARK: Work on `queue`

  private func subscribeToLogChanges() {
    if let existing = subscription {
      LogBuffer.shared().removeChangeObserver(existing)
    }
    // Delivered on the main queue at most a few times per second; all the work happens on `queue`.
    subscription = LogBuffer.shared().addChangeObserver { [weak self] in
      self?.queue.async { [weak self] in
        self?.pullNewEntries()
      }
    }
  }

  private func pullNewEntries() {
    guard subscription != nil else { return }
    let fresh = LogBuffer.shared().entries(afterSequence: lastSequence, limit: 0)
    guard !fresh.isEmpty else { return }
    ingest(fresh)
    guard !isPaused else { return }
    publishCurrentSnapshot()
  }

  private func ingest(_ fresh: [MLLogEntry]) {
    guard let newest = fresh.last else { return }
    let converted = DebugLogParser.entries(from: fresh)
    for (source, entry) in zip(fresh, converted) {
      if source.inRaw {
        rawEntries.append(entry)
      }
      if source.inCurated {
        curatedEntries.append(entry)
      }
    }
    lastSequence = max(lastSequence, newest.sequence)

    let limit = DebugLogLiveModel.maxRetainedLines
    let slack = DebugLogLiveModel.trimSlack
    if rawEntries.count > limit + slack {
      rawEntries.removeFirst(rawEntries.count - limit)
    }
    if curatedEntries.count > limit + slack {
      curatedEntries.removeFirst(curatedEntries.count - limit)
    }
  }

  /// "All History" needs the part of the files that predates the in-memory log; it is read once.
  private func loadHistoryIfNeeded() {
    guard query.includeHistory, !historyLoaded else { return }
    historyLoaded = true
    rawHistoryTail.reload()
    curatedHistoryTail.reload()
    rawHistory = rawHistoryTail.entries
    if curatedHistoryTail.entries.isEmpty {
      // No curated file: derive the curated view from the raw lines already parsed.
      curatedHistory = DebugLogParser.curatedEntries(
        fromEntries: rawHistory, minimumLevel: .all, showSystemNoise: false)
    } else {
      curatedHistory = curatedHistoryTail.entries
    }
  }

  private func publishCurrentSnapshot() {
    revision += 1
    let built = DebugLogLiveModel.buildSnapshot(
      base: baseEntries(for: query), query: query, revision: revision)
    deliver(built)
  }

  private func baseEntries(for query: DebugLogQuery) -> [DebugLogEntry] {
    let useRaw: Bool
    switch query.mode {
    case .raw:
      useRaw = true
    case .defaultLog:
      useRaw = query.showSystemNoise
    }
    let memory = useRaw ? rawEntries : curatedEntries
    guard query.includeHistory else { return memory }

    // File lines at or after the oldest in-memory entry are already part of the live log.
    let history = useRaw ? rawHistory : curatedHistory
    guard let cutoff = memory.first?.timestampText else { return history }
    let older = history.filter { (entry: DebugLogEntry) -> Bool in
      (entry.timestampText ?? "") < cutoff
    }
    return older + memory
  }

  private static func buildSnapshot(
    base: [DebugLogEntry], query: DebugLogQuery, revision: Int
  ) -> DebugLogSnapshot {
    var scoped = base
    if query.minimumLevel != .all {
      scoped = scoped.filter { (entry: DebugLogEntry) -> Bool in
        DebugLogParser.matchesMinimumLevel(entry.level, minimumLevel: query.minimumLevel)
      }
    }
    if let startDate = query.startDate {
      scoped = scoped.filter { (entry: DebugLogEntry) -> Bool in
        guard let timestamp = entry.timestamp else { return false }
        return timestamp >= startDate
      }
    }

    let folded = DebugLogParser.foldConsecutiveDuplicates(scoped)

    var rows = folded
    if !query.keyword.isEmpty || !query.categoryFilters.isEmpty {
      rows = folded.filter { (entry: DebugLogEntry) -> Bool in
        guard entry.matchesKeyword(query.keyword) else { return false }
        if query.categoryFilters.isEmpty { return true }
        return query.categoryFilters.contains { entry.matchesCategoryFilter($0) }
      }
    }

    var result = DebugLogSnapshot()
    result.revision = revision
    result.totalRows = folded.count
    for entry in rows {
      let weight = max(1, entry.count)
      switch entry.level {
      case .debug: result.debugCount += weight
      case .info: result.infoCount += weight
      case .warn: result.warnCount += weight
      case .error: result.errorCount += weight
      case .all, .unknown: break
      }
    }
    result.rows = rows
    return result
  }

  private func deliver(_ built: DebugLogSnapshot) {
    deliveryLock.lock()
    undeliveredSnapshot = built
    let needsSchedule = !deliveryScheduled
    deliveryScheduled = true
    deliveryLock.unlock()

    guard needsSchedule else { return }
    DispatchQueue.main.async { [weak self] in
      self?.applyUndeliveredSnapshot()
    }
  }

  // MARK: Main thread

  private func applyUndeliveredSnapshot() {
    deliveryLock.lock()
    let pending = undeliveredSnapshot
    undeliveredSnapshot = nil
    deliveryScheduled = false
    deliveryLock.unlock()

    if let pending = pending {
      snapshot = pending
    }
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

private struct DebugLogRowView: View, Equatable {
  let entry: DebugLogEntry
  let mode: DebugLogViewMode

  // Entries are immutable once parsed; only the folded repeat count can change.
  // Comparing just that lets SwiftUI skip rebuilding rows that did not change.
  static func == (lhs: DebugLogRowView, rhs: DebugLogRowView) -> Bool {
    lhs.entry.id == rhs.entry.id && lhs.entry.count == rhs.entry.count && lhs.mode == rhs.mode
  }

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
          .frame(maxWidth: .infinity, alignment: .leading)

        if let secondaryText {
          Text(secondaryText)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(.secondary)
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

private struct DebugLogContentFramePreferenceKey: PreferenceKey {
  static let defaultValue: CGRect = .zero
  static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
    value = nextValue()
  }
}

private struct DebugLogViewportHeightPreferenceKey: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = nextValue()
  }
}

/// Scroll bookkeeping that must not trigger view updates by itself; main thread only.
private final class DebugLogScrollTracker {
  var lastContentHeight: CGFloat = -1
  var contentMaxY: CGFloat = 0
  var viewportHeight: CGFloat = 0
  var isAtBottom = true
  var didInitialScroll = false
}

struct SettingsLogViewer: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var settingsModel: SettingsModel
  @ObservedObject var languageManager = LanguageManager.shared
  @StateObject private var model: DebugLogLiveModel
  @SwiftUI.State private var searchText: String = ""
  @SwiftUI.State private var appliedSearchText: String = ""
  @SwiftUI.State private var selectedCategoryFilters: Set<String> = []
  @SwiftUI.State private var detailEntry: DebugLogEntry?
  @SwiftUI.State private var clearFromDate: Date?
  @SwiftUI.State private var appLaunchDate: Date = NSRunningApplication.current.launchDate ?? Date()
  @SwiftUI.State private var pendingSearchRefresh: DispatchWorkItem?
  @SwiftUI.State private var isPaused: Bool = false
  @SwiftUI.State private var showsJumpToLatest: Bool = false
  @SwiftUI.State private var scrollTracker = DebugLogScrollTracker()

  private static let domainOptions = MLLogCategoryClassifier.domainFilterOptions()
  private static let detailOptions = MLLogCategoryClassifier.filterOptions().filter {
    $0.categoryKey != $0.domainKey
  }
  private static let endAnchorID = "log-end"
  private static let scrollSpaceName = "log-scroll-space"
  private static let bottomTolerance: CGFloat = 24

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

  private var snapshot: DebugLogSnapshot {
    model.snapshot
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
    switch settingsModel.debugLogMinLevel.lowercased() {
    case "all": return .all
    case "debug": return .debug
    case "warn", "warning": return .warn
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

  private var currentQuery: DebugLogQuery {
    DebugLogQuery(
      mode: currentMode,
      minimumLevel: currentMinimumLevel,
      showSystemNoise: settingsModel.debugLogShowSystemNoise,
      startDate: effectiveStartDate,
      includeHistory: currentTimeScope == .all,
      keyword: appliedSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
      categoryFilters: selectedCategoryFilters
    )
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
    pushQuery()
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

  /// Sends the current filters to the model, which re-filters off the main thread.
  private func pushQuery() {
    model.updateQuery(currentQuery)
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
    pushQuery()
  }

  private func clearCategoryFilters() {
    guard !selectedCategoryFilters.isEmpty else { return }
    selectedCategoryFilters.removeAll()
    pushQuery()
  }

  private func categoryFilterExportSummary() -> String {
    let selected = selectedCategoryDescriptors.map(\.displayName)
    return selected.isEmpty ? languageManager.localize("No Filter (Showing All)") : selected.joined(separator: " | ")
  }

  /// The category filter as an NSMenu for the controller menu panel, which reaches
  /// it where the SwiftUI Menu cannot be focused (macOS 27).
  private func controllerCategoryMenu() -> (title: String, menu: NSMenu) {
    let menu = NSMenu(title: categoryMenuTitle)
    menu.autoenablesItems = false
    menu.addItem(
      ControllerMenuBuilder.item(
        title: languageManager.localize("Clear Category Filters"),
        enabled: !selectedCategoryFilters.isEmpty
      ) {
        clearCategoryFilters()
      })
    menu.addItem(NSMenuItem.separator())

    for domain in Self.domainOptions {
      let submenu = NSMenu(title: domain.displayName)
      submenu.autoenablesItems = false
      var anySelected = selectedCategoryFilters.contains(domain.categoryKey)
      submenu.addItem(
        ControllerMenuBuilder.item(
          title: languageManager.localize("All"),
          checked: selectedCategoryFilters.contains(domain.categoryKey)
        ) {
          toggleDomainFilter(domain.categoryKey)
        })
      for detail in detailOptions(for: domain) {
        let isSelected = selectedCategoryFilters.contains(detail.categoryKey)
        anySelected = anySelected || isSelected
        submenu.addItem(
          ControllerMenuBuilder.item(title: detail.displayName, checked: isSelected) {
            toggleCategoryFilter(detail.categoryKey)
          })
      }
      menu.addItem(
        ControllerMenuBuilder.submenuItem(
          title: domain.displayName, checked: anySelected, submenu: submenu))
    }
    return (title: categoryMenuTitle, menu: menu)
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
      pushQuery()
      return
    }

    let workItem = DispatchWorkItem {
      appliedSearchText = searchText
      pushQuery()
    }
    pendingSearchRefresh = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
  }

  private func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  private func copyFilteredEntries() {
    copyToPasteboard(snapshot.rows.map(\.rawLine).joined(separator: "\n"))
  }

  private func exportFilteredEntries() {
    let snapshotEntries = snapshot.rows
    let snapshotMode = settingsModel.debugLogMode
    let snapshotMinLevel = settingsModel.debugLogMinLevel
    let snapshotShowNoise = settingsModel.debugLogShowSystemNoise
    let snapshotSearch = searchText
    let snapshotCategories = categoryFilterExportSummary()
    let snapshotTotalRows = snapshot.totalRows
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

  // MARK: Scrolling

  private func handleContentFrame(_ frame: CGRect) {
    // While rows are being added the content grows before the scroll position catches up,
    // so a height change says nothing about whether the user is at the bottom.
    let heightChanged = abs(frame.height - scrollTracker.lastContentHeight) > 1
    scrollTracker.lastContentHeight = frame.height
    scrollTracker.contentMaxY = frame.maxY
    if !heightChanged {
      updateFollowState()
    }
  }

  private func handleViewportHeight(_ height: CGFloat) {
    scrollTracker.viewportHeight = height
    updateFollowState()
  }

  private func updateFollowState() {
    guard scrollTracker.viewportHeight > 0 else { return }
    let atBottom = scrollTracker.contentMaxY <= scrollTracker.viewportHeight + Self.bottomTolerance
    scrollTracker.isAtBottom = atBottom
    if showsJumpToLatest == atBottom {
      showsJumpToLatest = !atBottom
    }
  }

  private func scrollToLatest(_ proxy: ScrollViewProxy) {
    scrollTracker.isAtBottom = true
    if showsJumpToLatest {
      showsJumpToLatest = false
    }
    DispatchQueue.main.async {
      proxy.scrollTo(Self.endAnchorID, anchor: .bottom)
    }
  }

  /// Follows new rows only while the viewer is already at the bottom, so reading
  /// older lines is not interrupted by the stream of new ones.
  private func followLatestIfNeeded(_ proxy: ScrollViewProxy) {
    guard settingsModel.debugLogAutoScroll, !snapshot.rows.isEmpty else { return }
    let isFirstContent = !scrollTracker.didInitialScroll
    scrollTracker.didInitialScroll = true
    guard isFirstContent || scrollTracker.isAtBottom else { return }
    scrollToLatest(proxy)
  }

  private var logList: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 2) {
          if snapshot.rows.isEmpty {
            Text(languageManager.localize("(No logs yet)"))
              .font(.system(.caption, design: .monospaced))
              .foregroundColor(.secondary)
              .padding(.horizontal, 8)
              .padding(.vertical, 16)
          } else {
            ForEach(snapshot.rows) { entry in
              DebugLogRowView(entry: entry, mode: currentMode)
                .equatable()
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                  detailEntry = entry
                }
                .contextMenu {
                  Button(languageManager.localize("Copy Line")) {
                    copyToPasteboard(entry.rawLine)
                  }
                  Button(languageManager.localize("Show Details")) {
                    detailEntry = entry
                  }
                }
            }
          }
          Color.clear
            .frame(height: 1)
            .id(Self.endAnchorID)
        }
        .padding(.vertical, 4)
        .background(
          GeometryReader { geometry in
            Color.clear.preference(
              key: DebugLogContentFramePreferenceKey.self,
              value: geometry.frame(in: .named(Self.scrollSpaceName)))
          }
        )
      }
      .coordinateSpace(name: Self.scrollSpaceName)
      .background(
        GeometryReader { geometry in
          Color.clear.preference(
            key: DebugLogViewportHeightPreferenceKey.self, value: geometry.size.height)
        }
      )
      .onPreferenceChange(DebugLogContentFramePreferenceKey.self) { frame in
        handleContentFrame(frame)
      }
      .onPreferenceChange(DebugLogViewportHeightPreferenceKey.self) { height in
        handleViewportHeight(height)
      }
      .background(Color(NSColor.textBackgroundColor))
      .overlay(
        RoundedRectangle(cornerRadius: 6)
          .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
      )
      .overlay(alignment: .bottomTrailing) {
        if showsJumpToLatest {
          Button(languageManager.localize("Jump to Latest")) {
            scrollToLatest(proxy)
          }
          .padding(12)
        }
      }
      .onChange(of: snapshot.revision) { _ in
        followLatestIfNeeded(proxy)
      }
      .onChange(of: settingsModel.debugLogAutoScroll) { enabled in
        if enabled {
          scrollToLatest(proxy)
        }
      }
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
        .controllerPicker(
          selection: $settingsModel.debugLogMinLevel,
          choices: [("all", "All"), ("debug", "Debug"), ("info", "Info"), ("warn", "Warn"), ("error", "Error")]
            .map { (value: $0.0, title: languageManager.localize($0.1)) })
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
          pushQuery()
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
        .controllerMenu(controllerCategoryMenu)

        Text("\(languageManager.localize("Filtered Rows")): \(snapshot.rows.count)")
          .font(.caption)
          .foregroundColor(.secondary)
        Text("\(languageManager.localize("Total Rows")): \(snapshot.totalRows)")
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

        DebugLogStatBadge(label: languageManager.localize("Debug"), value: snapshot.debugCount, color: .gray)
        DebugLogStatBadge(label: languageManager.localize("Info"), value: snapshot.infoCount, color: .blue)
        DebugLogStatBadge(label: languageManager.localize("Warn"), value: snapshot.warnCount, color: .orange)
        DebugLogStatBadge(label: languageManager.localize("Error"), value: snapshot.errorCount, color: .red)
        Spacer()

        Button(languageManager.localize(isPaused ? "Resume" : "Pause")) {
          isPaused.toggle()
          model.setPaused(isPaused)
        }
      }

      logList
    }
    .padding(16)
    .frame(minWidth: 980, minHeight: 560)
    .onAppear {
      appLaunchDate = NSRunningApplication.current.launchDate ?? Date()
      appliedSearchText = searchText
      model.start(query: currentQuery)
    }
    .onDisappear {
      pendingSearchRefresh?.cancel()
      model.stop()
    }
    .onChange(of: settingsModel.debugLogMode) { _ in
      pushQuery()
    }
    .onChange(of: settingsModel.debugLogShowSystemNoise) { _ in
      pushQuery()
    }
    .onChange(of: searchText) { _ in
      scheduleSearchRefresh()
    }
    .onChange(of: settingsModel.debugLogMinLevel) { _ in
      pushQuery()
    }
    .onChange(of: settingsModel.debugLogTimeScope) { _ in
      if currentTimeScope == .sinceClear && clearFromDate == nil {
        clearFromDate = Date()
      }
      pushQuery()
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