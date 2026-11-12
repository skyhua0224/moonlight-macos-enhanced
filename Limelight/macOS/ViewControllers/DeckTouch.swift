//
//  DeckTouch.swift
//  Moonlight for macOS
//
//  The app's own pages on a touchscreen Mac or a Sidecar iPad (macOS 27):
//  - DeckTouchState: whether any screen reports multi-touch (NSScreen.touchCapabilities).
//  - deckTouchTarget(): at least 36 pt to hit on each axis, by widening the hit area and not the picture
//    (Apple Tech Talk 111468, 5:37).
//  - deckHelp(): a tooltip for the mouse and, on touch, the same text in a popover on long press (a finger
//    has no hover).
//  - DeckTouchLongPress: a long press on a tile opens the same NSMenu as its right click.
//

import AppKit
import SwiftUI

@available(macOS 14.0, *)
@MainActor
final class DeckTouchState: ObservableObject {
  static let shared = DeckTouchState()

  /// True when a screen reports multi-touch (a touchscreen Mac, or a Sidecar iPad: a connected touch
  /// Sidecar makes every display report touch). Defaults key `MLTouchUIForce` turns it on for a Mac without.
  @Published private(set) var hasTouch = false

  private init() {
    refresh()
    NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.refresh() }
    }
  }

  func refresh() {
    var touch = UserDefaults.standard.bool(forKey: "MLTouchUIForce")
    if #available(macOS 27.0, *) {
      if NSScreen.screens.contains(where: { $0.touchCapabilities.contains(.multiTouch) }) { touch = true }
    }
    if touch != hasTouch { hasTouch = touch }
  }
}

@available(macOS 14.0, *)
struct DeckTouchTarget: ViewModifier {
  let minimum: CGFloat
  @ObservedObject private var touch = DeckTouchState.shared
  @SwiftUI.State private var size: CGSize = .zero

  func body(content: Content) -> some View {
    if touch.hasTouch {
      let dx = extra(size.width)
      let dy = extra(size.height)
      content
        .background(
          GeometryReader { proxy in
            Color.clear
              .onAppear { size = proxy.size }
              .onChange(of: proxy.size) { _, new in size = new }
          }
        )
        // Widen, give the widened rectangle the hit shape, then take the layout back: the picture does not move.
        .padding(.horizontal, dx).padding(.vertical, dy)
        .contentShape(Rectangle())
        .padding(.horizontal, -dx).padding(.vertical, -dy)
    } else {
      content
    }
  }

  /// Per side. Capped so neighbours that sit close together do not fight over the same finger.
  private func extra(_ length: CGFloat) -> CGFloat {
    min(max((minimum - length) / 2, 0), 10)
  }
}

@available(macOS 14.0, *)
private struct DeckHelp: ViewModifier {
  let text: String
  @ObservedObject private var touch = DeckTouchState.shared
  @SwiftUI.State private var showing = false

  func body(content: Content) -> some View {
    if touch.hasTouch {
      content
        .help(text)
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in showing = true })
        .popover(isPresented: $showing, arrowEdge: .bottom) {
          Text(text).font(.callout).padding(10).frame(maxWidth: 280, alignment: .leading)
            .deckPopoverContent()
        }
    } else {
      content.help(text)
    }
  }
}

@available(macOS 14.0, *)
extension View {
  /// At least `minimum` points to hit, on touch screens only.
  func deckTouchTarget(_ minimum: CGFloat = 36) -> some View {
    modifier(DeckTouchTarget(minimum: minimum))
  }

  /// `.help(text)` plus its touch equivalent.
  func deckHelp(_ text: String) -> some View {
    modifier(DeckHelp(text: text))
  }
}

// MARK: - Long press = right click

/// One long-press recognizer per window; the tiles that have a right-click menu register themselves and the
/// press is given to the innermost one under the finger. Touches only: a mouse press is never affected, and the
/// recognizer is not asked about a spot where no tile is registered, so taps and drags elsewhere are untouched.
@available(macOS 14.0, *)
@MainActor
final class DeckTouchLongPress: NSObject, NSGestureRecognizerDelegate {
  static let shared = DeckTouchLongPress()

  private struct Entry {
    weak var view: NSView?
    let provider: () -> NSMenu?
  }

  private var entries: [Entry] = []
  private var installedWindows = NSHashTable<NSWindow>.weakObjects()

  func register(_ view: NSView, provider: @escaping () -> NSMenu?) {
    entries.removeAll { $0.view == nil || $0.view === view }
    entries.append(Entry(view: view, provider: provider))
    guard #available(macOS 27.0, *), let window = view.window, let content = window.contentView,
      !installedWindows.contains(window)
    else { return }
    installedWindows.add(window)
    let press = NSPressGestureRecognizer(target: self, action: #selector(pressed(_:)))
    press.buttonMask = 0                        // touches only
    press.allowedTouchTypes = .direct
    press.minimumPressDuration = 0.45
    press.allowableMovement = 10
    press.isCancellableByScrollGesture = true   // a finger that starts scrolling is not a press
    press.delegate = self
    content.addGestureRecognizer(press)
  }

  func unregister(_ view: NSView) {
    entries.removeAll { $0.view == nil || $0.view === view }
  }

  /// The registered view with the smallest area that holds the point (window coordinates).
  private func target(at windowPoint: NSPoint, in window: NSWindow) -> (NSView, () -> NSMenu?)? {
    var best: (NSView, () -> NSMenu?)?
    var bestArea = CGFloat.greatestFiniteMagnitude
    for entry in entries {
      guard let view = entry.view, view.window === window, !view.isHiddenOrHasHiddenAncestor else { continue }
      let frame = view.convert(view.bounds, to: nil)
      guard frame.contains(windowPoint) else { continue }
      let area = frame.width * frame.height
      if area < bestArea {
        bestArea = area
        best = (view, entry.provider)
      }
    }
    return best
  }

  func gestureRecognizerShouldBegin(_ gestureRecognizer: NSGestureRecognizer) -> Bool {
    guard let content = gestureRecognizer.view, let window = content.window else { return false }
    let point = gestureRecognizer.location(in: nil)
    return target(at: point, in: window) != nil
  }

  @objc private func pressed(_ recognizer: NSPressGestureRecognizer) {
    guard recognizer.state == .began, let content = recognizer.view, let window = content.window else { return }
    let windowPoint = recognizer.location(in: nil)
    guard let (view, provider) = target(at: windowPoint, in: window), let menu = provider() else { return }
    menu.popUp(positioning: nil, at: view.convert(windowPoint, from: nil), in: view)
  }
}
