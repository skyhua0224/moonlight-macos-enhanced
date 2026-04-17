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
  @AppStorage("settings.video.metalTuningExpanded") private var metalTuningExpanded = false
  @SwiftUI.State private var showCustomTimingRiskAlert = false

  private static let hdrBrightnessFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.minimum = 0
    formatter.maximumFractionDigits = 0
    formatter.minimumFractionDigits = 0
    return formatter
  }()

  private static let hdrMinBrightnessFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.minimum = 0
    formatter.maximumFractionDigits = 4
    formatter.minimumFractionDigits = 0
    return formatter
  }()

  private var showingCustomTimingControls: Bool {
    settingsModel.selectedSmoothnessLatencyMode == SettingsModel.smoothnessLatencyCustom
  }

  private var normalizedRendererMode: String {
    SettingsModel.normalizedVideoRendererMode(settingsModel.selectedVideoRendererMode)
  }

  private var showsMetalTuningControls: Bool {
    normalizedRendererMode == "Metal Renderer"
  }

  private var showsManualHdrLuminanceControls: Bool {
    settingsModel.selectedHdrClientDisplayProfile == "Manual"
      && settingsModel.selectedHdrMetadataSource != "Host"
  }

  private var showsManualHdrLuminanceHint: Bool {
    settingsModel.selectedHdrClientDisplayProfile == "Manual"
      && settingsModel.selectedHdrMetadataSource == "Host"
  }

  private var frameInterpolationCapabilityAvailable: Bool {
    settingsModel.videoCapabilityMatrix.items.first(where: { $0.id == "enhancement.vtLowLatencyFI" })?
      .availability == .available
  }

  private var frameInterpolationDetailKey: String {
    if !showsMetalTuningControls {
      return "Frame Interpolation Metal only detail"
    }
    return frameInterpolationCapabilityAvailable
      ? "Frame Interpolation detail"
      : "Frame Interpolation unavailable detail"
  }

  private var upscalingDetailKey: String {
    showsMetalTuningControls ? "Upscaling detail" : "Upscaling Metal only detail"
  }

  private var metalTuningDetailKey: String {
    showsMetalTuningControls
      ? "Metal Renderer tuning detail"
      : "Metal Renderer tuning unavailable detail"
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
    if SettingsModel.av1HardwareDecodeSupported {
      if settingsModel.enableYUV444 {
        return ("Video Codec AV1 YUV444 ready detail", .secondary)
      }
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

          FormCell(
            title: "Renderer Mode", contentWidth: 220,
            content: {
              Picker("", selection: $settingsModel.selectedVideoRendererMode) {
                ForEach(SettingsModel.videoRendererModes, id: \.self) { mode in
                  Text(languageManager.localize(mode))
                }
              }
              .labelsHidden()
              .frame(maxWidth: .infinity, alignment: .trailing)
            })

          SettingDescriptionRow(textKey: "Renderer Mode detail")

          Divider()

          ToggleCell(title: "HDR", boolBinding: $settingsModel.hdr)

          Divider()

          FormCell(
            title: "Transfer Function", contentWidth: 200,
            content: {
              Picker("", selection: $settingsModel.selectedHdrTransferFunction) {
                ForEach(SettingsModel.hdrTransferFunctions, id: \.self) { mode in
                  Text(languageManager.localize(mode))
                }
              }
              .labelsHidden()
              .frame(maxWidth: .infinity, alignment: .trailing)
            })

          SettingDescriptionRow(textKey: "Transfer Function detail")

          Divider()

          InlineSectionLabel(title: "Quality Enhancement")

          FormCell(
            title: "Upscaling", contentWidth: 220,
            content: {
              Picker("", selection: $settingsModel.selectedUpscalingMode) {
                ForEach(SettingsModel.upscalingModes, id: \.self) { mode in
                  Text(languageManager.localize(mode))
                }
              }
              .labelsHidden()
              .disabled(!showsMetalTuningControls)
              .frame(maxWidth: .infinity, alignment: .trailing)
            })

          SettingDescriptionRow(textKey: upscalingDetailKey)
          SettingDescriptionRow(textKey: "AI enhancement recommended hint")
          SettingDescriptionRow(textKey: "Scale vs Upscaling hint")

          if settingsModel.streamResolutionScale && settingsModel.streamResolutionScaleRatio < 100
            && settingsModel.selectedUpscalingMode == "Off"
          {
            SettingDescriptionRow(textKey: "Resolution Scale + Upscaling hint")
          }

          Divider()

          FormCell(
            title: "Frame Interpolation", contentWidth: 260,
            content: {
              Picker("", selection: $settingsModel.selectedFrameInterpolationMode) {
                ForEach(SettingsModel.frameInterpolationModes, id: \.self) { mode in
                  Text(languageManager.localize(mode))
                }
              }
              .labelsHidden()
              .disabled(!showsMetalTuningControls || !frameInterpolationCapabilityAvailable)
              .frame(maxWidth: .infinity, alignment: .trailing)
            })

          SettingDescriptionRow(textKey: frameInterpolationDetailKey)

          Divider()

          DisclosureGroup(
            isExpanded: $metalTuningExpanded,
            content: {
              VStack(alignment: .leading, spacing: 14) {
                SettingDescriptionRow(textKey: metalTuningDetailKey)

                if showsMetalTuningControls {
                  Divider()

                  FormCell(
                    title: "HDR Metadata Source", contentWidth: 220,
                    content: {
                      Picker("", selection: $settingsModel.selectedHdrMetadataSource) {
                        ForEach(SettingsModel.hdrMetadataSources, id: \.self) { source in
                          Text(languageManager.localize(source))
                        }
                      }
                      .labelsHidden()
                      .frame(maxWidth: .infinity, alignment: .trailing)
                    })

                  SettingDescriptionRow(textKey: "HDR Metadata Source detail")

                  Divider()

                  FormCell(
                    title: "Client Display HDR Profile", contentWidth: 220,
                    content: {
                      Picker("", selection: $settingsModel.selectedHdrClientDisplayProfile) {
                        ForEach(SettingsModel.hdrClientDisplayProfiles, id: \.self) { profile in
                          Text(languageManager.localize(profile))
                        }
                      }
                      .labelsHidden()
                      .frame(maxWidth: .infinity, alignment: .trailing)
                    })

                  SettingDescriptionRow(textKey: "Client Display HDR Profile detail")

                  if showsManualHdrLuminanceHint {
                    SettingDescriptionRow(textKey: "HDR Manual Luminance Host detail")
                    Divider()
                  }

                  if showsManualHdrLuminanceControls {
                    Divider()

                    FormCell(
                      title: "Max Brightness", contentWidth: 160,
                      content: {
                        TextField(
                          "1000",
                          value: $settingsModel.hdrManualMaxBrightness,
                          formatter: Self.hdrBrightnessFormatter
                        )
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                      })

                    Divider()

                    FormCell(
                      title: "Min Brightness", contentWidth: 160,
                      content: {
                        TextField(
                          "0.001",
                          value: $settingsModel.hdrManualMinBrightness,
                          formatter: Self.hdrMinBrightnessFormatter
                        )
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                      })

                    Divider()

                    FormCell(
                      title: "Max Average Brightness", contentWidth: 200,
                      content: {
                        TextField(
                          "1000",
                          value: $settingsModel.hdrManualMaxAverageBrightness,
                          formatter: Self.hdrBrightnessFormatter
                        )
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                      })

                    SettingDescriptionRow(textKey: "HDR Manual Luminance detail")
                  }

                  Divider()

                  VideoPercentageSliderRow(
                    title: "Optical Output Scale",
                    value: $settingsModel.hdrOpticalOutputScale,
                    range: 50...200,
                    step: 1,
                    suffix: "%"
                  )

                  SettingDescriptionRow(textKey: "Optical Output Scale detail")

                  Divider()

                  FormCell(
                    title: "HLG Viewing Environment", contentWidth: 220,
                    content: {
                      Picker("", selection: $settingsModel.selectedHdrHlgViewingEnvironment) {
                        ForEach(SettingsModel.hdrHlgViewingEnvironments, id: \.self) { item in
                          Text(languageManager.localize(item))
                        }
                      }
                      .labelsHidden()
                      .frame(maxWidth: .infinity, alignment: .trailing)
                    })

                  SettingDescriptionRow(textKey: "HLG Viewing Environment detail")

                  Divider()

                  FormCell(
                    title: "EDR Strategy", contentWidth: 220,
                    content: {
                      Picker("", selection: $settingsModel.selectedHdrEdrStrategy) {
                        ForEach(SettingsModel.hdrEdrStrategies, id: \.self) { strategy in
                          Text(languageManager.localize(strategy))
                        }
                      }
                      .labelsHidden()
                      .frame(maxWidth: .infinity, alignment: .trailing)
                    })

                  SettingDescriptionRow(textKey: "EDR Strategy detail")

                  Divider()

                  FormCell(
                    title: "Tone Mapping Policy", contentWidth: 220,
                    content: {
                      Picker("", selection: $settingsModel.selectedHdrToneMappingPolicy) {
                        ForEach(SettingsModel.hdrToneMappingPolicies, id: \.self) { policy in
                          Text(languageManager.localize(policy))
                        }
                      }
                      .labelsHidden()
                      .frame(maxWidth: .infinity, alignment: .trailing)
                    })

                  SettingDescriptionRow(textKey: "Tone Mapping Policy detail")

                  Divider()

                  FormCell(
                    title: "Display Sync", contentWidth: 220,
                    content: {
                      Picker("", selection: $settingsModel.selectedDisplaySyncMode) {
                        ForEach(SettingsModel.displaySyncModes, id: \.self) { mode in
                          Text(languageManager.localize(mode))
                        }
                      }
                      .labelsHidden()
                      .frame(maxWidth: .infinity, alignment: .trailing)
                    })

                  SettingDescriptionRow(textKey: "Display Sync detail")

                  Divider()

                  FormCell(
                    title: "Allow Drawable Timeout", contentWidth: 220,
                    content: {
                      Picker("", selection: $settingsModel.selectedAllowDrawableTimeoutMode) {
                        ForEach(SettingsModel.allowDrawableTimeoutModes, id: \.self) { mode in
                          Text(languageManager.localize(mode))
                        }
                      }
                      .labelsHidden()
                      .frame(maxWidth: .infinity, alignment: .trailing)
                    })

                  SettingDescriptionRow(textKey: "Allow Drawable Timeout detail")
                }
              }
              .padding(.top, 8)
            },
            label: {
              VideoDisclosureLabel(title: "Metal Renderer Tuning")
            }
          )

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

            Divider()

            FormCell(
              title: "Frame Queue Target", contentWidth: 220,
              content: {
                Picker("", selection: $settingsModel.selectedFrameQueueTarget) {
                  ForEach(SettingsModel.frameQueueTargets, id: \.self) { target in
                    Text(languageManager.localize(target))
                  }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .trailing)
              })

            SettingDescriptionRow(textKey: "Frame Queue Target detail")

            Divider()

            FormCell(
              title: "Responsiveness Bias", contentWidth: 220,
              content: {
                Picker("", selection: $settingsModel.selectedResponsivenessBias) {
                  ForEach(SettingsModel.responsivenessBiasModes, id: \.self) { mode in
                    Text(languageManager.localize(mode))
                  }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .trailing)
              })

            SettingDescriptionRow(textKey: "Responsiveness Bias detail")
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
    .onAppear {
      settingsModel.refreshVideoDiagnosticsState()
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

private struct VideoDisclosureLabel: View {
  let title: String
  @ObservedObject private var languageManager = LanguageManager.shared

  var body: some View {
    HStack {
      Text(languageManager.localize(title))
      Spacer()
      Text(languageManager.localize("Advanced"))
        .font(.footnote)
        .foregroundColor(.secondary)
    }
  }
}

private struct VideoPercentageSliderRow: View {
  let title: String
  @Binding var value: CGFloat
  let range: ClosedRange<CGFloat>
  let step: CGFloat
  let suffix: String
  @ObservedObject private var languageManager = LanguageManager.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(languageManager.localize(title))
        Spacer()
        Text("\(Int(value.rounded()))\(suffix)")
          .foregroundColor(.secondary)
          .availableMonospacedDigit()
      }

      Slider(value: $value, in: range, step: step)
    }
  }
}
