import SwiftUI

struct VideoView: View {
  @EnvironmentObject private var settingsModel: SettingsModel
  @ObservedObject private var languageManager = LanguageManager.shared
  private var metalSelected: Bool {
    SettingsModel.normalizedVideoRendererMode(settingsModel.selectedVideoRendererMode) == "Metal Renderer"
  }

  var body: some View {
    SettingsContent {
      SettingsPageHero(
        title: "Video & HDR",
        subtitle: "Video settings subtitle",
        symbol: "video.fill",
        tint: .blue
      )

      FormSection(title: "Video") {
        SettingsRow(title: "Video Codec") {
          Picker("", selection: $settingsModel.selectedVideoCodec) {
            ForEach(SettingsModel.videoCodecs, id: \.self) { codec in
              Text(languageManager.localize(codec)).tag(codec)
            }
          }
          .labelsHidden()
          .frame(width: 190, alignment: .trailing)
        }


        SettingsRow(title: "Renderer Mode") {
          Picker("", selection: $settingsModel.selectedVideoRendererMode) {
            ForEach(SettingsModel.videoRendererModes, id: \.self) { mode in
              Text(languageManager.localize(mode)).tag(mode)
            }
          }
          .labelsHidden()
          .frame(width: 220, alignment: .trailing)
        }

        ToggleCell(title: "HDR", hintKey: "HDR detail", boolBinding: $settingsModel.hdr)
        ToggleCell(title: "YUV 4:4:4", hintKey: "YUV444 detail", boolBinding: $settingsModel.enableYUV444)
        ToggleCell(title: "10-bit SDR", hintKey: "10-bit SDR detail", boolBinding: $settingsModel.enable10BitSdr)


        SettingsRow(title: "Transfer Function") {
          Picker("", selection: $settingsModel.selectedHdrTransferFunction) {
            ForEach(SettingsModel.hdrTransferFunctions, id: \.self) { value in
              Text(languageManager.localize(value)).tag(value)
            }
          }
          .labelsHidden()
          .frame(width: 190, alignment: .trailing)
        }
      }

      if metalSelected {
      FormSection(title: "Quality Enhancement") {
        SettingsRow(title: "Upscaling") {
          Picker("", selection: $settingsModel.selectedUpscalingMode) {
            ForEach(SettingsModel.upscalingModes, id: \.self) { value in
              Text(languageManager.localize(value)).tag(value)
            }
          }
          .labelsHidden()
          .frame(width: 230, alignment: .trailing)
        }


        if settingsModel.videoCapabilityMatrix.items.contains(where: { $0.id == "enhancement.vtLowLatencyFI" && $0.availability == .available }) {
        SettingsRow(title: "Frame Interpolation") {
          Picker("", selection: $settingsModel.selectedFrameInterpolationMode) {
            ForEach(SettingsModel.frameInterpolationModes, id: \.self) { value in
              Text(languageManager.localize(value)).tag(value)
            }
          }
          .labelsHidden()
          .frame(width: 230, alignment: .trailing)
        }
        }
      }

      FormSection(title: "HDR Display Profile") {
        SettingsRow(title: "Metadata Source") {
          Picker("", selection: $settingsModel.selectedHdrMetadataSource) {
            ForEach(SettingsModel.hdrMetadataSources, id: \.self) { value in
              Text(languageManager.localize(value)).tag(value)
            }
          }
          .labelsHidden()
          .frame(width: 190, alignment: .trailing)
        }


        SettingsRow(title: "Client Display Profile") {
          Picker("", selection: $settingsModel.selectedHdrClientDisplayProfile) {
            ForEach(SettingsModel.hdrClientDisplayProfiles, id: \.self) { value in
              Text(languageManager.localize(value)).tag(value)
            }
          }
          .labelsHidden()
          .frame(width: 190, alignment: .trailing)
        }


        SettingsRow(title: "EDR Strategy") {
          Picker("", selection: $settingsModel.selectedHdrEdrStrategy) {
            ForEach(SettingsModel.hdrEdrStrategies, id: \.self) { value in
              Text(languageManager.localize(value)).tag(value)
            }
          }
          .labelsHidden()
          .frame(width: 190, alignment: .trailing)
        }


        SettingsRow(title: "Tone Mapping") {
          Picker("", selection: $settingsModel.selectedHdrToneMappingPolicy) {
            ForEach(SettingsModel.hdrToneMappingPolicies, id: \.self) { value in
              Text(languageManager.localize(value)).tag(value)
            }
          }
          .labelsHidden()
          .frame(width: 230, alignment: .trailing)
        }

        SettingsStatusRow(
          title: "Display Capability",
          value: settingsModel.videoCapabilityMatrix.displayName.isEmpty
            ? languageManager.localize("Unknown") : settingsModel.videoCapabilityMatrix.displayName,
          tint: .secondary
        )
      }
      }

      FormSection(title: "HDR Capabilities") {
        ForEach(settingsModel.videoCapabilityMatrix.items.filter {
          $0.id.hasPrefix("display.")
        }) { capability in
          HDRCapabilityRow(capability: capability)
        }
      }

      CompactVideoCapabilitySection(title: "Decoding", items: settingsModel.videoCapabilityMatrix.items.filter { $0.id.hasPrefix("decode.") })
      if metalSelected {
        CompactVideoCapabilitySection(title: "Quality Enhancement", items: settingsModel.videoCapabilityMatrix.items.filter { $0.id.hasPrefix("enhancement.") })
        VideoAdvancedSettingsSection()
      }

      FormSection(title: "Frame Pacing") {
        SettingsRow(title: "Pacing") {
          Picker("", selection: $settingsModel.selectedPacingOptions) {
            ForEach(SettingsModel.pacingOptions, id: \.self) { value in
              Text(languageManager.localize(value)).tag(value)
            }
          }
          .labelsHidden()
          .frame(width: 210, alignment: .trailing)
        }

        SettingsRow(title: "Smoothness / Latency") {
          Picker("", selection: $settingsModel.selectedSmoothnessLatencyMode) {
            ForEach(SettingsModel.smoothnessLatencyModes, id: \.self) { value in
              Text(languageManager.localize(value)).tag(value)
            }
          }
          .labelsHidden()
          .frame(width: 220, alignment: .trailing)
        }

        if settingsModel.selectedSmoothnessLatencyMode == SettingsModel.smoothnessLatencyCustom {
          VideoCustomTimingSection()
        }
        ToggleCell(title: "Compatibility Mode", boolBinding: $settingsModel.timingCompatibilityMode)
        ToggleCell(title: "SDR Compatibility Workaround", boolBinding: $settingsModel.timingSdrCompatibilityWorkaround)
        SettingsStatusRow(title: "Runtime", value: languageManager.localize(settingsModel.videoRuntimeStatusSummaryKey), tint: .secondary)
      }
    }
  }
}

private struct HDRCapabilityRow: View {
  let capability: VideoCapabilityItem
  @ObservedObject private var languageManager = LanguageManager.shared

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: capability.availability.systemImage)
        .foregroundStyle(capability.availability.tint)
        .frame(width: 18)
      Text(languageManager.localize(capability.titleKey))
      Spacer(minLength: 12)
      Text(languageManager.localize(capability.availability.localizationKey))
        .foregroundStyle(capability.availability.tint)
        .font(.callout)
    }
    .frame(minHeight: 36)
    .overlay(alignment: .bottom) {
      Divider().opacity(0.45)
    }
  }
}


private struct CompactVideoCapabilitySection: View {
  let title: String
  let items: [VideoCapabilityItem]
  var body: some View {
    FormSection(title: title) {
      ForEach(items) { item in HDRCapabilityRow(capability: item) }
    }
  }
}

private struct VideoAdvancedSettingsSection: View {
  @EnvironmentObject private var settingsModel: SettingsModel
  private var metal: Bool {
    SettingsModel.normalizedVideoRendererMode(settingsModel.selectedVideoRendererMode) == "Metal Renderer"
  }
  var body: some View {
    FormSection(title: "Advanced Video Settings") {
      if metal {
        if settingsModel.selectedHdrClientDisplayProfile == "Manual" && settingsModel.selectedHdrMetadataSource != "Host" {
          SettingsDecimalRow(title: "Max Brightness", value: $settingsModel.hdrManualMaxBrightness)
          SettingsDecimalRow(title: "Min Brightness", value: $settingsModel.hdrManualMinBrightness)
          SettingsDecimalRow(title: "Max Average Brightness", value: $settingsModel.hdrManualMaxAverageBrightness)
        }
        SettingsValueSliderRow(title: "Optical Output Scale", value: $settingsModel.hdrOpticalOutputScale,
          range: 50...200, step: 1, suffix: "%")
        SettingsChoiceRow(title: "HLG Viewing Environment", selection: $settingsModel.selectedHdrHlgViewingEnvironment,
          options: SettingsModel.hdrHlgViewingEnvironments)
        SettingsChoiceRow(title: "Display Sync", selection: $settingsModel.selectedDisplaySyncMode, options: SettingsModel.displaySyncModes)
        SettingsChoiceRow(title: "Allow Drawable Timeout", selection: $settingsModel.selectedAllowDrawableTimeoutMode,
          options: SettingsModel.allowDrawableTimeoutModes)
      } else {
        Text("Metal tuning is available with the Metal renderer.").font(.footnote).foregroundStyle(.secondary)
      }
    }
  }
}

private struct VideoCustomTimingSection: View {
  @EnvironmentObject private var settingsModel: SettingsModel
  var body: some View {
    ToggleCell(title: "VSync", boolBinding: $settingsModel.enableVsync)
    SettingsChoiceRow(title: "Buffer Level", selection: $settingsModel.selectedTimingBufferLevel, options: SettingsModel.timingBufferLevels)
    ToggleCell(title: "Prioritize Responsiveness", boolBinding: $settingsModel.timingPrioritizeResponsiveness)
    SettingsChoiceRow(title: "Frame Queue Target", selection: $settingsModel.selectedFrameQueueTarget, options: SettingsModel.frameQueueTargets)
    SettingsChoiceRow(title: "Responsiveness Bias", selection: $settingsModel.selectedResponsivenessBias, options: SettingsModel.responsivenessBiasModes)
  }
}
