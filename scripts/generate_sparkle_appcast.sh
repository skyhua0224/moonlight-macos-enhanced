#!/bin/sh
set -eu

: "${SPARKLE_GENERATE_APPCAST:?Set SPARKLE_GENERATE_APPCAST to Sparkle's generate_appcast}"
: "${SPARKLE_ARCHIVES_DIR:?Set SPARKLE_ARCHIVES_DIR to the universal DMG directory}"
: "${SPARKLE_OUTPUT_DIR:?Set SPARKLE_OUTPUT_DIR to the appcast output directory}"
: "${SPARKLE_DOWNLOAD_PREFIX:?Set SPARKLE_DOWNLOAD_PREFIX to the GitHub release asset URL prefix}"

case "$SPARKLE_DOWNLOAD_PREFIX" in
  https://github.com/skyhua0224/moonlight-macos-enhanced/releases/download/v*) ;;
  *) printf '%s\n' 'The update archive must use this product’s GitHub release URL.' >&2; exit 1 ;;
esac

mkdir -p "$SPARKLE_OUTPUT_DIR"
set -- --download-url-prefix "$SPARKLE_DOWNLOAD_PREFIX" \
  -o "$SPARKLE_OUTPUT_DIR/appcast.xml" --maximum-deltas 0 --embed-release-notes

case "${SPARKLE_CHANNEL:-stable}" in
  stable) ;;
  beta) set -- "$@" --channel beta ;;
  *) printf '%s\n' 'SPARKLE_CHANNEL must be stable or beta.' >&2; exit 1 ;;
esac

if [ -n "${SPARKLE_PRIVATE_KEY_SECRET:-}" ]; then
  printf '%s' "$SPARKLE_PRIVATE_KEY_SECRET" | \
    "$SPARKLE_GENERATE_APPCAST" "$@" --ed-key-file - "$SPARKLE_ARCHIVES_DIR"
else
  "$SPARKLE_GENERATE_APPCAST" "$@" "$SPARKLE_ARCHIVES_DIR"
fi

test -s "$SPARKLE_OUTPUT_DIR/appcast.xml"
printf 'Wrote %s\n' "$SPARKLE_OUTPUT_DIR/appcast.xml"
