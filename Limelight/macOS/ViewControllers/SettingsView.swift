//
//  SettingsView.swift
//  Moonlight for macOS
//
//  Created by Michael Kenny on 15/1/2024.
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

import AVFoundation
import AppKit
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
      if let hostId {
        settingsModel.selectHost(id: hostId)
      } else {
        // If opened without hostId, verify if we should lock global (e.g. from main menu)
        // For now, let's allow selection if no hostId is passed (or default to global but unlocked?)
        // The requirement is "Homepage -> Global", "Host -> Host Profile".
        // If we pass nil for Homepage, we can select Global and lock it?
        // Or keep existing behavior (remember last selection).
        // User said: "主页时是全局配置". So if we pass Global ID, we lock it.
        // If we pass nil, maybe we just let it be?
        // But we will modify callers to pass Global ID for homepage.
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

  var body: some View {
    Group {
      switch pane {
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
        SettingPaneLoader(settingsModel) {
          LegacyView()
        }
      }
    }
    .environmentObject(settingsModel)
    .navigationTitle(languageManager.localize(pane.title))
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
  @SwiftUI.State private var showRemoteCustomResolutionGroup = false
  @SwiftUI.State private var showRemoteCustomFpsGroup = false

  private func nativeDisplayPixelSize() -> CGSize? {
    guard let screen = NSScreen.main else { return nil }
    guard
      let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
        as? NSNumber
    else { return nil }

    let displayID = CGDirectDisplayID(screenNumber.uint32Value)
    guard let mode = CGDisplayCopyDisplayMode(displayID) else { return nil }

    return CGSize(width: mode.pixelWidth, height: mode.pixelHeight)
  }

  private func matchDisplayLabel() -> String {
    let base = languageManager.localize("Match Display")
    guard let size = nativeDisplayPixelSize() else { return base }
    return "\(base) (\(Int(size.width))×\(Int(size.height)))"
  }

  var body: some View {
    ScrollView {
      VStack {
        FormSection(title: "General") {
          if let hosts = SettingsModel.hosts {
            if !settingsModel.isProfileLocked {
              FormCell(title: "Profile:", contentWidth: 150) {
                Picker("", selection: $settingsModel.selectedHost) {
                  ForEach(hosts, id: \.self) { host in
                    if let host {
                      let name =
                        host.id == SettingsModel.globalHostId
                        ? languageManager.localize("Global (Default)") : host.name
                      Text(name).tag(Optional(host))
                    }
                  }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .trailing)
              }
            } else {
              HStack {
                Text(languageManager.localize("Profile:"))
                Spacer()
                let name =
                  settingsModel.selectedHost?.id == SettingsModel.globalHostId
                  ? languageManager.localize("Global (Default)")
                  : (settingsModel.selectedHost?.name ?? "")
                Text(name)
                  .foregroundColor(.secondary)
              }
            }

            HStack {
              Spacer()
              Text(
                settingsModel.selectedHost?.id == SettingsModel.globalHostId
                  ? languageManager.localize("Scope: Global")
                  : String(
                    format: languageManager.localize("Scope: Profile (%@)"),
                    settingsModel.selectedHost?.name ?? "")
              )
              .font(.footnote)
              .foregroundColor(.secondary)
            }

            Divider()
          }

          FormCell(title: "Connection Method", contentWidth: 250) {
            HStack {
              Picker("", selection: $settingsModel.selectedConnectionMethod) {
                ForEach(settingsModel.connectionCandidates, id: \.0) { candidate in
                  HStack {
                    if candidate.0 != "Auto" {
                      Image(systemName: "circle.fill")
                        .foregroundColor(candidate.2 ? .green : .red)
                        .font(.system(size: 8))
                    }
                    Text(candidate.1)
                  }
                  .tag(candidate.0)
                }
              }
              .labelsHidden()

              Button(action: {
                if let uuid = settingsModel.selectedHost?.id, uuid != SettingsModel.globalHostId {
                  NotificationCenter.default.post(
                    name: NSNotification.Name("MoonlightRequestHostDiscovery"), object: nil,
                    userInfo: ["uuid": uuid])
                }
              }) {
                Image(systemName: "arrow.clockwise")
              }
              .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
          }

          Divider()

          FormCell(
            title: "Default Display Mode", contentWidth: 150,
            content: {
              Picker("", selection: $settingsModel.selectedDisplayMode) {
                ForEach(SettingsModel.displayModes, id: \.self) { mode in
                  Text(languageManager.localize(mode))
                }
              }
              .labelsHidden()
              .frame(maxWidth: .infinity, alignment: .trailing)
            })

          Divider()

          FormCell(title: "Language", contentWidth: 150) {
            Picker("", selection: $languageManager.currentLanguage) {
              ForEach(AppLanguage.allCases) { lang in
                Text(languageManager.localize(lang.rawValue)).tag(lang)
              }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .trailing)
            .onChange(of: languageManager.currentLanguage) { _ in
              languageManager.applyAppLanguage()
              NotificationCenter.default.post(name: .init("LanguageChanged"), object: nil)
            }
          }

          Divider()

          ToggleCell(title: "Ignore Aspect Ratio", boolBinding: $settingsModel.ignoreAspectRatio)

          Divider()

          ToggleCell(title: "Show Local Cursor", boolBinding: $settingsModel.showLocalCursor)
        }

        Spacer()
          .frame(height: 32)

        FormSection(title: "Resolution & Scaling") {
          FormCell(
            title: "Resolution", contentWidth: 220,
            content: {
              Picker("", selection: $settingsModel.selectedResolution) {
                ForEach(SettingsModel.resolutions, id: \.self) { resolution in
                  if resolution == SettingsModel.matchDisplayResolutionSentinel {
                    Text(matchDisplayLabel())
                  } else if resolution == .zero {
                    Text(languageManager.localize("Custom"))
                  } else {
                    Text(verbatim: "\(Int(resolution.width))x\(Int(resolution.height))")
                  }
                }
              }
              .labelsHidden()
              .frame(maxWidth: .infinity, alignment: .trailing)
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

          ToggleCell(
            title: "Resolution Scale",
            hintKey: "Resolution Scale hint",
            boolBinding: $settingsModel.streamResolutionScale
          )

          Divider()

          FormCell(title: "Resolution Scale Ratio", contentWidth: 120) {
            Picker("", selection: $settingsModel.streamResolutionScaleRatio) {
              Text("50%").tag(50)
              Text("75%").tag(75)
              Text("100%").tag(100)
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .trailing)
          }
          .disabled(!settingsModel.streamResolutionScale)
          .opacity(settingsModel.streamResolutionScale ? 1.0 : 0.55)

          Divider()

          if SettingsModel.isMetalFXSupported {
            FormCell(
              title: "Upscaling", contentWidth: 200,
              content: {
                Picker("", selection: $settingsModel.selectedUpscalingMode) {
                  ForEach(SettingsModel.upscalingModes, id: \.self) { mode in
                    Text(languageManager.localize(mode))
                  }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .trailing)
              })
          } else {
            VStack(alignment: .leading, spacing: 6) {
              HStack {
                Text(languageManager.localize("Upscaling"))
                Spacer()
                Text(languageManager.localize("Not supported"))
                  .foregroundColor(.secondary)
              }
              Text(languageManager.localize("MetalFX requires macOS 13 or later."))
                .font(.footnote)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          }

          Text(languageManager.localize("AI enhancement recommended hint"))
            .font(.footnote)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)

          Divider()

          Text(languageManager.localize("Scale vs Upscaling hint"))
            .font(.footnote)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)

          if settingsModel.streamResolutionScale && settingsModel.streamResolutionScaleRatio < 100
            && settingsModel.selectedUpscalingMode == "Off"
          {
            Divider()

            Text(languageManager.localize("Resolution Scale + Upscaling hint"))
              .font(.footnote)
              .foregroundColor(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading)
          }

          Divider()

          ToggleCell(
            title: "Remote Resolution",
            hintKey: "Remote overrides hint",
            boolBinding: $settingsModel.remoteResolutionEnabled
          )

          if settingsModel.remoteResolutionEnabled {
            Divider()

            FormCell(
              title: "Remote Resolution Value", contentWidth: 220,
              content: {
                Picker("", selection: $settingsModel.selectedRemoteResolution) {
                  ForEach(SettingsModel.remoteResolutions, id: \.self) { resolution in
                    if resolution == .zero {
                      Text(languageManager.localize("Custom"))
                    } else {
                      Text(
                        verbatim: "\(Int(resolution.width))x\(Int(resolution.height))")
                    }
                  }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .trailing)
              })

            if showRemoteCustomResolutionGroup {
              Divider()

              FormCell(
                title: "Remote Custom Resolution", contentWidth: 0,
                content: {
                  DimensionsInputView(
                    widthBinding: $settingsModel.remoteCustomResWidth,
                    heightBinding: $settingsModel.remoteCustomResHeight,
                    placeholderDimensions: CGSize(width: 1920, height: 1080))
                })
            }
          }
        }

        Spacer()
          .frame(height: 32)

        FormSection(title: "Frame Rate") {
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
              .labelsHidden()
              .frame(maxWidth: .infinity, alignment: .trailing)
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

          Divider()

          ToggleCell(
            title: "Remote FPS",
            hintKey: "Remote overrides hint",
            boolBinding: $settingsModel.remoteFpsEnabled
          )

          if settingsModel.remoteFpsEnabled {
            Divider()

            FormCell(
              title: "Remote FPS Value", contentWidth: 120,
              content: {
                Picker("", selection: $settingsModel.selectedRemoteFps) {
                  ForEach(SettingsModel.fpss, id: \.self) { fps in
                    if fps == .zero {
                      Text(languageManager.localize("Custom"))
                    } else {
                      Text("\(fps)")
                    }
                  }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .trailing)
              })

            if showRemoteCustomFpsGroup {
              Divider()

              FormCell(
                title: "Remote Custom FPS", contentWidth: 0,
                content: {
                  TextField(
                    "60", value: $settingsModel.remoteCustomFps, formatter: NumberOnlyFormatter()
                  )
                  .multilineTextAlignment(.trailing)
                  .textFieldStyle(.plain)
                  .fixedSize()
                })
            }
          }
        }

        Spacer()
          .frame(height: 32)

        FormSection(title: "Bitrate") {
          VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $settingsModel.autoAdjustBitrate) {
              Text(languageManager.localize("Auto Adjust Bitrate"))
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Toggle(isOn: $settingsModel.unlockMaxBitrate) {
              Text(languageManager.localize("Unlock max bitrate (1000 Mbps)"))
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            let steps = SettingsModel.bitrateSteps(unlocked: settingsModel.unlockMaxBitrate)
            let index = max(0, min(Int(settingsModel.bitrateSliderValue), steps.count - 1))
            let stepKbps = Int(steps[index] * 1000.0)
            let bitrateKbps = settingsModel.customBitrate ?? stepKbps
            let bitrateMbps = max(0, bitrateKbps / 1000)

            if settingsModel.autoAdjustBitrate {
              HStack {
                Text(languageManager.localize("Target Bitrate"))
                Spacer()
                Text(verbatim: "\(bitrateMbps) Mbps")
                  .availableMonospacedDigit()
              }
              Text(languageManager.localize("Auto bitrate hint"))
                .font(.footnote)
                .foregroundColor(.secondary)
            } else {
              HStack {
                Text(verbatim: "\(bitrateMbps) Mbps")
                  .availableMonospacedDigit()

                Spacer()

                let customBitrateMbpsBinding = Binding<Int?>(
                  get: {
                    guard let kbps = settingsModel.customBitrate else { return nil }
                    return kbps / 1000
                  },
                  set: { newMbps in
                    if let newMbps {
                      settingsModel.customBitrate = max(0, newMbps) * 1000
                    } else {
                      settingsModel.customBitrate = nil
                    }
                  }
                )

                TextField("Mbps", value: customBitrateMbpsBinding, formatter: NumberOnlyFormatter())
                  .multilineTextAlignment(.trailing)
                  .textFieldStyle(.roundedBorder)
                  .frame(width: 80)
              }

              Slider(
                value: $settingsModel.bitrateSliderValue,
                in:
                  0...Float(
                    max(
                      0,
                      SettingsModel.bitrateSteps(unlocked: settingsModel.unlockMaxBitrate).count - 1
                    )),
                step: 1
              )
            }
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
        func updateRemoteCustomResolutionGroup() {
          showRemoteCustomResolutionGroup =
            settingsModel.remoteResolutionEnabled && settingsModel.selectedRemoteResolution == .zero
        }
        func updateRemoteCustomFpsGroup() {
          showRemoteCustomFpsGroup =
            settingsModel.remoteFpsEnabled && settingsModel.selectedRemoteFps == .zero
        }

        updateCustomResolutionGroup()
        updateCustomFpsGroup()
        updateRemoteCustomResolutionGroup()
        updateRemoteCustomFpsGroup()
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
      .onChange(of: settingsModel.remoteResolutionEnabled) { _ in
        withAnimation {
          showRemoteCustomResolutionGroup =
            settingsModel.remoteResolutionEnabled && settingsModel.selectedRemoteResolution == .zero
        }
      }
      .onChange(of: settingsModel.selectedRemoteResolution) { _ in
        withAnimation {
          showRemoteCustomResolutionGroup =
            settingsModel.remoteResolutionEnabled && settingsModel.selectedRemoteResolution == .zero
        }
      }
      .onChange(of: settingsModel.remoteFpsEnabled) { _ in
        withAnimation {
          showRemoteCustomFpsGroup =
            settingsModel.remoteFpsEnabled && settingsModel.selectedRemoteFps == .zero
        }
      }
      .onChange(of: settingsModel.selectedRemoteFps) { _ in
        withAnimation {
          showRemoteCustomFpsGroup =
            settingsModel.remoteFpsEnabled && settingsModel.selectedRemoteFps == .zero
        }
      }
    }
  }
}

struct VideoView: View {
  @EnvironmentObject private var settingsModel: SettingsModel
  @ObservedObject var languageManager = LanguageManager.shared

  var body: some View {
    ScrollView {
      VStack {
        FormSection(title: "Video") {
          FormCell(
            title: "Video Codec", contentWidth: 200,
            content: {
              Picker("", selection: $settingsModel.selectedVideoCodec) {
                ForEach(SettingsModel.videoCodecs, id: \.self) { codec in
                  Text(languageManager.localize(codec))
                }
              }
              .labelsHidden()
              .frame(maxWidth: .infinity, alignment: .trailing)
            })

          Divider()

          ToggleCell(title: "HDR", boolBinding: $settingsModel.hdr)

          Divider()

          ToggleCell(
            title: "Enable YUV 4:4:4",
            hintKey: "YUV 4:4:4 hint",
            boolBinding: $settingsModel.enableYUV444
          )

          Divider()

          ToggleCell(title: "V-Sync", boolBinding: $settingsModel.enableVsync)

          Divider()

          FormCell(
            title: "Frame Pacing", contentWidth: 200,
            content: {
              Picker("", selection: $settingsModel.selectedPacingOptions) {
                ForEach(SettingsModel.pacingOptions, id: \.self) { pacingOption in
                  Text(languageManager.localize(pacingOption))
                }
              }
              .labelsHidden()
              .frame(maxWidth: .infinity, alignment: .trailing)
            })

          Divider()

          ToggleCell(
            title: "Performance Overlay (⌃⌥S)",
            boolBinding: $settingsModel.showPerformanceOverlay)

          Divider()

          ToggleCell(
            title: "Show Connection Warnings",
            boolBinding: $settingsModel.showConnectionWarnings)
        }
      }
      .padding()
    }
  }
}

struct AudioView: View {
  @EnvironmentObject private var settingsModel: SettingsModel
  @ObservedObject var languageManager = LanguageManager.shared

  var body: some View {
    ScrollView {
      VStack {
        FormSection(title: "Audio") {
          FormCell(
            title: "Audio Configuration", contentWidth: 200,
            content: {
              Picker("", selection: $settingsModel.selectedAudioConfiguration) {
                ForEach(SettingsModel.audioConfigurations, id: \.self) { config in
                  Text(languageManager.localize(config))
                }
              }
              .labelsHidden()
              .frame(maxWidth: .infinity, alignment: .trailing)
            })

          Divider()

          ToggleCell(title: "Play Sound on Host", boolBinding: $settingsModel.audioOnPC)

          Divider()

          ToggleCell(
            title: "Enable Microphone",
            hintKey: "Microphone hint",
            boolBinding: $settingsModel.enableMicrophone
          )
          .onChange(of: settingsModel.enableMicrophone) { newValue in
            guard newValue else { return }

            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            switch status {
            case .authorized:
              break
            case .notDetermined:
              AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                  if !granted {
                    settingsModel.enableMicrophone = false
                  }
                }
              }
            case .denied, .restricted:
              // Don’t pop alerts; just revert the toggle.
              settingsModel.enableMicrophone = false
            @unknown default:
              settingsModel.enableMicrophone = false
            }
          }

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
  @SwiftUI.State private var showAdvancedInput = false

  var body: some View {
    ScrollView {
      VStack {
        FormSection(title: "Mouse") {
          ToggleCell(
            title: "Optimize mouse for remote desktop",
            boolBinding: $settingsModel.absoluteMouseMode)

          Divider()

          ToggleCell(
            title: "Swap Left and Right Mouse Buttons", boolBinding: $settingsModel.swapMouseButtons
          )

          Divider()

          ToggleCell(
            title: "Reverse Mouse Scrolling Direction",
            boolBinding: $settingsModel.reverseScrollDirection)

          Divider()

          FormCell(
            title: "Touchscreen Mode", contentWidth: 150,
            content: {
              Picker("", selection: $settingsModel.selectedTouchscreenMode) {
                ForEach(SettingsModel.touchscreenModes, id: \.self) { mode in
                  Text(languageManager.localize(mode))
                }
              }
              .labelsHidden()
              .frame(maxWidth: .infinity, alignment: .trailing)
            })
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

        FormSection(title: "Controller") {
          FormCell(
            title: "Multi-Controller Mode", contentWidth: 88,
            content: {
              Picker("", selection: $settingsModel.selectedMultiControllerMode) {
                ForEach(SettingsModel.multiControllerModes, id: \.self) { mode in
                  Text(languageManager.localize(mode))
                }
              }
              .labelsHidden()
              .frame(maxWidth: .infinity, alignment: .trailing)
            })

          Divider()

          ToggleCell(title: "Rumble Controller", boolBinding: $settingsModel.rumble)

          Divider()

          ToggleCell(title: "Swap A/B and X/Y Buttons", boolBinding: $settingsModel.swapButtons)

          Divider()

          ToggleCell(title: "Emulate Guide Button", boolBinding: $settingsModel.emulateGuide)

          Divider()

          ToggleCell(
            title: "Gamepad Mouse Emulation", hintKey: "Gamepad Mouse Hint",
            boolBinding: $settingsModel.gamepadMouseMode)
        }

        Spacer()
          .frame(height: 32)

        FormSection(title: "Advanced") {
          DisclosureGroup(
            isExpanded: $showAdvancedInput,
            content: {
              VStack {
                FormCell(
                  title: "Controller Driver", contentWidth: 120,
                  content: {
                    Picker("", selection: $settingsModel.selectedControllerDriver) {
                      ForEach(SettingsModel.controllerDrivers, id: \.self) { mode in
                        Text(languageManager.localize(mode))
                      }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                  })

                Divider()

                FormCell(
                  title: "Mouse Driver", contentWidth: 120,
                  content: {
                    Picker("", selection: $settingsModel.selectedMouseDriver) {
                      ForEach(SettingsModel.mouseDrivers, id: \.self) { mode in
                        Text(languageManager.localize(mode))
                      }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                  })
              }
            },
            label: {
              Text(languageManager.localize("Drivers"))
            }
          )
          .modifier(MoonlightDisclosureGroupStyleCompat())
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .padding()
    }
  }
}

private struct MoonlightDisclosureGroupStyleCompat: ViewModifier {
  func body(content: Content) -> some View {
    if #available(macOS 13.0, *) {
      content.disclosureGroupStyle(.automatic)
    } else {
      content
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
            title: "Quit App After Stream",
            boolBinding: $settingsModel.quitAppAfterStream)
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
  let hintKey: String?
  @Binding var boolBinding: Bool
  @ObservedObject var languageManager = LanguageManager.shared

  init(title: String, hintKey: String? = nil, boolBinding: Binding<Bool>) {
    self.title = title
    self.hintKey = hintKey
    self._boolBinding = boolBinding
  }

  var body: some View {
    HStack {
      HStack(spacing: 6) {
        Text(languageManager.localize(title))
        if let hintKey {
          InfoHintButton(hintKey: hintKey)
        }
      }

      Spacer()

      Toggle("", isOn: $boolBinding)
        .toggleStyle(.switch)
        .controlSize(.small)
    }
  }
}

private struct InfoHintButton: View {
  let hintKey: String
  @ObservedObject var languageManager = LanguageManager.shared
  @SwiftUI.State private var showPopover = false

  private var hintText: String {
    languageManager.localize(hintKey)
  }

  var body: some View {
    Button {
      showPopover.toggle()
    } label: {
      Image(systemName: "info.circle")
        .imageScale(.small)
        .foregroundColor(.secondary)
    }
    .buttonStyle(.plain)
    .help(hintText)
    .popover(isPresented: $showPopover, arrowEdge: .top) {
      Text(hintText)
        .font(.callout)
        .padding(10)
        .frame(maxWidth: 320, alignment: .leading)
    }
    .accessibilityLabel(Text(hintText))
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
              .frame(width: contentWidth, alignment: .trailing)
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
