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

struct VideoView: View {
  @EnvironmentObject private var settingsModel: SettingsModel
  @ObservedObject var languageManager = LanguageManager.shared
  @AppStorage("settings.video.customTimingRiskAcknowledged") private var customTimingRiskAcknowledged = false
  @SwiftUI.State private var showCustomTimingRiskAlert = false

  private var showingCustomTimingControls: Bool {
    settingsModel.selectedSmoothnessLatencyMode == SettingsModel.smoothnessLatencyCustom
  }

  private var videoCodecDetailKey: String {
    switch settingsModel.selectedVideoCodec {
    case "AV1":
      return "Video Codec AV1 detail"
    case "H.265":
      return "Video Codec H265 detail"
    default:
      return "Video Codec H264 detail"
    }
  }

  private var videoCodecStatus: (key: String, color: Color)? {
    guard settingsModel.selectedVideoCodec == "AV1" else { return nil }
    if settingsModel.enableYUV444 {
      return ("Video Codec AV1 YUV444 fallback detail", .orange)
    }
    if SettingsModel.av1HardwareDecodeSupported {
      return ("Video Codec AV1 current device ready detail", .secondary)
    }
    return ("Video Codec AV1 current device fallback detail", .orange)
  }

  private func timingBufferDisplayKey(for level: String) -> String {
    switch level {
    case SettingsModel.timingBufferLow:
      return "Buffer Level Low label"
    case SettingsModel.timingBufferHigh:
      return "Buffer Level High label"
    default:
      return "Buffer Level Standard label"
    }
  }

  var body: some View {
    ScrollView {
      LazyVStack {
        FormSection(title: "Video") {
          FormCell(
            title: "Video Codec", contentWidth: 200,
            content: {
              Picker("", selection: $settingsModel.selectedVideoCodec) {
                ForEach(SettingsModel.videoCodecs, id: \.self) { codec in
                  Text(languageManager.localize(codec))
                }
              }
              .labelsHidden()
              .frame(maxWidth: .infinity, alignment: .trailing)
            })

          Text(languageManager.localize(videoCodecDetailKey))
            .font(.footnote)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)

          if let videoCodecStatus {
            Text(languageManager.localize(videoCodecStatus.key))
              .font(.footnote)
              .foregroundColor(videoCodecStatus.color)
              .frame(maxWidth: .infinity, alignment: .leading)
          }

          Divider()

          ToggleCell(title: "HDR", boolBinding: $settingsModel.hdr)

          Divider()

          ToggleCell(
            title: "Enable YUV 4:4:4",
            hintKey: "YUV 4:4:4 hint",
            boolBinding: $settingsModel.enableYUV444
          )

          Divider()

          FormCell(
            title: "Streaming Style", contentWidth: 200,
            content: {
              Picker("", selection: $settingsModel.selectedSmoothnessLatencyMode) {
                ForEach(SettingsModel.smoothnessLatencyModes, id: \.self) { mode in
                  Text(languageManager.localize(mode))
                }
              }
              .labelsHidden()
              .frame(maxWidth: .infinity, alignment: .trailing)
            })

          SettingDescriptionRow(textKey: "Streaming Style detail")

          if showingCustomTimingControls {
            Divider()

            SettingDescriptionRow(textKey: "Custom timing hint")

            Divider()

            InlineSectionLabel(title: "Custom Options")

            ToggleCell(
              title: "V-Sync",
              boolBinding: $settingsModel.enableVsync
            )

            SettingDescriptionRow(textKey: "V-Sync detail")

            Divider()

            FormCell(
              title: "Buffer Level", contentWidth: 200,
              content: {
                Picker("", selection: $settingsModel.selectedTimingBufferLevel) {
                  ForEach(SettingsModel.timingBufferLevels, id: \.self) { level in
                    Text(languageManager.localize(timingBufferDisplayKey(for: level)))
                  }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .trailing)
              })

            SettingDescriptionRow(textKey: "Buffer Level detail")

            Divider()

            ToggleCell(
              title: "Prioritize Responsiveness",
              boolBinding: $settingsModel.timingPrioritizeResponsiveness
            )

            SettingDescriptionRow(textKey: "Prioritize Responsiveness detail")
          }

          Divider()

          InlineSectionLabel(title: "Compatibility")

          SettingDescriptionRow(textKey: "Compatibility section detail")

          ToggleCell(
            title: "Compatibility Mode",
            boolBinding: $settingsModel.timingCompatibilityMode
          )

          SettingDescriptionRow(textKey: "Compatibility Mode detail")

          Divider()

          ToggleCell(
            title: "SDR Compatibility Workaround",
            boolBinding: $settingsModel.timingSdrCompatibilityWorkaround
          )

          SettingDescriptionRow(textKey: "SDR Compatibility Workaround detail")

          Divider()

          ToggleCell(
            title: "Performance Overlay (⌃⌥S)",
            boolBinding: $settingsModel.showPerformanceOverlay)

          Divider()

          ToggleCell(
            title: "Show Connection Warnings",
            boolBinding: $settingsModel.showConnectionWarnings)
        }

      }
      .padding()
    }
    .onChange(of: settingsModel.selectedSmoothnessLatencyMode) { newValue in
      guard
        newValue == SettingsModel.smoothnessLatencyCustom,
        !customTimingRiskAcknowledged
      else { return }
      showCustomTimingRiskAlert = true
    }
    .alert(
      languageManager.localize("Custom timing risk title"),
      isPresented: $showCustomTimingRiskAlert
    ) {
      Button(languageManager.localize("Use Balanced Instead"), role: .cancel) {
        settingsModel.selectedSmoothnessLatencyMode = SettingsModel.smoothnessLatencyBalanced
      }
      Button(languageManager.localize("Keep Custom")) {
        customTimingRiskAcknowledged = true
      }
    } message: {
      Text(languageManager.localize("Custom timing risk detail"))
    }
  }
}
