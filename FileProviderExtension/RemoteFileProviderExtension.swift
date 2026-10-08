import FileProvider
import Foundation
import Security
import UniformTypeIdentifiers

private let remoteRoot = NSFileProviderItemIdentifier.rootContainer

private struct ProviderEntry {
  let name: String
  let path: String
  let isDirectory: Bool
  let size: UInt64
  let modifiedAt: Date?
}

private final class RemoteProviderItem: NSObject, NSFileProviderItem {
  let itemIdentifier: NSFileProviderItemIdentifier
  let parentItemIdentifier: NSFileProviderItemIdentifier
  let filename: String
  let contentType: UTType
  let capabilities: NSFileProviderItemCapabilities
  let documentSize: NSNumber?
  let contentModificationDate: Date?
  let childItemCount: NSNumber?
  let itemVersion: NSFileProviderItemVersion

  init(
    identifier: NSFileProviderItemIdentifier,
    parent: NSFileProviderItemIdentifier,
    name: String,
    isDirectory: Bool,
    size: UInt64 = 0,
    modifiedAt: Date? = nil
  ) {
    itemIdentifier = identifier
    parentItemIdentifier = parent
    filename = name
    contentType = isDirectory ? .folder : .data
    capabilities = isDirectory
      ? [.allowsContentEnumerating, .allowsReading, .allowsEvicting]
      : [.allowsReading, .allowsEvicting]
    documentSize = isDirectory ? nil : NSNumber(value: size)
    contentModificationDate = modifiedAt
    childItemCount = isDirectory ? nil : 0
    let version = Data(identifier.rawValue.utf8)
    itemVersion = NSFileProviderItemVersion(contentVersion: version, metadataVersion: version)
    super.init()
  }

}

private final class ProviderRPC: NSObject, URLSessionDelegate {
  private let state: FileProviderSharedState
  private let capability: [String: Any]
  private let identity: SecIdentity?
  private var session: URLSession?
  private var socket: URLSessionWebSocketTask?
  private var receiveStarted = false
  private var nextRequestID = 1
  private var pending: [Int: (Result<[String: Any], Error>) -> Void] = [:]
  private var ready: ((Result<Void, Error>) -> Void)?
  private var helloMessage: [String: Any]?

  init?(state: FileProviderSharedState) {
    self.state = state
    guard
      let object = try? JSONSerialization.jsonObject(with: state.capability) as? [String: Any],
      let p12 = SecPKCS12ImportIdentity(state.clientIdentity)
    else { return nil }
    capability = object
    identity = p12
    super.init()
  }

  func connect(completion: @escaping (Result<Void, Error>) -> Void) {
    if socket != nil {
      completion(.success(()))
      return
    }
    guard let url = sessionURL() else {
      completion(.failure(ProviderError.unavailable))
      return
    }
    ready = completion
    let configuration = URLSessionConfiguration.ephemeral
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    socket = session?.webSocketTask(with: url)
    socket?.resume()
    receiveNext()
    send([
      "type": "hello",
      "version": 1,
      "endpoint": "client",
      "client_uuid": capability["client_uuid"] as? String ?? "",
      "mappings": [],
    ])
  }

  func hello(completion: @escaping (Result<[[String: Any]], Error>) -> Void) {
    connect { [weak self] result in
      switch result {
      case .failure(let error): completion(.failure(error))
      case .success:
        completion(.success(self?.helloMessage?["mappings"] as? [[String: Any]] ?? []))
      }
    }
  }

  func list(mapping: String, path: String, completion: @escaping (Result<[ProviderEntry], Error>) -> Void) {
    connect { [weak self] result in
      switch result {
      case .failure(let error): completion(.failure(error))
      case .success:
        self?.sendRequest(["type": "list", "mapping": mapping, "path": Self.clean(path)]) { result in
          switch result {
          case .failure(let error): completion(.failure(error))
          case .success(let message):
            let entries = (message["entries"] as? [[String: Any]] ?? []).compactMap { raw -> ProviderEntry? in
              guard let name = raw["name"] as? String, !name.isEmpty else { return nil }
              return ProviderEntry(
                name: name,
                path: Self.clean(path).isEmpty ? name : Self.clean(path) + "/" + name,
                isDirectory: raw["kind"] as? String == "directory",
                size: (raw["size"] as? NSNumber)?.uint64Value ?? 0,
                modifiedAt: (raw["mtime"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) })
            }
            completion(.success(entries))
          }
        }
      }
    }
  }

  func read(mapping: String, path: String, offset: UInt64, length: UInt32,
            completion: @escaping (Result<Data, Error>) -> Void) {
    connect { [weak self] result in
      switch result {
      case .failure(let error): completion(.failure(error))
      case .success:
        self?.sendRequest([
          "type": "read", "mapping": mapping, "path": Self.clean(path),
          "offset": offset, "length": min(length, 4 * 1024 * 1024),
        ]) { result in
          switch result {
          case .failure(let error): completion(.failure(error))
          case .success(let message):
            guard let encoded = message["data"] as? String,
              let data = Data(base64Encoded: encoded) else {
              completion(.failure(ProviderError.invalidResponse))
              return
            }
            completion(.success(data))
          }
        }
      }
    }
  }

  private func sendRequest(_ payload: [String: Any], completion: @escaping (Result<[String: Any], Error>) -> Void) {
    var payload = payload
    let id = nextRequestID
    nextRequestID += 1
    payload["id"] = id
    pending[id] = completion
    send(payload)
  }

  private func send(_ payload: [String: Any]) {
    guard let socket,
      JSONSerialization.isValidJSONObject(payload),
      let data = try? JSONSerialization.data(withJSONObject: payload),
      let text = String(data: data, encoding: .utf8) else { return }
    socket.send(.string(text)) { [weak self] error in
      guard let error, let self else { return }
      let callbacks = self.pending.values
      self.pending.removeAll()
      callbacks.forEach { $0(.failure(error)) }
    }
  }

  private func receiveNext() {
    guard let socket else { return }
    receiveStarted = true
    socket.receive { [weak self] result in
      guard let self else { return }
      switch result {
      case .failure(let error):
        self.ready?(.failure(error))
        self.ready = nil
      case .success(let message):
        if case .string(let text) = message,
          let data = text.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
          if object["type"] as? String == "hello" {
            self.helloMessage = object
            self.ready?(.success(()))
            self.ready = nil
          }
          if let id = (object["id"] as? NSNumber)?.intValue,
            let callback = self.pending.removeValue(forKey: id) {
            if object["type"] as? String == "error" {
              callback(.failure(ProviderError.server(object["message"] as? String ?? "Remote request failed")))
            } else {
              callback(.success(object))
            }
          }
        }
        self.receiveNext()
      }
    }
  }

  private func sessionURL() -> URL? {
    if let raw = capability["session_url"] as? String,
      !raw.isEmpty,
      let url = URL(string: raw), url.scheme?.lowercased() == "wss" {
      return url
    }
    guard let port = (capability["port"] as? NSNumber)?.intValue,
      let endpoint = capability["session_endpoint"] as? String,
      let token = capability["session_token"] as? String,
      !endpoint.isEmpty, !token.isEmpty else { return nil }
    var components = URLComponents()
    components.scheme = "wss"
    components.host = state.hostAddress.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    components.port = port
    components.path = endpoint.hasPrefix("/") ? endpoint : "/" + endpoint
    components.queryItems = [URLQueryItem(name: "token", value: token)]
    return components.url
  }

  func urlSession(_ session: URLSession, task: URLSessionTask,
                  didReceive challenge: URLAuthenticationChallenge,
                  completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
    switch challenge.protectionSpace.authenticationMethod {
    case NSURLAuthenticationMethodServerTrust:
      guard let trust = challenge.protectionSpace.serverTrust,
        let certificate = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
        SecCertificateCopyData(certificate) as Data? == state.serverCertificate else {
        completionHandler(.cancelAuthenticationChallenge, nil)
        return
      }
      completionHandler(.useCredential, URLCredential(trust: trust))
    case NSURLAuthenticationMethodClientCertificate:
      guard let identity else {
        completionHandler(.cancelAuthenticationChallenge, nil)
        return
      }
      var certificate: SecCertificate?
      SecIdentityCopyCertificate(identity, &certificate)
      completionHandler(.useCredential,
                        URLCredential(identity: identity,
                                      certificates: certificate.map { [$0] },
                                      persistence: .forSession))
    default:
      completionHandler(.cancelAuthenticationChallenge, nil)
    }
  }

  private static func clean(_ path: String) -> String {
    path.split(separator: "/").filter { $0 != "." && $0 != ".." }.joined(separator: "/")
  }
}

private enum ProviderError: LocalizedError {
  case unavailable
  case invalidResponse
  case server(String)

  var errorDescription: String? {
    switch self {
    case .unavailable: return "Remote file mapping is unavailable"
    case .invalidResponse: return "The remote file provider returned an invalid response"
    case .server(let message): return message
    }
  }
}

private func SecPKCS12ImportIdentity(_ data: Data) -> SecIdentity? {
  var items: CFArray?
  let options = [kSecImportExportPassphrase as String: "limelight"] as CFDictionary
  guard SecPKCS12Import(data as CFData, options, &items) == errSecSuccess,
    let array = items as? [[String: Any]],
    let rawIdentity = array.first?[kSecImportItemIdentity as String] else { return nil }
  return unsafeBitCast(rawIdentity, to: SecIdentity.self)
}

private final class RemoteProviderEnumerator: NSObject, NSFileProviderEnumerator {
  private let state: FileProviderSharedState
  private let containerIdentifier: NSFileProviderItemIdentifier

  init(state: FileProviderSharedState, containerIdentifier: NSFileProviderItemIdentifier) {
    self.state = state
    self.containerIdentifier = containerIdentifier
  }

  func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
    guard let rpc = ProviderRPC(state: state) else {
      observer.finishEnumeratingWithError(NSFileProviderError(.notAuthenticated))
      return
    }
    if containerIdentifier == remoteRoot {
      rpc.hello { result in
        switch result {
        case .failure:
          observer.finishEnumeratingWithError(NSFileProviderError(.serverUnreachable))
        case .success(let mappings):
          let items = mappings.compactMap { mapping -> RemoteProviderItem? in
            guard let id = mapping["id"] as? String, !id.isEmpty else { return nil }
            let name = mapping["name"] as? String ?? id
            return RemoteProviderItem(identifier: Self.identifier(mapping: id, path: nil),
                                      parent: remoteRoot, name: name, isDirectory: true)
          }
          observer.didEnumerate(items)
          observer.finishEnumerating(upTo: nil)
        }
      }
      return
    }
    guard let parsed = Self.parse(containerIdentifier) else {
      observer.finishEnumeratingWithError(NSFileProviderError(.noSuchItem))
      return
    }
    rpc.list(mapping: parsed.mapping, path: parsed.path) { result in
      switch result {
      case .failure:
        observer.finishEnumeratingWithError(NSFileProviderError(.serverUnreachable))
      case .success(let entries):
        let items = entries.map { entry in
          RemoteProviderItem(identifier: Self.identifier(mapping: parsed.mapping, path: entry.path),
                              parent: self.containerIdentifier, name: entry.name,
                              isDirectory: entry.isDirectory, size: entry.size,
                              modifiedAt: entry.modifiedAt)
        }
        observer.didEnumerate(items)
        observer.finishEnumerating(upTo: nil)
      }
    }
  }

  func enumerateChanges(for observer: NSFileProviderChangeObserver, from syncAnchor: NSFileProviderSyncAnchor) {
    observer.finishEnumeratingChanges(upTo: NSFileProviderSyncAnchor(rawValue: Data(Date().timeIntervalSince1970.description.utf8)),
                                      moreComing: false)
  }

  func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
    completionHandler(NSFileProviderSyncAnchor(rawValue: Data(Date().timeIntervalSince1970.description.utf8)))
  }

  func invalidate() {}

  static func identifier(mapping: String, path: String?) -> NSFileProviderItemIdentifier {
    NSFileProviderItemIdentifier("remote/" + mapping + (path.map { "/" + $0 } ?? ""))
  }

  static func parse(_ identifier: NSFileProviderItemIdentifier) -> (mapping: String, path: String)? {
    let raw = identifier.rawValue
    guard raw.hasPrefix("remote/") else { return nil }
    let tail = String(raw.dropFirst(7))
    guard let separator = tail.firstIndex(of: "/") else {
      return tail.isEmpty ? nil : (tail, "")
    }
    let mapping = String(tail[..<separator])
    let path = String(tail[tail.index(after: separator)...])
    return mapping.isEmpty ? nil : (mapping, path)
  }
}

final class RemoteFileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
  private let domain: NSFileProviderDomain
  private let state: FileProviderSharedState?

  required init(domain: NSFileProviderDomain) {
    self.domain = domain
    state = FileProviderSharedStateStore.read()
    super.init()
  }

  func invalidate() {}

  func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier,
                  request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
    guard let state else { throw NSFileProviderError(.notAuthenticated) }
    return RemoteProviderEnumerator(state: state, containerIdentifier: containerItemIdentifier)
  }

  func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
            completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
    if identifier == remoteRoot {
      completionHandler(RemoteProviderItem(identifier: remoteRoot, parent: remoteRoot,
                                            name: state?.hostName ?? "Remote Files", isDirectory: true), nil)
      return Progress()
    }
    guard let parsed = RemoteProviderEnumerator.parse(identifier) else {
      completionHandler(nil, NSFileProviderError(.noSuchItem))
      return Progress()
    }
    guard let state, let rpc = ProviderRPC(state: state) else {
      completionHandler(nil, NSFileProviderError(.notAuthenticated))
      return Progress()
    }
    if parsed.path.isEmpty {
      completionHandler(RemoteProviderItem(identifier: identifier, parent: remoteRoot,
                                            name: parsed.mapping, isDirectory: true), nil)
      return Progress()
    }
    let parentPath = parsed.path.split(separator: "/").dropLast().joined(separator: "/")
    let parent = RemoteProviderEnumerator.identifier(mapping: parsed.mapping,
                                                      path: parentPath.isEmpty ? nil : parentPath)
    let progress = Progress(totalUnitCount: 1)
    rpc.list(mapping: parsed.mapping, path: parentPath) { result in
      switch result {
      case .failure:
        completionHandler(nil, NSFileProviderError(.serverUnreachable))
      case .success(let entries):
        guard let entry = entries.first(where: { $0.path == parsed.path }) else {
          completionHandler(nil, NSFileProviderError(.noSuchItem))
          return
        }
        completionHandler(RemoteProviderItem(identifier: identifier, parent: parent,
                                             name: entry.name, isDirectory: entry.isDirectory,
                                             size: entry.size, modifiedAt: entry.modifiedAt), nil)
        progress.completedUnitCount = 1
      }
    }
    return progress
  }

  func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier,
                     version requestedVersion: NSFileProviderItemVersion?,
                     request: NSFileProviderRequest,
                     completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
    guard let state, let parsed = RemoteProviderEnumerator.parse(itemIdentifier) else {
      completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
      return Progress()
    }
    let progress = Progress(totalUnitCount: 1)
    guard let rpc = ProviderRPC(state: state) else {
      completionHandler(nil, nil, NSFileProviderError(.notAuthenticated))
      return progress
    }
    var data = Data()
    func readNext(offset: UInt64) {
      if progress.isCancelled {
        completionHandler(nil, nil, NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        return
      }
      rpc.read(mapping: parsed.mapping, path: parsed.path, offset: offset, length: 4 * 1024 * 1024) { result in
        switch result {
        case .failure:
          completionHandler(nil, nil, NSFileProviderError(.serverUnreachable))
        case .success(let chunk):
          data.append(chunk)
          if chunk.count < 4 * 1024 * 1024 {
            guard let manager = NSFileProviderManager(for: self.domain),
              let directory = try? manager.temporaryDirectoryURL() else {
              completionHandler(nil, nil, NSFileProviderError(.serverUnreachable))
              return
            }
            let url = directory.appendingPathComponent(UUID().uuidString)
            do {
              try data.write(to: url, options: .atomic)
              let name = parsed.path.split(separator: "/").last.map(String.init) ?? "Remote File"
              let item = RemoteProviderItem(identifier: itemIdentifier, parent: remoteRoot,
                                             name: name, isDirectory: false, size: UInt64(data.count))
              progress.completedUnitCount = 1
              completionHandler(url, item, nil)
            } catch {
              completionHandler(nil, nil, error)
            }
          } else {
            readNext(offset: offset + UInt64(chunk.count))
          }
        }
      }
    }
    readNext(offset: 0)
    return progress
  }

  func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields,
                  contents url: URL?, options: NSFileProviderCreateItemOptions = [],
                  request: NSFileProviderRequest,
                  completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
    completionHandler(nil, [], false, NSFileProviderError(.notAuthenticated))
    return Progress()
  }

  func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion,
                  changedFields: NSFileProviderItemFields, contents newContents: URL?,
                  options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest,
                  completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
    completionHandler(nil, [], false, NSFileProviderError(.notAuthenticated))
    return Progress()
  }

  func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
                  options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest,
                  completionHandler: @escaping (Error?) -> Void) -> Progress {
    completionHandler(NSFileProviderError(.notAuthenticated))
    return Progress()
  }

  func materializedItemsDidChange(completionHandler: @escaping () -> Void) { completionHandler() }
  func pendingItemsDidChange(completionHandler: @escaping () -> Void) { completionHandler() }
  func importDidFinish(completionHandler: @escaping () -> Void) { completionHandler() }
}
