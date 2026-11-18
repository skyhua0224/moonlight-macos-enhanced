# Where the third-party license texts were read from

`scripts/generate_third_party_licenses.py` builds `Limelight/macOS/Supporting Files/ThirdPartyLicenses.json` from these
files and from the license files that already sit in the source tree. Nothing is typed from memory.

| File here | Read from | Pinned to |
| --- | --- | --- |
| `dav1d-COPYING.txt` | `xcframeworks/dav1d/COPYING` (the tree linked into the app) | dav1d 1.5.4 (`xcframeworks/dav1d/VERSION`) |
| `enet-LICENSE.txt` | `moonlight-common-c/enet/LICENSE` (submodule) | enet aca87840 |
| `sparkle-LICENSE.txt` | `SourcePackages/artifacts/sparkle/Sparkle/LICENSE` | Sparkle 2.10.0 (`Package.resolved`) |
| `ffmpeg-COPYING.LGPLv2.1.txt` | https://raw.githubusercontent.com/FFmpeg/FFmpeg/3f890fbfd9/COPYING.LGPLv2.1 | FFmpeg N-112686-g3f890fbfd9 (the `libffmpeg.a` in `xcframeworks/FFmpeg.xcframework`; its `avutil_license()` answers "LGPL version 2.1 or later") |
| `opus-COPYING.txt` | https://raw.githubusercontent.com/xiph/opus/v1.5.2/COPYING | Opus 1.5.2 (`opus_get_version_string()` of the linked `libopus.a`) |
| `openssl-LICENSE.txt` | https://raw.githubusercontent.com/openssl/openssl/openssl-3.5.9/LICENSE.txt | OpenSSL 3.5.9 (`xcframeworks/openssl/VERSION`, built by `scripts/build_openssl.sh`); the text is identical to the 3.6.1 one |

Read from the tree directly, not copied here: moonlight-common-c `LICENSE.txt` (GPL-3.0), the `reedsolomon/rs.c` header
(BSD 2-Clause) and the AutoEq license at the top of `HeadphoneCorrections.tsv`.

Not listed, and why:
- AlkaidLab's own cores (ds5-core, usbip-core) are our code, not third-party code. The libraries they replaced
  (usbipdcpp, libusb, asio, spdlog) are no longer built, linked or shipped.
- SDL2: embedded but never called, so no longer linked or embedded.
- MASPreferences and the Functional helpers: removed; nothing used them.
- nanors (a submodule of moonlight-common-c that is not compiled) and the Roboto font (removed from the repository).
