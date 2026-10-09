import Foundation

// This runtime accepts neutral physical-button IDs and emits a routing word for
// the input backends (layout in ControllerShortcutAdapter.h): bits 0–16 consume
// buttons, bit 31 presses the touchpad button, bits 32–48 replay a short tap.
// Transport adapters stay in the input backends. Whenever a player's routing
// changes, outputHandler is called so the owning backend sends fresh state;
// callers that only compute (polling timers) cannot swallow a change.
@objc final class ControllerShortcutRuntime: NSObject {
  // A short press of a hold trigger that does not keep its original input is
  // replayed for this long, so games still see the tap.
  private static let replayTapSeconds: TimeInterval = 0.06

  private final class Device {
    var buttons: UInt32 = 0
    var gestures: [ControllerShortcutGesture]
    var output: UInt64 = 0
    // Per-button replay deadlines, indexed by neutral button ID.
    var replayUntil = [TimeInterval](repeating: 0, count: 17)
    var touchpadTapUntil: TimeInterval = 0
    init(count: Int) { gestures = Array(repeating: ControllerShortcutGesture(), count: count) }
    var replaying: Bool { touchpadTapUntil > 0 || replayUntil.contains { $0 > 0 } }
    func clearOutput() -> Bool {
      let had = output != 0
      output = 0
      replayUntil = replayUntil.map { _ in 0 }
      touchpadTapUntil = 0
      return had
    }
  }
  private let lock = NSLock()
  private let hostId: String
  private let actionHandler: (String, UInt16) -> Void
  private let outputHandler: (UInt16) -> Void
  private var records: [(action: String, trigger: ControllerTouchpadShortcut)] = []
  private var devices: [UInt16: Device] = [:]
  private var enabled = false
  private var revision: UInt64 = 0
  private var timer: Timer?
  private var timerScheduled = false

  @objc init(hostId: String, actionHandler: @escaping (String, UInt16) -> Void,
             outputHandler: @escaping (UInt16) -> Void) {
    self.hostId = hostId
    self.actionHandler = actionHandler
    self.outputHandler = outputHandler
    super.init()
    reload()
  }
  deinit { timer?.invalidate() }

  @objc var active: Bool {
    get { lock.lock(); defer { lock.unlock() }; return enabled }
    set {
      lock.lock()
      enabled = newValue
      var changed: [UInt16] = []
      if !newValue {
        for (player, device) in devices {
          for i in records.indices {
            let trigger = records[i].trigger
            _ = ControllerShortcutUpdate(&device.gestures[i], device.buttons, trigger.buttonMask,
                                         trigger.holdSeconds, false, ProcessInfo.processInfo.systemUptime)
          }
          if device.clearOutput() { changed.append(player) }
        }
      }
      lock.unlock()
      notify(changed)
    }
  }

  /// Whether a button combination stands in for the touchpad button.
  @objc var mapsTouchpadButton: Bool {
    lock.lock(); defer { lock.unlock() }
    return records.contains { $0.action == ControllerShortcutProfile.touchpadAction }
  }

  @objc func reload() {
    let profile = SettingsClass.controllerShortcutProfile(for: hostId)
    let next = ControllerShortcutProfile.actions.compactMap { action -> (String, ControllerTouchpadShortcut)? in
      guard let trigger = profile.bindings[action]?.normalized, trigger.buttonMask != 0 else { return nil }
      return (action, trigger)
    }.sorted { lhs, rhs in
      if lhs.1.buttons.count != rhs.1.buttons.count { return lhs.1.buttons.count > rhs.1.buttons.count }
      let lp = profile.priorities.firstIndex(of: lhs.0) ?? Int.max
      let rp = profile.priorities.firstIndex(of: rhs.0) ?? Int.max
      if lp != rp { return lp < rp }
      return lhs.0 < rhs.0
    }
    lock.lock()
    revision &+= 1
    records = next
    let now = ProcessInfo.processInfo.systemUptime
    var changed: [UInt16] = []
    for (player, device) in devices {
      device.gestures = Array(repeating: ControllerShortcutGesture(), count: next.count)
      for i in next.indices {
        _ = ControllerShortcutUpdate(&device.gestures[i], device.buttons, next[i].1.buttonMask,
                                     next[i].1.holdSeconds, false, now)
      }
      if device.clearOutput() { changed.append(player) }
    }
    lock.unlock()
    notify(changed)
  }

  private func notify(_ players: [UInt16]) {
    for player in players {
      DispatchQueue.main.async { [weak self] in self?.outputHandler(player) }
    }
  }

  @objc func processButtons(_ buttons: UInt32, player: UInt16) -> UInt64 {
    var actions: [String] = []
    var actionRevision: UInt64 = 0
    var schedule = false
    lock.lock()
    let device = devices[player] ?? Device(count: records.count)
    devices[player] = device
    device.buttons = buttons
    let now = ProcessInfo.processInfo.systemUptime
    var claimed: UInt32 = 0
    var output: UInt64 = 0
    var pending = false
    for i in records.indices {
      let record = records[i]
      let mask = record.trigger.buttonMask
      let wasTracking = device.gestures[i].tracking
      let wasActive = device.gestures[i].active
      let began = device.gestures[i].began
      let available = enabled && claimed & mask == 0
      let pressed = ControllerShortcutUpdate(&device.gestures[i], buttons, mask,
        record.trigger.holdSeconds, available, now)
      let matched = device.gestures[i].tracking || device.gestures[i].active
      if available && matched {
        claimed |= mask
        if !record.trigger.preserveOriginal { output |= UInt64(mask) }
        if record.action == ControllerShortcutProfile.touchpadAction {
          if pressed { output |= 0x8000_0000 }
        } else if pressed && !wasActive { actions.append(record.action) }
        pending = pending || (!pressed && record.trigger.holdSeconds > 0)
      } else if available && device.gestures[i].blockedUntilRelease && !record.trigger.preserveOriginal {
        output |= UInt64(mask)
      }
      if available && wasTracking && !wasActive && !matched && record.trigger.holdSeconds > 0 {
        if now - began >= record.trigger.holdSeconds {
          // Held long enough, but no update observed the threshold before the
          // release (busy main thread): complete the long press now.
          if record.action == ControllerShortcutProfile.touchpadAction {
            device.touchpadTapUntil = now + Self.replayTapSeconds
          } else {
            actions.append(record.action)
          }
        } else if !record.trigger.preserveOriginal {
          // The buttons were withheld while the hold was pending; a release
          // before the threshold hands the press back to the game as a tap.
          let released = mask & ~buttons
          for bit in 0..<17 where released & (1 << bit) != 0 {
            device.replayUntil[bit] = now + Self.replayTapSeconds
          }
        }
      }
    }
    var replay: UInt32 = 0
    for bit in 0..<17 where device.replayUntil[bit] > 0 {
      if now < device.replayUntil[bit] { replay |= 1 << bit } else { device.replayUntil[bit] = 0 }
    }
    if device.touchpadTapUntil > 0 {
      if now < device.touchpadTapUntil { output |= 0x8000_0000 } else { device.touchpadTapUntil = 0 }
    }
    output |= UInt64(replay) << 32
    pending = pending || device.replaying
    let outputChanged = output != device.output
    device.output = output
    actionRevision = revision
    if pending && !timerScheduled { timerScheduled = true; schedule = true }
    lock.unlock()
    if outputChanged { notify([player]) }
    if schedule {
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        if self.timer == nil {
          self.timer = Timer(timeInterval: 0.016, repeats: true) { [weak self] _ in self?.tick() }
          RunLoop.main.add(self.timer!, forMode: .common)
        }
      }
    }
    for action in actions {
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.lock.lock()
        let valid = self.enabled && self.revision == actionRevision
        self.lock.unlock()
        if valid { self.actionHandler(action, player) }
      }
    }
    return output
  }
  private func tick() {
    lock.lock()
    let snapshots = devices.map { ($0.key, $0.value.buttons) }
    let running = enabled
    lock.unlock()
    var pending = false
    if running {
      // processButtons reports any routing change through outputHandler.
      for (player, buttons) in snapshots { _ = processButtons(buttons, player: player) }
      lock.lock()
      for device in devices.values {
        pending = pending || device.replaying ||
          device.gestures.contains { $0.tracking && !$0.active && !$0.blockedUntilRelease }
      }
      lock.unlock()
    }
    if !running || !pending {
      timer?.invalidate(); timer = nil
      lock.lock(); timerScheduled = false; lock.unlock()
    }
  }
}
