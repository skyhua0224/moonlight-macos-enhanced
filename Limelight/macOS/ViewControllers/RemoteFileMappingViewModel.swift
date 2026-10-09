import AppKit
import Darwin
import Foundation

/// What the Host Files page is currently doing. The view derives the status
/// text and indicator color from this instead of comparing display strings.
enum RemoteFileMappingState: Equatable {
  case idle
  case needsHost
  case checking
  case ready
  case noSharedFolders
  case loadingFolder
  case downloading(percent: Int?)
  case downloaded
  case cancelled
  /// Localization key or raw host message.
  case failed(String)

  var isHealthy: Bool {
    switch self {
    case .ready, .downloaded: return true
    default: return false
    }
  }
}

@MainActor
final class RemoteFileMappingViewModel: ObservableObject {
  @Published private(set) var state: RemoteFileMappingState = .idle
  @Published private(set) var mappings: [RemoteFileMapping] = []
  @Published private(set) var entries: [RemoteFileEntry] = []
  @Published private(set) var currentPath = ""
  @Published private(set) var selectedMappingID: String?
  @Published private(set) var downloadedURL: URL?
  @Published private(set) var isListing = false
  @Published private(set) var isDownloading = false

  var isBusy: Bool { isListing || isDownloading }

  /// Localized status line.
  var status: String {
    let language = LanguageManager.shared
    switch state {
    case .idle: return language.localize("Idle")
    case .needsHost: return language.localize("Select a paired host")
    case .checking: return language.localize("Checking Host Files…")
    case .ready: return language.localize("Host Files ready")
    case .noSharedFolders: return language.localize("No shared folders")
    case .loadingFolder: return language.localize("Loading folder…")
    case .downloading(let percent):
      guard let percent else { return language.localize("Downloading…") }
      return String(format: language.localize("Downloading… %d%%"), Int32(percent))
    case .downloaded: return language.localize("Downloaded")
    case .cancelled: return language.localize("Download cancelled")
    case .failed(let message): return language.localize(message)
    }
  }

  private var client: RemoteFileMappingClient?
  /// Bumped whenever the session is reset, so late callbacks from a previous
  /// host or an abandoned capability fetch are ignored.
  private var generation = 0
  /// Identifies the latest list request; older replies are dropped.
  private var listToken = 0
  private var currentDownload: DownloadJob?
  /// File writes and the final move happen here, never on the main thread.
  private let ioQueue = DispatchQueue(label: "com.moonlight.HostFilesDownload", qos: .utility)

  private var selectedMapping: RemoteFileMapping? {
    mappings.first { $0.id == selectedMappingID }
  }

  func refresh(host: Host?) {
    resetSession()
    let generation = self.generation

    guard let host, host.id != SettingsModel.globalHostId,
      let temporaryHosts = DataManager().getHosts() as? [TemporaryHost],
      let temporaryHost = temporaryHosts.first(where: { $0.uuid == host.id }),
      let address = Self.reachableAddress(for: temporaryHost),
      !address.isEmpty,
      let certificate = temporaryHost.serverCert else {
      state = .needsHost
      return
    }

    state = .checking
    guard let http = HttpManager(host: address, uniqueId: IdManager.getUniqueId(), serverCert: certificate) else {
      state = .failed("Unable to create the host connection")
      return
    }

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let capability = http.fetchSunshineFileMappingCapability()
      Task { @MainActor [weak self] in
        guard let self, self.generation == generation else { return }
        self.connect(capability: capability, address: address, certificate: certificate)
      }
    }
  }

  private func connect(capability: [String: Any]?, address: String, certificate: Data) {
    guard let capability else {
      state = .failed("Invalid Host Files capability response")
      return
    }
    guard (capability["ok"] as? NSNumber)?.boolValue == true else {
      state = .failed((capability["reason"] as? String)
        ?? (capability["statusMessage"] as? String)
        ?? "Host Files is unavailable")
      return
    }

    let generation = self.generation
    let fileClient = RemoteFileMappingClient()
    client = fileClient
    fileClient.connect(host: address, capability: capability, serverCertificate: certificate) { [weak self] result in
      Task { @MainActor [weak self] in
        guard let self, self.generation == generation else { return }
        switch result {
        case .failure(let error):
          self.state = .failed(Self.message(for: error))
        case .success(let mappings):
          self.mappings = mappings
          self.selectedMappingID = mappings.first?.id
          if mappings.isEmpty {
            self.state = .noSharedFolders
          } else {
            self.listCurrentFolder()
          }
        }
      }
    }
  }

  func selectMapping(_ mapping: RemoteFileMapping) {
    guard !isDownloading, selectedMappingID != mapping.id else { return }
    selectedMappingID = mapping.id
    currentPath = ""
    listCurrentFolder()
  }

  func listCurrentFolder() {
    // A running download owns the status line and busy state.
    guard !isDownloading, let client, let mapping = selectedMapping else { return }
    listToken += 1
    let token = listToken
    let generation = self.generation
    isListing = true
    state = .loadingFolder
    client.list(mappingID: mapping.id, path: currentPath) { [weak self] result in
      Task { @MainActor [weak self] in
        guard let self, self.generation == generation, self.listToken == token else { return }
        self.isListing = false
        switch result {
        case .failure(let error):
          self.state = .failed(Self.message(for: error))
        case .success(let entries):
          self.entries = entries.sorted {
            ($0.isDirectory ? 0 : 1, $0.name.lowercased()) < ($1.isDirectory ? 0 : 1, $1.name.lowercased())
          }
          self.state = .ready
        }
      }
    }
  }

  func open(_ entry: RemoteFileEntry) {
    if entry.isDirectory {
      guard !isDownloading else { return }
      currentPath = entry.path
      listCurrentFolder()
    } else {
      download(entry)
    }
  }

  func goUp() {
    guard !isDownloading, !currentPath.isEmpty else { return }
    currentPath = currentPath.split(separator: "/").dropLast().joined(separator: "/")
    listCurrentFolder()
  }

  func revealDownloadedFile() {
    if let downloadedURL { NSWorkspace.shared.activateFileViewerSelecting([downloadedURL]) }
  }

  /// Drops the connection and any running download. Called when the page goes
  /// away; `refresh(host:)` starts a new session.
  func disconnect() {
    resetSession()
    state = .idle
  }

  /// Stops the running download and removes its partial file.
  func cancelDownload() {
    guard let job = currentDownload else { return }
    currentDownload = nil
    isDownloading = false
    state = .cancelled
    ioQueue.async { job.discard() }
  }

  private func resetSession() {
    generation += 1
    listToken += 1
    if let job = currentDownload {
      currentDownload = nil
      ioQueue.async { job.discard() }
    }
    isDownloading = false
    isListing = false
    client?.disconnect()
    client = nil
    mappings = []
    entries = []
    currentPath = ""
    selectedMappingID = nil
    downloadedURL = nil
  }

  // MARK: - Downloads

  private static let chunkSize = RemoteFileMappingClient.maxReadLength

  func download(_ entry: RemoteFileEntry) {
    guard !entry.isDirectory, !isBusy, client != nil, let mapping = selectedMapping else { return }
    guard let fileName = HostDownloadStore.sanitizedFileName(entry.name) else {
      state = .failed(Self.message(for: RemoteFileMappingError.unsafeFileName))
      return
    }
    guard let downloads = HostDownloadStore.downloadsDirectory() else {
      state = .failed(Self.message(for: RemoteFileMappingError.cannotCreateFile))
      return
    }

    let job = DownloadJob(entry: entry, mappingID: mapping.id, fileName: fileName, downloads: downloads)
    currentDownload = job
    isDownloading = true
    downloadedURL = nil
    state = .downloading(percent: entry.size > 0 ? 0 : nil)
    ioQueue.async { [weak self] in
      do {
        try job.openPartFile()
      } catch {
        Task { @MainActor [weak self] in self?.failDownload(job, error) }
        return
      }
      Task { @MainActor [weak self] in self?.readNextChunk(job) }
    }
  }

  private func readNextChunk(_ job: DownloadJob) {
    guard currentDownload === job, let client else { return }
    client.read(mappingID: job.mappingID, path: job.entry.path, offset: job.offset, length: Self.chunkSize) { [weak self] result in
      Task { @MainActor [weak self] in self?.handleChunk(result, for: job) }
    }
  }

  private func handleChunk(_ result: Result<Data, Error>, for job: DownloadJob) {
    // Cancelled, failed or superseded: the job was already discarded.
    guard currentDownload === job else { return }
    switch result {
    case .failure(let error):
      failDownload(job, error)
    case .success(let data):
      if data.isEmpty {
        // End of file. Fine for unknown sizes; anything short of the
        // advertised size is a truncated transfer.
        if job.entry.size == 0 || job.offset >= job.entry.size {
          finishDownload(job)
        } else {
          failDownload(job, RemoteFileMappingError.incompleteDownload)
        }
        return
      }
      ioQueue.async { [weak self] in
        do {
          try job.append(data)
        } catch {
          Task { @MainActor [weak self] in self?.failDownload(job, error) }
          return
        }
        Task { @MainActor [weak self] in self?.chunkWritten(job, count: data.count) }
      }
    }
  }

  private func chunkWritten(_ job: DownloadJob, count: Int) {
    guard currentDownload === job else { return }
    job.offset += UInt64(count)
    let size = job.entry.size
    if size > 0 && job.offset >= size {
      finishDownload(job)
      return
    }
    state = .downloading(percent: size > 0 ? Int(min(99, job.offset * 100 / size)) : nil)
    readNextChunk(job)
  }

  private func finishDownload(_ job: DownloadJob) {
    ioQueue.async { [weak self] in
      do {
        let url = try job.finalize()
        Task { @MainActor [weak self] in self?.downloadCompleted(job, url: url) }
      } catch {
        job.discard()
        Task { @MainActor [weak self] in self?.failDownload(job, error) }
      }
    }
  }

  private func downloadCompleted(_ job: DownloadJob, url: URL) {
    guard currentDownload === job else {
      // Cancelled while the file was being moved into place.
      ioQueue.async { try? FileManager.default.removeItem(at: url) }
      return
    }
    currentDownload = nil
    isDownloading = false
    downloadedURL = url
    state = .downloaded
    revealDownloadedFile()
  }

  private func failDownload(_ job: DownloadJob, _ error: Error) {
    guard currentDownload === job else { return }
    currentDownload = nil
    isDownloading = false
    state = .failed(Self.message(for: error))
    ioQueue.async { job.discard() }
  }

  private static func message(for error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
  }

  private static func reachableAddress(for host: TemporaryHost) -> String? {
    let candidates = [host.activeAddress].compactMap { $0 } + ConnectionEndpointStore.allEndpoints(for: host)
    let states = host.addressStates ?? [:]
    return candidates.first(where: { states[$0]?.intValue == 1 }) ?? candidates.first(where: { !$0.isEmpty })
  }
}

/// One in-flight download. `offset` is only touched on the main actor; the
/// handle and part file only on the view model's I/O queue.
private final class DownloadJob: @unchecked Sendable {
  let entry: RemoteFileEntry
  let mappingID: String
  let fileName: String
  let downloads: URL
  var offset: UInt64 = 0

  private var partURL: URL?
  private var handle: FileHandle?

  init(entry: RemoteFileEntry, mappingID: String, fileName: String, downloads: URL) {
    self.entry = entry
    self.mappingID = mappingID
    self.fileName = fileName
    self.downloads = downloads
  }

  /// Creates a hidden, uniquely named ".part" file next to the final location.
  /// O_EXCL guarantees it is new, and O_NOFOLLOW that it is not a symlink.
  func openPartFile() throws {
    let url = downloads.appendingPathComponent(".moonlight-\(UUID().uuidString).part")
    let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { throw RemoteFileMappingError.cannotCreateFile }
    handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    partURL = url
  }

  func append(_ data: Data) throws {
    guard let handle else { throw RemoteFileMappingError.cannotCreateFile }
    try handle.write(contentsOf: data)
  }

  /// Closes the part file and moves it to a non-clobbering name in Downloads.
  func finalize() throws -> URL {
    guard let handle, let partURL else { throw RemoteFileMappingError.cannotCreateFile }
    try handle.close()
    self.handle = nil
    let destination = try HostDownloadStore.moveIntoPlace(part: partURL, fileName: fileName, downloads: downloads)
    self.partURL = nil
    return destination
  }

  /// Closes and deletes the part file. Safe to call more than once.
  func discard() {
    try? handle?.close()
    handle = nil
    if let partURL { try? FileManager.default.removeItem(at: partURL) }
    partURL = nil
  }
}

/// File-name and Downloads-directory handling for host-provided names, which
/// are untrusted input.
private enum HostDownloadStore {
  static let maxNameBytes = 255

  static func downloadsDirectory() -> URL? {
    FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
  }

  /// Returns a single safe path component, or nil if the host name has to be
  /// rejected (empty, "." / "..", path separators, control or bidi override
  /// characters). Over-long names are shortened to 255 UTF-8 bytes while
  /// keeping the extension.
  static func sanitizedFileName(_ raw: String) -> String? {
    let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name != ".", name != ".." else { return nil }
    for scalar in name.unicodeScalars {
      if scalar == "/" || scalar.properties.generalCategory == .control { return nil }
      switch scalar.value {
      case 0x202A...0x202E, 0x2066...0x2069: return nil
      default: break
      }
    }
    guard name.utf8.count > maxNameBytes else { return name }
    return compose(name, tag: "")
  }

  /// Moves `part` to `downloads/fileName`, or "name (2).ext", "name (3).ext"...
  /// if that exists. The rename is exclusive, so an existing file is never
  /// replaced, and the parent of every candidate must be Downloads itself.
  static func moveIntoPlace(part: URL, fileName: String, downloads: URL) throws -> URL {
    let parent = canonicalPath(downloads)
    for index in 1...999 {
      let candidateName = index == 1 ? fileName : compose(fileName, tag: " (\(index))")
      let candidate = downloads.appendingPathComponent(candidateName)
      guard candidate.lastPathComponent == candidateName,
        canonicalPath(candidate.deletingLastPathComponent()) == parent
      else { throw RemoteFileMappingError.unsafeFileName }
      if try renameExclusive(part, to: candidate) { return candidate }
    }
    throw RemoteFileMappingError.cannotCreateFile
  }

  /// Returns false if `destination` already exists.
  private static func renameExclusive(_ source: URL, to destination: URL) throws -> Bool {
    if renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 { return true }
    let code = errno
    switch code {
    case EEXIST:
      return false
    case ENOTSUP, EINVAL:
      // Volume without exclusive rename: fall back to check-then-move.
      if FileManager.default.fileExists(atPath: destination.path) { return false }
      try FileManager.default.moveItem(at: source, to: destination)
      return true
    default:
      throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
  }

  private static func canonicalPath(_ url: URL) -> String {
    url.standardizedFileURL.resolvingSymlinksInPath().path
  }

  /// "stem" + tag + ".ext", with the stem shortened so the result fits in 255 bytes.
  private static func compose(_ name: String, tag: String) -> String {
    let nsName = name as NSString
    let ext = nsName.pathExtension
    let stem = nsName.deletingPathExtension
    let tail = tag + (ext.isEmpty ? "" : "." + ext)
    let room = maxNameBytes - tail.utf8.count
    let shortened = room > 0 ? truncated(stem, toBytes: room) : ""
    let result = shortened + tail
    // Fall back to a random name if nothing of the original fits.
    let lostStem = shortened.isEmpty && !stem.isEmpty
    return (lostStem || result.isEmpty) ? UUID().uuidString : result
  }

  private static func truncated(_ text: String, toBytes limit: Int) -> String {
    var result = ""
    var used = 0
    for character in text {
      let size = String(character).utf8.count
      if used + size > limit { break }
      result.append(character)
      used += size
    }
    return result
  }
}
