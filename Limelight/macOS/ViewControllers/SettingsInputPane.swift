import GameController
import SwiftUI

enum InputScope {
  case all
  case controller
  case keyboardMouse
  case usb
}

struct InputView: View {
  let scope: InputScope
  @EnvironmentObject private var settingsModel: SettingsModel
  @StateObject private var remoteUSB = RemoteUSBForwardingViewModel()
  @AppStorage("settings.usb.mappingEnabled") private var usbMappingEnabled = true

  init(scope: InputScope = .all) {
    self.scope = scope
  }

  var body: some View {
    Group {
      if scope == .usb {
        USBMappingView()
      } else {
        SettingsContent {
          if scope == .all || scope == .controller {
            SettingsPageHero(
              title: "Controller",
              subtitle: "Controller settings subtitle",
              symbol: "gamecontroller.fill",
              tint: .purple
            )
            ControllerSettingsSection()
          }
          if scope == .all || scope == .keyboardMouse {
            SettingsPageHero(
              title: "Keyboard & Mouse",
              subtitle: "Keyboard and mouse settings subtitle",
              symbol: "keyboard.fill",
              tint: .blue
            )
            KeyboardMouseSettingsSection()
            MouseTuningSettingsSection()
            FormSection(title: "Shortcut Translation Rules") {
              KeyboardTranslationRulesView(settingsModel: settingsModel)
            }
            FormSection(title: "Stream Shortcuts") {
              ShortcutReferenceView(settingsModel: settingsModel)
            }
          }
          if scope == .all {
            USBSettingsSection(remoteUSB: remoteUSB, mappingEnabled: $usbMappingEnabled)
          }
        }
      }
    }
    .onAppear {
      if scope != .usb && scope == .all && usbMappingEnabled {
        remoteUSB.refresh(host: settingsModel.selectedHost)
      }
    }
    .onChange(of: usbMappingEnabled) { enabled in
      if enabled {
        remoteUSB.refresh(host: settingsModel.selectedHost)
      } else {
        remoteUSB.stop()
      }
    }
  }
}

private struct ControllerSettingsSection: View {
  @EnvironmentObject private var settingsModel: SettingsModel
  @ObservedObject private var languageManager = LanguageManager.shared

  /// Builds controller settings bound to the active profile, including background input.
  /// Preference edits flow through SettingsModel persistence and live-change notifications.
  var body: some View {
    FormSection(title: "Controller") {
      SettingsRow(title: "Controller Driver") {
        Picker("", selection: $settingsModel.selectedControllerDriver) {
          ForEach(SettingsModel.controllerDrivers, id: \.self) { value in
            Text(languageManager.localize(value)).tag(value)
          }
        }
        .labelsHidden()
        .frame(width: 170, alignment: .trailing)
      }

      SettingsRow(title: "Controller Count") {
        Picker("", selection: $settingsModel.selectedMultiControllerMode) {
          ForEach(SettingsModel.multiControllerModes, id: \.self) { value in
            Text(languageManager.localize(value)).tag(value)
          }
        }
        .labelsHidden()
        .frame(width: 160, alignment: .trailing)
      }

      ToggleCell(title: "Rumble", boolBinding: $settingsModel.rumble)
      ToggleCell(
        title: "Background Controller Input",
        hintKey: "Background Controller Input detail",
        boolBinding: $settingsModel.backgroundControllerInput
      )
      ToggleCell(title: "Swap Buttons", boolBinding: $settingsModel.swapButtons)
      SettingsRow(title: "DualSense Touchpad Mode", detail: "Native Touchpad detail") {
        Picker("", selection: Binding<String>(
          get: { settingsModel.nativeTouchpad ? "Host Touchpad" : "Mac-style Trackpad" },
          set: { settingsModel.nativeTouchpad = ($0 == "Host Touchpad") }
        )) {
          Text(languageManager.localize("Host Touchpad")).tag("Host Touchpad")
          Text(languageManager.localize("Mac-style Trackpad")).tag("Mac-style Trackpad")
        }
        .labelsHidden()
        .frame(width: 190, alignment: .trailing)
      }
      ToggleCell(title: "Hold Options to Switch Touchpad Mode", hintKey: "DualSense Options hint",
                 boolBinding: $settingsModel.gamepadMouseModeLongPressMenu)
      SettingsRow(title: "Haptic Feedback") {
        Picker("", selection: $settingsModel.selectedControllerHapticsMode) {
          ForEach(SettingsModel.controllerHapticsModes, id: \.self) { value in
            Text(languageManager.localize(value)).tag(value)
          }
        }
        .labelsHidden()
        .frame(width: 220, alignment: .trailing)
      }
      SettingsRow(title: "Motion Sensor") {
        Picker("", selection: $settingsModel.selectedControllerMotionMode) {
          ForEach(SettingsModel.controllerMotionModes, id: \.self) { value in
            Text(languageManager.localize(value)).tag(value)
          }
        }
        .labelsHidden()
        .frame(width: 220, alignment: .trailing)
      }
      SettingsRow(title: "Feedback Target") {
        Picker("", selection: $settingsModel.selectedControllerFeedbackTarget) {
          ForEach(SettingsModel.controllerFeedbackTargets, id: \.self) { value in
            Text(languageManager.localize(value)).tag(value)
          }
        }
        .labelsHidden()
        .frame(width: 220, alignment: .trailing)
      }
      ControllerDeadzoneRow(value: $settingsModel.controllerDeadzone)
      ToggleCell(title: "Emulate Guide Button", boolBinding: $settingsModel.emulateGuide)
      ToggleCell(title: "Gamepad Mouse Emulation", hintKey: "Gamepad Mouse Hint", boolBinding: $settingsModel.gamepadMouseMode)
      SettingsChoiceRow(title: "Host Controller Type", selection: $settingsModel.selectedControllerVirtualType,
                        options: SettingsModel.controllerVirtualTypes)
      SettingsRow(title: "Connected Controllers") {
        Text("\(GCController.controllers().count)")
          .foregroundStyle(.secondary)
      }
    }
  }
}

private struct ControllerDeadzoneRow: View {
  @Binding var value: Double
  @ObservedObject private var languageManager = LanguageManager.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack {
        Text(languageManager.localize("Controller Deadzone"))
        Spacer()
        Text(String(format: "%.0f%%", value * 100))
          .font(.callout.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      Slider(value: $value, in: 0...0.30, step: 0.01)
    }
    .padding(.vertical, 8)
  }
}

private struct KeyboardMouseSettingsSection: View {
  @EnvironmentObject private var settingsModel: SettingsModel
  @ObservedObject private var languageManager = LanguageManager.shared
  @ObservedObject private var inputPermissions = InputMonitoringPermissionManager.sharedManager

  var body: some View {
    FormSection(title: "Keyboard & Mouse") {
      SettingsRow(title: "Mouse Mode") {
        Picker("", selection: $settingsModel.mouseMode) {
          Text(languageManager.localize("Locked Mouse")).tag("game")
          Text(languageManager.localize("Free Mouse")).tag("remote")
        }
        .labelsHidden()
        .frame(width: 180, alignment: .trailing)
      }

      SettingsRow(title: "Mouse Driver") {
        Picker("", selection: $settingsModel.selectedMouseDriver) {
          ForEach(SettingsModel.mouseDrivers, id: \.self) { value in
            Text(languageManager.localize(value)).tag(value)
          }
        }
        .labelsHidden()
        .frame(width: 180, alignment: .trailing)
      }

      SettingsRow(title: "Keyboard Translation") {
        Picker("", selection: $settingsModel.selectedKeyboardCompatibilityMode) {
          ForEach(SettingsModel.keyboardCompatibilityModes, id: \.self) { value in
            Text(languageManager.localize(value)).tag(value)
          }
        }
        .labelsHidden()
        .frame(width: 240, alignment: .trailing)
      }

      ToggleCell(title: "Capture System Shortcuts", boolBinding: $settingsModel.captureSystemShortcuts)
      ToggleCell(title: "Absolute Mouse Mode", boolBinding: $settingsModel.absoluteMouseMode)
      ToggleCell(title: "Swap Mouse Buttons", boolBinding: $settingsModel.swapMouseButtons)
      ToggleCell(title: "Reverse Scroll Direction", boolBinding: $settingsModel.reverseScrollDirection)
      SettingsRow(title: "Pointer Speed") {
        Slider(value: $settingsModel.pointerSensitivity, in: 0.25...3.0)
          .frame(width: 190)
      }
      SettingsRow(title: "Scroll Mode") {
        Picker("", selection: $settingsModel.selectedPhysicalWheelMode) {
          ForEach(SettingsModel.physicalWheelModes, id: \.self) { value in
            Text(languageManager.localize(value)).tag(value)
          }
        }
        .labelsHidden()
        .frame(width: 180, alignment: .trailing)
      }
      SettingsRow(title: "Input Monitoring") {
        HStack(spacing: 8) {
          Circle()
            .fill(inputPermissions.isGranted ? Color.green : Color.orange)
            .frame(width: 8, height: 8)
          Text(languageManager.localize(inputPermissions.displayStatusLabelKey))
            .foregroundStyle(.secondary)
        }
      }
    }
  }
}

private struct USBMappingView: View {
  @EnvironmentObject private var settingsModel: SettingsModel
  @StateObject private var remoteUSB = RemoteUSBForwardingViewModel()
  @AppStorage("settings.usb.mappingEnabled") private var mappingEnabled = true

  private var hostAvailable: Bool {
    guard let host = settingsModel.selectedHost else { return false }
    return host.id != SettingsModel.globalHostId
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        USBMappingHeader(
          mappingEnabled: $mappingEnabled,
          status: hostAvailable ? remoteUSB.status : "Select a paired host",
          available: hostAvailable
        )

        USBMappingStatusCard(
          status: hostAvailable ? remoteUSB.status : "Select a paired host",
          available: remoteUSB.capabilityAvailable,
          enabled: mappingEnabled && hostAvailable
        )

        USBDeviceGroup(
          title: "My Devices",
          emptyTitle: "No mapped devices",
          devices: remoteUSB.devices.filter { remoteUSB.selectedBusID == $0.busID },
          remoteUSB: remoteUSB,
          enabled: mappingEnabled && hostAvailable
        )

        USBDeviceGroup(
          title: "Nearby Devices",
          emptyTitle: remoteUSB.status.contains("Checking") ? "Searching…" : "No claimable USB devices",
          devices: remoteUSB.devices.filter { remoteUSB.selectedBusID != $0.busID },
          remoteUSB: remoteUSB,
          enabled: mappingEnabled && hostAvailable
        )

      }
      .frame(maxWidth: 760, alignment: .leading)
      .padding(.horizontal, 28)
      .padding(.vertical, 24)
      .frame(maxWidth: .infinity, alignment: .center)
    }
    .onAppear {
      if mappingEnabled && hostAvailable {
        remoteUSB.refresh(host: settingsModel.selectedHost)
      }
    }
    .onChange(of: mappingEnabled) { enabled in
      if enabled && hostAvailable {
        remoteUSB.refresh(host: settingsModel.selectedHost)
      } else {
        remoteUSB.stop()
      }
    }
  }
}

private struct USBMappingStatusCard: View {
  let status: String
  let available: Bool
  let enabled: Bool
  @ObservedObject private var languageManager = LanguageManager.shared

  var body: some View {
    HStack(spacing: 10) {
      Circle()
        .fill(!enabled ? Color.secondary : (available ? Color.green : Color.orange))
        .frame(width: 9, height: 9)
      Text(!enabled ? languageManager.localize("USB Mapping Disabled") : localizedStatus)
        .font(.callout)
        .foregroundStyle(.secondary)
      Spacer()
      if enabled && status.contains("Checking") {
        ProgressView().controlSize(.small)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 11)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }

  private var localizedStatus: String {
    if status.hasPrefix("Forwarding") { return languageManager.localize("Forwarding") }
    return languageManager.localize(status)
  }
}

private struct USBDeviceGroup: View {
  @EnvironmentObject private var settingsModel: SettingsModel
  let title: String
  let emptyTitle: String
  let devices: [MLRemoteUSBDevice]
  @ObservedObject var remoteUSB: RemoteUSBForwardingViewModel
  let enabled: Bool
  @ObservedObject private var languageManager = LanguageManager.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack {
        Text(LocalizedStringKey(title))
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer()
        Button(languageManager.localize("Refresh")) { remoteUSB.refresh(host: settingsModel.selectedHost) }
          .buttonStyle(.borderless)
          .controlSize(.small)
          .disabled(!enabled)
      }

      VStack(spacing: 0) {
        if devices.isEmpty {
          HStack {
            if enabled { ProgressView().controlSize(.small) }
            Text(enabled
              ? languageManager.localize(emptyTitle)
              : languageManager.localize("USB Mapping Disabled"))
              .foregroundStyle(.secondary)
            Spacer()
          }
          .frame(minHeight: 48)
        } else {
          ForEach(devices, id: \.busID) { device in
            USBDeviceRow(device: device, remoteUSB: remoteUSB)
          }
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 3)
      .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
  }
}

private struct USBSettingsSection: View {
  @EnvironmentObject private var settingsModel: SettingsModel
  @ObservedObject var remoteUSB: RemoteUSBForwardingViewModel
  @Binding var mappingEnabled: Bool
  @ObservedObject private var languageManager = LanguageManager.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      USBMappingHeader(
        mappingEnabled: $mappingEnabled,
        status: remoteUSB.status,
        available: settingsModel.selectedHost?.id != SettingsModel.globalHostId
      )

      FormSection(title: "USB Mapping") {
        HStack(alignment: .center, spacing: 10) {
          Image(systemName: "cable.connector.horizontal")
            .foregroundStyle(.tint)
          VStack(alignment: .leading, spacing: 3) {
            Text(localizedUSBStatus(remoteUSB.status))
              .font(.body)
            Text(languageManager.localize("Foundation USB forwarding detail"))
              .font(.footnote)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          Spacer()
          Button(languageManager.localize("Refresh")) {
            remoteUSB.refresh(host: settingsModel.selectedHost)
          }
          .buttonStyle(.bordered)
          .disabled(!mappingEnabled)
        }
        .padding(.vertical, 8)

        ForEach(remoteUSB.devices, id: \.busID) { device in
          USBDeviceRow(device: device, remoteUSB: remoteUSB)
        }
      }

    }
  }

  private func localizedUSBStatus(_ status: String) -> String {
    if status.hasPrefix("Forwarding") { return languageManager.localize("Forwarding") }
    return languageManager.localize(status)
  }
}

private struct USBMappingHeader: View {
  @Binding var mappingEnabled: Bool
  let status: String
  let available: Bool
  @ObservedObject private var languageManager = LanguageManager.shared

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "cable.connector.horizontal")
        .font(.system(size: 22, weight: .medium))
        .foregroundStyle(.teal)
        .frame(width: 46, height: 46)
        .background(Color.teal.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

      VStack(alignment: .leading, spacing: 3) {
        Text(languageManager.localize("USB Mapping"))
          .font(.title3.weight(.semibold))
        Text(languageManager.localize("USB settings subtitle"))
          .font(.callout)
          .foregroundStyle(.secondary)
        Text(localizedStatus)
          .font(.footnote)
          .foregroundStyle(.secondary)
      }

      Spacer(minLength: 12)

      Toggle("", isOn: $mappingEnabled)
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.small)
        .disabled(!available)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .opacity(available ? 1 : 0.55)
  }

  private var localizedStatus: String {
    if status.hasPrefix("Forwarding") { return languageManager.localize("Forwarding") }
    return languageManager.localize(status)
  }
}

private struct USBDeviceRow: View {
  let device: MLRemoteUSBDevice
  @ObservedObject var remoteUSB: RemoteUSBForwardingViewModel
  @ObservedObject private var languageManager = LanguageManager.shared

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: device.isClaimable ? "externaldrive.connected.to.line.below" : "externaldrive")
        .foregroundStyle(device.isClaimable ? Color.accentColor : Color.secondary)
        .frame(width: 24)
      VStack(alignment: .leading, spacing: 3) {
        Text(device.product.isEmpty ? device.busID : device.product)
          .lineLimit(1)
        Text("\(device.vidPID) · \(device.busID)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer()
      if remoteUSB.selectedBusID == device.busID {
        Button(languageManager.localize("Stop")) { remoteUSB.stop() }
          .buttonStyle(.bordered)
      } else {
        Button(languageManager.localize("Forward")) { remoteUSB.start(device: device) }
          .buttonStyle(.borderedProminent)
          .disabled(!remoteUSB.capabilityAvailable || !device.isClaimable)
      }
    }
    .padding(.vertical, 8)
  }
}


private struct MouseTuningSettingsSection: View {
  @EnvironmentObject private var settingsModel: SettingsModel
  private var coreHID: Bool {
    let strategy = MouseInputDriverStrategy(selection: settingsModel.selectedMouseDriver)
    return strategy == .automatic || strategy == .coreHID
  }
  var body: some View {
    FormSection(title: "Mouse Tuning") {
      if settingsModel.mouseMode == "remote" {
        SettingsChoiceRow(title: "Free Mouse Movement", selection: $settingsModel.selectedFreeMouseMotionMode,
          options: SettingsModel.freeMouseMotionModes)
      }
      SettingsValueSliderRow(title: "Physical Wheel Speed", value: $settingsModel.wheelScrollSpeed,
        range: 0.1...4, step: 0.05, multiplier: 100, suffix: "%")
      if settingsModel.selectedPhysicalWheelMode != PhysicalWheelScrollMode.notched.displayKey {
        SettingsValueSliderRow(title: "High Precision Wheel Speed", value: $settingsModel.physicalWheelHighPrecisionScale,
          range: 1...12, step: 0.25, suffix: "×")
      }
      SettingsChoiceRow(title: "Smooth Wheel Mode", selection: $settingsModel.selectedRewrittenScrollMode, options: SettingsModel.rewrittenScrollModes)
      SettingsValueSliderRow(title: "Smooth Wheel Speed", value: $settingsModel.rewrittenScrollSpeed,
        range: 0.1...4, step: 0.05, multiplier: 100, suffix: "%")
      if settingsModel.selectedRewrittenScrollMode != RewrittenScrollMode.notched.displayKey || settingsModel.smartWheelTailFilter > 0 {
        SettingsValueSliderRow(title: "Smooth Wheel Tail Filter", value: $settingsModel.smartWheelTailFilter, range: 0...1, step: 0.02)
      }
      SettingsValueSliderRow(title: "Trackpad Speed", value: $settingsModel.gestureScrollSpeed,
        range: 0.1...4, step: 0.05, multiplier: 100, suffix: "%")
      SettingsRow(title: "CoreHID Max Mouse Report Rate") {
        Picker("", selection: $settingsModel.coreHIDMaxMouseReportRate) {
          ForEach(SettingsModel.coreHIDMaxMouseReportRates, id: \.self) { value in
            Text(SettingsModel.coreHIDMaxMouseReportRateLabel(value)).tag(value)
          }
        }.labelsHidden().frame(width: 190).disabled(!coreHID)
      }
      SettingsChoiceRow(title: "Touchscreen Mode", selection: $settingsModel.selectedTouchscreenMode, options: SettingsModel.touchscreenModes)
    }
  }
}
