#!/usr/bin/env python3

from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
NOTES_DIR = REPO_ROOT / ".github" / "release-notes"
OUTPUT_PATH = REPO_ROOT / "release_body.md"
DMG_NAME = "Moonlight-macOS-Universal.dmg"

TYPE_TO_ZH = {
    "feat": "新增",
    "fix": "修复",
    "docs": "文档",
    "refactor": "重构",
    "perf": "优化",
    "test": "测试",
    "ci": "持续集成",
    "build": "构建",
    "chore": "维护",
    "style": "样式",
}

PHRASE_REPLACEMENTS = [
    ("configurable stream shortcuts", "可配置串流快捷键"),
    ("stream shortcuts", "串流快捷键"),
    ("release guidance", "发布说明"),
    ("install docs", "安装说明"),
    ("shortcut reference", "快捷键说明"),
    ("stream diagnostics", "串流诊断"),
    ("display UX", "显示体验"),
    ("display", "显示"),
    ("input", "输入处理"),
    ("README", "README"),
    ("release notes", "Release Notes"),
    ("startup", "启动流程"),
    ("shortcuts", "快捷键"),
    ("mouse", "鼠标"),
    ("trackpad", "触控板"),
    ("overlay", "性能浮窗"),
    ("resolution", "分辨率"),
    ("reconnect", "重连"),
    ("stream", "串流"),
    ("guidance", "说明"),
    ("guides", "说明"),
    ("macOS", "macOS"),
]


def run_git(*args: str) -> str:
    result = subprocess.run(
        ["git", *args],
        cwd=REPO_ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


def get_previous_tag(current_tag: str) -> str | None:
    tags = [line.strip() for line in run_git("tag", "--sort=-v:refname").splitlines() if line.strip()]
    for tag in tags:
        if tag != current_tag and tag.startswith("v"):
            return tag
    return None


def parse_subject(subject: str) -> tuple[str | None, str | None, str]:
    match = re.match(r"^(?P<type>[a-z]+)(?:\((?P<scope>[^)]+)\))?!?: (?P<desc>.+)$", subject)
    if not match:
        return None, None, subject.strip()
    return match.group("type"), match.group("scope"), match.group("desc").strip()


def title_case_english(text: str) -> str:
    text = text.strip().rstrip(".")
    if not text:
        return text
    return text[0].upper() + text[1:]


def to_chinese_fragment(text: str) -> str:
    converted = text.strip().rstrip(".")
    for source, target in PHRASE_REPLACEMENTS:
        converted = re.sub(source, target, converted, flags=re.IGNORECASE)
    converted = converted.replace(" and ", "，并")
    converted = converted.replace(" with ", "，并包含")
    converted = converted.replace(" for ", "，面向")
    return converted


def build_fallback_highlights(current_tag: str, previous_tag: str | None) -> str:
    revision_range = f"{previous_tag}..{current_tag}" if previous_tag else current_tag
    subjects = [line.strip() for line in run_git("log", "--no-merges", "--format=%s", revision_range).splitlines() if line.strip()]

    lines: list[str] = ["### Highlights | 更新内容", ""]

    if not subjects:
        lines.extend([
            "- 本次版本已发布，完整改动请查看下方的版本对比链接。",
            "  This release is published; please use the compare link below for the full change list.",
        ])
        return "\n".join(lines)

    for subject in subjects:
        commit_type, scope, desc = parse_subject(subject)
        zh_prefix = TYPE_TO_ZH.get(commit_type or "", "更新")
        zh_desc = to_chinese_fragment(desc)
        en_desc = title_case_english(desc)

        if scope:
            lines.append(f"- {zh_prefix}（{scope}）：{zh_desc}。")
            lines.append(f"  {en_desc} for {scope}.")
        else:
            lines.append(f"- {zh_prefix}：{zh_desc}。")
            lines.append(f"  {en_desc}.")

    return "\n".join(lines)


def load_highlights(version: str, previous_tag: str | None) -> str:
    notes_path = NOTES_DIR / f"{version}.md"
    if notes_path.exists():
        return notes_path.read_text(encoding="utf-8").strip()
    return build_fallback_highlights(version, previous_tag)


def build_body(version: str) -> str:
    previous_tag = get_previous_tag(version)
    repo = os.environ.get("GITHUB_REPOSITORY", "skyhua0224/moonlight-macos-enhanced")
    compare_url = f"https://github.com/{repo}/compare/{previous_tag}...{version}" if previous_tag else f"https://github.com/{repo}/releases/tag/{version}"
    highlights = load_highlights(version, previous_tag)

    lines = [
        f"## Moonlight for macOS Enhanced {version}",
        "",
        highlights,
        "",
        "### Download | 下载",
        f"- 下载文件：`{DMG_NAME}`",
        f"  Download: `{DMG_NAME}` (Universal build for Apple Silicon and Intel Macs).",
        "",
        "### First Launch | 首次启动",
        f"1. 下载 `{DMG_NAME}`。",
        f"   Download `{DMG_NAME}`.",
        "2. 打开 DMG，并将 Moonlight 拖到 `Applications`。",
        "   Open the DMG and drag Moonlight to `Applications`.",
        "3. 先正常打开一次应用。",
        "   Try opening the app normally first.",
        "4. 如果 macOS 阻止打开，可右键应用选择“打开”，或前往 `System Settings → Privacy & Security → Open Anyway`。",
        "   If macOS blocks it, right-click the app and choose `Open`, or go to `System Settings → Privacy & Security → Open Anyway`.",
        "",
        "### If macOS says the app is damaged | 如果 macOS 提示“应用已损坏”",
        "- 这通常表示 Gatekeeper 拦截了未公证版本，并不一定是下载文件真的损坏。",
        "  This usually means Gatekeeper blocked a non-notarized build; it does not necessarily mean the download is corrupted.",
        "- 可在终端运行以下命令：",
        "  Run this command in Terminal:",
        "```bash",
        "xattr -dr com.apple.quarantine /Applications/Moonlight.app",
        "```",
        "- 执行后重新打开应用。",
        "  Launch the app again after the command finishes.",
        "- 不知道怎么打开终端？按 `⌘ Space`，输入 `Terminal`，回车即可。",
        "  To open Terminal, press `⌘ Space`, type `Terminal`, and press `Enter`.",
        "",
        "### Full Changelog | 完整变更",
    ]

    if previous_tag:
        lines.append(f"- 对比 `{previous_tag}` 与 `{version}`：[{previous_tag}...{version}]({compare_url})")
        lines.append(f"  Compare `{previous_tag}` and `{version}`: [{previous_tag}...{version}]({compare_url})")
    else:
        lines.append(f"- 查看当前版本发布页：[{version}]({compare_url})")
        lines.append(f"  View the current release page: [{version}]({compare_url})")

    return "\n".join(lines).strip() + "\n"


def main() -> None:
    version = os.environ.get("VERSION", "").strip()
    if not version:
        raise SystemExit("VERSION environment variable is required")

    OUTPUT_PATH.write_text(build_body(version), encoding="utf-8")


if __name__ == "__main__":
    main()
