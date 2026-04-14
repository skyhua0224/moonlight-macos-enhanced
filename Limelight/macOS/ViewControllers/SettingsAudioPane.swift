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
import CoreAudio
import CoreGraphics
import SwiftUI

struct AudioView: View {
  @EnvironmentObject private var settingsModel: SettingsModel
  @ObservedObject var languageManager = LanguageManager.shared
  @ObservedObject var micManager = MicrophoneManager.shared

  private var defaultOutputChannelCount: Int {
    AudioOutputDeviceInfo.defaultOutputChannelCount()
  }

  private var currentEQFrequencies: [Double] {
    SettingsModel.enhancedAudioEQFrequencies(for: settingsModel.selectedEnhancedAudioEQLayout)
  }

  private var usesDenseEQLayout: Bool {
    settingsModel.selectedEnhancedAudioEQLayout == "24-Band"
  }

  var body: some View {
    ScrollView {
      LazyVStack {
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

          FormCell(title: "Sound Mode", contentWidth: 250) {
            AudioModeSegmentedPicker(
              selection: $settingsModel.selectedAudioOutputMode,
              options: SettingsModel.audioOutputModes
            )
            .frame(maxWidth: .infinity, alignment: .trailing)
          }

          if defaultOutputChannelCount > 2 {
            Divider()

            HStack(alignment: .top, spacing: 8) {
              Image(systemName: "speaker.wave.3.fill")
                .foregroundColor(.accentColor)
                .padding(.top, 2)
              Text(
                languageManager.localize(
                  "Multi-channel device detected. Use Default for true 5.1/7.1/7.1.4 playback, or Audio Enhancement for headphone/stereo virtualization."
                )
              )
              .font(.callout)
              .foregroundColor(.secondary)
            }
          }

          if settingsModel.selectedAudioOutputMode == "Audio Enhancement" {
            Divider()

            FormCell(title: "Listening Device", contentWidth: 290) {
              AudioModeSegmentedPicker(
                selection: $settingsModel.selectedEnhancedAudioOutputTarget,
                options: SettingsModel.enhancedAudioOutputTargets,
                displayOptions: SettingsModel.enhancedAudioOutputTargetDisplayOrder
              )
              .frame(maxWidth: .infinity, alignment: .trailing)
            }

            Divider()

            AudioPresetChipRow(
              title: languageManager.localize("EQ Preset"),
              selection: $settingsModel.selectedEnhancedAudioPreset,
              options: SettingsModel.enhancedAudioPresets
            )

            Text(
              languageManager.localize(
                SettingsModel.enhancedAudioPresetDescription(for: settingsModel.selectedEnhancedAudioPreset)
              )
            )
            .font(.callout)
            .foregroundColor(.secondary)

            Divider()

            FormCell(title: "EQ Detail", contentWidth: 180) {
              AudioModeSegmentedPicker(
                selection: $settingsModel.selectedEnhancedAudioEQLayout,
                options: SettingsModel.enhancedAudioEQLayouts
              )
              .frame(maxWidth: .infinity, alignment: .trailing)
            }

            Divider()

            AudioParameterSliderRow(
              title: languageManager.localize("Spatial Intensity"),
              value: $settingsModel.enhancedAudioSpatialIntensity
            )

            Divider()

            AudioParameterSliderRow(
              title: languageManager.localize("Soundstage Width"),
              value: $settingsModel.enhancedAudioSoundstageWidth
            )

            Divider()

            AudioParameterSliderRow(
              title: languageManager.localize("Reverb"),
              value: $settingsModel.enhancedAudioReverbAmount
            )

            Divider()

            VStack(alignment: .leading, spacing: 12) {
              Text(languageManager.localize("EQ"))
                .font(.headline)

              HStack {
                Text("+12 dB")
                Spacer()
                Text("0 dB")
                Spacer()
                Text("-12 dB")
              }
              .font(.caption)
              .foregroundColor(.secondary)

              ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .bottom, spacing: usesDenseEQLayout ? 10 : 14) {
                  ForEach(Array(currentEQFrequencies.enumerated()), id: \.offset) {
                    index, frequency in
                    ProfessionalEQBandSlider(
                      title: AudioOutputDeviceInfo.eqLabel(for: frequency, compact: usesDenseEQLayout),
                      compact: usesDenseEQLayout,
                      value: Binding(
                        get: { settingsModel.enhancedAudioEQGains[safe: index] ?? 0.0 },
                        set: { settingsModel.setEnhancedAudioEQGain($0, at: index) }
                      ))
                  }
                }
                .padding(.vertical, 4)
              }
            }
          }

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

private struct AudioModeSegmentedPicker: View {
  @Binding var selection: String
  let displayOptions: [String]
  @ObservedObject private var languageManager = LanguageManager.shared

  init(selection: Binding<String>, options: [String], displayOptions: [String]? = nil) {
    _selection = selection
    self.displayOptions = (displayOptions ?? options).filter { options.contains($0) }
  }

  var body: some View {
    Picker("", selection: $selection) {
      ForEach(displayOptions, id: \.self) { option in
        Text(languageManager.localize(option)).tag(option)
      }
    }
    .labelsHidden()
    .pickerStyle(.segmented)
  }
}

private struct AudioPresetChipRow: View {
  let title: String
  @Binding var selection: String
  let options: [String]
  @ObservedObject private var languageManager = LanguageManager.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title)
        .font(.headline)

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 10) {
          ForEach(options, id: \.self) { option in
            Button {
              selection = option
            } label: {
              Text(languageManager.localize(option))
                .font(.callout.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                  Capsule()
                    .fill(selection == option ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.10))
                )
                .overlay(
                  Capsule()
                    .stroke(selection == option ? Color.accentColor : Color.secondary.opacity(0.16), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.vertical, 2)
      }
    }
  }
}

private struct AudioParameterSliderRow: View {
  let title: String
  @Binding var value: CGFloat

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(title)
        Spacer()
        Text("\(Int(value * 100))%")
          .foregroundColor(.secondary)
          .availableMonospacedDigit()
      }

      Slider(value: $value, in: 0.0...1.0)
    }
  }
}

private struct ProfessionalEQBandSlider: View {
  let title: String
  let compact: Bool
  @Binding var value: Double

  private let range = -12.0...12.0

  private func clamped(_ candidate: Double) -> Double {
    min(max(candidate, range.lowerBound), range.upperBound)
  }

  private func mappedValue(for locationY: CGFloat, height: CGFloat) -> Double {
    guard height > 0 else { return value }
    let progress = 1.0 - min(max(locationY / height, 0.0), 1.0)
    return clamped(range.lowerBound + Double(progress) * (range.upperBound - range.lowerBound))
  }

  var body: some View {
    VStack(spacing: compact ? 6 : 8) {
      Text(String(format: "%+.1f", value))
        .font(.caption)
        .foregroundColor(.secondary)
        .availableMonospacedDigit()
        .frame(width: compact ? 34 : 42)

      GeometryReader { geometry in
        let trackWidth: CGFloat = compact ? 5 : 6
        let zeroY = geometry.size.height / 2
        let normalized = CGFloat((clamped(value) - range.lowerBound) / (range.upperBound - range.lowerBound))
        let knobY = geometry.size.height * (1.0 - normalized)
        let activeHeight = abs(knobY - zeroY)

        ZStack {
          RoundedRectangle(cornerRadius: trackWidth / 2)
            .fill(Color.secondary.opacity(0.16))
            .frame(width: trackWidth)

          Rectangle()
            .fill(Color.secondary.opacity(0.22))
            .frame(height: 1)
            .padding(.horizontal, compact ? 4 : 6)
            .position(x: geometry.size.width / 2, y: zeroY)

          RoundedRectangle(cornerRadius: trackWidth / 2)
            .fill(Color.accentColor.opacity(0.85))
            .frame(width: trackWidth, height: max(activeHeight, 2))
            .position(
              x: geometry.size.width / 2,
              y: value >= 0 ? (zeroY - activeHeight / 2) : (zeroY + activeHeight / 2)
            )

          Circle()
            .fill(Color.white)
            .overlay(Circle().stroke(Color.accentColor, lineWidth: compact ? 1.5 : 1.8))
            .frame(width: compact ? 12 : 14, height: compact ? 12 : 14)
            .position(x: geometry.size.width / 2, y: knobY)
            .shadow(color: Color.black.opacity(0.12), radius: 2, y: 1)
        }
        .contentShape(Rectangle())
        .gesture(
          DragGesture(minimumDistance: 0)
            .onChanged { gesture in
              value = mappedValue(for: gesture.location.y, height: geometry.size.height)
            }
        )
      }
      .frame(width: compact ? 34 : 40, height: compact ? 152 : 164)

      Text(title)
        .font(.caption)
        .foregroundColor(.secondary)
        .frame(width: compact ? 34 : 50)
    }
  }
}

private enum AudioOutputDeviceInfo {
  static func defaultOutputChannelCount() -> Int {
    var deviceID = AudioDeviceID(0)
    var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )

    let status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      &propertySize,
      &deviceID
    )
    guard status == noErr else { return 2 }

    var streamConfigSize: UInt32 = 0
    var streamConfigAddress = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreamConfiguration,
      mScope: kAudioDevicePropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain
    )

    let sizeStatus = AudioObjectGetPropertyDataSize(
      deviceID,
      &streamConfigAddress,
      0,
      nil,
      &streamConfigSize
    )
    guard sizeStatus == noErr, streamConfigSize > 0 else { return 2 }

    let bufferList = UnsafeMutableRawPointer.allocate(
      byteCount: Int(streamConfigSize),
      alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { bufferList.deallocate() }

    let configStatus = AudioObjectGetPropertyData(
      deviceID,
      &streamConfigAddress,
      0,
      nil,
      &streamConfigSize,
      bufferList
    )
    guard configStatus == noErr else { return 2 }

    let audioBufferList = bufferList.assumingMemoryBound(to: AudioBufferList.self)
    let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
    return max(buffers.reduce(0) { $0 + Int($1.mNumberChannels) }, 2)
  }

  static func eqLabel(for frequency: Double, compact: Bool = false) -> String {
    if frequency >= 1000 {
      let kiloValue = frequency / 1000
      if compact {
        if floor(kiloValue) == kiloValue {
          return "\(Int(kiloValue))k"
        }
        return String(format: "%.1fk", kiloValue)
      }
      if floor(kiloValue) == kiloValue {
        return "\(Int(kiloValue)) kHz"
      }
      return String(format: "%.1f kHz", kiloValue)
    }
    if compact {
      if floor(frequency) == frequency {
        return "\(Int(frequency))"
      }
      return String(format: "%.1f", frequency)
    }
    if floor(frequency) == frequency {
      return "\(Int(frequency)) Hz"
    }
    return String(format: "%.1f Hz", frequency)
  }
}

private extension Array {
  subscript(safe index: Index) -> Element? {
    indices.contains(index) ? self[index] : nil
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
