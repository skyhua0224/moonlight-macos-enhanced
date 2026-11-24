#!/bin/sh
# Version and tag of a timestamp test build (scripts/release_info.py).
set -e
dir=$(cd "$(dirname "$0")" && pwd)
python3 "$dir/test_release_info.py"
python3 "$dir/test_release_body.py"
