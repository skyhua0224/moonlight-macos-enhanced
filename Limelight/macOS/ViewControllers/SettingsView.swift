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

  static var allCases: [SettingsPaneType] {
    [.stream, .video, .audio, .input, .app]
  }

  var title: String {
    switch self {
    case .stream:
      return "Stream"
    case .video:
      return "Video"
    case .audio:
      return "Audio"
    case .input:
      return "Input"
    case .app:
      return "App"
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
    case .audio:
      return "speaker.wave.2.fill"
    case .input:
      return "keyboard.fill"
    case .app:
      return "appclip"
    case .legacy:
      return "archivebox.fill"
    }
  }

  var color: Color {
    switch self {
    case .stream:
      return .blue
    case .video:
      return .orange
    case .audio:
      return Color(hex: 0x2FA7A0)
    case .input:
      return .purple
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
    NavigationView {
      Sidebar(selectedPane: $selectedPane)
      Detail(pane: selectedPane)
        .environmentObject(settingsModel)
    }
    .frame(minWidth: 575, minHeight: 275)
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
}

struct Sidebar: View {
  @Binding var selectedPane: SettingsPaneType
  @ObservedObject var languageManager = LanguageManager.shared

  var body: some View {
    // This "selectionBinding" is needed to make selection work with a macOS 11 Big Sur compatible List() constructor
    let selectionBinding = Binding<SettingsPaneType?>(
      get: {
        selectedPane
      },
      set: { newValue in
        if let newPane = newValue {
          selectedPane = newPane
        }
      })

    List(SettingsPaneType.allCases, id: \.self, selection: selectionBinding) { pane in
      PaneCellView(pane: pane)
    }
    .listStyle(.sidebar)
    .frame(minWidth: 160)
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
      case .audio:
        SettingPaneLoader(settingsModel) {
          AudioView()
        }
      case .input:
        SettingPaneLoader(settingsModel) {
          InputView()
        }
      case .app:
        SettingPaneLoader(settingsModel) {
          AppView()
        }
      case .legacy:
        EmptyView()
      }
    }
    .environmentObject(settingsModel)
    .navigationTitle(languageManager.localize(effectivePane.title))
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
    let iconSize = CGFloat(14)
    let containerSize = iconSize + (iconSize / 3)

    HStack(spacing: 6) {
      Image(systemName: pane.symbol)
        .adaptiveForegroundColor(.white)
        .font(.callout)
        .frame(width: containerSize, height: containerSize)
        .padding(1)
        .background(
          RoundedRectangle(cornerRadius: 5, style: .continuous)
            .foregroundColor(pane.color)
        )

      Text(languageManager.localize(pane.title))
    }
  }
}
