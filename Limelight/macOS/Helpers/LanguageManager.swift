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
    updateAppLanguage(postNotification: false)
  }

  @objc(applyAppLanguage) public func applyAppLanguage() {
    updateAppLanguage(postNotification: true)
  }

  private func updateAppLanguage(postNotification: Bool) {
    switch currentLanguage {
    case .system:
      UserDefaults.standard.removeObject(forKey: "AppleLanguages")
    case .english:
      UserDefaults.standard.set(["en"], forKey: "AppleLanguages")
    case .chinese:
      UserDefaults.standard.set(["zh-Hans"], forKey: "AppleLanguages")
    }

    guard postNotification else { return }
    NotificationCenter.default.post(name: .init("LanguageChanged"), object: nil)
  }

  /// The two language bundles are looked up once, not on every call.
  private static let languageBundles: [String: Bundle] = {
    var found: [String: Bundle] = [:]
    for code in ["en", "zh-Hans"] {
      if let path = Bundle.main.path(forResource: code, ofType: "lproj"), let bundle = Bundle(path: path) {
        found[code] = bundle
      }
    }
    return found
  }()

  private func localizedString(_ key: String, languageCode: String) -> String? {
    guard let bundle = Self.languageBundles[languageCode] else { return nil }
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

    // Every string lives in the two Localizable.strings files, and nowhere else
    // (scripts/check_localization.py enforces it). English is the development
    // language and the fallback for a key the Chinese file does not have.
    if useChinese, let val = localizedString(key, languageCode: "zh-Hans") { return val }
    if let val = localizedString(key, languageCode: "en") { return val }
    return key
  }
}
