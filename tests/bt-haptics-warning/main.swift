// Logic test of the Full Bluetooth Haptics switch: the warning gate, cancel, confirm, and switching off.
import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String) {
  print("\(ok ? "ok  " : "FAIL") \(what)")
  if !ok { failures += 1 }
}

final class Fixture {
  var output: Int
  var fallback: Int
  var asked = 0
  var declinedCount = 0
  var answer: ((Bool) -> Void)?
  init(output: Int, fallback: Int) { self.output = output; self.fallback = fallback }
  lazy var sw = BluetoothFullHapticsSwitch(
    readOutput: { self.output },
    writeOutput: { self.output = $0 },
    readFallback: { self.fallback },
    confirm: { answer in self.asked += 1; self.answer = answer },
    declined: { self.declinedCount += 1 })
}

// turning on writes nothing before the user answers
do {
  let f = Fixture(output: 2, fallback: 1)
  f.sw.set(true)
  check(f.asked == 1, "set(true) asks once")
  check(f.output == 2, "set(true) leaves btOutput unchanged before the answer")
  check(!f.sw.isOn, "switch reads off while the warning is open")
  f.answer?(true)
  check(f.output == 4 && f.sw.isOn, "confirm sets btOutput 4")
  check(f.declinedCount == 0, "confirm does not report a cancel")
}
// cancel keeps the previous value, for every starting output
for start in [0, 1, 2, 3] {
  let f = Fixture(output: start, fallback: 1)
  f.sw.set(true)
  f.answer?(false)
  check(f.output == start && !f.sw.isOn, "cancel keeps btOutput \(start)")
  check(f.declinedCount == 1, "cancel tells the view to redraw (start \(start))")
}
// switching off restores the fallback's output without asking
for (fallback, expected) in [(0, 0), (1, 2), (2, 1), (3, 3)] {
  let f = Fixture(output: 4, fallback: fallback)
  f.sw.set(false)
  check(f.output == expected, "set(false) restores output \(expected) for fallback \(fallback)")
  check(f.asked == 0, "set(false) shows no dialog (fallback \(fallback))")
}
// out-of-range fallbacks are clamped
do {
  let low = Fixture(output: 4, fallback: -5); low.sw.set(false)
  let high = Fixture(output: 4, fallback: 99); high.sw.set(false)
  check(low.output == 0 && high.output == 3, "set(false) clamps a stored fallback outside 0...3")
}
// already on: no second warning, value stays
do {
  let f = Fixture(output: 4, fallback: 0)
  f.sw.set(true)
  check(f.asked == 0 && f.output == 4, "set(true) while already on neither asks nor changes")
}
// every on/off cycle asks again (no remembered consent)
do {
  let f = Fixture(output: 0, fallback: 0)
  for _ in 0..<3 {
    f.sw.set(true); f.answer?(true); f.sw.set(false)
  }
  check(f.asked == 3 && f.output == 0, "each turn-on from off shows the warning again")
}
print(failures == 0 ? "all passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
