#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
build_dir=${REMOTE_USB_BUILD_DIR:-"$project_dir/RemoteUSB/build"}

set -- -S "$project_dir/RemoteUSB" -B "$build_dir" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=13.3
if [ -n "${ARCHS:-}" ]; then
    cmake_archs=$(printf '%s' "$ARCHS" | tr ' ' ';')
    set -- "$@" "-DCMAKE_OSX_ARCHITECTURES=$cmake_archs"
fi
cmake "$@"
cmake --build "$build_dir" --parallel

if [ -n "${TARGET_BUILD_DIR:-}" ] && [ -n "${CONTENTS_FOLDER_PATH:-}" ]; then
    install -d "$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/MacOS"
    install -m 755 "$build_dir/moonlight-usbd" \
        "$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/MacOS/moonlight-usbd"
fi
