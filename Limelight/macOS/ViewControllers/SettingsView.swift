import AppKit
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

  static var allCases: [SettingsPaneType] {
    [.stream, .display, .video, .audio, .input, .keyboard, .usb, .fileMapping, .app, .about]
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
    }
  }

  var categoryKey: String {
    switch self {
    case .stream, .video, .display, .audio: return "Media"
    case .input, .keyboard, .usb, .fileMapping: return "Input & Devices"
    case .app, .about, .updates, .legacy: return "Application"
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
    }
  }
}

private struct SettingsSearchEntry: Identifiable, Hashable {
  let id: String
  let pane: SettingsPaneType
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

private enum SettingsSearchIndex {
  static let entries: [SettingsSearchEntry] = [
    entry(.stream, "General", "Profile", keywords: ["Host", "主机", "配置"]),
    entry(.stream, "General", "Connection Method", keywords: ["addresses", "连接方式", "地址"]),
    entry(.stream, "General", "Connection Addresses", "Connection Addresses detail", keywords: ["host", "IP", "端口", "管理地址"]),
    entry(.stream, "Resolution & Frame Rate", "Resolution", keywords: ["分辨率"]),
    entry(.stream, "Resolution & Frame Rate", "Frame Rate", keywords: ["FPS", "帧率"]),
    entry(.stream, "Bitrate & Playback", "Bitrate", "Bitrate detail", keywords: ["码率"]),
    entry(.stream, "Bitrate & Playback", "Auto Adjust Bitrate", keywords: ["自动码率"]),
    entry(.stream, "Bitrate & Playback", "Play Sound on Host", keywords: ["audio", "音频", "主机声音"]),
    entry(.stream, "Clipboard", "Clipboard Sync", "Clipboard Sync detail", keywords: ["paste", "剪贴板"]),

    entry(.video, "Video", "Video Codec", keywords: ["H.264", "HEVC", "AV1", "编码"]),
    entry(.video, "Video", "Renderer Mode", keywords: ["Metal", "渲染器"]),
    entry(.video, "Video", "HDR", "HDR detail", keywords: ["高动态范围"]),
    entry(.video, "Video", "10-bit SDR", keywords: ["10 bit", "10位", "SDR"]),
    entry(.video, "Video", "Transfer Function", keywords: ["PQ", "HLG", "传输函数"]),
    entry(.video, "HDR Capabilities", "HDR Capabilities", keywords: ["HDR10+", "Dolby Vision", "杜比视界"]),
    entry(.video, "HDR Capabilities", "Dolby Vision Profile 8.1", keywords: ["DV", "杜比"]),
    entry(.video, "HDR Capabilities", "Dolby Vision Profile 8.4", keywords: ["DV", "杜比"]),
    entry(.video, "Frame Pacing", "Pacing", keywords: ["jitter", "帧 pacing", "流畅"]),
    entry(.video, "Frame Pacing", "VSync", keywords: ["垂直同步"]),

    entry(.audio, "Audio Configuration", "Audio Configuration", keywords: ["output", "输出", "音频设备"]),
    entry(.audio, "Audio Configuration", "Volume", keywords: ["音量"]),
    entry(.audio, "Audio Configuration", "Play Sound on Host", keywords: ["主机播放"]),
    entry(.audio, "Audio Enhancement", "Sound Mode", keywords: ["音效"]),
    entry(.audio, "Microphone", "Enable Microphone", keywords: ["mic", "麦克风"]),
    entry(.audio, "Microphone", "Microphone Permission", keywords: ["permission", "权限"]),
    entry(.audio, "Microphone", "Test Microphone", keywords: ["输入测试"]),

    entry(.input, "Controller", "Connected Controllers", keywords: ["gamepad", "手柄", "DualSense", "DS5"]),
    entry(.input, "Controller", "Host Controller Type", keywords: ["DS5", "DS4", "PlayStation", "手柄类型"]),
    entry(.input, "Controller", "Haptic Feedback", keywords: ["rumble", "震动", "触觉"]),
    entry(.input, "Controller", "Motion Sensor", keywords: ["motion", "陀螺仪", "动作"]),
    entry(.input, "Controller", "DualSense Touchpad Mode", "Native Touchpad detail", keywords: ["touchpad", "触控板", "Trackpad"]),
    entry(.input, "Controller", "Controller Deadzone", keywords: ["摇杆", "死区"]),
    entry(.keyboard, "Keyboard & Mouse", "Keyboard Translation", keywords: ["keyboard", "键盘"]),
    entry(.keyboard, "Keyboard & Mouse", "Mouse Mode", keywords: ["mouse", "鼠标"]),
    entry(.keyboard, "Keyboard & Mouse", "Pointer Speed", keywords: ["指针"]),

    entry(.display, "Host Display", "Target Display", keywords: ["显示器", "拓扑"]),
    entry(.display, "Host Display", "VDD Capability", keywords: ["virtual display", "虚拟显示器"]),
    entry(.display, "Host Display", "Use Virtual Display", keywords: ["VDD", "虚拟显示"]),
    entry(.display, "Host Display", "Screen Mode", keywords: ["屏幕模式", "自定义分辨率"]),
    entry(.display, "HDR Display Profile", "HDR Metadata Source", keywords: ["HDR", "元数据"]),
    entry(.display, "HDR Display Profile", "Override HDR Display Profile", keywords: ["亮度", "显示档案"]),

    entry(.usb, "USB Mapping", "USB Mapping", "USB settings subtitle", keywords: ["USB forwarding", "USB 转发", "USB/IP"]),
    entry(.fileMapping, "Host Files", "Host Files", "Host Files purpose detail", keywords: ["file mapping", "文件映射", "主机文件"]),
    entry(.app, "Diagnostics", "Input Diagnostics", keywords: ["mapping", "诊断"]),
    entry(.app, "Updates", "Check for Updates", keywords: ["Sparkle", "update", "更新"]),
    entry(.about, "About", "Moonlight macOS Enhanced", "About hero subtitle", keywords: ["version", "版本"]),
  ]

  private static func entry(_ pane: SettingsPaneType, _ sectionKey: String, _ titleKey: String,
                            _ detailKey: String? = nil, keywords: [String] = []) -> SettingsSearchEntry {
    SettingsSearchEntry(
      id: "\(pane.rawValue)-\(sectionKey)-\(titleKey)",
      pane: pane,
      sectionKey: sectionKey,
      titleKey: titleKey,
      detailKey: detailKey,
      keywords: keywords
    )
  }
}

struct SettingsView: View {
  @StateObject private var settingsModel = SettingsModel()
  @ObservedObject private var languageManager = LanguageManager.shared
  @AppStorage("selected-settings-pane") private var selectedPane: SettingsPaneType = .stream
  let hostId: String?

  init(hostId: String? = nil) {
    self.hostId = hostId
  }

  var body: some View {
    settingsRoot
    .environment(\.locale, languageManager.currentLanguage == .system ? .current
      : Locale(identifier: languageManager.currentLanguage == .chinese ? "zh-Hans" : "en"))
    .background(Color(nsColor: .windowBackgroundColor))
    .frame(minWidth: 820, minHeight: 560)
    .onAppear {
      if selectedPane == .legacy { selectedPane = .app }
      settingsModel.selectHost(id: hostId ?? SettingsModel.globalHostId)
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
      SettingsDetail(pane: selectedPane)
        .environmentObject(settingsModel)
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
      } else {
        List {
          if searchResults.isEmpty {
            SettingsEmptySearchView()
          } else {
            Section(languageManager.localize("Settings")) {
              ForEach(searchResults) { result in
                Button {
                  selection = result.pane
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
                .buttonStyle(.plain)
                .padding(.vertical, 3)
              }
            }
          }
        }
        .listStyle(.sidebar)
        .searchable(text: $query, placement: .sidebar, prompt: languageManager.localize("Search Settings"))
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
        case .app: AppView()
        case .about: AboutUpdatesSettingsPage()
        case .updates: AboutUpdatesSettingsPage()
        case .legacy: EmptyView()
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .environmentObject(settingsModel)
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
      .buttonStyle(.borderless)
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
        .buttonStyle(.borderless)
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
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
