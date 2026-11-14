// Measures every row description (both languages) at the width a row description really has in the settings window.
// usage: static_check <keys.txt> <en.strings> <zh.strings> <width>
import AppKit
let a = CommandLine.arguments
guard a.count >= 5, let keys = try? String(contentsOfFile: a[1]).split(separator: "\n").map(String.init),
  let en = NSDictionary(contentsOfFile: a[2]) as? [String: String], let zh = NSDictionary(contentsOfFile: a[3]) as? [String: String],
  let width = Double(a[4]) else { fputs("usage\n", stderr); exit(2) }
let font = NSFont.preferredFont(forTextStyle: .footnote)
let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
func lines(_ text: String) -> Int {
  let rect = (text as NSString).boundingRect(with: NSSize(width: width, height: 10000), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
  return Int((rect.height / lineHeight).rounded())
}
var bad = 0, measured = 0
for key in keys {
  for (lang, table) in [("en", en), ("zh", zh)] {
    guard let text = table[key] else { continue }
    measured += 1
    let n = lines(text)
    if n > 1 { bad += 1; print("\(lang) \(n) lines  \(key): \(text.prefix(70))") }
  }
}
print("\(measured) descriptions measured at \(Int(width)) pt, \(bad) need more than one line")
exit(bad == 0 ? 0 : 1)
