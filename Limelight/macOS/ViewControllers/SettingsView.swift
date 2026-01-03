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

        FormSection(title: "Resolution and FPS") {
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
                    Text(verbatim: resolution.height == 2160 ? "4K" : "\(Int(resolution.height))p")
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

          ToggleCell(title: "Resolution Scale", boolBinding: $settingsModel.streamResolutionScale)

          if settingsModel.streamResolutionScale {
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
                        verbatim: resolution.height == 2160 ? "4K" : "\(Int(resolution.height))p")
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

struct VideoAndAudioView: View {
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

        Spacer()
          .frame(height: 32)

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
              .labelsHidden()
              .frame(maxWidth: .infinity, alignment: .trailing)
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

        FormSection(title: "Buttons") {
          ToggleCell(title: "Swap A/B and X/Y Buttons", boolBinding: $settingsModel.swapButtons)

          Divider()

          ToggleCell(title: "Emulate Guide Button", boolBinding: $settingsModel.emulateGuide)

          Divider()

          ToggleCell(
            title: "Gamepad Mouse Emulation (!)", hintKey: "Gamepad Mouse Hint",
            boolBinding: $settingsModel.gamepadMouseMode)
        }

        Spacer()
          .frame(height: 32)

        FormSection(title: "Drivers") {
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

          Divider()

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

// MARK: - Language Manager

enum AppLanguage: String, CaseIterable, Identifiable {
  case system = "System"
  case english = "English"
  case chinese = "简体中文"

  var id: String { rawValue }
}

@objc class LanguageManager: NSObject, ObservableObject {
  @objc static let shared = LanguageManager()

  @AppStorage("appLanguage") var currentLanguage: AppLanguage = .system

  override init() {
    super.init()
    applyAppLanguage()
  }

  @objc func applyAppLanguage() {
    switch currentLanguage {
    case .system:
      UserDefaults.standard.removeObject(forKey: "AppleLanguages")
    case .english:
      UserDefaults.standard.set(["en"], forKey: "AppleLanguages")
    case .chinese:
      UserDefaults.standard.set(["zh-Hans"], forKey: "AppleLanguages")
    }
  }

  private func localizedString(_ key: String, languageCode: String) -> String? {
    guard let path = Bundle.main.path(forResource: languageCode, ofType: "lproj"),
      let bundle = Bundle(path: path)
    else {
      return nil
    }

    let val = NSLocalizedString(
      key, tableName: nil, bundle: bundle, value: "___MISSING___", comment: "")
    return val == "___MISSING___" ? nil : val
  }

  @objc func localize(_ key: String) -> String {
    let useChinese: Bool

    if currentLanguage == .system {
      // Check system preference
      let preferred = Locale.preferredLanguages.first ?? "en"
      useChinese = preferred.hasPrefix("zh")
    } else {
      useChinese = currentLanguage == .chinese
    }

    if useChinese {
      if let val = zhHans[key] { return val }
      if let val = localizedString(key, languageCode: "zh-Hans") { return val }
      return key
    }

    if let val = en[key] { return val }
    if let val = localizedString(key, languageCode: "en") { return val }
    return key
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
    "Global": "Global",
    "Global (Default)": "Global (Default)",
    "Scope: Global": "Scope: Global",
    "Scope: Profile (%@)": "Scope: Profile (%@)",

    "Resolution and FPS": "Resolution and FPS",
    "Resolution": "Resolution",
    "Match Display": "Match Display",
    "Custom": "Custom",
    "Custom Resolution": "Custom Resolution",
    "FPS": "FPS",
    "Custom FPS": "Custom FPS",

    "Resolution Scale": "Resolution Scale",
    "Resolution Scale Ratio": "Resolution Scale Ratio",
    "Auto Adjust Bitrate": "Auto Adjust Bitrate",
    "Ignore Aspect Ratio": "Ignore Aspect Ratio",
    "Show Local Cursor": "Show Local Cursor",

    "Remote Resolution": "Remote Resolution",
    "Remote Resolution Value": "Remote Resolution Value",
    "Remote Custom Resolution": "Remote Custom Resolution",
    "Remote FPS": "Remote FPS",
    "Remote FPS Value": "Remote FPS Value",
    "Remote Custom FPS": "Remote Custom FPS",
    "Remote overrides apply to the host render mode only.":
      "Remote overrides apply to the host render mode only.",
    "Enable Remote Resolution/FPS to override the /launch mode parameter.":
      "Enable Remote Resolution/FPS to override the /launch mode parameter.",

    "Bitrate": "Bitrate",

    "Video": "Video",
    "Video Codec": "Video Codec",
    "HDR": "HDR",
    "Frame Pacing": "Frame Pacing",
    "Lowest Latency": "Lowest Latency",
    "Smoothest Video": "Smoothest Video",

    "Audio": "Audio",
    "Audio Configuration": "Audio Configuration",
    "Stereo": "Stereo",
    "5.1 surround sound": "5.1 surround sound",
    "7.1 surround sound": "7.1 surround sound",
    "Play Sound on Host": "Play Sound on Host",
    "V-Sync": "V-Sync",
    "Performance Overlay": "Performance Overlay",
    "Performance Overlay (⌃⌥S)": "Performance Overlay (⌃⌥S)",
    "Show Connection Warnings": "Show Connection Warnings",
    "Unlock max bitrate (1000 Mbps)": "Unlock max bitrate (1000 Mbps)",
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

    "Mouse": "Mouse",
    "Optimize mouse for remote desktop": "Optimize mouse for remote desktop",
    "Swap Left and Right Mouse Buttons": "Swap Left and Right Mouse Buttons",
    "Reverse Mouse Scrolling Direction": "Reverse Mouse Scrolling Direction",
    "Touchscreen Mode": "Touchscreen Mode",
    "Trackpad": "Trackpad",
    "Touchscreen": "Touchscreen",

    "Behaviour": "Behaviour",
    "Automatically Fullscreen Stream Window": "Automatically Fullscreen Stream Window",
    "Quit App After Stream": "Quit App After Stream",
    "Visuals": "Visuals",
    "Dim Non-Hovered Apps": "Dim Non-Hovered Apps",
    "Custom Artwork Dimensions": "Custom Artwork Dimensions",

    "Geforce Experience": "Geforce Experience",
    "Optimize Game Settings": "Optimize Game Settings",

    "Not supported": "Not supported",
    "Settings": "Settings",
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
    "Global": "全局",
    "Global (Default)": "全局（默认）",
    "Scope: Global": "当前作用范围：全局",
    "Scope: Profile (%@)": "当前作用范围：配置文件（%@）",

    "Resolution and FPS": "分辨率和 FPS",
    "Resolution": "分辨率",
    "Match Display": "跟随屏幕",
    "Custom": "自定义",
    "Custom Resolution": "自定义分辨率",
    "FPS": "帧率",
    "Custom FPS": "自定义帧率",

    "Resolution Scale": "分辨率缩放",
    "Resolution Scale Ratio": "缩放比例",
    "Auto Adjust Bitrate": "自动调整码率",
    "Ignore Aspect Ratio": "忽略宽高比限制",
    "Show Local Cursor": "显示本地光标",

    "Remote Resolution": "远程分辨率",
    "Remote Resolution Value": "远程分辨率选项",
    "Remote Custom Resolution": "远程自定义分辨率",
    "Remote FPS": "远程帧率",
    "Remote FPS Value": "远程帧率选项",
    "Remote Custom FPS": "远程自定义帧率",
    "Remote overrides apply to the host render mode only.": "远程选项仅影响主机端渲染/编码模式，不改变本地显示设置。",
    "Enable Remote Resolution/FPS to override the /launch mode parameter.":
      "需开启远程分辨率/帧率才会覆盖启动参数（/launch mode）。",

    "Bitrate": "视频比特率",

    "Video": "视频",
    "Video Codec": "视频编解码器",
    "HDR": "HDR (高动态范围)",
    "Frame Pacing": "帧速调节",
    "Lowest Latency": "最低延迟",
    "Smoothest Video": "最流畅视频",

    "Audio": "音频",
    "Audio Configuration": "音频配置",
    "Stereo": "立体声",
    "5.1 surround sound": "5.1 环绕声",
    "7.1 surround sound": "7.1 环绕声",
    "Play Sound on Host": "在主机上播放声音",
    "V-Sync": "垂直同步",
    "Performance Overlay": "显示性能统计",
    "Performance Overlay (⌃⌥S)": "显示性能统计（⌃⌥S）",
    "Show Connection Warnings": "显示连接质量警告",
    "Unlock max bitrate (1000 Mbps)": "解锁最高码率（最高 1000 Mbps）",
    "Volume": "音量",

    "Controller": "手柄设置",
    "Multi-Controller Mode": "多手柄模式",
    "Single": "单人",
    "Auto": "自动",
    "Rumble Controller": "手柄震动",
    "Buttons": "按键",
    "Swap A/B and X/Y Buttons": "交换手柄的 A/B 和 X/Y 按钮",
    "Emulate Guide Button": "模拟 Guide 键 (长按 Start)",
    "Mouse": "鼠标",
    "Optimize mouse for remote desktop": "优化远程桌面鼠标 (绝对位置)",
    "Swap Left and Right Mouse Buttons": "交换鼠标左右键",
    "Reverse Mouse Scrolling Direction": "反转鼠标滚动方向",
    "Touchscreen Mode": "触摸屏模式",
    "Trackpad": "触控板",
    "Touchscreen": "触摸屏",

    "Behaviour": "行为",
    "Automatically Fullscreen Stream Window": "自动全屏显示",
    "Quit App After Stream": "流传输结束后退出程序",
    "Controller Driver": "手柄驱动",
    "Mouse Driver": "鼠标驱动",
    "HID": "HID (推荐)",
    "MFi": "MFi (原生)",
    "Keyboard": "键盘",
    "Capture system keyboard shortcuts": "捕获系统快捷键",

    "Visuals": "界面",
    "Dim Non-Hovered Apps": "调暗未选中应用封面",
    "Custom Artwork Dimensions": "自定义封面尺寸",

    "Geforce Experience": "Geforce Experience",
    "Optimize Game Settings": "优化游戏设置",

    "Not supported": "不支持",
    "Settings": "设置",
  ]
}
