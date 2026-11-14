#!/bin/sh
# Builds the licenses window into a small harness and renders it (light and dark, English and Chinese) to PNGs.
# usage: run.sh <out-dir>   (macOS with Xcode; no screen-recording permission needed)
set -e
dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$dir/../.." && pwd)
out=${1:?usage: run.sh <out-dir>}
mkdir -p "$out"
# a bundle, so LanguageManager finds the app's own en/zh-Hans strings
app="$out/LicensesShoot.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/en.lproj" "$app/Contents/Resources/zh-Hans.lproj"
cp "$root/Limelight/macOS/en.lproj/Localizable.strings" "$app/Contents/Resources/en.lproj/"
cp "$root/Limelight/macOS/zh-Hans.lproj/Localizable.strings" "$app/Contents/Resources/zh-Hans.lproj/"
printf '<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>shoot</string><key>CFBundleIdentifier</key><string>test.licensesshoot</string><key>CFBundleName</key><string>LicensesShoot</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>' > "$app/Contents/Info.plist"
swiftc -O -o "$app/Contents/MacOS/shoot" "$dir/main.swift" \
  "$root/Limelight/macOS/ViewControllers/ThirdPartyLicensesWindow.swift" "$root/Limelight/macOS/Helpers/LanguageManager.swift"
shoot="$app/Contents/MacOS/shoot"
json="$root/Limelight/macOS/Supporting Files/ThirdPartyLicenses.json"
for look in light dark; do
  "$shoot" "$json" "$out/licenses-$look-zh.png" $look zh ""
  "$shoot" "$json" "$out/licenses-$look-en.png" $look en ffmpeg
done
"$shoot" "$json" "$out/licenses-light-zh-search.png" light zh "" "bsd"
