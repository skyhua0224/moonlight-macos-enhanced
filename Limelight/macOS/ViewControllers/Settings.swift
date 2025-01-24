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
    let customResolution: CGSize?
    let fps: Int
    let customFps: CGFloat?
    let bitrate: Int
    let codec: Int
    let hdr: Bool
    let framePacing: Int
    let audioOnPC: Bool
    let volumeLevel: CGFloat?
    let multiController: Bool
    let swapABXYButtons: Bool
    let optimize: Bool
    
    let autoFullscreen: Bool
    let rumble: Bool
    let controllerDriver: Int
    let mouseDriver: Int
    
    let emulateGuide: Bool
    let appArtworkDimensions: CGSize?
    let dimNonHoveredArtwork: Bool
    
    static func getSettings(for key: String) -> Self? {
        if let data = UserDefaults.standard.data(forKey: SettingsClass.profileKey(for: key) ) {
            if let settings = (try? PropertyListDecoder().decode(Settings.self, from: data)) ?? nil {
                return settings
            }
        }
        
        return nil
    }
}

class SettingsClass: NSObject {
    static func profileKey(for hostId: String) -> String {
        let profileKey = "\(hostId)-moonlightSettings"
        
        return profileKey
    }

    @objc static func getSettings(for key: String) -> [String: Any]? {
        if let data = UserDefaults.standard.data(forKey: SettingsClass.profileKey(for: key)) {
            if let settings = (try? PropertyListDecoder().decode(Settings.self, from: data)) ?? nil {
                let objcSettings: [String: Any?] = [
                    "resolution": settings.resolution,
                    "customResolution": settings.customResolution,
                    "fps": settings.fps,
                    "customFps": settings.customFps,
                    "bitrate": settings.bitrate,
                    "codec": settings.codec,
                    "hdr": settings.hdr,
                    "framePacing": settings.framePacing,
                    "audioOnPC": settings.audioOnPC,
                    "volumeLevel": settings.volumeLevel,
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
    
    @objc static func loadMoonlightSettings(for key: String) {
        if let settings = Settings.getSettings(for: key) {
            let dataMan = DataManager()
            
            let dataResolutionWidth = settings.resolution == .zero ? settings.customResolution!.width : settings.resolution.width
            let dataResolutionHeight = settings.resolution == .zero ? settings.customResolution!.height : settings.resolution.height
            let dataFps = settings.fps == .zero ? Int(settings.customFps!) : settings.fps
            let dataBitrate = settings.bitrate
            let dataCodec = SettingsModel.getBool(from: settings.codec, in: SettingsModel.videoCodecs)
            
            // TODO: Add this back when VideoDecoderRenderer gets merged, with frame pacing setting check
//            let dataFramePacing = SettingsModel.getBool(from: settings.framePacing, in: SettingsModel.pacingOptions)
            
            dataMan.saveSettings(
                withBitrate: dataBitrate,
                framerate: dataFps,
                height: Int(dataResolutionHeight),
                width: Int(dataResolutionWidth),
                onscreenControls: 0,
                remote: false,
                optimizeGames: settings.optimize,
                multiController: settings.multiController,
                audioOnPC: settings.audioOnPC,
                useHevc: dataCodec,
                enableHdr: settings.hdr,
                btMouseSupport: false
            )
        }
    }
    
    @objc static func getHostUUID(from address: String) -> String? {
        if let hosts = DataManager().getHosts() as? [TemporaryHost] {
            if let matchingHost = hosts.first(where: { host in
                if let potentialAddress = host.localAddress {
                    return potentialAddress == address
                } else {
                    return false
                }
            }) {
                return matchingHost.uuid
            }
        }
        
        return nil
    }
    
    @objc static func autoFullscreen(for key: String) -> Bool {
        if let settings = Settings.getSettings(for: key) {
            return settings.autoFullscreen
        }
        
        return SettingsModel.defaultAutoFullscreen
    }
    
    @objc static func rumble(for key: String) -> Bool {
        if let settings = Settings.getSettings(for: key) {
            return settings.rumble
        }
        
        return SettingsModel.defaultRumble
    }
    
    @objc static func controllerDriver(for key: String) -> Int {
        if let settings = Settings.getSettings(for: key) {
            return settings.controllerDriver
        }
        
        return SettingsModel.getInt(from: SettingsModel.defaultControllerDriver, in: SettingsModel.controllerDrivers)
    }
    
    @objc static func mouseDriver(for key: String) -> Int {
        if let settings = Settings.getSettings(for: key) {
            return settings.mouseDriver
        }
        
        return SettingsModel.getInt(from: SettingsModel.defaultMouseDriver, in: SettingsModel.mouseDrivers)
    }
    
    @objc static func appArtworkDimensions(for key: String) -> CGSize {
        if let settings = Settings.getSettings(for: key) {
            if let dimensions = settings.appArtworkDimensions {
                return dimensions
            }
        }
        
        return CGSizeMake(300, 400)
    }
    
    @objc static func dimNonHoveredArtwork(for key: String) -> Bool {
        if let settings = Settings.getSettings(for: key) {
            return settings.dimNonHoveredArtwork
        }
        
        return SettingsModel.defaultDimNonHoveredArtwork
    }
    
    @objc static func volumeLevel(for key: String) -> CGFloat {
        if let settings = Settings.getSettings(for: key) {
            return settings.volumeLevel ?? SettingsModel.defaultVolumeLevel
        }
        
        return SettingsModel.defaultVolumeLevel
    }
}
