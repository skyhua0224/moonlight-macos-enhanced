import AppKit
import SwiftUI

struct StreamView: View {
  @EnvironmentObject private var settingsModel: SettingsModel
  @ObservedObject private var languageManager = LanguageManager.shared
  @State private var isAddressEditorPresented = false

  private var selectedHostName: String {
    guard let host = settingsModel.selectedHost else { return languageManager.localize("Default Profile") }
    return host.id == SettingsModel.globalHostId
      ? languageManager.localize("Default Profile") : host.name
  }

  var body: some View {
    SettingsContent {
      SettingsPageHero(
        title: "Streaming",
        subtitle: "Streaming settings subtitle",
        symbol: "rectangle.inset.filled.and.person.filled",
        tint: .cyan
      )

      FormSection(title: "General") {
        SettingsRow(title: "Profile") {
          Text(selectedHostName)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }


        SettingsRow(title: "Connection Method") {
          Picker("", selection: $settingsModel.selectedConnectionMethod) {
            ForEach(settingsModel.connectionCandidates) { candidate in
              Text(candidate.label).tag(candidate.id)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .frame(width: 220, alignment: .trailing)
        }

        SettingsRow(title: "Connection Addresses", detail: "Connection Addresses detail") {
          Button(languageManager.localize("Manage Addresses")) {
            isAddressEditorPresented = true
          }
          .disabled(selectedTemporaryHost == nil)
        }


        SettingsRow(title: "Default Display Mode") {
          Picker("", selection: $settingsModel.selectedDisplayMode) {
            ForEach(SettingsModel.displayModes, id: \.self) { mode in
              Text(languageManager.localize(mode)).tag(mode)
            }
          }
          .labelsHidden()
          .frame(width: 220, alignment: .trailing)
        }


        SettingsRow(title: "Language") {
          Picker("", selection: $languageManager.currentLanguage) {
            ForEach(AppLanguage.allCases) { language in
              Text(languageManager.localize(language.rawValue)).tag(language)
            }
          }
          .labelsHidden()
          .frame(width: 160, alignment: .trailing)
          .onChange(of: languageManager.currentLanguage) { _ in
            languageManager.applyAppLanguage()
          }
        }
      }

      FormSection(title: "Clipboard") {
        SettingsRow(title: "Clipboard Sync", detail: "Clipboard Sync detail") {
          Picker("", selection: $settingsModel.selectedClipboardSyncMode) {
            ForEach(SettingsModel.clipboardSyncModes, id: \.self) { mode in
              Text(languageManager.localize(mode)).tag(mode)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .frame(width: 170, alignment: .trailing)
        }

        SettingDescriptionRow(textKey: "Clipboard Sync Foundation detail")
      }

      FormSection(title: "Resolution & Frame Rate") {
        SettingsRow(title: "Resolution") {
          Picker("", selection: $settingsModel.selectedResolution) {
            ForEach(SettingsModel.resolutions, id: \.self) { resolution in
              if resolution == SettingsModel.matchDisplayResolutionSentinel {
                Text(languageManager.localize("Match Display")).tag(resolution)
              } else if resolution == .zero {
                Text(languageManager.localize("Custom")).tag(resolution)
              } else {
                Text("\(Int(resolution.width)) × \(Int(resolution.height))").tag(resolution)
              }
            }
          }
          .labelsHidden()
          .frame(width: 220, alignment: .trailing)
        }

        if settingsModel.selectedResolution == .zero {
          SettingsRow(title: "Custom Resolution") {
            DimensionsInputView(
              widthBinding: $settingsModel.customResWidth,
              heightBinding: $settingsModel.customResHeight,
              placeholderDimensions: CGSize(width: 1920, height: 1080)
            )
          }
        }


        SettingsRow(title: "Frame Rate") {
          Picker("", selection: $settingsModel.selectedFps) {
            ForEach(SettingsModel.fpss, id: \.self) { fps in
              Text(fps == 0 ? languageManager.localize("Custom") : "\(fps) Hz").tag(fps)
            }
          }
          .labelsHidden()
          .frame(width: 150, alignment: .trailing)
        }

        if settingsModel.selectedFps == 0 {
          SettingsRow(title: "Custom FPS") {
            TextField("60", value: $settingsModel.customFps, formatter: NumberOnlyFormatter())
              .multilineTextAlignment(.trailing)
              .textFieldStyle(.roundedBorder)
              .frame(width: 90)
          }
        }


        ToggleCell(title: "Resolution Scale", hintKey: "Resolution Scale hint", boolBinding: $settingsModel.streamResolutionScale)

        if settingsModel.streamResolutionScale {
          SettingsRow(title: "Resolution Scale Ratio") {
            Picker("", selection: $settingsModel.streamResolutionScaleRatio) {
              Text("50%").tag(50)
              Text("75%").tag(75)
              Text("100%").tag(100)
            }
            .labelsHidden()
            .frame(width: 130, alignment: .trailing)
          }
        }

        ToggleCell(title: "Remote Resolution", hintKey: "Remote overrides hint", boolBinding: $settingsModel.remoteResolutionEnabled)
        if settingsModel.remoteResolutionEnabled {
          SettingsRow(title: "Remote Resolution") {
            Picker("", selection: $settingsModel.selectedRemoteResolution) {
              ForEach(SettingsModel.remoteResolutions, id: \.self) { resolution in
                Text(resolution == .zero ? languageManager.localize("Custom") : "\(Int(resolution.width)) × \(Int(resolution.height))")
                  .tag(resolution)
              }
            }
            .labelsHidden()
            .frame(width: 220, alignment: .trailing)
          }

          if settingsModel.selectedRemoteResolution == .zero {
            SettingsRow(title: "Remote Custom Resolution") {
              DimensionsInputView(
                widthBinding: $settingsModel.remoteCustomResWidth,
                heightBinding: $settingsModel.remoteCustomResHeight,
                placeholderDimensions: CGSize(width: 1920, height: 1080)
              )
            }
          }
        }
      }

      RemoteFrameRateSection()

      FormSection(title: "Bitrate & Playback") {
        BitrateSettingsSection()

        ToggleCell(title: "Play Sound on Host", boolBinding: $settingsModel.audioOnPC)
        ToggleCell(title: "Ignore Aspect Ratio", boolBinding: $settingsModel.ignoreAspectRatio)
        ToggleCell(title: "Show Local Cursor", boolBinding: $settingsModel.showLocalCursor)
      }
    }
    .onAppear {
      settingsModel.refreshConnectionCandidates()
    }
    .onChange(of: settingsModel.selectedHost?.id) { _ in
      settingsModel.refreshConnectionCandidates()
    }
    .sheet(isPresented: $isAddressEditorPresented) {
      if let host = selectedTemporaryHost {
        ConnectionEditorSheet(host: host)
          .frame(minWidth: 620, minHeight: 520)
      }
    }
  }

  private var selectedTemporaryHost: TemporaryHost? {
    guard let hostID = settingsModel.selectedHost?.id,
      hostID != SettingsModel.globalHostId,
      let hosts = DataManager().getHosts() as? [TemporaryHost]
    else { return nil }
    return hosts.first(where: { $0.uuid == hostID })
  }
}

private struct ConnectionEditorSheet: NSViewControllerRepresentable {
  let host: TemporaryHost

  func makeNSViewController(context: Context) -> ConnectionEditorViewController {
    ConnectionEditorViewController(host: host)
  }

  func updateNSViewController(_ nsViewController: ConnectionEditorViewController, context: Context) {}
}


private struct BitrateSettingsSection: View {
  @EnvironmentObject private var settingsModel: SettingsModel
  @Environment(\.locale) private var locale
  private var mbps: Binding<Double> {
    Binding(get: { Double(settingsModel.effectiveBitrateKbps) / 1000 }, set: { value in
      guard value.isFinite else { return }
      let maxMbps = Double(SettingsModel.bitrateSteps(unlocked: settingsModel.unlockMaxBitrate).last!)
      settingsModel.customBitrate = Int((min(maxMbps, max(0.5, value)) * 1000).rounded())
    })
  }
  var body: some View {
    ToggleCell(title: "Auto Adjust Bitrate", hintKey: "Auto bitrate hint", boolBinding: $settingsModel.autoAdjustBitrate)
    ToggleCell(title: "Unlock max bitrate (1000 Mbps)", boolBinding: $settingsModel.unlockMaxBitrate)
    SettingsRow(title: settingsModel.autoAdjustBitrate ? "Target Bitrate" : "Bitrate") {
      HStack(spacing: 5) {
        TextField("Bitrate", value: mbps, format: .number.precision(.fractionLength(0...3)).locale(locale))
          .labelsHidden()
          .multilineTextAlignment(.trailing)
          .textFieldStyle(.roundedBorder)
          .frame(width: 90)
          .disabled(settingsModel.autoAdjustBitrate)
        Text("Mbps").foregroundStyle(.secondary)
      }
    }
    if !settingsModel.autoAdjustBitrate {
      SettingsRow(title: "Bitrate") {
        Slider(value: $settingsModel.bitrateSliderValue,
          in: 0...Float(SettingsModel.bitrateSteps(unlocked: settingsModel.unlockMaxBitrate).count - 1), step: 1)
          .frame(width: 250)
          .accessibilityLabel(Text("Bitrate"))
          .accessibilityValue(Text("\(Double(settingsModel.effectiveBitrateKbps) / 1000, format: .number.precision(.fractionLength(0...3))) Mbps"))
      }
    }
  }
}

private struct RemoteFrameRateSection: View {
  @EnvironmentObject private var settingsModel: SettingsModel
  var body: some View {
    FormSection(title: "Remote FPS") {
      ToggleCell(title: "Remote FPS", hintKey: "Remote overrides hint", boolBinding: $settingsModel.remoteFpsEnabled)
      if settingsModel.remoteFpsEnabled {
        SettingsRow(title: "Remote FPS Value") {
          Picker("", selection: $settingsModel.selectedRemoteFps) {
            ForEach(SettingsModel.fpss, id: \.self) { value in
              Text(value == 0 ? NSLocalizedString("Custom", comment: "") : "\(value) Hz").tag(value)
            }
          }.labelsHidden().frame(width: 190)
        }
        if settingsModel.selectedRemoteFps == 0 {
          SettingsRow(title: "Custom FPS") {
            TextField("60", value: $settingsModel.remoteCustomFps, formatter: NumberOnlyFormatter())
              .multilineTextAlignment(.trailing).frame(width: 90)
          }
        }
      }
    }
  }
}
