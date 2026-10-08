import Foundation

@MainActor
final class RemoteUSBForwardingViewModel: ObservableObject {
  @Published private(set) var devices: [MLRemoteUSBDevice] = []
  @Published private(set) var status = "Idle"
  @Published private(set) var capabilityAvailable = false
  @Published private(set) var selectedBusID: String?

  private let session = MLRemoteUSBForwardingSession.shared()
  private var capability: [String: Any] = [:]
  private var hostAddress = ""
  private var serverCertificate: Data?

  func refresh(host: Host?) {
    stop()
    guard let host, host.id != SettingsModel.globalHostId,
      let temporaryHosts = DataManager().getHosts() as? [TemporaryHost],
      let temporaryHost = temporaryHosts.first(where: { $0.uuid == host.id }),
      let address = Self.reachableAddress(for: temporaryHost),
      !address.isEmpty,
      let certificate = temporaryHost.serverCert
    else {
      devices = []
      capabilityAvailable = false
      status = "Select a paired host"
      return
    }

    hostAddress = address
    serverCertificate = certificate
    status = "Checking Foundation USB forwarding…"
    guard let http = HttpManager(host: address, uniqueId: IdManager.getUniqueId(), serverCert: certificate) else {
      status = "Unable to create the host connection"
      return
    }
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let capability = http.fetchSunshineUSBForwardingCapability() ?? [:]
      self?.session.refreshDevices { [weak self] devices, error in
        guard let self else { return }
        self.devices = devices
        self.capability = capability
        self.capabilityAvailable = (capability["enabled"] as? NSNumber)?.boolValue == true
          && (capability["available"] as? NSNumber)?.boolValue == true
        if !self.capabilityAvailable {
          if (capability["statusCode"] as? NSNumber)?.intValue != 200 {
            self.status = "Unable to read Foundation USB forwarding capability"
          } else if (capability["enabled"] as? NSNumber)?.boolValue == false {
            self.status = "Enable USB forwarding in Foundation Sunshine on the host"
          } else {
            self.status = "Foundation Sunshine USB forwarding service is unavailable"
          }
        } else if let error {
          self.status = error.localizedDescription
        } else if devices.isEmpty {
          self.status = "No claimable USB devices"
        } else {
          self.status = "Ready"
        }
      }
    }
  }

  func start(device: MLRemoteUSBDevice) {
    guard capabilityAvailable,
      let port = (capability["port"] as? NSNumber)?.uint16Value,
      let token = capability["token"] as? String,
      let certificate = serverCertificate
    else {
      status = "Refresh Foundation USB forwarding capability first"
      return
    }

    selectedBusID = device.busID
    status = "Connecting USB/IP…"
    session.startForwarding(for: device,
                            host: hostAddress,
                            port: port,
                            token: token,
                            serverCert: certificate) { [weak self] error in
      guard let self else { return }
      if let error {
        self.status = error.localizedDescription
        self.selectedBusID = nil
      } else {
        let name = device.product.isEmpty ? device.busID : device.product
        self.status = "Forwarding \(name)"
      }
    }
  }

  func stop() {
    session.stop()
    selectedBusID = nil
    if status.hasPrefix("Forwarding") || status.hasPrefix("Connecting") {
      status = "Ready"
    }
  }

  deinit {
    session.stop()
  }

  private static func reachableAddress(for host: TemporaryHost) -> String? {
    let candidates = [host.activeAddress].compactMap { $0 }
      + ConnectionEndpointStore.allEndpoints(for: host)
    let states = host.addressStates ?? [:]
    return candidates.first(where: { states[$0]?.intValue == 1 })
      ?? candidates.first(where: { !$0.isEmpty })
  }
}
