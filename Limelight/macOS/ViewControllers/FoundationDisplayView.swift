import AppKit
import SwiftUI

/// Foundation display topology and client HDR display profile settings.
///
/// Keeping this in its own page prevents host display lifecycle controls from
/// being mixed into stream bitrate and resolution choices.
struct FoundationDisplayView: View {
  @EnvironmentObject private var settingsModel: SettingsModel
  @ObservedObject private var languageManager = LanguageManager.shared

  private static let brightnessFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.minimumFractionDigits = 0
    formatter.maximumFractionDigits = 3
    formatter.minimum = 0
    return formatter
  }()

  private static let minimumBrightnessFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.minimumFractionDigits = 0
    formatter.maximumFractionDigits = 6
    formatter.minimum = 0
    return formatter
  }()

  var body: some View {
    ScrollView {
    LazyVStack(alignment: .leading, spacing: 28) {
        topologySection
        hdrDisplayProfileSection
      }
      .padding()
    }
  }

  private var topologySection: some View {
    SystemSettingsGroup(title: "Host Display") {
      SettingDescriptionRow(textKey: "Sunshine Foundation section detail")

      Divider()

      FormCell(title: "Display Capability", contentWidth: 0) {
        HStack(spacing: 8) {
          Image(systemName: settingsModel.sunshineDisplayCapabilityState.systemImage)
            .foregroundStyle(settingsModel.sunshineDisplayCapabilityState.tint)
          Text(languageManager.localize(settingsModel.sunshineDisplayCapabilityState.titleKey))
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
      }

      Text(settingsModel.sunshineDisplayCapabilityMessage)
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .trailing)

      FormCell(title: "VDD Capability", contentWidth: 0) {
        HStack(spacing: 8) {
          Image(systemName: settingsModel.sunshineVddState == .ready
            ? "checkmark.circle.fill" : "display")
            .foregroundStyle(settingsModel.sunshineVddState.tint)
          Text(languageManager.localize(settingsModel.sunshineVddState.titleKey))
            .foregroundStyle(.secondary)
          if let version = settingsModel.sunshineVddCapabilityVersion {
            Text("v\(version)")
              .foregroundStyle(.tertiary)
          }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
      }

      if settingsModel.sunshineVddCapabilityVersion == 0 {
        Text(languageManager.localize(
          "VDD unavailable on this host; virtual display selection is disabled."))
          .font(.footnote)
          .foregroundStyle(.orange)
          .frame(maxWidth: .infinity, alignment: .trailing)
      }

      FormCell(title: "Display Runtime", contentWidth: 0) {
        Text(languageManager.localize(settingsModel.sunshineDisplayRuntimeStateKey))
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .trailing)
      }

      if !settingsModel.sunshineDisplayRuntimeDetail.isEmpty {
        Text(settingsModel.sunshineDisplayRuntimeDetail)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .trailing)
      }

      if !settingsModel.availableSunshineDisplays.isEmpty {
        Text(
          settingsModel.availableSunshineDisplays
            .map { option in
              var label = "\(option.index + 1). \(option.title)"
              if option.isPrimary {
                label += " · " + languageManager.localize("Primary")
              }
              if let scale = option.currentScalePercent {
                label += " · \(scale)%"
              }
              return label
            }
            .joined(separator: "  ·  ")
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .frame(maxWidth: .infinity, alignment: .trailing)
      }

      Divider()

      FormCell(title: "Target Display", contentWidth: 220) {
        HStack(spacing: 8) {
          Picker("", selection: $settingsModel.sunshineTargetDisplayName) {
            ForEach(settingsModel.sunshineDisplayPickerOptions) { option in
              Text(option.title).tag(option.value)
            }
          }
          .labelsHidden()
          .frame(maxWidth: .infinity, alignment: .trailing)

          if settingsModel.isLoadingSunshineDisplays {
            ProgressView().controlSize(.small)
          } else {
            Button {
              settingsModel.refreshSunshineDisplays(force: true)
            } label: {
              Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
          }
        }
      }

      SettingDescriptionRow(textKey: "Target Display detail")

      Divider()

      ToggleCell(
        title: "Use Virtual Display",
        boolBinding: $settingsModel.sunshineUseVirtualDisplay
      )
      .disabled(!settingsModel.sunshineVddSupportsSelection)

      SettingDescriptionRow(textKey: "Use Virtual Display detail")

      Divider()

      FormCell(title: "Screen Mode", contentWidth: 220) {
        Picker("", selection: $settingsModel.selectedSunshineScreenMode) {
          ForEach(SettingsModel.sunshineScreenModes, id: \.self) { mode in
            Text(languageManager.localize(mode))
          }
        }
        .labelsHidden()
        .frame(maxWidth: .infinity, alignment: .trailing)
      }

      SettingDescriptionRow(textKey: "Screen Mode detail")
    }
  }

  private var hdrDisplayProfileSection: some View {
    SystemSettingsGroup(title: "HDR Display Profile") {
      ToggleCell(
        title: "Override HDR Display Profile",
        boolBinding: $settingsModel.sunshineHdrBrightnessOverride
      )
      SettingDescriptionRow(textKey: "Override HDR Display Profile detail")

      if settingsModel.sunshineHdrBrightnessOverride {
        Divider()

        FormCell(title: "Max Brightness", contentWidth: 140) {
          TextField(
            "1000",
            value: $settingsModel.sunshineMaxBrightness,
            formatter: Self.brightnessFormatter
          )
          .multilineTextAlignment(.trailing)
          .textFieldStyle(.roundedBorder)
          .frame(width: 120)
        }

        FormCell(title: "Min Brightness", contentWidth: 140) {
          TextField(
            "0.001",
            value: $settingsModel.sunshineMinBrightness,
            formatter: Self.minimumBrightnessFormatter
          )
          .multilineTextAlignment(.trailing)
          .textFieldStyle(.roundedBorder)
          .frame(width: 120)
        }

        Divider()

        FormCell(title: "Max Average Brightness", contentWidth: 180) {
          TextField(
            "1000",
            value: $settingsModel.sunshineMaxAverageBrightness,
            formatter: Self.brightnessFormatter
          )
          .multilineTextAlignment(.trailing)
          .textFieldStyle(.roundedBorder)
          .frame(width: 120)
        }
      }

      Divider()

      ToggleCell(
        title: "Show Touch Keyboard Automatically",
        boolBinding: $settingsModel.sunshineTouchKeyboardAutoInvoke
      )
      SettingDescriptionRow(textKey: "Show Touch Keyboard Automatically detail")
    }
  }
}
