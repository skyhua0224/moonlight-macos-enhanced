//
//  SettingsProfilesPane.swift
//  Moonlight for macOS
//
//  Copyright © 2026 Moonlight Game Streaming Project. All rights reserved.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A profile listed on the Setting Profiles page: the Default Profile, a paired host or a
/// preset.
struct SettingsProfileEntry: Identifiable, Hashable {
  enum Kind {
    case defaultProfile
    case host
    case preset
  }

  let id: String
  let kind: Kind
  let name: String

  static var defaultProfile: SettingsProfileEntry {
    SettingsProfileEntry(
      id: SettingsModel.globalHostId, kind: .defaultProfile,
      name: LanguageManager.shared.localize("Default Profile"))
  }

  static var hosts: [SettingsProfileEntry] {
    (SettingsModel.hosts ?? []).compactMap { $0 }
      .filter { $0.id != SettingsModel.globalHostId }
      .map { SettingsProfileEntry(id: $0.id, kind: .host, name: $0.name) }
  }

  static var presets: [SettingsProfileEntry] {
    SettingsModel.presets.map { SettingsProfileEntry(id: $0.id, kind: .preset, name: $0.name) }
  }

  static func find(_ id: String) -> SettingsProfileEntry? {
    ([defaultProfile] + hosts + presets).first { $0.id == id }
  }

  var symbol: String {
    switch kind {
    case .defaultProfile: return "rectangle.stack.fill"
    case .host: return "desktopcomputer"
    case .preset: return "bookmark.fill"
    }
  }

  var tint: Color {
    switch kind {
    case .defaultProfile: return .indigo
    case .host: return .blue
    case .preset: return .purple
    }
  }

  /// A host without settings of its own follows the Default Profile.
  var followsDefault: Bool {
    kind == .host && !SettingsModel.hasOwnSettings(id)
  }

  var modifiedAt: Date? {
    followsDefault ? nil : SettingsClass.profileModifiedAt(for: id)
  }

  /// What the profile is compared with: the Default Profile, or the built-in values for the
  /// Default Profile itself. Only shareable settings are compared.
  var differences: [ProfileDifference] {
    let values = SettingsProfileDifferences.Values(SettingsModel.profileSnapshot(of: id))
    let other = kind == .defaultProfile
      ? SettingsProfileDifferences.Values.builtIn
      : SettingsProfileDifferences.Values(SettingsModel.profileSnapshot(of: SettingsModel.globalHostId))
    return SettingsProfileDifferences.differences(values, from: other)
  }
}

/// The Setting Profiles page: every profile, and a profile's details one level down.
struct ProfilesSettingsPage: View {
  @SwiftUI.State private var openProfileId: String?
  // Moved by every change made here, so that what is read from the store is read again.
  @SwiftUI.State private var revision = 0

  var body: some View {
    Group {
      if let id = openProfileId, let entry = SettingsProfileEntry.find(id) {
        ProfileDetailView(
          entry: entry, revision: revision,
          onBack: { openProfileId = nil },
          onChange: { revision += 1 },
          onOpen: { openProfileId = $0 })
      } else {
        ProfilesListView(
          revision: revision,
          onOpen: { openProfileId = $0 },
          onChange: { revision += 1 })
      }
    }
    // A search result on this page is on the list.
    .onReceive(SettingsSearchNavigator.shared.$request) { request in
      if request?.pane == .profiles { openProfileId = nil }
    }
  }
}

// MARK: - List

private struct ProfilesListView: View {
  let revision: Int
  let onOpen: (String) -> Void
  let onChange: () -> Void
  @EnvironmentObject private var settingsModel: SettingsModel
  @ObservedObject private var languageManager = LanguageManager.shared
  @SwiftUI.State private var importError: String?

  var body: some View {
    let editingId = settingsModel.selectedHost?.id ?? SettingsModel.globalHostId
    let presets = SettingsProfileEntry.presets

    SettingsContent {
      SettingsPageHero(
        title: SettingsPaneType.profiles.titleKey,
        subtitle: SettingsPaneType.profiles.subtitleKey,
        symbol: SettingsPaneType.profiles.symbol,
        tint: SettingsPaneType.profiles.color
      )

      FormSection(title: "Hosts") {
        ForEach([SettingsProfileEntry.defaultProfile] + SettingsProfileEntry.hosts) { entry in
          ProfileListItem(entry: entry, isEditing: entry.id == editingId) { onOpen(entry.id) }
        }
      }

      FormSection(title: "Presets") {
        if presets.isEmpty {
          EmptyStateLine(symbol: "bookmark", textKey: "No Presets")
        }
        ForEach(presets) { entry in
          ProfileListItem(entry: entry, isEditing: false) { onOpen(entry.id) }
        }
      } accessory: {
        // settings-search: entry "Import Preset…"
        Button { importPreset() } label: {
          Label(languageManager.localize("Import Preset…"), systemImage: "square.and.arrow.down")
        }
        .controllerButtonStyle(.bordered)
        .controlSize(.small)
        .settingsSearchEntry("Import Preset…")
      }
    }
    .alert(
      languageManager.localize("Can’t Import Settings"),
      isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })
    ) {
      Button(languageManager.localize("OK"), role: .cancel) {}
    } message: {
      Text(importError ?? "")
    }
  }

  private func importPreset() {
    ProfileFilePanels.open { url in
      do {
        let file = try SettingsProfileFile.read(from: url)
        let name = file.profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let preset = SettingsModel.createPreset(
          named: name.isEmpty ? url.deletingPathExtension().lastPathComponent : name,
          with: file.snapshot)
        onChange()
        onOpen(preset.id)
      } catch {
        importError = SettingsProfileFile.message(for: error)
      }
    }
  }
}

/// One profile in the list: icon, name, status, how many settings differ. Opens its details.
private struct ProfileListItem: View {
  let entry: SettingsProfileEntry
  let isEditing: Bool
  let onOpen: () -> Void
  @ObservedObject private var languageManager = LanguageManager.shared

  var body: some View {
    let count = entry.differences.count
    Button(action: onOpen) {
      HStack(spacing: 10) {
        Image(systemName: entry.symbol)
          .foregroundStyle(entry.tint)
          .frame(width: 22)
        Text(verbatim: entry.name)
          .foregroundStyle(.primary)
          .lineLimit(1)
        if isEditing {
          Image(systemName: "pencil.circle.fill")
            .foregroundStyle(Color.accentColor)
            .help(languageManager.localize("Shown in the settings window"))
        }
        Spacer(minLength: 12)
        ProfileStatusBadge(entry: entry)
        DifferenceCountBadge(count: count, againstBuiltIn: entry.kind == .defaultProfile)
        Image(systemName: "chevron.right")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.tertiary)
      }
      .frame(minHeight: 40)
      .contentShape(Rectangle())
    }
    .controllerButtonStyle(.plain)
    .help(helpText)
    .overlay(alignment: .bottom) {
      Divider().opacity(0.45)
    }
  }
}

extension ProfileListItem {
  /// What the Default Profile is for, and when a profile last changed.
  fileprivate var helpText: String {
    let modified = entry.modifiedAt.map {
      String(format: languageManager.localize("Modified %@"), ProfileDates.text($0))
    }
    let parts = [entry.kind == .defaultProfile ? languageManager.localize("Used by new hosts") : nil, modified]
    return parts.compactMap { $0 }.joined(separator: " · ")
  }
}

/// "Default", "Uses Default", "Custom" or "Preset", as a small capsule.
private struct ProfileStatusBadge: View {
  let entry: SettingsProfileEntry
  @ObservedObject private var languageManager = LanguageManager.shared

  private var label: (key: String, tint: Color) {
    switch entry.kind {
    case .defaultProfile: return ("Default Badge", .indigo)
    case .preset: return ("Preset", .purple)
    case .host: return entry.followsDefault ? ("Uses Default", .gray) : ("Custom", .accentColor)
    }
  }

  var body: some View {
    let label = label
    Text(languageManager.localize(label.key))
      .font(.caption2.weight(.semibold))
      .foregroundStyle(label.tint)
      .padding(.horizontal, 7)
      .padding(.vertical, 2)
      .background(label.tint.opacity(0.15), in: Capsule())
      .fixedSize()
  }
}

/// "± 5": how many settings differ from the Default Profile (from the built-in values, for
/// the Default Profile itself).
private struct DifferenceCountBadge: View {
  let count: Int
  let againstBuiltIn: Bool
  @ObservedObject private var languageManager = LanguageManager.shared

  var body: some View {
    HStack(spacing: 3) {
      Image(systemName: "plusminus")
      Text("\(count)")
    }
    .font(.caption.monospacedDigit())
    .foregroundStyle(count == 0 ? .tertiary : .secondary)
    .frame(minWidth: 34, alignment: .trailing)
    .help(String(
      format: languageManager.localize(
        againstBuiltIn ? "Differ from Built-in %d" : "Differ from Default %d"),
      count))
  }
}

/// An empty state: a symbol and one short line.
private struct EmptyStateLine: View {
  let symbol: String
  let textKey: String
  var tint: Color = .secondary
  @ObservedObject private var languageManager = LanguageManager.shared

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: symbol)
        .foregroundStyle(tint)
      Text(languageManager.localize(textKey))
        .foregroundStyle(.secondary)
    }
    .font(.callout)
    .frame(maxWidth: .infinity, minHeight: 40)
  }
}

// MARK: - Details

private struct ProfileDetailView: View {
  // A page one level down: search cannot open a profile, so its parts are not indexed.
  // settings-search: ignore
  let entry: SettingsProfileEntry
  let revision: Int
  let onBack: () -> Void
  let onChange: () -> Void
  let onOpen: (String) -> Void
  @EnvironmentObject private var settingsModel: SettingsModel
  @ObservedObject private var languageManager = LanguageManager.shared
  @AppStorage("selected-settings-pane") private var selectedPane: SettingsPaneType = .stream
  @SwiftUI.State private var category: ProfileSettingCategory?
  @SwiftUI.State private var confirmation: ProfileConfirmation?
  @SwiftUI.State private var isConfirming = false
  @SwiftUI.State private var fileProblem: FileProblem?
  @SwiftUI.State private var nameRequest: PresetNameRequest?

  private var isDefault: Bool { entry.kind == .defaultProfile }
  private var isHost: Bool { entry.kind == .host }
  private var isPreset: Bool { entry.kind == .preset }

  var body: some View {
    let differences = entry.differences
    let overrides = isHost ? SettingsModel.perAppOverrides(for: entry.id) : []

    SettingsContent {
      Button(action: onBack) {
        Label(
          languageManager.localize(SettingsPaneType.profiles.titleKey), systemImage: "chevron.left")
      }
      .controllerButtonStyle(.borderless)

      ProfileHeaderCard(entry: entry)

      actionBar

      FormSection(title: isDefault ? "Compared with Built-in" : "Compared with Default") {
        ProfileDifferencesView(entry: entry, differences: differences, category: $category)
      }

      if !overrides.isEmpty {
        FormSection(title: "Per-App Settings") {
          ForEach(overrides) { item in
            PerAppOverrideLine(item: item) { confirmClear(item) }
          }
        }
      }
    }
    .alert(
      confirmation?.title ?? "", isPresented: $isConfirming, presenting: confirmation
    ) { confirmation in
      Button(languageManager.localize(confirmation.buttonKey), role: .destructive) {
        confirmation.action()
      }
      Button(languageManager.localize("Cancel"), role: .cancel) {}
    } message: { confirmation in
      if let key = confirmation.messageKey {
        Text(languageManager.localize(key))
      }
    }
    .background(
      Color.clear.alert(
        languageManager.localize(fileProblem?.titleKey ?? ""),
        isPresented: Binding(get: { fileProblem != nil }, set: { if !$0 { fileProblem = nil } })
      ) {
        Button(languageManager.localize("OK"), role: .cancel) {}
      } message: {
        Text(fileProblem?.message ?? "")
      })
    .sheet(item: $nameRequest) { request in
      PresetNameSheet(request: request) { name in
        request.onDone(name)
      }
    }
    .onChange(of: entry.id) { _ in category = nil }
  }

  // MARK: Actions

  private var actionBar: some View {
    HStack(spacing: 8) {
      if !isPreset {
        Button {
          settingsModel.selectHost(id: entry.id)
          selectedPane = .stream
        } label: {
          Label(languageManager.localize("Edit"), systemImage: "pencil")
        }
        .help(languageManager.localize("Edit these settings in the settings window"))
      }

      CopySourceMenu(destination: entry) { source in confirmCopy(from: source) }

      if !isPreset {
        Button { requestPresetName() } label: {
          Label(languageManager.localize("Save as Preset…"), systemImage: "bookmark")
        }
      }

      Spacer(minLength: 0)

      moreMenu
    }
    .controllerButtonStyle(.bordered)
  }

  private var moreMenu: some View {
    Menu {
      if !isDefault {
        Button(languageManager.localize("Use as Default Profile…")) { confirmUseAsDefault() }
      }
      Button(languageManager.localize("Export…")) { exportProfile() }
      Button(languageManager.localize("Import…")) { importProfile() }
      if (isHost && !entry.followsDefault) || isPreset {
        Divider()
      }
      if isHost && !entry.followsDefault {
        Button(languageManager.localize("Reset to Default Profile…")) { confirmReset() }
      }
      if isPreset {
        Button(languageManager.localize("Rename…")) { requestRename() }
        Button(languageManager.localize("Delete Preset…")) { confirmDeletePreset() }
      }
    } label: {
      Image(systemName: "ellipsis.circle")
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .help(languageManager.localize("More"))
    .controllerMenu { moreControllerMenu() }
  }

  /// The same choices for the controller menu panel.
  private func moreControllerMenu() -> (title: String, menu: NSMenu) {
    let title = languageManager.localize("More")
    let menu = NSMenu(title: title)
    menu.autoenablesItems = false
    func add(_ key: String, _ action: @escaping () -> Void) {
      menu.addItem(ControllerMenuBuilder.item(title: languageManager.localize(key), action: action))
    }
    if !isDefault { add("Use as Default Profile…") { confirmUseAsDefault() } }
    add("Export…") { exportProfile() }
    add("Import…") { importProfile() }
    if isHost && !entry.followsDefault { add("Reset to Default Profile…") { confirmReset() } }
    if isPreset {
      add("Rename…") { requestRename() }
      add("Delete Preset…") { confirmDeletePreset() }
    }
    return (title: title, menu: menu)
  }

  /// Said where a host's own addresses and display choices could seem at stake.
  private var hostSpecificNote: String? {
    isHost ? "Host-specific settings are kept." : nil
  }

  private func confirm(
    title: String, messageKey: String?, buttonKey: String, action: @escaping () -> Void
  ) {
    confirmation = ProfileConfirmation(
      title: title, messageKey: messageKey, buttonKey: buttonKey, action: action)
    isConfirming = true
  }

  private func titled(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: languageManager.localize(key), arguments: arguments)
  }

  /// Runs a change of a profile's settings, and shows it.
  private func change(_ profileId: String, _ body: () -> Void) {
    settingsModel.changeProfile(profileId, body)
    onChange()
  }

  private func confirmCopy(from source: SettingsProfileEntry) {
    confirm(
      title: titled("Copy Profile Title %1$@ %2$@", entry.name, source.name),
      messageKey: hostSpecificNote, buttonKey: "Copy Profile Button"
    ) {
      change(entry.id) { SettingsModel.copyProfileSettings(from: source.id, to: entry.id) }
    }
  }

  private func confirmUseAsDefault() {
    confirm(
      title: titled("Use as Default Title %@", entry.name),
      messageKey: "New hosts will start with these settings.", buttonKey: "Use as Default"
    ) {
      change(SettingsModel.globalHostId) {
        SettingsModel.copyProfileSettings(from: entry.id, to: SettingsModel.globalHostId)
      }
    }
  }

  private func confirmReset() {
    confirm(
      title: titled("Reset Profile Title %@", entry.name),
      messageKey: hostSpecificNote, buttonKey: "Reset"
    ) {
      change(entry.id) { SettingsModel.resetProfileToDefault(entry.id) }
    }
  }

  private func confirmDeletePreset() {
    confirm(
      title: titled("Delete Title %@", entry.name),
      messageKey: nil, buttonKey: "Delete"
    ) {
      SettingsModel.deletePreset(entry.id)
      onChange()
      onBack()
    }
  }

  private func confirmClear(_ item: PerAppOverride) {
    confirm(
      title: titled("Clear App Settings Title %@", item.appName ?? item.appId),
      messageKey: nil, buttonKey: "Clear"
    ) {
      SettingsModel.clearPerAppOverride(item)
      onChange()
    }
  }

  private func requestPresetName() {
    nameRequest = PresetNameRequest(
      titleKey: "New Preset", confirmKey: "Create", initialName: entry.name
    ) { name in
      guard let snapshot = SettingsModel.profileSnapshot(of: entry.id) else { return }
      let preset = SettingsModel.createPreset(named: name, with: snapshot)
      onChange()
      onOpen(preset.id)
    }
  }

  private func requestRename() {
    nameRequest = PresetNameRequest(
      titleKey: "Rename Preset", confirmKey: "Rename", initialName: entry.name
    ) { name in
      SettingsModel.renamePreset(entry.id, to: name)
      onChange()
    }
  }

  private func exportProfile() {
    guard let snapshot = SettingsModel.profileSnapshot(of: entry.id) else { return }
    ProfileFilePanels.save(suggestedName: entry.name) { url in
      do {
        try SettingsProfileFile(profileName: entry.name, snapshot: snapshot).write(to: url)
      } catch {
        fileProblem = FileProblem(
          titleKey: "Can’t Export Settings", message: error.localizedDescription)
      }
    }
  }

  private func importProfile() {
    ProfileFilePanels.open { url in
      do {
        let file = try SettingsProfileFile.read(from: url)
        confirm(
          title: titled("Copy Profile Title %1$@ %2$@", entry.name, url.lastPathComponent),
          messageKey: hostSpecificNote, buttonKey: "Copy Profile Button"
        ) {
          change(entry.id) { SettingsModel.apply(file.snapshot, to: entry.id) }
        }
      } catch {
        fileProblem = FileProblem(
          titleKey: "Can’t Import Settings", message: SettingsProfileFile.message(for: error))
      }
    }
  }
}

/// The top of a profile's details: icon, name, status, and where its settings come from.
private struct ProfileHeaderCard: View {
  let entry: SettingsProfileEntry
  @ObservedObject private var languageManager = LanguageManager.shared

  var body: some View {
    HStack(alignment: .center, spacing: 14) {
      Image(systemName: entry.symbol)
        .font(.system(size: 24, weight: .medium))
        .foregroundStyle(entry.tint)
        .frame(width: 52, height: 52)
        .background(
          entry.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 8) {
          Text(verbatim: entry.name)
            .font(.title2.weight(.semibold))
            .lineLimit(1)
          ProfileStatusBadge(entry: entry)
        }
        lineage
      }

      Spacer(minLength: 0)
    }
    .padding(14)
    .background(
      Color(nsColor: .controlBackgroundColor),
      in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }

  /// Default Profile 🔗 → Living Room PC; a branch for a host with settings of its own.
  @ViewBuilder
  private var lineage: some View {
    switch entry.kind {
    case .host:
      HStack(spacing: 6) {
        ProfileNameChip(name: languageManager.localize("Default Profile"), tint: .indigo)
        Image(systemName: entry.followsDefault ? "link" : "arrow.triangle.branch")
          .foregroundStyle(entry.followsDefault ? Color.accentColor : .secondary)
        Image(systemName: "arrow.right")
          .font(.caption)
          .foregroundStyle(.tertiary)
        ProfileNameChip(name: entry.name, tint: entry.tint)
      }
      .help(languageManager.localize(
        entry.followsDefault ? "Uses the Default Profile" : "Has settings of its own"))
    case .defaultProfile:
      let users = SettingsProfileEntry.hosts.filter(\.followsDefault).count
      HStack(spacing: 10) {
        Label(languageManager.localize("Used by new hosts"), systemImage: "sparkles")
        if users > 0 {
          Label("\(users)", systemImage: "link")
            .help(String(format: languageManager.localize("Hosts using Default %d"), users))
        }
      }
      .font(.callout.monospacedDigit())
      .foregroundStyle(.secondary)
    case .preset:
      Label(languageManager.localize("Shareable settings only"), systemImage: "square.on.square")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
  }
}

private struct ProfileNameChip: View {
  let name: String
  let tint: Color

  var body: some View {
    Text(verbatim: name)
      .font(.caption.weight(.medium))
      .lineLimit(1)
      .padding(.horizontal, 7)
      .padding(.vertical, 2)
      .background(tint.opacity(0.13), in: Capsule())
  }
}

/// Category tiles with their counts, and below them the settings that differ, as a small
/// table: setting, this profile's value, the other value.
private struct ProfileDifferencesView: View {
  let entry: SettingsProfileEntry
  let differences: [ProfileDifference]
  @Binding var category: ProfileSettingCategory?
  @ObservedObject private var languageManager = LanguageManager.shared

  private var shown: [ProfileDifference] {
    guard let category else { return differences }
    return differences.filter { $0.category == category }
  }

  var body: some View {
    if differences.isEmpty {
      EmptyStateLine(
        symbol: "checkmark.circle.fill",
        textKey: entry.kind == .defaultProfile ? "Same as Built-in" : "Same as Default",
        tint: .green)
    } else {
      VStack(alignment: .leading, spacing: 10) {
        tiles
        table
      }
      .padding(.vertical, 10)
    }
  }

  private var tiles: some View {
    let counts = Dictionary(grouping: differences, by: \.category).mapValues(\.count)
    let present = ProfileSettingCategory.allCases.filter { counts[$0] != nil }
    return LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
      ForEach(present, id: \.self) { item in
        CategoryTile(category: item, count: counts[item] ?? 0, isSelected: category == item) {
          category = category == item ? nil : item
        }
      }
    }
  }

  private var table: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Text(languageManager.localize("Setting"))
          .frame(maxWidth: .infinity, alignment: .leading)
        Text(verbatim: entry.name)
          .lineLimit(1)
          .frame(width: 160, alignment: .leading)
        Text(languageManager.localize(
          entry.kind == .defaultProfile ? "Built-in" : "Default Profile"))
          .lineLimit(1)
          .frame(width: 160, alignment: .leading)
      }
      .font(.caption.weight(.semibold))
      .foregroundStyle(.secondary)
      .padding(.vertical, 5)
      .overlay(alignment: .bottom) { Divider().opacity(0.45) }

      ForEach(shown) { difference in
        HStack(spacing: 10) {
          Text(languageManager.localize(difference.titleKey))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
          ValueChip(text: difference.value, emphasized: true)
            .frame(width: 160, alignment: .leading)
          ValueChip(text: difference.otherValue, emphasized: false)
            .frame(width: 160, alignment: .leading)
        }
        .padding(.vertical, 5)
        .overlay(alignment: .bottom) { Divider().opacity(0.3) }
      }
    }
  }
}

private struct CategoryTile: View {
  let category: ProfileSettingCategory
  let count: Int
  let isSelected: Bool
  let onSelect: () -> Void
  @ObservedObject private var languageManager = LanguageManager.shared

  var body: some View {
    Button(action: onSelect) {
      VStack(spacing: 4) {
        HStack(spacing: 5) {
          Image(systemName: category.symbol)
            .foregroundStyle(category.tint)
          Text("\(count)")
            .font(.title3.weight(.semibold).monospacedDigit())
            .foregroundStyle(.primary)
        }
        Text(languageManager.localize(category.titleKey))
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 8)
      .background(
        Color(nsColor: .windowBackgroundColor),
        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .strokeBorder(
            isSelected ? Color.accentColor : Color.secondary.opacity(0.18),
            lineWidth: isSelected ? 2 : 1))
      .contentShape(Rectangle())
    }
    .controllerButtonStyle(.plain)
  }
}

/// A value in the comparison table; this profile's value is emphasized.
private struct ValueChip: View {
  let text: String
  let emphasized: Bool

  var body: some View {
    Text(verbatim: text)
      .font(.callout)
      .lineLimit(1)
      .truncationMode(.middle)
      .foregroundStyle(emphasized ? Color.accentColor : Color.secondary)
      .padding(.horizontal, 8)
      .padding(.vertical, 2)
      .background(
        emphasized ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.1),
        in: Capsule())
      .help(text)
  }
}

/// One app's own display choices on a host, as chips, with a button that clears them.
private struct PerAppOverrideLine: View {
  let item: PerAppOverride
  let onClear: () -> Void
  @ObservedObject private var languageManager = LanguageManager.shared

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "app.fill")
        .foregroundStyle(.secondary)
      Text(verbatim: item.appName ?? item.appId)
        .lineLimit(1)
      Spacer(minLength: 12)
      if let display = item.displayName {
        chip(
          "display", display.isEmpty ? languageManager.localize("Host Default") : display,
          "Target Display")
      }
      if let mode = item.screenMode {
        chip(
          "rectangle.on.rectangle",
          languageManager.localize(SettingsModel.sunshineScreenModeSelection(for: mode)),
          "Screen Mode")
      }
      if let virtual = item.useVirtualDisplay {
        chip("display.2", languageManager.localize(virtual ? "On" : "Off"), "Use Virtual Display")
      }
      Button(action: onClear) {
        Image(systemName: "xmark.circle.fill")
          .foregroundStyle(.secondary)
      }
      .controllerButtonStyle(.borderless)
      .help(languageManager.localize("Clear"))
    }
    .frame(minHeight: 36)
    .overlay(alignment: .bottom) { Divider().opacity(0.45) }
  }

  private func chip(_ symbol: String, _ text: String, _ helpKey: String) -> some View {
    Label(text, systemImage: symbol)
      .font(.caption)
      .lineLimit(1)
      .padding(.horizontal, 7)
      .padding(.vertical, 2)
      .background(Color.secondary.opacity(0.1), in: Capsule())
      .help(languageManager.localize(helpKey))
  }
}

/// "Copy Settings": the profiles whose settings can be copied into `destination`, as a
/// pull-down button. The Default Profile first, then hosts and presets under their headers.
private struct CopySourceMenu: View {
  let destination: SettingsProfileEntry
  let onChoose: (SettingsProfileEntry) -> Void
  @ObservedObject private var languageManager = LanguageManager.shared

  private struct SourceGroup {
    let headerKey: String?
    let entries: [SettingsProfileEntry]
  }

  private var groups: [SourceGroup] {
    [
      SourceGroup(headerKey: nil, entries: [.defaultProfile]),
      SourceGroup(headerKey: "Hosts", entries: SettingsProfileEntry.hosts),
      SourceGroup(headerKey: "Presets", entries: SettingsProfileEntry.presets),
    ]
    .map { group in
      SourceGroup(headerKey: group.headerKey, entries: group.entries.filter {
        $0.id != destination.id && SettingsModel.profileSnapshot(of: $0.id) != nil
      })
    }
    .filter { !$0.entries.isEmpty }
  }

  var body: some View {
    let groups = groups
    Menu {
      ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
        if index > 0 { Divider() }
        if let headerKey = group.headerKey {
          // A disabled item: the section header of a menu on every macOS version.
          Text(languageManager.localize(headerKey))
        }
        ForEach(group.entries) { source in
          Button { onChoose(source) } label: {
            Label(itemTitle(source), systemImage: source.symbol)
          }
        }
      }
    } label: {
      Label(languageManager.localize("Copy Settings"), systemImage: "doc.on.doc")
    }
    .fixedSize()
    .disabled(groups.isEmpty)
    .controllerMenu { controllerMenu(groups) }
  }

  /// "Copy from Gaming PC".
  private func itemTitle(_ source: SettingsProfileEntry) -> String {
    source.kind == .defaultProfile
      ? languageManager.localize("Copy from Default Profile")
      : String(format: languageManager.localize("Copy from %@"), source.name)
  }

  private func controllerMenu(_ groups: [SourceGroup]) -> (title: String, menu: NSMenu) {
    let title = languageManager.localize("Copy Settings")
    let menu = NSMenu(title: title)
    menu.autoenablesItems = false
    for (index, group) in groups.enumerated() {
      if index > 0 { menu.addItem(NSMenuItem.separator()) }
      if let headerKey = group.headerKey {
        let header = languageManager.localize(headerKey)
        if #available(macOS 14.0, *) {
          menu.addItem(NSMenuItem.sectionHeader(title: header))
        } else {
          menu.addItem(ControllerMenuBuilder.item(title: header, enabled: false) {})
        }
      }
      for source in group.entries {
        let item = ControllerMenuBuilder.item(title: itemTitle(source)) { onChoose(source) }
        item.image = NSImage(systemSymbolName: source.symbol, accessibilityDescription: nil)
        menu.addItem(item)
      }
    }
    return (title: title, menu: menu)
  }
}

/// The confirmation shown before a profile's settings are replaced or removed: a short title
/// and one short sentence.
private struct ProfileConfirmation {
  let title: String
  let messageKey: String?
  let buttonKey: String
  let action: () -> Void
}

private struct FileProblem {
  let titleKey: String
  let message: String
}

// MARK: - Preset name

private struct PresetNameRequest: Identifiable {
  let id = UUID()
  let titleKey: String
  let confirmKey: String
  let initialName: String
  let onDone: (String) -> Void
}

private struct PresetNameSheet: View {
  let request: PresetNameRequest
  let onDone: (String) -> Void
  @ObservedObject private var languageManager = LanguageManager.shared
  @Environment(\.dismiss) private var dismiss
  @SwiftUI.State private var name = ""

  private var trimmedName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(languageManager.localize(request.titleKey))
        .font(.headline)
      TextField(languageManager.localize("Name"), text: $name)
        .textFieldStyle(.roundedBorder)
        .frame(width: 280)
      HStack {
        Spacer()
        Button(languageManager.localize("Cancel"), role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(languageManager.localize(request.confirmKey)) {
          onDone(trimmedName)
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(trimmedName.isEmpty)
      }
    }
    .padding(20)
    .onAppear { name = request.initialName }
  }
}

// MARK: - Files and dates

private enum ProfileFilePanels {
  static func save(suggestedName: String, _ completion: @escaping (URL) -> Void) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = suggestedName + ".json"
    run(panel) { completion($0) }
  }

  static func open(_ completion: @escaping (URL) -> Void) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    run(panel) { completion($0) }
  }

  private static func run(_ panel: NSSavePanel, _ completion: @escaping (URL) -> Void) {
    let finish: (NSApplication.ModalResponse) -> Void = { response in
      guard response == .OK, let url = panel.url else { return }
      completion(url)
    }
    if let window = NSApp.keyWindow {
      panel.beginSheetModal(for: window, completionHandler: finish)
    } else {
      finish(panel.runModal())
    }
  }
}

enum ProfileDates {
  /// A date in the language the app is shown in.
  static func text(_ date: Date) -> String {
    let formatter = DateFormatter()
    switch LanguageManager.shared.currentLanguage {
    case .chinese: formatter.locale = Locale(identifier: "zh-Hans")
    case .english: formatter.locale = Locale(identifier: "en")
    case .system: formatter.locale = .current
    }
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter.string(from: date)
  }
}
