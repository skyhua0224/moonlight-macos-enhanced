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
    
    static func getSettings() -> Self? {
        if let data = UserDefaults.standard.data(forKey: "moonlightSettings") {
            if let settings = (try? PropertyListDecoder().decode(Settings.self, from: data)) ?? nil {
                return settings
            }
        }
        
        return nil
    }
}

class SettingsClass: NSObject {
    @objc static func getSettings() -> [String: Any]? {
        if let data = UserDefaults.standard.data(forKey: "moonlightSettings") {
            if let settings = (try? PropertyListDecoder().decode(Settings.self, from: data)) ?? nil {
                let objcSettings : [String:Any] = [
                    "resolution": settings.resolution,
                    "customResolution": settings.customResolution,
                    "fps": settings.fps,
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
    
    @objc static func autoFullscreen() -> Bool {
        if let settings = Settings.getSettings() {
            return settings.autoFullscreen
        }
        
        return true
    }
    
    @objc static func rumble() -> Bool {
        if let settings = Settings.getSettings() {
            return settings.rumble
        }
        
        return true
    }
    
    @objc static func controllerDriver() -> Int {
        if let settings = Settings.getSettings() {
            return settings.controllerDriver
        }
        
        return 0
    }
    
    @objc static func mouseDriver() -> Int {
        if let settings = Settings.getSettings() {
            return settings.mouseDriver
        }
        
        return 0
    }
    
    @objc static func appArtworkDimensions() -> CGSize {
        if let settings = Settings.getSettings() {
            return settings.appArtworkDimensions
        }
        
        return CGSizeMake(300, 400)
    }
    
    @objc static func dimNonHoveredArtwork() -> Bool {
        if let settings = Settings.getSettings() {
            return settings.dimNonHoveredArtwork
        }
        
        return true
    }
}
