import FileProvider
import Foundation

/// Installs a read-only File Provider domain after the Foundation capability
/// handshake succeeds. The application UI remains usable when an unsigned or
/// non-App-Group debug build cannot register the extension.
final class FileProviderCoordinator {
  static let shared = FileProviderCoordinator()

  private var installedDomainIDs = Set<String>()

  private init() {}

  enum CoordinatorError: LocalizedError {
    case invalidState
    case appGroupUnavailable
    case registration(Error)
    case userVisibleURL(Error)

    var errorDescription: String? {
      switch self {
      case .invalidState: return "The host file sharing state is invalid."
      case .appGroupUnavailable: return "Host Files requires an App Group enabled signed build."
      case .registration(let error), .userVisibleURL(let error): return error.localizedDescription
      }
    }
  }

  func register(
    hostIdentifier: String,
    hostName: String,
    hostAddress: String,
    serverCertificate: Data,
    capability: [String: Any],
    completion: @escaping (Result<URL, Error>) -> Void
  ) {
    guard JSONSerialization.isValidJSONObject(capability),
      let capabilityData = try? JSONSerialization.data(withJSONObject: capability),
      let clientIdentity = CryptoManager.readP12FromFile()
    else {
      completion(.failure(CoordinatorError.invalidState))
      return
    }

    let state = FileProviderSharedState(
      hostIdentifier: hostIdentifier,
      hostName: hostName,
      hostAddress: hostAddress,
      serverCertificate: serverCertificate,
      clientIdentity: clientIdentity,
      capability: capabilityData,
      updatedAt: Date())
    guard FileProviderSharedStateStore.write(state) else {
      completion(.failure(CoordinatorError.appGroupUnavailable))
      return
    }

    let identifier = domainIdentifier(for: hostIdentifier)
    let domain = NSFileProviderDomain(identifier: identifier, displayName: hostName)
    let finish: (Error?) -> Void = { [weak self] error in
      if let error {
        self?.installedDomainIDs.remove(identifier.rawValue)
        completion(.failure(CoordinatorError.registration(error)))
        return
      }
      guard let manager = NSFileProviderManager(for: domain) else {
        completion(.failure(CoordinatorError.registration(CoordinatorError.invalidState)))
        return
      }
      manager.getUserVisibleURL(for: .rootContainer) { url, error in
        if let error {
          completion(.failure(CoordinatorError.userVisibleURL(error)))
        } else if let url {
          completion(.success(url))
        } else {
          completion(.failure(CoordinatorError.userVisibleURL(CoordinatorError.invalidState)))
        }
      }
    }

    if installedDomainIDs.contains(identifier.rawValue) {
      finish(nil)
      return
    }
    installedDomainIDs.insert(identifier.rawValue)

    NSFileProviderManager.add(domain, completionHandler: finish)
  }

  private func domainIdentifier(for hostIdentifier: String) -> NSFileProviderDomainIdentifier {
    NSFileProviderDomainIdentifier(
      "remote-files." + hostIdentifier.replacingOccurrences(of: "[^A-Za-z0-9.-]", with: "-", options: .regularExpression))
  }
}
