#!/bin/bash
# Builds a trimmed static libcrypto (no libssl) from pinned OpenSSL source for macOS.
#
#   scripts/build_openssl.sh                 -> xcframeworks/openssl/{lib/libcrypto.a,include,LICENSE.txt,VERSION}
#   ARCHS="arm64" scripts/build_openssl.sh   -> one architecture only (CI builds the slice it needs)
#
# The app and moonlight-common-c link this archive directly; there is no OpenSSL.framework.
# Keep the algorithm list in sync with docs/openssl-static-libcrypto.md. Assembly
# (ARMv8 crypto extensions, AES-NI, PCLMULQDQ) stays on: never add no-asm.
# Needs perl and make (both ship with the Xcode command line tools). Does nothing when the
# version and option set below are already built.
set -euo pipefail

# OpenSSL 3.5 is the long term support line (supported until 2030-04-08). Raise VERSION and
# SHA256 together; the SHA256 is published next to the tarball in the GitHub release.
VERSION=3.5.9
SHA256=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
MIN_MACOS=12.0

# Features the app does not use, taken out of libcrypto. What stays: RSA key generation,
# PEM/X.509/PKCS#12 (3DES + SHA-1, the only PKCS#12 flavour every macOS release imports),
# SHA-1/SHA-2, HMAC, AES (ECB/CBC/GCM), DES-EDE3 and the OS-seeded DRBG.
OPTIONS=(
  no-shared no-legacy no-module no-tests no-apps no-docs
  no-ssl no-tls no-dtls no-quic no-comp no-srp no-psk no-sctp no-http no-sock
  no-engine no-dso no-ocsp no-cms no-ct no-ts no-cmp no-ui-console
  no-ec no-ecdsa no-ecdh no-dh no-dsa no-sm2 no-sm3 no-sm4 no-sm2-precomp
  no-bf no-cast no-rc2 no-rc4 no-rc5 no-idea no-seed no-camellia no-aria
  no-chacha no-poly1305 no-ocb no-siv no-scrypt no-argon2
  no-md2 no-md4 no-mdc2 no-rmd160 no-whirlpool no-blake2 no-siphash
  no-zlib no-zstd no-brotli
)

ARCHS=${ARCHS:-"arm64 x86_64"}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT="$ROOT/xcframeworks/openssl"
STAMP="$VERSION|$MIN_MACOS|$ARCHS|${OPTIONS[*]}"
STAMP_HASH=$(printf '%s' "$STAMP" | shasum -a 256 | cut -d' ' -f1)

if [ -f "$OUT/VERSION" ] && [ "$(cat "$OUT/STAMP" 2>/dev/null)" = "$STAMP_HASH" ] && [ -f "$OUT/lib/libcrypto.a" ]; then
  echo "OpenSSL $VERSION ($ARCHS) is already built"
  exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

# OPENSSL_TARBALL points at a pre-downloaded openssl-$VERSION.tar.gz (offline or slow-network
# builds); the SHA256 check below applies to it as well.
if [ -n "${OPENSSL_TARBALL:-}" ]; then
  cp "$OPENSSL_TARBALL" openssl.tar.gz
else
  curl -fsSL --retry 3 --connect-timeout 30 --max-time 600 \
    "https://github.com/openssl/openssl/releases/download/openssl-$VERSION/openssl-$VERSION.tar.gz" -o openssl.tar.gz
fi
echo "$SHA256  openssl.tar.gz" | shasum -a 256 -c -
tar -xzf openssl.tar.gz
SRC="$WORK/openssl-$VERSION"
JOBS=$(sysctl -n hw.ncpu)

libs=()
for arch in $ARCHS; do
  case "$arch" in
    arm64)  target=darwin64-arm64-cc ;;
    x86_64) target=darwin64-x86_64-cc ;;
    *) echo "unsupported arch $arch"; exit 1 ;;
  esac
  mkdir -p "$WORK/build-$arch"
  (
    cd "$WORK/build-$arch"
    "$SRC/Configure" "$target" "${OPTIONS[@]}" \
      "-mmacosx-version-min=$MIN_MACOS" -fvisibility=hidden \
      --prefix="$WORK/install-$arch" --openssldir=/nonexistent
    make -j"$JOBS" build_generated >/dev/null
    make -j"$JOBS" libcrypto.a >/dev/null
  )
  libs+=("$WORK/build-$arch/libcrypto.a")
done

rm -rf "$OUT"
mkdir -p "$OUT/lib" "$OUT/include/openssl"
if [ "${#libs[@]}" -eq 1 ]; then
  cp "${libs[0]}" "$OUT/lib/libcrypto.a"
else
  lipo -create "${libs[@]}" -output "$OUT/lib/libcrypto.a"
fi
# Public headers: the source tree has the static ones, the build tree has the generated
# ones (configuration.h and the *.h produced from *.h.in). Generated files win.
first_arch=${ARCHS%% *}
cp "$SRC"/include/openssl/*.h "$OUT/include/openssl/"
cp "$WORK/build-$first_arch"/include/openssl/*.h "$OUT/include/openssl/"
cp "$SRC/LICENSE.txt" "$OUT/LICENSE.txt"
echo "$VERSION" > "$OUT/VERSION"
echo "$STAMP_HASH" > "$OUT/STAMP"
echo "OpenSSL $VERSION -> $OUT/lib/libcrypto.a ($(lipo -archs "$OUT/lib/libcrypto.a"), $(stat -f %z "$OUT/lib/libcrypto.a") bytes)"
