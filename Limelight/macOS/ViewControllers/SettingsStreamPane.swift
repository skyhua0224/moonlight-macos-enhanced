import AppKit
import SwiftUI

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
      }

      PictureSection()

      FormSection(title: "Bitrate") {
        BitrateSettingsSection()

        SettingsChoiceRow(title: "Video FEC", selection: $settingsModel.selectedVideoFecPercentage,
          options: SettingsModel.videoFecPercentages)
        Text("Video FEC hint").font(.footnote).foregroundStyle(.secondary)
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

      FormSection(title: "Host Overrides") {
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

        RemoteFrameRateRows()
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

private struct RemoteFrameRateRows: View {
  @EnvironmentObject private var settingsModel: SettingsModel
  var body: some View {
    Group {
      ToggleCell(title: "Remote FPS", hintKey: "Remote overrides hint", boolBinding: $settingsModel.remoteFpsEnabled)
      if settingsModel.remoteFpsEnabled {
        SettingsRow(title: "Remote FPS Value") {
          Picker("", selection: $settingsModel.selectedRemoteFps) {
            ForEach(SettingsModel.remoteFpss, id: \.self) { value in
              Text(value == 0 ? NSLocalizedString("Custom", comment: "") : "\(value) Hz").tag(value)
            }
          }
          .labelsHidden()
          .controllerPicker(
            selection: $settingsModel.selectedRemoteFps, options: SettingsModel.remoteFpss,
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
