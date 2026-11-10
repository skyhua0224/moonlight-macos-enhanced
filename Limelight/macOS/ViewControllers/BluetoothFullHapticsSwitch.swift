//
//  BluetoothFullHapticsSwitch.swift
//  Moonlight for macOS
//
//  The Advanced "Full Bluetooth Haptics (Experimental)" switch over the two stored DualSense values: the coarse
//  Bluetooth output path (key 100, value 4 = haptics as 0x32 reports) and the haptics fallback (key 10) that the
//  output returns to when the switch goes off. Turning it on from off needs the user's confirmation first; nothing
//  is written until then. Foundation only, so tests/bt-haptics-warning builds it without the app.
//

import Foundation

struct BluetoothFullHapticsSwitch {
  /// Output path value of the full-haptics Bluetooth path.
  static let pcmOutput = 4
  /// Haptics fallback index (Automatic, IR, Rumble, Off) -> output path that matches it.
  static let outputForFallback = [0, 2, 1, 3]

  var readOutput: () -> Int
  var writeOutput: (Int) -> Void
  var readFallback: () -> Int
  /// Asks the user; calls back once with true (turn on anyway) or false (cancel). May call back later.
  var confirm: (_ answer: @escaping (Bool) -> Void) -> Void
  /// Called when the user cancels, so the switch can be drawn off again.
  var declined: () -> Void = {}

  var isOn: Bool { readOutput() == Self.pcmOutput }

  var restoredOutput: Int {
    Self.outputForFallback[min(max(readFallback(), 0), Self.outputForFallback.count - 1)]
  }

  func set(_ on: Bool) {
    guard on else {
      writeOutput(restoredOutput)
      return
    }
    guard !isOn else { return }
    confirm { confirmed in
      if confirmed {
        writeOutput(Self.pcmOutput)
      } else {
        declined()
      }
    }
  }
}
