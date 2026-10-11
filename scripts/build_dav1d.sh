#!/bin/bash
# Builds dav1d, the AV1 decoder used where the Mac has no AV1 hardware decoder, as a
# universal static library for macOS.
#
#   scripts/build_dav1d.sh            -> xcframeworks/dav1d/{lib/libdav1d.a,include,COPYING,VERSION}
#
# Needs meson, ninja and nasm (brew install meson ninja nasm). Does nothing when the
# version below is already built.
set -euo pipefail

VERSION=1.5.4
SHA256=686616b7c69eb88d44459391ab25cac13b6647a3b288835c5784e71c1514a5c5
MIN_MACOS=12.0

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT="$ROOT/xcframeworks/dav1d"

if [ -f "$OUT/VERSION" ] && [ "$(cat "$OUT/VERSION")" = "$VERSION" ] && [ -f "$OUT/lib/libdav1d.a" ]; then
  echo "dav1d $VERSION is already built"
  exit 0
fi

for tool in meson ninja nasm; do
  command -v "$tool" >/dev/null || { echo "missing $tool (brew install meson ninja nasm)"; exit 1; }
done

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

curl -fsSL "https://downloads.videolan.org/pub/videolan/dav1d/$VERSION/dav1d-$VERSION.tar.xz" -o dav1d.tar.xz
echo "$SHA256  dav1d.tar.xz" | shasum -a 256 -c -
tar -xf dav1d.tar.xz
SRC="$WORK/dav1d-$VERSION"

for arch in arm64 x86_64; do
  cat > "$WORK/$arch.ini" <<INI
[binaries]
c = ['clang', '-arch', '$arch']
ar = 'ar'
strip = 'strip'

[built-in options]
c_args = ['-mmacosx-version-min=$MIN_MACOS']
c_link_args = ['-mmacosx-version-min=$MIN_MACOS']

[host_machine]
system = 'darwin'
cpu_family = '$( [ "$arch" = arm64 ] && echo aarch64 || echo x86_64 )'
cpu = '$arch'
endian = 'little'
INI
  meson setup "$WORK/build-$arch" "$SRC" --cross-file "$WORK/$arch.ini" \
    --buildtype=release --default-library=static \
    -Denable_tools=false -Denable_tests=false -Denable_examples=false -Denable_docs=false \
    -Dbitdepths=8,16 >/dev/null
  ninja -C "$WORK/build-$arch" >/dev/null
done

rm -rf "$OUT"
mkdir -p "$OUT/lib" "$OUT/include/dav1d"
lipo -create "$WORK/build-arm64/src/libdav1d.a" "$WORK/build-x86_64/src/libdav1d.a" -output "$OUT/lib/libdav1d.a"
cp "$SRC"/include/dav1d/*.h "$OUT/include/dav1d/"
cp "$SRC/COPYING" "$OUT/COPYING"
echo "$VERSION" > "$OUT/VERSION"
echo "dav1d $VERSION -> $OUT/lib/libdav1d.a ($(lipo -archs "$OUT/lib/libdav1d.a"))"
