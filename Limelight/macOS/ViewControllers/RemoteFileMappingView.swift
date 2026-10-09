import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Read-only browser for Foundation Sunshine shared folders. Downloads are
/// written to ~/Downloads and revealed in Finder; no App Group is required.
struct RemoteFileMappingView: View {
  @EnvironmentObject private var settingsModel: SettingsModel
  @ObservedObject private var languageManager = LanguageManager.shared
  @StateObject private var model = RemoteFileMappingViewModel()
  @State private var selectedEntryID: String?

  var body: some View {
    SettingsContent {
      SettingsPageHero(title: "Host Files", subtitle: "Read-only host files", symbol: "folder", tint: .teal)

      FormSection(title: "Host") {
        SettingsRow(title: "Connection") {
          Picker("", selection: selectedHostBinding) {
            ForEach(SettingsModel.hosts ?? [], id: \.self) { host in
              if let host { Text(host.id == SettingsModel.globalHostId ? languageManager.localize("Default Profile") : host.name).tag(Optional(host)) }
            }
          }
          .labelsHidden().pickerStyle(.menu).frame(width: 220, alignment: .trailing)
        }
        SettingsRow(title: "Status") {
          HStack(spacing: 8) {
            Circle().fill(model.state.isHealthy ? Color.green : Color.orange).frame(width: 8, height: 8)
            Text(model.status).foregroundStyle(.secondary).lineLimit(1)
            if model.isDownloading {
              Button(languageManager.localize("Cancel")) { model.cancelDownload() }
            } else if model.downloadedURL != nil {
              Button(languageManager.localize("Show in Finder")) { model.revealDownloadedFile() }
            }
          }
        }
      }

      SettingsFileListSection(title: "Shared Folders") {
        if model.mappings.isEmpty {
          SettingsFileListPlaceholder(textKey: "No shared folders")
        } else {
          ForEach(model.mappings) { mapping in
            // The current share is marked with a check; row highlight stays
            // reserved for the file selection below.
            SettingsFileListRow(
              icon: HostFileIcon.folder,
              name: mapping.name,
              detail: nil,
              isEnabled: !model.isDownloading,
              showsCheckmark: mapping.id == model.selectedMappingID
            ) { model.selectMapping(mapping) } onDoubleClick: { model.selectMapping(mapping) }
          }
        }
      }

      SettingsFileListSection(title: model.currentPath.isEmpty ? "Files" : model.currentPath) {
        if model.entries.isEmpty {
          SettingsFileListPlaceholder(textKey: model.isListing ? "Loading folder…" : "Folder is empty")
        } else {
          // Lazy so very large folders do not build every row up front.
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(model.entries) { entry in
              SettingsFileListRow(
                icon: entry.isDirectory ? HostFileIcon.folder : HostFileIcon.forFile(named: entry.name),
                name: entry.name,
                detail: entryDetail(entry),
                isSelected: entry.id == selectedEntryID,
                isEnabled: !model.isBusy,
                showsDisclosure: entry.isDirectory
              ) {
                selectedEntryID = entry.id
              } onDoubleClick: {
                selectedEntryID = entry.id
                model.open(entry)
              }
            }
          }
        }
      } toolbar: {
        SettingsFileListToolbarButton(symbol: "chevron.left", helpKey: "Back") { model.goUp() }
          .disabled(model.currentPath.isEmpty || model.isBusy)
        SettingsFileListToolbarButton(symbol: "arrow.clockwise", helpKey: "Refresh") { model.listCurrentFolder() }
          .disabled(model.isBusy)
        Spacer()
        if model.isDownloading {
          Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
          SettingsFileListToolbarButton(symbol: "xmark.circle", helpKey: "Cancel") { model.cancelDownload() }
        } else {
          SettingsFileListToolbarButton(symbol: "arrow.down.circle", helpKey: "Download") {
            if let entry = selectedFile { model.open(entry) }
          }
          .disabled(selectedFile == nil || model.isBusy)
          SettingsFileListToolbarButton(symbol: "magnifyingglass.circle", helpKey: "Show in Finder") {
            model.revealDownloadedFile()
          }
          .disabled(model.downloadedURL == nil)
        }
      }

      SettingDescriptionRow(textKey: "Host Files read-only detail")
    }
    .onAppear { model.refresh(host: settingsModel.selectedHost) }
    .onChange(of: settingsModel.selectedHost?.id) { _ in model.refresh(host: settingsModel.selectedHost) }
    // Close the socket and stop any download when the page goes away.
    .onDisappear { model.disconnect() }
  }

  private var selectedFile: RemoteFileEntry? {
    model.entries.first { $0.id == selectedEntryID && !$0.isDirectory }
  }

  private func entryDetail(_ entry: RemoteFileEntry) -> String? {
    var parts: [String] = []
    if !entry.isDirectory {
      parts.append(ByteCountFormatter.string(fromByteCount: Int64(clamping: entry.size), countStyle: .file))
    }
    if let modified = entry.modifiedAt {
      parts.append(modified.formatted(date: .abbreviated, time: .shortened))
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  private var selectedHostBinding: Binding<Host?> {
    Binding(get: { settingsModel.selectedHost }, set: { settingsModel.selectedHost = $0 })
  }
}

/// Finder icons for host entries, looked up by name only (host files are not local).
enum HostFileIcon {
  static var folder: NSImage { NSWorkspace.shared.icon(for: .folder) }

  static func forFile(named name: String) -> NSImage {
    let ext = (name as NSString).pathExtension
    let type = ext.isEmpty ? nil : UTType(filenameExtension: ext)
    return NSWorkspace.shared.icon(for: type ?? .data)
  }
}

/// A titled, bordered list with an optional bottom tool bar, in the style of
/// the item lists in System Settings (for example Login Items).
struct SettingsFileListSection<Rows: View, Toolbar: View>: View {
  let title: String
  let rows: Rows
  let toolbar: Toolbar
  private let hasToolbar: Bool

  init(title: String, @ViewBuilder rows: () -> Rows, @ViewBuilder toolbar: () -> Toolbar) {
    self.title = title
    self.rows = rows()
    self.toolbar = toolbar()
    hasToolbar = true
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(LocalizedStringKey(title))
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.head)
        .padding(.leading, 2)

      VStack(spacing: 0) {
        VStack(spacing: 0) { rows }
          .padding(.vertical, 4)
        if hasToolbar {
          Divider()
          HStack(spacing: 2) { toolbar }
            .padding(.horizontal, 6)
            .frame(height: 26)
        }
      }
      .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
  }
}

extension SettingsFileListSection where Toolbar == EmptyView {
  init(title: String, @ViewBuilder rows: () -> Rows) {
    self.title = title
    self.rows = rows()
    toolbar = EmptyView()
    hasToolbar = false
  }
}

struct SettingsFileListRow: View {
  let icon: NSImage
  let name: String
  let detail: String?
  var isSelected = false
  var isEnabled = true
  var showsDisclosure = false
  var showsCheckmark = false
  let onClick: () -> Void
  let onDoubleClick: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Image(nsImage: icon)
        .resizable()
        .frame(width: 20, height: 20)
      Text(name)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 8)
      if let detail {
        Text(detail)
          .font(.callout)
          .foregroundStyle(isSelected ? Color.white.opacity(0.85) : .secondary)
          .lineLimit(1)
      }
      if showsCheckmark {
        Image(systemName: "checkmark")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(Color.accentColor)
      }
      if showsDisclosure {
        Image(systemName: "chevron.right")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(isSelected ? Color.white.opacity(0.85) : .secondary)
      }
    }
    .foregroundStyle(isSelected ? Color.white : Color.primary)
    .padding(.horizontal, 8)
    .frame(height: 28)
    .background(
      RoundedRectangle(cornerRadius: 5, style: .continuous)
        .fill(isSelected ? Color.accentColor : Color.clear)
    )
    .padding(.horizontal, 4)
    .contentShape(Rectangle())
    .opacity(isEnabled ? 1 : 0.5)
    .onTapGesture(count: 2) { if isEnabled { onDoubleClick() } }
    .onTapGesture { if isEnabled { onClick() } }
    // Controller A selects first, then opens like a double click.
    .controllerFocusTarget(enabled: isEnabled) { isSelected ? onDoubleClick() : onClick() }
  }
}

struct SettingsFileListPlaceholder: View {
  @ObservedObject private var languageManager = LanguageManager.shared
  let textKey: String

  var body: some View {
    Text(languageManager.localize(textKey))
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, minHeight: 56)
  }
}

struct SettingsFileListToolbarButton: View {
  @ObservedObject private var languageManager = LanguageManager.shared
  let symbol: String
  let helpKey: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 13, weight: .medium))
        .frame(width: 24, height: 20)
        .contentShape(Rectangle())
    }
    .controllerButtonStyle(.borderless)
    .help(languageManager.localize(helpKey))
    .accessibilityLabel(languageManager.localize(helpKey))
  }
}
