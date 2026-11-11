//
//  DeckFirstRun.swift
//  What the window shows when there is no computer yet: 添加电脑 and the computers discovered on the
//  network. It is part of the new home; the old host list page is never shown.
//

import AppKit
import SwiftUI

@available(macOS 14.0, *)
@objc(MLDeckFirstRun)
public final class DeckFirstRun: NSObject {
  @objc public static func make(provider: @escaping () -> [TemporaryHost], onAdd: @escaping () -> Void,
                                onSelect: @escaping (TemporaryHost) -> Void) -> NSViewController {
    let controller = NSHostingController(rootView: DeckFirstRunView(provider: provider, onAdd: onAdd, onSelect: onSelect))
    if #available(macOS 13.0, *) { controller.sizingOptions = [] }
    return controller
  }
}

@available(macOS 14.0, *)
struct DeckFirstRunView: View {
  let provider: () -> [TemporaryHost]
  let onAdd: () -> Void
  let onSelect: (TemporaryHost) -> Void
  @SwiftUI.State private var hosts: [DeckHost] = []
  private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 28) {
        HStack(alignment: .center, spacing: 18) {
          Image(systemName: "desktopcomputer").font(.system(size: 40, weight: .light)).foregroundStyle(Color.accentColor)
            .frame(width: 76, height: 76)
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 19, style: .continuous))
          VStack(alignment: .leading, spacing: 8) {
            Text(DL("deck.addHost")).font(.system(size: 34, weight: .bold))
            Button { onAdd() } label: { Label(DL("deck.firstRun.byAddress"), systemImage: "plus") }
              .deckProminent().controlSize(.large)
          }
        }
        VStack(alignment: .leading, spacing: 12) {
          Text(DL("deck.firstRun.nearby")).font(.system(size: 20, weight: .bold))
          if hosts.isEmpty {
            HStack(spacing: 10) {
              ProgressView().controlSize(.small)
              Text(DL("deck.firstRun.searching")).font(.system(size: 14)).foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
          } else {
            VStack(spacing: 0) {
              ForEach(Array(hosts.enumerated()), id: \.element.id) { index, host in
                if index > 0 { Divider() }
                row(host)
              }
            }
            .padding(.horizontal, 14)
            .deckCard(radius: 12)
          }
        }
        .frame(maxWidth: 560, alignment: .leading)
      }
      .padding(.horizontal, DeckInset.page)
      .padding(.top, 70)
      .padding(.bottom, 40)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .onAppear { refresh() }
    .onReceive(timer) { _ in refresh() }
  }

  private func refresh() {
    hosts = DeckHostList.sorted(DeckHostList.build(provider())).filter { !$0.stale }
  }

  private func row(_ host: DeckHost) -> some View {
    HStack(spacing: 12) {
      DeckHostIcon(host: host, size: 36, muted: !host.online)
      VStack(alignment: .leading, spacing: 2) {
        Text(host.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
        Text(deckSubtitle(host)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer(minLength: 12)
      Button { onSelect(host.raw) } label: { Text(DL(host.paired ? "deck.connect" : "deck.pair")) }
        .deckSecondary().controlSize(.regular)
    }
    .padding(.vertical, 10)
  }
}
