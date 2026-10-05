import Foundation

@MainActor
final class RemoteFileMappingViewModel: ObservableObject {
  @Published private(set) var mappings: [RemoteFileMapping] = []
  @Published private(set) var entries: [RemoteFileEntry] = []
  @Published private(set) var status = "Idle"
  @Published private(set) var currentPath = ""
  @Published private(set) var preview = ""
  @Published private(set) var selectedMappingID: String?

  private let client = RemoteFileMappingClient()

  func refresh(host: Host?) {
    client.disconnect()
    mappings = []
    entries = []
    preview = ""
    currentPath = ""
    selectedMappingID = nil

    guard let host, host.id != SettingsModel.globalHostId,
      let temporaryHosts = DataManager().getHosts() as? [TemporaryHost],
      let temporaryHost = temporaryHosts.first(where: { $0.uuid == host.id }),
      let address = temporaryHost.activeAddress ?? temporaryHost.localAddress
        ?? temporaryHost.address ?? temporaryHost.externalAddress,
      !address.isEmpty,
      let certificate = temporaryHost.serverCert
    else {
      status = "Select a paired host"
      return
    }

    status = "Checking file mapping…"
    guard let http = HttpManager(host: address, uniqueId: IdManager.getUniqueId(), serverCert: certificate) else {
      status = "Unable to create the host connection"
      return
    }
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let capability = http.fetchSunshineFileMappingCapability() else {
        DispatchQueue.main.async { [weak self] in
          self?.status = "Invalid file mapping capability response"
        }
        return
      }
      guard let self else { return }
      DispatchQueue.main.async {
        guard (capability["ok"] as? NSNumber)?.boolValue == true else {
          self.status = (capability["reason"] as? String)
            ?? (capability["statusMessage"] as? String)
            ?? "File mapping is unavailable"
          return
        }
        self.status = "Connecting…"
        self.client.connect(host: address, capability: capability, serverCertificate: certificate) { [weak self] result in
          DispatchQueue.main.async {
            guard let self else { return }
            switch result {
            case .failure(let error):
              self.status = error.localizedDescription
            case .success(let mappings):
              self.mappings = mappings
              self.status = mappings.isEmpty ? "No shared folders" : "Ready"
              if let first = mappings.first {
                self.select(mapping: first)
              }
            }
          }
        }
      }
    }
  }

  func select(mapping: RemoteFileMapping) {
    selectedMappingID = mapping.id
    currentPath = ""
    preview = ""
    list(path: "")
  }

  func open(entry: RemoteFileEntry) {
    guard let mappingID = selectedMappingID else { return }
    if entry.isDirectory {
      currentPath = entry.path
      preview = ""
      list(path: entry.path)
      return
    }
    status = "Reading \(entry.name)…"
    client.read(mappingID: mappingID, path: entry.path, length: 256 * 1024) { [weak self] result in
      DispatchQueue.main.async {
        guard let self else { return }
        switch result {
        case .failure(let error):
          self.status = error.localizedDescription
        case .success(let data):
          if let text = String(data: data, encoding: .utf8) {
            self.preview = text
          } else {
            self.preview = "\(data.count) bytes"
          }
          self.status = "Ready"
        }
      }
    }
  }

  func goUp() {
    guard !currentPath.isEmpty else { return }
    currentPath = currentPath.split(separator: "/").dropLast().joined(separator: "/")
    list(path: currentPath)
  }

  func disconnect() {
    client.disconnect()
    status = "Idle"
    mappings = []
    entries = []
    preview = ""
  }

  private func list(path: String) {
    guard let mappingID = selectedMappingID else { return }
    status = "Loading…"
    client.list(mappingID: mappingID, path: path) { [weak self] result in
      DispatchQueue.main.async {
        guard let self else { return }
        switch result {
        case .failure(let error):
          self.status = error.localizedDescription
        case .success(let entries):
          self.entries = entries
          self.status = "Ready"
        }
      }
    }
  }

  deinit {
    client.disconnect()
  }
}
