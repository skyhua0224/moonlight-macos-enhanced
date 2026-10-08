#!/bin/sh
set -eu

: "\${SPARKLE_GENERATE_APPCAST:?Set SPARKLE_GENERATE_APPCAST to Sparkle 2.10.0 generate_appcast}"
: "\${SPARKLE_ARCHIVES_DIR:?Set SPARKLE_ARCHIVES_DIR to the directory containing signed DMGs}"
: "\${SPARKLE_OUTPUT_DIR:?Set SPARKLE_OUTPUT_DIR to the appcast output directory}"
: "\${SPARKLE_DOWNLOAD_PREFIX:?Set SPARKLE_DOWNLOAD_PREFIX to the asset base URL}"

mkdir -p "$SPARKLE_OUTPUT_DIR"

if [ -n "${SPARKLE_PRIVATE_KEY_SECRET:-}" ]; then
  printf '%s' "$SPARKLE_PRIVATE_KEY_SECRET" | \
    "$SPARKLE_GENERATE_APPCAST" \
      --ed-key-file - \
      --download-url-prefix "$SPARKLE_DOWNLOAD_PREFIX" \
      --output "$SPARKLE_OUTPUT_DIR/appcast.xml" \
      "$SPARKLE_ARCHIVES_DIR"
else
  # Sparkle's generate_appcast reads the private EdDSA key from the local
  # Keychain by default. This keeps a free local/CNB release path without
  # copying the private key into GitHub or the repository.
  "$SPARKLE_GENERATE_APPCAST" \
    --download-url-prefix "$SPARKLE_DOWNLOAD_PREFIX" \
    --output "$SPARKLE_OUTPUT_DIR/appcast.xml" \
    "$SPARKLE_ARCHIVES_DIR"
fi

test -s "$SPARKLE_OUTPUT_DIR/appcast.xml"
printf 'Wrote %s\n' "$SPARKLE_OUTPUT_DIR/appcast.xml"
