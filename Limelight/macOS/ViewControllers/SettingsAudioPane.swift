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

struct AudioView: View {
  @EnvironmentObject private var settingsModel: SettingsModel
  @ObservedObject var languageManager = LanguageManager.shared
  @ObservedObject var micManager = MicrophoneManager.shared

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
