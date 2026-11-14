#!/usr/bin/env python3
"""Lists the localisation keys of every row description in the settings code: what is passed as detail: or detailKey:,
the full-width SettingDescriptionRow lines, and the Text("key") lines set in .footnote. (Pop-over texts, shown by the
info button, are not row descriptions and are not listed.)  usage: keys.py <repo root>  -> one key per line"""
import glob, os, re, sys
root = sys.argv[1]
files = glob.glob(os.path.join(root, "Limelight/macOS/ViewControllers/Settings*.swift"))
keys = set()
for f in files:
    if f.endswith("SettingsSearchIndex.generated.swift") or f.endswith("SettingsLineCheck.swift"):
        continue
    s = open(f, encoding="utf-8").read()
    for m in re.finditer(r'\bdetail(?:Key)?:\s*"([^"]+)"', s):
        keys.add(m.group(1))
    for m in re.finditer(r'textKey:\s*"([^"]+)"', s):
        keys.add(m.group(1))
    for m in re.finditer(r'(?:languageManager\.localize\(|Text\()"([^"]+)"\)\s*\n?\s*\.font\(\.footnote\)', s):
        keys.add(m.group(1))
    for m in re.finditer(r'return "([A-Za-z0-9 .\'+-]+(?:detail|hint|Hint|note|warning)[A-Za-z0-9 ]*)"', s):
        keys.add(m.group(1))
# descriptions that reach a row through a computed value (a ternary, a model property): every quoted key whose name
# says detail / hint / note, except the ones only ever handed to an info button (hintKey:), which are pop-overs
popover_only = set()
for f in files:
    if f.endswith("SettingsSearchIndex.generated.swift") or f.endswith("SettingsLineCheck.swift"):
        continue
    s = open(f, encoding="utf-8").read()
    for m in re.finditer(r'"([^"\n]+)"', s):
        k = m.group(1)
        if re.search(r"(detail|hint|note|warning)\b", k, re.I) and " " in k and not k.startswith("http"):
            before = s[max(0, m.start() - 20):m.start()]
            if "hintKey:" in before or "InfoHintButton(" in before:
                popover_only.add(k)
            else:
                keys.add(k)
keys -= {k for k in popover_only if k not in keys}
print("\n".join(sorted(keys)))
