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

  var title: String {
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
  @ObservedObject var languageManager = LanguageManager.shared

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
    .navigationSubtitle(Text(languageManager.localize(pane.title)))
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        if let hosts = SettingsModel.hosts {
          HStack {
            Text(languageManager.localize("Profile:"))

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

struct StreamView: View {
  @EnvironmentObject private var settingsModel: SettingsModel
  @ObservedObject var languageManager = LanguageManager.shared

  @SwiftUI.State private var showCustomResolutionGroup = false
  @SwiftUI.State private var showCustomFpsGroup = false

  var body: some View {
    ScrollView {
      VStack {
        FormSection(title: "General") {
          FormCell(title: "Language", contentWidth: 150) {
            Picker("", selection: $languageManager.currentLanguage) {
              ForEach(AppLanguage.allCases) { lang in
                Text(languageManager.localize(lang.rawValue)).tag(lang)
              }
            }
          }
        }

        Spacer()
          .frame(height: 32)

        FormSection(title: "Resolution and FPS") {
          FormCell(
            title: "Resolution", contentWidth: 100,
            content: {
              Picker("", selection: $settingsModel.selectedResolution) {
                ForEach(SettingsModel.resolutions, id: \.self) { resolution in
                  if resolution == .zero {
                    Text(languageManager.localize("Custom"))
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
                    Text(languageManager.localize("Custom"))
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
            HStack {
              let bitrate =
                settingsModel.customBitrate
                ?? Int(SettingsModel.bitrateSteps[Int(settingsModel.bitrateSliderValue)])
              Text(verbatim: "\(bitrate) Mbps")
                .availableMonospacedDigit()

              Spacer()

              TextField(
                "Custom", value: $settingsModel.customBitrate, formatter: NumberOnlyFormatter()
              )
              .multilineTextAlignment(.trailing)
              .textFieldStyle(.roundedBorder)
              .frame(width: 80)
            }

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
  @ObservedObject var languageManager = LanguageManager.shared

  var body: some View {
    ScrollView {
      VStack {
        FormSection(title: "Video") {
          FormCell(
            title: "Video Codec", contentWidth: 155,
            content: {
              Picker("", selection: $settingsModel.selectedVideoCodec) {
                ForEach(SettingsModel.videoCodecs, id: \.self) { codec in
                  Text(languageManager.localize(codec))
                }
              }
            })

          Divider()

          ToggleCell(title: "HDR", boolBinding: $settingsModel.hdr)

          Divider()

          ToggleCell(title: "V-Sync", boolBinding: $settingsModel.enableVsync)

          Divider()

          FormCell(
            title: "Frame Pacing", contentWidth: 155,
            content: {
              Picker("", selection: $settingsModel.selectedPacingOptions) {
                ForEach(SettingsModel.pacingOptions, id: \.self) { pacingOption in
                  Text(languageManager.localize(pacingOption))
                }
              }
            })

          Divider()

          ToggleCell(
            title: "Performance Overlay", boolBinding: $settingsModel.showPerformanceOverlay)
        }

        Spacer()
          .frame(height: 32)

        FormSection(title: "Audio") {
          FormCell(
            title: "Audio Configuration", contentWidth: 155,
            content: {
              Picker("", selection: $settingsModel.selectedAudioConfiguration) {
                ForEach(SettingsModel.audioConfigurations, id: \.self) { config in
                  Text(languageManager.localize(config))
                }
              }
            })

          Divider()

          ToggleCell(title: "Play Sound on Host", boolBinding: $settingsModel.audioOnPC)

          Divider()

          VStack(alignment: .center) {
            Text(languageManager.localize("Volume"))

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
  @ObservedObject var languageManager = LanguageManager.shared

  var body: some View {
    ScrollView {
      VStack {
        FormSection(title: "Controller") {
          FormCell(
            title: "Multi-Controller Mode", contentWidth: 88,
            content: {
              Picker("", selection: $settingsModel.selectedMultiControllerMode) {
                ForEach(SettingsModel.multiControllerModes, id: \.self) { mode in
                  Text(languageManager.localize(mode))
                }
              }
            })

          Divider()

          ToggleCell(title: "Rumble Controller", boolBinding: $settingsModel.rumble)
        }

        Spacer()
          .frame(height: 32)

        FormSection(title: "Keyboard") {
          ToggleCell(
            title: "Capture system keyboard shortcuts",
            boolBinding: $settingsModel.captureSystemShortcuts)
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
                  Text(languageManager.localize(mode))
                }
              }
            })

          Divider()

          FormCell(
            title: "Mouse Driver", contentWidth: 88,
            content: {
              Picker("", selection: $settingsModel.selectedMouseDriver) {
                ForEach(SettingsModel.mouseDrivers, id: \.self) { mode in
                  Text(languageManager.localize(mode))
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
  @ObservedObject var languageManager = LanguageManager.shared

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
  @ObservedObject var languageManager = LanguageManager.shared

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
  let title: String
  @Binding var boolBinding: Bool
  @ObservedObject var languageManager = LanguageManager.shared

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
  let title: String
  let content: Content
  @ObservedObject var languageManager = LanguageManager.shared

  init(title: String, @ViewBuilder content: () -> Content) {
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
        Text(languageManager.localize(title))
          .font(
            .system(.body, design: .rounded)
              .weight(.semibold)
          )
          .padding(.bottom, 6)
      })
  }
}

struct FormCell<Content: View>: View {
  let title: String
  let contentWidth: CGFloat
  let content: Content
  @ObservedObject var languageManager = LanguageManager.shared

  init(title: String, contentWidth: CGFloat, @ViewBuilder content: () -> Content) {
    self.title = title
    self.contentWidth = contentWidth
    self.content = content()
  }

  var body: some View {
    HStack {
      Text(languageManager.localize(title))

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

// MARK: - Language Manager

enum AppLanguage: String, CaseIterable, Identifiable {
  case system = "System"
  case english = "English"
  case chinese = "简体中文"

  var id: String { rawValue }
}

class LanguageManager: ObservableObject {
  static let shared = LanguageManager()

  @AppStorage("appLanguage") var currentLanguage: AppLanguage = .system

  func localize(_ key: String) -> String {
    let useChinese: Bool

    if currentLanguage == .system {
      // Check system preference
      let preferred = Locale.preferredLanguages.first ?? "en"
      useChinese = preferred.hasPrefix("zh")
    } else {
      useChinese = currentLanguage == .chinese
    }

    let dict = useChinese ? zhHans : en
    return dict[key] ?? key
  }

  private let en: [String: String] = [
    "Stream": "Stream",
    "Video and Audio": "Video and Audio",
    "Input": "Input",
    "App": "App",
    "Legacy": "Legacy",
    "General": "General",
    "Language": "Language",
    "System": "System (Default)",

    "Profile:": "Profile:",

    "Resolution and FPS": "Resolution and FPS",
    "Resolution": "Resolution",
    "Custom": "Custom",
    "Custom Resolution": "Custom Resolution",
    "FPS": "FPS",
    "Custom FPS": "Custom FPS",
    "Bitrate": "Bitrate",

    "Video": "Video",
    "Video Codec": "Video Codec",
    "HDR": "HDR",
    "Frame Pacing": "Frame Pacing",
    "Lowest Latency": "Lowest Latency",
    "Smoothest Video": "Smoothest Video",

    "Audio": "Audio",
    "Audio Configuration": "Audio Configuration",
    "Play Sound on Host": "Play Sound on Host",
    "V-Sync": "V-Sync",
    "Performance Overlay": "Performance Overlay",
    "Volume": "Volume",

    "Controller": "Controller",
    "Multi-Controller Mode": "Multi-Controller Mode",
    "Single": "Single",
    "Auto": "Auto",
    "Rumble Controller": "Rumble Controller",
    "Buttons": "Buttons",
    "Swap A/B and X/Y Buttons": "Swap A/B and X/Y Buttons",
    "Emulate Guide Button": "Emulate Guide Button",
    "Drivers": "Drivers",
    "Controller Driver": "Controller Driver",
    "Mouse Driver": "Mouse Driver",
    "HID": "HID",
    "MFi": "MFi",
    "Keyboard": "Keyboard",
    "Capture system keyboard shortcuts": "Capture system keyboard shortcuts",

    "Behaviour": "Behaviour",
    "Automatically Fullscreen Stream Window": "Automatically Fullscreen Stream Window",
    "Visuals": "Visuals",
    "Dim Non-Hovered Apps": "Dim Non-Hovered Apps",
    "Custom Artwork Dimensions": "Custom Artwork Dimensions",

    "Geforce Experience": "Geforce Experience",
    "Optimize Game Settings": "Optimize Game Settings",

    "Not supported": "Not supported",
  ]

  private let zhHans: [String: String] = [
    "Stream": "基本设置",
    "Video and Audio": "音视频设置",
    "Input": "输入设置",
    "App": "应用设置",
    "Legacy": "其他设置",
    "General": "常规",
    "Language": "语言 (Language)",
    "System": "系统默认 (System)",

    "Profile:": "配置文件:",

    "Resolution and FPS": "分辨率和 FPS",
    "Resolution": "分辨率",
    "Custom": "自定义",
    "Custom Resolution": "自定义分辨率",
    "FPS": "帧率",
    "Custom FPS": "自定义帧率",
    "Bitrate": "视频比特率",

    "Video": "视频",
    "Video Codec": "视频编解码器",
    "HDR": "HDR (高动态范围)",
    "Frame Pacing": "帧速调节",
    "Lowest Latency": "最低延迟",
    "Smoothest Video": "最流畅视频",

    "Audio": "音频",
    "Audio Configuration": "音频配置",
    "Play Sound on Host": "在主机上播放声音",
    "V-Sync": "垂直同步",
    "Performance Overlay": "显示性能统计",
    "Volume": "音量",

    "Controller": "手柄设置",
    "Multi-Controller Mode": "多手柄模式",
    "Single": "单人",
    "Auto": "自动",
    "Rumble Controller": "手柄震动",
    "Buttons": "按键",
    "Swap A/B and X/Y Buttons": "交换手柄的 A/B 和 X/Y 按钮",
    "Emulate Guide Button": "模拟 Guide 键",
    "Drivers": "驱动程序",
    "Controller Driver": "手柄驱动",
    "Mouse Driver": "鼠标驱动",
    "HID": "HID (推荐)",
    "MFi": "MFi (原生)",
    "Keyboard": "键盘",
    "Capture system keyboard shortcuts": "捕获系统快捷键",

    "Behaviour": "行为",
    "Automatically Fullscreen Stream Window": "自动全屏显示",
    "Visuals": "界面",
    "Dim Non-Hovered Apps": "调暗未选中应用封面",
    "Custom Artwork Dimensions": "自定义封面尺寸",

    "Geforce Experience": "Geforce Experience",
    "Optimize Game Settings": "优化游戏设置",

    "Not supported": "不支持",
  ]
}
