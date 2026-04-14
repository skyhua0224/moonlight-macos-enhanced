# Moonlight macOS Enhanced

<div align="center">

[![Build](https://github.com/skyhua0224/moonlight-macos-enhanced/actions/workflows/build.yml/badge.svg)](https://github.com/skyhua0224/moonlight-macos-enhanced/actions/workflows/build.yml) [![Release](https://img.shields.io/github/v/release/skyhua0224/moonlight-macos-enhanced?include_prereleases)](https://github.com/skyhua0224/moonlight-macos-enhanced/releases) [![Downloads](https://img.shields.io/github/downloads/skyhua0224/moonlight-macos-enhanced/total)](https://github.com/skyhua0224/moonlight-macos-enhanced/releases) [![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-Native-orange.svg)]() [![License](https://img.shields.io/badge/license-GPLv3-blue.svg)](LICENSE.txt)

**Native Moonlight macOS / Moonlight for macOS Client**

`Moonlight macOS Enhanced` is a native macOS streaming client for Sunshine, Foundation Sunshine, and compatible GameStream hosts. It is built with AppKit / SwiftUI and continuously tuned for both Apple Silicon and Intel Macs.

[简体中文](README.md) | English

</div>

---

## ✨ Core Capabilities

- **Native macOS client** — AppKit / SwiftUI interface, Apple Silicon and Intel support, dark mode, and bilingual UI
- **Full streaming feature set** — custom resolution and FPS, HEVC / H.264 hardware decoding, HDR, YUV 4:4:4, MetalFX, and auto bitrate
- **Input and control upgrades** — Free Mouse / Locked Mouse, Automatic driver routing, configurable stream shortcuts, and controller enhancements
- **Audio and media improvements** — lower-latency local playback, multi-channel receive and playback, audio enhancement mode, and improved microphone path
- **Connectivity and stability** — per-host connection methods, custom ports / IPv6 / domains, performance overlay, diagnostics, and AWDL stability helpers

## 🖥️ Host Compatibility

| Host Software | Compatibility | Notes |
|---------------|---------------|-------|
| [Foundation Sunshine](https://github.com/qiin2333/foundation-sunshine) | ⭐ Recommended | Best support for microphone, YUV 4:4:4, and multi-channel audio features |
| [Sunshine (LizardByte)](https://github.com/LizardByte/Sunshine) | ✅ Supported | Most features work; some advanced paths are limited |
| GeForce Experience | ⚠️ Basic | Deprecated and missing newer features such as microphone uplink |

> 💡 Microphone, YUV 4:4:4, and some enhanced input or audio behaviors work best with [Foundation Sunshine](https://github.com/qiin2333/foundation-sunshine).

## 📦 Downloads

- Get the latest build from [Releases](https://github.com/skyhua0224/moonlight-macos-enhanced/releases)
- Each release provides `universal`, `arm64`, and `x86_64` packages
- If you are not sure which one to choose, start with `universal`

## 📸 Screenshots

| Host List | App List |
|:---------:|:--------:|
| <img src="readme-assets/images/host-list.png" width="400" alt="Host list"> | <img src="readme-assets/images/app-list.png" width="400" alt="App list"> |

| Performance Overlay | Connection Manager |
|:-------------------:|:------------------:|
| <img src="readme-assets/images/performance-overlay.png" width="400" alt="Performance overlay"> | <img src="readme-assets/images/connection-manager.png" width="400" alt="Connection manager"> |

| Streaming Overlay | Connection Error |
|:-----------------:|:----------------:|
| <img src="readme-assets/images/streaming-overlay.png" width="400" alt="Streaming overlay"> | <img src="readme-assets/images/connection-error.png" width="400" alt="Connection error"> |

| Video Settings | Streaming Settings |
|:--------------:|:------------------:|
| <img src="readme-assets/images/settings-video.png" width="400" alt="Video settings"> | <img src="readme-assets/images/settings-streaming.png" width="400" alt="Streaming settings"> |

## 🔊 Audio and Video

### Video
- Custom resolution, FPS, remote resolution, and remote FPS
- HEVC / H.264 hardware decoding
- HDR, YUV 4:4:4, MetalFX upscaling, and auto bitrate tuning
- Fullscreen, borderless, and windowed display modes

### Audio
- The default mode uses a newer low-latency local playback path with less extra buffering and copying
- Supports `2ch / 5.1 / 7.1 / 7.1.4` receive and playback with better preservation of channel semantics
- Includes an `Audio Enhancement` mode for headphones and `2.0 / 2.1` speakers with spatial feel, soundstage, reverb, and EQ controls
- When paired with a compatible [Foundation Sunshine](https://github.com/qiin2333/foundation-sunshine), Moonlight can use the enhanced microphone path

## 🖱️ Input and Control

### Defaults
- **Default mouse mode: Free Mouse**
- **Default mouse driver: Automatic**
- **Automatic order: CoreHID → HID → MFI**

### Mouse Modes
- **Locked Mouse**: better for games and sustained relative motion
- **Free Mouse**: better for remote control, multi-display use, and desktop apps

### Input Enhancements
- Reworked Mouse, Keyboard, and Controller settings layout
- Controls for local cursor, pointer speed, wheel speed, swapped buttons, reverse scroll, and CoreHID report-rate cap
- Separate strategies for physical wheel, rewritten / smoothed wheel, and trackpad input
- Multi-controller support, rumble, Guide emulation, and controller mouse mode

### Stream Shortcuts
These Moonlight-specific stream shortcuts can be adjusted in `Settings → Input → Keyboard`:

| Shortcut | Action | Notes |
|----------|--------|-------|
| `Ctrl` + `Option` | Release mouse capture | While streaming |
| `Ctrl` + `Option` + `S` | Toggle performance overlay | While streaming |
| `Ctrl` + `Option` + `M` | Toggle mouse mode | While streaming |
| `Ctrl` + `Option` + `G` | Toggle fullscreen control ball | Fullscreen only |
| `Ctrl` + `Option` + `W` | Disconnect stream | While streaming |
| `Ctrl` + `Shift` + `W` | Disconnect and quit app | While streaming |
| `Ctrl` + `Option` + `C` | Open control center | Fullscreen / borderless only |
| `Ctrl` + `Option` + `Command` + `B` | Toggle borderless / windowed | Advanced fallback shortcut |

> 💡 This list covers Moonlight-specific shortcuts only. Standard macOS shortcuts such as `⌘W` and `⌃⌘F` are not listed here.

## 🔧 Connectivity, Diagnostics, and Stability

- Per-host connection method management
- Custom ports, IPv6, and domain-based connections
- Performance overlay, connection warnings, and input diagnostics
- Both raw logs and curated logs for troubleshooting
- AWDL stability helper, reconnect behavior, and timeout recovery

## 🛠️ Installation

### Download Release
Download the latest `.dmg` from [Releases](https://github.com/skyhua0224/moonlight-macos-enhanced/releases).

> ⚠️ This app is currently not notarized by Apple. If macOS says `Moonlight.app` is damaged or blocks it from launching, that is usually Gatekeeper stopping a non-notarized app, not proof that the file is actually broken.
>
> Recommended first-launch steps:
> 1. Right-click the app and choose `Open`
> 2. Go to **System Settings → Privacy & Security** and click `Open Anyway`
> 3. If needed, run:
>    `xattr -dr com.apple.quarantine /Applications/Moonlight.app`

### Build from Source

```bash
git clone --recursive https://github.com/skyhua0224/moonlight-macos-enhanced.git
cd moonlight-macos-enhanced

curl -L -o xcframeworks.zip "https://github.com/coofdy/moonlight-mobile-deps/releases/download/latest/moonlight-apple-xcframeworks.zip"
unzip -o xcframeworks.zip -d xcframeworks/
```

Then:
1. Open `Moonlight.xcodeproj` in Xcode
2. Set your own Team in **Signing & Capabilities**
3. Adjust the Bundle Identifier if needed
4. Run the **Moonlight for macOS** scheme

## 🐛 Reporting Issues

Please include:
- macOS version
- Mac model / chip
- Host software and version
- Whether third-party mouse tools such as Mos, BetterMouse, or SteerMouse are active
- Reproduction steps
- Logs or screenshots

For input / wheel / mouse bugs, it is especially helpful to include:
- The log exported from `Settings → App → Debug Log`
- Whether you used **Free Mouse** or **Locked Mouse**
- Whether the active path was **Automatic / CoreHID / HID / MFI**

## 🤝 Contributing

PRs are welcome. Please try to:
- Keep Chinese and English user-facing copy in sync
- Test the core streaming and input paths before submitting
- Write PR descriptions in user-facing language instead of just pasting commit titles

## 📬 Contact

- 📧 Email: [dev@sky-hua.xyz](mailto:dev@sky-hua.xyz)
- 💬 Telegram: [@skyhua](https://t.me/skyhua)
- 🐧 QQ: 2110591491
- 🔗 GitHub Issues: [Submit Issue](https://github.com/skyhua0224/moonlight-macos-enhanced/issues)

## 🙏 Acknowledgements

For the full upstream, ecosystem, and reference list, see [ACKNOWLEDGEMENTS.md](ACKNOWLEDGEMENTS.md).

- Direct code foundations: `moonlight-macos`, `moonlight-ios`, `moonlight-common-c`
- Feature and behavior references: `moonlight-qt`, `qiin2333/moonlight-qt`
- Host ecosystem references: `Sunshine`, `foundation-sunshine`
- Input and wheel experience references: `Mos`, `Mouser`

## 📄 License

This project is licensed under the [GPLv3 License](LICENSE.txt).
