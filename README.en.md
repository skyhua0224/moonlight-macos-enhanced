# Moonlight macOS Enhanced

<div align="center">

[![Build](https://github.com/skyhua0224/moonlight-macos-enhanced/actions/workflows/build.yml/badge.svg)](https://github.com/skyhua0224/moonlight-macos-enhanced/actions/workflows/build.yml) [![Release](https://img.shields.io/github/v/release/skyhua0224/moonlight-macos-enhanced?include_prereleases)](https://github.com/skyhua0224/moonlight-macos-enhanced/releases) [![Downloads](https://img.shields.io/github/downloads/skyhua0224/moonlight-macos-enhanced/total)](https://github.com/skyhua0224/moonlight-macos-enhanced/releases) [![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-Native-orange.svg)]() [![License](https://img.shields.io/badge/license-GPLv3-blue.svg)](LICENSE.txt)

**Native Moonlight macOS / Moonlight for macOS Client**

`Moonlight macOS Enhanced` is a native Moonlight for macOS client for Sunshine and Foundation Sunshine, built with AppKit/SwiftUI and optimized for both Apple Silicon and Intel Macs.

This repository is the main GitHub home for releases, source code, installation guidance, and release notes.

[简体中文](README.md) | English

</div>

---

## ✨ Features

### 🍎 Native macOS Experience
- **Apple Silicon Optimized** - Native support for Apple Silicon chips
- **Native UI** - Built with AppKit/SwiftUI, not a Qt port
- **Dark Mode** - Full system dark mode support
- **Localization** - English and Simplified Chinese

#### 🎮 Streaming Performance
- **Custom Resolution & FPS** - Configurable resolution and frame rate
- **HEVC/H.264** - Hardware accelerated video decoding
- **HDR** - High Dynamic Range support
- **YUV 4:4:4** - Enhanced color sampling (requires Foundation Sunshine)
- **V-Sync** - Vertical synchronization support
- **Surround Sound** - 5.1/7.1 audio support

#### 🚀 Enhanced Features (What's New)
| Feature | Description |
|---------|-------------|
| 🎤 **Microphone Passthrough** | Stream your mic to the host (requires Foundation Sunshine) |
| 📊 **Performance Overlay** | Real-time stats: latency, FPS, bitrate (⌃⌥S to toggle) |
| 🖥️ **Multi-Host Streaming** | Connect to multiple hosts simultaneously |
| 🎨 **MetalFX Upscaling** | Apple's AI-powered image enhancement |
| 🌐 **Custom Ports/IPv6/Domain** | Flexible connection options |
| 🔧 **Connection Manager** | Manage multiple connection methods per host |
| 🎮 **Gamepad Mouse Mode** | Use controller as mouse |
| ⚡ **Auto Bitrate** | Adaptive bitrate based on network |
| 🖼️ **Display Modes** | Fullscreen / Borderless / Windowed |
| 🔄 **Smart Reconnection** | Auto reconnect with timeout handling |

### 🖥️ Host Compatibility

| Host Software | Compatibility | Notes |
|---------------|---------------|-------|
| [Foundation Sunshine](https://github.com/qiin2333/foundation-sunshine) | ⭐ Recommended | Full feature support (Mic, YUV444, etc.) |
| [Sunshine (LizardByte)](https://github.com/LizardByte/Sunshine) | ✅ Supported | Some advanced features unavailable |
| GeForce Experience | ⚠️ Basic | Deprecated, no microphone support |

> 💡 **Microphone, YUV 4:4:4** and other advanced features require [Foundation Sunshine](https://github.com/qiin2333/foundation-sunshine)

### 📸 Screenshots

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

### ⌨️ Keyboard Shortcuts

These Moonlight-specific stream shortcuts can now be adjusted in `Settings → Input → Keyboard`.

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

> 💡 This table lists Moonlight-specific stream shortcuts only. Standard macOS shortcuts like `⌘W` and `⌃⌘F` are not shown here and still follow the current stream-window behavior.

### 🛠️ Installation

#### Download Release
Download the latest `.dmg` from [Releases](https://github.com/skyhua0224/moonlight-macos-enhanced/releases).

> ⚠️ **This app is currently not notarized by Apple.**
> If macOS says `Moonlight.app` is damaged or blocks the app from opening, that is usually Gatekeeper stopping a non-notarized build — **it does not necessarily mean the download is actually corrupted**.
>
> On first launch, try these in order:
> 1. Right-click the app and choose `Open`
> 2. Go to **System Settings → Privacy & Security** and click `Open Anyway`
> 3. If it is still blocked, run this in Terminal:
>    `xattr -dr com.apple.quarantine /Applications/Moonlight.app`
>
> Not sure how to open Terminal?
> - Press `⌘ Space`, type `Terminal`, then press `Enter`

#### Build from Source
```bash
git clone --recursive https://github.com/skyhua0224/moonlight-macos-enhanced.git
cd moonlight-macos-enhanced

# Download XCFrameworks (FFmpeg, Opus, SDL2)
curl -L -o xcframeworks.zip "https://github.com/coofdy/moonlight-mobile-deps/releases/download/latest/moonlight-apple-xcframeworks.zip"
unzip -o xcframeworks.zip -d xcframeworks/

# Open Moonlight.xcodeproj in Xcode and build
```

### 📅 Update Policy

This is a personal project maintained in my spare time:
- 🐛 Critical bugs and crashes are prioritized
- 💡 New features added when time permits or when good suggestions come in
- 📥 Issues and PRs are welcome, but response time may vary

> I use this app daily myself, so I'm motivated to keep it working well!

### 🐛 Issue Guidelines

When reporting bugs, please include:
- macOS version (e.g., macOS 14.2)
- Chip type (Intel / M1 / M2 / M3 / M4)
- Host software and version (Sunshine / Foundation Sunshine / GFE)
- Steps to reproduce
- Relevant logs or screenshots

### 🤝 Contributing

PRs are welcome! Please:
- Follow existing code style
- Test your changes
- Provide clear descriptions

---

## 📬 Contact

- 📧 Email: [dev@sky-hua.xyz](mailto:dev@sky-hua.xyz)
- 💬 Telegram: [@skyhua](https://t.me/skyhua)
- 🐧 QQ: 2110591491
- 🔗 GitHub Issues: [Submit Issue](https://github.com/skyhua0224/moonlight-macos-enhanced/issues)

> 💡 Prefer GitHub Issues for bug reports and feature requests

---

## 🙏 Acknowledgements

For a full layered acknowledgement list covering upstream code lineage, feature references, and ecosystem projects, see [ACKNOWLEDGEMENTS.md](ACKNOWLEDGEMENTS.md).

- Direct code foundations: `moonlight-macos`, `moonlight-ios`, `moonlight-common-c`
- Feature and behavior references: `moonlight-qt`, `qiin2333/moonlight-qt`
- Host ecosystem references: `Sunshine`, `foundation-sunshine`
- Third-party dependencies: `SDL2`, `OpenSSL`, `MASPreferences`

---

## 📄 License

This project is licensed under the [GPLv3 License](LICENSE.txt).
