# Moonlight macOS Enhanced

<div align="center">

[![Build](https://github.com/skyhua0224/moonlight-macos/actions/workflows/build.yml/badge.svg)](https://github.com/skyhua0224/moonlight-macos/actions/workflows/build.yml) [![Release](https://img.shields.io/github/v/release/skyhua0224/moonlight-macos?include_prereleases)](https://github.com/skyhua0224/moonlight-macos/releases) [![Downloads](https://img.shields.io/github/downloads/skyhua0224/moonlight-macos/total)](https://github.com/skyhua0224/moonlight-macos/releases) [![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-Native-orange.svg)]() [![License](https://img.shields.io/badge/license-GPLv3-blue.svg)](LICENSE.txt)

**Native macOS Game Streaming Client**

A native macOS client for game streaming, built with AppKit/SwiftUI. Combines the smooth experience of a native Mac app with powerful community-enhanced features.

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

| Shortcut | Action |
|----------|--------|
| `Ctrl` + `Option` | Release mouse cursor |
| `Ctrl` + `Option` + `S` | Toggle performance overlay |
| `Ctrl` + `Option` + `W` | Disconnect stream |
| `Ctrl` + `Shift` + `W` | Quit application |

### 🛠️ Installation

#### Download Release
Download the latest `.dmg` from [Releases](https://github.com/skyhua0224/moonlight-macos/releases).

> ⚠️ **This app is not notarized.** On first launch:
> - Right-click the app and select "Open", or
> - Go to System Settings → Privacy & Security → Open Anyway, or
> - Run in Terminal: `xattr -cr /Applications/Moonlight.app`

#### Build from Source
```bash
git clone --recursive https://github.com/skyhua0224/moonlight-macos.git
cd moonlight-macos

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
- 🔗 GitHub Issues: [Submit Issue](https://github.com/skyhua0224/moonlight-macos/issues)

> 💡 Prefer GitHub Issues for bug reports and feature requests

---

## 🙏 Acknowledgements

This project is built upon these excellent open-source projects:

### Core Projects
- **[moonlight-macos](https://github.com/MichaelMKenny/moonlight-macos)** by MichaelMKenny - Native macOS client foundation
- **[moonlight-common-c](https://github.com/moonlight-stream/moonlight-common-c)** by Moonlight Team - Core streaming protocol

### Feature References
- **[Foundation Sunshine](https://github.com/qiin2333/foundation-sunshine)** by qiin2333 - Enhanced host with microphone support
- **[moonlight-qt](https://github.com/moonlight-stream/moonlight-qt)** by Moonlight Team - Official cross-platform client

### Dependencies
- [SDL2](https://www.libsdl.org/) - Input handling
- [OpenSSL](https://www.openssl.org/) - Encryption
- [MASPreferences](https://github.com/shpakovski/MASPreferences) - Settings UI

---

## 📄 License

This project is licensed under the [GPLv3 License](LICENSE.txt).
