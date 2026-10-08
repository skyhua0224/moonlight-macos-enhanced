import AppKit
import SwiftUI

struct FoundationDisplayView: View {
  @EnvironmentObject private var settingsModel: SettingsModel
  @ObservedObject private var languageManager = LanguageManager.shared

  private static let numberFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.minimum = 0
    formatter.maximumFractionDigits = 3
    return formatter
  }()

  var body: some View {
    SettingsContent {
      SettingsPageHero(
        title: "Display & HDR",
        subtitle: "Display settings subtitle",
        symbol: "display.2",
        tint: .orange
      )

      FormSection(title: "Host Display") {
        SettingsRow(title: "Display Capability", detail: settingsModel.sunshineDisplayCapabilityMessage) {
          HStack(spacing: 7) {
            Circle()
              .fill(settingsModel.sunshineDisplayCapabilityState.tint)
              .frame(width: 8, height: 8)
            Text(languageManager.localize(settingsModel.sunshineDisplayCapabilityState.titleKey))
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }

        SettingsRow(title: "VDD Capability", detail: settingsModel.sunshineVddCapabilityVersion.map { "Version \($0)" } ?? "") {
          HStack(spacing: 7) {
            Circle()
              .fill(settingsModel.sunshineVddState.tint)
              .frame(width: 8, height: 8)
            Text(languageManager.localize(settingsModel.sunshineVddState.titleKey))
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }

        SettingsRow(title: "Target Display") {
          HStack(spacing: 8) {
            Picker("", selection: $settingsModel.sunshineTargetDisplayName) {
              ForEach(settingsModel.sunshineDisplayPickerOptions) { option in
                Text(option.title).tag(option.value)
              }
            }
            .labelsHidden()
            .frame(width: 230, alignment: .trailing)
            if settingsModel.isLoadingSunshineDisplays {
              ProgressView().controlSize(.small)
            } else {
              Button { settingsModel.refreshSunshineDisplays(force: true) } label: {
                Image(systemName: "arrow.clockwise")
              }
              .buttonStyle(.plain)
              .help(languageManager.localize("Refresh"))
            }
          }
        }

        ToggleCell(title: "Use Virtual Display", hintKey: "Use Virtual Display detail", boolBinding: $settingsModel.sunshineUseVirtualDisplay)
          .disabled(!settingsModel.sunshineVddSupportsSelection)

        SettingsRow(title: "Screen Mode") {
          Picker("", selection: $settingsModel.selectedSunshineScreenMode) {
            ForEach(SettingsModel.sunshineScreenModes, id: \.self) { value in
              Text(languageManager.localize(value)).tag(value)
            }
          }
          .labelsHidden()
          .frame(width: 220, alignment: .trailing)
        }
      }

      FormSection(title: "HDR Display Profile") {
        ToggleCell(title: "Override HDR Display Profile", boolBinding: $settingsModel.sunshineHdrBrightnessOverride)

        if settingsModel.sunshineHdrBrightnessOverride {
          SettingsRow(title: "Maximum Brightness") {
            TextField("1000", value: $settingsModel.sunshineMaxBrightness, formatter: Self.numberFormatter)
              .multilineTextAlignment(.trailing)
              .frame(width: 120)
          }
          SettingsRow(title: "Minimum Brightness") {
            TextField("0.001", value: $settingsModel.sunshineMinBrightness, formatter: Self.numberFormatter)
              .multilineTextAlignment(.trailing)
              .frame(width: 120)
          }
          SettingsRow(title: "Maximum Average Brightness") {
            TextField("1000", value: $settingsModel.sunshineMaxAverageBrightness, formatter: Self.numberFormatter)
              .multilineTextAlignment(.trailing)
              .frame(width: 120)
          }
        }

        SettingsRow(title: "HDR Metadata Source") {
          Picker("", selection: $settingsModel.selectedHdrMetadataSource) {
            ForEach(SettingsModel.hdrMetadataSources, id: \.self) { value in
              Text(languageManager.localize(value)).tag(value)
            }
          }
          .labelsHidden()
          .frame(width: 210, alignment: .trailing)
        }

        SettingsRow(title: "Client Display Profile") {
          Picker("", selection: $settingsModel.selectedHdrClientDisplayProfile) {
            ForEach(SettingsModel.hdrClientDisplayProfiles, id: \.self) { value in
              Text(languageManager.localize(value)).tag(value)
            }
          }
          .labelsHidden()
          .frame(width: 210, alignment: .trailing)
        }

        ToggleCell(title: "Show Touch Keyboard Automatically", boolBinding: $settingsModel.sunshineTouchKeyboardAutoInvoke)
      }
    }
    .onAppear {
      settingsModel.refreshSunshineDisplays(force: false)
    }
  }
}
