import Foundation

@MainActor
final class RemoteFileMappingViewModel: ObservableObject {
  @Published private(set) var status = "Idle"
  @Published private(set) var finderURL: URL?

  func refresh(host: Host?) {
    finderURL = nil

    guard let host, host.id != SettingsModel.globalHostId,
      let temporaryHosts = DataManager().getHosts() as? [TemporaryHost],
      let temporaryHost = temporaryHosts.first(where: { $0.uuid == host.id }),
    let address = Self.reachableAddress(for: temporaryHost),
      !address.isEmpty,
      let certificate = temporaryHost.serverCert
    else {
      status = "Select a paired host"
      return
    }
    let hostIdentifier = temporaryHost.uuid
    let hostName = temporaryHost.name

    status = "Checking Host Files…"
    guard let http = HttpManager(host: address, uniqueId: IdManager.getUniqueId(), serverCert: certificate) else {
      status = "Unable to create the host connection"
      return
    }
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let capability = http.fetchSunshineFileMappingCapability() else {
        DispatchQueue.main.async { [weak self] in
            self?.status = "Invalid Host Files capability response"
        }
        return
      }
      guard let self else { return }
      DispatchQueue.main.async {
        guard (capability["ok"] as? NSNumber)?.boolValue == true else {
          self.status = (capability["reason"] as? String)
            ?? (capability["statusMessage"] as? String)
            ?? "Host Files is unavailable"
          return
        }
        FileProviderCoordinator.shared.register(
          hostIdentifier: hostIdentifier,
          hostName: hostName,
          hostAddress: address,
          serverCertificate: certificate,
          capability: capability) { [weak self] result in
          DispatchQueue.main.async {
            guard let self else { return }
            switch result {
            case .failure(let error):
              self.status = error.localizedDescription
            case .success(let url):
              self.finderURL = url
              self.status = "Host Files ready"
            }
          }
        }
      }
    }
  }

  func disconnect() {
    status = "Idle"
    finderURL = nil
  }

  private static func reachableAddress(for host: TemporaryHost) -> String? {
    let candidates = [host.activeAddress].compactMap { $0 }
      + ConnectionEndpointStore.allEndpoints(for: host)
    let states = host.addressStates ?? [:]
    return candidates.first(where: { states[$0]?.intValue == 1 })
      ?? candidates.first(where: { !$0.isEmpty })
  }
}
