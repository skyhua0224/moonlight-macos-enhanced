//
//  SettingsView.swift
//  Moonlight for macOS
//
//  Created by Michael Kenny on 15/1/2024.
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

import AVFoundation
import AppKit
import Carbon.HIToolbox
import CoreGraphics
import SwiftUI

struct StreamRiskSummarySection: View {
  let assessment: StreamRiskAssessment
  @ObservedObject var languageManager = LanguageManager.shared
  @AppStorage("settings.video.streamRiskSummaryExpanded") private var isExpanded = false

  private var riskColor: Color {
    switch assessment.riskLevel {
    case .low:
      return .secondary
    case .medium:
      return .blue
    case .high:
      return .purple
    }
  }

  var body: some View {
    FormSection(title: "Profile Assessment") {
      DisclosureGroup(isExpanded: $isExpanded) {
        VStack(alignment: .leading, spacing: 8) {
          Text(languageManager.localize("Profile assessment hint"))
            .font(.footnote)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)

          Divider()

          HStack {
            Text(languageManager.localize("Profile Level"))
            Spacer()
            Text(assessment.riskLabel)
              .font(.system(.body, design: .rounded).weight(.semibold))
              .foregroundColor(riskColor)
          }

          Divider()

          HStack {
            Text(languageManager.localize("Route Tier"))
            Spacer()
            Text(assessment.routeLabel)
              .foregroundColor(.secondary)
          }

          if let hostRuntimeLabel = assessment.hostRuntimeLabel, !hostRuntimeLabel.isEmpty {
            Divider()

            HStack {
              Text(languageManager.localize("Host Runtime"))
              Spacer()
              Text(hostRuntimeLabel)
                .foregroundColor(.secondary)
            }
          }

          Divider()

          HStack {
            Text(languageManager.localize("Video Codec"))
            Spacer()
            Text("\(assessment.codecName) · \(assessment.chromaName)")
              .foregroundColor(.secondary)
          }

          Divider()

          HStack {
            Text(languageManager.localize("Target FPS"))
            Spacer()
            Text("\(assessment.targetFps)")
              .availableMonospacedDigit()
              .foregroundColor(.secondary)
          }

          Divider()

          HStack {
            Text(languageManager.localize("Compression Budget"))
            Spacer()
            Text("\(assessment.bpppfText) bpppf")
              .availableMonospacedDigit()
              .foregroundColor(.secondary)
          }

          Divider()

          HStack {
            Text(languageManager.localize("Pixel Rate"))
            Spacer()
            Text(assessment.pixelRateText)
              .availableMonospacedDigit()
              .foregroundColor(.secondary)
          }

          if assessment.displayRefreshRateHz > 0 {
            Divider()

            HStack {
              Text(languageManager.localize("Display Refresh"))
              Spacer()
              Text(String(format: "%.2f Hz", assessment.displayRefreshRateHz))
                .availableMonospacedDigit()
                .foregroundColor(.secondary)
            }
          }

          if let cadenceLabel = assessment.cadenceLabel, !cadenceLabel.isEmpty {
            Divider()

            HStack {
              Text(languageManager.localize("Cadence Match"))
              Spacer()
              Text(cadenceLabel)
                .foregroundColor(.secondary)
            }
          }

          if let wirelessLinkText = assessment.wirelessLinkText, !wirelessLinkText.isEmpty {
            Divider()

            HStack {
              Text(languageManager.localize("Wireless Link"))
              Spacer()
              Text(wirelessLinkText)
                .availableMonospacedDigit()
                .foregroundColor(.secondary)
            }
          }

          if !assessment.reasons.isEmpty {
            Divider()

            VStack(alignment: .leading, spacing: 6) {
              Text(languageManager.localize("Assessment Reasons"))
                .font(.footnote.weight(.semibold))
                .foregroundColor(.secondary)

              ForEach(Array(assessment.reasons.prefix(3)), id: \.self) { reason in
                Text("• \(reason)")
                  .font(.footnote)
                  .foregroundColor(.secondary)
                  .frame(maxWidth: .infinity, alignment: .leading)
              }
            }
          }

          if !assessment.recommendedFallbacks.isEmpty {
            Divider()

            VStack(alignment: .leading, spacing: 6) {
              Text(languageManager.localize("Suggested Fallbacks"))
                .font(.footnote.weight(.semibold))
                .foregroundColor(.secondary)

              ForEach(Array(assessment.recommendedFallbacks.prefix(3)), id: \.summaryLine) { recommendation in
                Text("• \(recommendation.summaryLine)")
                  .font(.footnote)
                  .foregroundColor(.secondary)
                  .frame(maxWidth: .infinity, alignment: .leading)
              }
            }
          }
        }
      } label: {
        HStack {
          Text(languageManager.localize("Analyze Current Profile"))
          Spacer()
          Text(isExpanded ? languageManager.localize("Expanded") : languageManager.localize("Tap to Analyze"))
            .font(.footnote)
            .foregroundColor(.secondary)
        }
      }
    }
  }
}

struct ToggleCell: View {
  let title: String
  let hintKey: String?
  @Binding var boolBinding: Bool
  @ObservedObject var languageManager = LanguageManager.shared

  init(title: String, hintKey: String? = nil, boolBinding: Binding<Bool>) {
    self.title = title
    self.hintKey = hintKey
    self._boolBinding = boolBinding
  }

  var body: some View {
    HStack {
      HStack(spacing: 6) {
        Text(languageManager.localize(title))
        if let hintKey {
          InfoHintButton(hintKey: hintKey)
        }
      }

      Spacer()

      Toggle("", isOn: $boolBinding)
        .toggleStyle(.switch)
        .controlSize(.small)
    }
  }
}

struct DetailedToggleSettingRow: View {
  let title: String
  let descriptionKey: String
  @Binding var boolBinding: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ToggleCell(title: title, boolBinding: $boolBinding)
      SettingDescriptionRow(textKey: descriptionKey)
    }
  }
}

struct SettingDescriptionRow: View {
  let textKey: String
  var color: Color = .secondary
  @ObservedObject var languageManager = LanguageManager.shared

  var body: some View {
    Text(languageManager.localize(textKey))
      .font(.footnote)
      .foregroundColor(color)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct InlineSectionLabel: View {
  let title: String
  @ObservedObject var languageManager = LanguageManager.shared

  var body: some View {
    Text(languageManager.localize(title))
      .font(.footnote.weight(.semibold))
      .foregroundColor(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 2)
  }
}

struct InfoHintButton: View {
  let hintKey: String
  @ObservedObject var languageManager = LanguageManager.shared
  @SwiftUI.State private var showPopover = false

  private var hintText: String {
    languageManager.localize(hintKey)
  }

  var body: some View {
    Button {
      showPopover.toggle()
    } label: {
      Image(systemName: "info.circle")
        .imageScale(.small)
        .foregroundColor(.secondary)
    }
    .buttonStyle(.plain)
    .help(hintText)
    .popover(isPresented: $showPopover, arrowEdge: .top) {
      Text(hintText)
        .font(.callout)
        .padding(10)
        .frame(maxWidth: 320, alignment: .leading)
    }
    .accessibilityLabel(Text(hintText))
  }
}

struct DimensionsInputView: View {
  @Binding var widthBinding: CGFloat?
  @Binding var heightBinding: CGFloat?
  let placeholderDimensions: CGSize

  var body: some View {
    HStack(spacing: 4) {
      TextField(
        formatDimension(placeholderDimensions.width), value: $widthBinding,
        formatter: NumberOnlyFormatter()
      )
      .multilineTextAlignment(.trailing)

      Text("×")

      TextField(
        formatDimension(placeholderDimensions.height), value: $heightBinding,
        formatter: NumberOnlyFormatter()
      )
      .multilineTextAlignment(.leading)
    }
    .textFieldStyle(.plain)
    .fixedSize()
  }

  func formatDimension(_ dimension: CGFloat) -> String {
    return "\(Int(dimension))"
  }
}

struct FormSection<Content: View>: View {
  let title: String
  let content: Content
  @ObservedObject var languageManager = LanguageManager.shared

  init(title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    GroupBox(
      content: {
        VStack {
          Group {
            content
          }
          .padding([.top], 1)
        }
        .padding([.top, .bottom], 6)
        .padding([.leading, .trailing], 6)
      },
      label: {
        Text(languageManager.localize(title))
          .font(
            .system(.body, design: .rounded)
              .weight(.semibold)
          )
          .padding(.bottom, 6)
      })
  }
}

struct FormCell<Content: View>: View {
  let title: String
  let contentWidth: CGFloat
  let content: Content
  @ObservedObject var languageManager = LanguageManager.shared

  init(title: String, contentWidth: CGFloat, @ViewBuilder content: () -> Content) {
    self.title = title
    self.contentWidth = contentWidth
    self.content = content()
  }

  var body: some View {
    HStack {
      Text(languageManager.localize(title))

      Spacer()

      content
        .if(
          contentWidth != 0,
          transform: { view in
            view
              .frame(width: contentWidth, alignment: .trailing)
          })
    }
  }
}

private struct ShortcutReferenceItem: Hashable, Identifiable {
  let action: String
  let actionKey: String

  var id: String { action }
}

struct ShortcutReferenceView: View {
  @ObservedObject var settingsModel: SettingsModel
  @ObservedObject var languageManager = LanguageManager.shared
  @SwiftUI.State private var editingItem: ShortcutReferenceItem?

  private let items: [ShortcutReferenceItem] = [
    ShortcutReferenceItem(action: StreamShortcutProfile.releaseMouseCaptureAction, actionKey: "Release mouse capture"),
    ShortcutReferenceItem(action: StreamShortcutProfile.togglePerformanceOverlayAction, actionKey: "Toggle performance overlay"),
    ShortcutReferenceItem(action: StreamShortcutProfile.toggleMouseModeAction, actionKey: "Toggle mouse mode"),
    ShortcutReferenceItem(action: StreamShortcutProfile.toggleFullscreenControlBallAction, actionKey: "Toggle fullscreen control ball"),
    ShortcutReferenceItem(action: StreamShortcutProfile.showDisconnectOptionsAction, actionKey: "Show Disconnect Options"),
    ShortcutReferenceItem(action: StreamShortcutProfile.disconnectStreamAction, actionKey: "Disconnect from Stream"),
    ShortcutReferenceItem(action: StreamShortcutProfile.closeAndQuitAppAction, actionKey: "Close and Quit App"),
    ShortcutReferenceItem(action: StreamShortcutProfile.reconnectStreamAction, actionKey: "Reconnect Stream"),
    ShortcutReferenceItem(action: StreamShortcutProfile.openControlCenterAction, actionKey: "Open control center"),
    ShortcutReferenceItem(action: StreamShortcutProfile.toggleBorderlessWindowedAction, actionKey: "Toggle borderless / windowed (advanced)"),
  ]

  init(settingsModel: SettingsModel) {
    _settingsModel = ObservedObject(wrappedValue: settingsModel)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(languageManager.localize("Stream Shortcuts"))
        .font(.subheadline.weight(.medium))

      Text(languageManager.localize("Stream shortcut note"))
        .font(.footnote)
        .foregroundColor(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)

      LazyVGrid(
        columns: [GridItem(.adaptive(minimum: 280), spacing: 12, alignment: .top)],
        alignment: .leading,
        spacing: 12
      ) {
        ForEach(items, id: \.self) { item in
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
    .buttonStyle(.plain)
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

          Text(languageManager.localize("Shortcut Translation Rules note"))
            .font(.footnote)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
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
          .buttonStyle(.link)

        Spacer()

        Button(languageManager.localize("Delete Rule"), role: .destructive, action: onDelete)
          .buttonStyle(.link)
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
      .buttonStyle(.plain)

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
        .buttonStyle(.plain)
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

extension CGSize: @retroactive Hashable {
  public func hash(into hasher: inout Hasher) {
    hasher.combine(width)
    hasher.combine(height)
  }
}

#Preview {
  if #available(macOS 13.0, *) {
    return SettingsView()
  } else {
    return Text("Not supported")
  }
}
