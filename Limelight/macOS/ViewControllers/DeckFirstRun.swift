//
//  DeckFirstRun.swift
//  What the window shows when there is no computer yet. The page itself is NoHostPage (SwiftUI, nothing newer than macOS 12 in it); this adapter
//  turns the discovery list into "is there one" and routes its three actions. When a computer turns up the page hands over to the host list
//  (HostsViewController does the change). It is part of the new home; the old host list page is never shown.
//

import AppKit
import SwiftUI

@objc(MLDeckFirstRun)
public final class DeckFirstRun: NSObject {
  @objc public static func make(provider: @escaping () -> [TemporaryHost], onAdd: @escaping () -> Void,
                                onSelect: @escaping (TemporaryHost) -> Void) -> NSViewController {
    let discovered: () -> [DeckHost] = { DeckHostList.sorted(DeckHostList.build(provider())).filter { !$0.stale } }
    let page = NoHostPage(
      provider: { discovered().map { NoHostFound(id: $0.id) } },
      actions: NoHostActions(
        add: onAdd,
        learn: { DeckFs.learn() },
        select: { id in
          guard let host = discovered().first(where: { $0.id == id }) else { return false }
          onSelect(host.raw)
          return true
        }))
    let controller = NSHostingController(rootView: page)
    if #available(macOS 13.0, *) { controller.sizingOptions = [] }
    return controller
  }
}
