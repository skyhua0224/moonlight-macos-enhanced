//
//  SettingsLineCheck.swift
//  Moonlight for macOS
//
//  A test hook, off unless the environment variable MLC_LINECHECK is set: every settings description line that is
//  marked with .settingsLineCheck(_:) writes how many lines it really took when laid out, at the width it really had.
//  tests/settings-lines/run.sh drives it over every pane and both languages and fails when a row description
//  does not fit one line.
//

import AppKit
import SwiftUI

enum SettingsLineCheck {
  static let enabled = ProcessInfo.processInfo.environment["MLC_LINECHECK"] != nil
  static let lineHeight: CGFloat = {
    let font = NSFont.preferredFont(forTextStyle: .footnote)
    return NSLayoutManager().defaultLineHeight(for: font)
  }()

  static func report(_ id: String, text: String, size: CGSize) {
    let lines = max(1, Int((size.height / lineHeight).rounded()))
    let line = "[linecheck] id=\(id) lines=\(lines) width=\(Int(size.width)) text=\(text.replacingOccurrences(of: "\n", with: "⏎"))\n"
    FileHandle.standardError.write(Data(line.utf8))
  }
}

/// Walks the panes of the open settings window one after the other (the pane is an @AppStorage value, so setting the
/// default switches the visible pane) and quits when done.
@objc final class SettingsLineCheckDriver: NSObject {
  @objc static func run() {
    let panes = [0, 1, 6, 5, 2, 7, 8, 9, 3, 10, 11, 12]
    func step(_ index: Int) {
      if index >= panes.count { fflush(stderr); _exit(0) }
      FileHandle.standardError.write(Data("[linecheck-pane] \(panes[index])\n".utf8))
      if let pane = SettingsPaneType(rawValue: panes[index]) { SettingsPaneContainerView.current?.show(pane) }
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { step(index + 1) }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { step(0) }
  }
}

private struct SettingsLineCheckModifier: ViewModifier {
  let id: String
  let text: String

  func body(content: Content) -> some View {
    if SettingsLineCheck.enabled {
      content.background(
        GeometryReader { proxy in
          Color.clear
            .onAppear { SettingsLineCheck.report(id, text: text, size: proxy.size) }
            .onChange(of: proxy.size) { size in SettingsLineCheck.report(id, text: text, size: size) }
        })
    } else {
      content
    }
  }
}

extension View {
  /// Marks a description line for the line check. No effect in a normal run.
  func settingsLineCheck(_ id: String, text: String = "") -> some View {
    modifier(SettingsLineCheckModifier(id: id, text: text))
  }
}
