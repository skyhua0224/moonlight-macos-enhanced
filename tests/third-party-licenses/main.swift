// Renders the third-party licenses window to a PNG, light or dark, in English or Chinese, with no screen-recording
// permission: the content view draws itself. usage: shoot <json> <out.png> <light|dark> <en|zh> [dependency id] [query]
import AppKit
import SwiftUI

let args = CommandLine.arguments
guard args.count >= 5, let data = try? Data(contentsOf: URL(fileURLWithPath: args[1])),
  let model = try? JSONDecoder().decode(ThirdPartyLicenseData.self, from: data)
else { fputs("usage: shoot <json> <out.png> <light|dark> <en|zh> [id] [query]\n", stderr); exit(2) }

UserDefaults.standard.set(args[4] == "zh" ? "简体中文" : "English", forKey: "appLanguage")
let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.appearance = NSAppearance(named: args[3] == "dark" ? .darkAqua : .aqua)

let view = ThirdPartyLicensesView(data: model, initialSelection: args.count > 5 && !args[5].isEmpty ? args[5] : nil,
                                  initialQuery: args.count > 6 ? args[6] : "")
let host = NSHostingController(rootView: view)
let window = NSWindow(contentViewController: host)
window.title = LanguageManager.shared.localize("Third-Party Licenses")
window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
window.setContentSize(NSSize(width: 860, height: 560))
window.center()
window.makeKeyAndOrderFront(nil)
window.orderFrontRegardless()
window.makeKey()
app.activate(ignoringOtherApps: true)

DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
  guard let frameView = window.contentView?.superview else { exit(3) }
  guard let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { exit(4) }
  frameView.cacheDisplay(in: frameView.bounds, to: rep)
  guard let png = rep.representation(using: .png, properties: [:]) else { exit(5) }
  try? png.write(to: URL(fileURLWithPath: args[2]))
  print("wrote \(args[2]) \(rep.pixelsWide)x\(rep.pixelsHigh)")
  exit(0)
}
app.run()
