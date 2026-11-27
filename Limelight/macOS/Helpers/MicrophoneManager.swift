//
//  MicrophoneManager.swift
//  Moonlight for macOS
//
//  Manages microphone device enumeration, permission status, and input level metering.
//

import AppKit
import AVFoundation
import Combine
import CoreAudio
import CoreGraphics
import IOKit.hidsystem
import Security
import SwiftUI

struct MicrophoneDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

class MicrophoneManager: ObservableObject {
    static let shared = MicrophoneManager()

    @Published var devices: [MicrophoneDevice] = []
    @Published var permissionStatus: AVAuthorizationStatus = .notDetermined
    @Published var inputLevel: Float = 0
    @Published var isTesting: Bool = false

    @AppStorage("selectedMicDeviceUID") var selectedDeviceUID: String = ""

    private var testEngine: AVAudioEngine?
    private var levelTimer: Timer?
    // Device queries run here, never on the main thread: while an output device is starting
    // (or failing to, like an HDMI TV whose clock is not running) CoreAudio holds its I/O lock
    // for seconds, and these queries wait for it.
    private let deviceQueue = DispatchQueue(label: "moonlight.microphone.devices", qos: .utility)

    init() {
        refreshDevices()
        refreshPermissionStatus()
        installDeviceChangeListener()
    }

    deinit {
        removeDeviceChangeListener()
        stopTest()
    }

    // MARK: - Device Enumeration

    func refreshDevices() {
        deviceQueue.async { [weak self] in
            let result = Self.inputDevices()
            // A chosen microphone that is not there now stays chosen: it may only be unplugged
            // for a moment, and until it is back the stream uses the system default.
            DispatchQueue.main.async {
                self?.devices = result
            }
        }
    }

    private static func inputDevices() -> [MicrophoneDevice] {
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &propAddr, 0, nil, &dataSize) == noErr
        else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &propAddr, 0, nil, &dataSize, &deviceIDs)
            == noErr
        else { return [] }

        var result: [MicrophoneDevice] = []
        for id in deviceIDs {
            // Check if device has input channels
            var inputScope = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var bufSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &inputScope, 0, nil, &bufSize) == noErr,
                  bufSize >= UInt32(MemoryLayout<AudioBufferList>.size) else { continue }

            // As large as the device says. The list has one buffer per stream, and
            // AudioBufferList by itself has room for one: a device with several input
            // streams (an aggregate device, such as the one the system makes while audio
            // plays) was written past the end of it, into whatever lay behind.
            let capacity = Int(bufSize)
            let storage = UnsafeMutableRawPointer.allocate(
                byteCount: capacity, alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { storage.deallocate() }
            storage.initializeMemory(as: UInt8.self, repeating: 0, count: capacity)
            guard AudioObjectGetPropertyData(id, &inputScope, 0, nil, &bufSize, storage) == noErr
            else { continue }
            let bufferList = storage.bindMemory(to: AudioBufferList.self, capacity: 1)

            // No more buffers than there is room for, whatever the count in front says.
            let room = (capacity - MemoryLayout<AudioBufferList>.size) / MemoryLayout<AudioBuffer>.stride + 1
            let inputChannels = UnsafeMutableAudioBufferListPointer(bufferList)
                .prefix(room)
                .reduce(0) { $0 + Int($1.mNumberChannels) }
            guard inputChannels > 0 else { continue }

            // Get UID
            var uidProp = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uidRef: Unmanaged<CFString>?
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &uidProp, 0, nil, &uidSize, &uidRef) == noErr,
                let uid = uidRef?.takeRetainedValue()
            else { continue }

            // Get Name
            var nameProp = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var nameRef: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &nameProp, 0, nil, &nameSize, &nameRef) == noErr,
                let name = nameRef?.takeRetainedValue()
            else { continue }

            // Not the device the system puts together for this app alone while it plays audio:
            // it is not a microphone anyone can choose, and it is gone when the audio stops.
            if (uid as String).hasPrefix("CADefaultDeviceAggregate")
                || (name as String).hasPrefix("CADefaultDeviceAggregate") { continue }

            result.append(MicrophoneDevice(
                id: id,
                uid: uid as String,
                name: name as String
            ))
        }
        return result
    }

    // MARK: - Device Change Listener

    private var listenerBlock: AudioObjectPropertyListenerBlock?

    private func installDeviceChangeListener() {
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refreshDevices()
        }
        listenerBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &propAddr, deviceQueue, block)
    }

    private func removeDeviceChangeListener() {
        guard let block = listenerBlock else { return }
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &propAddr, deviceQueue, block)
        listenerBlock = nil
    }

    // MARK: - Permissions

    func refreshPermissionStatus() {
        permissionStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    }

    func requestPermission() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            DispatchQueue.main.async {
                self?.refreshPermissionStatus()
            }
        }
    }

    func openSystemPreferences() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Test (Level Metering)

    func startTest() {
        guard !isTesting else { return }

        let engine = AVAudioEngine()

        // Set selected device if not default
        if !selectedDeviceUID.isEmpty,
           let device = devices.first(where: { $0.uid == selectedDeviceUID })
        {
            setAudioUnitDevice(engine.inputNode, deviceID: device.id)
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { return }

        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let data = buffer.floatChannelData else { return }
            let count = Int(buffer.frameLength)
            var maxVal: Float = 0
            for i in 0..<count {
                let abs = Swift.abs(data[0][i])
                if abs > maxVal { maxVal = abs }
            }
            DispatchQueue.main.async {
                // Smooth the level a bit
                self?.inputLevel = max(maxVal, (self?.inputLevel ?? 0) * 0.7)
            }
        }

        do {
            try engine.start()
            testEngine = engine
            isTesting = true

            // Auto-stop after 15 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                self?.stopTest()
            }
        } catch {
            NSLog("Mic test failed to start: %@", error.localizedDescription)
        }
    }

    func stopTest() {
        guard isTesting else { return }
        testEngine?.inputNode.removeTap(onBus: 0)
        testEngine?.stop()
        testEngine = nil
        isTesting = false
        inputLevel = 0
    }

    // MARK: - Helpers

    /// Get the AudioDeviceID for the selected device, or 0 for system default.
    @objc var selectedAudioDeviceID: AudioDeviceID {
        guard !selectedDeviceUID.isEmpty,
              let device = devices.first(where: { $0.uid == selectedDeviceUID })
        else { return 0 }
        return device.id
    }

    private func setAudioUnitDevice(_ inputNode: AVAudioInputNode, deviceID: AudioDeviceID) {
        var deviceID = deviceID
        let audioUnit = inputNode.audioUnit!
        AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
    }
}

@objc enum InputMonitoringAuthorizationState: Int {
    case unsupported = 0
    case notDetermined = 1
    case denied = 2
    case granted = 3
    case grantedNeedsReentry = 4
}

@objcMembers
final class InputMonitoringPermissionManager: NSObject, ObservableObject {
    @objc(sharedManager) static let sharedManager = InputMonitoringPermissionManager()
    private static let everGrantedKey = "inputMonitoring.everGranted"
    private static let systemRefreshWindowSeconds: TimeInterval = 8.0

    @Published var authorizationState: InputMonitoringAuthorizationState = .notDetermined
    @Published var isRequestingAuthorization: Bool = false
    @Published var lastFailureMessage: String = ""

    private var didBecomeActiveObserver: NSObjectProtocol?
    private var hasShownRuntimeAlert = false
    // The CoreHID-silent alert is kept while a stream window is on screen and shown when it has closed.
    private var runtimeAlertPending = false
    private var streamWindowCloseObserver: NSObjectProtocol?
    private var observedSystemState: InputMonitoringAuthorizationState = .notDetermined
    private var needsStreamReentry = false
    private var hasPersistedGrantHistory = false
    private var hasRuntimeVerifiedGrantThisSession = false
    private var didAttemptAuthorizationThisSession = false
    private var shouldSuggestSettingsRepair = false
    // CoreHID delivered nothing while the system pointer moved, and the system does not report Input Monitoring as
    // allowed for this build. An earlier grant (everGranted) must not hide that behind "granted, re-enter the stream":
    // the shipped builds are ad-hoc signed, so the grant belongs to one build and is gone after an update (an ad hoc
    // signed code has a designated requirement tied to that specific version of the code;
    // sources: macos-apple-tn3127-requirements-20261119).
    private var runtimeSilentWithoutPermission = false
    private var expectedSystemRefreshUntilUptime: TimeInterval = 0

    override init() {
        super.init()
        hasPersistedGrantHistory = UserDefaults.standard.bool(forKey: Self.everGrantedKey)
        let initialState = Self.currentSystemAuthorizationState()
        observedSystemState = initialState
        if initialState == .granted {
            authorizationState = .granted
        } else if hasPersistedGrantHistory {
            authorizationState = .grantedNeedsReentry
        } else {
            authorizationState = initialState
        }
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshAuthorizationStatus()
        }
        streamWindowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let window = note.object as? NSWindow, PermissionAlertPresenter.isStreamWindow(window) else { return }
            // Let the stream window finish closing and the host list come back before a sheet goes on it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self?.presentPendingRuntimeAlertIfPossible()
            }
        }
    }

    deinit {
        if let didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(didBecomeActiveObserver)
        }
        if let streamWindowCloseObserver {
            NotificationCenter.default.removeObserver(streamWindowCloseObserver)
        }
    }

    @objc var isGranted: Bool {
        authorizationState == .granted || authorizationState == .grantedNeedsReentry
    }

    @objc var shouldAttemptRuntimeActivationWithoutPrompt: Bool {
        if isGranted {
            return true
        }

        if hasPersistedGrantHistory || UserDefaults.standard.bool(forKey: Self.everGrantedKey) {
            return true
        }

        return false
    }

    @objc var displayStatusLabelKey: String {
        if authorizationState == .unsupported {
            return "Unavailable"
        }
        if authorizationState == .grantedNeedsReentry {
            return "Granted Pending Reentry"
        }
        if authorizationState == .granted {
            return "Granted"
        }
        if isAwaitingSystemRefresh {
            return "Checking"
        }
        if shouldSuggestSettingsRepair {
            return "Check Settings"
        }
        switch authorizationState {
        case .notDetermined:
            return "Not Granted"
        case .denied:
            return "Denied"
        case .unsupported, .granted, .grantedNeedsReentry:
            return "Unavailable"
        }
    }

    @objc var statusLabelKey: String {
        displayStatusLabelKey
    }

    @objc var primaryActionTitleKey: String? {
        if authorizationState == .unsupported || authorizationState == .granted || authorizationState == .grantedNeedsReentry {
            return nil
        }
        if isAwaitingSystemRefresh || shouldSuggestSettingsRepair || authorizationState == .denied {
            return "Open Settings"
        }
        return "Request"
    }

    @objc var supplementalStatusMessageKey: String? {
        if authorizationState == .grantedNeedsReentry {
            return "Input Monitoring Reentry detail"
        }
        if isAwaitingSystemRefresh {
            return "Input Monitoring Checking detail"
        }
        if shouldSuggestSettingsRepair {
            return "Input Monitoring Repair detail"
        }
        return nil
    }

    @objc var rawFailureMessageForDisplay: String? {
        guard supplementalStatusMessageKey == nil,
              !lastFailureMessage.isEmpty,
              authorizationState != .granted,
              authorizationState != .grantedNeedsReentry
        else {
            return nil
        }
        return lastFailureMessage
    }

    @objc(refreshAuthorizationStatus)
    func refreshAuthorizationStatus() {
        let state = Self.currentSystemAuthorizationState()
        DispatchQueue.main.async {
            self.applySystemAuthorizationState(state)
        }
    }

    @discardableResult
    @objc(requestAuthorizationIfNeededInteractive:)
    func requestAuthorizationIfNeeded(interactive: Bool) -> Bool {
        let currentState = Self.currentSystemAuthorizationState()
        if currentState == .granted {
            DispatchQueue.main.async {
                self.applySystemAuthorizationState(.granted)
            }
            return true
        }

        guard interactive, #available(macOS 15.0, *) else {
            DispatchQueue.main.async {
                self.applySystemAuthorizationState(currentState)
            }
            return false
        }

        if Thread.isMainThread {
            return performInteractiveAuthorizationRequest()
        }

        var granted = false
        DispatchQueue.main.sync {
            granted = performInteractiveAuthorizationRequest()
        }
        return granted
    }

    @objc(requestAuthorizationWithCompletion:)
    func requestAuthorization(_ completion: ((Bool) -> Void)? = nil) {
        didAttemptAuthorizationThisSession = true
        beginWaitingForSystemRefresh()
        let granted = requestAuthorizationIfNeeded(interactive: true)
        scheduleAuthorizationRefreshes()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            self.refreshAuthorizationStatus()
            completion?(granted || self.isGranted)
        }
    }

    @objc(openSystemPreferences)
    func openSystemPreferences() {
        didAttemptAuthorizationThisSession = true
        beginWaitingForSystemRefresh()
        let candidateURLs = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent",
            "x-apple.systempreferences:com.apple.preference.security",
        ]

        for candidate in candidateURLs {
            guard let url = URL(string: candidate) else { continue }
            if NSWorkspace.shared.open(url) {
                return
            }
        }

        if let fallbackURL = URL(fileURLWithPath: "/System/Applications/System Settings.app", isDirectory: true) as URL? {
            NSWorkspace.shared.openApplication(
                at: fallbackURL,
                configuration: NSWorkspace.OpenConfiguration(),
                completionHandler: nil
            )
        }

        scheduleAuthorizationRefreshes()
    }

    /// CoreHID cannot be used because the system does not report Input Monitoring as allowed (the check said so when
    /// the driver started, or the stream found CoreHID silent while the pointer moved): show it as not allowed, with
    /// the repair hint. The user is told in an alert, once per launch, when they can expect CoreHID to work: they
    /// chose the CoreHID driver, tried to allow it in this session, or allowed Input Monitoring before (the grant
    /// went stale). Automatic mode with no history falls back quietly, as it always did.
    @objc(noteCoreHIDSilentWithoutPermissionWithMessage:userChoseCoreHID:)
    func noteCoreHIDSilentWithoutPermission(withMessage message: String, userChoseCoreHID: Bool) {
        DispatchQueue.main.async {
            let state = Self.currentSystemAuthorizationState()
            guard state != .granted, state != .unsupported, !self.hasRuntimeVerifiedGrantThisSession else {
                return
            }
            self.runtimeSilentWithoutPermission = true
            self.observedSystemState = state
            self.endWaitingForSystemRefresh()
            self.authorizationState = state
            self.lastFailureMessage = message
            // "Remove and add it again" is for a grant that went stale; a user who never allowed it needs "allow it".
            self.shouldSuggestSettingsRepair = self.hasPersistedGrantHistory || self.didAttemptAuthorizationThisSession
            if userChoseCoreHID || self.didAttemptAuthorizationThisSession || self.hasPersistedGrantHistory {
                self.runtimeAlertPending = true
                self.presentPendingRuntimeAlertIfPossible()
            }
        }
    }

    @objc(noteCoreHIDDidBecomeActive)
    func noteCoreHIDDidBecomeActive() {
        DispatchQueue.main.async {
            self.needsStreamReentry = false
            self.runtimeSilentWithoutPermission = false
            self.hasRuntimeVerifiedGrantThisSession = true
            self.markGrantObserved()
            self.observedSystemState = .granted
            self.authorizationState = .granted
            self.lastFailureMessage = ""
            self.hasShownRuntimeAlert = false
            self.shouldSuggestSettingsRepair = false
        }
    }

    // Direct Caps Lock can use a current grant even on macOS versions without CoreHID.
    @objc var hasCurrentSystemGrant: Bool { CoreHIDMouseDriver.currentListenAccess() == .granted }

    private static func currentSystemAuthorizationState() -> InputMonitoringAuthorizationState {
        guard #available(macOS 15.0, *) else { return .unsupported }
        switch CoreHIDMouseDriver.currentListenAccess() {
        case .granted: return .granted
        case .denied: return .denied
        case .unknown, .unchecked: return .notDetermined
        }
    }

    private var isAwaitingSystemRefresh: Bool {
        authorizationState != .granted &&
        authorizationState != .grantedNeedsReentry &&
        ProcessInfo.processInfo.systemUptime < expectedSystemRefreshUntilUptime
    }

    private func beginWaitingForSystemRefresh() {
        expectedSystemRefreshUntilUptime = max(
            expectedSystemRefreshUntilUptime,
            ProcessInfo.processInfo.systemUptime + Self.systemRefreshWindowSeconds
        )
        shouldSuggestSettingsRepair = false
        objectWillChange.send()
    }

    private func endWaitingForSystemRefresh() {
        if expectedSystemRefreshUntilUptime != 0 {
            expectedSystemRefreshUntilUptime = 0
            objectWillChange.send()
        }
    }

    private func markGrantObserved() {
        let alreadyPersisted = hasPersistedGrantHistory
            || UserDefaults.standard.bool(forKey: Self.everGrantedKey)
        hasPersistedGrantHistory = true
        if !alreadyPersisted {
            UserDefaults.standard.set(true, forKey: Self.everGrantedKey)
        }
        shouldSuggestSettingsRepair = false
        endWaitingForSystemRefresh()
    }

    private func updateRepairSuggestionIfNeeded(for state: InputMonitoringAuthorizationState) {
        guard state != .granted, state != .grantedNeedsReentry else {
            shouldSuggestSettingsRepair = false
            return
        }

        guard !isAwaitingSystemRefresh else {
            shouldSuggestSettingsRepair = false
            return
        }

        if hasPersistedGrantHistory || didAttemptAuthorizationThisSession {
            shouldSuggestSettingsRepair = true
        }
    }

    @available(macOS 15.0, *)
    private func performInteractiveAuthorizationRequest() -> Bool {
        isRequestingAuthorization = true
        NSApp.activate(ignoringOtherApps: true)
        let initialState = Self.currentSystemAuthorizationState()
        var grantedByRequest = false

        if !CGPreflightListenEventAccess() {
            grantedByRequest = CGRequestListenEventAccess() || grantedByRequest
        }

        let ioState = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        if ioState != kIOHIDAccessTypeGranted {
            grantedByRequest = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) || grantedByRequest
        }

        isRequestingAuthorization = false
        let finalState = Self.currentSystemAuthorizationState()
        if finalState == .granted || grantedByRequest {
            if initialState != .granted || grantedByRequest {
                needsStreamReentry = true
            }
            observedSystemState = .granted
            authorizationState = .grantedNeedsReentry
            lastFailureMessage = ""
            hasShownRuntimeAlert = false
            markGrantObserved()
            return true
        }

        applySystemAuthorizationState(finalState)
        return finalState == .granted
    }

    /// Shows the CoreHID-silent alert if one is waiting and no stream window is on screen. It is never run modally: see
    /// PermissionAlertPresenter. During a stream the user is told by the Input Monitoring state in Settings and, when
    /// the stream window closes, by this alert.
    private func presentPendingRuntimeAlertIfPossible() {
        guard runtimeAlertPending else { return }
        guard authorizationState != .granted,
              authorizationState != .grantedNeedsReentry,
              !hasShownRuntimeAlert
        else {
            runtimeAlertPending = false
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        configureInputMonitoringAlert(alert)
        let shown = PermissionAlertPresenter.presentWithoutBlocking(alert) { [weak self] response in
            if response == .alertFirstButtonReturn {
                self?.openSystemPreferences()
            }
        }
        if shown {
            hasShownRuntimeAlert = true
            runtimeAlertPending = false
        }
    }

    /// One text for both Input Monitoring alerts (the launch check and the CoreHID-silent stream).
    private func configureInputMonitoringAlert(_ alert: NSAlert) {
        alert.messageText = localized(
            "Input Monitoring Alert Title", fallback: "Moonlight Needs Input Monitoring to Enable CoreHID")
        alert.informativeText = localized(
            "Input Monitoring Alert Message",
            fallback: "Without it, the mouse uses the compatibility path. In System Settings > Privacy & Security > Input Monitoring, turn on Moonlight. If it is already on, turn it off and on again.")
        alert.addButton(withTitle: localized("Open System Settings", fallback: "Open System Settings"))
        alert.addButton(withTitle: localized("Later", fallback: "Later"))
    }

    private func localized(_ key: String, fallback: String) -> String {
        let value = LanguageManager.shared.localize(key)
        return value == key ? fallback : value
    }

    private func applySystemAuthorizationState(_ state: InputMonitoringAuthorizationState) {
        if state != .granted && state != .unsupported {
            if hasRuntimeVerifiedGrantThisSession {
                observedSystemState = .granted
                markGrantObserved()
                authorizationState = .granted
                lastFailureMessage = ""
                hasShownRuntimeAlert = false
                shouldSuggestSettingsRepair = false
                return
            }

            if !runtimeSilentWithoutPermission
                && (hasPersistedGrantHistory || UserDefaults.standard.bool(forKey: Self.everGrantedKey))
            {
                hasPersistedGrantHistory = true
                observedSystemState = state
                endWaitingForSystemRefresh()
                authorizationState = .grantedNeedsReentry
                lastFailureMessage = ""
                hasShownRuntimeAlert = false
                shouldSuggestSettingsRepair = false
                return
            }
        }

        let transitionedToGranted = observedSystemState != .granted && state == .granted
        observedSystemState = state

        if state == .granted {
            runtimeSilentWithoutPermission = false
            if transitionedToGranted {
                needsStreamReentry = true
            }
            markGrantObserved()
            authorizationState = needsStreamReentry ? .grantedNeedsReentry : .granted
            if !needsStreamReentry {
                lastFailureMessage = ""
                hasShownRuntimeAlert = false
            }
            return
        }

        needsStreamReentry = false
        authorizationState = state
        updateRepairSuggestionIfNeeded(for: state)
    }

    private func scheduleAuthorizationRefreshes() {
        let delays: [TimeInterval] = [0.35, 1.0, 2.0, 4.0, 8.0]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.refreshAuthorizationStatus()
            }
        }
    }
}

// MARK: - Check at launch

/// Input Monitoring is checked when the app starts, not only when a stream starts: CoreHID delivers nothing, and
/// says nothing, without it, and a grant made for an earlier build can stop matching after an update while the
/// switch in System Settings still shows on.
extension InputMonitoringPermissionManager {
    private static let launchPromptVersionKey = "inputMonitoring.launchPromptVersion"

    /// App version and build, the unit "once per version" is counted in.
    private static var launchBuildIdentity: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?[kCFBundleVersionKey as String] as? String ?? "0"
        return "\(version) (\(build))"
    }

    /// A stream would take mouse input from CoreHID: the profile of some host does, or the default profile does when
    /// there is no host yet. A host without a profile of its own follows the default.
    private static func settingsUseCoreHID() -> Bool {
        let hosts = (DataManager().getHosts() as? [TemporaryHost]) ?? []
        let hostIds = hosts.map { $0.uuid }.filter { !$0.isEmpty }
        if hostIds.isEmpty {
            return SettingsClass.shouldAllowCoreHIDMouse(for: SettingsModel.globalHostId)
        }
        return hostIds.contains { SettingsClass.shouldAllowCoreHIDMouse(for: $0) }
    }

    @objc(checkAtLaunch)
    func checkAtLaunch() {
        guard #available(macOS 15.0, *) else { return }

        let state = Self.currentSystemAuthorizationState()
        let access: InputMonitoringLaunchAccess
        switch state {
        case .granted, .grantedNeedsReentry: access = .granted
        case .notDetermined: access = .unknown
        case .denied, .unsupported: access = .denied
        }
        let everGranted = hasPersistedGrantHistory || UserDefaults.standard.bool(forKey: Self.everGrantedKey)
        let version = Self.launchBuildIdentity
        let usesCoreHID = Self.settingsUseCoreHID()
        let action = InputMonitoringLaunchRules.action(
            usesCoreHID: usesCoreHID,
            coreHIDSupported: true,
            access: access,
            everGranted: everGranted,
            promptedVersion: UserDefaults.standard.string(forKey: Self.launchPromptVersionKey),
            currentVersion: version)
        LogMessage(LOG_I, "[diag] Input Monitoring at launch: system=\(state.rawValue) everGranted=\(everGranted) action=\(action) "
            + "iohid=\(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent).rawValue) cgPreflight=\(CGPreflightListenEventAccess())")

        // The system says no, so the settings page must not read "granted, re-enter the stream" from an old grant: also
        // when the alert is not shown again (answered for this build).
        if usesCoreHID && access != .granted && action != .requestAccess {
            runtimeSilentWithoutPermission = true
            observedSystemState = state
            authorizationState = state
            shouldSuggestSettingsRepair = everGranted
        }

        switch action {
        case .nothing:
            break
        case .requestAccess:
            UserDefaults.standard.set(version, forKey: Self.launchPromptVersionKey)
            requestAuthorization(nil)
        case .showAlert:
            presentLaunchAlert(version: version)
        }
    }

#if MLC_CONCEPT_HARNESS
    /// The concept harness photographs the launch alert; it shows it on request, exactly as the launch check does.
    @objc func presentLaunchAlertForHarness() {
        presentLaunchAlert(version: "harness")
    }
#endif

    private func presentLaunchAlert(version: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        configureInputMonitoringAlert(alert)
        // Not shown when a stream has already started (or no window can take it): nothing is recorded, so the next
        // launch asks again.
        let shown = PermissionAlertPresenter.presentWithoutBlocking(alert) { [weak self] response in
            if response == .alertFirstButtonReturn {
                self?.openSystemPreferences()
            } else {
                UserDefaults.standard.set(version, forKey: Self.launchPromptVersionKey)
            }
        }
        if shown {
            hasShownRuntimeAlert = true
        }
    }
}
