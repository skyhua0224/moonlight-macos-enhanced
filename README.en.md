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
- **Full streaming feature set** — custom resolution and FPS, AV1 / HEVC / H.264 decode, HDR, YUV 4:4:4, MetalFX / VT enhancement, and auto bitrate
- **Multiple video renderers** — includes `Native Renderer`, `Metal Renderer`, and `Compatibility Renderer`; `Native Renderer` is the recommended default, while `Metal Renderer` provides deeper HDR and color controls
- **Input and control upgrades** — Free Mouse / Locked Mouse, Automatic driver routing, configurable stream shortcuts, and controller enhancements
- **Audio and media improvements** — lower-latency local playback, multi-channel receive and playback, audio enhancement mode, and improved microphone path
- **Connectivity and stability** — per-host connection methods, custom ports / IPv6 / domains, performance overlay, diagnostics, and AWDL stability helpers

<details>
<summary><strong>Video / HDR / renderer pipeline</strong></summary>

- Video negotiation covers `AV1 / HEVC / H.264`, HDR, YUV `4:4:4`, remote resolution / FPS overrides, and adaptive bitrate control
- Provides three video playback paths: `Native Renderer`, `Metal Renderer`, and `Compatibility Renderer`
- `Native Renderer` uses `VideoToolbox decode + native sample-buffer presentation` and is the recommended default for lower latency, higher default color accuracy, and stable HDR playback
- `Metal Renderer` uses a deeper `Metal / EDR` presentation path with `HLG / PQ`, HDR metadata source, client HDR profile, luminance parameters, optical output scale, HLG viewing environment, EDR strategy, and tone-mapping policy
- `Metal Renderer` also exposes presentation-timing controls such as display sync, frame queue target, responsiveness bias, and drawable-timeout behavior
- `Compatibility Renderer` keeps the legacy presentation path for older systems, compatibility issues, and recovery scenarios
- The enhancement stack can use `VT Low-Latency Super Resolution`, `VT Quality Super Resolution`, `MetalFX`, `Basic Scaling`, and `VT Low-Latency Frame Interpolation`, with automatic fallback when needed

</details>

<details>
<summary><strong>Audio / microphone pipeline</strong></summary>

- The default playback path has moved to a more direct `Core Audio`-oriented local renderer with lower extra buffering, while keeping compatibility fallback in place
- Supports host `Opus multistream` receive, local decode, negotiation, and playback for `2ch / 5.1 / 7.1 / 7.1.4`
- Real multi-channel devices keep their channel semantics whenever possible; headphones and `2.0 / 2.1` speakers can switch to `Audio Enhancement` for client-side spatial feel, soundstage, reverb, and EQ rerendering
- `Audio Enhancement` includes presets, manual EQ, spatial intensity, soundstage width, and reverb controls for stereo listening devices
- When paired with a compatible Foundation Sunshine host, Moonlight can use the fuller multi-channel negotiation path, microphone uplink, and related enhancement flows

</details>

<details>
<summary><strong>Host integration / input / diagnostics</strong></summary>

- Mouse input defaults to `Automatic` routing in the order `CoreHID → HID → MFI`; on supported macOS versions it will try the higher-polling `CoreHID` relative mouse path first and fall back automatically when permissions or runtime conditions do not allow it
- The input stack covers `Free Mouse / Locked Mouse`, keyboard shortcut translation, separate physical wheel / smoothed wheel / trackpad strategies, multi-controller support, rumble, Guide emulation, and controller mouse
- Can send Foundation Sunshine host-display extension parameters and let you choose the target display, streaming mode, `display_name`, `useVdd`, `customScreenMode`, and HDR display-profile overrides from host settings or when starting a stream
- Host and network integration also includes per-host connection methods, custom ports, IPv6, domains, `AWDL`, performance overlay, connection warnings, input diagnostics, and both raw and curated logs

</details>

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

### Video Pipeline
- Custom resolution, FPS, remote resolution, and remote FPS overrides
- Video negotiation for `AV1 / HEVC / H.264`, HDR, YUV `4:4:4`, and adaptive bitrate tuning
- `Native Renderer / Metal Renderer / Compatibility Renderer` presentation paths
- `Native Renderer` is aimed at the lowest latency and highest default color accuracy; `Metal Renderer` is aimed at deeper HDR and color control; `Compatibility Renderer` is kept for older systems and recovery cases

### HDR, Color, and Enhancement
- HDR transfer functions support `HLG / PQ / Auto`, with presentation tuned to the current display path
- `Metal Renderer` exposes HDR metadata source, client HDR profile, luminance parameters, optical output scale, HLG viewing environment, EDR strategy, and tone-mapping policy
- The enhancement stack supports `VT Low-Latency Super Resolution`, `VT Quality Super Resolution`, `MetalFX`, and `Basic Scaling`
- `VT Low-Latency Frame Interpolation` is also integrated into the Metal video path for cadence smoothing on high-refresh displays

### Audio Pipeline
- The default audio path uses a more direct `Core Audio`-oriented low-latency local renderer with compatibility fallback
- Local receive, decode, negotiation, and playback for `2ch / 5.1 / 7.1 / 7.1.4`
- When the output device supports real multi-channel playback, Moonlight keeps the multichannel layout whenever possible; stereo devices can switch to `Audio Enhancement`
- `Audio Enhancement` is designed for headphones and `2.0 / 2.1` speakers, with client-side spatial feel, soundstage, reverb, EQ presets, and manual controls
- When paired with a compatible [Foundation Sunshine](https://github.com/qiin2333/foundation-sunshine), Moonlight can use the enhanced microphone uplink and fuller multi-channel negotiation path

## 🖱️ Input and Control

### Defaults
- **Default mouse mode: Free Mouse**
- **Default mouse driver: Automatic**
- **Automatic order: CoreHID → HID → MFI**

### Mouse Modes
- **Locked Mouse**: better for games and sustained relative motion
- **Free Mouse**: better for remote control, multi-display use, and desktop apps

### Mouse and Wheel Pipeline
- On supported systems, `CoreHID` provides the higher-polling relative mouse path; if permissions or runtime conditions block it, Moonlight falls back automatically to `HID / MFI / AppKit` compatibility paths
- Controls for local cursor, pointer speed, swapped buttons, reverse scroll, and `CoreHID` report-rate cap
- Separate handling for `physical wheel`, `rewritten / smoothed wheel`, and `trackpad` input sources
- Physical wheel modes support automatic, high-precision, and notched behavior, with separate distance, speed, and tail-filter tuning

### Keyboard, Controllers, and Shortcuts
- Keyboard input supports common Windows shortcut translation, custom translation rules, and Moonlight-specific stream shortcuts
- Controller input supports multi-controller sessions, rumble, Guide emulation, and controller mouse mode
- Mouse, Keyboard, and Controller settings have been reorganized so the most-used input controls are easier to reach

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
