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

/// Error descriptions are English localization keys (or raw host messages);
/// the UI runs them through `LanguageManager.localize` when displaying them.
enum RemoteFileMappingError: LocalizedError {
  case unavailable(String)
  case protocolError(String)
  case serverError(String)
  case invalidResponse
  case notConnected
  case timedOut
  case disconnected
  case incompleteDownload
  case unsafeFileName
  case cannotCreateFile

  var errorDescription: String? {
    switch self {
    case .unavailable(let message), .protocolError(let message), .serverError(let message):
      return message
    case .invalidResponse:
      return "Invalid file mapping response"
    case .notConnected:
      return "File mapping is not connected"
    case .timedOut:
      return "File mapping request timed out"
    case .disconnected:
      return "File mapping connection closed"
    case .incompleteDownload:
      return "The download is incomplete"
    case .unsafeFileName:
      return "The host file name is not safe to save"
    case .cannotCreateFile:
      return "Unable to create the download file"
    }
  }
}

/// Read-only Foundation file-mapping RPC client.
///
/// The client keeps the session token in memory, pins the paired host
/// certificate, and accepts only mapping IDs plus relative paths. It does not
/// expose absolute host paths or enable write/delete/execute operations.
///
/// Threading: all mutable state (`socket`, `pending`, `nextRequestID`, ...) is
/// confined to one private serial queue, which is also the URLSession delegate
/// queue. Every public method may be called from any thread, and every
/// completion handler is delivered on the main queue exactly once.
final class RemoteFileMappingClient: NSObject, URLSessionTaskDelegate {
  /// URLSessionWebSocketTask defaults to 1 MiB, which a base64 chunk can exceed.
  private static let maxMessageSize = 8 << 20
  /// Largest read requested per chunk; base64 plus JSON stays far below
  /// `maxMessageSize`.
  static let maxReadLength: UInt32 = 1 << 20
  private static let helloTimeoutSeconds: TimeInterval = 15
  private static let requestTimeoutSeconds: TimeInterval = 30

  private struct PendingRequest {
    /// Always invoked on `queue`.
    let completion: (Result<[String: Any], Error>) -> Void
    let timeout: DispatchWorkItem
  }

  private let queue = DispatchQueue(label: "com.moonlight.RemoteFileMappingClient")

  // Everything below is confined to `queue`.
  private var session: URLSession?
  private var socket: URLSessionWebSocketTask?
  private var identity: SecIdentity?
  private var serverCertificate: Data?
  private var nextRequestID = 1
  private var pending: [Int: PendingRequest] = [:]
  private var helloCompletion: ((Result<[RemoteFileMapping], Error>) -> Void)?
  private var helloTimeout: DispatchWorkItem?
  private var currentMappings: [RemoteFileMapping] = []

  var mappings: [RemoteFileMapping] {
    queue.sync { currentMappings }
  }

  func connect(
    host: String,
    capability: [String: Any],
    serverCertificate: Data,
    completion: @escaping (Result<[RemoteFileMapping], Error>) -> Void
  ) {
    queue.async { [weak self] in
      guard let self else { return }
      self.teardown(error: RemoteFileMappingError.disconnected)
      guard
        (capability["ok"] as? NSNumber)?.boolValue == true,
        (capability["enabled"] as? NSNumber)?.boolValue == true,
        let url = Self.sessionURL(from: capability, host: host),
        url.scheme?.lowercased() == "wss",
        url.host?.isEmpty == false,
        let p12 = CryptoManager.readP12FromFile(),
        let identity = Self.loadIdentity(from: p12)
      else {
        self.deliver(completion, .failure(RemoteFileMappingError.unavailable("File mapping capability is unavailable")))
        return
      }

      self.serverCertificate = serverCertificate
      self.identity = identity
      let delegateQueue = OperationQueue()
      delegateQueue.maxConcurrentOperationCount = 1
      delegateQueue.underlyingQueue = self.queue
      let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: delegateQueue)
      let socket = session.webSocketTask(with: url)
      socket.maximumMessageSize = Self.maxMessageSize
      self.session = session
      self.socket = socket
      self.helloCompletion = completion
      self.helloTimeout = self.schedule(after: Self.helloTimeoutSeconds) { [weak self] in
        self?.teardown(error: RemoteFileMappingError.timedOut)
      }

      socket.resume()
      self.receiveNext(on: socket)
      let clientUUID = capability["client_uuid"] as? String ?? ""
      self.send([
        "type": "hello",
        "version": 1,
        "endpoint": "client",
        "client_uuid": clientUUID,
        "mappings": [],
      ], on: socket) { [weak self] error in
        self?.teardown(error: error)
      }
    }
  }

  func list(
    mappingID: String,
    path: String,
    completion: @escaping (Result<[RemoteFileEntry], Error>) -> Void
  ) {
    let relative = Self.relativePath(path)
    queue.async {
      self.sendRequest([
        "type": "list",
        "mapping": mappingID,
        "path": relative,
      ]) { result in
        // The host reply "type" is not checked (matching FileProviderExtension);
        // only "error" replies are failures, and those are handled upstream.
        switch result {
        case .failure(let error):
          self.deliver(completion, .failure(error))
        case .success(let message):
          let entries = (message["entries"] as? [[String: Any]] ?? []).compactMap { entry -> RemoteFileEntry? in
            // Names are untrusted: skip anything that is not a single component.
            guard let name = entry["name"] as? String,
              !name.isEmpty, name != ".", name != "..", !name.contains("/")
            else { return nil }
            let entryPath = relative.isEmpty ? name : relative + "/" + name
            return RemoteFileEntry(
              id: mappingID + ":" + entryPath,
              name: name,
              path: entryPath,
              isDirectory: (entry["kind"] as? String) == "directory",
              size: (entry["size"] as? NSNumber)?.uint64Value ?? 0,
              modifiedAt: (entry["mtime"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) })
          }
          self.deliver(completion, .success(entries))
        }
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
    let relative = Self.relativePath(path)
    queue.async {
      self.sendRequest([
        "type": "read",
        "mapping": mappingID,
        "path": relative,
        "offset": offset,
        "length": min(length, Self.maxReadLength),
      ]) { result in
        switch result {
        case .failure(let error):
          self.deliver(completion, .failure(error))
        case .success(let message):
          guard
            let encoded = message["data"] as? String,
            let data = Data(base64Encoded: encoded)
          else {
            self.deliver(completion, .failure(RemoteFileMappingError.invalidResponse))
            return
          }
          self.deliver(completion, .success(data))
        }
      }
    }
  }

  /// Closes the connection and fails every outstanding callback (including an
  /// unfinished `connect`) with `RemoteFileMappingError.disconnected`.
  func disconnect() {
    queue.async {
      self.teardown(error: RemoteFileMappingError.disconnected)
    }
  }

  // MARK: - Queue-confined helpers

  private func deliver<T>(_ completion: @escaping (Result<T, Error>) -> Void, _ result: Result<T, Error>) {
    DispatchQueue.main.async { completion(result) }
  }

  private func schedule(after seconds: TimeInterval, _ block: @escaping () -> Void) -> DispatchWorkItem {
    let item = DispatchWorkItem(block: block)
    queue.asyncAfter(deadline: .now() + seconds, execute: item)
    return item
  }

  /// Closes the socket and completes the hello handler and every pending
  /// request with `error`. Safe to call repeatedly.
  private func teardown(error: Error) {
    let socket = self.socket
    let session = self.session
    // Clear first so late callbacks from the cancelled socket are ignored.
    self.socket = nil
    self.session = nil
    identity = nil
    serverCertificate = nil
    currentMappings.removeAll()

    helloTimeout?.cancel()
    helloTimeout = nil
    let hello = helloCompletion
    helloCompletion = nil
    let callbacks = pending
    pending.removeAll()

    socket?.cancel(with: .goingAway, reason: nil)
    session?.invalidateAndCancel()

    if let hello { deliver(hello, .failure(error)) }
    for request in callbacks.values {
      request.timeout.cancel()
      request.completion(.failure(error))
    }
  }

  private func sendRequest(
    _ payload: [String: Any],
    completion: @escaping (Result<[String: Any], Error>) -> Void
  ) {
    guard let socket else {
      completion(.failure(RemoteFileMappingError.notConnected))
      return
    }
    var message = payload
    let requestID = nextRequestID
    nextRequestID += 1
    message["id"] = requestID
    let timeout = schedule(after: Self.requestTimeoutSeconds) { [weak self] in
      guard let self, let request = self.pending.removeValue(forKey: requestID) else { return }
      request.completion(.failure(RemoteFileMappingError.timedOut))
    }
    pending[requestID] = PendingRequest(completion: completion, timeout: timeout)
    send(message, on: socket) { [weak self] error in
      // A send failure means the connection is unusable; fail everything.
      self?.teardown(error: error)
    }
  }

  private func send(
    _ payload: [String: Any],
    on socket: URLSessionWebSocketTask,
    onFailure: @escaping (Error) -> Void
  ) {
    guard JSONSerialization.isValidJSONObject(payload),
      let data = try? JSONSerialization.data(withJSONObject: payload),
      let string = String(data: data, encoding: .utf8)
    else {
      onFailure(RemoteFileMappingError.protocolError("Invalid file mapping response"))
      return
    }
    socket.send(.string(string)) { [weak self] error in
      guard let error, let self else { return }
      self.queue.async {
        if self.socket === socket { onFailure(error) }
      }
    }
  }

  private func receiveNext(on socket: URLSessionWebSocketTask) {
    socket.receive { [weak self] result in
      guard let self else { return }
      self.queue.async {
        // Ignore callbacks from a socket that was already torn down.
        guard self.socket === socket else { return }
        switch result {
        case .failure(let error):
          self.teardown(error: error)
        case .success(let message):
          if case .string(let text) = message,
            let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
          {
            self.handle(object)
          }
          self.receiveNext(on: socket)
        }
      }
    }
  }

  private func handle(_ object: [String: Any]) {
    let type = object["type"] as? String
    if type == "hello", let hello = helloCompletion {
      helloCompletion = nil
      helloTimeout?.cancel()
      helloTimeout = nil
      currentMappings = (object["mappings"] as? [[String: Any]] ?? []).compactMap {
        guard let id = $0["id"] as? String, !id.isEmpty else { return nil }
        return RemoteFileMapping(
          id: id,
          name: $0["name"] as? String ?? id,
          side: $0["side"] as? String ?? "host",
          mode: $0["mode"] as? String ?? "read")
      }
      deliver(hello, .success(currentMappings))
      return
    }

    if let id = (object["id"] as? NSNumber)?.intValue, let request = pending.removeValue(forKey: id) {
      request.timeout.cancel()
      if type == "error" {
        request.completion(.failure(RemoteFileMappingError.serverError(
          object["message"] as? String ?? "File mapping request failed")))
      } else {
        request.completion(.success(object))
      }
      return
    }

    if type == "error", helloCompletion != nil {
      teardown(error: RemoteFileMappingError.serverError(
        object["message"] as? String ?? "File mapping hello failed"))
    }
  }

  private static func relativePath(_ path: String) -> String {
    path.split(separator: "/")
      .filter { $0 != "." && $0 != ".." && !$0.isEmpty }
      .joined(separator: "/")
  }

  /// Host addresses are stored with the host's HTTP port ("name:57989",
  /// "[fe80::1]:47989"); the session uses its own port, so keep only the host.
  static func hostComponent(of address: String) -> String {
    if address.hasPrefix("["), let close = address.firstIndex(of: "]") {
      return String(address[...close])
    }
    let colons = address.filter { $0 == ":" }.count
    if colons == 1, let colon = address.lastIndex(of: ":") {
      return String(address[..<colon])
    }
    // A bare IPv6 literal has several colons and no port.
    return colons > 1 ? "[\(address)]" : address
  }

  private static func sessionURL(from capability: [String: Any], host: String) -> URL? {
    if let rawURL = capability["session_url"] as? String,
      !rawURL.isEmpty,
      let url = URL(string: rawURL),
      url.scheme?.lowercased() == "wss"
    {
      return url
    }

    guard
      let port = (capability["port"] as? NSNumber)?.intValue,
      port > 0 && port <= 65_535,
      let endpoint = capability["session_endpoint"] as? String,
      !endpoint.isEmpty
    else {
      return nil
    }

    var components = URLComponents()
    components.scheme = "wss"
    components.host = hostComponent(of: host)
    components.port = port
    components.path = endpoint.hasPrefix("/") ? endpoint : "/" + endpoint
    if let token = capability["session_token"] as? String, !token.isEmpty {
      components.queryItems = [URLQueryItem(name: "token", value: token)]
    }
    return components.url
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

  // MARK: - URLSession delegate (runs on `queue`)

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    // Covers failures such as a rejected TLS pin before any message flows.
    guard let error, task === socket else { return }
    teardown(error: error)
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
        let certificate = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
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
