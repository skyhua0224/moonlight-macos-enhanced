//
//  MicrophoneManager.swift
//  Moonlight for macOS
//
//  Manages microphone device enumeration, permission status, and input level metering.
//

import AVFoundation
import Combine
import CoreAudio
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
