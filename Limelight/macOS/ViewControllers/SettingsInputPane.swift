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
            FormSection(title: "Controller Shortcuts") {
              ControllerShortcutReferenceView(settingsModel: settingsModel)
            }
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

  var body: some View {
    FormSection(title: "Controller") {
      SettingsRow(title: "Controller Driver") {
        Picker("", selection: $settingsModel.selectedControllerDriver) {
          ForEach(SettingsModel.controllerDrivers, id: \.self) { value in
            Text(languageManager.localize(value)).tag(value)
          }
        }
        .labelsHidden()
        .controllerPicker(selection: $settingsModel.selectedControllerDriver, options: SettingsModel.controllerDrivers, title: { value in languageManager.localize(value) })
        .frame(width: 170, alignment: .trailing)
      }

      SettingsRow(title: "Controller Count") {
        Picker("", selection: $settingsModel.selectedMultiControllerMode) {
          ForEach(SettingsModel.multiControllerModes, id: \.self) { value in
            Text(languageManager.localize(value)).tag(value)
          }
        }
        .labelsHidden()
        .controllerPicker(selection: $settingsModel.selectedMultiControllerMode, options: SettingsModel.multiControllerModes, title: { value in languageManager.localize(value) })
        .frame(width: 160, alignment: .trailing)
      }

      ToggleCell(title: "Rumble", boolBinding: $settingsModel.rumble)
      ToggleCell(title: "Swap Buttons", boolBinding: $settingsModel.swapButtons)
      SettingsRow(title: "DualSense Touchpad Mode") {
        HStack(spacing: 6) {
          InfoHintButton(hintKey: "Native Touchpad detail")
          Picker("", selection: Binding<String>(
            get: { settingsModel.nativeTouchpad ? "Host Touchpad" : "Mac-style Trackpad" },
            set: { settingsModel.nativeTouchpad = ($0 == "Host Touchpad") }
          )) {
            Text(languageManager.localize("Host Touchpad")).tag("Host Touchpad")
            Text(languageManager.localize("Mac-style Trackpad")).tag("Mac-style Trackpad")
          }
          .labelsHidden()
          .controllerPicker(
            selection: Binding<String>(
              get: { settingsModel.nativeTouchpad ? "Host Touchpad" : "Mac-style Trackpad" },
              set: { settingsModel.nativeTouchpad = ($0 == "Host Touchpad") }),
            options: ["Host Touchpad", "Mac-style Trackpad"], title: { languageManager.localize($0) })
          .frame(width: 190, alignment: .trailing)
        }
      }
      SettingsRow(title: "DualSense Touchpad Output") {
        HStack(spacing: 6) {
          InfoHintButton(hintKey: "DualSense Touchpad Output detail")
          Picker("", selection: $settingsModel.dualSensePrecisionTouchpad) {
            Text(languageManager.localize("DualSense Touchpad Output Controller")).tag(false)
            Text(languageManager.localize("DualSense Touchpad Output Precision")).tag(true)
          }
          .labelsHidden()
          .controllerPicker(selection: $settingsModel.dualSensePrecisionTouchpad, options: [false, true], title: { value in
            languageManager.localize(value ? "DualSense Touchpad Output Precision" : "DualSense Touchpad Output Controller")
          })
          .frame(width: 250, alignment: .trailing)
        }
      }
      SettingsRow(title: "Haptic Feedback") {
        Picker("", selection: $settingsModel.selectedControllerHapticsMode) {
          ForEach(SettingsModel.controllerHapticsModes, id: \.self) { value in
            Text(languageManager.localize(value)).tag(value)
          }
        }
        .labelsHidden()
        .controllerPicker(selection: $settingsModel.selectedControllerHapticsMode, options: SettingsModel.controllerHapticsModes, title: { value in languageManager.localize(value) })
        .frame(width: 220, alignment: .trailing)
      }
      SettingsRow(title: "Motion Sensor") {
        Picker("", selection: $settingsModel.selectedControllerMotionMode) {
          ForEach(SettingsModel.controllerMotionModes, id: \.self) { value in
            Text(languageManager.localize(value)).tag(value)
          }
        }
        .labelsHidden()
        .controllerPicker(selection: $settingsModel.selectedControllerMotionMode, options: SettingsModel.controllerMotionModes, title: { value in languageManager.localize(value) })
        .frame(width: 220, alignment: .trailing)
      }
      SettingsRow(title: "Feedback Target") {
        Picker("", selection: $settingsModel.selectedControllerFeedbackTarget) {
          ForEach(SettingsModel.controllerFeedbackTargets, id: \.self) { value in
            Text(languageManager.localize(value)).tag(value)
          }
        }
        .labelsHidden()
        .controllerPicker(selection: $settingsModel.selectedControllerFeedbackTarget, options: SettingsModel.controllerFeedbackTargets, title: { value in languageManager.localize(value) })
        .frame(width: 220, alignment: .trailing)
      }
      ControllerDeadzoneRow(value: $settingsModel.controllerDeadzone)
      ToggleCell(title: "Emulate Guide Button", boolBinding: $settingsModel.emulateGuide)
      ToggleCell(title: "Gamepad Mouse Emulation", hintKey: "Gamepad Mouse Hint", boolBinding: $settingsModel.gamepadMouseMode)
      SettingsChoiceRow(title: "Host Controller Type", detail: "Host Controller Type detail", selection: $settingsModel.selectedControllerVirtualType,
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
    // settings-search: entry "Controller Deadzone"
    VStack(alignment: .leading, spacing: 7) {
      HStack {
        Text(languageManager.localize("Controller Deadzone"))
        Spacer()
        Text(String(format: "%.0f%%", value * 100))
          .font(.callout.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      Slider(value: $value, in: 0...0.30, step: 0.01)
        .controllerSlider(value: $value, in: 0...0.30, step: 0.01)
    }
    .padding(.vertical, 8)
    .settingsSearchEntry("Controller Deadzone")
  }
}

private struct KeyboardMouseSettingsSection: View {
  @EnvironmentObject private var settingsModel: SettingsModel
  @ObservedObject private var languageManager = LanguageManager.shared
  @ObservedObject private var inputPermissions = InputMonitoringPermissionManager.sharedManager
  @StateObject private var accessibility = AccessibilityGesturePermission()

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
        .controllerPicker(selection: $settingsModel.selectedMouseDriver, options: SettingsModel.mouseDrivers, title: { value in languageManager.localize(value) })
        .frame(width: 180, alignment: .trailing)
      }

      // Grouped so the section keeps the same number of direct children.
      Group {
        SettingsRow(title: "Keyboard Translation") {
          Picker("", selection: $settingsModel.selectedKeyboardCompatibilityMode) {
            ForEach(SettingsModel.keyboardCompatibilityModes, id: \.self) { value in
              Text(languageManager.localize(value)).tag(value)
            }
          }
          .labelsHidden()
          .controllerPicker(selection: $settingsModel.selectedKeyboardCompatibilityMode, options: SettingsModel.keyboardCompatibilityModes, title: { value in languageManager.localize(value) })
          .frame(width: 240, alignment: .trailing)
        }

        SettingsRow(title: "Key Mapping", detail: "Key Mapping detail") {
          Picker("", selection: $settingsModel.selectedKeyMappingMode) {
            ForEach(SettingsModel.keyMappingModes, id: \.self) { value in
              Text(languageManager.localize(value)).tag(value)
            }
          }
          .labelsHidden()
          .controllerPicker(selection: $settingsModel.selectedKeyMappingMode, options: SettingsModel.keyMappingModes, title: { value in languageManager.localize(value) })
          .frame(width: 240, alignment: .trailing)
        }
      }

      SettingsRow(title: "Capture System Shortcuts") {
        HStack(spacing: 6) {
          if settingsModel.captureSystemShortcuts && !accessibility.isTrusted {
            InfoHintButton(
              hintKey: "Capture System Shortcuts Permission Hint",
              systemImage: "exclamationmark.triangle.fill", tint: .orange)
            Button(languageManager.localize("Grant Access")) { accessibility.request() }
              .controllerButtonStyle(.bordered)
              .controlSize(.small)
          }
          InfoHintButton(hintKey: "Capture System Shortcuts Hint")
          Toggle("", isOn: $settingsModel.captureSystemShortcuts)
            .labelsHidden()
            .toggleStyle(.switch)
            .focusable()
            .controlSize(.small)
        }
      }
      .onChange(of: settingsModel.captureSystemShortcuts) { enabled in
        if enabled {
          accessibility.offerPermissionIfNeeded(
            titleKey: "Capture System Shortcuts Permission Title",
            messageKey: "Capture System Shortcuts Permission Message")
        }
      }
      ToggleCell(title: "Swap Mouse Buttons", boolBinding: $settingsModel.swapMouseButtons)
      ToggleCell(title: "Reverse Scroll Direction", boolBinding: $settingsModel.reverseScrollDirection)
      SettingsRow(title: "Precision Touchpad") {
        HStack(spacing: 6) {
          if settingsModel.hostPrecisionTouchpadMode != 0 && !accessibility.isTrusted {
            InfoHintButton(
              hintKey: "Precision Touchpad Gesture Permission Hint",
              systemImage: "exclamationmark.triangle.fill", tint: .orange)
            Button(languageManager.localize("Grant Access")) { accessibility.request() }
              .controllerButtonStyle(.bordered)
              .controlSize(.small)
          }
          InfoHintButton(hintKey: "Precision Touchpad Hint")
          Picker("", selection: $settingsModel.hostPrecisionTouchpadMode) {
            Text(languageManager.localize("Precision Touchpad Off")).tag(0)
            Text(languageManager.localize("Precision Touchpad Block")).tag(1)
            Text(languageManager.localize("Precision Touchpad Both")).tag(2)
          }
          .labelsHidden()
          .controllerPicker(selection: $settingsModel.hostPrecisionTouchpadMode, options: [0, 1, 2], title: { value in
            languageManager.localize(["Precision Touchpad Off", "Precision Touchpad Block", "Precision Touchpad Both"][value])
          })
          .frame(width: 300, alignment: .trailing)
        }
      }
      .onChange(of: settingsModel.hostPrecisionTouchpadMode) { mode in
        if mode != 0 {
          accessibility.offerPermissionIfNeeded(
            titleKey: "Precision Touchpad Gesture Permission Title",
            messageKey: "Precision Touchpad Gesture Permission Message")
        }
      }
      ToggleCell(title: "Type Text with the macOS Input Method", hintKey: "Type Text with the macOS Input Method Hint", boolBinding: $settingsModel.imeTextInput)
      SettingsRow(title: "Pointer Speed") {
        Slider(value: $settingsModel.pointerSensitivity, in: 0.25...3.0)
          .controllerSlider(value: $settingsModel.pointerSensitivity, in: 0.25...3.0)
          .frame(width: 190)
      }
      SettingsRow(title: "Scroll Mode") {
        Picker("", selection: $settingsModel.selectedPhysicalWheelMode) {
          ForEach(SettingsModel.physicalWheelModes, id: \.self) { value in
            Text(languageManager.localize(value)).tag(value)
          }
        }
        .labelsHidden()
        .controllerPicker(selection: $settingsModel.selectedPhysicalWheelMode, options: SettingsModel.physicalWheelModes, title: { value in languageManager.localize(value) })
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

/// Accessibility access lets the stream swallow macOS system gestures (Mission Control, Spaces swipes)
/// and system shortcuts (⌘Tab, ⌘Space) so they reach the host. Without it both features degrade to
/// the normal behavior.
@MainActor
final class AccessibilityGesturePermission: ObservableObject {
  @Published var isTrusted = MLSystemGestureBlocker.isAccessibilityTrusted()
  private var activeObserver: NSObjectProtocol?
  private var didPromptThisSession = false

  init() {
    activeObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.refresh() }
    }
  }

  deinit {
    if let activeObserver {
      NotificationCenter.default.removeObserver(activeObserver)
    }
  }

  func refresh() {
    isTrusted = MLSystemGestureBlocker.isAccessibilityTrusted()
  }

  /// The first request clears any switch left over from an earlier build and shows the
  /// system prompt for this one (which also lists the app in the pane); later requests
  /// open the Accessibility pane directly.
  func request() {
    refresh()
    guard !isTrusted else { return }
    if didPromptThisSession {
      MLSystemGestureBlocker.openAccessibilitySettings()
    } else {
      didPromptThisSession = true
      _ = MLSystemGestureBlocker.resetAndRequestAccessibilityPermission()
    }
  }

  func offerPermissionIfNeeded(titleKey: String, messageKey: String) {
    refresh()
    guard !isTrusted else { return }
    let language = LanguageManager.shared
    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = language.localize(titleKey)
    alert.informativeText = language.localize(messageKey)
    alert.addButton(withTitle: language.localize("Grant Accessibility Access"))
    alert.addButton(withTitle: language.localize("Not Now"))
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    request()
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
    SettingsSearchScrollView {
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

        USBOpenSourceNotice()
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
          .controllerButtonStyle(.borderless)
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
    .settingsSearchSection(title)
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
          .controllerButtonStyle(.bordered)
          .disabled(!mappingEnabled)
        }
        .padding(.vertical, 8)

        ForEach(remoteUSB.devices, id: \.busID) { device in
          USBDeviceRow(device: device, remoteUSB: remoteUSB)
        }
      }

      USBOpenSourceNotice()
    }
  }

  private func localizedUSBStatus(_ status: String) -> String {
    if status.hasPrefix("Forwarding") { return languageManager.localize("Forwarding") }
    return languageManager.localize(status)
  }
}

private struct USBOpenSourceNotice: View {
  @ObservedObject private var languageManager = LanguageManager.shared

  var body: some View {
    FormSection(title: "Open Source") {
      VStack(alignment: .leading, spacing: 6) {
        // usbipdcpp asks for this sentence, unchanged, wherever it is used.
        Text(verbatim: ThirdPartyNotices.usbipdcppAttribution)
          .font(.callout)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
        Text(languageManager.localize("USB open source detail"))
          .font(.footnote)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 10) {
          Link(languageManager.localize("About usbipdcpp"), destination: ThirdPartyNotices.usbipdcppURL)
          Button(languageManager.localize("Third-Party Licenses")) {
            ThirdPartyNotices.openLicenses()
          }
          .controllerButtonStyle(.bordered)
          .controlSize(.small)
        }
        .padding(.top, 2)
      }
      .padding(.vertical, 10)
    }
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
          .controllerButtonStyle(.bordered)
      } else {
        Button(languageManager.localize("Forward")) { remoteUSB.start(device: device) }
          .controllerButtonStyle(.borderedProminent)
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
        }
        .labelsHidden()
        .controllerPicker(
          selection: $settingsModel.coreHIDMaxMouseReportRate, options: SettingsModel.coreHIDMaxMouseReportRates,
          title: { SettingsModel.coreHIDMaxMouseReportRateLabel($0) })
        .frame(width: 190, alignment: .trailing)
        .disabled(!coreHID)
      }
      SettingsChoiceRow(title: "Touchscreen Mode", selection: $settingsModel.selectedTouchscreenMode, options: SettingsModel.touchscreenModes)
    }
  }
}
