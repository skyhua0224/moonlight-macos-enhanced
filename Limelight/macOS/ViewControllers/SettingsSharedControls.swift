import AppKit
import SwiftUI

/// Shared macOS settings composition. Pages use one centered content column,
/// native group surfaces, and a consistent label/value row.
struct SettingsContent<Content: View>: View {
  let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    ScrollView {
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

struct FormSection<Content: View>: View {
  let title: String
  let content: Content
  @ObservedObject private var languageManager = LanguageManager.shared

  init(title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(LocalizedStringKey(title))
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.leading, 2)

      VStack(alignment: .leading, spacing: 0) {
        content
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 2)
      .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
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
  @ObservedObject private var languageManager = LanguageManager.shared
  @SwiftUI.State private var isPresented = false

  var body: some View {
    Button { isPresented.toggle() } label: {
      Image(systemName: "info.circle")
        .foregroundStyle(.secondary)
    }
    .buttonStyle(.plain)
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
      Text("×").foregroundStyle(.secondary)
      TextField("\(Int(placeholderDimensions.height))", value: $heightBinding, formatter: NumberOnlyFormatter())
        .multilineTextAlignment(.leading)
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
      Slider(value: $value, in: range)
    }
    .padding(.vertical, 8)
  }
}


struct SettingsChoiceRow: View {
  let title: String
  @Binding var selection: String
  let options: [String]
  @ObservedObject private var languageManager = LanguageManager.shared

  var body: some View {
    SettingsRow(title: title) {
      Picker("", selection: $selection) {
        ForEach(options, id: \.self) { value in
          Text(languageManager.localize(value)).tag(value)
        }
      }
      .labelsHidden()
      .pickerStyle(.menu)
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
        Slider(value: $value, in: range, step: step)
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
        .textFieldStyle(.roundedBorder)
        .frame(width: 120)
    }
  }
}
