//
//  SettingsModel.swift
//  Moonlight SwiftUI
//
//  Created by Michael Kenny on 25/1/2023.
//  Copyright © 2023 Moonlight Game Streaming Project. All rights reserved.
//

import SwiftUI

class SettingsModel: ObservableObject {
    var resolutionChangedCallback: (() -> Void)?
    
    @Published var selectedResolution: CGSize {
        didSet {
            saveSettings()
            resolutionChangedCallback?()
        }
    }
    @Published var selectedFps: Int {
        didSet {
            saveSettings()
        }
    }
    @Published var customResWidth: Int {
        didSet {
            saveSettings()
        }
    }
    @Published var customResHeight: Int {
        didSet {
            saveSettings()
        }
    }
    @Published var bitrateSliderValue: Float {
        didSet {
            saveSettings()
        }
    }
    @Published var selectedVideoCodec: String {
        didSet {
            saveSettings()
        }
    }
    @Published var hdr: Bool {
        didSet {
            saveSettings()
        }
    }
    @Published var selectedPacingOptions: String {
        didSet {
            saveSettings()
        }
    }
    @Published var audioOnPC: Bool {
        didSet {
            saveSettings()
        }
    }
    @Published var selectedMultiControllerMode: String {
        didSet {
            saveSettings()
        }
    }
    @Published var swapButtons: Bool {
        didSet {
            saveSettings()
        }
    }
    @Published var optimize: Bool {
        didSet {
            saveSettings()
        }
    }
    
    @Published var autoFullscreen: Bool {
        didSet {
            saveSettings()
        }
    }
    @Published var rumble: Bool {
        didSet {
            saveSettings()
        }
    }
    @Published var selectedControllerDriver: String {
        didSet {
            saveSettings()
        }
    }
    @Published var selectedMouseDriver: String {
        didSet {
            saveSettings()
        }
    }

    @Published var emulateGuide: Bool {
        didSet {
            saveSettings()
        }
    }
    @Published var appArtworkWidth: Int {
        didSet {
            saveSettings()
        }
    }
    @Published var appArtworkHeight: Int {
        didSet {
            saveSettings()
        }
    }
    @Published var dimNonHoveredArtwork: Bool {
        didSet {
            saveSettings()
        }
    }

    static var resolutions: [CGSize] = [CGSizeMake(640, 360), CGSizeMake(1280, 720), CGSizeMake(1920, 1080), CGSizeMake(2560, 1440), CGSizeMake(3840, 2160), .zero]
    static var fpss: [Int] = [30, 60, 90, 120, 144]
    static var bitrateSteps: [Float] = [
        0.5,
        1,
        1.5,
        2,
        2.5,
        3,
        4,
        5,
        6,
        7,
        8,
        9,
        10,
        12,
        15,
        18,
        20,
        25,
        30,
        40,
        50,
        60,
        70,
        80,
        90,
        100,
        120,
        150
    ]
    static var videoCodecs: [String] = ["H.264", "H.265"]
    static var pacingOptions: [String] = ["Lowest Latency", "Smoothest Video"]
    static var multiControllerModes: [String] = ["Single", "Auto"]

    static var controllerDrivers: [String] = ["HID", "MFi"]
    static var mouseDrivers: [String] = ["HID", "MFi"]

    init() {
        if let settings = DataManager().getSettings() {
            selectedResolution = CGSizeMake(CGFloat(truncating: settings.width), CGFloat(truncating: settings.height))
            customResWidth = 0
            customResHeight = 0
            selectedFps = settings.framerate.intValue
            
            var bitrateIndex = 0
            for i in 0..<Self.bitrateSteps.count {
                if settings.bitrate.floatValue <= Self.bitrateSteps[i] * 1000.0 {
                    bitrateIndex = i
                    break
                }
            }
            bitrateSliderValue = Float(bitrateIndex)
            
            selectedVideoCodec = Self.getString(from: settings.useHevc, in: Self.videoCodecs)
            hdr = settings.enableHdr
            selectedPacingOptions = "Smoothest Video" // Self.getString(from: settings.useFramePacing, in: Self.pacingOptions)

            audioOnPC = settings.playAudioOnPC

            selectedMultiControllerMode = Self.getString(from: settings.multiController, in: Self.multiControllerModes)
            swapButtons = false // settings.swapABXYButtons
            
            optimize = settings.optimizeGames
            
            autoFullscreen = true
            rumble = true
            selectedControllerDriver = "HID"
            selectedMouseDriver = "HID"
            
            emulateGuide = false
            appArtworkWidth = 600
            appArtworkHeight = 900
            dimNonHoveredArtwork = true
        } else {
            selectedResolution = CGSizeMake(1280, 720)
            customResWidth = 0
            customResHeight = 0
            selectedFps = 60
            bitrateSliderValue = 10

            selectedVideoCodec = "H.264"
            hdr = false
            selectedPacingOptions = "Smoothest Video"

            audioOnPC = false

            selectedMultiControllerMode = "Auto"
            swapButtons = false

            optimize = false
            
            autoFullscreen = true
            rumble = true
            selectedControllerDriver = "HID"
            selectedMouseDriver = "HID"
            
            emulateGuide = false
            appArtworkWidth = 600
            appArtworkHeight = 900
            dimNonHoveredArtwork = true
        }
    }
    
    func saveSettings() {
        let dataMan = DataManager()
        
        let bitrate = Int(Self.bitrateSteps[Int(bitrateSliderValue)] * 1000)
        
        let multiController = getBool(from: selectedMultiControllerMode, in: Self.multiControllerModes)
        let hevc = getBool(from: selectedVideoCodec, in: Self.videoCodecs)
        let framePacing = getBool(from: selectedPacingOptions, in: Self.pacingOptions)
        
        dataMan.saveSettings(withBitrate: bitrate, framerate: selectedFps, height: Int(selectedResolution.height), width: Int(selectedResolution.width), onscreenControls: 0, remote: false, optimizeGames: optimize, multiController: multiController, audioOnPC: audioOnPC, useHevc: hevc, enableHdr: hdr, btMouseSupport: false)
    }
    
    func getBool(from selectedSetting: String, in settingsArray: [String]) -> Bool {
        selectedSetting == settingsArray.last
    }
    
    static func getString(from settingBool: Bool, in settingsArray: [String]) -> String {
        var settingString = settingsArray.first!
        for (index, setting) in settingsArray.enumerated() {
            let indexBool = index == 1
            if indexBool == settingBool {
                settingString = setting
            }
        }
        
        return settingString
    }
}
