import Foundation
var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
  if !ok { failures += 1 }
  print("\(ok ? "PASS" : "FAIL") \(name)\(ok ? "" : " — " + detail())")
}
func app(_ id: String, _ name: String, _ kind: String? = nil) -> DeckPlanApp { DeckPlanApp(id: id, name: name, kind: kind) }

// 1. Foundation Sunshine with 大屏 (FsKind): the button is offered, 桌面 and 大屏 are not in the grid
do {
  let apps = [app("1", "Desktop", "desktop"), app("2", "大屏", "bigscreen"), app("3", "Steam", "game")]
  let p = DeckConnectPlan.make(isFoundation: true, apps: apps)
  check("FS with 大屏: button offered", p.bigScreenId == "2", "\(p)")
  check("FS with 大屏: 连接桌面 starts the Desktop entry", p.target == .desktop(id: "1"), "\(p)")
  check("FS with 大屏: both entries hidden from the grid", p.hiddenFromGrid == ["1", "2"], "\(p.hiddenFromGrid)")
}
// 2. Foundation Sunshine without 大屏
do {
  let apps = [app("1", "Desktop", "desktop"), app("3", "Steam", "game")]
  let p = DeckConnectPlan.make(isFoundation: true, apps: apps)
  check("FS without 大屏: no button", p.bigScreenId == nil, "\(p)")
  check("FS without 大屏: Desktop hidden, Steam shown", p.hiddenFromGrid == ["1"], "\(p.hiddenFromGrid)")
}
// 2b. FS host with no Desktop entry at all: first app, the grid keeps everything
do {
  let p = DeckConnectPlan.make(isFoundation: true, apps: [app("3", "Steam", "game")])
  check("FS without Desktop: 连接 <first app>, nothing hidden", p.target == .firstApp(id: "3", name: "Steam") && p.hiddenFromGrid.isEmpty, "\(p)")
}
// 2c. FS host, no Desktop entry, the list starts with the 大屏 entry: the button starts the first real app
do {
  let p = DeckConnectPlan.make(isFoundation: true, apps: [app("2", "大屏", "bigscreen"), app("3", "Steam", "game")])
  check("FS without Desktop, 大屏 first: 连接 <first app that is not 大屏>", p.target == .firstApp(id: "3", name: "Steam") && p.bigScreenId == "2", "\(p)")
}
// 3. other host with a Desktop app
for name in ["Desktop", "桌面", "Remote Desktop (Parsec)"] {
  let apps = [app("7", "Alpha"), app("8", name), app("9", "Zed")]
  let p = DeckConnectPlan.make(isFoundation: false, apps: apps)
  check("non-FS with \(name): 连接桌面 starts it", p.target == .desktop(id: "8"), "\(p)")
  check("non-FS with \(name): it is not repeated in the grid", p.hiddenFromGrid == ["8"], "\(p.hiddenFromGrid)")
  check("non-FS with \(name): no 大屏 button", p.bigScreenId == nil)
}
do {   // a second Desktop-like app stays in the grid
  let p = DeckConnectPlan.make(isFoundation: false, apps: [app("1", "Desktop"), app("2", "Remote Desktop")])
  check("non-FS with two desktop-like apps: only the first is the button's", p.hiddenFromGrid == ["1"], "\(p.hiddenFromGrid)")
}
// 4. other host without a Desktop app: the first app, every app in the grid
do {
  let apps = [app("5", "Cyberpunk 2077"), app("6", "Steam"), app("7", "Hades")]
  let p = DeckConnectPlan.make(isFoundation: false, apps: apps)
  check("non-FS without Desktop: 连接 <first app>", p.target == .firstApp(id: "5", name: "Cyberpunk 2077"), "\(p)")
  check("non-FS without Desktop: nothing hidden", p.hiddenFromGrid.isEmpty, "\(p.hiddenFromGrid)")
  check("non-FS without Desktop: no 大屏 button", p.bigScreenId == nil)
}
// 5. other host with an app called 大屏 / Big Picture: an ordinary app
for name in ["大屏", "大屏模式", "Steam Big Picture", "Big Screen"] {
  let apps = [app("1", name), app("2", "Hades")]
  let p = DeckConnectPlan.make(isFoundation: false, apps: apps)
  check("non-FS app named \(name): no 大屏 button", p.bigScreenId == nil, "\(p)")
  check("non-FS app named \(name): in the grid", !p.hiddenFromGrid.contains("1"), "\(p.hiddenFromGrid)")
  check("non-FS app named \(name): is the first app, so 连接 <it>", p.target == .firstApp(id: "1", name: name), "\(p)")
}
// 5b. a host that sends FsKind=bigscreen but is not Foundation Sunshine (cannot happen; still no button)
do {
  let p = DeckConnectPlan.make(isFoundation: false, apps: [app("1", "Big", "bigscreen"), app("2", "Hades")])
  check("non-FS: no 大屏 button even for a bigscreen kind", p.bigScreenId == nil, "\(p)")
}
// 6. empty list
do {
  let p = DeckConnectPlan.make(isFoundation: false, apps: [])
  check("empty list: button disabled", p.target == .none && p.bigScreenId == nil && p.hiddenFromGrid.isEmpty, "\(p)")
  let q = DeckConnectPlan.make(isFoundation: true, apps: [])
  check("empty list on FS: button disabled", q.target == .none, "\(q)")
}
// 连接桌面 next to 继续 while an app runs
do {
  let apps = [app("1", "Desktop", "desktop"), app("2", "大屏", "bigscreen"), app("3", "Steam Big Picture", "tool"), app("4", "Hades", "game")]
  let p = DeckConnectPlan.make(isFoundation: true, apps: apps)
  check("Steam runs: 连接桌面 is offered (the Desktop entry)", DeckConnectPlan.desktopWhileRunning(plan: p, runningId: "3") == "1")
  check("a game runs: offered", DeckConnectPlan.desktopWhileRunning(plan: p, runningId: "4") == "1")
  check("大屏模式 runs: offered", DeckConnectPlan.desktopWhileRunning(plan: p, runningId: "2") == "1")
  check("the Desktop itself runs: not offered (that is 继续)", DeckConnectPlan.desktopWhileRunning(plan: p, runningId: "1") == nil)
  check("nothing runs: not offered here (连接桌面 is the main button)", DeckConnectPlan.desktopWhileRunning(plan: p, runningId: nil) == nil && DeckConnectPlan.desktopWhileRunning(plan: p, runningId: "") == nil)
  let noDesktop = DeckConnectPlan.make(isFoundation: true, apps: [app("2", "大屏", "bigscreen"), app("3", "Steam", "tool")])
  check("no Desktop entry on the host: not offered", DeckConnectPlan.desktopWhileRunning(plan: noDesktop, runningId: "3") == nil)
  let plain = DeckConnectPlan.make(isFoundation: false, apps: [app("1", "Desktop"), app("9", "Game")])
  check("plain Sunshine with a Desktop app: offered while the game runs", DeckConnectPlan.desktopWhileRunning(plan: plain, runningId: "9") == "1")
  // 大屏 is its own app: it has its own id, which is what the running app is compared with
  check("大屏模式 and Steam are two apps: 大屏 id differs from the running Steam id", p.bigScreenId == "2" && p.bigScreenId != "3")
}
// 退出 <app>: whatever runs, 桌面 and 大屏模式 included
do {
  let apps = [app("1", "Desktop", "desktop"), app("2", "大屏", "bigscreen"), app("3", "Steam", "game"), app("4", "  ", "game")]
  func entry(_ id: String?, reachable: Bool = true) -> DeckQuitEntry? { DeckConnectPlan.quitEntry(runningId: id, apps: apps, reachable: reachable) }
  check("quit: Desktop runs -> 退出桌面", entry("1") == DeckQuitEntry(appId: "1", name: "Desktop", role: .desktop))
  check("quit: 大屏模式 runs -> 退出大屏模式", entry("2") == DeckQuitEntry(appId: "2", name: "大屏", role: .bigScreen))
  let plainDesk = [app("1", "Desktop"), app("9", "Game")]
  check("quit: a plain host's Desktop is named by name", DeckConnectPlan.quitEntry(runningId: "1", apps: plainDesk, reachable: true)?.role == .desktop)
  check("quit: a plain host's game stays 退出 X", DeckConnectPlan.quitEntry(runningId: "9", apps: plainDesk, reachable: true)?.role == .app)
  check("quit: an ordinary app runs", entry("3") == DeckQuitEntry(appId: "3", name: "Steam"))
  check("quit: no name given -> nil name", entry("4") == DeckQuitEntry(appId: "4", name: nil))
  check("quit: nothing runs", entry(nil) == nil && entry("") == nil && entry("0") == nil)
  check("quit: running id not in the list", entry("99") == nil)
  check("quit: host off or not paired", entry("3", reachable: false) == nil)
}
// names
check("short name kept", DeckConnectPlan.shortName("Hades") == "Hades")
check("long name cut", DeckConnectPlan.shortName("The Witcher 3: Wild Hunt — Complete Edition") == "The Witcher 3: …", DeckConnectPlan.shortName("The Witcher 3: Wild Hunt — Complete Edition"))
print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
