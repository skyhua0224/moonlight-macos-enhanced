import SwiftUI

/// Host Files exposes the host's shared folders through the native Finder
/// surface. It is read-only and intentionally has no local-folder comparison
/// UI because the protocol does not synchronize or compare local files.
struct RemoteFileMappingView: View {
  @EnvironmentObject private var settingsModel: SettingsModel
  @ObservedObject private var languageManager = LanguageManager.shared
  @StateObject private var model = RemoteFileMappingViewModel()
  @Environment(\.openURL) private var openURL

  var body: some View {
    SettingsContent {
      SettingsPageHero(
        title: "Host Files",
        subtitle: "Host Files settings subtitle",
        symbol: "folder.badge.gearshape",
        tint: .teal)

      FormSection(title: "Host Files") {
        SettingsRow(title: "Host") {
          Picker("", selection: selectedHostBinding) {
            ForEach(SettingsModel.hosts ?? [], id: \.self) { host in
              if let host {
                Text(host.id == SettingsModel.globalHostId
                  ? languageManager.localize("Default Profile") : host.name)
                  .tag(Optional(host))
              }
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .frame(width: 220, alignment: .trailing)
        }

        SettingsRow(title: "Host Files Status", detail: "Host Files Status detail") {
          HStack(spacing: 8) {
            Circle()
              .fill(model.finderURL == nil ? Color.orange : Color.green)
              .frame(width: 8, height: 8)
            Text(languageManager.localize(model.status))
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }

        SettingsRow(title: "Open Host Files") {
          Button(languageManager.localize("Open in Finder")) {
            if let url = model.finderURL {
              openURL(url)
            }
          }
          .disabled(model.finderURL == nil)
        }

        SettingsRow(title: "Refresh") {
          Button(languageManager.localize("Refresh")) {
            model.refresh(host: settingsModel.selectedHost)
          }
        }
      }

      SettingDescriptionRow(textKey: "Host Files purpose detail")

      FormSection(title: "Access") {
        SettingsRow(title: "Access Mode") {
          Text(languageManager.localize("Read Only"))
            .foregroundStyle(.secondary)
        }
        SettingDescriptionRow(textKey: "Host Files read-only detail")
      }
    }
    .onAppear { model.refresh(host: settingsModel.selectedHost) }
    .onChange(of: settingsModel.selectedHost?.id) { _ in
      model.refresh(host: settingsModel.selectedHost)
    }
  }

  private var selectedHostBinding: Binding<Host?> {
    Binding(
      get: { settingsModel.selectedHost },
      set: { settingsModel.selectedHost = $0 })
  }
}
