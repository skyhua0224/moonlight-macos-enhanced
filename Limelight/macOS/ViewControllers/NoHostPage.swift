//
//  NoHostPage.swift
//  The window's content while there is no computer: it polls the discovery list twice a second and hands the result to NoHostEmpty, which
//  draws the states and, when a computer turns up, hands over to the host list.
//

import AppKit
import Combine
import SwiftUI

struct NoHostPage: View {
  let provider: () -> [NoHostFound]
  let actions: NoHostActions
  @SwiftUI.State private var hosts: [NoHostFound] = []
  @SwiftUI.State private var started = Date()
  private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

  var body: some View {
    NoHostEmpty(hosts: hosts, actions: actions)
      .onAppear { started = Date(); refresh() }
      .onReceive(timer) { _ in refresh() }
  }

  private func refresh() {
    let next = NoHostPreview.active ? NoHostPreview.hosts(elapsed: Date().timeIntervalSince(started)) : provider()
    if next.map({ $0.id }) != hosts.map({ $0.id }) { hosts = next }
  }
}
