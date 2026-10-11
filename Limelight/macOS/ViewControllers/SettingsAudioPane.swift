import AVFoundation
import CoreAudio
import SwiftUI
import UniformTypeIdentifiers

/// Re-renders the audio pane when the system default output device changes, so a hint that
/// names the device (Dolby passthrough) never shows the one from when the pane was opened.
private final class DefaultOutputDeviceObserver: ObservableObject {
  private var listener: AudioObjectPropertyListenerBlock?
  private var address = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)

  init() {
    let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      self?.objectWillChange.send()
    }
    listener = block
    AudioObjectAddPropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
  }

  deinit {
    guard let block = listener else { return }
    var removeAddress = address
    AudioObjectRemovePropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject), &removeAddress, DispatchQueue.main, block)
  }
}

struct AudioView: View {
  @EnvironmentObject private var settingsModel: SettingsModel
  @ObservedObject private var languageManager = LanguageManager.shared
  @ObservedObject private var microphoneManager = MicrophoneManager.shared
  @StateObject private var outputDeviceObserver = DefaultOutputDeviceObserver()

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

            AudioCompactRow(
              title: "Spatial Audio", hint: languageManager.localize(spatialAudioHintKey)
            ) {
              Picker("", selection: $settingsModel.selectedEnhancedAudioSpatialMode) {
                ForEach(EnhancedAudioSpatialMode.allCases.map(\.title), id: \.self) { value in
                  Text(languageManager.localize(value)).tag(value)
                }
              }
              .labelsHidden()
              .controllerPicker(selection: $settingsModel.selectedEnhancedAudioSpatialMode, options: EnhancedAudioSpatialMode.allCases.map(\.title), title: { value in languageManager.localize(value) })
              .pickerStyle(.menu)
              .controlSize(.small)
              .frame(width: 190, alignment: .trailing)
            }

            AudioCompactSliderRow(title: "Spatial Intensity", value: $settingsModel.enhancedAudioSpatialIntensity)
              .disabled(spatialAudioOff)
            AudioCompactSliderRow(title: "Soundstage Width", value: $settingsModel.enhancedAudioSoundstageWidth)
              .disabled(spatialAudioOff)
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

  private var spatialAudioOff: Bool {
    EnhancedAudioSpatialMode(title: settingsModel.selectedEnhancedAudioSpatialMode) == .off
  }

  private var spatialAudioHintKey: String {
    switch EnhancedAudioSpatialMode(title: settingsModel.selectedEnhancedAudioSpatialMode) {
    case .automatic: return "Spatial Audio Automatic hint"
    case .wideStereo: return "Spatial Audio Wide Stereo hint"
    case .off: return "Spatial Audio Off hint"
    }
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
  @ObservedObject private var languageManager = LanguageManager.shared
  @State private var importNote: String?

  private var frequencies: [Double] {
    SettingsModel.enhancedAudioEQFrequencies(for: settingsModel.selectedEnhancedAudioEQLayout)
  }
  private var isParametric: Bool {
    EnhancedAudioEQ.Mode(title: settingsModel.selectedEnhancedAudioEQMode) == .parametric
  }

  var body: some View {
    FormSection(title: "EQ") {
      SettingsRow(title: "Enable Equalizer") {
        Toggle("", isOn: $settingsModel.enhancedAudioEQEnabled)
          .labelsHidden()
          .toggleStyle(.switch)
          .controlSize(.small)
      }
      SettingsChoiceRow(
        title: "EQ Mode", selection: $settingsModel.selectedEnhancedAudioEQMode,
        options: EnhancedAudioEQ.Mode.allCases.map(\.title))

      AudioEQCurveView(
        filters: settingsModel.enhancedAudioEQFilters,
        bands: isParametric ? $settingsModel.enhancedAudioEQBands : nil
      )
      .frame(height: 190)
      .padding(.vertical, 10)
      .opacity(settingsModel.enhancedAudioEQEnabled ? 1 : 0.45)

      SettingsValueSliderRow(
        title: "EQ Preamp", value: $settingsModel.enhancedAudioEQPreamp,
        range: CGFloat(EnhancedAudioEQ.preampRange.lowerBound)...CGFloat(
          EnhancedAudioEQ.preampRange.upperBound),
        step: 0.5, suffix: " dB")

      if isParametric {
        parametricEditor
      } else {
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

  @ViewBuilder
  private var parametricEditor: some View {
    if let name = settingsModel.enhancedAudioEQProfileName, !name.isEmpty {
      Text(String(format: languageManager.localize("EQ Correction %@"), name))
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }
    ForEach($settingsModel.enhancedAudioEQBands) { $band in
      AudioEQBandRow(band: $band) {
        settingsModel.enhancedAudioEQBands.removeAll { $0.id == band.id }
      }
    }
    HStack(spacing: 8) {
      Button(languageManager.localize("EQ Add Band")) {
        settingsModel.enhancedAudioEQBands.append(EnhancedAudioEQBand(kind: .peak, frequency: 1000, q: 1))
      }
      .disabled(settingsModel.enhancedAudioEQBands.count >= EnhancedAudioEQ.maxBands)
      Button(languageManager.localize("EQ Import File")) { importFromFile() }
      Button(languageManager.localize("EQ Paste")) {
        applyImport(NSPasteboard.general.string(forType: .string), name: nil)
      }
      Spacer()
      Button(languageManager.localize("EQ Reset Bands")) {
        settingsModel.enhancedAudioEQBands = EnhancedAudioEQ.starterBands()
        settingsModel.enhancedAudioEQPreamp = 0
        settingsModel.enhancedAudioEQProfileName = nil
        importNote = nil
      }
    }
    .controlSize(.small)
    .frame(minHeight: 38)
    Text(importNote ?? languageManager.localize("EQ Import Hint"))
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.bottom, 8)
  }

  private func importFromFile() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.plainText]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let text =
      (try? String(contentsOf: url, encoding: .utf8))
      ?? (try? String(contentsOf: url, encoding: .utf16))
      ?? (try? String(contentsOf: url, encoding: .isoLatin1))
    // AutoEq names its files "<headphone> ParametricEQ.txt".
    var name = url.deletingPathExtension().lastPathComponent
    if name.hasSuffix(" ParametricEQ") {
      name = String(name.dropLast(" ParametricEQ".count))
    }
    applyImport(text, name: name)
  }

  private func applyImport(_ text: String?, name: String?) {
    guard let text, let profile = EnhancedAudioEQ.parseParametricText(text) else {
      importNote = languageManager.localize("EQ Import Failed")
      return
    }
    settingsModel.applyImportedEnhancedAudioEQ(profile, name: name)
    importNote =
      profile.skippedLines > 0
      ? String(
        format: languageManager.localize("EQ Import Skipped %d %d"), profile.bands.count,
        profile.skippedLines)
      : String(format: languageManager.localize("EQ Import Done %d"), profile.bands.count)
  }
}

/// One parametric band: on/off, filter kind, frequency, gain and Q.
private struct AudioEQBandRow: View {
  @Binding var band: EnhancedAudioEQBand
  let onDelete: () -> Void
  @ObservedObject private var languageManager = LanguageManager.shared

  var body: some View {
    HStack(spacing: 8) {
      Toggle("", isOn: $band.enabled)
        .labelsHidden()
        .toggleStyle(.checkbox)
      Picker("", selection: $band.kind) {
        ForEach(EnhancedAudioEQBand.Kind.allCases, id: \.self) { kind in
          Text(languageManager.localize(kind.titleKey)).tag(kind)
        }
      }
      .labelsHidden()
      .controllerPicker(
        selection: $band.kind, options: EnhancedAudioEQBand.Kind.allCases,
        title: { kind in languageManager.localize(kind.titleKey) }
      )
      .pickerStyle(.menu)
      .frame(width: 104)

      numberField(clamped(\.frequency, EnhancedAudioEQBand.frequencyRange), fraction: 0...1, width: 62)
      Text("Hz").foregroundStyle(.secondary)

      Slider(value: clamped(\.gain, EnhancedAudioEQBand.gainRange), in: -15...15, step: 0.1)
        .controllerSlider(value: clamped(\.gain, EnhancedAudioEQBand.gainRange), in: -15...15, step: 0.5)
        .frame(minWidth: 70, maxWidth: .infinity)
        .disabled(!band.kind.usesGain)
      Text(band.kind.usesGain ? String(format: "%+.1f dB", band.gain) : "—")
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .frame(width: 58, alignment: .trailing)

      Text("Q").foregroundStyle(.secondary)
      numberField(clamped(\.q, EnhancedAudioEQBand.qRange), fraction: 0...2, width: 46)

      Button(action: onDelete) {
        Image(systemName: "minus.circle")
      }
      .buttonStyle(.borderless)
    }
    .controlSize(.small)
    .opacity(band.enabled ? 1 : 0.55)
    .frame(minHeight: 36)
    .overlay(alignment: .bottom) {
      Divider().opacity(0.45)
    }
  }

  private func clamped(
    _ keyPath: WritableKeyPath<EnhancedAudioEQBand, Double>, _ range: ClosedRange<Double>
  ) -> Binding<Double> {
    Binding(
      get: { band[keyPath: keyPath] },
      set: { band[keyPath: keyPath] = EnhancedAudioEQBand.clamp($0, to: range) })
  }

  private func numberField(_ value: Binding<Double>, fraction: ClosedRange<Int>, width: CGFloat)
    -> some View
  {
    TextField("", value: value, format: .number.precision(.fractionLength(fraction)).grouping(.never))
      .multilineTextAlignment(.trailing)
      .controllerNumericField()
      .textFieldStyle(.roundedBorder)
      .frame(width: width)
  }
}

/// The frequency response the equalizer is set to, 20 Hz to 20 kHz on a log axis. With `bands`
/// (the parametric equalizer) every band has a handle that drags its frequency and gain.
private struct AudioEQCurveView: View {
  let filters: [EnhancedAudioEQ.Filter]
  let bands: Binding<[EnhancedAudioEQBand]>?
  @State private var draggedBandID: UUID?
  @State private var dragMissed = false
  // What a running stream plays right now; empty without one in the enhanced sound mode.
  @ObservedObject private var spectrum = EnhancedAudioSpectrum.shared

  private static let minFrequency = 20.0
  private static let maxFrequency = 20000.0
  private static let sampleCount = 180
  private static let leftInset: CGFloat = 30
  private static let bottomInset: CGFloat = 16

  private var samples: [(frequency: Double, gain: Double)] {
    (0...Self.sampleCount).map { index in
      let frequency =
        Self.minFrequency
        * pow(Self.maxFrequency / Self.minFrequency, Double(index) / Double(Self.sampleCount))
      return (frequency, EnhancedAudioEQ.response(of: filters, at: frequency))
    }
  }

  /// Half the height of the gain axis, in dB: 12, or more when the curve or a band needs it.
  private func gainSpan(_ samples: [(frequency: Double, gain: Double)]) -> Double {
    var peak = samples.map { abs($0.gain) }.max() ?? 0
    for band in bands?.wrappedValue ?? [] where band.kind.usesGain {
      peak = max(peak, abs(band.gain))
    }
    if peak <= 11.5 { return 12 }
    if peak <= 17.5 { return 18 }
    return 24
  }

  var body: some View {
    GeometryReader { proxy in
      let samples = self.samples
      let span = gainSpan(samples)
      let plot = CGRect(
        x: Self.leftInset, y: 4, width: max(1, proxy.size.width - Self.leftInset - 4),
        height: max(1, proxy.size.height - Self.bottomInset - 4))
      Canvas { context, _ in
        draw(in: &context, plot: plot, samples: samples, span: span)
      }
      .contentShape(Rectangle())
      .gesture(dragGesture(plot: plot, span: span), including: bands == nil ? .none : .all)
    }
    .onAppear { spectrum.addViewer() }
    .onDisappear { spectrum.removeViewer() }
  }

  private func x(_ frequency: Double, _ plot: CGRect) -> CGFloat {
    let position =
      log10(frequency / Self.minFrequency) / log10(Self.maxFrequency / Self.minFrequency)
    return plot.minX + CGFloat(position) * plot.width
  }

  private func y(_ gain: Double, _ plot: CGRect, _ span: Double) -> CGFloat {
    let clampedGain = min(max(gain, -span), span)
    return plot.midY - CGFloat(clampedGain / span) * plot.height / 2
  }

  private func handlePoint(_ band: EnhancedAudioEQBand, _ plot: CGRect, _ span: Double) -> CGPoint {
    CGPoint(x: x(band.frequency, plot), y: y(band.kind.usesGain ? band.gain : 0, plot, span))
  }

  private func draw(
    in context: inout GraphicsContext, plot: CGRect,
    samples: [(frequency: Double, gain: Double)], span: Double
  ) {
    let gridColor = Color.secondary.opacity(0.18)
    let labelFont = Font.system(size: 9)

    for frequency in [50.0, 100, 200, 500, 1000, 2000, 5000, 10000] {
      var line = Path()
      line.move(to: CGPoint(x: x(frequency, plot), y: plot.minY))
      line.addLine(to: CGPoint(x: x(frequency, plot), y: plot.maxY))
      context.stroke(line, with: .color(gridColor), lineWidth: 0.5)
    }
    for (frequency, label) in [(100.0, "100"), (1000, "1k"), (10000, "10k")] {
      context.draw(
        Text(label).font(labelFont).foregroundColor(.secondary),
        at: CGPoint(x: x(frequency, plot), y: plot.maxY + 2), anchor: .top)
    }
    for gain in stride(from: -span, through: span, by: 6) {
      var line = Path()
      line.move(to: CGPoint(x: plot.minX, y: y(gain, plot, span)))
      line.addLine(to: CGPoint(x: plot.maxX, y: y(gain, plot, span)))
      context.stroke(
        line, with: .color(gain == 0 ? Color.secondary.opacity(0.45) : gridColor),
        lineWidth: gain == 0 ? 1 : 0.5)
      context.draw(
        Text(String(format: "%+.0f", gain)).font(labelFont).foregroundColor(.secondary),
        at: CGPoint(x: plot.minX - 4, y: y(gain, plot, span)), anchor: .trailing)
    }

    // The live spectrum, behind the curve: the bottom of the plot is -90 dB, the top full scale.
    let levels = spectrum.levels
    if levels.count > 1 {
      var shape = Path()
      shape.move(to: CGPoint(x: plot.minX, y: plot.maxY))
      for (index, level) in levels.enumerated() {
        let frequency = EnhancedAudioSpectrum.frequency(ofBand: index)
        let height = CGFloat(min(max((Double(level) + 90) / 90, 0), 1)) * plot.height
        shape.addLine(to: CGPoint(x: x(frequency, plot), y: plot.maxY - height))
      }
      shape.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
      shape.closeSubpath()
      context.fill(shape, with: .color(Color.secondary.opacity(0.22)))
    }

    var curve = Path()
    for (index, sample) in samples.enumerated() {
      let point = CGPoint(x: x(sample.frequency, plot), y: y(sample.gain, plot, span))
      if index == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
    }
    var area = curve
    area.addLine(to: CGPoint(x: plot.maxX, y: plot.midY))
    area.addLine(to: CGPoint(x: plot.minX, y: plot.midY))
    area.closeSubpath()
    context.fill(area, with: .color(Color.accentColor.opacity(0.16)))
    context.stroke(curve, with: .color(.accentColor), lineWidth: 2)

    for band in bands?.wrappedValue ?? [] {
      let point = handlePoint(band, plot, span)
      let radius: CGFloat = band.id == draggedBandID ? 7 : 5
      let circle = Path(
        ellipseIn: CGRect(
          x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
      context.fill(
        circle, with: .color(band.enabled ? Color.accentColor : Color(nsColor: .controlBackgroundColor)))
      context.stroke(circle, with: .color(band.enabled ? Color.white : Color.secondary), lineWidth: 1.5)
    }
  }

  private func dragGesture(plot: CGRect, span: Double) -> some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { value in
        guard let bands, !dragMissed else { return }
        if draggedBandID == nil {
          // The handle under the pointer, when the drag starts within reach of one.
          let nearest = bands.wrappedValue
            .map { band -> (id: UUID, distance: CGFloat) in
              let point = handlePoint(band, plot, span)
              return (band.id, hypot(point.x - value.startLocation.x, point.y - value.startLocation.y))
            }
            .min { $0.distance < $1.distance }
          guard let nearest, nearest.distance <= 14 else {
            dragMissed = true
            return
          }
          draggedBandID = nearest.id
        }
        guard let index = bands.wrappedValue.firstIndex(where: { $0.id == draggedBandID }) else {
          return
        }
        let position = Double(min(max((value.location.x - plot.minX) / plot.width, 0), 1))
        let frequency =
          Self.minFrequency * pow(Self.maxFrequency / Self.minFrequency, position)
        var band = bands.wrappedValue[index]
        // Two to three significant digits, like the values people type.
        let magnitude = pow(10, floor(log10(frequency)) - 2)
        band.frequency = EnhancedAudioEQBand.clamp(
          (frequency / magnitude).rounded() * magnitude, to: EnhancedAudioEQBand.frequencyRange)
        if band.kind.usesGain {
          let gain = Double((plot.midY - value.location.y) / (plot.height / 2)) * span
          band.gain = EnhancedAudioEQBand.clamp(
            (gain * 10).rounded() / 10, to: -span...span)
        }
        if band != bands.wrappedValue[index] {
          bands.wrappedValue[index] = band
        }
      }
      .onEnded { _ in
        draggedBandID = nil
        dragMissed = false
      }
  }
}
