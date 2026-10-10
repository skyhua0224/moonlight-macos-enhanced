import AppKit
import SwiftUI

// On-screen keyboard for text fields while a controller drives the interface.
// It never takes key status: the window's field editor stays first responder
// and receives the typed text like a hardware keyboard would.

// MARK: - Numeric fields

/// Invisible marker behind a SwiftUI text field that only takes numbers.
final class ControllerNumericMarkerView: NSView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct ControllerNumericMarker: NSViewRepresentable {
  func makeNSView(context: Context) -> ControllerNumericMarkerView { ControllerNumericMarkerView() }
  func updateNSView(_ view: ControllerNumericMarkerView, context: Context) {}
}

extension View {
  /// The controller keyboard offers digits only for this text field.
  func controllerNumericField() -> some View {
    background(ControllerNumericMarker())
  }
}

// MARK: - Model

final class ControllerKeyboardModel: ObservableObject {
  enum Layout { case letters, symbols, numeric }
  enum Shift { case off, once, caps }

  enum Action: Equatable {
    case insert(String)
    case shift, backspace, toggleLayout, done
    case space
  }

  struct Key: Identifiable {
    let id: String
    let action: Action
    var weight: CGFloat = 1
  }

  @Published private(set) var layout: Layout = .letters
  @Published private(set) var shift: Shift = .off
  @Published private(set) var row = 1
  @Published private(set) var column = 0
  var onAction: ((Action) -> Void)?
  var onLayoutChange: (() -> Void)?
  private var anchorX: CGFloat = 0

  static let keyWidth: CGFloat = 52
  static let keyHeight: CGFloat = 42
  static let spacing: CGFloat = 6

  func reset(numeric: Bool) {
    layout = numeric ? .numeric : .letters
    shift = .off
    row = numeric ? 0 : 1
    column = 0
    anchorX = center(of: column, in: row)
  }

  // MARK: Layouts

  var rows: [[Key]] { Self.rows(for: layout, shift: shift) }

  private static func keys(_ characters: String, row: Int, shift: Shift) -> [Key] {
    characters.enumerated().map { index, character in
      let text = shift == .off ? String(character) : String(character).uppercased()
      return Key(id: "\(row).\(index)", action: .insert(text))
    }
  }

  private static func rows(for layout: Layout, shift: Shift) -> [[Key]] {
    let bottom = [
      Key(id: "4.0", action: .toggleLayout, weight: 1.5),
      Key(id: "4.1", action: .insert(",")),
      Key(id: "4.2", action: .space, weight: 4),
      Key(id: "4.3", action: .insert(".")),
      Key(id: "4.4", action: .done, weight: 2.5),
    ]
    switch layout {
    case .letters:
      return [
        keys("1234567890", row: 0, shift: .off),
        keys("qwertyuiop", row: 1, shift: shift),
        keys("asdfghjkl", row: 2, shift: shift),
        [Key(id: "3.s", action: .shift, weight: 1.5)] + keys("zxcvbnm", row: 3, shift: shift)
          + [Key(id: "3.b", action: .backspace, weight: 1.5)],
        bottom,
      ]
    case .symbols:
      return [
        keys("1234567890", row: 0, shift: .off),
        keys("-/:;()$&@\"", row: 1, shift: .off),
        keys("[]{}#%^*+=", row: 2, shift: .off),
        keys("_\\|~<>'!?", row: 3, shift: .off) + [Key(id: "3.b", action: .backspace)],
        bottom,
      ]
    case .numeric:
      return [
        keys("123", row: 0, shift: .off),
        keys("456", row: 1, shift: .off),
        keys("789", row: 2, shift: .off),
        [Key(id: "3.0", action: .insert(".")), Key(id: "3.1", action: .insert("0")),
         Key(id: "3.2", action: .backspace)],
        [Key(id: "4.0", action: .done, weight: 3)],
      ]
    }
  }

  static func width(of row: [Key]) -> CGFloat {
    row.reduce(0) { $0 + $1.weight * (keyWidth + spacing) } - spacing
  }

  var preferredSize: CGSize {
    let rows = self.rows
    let width = rows.map(Self.width(of:)).max() ?? 0
    let height = CGFloat(rows.count) * Self.keyHeight + CGFloat(rows.count - 1) * Self.spacing
    return CGSize(width: width + 32, height: height + 32)
  }

  var focusedKey: Key? {
    let rows = self.rows
    guard rows.indices.contains(row), rows[row].indices.contains(column) else { return nil }
    return rows[row][column]
  }

  // MARK: Focus

  /// Horizontal centre of a key in units, measured from the row's middle.
  private func center(of column: Int, in row: Int) -> CGFloat {
    let rows = self.rows
    guard rows.indices.contains(row) else { return 0 }
    let keys = rows[row]
    let total = keys.reduce(0) { $0 + $1.weight }
    let before = keys.prefix(column).reduce(0) { $0 + $1.weight }
    return before + (keys.indices.contains(column) ? keys[column].weight / 2 : 0) - total / 2
  }

  private func nearestColumn(in row: Int, to x: CGFloat) -> Int {
    let count = rows[row].count
    return (0..<count).min { abs(center(of: $0, in: row) - x) < abs(center(of: $1, in: row) - x) } ?? 0
  }

  func move(dx: Int, dy: Int) {
    let rows = self.rows
    if dx != 0 {
      column = min(max(column + dx, 0), rows[row].count - 1)
      anchorX = center(of: column, in: row)
    }
    if dy != 0 {
      row = min(max(row + dy, 0), rows.count - 1)
      column = nearestColumn(in: row, to: anchorX)
    }
  }

  func focus(row: Int, column: Int) {
    self.row = row
    self.column = column
    anchorX = center(of: column, in: row)
  }

  // MARK: Actions

  func perform(_ action: Action) {
    switch action {
    case .shift:
      cycleShift()
    case .toggleLayout:
      toggleLayout()
    case .insert(let text):
      onAction?(.insert(text))
      if shift == .once { shift = .off }
    default:
      onAction?(action)
    }
  }

  func accept() {
    if let key = focusedKey { perform(key.action) }
  }

  func cycleShift() {
    guard layout == .letters else { return }
    switch shift {
    case .off: shift = .once
    case .once: shift = .caps
    case .caps: shift = .off
    }
  }

  func toggleLayout() {
    guard layout != .numeric else { return }
    layout = layout == .letters ? .symbols : .letters
    shift = .off
    row = min(row, rows.count - 1)
    column = nearestColumn(in: row, to: anchorX)
    onLayoutChange?()
  }
}

// MARK: - Panel

/// Presents the keyboard under a window and feeds the window's field editor.
@objc final class ControllerKeyboardPanel: NSObject {
  @objc static let shared = ControllerKeyboardPanel()

  private var panel: NSPanel?
  private var host: NSHostingView<ControllerKeyboardView>?
  private let model = ControllerKeyboardModel()
  private var closeObserver: NSObjectProtocol?
  private var lastParentFrame: NSRect = .zero
  @objc private(set) weak var parentWindow: NSWindow?

  @objc var isPresented: Bool { panel != nil }

  /// Shows the keyboard for the field currently being edited in `window`.
  @objc(presentInWindow:)
  func present(in window: NSWindow) {
    guard let editor = Self.fieldEditor(in: window) else { return }
    dismiss()
    let field = editor.delegate as? NSTextField
    model.reset(numeric: field.map(Self.isNumeric) ?? false)
    model.onAction = { [weak self] action in self?.apply(action) }
    model.onLayoutChange = { [weak self] in self?.layout() }

    let host = NSHostingView(rootView: ControllerKeyboardView(model: model))
    let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
    panel.contentView = host
    self.panel = panel
    self.host = host
    parentWindow = window
    layout()
    window.addChildWindow(panel, ordered: .above)
    panel.orderFront(nil)
    closeObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: window, queue: .main
    ) { [weak self] _ in self?.dismiss() }

    // Typing continues after the existing text instead of replacing it.
    editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
  }

  /// Called every poll: closes when editing ended elsewhere, follows the window.
  @objc func validate() {
    guard isPresented, let window = parentWindow else { return }
    if Self.fieldEditor(in: window) == nil || !window.isVisible {
      dismiss()
    } else if window.frame != lastParentFrame {
      layout()
    }
  }

  @objc(handleInput:)
  func handle(_ input: ControllerFocusInput) {
    guard isPresented else { return }
    switch input {
    case .up: model.move(dx: 0, dy: -1)
    case .down: model.move(dx: 0, dy: 1)
    case .left: model.move(dx: -1, dy: 0)
    case .right: model.move(dx: 1, dy: 0)
    case .accept: model.accept()
    case .delete: apply(.backspace)
    case .space: apply(.space)
    case .previousColumn: model.toggleLayout()
    case .nextColumn: model.cycleShift()
    case .done: apply(.done)
    case .back: dismiss()
    }
  }

  @objc func dismiss() {
    guard let panel else { return }
    if let closeObserver {
      NotificationCenter.default.removeObserver(closeObserver)
    }
    closeObserver = nil
    parentWindow?.removeChildWindow(panel)
    panel.orderOut(nil)
    self.panel = nil
    host = nil
    parentWindow = nil
  }

  // MARK: Typing

  private func apply(_ action: ControllerKeyboardModel.Action) {
    guard let window = parentWindow, let editor = Self.fieldEditor(in: window) else {
      dismiss()
      return
    }
    switch action {
    case .insert(let text):
      editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    case .space:
      editor.insertText(" ", replacementRange: NSRange(location: NSNotFound, length: 0))
    case .backspace:
      editor.deleteBackward(nil)
    case .done:
      dismiss()
      window.makeFirstResponder(nil)
    case .shift, .toggleLayout:
      break
    }
  }

  private static func fieldEditor(in window: NSWindow) -> NSTextView? {
    guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else { return nil }
    return editor
  }

  /// SwiftUI keeps a text field's formatter to itself, so fields mark themselves.
  private static func isNumeric(_ field: NSTextField) -> Bool {
    if field.formatter is NumberOnlyFormatter || field.formatter is NumberFormatter { return true }
    guard let root = field.window?.contentView else { return false }
    let frame = field.convert(field.bounds, to: nil)
    func marked(_ view: NSView) -> Bool {
      if view is ControllerNumericMarkerView,
         view.convert(view.bounds, to: nil).insetBy(dx: -4, dy: -4).contains(frame) {
        return true
      }
      return view.subviews.contains(where: marked)
    }
    return marked(root)
  }

  // MARK: Placement

  /// Bottom-centre of the window, above the controller legend; the top when the
  /// field being edited would sit underneath.
  private func layout() {
    guard let panel, let host, let parent = parentWindow else { return }
    let size = model.preferredSize
    lastParentFrame = parent.frame
    var frame = NSRect(
      x: parent.frame.midX - size.width / 2, y: parent.frame.minY + 64,
      width: size.width, height: size.height)
    if let editor = Self.fieldEditor(in: parent) {
      let fieldFrame = parent.convertToScreen(editor.convert(editor.bounds, to: nil)).insetBy(dx: -12, dy: -12)
      if fieldFrame.intersects(frame) {
        let top = parent.convertToScreen(parent.contentLayoutRect).maxY
        frame.origin.y = top - size.height - 12
      }
    }
    host.frame = NSRect(origin: .zero, size: frame.size)
    panel.setFrame(frame, display: true)
  }
}

// MARK: - View

struct ControllerKeyboardView: View {
  @ObservedObject var model: ControllerKeyboardModel
  @ObservedObject private var languageManager = LanguageManager.shared

  var body: some View {
    VStack(spacing: ControllerKeyboardModel.spacing) {
      ForEach(Array(model.rows.enumerated()), id: \.offset) { rowIndex, keys in
        HStack(spacing: ControllerKeyboardModel.spacing) {
          ForEach(Array(keys.enumerated()), id: \.element.id) { columnIndex, key in
            keyView(key, focused: rowIndex == model.row && columnIndex == model.column)
              .onTapGesture {
                model.focus(row: rowIndex, column: columnIndex)
                model.perform(key.action)
              }
          }
        }
      }
    }
    .padding(16)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
  }

  private func keyView(_ key: ControllerKeyboardModel.Key, focused: Bool) -> some View {
    let width = key.weight * (ControllerKeyboardModel.keyWidth + ControllerKeyboardModel.spacing)
      - ControllerKeyboardModel.spacing
    let special = !isCharacter(key.action) && key.action != .space
    let shiftOn = key.action == .shift && model.shift != .off
    return label(for: key.action)
      .font(.system(size: special ? 14 : 18, weight: special ? .semibold : .regular))
      .lineLimit(1)
      .frame(width: width, height: ControllerKeyboardModel.keyHeight)
      .foregroundStyle(focused ? Color.white : Color.primary)
      .background(
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .fill(focused ? Color.accentColor
                : shiftOn ? Color.accentColor.opacity(0.35)
                : Color.primary.opacity(special ? 0.14 : 0.07)))
      .contentShape(Rectangle())
  }

  private func isCharacter(_ action: ControllerKeyboardModel.Action) -> Bool {
    if case .insert = action { return true }
    return false
  }

  @ViewBuilder
  private func label(for action: ControllerKeyboardModel.Action) -> some View {
    switch action {
    case .insert(let text):
      Text(text)
    case .space:
      Text(languageManager.localize("Keyboard Space"))
    case .backspace:
      Image(systemName: "delete.left")
    case .shift:
      Image(systemName: model.shift == .caps ? "capslock.fill" : model.shift == .once ? "shift.fill" : "shift")
    case .toggleLayout:
      Text(model.layout == .letters ? "123" : "ABC")
    case .done:
      Text(languageManager.localize("Controller Hint Done"))
    }
  }
}
