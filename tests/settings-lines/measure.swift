// Lines each text takes at a given width (footnote font). usage: measure <in.json> <width> -> JSON on stdout
// in.json: {"texts": {"id": "text", ...}}
import AppKit
let a = CommandLine.arguments
guard a.count >= 3, let data = FileManager.default.contents(atPath: a[1]),
  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String], let width = Double(a[2]) else { exit(2) }
let font = NSFont.preferredFont(forTextStyle: .footnote)
let lh = NSLayoutManager().defaultLineHeight(for: font)
var out: [String: Int] = [:]
for (k, t) in obj {
  let r = (t as NSString).boundingRect(with: NSSize(width: width, height: 10000), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
  out[k] = Int((r.height / lh).rounded())
}
print(String(data: try! JSONSerialization.data(withJSONObject: out), encoding: .utf8)!)
