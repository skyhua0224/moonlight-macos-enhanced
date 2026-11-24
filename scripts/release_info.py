#!/usr/bin/env python3
"""Version and tag of a test build, computed from the committer time of the tagged commit.

usage:
  release_info.py [--date ISO8601] [--output FILE]   print release_version and release_tag (default: HEAD's committer date)
  release_info.py --check-tag TAG                    exit 0 only when TAG is exactly the tag HEAD would get

Same rule as Foundation Sunshine (scripts/ci/release-info.py there): the committer time, converted to UTC,
    version = f"{year}.{int(month)}{day}.{int(hour + minute + second)}"     month unpadded, day/hour/minute/second padded text
    tag     = "v" + version                                                  e.g. v2026.1124.103317
The tag is never typed by hand: CI and the person publishing both take it from this script.
"""

import argparse
import datetime
import re
import subprocess
import sys

# A timestamp tag: four-digit year, month (unpadded) + day, then the clock number.
TIMESTAMP_TAG = re.compile(r"^v[0-9]{4}\.[0-9]{3,4}\.[0-9]{1,6}$")


def compute(iso: str):
    stamp = datetime.datetime.fromisoformat(iso.replace("Z", "+00:00")).astimezone(datetime.timezone.utc)
    version = f"{stamp.year}.{stamp.month}{stamp.day:02d}.{int(f'{stamp.hour:02d}{stamp.minute:02d}{stamp.second:02d}')}"
    return version, f"v{version}"


def is_timestamp_tag(tag: str) -> bool:
    return TIMESTAMP_TAG.match(tag) is not None


def head_committer_date() -> str:
    return subprocess.run(["git", "log", "-1", "--format=%cI"], capture_output=True, text=True, check=True).stdout.strip()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--date")
    parser.add_argument("--output")
    parser.add_argument("--check-tag")
    args = parser.parse_args()
    version, tag = compute(args.date or head_committer_date())

    if args.check_tag is not None:
        if not is_timestamp_tag(args.check_tag):
            print(f"{args.check_tag} is not a timestamp tag", file=sys.stderr)
            return 1
        if args.check_tag != tag:
            print(f"{args.check_tag} does not match the tagged commit's time; expected {tag}", file=sys.stderr)
            return 1
        return 0

    lines = [f"release_version={version}", f"release_tag={tag}"]
    print("\n".join(lines))
    if args.output:
        with open(args.output, "a", encoding="utf-8") as handle:
            handle.write("\n".join(lines) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
