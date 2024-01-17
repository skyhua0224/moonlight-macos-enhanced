//
//  Settings.swift
//  Moonlight for macOS
//
//  Created by Michael Kenny on 16/1/2024.
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

import Foundation

struct Settings {
    let resolution: CGSize
    let fps: Int
    let bitrate: Float
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
}
