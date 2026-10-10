// Restored from this project's v1.3.8 settings (existing GPL application code).
import AppKit
import Carbon.HIToolbox
import GameController
import SwiftUI

private struct ShortcutReferenceItem: Hashable, Identifiable {
  let action: String
  let actionKey: String

  var id: String { action }
}

struct ShortcutReferenceView: View {
  @ObservedObject var settingsModel: SettingsModel
  @ObservedObject var languageManager = LanguageManager.shared
  @SwiftUI.State private var editingItem: ShortcutReferenceItem?

  private var items: [ShortcutReferenceItem] {
    StreamShortcutProfile.actionOrder().map {
      ShortcutReferenceItem(action: $0, actionKey: StreamShortcutProfile.actionTitleKey(for: $0))
    }
  }

  init(settingsModel: SettingsModel) {
    _settingsModel = ObservedObject(wrappedValue: settingsModel)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(languageManager.localize("Stream Shortcuts"))
        .font(.subheadline.weight(.medium))


      LazyVGrid(
        columns: [GridItem(.adaptive(minimum: 280), spacing: 12, alignment: .top)],
        alignment: .leading,
        spacing: 12
      ) {
        ForEach(items) { item in
          ShortcutReferenceCard(
            item: item,
            shortcut: settingsModel.shortcut(for: item.action),
            onEdit: { editingItem = item })
        }
      }
    }
    .padding(.top, 2)
    .sheet(item: $editingItem) { item in
      ShortcutCaptureSheet(settingsModel: settingsModel, item: item)
    }
  }
}

private struct ShortcutReferenceCard: View {
  @ObservedObject var languageManager = LanguageManager.shared
  let item: ShortcutReferenceItem
  let shortcut: StreamShortcut
  let onEdit: () -> Void

  var body: some View {
    Button(action: onEdit) {
      VStack(alignment: .leading, spacing: 12) {
        ShortcutTokenRowView(tokens: StreamShortcutProfile.displayTokens(for: shortcut))

        Text(languageManager.localize(item.actionKey))
          .font(.callout.weight(.medium))
          .foregroundColor(.primary)
          .multilineTextAlignment(.leading)
          .frame(maxWidth: .infinity, alignment: .leading)

        HStack(spacing: 6) {
          Text(languageManager.localize("Change Shortcut"))
            .font(.footnote.weight(.medium))
          Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .semibold))
        }
        .foregroundColor(.secondary)
      }
      .padding(14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(Color(NSColor.controlBackgroundColor))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
      )
    }
    .controllerButtonStyle(.plain)
  }
}

private struct ShortcutCaptureSheet: View {
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var settingsModel: SettingsModel
  @ObservedObject var languageManager = LanguageManager.shared

  let item: ShortcutReferenceItem

  @SwiftUI.State private var eventMonitor: Any?
  @SwiftUI.State private var errorKey: String?

  init(settingsModel: SettingsModel, item: ShortcutReferenceItem) {
    _settingsModel = ObservedObject(wrappedValue: settingsModel)
    self.item = item
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(languageManager.localize("Change Shortcut"))
        .font(.title3.weight(.semibold))

      Text(languageManager.localize(item.actionKey))
        .font(.headline)

      Text(languageManager.localize("Press shortcut to record"))
        .font(.callout)
        .foregroundColor(.secondary)

      ShortcutTokenRowView(tokens: StreamShortcutProfile.displayTokens(for: settingsModel.shortcut(for: item.action)))

      Text(languageManager.localize("Shortcut capture note"))
        .font(.footnote)
        .foregroundColor(.secondary)

      if let errorKey {
        Text(languageManager.localize(errorKey))
          .font(.footnote)
          .foregroundColor(.red)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      HStack {
        Button(languageManager.localize("Cancel")) {
          dismiss()
        }

        Spacer()

        if !settingsModel.isDefaultShortcut(for: item.action) {
          Button(languageManager.localize("Restore Default Shortcut")) {
            settingsModel.resetShortcut(for: item.action)
            dismiss()
          }
        }
      }
    }
    .padding(20)
    .frame(width: 420)
    .onAppear(perform: installMonitor)
    .onDisappear(perform: removeMonitor)
  }

  private func installMonitor() {
    guard eventMonitor == nil else { return }
    eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
      handle(event)
    }
  }

  private func removeMonitor() {
    if let eventMonitor {
      NSEvent.removeMonitor(eventMonitor)
      self.eventMonitor = nil
    }
  }

  private func handle(_ event: NSEvent) -> NSEvent? {
    switch event.type {
    case .keyDown:
      return handleKeyDown(event)
    case .flagsChanged:
      return handleFlagsChanged(event)
    default:
      return event
    }
  }

  private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
    if event.keyCode == UInt16(kVK_Escape) {
      dismiss()
      return nil
    }

    let shortcut = StreamShortcut(
      keyCode: Int(event.keyCode),
      modifierFlags: StreamShortcutProfile.relevantModifierFlags(event.modifierFlags))
    return capture(shortcut)
  }

  private func handleFlagsChanged(_ event: NSEvent) -> NSEvent? {
    guard StreamShortcutProfile.isModifierOnlyAction(item.action) else {
      return event
    }

    let modifiers = StreamShortcutProfile.relevantModifierFlags(event.modifierFlags)
    guard !modifiers.isEmpty else {
      return event
    }

    let shortcut = StreamShortcut(modifierFlags: modifiers, modifierOnly: true)
    return capture(shortcut)
  }

  private func capture(_ shortcut: StreamShortcut) -> NSEvent? {
    if let errorKey = StreamShortcutProfile.validationErrorKey(
      for: shortcut,
      action: item.action,
      shortcuts: settingsModel.streamShortcuts,
      keyboardTranslationRules: settingsModel.keyboardTranslationRules)
    {
      self.errorKey = errorKey
      return nil
    }

    settingsModel.setShortcut(shortcut, for: item.action)
    dismiss()
    return nil
  }
}

private struct ControllerShortcutItem: Hashable, Identifiable {
  let action: String
  var id: String { action }
}

/// Controller counterpart of ShortcutReferenceView: same cards, same capture flow.
struct ControllerShortcutReferenceView: View {
  @ObservedObject var settingsModel: SettingsModel
  @ObservedObject var languageManager = LanguageManager.shared
  @SwiftUI.State private var editingItem: ControllerShortcutItem?
  @SwiftUI.State private var restoringDefaults = false

  init(settingsModel: SettingsModel) {
    _settingsModel = ObservedObject(wrappedValue: settingsModel)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(languageManager.localize("Controller Shortcuts"))
        .font(.subheadline.weight(.medium))

      LazyVGrid(
        columns: [GridItem(.adaptive(minimum: 280), spacing: 12, alignment: .top)],
        alignment: .leading,
        spacing: 12
      ) {
        ForEach(ControllerShortcutProfile.actions, id: \.self) { action in
          ControllerShortcutCard(
            action: action,
            trigger: settingsModel.controllerShortcuts.bindings[action] ?? .disabled,
            onEdit: { editingItem = ControllerShortcutItem(action: action) })
        }
      }

      HStack {
        Spacer()
        Button(languageManager.localize("Restore Default Controller Shortcuts")) {
          restoringDefaults = true
        }
      }
    }
    .padding(.top, 2)
    .sheet(item: $editingItem) { item in
      ControllerShortcutCaptureSheet(settingsModel: settingsModel, action: item.action)
    }
    .confirmationDialog(
      languageManager.localize("Restore Default Controller Shortcuts"), isPresented: $restoringDefaults
    ) {
      Button(languageManager.localize("Restore Defaults"), role: .destructive) {
        settingsModel.controllerShortcuts = .defaults()
      }
    }
  }
}

private struct ControllerShortcutCard: View {
  @ObservedObject var languageManager = LanguageManager.shared
  let action: String
  let trigger: ControllerTouchpadShortcut
  let onEdit: () -> Void

  // Not a Button: the touchpad card carries an info button, and buttons do not nest.
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ControllerShortcutTokenRowView(trigger: trigger)

      HStack(spacing: 6) {
        Text(languageManager.localize(ControllerShortcutProfile.titleKey(for: action)))
          .font(.callout.weight(.medium))
          .foregroundColor(.primary)
          .multilineTextAlignment(.leading)
        if action == ControllerShortcutProfile.touchpadAction {
          InfoHintButton(hintKey: "Touchpad Button Shortcut hint")
        }
        Spacer(minLength: 0)
      }

      HStack(spacing: 6) {
        Text(languageManager.localize("Change Shortcut"))
          .font(.footnote.weight(.medium))
        Image(systemName: "chevron.right")
          .font(.system(size: 10, weight: .semibold))
      }
      .foregroundColor(.secondary)
    }
    .padding(14)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color(NSColor.controlBackgroundColor))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
    )
    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .onTapGesture(perform: onEdit)
    .controllerFocusTarget(onEdit)
    .accessibilityElement(children: .contain)
    .accessibilityAddTraits(.isButton)
    .accessibilityAction(.default, onEdit)
  }
}

private struct ControllerShortcutCaptureSheet: View {
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var settingsModel: SettingsModel
  @ObservedObject var languageManager = LanguageManager.shared

  let action: String

  @SwiftUI.State private var draft: ControllerTouchpadShortcut
  @SwiftUI.State private var recording: Set<ControllerTouchpadShortcut.Button> = []
  @SwiftUI.State private var pollTimer: Timer?
  @SwiftUI.State private var resolvingConflict = false

  init(settingsModel: SettingsModel, action: String) {
    _settingsModel = ObservedObject(wrappedValue: settingsModel)
    self.action = action
    _draft = SwiftUI.State(initialValue: settingsModel.controllerShortcuts.bindings[action] ?? .disabled)
  }

  private var defaultTrigger: ControllerTouchpadShortcut {
    ControllerShortcutProfile.defaults().bindings[action] ?? .disabled
  }

  private var conflicts: [String] {
    settingsModel.controllerShortcuts.conflicts(for: action, with: draft)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(languageManager.localize("Change Shortcut"))
        .font(.title3.weight(.semibold))

      Text(languageManager.localize(ControllerShortcutProfile.titleKey(for: action)))
        .font(.headline)

      Text(languageManager.localize("Press controller buttons to record"))
        .font(.callout)
        .foregroundColor(.secondary)

      ControllerShortcutTokenRowView(
        trigger: recording.isEmpty ? draft : ControllerTouchpadShortcut(buttons: Array(recording)).normalized)

      Text(languageManager.localize("Controller shortcut capture note"))
        .font(.footnote)
        .foregroundColor(.secondary)

      Picker(languageManager.localize("Shortcut Activation"), selection: Binding(
        get: { draft.holdSeconds > 0 },
        set: { draft.holdSeconds = $0 ? max(draft.holdSeconds, 0.5) : 0 })
      ) {
        Text(languageManager.localize("Shortcut Immediate")).tag(false)
        Text(languageManager.localize("Shortcut Long Hold")).tag(true)
      }
      .pickerStyle(.segmented)

      if draft.holdSeconds > 0 {
        Stepper(value: $draft.holdSeconds, in: 0.2...5, step: 0.1) {
          Text(String(format: languageManager.localize("Shortcut Hold Format"), draft.holdSeconds))
        }
      }

      VStack(alignment: .leading, spacing: 4) {
        Toggle(languageManager.localize("Shortcut Preserve Original"), isOn: $draft.preserveOriginal)
        Text(languageManager.localize("Shortcut Preserve Original hint"))
          .font(.footnote)
          .foregroundColor(.secondary)
      }

      if !conflicts.isEmpty {
        Text(String(format: languageManager.localize("Controller shortcut conflict format"),
                    conflicts.map { languageManager.localize(ControllerShortcutProfile.titleKey(for: $0)) }
                      .formatted(.list(type: .and))))
          .font(.footnote)
          .foregroundColor(.orange)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      HStack {
        Button(languageManager.localize("Cancel")) {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)

        Spacer()

        if draft.normalized != defaultTrigger {
          Button(languageManager.localize("Restore Default Shortcut")) {
            draft = defaultTrigger
          }
        }
        Button(languageManager.localize("Shortcut Clear")) {
          draft = .disabled
        }
        Button(languageManager.localize("Save")) {
          if conflicts.isEmpty { save(replacing: []) } else { resolvingConflict = true }
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 460)
    .onAppear(perform: startCapture)
    .onDisappear(perform: stopCapture)
    .confirmationDialog(
      languageManager.localize("Controller Shortcut Conflict"), isPresented: $resolvingConflict,
      titleVisibility: .visible
    ) {
      Button(languageManager.localize("Replace Conflicting Shortcuts"), role: .destructive) {
        save(replacing: conflicts)
      }
      Button(languageManager.localize("Keep Both Prefer New")) { save(replacing: []) }
      Button(languageManager.localize("Keep Existing Shortcuts"), role: .cancel) {}
    } message: {
      Text(conflicts.map { languageManager.localize(ControllerShortcutProfile.titleKey(for: $0)) }
        .formatted(.list(type: .and)))
    }
  }

  private func save(replacing replaced: [String]) {
    var profile = settingsModel.controllerShortcuts
    profile.assign(draft, to: action, replacing: replaced)
    settingsModel.controllerShortcuts = profile
    dismiss()
  }

  // Records the largest chord held on any controller; releasing every button
  // commits it. Interface navigation is paused so the presses do not act on the sheet.
  private func startCapture() {
    guard pollTimer == nil else { return }
    ControllerNavigationSuspension.set(true)
    let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in
      var held: Set<ControllerTouchpadShortcut.Button> = []
      for controller in GCController.controllers() {
        guard let pad = controller.extendedGamepad else { continue }
        for button in ControllerTouchpadShortcut.Button.allCases where button.isPressed(in: pad) {
          held.insert(button)
        }
      }
      if held.isEmpty {
        if !recording.isEmpty {
          draft.buttons = Array(recording)
          draft = draft.normalized
          recording = []
        }
      } else {
        recording.formUnion(held)
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    pollTimer = timer
  }

  private func stopCapture() {
    pollTimer?.invalidate()
    pollTimer = nil
    ControllerNavigationSuspension.set(false)
  }
}

/// Lets a capture sheet take the controller away from interface navigation.
enum ControllerNavigationSuspension {
  static let notification = Notification.Name("ControllerNavigationSuspended")

  static func set(_ suspended: Bool) {
    NotificationCenter.default.post(name: notification, object: nil, userInfo: ["suspended": suspended])
  }
}

private struct ControllerShortcutTokenRowView: View {
  @ObservedObject var languageManager = LanguageManager.shared
  let trigger: ControllerTouchpadShortcut

  var body: some View {
    let family = ControllerGlyphFamily.current
    HStack(spacing: 6) {
      if trigger.buttons.isEmpty {
        ShortcutKeycapView(key: languageManager.localize("Shortcut Not Mapped"))
      }
      ForEach(Array(trigger.buttons.enumerated()), id: \.offset) { index, button in
        if index > 0 {
          Text("+")
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundColor(.secondary)
        }
        ControllerButtonKeycapView(button: button, family: family)
      }
      if trigger.holdSeconds > 0 && !trigger.buttons.isEmpty {
        Text(String(format: languageManager.localize("Shortcut Hold Format"), trigger.holdSeconds))
          .font(.footnote.weight(.medium))
          .foregroundColor(.secondary)
          .padding(.leading, 4)
      }
    }
  }
}

private struct ControllerButtonKeycapView: View {
  let button: ControllerTouchpadShortcut.Button
  let family: ControllerGlyphFamily

  var body: some View {
    Group {
      if let symbol = button.symbolName(family) {
        Image(systemName: symbol)
          .font(.system(size: 15, weight: .medium))
          .accessibilityLabel(button.displayName(family))
      } else {
        Text(button.displayName(family))
          .font(.system(size: 13, weight: .semibold, design: .rounded))
      }
    }
    .foregroundColor(.primary)
    .help(button.displayName(family))
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color(NSColor.windowBackgroundColor))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
    )
  }
}

private struct KeyboardTranslationEditorRequest: Identifiable {
  let id = UUID()
  let rule: KeyboardTranslationRule?
}

struct KeyboardTranslationRulesView: View {
  @ObservedObject var settingsModel: SettingsModel
  @ObservedObject var languageManager = LanguageManager.shared
  @SwiftUI.State private var editingRequest: KeyboardTranslationEditorRequest?

  init(settingsModel: SettingsModel) {
    _settingsModel = ObservedObject(wrappedValue: settingsModel)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text(languageManager.localize("Shortcut Translation Rules"))
            .font(.subheadline.weight(.medium))

        }

        Spacer()

        Button(languageManager.localize("Add Rule")) {
          editingRequest = KeyboardTranslationEditorRequest(rule: nil)
        }
      }

      if settingsModel.keyboardTranslationRules.isEmpty {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(Color(NSColor.controlBackgroundColor))
          .overlay(
            VStack(alignment: .leading, spacing: 8) {
              Text(languageManager.localize("No Shortcut Translation Rules"))
                .font(.callout.weight(.medium))
                .foregroundColor(.primary)

              Text(languageManager.localize("No Shortcut Translation Rules detail"))
                .font(.footnote)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
          )
          .frame(maxWidth: .infinity, minHeight: 92)
      } else {
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 300), spacing: 12, alignment: .top)],
          alignment: .leading,
          spacing: 12
        ) {
          ForEach(settingsModel.keyboardTranslationRules) { rule in
            KeyboardTranslationRuleCard(
              rule: rule,
              onEdit: {
                editingRequest = KeyboardTranslationEditorRequest(rule: rule)
              },
              onDelete: {
                settingsModel.removeKeyboardTranslationRule(id: rule.id)
              })
          }
        }
      }
    }
    .padding(.top, 2)
    .sheet(item: $editingRequest) { request in
      KeyboardTranslationRuleEditorSheet(settingsModel: settingsModel, rule: request.rule)
    }
  }
}

private struct KeyboardTranslationRuleCard: View {
  @ObservedObject var languageManager = LanguageManager.shared
  let rule: KeyboardTranslationRule
  let onEdit: () -> Void
  let onDelete: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ShortcutTokenRowView(tokens: KeyboardTranslationProfile.displayTokens(forTrigger: rule.trigger))

      HStack(alignment: .center, spacing: 8) {
        Image(systemName: "arrow.right")
          .font(.system(size: 12, weight: .semibold))
          .foregroundColor(.secondary)

        if rule.outputKind == .remoteShortcut, let outputShortcut = rule.outputShortcut {
          ShortcutTokenRowView(tokens: KeyboardTranslationProfile.displayTokens(forRemoteOutput: outputShortcut))
        } else {
          Text(languageManager.localize(KeyboardTranslationProfile.localActionTitleKey(for: rule.localAction ?? KeyboardTranslationProfile.localActionDisconnectStream)))
            .font(.callout.weight(.medium))
            .foregroundColor(.primary)
            .multilineTextAlignment(.leading)
        }
      }

      HStack(spacing: 12) {
        Button(languageManager.localize("Edit Rule"), action: onEdit)
          .controllerButtonStyle(.link)

        Spacer()

        Button(languageManager.localize("Delete Rule"), role: .destructive, action: onDelete)
          .controllerButtonStyle(.link)
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color(NSColor.controlBackgroundColor))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
    )
  }
}

private struct KeyboardTranslationRuleEditorSheet: View {
  private enum CaptureTarget {
    case trigger
    case output
  }

  @Environment(\.dismiss) private var dismiss
  @ObservedObject var settingsModel: SettingsModel
  @ObservedObject var languageManager = LanguageManager.shared

  let rule: KeyboardTranslationRule?

  @SwiftUI.State private var triggerShortcut: StreamShortcut
  @SwiftUI.State private var outputKindSelection: String
  @SwiftUI.State private var remoteOutputShortcut: StreamShortcut
  @SwiftUI.State private var localAction: String
  @SwiftUI.State private var captureTarget: CaptureTarget?
  @SwiftUI.State private var eventMonitor: Any?
  @SwiftUI.State private var errorKey: String?

  init(settingsModel: SettingsModel, rule: KeyboardTranslationRule?) {
    _settingsModel = ObservedObject(wrappedValue: settingsModel)
    self.rule = rule

    let defaultTrigger = StreamShortcut(keyCode: kVK_ANSI_W, modifierFlags: [.command])
    let defaultOutput = StreamShortcut(keyCode: kVK_F4, modifierFlags: [.option])
    let resolvedKind = rule?.outputKind ?? .remoteShortcut

    _triggerShortcut = .init(initialValue: rule?.trigger ?? defaultTrigger)
    _outputKindSelection = .init(initialValue: resolvedKind.displayKey)
    _remoteOutputShortcut = .init(initialValue: rule?.outputShortcut ?? defaultOutput)
    _localAction = .init(
      initialValue: rule?.localAction ?? KeyboardTranslationProfile.localActionDisconnectStream)
  }

  private var selectedOutputKind: KeyboardTranslationOutputKind {
    KeyboardTranslationOutputKind.allCases.first(where: { $0.displayKey == outputKindSelection })
      ?? .remoteShortcut
  }

  private var titleKey: String {
    rule == nil ? "Add Shortcut Translation Rule" : "Edit Shortcut Translation Rule"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(languageManager.localize(titleKey))
        .font(.title3.weight(.semibold))

      Text(languageManager.localize("Shortcut Translation Editor note"))
        .font(.callout)
        .foregroundColor(.secondary)

      Button {
        errorKey = nil
        captureTarget = .trigger
      } label: {
        editorCaptureRow(
          title: "Trigger",
          tokens: KeyboardTranslationProfile.displayTokens(forTrigger: triggerShortcut),
          isCapturing: captureTarget == .trigger)
      }
      .controllerButtonStyle(.plain)

      VStack(alignment: .leading, spacing: 8) {
        Text(languageManager.localize("Action Type"))
          .font(.headline)

        Picker("", selection: $outputKindSelection) {
          ForEach(KeyboardTranslationProfile.outputKinds(), id: \.self) { kind in
            Text(languageManager.localize(kind))
          }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
      }

      if selectedOutputKind == .remoteShortcut {
        Button {
          errorKey = nil
          captureTarget = .output
        } label: {
          editorCaptureRow(
            title: "Remote Shortcut",
            tokens: KeyboardTranslationProfile.displayTokens(forRemoteOutput: remoteOutputShortcut),
            isCapturing: captureTarget == .output)
        }
        .controllerButtonStyle(.plain)
      } else {
        VStack(alignment: .leading, spacing: 8) {
          Text(languageManager.localize("Moonlight Action"))
            .font(.headline)

          Picker("", selection: $localAction) {
            ForEach(KeyboardTranslationProfile.localActionOrder(), id: \.self) { action in
              Text(languageManager.localize(KeyboardTranslationProfile.localActionTitleKey(for: action)))
                .tag(action)
            }
          }
          .labelsHidden()
        }
      }

      if let errorKey {
        Text(languageManager.localize(errorKey))
          .font(.footnote)
          .foregroundColor(.red)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      HStack {
        Button(languageManager.localize("Cancel")) {
          dismiss()
        }

        if let rule {
          Button(languageManager.localize("Delete Rule"), role: .destructive) {
            settingsModel.removeKeyboardTranslationRule(id: rule.id)
            dismiss()
          }
        }

        Spacer()

        Button(languageManager.localize("Save Rule")) {
          save()
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 460)
    .onAppear(perform: installMonitor)
    .onDisappear(perform: removeMonitor)
  }

  @ViewBuilder
  private func editorCaptureRow(title: String, tokens: [String], isCapturing: Bool) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(languageManager.localize(title))
          .font(.headline)
        Spacer()
        Text(
          languageManager.localize(
            isCapturing ? "Recording Shortcut" : "Click to Record Shortcut")
        )
        .font(.footnote)
        .foregroundColor(.secondary)
      }

      ShortcutTokenRowView(tokens: tokens)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(
              isCapturing ? Color.accentColor : Color.secondary.opacity(0.14),
              lineWidth: isCapturing ? 1.5 : 1)
        )
    }
  }

  private func installMonitor() {
    guard eventMonitor == nil else { return }
    eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
      handle(event)
    }
  }

  private func removeMonitor() {
    if let eventMonitor {
      NSEvent.removeMonitor(eventMonitor)
      self.eventMonitor = nil
    }
  }

  private func handle(_ event: NSEvent) -> NSEvent? {
    guard let captureTarget else {
      return event
    }

    if event.keyCode == UInt16(kVK_Escape) {
      self.captureTarget = nil
      return nil
    }

    let shortcut = StreamShortcut(
      keyCode: Int(event.keyCode),
      modifierFlags: StreamShortcutProfile.relevantModifierFlags(event.modifierFlags))

    switch captureTarget {
    case .trigger:
      triggerShortcut = shortcut
    case .output:
      remoteOutputShortcut = shortcut
    }

    self.captureTarget = nil
    return nil
  }

  private func save() {
    if let errorKey = KeyboardTranslationProfile.validationErrorKey(
      forTrigger: triggerShortcut,
      editingRuleId: rule?.id,
      rules: settingsModel.keyboardTranslationRules,
      streamShortcuts: settingsModel.streamShortcuts)
    {
      self.errorKey = errorKey
      return
    }

    let nextRule: KeyboardTranslationRule
    switch selectedOutputKind {
    case .remoteShortcut:
      if let errorKey = KeyboardTranslationProfile.validationErrorKey(
        forRemoteOutput: remoteOutputShortcut)
      {
        self.errorKey = errorKey
        return
      }
      nextRule = KeyboardTranslationRule(
        id: rule?.id ?? UUID().uuidString,
        trigger: triggerShortcut,
        outputShortcut: remoteOutputShortcut)
    case .localAction:
      nextRule = KeyboardTranslationRule(
        id: rule?.id ?? UUID().uuidString,
        trigger: triggerShortcut,
        localAction: localAction)
    }

    settingsModel.upsertKeyboardTranslationRule(nextRule)
    dismiss()
  }
}

private struct ShortcutTokenRowView: View {
  let tokens: [String]

  var body: some View {
    HStack(spacing: 6) {
      ForEach(Array(tokens.enumerated()), id: \.offset) { index, key in
        if index > 0 {
          Text("+")
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundColor(.secondary)
        }

        ShortcutKeycapView(key: key)
      }
    }
  }
}

private struct ShortcutKeycapView: View {
  let key: String

  var body: some View {
    Text(key)
      .font(.system(size: 13, weight: .semibold, design: .monospaced))
      .foregroundColor(.primary)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(Color(NSColor.windowBackgroundColor))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
      )
    }
}
