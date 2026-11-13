//
//  OverlaySettingsPage.swift
//  The 「性能 HUD」 page of the settings window: a live preview of the real HUD over a sample frame, and every choice
//  that changes it (style, position, items, background opacity, size, shortcuts). A change shows in the preview at once,
//  because the preview draws the same OverlayRoot from the same OverlayPrefs the stream uses.
//

import AppKit
import SwiftUI

// MARK: - Preview

/// Feeds the preview's model with sample values twice a second, like the stats of a real stream.
@available(macOS 14.0, *)
final class OverlayPreviewFeed: ObservableObject {
  let model = OverlayModel()
  var showWarning = false { didSet { applyWarning() } }
  private var tick = 0
  private var timer: Timer?

  init() {
    model.geometry = OverlayGeometry(width: 700, height: 200, safeTop: 0, bottomInset: OverlayGeometry.topMargin)
    for t in 0..<96 { model.apply(OverlaySample.metrics(tick: t, anomaly: false), now: Date().addingTimeInterval(Double(t) * 0.5 - 48)) }
    tick = 96
  }

  func start() {
    guard timer == nil else { return }
    timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
      guard let self else { return }
      self.tick += 1
      self.model.apply(OverlaySample.metrics(tick: self.tick, anomaly: false))
      self.applyWarning()
    }
  }

  func stop() { timer?.invalidate(); timer = nil }

  private func applyWarning() {
    let lines = showWarning ? [OverlayModel.text(.netLoss(percent: 3.2))] : []
    if model.anomalies != lines { model.anomalies = lines }
  }

  deinit { timer?.invalidate() }
}

/// A made-up game frame, bright (daylight sky) or dark (night street), so the panel is judged over both.
@available(macOS 14.0, *)
struct OverlaySampleFrame: View {
  let bright: Bool
  var body: some View {
    Canvas { ctx, size in
      let w = size.width, h = size.height
      let sky = bright
        ? Gradient(colors: [Color(red: 0.45, green: 0.72, blue: 0.98), Color(red: 0.97, green: 0.94, blue: 0.84)])
        : Gradient(colors: [Color(red: 0.02, green: 0.03, blue: 0.09), Color(red: 0.13, green: 0.15, blue: 0.30)])
      ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(sky, startPoint: .zero, endPoint: CGPoint(x: 0, y: h * 0.75)))
      // sun or moon
      let body = CGRect(x: w * 0.74, y: h * 0.12, width: h * 0.16, height: h * 0.16)
      ctx.fill(Path(ellipseIn: body), with: .color(bright ? Color.white.opacity(0.95) : Color(red: 0.92, green: 0.93, blue: 1.0).opacity(0.9)))
      if bright {
        for (x, y, r) in [(0.18, 0.2, 0.07), (0.42, 0.1, 0.05), (0.58, 0.26, 0.06)] {
          ctx.fill(Path(ellipseIn: CGRect(x: w * x, y: h * y, width: w * r * 2.2, height: h * r)), with: .color(Color.white.opacity(0.85)))
        }
        for (x, base, scale) in [(0.0, 0.78, 0.5), (0.35, 0.82, 0.6), (0.7, 0.76, 0.5)] {
          var hill = Path()
          hill.move(to: CGPoint(x: w * x, y: h))
          hill.addQuadCurve(to: CGPoint(x: w * (x + scale), y: h), control: CGPoint(x: w * (x + scale / 2), y: h * (base - 0.2)))
          ctx.fill(hill, with: .color(Color(red: 0.36, green: 0.62, blue: 0.34)))
        }
      } else {
        var x = 0.0
        var i = 0
        while x < w {
          let bw = w * (0.05 + Double((i * 7) % 5) * 0.01), bh = h * (0.25 + Double((i * 13) % 7) * 0.06)
          ctx.fill(Path(CGRect(x: x, y: h - bh, width: bw, height: bh)), with: .color(Color(red: 0.05, green: 0.06, blue: 0.12)))
          var wy = h - bh + 10
          while wy < h - 12 {
            if (Int(wy) + i * 3) % 4 != 0 { ctx.fill(Path(CGRect(x: x + bw * 0.2, y: wy, width: 6, height: 8)), with: .color(Color(red: 1, green: 0.85, blue: 0.5).opacity(0.7))) }
            wy += 26
          }
          x += bw + 3; i += 1
        }
      }
    }
  }
}

@available(macOS 14.0, *)
struct OverlayPreviewCard: View {
  /// The card is small and stays at the top of the page while the settings below scroll, so every change is seen at once.
  static let height: CGFloat = 200
  @ObservedObject var prefs: OverlayPrefs
  @StateObject private var feed = OverlayPreviewFeed()
  @SwiftUI.State private var bright = conceptEnv("MLC_OV_PREVIEW") != "dark"
  @SwiftUI.State private var warning = conceptEnv("MLC_OV_PREVIEW_WARN") == "1"
  @SwiftUI.State private var panel = CGSize.zero
  @ObservedObject private var languageManager = LanguageManager.shared

  /// The HUD is drawn at its real size. Only a panel taller than the card (corner list, chart with many items) is
  /// scaled down to fit, never below 30 %.
  private func fit(_ card: CGSize) -> CGFloat {
    // a stream window is wide: the card shows at least this much width, so a compact bar stays on one row as it does there
    let byWidth = min(1, card.width / 800)
    guard panel.height > 0 else { return byWidth }
    return min(byWidth, max(0.3, (card.height - 2 * OverlayGeometry.topMargin) / panel.height))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      GeometryReader { geo in
        let f = fit(geo.size)
        let canvas = CGSize(width: geo.size.width / f, height: geo.size.height / f)
        ZStack(alignment: .topLeading) {
          OverlaySampleFrame(bright: bright)
          OverlayRoot(model: feed.model, prefs: prefs)
            .frame(width: canvas.width, height: canvas.height)
            .scaleEffect(f, anchor: .topLeading)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .onChange(of: canvas, initial: true) { _, size in
          feed.model.geometry = OverlayGeometry(width: size.width, height: size.height, safeTop: 0, bottomInset: OverlayGeometry.topMargin)
        }
      }
      .frame(height: Self.height)
      .onPreferenceChange(OverlayPanelSizeKey.self) { panel = $0 }
      HStack(spacing: 14) {
        Picker("", selection: $bright) {
          Text(languageManager.localize("ov.preview.bright")).tag(true)
          Text(languageManager.localize("ov.preview.dark")).tag(false)
        }
        .pickerStyle(.segmented).labelsHidden().frame(width: 170)
        Toggle(languageManager.localize("ov.preview.warning"), isOn: $warning).toggleStyle(.checkbox)
        Spacer(minLength: 0)
      }
    }
    .onAppear { feed.model.reportsSize = true; feed.start(); feed.showWarning = warning }
    .onDisappear { feed.stop() }
    .onChange(of: warning) { _, value in feed.showWarning = value }
  }
}

// MARK: - Position picker

/// The six places, drawn on a small screen; a click picks one.
@available(macOS 14.0, *)
struct OverlayPositionPicker: View {
  @ObservedObject var prefs: OverlayPrefs

  private func spot(_ position: OverlayPosition, _ alignment: Alignment) -> some View {
    let selected = prefs.position == position
    return Button { prefs.positionRaw = position.rawValue } label: {
      Capsule().fill(selected ? Color.accentColor : Color.secondary.opacity(0.35)).frame(width: 26, height: 9)
        .padding(4).contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(position.title)
    .accessibilityLabel(position.title)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
  }

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(nsColor: .windowBackgroundColor))
      RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1)
      ForEach(OverlayPosition.allCases, id: \.self) { spot($0, $0.alignment) }
    }
    .frame(width: 116, height: 70)
  }
}

// MARK: - The list of items

/// The items that are shown, in the order they have in the HUD: drag a row to move it, the minus takes it out. Items that
/// are not shown are added from the menu below the list, by group.
@available(macOS 14.0, *)
struct OverlayItemList: View {
  @ObservedObject var prefs: OverlayPrefs
  @ObservedObject private var languageManager = LanguageManager.shared
  static let rowHeight: CGFloat = 30
  static let headerHeight: CGFloat = 34

  private func row(_ field: OverlayField) -> some View {
    let fits = prefs.style.reason(for: field, selection: prefs.fields) == nil
    return HStack(spacing: 8) {
      Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
      Image(systemName: field.symbol).frame(width: 18).foregroundStyle(.secondary)
      Text(field.title)
      Text(field.group.title).font(.footnote).foregroundStyle(.tertiary)
      Spacer(minLength: 8)
      Button { prefs.toggle(field) } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
        .buttonStyle(.plain).help(languageManager.localize("ov.items.remove"))
    }
    .frame(height: Self.rowHeight - 6)
    .opacity(fits ? 1 : 0.45)
    .help(fits ? "" : languageManager.localize("ov.items.noRoom"))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      List {
        Section {
          ForEach(prefs.fields, id: \.self) { row($0) }.onMove { prefs.moveFields(from: $0, to: $1) }
        } header: {
          Text(languageManager.localize("ov.items.shown"))
        }
      }
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
      .scrollDisabled(true)
      .frame(height: CGFloat(prefs.fields.count) * Self.rowHeight + Self.headerHeight + 8)
      Menu {
        ForEach(OverlayGroup.allCases, id: \.self) { group in
          let missing = OverlayField.allCases.filter { $0.group == group && !prefs.fields.contains($0) }
          if !missing.isEmpty {
            Menu(group.title) {
              ForEach(missing, id: \.self) { field in
                Button { prefs.toggle(field) } label: { Label(field.title, systemImage: field.symbol) }
                  .disabled(prefs.style.reason(for: field, selection: prefs.fields) != nil)
              }
            }
          }
        }
      } label: {
        Label(languageManager.localize("ov.items.add"), systemImage: "plus")
      }
      .menuStyle(.borderlessButton).fixedSize()
      .padding(.vertical, 8)
    }
  }
}

// MARK: - The page

@available(macOS 14.0, *)
struct OverlayView: View {
  @EnvironmentObject private var settingsModel: SettingsModel
  @ObservedObject private var languageManager = LanguageManager.shared
  @ObservedObject private var prefs = OverlayPrefs.shared
  @SwiftUI.State private var editingItem: ShortcutReferenceItem?
  @StateObject private var tester = OverlayShortcutTester()

  private func presetButton(_ title: String, _ fields: [OverlayField]) -> some View {
    Button(title) { prefs.choose(fields) }.buttonStyle(.bordered).controlSize(.small)
  }

  private func shortcutRow(_ action: String) -> some View {
    let shortcut = settingsModel.shortcut(for: action)
    return VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 10) {
        Text(languageManager.localize(StreamShortcutProfile.actionTitleKey(for: action)))
        Spacer(minLength: 8)
        ShortcutTokenRowView(tokens: StreamShortcutProfile.displayTokens(for: shortcut))
        Button(languageManager.localize("Test Shortcut")) { tester.start(action: action, shortcut: shortcut) }
          .buttonStyle(.bordered).controlSize(.small)
        Button(languageManager.localize("Change Shortcut")) { editingItem = ShortcutReferenceItem(action: action, actionKey: StreamShortcutProfile.actionTitleKey(for: action)) }
          .buttonStyle(.bordered).controlSize(.small)
      }
      if tester.action == action, let line = tester.message(language: languageManager) {
        Text(line).font(.footnote).foregroundStyle(tester.isFailure ? Color.orange : Color.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.vertical, 8)
  }

  var body: some View {
    VStack(spacing: 0) {
      // pinned: only what is below it scrolls
      OverlayPreviewCard(prefs: prefs)
        .frame(maxWidth: 760)
        .padding(.horizontal, 28).padding(.top, 16).padding(.bottom, 10)
        .frame(maxWidth: .infinity)
      Divider()
      SettingsContent {
        FormSection(title: "HUD Appearance") {
          SettingsRow(title: "HUD Style") {
            Picker("", selection: $prefs.style) { ForEach(OverlayStyle.choosable, id: \.self) { Text($0.title).tag($0) } }
              .pickerStyle(.segmented).labelsHidden().frame(width: 240)
          }
          SettingsRow(title: "HUD Position") { OverlayPositionPicker(prefs: prefs).padding(.vertical, 8) }
          if prefs.position.isBottom {
            Text(languageManager.localize("ov.settings.bottomNote")).font(.footnote).foregroundStyle(.secondary).padding(.vertical, 6)
          }
          SettingsRow(title: "HUD Panel Opacity") {
            HStack {
              Slider(value: $prefs.plateOpacity, in: OverlayPrefs.plateRange).frame(width: 170)
              Text("\(Int((prefs.plateOpacity * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
            }
          }
          SettingsRow(title: "HUD Size") {
            HStack {
              Slider(value: $prefs.scale, in: OverlayPrefs.scaleRange).frame(width: 170)
              Text("\(Int((prefs.scale * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
            }
          }
        }

        FormSection(title: "HUD Behaviour") {
          ToggleCell(title: "Show Performance Overlay", boolBinding: $settingsModel.showPerformanceOverlay)
          ToggleCell(title: "HUD Fade When Quiet", boolBinding: $prefs.autoFade)
          ToggleCell(title: "HUD Warn On Problems", boolBinding: $prefs.expandOnAnomaly)
          ToggleCell(title: "HUD Split At Notch", boolBinding: $prefs.notchSplit)
        }

        FormSection(title: "HUD Items") {
          HStack(spacing: 8) {
            presetButton(languageManager.localize("ov.preset.minimal"), OverlayField.minimal)
            presetButton(languageManager.localize("ov.preset.usual"), OverlayField.usual)
            presetButton(languageManager.localize("ov.preset.all"), OverlayField.allCases)
            Spacer()
            Text(String(format: languageManager.localize("ov.settings.count"), prefs.fields.count)).font(.footnote).foregroundStyle(.secondary)
          }
          .padding(.vertical, 8)
          OverlayItemList(prefs: prefs)
          Text(languageManager.localize("ov.settings.fieldsNote")).font(.footnote).foregroundStyle(.secondary).padding(.vertical, 8)
        }

        FormSection(title: "HUD Shortcuts") {
          shortcutRow(StreamShortcutProfile.togglePerformanceOverlayAction)
          Divider().opacity(0.45)
          shortcutRow(StreamShortcutProfile.cyclePerformanceOverlayStyleAction)
          Text(languageManager.localize("ov.settings.shortcutNote")).font(.footnote).foregroundStyle(.secondary).padding(.vertical, 8)
        }

        HStack {
          Spacer()
          Button(languageManager.localize("Reset HUD Settings")) { prefs.resetToDefaults() }.buttonStyle(.bordered)
        }
      }
    }
    .sheet(item: $editingItem) { item in
      ShortcutCaptureSheet(settingsModel: settingsModel, item: item)
    }
    .onDisappear { tester.stop() }
  }
}

// MARK: - Shortcut test

/// Listens for one shortcut for a few seconds and says whether it reached this app. A key another process took (an
/// active event tap in the key path) never arrives; then the page names the processes that could have taken it.
@available(macOS 14.0, *)
final class OverlayShortcutTester: ObservableObject {
  enum State: Equatable { case idle, listening, arrived, missing([String]) }
  @Published private(set) var state = State.idle
  @Published private(set) var action: String?
  private var monitor: Any?
  private var timer: Timer?
  private var shortcut: StreamShortcut?

  var isFailure: Bool { if case .missing = state { return true } else { return false } }

  func start(action: String, shortcut: StreamShortcut) {
    stop()
    self.action = action
    self.shortcut = shortcut
    state = .listening
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, let target = self.shortcut else { return event }
      if Int(event.keyCode) == target.keyCode && OverlayShortcutRules.same(event.modifierFlags, target.modifierFlags) {
        self.finish(arrived: true)
        return nil
      }
      return event
    }
    timer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in self?.finish(arrived: false) }
  }

  private func finish(arrived: Bool) {
    removeListeners()
    switch OverlayShortcutRules.testResult(arrived: arrived, taps: OverlayShortcutRules.installedTaps(), ownPid: getpid()) {
    case .arrived: state = .arrived
    case .missing(let candidates): state = .missing(candidates)
    }
  }

  func stop() {
    removeListeners()
    state = .idle
    action = nil
  }

  private func removeListeners() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    timer?.invalidate(); timer = nil
  }

  func message(language: LanguageManager) -> String? {
    switch state {
    case .idle: return nil
    case .listening:
      let tokens = shortcut.map { StreamShortcutProfile.displayTokens(for: $0).joined() } ?? ""
      return String(format: language.localize("ov.test.listening"), tokens)
    case .arrived: return language.localize("ov.test.arrived")
    case .missing(let candidates):
      let list = candidates.isEmpty ? language.localize("ov.test.noCandidates") : candidates.joined(separator: ", ")
      return String(format: language.localize("ov.test.missing"), list)
    }
  }

  deinit { removeListeners() }
}

@objc(MLOverlayShortcutDiagnostics)
public final class OverlayShortcutDiagnostics: NSObject {
  /// The line the stream writes to the log at its start: which other processes hold an active key tap.
  @objc public static func keyPathLine() -> String {
    OverlayShortcutRules.logLine(owners: OverlayShortcutRules.keyTapOwners(OverlayShortcutRules.installedTaps(), excluding: getpid()))
  }
}

/// The pane's root: the page needs macOS 14 (SwiftUI Layout, Grid); below it the pane is empty.
struct OverlayPaneRoot: View {
  var body: some View {
    if #available(macOS 14.0, *) { OverlayView() } else { EmptyView() }
  }
}
