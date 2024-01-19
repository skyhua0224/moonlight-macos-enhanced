//
//  Settings.swift
//  Moonlight for macOS
//
//  Created by Michael Kenny on 16/1/2024.
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

import SwiftUI

struct Settings: Encodable, Decodable {
    let resolution: CGSize
    let customResolution: CGSize
    let fps: Int
    let customFps: Int
    let bitrate: Int
    let codec: Int
    let hdr: Bool
    let framePacing: Int
    let audioOnPC: Bool
    let multiController: Bool
    let swapABXYButtons: Bool
    let optimize: Bool
    
    let autoFullscreen: Bool
    let rumble: Bool
    let controllerDriver: Int
    let mouseDriver: Int
    
    let emulateGuide: Bool
    let appArtworkDimensions: CGSize
    let dimNonHoveredArtwork: Bool
    
    static func getSettings(for key: String) -> Self? {
        if let data = UserDefaults.standard.data(forKey: key) {
            if let settings = (try? PropertyListDecoder().decode(Settings.self, from: data)) ?? nil {
                return settings
            }
        }
        
        return nil
    }
}

class SettingsClass: NSObject {
    @objc static func getSettings(for key: String) -> [String: Any]? {
        if let data = UserDefaults.standard.data(forKey: key) {
            if let settings = (try? PropertyListDecoder().decode(Settings.self, from: data)) ?? nil {
                let objcSettings : [String:Any] = [
                    "resolution": settings.resolution,
                    "customResolution": settings.customResolution,
                    "fps": settings.fps,
                    "customFps": settings.customFps,
                    "bitrate": settings.bitrate,
                    "codec": settings.codec,
                    "hdr": settings.hdr,
                    "framePacing": settings.framePacing,
                    "audioOnPC": settings.audioOnPC,
                    "multiController": settings.multiController,
                    "swapABXYButtons": settings.swapABXYButtons,
                    "optimize": settings.optimize,
                    "autoFullscreen": settings.autoFullscreen,
                    "rumble": settings.rumble,
                    "controllerDriver": settings.controllerDriver,
                    "mouseDriver": settings.mouseDriver,
                    "emulateGuide": settings.emulateGuide,
                    "appArtworkDimensions": settings.appArtworkDimensions,
                    "dimNonHoveredArtwork": settings.dimNonHoveredArtwork
                ]
                
                return objcSettings
            }
        }
        
        return nil
    }
    
    @objc static func autoFullscreen(for key: String) -> Bool {
        if let settings = Settings.getSettings(for: key) {
            return settings.autoFullscreen
        }
        
        return true
    }
    
    @objc static func rumble(for key: String) -> Bool {
        if let settings = Settings.getSettings(for: key) {
            return settings.rumble
        }
        
        return true
    }
    
    @objc static func controllerDriver(for key: String) -> Int {
        if let settings = Settings.getSettings(for: key) {
            return settings.controllerDriver
        }
        
        return 0
    }
    
    @objc static func mouseDriver(for key: String) -> Int {
        if let settings = Settings.getSettings(for: key) {
            return settings.mouseDriver
        }
        
        return 0
    }
    
    @objc static func appArtworkDimensions(for key: String) -> CGSize {
        if let settings = Settings.getSettings(for: key) {
            return settings.appArtworkDimensions
        }
        
        return CGSizeMake(300, 400)
    }
    
    @objc static func dimNonHoveredArtwork(for key: String) -> Bool {
        if let settings = Settings.getSettings(for: key) {
            return settings.dimNonHoveredArtwork
        }
        
        return true
    }
}
