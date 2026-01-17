//
//  LanguageManager.swift
//  Moonlight for macOS
//
//  Created by SkyHua on 2024/01/17.
//

import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
  case system = "System"
  case english = "English"
  case chinese = "简体中文"

  var id: String { rawValue }
}

@objcMembers
@objc(LanguageManager)
public class LanguageManager: NSObject, ObservableObject {
  public static let shared = LanguageManager()

  @AppStorage("appLanguage") var currentLanguage: AppLanguage = .system

  public override init() {
    super.init()
    applyAppLanguage()
  }

  @objc(applyAppLanguage) public func applyAppLanguage() {
    switch currentLanguage {
    case .system:
      UserDefaults.standard.removeObject(forKey: "AppleLanguages")
    case .english:
      UserDefaults.standard.set(["en"], forKey: "AppleLanguages")
    case .chinese:
      UserDefaults.standard.set(["zh-Hans"], forKey: "AppleLanguages")
    }

    NotificationCenter.default.post(name: .init("LanguageChanged"), object: nil)
  }

  private func localizedString(_ key: String, languageCode: String) -> String? {
    guard let path = Bundle.main.path(forResource: languageCode, ofType: "lproj"),
      let bundle = Bundle(path: path)
    else {
      return nil
    }

    let val = NSLocalizedString(
      key, tableName: nil, bundle: bundle, value: "___MISSING___", comment: "")
    return val == "___MISSING___" ? nil : val
  }

  public func localize(_ key: String) -> String {
    let useChinese: Bool

    if currentLanguage == .system {
      // Check system preference
      let preferred = Locale.preferredLanguages.first ?? "en"
      useChinese = preferred.hasPrefix("zh")
    } else {
      useChinese = currentLanguage == .chinese
    }

    if useChinese {
      if let val = zhHans[key] { return val }
      if let val = localizedString(key, languageCode: "zh-Hans") { return val }
      return key
    }

    if let val = en[key] { return val }
    if let val = localizedString(key, languageCode: "en") { return val }
    return key
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
    "Global": "Global",
    "Global (Default)": "Global (Default)",
    "Scope: Global": "Scope: Global",
    "Scope: Profile (%@)": "Scope: Profile (%@)",

    "Resolution and FPS": "Resolution and FPS",
    "Resolution": "Resolution",
    "Match Display": "Match Display",
    "Custom": "Custom",
    "Custom Resolution": "Custom Resolution",
    "Frame Rate": "Frame Rate",
    "FPS": "FPS",
    "Custom FPS": "Custom FPS",

    "Resolution Scale": "Resolution Scale",
    "Resolution Scale Ratio": "Resolution Scale Ratio",
    "Resolution & Scaling": "Resolution & Scaling",
    "Resolution Scale hint": "Reduces resolution to save bandwidth.",
    "Upscaling": "AI Quality Enhancement",
    "Scale vs Upscaling hint": "Scale saves bandwidth. AI enhancement improves quality.",
    "AI enhancement recommended hint": "Recommended for low resolution/low bitrate.",
    "Resolution Scale + Upscaling hint": "Tip: Lower scale + AI enhancement = clearer image.",
    "MetalFX requires macOS 13 or later.": "Requires macOS 13+.",

    "MetalFX Spatial (Quality)": "MetalFX (Quality)",
    "MetalFX Spatial (Performance)": "MetalFX (Performance)",
    "Auto Adjust Bitrate": "Auto Adjust Bitrate",
    "Ignore Aspect Ratio": "Ignore Aspect Ratio",
    "Show Local Cursor": "Show Local Cursor",

    "Remote Resolution": "Host Render Resolution",
    "Remote Resolution Value": "Host Render Resolution",
    "Remote Custom Resolution": "Host Custom Render Resolution",
    "Remote FPS": "Host Render FPS",
    "Remote FPS Value": "Host Render FPS",
    "Remote Custom FPS": "Host Custom Render FPS",
    "Remote overrides hint": "Forces the host to render at this value.",
    "Remote overrides apply to the host render mode only.":
      "Remote overrides apply to the host render mode only.",
    "Enable Remote Resolution/FPS to override the /launch mode parameter.":
      "Enable Remote Resolution/FPS to override the /launch mode parameter.",

    "Bitrate": "Bitrate",

    "Video": "Video",
    "Video Codec": "Video Codec",
    "HDR": "HDR",
    "Frame Pacing": "Frame Pacing",
    "Lowest Latency": "Lowest Latency",
    "Smoothest Video": "Smoothest Video",

    "Audio": "Audio",
    "Audio Configuration": "Audio Configuration",
    "Stereo": "Stereo",
    "5.1 surround sound": "5.1 surround sound",
    "7.1 surround sound": "7.1 surround sound",
    "Play Sound on Host": "Play Sound on Host",
    "V-Sync": "V-Sync",
    "Performance Overlay": "Performance Overlay",
    "Performance Overlay (⌃⌥S)": "Performance Overlay (⌃⌥S)",
    "Show Connection Warnings": "Show Connection Warnings",
    "Unlock max bitrate (1000 Mbps)": "Unlock max bitrate (1000 Mbps)",
    "Volume": "Volume",

    "Controller": "Controller",
    "Multi-Controller Mode": "Multi-Controller Mode",
    "Single": "Single",
    "Auto": "Auto",
    "Rumble Controller": "Rumble Controller",
    "Buttons": "Buttons",
    "Swap A/B and X/Y Buttons": "Swap A/B and X/Y Buttons",
    "Emulate Guide Button": "Emulate Guide Button",
    "Gamepad Mouse Emulation": "Gamepad Mouse Emulation",
    "Gamepad Mouse Hint": "Use the gamepad as a mouse (hold Start to toggle).",
    "Drivers": "Drivers",
    "Advanced": "Advanced",
    "Controller Driver": "Controller Driver",
    "Mouse Driver": "Mouse Driver",
    "HID": "HID",
    "MFi": "MFi",
    "Keyboard": "Keyboard",
    "Capture system keyboard shortcuts": "Capture system keyboard shortcuts",

    "Mouse": "Mouse",
    "Optimize mouse for remote desktop": "Optimize mouse for remote desktop",
    "Swap Left and Right Mouse Buttons": "Swap Left and Right Mouse Buttons",
    "Reverse Mouse Scrolling Direction": "Reverse Mouse Scrolling Direction",
    "Touchscreen Mode": "Touchscreen Mode",
    "Trackpad": "Trackpad",
    "Touchscreen": "Touchscreen",

    "Behaviour": "Behaviour",
    "Default Display Mode": "Default Display Mode",
    "Windowed": "Windowed",
    "Fullscreen": "Fullscreen",
    "Borderless Windowed": "Borderless Windowed",
    "Automatically Fullscreen Stream Window": "Automatically Fullscreen Stream Window",
    "Quit App After Stream": "Quit App After Stream",
    "Visuals": "Visuals",
    "Dim Non-Hovered Apps": "Dim Non-Hovered Apps",
    "Custom Artwork Dimensions": "Custom Artwork Dimensions",

    "Geforce Experience": "Geforce Experience",
    "Optimize Game Settings": "Optimize Game Settings",

    "Mouse Mode On": "Mouse Mode On",
    "Mouse Mode Off": "Mouse Mode Off",

    "Not supported": "Not supported",
    "Settings": "Settings",

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
    "System Info": "System",
    "UUID": "UUID",
    "Running Game": "Running Game",
    "Latency": "Latency",
    "Close": "Close",

    // Host Sidebar & Overlays
    "Computers": "Computers",
    "Streaming Active": "Streaming Active",
    "Host: %@": "Host: %@",
    "App: %@": "App: %@",
    "Connected": "Connected",
    "Show Stream Window": "Show Stream Window",
    "Disconnect": "Disconnect",
    "Disconnect Alert": "Disconnect Alert",
    "Disconnect from Stream": "Disconnect from Stream",
    "Close and Quit App": "Close and Quit App",
    "%@ is Offline": "%@ is Offline",
    "Sending Wake-on-LAN packets...": "Sending Wake-on-LAN packets...",
    "This computer is currently offline or sleeping.": "This computer is currently offline or sleeping.",
    "Waking...": "Waking...",
    "Wake Host": "Wake Host",
    "Refresh Status": "Refresh Status",
    "Back to Computers": "Back to Computers",
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
    "Global": "全局",
    "Global (Default)": "全局（默认）",
    "Scope: Global": "当前作用范围：全局",
    "Scope: Profile (%@)": "当前作用范围：配置文件（%@）",

    "Resolution and FPS": "分辨率和 FPS",
    "Resolution": "分辨率",
    "Match Display": "跟随屏幕",
    "Custom": "自定义",
    "Custom Resolution": "自定义分辨率",
    "Frame Rate": "帧率",
    "FPS": "帧率",
    "Custom FPS": "自定义帧率",

    "Resolution Scale": "分辨率缩放",
    "Resolution Scale Ratio": "缩放比例",
    "Resolution & Scaling": "分辨率与缩放",
    "Resolution Scale hint": "降低分辨率以节省带宽。",
    "Upscaling": "AI 画质增强",
    "Scale vs Upscaling hint": "缩放节省带宽，AI 画质增强提升画质。",
    "AI enhancement recommended hint": "建议在低分辨率/低码率下使用。",
    "Resolution Scale + Upscaling hint": "提示：降低缩放 + AI 画质增强 = 更清晰。",
    "MetalFX requires macOS 13 or later.": "需要 macOS 13+。",
    "Auto Adjust Bitrate": "自动调整码率",
    "Ignore Aspect Ratio": "忽略宽高比限制",
    "Show Local Cursor": "显示本地光标",

    "Remote Resolution": "主机渲染分辨率",
    "Remote Resolution Value": "主机渲染分辨率",
    "Remote Custom Resolution": "主机自定义渲染分辨率",
    "Remote FPS": "主机渲染帧率",
    "Remote FPS Value": "主机渲染帧率",
    "Remote Custom FPS": "主机自定义渲染帧率",
    "Remote overrides hint": "强制被控端按该值渲染。",
    "Remote overrides apply to the host render mode only.": "仅影响被控端渲染/编码。",
    "Enable Remote Resolution/FPS to override the /launch mode parameter.":
      "需开启远程分辨率/帧率才会覆盖启动参数（/launch mode）。",

    "Bitrate": "视频比特率",

    "Video": "视频",
    "Video Codec": "视频编解码器",
    "MetalFX Spatial (Quality)": "MetalFX（画质）",
    "MetalFX Spatial (Performance)": "MetalFX（性能）",
    "Enable YUV 4:4:4": "启用 YUV 4:4:4",
    "YUV 4:4:4 hint": "启用高保真色彩模式 (需要显卡支持)",
    "HDR": "HDR (高动态范围)",
    "Frame Pacing": "帧速调节",
    "Lowest Latency": "最低延迟",
    "Smoothest Video": "最流畅视频",

    "Audio": "音频",
    "Audio Configuration": "音频配置",
    "Stereo": "立体声",
    "5.1 surround sound": "5.1 环绕声",
    "7.1 surround sound": "7.1 环绕声",
    "Play Sound on Host": "在主机上播放声音",
    "V-Sync": "垂直同步",
    "Performance Overlay": "显示性能统计",
    "Performance Overlay (⌃⌥S)": "显示性能统计（⌃⌥S）",
    "Show Connection Warnings": "显示连接质量警告",
    "Unlock max bitrate (1000 Mbps)": "解锁最高码率（最高 1000 Mbps）",
    "Volume": "音量",

    "Controller": "手柄设置",
    "Multi-Controller Mode": "多手柄模式",
    "Single": "单人",
    "Auto": "自动",
    "Rumble Controller": "手柄震动",
    "Buttons": "按键",
    "Swap A/B and X/Y Buttons": "交换手柄的 A/B 和 X/Y 按钮",
    "Emulate Guide Button": "模拟 Guide 键 (长按 Start)",
    "Gamepad Mouse Emulation": "手柄模拟鼠标",
    "Gamepad Mouse Emulation (!)": "手柄模拟鼠标",
    "Gamepad Mouse Hint": "使用手柄模拟鼠标（长按 Start 切换）。",
    "Mouse": "鼠标",
    "Optimize mouse for remote desktop": "优化远程桌面鼠标 (绝对位置)",
    "Swap Left and Right Mouse Buttons": "交换鼠标左右键",
    "Reverse Mouse Scrolling Direction": "反转鼠标滚动方向",
    "Touchscreen Mode": "触摸屏模式",
    "Trackpad": "触控板",
    "Touchscreen": "触摸屏",

    "Behaviour": "行为",
    "Default Display Mode": "默认显示模式",
    "Windowed": "窗口模式",
    "Fullscreen": "全屏模式",
    "Borderless Windowed": "无边框窗口",
    "Automatically Fullscreen Stream Window": "进入串流时默认全屏",
    "Quit App After Stream": "流传输结束后退出程序",
    "Controller Driver": "手柄驱动",
    "Mouse Driver": "鼠标驱动",
    "HID": "HID (推荐)",
    "MFi": "MFi (原生)",
    "Keyboard": "键盘",
    "Capture system keyboard shortcuts": "捕获系统快捷键",

    "Visuals": "界面",
    "Dim Non-Hovered Apps": "调暗未选中应用封面",
    "Custom Artwork Dimensions": "自定义封面尺寸",

    "Geforce Experience": "Geforce Experience",
    "Optimize Game Settings": "优化游戏设置",

    "Mouse Mode On": "鼠标模式开启",
    "Mouse Mode Off": "鼠标模式关闭",

    "Not supported": "不支持",
    "Settings": "设置",

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
    "System Info": "系统",
    "UUID": "UUID",
    "Running Game": "运行游戏",
    "Latency": "延迟",
    "Close": "关闭",

    // Host Sidebar & Overlays
    "Computers": "计算机",
    "Streaming Active": "串流进行中",
    "Host: %@": "主机: %@",
    "App: %@": "应用: %@",
    "Connected": "已连接",
    "Show Stream Window": "显示串流窗口",
    "Disconnect": "断开连接",
    "Disconnect Alert": "断开连接",
    "Disconnect from Stream": "断开串流",
    "Close and Quit App": "断开并退出应用",
    "%@ is Offline": "%@ 离线",
    "Sending Wake-on-LAN packets...": "正在发送网络唤醒数据包...",
    "This computer is currently offline or sleeping.": "此计算机当前离线或休眠。",
    "Waking...": "正在唤醒...",
    "Wake Host": "唤醒主机",
    "Refresh Status": "刷新状态",
    "Back to Computers": "返回计算机列表",
  ]
}
