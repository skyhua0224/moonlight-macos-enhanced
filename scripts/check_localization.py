#!/usr/bin/env python3
"""Check the two Localizable.strings files, the only place the app's text lives.

Fails (exit 1) when:
  * LanguageManager.swift holds a built-in string table again (two copies of one text drift apart,
    and the one in Swift wins at runtime, so an edit to the .strings file does nothing);
  * a key appears twice in one file;
  * a key ends in "subtitle", "detail", "hint" or "note" and its English text is the key itself
    (English users would read "USB settings subtitle" on the screen). A key that has no English
    entry counts: the key is what is shown.

Prints, without failing, the keys that exist in only one of the two files.

Usage: python3 scripts/check_localization.py
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MACOS = os.path.join(ROOT, "Limelight", "macOS")
FILES = {
    "en": os.path.join(MACOS, "en.lproj", "Localizable.strings"),
    "zh-Hans": os.path.join(MACOS, "zh-Hans.lproj", "Localizable.strings"),
}
LANGUAGE_MANAGER = os.path.join(MACOS, "Helpers", "LanguageManager.swift")

LITERAL = r'"((?:[^"\\]|\\.)*)"'
PAIR = re.compile(r"^\s*" + LITERAL + r"\s*=\s*" + LITERAL + r"\s*;\s*$")
DESCRIPTIVE = re.compile(r"\s(subtitle|detail|hint|note)$")
BUILT_IN_TABLE = re.compile(r"\blet\s+(en|zhHans)\s*:\s*\[String\s*:\s*String\]")


COMMENT = re.compile(r"/\*.*?\*/|//[^\n]*", re.S)


def strip_comments(text):
    """Drop /* */ and // comments (valid in .strings files) but keep line numbers and string literals."""
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if c == '"':
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            out.append(text[i:j + 1]); i = j + 1
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2); j = n if j < 0 else j + 2
            out.append("\n" * text.count("\n", i, j)); i = j
        elif text.startswith("//", i):
            j = text.find("\n", i); j = n if j < 0 else j
            i = j
        else:
            out.append(c); i += 1
    return "".join(out)


def read_strings(path):
    values, duplicates = {}, []
    with open(path, encoding="utf-8") as handle:
        text = strip_comments(handle.read())
        for number, line in enumerate(text.split("\n"), 1):
            match = PAIR.match(line)
            if not match:
                continue
            key, value = match.group(1), match.group(2)
            if key in values:
                duplicates.append((key, number))
            values[key] = value
    return values, duplicates


def main():
    problems = []
    tables = {}
    for language, path in FILES.items():
        tables[language], duplicates = read_strings(path)
        for key, number in duplicates:
            problems.append("%s:%d: duplicate key '%s'" % (os.path.relpath(path, ROOT), number, key))

    with open(LANGUAGE_MANAGER, encoding="utf-8") as handle:
        if BUILT_IN_TABLE.search(handle.read()):
            problems.append(
                "LanguageManager.swift has a built-in string table; put the text in the two "
                "Localizable.strings files instead")

    english, chinese = tables["en"], tables["zh-Hans"]
    for key in sorted(set(english) | set(chinese)):
        if DESCRIPTIVE.search(key) and english.get(key, key) == key:
            problems.append("'%s': the English text is the key itself" % key)

    only_en = sorted(set(english) - set(chinese))
    only_zh = sorted(set(chinese) - set(english))
    if only_en:
        print("Only in en.lproj (%d):" % len(only_en))
        for key in only_en:
            print("  " + key)
    if only_zh:
        print("Only in zh-Hans.lproj (%d), English falls back to the key:" % len(only_zh))
        for key in only_zh:
            print("  " + key)

    if problems:
        print("FAILED: %d problem(s)" % len(problems))
        for problem in problems:
            print("  " + problem)
        return 1
    print("OK: %d en keys, %d zh-Hans keys" % (len(english), len(chinese)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
