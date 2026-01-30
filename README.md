# Moonlight macOS Enhanced

<div align="center">

[![Build](https://github.com/skyhua0224/moonlight-macos/actions/workflows/build.yml/badge.svg)](https://github.com/skyhua0224/moonlight-macos/actions/workflows/build.yml) [![Release](https://img.shields.io/github/v/release/skyhua0224/moonlight-macos?include_prereleases)](https://github.com/skyhua0224/moonlight-macos/releases) [![Downloads](https://img.shields.io/github/downloads/skyhua0224/moonlight-macos/total)](https://github.com/skyhua0224/moonlight-macos/releases) [![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-Native-orange.svg)]() [![License](https://img.shields.io/badge/license-GPLv3-blue.svg)](LICENSE.txt)

**Native macOS Game Streaming Client** | **原生 macOS 游戏串流客户端**

A native macOS client for game streaming, built with AppKit/SwiftUI. Combines the smooth experience of a native Mac app with powerful community-enhanced features.

一款原生 macOS 游戏串流客户端，使用 AppKit/SwiftUI 构建。结合原生 Mac 应用的流畅体验与社区增强版的强大功能。

[English](#-features) | [简体中文](#-特性)

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

<a name="简体中文"></a>

## 🇨🇳 简体中文

**Moonlight macOS Enhanced** 是一款原生 macOS 游戏串流客户端，使用 AppKit/SwiftUI 构建。它结合了原生 Mac 应用的流畅体验与社区增强版的强大功能。

### ✨ 核心特性

#### 🍎 原生 macOS 体验
- **Apple Silicon 优化** - 原生支持 Apple Silicon 芯片
- **原生界面** - 使用 AppKit/SwiftUI 构建，非 Qt 移植
- **深色模式** - 完整支持系统深色模式
- **多语言** - 支持简体中文和英文

#### 🎮 串流性能
- **自定义分辨率和帧率** - 可配置分辨率和刷新率
- **HEVC/H.264** - 硬件加速视频解码
- **HDR** - 高动态范围支持
- **YUV 4:4:4** - 增强色彩采样（需要 Foundation Sunshine）
- **垂直同步** - V-Sync 支持
- **环绕声** - 5.1/7.1 音频支持

#### 🚀 增强功能（新增特性）
| 功能 | 说明 |
|------|------|
| 🎤 **麦克风直通** | 将麦克风音频传输到主机（需要 Foundation Sunshine） |
| 📊 **性能浮窗** | 实时显示延迟、帧率、码率等信息（⌃⌥S 切换） |
| 🖥️ **多主机同时串流** | 同时连接多台主机 |
| 🎨 **MetalFX 画质增强** | Apple AI 超分辨率技术 |
| 🌐 **自定义端口/IPv6/域名** | 灵活的连接选项 |
| 🔧 **连接方式管理** | 为每台主机管理多个连接方式 |
| 🎮 **手柄鼠标模式** | 用手柄模拟鼠标操作 |
| ⚡ **自动码率** | 根据网络状况自适应调整 |
| 🖼️ **显示模式** | 全屏 / 无边框 / 窗口化 |
| 🔄 **智能重连** | 自动重连并处理超时 |

### 🖥️ 主机端兼容性

| 主机软件 | 兼容性 | 备注 |
|----------|--------|------|
| [Foundation Sunshine](https://github.com/qiin2333/foundation-sunshine) | ⭐ 推荐 | 支持全部功能（麦克风、YUV444 等） |
| [Sunshine (LizardByte)](https://github.com/LizardByte/Sunshine) | ✅ 支持 | 部分高级功能不可用 |
| GeForce Experience | ⚠️ 基础支持 | 已停止更新，不支持麦克风 |

> 💡 **麦克风、YUV 4:4:4** 等高级功能需要配合 [Foundation Sunshine](https://github.com/qiin2333/foundation-sunshine) 使用

### 📸 截图

| 主机列表 | 应用列表 |
|:--------:|:--------:|
| <img src="readme-assets/images/host-list.png" width="400" alt="主机列表"> | <img src="readme-assets/images/app-list.png" width="400" alt="应用列表"> |

| 性能浮窗 | 连接管理 |
|:--------:|:--------:|
| <img src="readme-assets/images/performance-overlay.png" width="400" alt="性能浮窗"> | <img src="readme-assets/images/connection-manager.png" width="400" alt="连接管理"> |

| 串流中遮罩 | 连接错误 |
|:----------:|:--------:|
| <img src="readme-assets/images/streaming-overlay.png" width="400" alt="串流中遮罩"> | <img src="readme-assets/images/connection-error.png" width="400" alt="连接错误"> |

| 视频设置 | 串流设置 |
|:--------:|:--------:|
| <img src="readme-assets/images/settings-video.png" width="400" alt="视频设置"> | <img src="readme-assets/images/settings-streaming.png" width="400" alt="串流设置"> |

### ⌨️ 快捷键

| 快捷键 | 功能 |
|--------|------|
| `Ctrl` + `Option` | 释放鼠标 |
| `Ctrl` + `Option` + `S` | 切换性能浮窗 |
| `Ctrl` + `Option` + `W` | 断开连接 |
| `Ctrl` + `Shift` + `W` | 退出应用 |

### 🛠️ 安装

#### 下载发布版
从 [Releases](https://github.com/skyhua0224/moonlight-macos/releases) 下载最新的 `.dmg` 文件。

> ⚠️ **此应用未经公证签名。** 首次启动时：
> - 右键点击应用，选择"打开"，或
> - 前往 系统设置 → 隐私与安全性 → 仍要打开，或
> - 在终端运行：`xattr -cr /Applications/Moonlight.app`

#### 从源码构建
```bash
git clone --recursive https://github.com/skyhua0224/moonlight-macos.git
cd moonlight-macos
# 在 Xcode 中打开 Moonlight.xcodeproj 并构建
```

### 📅 更新策略

本项目为个人业余时间维护：
- 🐛 严重 Bug 和闪退问题优先修复
- 💡 有空闲时间或看到好建议时会添加新功能
- 📥 欢迎提交 Issue 和 PR，但响应时间不固定

> 我自己每天都在使用这个应用，所以会持续保持它的正常运行！

### 🐛 问题反馈

提交 Bug 时请包含：
- macOS 版本（如 macOS 14.2）
- 芯片类型（Intel / M1 / M2 / M3 / M4）
- 主机端软件及版本（Sunshine / Foundation Sunshine / GFE）
- 复现步骤
- 相关日志或截图

### 🤝 贡献代码

欢迎提交 PR！请：
- 遵循现有代码风格
- 测试你的更改
- 提供清晰的描述

---

## 📬 Contact | 联系方式

- 📧 Email: [dev@sky-hua.xyz](mailto:dev@sky-hua.xyz)
- 💬 Telegram: [@skyhua](https://t.me/skyhua)
- 🐧 QQ: 2110591491
- 🔗 GitHub Issues: [Submit Issue](https://github.com/skyhua0224/moonlight-macos/issues)

> 💡 Prefer GitHub Issues for bug reports and feature requests | 建议使用 GitHub Issues 提交问题和建议

---

## 🙏 Acknowledgements | 致谢

This project is built upon these excellent open-source projects:

### Core Projects | 核心项目
- **[moonlight-macos](https://github.com/MichaelMKenny/moonlight-macos)** by MichaelMKenny - Native macOS client foundation
- **[moonlight-common-c](https://github.com/moonlight-stream/moonlight-common-c)** by Moonlight Team - Core streaming protocol

### Feature References | 功能参考
- **[Foundation Sunshine](https://github.com/qiin2333/foundation-sunshine)** by qiin2333 - Enhanced host with microphone support
- **[moonlight-qt](https://github.com/moonlight-stream/moonlight-qt)** by Moonlight Team - Official cross-platform client

### Dependencies | 依赖库
- [SDL2](https://www.libsdl.org/) - Input handling
- [OpenSSL](https://www.openssl.org/) - Encryption
- [MASPreferences](https://github.com/shpakovski/MASPreferences) - Settings UI

---

## 📄 License

This project is licensed under the [GPLv3 License](LICENSE.txt).

