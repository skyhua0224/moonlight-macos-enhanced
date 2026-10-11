import AVFoundation
import CoreAudio
import SwiftUI
import UniformTypeIdentifiers

/// The Mac's output devices and which of them is the system default. Also re-renders the
/// audio pane when the default changes, so a hint that names the device (Dolby passthrough)
/// never shows the one from when the pane was opened.
private final class AudioOutputDeviceList: ObservableObject {
  struct Device: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String
  }

  @Published private(set) var devices: [Device] = []
  @Published private(set) var current = AudioDeviceID(kAudioObjectUnknown)

  private var listener: AudioObjectPropertyListenerBlock?
  private static let selectors: [AudioObjectPropertySelector] = [
    kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices,
  ]

  init() {
    let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      self?.refresh()
    }
    listener = block
    for selector in Self.selectors {
      var address = Self.address(selector)
      AudioObjectAddPropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
    }
    refresh()
  }

  deinit {
    guard let block = listener else { return }
    for selector in Self.selectors {
      var address = Self.address(selector)
      AudioObjectRemovePropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
    }
  }

  private static func address(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
  ) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
  }

  private static func flag(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> Bool? {
    var address = Self.address(selector)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
      return nil
    }
    return value != 0
  }

  private static func name(_ device: AudioDeviceID) -> String? {
    var address = Self.address(kAudioObjectPropertyName)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
      return nil
    }
    return value?.takeRetainedValue() as String?
  }

  private static func hasOutput(_ device: AudioDeviceID) -> Bool {
    var address = Self.address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)
    var size: UInt32 = 0
    return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr
      && size >= UInt32(MemoryLayout<AudioStreamID>.size)
  }

  // What the default device accepts as a bitstream, asked once per device change: the hint
  // under Audio Codec is worked out every time the pane is drawn.
  private var bitstreamSupportByCodec: [Int32: MLAudioBitstreamSupport] = [:]

  func bitstreamSupport(forCodec codec: Int32) -> MLAudioBitstreamSupport {
    if let known = bitstreamSupportByCodec[codec] {
      return known
    }
    let support = MLAudioBitstreamOutput.supportOnDefaultDevice(forCodec: codec)
    bitstreamSupportByCodec[codec] = support
    return support
  }

  private func refresh() {
    bitstreamSupportByCodec = [:]
    let system = AudioObjectID(kAudioObjectSystemObject)

    var defaultAddress = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
    var defaultDevice = AudioDeviceID(kAudioObjectUnknown)
    var defaultSize = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(system, &defaultAddress, 0, nil, &defaultSize, &defaultDevice)

    var listAddress = Self.address(kAudioHardwarePropertyDevices)
    var listSize: UInt32 = 0
    var ids: [AudioDeviceID] = []
    if AudioObjectGetPropertyDataSize(system, &listAddress, 0, nil, &listSize) == noErr {
      ids = [AudioDeviceID](
        repeating: AudioDeviceID(kAudioObjectUnknown),
        count: Int(listSize) / MemoryLayout<AudioDeviceID>.size)
      if AudioObjectGetPropertyData(system, &listAddress, 0, nil, &listSize, &ids) != noErr {
        ids = []
      }
    }
    // The same devices as the Audio Output menu of the control center: alive, with output, not hidden.
    let found = ids.compactMap { id -> Device? in
      guard Self.hasOutput(id), Self.flag(id, kAudioDevicePropertyDeviceIsAlive) == true,
        Self.flag(id, kAudioDevicePropertyIsHidden) != true
      else { return nil }
      return Device(id: id, name: Self.name(id) ?? "?")
    }
    if found != devices { devices = found }
    // Published even when unchanged: the hints that depend on the device are worked out again.
    current = defaultDevice
  }

  /// Makes a device the system default output, like the sound menu of the menu bar, and has a
  /// running stream start its output again on it.
  func select(_ device: AudioDeviceID) {
    guard device != current, device != AudioDeviceID(kAudioObjectUnknown) else { return }
    // Before the change, so a passthrough session that ends because of it does not undo it.
    MLAudioBitstreamOutput.noteUserChoseDefaultOutputDevice()
    var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
    var value = device
    let status = AudioObjectSetPropertyData(
      AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
      UInt32(MemoryLayout<AudioDeviceID>.size), &value)
    guard status == noErr else {
      refresh()
      return
    }
    current = device
    NotificationCenter.default.post(
      name: Notification.Name("audioOutputDeviceChosen"), object: nil)
  }
}

struct AudioView: View {
  @EnvironmentObject private var settingsModel: SettingsModel
  @ObservedObject private var languageManager = LanguageManager.shared
  @ObservedObject private var microphoneManager = MicrophoneManager.shared
  @StateObject private var outputDevices = AudioOutputDeviceList()

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
          AudioCompactRow(
            title: "Output Device", hint: languageManager.localize("Output Device hint")
          ) {
            Picker("", selection: outputDeviceSelection) {
              ForEach(outputDevices.devices) { device in
                Text(device.name).tag(device.id)
              }
            }
            .labelsHidden()
            .controllerPicker(
              selection: outputDeviceSelection,
              choices: outputDevices.devices.map { (value: $0.id, title: $0.name) }
            )
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(width: 230, alignment: .trailing)
          }

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

        // Always shown, so what the enhancement offers can be seen before it is turned on.
        if !audioEnhancementOn {
          HStack(spacing: 10) {
            Image(systemName: "wand.and.stars")
              .foregroundStyle(.secondary)
            Text(languageManager.localize("Audio Enhancement off note"))
              .font(.callout)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(languageManager.localize("Turn On Audio Enhancement")) {
              settingsModel.selectedAudioOutputMode = "Audio Enhancement"
            }
            .controlSize(.small)
          }
          .padding(.horizontal, 2)
        }

        Group {
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
        .disabled(!audioEnhancementOn)
        .opacity(audioEnhancementOn ? 1 : 0.5)

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
      let support = outputDevices.bitstreamSupport(forCodec: Int32(choice.codecId))
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

  private var audioEnhancementOn: Bool {
    settingsModel.selectedAudioOutputMode == "Audio Enhancement"
  }

  private var outputDeviceSelection: Binding<AudioDeviceID> {
    Binding(get: { outputDevices.current }, set: { outputDevices.select($0) })
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
  @State private var showsPresetPicker = false
  @State private var curveDrag: CurveDrag?

  /// What a drag on the curve has changed. While it lasts only this section is drawn again
  /// for every move of the pointer; the settings, and with them the rest of the pane and the
  /// stream, follow 25 times a second and when the drag ends.
  private struct CurveDrag {
    var bands: [EnhancedAudioEQBand]
    var gains: [Double]
    var lastCommit: DispatchTime
  }

  /// The bands choice that is not one of the fixed layouts.
  private static let customBands = "EQ Bands Custom"

  private var frequencies: [Double] {
    SettingsModel.enhancedAudioEQFrequencies(for: settingsModel.selectedEnhancedAudioEQLayout)
  }
  private var isParametric: Bool {
    EnhancedAudioEQ.Mode(title: settingsModel.selectedEnhancedAudioEQMode) == .parametric
  }

  private var shownBands: [EnhancedAudioEQBand] {
    curveDrag?.bands ?? settingsModel.enhancedAudioEQBands
  }
  private var shownGains: [Double] {
    curveDrag?.gains ?? settingsModel.enhancedAudioEQGains
  }
  private var shownFilters: [EnhancedAudioEQ.Filter] {
    guard settingsModel.enhancedAudioEQEnabled else { return [] }
    return isParametric
      ? EnhancedAudioEQ.parametricFilters(shownBands)
      : EnhancedAudioEQ.graphicFilters(frequencies: frequencies, gains: shownGains)
  }
  private var presetActive: Bool {
    isParametric && !(settingsModel.enhancedAudioEQProfileName ?? "").isEmpty
  }

  /// One choice for the fixed layouts and the free bands.
  private var bandsSelection: Binding<String> {
    Binding(
      get: { isParametric ? Self.customBands : settingsModel.selectedEnhancedAudioEQLayout },
      set: { value in
        if value == Self.customBands {
          settingsModel.selectedEnhancedAudioEQMode = EnhancedAudioEQ.Mode.parametric.title
        } else {
          settingsModel.selectedEnhancedAudioEQLayout = value
          settingsModel.selectedEnhancedAudioEQMode = EnhancedAudioEQ.Mode.graphic.title
        }
      })
  }

  /// The points of the curve: the free bands move both ways, the fixed ones up and down.
  private var curveHandles: [AudioEQCurveView.Handle] {
    if isParametric {
      return shownBands.enumerated().map { index, band in
        AudioEQCurveView.Handle(
          id: index, frequency: band.frequency, gain: band.kind.usesGain ? band.gain : 0,
          enabled: band.enabled, movesFrequency: true, movesGain: band.kind.usesGain,
          gainLimit: EnhancedAudioEQBand.gainRange.upperBound)
      }
    }
    let gains = shownGains
    return frequencies.enumerated().map { index, frequency in
      AudioEQCurveView.Handle(
        id: index, frequency: frequency, gain: gains.indices.contains(index) ? gains[index] : 0,
        enabled: true, movesFrequency: false, movesGain: true, gainLimit: 12)
    }
  }

  private func moveHandle(_ index: Int, frequency: Double, gain: Double) {
    var drag =
      curveDrag
      ?? CurveDrag(
        bands: settingsModel.enhancedAudioEQBands, gains: settingsModel.enhancedAudioEQGains,
        lastCommit: DispatchTime(uptimeNanoseconds: 0))
    if isParametric {
      guard drag.bands.indices.contains(index) else { return }
      drag.bands[index].frequency = frequency
      if drag.bands[index].kind.usesGain { drag.bands[index].gain = gain }
    } else {
      guard drag.gains.indices.contains(index) else { return }
      // The same half-decibel steps as the sliders below.
      drag.gains[index] = (gain * 2).rounded() / 2
    }
    let now = DispatchTime.now()
    if now.uptimeNanoseconds &- drag.lastCommit.uptimeNanoseconds >= 40_000_000 {
      drag.lastCommit = now
      commit(drag)
    }
    curveDrag = drag
  }

  private func commit(_ drag: CurveDrag) {
    if isParametric {
      if settingsModel.enhancedAudioEQBands != drag.bands {
        settingsModel.enhancedAudioEQBands = drag.bands
      }
    } else if settingsModel.enhancedAudioEQGains != drag.gains {
      settingsModel.enhancedAudioEQGains = drag.gains
    }
  }

  private func endCurveDrag() {
    guard let drag = curveDrag else { return }
    commit(drag)
    curveDrag = nil
  }

  /// Rows are bound by id: a row that is being removed must not write to whichever band
  /// took its place.
  private func bandBinding(_ id: UUID) -> Binding<EnhancedAudioEQBand> {
    Binding(
      get: {
        shownBands.first { $0.id == id } ?? EnhancedAudioEQBand(kind: .peak, frequency: 1000)
      },
      set: { newValue in
        // An edit in a row ends whatever a drag left behind.
        curveDrag = nil
        guard let index = settingsModel.enhancedAudioEQBands.firstIndex(where: { $0.id == id }),
          settingsModel.enhancedAudioEQBands[index] != newValue
        else { return }
        settingsModel.enhancedAudioEQBands[index] = newValue
      })
  }

  var body: some View {
    FormSection(title: "EQ") {
      SettingsRow(title: "Enable Equalizer") {
        Toggle("", isOn: $settingsModel.enhancedAudioEQEnabled)
          .labelsHidden()
          .toggleStyle(.switch)
          .controlSize(.small)
      }
      SettingsRow(title: "Preset EQ", detail: "Preset EQ hint") {
        HStack(spacing: 8) {
          if presetActive {
            // Back to the fixed bands, which are as they were before the preset.
            Button(languageManager.localize("Preset EQ Remove")) {
              settingsModel.removeEnhancedAudioEQPreset()
              importNote = nil
            }
          }
          Button(presetButtonTitle) { showsPresetPicker = true }
            .popover(isPresented: $showsPresetPicker, arrowEdge: .bottom) {
              PresetEQPicker(currentProfile: { settingsModel.enhancedAudioEQAsProfile }) {
                profile, name in
                curveDrag = nil
                settingsModel.applyImportedEnhancedAudioEQ(profile, name: name)
                importNote = nil
                showsPresetPicker = false
              }
            }
        }
        .controlSize(.small)
      }

      AudioEQCurveView(
        filters: shownFilters, handles: curveHandles, onMove: moveHandle, onEnd: endCurveDrag
      )
      .frame(height: 200)
      .padding(.top, 10)
      .opacity(settingsModel.enhancedAudioEQEnabled ? 1 : 0.45)

      HStack(spacing: 8) {
        Button(languageManager.localize("EQ Import File")) { importFromFile() }
        Button(languageManager.localize("EQ Paste")) {
          applyImport(NSPasteboard.general.string(forType: .string), name: nil)
        }
        Spacer()
        Button(languageManager.localize("EQ Reset Bands")) { reset() }
      }
      .controlSize(.small)
      .frame(minHeight: 38)
      Text(importNote ?? languageManager.localize("EQ Import Hint"))
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) {
          Divider().opacity(0.45)
        }

      SettingsChoiceRow(
        title: "EQ Bands", selection: bandsSelection,
        options: SettingsModel.enhancedAudioEQLayouts + [Self.customBands])
      SettingsValueSliderRow(
        title: "EQ Preamp", value: $settingsModel.enhancedAudioEQPreamp,
        range: CGFloat(EnhancedAudioEQ.preampRange.lowerBound)...CGFloat(
          EnhancedAudioEQ.preampRange.upperBound),
        step: 0.5, suffix: " dB")

      if isParametric {
        ForEach(shownBands) { band in
          AudioEQBandRow(band: bandBinding(band.id)) {
            settingsModel.enhancedAudioEQBands.removeAll { $0.id == band.id }
          }
        }
        HStack {
          Button(languageManager.localize("EQ Add Band")) {
            settingsModel.enhancedAudioEQBands.append(
              EnhancedAudioEQBand(kind: .peak, frequency: 1000, q: 1))
          }
          .controlSize(.small)
          .disabled(settingsModel.enhancedAudioEQBands.count >= EnhancedAudioEQ.maxBands)
          Spacer()
        }
        .frame(minHeight: 38)
      } else {
        ForEach(frequencies, id: \.self) { frequency in
          SettingsValueSliderRow(title: String(format: "%g Hz", frequency), value: Binding(
            get: {
              let gains = shownGains
              guard let index = frequencies.firstIndex(of: frequency), gains.indices.contains(index) else { return 0 }
              return CGFloat(gains[index])
            }, set: { value in
              curveDrag = nil
              if let index = frequencies.firstIndex(of: frequency) { settingsModel.setEnhancedAudioEQGain(Double(value), at: index) }
            }), range: -12...12, step: 0.5, suffix: " dB")
        }
      }
    }
    // Read ahead of the first search, which would otherwise wait for it.
    .onAppear { HeadphoneCorrectionLibrary.shared.loadIfNeeded() }
  }

  private var presetButtonTitle: String {
    if presetActive, let name = settingsModel.enhancedAudioEQProfileName {
      return name
    }
    return languageManager.localize("Preset EQ Choose")
  }

  /// Back to a flat equalizer of the kind that is showing.
  private func reset() {
    curveDrag = nil
    if isParametric {
      settingsModel.enhancedAudioEQBands = EnhancedAudioEQ.starterBands()
    } else {
      settingsModel.enhancedAudioEQGains = [Double](repeating: 0, count: frequencies.count)
    }
    settingsModel.enhancedAudioEQPreamp = 0
    settingsModel.enhancedAudioEQProfileName = nil
    importNote = nil
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
    curveDrag = nil
    settingsModel.applyImportedEnhancedAudioEQ(
      profile, name: name ?? languageManager.localize("EQ Imported Name"))
    importNote =
      profile.skippedLines > 0
      ? String(
        format: languageManager.localize("EQ Import Skipped %d %d"), profile.bands.count,
        profile.skippedLines)
      : String(format: languageManager.localize("EQ Import Done %d"), profile.bands.count)
  }
}

/// Saved presets and the library of measured headphones, searched together; picking one
/// applies it. The current equalizer can be saved under a name from here.
private struct PresetEQPicker: View {
  let currentProfile: () -> EnhancedAudioEQ.ImportedProfile
  let onPick: (EnhancedAudioEQ.ImportedProfile, String) -> Void
  @ObservedObject private var library = HeadphoneCorrectionLibrary.shared
  @ObservedObject private var userPresets = EnhancedAudioEQUserPresets.shared
  @ObservedObject private var languageManager = LanguageManager.shared
  @State private var query = ""
  @State private var newName = ""

  var body: some View {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    let saved = userPresets.presets.filter {
      trimmed.isEmpty || $0.name.localizedCaseInsensitiveContains(trimmed)
    }
    let results = library.search(query)
    VStack(alignment: .leading, spacing: 8) {
      TextField(languageManager.localize("Preset EQ Search"), text: $query)
        .textFieldStyle(.roundedBorder)
        .onSubmit {
          // Return takes the first match.
          if let preset = saved.first {
            onPick(preset.profile, preset.name)
          } else if let entry = results.first {
            onPick(library.profile(for: entry), entry.name)
          }
        }

      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          if !saved.isEmpty {
            sectionTitle("Preset EQ Saved")
            ForEach(saved) { preset in
              HStack(spacing: 4) {
                row(
                  preset.name,
                  String(
                    format: languageManager.localize("Preset EQ bands %d"), preset.bands.count)
                ) {
                  onPick(preset.profile, preset.name)
                }
                Button {
                  userPresets.delete(preset.id)
                } label: {
                  Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
              }
            }
          }
          if !results.isEmpty {
            sectionTitle("Preset EQ Library")
            ForEach(results) { entry in
              row(entry.name, entry.form.isEmpty ? entry.source : "\(entry.form) · \(entry.source)") {
                onPick(library.profile(for: entry), entry.name)
              }
            }
          } else if trimmed.isEmpty || saved.isEmpty {
            Text(
              languageManager.localize(
                trimmed.isEmpty ? "Preset EQ search hint" : "Preset EQ search empty")
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 24)
          }
        }
      }

      Divider()
      HStack(spacing: 8) {
        TextField(languageManager.localize("Preset EQ Name"), text: $newName)
          .textFieldStyle(.roundedBorder)
        Button(languageManager.localize("Preset EQ Save")) {
          userPresets.save(name: newName, profile: currentProfile())
          newName = ""
        }
        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
      }
      Text(
        String(
          format: languageManager.localize("Preset EQ attribution"), library.entries.count)
      )
      .font(.caption2)
      .foregroundStyle(.secondary)
    }
    .padding(12)
    .frame(width: 400, height: 460)
    .onAppear { library.loadIfNeeded() }
  }

  private func sectionTitle(_ key: String) -> some View {
    Text(languageManager.localize(key))
      .font(.caption.weight(.semibold))
      .foregroundStyle(.secondary)
      .padding(.top, 6)
      .padding(.bottom, 2)
  }

  private func row(_ title: String, _ subtitle: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 1) {
        Text(verbatim: title)
        Text(verbatim: subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 4)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
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

      Slider(
        value: clamped(\.gain, EnhancedAudioEQBand.gainRange), in: EnhancedAudioEQBand.gainRange,
        step: 0.1
      )
      .controllerSlider(
        value: clamped(\.gain, EnhancedAudioEQBand.gainRange), in: EnhancedAudioEQBand.gainRange,
        step: 0.5)
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

/// The live spectrum of a running stream, behind the curve. A view of its own, so that its 30
/// updates a second draw nothing else again.
private struct AudioEQSpectrumLayer: View {
  // What a running stream plays right now; empty without one in the enhanced sound mode.
  @ObservedObject private var spectrum = EnhancedAudioSpectrum.shared

  var body: some View {
    Canvas { context, size in
      let levels = spectrum.levels
      guard levels.count > 1 else { return }
      let plot = AudioEQCurveView.plotRect(in: size)
      // The bottom of the plot is -90 dB, the top full scale.
      var shape = Path()
      shape.move(to: CGPoint(x: plot.minX, y: plot.maxY))
      for (index, level) in levels.enumerated() {
        let frequency = EnhancedAudioSpectrum.frequency(ofBand: index)
        let height = CGFloat(min(max((Double(level) + 90) / 90, 0), 1)) * plot.height
        shape.addLine(
          to: CGPoint(x: AudioEQCurveView.x(frequency, plot), y: plot.maxY - height))
      }
      shape.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
      shape.closeSubpath()
      context.fill(shape, with: .color(Color.secondary.opacity(0.22)))
    }
    .allowsHitTesting(false)
    .onAppear { spectrum.addViewer() }
    .onDisappear { spectrum.removeViewer() }
  }
}

/// The frequency response the equalizer is set to, 20 Hz to 20 kHz on a log axis, with a point
/// for every band that can be dragged, and the live spectrum of a running stream behind it.
private struct AudioEQCurveView: View {
  struct Handle: Identifiable, Equatable {
    let id: Int
    var frequency: Double
    var gain: Double
    var enabled: Bool
    /// The fixed bands only move up and down.
    var movesFrequency: Bool
    var movesGain: Bool
    var gainLimit: Double
  }

  private struct Drag: Equatable {
    var start: CGPoint
    /// nil when the drag did not begin on a point.
    var handle: Int?
    /// The gain axis as it was when the drag began. It stays put until the drag ends: an axis
    /// that grew with the value being dragged would run away from the pointer.
    var span: Double
  }

  let filters: [EnhancedAudioEQ.Filter]
  let handles: [Handle]
  let onMove: (_ id: Int, _ frequency: Double, _ gain: Double) -> Void
  /// The drag is over: what it changed can be handed on.
  let onEnd: () -> Void
  @State private var drag: Drag?

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
    for handle in handles {
      peak = max(peak, abs(handle.gain))
    }
    if peak <= 11.5 { return 12 }
    if peak <= 17.5 { return 18 }
    return 24
  }

  var body: some View {
    ZStack {
      AudioEQSpectrumLayer()
      GeometryReader { proxy in
        let samples = self.samples
        let span = drag?.span ?? gainSpan(samples)
        let plot = Self.plotRect(in: proxy.size)
        Canvas { context, _ in
          draw(in: &context, plot: plot, samples: samples, span: span)
        }
        .contentShape(Rectangle())
        .gesture(dragGesture(plot: plot, span: span))
      }
    }
  }

  static func plotRect(in size: CGSize) -> CGRect {
    CGRect(
      x: leftInset, y: 4, width: max(1, size.width - leftInset - 4),
      height: max(1, size.height - bottomInset - 4))
  }

  static func x(_ frequency: Double, _ plot: CGRect) -> CGFloat {
    let position = log10(frequency / minFrequency) / log10(maxFrequency / minFrequency)
    return plot.minX + CGFloat(position) * plot.width
  }

  private func x(_ frequency: Double, _ plot: CGRect) -> CGFloat {
    Self.x(frequency, plot)
  }

  private func y(_ gain: Double, _ plot: CGRect, _ span: Double) -> CGFloat {
    let clampedGain = min(max(gain, -span), span)
    return plot.midY - CGFloat(clampedGain / span) * plot.height / 2
  }

  private func point(_ handle: Handle, _ plot: CGRect, _ span: Double) -> CGPoint {
    CGPoint(x: x(handle.frequency, plot), y: y(handle.gain, plot, span))
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

    // Many fixed bands sit close together at the low end: smaller points there.
    let baseRadius: CGFloat = handles.count > 16 ? 3.5 : 5
    for handle in handles {
      let center = point(handle, plot, span)
      let radius = handle.id == drag?.handle ? baseRadius + 2 : baseRadius
      let circle = Path(
        ellipseIn: CGRect(
          x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
      context.fill(
        circle,
        with: .color(handle.enabled ? Color.accentColor : Color(nsColor: .controlBackgroundColor)))
      context.stroke(
        circle, with: .color(handle.enabled ? Color.white : Color.secondary), lineWidth: 1.5)
    }
  }

  private func dragGesture(plot: CGRect, span: Double) -> some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { value in
        var current = drag
        if current?.start != value.startLocation {
          // A new drag. A cancelled one never reports its end, so this is also where what it
          // left behind goes.
          if current != nil { onEnd() }
          let nearest = handles
            .map { handle -> (id: Int, distance: CGFloat) in
              let center = point(handle, plot, span)
              return (
                handle.id,
                hypot(center.x - value.startLocation.x, center.y - value.startLocation.y)
              )
            }
            .min { $0.distance < $1.distance }
          var grabbed: Int?
          if let nearest, nearest.distance <= 14 {
            grabbed = nearest.id
          }
          current = Drag(start: value.startLocation, handle: grabbed, span: span)
          drag = current
        }
        guard let active = current, let id = active.handle,
          let handle = handles.first(where: { $0.id == id })
        else { return }

        var frequency = handle.frequency
        if handle.movesFrequency {
          let position = Double(min(max((value.location.x - plot.minX) / plot.width, 0), 1))
          let raw = Self.minFrequency * pow(Self.maxFrequency / Self.minFrequency, position)
          // Three significant digits, like the values people type.
          let magnitude = pow(10, floor(log10(raw)) - 2)
          frequency = EnhancedAudioEQBand.clamp(
            (raw / magnitude).rounded() * magnitude, to: EnhancedAudioEQBand.frequencyRange)
        }
        var gain = handle.gain
        if handle.movesGain {
          let limit = min(active.span, handle.gainLimit)
          let raw = Double((plot.midY - value.location.y) / (plot.height / 2)) * active.span
          gain = min(max((raw * 10).rounded() / 10, -limit), limit)
        }
        if frequency != handle.frequency || gain != handle.gain {
          onMove(id, frequency, gain)
        }
      }
      .onEnded { _ in
        drag = nil
        onEnd()
      }
  }
}
