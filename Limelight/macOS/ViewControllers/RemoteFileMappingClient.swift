import Foundation
import Security

struct RemoteFileMapping: Identifiable, Equatable {
  let id: String
  let name: String
  let side: String
  let mode: String
}

struct RemoteFileEntry: Identifiable, Equatable {
  let id: String
  let name: String
  let path: String
  let isDirectory: Bool
  let size: UInt64
  let modifiedAt: Date?
}

enum RemoteFileMappingError: LocalizedError {
  case unavailable(String)
  case protocolError(String)
  case serverError(String)
  case invalidResponse

  var errorDescription: String? {
    switch self {
    case .unavailable(let message), .protocolError(let message), .serverError(let message):
      return message
    case .invalidResponse:
      return "Invalid file mapping response"
    }
  }
}

/// Read-only Foundation file-mapping RPC client.
///
/// The client keeps the session token in memory, pins the paired host
/// certificate, and accepts only mapping IDs plus relative paths. It does not
/// expose absolute host paths or enable write/delete/execute operations.
final class RemoteFileMappingClient: NSObject, URLSessionDelegate {
  private var session: URLSession?
  private var socket: URLSessionWebSocketTask?
  private var identity: SecIdentity?
  private var serverCertificate: Data?
  private var nextRequestID = 1
  private var pending: [Int: (Result<[String: Any], Error>) -> Void] = [:]
  private var receiveStarted = false

  private(set) var mappings: [RemoteFileMapping] = []

  func connect(
    host: String,
    capability: [String: Any],
    serverCertificate: Data,
    completion: @escaping (Result<[RemoteFileMapping], Error>) -> Void
  ) {
    disconnect()
    guard
      (capability["ok"] as? NSNumber)?.boolValue == true,
      (capability["enabled"] as? NSNumber)?.boolValue == true,
      let rawURL = capability["session_url"] as? String,
      let url = URL(string: rawURL),
      url.scheme?.lowercased() == "wss",
      url.host?.isEmpty == false,
      let p12 = CryptoManager.readP12FromFile(),
      let identity = Self.loadIdentity(from: p12)
    else {
      completion(.failure(RemoteFileMappingError.unavailable("File mapping capability is unavailable")))
      return
    }

    self.serverCertificate = serverCertificate
    self.identity = identity
    let configuration = URLSessionConfiguration.ephemeral
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    socket = session?.webSocketTask(with: url)
    socket?.resume()
    startReceiveLoop { [weak self] message in
      guard let self else { return }
      guard let type = message["type"] as? String else { return }
      if type == "hello" {
        self.mappings = (message["mappings"] as? [[String: Any]] ?? []).compactMap {
          guard let id = $0["id"] as? String, !id.isEmpty else { return nil }
          return RemoteFileMapping(
            id: id,
            name: $0["name"] as? String ?? id,
            side: $0["side"] as? String ?? "host",
            mode: $0["mode"] as? String ?? "read")
        }
        completion(.success(self.mappings))
      } else if type == "error" {
        completion(.failure(RemoteFileMappingError.serverError(message["message"] as? String ?? "File mapping hello failed")))
      }
    }

    let clientUUID = capability["client_uuid"] as? String ?? ""
    sendRaw([
      "type": "hello",
      "version": 1,
      "endpoint": "client",
      "client_uuid": clientUUID,
      "mappings": [],
    ])
  }

  func list(
    mappingID: String,
    path: String,
    completion: @escaping (Result<[RemoteFileEntry], Error>) -> Void
  ) {
    sendRequest([
      "type": "list",
      "mapping": mappingID,
      "path": Self.relativePath(path),
    ]) { result in
      switch result {
      case .failure(let error):
        completion(.failure(error))
      case .success(let message):
        guard message["type"] as? String == "result" else {
          completion(.failure(RemoteFileMappingError.invalidResponse))
          return
        }
        let entries = (message["entries"] as? [[String: Any]] ?? []).compactMap { entry -> RemoteFileEntry? in
          guard let name = entry["name"] as? String, !name.isEmpty else { return nil }
          let entryPath = Self.relativePath(path).isEmpty
            ? name
            : Self.relativePath(path) + "/" + name
          return RemoteFileEntry(
            id: mappingID + ":" + entryPath,
            name: name,
            path: entryPath,
            isDirectory: (entry["kind"] as? String) == "directory",
            size: (entry["size"] as? NSNumber)?.uint64Value ?? 0,
            modifiedAt: (entry["mtime"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) })
        }
        completion(.success(entries))
      }
    }
  }

  func read(
    mappingID: String,
    path: String,
    offset: UInt64 = 0,
    length: UInt32 = 64 * 1024,
    completion: @escaping (Result<Data, Error>) -> Void
  ) {
    sendRequest([
      "type": "read",
      "mapping": mappingID,
      "path": Self.relativePath(path),
      "offset": offset,
      "length": min(length, 4 * 1024 * 1024),
    ]) { result in
      switch result {
      case .failure(let error):
        completion(.failure(error))
      case .success(let message):
        guard
          message["type"] as? String == "result",
          let encoded = message["data"] as? String,
          let data = Data(base64Encoded: encoded)
        else {
          completion(.failure(RemoteFileMappingError.invalidResponse))
          return
        }
        completion(.success(data))
      }
    }
  }

  func disconnect() {
    socket?.cancel(with: .normalClosure, reason: nil)
    session?.invalidateAndCancel()
    socket = nil
    session = nil
    identity = nil
    serverCertificate = nil
    pending.removeAll()
    mappings.removeAll()
    receiveStarted = false
  }

  private func sendRequest(
    _ payload: [String: Any],
    completion: @escaping (Result<[String: Any], Error>) -> Void
  ) {
    var message = payload
    let requestID = nextRequestID
    nextRequestID += 1
    message["id"] = requestID
    pending[requestID] = completion
    sendRaw(message)
  }

  private func sendRaw(_ payload: [String: Any]) {
    guard let socket else { return }
    guard JSONSerialization.isValidJSONObject(payload),
      let data = try? JSONSerialization.data(withJSONObject: payload),
      let string = String(data: data, encoding: .utf8)
    else { return }
    socket.send(.string(string)) { [weak self] error in
      if let error, let self {
        let callbacks = self.pending.values
        self.pending.removeAll()
        callbacks.forEach { $0(.failure(error)) }
      }
    }
  }

  private func startReceiveLoop(onMessage: @escaping ([String: Any]) -> Void) {
    guard !receiveStarted else { return }
    receiveStarted = true
    receiveNext(onMessage: onMessage)
  }

  private func receiveNext(onMessage: @escaping ([String: Any]) -> Void) {
    socket?.receive { [weak self] result in
      guard let self else { return }
      switch result {
      case .failure(let error):
        let callbacks = self.pending.values
        self.pending.removeAll()
        callbacks.forEach { $0(.failure(error)) }
      case .success(let message):
        if case .string(let text) = message,
          let data = text.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
          if let id = (object["id"] as? NSNumber)?.intValue, let callback = self.pending.removeValue(forKey: id) {
            if object["type"] as? String == "error" {
              callback(.failure(RemoteFileMappingError.serverError(object["message"] as? String ?? "File mapping request failed")))
            } else {
              callback(.success(object))
            }
          } else {
            onMessage(object)
          }
        }
        self.receiveNext(onMessage: onMessage)
      }
    }
  }

  private static func relativePath(_ path: String) -> String {
    path.split(separator: "/")
      .filter { $0 != "." && $0 != ".." && !$0.isEmpty }
      .joined(separator: "/")
  }

  private static func loadIdentity(from p12: Data) -> SecIdentity? {
    var items: CFArray?
    let options = [kSecImportExportPassphrase as String: "limelight"] as CFDictionary
    guard SecPKCS12Import(p12 as CFData, options, &items) == errSecSuccess,
      let array = items as? [[String: Any]],
      let rawIdentity = array.first?[kSecImportItemIdentity as String]
    else { return nil }
    return rawIdentity as! SecIdentity
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    switch challenge.protectionSpace.authenticationMethod {
    case NSURLAuthenticationMethodServerTrust:
      guard let trust = challenge.protectionSpace.serverTrust,
        let certificate = SecTrustGetCertificateAtIndex(trust, 0),
        let expected = serverCertificate,
        let actual = SecCertificateCopyData(certificate) as Data?,
        actual == expected
      else {
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
      completionHandler(
        .useCredential,
        URLCredential(identity: identity, certificates: certificate.map { [$0] }, persistence: .forSession))
    default:
      completionHandler(.cancelAuthenticationChallenge, nil)
    }
  }
}
