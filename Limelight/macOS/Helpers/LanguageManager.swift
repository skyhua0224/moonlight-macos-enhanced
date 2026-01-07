//
//  LanguageManager.swift
//  Moonlight for macOS
//
//  Created by Cline on 2024/01/17.
//

import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
  case system = "System"
  case english = "English"
  case chinese = "简体中文"

  var id: String { rawValue }
}

class LanguageManager: ObservableObject {
  static let shared = LanguageManager()

  @AppStorage("appLanguage") var currentLanguage: AppLanguage = .system

  func localize(_ key: String) -> String {
    let useChinese: Bool

    if currentLanguage == .system {
      // Check system preference
      let preferred = Locale.preferredLanguages.first ?? "en"
      useChinese = preferred.hasPrefix("zh")
    } else {
      useChinese = currentLanguage == .chinese
    }

    let dict = useChinese ? zhHans : en
    return dict[key] ?? key
  }

  private let en: [String: String] = [
    "Stream": "Stream",
    "Video and Audio": "Video and Audio",
    "Input": "Input",
    "App": "App",
    "Legacy": "Legacy",
    "General": "General",
    "Language": "Language",
    "System": "System (Default)",

    "Profile:": "Profile:",

    "Resolution and FPS": "Resolution and FPS",
    "Resolution": "Resolution",
    "Custom": "Custom",
    "Custom Resolution": "Custom Resolution",
    "FPS": "FPS",
    "Custom FPS": "Custom FPS",
    "Bitrate": "Bitrate",

    "Video": "Video",
    "Video Codec": "Video Codec",
    "Upscaling": "Upscaling",
    "Off": "Off",
    "MetalFX Spatial (Quality)": "MetalFX Spatial (Quality)",
    "MetalFX Spatial (Performance)": "MetalFX Spatial (Performance)",
    "HDR": "HDR",
    "Frame Pacing": "Frame Pacing",
    "Lowest Latency": "Lowest Latency",
    "Smoothest Video": "Smoothest Video",

    "Audio": "Audio",
    "Play Sound on Host": "Play Sound on Host",
    "Volume": "Volume",

    "Controller": "Controller",
    "Multi-Controller Mode": "Multi-Controller Mode",
    "Single": "Single",
    "Auto": "Auto",
    "Rumble Controller": "Rumble Controller",
    "Buttons": "Buttons",
    "Swap A/B and X/Y Buttons": "Swap A/B and X/Y Buttons",
    "Emulate Guide Button": "Emulate Guide Button",
    "Drivers": "Drivers",
    "Controller Driver": "Controller Driver",
    "Mouse Driver": "Mouse Driver",
    "HID": "HID",
    "MFi": "MFi",

    "Behaviour": "Behaviour",
    "Automatically Fullscreen Stream Window": "Automatically Fullscreen Stream Window",
    "Visuals": "Visuals",
    "Dim Non-Hovered Apps": "Dim Non-Hovered Apps",
    "Custom Artwork Dimensions": "Custom Artwork Dimensions",

    "Geforce Experience": "Geforce Experience",
    "Optimize Game Settings": "Optimize Game Settings",

    "Mouse Mode On": "Mouse Mode On",
    "Mouse Mode Off": "Mouse Mode Off",

    "Not supported": "Not supported",

    // Connection Details
    "Connection Details": "Connection Details",
    "Basic Info": "Basic Info",
    "Host Name": "Host Name",
    "Status": "Status",
    "Online": "Online",
    "Offline": "Offline",
    "Unknown": "Unknown",
    "Pair State": "Pair State",
    "Paired": "Paired",
    "Unpaired": "Unpaired",
    "Network": "Network",
    "Active Address": "Active Address",
    "Local Address": "Local Address",
    "External Address": "External Address",
    "IPv6 Address": "IPv6 Address",
    "Manual Address": "Manual Address",
    "MAC Address": "MAC Address",
    "System": "System",
    "UUID": "UUID",
    "Running Game": "Running Game",
    "Latency": "Latency",
    "Close": "Close",
  ]

  private let zhHans: [String: String] = [
    "Stream": "串流",
    "Video and Audio": "音视频",
    "Input": "输入",
    "App": "应用",
    "Legacy": "旧版",
    "General": "通用",
    "Language": "语言",
    "System": "系统默认",

    "Profile:": "配置文件:",

    "Resolution and FPS": "分辨率与帧率",
    "Resolution": "分辨率",
    "Custom": "自定义",
    "Custom Resolution": "自定义分辨率",
    "FPS": "帧率",
    "Custom FPS": "自定义帧率",
    "Bitrate": "比特率",

    "Video": "视频",
    "Video Codec": "视频编码",
    "Upscaling": "画质增强 (Upscaling)",
    "Off": "关闭",
    "MetalFX Spatial (Quality)": "MetalFX 空间缩放 (画质优先)",
    "MetalFX Spatial (Performance)": "MetalFX 空间缩放 (性能优先)",
    "HDR": "HDR",
    "Frame Pacing": "帧率平滑",
    "Lowest Latency": "最低延迟",
    "Smoothest Video": "最流畅视频",

    "Audio": "音频",
    "Play Sound on Host": "在主机上播放声音",
    "Volume": "音量",

    "Controller": "手柄",
    "Multi-Controller Mode": "多手柄模式",
    "Single": "单人",
    "Auto": "自动",
    "Rumble Controller": "手柄震动",
    "Buttons": "按键",
    "Swap A/B and X/Y Buttons": "交换 A/B 和 X/Y 键",
    "Emulate Guide Button": "模拟 Guide 键",
    "Drivers": "驱动",
    "Controller Driver": "手柄驱动",
    "Mouse Driver": "鼠标驱动",
    "HID": "HID",
    "MFi": "MFi",

    "Behaviour": "行为",
    "Automatically Fullscreen Stream Window": "自动全屏串流窗口",
    "Visuals": "视觉",
    "Dim Non-Hovered Apps": "未悬停应用变暗",
    "Custom Artwork Dimensions": "自定义封面尺寸",

    "Geforce Experience": "Geforce Experience",
    "Optimize Game Settings": "优化游戏设置",

    "Mouse Mode On": "鼠标模式开启",
    "Mouse Mode Off": "鼠标模式关闭",

    "Not supported": "不支持",

    // Connection Details
    "Connection Details": "连接详情",
    "Basic Info": "基本信息",
    "Host Name": "主机名称",
    "Status": "状态",
    "Online": "在线",
    "Offline": "离线",
    "Unknown": "未知",
    "Pair State": "配对状态",
    "Paired": "已配对",
    "Unpaired": "未配对",
    "Network": "网络",
    "Active Address": "活动地址",
    "Local Address": "本地地址",
    "External Address": "外部地址",
    "IPv6 Address": "IPv6 地址",
    "Manual Address": "手动地址",
    "MAC Address": "MAC 地址",
    "System": "系统",
    "UUID": "UUID",
    "Running Game": "运行游戏",
    "Latency": "延迟",
    "Close": "关闭",
  ]
}
