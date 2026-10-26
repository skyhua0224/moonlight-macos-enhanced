import AppKit
import Combine
import SwiftUI

/// CGSize is Hashable only from macOS 15. A picker whose selection or tag type
/// is CGSize cannot resolve its view type on macOS 12-14 and the settings
/// window aborts, so the resolution pickers select this value instead.
struct ResolutionChoice: Hashable {
  let width: Int
  let height: Int

  init(_ size: CGSize) {
    width = Int(size.width)
    height = Int(size.height)
  }

  var size: CGSize { CGSize(width: width, height: height) }

  static func binding(_ source: Binding<CGSize>) -> Binding<ResolutionChoice> {
    Binding(
      get: { ResolutionChoice(source.wrappedValue) },
      set: { source.wrappedValue = $0.size })
  }
}

/// Picker values that are not sizes.
enum ResolutionMenuValue {
  static let matchDisplay = SettingsModel.matchDisplayResolutionSentinel
  static let custom = CGSize.zero
  /// Free window only: open at the size the window had last time.
  static let lastWindowSize = CGSize(width: -2, height: -2)
  /// Per-screen only: no choice of its own.
  static let useDefault = CGSize(width: -3, height: -3)
}

/// One resolution menu: optional leading entries, Match Display, recent sizes,
/// the presets by aspect ratio, and Custom.
struct ResolutionMenu: View {
  @Binding var selection: CGSize
  var leading: [(size: CGSize, title: String)] = []
  let matchDisplayTitle: String
  @ObservedObject private var languageManager = LanguageManager.shared

  private var recent: [CGSize] {
    var sizes = RecentStreamResolutions.list()
    if selection.width > 0, !StreamResolution.isPreset(selection), !sizes.contains(selection) {
      sizes.insert(selection, at: 0)
    }
    return sizes
  }

  private var flatChoices: [(value: CGSize, title: String)] {
    leading.map { (value: $0.size, title: $0.title) }
      + [(value: ResolutionMenuValue.matchDisplay, title: matchDisplayTitle)]
      + recent.map { (value: $0, title: StreamResolution.label($0)) }
      + StreamResolution.presets.map { (value: $0, title: StreamResolution.label($0)) }
      + [(value: ResolutionMenuValue.custom, title: languageManager.localize("Custom…"))]
  }

  var body: some View {
    Picker("", selection: ResolutionChoice.binding($selection)) {
      ForEach(leading.map(\.size).map(ResolutionChoice.init), id: \.self) { choice in
        Text(leading.first { ResolutionChoice($0.size) == choice }?.title ?? "").tag(choice)
      }
      Text(matchDisplayTitle).tag(ResolutionChoice(ResolutionMenuValue.matchDisplay))
      if !recent.isEmpty {
        Section(header: Text(languageManager.localize("Recently Used"))) {
          ForEach(recent.map(ResolutionChoice.init), id: \.self) { choice in
            Text(StreamResolution.label(choice.size)).tag(choice)
          }
        }
      }
      ForEach(StreamResolution.presetGroups, id: \.ratio) { group in
        Section(header: Text(group.ratio)) {
          ForEach(group.sizes.map(ResolutionChoice.init), id: \.self) { choice in
            Text(StreamResolution.label(choice.size)).tag(choice)
          }
        }
      }
      Divider()
      Text(languageManager.localize("Custom…")).tag(ResolutionChoice(ResolutionMenuValue.custom))
    }
    .labelsHidden()
    .controllerPicker(selection: $selection, choices: flatChoices)
    .frame(width: 240, alignment: .trailing)
  }
}

/// The Picture section of the Streaming page: window mode, resolution, frame rate and fit.
struct PictureSection: View {
  @EnvironmentObject private var settingsModel: SettingsModel
  @ObservedObject private var languageManager = LanguageManager.shared
  @SwiftUI.State private var screens: [StreamScreen] = []
  /// The screen the settings window is on: what "Match Display" is shown for.
  @SwiftUI.State private var current: StreamScreen? = nil
  @SwiftUI.State private var isScreensSheetPresented = false

  private var mode: StreamDisplayMode { settingsModel.selectedStreamDisplayMode }
  /// Free windows need Foundation Sunshine; nil while the host has not been seen.
  private var hostLacksLiveResolution: Bool { settingsModel.audioHostIsFoundation == false }

  private func offered(_ windowModes: [String]) -> [String] {
    windowModes.filter { $0 != "Free Window" || !hostLacksLiveResolution || mode == .freeWindow }
  }

  private var matchDisplayTitle: String {
    let title = languageManager.localize("Match Display")
    guard let current else { return title }
    let size = StreamResolution.matchDisplaySize(
      on: current, mode: mode, notch: StreamNotchMode(rawValue: settingsModel.notchMode) ?? .avoid)
    return "\(title) (\(Int(size.width)) × \(Int(size.height)))"
  }

  private var matchDisplayFpsTitle: String {
    let title = languageManager.localize("Match Display")
    guard let current else { return title }
    return "\(title) · \(StreamResolution.refreshLabel(current))"
  }

  /// The free window's first entry stands for `freeWindowInitialSize == 0`.
  private var initialSizeSelection: Binding<CGSize> {
    Binding(
      get: {
        settingsModel.freeWindowInitialSize == 0
          ? ResolutionMenuValue.lastWindowSize : settingsModel.selectedResolution
      },
      set: { value in
        if value == ResolutionMenuValue.lastWindowSize {
          settingsModel.freeWindowInitialSize = 0
        } else {
          settingsModel.freeWindowInitialSize = 1
          settingsModel.selectedResolution = value
        }
      })
  }

  private var showsCustomResolution: Bool {
    settingsModel.selectedResolution == .zero
      && !(mode == .freeWindow && settingsModel.freeWindowInitialSize == 0)
  }

  private var screensWithOwnChoice: Int {
    settingsModel.screenResolutions.count
  }

  private var aspectSelection: Binding<Int> {
    Binding(
      get: { settingsModel.ignoreAspectRatio ? 1 : 0 },
      set: { settingsModel.ignoreAspectRatio = $0 == 1 })
  }

  private func refreshScreens() {
    screens = StreamScreens.known()
    current = StreamScreens.current()
  }

  var body: some View {
    FormSection(title: "Picture") {
      SettingsRow(title: "Window Mode") {
        Picker("", selection: $settingsModel.selectedDisplayMode) {
          ForEach(offered(SettingsModel.displayModeMenuOrder), id: \.self) { value in
            Text(languageManager.localize(value)).tag(value)
          }
        }
        .labelsHidden()
        .controllerPicker(
          selection: $settingsModel.selectedDisplayMode, options: offered(SettingsModel.displayModeMenuOrder),
          title: { value in languageManager.localize(value) })
        .frame(width: 240, alignment: .trailing)
      }

      if mode == .freeWindow {
        if hostLacksLiveResolution {
          SettingDescriptionRow(textKey: "Free Window needs Foundation Sunshine")
        }
        SettingsRow(title: "Initial Size") {
          ResolutionMenu(
            selection: initialSizeSelection,
            leading: [(ResolutionMenuValue.lastWindowSize, languageManager.localize("Last Window Size"))],
            matchDisplayTitle: matchDisplayTitle)
        }
      } else {
        SettingsRow(title: "Resolution") {
          ResolutionMenu(selection: $settingsModel.selectedResolution, matchDisplayTitle: matchDisplayTitle)
        }
      }

      if showsCustomResolution {
        SettingsRow(title: "Custom Resolution") {
          DimensionsInputView(
            widthBinding: $settingsModel.customResWidth,
            heightBinding: $settingsModel.customResHeight,
            placeholderDimensions: CGSize(width: 1920, height: 1080)
          )
        }
      }

      if screens.count > 1 || screensWithOwnChoice > 0 {
        SettingsRow(title: "Resolution per Screen") {
          HStack(spacing: 10) {
            if screensWithOwnChoice > 0 {
              Text(String(format: languageManager.localize("%d screens set"), screensWithOwnChoice))
                .foregroundStyle(.secondary)
            }
            Button(languageManager.localize("Set Up…")) { isScreensSheetPresented = true }
          }
        }
      }

      if mode == .borderless && screens.contains(where: \.hasNotch) {
        SettingsRow(title: "Notch") {
          Picker("", selection: $settingsModel.notchMode) {
            Text(languageManager.localize("Avoid Notch")).tag(StreamNotchMode.avoid.rawValue)
            Text(languageManager.localize("Fill Screen")).tag(StreamNotchMode.fill.rawValue)
          }
          .labelsHidden()
          .controllerPicker(
            selection: $settingsModel.notchMode,
            choices: [(StreamNotchMode.avoid.rawValue, languageManager.localize("Avoid Notch")),
                      (StreamNotchMode.fill.rawValue, languageManager.localize("Fill Screen"))])
          .pickerStyle(.segmented)
          .controlSize(.small)
          .frame(width: 210, alignment: .trailing)
        }
      }

      if mode == .freeWindow {
        SettingsRow(title: "Retina", detail: "Retina free window detail") {
          Picker("", selection: $settingsModel.freeWindowScaleMode) {
            Text(languageManager.localize("Every Pixel")).tag(FreeWindowScaleMode.pixels.rawValue)
            Text(languageManager.localize("Point Size")).tag(FreeWindowScaleMode.points.rawValue)
          }
          .labelsHidden()
          .controllerPicker(
            selection: $settingsModel.freeWindowScaleMode,
            choices: [(FreeWindowScaleMode.pixels.rawValue, languageManager.localize("Every Pixel")),
                      (FreeWindowScaleMode.points.rawValue, languageManager.localize("Point Size"))])
          .pickerStyle(.segmented)
          .controlSize(.small)
          .frame(width: 210, alignment: .trailing)
        }
      }

      if mode != .freeWindow {
        ToggleCell(title: "Resolution Scale", hintKey: "Resolution Scale hint", boolBinding: $settingsModel.streamResolutionScale)
      }

      if mode != .freeWindow && settingsModel.streamResolutionScale {
        SettingsRow(title: "Resolution Scale Ratio") {
          Picker("", selection: $settingsModel.streamResolutionScaleRatio) {
            Text("50%").tag(50)
            Text("75%").tag(75)
            Text("100%").tag(100)
          }
          .labelsHidden()
          .controllerPicker(
            selection: $settingsModel.streamResolutionScaleRatio, options: [50, 75, 100], title: { "\($0)%" })
          .frame(width: 130, alignment: .trailing)
        }
      }

      SettingsRow(title: "Frame Rate") {
        Picker("", selection: $settingsModel.selectedFps) {
          Text(matchDisplayFpsTitle).tag(StreamResolution.matchDisplayFps)
          Divider()
          ForEach(SettingsModel.fpss.filter { $0 > 0 }, id: \.self) { fps in
            Text("\(fps) Hz").tag(fps)
          }
          Divider()
          Text(languageManager.localize("Custom…")).tag(0)
        }
        .labelsHidden()
        .controllerPicker(
          selection: $settingsModel.selectedFps, options: SettingsModel.fpss,
          title: { fps in
            fps == StreamResolution.matchDisplayFps ? matchDisplayFpsTitle
              : fps == 0 ? languageManager.localize("Custom…") : "\(fps) Hz"
          })
        .frame(width: 240, alignment: .trailing)
      }

      if settingsModel.selectedFps == 0 {
        SettingsRow(title: "Custom FPS") {
          TextField("60", value: $settingsModel.customFps, formatter: NumberOnlyFormatter())
            .multilineTextAlignment(.trailing)
            .controllerNumericField()
            .textFieldStyle(.roundedBorder)
            .frame(width: 90)
        }
      }

      SettingsRow(title: "Picture Aspect") {
        Picker("", selection: aspectSelection) {
          Text(languageManager.localize("Keep Aspect")).tag(0)
          Text(languageManager.localize("Stretch to Fill")).tag(1)
        }
        .labelsHidden()
        .controllerPicker(
          selection: aspectSelection,
          choices: [(0, languageManager.localize("Keep Aspect")), (1, languageManager.localize("Stretch to Fill"))])
        .pickerStyle(.segmented)
        .controlSize(.small)
        .frame(width: 210, alignment: .trailing)
      }
    }
    .onAppear(perform: refreshScreens)
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
      refreshScreens()
    }
    .sheet(isPresented: $isScreensSheetPresented) {
      ScreenResolutionsSheet(isPresented: $isScreensSheetPresented)
        .environmentObject(settingsModel)
    }
  }
}

/// Resolution chosen per screen; a screen without a choice of its own uses the Picture section's.
struct ScreenResolutionsSheet: View {
  // settings-search: ignore
  @Binding var isPresented: Bool
  @EnvironmentObject private var settingsModel: SettingsModel
  @ObservedObject private var languageManager = LanguageManager.shared
  @SwiftUI.State private var screens: [StreamScreen] = []
  @SwiftUI.State private var connectedIDs: Set<String> = []
  /// Screens whose menu is on Custom while the size is being typed.
  @SwiftUI.State private var customSizes: [String: (width: CGFloat?, height: CGFloat?)] = [:]

  private func selection(for screen: StreamScreen) -> Binding<CGSize> {
    Binding(
      get: {
        if customSizes[screen.id] != nil { return ResolutionMenuValue.custom }
        return settingsModel.screenResolutions[screen.id] ?? ResolutionMenuValue.useDefault
      },
      set: { value in
        if value == ResolutionMenuValue.custom {
          let own = settingsModel.screenResolutions[screen.id]
          customSizes[screen.id] = (own.map { $0.width > 0 ? $0.width : nil } ?? nil,
                                    own.map { $0.height > 0 ? $0.height : nil } ?? nil)
          return
        }
        customSizes[screen.id] = nil
        if value == ResolutionMenuValue.useDefault {
          settingsModel.screenResolutions[screen.id] = nil
        } else {
          settingsModel.screenResolutions[screen.id] = value
        }
      })
  }

  private func customBinding(_ screen: StreamScreen, width: Bool) -> Binding<CGFloat?> {
    Binding(
      get: { width ? customSizes[screen.id]?.width : customSizes[screen.id]?.height },
      set: { value in
        var entry = customSizes[screen.id] ?? (nil, nil)
        if width { entry.width = value } else { entry.height = value }
        customSizes[screen.id] = entry
        if let w = entry.width, let h = entry.height, w >= 64, h >= 64 {
          settingsModel.screenResolutions[screen.id] = CGSize(
            width: StreamScreen.even(w), height: StreamScreen.even(h))
        }
      })
  }

  private func matchDisplayTitle(_ screen: StreamScreen) -> String {
    let size = StreamResolution.matchDisplaySize(
      on: screen, mode: settingsModel.selectedStreamDisplayMode,
      notch: StreamNotchMode(rawValue: settingsModel.notchMode) ?? .avoid)
    return "\(languageManager.localize("Match Display")) (\(Int(size.width)) × \(Int(size.height)))"
  }

  private func summary(_ screen: StreamScreen) -> String {
    var parts = ["\(Int(screen.fullPixels.width)) × \(Int(screen.fullPixels.height))",
                 StreamResolution.refreshLabel(screen)]
    if !connectedIDs.contains(screen.id) {
      parts.append(languageManager.localize("Not Connected"))
    }
    return parts.joined(separator: " · ")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(languageManager.localize("Resolution per Screen"))
        .font(.headline)

      VStack(alignment: .leading, spacing: 0) {
        ForEach(screens) { screen in
          VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
              Image(systemName: screen.isBuiltin ? "laptopcomputer" : "display")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 30)
              VStack(alignment: .leading, spacing: 2) {
                Text(screen.name)
                Text(summary(screen))
                  .font(.footnote)
                  .foregroundStyle(.secondary)
              }
              Spacer(minLength: 12)
              ResolutionMenu(
                selection: selection(for: screen),
                leading: [(ResolutionMenuValue.useDefault, languageManager.localize("Use Picture Setting"))],
                matchDisplayTitle: matchDisplayTitle(screen))
              if !connectedIDs.contains(screen.id) {
                Button {
                  settingsModel.screenResolutions[screen.id] = nil
                  StreamScreens.forget(screen.id)
                  screens = StreamScreens.known()
                } label: {
                  Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help(languageManager.localize("Forget Screen"))
              }
            }
            if customSizes[screen.id] != nil {
              HStack {
                Spacer()
                DimensionsInputView(
                  widthBinding: customBinding(screen, width: true),
                  heightBinding: customBinding(screen, width: false),
                  placeholderDimensions: screen.fullPixels)
              }
            }
          }
          .padding(.vertical, 9)
          .overlay(alignment: .bottom) { Divider().opacity(0.45) }
        }
      }
      .padding(.horizontal, 12)
      .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

      HStack {
        Spacer()
        Button(languageManager.localize("Done")) { isPresented = false }
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(minWidth: 620)
    .onAppear {
      connectedIDs = Set(StreamScreens.connected().map(\.id))
      screens = StreamScreens.known()
    }
  }
}
