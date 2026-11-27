//
//  AwdlHelperSetup.swift
//  Moonlight for macOS
//
//  The one question about the AWDL stability helper, asked before a stream starts and never during one: a short
//  explanation, then the system's administrator authorization. The answer is remembered, so the question does not come
//  back; a "Not Now", a cancelled dialog or a failed install never keeps the stream from starting.
//

import AppKit
import Foundation

@objc(AwdlHelperSetup)
final class AwdlHelperSetup: NSObject {
    /// Called when the user starts a stream, before the stream window opens. `proceed` runs on the main thread, exactly
    /// once, whatever happens here; the caller checks that its launch was not cancelled meanwhile.
    @objc(prepareForStreamThen:)
    static func prepareForStream(then proceed: @escaping () -> Void) {
        let manager = AwdlHelperManager.sharedManager
        manager.setupAction { action in
            guard action != .none else {
                proceed()
                return
            }
            present(action, manager: manager, proceed: proceed)
        }
    }

    private static func present(_ action: AwdlSetupAction, manager: AwdlHelperManager, proceed: @escaping () -> Void) {
        let language = LanguageManager.shared
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = language.localize("AWDL Setup Title")
        alert.informativeText = language.localize(action == .update ? "AWDL Update Message" : "AWDL Setup Message")
        alert.addButton(withTitle: language.localize(action == .update ? "Update" : "Authorize"))
        alert.addButton(withTitle: language.localize("Not Now"))

        // A sheet, not a modal session: a modal alert blocks the main queue the stream start runs on. With no window to
        // put it on (or a stream window up) nothing is asked and nothing is recorded: the stream starts as it is and the
        // question comes with the next one.
        let shown = PermissionAlertPresenter.presentWithoutBlocking(alert) { response in
            manager.noteSetupAnswered(action)
            guard response == .alertFirstButtonReturn else {
                proceed()
                return
            }
            manager.setUpHelper { _ in proceed() }
        }
        if !shown {
            proceed()
        }
    }
}
