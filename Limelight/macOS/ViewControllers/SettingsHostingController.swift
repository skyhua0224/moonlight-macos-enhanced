//
//  SettingsHostingController.swift
//  Moonlight for macOS
//
//  Created by Michael Kenny on 15/1/2024.
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

import Cocoa
import SwiftUI
import Combine

class SettingsHostingController<RootView: View>: NSWindowController {
    convenience init(rootView: RootView) {
        let hostingController = NSHostingController(rootView: rootView)
        
        let window = NSWindow(contentViewController: hostingController)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.collectionBehavior = [.fullScreenNone]
        window.title = "Settings"
        
        self.init(window: window)
    }
}

@objc class SettingsWindowObjCBridge: NSView {
    @objc class func makeSettingsWindow() -> NSWindowController {
        SettingsHostingController(rootView: SettingsView())
    }
}
