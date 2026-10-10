import AVFoundation
import SwiftUI

struct AudioView: View {
  @EnvironmentObject private var settingsModel: SettingsModel
  @ObservedObject private var languageManager = LanguageManager.shared
  @ObservedObject private var microphoneManager = MicrophoneManager.shared

  var body: some View {
    SettingsSearchScrollView {
      VStack(alignment: .leading, spacing: 22) {
        SettingsPageHero(
          title: "Audio & Microphone",
          subtitle: "Audio settings subtitle",
          symbol: "speaker.wave.2.fill",
          tint: .red
        )

        AudioCompactGroup(title: "Audio") {
          AudioCompactRow(title: "Audio Configuration") {
            Picker("", selection: $settingsModel.selectedAudioConfiguration) {
              ForEach(SettingsModel.audioConfigurations, id: \.self) { value in
                Text(languageManager.localize(value)).tag(value)
              }
            }
            .labelsHidden()
            .controllerPicker(selection: $settingsModel.selectedAudioConfiguration, options: SettingsModel.audioConfigurations, title: { value in languageManager.localize(value) })
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(width: 190, alignment: .trailing)
          }

          AudioCompactRow(title: "Audio Codec", hint: audioCodecHint) {
            Picker("", selection: $settingsModel.selectedAudioCodec) {
              ForEach(SettingsModel.audioCodecs, id: \.self) { value in
                Text(languageManager.localize(value)).tag(value)
              }
            }
            .labelsHidden()
            .controllerPicker(selection: $settingsModel.selectedAudioCodec, options: SettingsModel.audioCodecs, title: { value in languageManager.localize(value) })
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(width: 190, alignment: .trailing)
          }

          if let conflict = audioCodecChannelConflict {
            AudioCodecConflictRow(
              message: conflict.message,
              keepCodecTitle: conflict.keepCodecTitle,
              keepChannelsTitle: conflict.keepChannelsTitle,
              keepCodec: { settingsModel.selectedAudioConfiguration = "5.1 surround sound" },
              keepChannels: { settingsModel.selectedAudioCodec = SettingsModel.defaultAudioCodec })
          }

          if dolbyOutputApplies {
            AudioCompactRow(title: "Dolby Output") {
              Picker("", selection: $settingsModel.selectedDolbyOutput) {
                ForEach(SettingsModel.dolbyOutputModes, id: \.self) { value in
                  Text(languageManager.localize(value)).tag(value)
                }
              }
              .labelsHidden()
              .controllerPicker(selection: $settingsModel.selectedDolbyOutput, options: SettingsModel.dolbyOutputModes, title: { value in languageManager.localize(value) })
              .pickerStyle(.menu)
              .controlSize(.small)
              .frame(width: 190, alignment: .trailing)
            }
          }

          AudioCompactRow(title: "Play Sound on Host") {
            Toggle("", isOn: $settingsModel.audioOnPC)
              .labelsHidden()
              .toggleStyle(.switch)
              .controlSize(.small)
          }

          AudioCompactRow(title: "Keep Audio Stream Active During Silence", hint: languageManager.localize("Keep Audio Stream Active During Silence hint")) {
            Toggle("", isOn: $settingsModel.continuousAudio)
              .labelsHidden()
              .toggleStyle(.switch)
              .controlSize(.small)
          }

          AudioCompactRow(title: "Sound Mode") {
            Picker("", selection: $settingsModel.selectedAudioOutputMode) {
              ForEach(SettingsModel.audioOutputModes, id: \.self) { value in
                Text(languageManager.localize(value)).tag(value)
              }
            }
            .labelsHidden()
            .controllerPicker(selection: $settingsModel.selectedAudioOutputMode, options: SettingsModel.audioOutputModes, title: { value in languageManager.localize(value) })
            .pickerStyle(.segmented)
            .controlSize(.small)
            .frame(width: 210, alignment: .trailing)
          }

          AudioCompactSliderRow(title: "Volume", value: $settingsModel.volumeLevel, showsSeparator: false)
        }

        if settingsModel.selectedAudioOutputMode == "Audio Enhancement" {
          AudioCompactGroup(title: "Audio Enhancement") {
            AudioCompactRow(title: "Listening Device") {
              Picker("", selection: $settingsModel.selectedEnhancedAudioOutputTarget) {
                ForEach(SettingsModel.enhancedAudioOutputTargetDisplayOrder, id: \.self) { value in
                  Text(languageManager.localize(value)).tag(value)
                }
              }
              .labelsHidden()
              .controllerPicker(selection: $settingsModel.selectedEnhancedAudioOutputTarget, options: SettingsModel.enhancedAudioOutputTargetDisplayOrder, title: { value in languageManager.localize(value) })
              .pickerStyle(.menu)
              .controlSize(.small)
              .frame(width: 190, alignment: .trailing)
            }

            AudioCompactRow(title: "Preset") {
              Picker("", selection: $settingsModel.selectedEnhancedAudioPreset) {
                ForEach(SettingsModel.enhancedAudioPresets, id: \.self) { value in
                  Text(languageManager.localize(value)).tag(value)
                }
              }
              .labelsHidden()
              .controllerPicker(selection: $settingsModel.selectedEnhancedAudioPreset, options: SettingsModel.enhancedAudioPresets, title: { value in languageManager.localize(value) })
              .pickerStyle(.menu)
              .controlSize(.small)
              .frame(width: 190, alignment: .trailing)
            }

            AudioCompactSliderRow(title: "Spatial Intensity", value: $settingsModel.enhancedAudioSpatialIntensity)
            AudioCompactSliderRow(title: "Soundstage Width", value: $settingsModel.enhancedAudioSoundstageWidth)
            AudioCompactSliderRow(title: "Reverb", value: $settingsModel.enhancedAudioReverbAmount, showsSeparator: false)
          }
          AudioEqualizerSection()
        }

        AudioCompactGroup(title: "Microphone") {
          AudioCompactRow(title: "Enable Microphone") {
            Toggle("", isOn: $settingsModel.enableMicrophone)
              .labelsHidden()
              .toggleStyle(.switch)
              .controlSize(.small)
              .onChange(of: settingsModel.enableMicrophone) { enabled in
                guard enabled else { return }
                if microphoneManager.permissionStatus == .notDetermined {
                  microphoneManager.requestPermission()
                } else if microphoneManager.permissionStatus != .authorized {
                  settingsModel.enableMicrophone = false
                }
              }
          }

          AudioCompactRow(title: "Microphone Permission") {
            Label(
              microphoneStatus,
              systemImage: microphoneManager.permissionStatus == .authorized
                ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
            )
            .font(.callout)
            .foregroundStyle(microphoneManager.permissionStatus == .authorized ? .green : .orange)
          }

          AudioCompactRow(title: "Microphone Device") {
            Picker("", selection: $microphoneManager.selectedDeviceUID) {
              Text(languageManager.localize("System Default")).tag("")
              ForEach(microphoneManager.devices) { device in
                Text(device.name).tag(device.uid)
              }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .controllerPicker(
              selection: $microphoneManager.selectedDeviceUID,
              choices: [(value: "", title: languageManager.localize("System Default"))]
                + microphoneManager.devices.map { (value: $0.uid, title: $0.name) })
            .frame(width: 210, alignment: .trailing)
            .onAppear { microphoneManager.refreshDevices() }
          }

          // settings-search: entry "Start Test"
          HStack {
            Spacer()
            Button(languageManager.localize(microphoneManager.isTesting ? "Stop" : "Start Test")) {
              if microphoneManager.isTesting { microphoneManager.stopTest() }
              else { microphoneManager.startTest() }
            }
            .controlSize(.small)
            .disabled(microphoneManager.permissionStatus != .authorized)
          }
          .frame(minHeight: 36)
          .settingsSearchEntry("Start Test")
          if microphoneManager.isTesting {
            ProgressView(value: Double(microphoneManager.inputLevel), total: 1)
              .padding(.vertical, 8)
          }
        }
      }
      .frame(maxWidth: 760, alignment: .leading)
      .padding(.horizontal, 28)
      .padding(.vertical, 24)
      .frame(maxWidth: .infinity, alignment: .center)
    }
    .onDisappear { microphoneManager.stopTest() }
    .onReceive(NotificationCenter.default.publisher(for: SettingsModel.audioCodecFailureChangedNotification)) { _ in
      settingsModel.reloadAudioCodecFailures()
    }
    .onAppear { settingsModel.reloadAudioCodecFailures() }
  }

  /// Explains the bandwidth cost of the selected codec, or why Opus is used instead.
  private var audioCodecHint: String? {
    let choice = AudioCodecChoice(selection: settingsModel.selectedAudioCodec)
    guard choice != .opus else { return nil }

    let channels = MLAudioStreamPlan.channelCount(
      forAudioConfigurationIndex: SettingsModel.getInt(
        from: settingsModel.selectedAudioConfiguration, in: SettingsModel.audioConfigurations))
    let foundationFlag: Int
    switch settingsModel.audioHostIsFoundation {
    case .some(true): foundationFlag = 1
    case .some(false): foundationFlag = 0
    case .none: foundationFlag = -1
    }
    func plan(_ channelCount: Int) -> MLAudioStreamPlan {
      MLAudioStreamPlan.make(
        requestedCodec: choice.codecId, channelCount: channelCount, videoBitrateKbps: 0,
        disableHighQualitySurround: false, foundationHost: foundationFlag,
        codecFailed: settingsModel.audioCodecFailedIds.contains(choice.codecId))
    }

    let current = plan(channels)
    switch current.fallbackReason {
    case .tooManyChannels:
      // Shown as a choice instead of a note: see audioCodecChannelConflict.
      return nil
    case .notFoundationHost:
      return languageManager.localize("Audio codec fallback: host")
    case .previouslyFailed:
      return languageManager.localize("Audio codec fallback: failed")
    case .none:
      break
    }

    if choice == .pcm {
      let stereo = MLAudioStreamPlan.mbpsText(plan(2).wireKbps)
      let surround = MLAudioStreamPlan.mbpsText(plan(6).wireKbps)
      return String(
        format: languageManager.localize("Audio codec hint PCM"), stereo, surround)
    }
    // AC3 / E-AC3 run at a fixed bitrate whatever the channel count.
    let mbps = MLAudioStreamPlan.mbpsText(current.wireKbps)
    if settingsModel.selectedDolbyOutput != "Decode on This Mac" {
      let support = MLAudioBitstreamOutput.supportOnDefaultDevice(forCodec: Int32(choice.codecId))
      if support.available {
        let dolbyName = languageManager.localize(
          choice == .eac3 ? "Dolby Digital Plus" : "Dolby Digital")
        var text = String(
          format: languageManager.localize("Audio codec hint passthrough"),
          support.deviceName, dolbyName, mbps)
        if channels <= 2 {
          text += " " + languageManager.localize("Audio codec hint passthrough stereo")
        }
        return text
      }
    }
    return String(
      format: languageManager.localize("Audio codec hint compressed"),
      MLAudioStreamPlan.codecDisplayName(choice.codecId), mbps)
  }

  /// PCM, AC3 and E-AC3 carry at most 5.1. With a larger Audio Configuration one of
  /// the two settings has to give way, and which one is the user's call, so the
  /// pane offers both instead of silently using Opus.
  private var audioCodecChannelConflict:
    (message: String, keepCodecTitle: String, keepChannelsTitle: String)?
  {
    let choice = AudioCodecChoice(selection: settingsModel.selectedAudioCodec)
    guard choice != .opus else { return nil }
    let channels = MLAudioStreamPlan.channelCount(
      forAudioConfigurationIndex: SettingsModel.getInt(
        from: settingsModel.selectedAudioConfiguration, in: SettingsModel.audioConfigurations))
    guard channels > 6 else { return nil }
    let codecName = MLAudioStreamPlan.codecDisplayName(choice.codecId)
    let layoutName = languageManager.localize(settingsModel.selectedAudioConfiguration)
    return (
      message: String(
        format: languageManager.localize("Audio codec conflict message"), codecName, layoutName),
      keepCodecTitle: String(
        format: languageManager.localize("Audio codec conflict keep codec"), codecName),
      keepChannelsTitle: String(
        format: languageManager.localize("Audio codec conflict keep channels"), layoutName)
    )
  }

  /// The Dolby Output choice only matters for the codecs that can be passed through.
  private var dolbyOutputApplies: Bool {
    let choice = AudioCodecChoice(selection: settingsModel.selectedAudioCodec)
    return choice == .ac3 || choice == .eac3
  }

  private var microphoneStatus: String {
    switch microphoneManager.permissionStatus {
    case .authorized: return languageManager.localize("Granted")
    case .denied, .restricted: return languageManager.localize("Denied")
    case .notDetermined: return languageManager.localize("Not Granted")
    @unknown default: return languageManager.localize("Not Granted")
    }
  }
}

private struct AudioCompactGroup<Content: View>: View {
  let title: String
  let content: Content

  init(title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(LocalizedStringKey(title))
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.leading, 2)

      VStack(alignment: .leading, spacing: 0) {
        content
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 2)
      .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
    .settingsSearchSection(title)
  }
}

/// Two-way choice shown under the Audio Codec row while it conflicts with the
/// Audio Configuration.
private struct AudioCodecConflictRow: View {
  let message: String
  let keepCodecTitle: String
  let keepChannelsTitle: String
  let keepCodec: () -> Void
  let keepChannels: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
        Text(message)
          .font(.caption)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack(spacing: 8) {
        Button(keepCodecTitle, action: keepCodec)
        Button(keepChannelsTitle, action: keepChannels)
      }
      .controlSize(.small)
    }
    .padding(.vertical, 8)
    .overlay(alignment: .bottom) {
      Divider().opacity(0.45)
    }
  }
}

private struct AudioCompactRow<Content: View>: View {
  let title: String
  let hint: String?
  let content: Content
  let showsSeparator: Bool

  init(
    title: String, hint: String? = nil, showsSeparator: Bool = true,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.hint = hint
    self.showsSeparator = showsSeparator
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 16) {
        Text(LocalizedStringKey(title))
          .frame(maxWidth: .infinity, alignment: .leading)
        content
      }
      .frame(minHeight: 38)
      if let hint, !hint.isEmpty {
        Text(hint)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.bottom, 8)
      }
    }
    .overlay(alignment: .bottom) {
      if showsSeparator {
        Divider().opacity(0.45)
      }
    }
    .settingsSearchRow(title: title)
  }
}

private struct AudioCompactSliderRow: View {
  let title: String
  @Binding var value: CGFloat
  var showsSeparator = true

  var body: some View {
    HStack(spacing: 10) {
      Text(LocalizedStringKey(title))
        .frame(width: 84, alignment: .leading)
      Image(systemName: "speaker.wave.1.fill")
        .foregroundStyle(.secondary)
      // Fills the row like the system Sound output volume.
      Slider(value: $value, in: 0...1)
        .controllerSlider(value: $value, in: 0...1)
        .frame(maxWidth: .infinity)
      Image(systemName: "speaker.wave.3.fill")
        .foregroundStyle(.secondary)
    }
    .frame(minHeight: 42)
    .overlay(alignment: .bottom) {
      if showsSeparator {
        Divider().opacity(0.45)
      }
    }
    .settingsSearchRow(title: title)
  }
}


private struct AudioEqualizerSection: View {
  @EnvironmentObject private var settingsModel: SettingsModel
  private var frequencies: [Double] {
    SettingsModel.enhancedAudioEQFrequencies(for: settingsModel.selectedEnhancedAudioEQLayout)
  }
  var body: some View {
    FormSection(title: "EQ") {
      SettingsChoiceRow(title: "EQ Detail", selection: $settingsModel.selectedEnhancedAudioEQLayout, options: SettingsModel.enhancedAudioEQLayouts)
      ForEach(frequencies, id: \.self) { frequency in
        SettingsValueSliderRow(title: String(format: "%g Hz", frequency), value: Binding(
          get: {
            guard let index = frequencies.firstIndex(of: frequency), settingsModel.enhancedAudioEQGains.indices.contains(index) else { return 0 }
            return CGFloat(settingsModel.enhancedAudioEQGains[index])
          }, set: { value in
            if let index = frequencies.firstIndex(of: frequency) { settingsModel.setEnhancedAudioEQGain(Double(value), at: index) }
          }), range: -12...12, step: 0.5, suffix: " dB")
      }
    }
  }
}
