import AppKit
import SwiftUI

// MARK: - Search navigation

/// The one place that defines how a settings row or section is identified for
/// scrolling. Rows and section components attach these ids through the
/// `settingsSearch...` modifiers below; a search result is turned into the same
/// id by `id(for:)`. Both sides use only constant keys (section title and row
/// title as written in the source), so the ids never change while the user
/// edits a control.
enum SettingsSearchScrollID {
  /// Anchor at the top of a pane's scroll content (pane-level results).
  static let top = "settings-search.top"

  private static let separator = "\u{1F}"

  static func row(section: String, title: String) -> String {
    "row" + separator + section + separator + title
  }

  static func section(_ title: String) -> String {
    "section" + separator + title
  }

  /// nil means "scroll to the top of the pane".
  static func id(for entry: SettingsSearchEntry) -> String? {
    switch entry.kind {
    case .pane: return nil
    case .section: return section(entry.titleKey)
    case .row: return row(section: entry.sectionKey, title: entry.titleKey)
    }
  }
}

struct SettingsSearchRequest: Equatable {
  let token: Int
  let pane: SettingsPaneType
  let scrollID: String?
  let alignsToTop: Bool
}

/// Holds the search result the user picked until the destination pane has
/// scrolled to it. The request is consumed once, and it expires on its own, so
/// it can never fire later when a hidden row appears.
final class SettingsSearchNavigator: ObservableObject {
  static let shared = SettingsSearchNavigator()

  @Published private(set) var request: SettingsSearchRequest?
  /// The row or section that is currently tinted after a scroll.
  @Published private(set) var highlightedID: String?

  private var counter = 0
  private var highlightWork: DispatchWorkItem?

  private init() {}

  func navigate(to entry: SettingsSearchEntry) {
    counter += 1
    let token = counter
    request = SettingsSearchRequest(
      token: token,
      pane: entry.pane,
      scrollID: SettingsSearchScrollID.id(for: entry),
      alignsToTop: entry.kind == .section)
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
      if self?.request?.token == token { self?.request = nil }
    }
  }

  func consume(_ token: Int) {
    if request?.token == token { request = nil }
  }

  func flash(_ id: String) {
    highlightWork?.cancel()
    withAnimation(.easeIn(duration: 0.2)) { highlightedID = id }
    let work = DispatchWorkItem { [weak self] in
      withAnimation(.easeOut(duration: 0.8)) { self?.highlightedID = nil }
    }
    highlightWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
  }
}

private struct SettingsSearchPaneKey: EnvironmentKey {
  static let defaultValue: SettingsPaneType? = nil
}

private struct SettingsSearchSectionKey: EnvironmentKey {
  static let defaultValue: String = ""
}

private struct SettingsSearchTargetEnabledKey: EnvironmentKey {
  static let defaultValue: Bool = true
}

extension EnvironmentValues {
  /// The pane whose content is being drawn (set by the settings detail view).
  var settingsSearchPane: SettingsPaneType? {
    get { self[SettingsSearchPaneKey.self] }
    set { self[SettingsSearchPaneKey.self] = newValue }
  }

  /// The title of the enclosing section, or the pane title outside a section.
  var settingsSearchSection: String {
    get { self[SettingsSearchSectionKey.self] }
    set { self[SettingsSearchSectionKey.self] = newValue }
  }

  var settingsSearchTargetEnabled: Bool {
    get { self[SettingsSearchTargetEnabledKey.self] }
    set { self[SettingsSearchTargetEnabledKey.self] = newValue }
  }
}

/// Gives a view its scroll id and the brief tint shown after a search jump.
private struct SettingsSearchAnchorModifier: ViewModifier {
  let anchorID: String
  @ObservedObject private var navigator = SettingsSearchNavigator.shared

  func body(content: Content) -> some View {
    content
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(Color.accentColor.opacity(navigator.highlightedID == anchorID ? 0.16 : 0))
          .allowsHitTesting(false)
      )
      .id(anchorID)
  }
}

private struct SettingsSearchRowModifier: ViewModifier {
  let title: String
  @Environment(\.settingsSearchSection) private var section
  @Environment(\.settingsSearchTargetEnabled) private var enabled

  @ViewBuilder
  func body(content: Content) -> some View {
    if enabled {
      content.modifier(SettingsSearchAnchorModifier(
        anchorID: SettingsSearchScrollID.row(section: section, title: title)))
    } else {
      content
    }
  }
}

private struct SettingsSearchSectionModifier: ViewModifier {
  let title: String?

  @ViewBuilder
  func body(content: Content) -> some View {
    if let title {
      content
        .environment(\.settingsSearchSection, title)
        .modifier(SettingsSearchAnchorModifier(anchorID: SettingsSearchScrollID.section(title)))
    } else {
      content
    }
  }
}

extension View {
  /// Marks a settings row so a search result can scroll to it. Row components
  /// apply this themselves; use it directly only for a custom row.
  func settingsSearchRow(title: String) -> some View {
    modifier(SettingsSearchRowModifier(title: title))
  }

  /// Marks a custom control that has a `// settings-search: entry "Title"`
  /// marker. The generator checks that the marker and this call agree.
  func settingsSearchEntry(_ title: String) -> some View {
    modifier(SettingsSearchRowModifier(title: title))
  }

  /// Names the section that the rows inside belong to, and makes the section
  /// itself a scroll target. A nil title leaves the surrounding section alone.
  func settingsSearchSection(_ title: String?) -> some View {
    modifier(SettingsSearchSectionModifier(title: title))
  }

  /// For a second row that shares its title and section with an earlier row:
  /// only the first one is the scroll target.
  func settingsSearchTargetSuppressed() -> some View {
    environment(\.settingsSearchTargetEnabled, false)
  }
}

/// A vertical scroll view that scrolls to the settings search result the user
/// picked. The scroll runs after the pane's views have been laid out.
struct SettingsSearchScrollView<Content: View>: View {
  let content: Content
  @Environment(\.settingsSearchPane) private var pane

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        content.id(SettingsSearchScrollID.top)
      }
      .onAppear { handle(SettingsSearchNavigator.shared.request, proxy: proxy) }
      .onReceive(SettingsSearchNavigator.shared.$request) { request in
        handle(request, proxy: proxy)
      }
    }
  }

  private func handle(_ request: SettingsSearchRequest?, proxy: ScrollViewProxy) {
    guard let request = request, let currentPane = pane, request.pane == currentPane else { return }
    let token = request.token
    // The destination pane was just created; give it one layout pass first.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
      let navigator = SettingsSearchNavigator.shared
      guard navigator.request?.token == token else { return }
      navigator.consume(token)
      guard let id = request.scrollID else {
        proxy.scrollTo(SettingsSearchScrollID.top, anchor: .top)
        return
      }
      withAnimation(.easeInOut(duration: 0.3)) {
        proxy.scrollTo(id, anchor: request.alignsToTop ? .top : .center)
      }
      navigator.flash(id)
    }
  }
}

/// Shared macOS settings composition. Pages use one centered content column,
/// native group surfaces, and a consistent label/value row.
struct SettingsContent<Content: View>: View {
  let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    SettingsSearchScrollView {
      VStack(alignment: .leading, spacing: 20) {
        content
      }
      .frame(maxWidth: 760, alignment: .leading)
      .padding(.horizontal, 28)
      .padding(.vertical, 22)
      .frame(maxWidth: .infinity, alignment: .center)
    }
  }
}

struct FormSection<Content: View, Accessory: View>: View {
  let title: String
  let content: Content
  let accessory: Accessory
  @ObservedObject private var languageManager = LanguageManager.shared

  /// `accessory` sits at the trailing end of the title line, for an action on the whole section.
  init(title: String, @ViewBuilder content: () -> Content, @ViewBuilder accessory: () -> Accessory) {
    self.title = title
    self.content = content()
    self.accessory = accessory()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(LocalizedStringKey(title))
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.secondary)
          .padding(.leading, 2)
        Spacer(minLength: 0)
        accessory
      }

      VStack(alignment: .leading, spacing: 0) {
        content
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 2)
      .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
    .settingsSearchSection(title)
  }
}

extension FormSection where Accessory == EmptyView {
  init(title: String, @ViewBuilder content: () -> Content) {
    self.init(title: title, content: content, accessory: { EmptyView() })
  }
}

struct SystemSettingsGroup<Content: View>: View {
  let title: String?
  let content: Content
  @ObservedObject private var languageManager = LanguageManager.shared

  init(title: String? = nil, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      if let title {
        Text(LocalizedStringKey(title))
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.secondary)
      }
      VStack(alignment: .leading, spacing: 0) { content }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
    .settingsSearchSection(title)
  }
}

struct SettingsRow<Content: View>: View {
  let title: String
  let detail: String?
  let content: Content
  @ObservedObject private var languageManager = LanguageManager.shared

  init(title: String, detail: String? = nil, @ViewBuilder content: () -> Content) {
    self.title = title
    self.detail = detail
    self.content = content()
  }

  @ViewBuilder
  var body: some View {
    Group {
      HStack(alignment: .center, spacing: 20) {
        rowLabel
        Spacer(minLength: 18)
        content.frame(maxWidth: .infinity, alignment: .trailing)
      }
      .frame(minHeight: 36)
      .overlay(alignment: .bottom) {
        Divider().opacity(0.45)
      }
    }
    .settingsSearchRow(title: title)
  }

  private var rowLabel: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(LocalizedStringKey(title))
        .fixedSize(horizontal: false, vertical: true)
      if let detail, !detail.isEmpty {
        Text(LocalizedStringKey(detail))
          .font(.footnote)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

struct FormCell<Content: View>: View {
  let title: String
  let contentWidth: CGFloat
  let content: Content

  init(title: String, contentWidth: CGFloat = 0, @ViewBuilder content: () -> Content) {
    self.title = title
    self.contentWidth = contentWidth
    self.content = content()
  }

  var body: some View {
    SettingsRow(title: title) {
      content.frame(width: contentWidth > 0 ? contentWidth : nil, alignment: .trailing)
    }
  }
}

struct ToggleCell: View {
  let title: String
  let hintKey: String?
  @Binding var boolBinding: Bool

  init(title: String, hintKey: String? = nil, boolBinding: Binding<Bool>) {
    self.title = title
    self.hintKey = hintKey
    self._boolBinding = boolBinding
  }

  var body: some View {
    SettingsRow(title: title) {
      HStack(spacing: 6) {
        if let hintKey {
          InfoHintButton(hintKey: hintKey)
        }
        Toggle("", isOn: $boolBinding)
          .labelsHidden()
          .toggleStyle(.switch)
          .focusable()
          .controlSize(.small)
      }
    }
  }
}

struct PickerSettingRow<Content: View>: View {
  let title: String
  let detailKey: String?
  let content: Content

  init(title: String, detailKey: String? = nil, @ViewBuilder content: () -> Content) {
    self.title = title
    self.detailKey = detailKey
    self.content = content()
  }

  var body: some View {
    SettingsRow(title: title, detail: detailKey) { content }
  }
}

struct SettingDescriptionRow: View {
  let textKey: String
  @ObservedObject private var languageManager = LanguageManager.shared

  var body: some View {
    Text(languageManager.localize(textKey))
      .font(.footnote)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 7)
  }
}

struct InlineSectionLabel: View {
  let title: String

  var body: some View {
    Text(LocalizedStringKey(title))
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(.secondary)
      .padding(.top, 8)
      .padding(.bottom, 4)
  }
}

struct InfoHintButton: View {
  let hintKey: String
  var systemImage: String = "info.circle"
  var tint: Color = .secondary
  @ObservedObject private var languageManager = LanguageManager.shared
  @SwiftUI.State private var isPresented = false

  var body: some View {
    Button { isPresented.toggle() } label: {
      Image(systemName: systemImage)
        .foregroundStyle(tint)
    }
    .controllerButtonStyle(.plain)
    .popover(isPresented: $isPresented) {
      Text(languageManager.localize(hintKey))
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .padding(12)
        .frame(width: 300, alignment: .leading)
    }
    .help(languageManager.localize(hintKey))
  }
}

struct DimensionsInputView: View {
  @Binding var widthBinding: CGFloat?
  @Binding var heightBinding: CGFloat?
  let placeholderDimensions: CGSize

  var body: some View {
    HStack(spacing: 5) {
      TextField("\(Int(placeholderDimensions.width))", value: $widthBinding, formatter: NumberOnlyFormatter())
        .multilineTextAlignment(.trailing)
        .controllerNumericField()
      Text("×").foregroundStyle(.secondary)
      TextField("\(Int(placeholderDimensions.height))", value: $heightBinding, formatter: NumberOnlyFormatter())
        .multilineTextAlignment(.leading)
        .controllerNumericField()
    }
    .textFieldStyle(.roundedBorder)
    .frame(width: 165)
  }
}

struct SettingsStatusRow: View {
  let title: String
  let value: String
  let tint: Color

  var body: some View {
    SettingsRow(title: title) {
      Text(value)
        .font(.callout)
        .foregroundStyle(tint)
        .multilineTextAlignment(.trailing)
        .lineLimit(2)
    }
  }
}

struct SettingsPageHero: View {
  let title: String
  let subtitle: String
  let symbol: String
  let tint: Color

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      Image(systemName: symbol)
        .font(.system(size: 22, weight: .medium))
        .foregroundStyle(tint)
        .frame(width: 44, height: 44)
        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 11, style: .continuous))

      VStack(alignment: .leading, spacing: 3) {
        Text(LocalizedStringKey(title))
          .font(.title2.weight(.semibold))
        Text(LocalizedStringKey(subtitle))
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 0)
    }
    .padding(.vertical, 8)
    .padding(.horizontal, 4)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct SettingsSliderRow: View {
  let title: String
  @Binding var value: CGFloat
  let range: ClosedRange<CGFloat>
  let suffix: String
  @ObservedObject private var languageManager = LanguageManager.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack {
        Text(LocalizedStringKey(title))
        Spacer()
        Text(String(format: "%.0f%@", value * 100, suffix))
          .font(.callout.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      Slider(value: $value, in: range).focusable()
        .controllerSlider(value: $value, in: range)
    }
    .padding(.vertical, 8)
    .settingsSearchRow(title: title)
  }
}


struct SettingsChoiceRow: View {
  let title: String
  var detail: String? = nil
  @Binding var selection: String
  let options: [String]
  @ObservedObject private var languageManager = LanguageManager.shared

  var body: some View {
    SettingsRow(title: title, detail: detail) {
      Picker("", selection: $selection) {
        ForEach(options, id: \.self) { value in
          Text(languageManager.localize(value)).tag(value)
        }
      }
      .labelsHidden()
      .controllerPicker(selection: $selection, options: options, title: { value in languageManager.localize(value) })
      .pickerStyle(.menu)
      .focusable()
      .frame(width: 190, alignment: .trailing)
    }
  }
}

struct SettingsValueSliderRow: View {
  let title: String
  @Binding var value: CGFloat
  let range: ClosedRange<CGFloat>
  var step: CGFloat = 0.01
  var multiplier: CGFloat = 1
  var suffix: String = ""

  var body: some View {
    SettingsRow(title: title) {
      HStack(spacing: 8) {
        Slider(value: $value, in: range, step: step).focusable()
          .controllerSlider(value: $value, in: range, step: step)
          .frame(width: 190)
        Text(Double(value * multiplier).formatted(.number.precision(.fractionLength(0...2))) + suffix)
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .frame(width: 62, alignment: .trailing)
      }
    }
  }
}

struct SettingsDecimalRow: View {
  let title: String
  @Binding var value: CGFloat?
  var formatter: NumberFormatter {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = 6
    formatter.minimum = 0
    return formatter
  }

  var body: some View {
    SettingsRow(title: title) {
      TextField("", value: $value, formatter: formatter)
        .multilineTextAlignment(.trailing)
        .controllerNumericField()
        .textFieldStyle(.roundedBorder)
        .frame(width: 120)
    }
  }
}
