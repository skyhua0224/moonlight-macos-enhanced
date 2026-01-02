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

**Moonlight macOS Enhanced** combines the fluidity of a native macOS application with the rich feature set of the community-enhanced QT version.

### 🌟 Project Origins

This project is a fusion of two excellent open-source projects:

1.  **Core Base:** [moonlight-macos](https://github.com/MichaelMKenny/moonlight-macos) (Native AppKit/SwiftUI foundation)
2.  **Feature Reference:** [moonlight-qt (qiin2333 fork)](https://github.com/qiin2333/moonlight-qt) (Enhanced functionality reference)

> **Key Enhancement:** The original native client lacked support for **Custom Ports**, **IPv6**, and **Domain Names**. This enhanced version implements these features, offering greater connectivity flexibility comparable to the QT version.

### ✨ Features

- **🚀 Apple Silicon Native:** Optimized for M1/M2/M3 chips.
- **🖥️ Performance:** 4K @ 144fps, HEVC/H.264 Hardware Decoding, HDR.
- **🌐 Connectivity:** Custom Ports, IPv6, Domain Name support, Wake-on-LAN.
- **🎨 UI/UX:** Native macOS interface with Dark Mode support.
- **🎮 Controls:** Extensive Gamepad support with custom HID drivers.
- **🆕 New Additions:**
  - Localization (Chinese/English)
  - Surround Sound (5.1/7.1) *[In Progress]*
  - V-Sync & Performance Overlay *[In Progress]*

### 📸 Screenshots

| Host List | Preferences |
|:---:|:---:|
| <img src="readme-assets/images/host-list.png" width="400"> | <img src="readme-assets/images/preferences.png" width="400"> |

### 🛠️ Build

```bash
git clone --recursive https://github.com/skyhua0224/moonlight-macos-enhanced.git
# Open Moonlight.xcodeproj in Xcode and build.
```

---

<a name="简体中文"></a>

## 🇨🇳 简体中文

**Moonlight macOS Enhanced** 旨在结合 macOS 原生应用的流畅体验与社区增强版 QT 客户端的丰富功能。

### 🌟 项目渊源

本项目融合了两个优秀的开源项目：

1.  **核心基础:** [moonlight-macos](https://github.com/MichaelMKenny/moonlight-macos) (提供原生 AppKit/SwiftUI 架构)
2.  **功能参考:** [moonlight-qt (qiin2333 修改版)](https://github.com/qiin2333/moonlight-qt) (提供增强功能参考)

> **核心增强：** 原版 macOS 客户端不支持 **自定义端口**、**IPv6** 或 **域名连接**。本项目已补全这些功能，提供了与 QT 版本相当的连接灵活性。

### ✨ 主要特性

- **🚀 Apple Silicon 原生:** 针对 M1/M2/M3 芯片深度优化。
- **🖥️ 极致性能:** 支持 4K 144fps，HEVC/H.264 硬件解码，HDR。
- **🌐 连接增强:** 支持自定义端口、IPv6、域名连接及网络唤醒 (WoL)。
- **🎨 原生体验:** 纯正 macOS 界面风格，支持深色模式。
- **🎮 手柄支持:** 广泛的控制器兼容性，内置自定义 HID 驱动。
- **🆕 新增功能:**
  - 多语言支持 (简中/英文)
  - 环绕声支持 (5.1/7.1) *[开发中]*
  - 垂直同步与性能浮窗 *[开发中]*

### 💡 快捷键

- **释放鼠标:** `Ctrl` + `Opt`
- **快速断开:** `Ctrl` + `Opt` + `W`
- **退出应用:** `Ctrl` + `Shift` + `W`

### 🤝 致谢 (Acknowledgements)

- **MichaelMKenny** for the native macOS foundation.
- **Moonlight Stream Team** & **qiin2333** for the feature-rich QT implementation.
- **Dependencies:** [MASPreferences](https://github.com/shpakovski/MASPreferences), [Functional](https://github.com/leuchtetgruen/Functional.m).
