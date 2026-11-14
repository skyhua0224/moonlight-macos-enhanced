import Foundation
var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
  if !ok { failures += 1 }
  print("\(ok ? "PASS" : "FAIL") \(name)\(ok ? "" : " — " + detail())")
}

// ---- focus graph: the Deck computer sidebar is never in it
do {
  let sidebarEdge: CGFloat = 240
  let rows: [CGFloat] = [20, 120, 239]          // centres inside the sidebar
  let page: [CGFloat] = [241, 300, 900]         // centres on the page
  for deckMain in [true] {
    for column in [true, false] {               // whatever column the navigator believes it is in
      let reachable = (rows + page).filter {
        PadFocusScope.includes(midX: $0, sidebarMaxX: sidebarEdge, sidebarColumn: column, deckMain: deckMain)
      }
      check("deck main (column \(column ? "sidebar" : "detail")): only page controls are targets", reachable == page, "\(reachable)")
    }
  }
  let settingsSidebar = rows.filter { PadFocusScope.includes(midX: $0, sidebarMaxX: sidebarEdge, sidebarColumn: true, deckMain: false) }
  check("settings window: its sidebar column keeps the sidebar controls", settingsSidebar == rows)
  let settingsDetail = (rows + page).filter { PadFocusScope.includes(midX: $0, sidebarMaxX: sidebarEdge, sidebarColumn: false, deckMain: false) }
  check("settings window: its detail column keeps the page controls", settingsDetail == page)
  check("a window without a sidebar keeps every control",
        PadFocusScope.includes(midX: 5, sidebarMaxX: nil, sidebarColumn: false, deckMain: true))
  check("the sidebar edge belongs to the page (centre at the edge is not in the sidebar)",
        PadFocusScope.includes(midX: 240, sidebarMaxX: 240, sidebarColumn: false, deckMain: true))
}

// ---- focus return after a window closes
do {
  check("return: the remembered control is back", PadFocusReturn.step(found: true, ticksLeft: 100) == .restore)
  check("return: found at the last poll still restores", PadFocusReturn.step(found: true, ticksLeft: 0) == .restore)
  check("return: the page is still being rebuilt", PadFocusReturn.step(found: false, ticksLeft: 50) == .wait)
  check("return: it never came back, the page default takes the focus", PadFocusReturn.step(found: false, ticksLeft: 0) == .pageDefault)
  check("return: no polls left is the page default, not the sidebar", PadFocusReturn.step(found: false, ticksLeft: -1) == .pageDefault)
  // the whole way back as the navigator walks it: ticks count down until the control is there
  var ticks = 120
  var steps: [PadFocusReturn.Step] = []
  let appearsAt = 30
  while true {
    ticks -= 1
    let step = PadFocusReturn.step(found: (120 - ticks) >= appearsAt, ticksLeft: ticks)
    steps.append(step)
    if step != .wait { break }
  }
  check("return: waits while the page rebuilds, then restores", steps.count == appearsAt && steps.last == .restore, "\(steps.count) \(String(describing: steps.last))")
}

// ---- LB / RB
do {
  let order = ["a", "b", "c"]
  func step(_ selected: String?, _ delta: Int) -> PadHostStep? { PadHostSwitch.step(order: order, selected: selected, delta: delta) }
  check("RB: next computer", step("a", 1) == PadHostStep(id: "b", index: 1, count: 3, moved: true))
  check("LB: previous computer", step("c", -1) == PadHostStep(id: "b", index: 1, count: 3, moved: true))
  check("RB at the end stays and says so", step("c", 1) == PadHostStep(id: "c", index: 2, count: 3, moved: false))
  check("LB at the start stays and says so", step("a", -1) == PadHostStep(id: "a", index: 0, count: 3, moved: false))
  check("nothing selected: RB gives the first", step(nil, 1)?.id == "a")
  check("nothing selected: LB gives the last", step(nil, -1)?.id == "c")
  check("a selection that is not in the list (an old record): RB gives the first", step("gone", 1)?.id == "a")
  check("no computers: nothing", PadHostSwitch.step(order: [], selected: nil, delta: 1) == nil)
  var selected: String? = "a"
  var visited: [String] = []
  for _ in 0..<4 { if let s = step(selected, 1) { selected = s.id; visited.append(s.id) } }
  check("RB walks the list in order and stops at the end", visited == ["b", "c", "c", "c"], "\(visited)")
}

// ---- LT / RT: section jump
do {
  func item(_ id: String, _ section: String?, _ top: Double, _ left: Double = 0, entry: Bool = false) -> PadSectionItem {
    PadSectionItem(id: id, section: section, top: top, left: left, isEntry: entry)
  }
  // a Deck page: hero (chips, primary, buttons), the 最近使用 shelf, a loose slider, the 应用 grid
  let page = [
    item("icon", "computer", 60), item("chip", "computer", 236, 320), item("primary", "computer", 320, 288, entry: true),
    item("more", "computer", 320, 919), item("label", "computer", 444),
    item("recent1", "continuePlaying", 520, 288), item("recent2", "continuePlaying", 520, 687),
    item("slider", nil, 700, 1097),
    item("app1", "apps", 760, 288), item("app2", "apps", 760, 687), item("app3", "apps", 990, 288),
  ]
  func jump(_ from: String, _ forward: Bool, _ preferred: [String: String] = [:]) -> String? {
    PadSectionJump.target(items: page, current: from, forward: forward, preferred: preferred)
  }
  check("sections: RT from the hero lands on the first control of the next shelf", jump("primary", true) == "recent1")
  check("sections: RT from any hero control does the same", jump("icon", true) == "recent1" && jump("label", true) == "recent1")
  check("sections: RT again goes to the grid", jump("recent2", true) == "app1")
  check("sections: the loose slider belongs to the shelf above it (RT goes on to the grid)", jump("slider", true) == "app1")
  check("sections: ... and LT from it goes to the hero", jump("slider", false) == "primary")
  check("sections: LT from the shelf lands on the hero's primary button, not its top control", jump("recent1", false) == "primary")
  check("sections: LT from the grid goes to the shelf", jump("app3", false) == "recent1")
  check("sections: LT in the first section does nothing (no wrap)", jump("primary", false) == nil)
  check("sections: RT in the last section does nothing (no wrap)", jump("app2", true) == nil)
  check("sections: the control last visited in a section is where the jump returns",
        jump("primary", true, ["continuePlaying": "recent2"]) == "recent2")
  check("sections: a remembered control that is gone is ignored", jump("primary", true, ["continuePlaying": "gone"]) == "recent1")
  check("sections: an unknown current control does nothing", jump("nope", true) == nil)
  check("sections: one section only means no jump",
        PadSectionJump.target(items: [item("a", "x", 0), item("b", "x", 50)], current: "a", forward: true) == nil)
  check("sections: no sections at all means no jump (the page jump takes over)",
        PadSectionJump.target(items: [item("a", nil, 0), item("b", nil, 50)], current: "a", forward: true) == nil)
  check("sections: controls above the first marked one join the first section",
        PadSectionJump.target(items: [item("a", nil, 0), item("b", "s1", 40), item("c", "s2", 90)], current: "a", forward: true) == "c")
}

// ---- LT / RT: page jump where there are no sections
do {
  func rows(_ n: Int, step: Double = 40) -> [PadPageItem] { (0..<n).map { PadPageItem(id: "r\($0)", midX: 100, midY: Double($0) * step) } }
  let list = rows(30)
  check("page: RT jumps about a page down", PadPageJump.target(items: list, current: "r0", pageHeight: 400, forward: true) == "r8", "\(String(describing: PadPageJump.target(items: list, current: "r0", pageHeight: 400, forward: true)))")
  check("page: LT jumps about a page up", PadPageJump.target(items: list, current: "r20", pageHeight: 400, forward: false) == "r12")
  check("page: less than a page left goes to the last control", PadPageJump.target(items: list, current: "r25", pageHeight: 400, forward: true) == "r29")
  check("page: less than a page up goes to the first control", PadPageJump.target(items: list, current: "r4", pageHeight: 400, forward: false) == "r0")
  check("page: on the last control RT does nothing", PadPageJump.target(items: list, current: "r29", pageHeight: 400, forward: true) == nil)
  check("page: on the first control LT does nothing", PadPageJump.target(items: list, current: "r0", pageHeight: 400, forward: false) == nil)
  let wide = [PadPageItem(id: "cur", midX: 300, midY: 0), PadPageItem(id: "left", midX: 50, midY: 330), PadPageItem(id: "mid", midX: 280, midY: 330), PadPageItem(id: "far", midX: 300, midY: 900)]
  check("page: the control nearest in the row a page away, by column", PadPageJump.target(items: wide, current: "cur", pageHeight: 400, forward: true) == "mid")
  check("page: an unknown current control does nothing", PadPageJump.target(items: list, current: "x", pageHeight: 400, forward: true) == nil)
}

print(failures == 0 ? "all passed" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
