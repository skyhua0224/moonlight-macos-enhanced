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
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &propAddr, 0, nil, &dataSize) == noErr
        else { return }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &propAddr, 0, nil, &dataSize, &deviceIDs)
            == noErr
        else { return }

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
                  bufSize > 0 else { continue }

            let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
            defer { bufferList.deallocate() }
            guard AudioObjectGetPropertyData(id, &inputScope, 0, nil, &bufSize, bufferList) == noErr
            else { continue }

            let inputChannels = UnsafeMutableAudioBufferListPointer(bufferList)
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
                let uid = uidRef?.takeUnretainedValue()
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
                let name = nameRef?.takeUnretainedValue()
            else { continue }

            result.append(MicrophoneDevice(
                id: id,
                uid: uid as String,
                name: name as String
            ))
        }

        DispatchQueue.main.async {
            self.devices = result
            // If selection invalid, clear it (will use system default)
            if !self.selectedDeviceUID.isEmpty,
               !result.contains(where: { $0.uid == self.selectedDeviceUID })
            {
                self.selectedDeviceUID = ""
            }
        }
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
            DispatchQueue.main.async {
                self?.refreshDevices()
            }
        }
        listenerBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &propAddr, DispatchQueue.main, block)
    }

    private func removeDeviceChangeListener() {
        guard let block = listenerBlock else { return }
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &propAddr, DispatchQueue.main, block)
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
    private var observedSystemState: InputMonitoringAuthorizationState = .notDetermined
    private var needsStreamReentry = false
    private var hasPersistedGrantHistory = false
    private var didAttemptAuthorizationThisSession = false
    private var shouldSuggestSettingsRepair = false
    private var expectedSystemRefreshUntilUptime: TimeInterval = 0

    override init() {
        super.init()
        hasPersistedGrantHistory = UserDefaults.standard.bool(forKey: Self.everGrantedKey)
        let initialState = Self.currentSystemAuthorizationState()
        observedSystemState = initialState
        authorizationState = initialState
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshAuthorizationStatus()
        }
    }

    deinit {
        if let didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(didBecomeActiveObserver)
        }
    }

    @objc var isGranted: Bool {
        authorizationState == .granted || authorizationState == .grantedNeedsReentry
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

    @objc(noteCoreHIDPermissionFailureWithMessage:)
    func noteCoreHIDPermissionFailure(withMessage message: String) {
        DispatchQueue.main.async {
            let state = Self.currentSystemAuthorizationState()
            self.applySystemAuthorizationState(state)
            if state == .granted {
                self.lastFailureMessage = ""
            } else {
                self.lastFailureMessage = message
                self.shouldSuggestSettingsRepair =
                    self.hasPersistedGrantHistory || self.didAttemptAuthorizationThisSession
                self.presentRuntimeAlertIfNeeded()
            }
        }
    }

    @objc(noteCoreHIDDidBecomeActive)
    func noteCoreHIDDidBecomeActive() {
        DispatchQueue.main.async {
            self.needsStreamReentry = false
            self.markGrantObserved()
            self.applySystemAuthorizationState(Self.currentSystemAuthorizationState())
        }
    }

    private static func currentSystemAuthorizationState() -> InputMonitoringAuthorizationState {
        guard #available(macOS 15.0, *) else {
            return .unsupported
        }

        let cgGranted = CGPreflightListenEventAccess()
        let ioState = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        if ioState == kIOHIDAccessTypeGranted || cgGranted {
            return .granted
        }
        if ioState == kIOHIDAccessTypeUnknown {
            return .notDetermined
        }
        return .denied
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

    private func presentRuntimeAlertIfNeeded() {
        guard authorizationState != .granted,
              authorizationState != .grantedNeedsReentry,
              !hasShownRuntimeAlert
        else { return }
        hasShownRuntimeAlert = true

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = localized("CoreHID Permission Required", fallback: "CoreHID Permission Required")
        alert.informativeText = localized(
            "CoreHID Permission Alert Message",
            fallback: "CoreHID needs Input Monitoring to deliver high-polling mouse input. Moonlight is currently using the compatibility path. Grant access in System Settings, then re-enter the stream."
        )
        alert.addButton(withTitle: localized("Open Input Monitoring", fallback: "Open Input Monitoring"))
        alert.addButton(withTitle: localized("Later", fallback: "Later"))
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openSystemPreferences()
        }
    }

    private func localized(_ key: String, fallback: String) -> String {
        let value = LanguageManager.shared.localize(key)
        return value == key ? fallback : value
    }

    private func applySystemAuthorizationState(_ state: InputMonitoringAuthorizationState) {
        let transitionedToGranted = observedSystemState != .granted && state == .granted
        observedSystemState = state

        if state == .granted {
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

@objc enum AwdlHelperAuthorizationState: Int {
    case notDetermined = 0
    case ready = 1
    case failed = 2
    case unavailable = 3
}

@objc enum AwdlHelperInstallState: Int {
    case unknown = 0
    case installed = 1
    case notReady = 2
    case adminPromptOnly = 3
    case unavailable = 4
}

@objc enum AwdlHelperExecutionPath: Int {
    case unknown = 0
    case privilegedHelper = 1
    case administratorPrompt = 2
}

private struct AwdlInterfaceState {
    let present: Bool
    let up: Bool
    let stderr: String
}

@objcMembers
final class AwdlHelperManager: NSObject, ObservableObject {
    @objc(sharedManager) static let sharedManager = AwdlHelperManager()

    @Published var authorizationState: AwdlHelperAuthorizationState = .notDetermined {
        didSet {
            UserDefaults.standard.set(authorizationState.rawValue, forKey: Self.authorizationStateKey)
        }
    }
    @Published var lastErrorMessage: String = "" {
        didSet {
            UserDefaults.standard.set(lastErrorMessage, forKey: Self.lastErrorMessageKey)
        }
    }
    @Published var helperInstallState: AwdlHelperInstallState = .unknown
    @Published var lastExecutionPath: AwdlHelperExecutionPath = .unknown
    @Published var supportsPersistentHelperInstallation: Bool = false
    @Published var isRequestingAuthorization: Bool = false

    private static let authorizationStateKey = "networkCompatibility.awdlHelperAuthorizationState"
    private static let lastErrorMessageKey = "networkCompatibility.awdlHelperLastErrorMessage"
    private static let pendingRestoreKey = "networkCompatibility.awdlHelperPendingRestore"
    private static let helperSuffix = ".AwdlPrivilegedHelper"
    private static let helperFallbackLabel = "std.skyhua.MoonlightMac.AwdlPrivilegedHelper"

    private let sessionQueue = DispatchQueue(label: "moonlight.awdl.helper")
    private let isSandboxedBuild = AwdlHelperManager.detectSandboxedBuild()
    private var appWillTerminateObserver: NSObjectProtocol?
    private var sessionGeneration: UInt = 0
    private var sessionEnabled = false
    private var interfacePresent = false
    private var originalInterfaceUp = false
    private var changedInterfaceState = false

    override init() {
        super.init()

        if UserDefaults.standard.object(forKey: Self.authorizationStateKey) != nil {
            authorizationState = AwdlHelperAuthorizationState(
                rawValue: UserDefaults.standard.integer(forKey: Self.authorizationStateKey)
            ) ?? .notDetermined
        }
        if let lastError = UserDefaults.standard.string(forKey: Self.lastErrorMessageKey) {
            lastErrorMessage = lastError
        }
        appWillTerminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleApplicationWillTerminate()
        }
        refreshAuthorizationStatus()
    }

    deinit {
        if let appWillTerminateObserver {
            NotificationCenter.default.removeObserver(appWillTerminateObserver)
        }
        MLAwdlAuthorizationHelper.invalidateSession()
    }

    private func logInfo(_ message: String) {
        LogMessage(LOG_I, message)
    }

    private func logWarning(_ message: String) {
        LogMessage(LOG_W, message)
    }

    private func publishHelperInstallState(_ state: AwdlHelperInstallState) {
        DispatchQueue.main.async {
            self.helperInstallState = state
        }
    }

    private func publishExecutionPath(_ path: AwdlHelperExecutionPath) {
        DispatchQueue.main.async {
            self.lastExecutionPath = path
        }
    }

    private func publishPersistentHelperSupport(_ supported: Bool) {
        DispatchQueue.main.async {
            self.supportsPersistentHelperInstallation = supported
        }
    }

    private func currentHelperInstallStateLocked(interfacePresent: Bool) -> AwdlHelperInstallState {
        guard interfacePresent else {
            return .unavailable
        }

        guard !isSandboxedBuild else {
            return .adminPromptOnly
        }

        guard MLAwdlAuthorizationHelper.bundledPrivilegedHelperAvailable() else {
            return .adminPromptOnly
        }

        guard MLAwdlAuthorizationHelper.installedPrivilegedHelperHasUsableSignature() else {
            return .notReady
        }

        if MLAwdlAuthorizationHelper.privilegedHelperLaunchdJobLoaded() {
            return .installed
        }

        return MLAwdlAuthorizationHelper.privilegedHelperInstalled() ? .installed : .notReady
    }

    private var pendingRestoreRequired: Bool {
        get { UserDefaults.standard.bool(forKey: Self.pendingRestoreKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.pendingRestoreKey) }
    }

    private static func detectSandboxedBuild() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                task,
                "com.apple.security.app-sandbox" as CFString,
                nil
              )
        else {
            return false
        }

        return (value as? Bool) ?? false
    }

    private static func helperLabel() -> String {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier, !bundleIdentifier.isEmpty else {
            return helperFallbackLabel
        }

        return bundleIdentifier + helperSuffix
    }

    private static func bundledHelperPath() -> String {
        Bundle.main.bundlePath + "/Contents/Library/LaunchServices/\(helperLabel())"
    }

    private static func installedHelperPath() -> String {
        "/Library/PrivilegedHelperTools/\(helperLabel())"
    }

    private static func installedLaunchdPlistPath() -> String {
        "/Library/LaunchDaemons/\(helperLabel()).plist"
    }

    func refreshAuthorizationStatus() {
        sessionQueue.async {
            let state = self.queryAwdlInterfaceState()
            let canInstallPersistentHelper = !self.isSandboxedBuild && MLAwdlAuthorizationHelper.bundledPrivilegedHelperAvailable()
            let installState = self.currentHelperInstallStateLocked(interfacePresent: state.present)
            if state.present && state.up && self.pendingRestoreRequired {
                self.pendingRestoreRequired = false
            }
            DispatchQueue.main.async {
                self.supportsPersistentHelperInstallation = canInstallPersistentHelper
                self.helperInstallState = installState
                if !state.present {
                    self.logInfo("[diag] AWDL helper status: awdl0 unavailable")
                    self.authorizationState = .unavailable
                    return
                }

                if self.authorizationState == .unavailable {
                    self.logInfo("[diag] AWDL helper status: awdl0 available")
                    self.authorizationState = .notDetermined
                }
            }
        }
    }

    func requestAuthorization(_ completion: ((Bool) -> Void)? = nil) {
        DispatchQueue.main.async {
            self.isRequestingAuthorization = true
            NSApp.activate(ignoringOtherApps: true)
        }

        sessionQueue.async {
            self.logInfo("[diag] AWDL helper authorization environment: sandbox=\(self.isSandboxedBuild ? 1 : 0)")
            self.logInfo("[diag] AWDL helper authorization request started")
            let result = self.performAuthorizationProbe()
            DispatchQueue.main.async {
                self.isRequestingAuthorization = false
                self.updateAuthorizationState(result.state, message: result.message)
                switch result.state {
                case .ready:
                    self.logInfo("[diag] AWDL helper authorization request succeeded")
                case .failed:
                    self.logWarning("[diag] AWDL helper authorization request failed: \(result.message)")
                case .unavailable:
                    self.logInfo("[diag] AWDL helper authorization request skipped: awdl0 unavailable")
                case .notDetermined:
                    self.logInfo("[diag] AWDL helper authorization request ended without state change")
                }
                completion?(result.state == .ready)
            }
        }
    }

    func installPersistentHelper(_ completion: ((Bool) -> Void)? = nil) {
        DispatchQueue.main.async {
            self.isRequestingAuthorization = true
            NSApp.activate(ignoringOtherApps: true)
        }

        sessionQueue.async {
            self.logInfo("[diag] AWDL persistent helper install started")
            let result = self.performPersistentHelperInstall()
            DispatchQueue.main.async {
                self.isRequestingAuthorization = false
                self.updateAuthorizationState(result.state, message: result.message)
                if result.state == .ready {
                    self.lastErrorMessage = ""
                    self.logInfo("[diag] AWDL persistent helper install succeeded")
                } else if !result.message.isEmpty {
                    self.logWarning("[diag] AWDL persistent helper install failed: \(result.message)")
                }
                self.refreshAuthorizationStatus()
                completion?(result.state == .ready)
            }
        }
    }

    @objc(beginStreamSessionIfEnabled:generation:)
    func beginStreamSessionIfEnabled(_ enabled: Bool, generation: UInt) {
        sessionQueue.async {
            self.restoreIfNeededLocked(reason: "superseded-by-new-stream")
            self.resetSessionStateLocked()

            if !enabled {
                self.logInfo("[diag] AWDL helper disabled for stream generation=\(generation)")
                return
            }

            self.sessionEnabled = true
            self.sessionGeneration = generation

            let state = self.queryAwdlInterfaceState()
            self.interfacePresent = state.present
            self.originalInterfaceUp = state.up

            if !self.interfacePresent {
                self.logInfo("[diag] AWDL helper found no awdl0 interface for generation=\(generation)")
                DispatchQueue.main.async {
                    self.updateAuthorizationState(.unavailable, message: "")
                }
                return
            }

            if self.pendingRestoreRequired {
                if state.up {
                    self.pendingRestoreRequired = false
                } else {
                    self.originalInterfaceUp = true
                    self.changedInterfaceState = true
                    self.logWarning("[diag] AWDL helper found pending restore from a previous unfinished stream; keeping awdl0 down for generation=\(generation)")
                    DispatchQueue.main.async {
                        self.updateAuthorizationState(.ready, message: "")
                    }
                    return
                }
            }

            if !self.originalInterfaceUp {
                self.logInfo("[diag] AWDL helper found awdl0 already down for generation=\(generation)")
                DispatchQueue.main.async {
                    self.updateAuthorizationState(.ready, message: "")
                }
                return
            }

            if let errorMessage = self.runPrivilegedIfconfigArgument("down") {
                self.logWarning("[diag] AWDL helper activation failed for generation=\(generation) error=\(errorMessage)")
                DispatchQueue.main.async {
                    self.updateAuthorizationState(.failed, message: errorMessage)
                }
                return
            }

            self.changedInterfaceState = true
            self.pendingRestoreRequired = true
            let changedState = self.queryAwdlInterfaceState()
            self.logInfo("[diag] AWDL helper activated for generation=\(generation)")
            self.logInfo("[diag] AWDL helper post-activation state: present=\(changedState.present ? 1 : 0) up=\(changedState.up ? 1 : 0)")
            DispatchQueue.main.async {
                self.updateAuthorizationState(.ready, message: "")
            }
        }
    }

    @objc(endStreamSessionWithReason:)
    func endStreamSession(withReason reason: String?) {
        sessionQueue.async {
            self.restoreIfNeededLocked(reason: reason ?? "(unknown)")
            self.resetSessionStateLocked()
        }
    }

    private func performAuthorizationProbe() -> (state: AwdlHelperAuthorizationState, message: String) {
        let state = queryAwdlInterfaceState()
        publishPersistentHelperSupport(!isSandboxedBuild && MLAwdlAuthorizationHelper.bundledPrivilegedHelperAvailable())
        publishHelperInstallState(currentHelperInstallStateLocked(interfacePresent: state.present))
        guard state.present else {
            return (.unavailable, "")
        }

        let originalUp = state.up
        if let error = runPrivilegedIfconfigArgument("down") {
            return (.failed, error)
        }

        if originalUp, let restoreError = runPrivilegedIfconfigArgument("up") {
            return (.failed, restoreError)
        }

        let finalState = queryAwdlInterfaceState()
        if originalUp && !finalState.up {
            return (.failed, "Failed to restore AWDL interface state.")
        }

        return (.ready, "")
    }

    private func performPersistentHelperInstall() -> (state: AwdlHelperAuthorizationState, message: String) {
        let interfaceState = queryAwdlInterfaceState()
        publishPersistentHelperSupport(!isSandboxedBuild && MLAwdlAuthorizationHelper.bundledPrivilegedHelperAvailable())
        guard interfaceState.present else {
            publishHelperInstallState(.unavailable)
            return (.unavailable, "")
        }

        guard !isSandboxedBuild else {
            publishHelperInstallState(.adminPromptOnly)
            return (.failed, "Persistent helper installation is unavailable in this sandboxed build.")
        }

        let bundledHelperPath = Self.bundledHelperPath()
        guard FileManager.default.isExecutableFile(atPath: bundledHelperPath) else {
            publishHelperInstallState(.adminPromptOnly)
            return (.failed, "The bundled AWDL helper is missing from this build.")
        }

        guard MLAwdlAuthorizationHelper.bundledPrivilegedHelperHasUsableSignature() else {
            publishHelperInstallState(.adminPromptOnly)
            return (.failed, "The bundled AWDL helper in this build is not signed in a way macOS accepts for persistent installation.")
        }

        let label = Self.helperLabel()
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let tempPlistURL = tempDirectory.appendingPathComponent("\(label).plist")
        let tempScriptURL = tempDirectory.appendingPathComponent("install-awdl-helper.sh")

        do {
            try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
            try makeLaunchdPlist(label: label).write(to: tempPlistURL, options: .atomic)
            try makeInstallScript().write(to: tempScriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tempScriptURL.path)
        } catch {
            publishHelperInstallState(.notReady)
            return (.failed, error.localizedDescription)
        }

        defer {
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        let command = [
            "/bin/sh",
            shellQuote(tempScriptURL.path),
            shellQuote(bundledHelperPath),
            shellQuote(Self.installedHelperPath()),
            shellQuote(tempPlistURL.path),
            shellQuote(Self.installedLaunchdPlistPath()),
            shellQuote(label),
        ].joined(separator: " ")

        logInfo("[diag] AWDL persistent helper install requesting administrator command")

        if let error = runAdministratorShellCommand(command) {
            publishHelperInstallState(.notReady)
            return (.failed, normalizedAuthorizationError(error))
        }

        MLAwdlAuthorizationHelper.invalidateSession()
        if MLAwdlAuthorizationHelper.privilegedHelperInstalled() {
            publishHelperInstallState(.installed)
            publishExecutionPath(.privilegedHelper)
            return (.ready, "")
        }

        publishHelperInstallState(.notReady)
        if !MLAwdlAuthorizationHelper.installedPrivilegedHelperHasUsableSignature() {
            return (.failed, "The helper was copied into /Library, but macOS blocked it from starting because the installed helper signature is not acceptable.")
        }

        return (.failed, "The persistent helper was installed but did not start correctly.")
    }

    private func updateAuthorizationState(_ state: AwdlHelperAuthorizationState, message: String) {
        authorizationState = state
        lastErrorMessage = message
    }

    private func normalizedAuthorizationError(_ message: String) -> String {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else {
            return isSandboxedBuild
                ? "没有收到管理员授权结果。当前这个构建的安全限制可能拦住了系统授权窗。"
                : "没有收到管理员授权结果，请重试。"
        }

        if trimmedMessage.contains("(-128)") {
            return "你已取消管理员授权。"
        }

        if trimmedMessage.localizedCaseInsensitiveContains("timed out") {
            return "管理员授权超时，请重试。"
        }

        if trimmedMessage.contains("(-60005)") {
            return isSandboxedBuild
                ? "系统没有正常弹出管理员授权窗口。当前这个构建的安全限制可能拦住了这类请求。"
                : "管理员授权没有完成，请确认当前账户有管理员权限后重试。"
        }

        if trimmedMessage.contains("(-10004)")
            || trimmedMessage.localizedCaseInsensitiveContains("not authorized")
            || trimmedMessage.localizedCaseInsensitiveContains("not permitted")
        {
            return "系统拦截了管理员授权请求。"
        }

        return trimmedMessage
    }

    private func awdlAuthorizationPrompt() -> String {
        let preferredLanguage = Locale.preferredLanguages.first ?? "en"
        let languageCode = preferredLanguage.hasPrefix("zh") ? "zh-Hans" : "en"
        let key = "AWDL Helper Authorization Prompt"

        if let path = Bundle.main.path(forResource: languageCode, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            let localized = NSLocalizedString(
                key,
                tableName: nil,
                bundle: bundle,
                value: "___MISSING___",
                comment: ""
            )
            if localized != "___MISSING___" {
                return localized
            }
        }

        return "Moonlight needs administrator permission to manage the AWDL interface while streaming."
    }

    private func awdlInstallPrompt() -> String {
        let preferredLanguage = Locale.preferredLanguages.first ?? "en"
        let languageCode = preferredLanguage.hasPrefix("zh") ? "zh-Hans" : "en"
        let key = "AWDL Helper Install Prompt"

        if let path = Bundle.main.path(forResource: languageCode, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            let localized = NSLocalizedString(
                key,
                tableName: nil,
                bundle: bundle,
                value: "___MISSING___",
                comment: ""
            )
            if localized != "___MISSING___" {
                return localized
            }
        }

        return "Moonlight needs administrator permission to install the AWDL helper."
    }

    private func makeLaunchdPlist(label: String) -> Data {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [Self.installedHelperPath()],
            "MachServices": [label: true],
            "RunAtLoad": true,
        ]

        return try! PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
    }

    private func makeInstallScript() -> String {
        """
        set -euo pipefail
        helper_src="$1"
        helper_dst="$2"
        plist_src="$3"
        plist_dst="$4"
        label="$5"

        /bin/mkdir -p /Library/PrivilegedHelperTools
        /bin/mkdir -p /Library/LaunchDaemons

        /bin/launchctl bootout system "$plist_dst" >/dev/null 2>&1 || true
        /bin/rm -f "$helper_dst" "$plist_dst"

        /usr/bin/install -m 755 "$helper_src" "$helper_dst"
        /usr/sbin/chown root:wheel "$helper_dst"
        /bin/chmod 755 "$helper_dst"
        /usr/bin/xattr -d com.apple.quarantine "$helper_dst" >/dev/null 2>&1 || true

        /usr/bin/install -m 644 "$plist_src" "$plist_dst"
        /usr/sbin/chown root:wheel "$plist_dst"
        /bin/chmod 644 "$plist_dst"

        /bin/launchctl bootstrap system "$plist_dst"
        /bin/launchctl enable "system/$label" >/dev/null 2>&1 || true
        /bin/launchctl kickstart -k "system/$label" >/dev/null 2>&1 || true
        """
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func runAdministratorShellCommand(_ command: String) -> String? {
        let prompt = awdlInstallPrompt()
        let promptPrefix = "with prompt \"\(Self.escapeForAppleScript(prompt))\""
        let appleScript =
            "do shell script \"\(Self.escapeForAppleScript(command))\" \(promptPrefix) with administrator privileges"

        if Thread.isMainThread {
            NSApp.activate(ignoringOtherApps: true)
        } else {
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
            }
        }

        let osascriptResult = runTask(
            launchPath: "/usr/bin/osascript",
            arguments: ["-e", appleScript],
            timeout: 120
        )
        if osascriptResult.terminationStatus == 0 {
            logInfo("[diag] AWDL persistent helper administrator command succeeded")
            return nil
        }

        let taskError = !osascriptResult.stderr.isEmpty ? osascriptResult.stderr : osascriptResult.stdout
        if !taskError.isEmpty {
            logWarning("[diag] AWDL persistent helper administrator command failed: \(taskError)")
        }
        return !taskError.isEmpty ? taskError : "Administrator authorization failed."
    }

    private func waitForInterfaceState(up expectedUp: Bool, attempts: Int = 20) -> Bool {
        for attempt in 0..<attempts {
            let state = queryAwdlInterfaceState()
            if !state.present {
                return false
            }
            if state.up == expectedUp {
                return true
            }
            if attempt + 1 < attempts {
                usleep(50_000)
            }
        }
        return false
    }

    private func runPrivilegedIfconfigViaAuthorizationHelper(_ argument: String) -> String? {
        let prompt = awdlAuthorizationPrompt()
        var errorMessage: NSString?
        let succeeded = MLAwdlAuthorizationHelper.runIfconfigArgument(
            argument,
            prompt: prompt,
            errorMessage: &errorMessage
        )
        guard succeeded else {
            return normalizedAuthorizationError((errorMessage as String?) ?? "Authorization failed.")
        }

        let expectedUp = (argument == "up")
        guard waitForInterfaceState(up: expectedUp) else {
            return expectedUp
                ? "Failed to restore AWDL interface state."
                : "Failed to disable AWDL interface."
        }

        return nil
    }

    private func runPrivilegedIfconfigViaAppleScript(_ argument: String) -> String? {
        let command = "/sbin/ifconfig awdl0 \(argument)"
        let appleScript = "do shell script \"\(Self.escapeForAppleScript(command))\" with administrator privileges"

        let executeAppleScript: () -> String? = {
            NSApp.activate(ignoringOtherApps: true)
            var error: NSDictionary?
            let script = NSAppleScript(source: appleScript)
            _ = script?.executeAndReturnError(&error)
            guard let error else { return nil }

            if let message = error[NSAppleScript.errorMessage] as? String, !message.isEmpty {
                return message
            }
            return error.description
        }

        let mainThreadError: String?
        if Thread.isMainThread {
            mainThreadError = executeAppleScript()
        } else {
            var result: String?
            DispatchQueue.main.sync {
                result = executeAppleScript()
            }
            mainThreadError = result
        }

        if let mainThreadError {
            logWarning("[diag] AWDL helper NSAppleScript request failed: \(mainThreadError)")
        } else {
            logInfo("[diag] AWDL helper NSAppleScript request succeeded")
            return nil
        }

        let osascriptResult = runTask(launchPath: "/usr/bin/osascript", arguments: ["-e", appleScript])
        if osascriptResult.terminationStatus == 0 {
            logInfo("[diag] AWDL helper osascript fallback succeeded")
            return nil
        }

        let taskError = !osascriptResult.stderr.isEmpty ? osascriptResult.stderr : osascriptResult.stdout
        if !taskError.isEmpty {
            logWarning("[diag] AWDL helper osascript fallback failed: \(taskError)")
        }

        return normalizedAuthorizationError(!taskError.isEmpty ? taskError : (mainThreadError ?? ""))
    }

    private func runTask(
        launchPath: String,
        arguments: [String],
        timeout: TimeInterval? = nil
    ) -> (terminationStatus: Int32, stdout: String, stderr: String) {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = arguments
        task.standardOutput = stdoutPipe
        task.standardError = stderrPipe

        do {
            try task.run()
            if let timeout, timeout > 0 {
                let waitSemaphore = DispatchSemaphore(value: 0)
                task.terminationHandler = { _ in
                    waitSemaphore.signal()
                }

                if waitSemaphore.wait(timeout: .now() + timeout) == .timedOut {
                    if task.isRunning {
                        task.interrupt()
                        usleep(150_000)
                        if task.isRunning {
                            task.terminate()
                        }
                    }
                    return (-2, "", "Timed out after \(Int(timeout)) seconds")
                }
            } else {
                task.waitUntilExit()
            }
        } catch {
            return (-1, "", error.localizedDescription)
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdoutText = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
        return (task.terminationStatus, stdoutText, stderrText)
    }

    private func queryAwdlInterfaceState() -> AwdlInterfaceState {
        let result = runTask(launchPath: "/sbin/ifconfig", arguments: ["awdl0"])
        guard result.terminationStatus == 0 else {
            return AwdlInterfaceState(present: false, up: false, stderr: result.stderr)
        }

        let stdoutText = result.stdout
        let isUp: Bool
        if let openRange = stdoutText.range(of: "<"),
           let closeRange = stdoutText.range(of: ">"),
           openRange.lowerBound < closeRange.lowerBound {
            let flagsString = String(stdoutText[openRange.upperBound..<closeRange.lowerBound])
            let flags = flagsString.split(separator: ",").map(String.init)
            isUp = flags.contains("UP")
        } else {
            isUp = stdoutText.contains("UP")
        }

        return AwdlInterfaceState(present: true, up: isUp, stderr: result.stderr)
    }

    private func runPrivilegedIfconfigArgument(_ argument: String) -> String? {
        let command = "/sbin/ifconfig awdl0 \(argument)"
        logInfo("[diag] AWDL helper requesting privileged command: \(command)")

        if !isSandboxedBuild {
            let hasBundledHelper = MLAwdlAuthorizationHelper.bundledPrivilegedHelperAvailable()
            if let helperError = runPrivilegedIfconfigViaAuthorizationHelper(argument) {
                logWarning("[diag] AWDL privileged helper request failed: \(helperError)")
                publishHelperInstallState(hasBundledHelper ? .notReady : .adminPromptOnly)
                if hasBundledHelper {
                    logInfo("[diag] AWDL helper falling back to administrator command prompt")
                    if let fallbackError = runPrivilegedIfconfigViaAppleScript(argument) {
                        publishExecutionPath(.administratorPrompt)
                        return fallbackError
                    }
                    publishExecutionPath(.administratorPrompt)
                    return nil
                }
                publishExecutionPath(.administratorPrompt)
                return helperError
            }
            logInfo("[diag] AWDL privileged helper request succeeded")
            publishHelperInstallState(.installed)
            publishExecutionPath(.privilegedHelper)
            return nil
        }

        let result = runPrivilegedIfconfigViaAppleScript(argument)
        publishHelperInstallState(.adminPromptOnly)
        publishExecutionPath(.administratorPrompt)
        return result
    }

    private static func escapeForAppleScript(_ command: String) -> String {
        command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func resetSessionStateLocked() {
        sessionEnabled = false
        interfacePresent = false
        originalInterfaceUp = false
        changedInterfaceState = false
        sessionGeneration = 0
    }

    private func restoreIfNeededLocked(reason: String) {
        guard sessionEnabled, interfacePresent, originalInterfaceUp, changedInterfaceState else {
            return
        }

        if let errorMessage = runPrivilegedIfconfigArgument("up") {
            logWarning("[diag] AWDL helper failed to restore pre-stream state: reason=\(reason) error=\(errorMessage)")
            DispatchQueue.main.async {
                self.updateAuthorizationState(.failed, message: errorMessage)
            }
            return
        }

        let restoredState = queryAwdlInterfaceState()
        pendingRestoreRequired = false
        logInfo("[diag] AWDL helper restored pre-stream state: reason=\(reason)")
        logInfo("[diag] AWDL helper restored state: present=\(restoredState.present ? 1 : 0) up=\(restoredState.up ? 1 : 0)")
        DispatchQueue.main.async {
            self.updateAuthorizationState(.ready, message: "")
        }
    }

    private func handleApplicationWillTerminate() {
        sessionQueue.sync {
            self.restoreIfNeededLocked(reason: "app-will-terminate")
            self.resetSessionStateLocked()
        }
    }
}
