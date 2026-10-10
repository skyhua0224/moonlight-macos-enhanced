#!/usr/bin/env python3
"""Fail when text shown by the log viewer has no entry in the Localizable.strings files.

The curated log builds its titles and details in DebugLogParser.swift through tr("..."),
and names its rule titles in the R("tag", "match", "Title", ...) table. The viewer itself
localises its chrome with languageManager.localize("..."). Every such key must exist in
both Limelight/macOS/zh-Hans.lproj/Localizable.strings and en.lproj/Localizable.strings,
otherwise a Chinese user silently sees the English key again.

Usage: python3 scripts/check_log_text_coverage.py
Not part of the Xcode build; run it after changing log titles.
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VIEW_DIR = os.path.join(ROOT, "Limelight", "macOS", "ViewControllers")
PARSER = os.path.join(VIEW_DIR, "DebugLogParser.swift")
VIEWER = os.path.join(VIEW_DIR, "SettingsLogViewer.swift")
# The in-stream log panel's notification text lives in Objective-C.
OVERLAY_HOST = os.path.join(VIEW_DIR, "StreamViewController+Diagnostics.m")
STRINGS = {
    "zh-Hans": os.path.join(ROOT, "Limelight", "macOS", "zh-Hans.lproj", "Localizable.strings"),
    "en": os.path.join(ROOT, "Limelight", "macOS", "en.lproj", "Localizable.strings"),
}

LITERAL = r'"((?:[^"\\]|\\.)*)"'


def unescape(text):
    return text.replace('\\"', '"').replace("\\\\", "\\")


def swift_keys():
    """(key, file, line) for every localised literal in the parser and the viewer."""
    found = []
    with open(PARSER, encoding="utf-8") as handle:
        parser = handle.read()
    with open(VIEWER, encoding="utf-8") as handle:
        viewer = handle.read()

    def collect(text, name, pattern, group=1):
        for match in re.finditer(pattern, text):
            line = text.count("\n", 0, match.start()) + 1
            found.append((unescape(match.group(group)), name, line))

    # tr("key") and tr("format %@", args...), also when the literal is on the next line.
    collect(parser, "DebugLogParser.swift", r"\btr\(\s*" + LITERAL)
    # Rule table: R("tag", "match", "Title", detail)
    collect(parser, "DebugLogParser.swift", r'\bR\(\s*"[^"]*",\s*"(?:[^"\\]|\\.)*",\s*' + LITERAL)
    # Category descriptors: displayName / badgeText are localisation keys.
    collect(parser, "DebugLogParser.swift", r"\b(?:displayName|badgeText):\s*" + LITERAL)
    # Noise category names: the `return "..."` lines of DebugNoiseCategory.displayName.
    start = parser.find("enum DebugNoiseCategory")
    end = parser.find("extension DebugNoiseCategory")
    if start != -1 and end > start:
        block = parser[start:end]
        for match in re.finditer(r"return " + LITERAL, block):
            line = parser.count("\n", 0, start + match.start()) + 1
            found.append((unescape(match.group(1)), "DebugLogParser.swift", line))
    # Level names shown by the badge and filters.
    start = parser.find("var displayText: String")
    if start != -1:
        block = parser[start : start + 600]
        for match in re.finditer(r"return " + LITERAL, block):
            line = parser.count("\n", 0, start + match.start()) + 1
            found.append((unescape(match.group(1)), "DebugLogParser.swift", line))
    # Viewer chrome.
    collect(viewer, "SettingsLogViewer.swift", r"\blocalize\(\s*" + LITERAL)
    # In-stream overlay host: the "Logs copied" toast.
    with open(OVERLAY_HOST, encoding="utf-8") as handle:
        host = handle.read()
    for match in re.finditer(r'MLString\(@"((?:[^"\\]|\\.)*)"', host):
        if "Logs copied" in match.group(1):
            line = host.count("\n", 0, match.start()) + 1
            found.append((unescape(match.group(1)), "StreamViewController+Diagnostics.m", line))
    return found


def strings_keys(path):
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    return {unescape(m.group(1)) for m in re.finditer(r"^" + LITERAL + r"\s*=", text, re.M)}


def main():
    keys = swift_keys()
    unique = {}
    for key, name, line in keys:
        unique.setdefault(key, (name, line))

    failures = 0
    for language, path in STRINGS.items():
        have = strings_keys(path)
        missing = sorted(key for key in unique if key not in have)
        print(f"{language}: {len(unique) - len(missing)}/{len(unique)} keys present")
        for key in missing:
            name, line = unique[key]
            print(f"  MISSING in {language}: {key!r} ({name}:{line})")
        failures += len(missing)

    if failures:
        print(f"FAILED: {failures} missing entries")
        return 1
    print(f"OK: {len(unique)} log text keys are present in both Localizable.strings files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
