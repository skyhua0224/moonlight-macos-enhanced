#!/bin/sh
set -eu
dir=$(cd "$(dirname "$0")" && pwd)
source_dir="$dir/../../Limelight/macOS/ViewControllers"
out=$(mktemp -d "${TMPDIR:-/var/tmp}/disconnect-confirmation.XXXXXX")
trap 'if test -f "$out/test"; then unlink "$out/test"; fi; rmdir "$out"' EXIT
xcrun clang -fobjc-arc -framework AppKit -I "$source_dir" \
    "$source_dir/MLStreamDisconnectConfirmation.m" "$dir/main.m" -o "$out/test"
"$out/test" "$@"
