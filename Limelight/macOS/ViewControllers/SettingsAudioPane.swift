import AVFoundation
import SwiftUI

struct AudioView: View {
  @EnvironmentObject private var settingsModel: SettingsModel
  @ObservedObject private var languageManager = LanguageManager.shared
  @ObservedObject private var microphoneManager = MicrophoneManager.shared

  var body: some View {
    ScrollView {
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
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(width: 190, alignment: .trailing)
          }

          AudioCompactRow(title: "Play Sound on Host") {
            Toggle("", isOn: $settingsModel.audioOnPC)
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
            .frame(width: 210, alignment: .trailing)
            .onAppear { microphoneManager.refreshDevices() }
          }

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
  }
}

private struct AudioCompactRow<Content: View>: View {
  let title: String
  let content: Content
  let showsSeparator: Bool

  init(title: String, showsSeparator: Bool = true, @ViewBuilder content: () -> Content) {
    self.title = title
    self.showsSeparator = showsSeparator
    self.content = content()
  }

  var body: some View {
    HStack(spacing: 16) {
      Text(LocalizedStringKey(title))
        .frame(maxWidth: .infinity, alignment: .leading)
      content
    }
    .frame(minHeight: 38)
    .overlay(alignment: .bottom) {
      if showsSeparator {
        Divider().opacity(0.45)
      }
    }
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
      Slider(value: $value, in: 0...1)
        .frame(width: 190)
      Image(systemName: "speaker.wave.3.fill")
        .foregroundStyle(.secondary)
    }
    .frame(minHeight: 42)
    .overlay(alignment: .bottom) {
      if showsSeparator {
        Divider().opacity(0.45)
      }
    }
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
