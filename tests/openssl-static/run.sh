#!/bin/sh
# Builds and runs the static libcrypto checks (certificate, PKCS#12, pairing signatures,
# AES-GCM/CBC/ECB, HMAC, SHA, RAND) for every architecture this Mac can execute, and then
# the AES-GCM per-packet benchmark when BENCH=1.
#
#   tests/openssl-static/run.sh                run the checks
#   BENCH=1 tests/openssl-static/run.sh        also run the benchmark
#   OPENSSL_DIR=<dir with lib/libcrypto.a and include/>   link another build (default: xcframeworks/openssl)
set -e
dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$dir/../.." && pwd)
common="$root/moonlight-common/moonlight-common-c/src"
ossl=${OPENSSL_DIR:-"$root/xcframeworks/openssl"}
[ -f "$ossl/lib/libcrypto.a" ] || bash "$root/scripts/build_openssl.sh"

# Every architecture the library carries that this Mac can execute (x86_64 runs under Rosetta).
archs=
for a in $(lipo -archs "$ossl/lib/libcrypto.a"); do
    if [ "$a" = "$(uname -m)" ] || { [ "$a" = x86_64 ] && arch -x86_64 /usr/bin/true 2>/dev/null; }; then
        archs="$archs $a"
    fi
done
[ -n "$archs" ] || { echo "no runnable architecture in $ossl/lib/libcrypto.a"; exit 1; }

work=${TMPDIR:-/tmp}/openssl-static-test.$$
mkdir -p "$work"
trap 'rm -rf "$work"' EXIT
status=0
for arch in $archs; do
    echo "== $arch"
    cc="clang -arch $arch -mmacosx-version-min=12.0 -O2 -g -Wall -Wextra -Wno-unused-parameter -Wno-deprecated-declarations"
    inc="-I$root/Limelight/Crypto -I$common -I$common/../enet/include -I$ossl/include"
    for m in "$dir/test_crypto.m" "$root/Limelight/Crypto/CryptoManager.m"; do
        $cc -fobjc-arc -include Foundation/Foundation.h -include "$root/Limelight/Utility/Logger.h" $inc \
            -c "$m" -o "$work/$(basename "$m" .m)-$arch.o"
    done
    for c in "$root/Limelight/Crypto/mkcert.c" "$common/PlatformCrypto.c"; do
        $cc $inc -c "$c" -o "$work/$(basename "$c" .c)-$arch.o"
    done
    $cc -o "$work/test-$arch" "$work"/*-"$arch".o "$ossl/lib/libcrypto.a" -framework Foundation -framework Security -Wl,-dead_strip
    if [ "$arch" = x86_64 ] && [ "$(uname -m)" = arm64 ]; then
        arch -x86_64 "$work/test-$arch" || status=1
    else
        "$work/test-$arch" || status=1
    fi
    if [ -n "$BENCH" ]; then
        $cc -I"$common" -I"$common/../enet/include" -I"$ossl/include" -o "$work/bench-$arch" "$dir/bench_gcm.c" "$common/PlatformCrypto.c" "$ossl/lib/libcrypto.a" -Wl,-dead_strip
        if [ "$arch" = x86_64 ] && [ "$(uname -m)" = arm64 ]; then
            arch -x86_64 "$work/bench-$arch" 1400 3 5
        else
            "$work/bench-$arch" 1400 3 5
        fi
    fi
done
exit $status
