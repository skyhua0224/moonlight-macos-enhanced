#!/usr/bin/env python3
"""Sign nested macOS code from the inside out using the system codesign tool."""
from __future__ import annotations

import argparse
import plistlib
import subprocess
from pathlib import Path

MACHO_MAGICS = {b'\xfe\xed\xfa\xce', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf',
                b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca',
                b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'}


def sign(path: Path, identity: str, entitlements: Path | None = None) -> None:
    command = ['codesign', '--force', '--sign', identity]
    if entitlements is not None:
        command += ['--entitlements', str(entitlements)]
    elif subprocess.run(['codesign', '--display', str(path)],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
        command += ['--preserve-metadata=entitlements']
    subprocess.run([*command, str(path)], check=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('app', type=Path)
    parser.add_argument('--identity', default='-')
    parser.add_argument('--entitlements', type=Path, required=True)
    parser.add_argument('--extension-entitlements', type=Path, required=True)
    args = parser.parse_args()
    app = args.app.resolve()
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if app.suffix != '.app' or info.get('CFBundleIdentifier') != 'std.skyhua.MoonlightMacEnhanced':
        raise SystemExit('Expected the enhanced application bundle.')
    main_binary = (app / 'Contents/MacOS' / info['CFBundleExecutable']).resolve()
    binaries: list[Path] = []
    bundles: list[Path] = []
    for path in app.rglob('*'):
        if path.is_symlink():
            continue
        if path.is_dir() and path.suffix in {'.app', '.xpc', '.appex', '.framework'}:
            bundles.append(path)
        elif path.is_file() and path.resolve() != main_binary:
            with path.open('rb') as stream:
                if stream.read(4) in MACHO_MAGICS:
                    binaries.append(path)
    for path in sorted(binaries, key=lambda p: len(p.parts), reverse=True):
        sign(path, args.identity)
    for path in sorted(bundles, key=lambda p: len(p.parts), reverse=True):
        entitlements = args.extension_entitlements if path.name == 'RemoteFileProvider.appex' else None
        sign(path, args.identity, entitlements)
    sign(app, args.identity, args.entitlements)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    print('Verified signed application:', app)


if __name__ == '__main__':
    main()
