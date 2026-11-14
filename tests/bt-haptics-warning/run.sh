#!/bin/sh
# Builds and runs the Full Bluetooth Haptics switch logic test (macOS: needs swiftc; the file under test is Foundation only).
set -e
dir=$(cd "$(dirname "$0")" && pwd)
root=$dir/../..
out=${TMPDIR:-/tmp}/bt-haptics-warning-test.$$
mkdir -p "$out"
swiftc -O -o "$out/test" "$root/Limelight/macOS/ViewControllers/BluetoothFullHapticsSwitch.swift" "$dir/main.swift"
"$out/test"
rm -rf "$out"
