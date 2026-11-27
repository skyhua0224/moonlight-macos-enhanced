//
//  AwdlHelperManager.swift
//  Moonlight for macOS
//
//  The AWDL stability helper: while a stream runs, awdl0 (the interface AirDrop, Handoff and Sidecar use) is turned off,
//  because its channel hopping makes Wi-Fi streams stutter. Turning it off takes root, so the app installs a small
//  helper as a launchd daemon once, with one administrator authorization. The rules are in AwdlHelperPolicy.swift; the
//  question before the first stream is in AwdlHelperSetup.swift.
//
//  Never an authorization prompt while a stream runs: a helper that is missing or too old leaves awdl0 alone.
//

import AppKit
import Combine
import CryptoKit
import Foundation
import Security

/// What the settings page and the welcome window show.
@objc enum AwdlHelperStatus: Int {
    /// Not looked at yet in this run.
    case checking = 0
    /// The helper answers and is current.
    case ready = 1
    /// Not installed: waiting for the authorization.
    case notSetUp = 2
    /// Installed, but older than this app or not answering: one authorization updates it.
    case needsUpdate = 3
    /// The last setup or session failed; `lastErrorMessage` says why.
    case failed = 4
    /// This Mac has no awdl0.
    case noInterface = 5
    /// This build cannot install the helper (sandboxed, or the helper is not bundled).
    case unsupported = 6
}

private enum AwdlInstallOutcome {
    case installed
    case cancelled
    case failed(String)
}

/// The real interface and helper behind the rules.
private final class AwdlRuntimeProbe: AwdlHelperProbing {
    func handshake() -> AwdlHelperHandshake {
        let answer = MLAwdlAuthorizationHelper.helperHandshake()
        return AwdlHelperHandshake(
            reachable: (answer["reachable"] as? NSNumber)?.boolValue ?? false,
            interfaceVersion: (answer["interfaceVersion"] as? NSNumber)?.intValue ?? 0,
            buildVersion: answer["buildVersion"] as? String ?? "",
            error: answer["error"] as? String ?? "")
    }

    var installedFilePresent: Bool {
        MLAwdlAuthorizationHelper.installedPrivilegedHelperFilePresent()
    }

    func interfaceSnapshot() -> AwdlInterfaceSnapshot {
        let result = AwdlRuntimeProbe.run("/sbin/ifconfig", ["awdl0"])
        guard result.status == 0 else { return AwdlInterfaceSnapshot(present: false, up: false) }
        let text = result.stdout
        let isUp: Bool
        if let open = text.range(of: "<"), let close = text.range(of: ">"), open.lowerBound < close.lowerBound {
            let flags = text[open.upperBound..<close.lowerBound].split(separator: ",").map(String.init)
            isUp = flags.contains("UP")
        } else {
            isUp = text.contains("UP")
        }
        return AwdlInterfaceSnapshot(present: true, up: isUp)
    }

    func holdDown() -> String? {
        var message: NSString?
        return MLAwdlAuthorizationHelper.holdAwdlDown(errorMessage: &message) ? nil : (message as String? ?? "")
    }

    func releaseHold() -> AwdlReleaseResult {
        var message: NSString?
        var stillHeld = ObjCBool(false)
        guard MLAwdlAuthorizationHelper.releaseAwdlHold(stillHeld: &stillHeld, errorMessage: &message) else {
            return .failed(message as String? ?? "")
        }
        return stillHeld.boolValue ? .stillHeld : .released
    }

    func forceUp() -> String? {
        var message: NSString?
        return MLAwdlAuthorizationHelper.bringAwdlUp(errorMessage: &message) ? nil : (message as String? ?? "")
    }

    func waitForInterface(up expectedUp: Bool) -> Bool {
        for attempt in 0..<20 {
            let state = interfaceSnapshot()
            if !state.present { return false }
            if state.up == expectedUp { return true }
            if attempt + 1 < 20 { usleep(50_000) }
        }
        return false
    }

    static func run(
        _ launchPath: String,
        _ arguments: [String],
        timeout: TimeInterval? = nil
    ) -> (status: Int32, stdout: String, stderr: String) {
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
                task.terminationHandler = { _ in waitSemaphore.signal() }
                if waitSemaphore.wait(timeout: .now() + timeout) == .timedOut {
                    if task.isRunning {
                        task.interrupt()
                        usleep(150_000)
                        if task.isRunning { task.terminate() }
                    }
                    return (-2, "", "Timed out after \(Int(timeout)) seconds")
                }
            } else {
                task.waitUntilExit()
            }
        } catch {
            return (-1, "", error.localizedDescription)
        }

        let stdoutText = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderrText = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (task.terminationStatus, stdoutText, stderrText)
    }
}

@objcMembers
final class AwdlHelperManager: NSObject, ObservableObject {
    @objc(sharedManager) static let sharedManager = AwdlHelperManager()

    @Published private(set) var status: AwdlHelperStatus = .checking
    /// Why the last setup or stream session failed; empty when nothing failed.
    @Published private(set) var lastErrorMessage: String = ""
    /// The system's authorization dialog is up, or the self-check is running.
    @Published private(set) var isWorking: Bool = false

    private static let installAnsweredKey = "networkCompatibility.awdlHelperSetupAnswered"
    private static let updatePromptedBuildKey = "networkCompatibility.awdlHelperUpdatePromptedBuild"
    /// Before the default-on release the marker was a UserDefaults flag.
    private static let legacyPendingRestoreKey = "networkCompatibility.awdlHelperPendingRestore"
    private static let helperSuffix = ".AwdlPrivilegedHelper"
    private static let helperFallbackLabel = "std.skyhua.MoonlightMacEnhanced.AwdlPrivilegedHelper"

    /// Everything that talks to the helper or changes awdl0 runs here, one at a time. Never held while the authorization
    /// dialog is up (that runs on `installQueue`), so a stream can still end and give awdl0 back.
    private let sessionQueue = DispatchQueue(label: "moonlight.awdl.helper")
    private let installQueue = DispatchQueue(label: "moonlight.awdl.helper.install")
    private let isSandboxedBuild = AwdlHelperManager.detectSandboxedBuild()
    private let probe = AwdlRuntimeProbe()
    private let engine: AwdlSessionEngine
    private var observers: [NSObjectProtocol] = []
    /// What the last look at the helper found; nil until the first one. Only touched on `sessionQueue`.
    private var lastLink: AwdlHelperLink?
    /// Why the last setup, check or session failed. Kept until something verifies the helper (a check or a stream that
    /// works), so that a handshake alone does not turn a failed state into an enabled one. Only on `sessionQueue`.
    private var failureMessage: String
    private let pendingMarker: AwdlPendingRestoreFile

    override init() {
        let marker = AwdlPendingRestoreFile(url: Self.pendingRestoreURL())
        // A hold left over from the build before this one.
        if UserDefaults.standard.bool(forKey: Self.legacyPendingRestoreKey) {
            marker.required = true
            if marker.required {
                UserDefaults.standard.removeObject(forKey: Self.legacyPendingRestoreKey)
            }
        }
        engine = AwdlSessionEngine(probe: probe, pending: marker) { message in
            LogMessage(LOG_I, message)
        }
        pendingMarker = marker
        failureMessage = ""
        super.init()

        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleApplicationWillTerminate()
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.handleWake()
        })

        // A crash or a force quit during a stream: the helper brought awdl0 back when it saw this process go, and the
        // marker is the second chance for the case that it could not.
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let outcome = self.engine.restorePending(reason: "launch")
            if outcome != .nothingPending {
                self.logInfo("[diag] AWDL helper restore at launch: \(outcome)")
            }
        }
        refreshAuthorizationStatus()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        MLAwdlAuthorizationHelper.invalidateSession()
    }

    // MARK: Logging

    private func logInfo(_ message: String) {
        LogMessage(LOG_I, message)
    }

    private func logWarning(_ message: String) {
        LogMessage(LOG_W, message)
    }

    // MARK: Facts

    private static func detectSandboxedBuild() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.security.app-sandbox" as CFString, nil)
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

    private static func pendingRestoreURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "std.skyhua.MoonlightMacEnhanced", isDirectory: true)
            .appendingPathComponent("awdl-restore-pending")
    }

    /// The build installs the helper itself: it is not sandboxed and carries a helper macOS accepts.
    var supportsPersistentHelperInstallation: Bool {
        !isSandboxedBuild && MLAwdlAuthorizationHelper.bundledPrivilegedHelperAvailable()
    }

    /// App version and build: what "once per build" counts in.
    static var currentBuildIdentity: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?[kCFBundleVersionKey as String] as? String ?? "0"
        return "\(version) (\(build))"
    }

    /// A Sidecar display is connected: it shows up among the screens under a name that carries "Sidecar" in every
    /// localisation Apple ships (the Chinese name is "Sidecar Display（隔空播放）"). The SidecarDisplayAgent process is
    /// no signal: once Sidecar has been used, macOS keeps the agent running and relaunches it within seconds after it
    /// is killed, with no Sidecar display connected (issue #134).
    static func sidecarSessionActive() -> Bool {
        NSScreen.screens.contains { $0.localizedName.localizedCaseInsensitiveContains("sidecar") }
    }

    static var settingEnabled: Bool {
        AwdlHelperDefault.isEnabled(
            stored: UserDefaults.standard.object(forKey: SettingsModel.awdlStabilityHelperEnabledKey) as? Bool)
    }

    /// Nothing has been set up yet and the user was not asked: what the welcome window offers on a first launch. Looks at
    /// files and the interface list only, so it can run on the main thread.
    var needsFirstSetup: Bool {
        Self.settingEnabled
            && supportsPersistentHelperInstallation
            && if_nametoindex("awdl0") != 0
            && !MLAwdlAuthorizationHelper.installedPrivilegedHelperFilePresent()
            && !UserDefaults.standard.bool(forKey: Self.installAnsweredKey)
    }

    // MARK: Status

    /// Looks at the helper again (a handshake, no prompt) and publishes the result.
    func refreshAuthorizationStatus() {
        sessionQueue.async {
            self.refreshLocked()
        }
    }

    private func refreshLocked() {
        let snapshot = probe.interfaceSnapshot()
        let status: AwdlHelperStatus
        if !snapshot.present {
            lastLink = nil
            status = .noInterface
        } else if !supportsPersistentHelperInstallation {
            lastLink = nil
            status = .unsupported
        } else {
            let link = AwdlHelperLink.evaluate(probe.handshake(), installedFilePresent: probe.installedFilePresent)
            lastLink = link
            status = statusLocked(for: link)
        }
        publish(status)
    }

    private func statusLocked(for link: AwdlHelperLink) -> AwdlHelperStatus {
        switch link {
        case .ready:
            return failureMessage.isEmpty ? .ready : .failed
        case .notInstalled:
            return failureMessage.isEmpty ? .notSetUp : .failed
        case .notRunning, .outdated:
            return failureMessage.isEmpty ? .needsUpdate : .failed
        }
    }

    private func publish(_ status: AwdlHelperStatus) {
        let message = failureMessage
        DispatchQueue.main.async {
            if self.status != status { self.status = status }
            if self.lastErrorMessage != message { self.lastErrorMessage = message }
        }
    }

    // MARK: Before a stream

    /// What the app should do about the helper before the next stream starts; `completion` runs on the main thread.
    /// Cached: the handshake happens at launch and after every change, not at every click.
    func setupAction(completion: @escaping (AwdlSetupAction) -> Void) {
        let sidecar = Self.sidecarSessionActive()
        let enabled = Self.settingEnabled
        sessionQueue.async {
            if self.lastLink == nil {
                self.refreshLocked()
            }
            let snapshot = self.probe.interfaceSnapshot()
            let action: AwdlSetupAction
            if let link = self.lastLink {
                action = AwdlSetupRules.action(
                    enabled: enabled,
                    supported: self.supportsPersistentHelperInstallation,
                    interfacePresent: snapshot.present,
                    sidecarActive: sidecar,
                    link: link,
                    record: Self.storedSetupRecord(),
                    currentBuild: Self.currentBuildIdentity)
            } else {
                action = .none
            }
            DispatchQueue.main.async { completion(action) }
        }
    }

    private static func storedSetupRecord() -> AwdlSetupRecord {
        AwdlSetupRecord(
            installAnswered: UserDefaults.standard.bool(forKey: installAnsweredKey),
            updatePromptedBuild: UserDefaults.standard.string(forKey: updatePromptedBuildKey))
    }

    /// The user answered the explanation (any button). Main thread.
    func noteSetupAnswered(_ action: AwdlSetupAction) {
        switch action {
        case .install:
            UserDefaults.standard.set(true, forKey: Self.installAnsweredKey)
        case .update:
            UserDefaults.standard.set(Self.currentBuildIdentity, forKey: Self.updatePromptedBuildKey)
        case .none:
            break
        }
    }

    /// The switch in the settings was changed. Turning it on is asking for the helper again.
    func settingChanged(enabled: Bool) {
        guard enabled else { return }
        UserDefaults.standard.removeObject(forKey: Self.installAnsweredKey)
        UserDefaults.standard.removeObject(forKey: Self.updatePromptedBuildKey)
        sessionQueue.async {
            self.failureMessage = ""
            self.refreshLocked()
        }
    }

    // MARK: Setup

    /// Installs or updates the helper (one administrator authorization), then checks it by turning awdl0 off and on.
    /// `completion` runs on the main thread with whether the helper is ready afterwards.
    func setUpHelper(_ completion: ((Bool) -> Void)? = nil) {
        DispatchQueue.main.async {
            self.isWorking = true
            // Asked for, from here or from the question before a stream: either way it is answered.
            self.noteSetupAnswered(.install)
            self.noteSetupAnswered(.update)
            NSApp.activate(ignoringOtherApps: true)
        }

        installQueue.async {
            self.logInfo("[diag] AWDL helper setup started")
            let outcome = self.performInstall()
            self.sessionQueue.async {
                var ready = false
                self.failureMessage = ""
                switch outcome {
                case .installed:
                    MLAwdlAuthorizationHelper.invalidateSession()
                    ready = self.runSelfCheckLocked()
                case .cancelled:
                    self.logInfo("[diag] AWDL helper setup cancelled by the user")
                    self.refreshLocked()
                case .failed(let message):
                    self.logWarning("[diag] AWDL helper setup failed: \(message)")
                    self.failureMessage = message
                    self.refreshLocked()
                }
                DispatchQueue.main.async {
                    self.isWorking = false
                    completion?(ready)
                }
            }
        }
    }

    /// What the button of a status row does. A current helper is checked again; one that is missing, not answering or
    /// older than the app is installed (the administrator authorization), which also checks it.
    func performPrimaryAction(_ completion: ((Bool) -> Void)? = nil) {
        switch status {
        case .notSetUp, .needsUpdate:
            setUpHelper(completion)
        case .failed:
            DispatchQueue.main.async { self.isWorking = true }
            sessionQueue.async {
                let link = AwdlHelperLink.evaluate(self.probe.handshake(), installedFilePresent: self.probe.installedFilePresent)
                if link == .ready {
                    let ready = self.runSelfCheckLocked()
                    DispatchQueue.main.async {
                        self.isWorking = false
                        completion?(ready)
                    }
                } else {
                    DispatchQueue.main.async {
                        self.isWorking = false
                        self.setUpHelper(completion)
                    }
                }
            }
        case .checking, .ready, .noInterface, .unsupported:
            completion?(status == .ready)
        }
    }

    /// Asked right before the check turns awdl0 off: no stream holds it, and no Sidecar display needs it. (The main
    /// thread waits for the session queue only for a bounded time at quit, so reading the screens from here is safe.)
    private func mayToggleNow() -> Bool {
        !engine.isActive && !DispatchQueue.main.sync { Self.sidecarSessionActive() }
    }

    /// Handshake, then awdl0 off and on again; the status says the result. A freshly installed helper needs a moment
    /// before launchd lets the app talk to it, so a helper that does not answer is asked again for a short while.
    private func runSelfCheckLocked() -> Bool {
        // awdl0 left down by an earlier check or run goes back up first, or this check would see it down and pass.
        _ = engine.restorePending(reason: "before-self-check")
        var outcome = AwdlSelfCheck.run(probe, allowToggle: self.mayToggleNow(), marker: pendingMarker)
        var attempts = 0
        while case .failed(.helperNotRunning) = outcome, attempts < 5 {
            attempts += 1
            usleep(400_000)
            MLAwdlAuthorizationHelper.invalidateSession()
            outcome = AwdlSelfCheck.run(probe, allowToggle: self.mayToggleNow(), marker: pendingMarker)
        }

        switch outcome {
        case .passed(let toggleVerified):
            logInfo("[diag] AWDL helper self-check passed: toggleVerified=\(toggleVerified ? 1 : 0)")
            failureMessage = ""
            lastLink = .ready
            publish(.ready)
            return true
        case .noInterface:
            logInfo("[diag] AWDL helper self-check skipped: awdl0 unavailable")
            failureMessage = ""
            publish(.noInterface)
            return false
        case .failed(let failure):
            var message = LanguageManager.shared.localize(failure.messageKey)
            if !failure.detail.isEmpty { message += " (\(failure.detail))" }
            logWarning("[diag] AWDL helper self-check failed: \(message)")
            failureMessage = message
            publish(.failed)
            return false
        }
    }

    /// Copies the bundled helper to /Library/PrivilegedHelperTools and loads it as a launchd daemon: the only step that
    /// asks for the administrator password, once.
    private func performInstall() -> AwdlInstallOutcome {
        guard !isSandboxedBuild else {
            return .failed(LanguageManager.shared.localize("AWDL helper cannot be installed in a sandboxed build"))
        }

        let bundledHelperPath = Self.bundledHelperPath()
        guard FileManager.default.isExecutableFile(atPath: bundledHelperPath) else {
            return .failed(LanguageManager.shared.localize("The bundled AWDL helper is missing from this build."))
        }
        guard MLAwdlAuthorizationHelper.bundledPrivilegedHelperHasUsableSignature() else {
            return .failed(LanguageManager.shared.localize("The bundled AWDL helper has no signature macOS accepts."))
        }
        // The bytes that passed the check. The script, running as root, compares what it installed with this digest, so
        // a file replaced while the dialog is up is not installed.
        guard let helperBytes = try? Data(contentsOf: URL(fileURLWithPath: bundledHelperPath)) else {
            return .failed(LanguageManager.shared.localize("The bundled AWDL helper is missing from this build."))
        }
        let helperDigest = SHA256.hash(data: helperBytes).map { String(format: "%02x", $0) }.joined()

        // No file is written for root to run: a script or plist in the user's temporary directory could be replaced while
        // the authorization dialog is up. The script and the plist go into the one command the dialog authorizes.
        let label = Self.helperLabel()
        let command = "/bin/sh -c " + shellQuote(makeInstallScript(
            helperSource: bundledHelperPath,
            helperDestination: Self.installedHelperPath(),
            plistContent: makeLaunchdPlist(label: label),
            plistDestination: Self.installedLaunchdPlistPath(),
            label: label,
            helperDigest: helperDigest))

        logInfo("[diag] AWDL helper install requesting administrator command")
        let prompt = LanguageManager.shared.localize("AWDL Helper Install Prompt")
        let appleScript =
            "do shell script \"\(Self.escapeForAppleScript(command))\" with prompt \"\(Self.escapeForAppleScript(prompt))\" with administrator privileges"
        let run = AwdlRuntimeProbe.run("/usr/bin/osascript", ["-e", appleScript], timeout: 120)
        let result = AwdlAdminPromptResult.classify(
            terminationStatus: run.status,
            output: run.stderr.isEmpty ? run.stdout : run.stderr)

        switch result {
        case .succeeded:
            logInfo("[diag] AWDL helper administrator command succeeded")
            return .installed
        case .cancelled:
            return .cancelled
        case .timedOut:
            return .failed(LanguageManager.shared.localize("Administrator authorization timed out. Please try again."))
        case .noResponse:
            return .failed(LanguageManager.shared.localize("No administrator authorization response was received. Please try again."))
        case .notAdministrator:
            return .failed(LanguageManager.shared.localize("Administrator authorization did not complete. Confirm that this account has administrator privileges and try again."))
        case .blocked:
            return .failed(LanguageManager.shared.localize("The system blocked the administrator authorization request."))
        case .failed(let message):
            return .failed(message)
        }
    }

    private func makeLaunchdPlist(label: String) -> String {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [Self.installedHelperPath()],
            "MachServices": [label: true],
            "RunAtLoad": true,
        ]
        let data = try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        // One line: the whole script is one AppleScript string.
        return String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\t", with: "")
    }

    private func makeInstallScript(
        helperSource: String, helperDestination: String, plistContent: String, plistDestination: String, label: String,
        helperDigest: String
    ) -> String {
        [
            "set -euo pipefail",
            "helper_src=\(shellQuote(helperSource))",
            "helper_dst=\(shellQuote(helperDestination))",
            "plist_dst=\(shellQuote(plistDestination))",
            "label=\(shellQuote(label))",
            "/bin/mkdir -p /Library/PrivilegedHelperTools /Library/LaunchDaemons",
            "/bin/launchctl bootout system \"$plist_dst\" >/dev/null 2>&1 || true",
            "/bin/rm -f \"$helper_dst\" \"$plist_dst\"",
            "/usr/bin/install -m 755 \"$helper_src\" \"$helper_dst\"",
            "/usr/sbin/chown root:wheel \"$helper_dst\"",
            "/bin/chmod 755 \"$helper_dst\"",
            "[ \"$(/usr/bin/shasum -a 256 \"$helper_dst\" | /usr/bin/awk '{print $1}')\" = \(shellQuote(helperDigest)) ] || { /bin/rm -f \"$helper_dst\"; exit 1; }",
            "/usr/bin/xattr -d com.apple.quarantine \"$helper_dst\" >/dev/null 2>&1 || true",
            "/usr/bin/printf '%s\\n' \(shellQuote(plistContent)) > \"$plist_dst\"",
            "/usr/sbin/chown root:wheel \"$plist_dst\"",
            "/bin/chmod 644 \"$plist_dst\"",
            "/bin/launchctl bootstrap system \"$plist_dst\"",
            "/bin/launchctl enable \"system/$label\" >/dev/null 2>&1 || true",
            "/bin/launchctl kickstart -k \"system/$label\" >/dev/null 2>&1 || true",
        ].joined(separator: "; ")
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func escapeForAppleScript(_ command: String) -> String {
        command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: Stream sessions

    @objc(beginStreamSessionIfEnabled:generation:ownerID:)
    func beginStreamSessionIfEnabled(_ enabled: Bool, generation: UInt, ownerID: String) {
        let sidecar = enabled && Self.sidecarSessionActive()
        sessionQueue.async {
            let result = self.engine.begin(enabled: enabled, sidecarActive: sidecar, generation: generation, ownerID: ownerID)
            switch result {
            case .disabled:
                self.logInfo("[diag] AWDL helper disabled for stream generation=\(generation)")
            case .sidecar:
                self.logInfo("[diag] AWDL helper skipped for stream generation=\(generation): a Sidecar display is connected and needs awdl0")
            case .noInterface:
                self.logInfo("[diag] AWDL helper found no awdl0 interface for generation=\(generation)")
                self.publish(.noInterface)
            case .alreadyDown:
                self.logInfo("[diag] AWDL helper found awdl0 already down for generation=\(generation)")
            case .helperNotReady(let link):
                // The stream goes on with awdl0 as it is; the settings page says what is missing.
                self.logInfo("[diag] AWDL helper not ready for generation=\(generation): \(link); awdl0 left as it is")
                if self.supportsPersistentHelperInstallation {
                    self.lastLink = link
                    self.publish(self.statusLocked(for: link))
                }
            case .holdFailed(let message):
                self.logWarning("[diag] AWDL helper activation failed for generation=\(generation) error=\(message)")
                self.failureMessage = message
                self.publish(.failed)
            case .active:
                self.logInfo("[diag] AWDL helper activated for generation=\(generation)")
                self.failureMessage = ""
                self.publish(.ready)
            }
        }
    }

    @objc(endStreamSessionForOwner:withReason:)
    func endStreamSession(forOwner ownerID: String?, withReason reason: String?) {
        sessionQueue.async {
            // Different controllers may reuse the same generation number. A late
            // termination or deinit must not restore a newer controller's session.
            let result = self.engine.end(forOwner: ownerID, reason: reason ?? "(unknown)")
            if case .restoreFailed(let message) = result {
                self.failureMessage = message
                self.publish(.failed)
            }
        }
    }

    private func handleApplicationWillTerminate() {
        // The helper gives awdl0 back when this process goes away and the marker file is the second chance, so a check
        // that waits on an unresponsive helper must not hold the quit up.
        let done = DispatchSemaphore(value: 0)
        sessionQueue.async {
            _ = self.engine.shutdown(reason: "app-will-terminate")
            done.signal()
        }
        _ = done.wait(timeout: .now() + 2)
    }

    private func handleWake() {
        sessionQueue.async {
            if self.engine.isActive {
                _ = self.engine.reassertIfActive(reason: "wake")
            } else {
                _ = self.engine.restorePending(reason: "wake")
            }
        }
    }
}

// MARK: - Text keys for the status

extension AwdlHelperManager {
    /// Key (Localizable.strings) of the short state shown in the settings page and the welcome window.
    var statusLabelKey: String {
        switch status {
        case .checking: return "Checking"
        case .ready: return "Enabled"
        case .notSetUp: return "Not Authorized"
        case .needsUpdate: return "Update Needed"
        case .failed: return "Failed"
        case .noInterface, .unsupported: return "Unavailable"
        }
    }

    /// Key of the button next to it, if there is something to do.
    var actionTitleKey: String? {
        switch status {
        case .notSetUp: return "Authorize"
        case .needsUpdate: return "Update"
        case .failed: return "Retry"
        case .checking, .ready, .noInterface, .unsupported: return nil
        }
    }
}
