//
//  CoreHIDMouseDriver.swift
//  Moonlight for macOS
//

import CoreHID
import Foundation
import IOKit.hidsystem

@objc protocol CoreHIDMouseDriverDelegate: AnyObject {
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

    guard ensureListenAccessGranted() else {
      postFailureIfNeeded(
        reason: Failure.permissionDeniedReason,
        messageKey: Failure.permissionDeniedMessageKey
      )
      return
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
    stateLock.unlock()
  }

  deinit {
    stop()
  }

  private func ensureListenAccessGranted() -> Bool {
    let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
    switch access {
    case kIOHIDAccessTypeGranted:
      return true
    case kIOHIDAccessTypeUnknown:
      return requestsListenAccessIfNeeded ? IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) : false
    default:
      return false
    }
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
