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

  private func safeDisplayPixelSize() -> CGSize? {
    guard let screen = NSScreen.main else { return nil }
    guard #available(macOS 12.0, *) else { return nil }

    let insets = screen.safeAreaInsets
    let safeFrame = NSRect(
      x: screen.frame.origin.x + insets.left,
      y: screen.frame.origin.y + insets.bottom,
      width: max(0.0, screen.frame.size.width - insets.left - insets.right),
      height: max(0.0, screen.frame.size.height - insets.top - insets.bottom)
    )
    guard safeFrame.size.width > 0.0, safeFrame.size.height > 0.0 else { return nil }

    let scale = max(1.0, screen.backingScaleFactor)
    func even(_ v: CGFloat) -> CGFloat {
      let i = Int(v.rounded(.down))
      return CGFloat(i - (i % 2))
    }

    return CGSize(width: even(safeFrame.width * scale), height: even(safeFrame.height * scale))
  }

  private func matchDisplayLabel() -> String {
    let base = languageManager.localize("Match Display")
    let displayMode = settingsModel.selectedDisplayMode
    let native = nativeDisplayPixelSize()
    let safe = safeDisplayPixelSize()

    if displayMode == "Fullscreen", let safe {
      return "\(base) (\(languageManager.localize("Fullscreen Safe Area")) \(Int(safe.width))×\(Int(safe.height)))"
    }

    if let native {
      let prefix =
        (displayMode == "Borderless Windowed")
        ? languageManager.localize("Full Panel")
        : ((safe != nil && safe != native) ? languageManager.localize("Full Panel") : "")
      if prefix.isEmpty {
        return "\(base) (\(Int(native.width))×\(Int(native.height)))"
      }
      return "\(base) (\(prefix) \(Int(native.width))×\(Int(native.height)))"
    }

    return base
  }

  private func displayResolutionModeHint() -> String {
    if settingsModel.selectedDisplayMode == "Fullscreen" {
      return languageManager.localize("Fullscreen Safe Resolution hint")
    }
    return languageManager.localize("Full Panel Resolution hint")
  }

  private func statusDotImage(state: Int) -> Image {
    let color: NSColor = (state == 1) ? .systemGreen : (state == 0 ? .systemRed : .systemGray)
    let size = NSSize(width: 8, height: 8)
    let image = NSImage(size: size)
    image.lockFocus()
    color.setFill()
    let rect = NSRect(origin: .zero, size: size)
    NSBezierPath(ovalIn: rect).fill()
    image.unlockFocus()
    return Image(nsImage: image)
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
                ForEach(settingsModel.connectionCandidates) { candidate in
                  HStack {
                    if candidate.id != "Auto" {
                      statusDotImage(state: candidate.state)
                        .padding(.trailing, 4)
                    }
                    Text(candidate.label)
                  }
                  .tag(candidate.id)
                }
              }
              .labelsHidden()

              Button(action: {
                guard let uuid = settingsModel.selectedHost?.id,
                  uuid != SettingsModel.globalHostId,
                  let hosts = DataManager().getHosts() as? [TemporaryHost],
                  let host = hosts.first(where: { !$0.uuid.isEmpty && $0.uuid == uuid })
                else { return }

                let editor = ConnectionEditorViewController(host: host)
                NSApp.keyWindow?.contentViewController?.presentAsSheet(editor)
              }) {
                Image(systemName: "gearshape")
              }
              .buttonStyle(.plain)

              Button(action: {
                if let uuid = settingsModel.selectedHost?.id, uuid != SettingsModel.globalHostId {
                  settingsModel.refreshConnectionCandidates()
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
          .onAppear {
            settingsModel.refreshConnectionCandidates()
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

          Text(displayResolutionModeHint())
            .font(.footnote)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)

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

        Spacer()
          .frame(height: 32)

        StreamRiskSummarySection(assessment: settingsModel.streamRiskAssessment)
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

        Spacer()
          .frame(height: 32)

        StreamRiskSummarySection(assessment: settingsModel.streamRiskAssessment)
      }
      .padding()
    }
  }
}

struct AudioView: View {
  @EnvironmentObject private var settingsModel: SettingsModel
  @ObservedObject var languageManager = LanguageManager.shared
  @ObservedObject var micManager = MicrophoneManager.shared

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

        Spacer().frame(height: 16)

        FormSection(title: "Microphone") {
          ToggleCell(
            title: "Enable Microphone",
            hintKey: "Microphone hint",
            boolBinding: $settingsModel.enableMicrophone
          )
          .onChange(of: settingsModel.enableMicrophone) { newValue in
            guard newValue else { return }
            micManager.refreshPermissionStatus()
            switch micManager.permissionStatus {
            case .authorized:
              break
            case .notDetermined:
              micManager.requestPermission()
            case .denied, .restricted:
              settingsModel.enableMicrophone = false
            @unknown default:
              settingsModel.enableMicrophone = false
            }
          }

          Divider()

          MicPermissionRow(micManager: micManager)

          Divider()

          FormCell(
            title: "Microphone Device", contentWidth: 220,
            content: {
              Picker("", selection: $micManager.selectedDeviceUID) {
                Text(languageManager.localize("System Default"))
                  .tag("")
                ForEach(micManager.devices) { device in
                  Text(device.name).tag(device.uid)
                }
              }
              .labelsHidden()
              .frame(maxWidth: .infinity, alignment: .trailing)
            })
          .onAppear {
            micManager.refreshDevices()
          }

          Divider()

          MicTestRow(micManager: micManager)
        }
      }
      .padding()
    }
  }
}

private struct MicPermissionRow: View {
  @ObservedObject var micManager: MicrophoneManager
  @ObservedObject var languageManager = LanguageManager.shared

  var body: some View {
    HStack {
      Text(languageManager.localize("Microphone Permission"))
      Spacer()

      switch micManager.permissionStatus {
      case .authorized:
        Label(languageManager.localize("Authorized"), systemImage: "checkmark.circle.fill")
          .foregroundColor(.green)
          .font(.callout)
      case .denied, .restricted:
        HStack(spacing: 8) {
          Label(languageManager.localize("Denied"), systemImage: "xmark.circle.fill")
            .foregroundColor(.red)
            .font(.callout)
          Button(languageManager.localize("Open Settings")) {
            micManager.openSystemPreferences()
          }
          .controlSize(.small)
        }
      case .notDetermined:
        HStack(spacing: 8) {
          Text(languageManager.localize("Not Determined"))
            .foregroundColor(.secondary)
            .font(.callout)
          Button(languageManager.localize("Request")) {
            micManager.requestPermission()
          }
          .controlSize(.small)
        }
      @unknown default:
        Text("Unknown")
          .foregroundColor(.secondary)
          .font(.callout)
      }
    }
    .onAppear {
      micManager.refreshPermissionStatus()
    }
  }
}

private struct MicTestRow: View {
  @ObservedObject var micManager: MicrophoneManager
  @ObservedObject var languageManager = LanguageManager.shared

  var body: some View {
    VStack(spacing: 8) {
      HStack {
        Text(languageManager.localize("Test Microphone"))
        Spacer()
        Button(micManager.isTesting
               ? languageManager.localize("Stop")
               : languageManager.localize("Start Test")) {
          if micManager.isTesting {
            micManager.stopTest()
          } else {
            micManager.startTest()
          }
        }
        .controlSize(.small)
        .disabled(micManager.permissionStatus != .authorized)
      }

      if micManager.isTesting {
        MicLevelBar(level: micManager.inputLevel)
          .frame(height: 8)
          .animation(.easeOut(duration: 0.1), value: micManager.inputLevel)
      }
    }
  }
}

private struct MicLevelBar: View {
  let level: Float

  var body: some View {
    GeometryReader { geo in
      ZStack(alignment: .leading) {
        RoundedRectangle(cornerRadius: 4)
          .fill(Color.gray.opacity(0.2))
        RoundedRectangle(cornerRadius: 4)
          .fill(barColor)
          .frame(width: geo.size.width * CGFloat(min(level, 1.0)))
      }
    }
  }

  private var barColor: Color {
    if level > 0.8 { return .red }
    if level > 0.5 { return .orange }
    return .green
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
            hintKey: "Absolute Mouse Mode hint",
            boolBinding: $settingsModel.absoluteMouseMode)

          Divider()

          VStack(alignment: .leading, spacing: 8) {
            HStack {
              Text(languageManager.localize("Pointer Speed"))
              Spacer()
              Text("\(Int((settingsModel.pointerSensitivity * 100).rounded()))%")
                .availableMonospacedDigit()
                .foregroundColor(.secondary)
            }

            Slider(value: $settingsModel.pointerSensitivity, in: 0.5...2.0, step: 0.05) {
              EmptyView()
            } minimumValueLabel: {
              Text("50%")
                .font(.caption)
                .availableMonospacedDigit()
            } maximumValueLabel: {
              Text("200%")
                .font(.caption)
                .availableMonospacedDigit()
            } onEditingChanged: { _ in

            }

            Text(languageManager.localize("Pointer Speed hint"))
              .font(.footnote)
              .foregroundColor(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading)
          }

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
  @SwiftUI.State private var showLiveLogViewer = false
  @SwiftUI.State private var showHostResetConfirm = false
  @SwiftUI.State private var showFullResetConfirm = false
  @SwiftUI.State private var showResetDone = false
  @SwiftUI.State private var resetDoneMessageKey = ""

  private func debugLogFileURL(fileName: String) -> URL? {
    guard let libraryDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
    else {
      return nil
    }
    return libraryDir
      .appendingPathComponent("Logs", isDirectory: true)
      .appendingPathComponent("Moonlight", isDirectory: true)
      .appendingPathComponent(fileName, isDirectory: false)
  }

  private func rawDebugLogFileURL() -> URL? {
    debugLogFileURL(fileName: "moonlight-debug.log")
  }

  private func curatedDebugLogFileURL() -> URL? {
    debugLogFileURL(fileName: "moonlight-debug-curated.log")
  }

  @MainActor
  private func openDebugLogFolder() {
    guard let logURL = rawDebugLogFileURL() else { return }
    let dirURL = logURL.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
    NSWorkspace.shared.activateFileViewerSelecting([dirURL])
  }

  @MainActor
  private func viewDebugLog() {
    showLiveLogViewer = true
  }

  @MainActor
  private func exportRawDebugLog() {
    guard let logURL = rawDebugLogFileURL() else { return }
    let dirURL = logURL.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

    if !FileManager.default.fileExists(atPath: logURL.path) {
      try? "".write(to: logURL, atomically: true, encoding: .utf8)
    }

    let panel = NSSavePanel()
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = "moonlight-debug.log"
    if #available(macOS 11.0, *) {
      panel.allowedContentTypes = [.plainText]
    } else {
      panel.allowedFileTypes = ["log", "txt"]
    }

    let saveAction: (URL) -> Void = { destinationURL in
      do {
        if FileManager.default.fileExists(atPath: destinationURL.path) {
          try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: logURL, to: destinationURL)
      } catch {
        NSApp.presentError(error)
      }
    }

    let response = panel.runModal()
    if response == .OK, let destinationURL = panel.url {
      saveAction(destinationURL)
    }
  }

  @MainActor
  private func openDebugLogInExternalEditor() {
    let fileName = settingsModel.debugLogMode == "raw" ? "moonlight-debug.log" : "moonlight-debug-curated.log"
    guard let logURL = debugLogFileURL(fileName: fileName) else { return }
    let dirURL = logURL.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

    if !FileManager.default.fileExists(atPath: logURL.path) {
      try? "".write(to: logURL, atomically: true, encoding: .utf8)
    }

    NSWorkspace.shared.open(logURL)
  }

  private func clearPairingAndCacheFiles() {
    let fileManager = FileManager.default
    var targets: [URL] = []

    if let documentsDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
      targets.append(documentsDir.appendingPathComponent("client.crt", isDirectory: false))
      targets.append(documentsDir.appendingPathComponent("client.key", isDirectory: false))
      targets.append(documentsDir.appendingPathComponent("client.p12", isDirectory: false))
    }

    if let appSupportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
      let moonlightDir = appSupportDir.appendingPathComponent("Moonlight", isDirectory: true)
      targets.append(moonlightDir.appendingPathComponent("Moonlight_macOS.sqlite", isDirectory: false))
      targets.append(moonlightDir.appendingPathComponent("Moonlight_macOS.sqlite-shm", isDirectory: false))
      targets.append(moonlightDir.appendingPathComponent("Moonlight_macOS.sqlite-wal", isDirectory: false))
    }

    for fileURL in targets where fileManager.fileExists(atPath: fileURL.path) {
      try? fileManager.removeItem(at: fileURL)
    }
  }

  private func clearAllHosts() {
    let dataManager = DataManager()
    guard let hosts = dataManager.getHosts() as? [TemporaryHost] else { return }

    for host in hosts {
      dataManager.remove(host)
    }
  }

  @MainActor
  private func restartApplication() {
    let appURL = Bundle.main.bundleURL
    let configuration = NSWorkspace.OpenConfiguration()

    NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, _ in
      DispatchQueue.main.async {
        NSApp.terminate(nil)
      }
    }
  }

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

        Spacer()
          .frame(height: 32)

        FormSection(title: "Misc") {
          FormCell(title: "Debug Log", contentWidth: 0) {
            HStack(spacing: 8) {
              Button(languageManager.localize("View Log")) {
                Task { @MainActor in
                  viewDebugLog()
                }
              }
              Button(languageManager.localize("Open Folder")) {
                Task { @MainActor in
                  openDebugLogFolder()
                }
              }
              Button(languageManager.localize("Open in Editor")) {
                Task { @MainActor in
                  openDebugLogInExternalEditor()
                }
              }
              Button(languageManager.localize("Export Raw Log…")) {
                exportRawDebugLog()
              }
            }
          }

          FormCell(title: "Pairing Cache", contentWidth: 0) {
            VStack(alignment: .trailing, spacing: 14) {
              Button(role: .destructive) {
                showHostResetConfirm = true
              } label: {
                Text(languageManager.localize("Reset Hosts (Recommended)"))
              }
              .buttonStyle(.borderedProminent)
              .tint(.red)

              Text(languageManager.localize("Advanced Reset Separator"))
                .font(.caption)
                .foregroundStyle(.secondary)

              Button(role: .destructive) {
                showFullResetConfirm = true
              } label: {
                Text(languageManager.localize("Full Reset (Pairing + Cache)"))
              }
              .buttonStyle(.bordered)
              .tint(.red)
              .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
          }
        }
      }
      .padding()
    }
    .sheet(isPresented: $showLiveLogViewer) {
      DebugLogLiveView(rawLogURL: rawDebugLogFileURL(), curatedLogURL: curatedDebugLogFileURL())
        .environmentObject(settingsModel)
    }
    .alert(languageManager.localize("Dangerous Operation"), isPresented: $showHostResetConfirm) {
      Button(languageManager.localize("Cancel"), role: .cancel) {}
      Button(languageManager.localize("I Understand, Continue"), role: .destructive) {
        clearAllHosts()
        resetDoneMessageKey = "Hosts reset completed message"
        showResetDone = true
      }
    } message: {
      Text(languageManager.localize("Reset Hosts Confirm Message"))
    }
    .alert(languageManager.localize("Dangerous Operation"), isPresented: $showFullResetConfirm) {
      Button(languageManager.localize("Cancel"), role: .cancel) {}
      Button(languageManager.localize("I Understand, Continue"), role: .destructive) {
        clearAllHosts()
        clearPairingAndCacheFiles()
        resetDoneMessageKey = "Full reset completed message"
        showResetDone = true
      }
    } message: {
      Text(languageManager.localize("Full Reset Confirm Message"))
    }
    .alert(languageManager.localize("Reset Completed"), isPresented: $showResetDone) {
      Button(languageManager.localize("Restart App")) {
        restartApplication()
      }
    } message: {
      Text(languageManager.localize(resetDoneMessageKey))
    }
  }
}

private enum DebugLogViewMode: String {
  case curated
  case raw
}

private enum DebugLogTimeScope: String {
  case all
  case launch = "launch"
  case sinceClear = "since_clear"
}

private final class DebugLogLiveModel: ObservableObject {
  @Published var refreshToken = UUID()

  private let rawLogURL: URL
  private let curatedLogURL: URL
  private let maxRetainedLines = 3000
  private let initialTailBytes: UInt64 = 1_024 * 1_024
  private var rawText: String = ""
  private var curatedText: String = ""
  private var rawFileSize: UInt64 = 0
  private var curatedFileSize: UInt64 = 0
  private var timer: Timer?

  init(rawLogURL: URL, curatedLogURL: URL) {
    self.rawLogURL = rawLogURL
    self.curatedLogURL = curatedLogURL
  }

  func start() {
    ensureLogFileExists(at: rawLogURL)
    ensureLogFileExists(at: curatedLogURL)
    reloadAll()

    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
      self?.pollForUpdates()
    }
    if let timer {
      RunLoop.main.add(timer, forMode: .common)
    }
  }

  func stop() {
    timer?.invalidate()
    timer = nil
  }

  func entries(
    mode: DebugLogViewMode,
    minimumLevel: DebugLogLevel,
    showSystemNoise: Bool
  ) -> [DebugLogEntry] {
    switch mode {
    case .raw:
      return DebugLogParser.parseEntries(from: rawText).filter {
        DebugLogParser.matchesMinimumLevel($0.level, minimumLevel: minimumLevel)
      }
    case .curated:
      if showSystemNoise {
        return DebugLogParser.curatedEntries(
          fromRawText: rawText,
          minimumLevel: minimumLevel,
          showSystemNoise: true
        )
      }
      if !curatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return DebugLogParser.parseEntries(from: curatedText).filter {
          DebugLogParser.matchesMinimumLevel($0.level, minimumLevel: minimumLevel)
        }
      }
      return DebugLogParser.curatedEntries(
        fromRawText: rawText,
        minimumLevel: minimumLevel,
        showSystemNoise: false
      )
    }
  }

  private func ensureLogFileExists(at url: URL) {
    let dirURL = url.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: url.path) {
      try? "".write(to: url, atomically: true, encoding: .utf8)
    }
  }

  private func reloadAll() {
    rawText = readTailText(from: rawLogURL, maxBytes: initialTailBytes)
    curatedText = readTailText(from: curatedLogURL, maxBytes: initialTailBytes)
    rawFileSize = fileSize(of: rawLogURL)
    curatedFileSize = fileSize(of: curatedLogURL)
    refreshToken = UUID()
  }

  private func pollForUpdates() {
    var changed = false

    let latestRawSize = fileSize(of: rawLogURL)
    if latestRawSize < rawFileSize {
      rawText = readTailText(from: rawLogURL, maxBytes: initialTailBytes)
      rawFileSize = latestRawSize
      changed = true
    } else if latestRawSize > rawFileSize {
      if let delta = readDeltaText(from: rawLogURL, startOffset: rawFileSize) {
        rawText = trimToLastLines(rawText + delta, maxLines: maxRetainedLines)
      }
      rawFileSize = latestRawSize
      changed = true
    }

    let latestCuratedSize = fileSize(of: curatedLogURL)
    if latestCuratedSize < curatedFileSize {
      curatedText = readTailText(from: curatedLogURL, maxBytes: initialTailBytes)
      curatedFileSize = latestCuratedSize
      changed = true
    } else if latestCuratedSize > curatedFileSize {
      if let delta = readDeltaText(from: curatedLogURL, startOffset: curatedFileSize) {
        curatedText = trimToLastLines(curatedText + delta, maxLines: maxRetainedLines)
      }
      curatedFileSize = latestCuratedSize
      changed = true
    }

    if changed {
      refreshToken = UUID()
    }
  }

  private func fileSize(of url: URL) -> UInt64 {
    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
  }

  private func readTailText(from url: URL, maxBytes: UInt64) -> String {
    let size = fileSize(of: url)
    guard let file = try? FileHandle(forReadingFrom: url) else {
      return ""
    }
    defer { try? file.close() }

    do {
      if size > maxBytes {
        try file.seek(toOffset: size - maxBytes)
      } else {
        try file.seek(toOffset: 0)
      }
      let data = try file.readToEnd() ?? Data()
      return trimToLastLines(String(decoding: data, as: UTF8.self), maxLines: maxRetainedLines)
    } catch {
      return ""
    }
  }

  private func readDeltaText(from url: URL, startOffset: UInt64) -> String? {
    guard let file = try? FileHandle(forReadingFrom: url) else {
      return nil
    }
    defer { try? file.close() }

    do {
      try file.seek(toOffset: startOffset)
      let data = try file.readToEnd() ?? Data()
      guard !data.isEmpty else { return nil }
      return String(decoding: data, as: UTF8.self)
    } catch {
      return nil
    }
  }

  private func trimToLastLines(_ text: String, maxLines: Int) -> String {
    guard maxLines > 0 else { return text }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    guard lines.count > maxLines else { return text }
    return lines.suffix(maxLines).joined(separator: "\n")
  }
}

private struct DebugLogLevelBadge: View {
  let level: DebugLogLevel

  private var color: Color {
    switch level {
    case .debug:
      return .gray
    case .info:
      return .blue
    case .warn:
      return .orange
    case .error:
      return .red
    case .all, .unknown:
      return .secondary
    }
  }

  var body: some View {
    Text(level.displayText.uppercased())
      .font(.system(size: 10, weight: .bold, design: .monospaced))
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .foregroundColor(.white)
      .background(RoundedRectangle(cornerRadius: 4).fill(color))
  }
}

private struct DebugLogRowView: View {
  let entry: DebugLogEntry

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Text(entry.timestampText ?? "--")
        .font(.system(size: 11, design: .monospaced))
        .foregroundColor(.secondary)
        .frame(width: 170, alignment: .leading)

      DebugLogLevelBadge(level: entry.level)
        .frame(width: 58, alignment: .leading)

      VStack(alignment: .leading, spacing: 2) {
        Text(entry.message.isEmpty ? entry.rawLine : entry.message)
          .font(.system(size: 12, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)

        if entry.count > 1 {
          Text("×\(entry.count)")
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundColor(.secondary)
        }
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(
      entry.isNoiseSummary ? Color.orange.opacity(0.07) : Color.clear
    )
    .cornerRadius(4)
  }
}

private struct DebugLogLiveView: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var settingsModel: SettingsModel
  @ObservedObject var languageManager = LanguageManager.shared
  @StateObject private var model: DebugLogLiveModel
  @SwiftUI.State private var searchText: String = ""
  @SwiftUI.State private var renderedEntries: [DebugLogEntry] = []
  @SwiftUI.State private var totalRows: Int = 0
  @SwiftUI.State private var detailEntry: DebugLogEntry?
  @SwiftUI.State private var clearFromDate: Date?
  @SwiftUI.State private var appLaunchDate: Date = NSRunningApplication.current.launchDate ?? Date()

  init(rawLogURL: URL?, curatedLogURL: URL?) {
    let baseDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
      .appendingPathComponent("Logs", isDirectory: true)
      .appendingPathComponent("Moonlight", isDirectory: true)
      ?? URL(fileURLWithPath: NSTemporaryDirectory())
    let fallbackRaw = baseDir.appendingPathComponent("moonlight-debug.log")
    let fallbackCurated = baseDir.appendingPathComponent("moonlight-debug-curated.log")
    _model = SwiftUI.StateObject(
      wrappedValue: DebugLogLiveModel(
        rawLogURL: rawLogURL ?? fallbackRaw,
        curatedLogURL: curatedLogURL ?? fallbackCurated
      ))
  }

  private var currentMode: DebugLogViewMode {
    settingsModel.debugLogMode == "raw" ? .raw : .curated
  }

  private var currentMinimumLevel: DebugLogLevel {
    switch settingsModel.debugLogMinLevel {
    case "all": return .all
    case "debug": return .debug
    case "warn": return .warn
    case "error": return .error
    default: return .info
    }
  }

  private var currentTimeScope: DebugLogTimeScope {
    DebugLogTimeScope(rawValue: settingsModel.debugLogTimeScope) ?? .launch
  }

  private var effectiveStartDate: Date? {
    switch currentTimeScope {
    case .all:
      return nil
    case .launch:
      return appLaunchDate
    case .sinceClear:
      return clearFromDate ?? appLaunchDate
    }
  }

  private static let logTimestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return formatter
  }()

  private func filterEntriesByTimeScope(_ entries: [DebugLogEntry]) -> [DebugLogEntry] {
    guard let startDate = effectiveStartDate else {
      return entries
    }
    return entries.filter { entry in
      if let ts = entry.timestamp {
        return ts >= startDate
      }
      if let text = entry.timestampText, let parsed = Self.logTimestampFormatter.date(from: text) {
        return parsed >= startDate
      }
      return false
    }
  }

  private func refreshRenderedEntries() {
    let base = model.entries(
      mode: currentMode,
      minimumLevel: currentMinimumLevel,
      showSystemNoise: settingsModel.debugLogShowSystemNoise
    )
    let scopedBase = filterEntriesByTimeScope(base)
    let foldedBase = DebugLogParser.foldConsecutiveDuplicates(scopedBase)
    totalRows = foldedBase.count

    let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    renderedEntries = foldedBase.filter { entry in
      let keywordPass: Bool
      if keyword.isEmpty {
        keywordPass = true
      } else {
        keywordPass = entry.searchableText.lowercased().contains(keyword)
      }
      return keywordPass
    }
  }

  private func copyFilteredEntries() {
    let text = renderedEntries.map(\.rawLine).joined(separator: "\n")
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  private func exportFilteredEntries() {
    let snapshotEntries = renderedEntries
    let snapshotMode = settingsModel.debugLogMode
    let snapshotMinLevel = settingsModel.debugLogMinLevel
    let snapshotShowNoise = settingsModel.debugLogShowSystemNoise
    let snapshotSearch = searchText
    let snapshotTotalRows = totalRows
    let snapshotTimeScope = settingsModel.debugLogTimeScope
    let snapshotStartDate = effectiveStartDate

    let panel = NSSavePanel()
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = "moonlight-debug-filtered.log"
    if #available(macOS 11.0, *) {
      panel.allowedContentTypes = [.plainText]
    } else {
      panel.allowedFileTypes = ["log", "txt"]
    }

    let header = """
      # Moonlight Filtered Log
      # Generated: \(ISO8601DateFormatter().string(from: Date()))
      # Log Mode: \(snapshotMode)
      # Min Level: \(snapshotMinLevel)
      # Show System Noise: \(snapshotShowNoise)
      # Search: \(snapshotSearch.isEmpty ? "(empty)" : snapshotSearch)
      # Time Scope: \(snapshotTimeScope)
      # Start At: \(snapshotStartDate.map { ISO8601DateFormatter().string(from: $0) } ?? "(none)")
      # Filtered Rows: \(snapshotEntries.count)
      # Total Rows: \(snapshotTotalRows)

      """
    let body = snapshotEntries.map(\.rawLine).joined(separator: "\n")
    let content = header + body + "\n"

    let saveAction: (URL) -> Void = { destinationURL in
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          try content.write(to: destinationURL, atomically: true, encoding: .utf8)
        } catch {
          DispatchQueue.main.async {
            NSApp.presentError(error)
          }
        }
      }
    }

    if let window = NSApp.keyWindow ?? NSApp.mainWindow {
      panel.beginSheetModal(for: window) { response in
        if response == .OK, let destinationURL = panel.url {
          saveAction(destinationURL)
        }
      }
    } else if panel.runModal() == .OK, let destinationURL = panel.url {
      saveAction(destinationURL)
    }
  }

  var body: some View {
    VStack(spacing: 12) {
      HStack {
        Text(languageManager.localize("Live Debug Log"))
          .font(.headline)
        Spacer()
        Button(languageManager.localize("Export Filtered Log…")) {
          exportFilteredEntries()
        }
        Button(languageManager.localize("Copy All")) {
          copyFilteredEntries()
        }
        Button(languageManager.localize("Close")) {
          dismiss()
        }
      }

      HStack(spacing: 8) {
        Text(languageManager.localize("Log Mode"))
          .font(.caption)
          .foregroundColor(.secondary)
        Picker("", selection: $settingsModel.debugLogMode) {
          Text(languageManager.localize("Curated Log")).tag("curated")
          Text(languageManager.localize("Raw Log")).tag("raw")
        }
        .pickerStyle(.segmented)
        .frame(width: 230)

        Picker("", selection: $settingsModel.debugLogMinLevel) {
          Text("All").tag("all")
          Text("Debug").tag("debug")
          Text("Info").tag("info")
          Text("Warn").tag("warn")
          Text("Error").tag("error")
        }
        .frame(width: 140)

        Toggle(languageManager.localize("Show System Noise"), isOn: $settingsModel.debugLogShowSystemNoise)
          .toggleStyle(.checkbox)
          .frame(width: 180, alignment: .leading)

        Toggle(languageManager.localize("Auto Scroll"), isOn: $settingsModel.debugLogAutoScroll)
          .toggleStyle(.checkbox)
          .frame(width: 130, alignment: .leading)
      }

      HStack(spacing: 8) {
        Text(languageManager.localize("Log Range"))
          .font(.caption)
          .foregroundColor(.secondary)
        Picker("", selection: $settingsModel.debugLogTimeScope) {
          Text(languageManager.localize("All History")).tag("all")
          Text(languageManager.localize("This Launch")).tag("launch")
          Text(languageManager.localize("Since Clear")).tag("since_clear")
        }
        .pickerStyle(.segmented)
        .frame(width: 280)

        Button(languageManager.localize("Clear From Now")) {
          clearFromDate = Date()
          settingsModel.debugLogTimeScope = DebugLogTimeScope.sinceClear.rawValue
          refreshRenderedEntries()
        }

        if let startDate = effectiveStartDate, currentTimeScope != .all {
          Text("\(languageManager.localize("Since")): \(Self.logTimestampFormatter.string(from: startDate))")
            .font(.caption)
            .foregroundColor(.secondary)
        }

        Spacer()
      }

      HStack(spacing: 8) {
        TextField("Search...", text: $searchText)
          .textFieldStyle(.roundedBorder)

        Text("\(languageManager.localize("Filtered Rows")): \(renderedEntries.count)")
          .font(.caption)
          .foregroundColor(.secondary)
        Text("\(languageManager.localize("Total Rows")): \(totalRows)")
          .font(.caption)
          .foregroundColor(.secondary)
      }

      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 2) {
            if renderedEntries.isEmpty {
              Text(languageManager.localize("(No logs yet)"))
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 16)
            } else {
              ForEach(renderedEntries) { entry in
                DebugLogRowView(entry: entry)
                  .id(entry.id)
                  .contentShape(Rectangle())
                  .onTapGesture(count: 2) {
                    detailEntry = entry
                  }
              }
            }
            Color.clear
              .frame(height: 1)
              .id("log-end")
          }
          .padding(.vertical, 4)
        }
        .background(Color(NSColor.textBackgroundColor))
        .overlay(
          RoundedRectangle(cornerRadius: 6)
            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
        .onChange(of: renderedEntries.count) { _ in
          guard settingsModel.debugLogAutoScroll else { return }
          withAnimation(.easeOut(duration: 0.12)) {
            proxy.scrollTo("log-end", anchor: .bottom)
          }
        }
      }
    }
    .padding(16)
    .frame(minWidth: 980, minHeight: 560)
    .onAppear {
      appLaunchDate = NSRunningApplication.current.launchDate ?? Date()
      model.start()
      refreshRenderedEntries()
    }
    .onDisappear {
      model.stop()
    }
    .onReceive(model.$refreshToken) { _ in
      refreshRenderedEntries()
    }
    .onChange(of: settingsModel.debugLogMode) { _ in
      refreshRenderedEntries()
    }
    .onChange(of: settingsModel.debugLogShowSystemNoise) { _ in
      refreshRenderedEntries()
    }
    .onChange(of: searchText) { _ in
      refreshRenderedEntries()
    }
    .onChange(of: settingsModel.debugLogMinLevel) { _ in
      refreshRenderedEntries()
    }
    .onChange(of: settingsModel.debugLogTimeScope) { _ in
      if currentTimeScope == .sinceClear && clearFromDate == nil {
        clearFromDate = Date()
      }
      refreshRenderedEntries()
    }
    .sheet(item: $detailEntry) { entry in
      DebugLogEntryDetailView(entry: entry)
    }
  }
}

private struct DebugLogEntryDetailView: View {
  let entry: DebugLogEntry
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 12) {
      HStack {
        Text("Log Detail")
          .font(.headline)
        Spacer()
        Button("Close") {
          dismiss()
        }
      }

      HStack(spacing: 8) {
        DebugLogLevelBadge(level: entry.level)
        Text(entry.timestampText ?? "--")
          .font(.system(size: 12, design: .monospaced))
          .foregroundColor(.secondary)
        if entry.count > 1 {
          Text("×\(entry.count)")
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundColor(.secondary)
        }
        Spacer()
      }

      VStack(alignment: .leading, spacing: 6) {
        Text("Message")
          .font(.caption)
          .foregroundColor(.secondary)
        Text(entry.message.isEmpty ? entry.rawLine : entry.message)
          .font(.system(size: 12, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      Divider()

      VStack(alignment: .leading, spacing: 6) {
        Text("Raw Line")
          .font(.caption)
          .foregroundColor(.secondary)
        ScrollView {
          Text(entry.rawLine)
            .font(.system(size: 12, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      Spacer()
    }
    .padding(16)
    .frame(minWidth: 760, minHeight: 360)
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


struct StreamRiskSummarySection: View {
  let assessment: StreamRiskAssessment
  @ObservedObject var languageManager = LanguageManager.shared
  @SwiftUI.State private var isExpanded = false

  private var riskColor: Color {
    switch assessment.riskLevel {
    case .low:
      return .secondary
    case .medium:
      return .blue
    case .high:
      return .purple
    }
  }

  var body: some View {
    FormSection(title: "Profile Assessment") {
      DisclosureGroup(isExpanded: $isExpanded) {
        VStack(alignment: .leading, spacing: 8) {
          Text(languageManager.localize("Profile assessment hint"))
            .font(.footnote)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)

          Divider()

          HStack {
            Text(languageManager.localize("Profile Level"))
            Spacer()
            Text(assessment.riskLabel)
              .font(.system(.body, design: .rounded).weight(.semibold))
              .foregroundColor(riskColor)
          }

          Divider()

          HStack {
            Text(languageManager.localize("Route Tier"))
            Spacer()
            Text(assessment.routeLabel)
              .foregroundColor(.secondary)
          }

          Divider()

          HStack {
            Text(languageManager.localize("Video Codec"))
            Spacer()
            Text("\(assessment.codecName) · \(assessment.chromaName)")
              .foregroundColor(.secondary)
          }

          Divider()

          HStack {
            Text(languageManager.localize("Compression Budget"))
            Spacer()
            Text("\(assessment.bpppfText) bpppf")
              .availableMonospacedDigit()
              .foregroundColor(.secondary)
          }

          Divider()

          HStack {
            Text(languageManager.localize("Pixel Rate"))
            Spacer()
            Text(assessment.pixelRateText)
              .availableMonospacedDigit()
              .foregroundColor(.secondary)
          }

          if assessment.displayRefreshRateHz > 0 {
            Divider()

            HStack {
              Text(languageManager.localize("Display Refresh"))
              Spacer()
              Text(String(format: "%.0f Hz", assessment.displayRefreshRateHz))
                .availableMonospacedDigit()
                .foregroundColor(.secondary)
            }
          }

          if !assessment.reasons.isEmpty {
            Divider()

            VStack(alignment: .leading, spacing: 6) {
              Text(languageManager.localize("Assessment Reasons"))
                .font(.footnote.weight(.semibold))
                .foregroundColor(.secondary)

              ForEach(Array(assessment.reasons.prefix(3)), id: \.self) { reason in
                Text("• \(reason)")
                  .font(.footnote)
                  .foregroundColor(.secondary)
                  .frame(maxWidth: .infinity, alignment: .leading)
              }
            }
          }

          if !assessment.recommendedFallbacks.isEmpty {
            Divider()

            VStack(alignment: .leading, spacing: 6) {
              Text(languageManager.localize("Suggested Fallbacks"))
                .font(.footnote.weight(.semibold))
                .foregroundColor(.secondary)

              ForEach(Array(assessment.recommendedFallbacks.prefix(3)), id: \.summaryLine) { recommendation in
                Text("• \(recommendation.summaryLine)")
                  .font(.footnote)
                  .foregroundColor(.secondary)
                  .frame(maxWidth: .infinity, alignment: .leading)
              }
            }
          }
        }
      } label: {
        HStack {
          Text(languageManager.localize("Analyze Current Profile"))
          Spacer()
          Text(isExpanded ? languageManager.localize("Expanded") : languageManager.localize("Tap to Analyze"))
            .font(.footnote)
            .foregroundColor(.secondary)
        }
      }
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
