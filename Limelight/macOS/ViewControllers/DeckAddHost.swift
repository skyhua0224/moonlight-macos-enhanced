//
//  DeckAddHost.swift
//  添加电脑 as a sheet in the app's own look: a large address field with the formats it takes, the
//  computers found nearby with their state, a clear 添加 button, progress and errors in place, and then
//  straight into pairing (the caller selects the computer and starts pairing). No system alert.
//

import AppKit
import SwiftUI

enum DeckAddressCheck {
  /// "192.0.2.20", "pc.local", "[fe80::1]", "192.0.2.20:47989": trimmed and checked. The message says
  /// what is wrong in the user's words; nil means fine.
  static func problem(_ raw: String) -> String? {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty { return nil }
    if text.contains(where: { $0.isWhitespace }) { return DL("deck.add.err.space") }
    if text.contains("://") || text.contains("/") { return DL("deck.add.err.scheme") }
    var host = text
    var port: String?
    if text.hasPrefix("[") {
      guard let close = text.firstIndex(of: "]") else { return DL("deck.add.err.bracket") }
      host = String(text[text.index(after: text.startIndex)..<close])
      let rest = text[text.index(after: close)...]
      if rest.hasPrefix(":") { port = String(rest.dropFirst()) } else if !rest.isEmpty { return DL("deck.add.err.format") }
    } else if text.filter({ $0 == ":" }).count == 1, let colon = text.firstIndex(of: ":") {
      host = String(text[..<colon]); port = String(text[text.index(after: colon)...])
    }
    if host.isEmpty { return DL("deck.add.err.format") }
    if let port, !(Int(port).map { (1...65535).contains($0) } ?? false) { return DL("deck.add.err.port") }
    return nil
  }
}

@available(macOS 14.0, *)
@objc(MLDeckAddHost)
public final class DeckAddHost: NSObject {
  /// `onSubmit` talks to the host (discovery) and calls back on the main thread with an error message, or
  /// with the host that was added. `onChosen` is called after the sheet has closed, with the added or the
  /// chosen computer: the caller selects it and starts pairing.
  @objc public static func present(in window: NSWindow?, provider: @escaping () -> [TemporaryHost],
                                   onSubmit: @escaping (String, @escaping (String?, TemporaryHost?) -> Void) -> Void,
                                   onChosen: @escaping (TemporaryHost) -> Void) {
    guard let presenter = window?.contentViewController else { return }
    let box = ControllerBox()
    let view = DeckAddHostView(provider: provider, onSubmit: onSubmit, onClose: { host in
      if let controller = box.controller { presenter.dismiss(controller) }
      if let host { DispatchQueue.main.async { onChosen(host) } }
    })
    let controller = NSHostingController(rootView: view)
    // the sheet is as tall as its content (width fixed), like a standard macOS sheet
    controller.sizingOptions = [.preferredContentSize]
    box.controller = controller
    presenter.presentAsSheet(controller)
  }

  final class ControllerBox { weak var controller: NSViewController? }
}

@available(macOS 14.0, *)
struct DeckAddHostView: View {
  let provider: () -> [TemporaryHost]
  let onSubmit: (String, @escaping (String?, TemporaryHost?) -> Void) -> Void
  let onClose: (TemporaryHost?) -> Void

  @SwiftUI.State private var address = ""
  @SwiftUI.State private var working = false
  @SwiftUI.State private var failure: String?
  @SwiftUI.State private var nearby: [DeckHost] = []
  @FocusState private var focused: Bool
  private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
  private let rowHeight: CGFloat = 54

  private var trimmed: String { address.trimmingCharacters(in: .whitespacesAndNewlines) }
  private var problem: String? { DeckAddressCheck.problem(address) }
  private var canAdd: Bool { !trimmed.isEmpty && problem == nil && !working }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 12) {
        Image(systemName: "desktopcomputer").font(.system(size: 20)).foregroundStyle(Color.accentColor)
          .frame(width: 40, height: 40).background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        Text(DL("deck.addHost")).font(.system(size: 20, weight: .bold))
      }

      VStack(alignment: .leading, spacing: 8) {
        TextField(DL("deck.add.placeholder"), text: $address)
          .textFieldStyle(.roundedBorder)
          .controlSize(.large)
          .font(.system(size: 15, design: .monospaced))
          .focused($focused)
          .disabled(working)
          .onSubmit { add() }
          .onChange(of: address) { _, _ in failure = nil }
        if working {
          HStack(spacing: 8) { ProgressView().controlSize(.small); Text(DLf("deck.add.connecting", trimmed)).font(.system(size: 12)).foregroundStyle(.secondary) }
        } else if let message = failure ?? problem {
          Label(message, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        } else {
          Text(DL("deck.add.help")).font(.system(size: 12)).foregroundStyle(.secondary)
        }
      }

      VStack(alignment: .leading, spacing: 8) {
        Text(DL("deck.firstRun.nearby")).font(.system(size: 13, weight: .semibold))
        if nearby.isEmpty {
          HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(DL("deck.firstRun.searching")).font(.system(size: 12)).foregroundStyle(.secondary)
          }
        } else {
          // sized to its rows: at most five, then it scrolls
          ScrollView {
            VStack(spacing: 0) {
              ForEach(Array(nearby.enumerated()), id: \.element.id) { index, host in
                if index > 0 { Divider() }
                HStack(spacing: 10) {
                  DeckHostIcon(host: host, size: 30, muted: !host.online)
                  VStack(alignment: .leading, spacing: 1) {
                    Text(host.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text([host.address, DL("deck.unpaired")].compactMap { $0 }.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                  }
                  Spacer(minLength: 8)
                  Button(DL("deck.pair")) { onClose(host.raw) }.controllerButtonStyle(.automatic).controlSize(.regular)
                }
                .frame(height: rowHeight)
              }
            }
            .padding(.horizontal, 10)
          }
          .frame(height: CGFloat(min(nearby.count, 5)) * rowHeight)
          .scrollDisabled(nearby.count <= 5)
          .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
          .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5))
        }
      }

      HStack(spacing: 10) {
        Spacer()
        Button(DL("deck.cancel")) { onClose(nil) }.keyboardShortcut(.cancelAction).controllerButtonStyle(.automatic)
        Button(DL("deck.add.add")) { add() }.keyboardShortcut(.defaultAction).controllerButtonStyle(.borderedProminent).disabled(!canAdd)
      }
      .controlSize(.regular)
      .padding(.top, 4)
    }
    .padding(20)
    .frame(width: 480)
    .fixedSize(horizontal: false, vertical: true)
    .onAppear {
      focused = true
      refresh()
      // harness only: start with text in the field, and submit it
      if let text = conceptEnv("MLC_ADD_TEXT") {
        address = text
        if conceptEnv("MLC_ADD_SUBMIT") != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { add() } }
      }
    }
    .onReceive(timer) { _ in refresh() }
  }

  private func refresh() {
    nearby = DeckHostList.sorted(DeckHostList.build(provider())).filter { $0.online && !$0.paired && !$0.stale }
  }

  private func add() {
    guard canAdd else { return }
    working = true
    failure = nil
    onSubmit(trimmed) { error, host in
      working = false
      if let host { onClose(host) } else {
        // the discovery message talks about GeForce Experience; for the user the useful part is that nothing answered
        _ = error
        failure = DL("deck.add.err.unreachable")
      }
    }
  }
}
