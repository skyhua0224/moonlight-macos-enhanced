//
//  SettingsView.swift
//  Moonlight for macOS
//
//  Created by Michael Kenny on 15/1/2024.
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

import SwiftUI

enum SettingsPaneType: Int, CaseIterable {
  case stream
  case videoAndAudio
  case input
  case app
  case legacy

  var title: LocalizedStringKey {
    switch self {
    case .stream:
      return "Stream"
    case .videoAndAudio:
      return "Video and Audio"

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
    case .videoAndAudio:
      return "video.fill"
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
    case .videoAndAudio:
      return .orange
    case .input:
      return .purple
    case .app:
      return .pink
    case .legacy:
      return Color(hex: 0x65B741)
    }
  }
}

// From: https://medium.com/@jakir/use-hex-color-in-swiftui-c19e6ab79220
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

  @AppStorage("selected-settings-pane") private var selectedPane: SettingsPaneType = .stream

  var body: some View {
    NavigationView {
      Sidebar(selectedPane: $selectedPane)
      Detail(pane: selectedPane)
        .environmentObject(settingsModel)
    }
    .frame(minWidth: 575, minHeight: 275)
  }
}

struct Sidebar: View {
  @Binding var selectedPane: SettingsPaneType

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

  var body: some View {
    Group {
      switch pane {
      case .stream:
        SettingPaneLoader(settingsModel) {
          StreamView()
        }
      case .videoAndAudio:
        SettingPaneLoader(settingsModel) {
          VideoAndAudioView()
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
        SettingPaneLoader(settingsModel) {
          LegacyView()
        }
      }
    }
    .environmentObject(settingsModel)
    .navigationSubtitle(Text(pane.title))
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        if let hosts = SettingsModel.hosts {
          HStack {
            Text("Profile:")

            Picker("", selection: $settingsModel.selectedHost) {
              ForEach(hosts, id: \.self) { host in
                if let host {
                  Text(host.name)
                }
              }
            }
          }
        }
      }
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
        settingsModel.loadSettings()
      }
  }
}

struct PaneCellView: View {
  let pane: SettingsPaneType

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

      Text(pane.title)
    }
  }
}

struct StreamView: View {
  @EnvironmentObject private var settingsModel: SettingsModel

  @SwiftUI.State private var showCustomResolutionGroup = false
  @SwiftUI.State private var showCustomFpsGroup = false

  var body: some View {
    ScrollView {
      VStack {
        FormSection(title: "Resolution and FPS") {
          FormCell(
            title: "Resolution", contentWidth: 100,
            content: {
              Picker("", selection: $settingsModel.selectedResolution) {
                ForEach(SettingsModel.resolutions, id: \.self) { resolution in
                  if resolution == .zero {
                    Text("Custom")
                  } else {
                    Text(verbatim: resolution.height == 2160 ? "4K" : "\(Int(resolution.height))p")
                  }
                }
              }
            })

          if showCustomResolutionGroup {
            Divider()

            FormCell(
              title: "Custom Resolution", contentWidth: 0,
              content: {
                DimensionsInputView(
                  widthBinding: $settingsModel.customResWidth,
                  heightBinding: $settingsModel.customResHeight,
                  placeholderDimensions: CGSize(width: 3440, height: 1440))
              })
          }

          Divider()

          FormCell(
            title: "FPS", contentWidth: 100,
            content: {
              Picker("", selection: $settingsModel.selectedFps) {
                ForEach(SettingsModel.fpss, id: \.self) { fps in
                  if fps == .zero {
                    Text("Custom")
                  } else {
                    Text("\(fps)")
                  }
                }
              }
            })

          if showCustomFpsGroup {
            Divider()

            FormCell(
              title: "Custom FPS", contentWidth: 0,
              content: {
                TextField("40", value: $settingsModel.customFps, formatter: NumberOnlyFormatter())
                  .multilineTextAlignment(.trailing)
                  .textFieldStyle(.plain)
                  .fixedSize()
              })
          }
        }

        Spacer()
          .frame(height: 32)

        FormSection(title: "Bitrate") {
          VStack(alignment: .leading) {
            let bitrate = Int(SettingsModel.bitrateSteps[Int(settingsModel.bitrateSliderValue)])
            Text("\(bitrate) Mbps")
              .availableMonospacedDigit()
            Slider(
              value: $settingsModel.bitrateSliderValue,
              in: 0...Float(SettingsModel.bitrateSteps.count - 1), step: 1)
          }
        }
      }
      .padding()
      .onAppear {
        func updateCustomResolutionGroup() {
          showCustomResolutionGroup = settingsModel.selectedResolution == .zero
        }
        func updateCustomFpsGroup() {
          showCustomFpsGroup = settingsModel.selectedFps == .zero
        }

        updateCustomResolutionGroup()
        updateCustomFpsGroup()
        settingsModel.resolutionChangedCallback = {
          withAnimation {
            updateCustomResolutionGroup()
          }
        }
        settingsModel.fpsChangedCallback = {
          withAnimation {
            updateCustomFpsGroup()
          }
        }
      }
    }
  }
}

struct VideoAndAudioView: View {
  @EnvironmentObject private var settingsModel: SettingsModel

  var body: some View {
    ScrollView {
      VStack {
        FormSection(title: "Video") {
          FormCell(
            title: "Video Codec", contentWidth: 155,
            content: {
              Picker("", selection: $settingsModel.selectedVideoCodec) {
                ForEach(SettingsModel.videoCodecs, id: \.self) { codec in
                  Text(LocalizedStringKey(codec))
                }
              }
            })

          Divider()

          ToggleCell(title: "HDR", boolBinding: $settingsModel.hdr)

          Divider()

          FormCell(
            title: "Frame Pacing", contentWidth: 155,
            content: {
              Picker("", selection: $settingsModel.selectedPacingOptions) {
                ForEach(SettingsModel.pacingOptions, id: \.self) { pacingOption in
                  Text(LocalizedStringKey(pacingOption))
                }
              }
            })
        }

        Spacer()
          .frame(height: 32)

        FormSection(title: "Audio") {
          ToggleCell(title: "Play Sound on Host", boolBinding: $settingsModel.audioOnPC)

          Divider()

          VStack(alignment: .center) {
            Text("Volume")

            let volume = Int(settingsModel.volumeLevel * 100)
            Slider(value: $settingsModel.volumeLevel, in: 0.0...1.0) {
              ZStack(alignment: .leading) {
                Text("\(100)%")
                  .availableMonospacedDigit()
                  .hidden()
                Text("\(volume)%")
                  .availableMonospacedDigit()
              }
            } minimumValueLabel: {
              Image(systemName: "speaker.wave.1.fill")
            } maximumValueLabel: {
              Image(systemName: "speaker.wave.3.fill")
            } onEditingChanged: { changed in

            }
          }
        }
      }
      .padding()
    }
  }
}

struct InputView: View {
  @EnvironmentObject private var settingsModel: SettingsModel

  var body: some View {
    ScrollView {
      VStack {
        FormSection(title: "Controller") {
          FormCell(
            title: "Multi-Controller Mode", contentWidth: 88,
            content: {
              Picker("", selection: $settingsModel.selectedMultiControllerMode) {
                ForEach(SettingsModel.multiControllerModes, id: \.self) { mode in
                  Text(LocalizedStringKey(mode))
                }
              }
            })

          Divider()

          ToggleCell(title: "Rumble Controller", boolBinding: $settingsModel.rumble)
        }

        Spacer()
          .frame(height: 32)

        FormSection(title: "Buttons") {
          ToggleCell(title: "Swap A/B and X/Y Buttons", boolBinding: $settingsModel.swapButtons)

          Divider()

          ToggleCell(title: "Emulate Guide Button", boolBinding: $settingsModel.emulateGuide)
        }

        Spacer()
          .frame(height: 32)

        FormSection(title: "Drivers") {
          FormCell(
            title: "Controller Driver", contentWidth: 88,
            content: {
              Picker("", selection: $settingsModel.selectedControllerDriver) {
                ForEach(SettingsModel.controllerDrivers, id: \.self) { mode in
                  Text(LocalizedStringKey(mode))
                }
              }
            })

          Divider()

          FormCell(
            title: "Mouse Driver", contentWidth: 88,
            content: {
              Picker("", selection: $settingsModel.selectedMouseDriver) {
                ForEach(SettingsModel.mouseDrivers, id: \.self) { mode in
                  Text(LocalizedStringKey(mode))
                }
              }
            })
        }
      }
      .padding()
    }
  }
}

struct AppView: View {
  @EnvironmentObject private var settingsModel: SettingsModel

  var body: some View {
    ScrollView {
      VStack {
        FormSection(title: "Behaviour") {
          ToggleCell(
            title: "Automatically Fullscreen Stream Window",
            boolBinding: $settingsModel.autoFullscreen)
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
      }
      .padding()
    }
  }
}

struct LegacyView: View {
  @EnvironmentObject private var settingsModel: SettingsModel

  var body: some View {
    ScrollView {
      VStack {
        FormSection(title: "Geforce Experience") {
          ToggleCell(title: "Optimize Game Settings", boolBinding: $settingsModel.optimize)
        }
      }
      .padding()
    }
  }
}

struct ToggleCell: View {
  let title: LocalizedStringKey
  @Binding var boolBinding: Bool

  var body: some View {
    FormCell(
      title: title, contentWidth: 0,
      content: {
        Toggle("", isOn: $boolBinding)
          .toggleStyle(.switch)
          .controlSize(.small)
      })
  }
}

struct DimensionsInputView: View {
  @Binding var widthBinding: CGFloat?
  @Binding var heightBinding: CGFloat?
  let placeholderDimensions: CGSize

  var body: some View {
    HStack(spacing: 4) {
      TextField(
        formatDimension(placeholderDimensions.width), value: $widthBinding,
        formatter: NumberOnlyFormatter()
      )
      .multilineTextAlignment(.trailing)

      Text("×")

      TextField(
        formatDimension(placeholderDimensions.height), value: $heightBinding,
        formatter: NumberOnlyFormatter()
      )
      .multilineTextAlignment(.leading)
    }
    .textFieldStyle(.plain)
    .fixedSize()
  }

  func formatDimension(_ dimension: CGFloat) -> String {
    return "\(Int(dimension))"
  }
}

struct FormSection<Content: View>: View {
  let title: LocalizedStringKey
  let content: Content

  init(title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    GroupBox(
      content: {
        VStack {
          Group {
            content
          }
          .padding([.top], 1)
        }
        .padding([.top, .bottom], 6)
        .padding([.leading, .trailing], 6)
      },
      label: {
        Text(title)
          .font(
            .system(.body, design: .rounded)
              .weight(.semibold)
          )
          .padding(.bottom, 6)
      })
  }
}

struct FormCell<Content: View>: View {
  let title: LocalizedStringKey
  let contentWidth: CGFloat
  let content: Content

  init(title: LocalizedStringKey, contentWidth: CGFloat, @ViewBuilder content: () -> Content) {
    self.title = title
    self.contentWidth = contentWidth
    self.content = content()
  }

  var body: some View {
    HStack {
      Text(title)

      Spacer()

      content
        .if(
          contentWidth != 0,
          transform: { view in
            view
              .frame(width: contentWidth)
          })
    }
  }
}

extension CGSize: @retroactive Hashable {
  public func hash(into hasher: inout Hasher) {
    hasher.combine(width)
    hasher.combine(height)
  }
}

#Preview {
  if #available(macOS 13.0, *) {
    return SettingsView()
  } else {
    return Text("Not supported")
  }
}
