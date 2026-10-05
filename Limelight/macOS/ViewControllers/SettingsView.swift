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

enum SettingsPaneType: Int, CaseIterable {
  // NOTE: Raw values are pinned to keep backward compatibility with persisted selection.
  case stream = 0
  case video = 1
  case audio = 5
  case input = 2
  case app = 3
  case legacy = 4
  case display = 6
  case keyboard = 7
  case usb = 8

  static var allCases: [SettingsPaneType] {
    [.stream, .display, .video, .audio, .input, .keyboard, .usb, .app]
  }

  var title: String {
    switch self {
    case .stream:
      return "Streaming"
    case .video:
      return "Video"
    case .display:
      return "Display & HDR"
    case .audio:
      return "Audio & Microphone"
    case .input:
      return "Controller"
    case .keyboard:
      return "Keyboard & Mouse"
    case .usb:
      return "USB Devices"
    case .app:
      return "App & Diagnostics"
    case .legacy:
      return "Legacy"
    }
  }

  var symbol: String {
    switch self {
    case .stream:
      return "airplayvideo"
    case .video:
      return "video.fill"
    case .display:
      return "display.2"
    case .audio:
      return "speaker.wave.2.fill"
    case .input:
      return "gamecontroller.fill"
    case .keyboard:
      return "keyboard.fill"
    case .usb:
      return "cable.connector.horizontal"
    case .app:
      return "gearshape.2.fill"
    case .legacy:
      return "archivebox.fill"
    }
  }

  var subtitleKey: String {
    switch self {
    case .stream:
      return "Streaming settings subtitle"
    case .display:
      return "Display settings subtitle"
    case .video:
      return "Video settings subtitle"
    case .audio:
      return "Audio settings subtitle"
    case .input:
      return "Controller settings subtitle"
    case .keyboard:
      return "Keyboard and mouse settings subtitle"
    case .usb:
      return "USB settings subtitle"
    case .app:
      return "App diagnostics settings subtitle"
    case .legacy:
      return "App diagnostics settings subtitle"
    }
  }

  var color: Color {
    switch self {
    case .stream:
      return .blue
    case .video:
      return .orange
    case .display:
      return .cyan
    case .audio:
      return Color(hex: 0x2FA7A0)
    case .input:
      return .purple
    case .keyboard:
      return .indigo
    case .usb:
      return .teal
    case .app:
      return .pink
    case .legacy:
      return Color(hex: 0x65B741)
    }
  }
}


extension Color {
  init(hex: Int, opacity: Double = 1) {
    self.init(
      .sRGB,
      red: Double((hex >> 16) & 0xff) / 255,
      green: Double((hex >> 08) & 0xff) / 255,
      blue: Double((hex >> 00) & 0xff) / 255,
      opacity: opacity
    )
  }
}

struct SettingsView: View {
  @StateObject var settingsModel = SettingsModel()
  @ObservedObject var languageManager = LanguageManager.shared

  @AppStorage("selected-settings-pane") private var selectedPane: SettingsPaneType = .stream

  var hostId: String?

  init(hostId: String? = nil) {
    self.hostId = hostId
  }

  var body: some View {
    settingsNavigation
    .frame(minWidth: 1060, minHeight: 720)
    .toolbar {
      ToolbarItem(placement: .automatic) {
        SettingsProfilePicker(settingsModel: settingsModel)
      }
    }
    .onAppear {
      if selectedPane == .legacy {
        selectedPane = .app
      }

      if let hostId {
        settingsModel.selectHost(id: hostId)
      } else {
        settingsModel.selectHost(id: SettingsModel.globalHostId)
      }
    }
  }

  @ViewBuilder
  private var settingsNavigation: some View {
    if #available(macOS 13.0, *) {
      ModernSettingsNavigation(
        selectedPane: $selectedPane,
        settingsModel: settingsModel
      )
    } else {
      NavigationView {
        Sidebar(selectedPane: $selectedPane, settingsModel: settingsModel)
        Detail(pane: selectedPane)
          .environmentObject(settingsModel)
      }
    }
  }
}

@available(macOS 13.0, *)
private struct ModernSettingsNavigation: View {
  @Binding var selectedPane: SettingsPaneType
  @ObservedObject var settingsModel: SettingsModel
  @State private var columnVisibility: NavigationSplitViewVisibility = .all

  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      Sidebar(selectedPane: $selectedPane, settingsModel: settingsModel)
    } detail: {
      Detail(pane: selectedPane)
        .environmentObject(settingsModel)
    }
    .navigationSplitViewStyle(.balanced)
    .navigationSplitViewColumnWidth(min: 280, ideal: 300, max: 340)
    .onChange(of: columnVisibility) { visibility in
      if visibility != .all {
        columnVisibility = .all
      }
    }
  }
}

struct Sidebar: View {
  @Binding var selectedPane: SettingsPaneType
  @ObservedObject var settingsModel: SettingsModel
  @ObservedObject var languageManager = LanguageManager.shared
  @State private var searchText = ""

  private let orderedPanes: [SettingsPaneType] = [
    .stream, .display, .video, .audio, .input, .keyboard, .usb, .app
  ]

  private func matches(_ pane: SettingsPaneType) -> Bool {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return true }
    let title = languageManager.localize(pane.title)
    let subtitle = languageManager.localize(pane.subtitleKey)
    return title.localizedCaseInsensitiveContains(query)
      || subtitle.localizedCaseInsensitiveContains(query)
  }

  private var visiblePanes: [SettingsPaneType] { orderedPanes.filter(matches) }

  var body: some View {
    // Keep selection explicit so the sidebar remains stable across macOS releases.
    let selectionBinding = Binding<SettingsPaneType?>(
      get: {
        selectedPane
      },
      set: { newValue in
        if let newPane = newValue {
          selectedPane = newPane
        }
      })

    VStack(spacing: 0) {
      SettingsSearchField(text: $searchText)
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 8)

      Divider()

      List(selection: selectionBinding) {
        Section {
          ForEach(visiblePanes, id: \.self) { pane in
            PaneCellView(pane: pane).tag(pane)
          }
        }

        if visiblePanes.isEmpty {
          Text(languageManager.localize("No matching settings"))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .listRowBackground(Color.clear)
          }
      }
      .listStyle(.sidebar)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(minWidth: 280, idealWidth: 300)
    .navigationTitle(languageManager.localize("Settings"))
  }
}

private struct SettingsSearchField: View {
  @Binding var text: String
  @ObservedObject private var languageManager = LanguageManager.shared

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)
      TextField(languageManager.localize("Search Settings"), text: $text)
        .textFieldStyle(.plain)
      if !text.isEmpty {
        Button {
          text = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
  }
}

private struct SettingsProfilePicker: View {
  @ObservedObject var settingsModel: SettingsModel
  @ObservedObject var languageManager = LanguageManager.shared

  private var selectedHostBinding: Binding<Host?> {
    Binding(
      get: { settingsModel.selectedHost },
      set: { settingsModel.selectedHost = $0 }
    )
  }

  var body: some View {
    Picker(selection: selectedHostBinding) {
      ForEach(SettingsModel.hosts ?? [], id: \.self) { host in
        if let host {
          Text(host.id == SettingsModel.globalHostId
            ? languageManager.localize("Default Profile")
            : host.name)
            .tag(Optional(host))
        }
      }
    } label: {
      Label(languageManager.localize("Settings Profile"), systemImage: "person.crop.circle")
    }
    .pickerStyle(.menu)
    .help(languageManager.localize("Settings Profile"))
  }
}

struct Detail: View {
  var pane: SettingsPaneType

  @EnvironmentObject private var settingsModel: SettingsModel
  @ObservedObject var languageManager = LanguageManager.shared

  private var effectivePane: SettingsPaneType {
    pane == .legacy ? .app : pane
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      SettingsPageHeader(pane: effectivePane)
      Divider()

      Group {
        switch effectivePane {
      case .stream:
        SettingPaneLoader(settingsModel) {
          StreamView()
        }
      case .video:
        SettingPaneLoader(settingsModel) {
          VideoView()
        }
      case .display:
        SettingPaneLoader(settingsModel) {
          FoundationDisplayView()
        }
      case .audio:
        SettingPaneLoader(settingsModel) {
          AudioView()
        }
      case .input:
        SettingPaneLoader(settingsModel) {
          InputView(scope: .controller)
        }
      case .keyboard:
        SettingPaneLoader(settingsModel) {
          InputView(scope: .keyboardMouse)
        }
      case .usb:
        SettingPaneLoader(settingsModel) {
          InputView(scope: .usb)
        }
      case .app:
        SettingPaneLoader(settingsModel) {
          AppView()
        }
      case .legacy:
        EmptyView()
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .frame(maxWidth: 760, maxHeight: .infinity, alignment: .top)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .environmentObject(settingsModel)
    .navigationTitle("")
  }
}

private struct SettingsPageHeader: View {
  let pane: SettingsPaneType
  @ObservedObject private var languageManager = LanguageManager.shared

  @ViewBuilder
  var body: some View {
    switch pane {
    case .stream, .audio, .keyboard:
      HStack {
        Text(languageManager.localize(pane.title))
          .font(.title2.weight(.semibold))
        Spacer()
      }
      .padding(.horizontal, 24)
      .padding(.vertical, 14)
    case .usb:
      HStack(alignment: .center, spacing: 12) {
        Image(systemName: pane.symbol)
          .symbolRenderingMode(.hierarchical)
          .foregroundStyle(pane.color)
          .font(.system(size: 20, weight: .semibold))
          .frame(width: 38, height: 38)
          .background(pane.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
        VStack(alignment: .leading, spacing: 3) {
          Text(languageManager.localize(pane.title))
            .font(.title3.weight(.semibold))
          Text(languageManager.localize(pane.subtitleKey))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer()
      }
      .padding(.horizontal, 24)
      .padding(.vertical, 14)
    default:
      HStack(alignment: .center, spacing: 14) {
      Image(systemName: pane.symbol)
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(pane.color)
        .font(.system(size: 24, weight: .semibold))
        .frame(width: 48, height: 48)
        .background(pane.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))

      VStack(alignment: .leading, spacing: 3) {
        Text(languageManager.localize(pane.title))
          .font(.title2.weight(.semibold))
        Text(languageManager.localize(pane.subtitleKey))
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
      }
      .padding(.horizontal, 24)
      .padding(.vertical, 16)
    }
  }
}

struct SettingPaneLoader<Content: View>: View {
  let settingsModel: SettingsModel
  let content: Content

  init(_ settingsModel: SettingsModel, @ViewBuilder content: () -> Content) {
    self.settingsModel = settingsModel
    self.content = content()
  }

  var body: some View {
    content
      .onAppear {
        settingsModel.ensureSettingsLoadedIfNeeded()
      }
  }
}

struct PaneCellView: View {
  let pane: SettingsPaneType
  @ObservedObject var languageManager = LanguageManager.shared

  var body: some View {
    Label {
      Text(languageManager.localize(pane.title))
        .lineLimit(1)
    } icon: {
      Image(systemName: pane.symbol)
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(pane.color)
        .imageScale(.medium)
        .frame(width: 22, height: 22, alignment: .center)
    }
    .labelStyle(.titleAndIcon)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
  }
}
