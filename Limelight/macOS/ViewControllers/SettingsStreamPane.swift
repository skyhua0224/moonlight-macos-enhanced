import AppKit
import SwiftUI

/// CGSize is Hashable only from macOS 15. A picker whose selection or tag type
/// is CGSize cannot resolve its view type on macOS 12-14 and the settings
/// window aborts, so the resolution pickers select this value instead.
private struct ResolutionChoice: Hashable {
  let width: Int
  let height: Int

  init(_ size: CGSize) {
    width = Int(size.width)
    height = Int(size.height)
  }

  var size: CGSize { CGSize(width: width, height: height) }

  static func binding(_ source: Binding<CGSize>) -> Binding<ResolutionChoice> {
    Binding(
      get: { ResolutionChoice(source.wrappedValue) },
      set: { source.wrappedValue = $0.size })
  }
}

struct StreamView: View {
  @EnvironmentObject private var settingsModel: SettingsModel
  @ObservedObject private var languageManager = LanguageManager.shared
  @SwiftUI.State private var isAddressEditorPresented = false
  @AppStorage("selected-settings-pane") private var selectedPane: SettingsPaneType = .stream

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
          HStack(spacing: 10) {
            Text(selectedHostName)
              .foregroundStyle(.secondary)
              .lineLimit(1)
            Button(languageManager.localize("Manage Profiles")) {
              selectedPane = .profiles
            }
          }
        }


        SettingsRow(title: "Connection Method") {
          Picker("", selection: $settingsModel.selectedConnectionMethod) {
            ForEach(settingsModel.connectionCandidates) { candidate in
              Text(candidate.label).tag(candidate.id)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .controllerPicker(
            selection: $settingsModel.selectedConnectionMethod,
            choices: settingsModel.connectionCandidates.map { (value: $0.id, title: $0.label) })
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
          .controllerPicker(selection: $settingsModel.selectedDisplayMode, options: SettingsModel.displayModes, title: { mode in languageManager.localize(mode) })
          .frame(width: 220, alignment: .trailing)
        }


        SettingsRow(title: "Language") {
          Picker("", selection: $languageManager.currentLanguage) {
            ForEach(AppLanguage.allCases) { language in
              Text(languageManager.localize(language.rawValue)).tag(language)
            }
          }
          .labelsHidden()
          .controllerPicker(
            selection: $languageManager.currentLanguage, options: AppLanguage.allCases,
            title: { languageManager.localize($0.rawValue) })
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
          .controllerPicker(selection: $settingsModel.selectedClipboardSyncMode, options: SettingsModel.clipboardSyncModes, title: { mode in languageManager.localize(mode) })
          .pickerStyle(.menu)
          .frame(width: 170, alignment: .trailing)
        }

        SettingDescriptionRow(textKey: "Clipboard Sync Foundation detail")
      }

      FormSection(title: "Resolution & Frame Rate") {
        SettingsRow(title: "Resolution") {
          Picker("", selection: ResolutionChoice.binding($settingsModel.selectedResolution)) {
            ForEach(SettingsModel.resolutions.map(ResolutionChoice.init), id: \.self) { choice in
              if choice.size == SettingsModel.matchDisplayResolutionSentinel {
                Text(languageManager.localize("Match Display")).tag(choice)
              } else if choice.size == .zero {
                Text(languageManager.localize("Custom")).tag(choice)
              } else {
                Text("\(choice.width) × \(choice.height)").tag(choice)
              }
            }
          }
          .labelsHidden()
          .controllerPicker(
            selection: $settingsModel.selectedResolution,
            choices: SettingsModel.resolutions.map { resolution in
              (value: resolution,
               title: resolution == SettingsModel.matchDisplayResolutionSentinel
                 ? languageManager.localize("Match Display")
                 : resolution == .zero ? languageManager.localize("Custom")
                 : "\(Int(resolution.width)) × \(Int(resolution.height))")
            })
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
          .controllerPicker(selection: $settingsModel.selectedFps, options: SettingsModel.fpss, title: { fps in fps == 0 ? languageManager.localize("Custom") : "\(fps) Hz" })
          .frame(width: 150, alignment: .trailing)
        }

        if settingsModel.selectedFps == 0 {
          SettingsRow(title: "Custom FPS") {
            TextField("60", value: $settingsModel.customFps, formatter: NumberOnlyFormatter())
              .multilineTextAlignment(.trailing)
              .controllerNumericField()
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
            .controllerPicker(
              selection: $settingsModel.streamResolutionScaleRatio, options: [50, 75, 100], title: { "\($0)%" })
            .frame(width: 130, alignment: .trailing)
          }
        }

        ToggleCell(title: "Remote Resolution", hintKey: "Remote overrides hint", boolBinding: $settingsModel.remoteResolutionEnabled)
        if settingsModel.remoteResolutionEnabled {
          SettingsRow(title: "Remote Resolution") {
            Picker("", selection: ResolutionChoice.binding($settingsModel.selectedRemoteResolution)) {
              ForEach(SettingsModel.remoteResolutions.map(ResolutionChoice.init), id: \.self) { choice in
                Text(choice.size == .zero ? languageManager.localize("Custom") : "\(choice.width) × \(choice.height)")
                  .tag(choice)
              }
            }
            .labelsHidden()
            .controllerPicker(
              selection: $settingsModel.selectedRemoteResolution, options: SettingsModel.remoteResolutions,
              title: { resolution in
                resolution == .zero ? languageManager.localize("Custom") : "\(Int(resolution.width)) × \(Int(resolution.height))"
              })
            .frame(width: 220, alignment: .trailing)
          }
          // Same title as the toggle above: the toggle is the search target.
          .settingsSearchTargetSuppressed()

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
        SettingsChoiceRow(title: "Video FEC", selection: $settingsModel.selectedVideoFecPercentage,
          options: SettingsModel.videoFecPercentages)
        Text("Video FEC hint").font(.footnote).foregroundStyle(.secondary)
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
    ToggleCell(title: "Adaptive Bitrate", hintKey: "Adaptive Bitrate hint", boolBinding: $settingsModel.enableAdaptiveBitrate)
    ToggleCell(title: "Unlock max bitrate (1000 Mbps)", boolBinding: $settingsModel.unlockMaxBitrate)
    SettingsRow(title: settingsModel.autoAdjustBitrate ? "Target Bitrate" : "Bitrate") {
      HStack(spacing: 5) {
        TextField("Bitrate", value: mbps, format: .number.precision(.fractionLength(0...3)).locale(locale))
          .labelsHidden()
          .controllerNumericField()
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
          .controllerSlider(
            value: $settingsModel.bitrateSliderValue,
            in: 0...Float(SettingsModel.bitrateSteps(unlocked: settingsModel.unlockMaxBitrate).count - 1), step: 1)
          .frame(width: 250)
          .accessibilityLabel(Text("Bitrate"))
          .accessibilityValue(Text("\(Double(settingsModel.effectiveBitrateKbps) / 1000, format: .number.precision(.fractionLength(0...3))) Mbps"))
      }
      // Same title as the numeric row above: that row is the search target.
      .settingsSearchTargetSuppressed()
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
          }
          .labelsHidden()
          .controllerPicker(
            selection: $settingsModel.selectedRemoteFps, options: SettingsModel.fpss,
            title: { value in value == 0 ? NSLocalizedString("Custom", comment: "") : "\(value) Hz" })
          .frame(width: 190)
        }
        if settingsModel.selectedRemoteFps == 0 {
          SettingsRow(title: "Custom FPS") {
            TextField("60", value: $settingsModel.remoteCustomFps, formatter: NumberOnlyFormatter())
              .multilineTextAlignment(.trailing)
              .controllerNumericField()
              .frame(width: 90)
          }
        }
      }
    }
  }
}
