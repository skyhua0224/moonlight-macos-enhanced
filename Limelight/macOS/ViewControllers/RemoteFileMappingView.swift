import SwiftUI

struct RemoteFileMappingView: View {
  @EnvironmentObject private var settingsModel: SettingsModel
  @StateObject private var model = RemoteFileMappingViewModel()

  var body: some View {
    FormSection(title: "File Mapping") {
      HStack {
        Image(systemName: "folder.badge.person.crop")
          .foregroundColor(.accentColor)
        Text(model.status)
          .foregroundColor(.secondary)
        Spacer()
        Button("Refresh") {
          model.refresh(host: settingsModel.selectedHost)
        }
        .buttonStyle(.bordered)
      }

      if !model.mappings.isEmpty {
        Picker("Shared folder", selection: Binding(
          get: { model.selectedMappingID ?? model.mappings[0].id },
          set: { id in
            if let mapping = model.mappings.first(where: { $0.id == id }) {
              model.select(mapping: mapping)
            }
          })) {
          ForEach(model.mappings) { mapping in
            Text(mapping.name).tag(mapping.id)
          }
        }

        HStack {
          Button(action: model.goUp) {
            Label("Up", systemImage: "arrow.up")
          }
          .buttonStyle(.bordered)
          .disabled(model.currentPath.isEmpty)
          Text(model.currentPath.isEmpty ? "/" : model.currentPath)
            .font(.footnote)
            .foregroundColor(.secondary)
          Spacer()
        }

        ForEach(model.entries) { entry in
          Button {
            model.open(entry: entry)
          } label: {
            HStack {
              Image(systemName: entry.isDirectory ? "folder" : "doc")
              Text(entry.name)
              Spacer()
              if !entry.isDirectory {
                Text(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))
                  .font(.caption)
                  .foregroundColor(.secondary)
              }
            }
          }
          .buttonStyle(.plain)
        }

        if !model.preview.isEmpty {
          Divider()
          ScrollView {
            Text(model.preview)
              .font(.system(.body, design: .monospaced))
              .frame(maxWidth: .infinity, alignment: .leading)
              .textSelection(.enabled)
          }
          .frame(minHeight: 100, maxHeight: 220)
        }
      } else {
        Text("Foundation must expose a read-only mapping before files can be browsed.")
          .font(.footnote)
          .foregroundColor(.secondary)
      }
    }
    .onAppear {
      model.refresh(host: settingsModel.selectedHost)
    }
  }
}
