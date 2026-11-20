#!/usr/bin/env python3
"""Run the production keyboard routes with AppKit events and a recording host."""
import os
from pathlib import Path
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
VIEWS = ROOT / "Limelight/macOS/ViewControllers"


def extract_body(source, signature):
    start = source.index(signature)
    opening_brace = source.index("{", start)
    depth = 1
    for end in range(opening_brace + 1, len(source)):
        depth += (source[end] == "{") - (source[end] == "}")
        if depth == 0:
            return source[start : end + 1]
    raise ValueError(f"Unclosed body for {signature}")


controller = (VIEWS / "StreamViewController+MouseCapture.m").read_text()
internal = (VIEWS / "StreamViewController_Internal.h").read_text()
key_up_monitor = "[NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyUp handler:"
monitor = controller.split(key_up_monitor, 1)[1]
monitor_block = extract_body(monitor, monitor.split("{", 1)[0])
methods = "\n".join(
    extract_body(controller, signature)
    for signature in (
        "- (void)keyDown:(NSEvent *)event",
        "- (void)keyUp:(NSEvent *)event",
        "- (KeyboardTranslationRule *)keyboardTranslationRuleMatchingEvent:",
        "- (BOOL)handleKeyboardTranslationRuleForEvent:",
        "- (BOOL)onKeyboardEquivalent:",
    )
)
with tempfile.TemporaryDirectory(prefix="key-repeat-", dir=os.getenv("TMPDIR", "/var/tmp")) as directory:
    build = Path(directory)
    (build / "shortcut_modifiers.inc").write_text(
        extract_body(internal, "static inline NSEventModifierFlags MLRelevantShortcutModifiers(")
    )
    (build / "keyboard_routes.inc").write_text(
        methods + "\n- (NSEvent *)monitorKeyUp:(NSEvent *)event {\n"
        "    __weak typeof(self) weakSelf = self;\n"
        f"    return ({monitor_block})(event);\n"
        "}\n"
    )
    binary = build / "test_key_repeat"
    subprocess.run(
        [
            "clang", "-fobjc-arc", "-Wall", "-Wextra", "-Werror",
            "-Wno-unused-parameter", "-framework", "AppKit",
            "-I", str(build), "-I", str(ROOT / "Limelight/Input"),
            str(HERE / "test_key_repeat.m"), "-o", str(binary),
        ],
        check=True,
    )
    subprocess.run([str(binary)], check=True)
