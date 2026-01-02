# Moonlight macOS Enhanced (增强版)

<div align="center">

![Moonlight Logo](readme-assets/images/app-list.png)

**Native macOS client for NVIDIA GameStream | NVIDIA GameStream 原生 macOS 客户端**

[![License](https://img.shields.io/badge/license-GPLv3-blue.svg)](LICENSE.txt)
[![Platform](https://img.shields.io/badge/platform-macOS-lightgrey.svg)]()

[English](#-english) | [简体中文](#-简体中文)

</div>

---

<a name="english"></a>

## 🇬🇧 English

**Moonlight macOS Enhanced** is a native macOS client for NVIDIA's GameStream, allowing you to stream games from your desktop computer to your Mac with high performance and low latency.

> **Project Origins:**
> This project is a fork based on the native **[moonlight-macos](https://github.com/MichaelMKenny/moonlight-macos)** project, incorporating advanced features and design references from the official **[moonlight-qt](https://github.com/moonlight-stream/moonlight-qt)** client. It aims to combine the native look and feel of macOS with the rich functionality of the QT version.

### ✨ Key Features

- **🚀 Apple Silicon Native:** Fully optimized for M1/M2/M3 chips.
- **🖥️ High Performance:** Up to 4K streaming at 144fps with Hardware Decoding (HEVC/H.264).
- **🎨 Native UI:** Built with AppKit/SwiftUI for a true macOS experience, including Dark Mode.
- **🎮 Controller Support:** Extensive support including custom HID drivers for older macOS versions.
- **🔌 Connectivity:** Local network discovery, manual host addition, and Wake-on-LAN.
- **🆕 Enhanced Features (In Progress):**
  - 🌐 **Localization:** Full Chinese/English support.
  - 🎧 **Surround Sound:** 5.1/7.1 Audio support.
  - 📊 **Pro Tools:** V-Sync toggle and Performance Overlay.

### 📸 Screenshots

| Host List | Preferences |
|:---:|:---:|
| <img src="readme-assets/images/host-list.png" width="400"> | <img src="readme-assets/images/preferences.png" width="400"> |

### 🛠️ Build Instructions

1. **Clone the repository:**
   ```bash
   git clone --recursive https://github.com/skyhua0224/moonlight-macos-enhanced.git
   ```
2. **Install Dependencies:**
   Download [the latest frameworks](https://github.com/coofdy/moonlight-mobile-deps/releases/download/latest/moonlight-apple-xcframeworks.zip), unzip, and place `.xcframework` files into the `xcframeworks` directory.
3. **Build in Xcode:**
   - Open `Moonlight.xcodeproj`.
   - Update **Signing & Capabilities** with your Team ID.
   - Update **Bundle Identifier**.
   - Select "Moonlight" target > "My Mac" > Run (`Cmd+R`).

### 🤝 Acknowledgements

- **Core Base:** [moonlight-macos](https://github.com/MichaelMKenny/moonlight-macos) by MichaelMKenny.
- **Feature Reference:** [moonlight-qt](https://github.com/moonlight-stream/moonlight-qt) by the Moonlight Stream team.
- **Dependencies:** [MASPreferences](https://github.com/shpakovski/MASPreferences), [Functional](https://github.com/leuchtetgruen/Functional.m).

---

<a name="简体中文"></a>

## 🇨🇳 简体中文

**Moonlight macOS Enhanced** 是 NVIDIA GameStream 的原生 macOS 客户端增强版。它允许您以高性能和低延迟将桌面电脑上的游戏串流到 Mac 上游玩。

> **项目渊源：**
> 本项目基于 **[moonlight-macos](https://github.com/MichaelMKenny/moonlight-macos)** 原生项目开发，并参考了官方 **[moonlight-qt](https://github.com/moonlight-stream/moonlight-qt)** 客户端的功能设计。我们的目标是结合 macOS 原生的流畅体验与 QT 版本的丰富功能。

### ✨ 主要特性

- **🚀 Apple Silicon 原生支持:** 针对 M1/M2/M3 芯片深度优化。
- **🖥️ 极致性能:** 支持最高 4K 144fps 串流，硬件解码 (HEVC/H.264) 及 HDR 支持。
- **🎨 原生界面:** 基于 AppKit/SwiftUI 构建，完美契合 macOS 风格（支持深色模式）。
- **🎮 手柄支持:** 广泛的控制器支持，包含针对旧版 macOS 的自定义 HID 驱动。
- **🔌 便捷连接:** 局域网自动发现、手动添加主机、以及网络唤醒 (WoL) 功能。
- **🆕 增强功能 (开发中):**
  - 🌐 **多语言支持:** 完整的简体中文/英文界面适配。
  - 🎧 **环绕声:** 支持 5.1/7.1 声道输出。
  - 📊 **专业工具:** 垂直同步 (V-Sync) 开关与性能监测浮窗 (Overlay)。

### 💡 使用贴士

- **释放鼠标:** 同时按下 `Control` + `Option`。
- **快速断开:** 按下 `Control` + `Option` + `W`。
- **退出并断开:** 按下 `Control` + `Shift` + `W`。
- **调整图标大小:** 在应用列表中使用 `Command +` 或 `Command -`。

### 🐞 已知问题

- 目前 HID 驱动不支持多个手柄同时使用。
- 仅支持蓝牙连接的 Xbox 手柄（不支持有线）。
- DualSense (PS5) 手柄在有线和无线模式下的震动强度不同。
- 部分 PlayStation 手柄在 FPS 游戏中可能出现视角漂移（建议在设置中将驱动改为 MFi）。
- 侧键鼠标暂不支持。

### 🤝 致谢

- **核心基础:** [moonlight-macos](https://github.com/MichaelMKenny/moonlight-macos) (作者: MichaelMKenny)。
- **功能参考:** [moonlight-qt](https://github.com/moonlight-stream/moonlight-qt) (Moonlight Stream 团队)。
- **开源依赖:** [MASPreferences](https://github.com/shpakovski/MASPreferences), [Functional](https://github.com/leuchtetgruen/Functional.m)。
