#!/usr/bin/env python3
"""Symbolicate a Moonlight Enhanced crash report or call-stack log with a release dSYM.

Release builds ship without local symbols, so frames of the app itself arrive as
offsets into the main binary. The dSYM of the same build holds the names and the
source lines. This script matches the report to the dSYM by UUID and calls the
system atos to resolve every frame of the app image.

    scripts/symbolicate_crash.py REPORT.ips --dsym MoonlightEnhanced.app.dSYM
    scripts/symbolicate_crash.py app.log     --dsym MoonlightEnhanced.app.dSYM [--load-address 0x100000000]

REPORT is either a macOS crash report (.ips, JSON) or text that holds call-stack
lines such as those written by Thread.callStackSymbols:

    3   MoonlightEnhanced   0x0000000100a3c1f0 MoonlightEnhanced + 4571632

--dsym takes the .dSYM bundle of the release the report came from (the dSYM zip of
that release, unzipped) or a DWARF file inside it. A dSYM of another build is
refused: the UUIDs must match. Needs macOS (atos, dwarfdump). Python standard
library only.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

IMAGE_NAME = "MoonlightEnhanced"
LINE_RE = re.compile(r"(\d+)\s+(\S+)\s+(0x[0-9a-fA-F]+)\s+(\S+)\s\+\s(\d+)")


def dwarf_file(dsym: Path, image: str) -> Path:
    if dsym.is_file():
        return dsym
    candidate = dsym / "Contents" / "Resources" / "DWARF" / image
    if candidate.is_file():
        return candidate
    files = sorted((dsym / "Contents" / "Resources" / "DWARF").glob("*"))
    if len(files) == 1:
        return files[0]
    raise SystemExit(f"No DWARF file for {image} in {dsym}")


def dsym_uuids(dwarf: Path) -> dict[str, str]:
    """arch -> UUID (lowercase, with dashes) of every slice of the DWARF file."""
    out = subprocess.run(["dwarfdump", "--uuid", str(dwarf)], capture_output=True, text=True, check=True).stdout
    result = {}
    for line in out.splitlines():
        match = re.match(r"UUID: ([0-9A-Fa-f-]{36}) \((\w+)\)", line)
        if match:
            result[match.group(2)] = match.group(1).lower()
    return result


def atos(dwarf: Path, arch: str, load: int, addresses: list[int]) -> list[str]:
    command = ["atos", "-arch", arch, "-o", str(dwarf), "-l", hex(load), *[hex(a) for a in addresses]]
    out = subprocess.run(command, capture_output=True, text=True, check=True).stdout
    return out.splitlines()


def parse_ips(text: str):
    """The .ips format is a one-line JSON header followed by the JSON body."""
    head, _, body = text.partition("\n")
    try:
        header = json.loads(head)
        report = json.loads(body)
    except ValueError:
        report = json.loads(text)
        header = {}
    return header, report


def symbolicate_ips(report: dict, dwarf: Path, image: str) -> int:
    uuids = dsym_uuids(dwarf)
    images = report.get("usedImages", [])
    ours = [(i, entry) for i, entry in enumerate(images) if entry.get("name") == image]
    if not ours:
        raise SystemExit(f"The report has no image named {image}")
    index, entry = ours[0]
    arch = entry.get("arch", "arm64").replace("arm64e", "arm64")
    uuid = entry.get("uuid", "").lower()
    if uuids.get(arch) != uuid:
        raise SystemExit(
            f"The dSYM is not from this build: report UUID {uuid} ({arch}), dSYM UUIDs {uuids}")
    base = int(entry["base"])
    print(f"{image} {arch} UUID {uuid} base {hex(base)}: dSYM matches")
    resolved = 0
    for number, thread in enumerate(report.get("threads", [])):
        frames = thread.get("frames", [])
        wanted = [(k, f) for k, f in enumerate(frames) if f.get("imageIndex") == index]
        if not wanted:
            continue
        # Every frame but the first of the crashing thread holds a return address: the
        # call is the instruction before it, so that is the one to look up.
        crashed = number == report.get("faultingThread")
        addresses = [base + f["imageOffset"] - (0 if crashed and k == 0 else 1) for k, f in wanted]
        names = atos(dwarf, arch, base, addresses)
        lookup = {k: n for (k, _), n in zip(wanted, names)}
        tag = " (crashed)" if crashed else ""
        print(f"\nThread {number}{tag}  {thread.get('name') or thread.get('queue') or ''}".rstrip())
        for k, frame in enumerate(frames):
            where = lookup.get(k)
            if where is None:
                label = frame.get("symbol") or "?"
                print(f"  {k:>3}  {label}")
            else:
                resolved += 1
                print(f"  {k:>3}  {where}")
    return resolved


def symbolicate_text(text: str, dwarf: Path, image: str, load: int | None) -> int:
    uuids = dsym_uuids(dwarf)
    arch = "arm64" if "arm64" in uuids else next(iter(uuids))
    resolved = 0
    for raw in text.splitlines():
        matches = [m for m in LINE_RE.finditer(raw) if m.group(2) == image]
        if not matches:
            print(raw)
            continue
        print(raw)
        for match in matches:
            address = int(match.group(3), 16)
            symbol, offset = match.group(4), int(match.group(5))
            base = load
            if base is None and symbol == image:
                # dladdr found no symbol: it names the image, and address - offset is its load address.
                base = address - offset
            if base is None:
                print(f"      <- pass --load-address: the frame names a nearby exported symbol ({symbol}), not the image")
                continue
            # callStackSymbols frames are return addresses; look up the call, not the return.
            where = atos(dwarf, arch, base, [address - 1])[0]
            resolved += 1
            print(f"      -> {where}")
    return resolved


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("report", type=Path)
    parser.add_argument("--dsym", type=Path, required=True)
    parser.add_argument("--image", default=IMAGE_NAME, help="image name in the report (default %(default)s)")
    parser.add_argument("--load-address", type=lambda v: int(v, 0), help="load address of the image, for text logs")
    args = parser.parse_args()
    text = args.report.read_text(errors="replace")
    dwarf = dwarf_file(args.dsym, args.image)
    if text.lstrip().startswith("{"):
        _, report = parse_ips(text)
        resolved = symbolicate_ips(report, dwarf, args.image)
    else:
        resolved = symbolicate_text(text, dwarf, args.image, args.load_address)
    print(f"\n{resolved} frame(s) resolved", file=sys.stderr)
    if resolved == 0:
        sys.exit(1)


if __name__ == "__main__":
    main()
