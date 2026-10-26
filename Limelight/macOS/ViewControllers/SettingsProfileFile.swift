//
//  SettingsProfileFile.swift
//  Moonlight for macOS
//
//  Copyright © 2026 Moonlight Game Streaming Project. All rights reserved.
//

import Foundation

/// A settings profile written to a file (JSON). It holds what a copy would take: the
/// shareable fields of `Settings` and the per-profile keys by their ids. Nothing host-only is
/// in it; version 1 files could hold some, and they are ignored on import.
struct SettingsProfileFile: Codable {
  static let formatName = "moonlight-macos-enhanced.settings-profile"
  static let currentFormatVersion = 2

  /// A per-profile key's value. UserDefaults hands them over as property list objects; each
  /// one is written with its kind so it is stored back as the same kind.
  enum KeyValue: Codable, Equatable {
    case bool(Bool)
    case integer(Int)
    case double(Double)
    case string(String)
    case data(Data)

    private enum CodingKeys: String, CodingKey { case type, value }

    init?(_ object: Any) {
      if let number = object as? NSNumber {
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
          self = .bool(number.boolValue)
        } else if CFNumberIsFloatType(number) {
          self = .double(number.doubleValue)
        } else {
          self = .integer(number.intValue)
        }
      } else if let string = object as? String {
        self = .string(string)
      } else if let data = object as? Data {
        self = .data(data)
      } else {
        return nil
      }
    }

    var object: Any {
      switch self {
      case .bool(let value): return value
      case .integer(let value): return value
      case .double(let value): return value
      case .string(let value): return value
      case .data(let value): return value
      }
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      switch try container.decode(String.self, forKey: .type) {
      case "bool": self = .bool(try container.decode(Bool.self, forKey: .value))
      case "integer": self = .integer(try container.decode(Int.self, forKey: .value))
      case "double": self = .double(try container.decode(Double.self, forKey: .value))
      case "string": self = .string(try container.decode(String.self, forKey: .value))
      case "data": self = .data(try container.decode(Data.self, forKey: .value))
      default:
        throw DecodingError.dataCorruptedError(
          forKey: .type, in: container, debugDescription: "Unknown value type")
      }
    }

    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      switch self {
      case .bool(let value):
        try container.encode("bool", forKey: .type)
        try container.encode(value, forKey: .value)
      case .integer(let value):
        try container.encode("integer", forKey: .type)
        try container.encode(value, forKey: .value)
      case .double(let value):
        try container.encode("double", forKey: .type)
        try container.encode(value, forKey: .value)
      case .string(let value):
        try container.encode("string", forKey: .type)
        try container.encode(value, forKey: .value)
      case .data(let value):
        // Base64, as JSONEncoder writes Data.
        try container.encode("data", forKey: .type)
        try container.encode(value, forKey: .value)
      }
    }
  }

  enum ReadError: Error {
    case unreadable
    case notAProfile
    case newerVersion
  }

  let format: String
  let formatVersion: Int
  let appVersion: String
  let profileName: String
  let exportedAt: Date
  let settings: Settings
  let profileKeys: [String: KeyValue]

  init(profileName: String, snapshot: SettingsModel.ProfileSnapshot) {
    format = Self.formatName
    formatVersion = Self.currentFormatVersion
    appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    self.profileName = profileName
    exportedAt = Date()
    settings = snapshot.settings.shareableOnly
    var keys: [String: KeyValue] = [:]
    for entry in SettingsModel.profileKeys {
      if let object = snapshot.keys[entry.id], let value = KeyValue(object) {
        keys[entry.id] = value
      }
    }
    profileKeys = keys
  }

  /// The profile's preferences. Keys this version does not know are left out.
  var snapshot: SettingsModel.ProfileSnapshot {
    let settings = settings.shareableOnly
    var keys: [String: Any] = [:]
    for entry in SettingsModel.profileKeys {
      if let value = profileKeys[entry.id] { keys[entry.id] = value.object }
    }
    return SettingsModel.ProfileSnapshot(settings: settings, keys: keys)
  }

  func write(to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    encoder.nonConformingFloatEncodingStrategy = .convertToString(
      positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
    try encoder.encode(self).write(to: url, options: .atomic)
  }

  static func read(from url: URL) throws -> SettingsProfileFile {
    guard let data = try? Data(contentsOf: url) else { throw ReadError.unreadable }
    // The wrapper first: a file of another kind is named as such, not as a damaged profile.
    struct Header: Decodable {
      let format: String?
      let formatVersion: Int?
    }
    guard let header = try? JSONDecoder().decode(Header.self, from: data),
      header.format == formatName, let version = header.formatVersion
    else { throw ReadError.notAProfile }
    guard version <= currentFormatVersion else { throw ReadError.newerVersion }

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    decoder.nonConformingFloatDecodingStrategy = .convertFromString(
      positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
    guard let file = try? decoder.decode(SettingsProfileFile.self, from: data) else {
      throw ReadError.notAProfile
    }
    return file
  }

  static func message(for error: Error) -> String {
    switch error as? ReadError {
    case .newerVersion:
      return LanguageManager.shared.localize("Profile Import Error Newer")
    case .notAProfile:
      return LanguageManager.shared.localize("Profile Import Error Not Profile")
    default:
      return LanguageManager.shared.localize("Profile Import Error Unreadable")
    }
  }
}
