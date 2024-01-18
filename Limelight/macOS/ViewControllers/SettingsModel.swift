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

    static var resolutions: [CGSize] = [CGSizeMake(1280, 720), CGSizeMake(1920, 1080), CGSizeMake(2560, 1440), CGSizeMake(3840, 2160), .zero]
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
        if let settings = Settings.getSettings() {
            selectedResolution = settings.resolution
            customResWidth = Int(settings.customResolution.width)
            customResHeight = Int(settings.customResolution.height)
            selectedFps = settings.fps
            
            var bitrateIndex = 0
            for i in 0..<Self.bitrateSteps.count {
                if Float(settings.bitrate) <= Self.bitrateSteps[i] * 1000.0 {
                    bitrateIndex = i
                    break
                }
            }
            bitrateSliderValue = Float(bitrateIndex)
            
            selectedVideoCodec = Self.getString(from: settings.codec, in: Self.videoCodecs)
            hdr = settings.hdr
            selectedPacingOptions = Self.getString(from: settings.framePacing, in: Self.pacingOptions)
            
            audioOnPC = settings.audioOnPC
            
            selectedMultiControllerMode = Self.getString(from: settings.multiController, in: Self.multiControllerModes)
            swapButtons = settings.swapABXYButtons
            
            optimize = settings.optimize
            
            autoFullscreen = settings.autoFullscreen
            rumble = settings.rumble
            selectedControllerDriver = Self.getString(from: settings.controllerDriver, in: Self.controllerDrivers)
            selectedMouseDriver = Self.getString(from: settings.mouseDriver, in: Self.mouseDrivers)
            
            emulateGuide = settings.emulateGuide
            appArtworkWidth = Int(settings.appArtworkDimensions.width)
            appArtworkHeight = Int(settings.appArtworkDimensions.height)
            dimNonHoveredArtwork = settings.dimNonHoveredArtwork
        } else {
            selectedResolution = CGSizeMake(1280, 720)
            customResWidth = 0
            customResHeight = 0
            selectedFps = 60
            
            var bitrateIndex = 0
            for i in 0..<Self.bitrateSteps.count {
                if 10000.0 <= Self.bitrateSteps[i] * 1000.0 {
                    bitrateIndex = i
                    break
                }
            }
            bitrateSliderValue = Float(bitrateIndex)
            
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
            appArtworkWidth = 300
            appArtworkHeight = 400
            dimNonHoveredArtwork = true
        }        
    }
    
    func saveSettings() {
        let customResolution = CGSizeMake(CGFloat(customResWidth), CGFloat(customResHeight))
        let bitrate = Int(Self.bitrateSteps[Int(bitrateSliderValue)] * 1000)
        let codec = getInt(from: selectedVideoCodec, in: Self.videoCodecs)
        let framePacing = getInt(from: selectedPacingOptions, in: Self.pacingOptions)
        let multiController = getBool(from: selectedMultiControllerMode, in: Self.multiControllerModes)
        let controllerDriver = getInt(from: selectedControllerDriver, in: Self.controllerDrivers)
        let mouseDriver = getInt(from: selectedMouseDriver, in: Self.mouseDrivers)
        let appArtworkDimensions = CGSizeMake(CGFloat(appArtworkWidth), CGFloat(appArtworkHeight))

        let settings = Settings(
            resolution: selectedResolution,
            customResolution: customResolution,
            fps: selectedFps,
            bitrate: bitrate,
            codec: codec,
            hdr: hdr,
            framePacing: framePacing,
            audioOnPC: audioOnPC,
            multiController: multiController,
            swapABXYButtons: swapButtons,
            optimize: optimize,
            autoFullscreen: autoFullscreen,
            rumble: rumble,
            controllerDriver: controllerDriver,
            mouseDriver: mouseDriver,
            emulateGuide: emulateGuide,
            appArtworkDimensions: appArtworkDimensions,
            dimNonHoveredArtwork: dimNonHoveredArtwork
        )
        
        if let data = try? PropertyListEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: "moonlightSettings")
        }
        
        
        let dataMan = DataManager()
        
        let dataResolutionWidth = selectedResolution == .zero ? customResolution.width : selectedResolution.width
        let dataResolutionHeight = selectedResolution == .zero ? customResolution.height : selectedResolution.height
        let dataBitrate = Int(Self.bitrateSteps[Int(bitrateSliderValue)] * 1000)
        let dataCodec = getBool(from: selectedVideoCodec, in: Self.videoCodecs)
        
        // TODO: Add this back when VideoDecoderRenderer gets merged, with frame pacing setting check
        // let dataFramePacing = getBool(from: selectedPacingOptions, in: Self.pacingOptions)

        dataMan.saveSettings(
            withBitrate: dataBitrate,
            framerate: selectedFps,
            height: Int(dataResolutionHeight),
            width: Int(dataResolutionWidth),
            onscreenControls: 0,
            remote: false,
            optimizeGames: optimize,
            multiController: multiController,
            audioOnPC: audioOnPC, 
            useHevc: dataCodec,
            enableHdr: hdr,
            btMouseSupport: false
        )
    }

    func getInt(from selectedSetting: String, in settingsArray: [String]) -> Int {
        for (index, setting) in settingsArray.enumerated() {
            if setting == selectedSetting {
                return index
            }
        }
        
        return 0
    }

    static func getString(from settingInt: Int, in settingsArray: [String]) -> String {
        var settingString = settingsArray.first!
        for (index, setting) in settingsArray.enumerated() {
            if index == settingInt {
                settingString = setting
            }
        }
        
        return settingString
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
