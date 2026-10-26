import AppKit
import Combine
import SwiftUI

/// Native macOS settings information architecture. The split view is kept
/// resizable but the sidebar has a hard minimum so navigation cannot vanish.
enum SettingsPaneType: Int, CaseIterable, Hashable {
  case stream = 0
  case video = 1
  case audio = 5
  case input = 2
  case app = 3
  case legacy = 4
  case display = 6
  case keyboard = 7
  case usb = 8
  case fileMapping = 9
  case about = 10
  case updates = 11
  case profiles = 12

  static var allCases: [SettingsPaneType] {
    [.stream, .display, .video, .audio, .input, .keyboard, .usb, .fileMapping, .profiles, .app, .about]
  }

  var titleKey: String {
    switch self {
    case .stream: return "Streaming"
    case .video: return "Video"
    case .display: return "Display & HDR"
    case .audio: return "Audio & Microphone"
    case .input: return "Controller"
    case .keyboard: return "Keyboard & Mouse"
    case .usb: return "USB Mapping"
    case .app: return "App & Diagnostics"
    case .fileMapping: return "Host Files"
    case .about: return "About & Updates"
    case .updates: return "Updates"
    case .legacy: return "Legacy"
    case .profiles: return "settingProfiles"
    }
  }

  var categoryKey: String {
    switch self {
    case .stream, .video, .display, .audio: return "Media"
    case .input, .keyboard, .usb, .fileMapping: return "Input & Devices"
    case .profiles, .app, .about, .updates, .legacy: return "Application"
    }
  }

  var symbol: String {
    switch self {
    case .stream: return "rectangle.inset.filled.and.person.filled"
    case .video: return "video.fill"
    case .display: return "display.2"
    case .audio: return "speaker.wave.2.fill"
    case .input: return "gamecontroller.fill"
    case .keyboard: return "keyboard.fill"
    case .usb: return "cable.connector.horizontal"
    case .fileMapping: return "folder.badge.gearshape"
    case .app: return "gearshape.2.fill"
    case .about: return "info.circle.fill"
    case .updates: return "arrow.down.circle.fill"
    case .legacy: return "archivebox.fill"
    case .profiles: return "person.2.fill"
    }
  }

  var subtitleKey: String {
    switch self {
    case .stream: return "Streaming settings subtitle"
    case .display: return "Display settings subtitle"
    case .video: return "Video settings subtitle"
    case .audio: return "Audio settings subtitle"
    case .input: return "Controller settings subtitle"
    case .keyboard: return "Keyboard and mouse settings subtitle"
    case .usb: return "USB settings subtitle"
    case .fileMapping: return "Host Files settings subtitle"
    case .about: return "About settings subtitle"
    case .updates: return "Updates settings subtitle"
    case .app, .legacy: return "App diagnostics settings subtitle"
    case .profiles: return "settingProfiles subtitle"
    }
  }

  var color: Color {
    switch self {
    case .stream: return .cyan
    case .display: return .orange
    case .video: return .blue
    case .audio: return .red
    case .input: return .purple
    case .keyboard: return .blue
    case .usb, .fileMapping: return .teal
    case .app: return .pink
    case .about: return .gray
    case .updates: return .blue
    case .legacy: return .gray
    case .profiles: return .indigo
    }
  }
}

/// What a search entry points at: a whole pane, a titled section of a pane, or
/// one row. Rows and sections can be scrolled to; panes scroll to the top.
enum SettingsSearchEntryKind: Hashable {
  case pane
  case section
  case row
}

struct SettingsSearchEntry: Identifiable, Hashable {
  let id: String
  let pane: SettingsPaneType
  let kind: SettingsSearchEntryKind
  let sectionKey: String
  let titleKey: String
  let detailKey: String?
  let keywords: [String]

  func matches(_ query: String, languageManager: LanguageManager) -> Bool {
    let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return true }
    let values = [titleKey, sectionKey, detailKey ?? ""] + keywords
    return values.contains { value in
      value.localizedCaseInsensitiveContains(normalized) ||
        languageManager.localize(value).localizedCaseInsensitiveContains(normalized)
    }
  }
}

/// The searchable settings items. `generatedEntries` lives in
/// SettingsSearchIndex.generated.swift and is produced from the settings views
/// by scripts/generate_settings_search_index.py (an Xcode build phase runs it
/// before compiling), so a new row is searchable without touching this file.
/// Only extra search words for existing rows are written by hand below.
enum SettingsSearchIndex {
  static let entries: [SettingsSearchEntry] = SettingsSearchIndex.generatedEntries.map { (entry: SettingsSearchEntry) -> SettingsSearchEntry in
    guard let extra = SettingsSearchIndex.supplementalKeywords[entry.titleKey] else { return entry }
    return SettingsSearchEntry(
      id: entry.id,
      pane: entry.pane,
      kind: entry.kind,
      sectionKey: entry.sectionKey,
      titleKey: entry.titleKey,
      detailKey: entry.detailKey,
      keywords: entry.keywords + extra
    )
  }

  /// Optional synonyms and abbreviations, keyed by the row's title key. Rows do
  /// not need an item here to be found.
  private static let supplementalKeywords: [String: [String]] = [
    "Profile": ["Host", "主机", "配置"],
    // A profile's details are one level down, where search cannot go: their actions are
    // words for the page.
    "settingProfiles": [
      "Profile", "Default Profile", "Preset", "Copy Settings", "Save as Preset…",
      "Use as Default Profile…", "Export…", "Import…", "Reset to Default Profile…",
      "Per-App Settings", "配置", "预设",
    ],
    "Connection Method": ["addresses", "连接方式", "地址"],
    "Connection Addresses": ["host", "IP", "端口", "管理地址"],
    "Resolution": ["分辨率"],
    "Frame Rate": ["FPS", "帧率"],
    "Bitrate": ["码率"],
    "Auto Adjust Bitrate": ["自动码率"],
    "Play Sound on Host": ["audio", "音频", "主机声音", "主机播放"],
    "Clipboard Sync": ["paste", "剪贴板"],
    "Video Codec": ["HEVC", "编码"],
    "Renderer Mode": ["Metal", "渲染器"],
    "HDR": ["高动态范围"],
    "10-bit SDR": ["10 bit", "10位", "SDR"],
    "Transfer Function": ["PQ", "HLG", "传输函数"],
    "Dolby Vision Profile 8.1": ["DV", "杜比", "杜比视界"],
    "Dolby Vision Profile 8.4": ["DV", "杜比", "杜比视界"],
    "Pacing": ["jitter", "帧 pacing", "流畅"],
    "VSync": ["垂直同步"],
    "Audio Configuration": ["output", "输出", "音频设备"],
    "Volume": ["音量"],
    "Sound Mode": ["音效"],
    "Enable Microphone": ["mic", "麦克风"],
    "Microphone Permission": ["permission", "权限"],
    "Start Test": ["Test Microphone", "输入测试"],
    "Connected Controllers": ["gamepad", "手柄", "DualSense", "DS5"],
    "Host Controller Type": ["DS5", "DS4", "PlayStation", "DualShock", "PS4", "PS5", "手柄类型"],
    "Haptic Feedback": ["rumble", "震动", "触觉"],
    "Rumble": ["haptic", "震动"],
    "Motion Sensor": ["motion", "陀螺仪", "动作"],
    "DualSense Touchpad Mode": ["touchpad", "触控板", "Trackpad"],
    "Controller Deadzone": ["摇杆", "死区"],
    "Keyboard Translation": ["keyboard", "键盘"],
    "Mouse Mode": ["mouse", "鼠标"],
    "Pointer Speed": ["指针"],
    "Target Display": ["显示器", "拓扑"],
    "VDD Capability": ["virtual display", "虚拟显示器"],
    "Use Virtual Display": ["VDD", "虚拟显示"],
    "Screen Mode": ["屏幕模式", "自定义分辨率"],
    "HDR Metadata Source": ["HDR", "元数据"],
    "Override HDR Display Profile": ["亮度", "显示档案"],
    "USB Mapping": ["USB forwarding", "USB 转发", "USB/IP"],
    "Host Files": ["file mapping", "文件映射", "主机文件"],
    "Input Diagnostics": ["mapping", "诊断"],
    "Recording Detail": ["log", "debug", "日志", "调试"],
    "Check for Updates": ["Sparkle", "update", "更新"],
    "Moonlight macOS Enhanced": ["版本"],
  ]
}

struct SettingsView: View {
  @StateObject private var settingsModel = SettingsModel()
  @ObservedObject private var languageManager = LanguageManager.shared
  @AppStorage("selected-settings-pane") private var selectedPane: SettingsPaneType = .stream
  let hostId: String?
  @State private var selectedInitialHost = false

  init(hostId: String? = nil) {
    self.hostId = hostId
  }

  var body: some View {
    settingsRoot
    // Default-style buttons become controller focus targets.
    .controllerButtonStyle(.automatic)
    .environment(\.locale, languageManager.currentLanguage == .system ? .current
      : Locale(identifier: languageManager.currentLanguage == .chinese ? "zh-Hans" : "en"))
    .background(Color(nsColor: .windowBackgroundColor))
    .frame(minWidth: 820, minHeight: 560)
    .onAppear {
      if selectedPane == .legacy { selectedPane = .app }
      // Once: the window is kept and shown again, and then the host comes from
      // SettingsWindowObjCBridge.prepareSettingsWindowForShowing, not from when it was made.
      guard !selectedInitialHost else { return }
      selectedInitialHost = true
      settingsModel.selectHost(
        id: SettingsWindowObjCBridge.requestedHostId ?? hostId ?? SettingsModel.globalHostId)
    }
  }

  @ViewBuilder
  private var settingsRoot: some View {
    if #available(macOS 13.0, *) {
      ModernSettingsRoot(selectedPane: $selectedPane, settingsModel: settingsModel)
    } else {
      HSplitView {
        SettingsSidebar(selection: $selectedPane, settingsModel: settingsModel)
          .frame(minWidth: 188, idealWidth: 208, maxWidth: 228)
        SettingsDetail(pane: selectedPane)
          .environmentObject(settingsModel)
          .frame(minWidth: 650, maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }
}

@available(macOS 13.0, *)
private struct ModernSettingsRoot: View {
  @Binding var selectedPane: SettingsPaneType
  @ObservedObject var settingsModel: SettingsModel
  @SwiftUI.State private var columnVisibility: NavigationSplitViewVisibility = .all

  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      SettingsSidebar(selection: $selectedPane, settingsModel: settingsModel)
        .navigationSplitViewColumnWidth(min: 188, ideal: 208, max: 228)
    } detail: {
      SettingsPaneHost(pane: selectedPane, settingsModel: settingsModel)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    .navigationSplitViewStyle(.balanced)
    .onChange(of: columnVisibility) { value in
      if value != .all { columnVisibility = .all }
    }
  }
}

private struct SettingsSidebar: View {
  @Binding var selection: SettingsPaneType
  @ObservedObject var settingsModel: SettingsModel
  @ObservedObject private var languageManager = LanguageManager.shared
  @SwiftUI.State private var query = ""

  private var filteredPanes: [SettingsPaneType] {
    let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return SettingsPaneType.allCases }
    return SettingsPaneType.allCases.filter { pane in
      languageManager.localize(pane.titleKey).localizedCaseInsensitiveContains(normalized)
        || languageManager.localize(pane.subtitleKey).localizedCaseInsensitiveContains(normalized)
    }
  }

  private var searchResults: [SettingsSearchEntry] {
    SettingsSearchIndex.entries.filter { $0.matches(query, languageManager: languageManager) }
  }

  private func panes(in category: String) -> [SettingsPaneType] {
    filteredPanes.filter { $0.categoryKey == category }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      SettingsProfilePicker(settingsModel: settingsModel)
        .padding(.horizontal, 14)
        .padding(.bottom, 8)

      if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        List(selection: Binding<SettingsPaneType?>(
          get: { selection },
          set: { if let value = $0 { selection = value } }
        )) {
          SettingsSidebarCategory(titleKey: "Media", panes: panes(in: "Media"), selection: $selection)
          SettingsSidebarCategory(titleKey: "Input & Devices", panes: panes(in: "Input & Devices"), selection: $selection)
          SettingsSidebarCategory(titleKey: "Application", panes: panes(in: "Application"), selection: $selection)
        }
        .listStyle(.sidebar)
        .searchable(text: $query, placement: .sidebar, prompt: languageManager.localize("Search Settings"))
        .controllerSearchFocus()
      } else {
        List {
          if searchResults.isEmpty {
            SettingsEmptySearchView()
          } else {
            Section(languageManager.localize("Settings")) {
              ForEach(searchResults) { result in
                Button {
                  selection = result.pane
                  SettingsSearchNavigator.shared.navigate(to: result)
                  query = ""
                } label: {
                  VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                      Image(systemName: result.pane.symbol)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(result.pane.color)
                      Text(languageManager.localize(result.titleKey))
                    }
                    Text("\(languageManager.localize(result.pane.titleKey)) · \(languageManager.localize(result.sectionKey))")
                      .font(.caption)
                      .foregroundStyle(.secondary)
                      .lineLimit(1)
                  }
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .contentShape(Rectangle())
                }
                .controllerButtonStyle(.plain)
                .padding(.vertical, 3)
              }
            }
          }
        }
        .listStyle(.sidebar)
        .searchable(text: $query, placement: .sidebar, prompt: languageManager.localize("Search Settings"))
        .controllerSearchFocus()
      }
    }
    .background(.thinMaterial)
  }
}

private struct SettingsEmptySearchView: View {
  @ObservedObject private var languageManager = LanguageManager.shared

  var body: some View {
    VStack(spacing: 7) {
      Image(systemName: "magnifyingglass")
        .font(.title3)
        .foregroundStyle(.secondary)
      Text(languageManager.localize("No Results"))
        .font(.headline)
      Text(languageManager.localize("No matching settings"))
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 28)
  }
}

private struct SettingsSidebarCategory: View {
  let titleKey: String
  let panes: [SettingsPaneType]
  @Binding var selection: SettingsPaneType
  @ObservedObject private var languageManager = LanguageManager.shared

  var body: some View {
    if !panes.isEmpty {
      Section {
        ForEach(panes, id: \.self) { pane in
          Label {
            Text(languageManager.localize(pane.titleKey)).lineLimit(1)
          } icon: {
            Image(systemName: pane.symbol)
              .symbolRenderingMode(.hierarchical)
              .foregroundStyle(pane.color)
          }
          .padding(.vertical, 3)
          .tag(pane)
        }
      } header: {
        Text(languageManager.localize(titleKey))
      }
    }
  }
}

/// Holds the settings pages that were shown and puts the selected one in the window.
///
/// With the pages in the window's own SwiftUI tree, going from one to another threw the
/// views of the first away and built those of the second, several hundred each time: a
/// visible wait on every click (measured: three to four times what bringing a kept page
/// back costs). Here every page has a hosting view of its own, and the ones that are not
/// showing wait outside the window. Pages are also built ahead (see prewarmNextPage).
///
/// Kept pages are not free, though: every one of them works a change of the settings
/// through, in the window or not (measured: 32 ms for a change with one page, 250 ms and
/// more with ten). So they are only kept while nothing changes. The first real change
/// releases the pages that are not showing; they are built again once things are quiet.
final class SettingsPaneContainerView: NSView {
  /// The container of the settings window, for building pages ahead.
  static weak var current: SettingsPaneContainerView?

  var makePage: ((SettingsPaneType) -> NSView)?
  private var pages: [SettingsPaneType: NSView] = [:]
  private var shown: SettingsPaneType?
  private var lastSwitch: TimeInterval = 0
  private var lastChange: TimeInterval = 0

  /// The settings are about to change. A reload of the whole profile is let through to
  /// every page (it happens once). So is a status that is announced, and what a page does
  /// by itself. What is left is someone editing: the other pages go.
  func settingsWillChange(isLoading: Bool) {
    // The pages are views: they are only let go on the main thread. A change announced
    // anywhere else is a mistake of whoever made it, and is named in the log.
    guard Thread.isMainThread else {
      if !Self.reportedBackgroundChange {
        Self.reportedBackgroundChange = true
        LogMessage(
          LOG_W,
          "[diag] settings changed off the main thread: "
            + Thread.callStackSymbols.dropFirst(2).prefix(8).joined(separator: " | "))
      }
      DispatchQueue.main.async { [weak self] in self?.settingsWillChange(isLoading: isLoading) }
      return
    }
    guard !isLoading, someoneIsEditing else { return }
    let now = ProcessInfo.processInfo.systemUptime
    lastChange = now
    guard now - lastSwitch > 0.35, pages.count > 1, !releaseScheduled else { return }
    // Not here: this runs inside the announcement of the change, which may come from one of
    // these very pages (something it does when a notification arrives, or when it appears),
    // and a page must not be taken apart under its own update. Right after it.
    releaseScheduled = true
    DispatchQueue.main.async { [weak self] in
      self?.releaseScheduled = false
      self?.releasePagesNotShowing()
    }
  }

  private var releaseScheduled = false

  /// Whether a change that is going on now can be somebody editing the settings. A page
  /// changes the model by itself too, when it appears and when something it asked for
  /// arrives; taken for edits, those let the pages built ahead go as soon as they were
  /// built, and they were built again, without end.
  private var someoneIsEditing: Bool {
    // What a controller does is not seen here; with one connected every change counts
    // (and no page is built ahead, see prewarmNextPage).
    if ControllerPresence.shared.isConnected { return true }
    guard NSApp.isActive else { return false }
    let sinceInput = CGEventSource.secondsSinceLastEventType(
      .combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    return sinceInput < 0.5
  }
  private static var reportedBackgroundChange = false

  /// Lets every page go but the one in the window. Also when the window closes: nobody is
  /// about to click a page then, and a kept page works every change of the settings through.
  func releasePagesNotShowing() {
    guard pages.count > 1 else { return }
    let released = pages.count - 1
    pages = pages.filter { $0.key == shown }
    LogMessage(LOG_I, "[diag] settings pages released: \(released)")
  }

  private func page(for pane: SettingsPaneType) -> NSView? {
    if let page = pages[pane] {
      return page
    }
    guard let page = makePage?(pane) else { return nil }
    page.autoresizingMask = [.width, .height]
    pages[pane] = page
    return page
  }

  func show(_ pane: SettingsPaneType) {
    guard shown != pane, let page = page(for: pane) else { return }
    if let shown {
      pages[shown]?.removeFromSuperview()
    }
    page.isHidden = false
    page.frame = bounds
    addSubview(page)
    shown = pane
    lastSwitch = ProcessInfo.processInfo.systemUptime
  }

  /// The window closed or is about to open. The page that was showing leaves a closed
  /// window like the others, so that it is told: what it keeps open stops, and it looks at
  /// things afresh when the window opens.
  func windowVisibilityChanged(_ visible: Bool) {
    guard let shown, let page = pages[shown] else { return }
    if !visible {
      releasePagesNotShowing()
      page.removeFromSuperview()
    } else if page.superview == nil {
      page.frame = bounds
      addSubview(page)
    }
  }

  /// Builds one page that has not been asked for yet, so that it is there when it is.
  /// Returns false when every page exists.
  func prewarmNextPage() -> Bool {
    // Not while settings are being edited: the page would be released by the next change.
    guard ProcessInfo.processInfo.systemUptime - lastChange > 3 else { return false }
    // Only while the window is open: that is when a page may be clicked next. Behind a
    // closed window the pages would be built, and let go at the next change, for nobody.
    guard window?.isVisible == true, !ControllerPresence.shared.isConnected,
      let pane = SettingsPaneType.allCases.first(where: { pages[$0] == nil }),
      let page = page(for: pane)
    else { return false }
    // In the window for one layout, which is what creates its views; hidden meanwhile.
    page.isHidden = true
    page.frame = bounds
    addSubview(page)
    page.layoutSubtreeIfNeeded()
    page.removeFromSuperview()
    page.isHidden = false
    return true
  }
}

@available(macOS 13.0, *)
private struct SettingsPaneHost: NSViewRepresentable {
  let pane: SettingsPaneType
  let settingsModel: SettingsModel

  final class Coordinator {
    var changes: AnyCancellable?
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> SettingsPaneContainerView {
    let view = SettingsPaneContainerView()
    let model = settingsModel
    context.coordinator.changes = model.objectWillChange.sink { [weak view, weak model] _ in
      // A reload of the profile and a status that is announced are not edits.
      view?.settingsWillChange(
        isLoading: (model?.isLoading ?? false) || (model?.isAnnouncingStatus ?? false))
    }
    view.makePage = { pane in
      let host = NSHostingView(rootView: SettingsPaneRoot(pane: pane, settingsModel: model))
      // The page fills the column; it has no say in the size of the window.
      host.sizingOptions = []
      return host
    }
    SettingsPaneContainerView.current = view
    return view
  }

  func updateNSView(_ view: SettingsPaneContainerView, context: Context) {
    switch pane {
    case .legacy: view.show(.app)
    case .updates: view.show(.about)
    default: view.show(pane)
    }
  }
}

/// A settings page with what it used to take from the window's SwiftUI tree around it.
private struct SettingsPaneRoot: View {
  let pane: SettingsPaneType
  let settingsModel: SettingsModel
  @ObservedObject private var languageManager = LanguageManager.shared

  var body: some View {
    SettingsDetail(pane: pane)
      .environmentObject(settingsModel)
      // Default-style buttons become controller focus targets.
      .controllerButtonStyle(.automatic)
      .environment(\.locale, languageManager.currentLanguage == .system ? .current
        : Locale(identifier: languageManager.currentLanguage == .chinese ? "zh-Hans" : "en"))
  }
}

private struct SettingsDetail: View {
  let pane: SettingsPaneType
  @EnvironmentObject private var settingsModel: SettingsModel

  private var effectivePane: SettingsPaneType {
    switch pane {
    case .legacy: return .app
    case .updates: return .about
    default: return pane
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Group {
        switch effectivePane {
        case .stream: StreamView()
        case .video: VideoView()
        case .display: FoundationDisplayView()
        case .audio: AudioView()
        case .input: InputView(scope: .controller)
        case .keyboard: InputView(scope: .keyboardMouse)
        case .usb: InputView(scope: .usb)
        case .fileMapping: FileMappingSettingsPage()
        case .profiles: ProfilesSettingsPage()
        case .app: AppView()
        case .about: AboutUpdatesSettingsPage()
        case .updates: AboutUpdatesSettingsPage()
        case .legacy: EmptyView()
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .environmentObject(settingsModel)
    // Rows outside any titled section belong to the pane itself, which is how
    // the search index names them.
    .environment(\.settingsSearchPane, effectivePane)
    .environment(\.settingsSearchSection, effectivePane.titleKey)
    .background(Color(nsColor: .windowBackgroundColor).opacity(0.96))
  }
}

private struct AudioSettingsHeader: View {
  @ObservedObject private var languageManager = LanguageManager.shared

  var body: some View {
    HStack(spacing: 14) {
      HStack(spacing: 0) {
        Button { } label: { Image(systemName: "chevron.left") }
        Button { } label: { Image(systemName: "chevron.right") }
      }
      .controllerButtonStyle(.borderless)
      .font(.title3)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(Color(nsColor: .controlBackgroundColor), in: Capsule())

      Text(languageManager.localize("Sound"))
        .font(.title2.weight(.semibold))
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 24)
    .padding(.top, 18)
    .padding(.bottom, 12)
  }
}

private struct SettingsPageHeader: View {
  let pane: SettingsPaneType
  @ObservedObject private var languageManager = LanguageManager.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 14) {
        HStack(spacing: 0) {
          Button { } label: { Image(systemName: "chevron.left") }
          Button { } label: { Image(systemName: "chevron.right") }
        }
        .controllerButtonStyle(.borderless)
        .font(.title3)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())

        VStack(alignment: .leading, spacing: 3) {
          Text(languageManager.localize(pane.titleKey))
            .font(.title2.weight(.semibold))
          Text(languageManager.localize(pane.subtitleKey))
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
      }
    }
    .padding(.horizontal, 32)
    .padding(.top, 26)
    .padding(.bottom, 17)
  }
}

private struct SettingsProfilePicker: View {
  @ObservedObject var settingsModel: SettingsModel
  @ObservedObject private var languageManager = LanguageManager.shared

  private var binding: Binding<Host?> {
    Binding(get: { settingsModel.selectedHost }, set: { settingsModel.selectedHost = $0 })
  }

  var body: some View {
    Picker(selection: binding) {
      ForEach(SettingsModel.hosts ?? [], id: \.self) { host in
        if let host {
          Text(host.id == SettingsModel.globalHostId
            ? languageManager.localize("Default Profile") : host.name)
            .foregroundStyle(host.id == SettingsModel.globalHostId ? .secondary : .primary)
            .tag(Optional(host))
        }
      }
    } label: {
      Label(languageManager.localize("Settings Profile"), systemImage: "person.crop.circle")
    }
    .pickerStyle(.menu)
    .controlSize(.small)
    .controllerPicker(
      selection: binding,
      choices: (SettingsModel.hosts ?? []).compactMap { $0 }.map { host in
        (value: Optional(host),
         title: host.id == SettingsModel.globalHostId ? languageManager.localize("Default Profile") : host.name)
      })
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}


private extension View {
  @ViewBuilder func controllerSearchFocus() -> some View {
    if #available(macOS 15, *) { modifier(ControllerSearchFocusModifier()) }
    else { self }
  }
}
@available(macOS 15, *)
private struct ControllerSearchFocusModifier: ViewModifier {
  @FocusState private var focused: Bool
  func body(content: Content) -> some View {
    content.searchFocused($focused)
      .onReceive(NotificationCenter.default.publisher(for: .init("ControllerFocusSettingsSearch"))) { _ in focused = true }
  }
}
