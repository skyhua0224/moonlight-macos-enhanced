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
      return "\(base) (\(Int(safe.width))×\(Int(safe.height)))"
    }

    if let native {
      return "\(base) (\(Int(native.width))×\(Int(native.height)))"
    }

    return base
  }

  private func displayResolutionModeHint() -> String {
    return languageManager.localize("Match Display Resolution hint")
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
      LazyVStack {
        FormSection(title: "General") {
          if let hosts = SettingsModel.hosts {
            FormCell(title: "Profile:", contentWidth: 150) {
              Picker("", selection: $settingsModel.selectedHost) {
                ForEach(hosts, id: \.self) { host in
                  if let host {
                    let name =
                      host.id == SettingsModel.globalHostId
                      ? languageManager.localize("Default Profile") : host.name
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
                  ? languageManager.localize("Default Profile Scope")
                  : String(
                    format: languageManager.localize("Host Profile Scope (%@)"),
                    settingsModel.selectedHost?.name ?? "")
              )
              .font(.footnote)
              .foregroundColor(.secondary)
              .multilineTextAlignment(.trailing)
            }

            Divider()
          }

          if settingsModel.selectedHost?.id == SettingsModel.globalHostId {
            FormCell(title: "Connection Method", contentWidth: 0) {
              Text(languageManager.localize("Connection Method Default Profile Hint"))
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
          } else {
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
            .onChange(of: settingsModel.selectedHost?.id) { newValue in
              if let newValue, newValue != SettingsModel.globalHostId {
                settingsModel.refreshConnectionCandidates()
              }
            }
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
            }
          }

          Divider()

          ToggleCell(title: "Ignore Aspect Ratio", boolBinding: $settingsModel.ignoreAspectRatio)
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
