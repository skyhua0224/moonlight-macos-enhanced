#!/usr/bin/env python3
"""Builds the third-party license data the About window shows:
Limelight/macOS/Supporting Files/ThirdPartyLicenses.json

Every entry is something that is really in the app bundle (see DEPENDENCIES: the "evidence" field says how that was
established for the release build). Every license text is read from a file: the dependency's own source tree where the
tree has it, otherwise the text kept under docs/third-party/ (see docs/third-party/SOURCES.md for where each was
read). Nothing is typed from memory.

A license text that several dependencies share (the same MIT or BSD wording, Apache 2.0, GPL 3) is stored once; each
dependency keeps its own copyright lines, which the viewer puts above the shared text.

usage:
  generate_third_party_licenses.py          write the JSON
  generate_third_party_licenses.py --check  exit 1 when the JSON is stale
"""
import hashlib
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Limelight/macOS/Supporting Files/ThirdPartyLicenses.json")
TP = os.path.join(ROOT, "docs/third-party")
COMMON = os.path.join(ROOT, "moonlight-common/moonlight-common-c")


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def norm(text):
    text = text.replace("\r\n", "\n").strip("\n")
    return re.sub(r"\n{3,}", "\n\n", text)


def paragraphs(text):
    return [p for p in re.split(r"\n\s*\n", norm(text)) if p.strip()]


def split_copyright(text, drop_first_if=None, keep_paragraphs=1):
    """(copyright lines, license body): the leading copyright paragraph(s) are the dependency's; the rest can be shared."""
    paras = paragraphs(text)
    if drop_first_if and paras and re.search(drop_first_if, paras[0]):
        paras = paras[1:]
    lead = paras[:keep_paragraphs]
    body = paras[keep_paragraphs:]
    copyright_lines = []
    for p in lead:
        for line in p.split("\n"):
            line = line.strip()
            if line and not re.fullmatch(r"all rights reserved\.?", line, re.I):
                copyright_lines.append(line)
    return copyright_lines, "\n\n".join(body)


def c_comment_text(path, paragraphs_to_skip=0):
    src = read(path)
    m = re.match(r"\s*/\*(.*?)\*/", src, re.S)
    lines = [re.sub(r"^\s*\* ?", "", l) for l in m.group(1).split("\n")]
    # the line that names the file ("fec.c -- what it does") is not part of the license
    return norm("\n".join(l for l in lines if not re.match(r"^\w+\.c --", l)))


def hash_hash(text):
    return hashlib.sha256(re.sub(r"\s+", " ", text).encode()).hexdigest()[:10]


# --------------------------------------------------------------------------------------------------------------
# What is in the app bundle. How each was established is the evidence (otool -L / nm / pbxproj / Package.resolved).
# --------------------------------------------------------------------------------------------------------------
DEPENDENCIES = [
    dict(id="moonlight-common-c", name="moonlight-common-c", version="skyhua0224 fork, 9ec12c9", spdx="GPL-3.0-only",
         url="https://github.com/moonlight-stream/moonlight-common-c", kind="static library",
         text=lambda: ("canonical", "GPL-3.0-only", "GNU General Public License, version 3", read(os.path.join(COMMON, "LICENSE.txt"))),
         evidence="libmoonlight-common.a in the app target's Frameworks build phase; LiStartConnection defined in the binary"),
    dict(id="enet", name="ENet", version="1.3.x (cgutman fork, aca8784)", spdx="MIT",
         url="https://github.com/cgutman/enet", kind="static library (inside moonlight-common-c)",
         text=lambda: ("split", read(os.path.join(TP, "enet-LICENSE.txt")), {}),
         evidence="enet *.c are compiled sources of the moonlight-common target; enet_host_create defined in the binary"),
    dict(id="reedsolomon", name="Reed-Solomon FEC (rs.c)", version="in moonlight-common-c", spdx="BSD-2-Clause",
         url="https://github.com/moonlight-stream/moonlight-common-c/tree/master/reedsolomon", kind="static library (inside moonlight-common-c)",
         text=lambda: ("split", c_comment_text(os.path.join(COMMON, "reedsolomon/rs.c")), dict(keep_paragraphs=2)),
         evidence="moonlight-common-c/reedsolomon/rs.c is a compiled source of the moonlight-common target; reed_solomon_new defined in the binary"),
    dict(id="ffmpeg", name="FFmpeg (libavcodec, libavformat, libavutil)", version="N-112686-g3f890fbfd9", spdx="LGPL-2.1-or-later",
         url="https://ffmpeg.org", kind="static library",
         copyright=["The FFmpeg developers"],
         note="Built with only the AV1 decoder and the FLV muxer enabled (libavutil 58.29.100).",
         text=lambda: ("canonical", "LGPL-2.1-or-later", "GNU Lesser General Public License, version 2.1", read(os.path.join(TP, "ffmpeg-COPYING.LGPLv2.1.txt"))),
         evidence="FFmpeg.xcframework (libffmpeg.a) in the Frameworks build phase; avutil_license() of that library answers 'LGPL version 2.1 or later'; av_* defined in the binary"),
    dict(id="opus", name="Opus", version="1.5.2", spdx="BSD-3-Clause",
         url="https://opus-codec.org", kind="static library",
         text=lambda: ("split", read(os.path.join(TP, "opus-COPYING.txt")), {}),
         evidence="Opus.xcframework (libopus.a) in the Frameworks build phase; opus_get_version_string() of that library answers 'libopus 1.5.2'; opus_decode_* defined in the binary"),
    dict(id="dav1d", name="dav1d", version="1.5.4", spdx="BSD-2-Clause",
         url="https://code.videolan.org/videolan/dav1d", kind="static library",
         text=lambda: ("split", read(os.path.join(TP, "dav1d-COPYING.txt")), {}),
         evidence="xcframeworks/dav1d/lib/libdav1d.a in OTHER_LDFLAGS of the app target (VERSION file: 1.5.4); dav1d_* defined in the binary"),
    dict(id="openssl", name="OpenSSL", version="3.6.1", spdx="Apache-2.0",
         url="https://www.openssl.org", kind="framework (OpenSSL.framework)",
         copyright=["The OpenSSL Project Authors"],
         text=lambda: ("canonical", "Apache-2.0", "Apache License, version 2.0", read(os.path.join(TP, "openssl-LICENSE.txt"))),
         evidence="Package.resolved pins OpenSSL-Package 3.6.1; OpenSSL.framework is in Contents/Frameworks and in otool -L; 31 EVP_* imports"),
    dict(id="sparkle", name="Sparkle", version="2.10.0", spdx="MIT",
         url="https://sparkle-project.org", kind="framework (Sparkle.framework)",
         text=lambda: ("whole", read(os.path.join(TP, "sparkle-LICENSE.txt"))),
         note="Sparkle's license file also covers the components bundled inside it (bsdiff, sais-lite, ed25519 and others).",
         evidence="Package.resolved pins Sparkle 2.10.0; Sparkle.framework is in Contents/Frameworks and in otool -L; SPUUpdater is imported"),
    dict(id="autoeq", name="AutoEq headphone corrections", version="7ae0f56d (2025-07-20)", spdx="MIT",
         url="https://github.com/jaakkopasanen/AutoEq", kind="data",
         text=lambda: ("split", autoeq_text(), {}),
         evidence="HeadphoneCorrections.tsv is in Contents/Resources; its header holds the AutoEq license"),
]


def autoeq_text():
    lines = read(os.path.join(ROOT, "Limelight/macOS/Supporting Files/HeadphoneCorrections.tsv")).split("\n")
    out = []
    started = False
    for l in lines:
        if l.startswith("# MIT License"):
            started = True
            continue
        if started:
            if not l.startswith("#"):
                break
            out.append(re.sub(r"^# ?", "", l))
    return norm("\n".join(out))


def build():
    licenses = {}
    deps = []
    shared_bodies = {}   # hash -> key
    for d in DEPENDENCIES:
        entry = {k: d[k] for k in ("id", "name", "version", "spdx", "url", "kind", "evidence")}
        copyright_lines = list(d.get("copyright", []))
        spec = d["text"]()
        key = None
        if spec[0] == "canonical":
            _, key, title, text = spec
            licenses.setdefault(key, {"name": title, "text": norm(text)})
        elif spec[0] == "shared":
            key = spec[1]
        elif spec[0] == "whole":
            key = "%s-license" % d["id"]
            licenses[key] = {"name": "%s license" % d["name"], "text": norm(spec[1])}
        elif spec[0] == "none":
            key = "%s-note" % d["id"]
            licenses[key] = {"name": "No license text", "text": spec[1]}
        else:  # split
            _, text, opts = spec
            lines, body = split_copyright(text, **opts)
            copyright_lines = lines + copyright_lines
            h = hash_hash(body)
            if h not in shared_bodies:
                shared_bodies[h] = "%s:%s" % (d["spdx"], h)
                licenses[shared_bodies[h]] = {"name": {"MIT": "MIT License", "BSD-2-Clause": "BSD 2-Clause License",
                                                       "BSD-3-Clause": "BSD 3-Clause License"}.get(d["spdx"], d["spdx"]),
                                              "text": body}
            key = shared_bodies[h]
        entry["license"] = key
        entry["copyright"] = copyright_lines
        if "note" in d:
            entry["note"] = d["note"]
        if "notice" in d:
            entry["notice"] = d["notice"]()
        deps.append(entry)
    deps.sort(key=lambda e: e["name"].lower())
    return {"schema": 1, "licenses": licenses, "dependencies": deps}


def main():
    data = build()
    text = json.dumps(data, ensure_ascii=False, indent=1, sort_keys=False) + "\n"
    if "--check" in sys.argv:
        current = read(OUT) if os.path.exists(OUT) else ""
        if current != text:
            print("%s is stale" % os.path.relpath(OUT, ROOT))
            sys.exit(1)
        print("%s is up to date (%d dependencies, %d license texts)" % (os.path.relpath(OUT, ROOT), len(data["dependencies"]), len(data["licenses"])))
        return
    with open(OUT, "w", encoding="utf-8") as f:
        f.write(text)
    print("wrote %s (%d dependencies, %d license texts)" % (os.path.relpath(OUT, ROOT), len(data["dependencies"]), len(data["licenses"])))


if __name__ == "__main__":
    main()
