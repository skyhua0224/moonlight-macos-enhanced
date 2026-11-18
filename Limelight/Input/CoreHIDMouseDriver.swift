//
//  CoreHIDMouseDriver.swift
//  Moonlight for macOS
//

import CoreGraphics
import CoreHID
import Foundation
import IOKit.hidsystem

@objc protocol CoreHIDMouseDriverDelegate: AnyObject {
  @objc optional func coreHIDMouseDriver(
    _ driver: CoreHIDMouseDriver, didObserveRawDeltaX deltaX: Double, deltaY: Double)
  func coreHIDMouseDriver(
    _ driver: CoreHIDMouseDriver, didReceiveDeltaX deltaX: Double, deltaY: Double)
  func coreHIDMouseDriver(
    _ driver: CoreHIDMouseDriver, didFailWithReason reason: String, messageKey: String)
}

@objcMembers
final class CoreHIDMouseDriver: NSObject {
  private enum Failure {
    static let unsupportedOSReason = "unsupported-os"
    static let permissionDeniedReason = "permission-denied"
    // Input Monitoring is not reported as allowed and a mouse matched without any movement element: without the
    // permission CoreHID lists the device but gives no elements and no events. The system answers "unknown", not
    // "denied", for a build that was never asked (seen on macOS 26 with an ad-hoc signed app), so it is not "denied".
    static let permissionUnverifiedReason = "permission-unverified"
    static let managerErrorReason = "manager-error"
    static let clientErrorReason = "client-error"

    static let unsupportedOSMessageKey = "CoreHID Mouse requires macOS 15 or later."
    static let permissionDeniedMessageKey =
      "CoreHID Mouse access denied. Allow Input Monitoring in System Settings."
    static let runtimeErrorMessageKey = "CoreHID Mouse input failed."
  }

  private enum ReportRate {
    static let unlimited = 0
    static let defaultMaximum = 1000
    static let maxRate = 8000
  }

  weak var delegate: CoreHIDMouseDriverDelegate?
  var maximumReportRate = ReportRate.defaultMaximum
  var requestsListenAccessIfNeeded = false

  private let stateLock = NSLock()
  private var managerTask: Task<Void, Never>?
  private var pendingDeltaX = 0.0
  private var pendingDeltaY = 0.0
  private var lastDispatchTimestamp: TimeInterval = 0
  private var hasPostedFailure = false
  private var lastMovementEventTimestamp: TimeInterval = 0
  private var flushTask: Task<Void, Never>?
  private var listenAccess = ListenAccess.unchecked
  private var devicesMatched = 0
  private var devicesMonitored = 0
  private var devicesRejectedBuiltIn = 0
  private var devicesRejectedTrackpad = 0
  private var devicesWithoutMovement = 0

  /// What the system said about Input Monitoring when the driver started. CoreHID delivers nothing, and reports no
  /// error, when it is not allowed, so this is the first thing to read when the driver is silent.
  enum ListenAccess: String {
    case unchecked
    case granted
    case denied
    case unknown
  }

  var listenAccessState: String {
    stateLock.lock()
    defer { stateLock.unlock() }
    return listenAccess.rawValue
  }

  /// Input Monitoring is allowed now (read again, not the answer from when the driver started).
  var isListenAccessGranted: Bool {
    Self.currentListenAccess() == .granted
  }

  /// One line for the log: the permission and what became of the devices CoreHID matched.
  var diagnosticSummary: String {
    stateLock.lock()
    defer { stateLock.unlock() }
    return "access=\(listenAccess.rawValue) matched=\(devicesMatched) monitored=\(devicesMonitored) "
      + "builtIn=\(devicesRejectedBuiltIn) trackpad=\(devicesRejectedTrackpad) "
      + "noMovementElements=\(devicesWithoutMovement)"
  }

  /// Reads the Input Monitoring state without asking: the same two checks InputMonitoringPermissionManager makes.
  /// (Sources: macos-apple-iohidaccesstype-20261119, macos-apple-cgpreflightlisteneventaccess-20261119.)
  static func currentListenAccess() -> ListenAccess {
    let ioState = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
    if ioState == kIOHIDAccessTypeGranted || CGPreflightListenEventAccess() {
      return .granted
    }
    if ioState == kIOHIDAccessTypeUnknown {
      return .unknown
    }
    return .denied
  }

  var secondsSinceLastMovementEvent: TimeInterval {
    stateLock.lock()
    let timestamp = lastMovementEventTimestamp
    stateLock.unlock()

    guard timestamp > 0 else {
      return .greatestFiniteMagnitude
    }

    return max(0, ProcessInfo.processInfo.systemUptime - timestamp)
  }

  func start() {
    stop()

    guard #available(macOS 15.0, *) else {
      postFailureIfNeeded(
        reason: Failure.unsupportedOSReason,
        messageKey: Failure.unsupportedOSMessageKey
      )
      return
    }

    let access = Self.currentListenAccess()
    stateLock.lock()
    listenAccess = access
    stateLock.unlock()
    LogMessage(LOG_I, "[diag] CoreHID listen access: \(access.rawValue)")

    let permissionManager = InputMonitoringPermissionManager.sharedManager
    if requestsListenAccessIfNeeded {
      let granted = permissionManager.requestAuthorizationIfNeeded(
        interactive: true
      )
      guard granted else {
        postFailureIfNeeded(
          reason: Failure.permissionDeniedReason,
          messageKey: Failure.permissionDeniedMessageKey
        )
        return
      }
    } else {
      permissionManager.requestAuthorizationIfNeeded(interactive: false)
      // Without the permission CoreHID delivers nothing and says nothing. Say so now, and keep listening: if
      // motion does arrive the check was wrong and the delegate takes the free mouse back from the fallback.
      if access == .denied {
        postFailureIfNeeded(
          reason: Failure.permissionDeniedReason,
          messageKey: Failure.permissionDeniedMessageKey
        )
      }
    }

    managerTask = Task { [weak self] in
      guard let self else { return }
      await self.monitorManager()
    }
  }

  func stop() {
    stateLock.lock()
    managerTask?.cancel()
    managerTask = nil
    flushTask?.cancel()
    flushTask = nil
    pendingDeltaX = 0
    pendingDeltaY = 0
    lastDispatchTimestamp = 0
    hasPostedFailure = false
    lastMovementEventTimestamp = 0
    listenAccess = .unchecked
    devicesMatched = 0
    devicesMonitored = 0
    devicesRejectedBuiltIn = 0
    devicesRejectedTrackpad = 0
    devicesWithoutMovement = 0
    stateLock.unlock()
  }

  deinit {
    stop()
  }

  @available(macOS 15.0, *)
  private func monitorManager() async {
    let manager = HIDDeviceManager()
    let criteria = HIDDeviceManager.DeviceMatchingCriteria(primaryUsage: .genericDesktop(.mouse))

    do {
      let stream = await manager.monitorNotifications(matchingCriteria: [criteria])
      var clientTasks: [HIDDeviceClient.DeviceReference: Task<Void, Never>] = [:]

      defer {
        for task in clientTasks.values {
          task.cancel()
        }
      }

      for try await notification in stream {
        if Task.isCancelled {
          break
        }

        switch notification {
        case .deviceMatched(let deviceReference):
          guard clientTasks[deviceReference] == nil,
            let client = HIDDeviceClient(deviceReference: deviceReference)
          else {
            continue
          }

          noteDeviceCounter { $0.devicesMatched += 1 }
          guard await shouldMonitorDevice(client) else {
            continue
          }
          noteDeviceCounter { $0.devicesMonitored += 1 }

          clientTasks[deviceReference] = Task { [weak self] in
            guard let self else { return }
            await self.monitorClient(client)
          }

        case .deviceRemoved(let deviceReference):
          clientTasks[deviceReference]?.cancel()
          clientTasks.removeValue(forKey: deviceReference)

        @unknown default:
          continue
        }
      }
    } catch {
      if !Task.isCancelled {
        postFailureIfNeeded(
          reason: Failure.managerErrorReason,
          messageKey: Failure.runtimeErrorMessageKey
        )
      }
    }
  }

  @available(macOS 15.0, *)
  private func monitorClient(_ client: HIDDeviceClient) async {
    let allElements = await client.elements
    let movementElements = allElements.filter { element in
      isMovementUsage(element.usage)
    }
    guard !movementElements.isEmpty else {
      let productName = await client.product ?? "?"
      noteDeviceCounter { $0.devicesWithoutMovement += 1 }
      LogMessage(LOG_I, "[diag] CoreHID device skipped: no X/Y movement element product=\(productName)")
      if !isListenAccessGranted {
        postFailureIfNeeded(
          reason: Failure.permissionUnverifiedReason,
          messageKey: Failure.permissionDeniedMessageKey
        )
      }
      return
    }

    let reportIDs: [ClosedRange<HIDReportID>] = []

    do {
      let stream = await client.monitorNotifications(
        reportIDsToMonitor: reportIDs,
        elementsToMonitor: movementElements
      )

      for try await notification in stream {
        if Task.isCancelled {
          break
        }

        switch notification {
        case .elementUpdates(let values):
          var deltaX = 0.0
          var deltaY = 0.0

          for value in values {
            switch value.element.usage {
            case .genericDesktop(.x):
              deltaX += valueAsDelta(value)
            case .genericDesktop(.y):
              deltaY += valueAsDelta(value)
            default:
              continue
            }
          }

          if deltaX != 0 || deltaY != 0 {
            reportDelta(deltaX: deltaX, deltaY: deltaY)
          }

        case .deviceRemoved:
          return

        case .inputReport, .deviceSeized, .deviceUnseized:
          continue

        @unknown default:
          continue
        }
      }
    } catch {
      if !Task.isCancelled {
        postFailureIfNeeded(
          reason: Failure.clientErrorReason,
          messageKey: Failure.runtimeErrorMessageKey
        )
      }
    }
  }

  @available(macOS 15.0, *)
  private func shouldMonitorDevice(_ client: HIDDeviceClient) async -> Bool {
    let rawProduct = await client.product?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
    if await client.isBuiltIn {
      noteDeviceCounter { $0.devicesRejectedBuiltIn += 1 }
      LogMessage(LOG_I, "[diag] CoreHID device skipped: built-in product=\(rawProduct)")
      return false
    }

    if rawProduct.lowercased().contains("trackpad") {
      noteDeviceCounter { $0.devicesRejectedTrackpad += 1 }
      LogMessage(LOG_I, "[diag] CoreHID device skipped: trackpad product=\(rawProduct)")
      return false
    }

    LogMessage(LOG_I, "[diag] CoreHID device monitored: product=\(rawProduct)")
    return true
  }

  private func noteDeviceCounter(_ update: (CoreHIDMouseDriver) -> Void) {
    stateLock.lock()
    update(self)
    stateLock.unlock()
  }

  @available(macOS 15.0, *)
  private func valueAsDelta(_ value: HIDElement.Value) -> Double {
    if let logicalValue = value.logicalValue(asTypeTruncatingIfNeeded: Int64.self) {
      return Double(logicalValue)
    }
    return Double(value.integerValue(asTypeTruncatingIfNeeded: Int64.self))
  }

  @available(macOS 15.0, *)
  private func isMovementUsage(_ usage: HIDUsage) -> Bool {
    if case .genericDesktop(.x) = usage {
      return true
    }
    if case .genericDesktop(.y) = usage {
      return true
    }
    return false
  }

  private func reportDelta(deltaX: Double, deltaY: Double) {
    delegate?.coreHIDMouseDriver?(self, didObserveRawDeltaX: deltaX, deltaY: deltaY)

    let maxRate = Self.normalizedMaximumReportRate(maximumReportRate)
    if maxRate == ReportRate.unlimited {
      markMovementEventDelivered()
      delegate?.coreHIDMouseDriver(self, didReceiveDeltaX: deltaX, deltaY: deltaY)
      return
    }

    var deltaToDispatch: (x: Double, y: Double)?
    var flushDelaySeconds: TimeInterval?

    stateLock.lock()
    pendingDeltaX += deltaX
    pendingDeltaY += deltaY

    let now = ProcessInfo.processInfo.systemUptime
    let minimumInterval = 1.0 / Double(maxRate)
    let elapsed =
      lastDispatchTimestamp == 0
      ? TimeInterval.greatestFiniteMagnitude
      : (now - lastDispatchTimestamp)

    if elapsed >= minimumInterval {
      deltaToDispatch = (pendingDeltaX, pendingDeltaY)
      pendingDeltaX = 0
      pendingDeltaY = 0
      lastDispatchTimestamp = now
      flushTask?.cancel()
      flushTask = nil
    } else if flushTask == nil {
      flushDelaySeconds = max(0, minimumInterval - elapsed)
    }
    stateLock.unlock()

    if let deltaToDispatch {
      markMovementEventDelivered()
      delegate?.coreHIDMouseDriver(self, didReceiveDeltaX: deltaToDispatch.x, deltaY: deltaToDispatch.y)
    }

    if let flushDelaySeconds {
      schedulePendingFlush(after: flushDelaySeconds)
    }
  }

  private func schedulePendingFlush(after delaySeconds: TimeInterval) {
    let clampedDelay = max(0, delaySeconds)
    let delayNanoseconds = UInt64(clampedDelay * 1_000_000_000.0)
    let task = Task { [weak self] in
      if delayNanoseconds > 0 {
        try? await Task.sleep(nanoseconds: delayNanoseconds)
      }
      self?.flushPendingDeltaIfNeeded()
    }

    stateLock.lock()
    if flushTask == nil {
      flushTask = task
      stateLock.unlock()
      return
    }
    stateLock.unlock()
    task.cancel()
  }

  private func flushPendingDeltaIfNeeded() {
    var deltaToDispatch: (x: Double, y: Double)?
    stateLock.lock()
    flushTask = nil
    if pendingDeltaX != 0 || pendingDeltaY != 0 {
      deltaToDispatch = (pendingDeltaX, pendingDeltaY)
      pendingDeltaX = 0
      pendingDeltaY = 0
      lastDispatchTimestamp = ProcessInfo.processInfo.systemUptime
    }
    stateLock.unlock()

    if let deltaToDispatch {
      markMovementEventDelivered()
      delegate?.coreHIDMouseDriver(self, didReceiveDeltaX: deltaToDispatch.x, deltaY: deltaToDispatch.y)
    }
  }

  private func markMovementEventDelivered() {
    stateLock.lock()
    lastMovementEventTimestamp = ProcessInfo.processInfo.systemUptime
    stateLock.unlock()
  }

  private static func normalizedMaximumReportRate(_ value: Int) -> Int {
    let clamped = max(ReportRate.unlimited, min(value, ReportRate.maxRate))
    if clamped == ReportRate.unlimited {
      return ReportRate.unlimited
    }
    return max(1, clamped)
  }

  private func postFailureIfNeeded(reason: String, messageKey: String) {
    stateLock.lock()
    if hasPostedFailure {
      stateLock.unlock()
      return
    }
    hasPostedFailure = true
    stateLock.unlock()

    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.delegate?.coreHIDMouseDriver(self, didFailWithReason: reason, messageKey: messageKey)
    }
  }
}
