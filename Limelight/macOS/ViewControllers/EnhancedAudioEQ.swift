import Combine
import Foundation

/// One filter of the parametric equalizer.
struct EnhancedAudioEQBand: Codable, Equatable, Identifiable {
  enum Kind: Int, CaseIterable {
    case peak = 0
    case lowShelf = 1
    case highShelf = 2
    case lowPass = 3
    case highPass = 4

    var titleKey: String {
      switch self {
      case .peak: return "EQ Filter Peak"
      case .lowShelf: return "EQ Filter Low Shelf"
      case .highShelf: return "EQ Filter High Shelf"
      case .lowPass: return "EQ Filter Low Pass"
      case .highPass: return "EQ Filter High Pass"
      }
    }

    var usesGain: Bool {
      self == .peak || self == .lowShelf || self == .highShelf
    }

    /// AVAudioUnitEQFilterType of the filter that takes a Q for this kind (the plain shelves
    /// and passes of the unit are fixed at Q 0.707).
    var unitFilterType: Int {
      switch self {
      case .peak: return 0  // parametric
      case .lowShelf: return 9  // resonantLowShelf
      case .highShelf: return 10  // resonantHighShelf
      case .lowPass: return 3  // resonantLowPass
      case .highPass: return 4  // resonantHighPass
      }
    }
  }

  static let frequencyRange: ClosedRange<Double> = 20...20000
  static let gainRange: ClosedRange<Double> = -24...24
  // What the equalizer unit can reach at every frequency (its bandwidth is 0.05 to 5 octaves).
  static let qRange: ClosedRange<Double> = 0.2...10
  static let defaultQ = 0.707

  var id: UUID
  var kindRawValue: Int
  var frequency: Double
  var gain: Double
  var q: Double
  var enabled: Bool

  var kind: Kind {
    get { Kind(rawValue: kindRawValue) ?? .peak }
    set { kindRawValue = newValue.rawValue }
  }

  init(
    kind: Kind, frequency: Double, gain: Double = 0, q: Double = EnhancedAudioEQBand.defaultQ,
    enabled: Bool = true
  ) {
    id = UUID()
    kindRawValue = kind.rawValue
    self.frequency = Self.clamp(frequency, to: Self.frequencyRange)
    self.gain = Self.clamp(gain, to: Self.gainRange)
    self.q = Self.clamp(q, to: Self.qRange)
    self.enabled = enabled
  }

  private enum CodingKeys: String, CodingKey {
    case id, kind, frequency, gain, q, enabled
  }

  // Never throws: this is stored inside the settings of a host, and one unreadable band must
  // not make the whole profile unreadable.
  init(from decoder: Decoder) throws {
    let container = try? decoder.container(keyedBy: CodingKeys.self)
    func value<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
      guard let container else { return nil }
      return (try? container.decodeIfPresent(type, forKey: key)) ?? nil
    }
    id = value(UUID.self, .id) ?? UUID()
    kindRawValue = value(Int.self, .kind) ?? Kind.peak.rawValue
    frequency = Self.clamp(value(Double.self, .frequency) ?? 1000, to: Self.frequencyRange)
    gain = Self.clamp(value(Double.self, .gain) ?? 0, to: Self.gainRange)
    q = Self.clamp(value(Double.self, .q) ?? Self.defaultQ, to: Self.qRange)
    enabled = value(Bool.self, .enabled) ?? true
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(kindRawValue, forKey: .kind)
    try container.encode(frequency, forKey: .frequency)
    try container.encode(gain, forKey: .gain)
    try container.encode(q, forKey: .q)
    try container.encode(enabled, forKey: .enabled)
  }

  static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
    guard value.isFinite else { return range.lowerBound }
    return min(max(value, range.lowerBound), range.upperBound)
  }
}

/// What the audio enhancement stores besides the fixed-band gains.
struct EnhancedAudioExtras: Codable, Equatable {
  var eqEnabled = true
  var eqMode = EnhancedAudioEQ.Mode.graphic.rawValue
  var eqPreamp = 0.0
  var eqBands: [EnhancedAudioEQBand] = []
  var eqProfileName: String?
  var spatialMode = EnhancedAudioSpatialMode.automatic.rawValue
  /// Preamp of the equalizer kind that is not in use (fixed and custom bands keep their own).
  var eqInactivePreamp = 0.0

  init(
    eqEnabled: Bool = true, eqMode: Int = EnhancedAudioEQ.Mode.graphic.rawValue,
    eqPreamp: Double = 0, eqBands: [EnhancedAudioEQBand] = [], eqProfileName: String? = nil,
    spatialMode: Int = EnhancedAudioSpatialMode.automatic.rawValue, eqInactivePreamp: Double = 0
  ) {
    self.spatialMode = spatialMode
    self.eqInactivePreamp = EnhancedAudioEQBand.clamp(
      eqInactivePreamp, to: EnhancedAudioEQ.preampRange)
    self.eqEnabled = eqEnabled
    self.eqMode = eqMode
    self.eqPreamp = EnhancedAudioEQBand.clamp(eqPreamp, to: EnhancedAudioEQ.preampRange)
    self.eqBands = Array(eqBands.prefix(EnhancedAudioEQ.maxBands))
    self.eqProfileName = eqProfileName
  }

  private enum CodingKeys: String, CodingKey {
    case eqEnabled, eqMode, eqPreamp, eqBands, eqProfileName, spatialMode, eqInactivePreamp
  }

  // Never throws, for the same reason as the band.
  init(from decoder: Decoder) throws {
    let container = try? decoder.container(keyedBy: CodingKeys.self)
    func value<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
      guard let container else { return nil }
      return (try? container.decodeIfPresent(type, forKey: key)) ?? nil
    }
    self.init(
      eqEnabled: value(Bool.self, .eqEnabled) ?? true,
      eqMode: value(Int.self, .eqMode) ?? EnhancedAudioEQ.Mode.graphic.rawValue,
      eqPreamp: value(Double.self, .eqPreamp) ?? 0,
      eqBands: value([EnhancedAudioEQBand].self, .eqBands) ?? [],
      eqProfileName: value(String.self, .eqProfileName),
      spatialMode: value(Int.self, .spatialMode) ?? EnhancedAudioSpatialMode.automatic.rawValue,
      eqInactivePreamp: value(Double.self, .eqInactivePreamp) ?? 0)
  }
}

/// Equalizer presets the user saved. They are kept for the app, not per host.
struct EnhancedAudioEQUserPreset: Codable, Identifiable, Equatable {
  var id = UUID()
  var name: String
  var preamp: Double
  var bands: [EnhancedAudioEQBand]

  var profile: EnhancedAudioEQ.ImportedProfile {
    EnhancedAudioEQ.ImportedProfile(preamp: preamp, bands: bands, skippedLines: 0)
  }
}

final class EnhancedAudioEQUserPresets: ObservableObject {
  static let shared = EnhancedAudioEQUserPresets()
  private static let storageKey = "enhancedAudioEQUserPresets"

  @Published private(set) var presets: [EnhancedAudioEQUserPreset] = []

  private init() {
    if let data = UserDefaults.standard.data(forKey: Self.storageKey),
      let stored = try? PropertyListDecoder().decode([EnhancedAudioEQUserPreset].self, from: data)
    {
      presets = stored
    }
  }

  /// Saves under a name; a preset that already has the name is replaced.
  func save(name: String, profile: EnhancedAudioEQ.ImportedProfile) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !profile.bands.isEmpty else { return }
    var updated = presets.filter { $0.name.caseInsensitiveCompare(trimmed) != .orderedSame }
    updated.append(
      EnhancedAudioEQUserPreset(name: trimmed, preamp: profile.preamp, bands: profile.bands))
    updated.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    store(updated)
  }

  func delete(_ id: UUID) {
    store(presets.filter { $0.id != id })
  }

  private func store(_ updated: [EnhancedAudioEQUserPreset]) {
    presets = updated
    if let data = try? PropertyListEncoder().encode(updated) {
      UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
  }
}

/// The headphone corrections that ship with the app: the parametric results of the AutoEq
/// project, one per headphone (see scripts/build_headphone_corrections.py).
final class HeadphoneCorrectionLibrary: ObservableObject {
  struct Entry: Identifiable {
    let id: Int
    let name: String
    /// over-ear, in-ear or earbud.
    let form: String
    /// Who measured it.
    let source: String
    let preamp: Double
    /// "K frequency gain q" joined by ";", K being P, L or H.
    let filters: String
    let searchKey: String
    /// The search key without spaces and dashes, so "hd650" finds "HD 650".
    let compactKey: String
  }

  static let shared = HeadphoneCorrectionLibrary()

  @Published private(set) var entries: [Entry] = []
  private var isLoading = false

  private static func compact(_ text: String) -> String {
    text.filter { $0 != " " && $0 != "-" }
  }

  /// Main thread. Reads the list in the background the first time it is needed.
  func loadIfNeeded() {
    guard entries.isEmpty, !isLoading else { return }
    isLoading = true
    DispatchQueue.global(qos: .userInitiated).async {
      let loaded = Self.load()
      DispatchQueue.main.async {
        self.entries = loaded
        self.isLoading = false
      }
    }
  }

  private static func load() -> [Entry] {
    guard let url = Bundle.main.url(forResource: "HeadphoneCorrections", withExtension: "tsv"),
      let text = try? String(contentsOf: url, encoding: .utf8)
    else { return [] }
    var result: [Entry] = []
    result.reserveCapacity(6500)
    for line in text.split(separator: "\n") where !line.hasPrefix("#") {
      let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
      guard fields.count == 5, let preamp = Double(fields[3]) else { continue }
      let name = String(fields[0])
      let key = name.lowercased()
      result.append(
        Entry(
          id: result.count, name: name, form: String(fields[1]), source: String(fields[2]),
          preamp: preamp, filters: String(fields[4]), searchKey: key, compactKey: compact(key)))
    }
    return result
  }

  /// Headphones whose name has every word of the query; the ones that begin with it come first.
  func search(_ query: String, limit: Int = 50) -> [Entry] {
    let words = query.lowercased().split(separator: " ").map(String.init)
    guard !words.isEmpty else { return [] }
    let joined = words.joined(separator: " ")
    let compactQuery = Self.compact(joined)
    var leading: [Entry] = []
    var others: [Entry] = []
    for entry in entries {
      guard
        words.allSatisfy({ entry.searchKey.contains($0) })
          || entry.compactKey.contains(compactQuery)
      else { continue }
      if entry.searchKey.hasPrefix(joined) {
        leading.append(entry)
        if leading.count >= limit { break }
      } else if others.count < limit {
        others.append(entry)
      }
    }
    return Array((leading + others).prefix(limit))
  }

  func profile(for entry: Entry) -> EnhancedAudioEQ.ImportedProfile {
    let bands = entry.filters.split(separator: ";").compactMap { item -> EnhancedAudioEQBand? in
      let parts = item.split(separator: " ")
      guard parts.count == 4, let frequency = Double(parts[1]), let gain = Double(parts[2]),
        let q = Double(parts[3])
      else { return nil }
      let kind: EnhancedAudioEQBand.Kind =
        parts[0] == "L" ? .lowShelf : (parts[0] == "H" ? .highShelf : .peak)
      return EnhancedAudioEQBand(kind: kind, frequency: frequency, gain: gain, q: q)
    }
    return EnhancedAudioEQ.ImportedProfile(
      preamp: EnhancedAudioEQBand.clamp(entry.preamp, to: EnhancedAudioEQ.preampRange),
      bands: Array(bands.prefix(EnhancedAudioEQ.maxBands)), skippedLines: 0)
  }
}

/// MLAudioEnhancedSpatialMode in Connection.m.
enum EnhancedAudioSpatialMode: Int, CaseIterable {
  /// Surround streams are rendered binaurally for headphones; everything else is widened stereo.
  case automatic = 0
  case wideStereo = 1
  case off = 2

  var title: String {
    switch self {
    case .automatic: return "Spatial Audio Automatic"
    case .wideStereo: return "Spatial Audio Wide Stereo"
    case .off: return "Spatial Audio Off"
    }
  }

  init(title: String) {
    self = EnhancedAudioSpatialMode.allCases.first(where: { $0.title == title }) ?? .automatic
  }
}

enum EnhancedAudioEQ {
  enum Mode: Int, CaseIterable {
    case graphic = 0
    case parametric = 1

    var title: String {
      switch self {
      case .graphic: return "EQ Mode Graphic"
      case .parametric: return "EQ Mode Parametric"
      }
    }

    init(title: String) {
      self = Mode.allCases.first(where: { $0.title == title }) ?? .graphic
    }
  }

  /// A filter as the renderer applies it and as the response curve draws it.
  struct Filter: Equatable {
    var kind: EnhancedAudioEQBand.Kind
    var frequency: Double
    var gain: Double
    var q: Double
  }

  struct ImportedProfile: Equatable {
    var preamp: Double
    var bands: [EnhancedAudioEQBand]
    // Filter lines of a type this equalizer does not have.
    var skippedLines: Int
  }

  /// kEnhancedEQMaxBands in Connection.m.
  static let maxBands = 32
  static let preampRange: ClosedRange<Double> = -24...12
  /// Every audio stream is 48 kHz.
  static let sampleRate = 48000.0
  /// Width of one fixed band, in octaves.
  static let graphicBandwidth = 0.7

  /// Q of a filter the equalizer unit was given this bandwidth for. The unit pre-warps the
  /// bandwidth, so the same width is a lower Q towards the top of the spectrum.
  static func q(forBandwidth octaves: Double, frequency: Double) -> Double {
    let w0 = 2 * Double.pi * frequency / sampleRate
    return 1 / (2 * sinh(log(2.0) / 2 * octaves * w0 / sin(w0)))
  }

  static func graphicFilters(frequencies: [Double], gains: [Double]) -> [Filter] {
    frequencies.enumerated().map { index, frequency in
      Filter(
        kind: .peak, frequency: frequency,
        gain: gains.indices.contains(index) ? gains[index] : 0,
        q: q(forBandwidth: graphicBandwidth, frequency: frequency))
    }
  }

  static func parametricFilters(_ bands: [EnhancedAudioEQBand]) -> [Filter] {
    bands.filter(\.enabled).prefix(maxBands).map {
      Filter(kind: $0.kind, frequency: $0.frequency, gain: $0.kind.usesGain ? $0.gain : 0, q: $0.q)
    }
  }

  static func starterBands() -> [EnhancedAudioEQBand] {
    [
      EnhancedAudioEQBand(kind: .lowShelf, frequency: 105),
      EnhancedAudioEQBand(kind: .peak, frequency: 250, q: 1),
      EnhancedAudioEQBand(kind: .peak, frequency: 1000, q: 1),
      EnhancedAudioEQBand(kind: .peak, frequency: 4000, q: 1),
      EnhancedAudioEQBand(kind: .highShelf, frequency: 10000),
    ]
  }

  // MARK: Response

  /// Gain of one filter at a frequency, in dB. These are the audio EQ cookbook biquads, which
  /// is what the equalizer unit implements (measured within 0.02 dB for all five kinds).
  static func response(of filter: Filter, at frequency: Double) -> Double {
    let a = pow(10, filter.gain / 40)
    let w0 = 2 * Double.pi * min(filter.frequency, sampleRate * 0.45) / sampleRate
    let cosw0 = cos(w0)
    let alpha = sin(w0) / (2 * max(filter.q, 0.01))
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a0 = 1.0, a1 = 0.0, a2 = 0.0
    switch filter.kind {
    case .peak:
      b0 = 1 + alpha * a
      b1 = -2 * cosw0
      b2 = 1 - alpha * a
      a0 = 1 + alpha / a
      a1 = -2 * cosw0
      a2 = 1 - alpha / a
    case .lowShelf:
      let k = 2 * a.squareRoot() * alpha
      b0 = a * ((a + 1) - (a - 1) * cosw0 + k)
      b1 = 2 * a * ((a - 1) - (a + 1) * cosw0)
      b2 = a * ((a + 1) - (a - 1) * cosw0 - k)
      a0 = (a + 1) + (a - 1) * cosw0 + k
      a1 = -2 * ((a - 1) + (a + 1) * cosw0)
      a2 = (a + 1) + (a - 1) * cosw0 - k
    case .highShelf:
      let k = 2 * a.squareRoot() * alpha
      b0 = a * ((a + 1) + (a - 1) * cosw0 + k)
      b1 = -2 * a * ((a - 1) + (a + 1) * cosw0)
      b2 = a * ((a + 1) + (a - 1) * cosw0 - k)
      a0 = (a + 1) - (a - 1) * cosw0 + k
      a1 = 2 * ((a - 1) - (a + 1) * cosw0)
      a2 = (a + 1) - (a - 1) * cosw0 - k
    case .lowPass:
      b0 = (1 - cosw0) / 2
      b1 = 1 - cosw0
      b2 = (1 - cosw0) / 2
      a0 = 1 + alpha
      a1 = -2 * cosw0
      a2 = 1 - alpha
    case .highPass:
      b0 = (1 + cosw0) / 2
      b1 = -(1 + cosw0)
      b2 = (1 + cosw0) / 2
      a0 = 1 + alpha
      a1 = -2 * cosw0
      a2 = 1 - alpha
    }
    let w = 2 * Double.pi * frequency / sampleRate
    let c1 = cos(w), s1 = -sin(w), c2 = cos(2 * w), s2 = -sin(2 * w)
    let numeratorReal = b0 + b1 * c1 + b2 * c2
    let numeratorImaginary = b1 * s1 + b2 * s2
    let denominatorReal = a0 + a1 * c1 + a2 * c2
    let denominatorImaginary = a1 * s1 + a2 * s2
    let numerator = numeratorReal * numeratorReal + numeratorImaginary * numeratorImaginary
    let denominator =
      denominatorReal * denominatorReal + denominatorImaginary * denominatorImaginary
    return 10 * log10(max(numerator, 1e-24) / max(denominator, 1e-24))
  }

  static func response(of filters: [Filter], at frequency: Double) -> Double {
    filters.reduce(0) { $0 + response(of: $1, at: frequency) }
  }

  // MARK: Presets by kind of device

  /// A preset that is not for one model but for a kind of speaker or a way of listening.
  /// These are written for this app from what such devices usually need. They are a starting
  /// point, not a measurement. Each preamp takes back the highest point of its curve.
  struct GeneralPreset: Identifiable {
    let id: String
    let nameKey: String
    let detailKey: String
    let preamp: Double
    let bands: [EnhancedAudioEQBand]

    init(id: String, preamp: Double, bands: [EnhancedAudioEQBand]) {
      self.init(
        id: id, nameKey: "EQ General " + id, detailKey: "EQ General " + id + " detail",
        preamp: preamp, bands: bands)
    }

    init(id: String, nameKey: String, detailKey: String, preamp: Double, bands: [EnhancedAudioEQBand]) {
      self.id = id
      self.nameKey = nameKey
      self.detailKey = detailKey
      self.preamp = preamp
      self.bands = bands
    }

    var profile: ImportedProfile {
      // Fresh ids every time: a preset applied twice must not share bands.
      ImportedProfile(
        preamp: preamp,
        bands: bands.map {
          EnhancedAudioEQBand(kind: $0.kind, frequency: $0.frequency, gain: $0.gain, q: $0.q)
        }, skippedLines: 0)
    }
  }

  private static func band(
    _ kind: EnhancedAudioEQBand.Kind, _ frequency: Double, _ gain: Double = 0, q: Double = 0.7
  ) -> EnhancedAudioEQBand {
    EnhancedAudioEQBand(kind: kind, frequency: frequency, gain: gain, q: q)
  }

  /// By kind of device.
  static let devicePresets: [GeneralPreset] = [
    // Two small boxes on a desk: little bass, a boxy lower midrange, some edge up high.
    GeneralPreset(
      id: "Small Desktop Speakers", preamp: -3,
      bands: [
        band(.highPass, 45), band(.lowShelf, 120, 4), band(.peak, 250, -2, q: 1.2),
        band(.peak, 3000, -1.5, q: 1.5), band(.highShelf, 10000, 1.5),
      ]),
    // Satellites with a subwoofer: a boomy subwoofer, a gap where it hands over, bright satellites.
    GeneralPreset(
      id: "2.1 Speakers", preamp: -2.5,
      bands: [
        band(.peak, 80, -3, q: 1), band(.peak, 220, 2.5, q: 1), band(.peak, 5000, -2, q: 2),
        band(.highShelf, 10000, 1.5),
      ]),
    // Larger speakers on a desk or near a wall: the surface and the room pile up the upper bass.
    GeneralPreset(
      id: "Bookshelf Speakers", preamp: -1,
      bands: [
        band(.peak, 120, -3, q: 1.4), band(.peak, 200, -1.5, q: 1.5), band(.highShelf, 10000, 1),
      ]),
    // Flat panel speakers: thin, voices buried, and no deep bass to boost.
    GeneralPreset(
      id: "TV Speakers", preamp: -3,
      bands: [
        band(.highPass, 70), band(.lowShelf, 150, 3), band(.peak, 400, -2, q: 1),
        band(.peak, 2500, 2.5, q: 1), band(.peak, 7000, -1.5, q: 2),
      ]),
    GeneralPreset(
      id: "Laptop Speakers", preamp: -2,
      bands: [
        band(.highPass, 100), band(.lowShelf, 200, 4), band(.peak, 500, -2.5, q: 1),
        band(.peak, 3500, -2, q: 1.5), band(.highShelf, 9000, 2),
      ]),
  ]

  /// By what one wants to hear, next to the tonal curves the app always had (see
  /// SettingsModel.soundEQPresets).
  static let usagePresets: [GeneralPreset] = [
    // At low volume the ear loses bass and treble first.
    GeneralPreset(
      id: "Night Listening", preamp: -5,
      bands: [band(.lowShelf, 100, 5), band(.peak, 3000, -1, q: 1), band(.highShelf, 8000, 3)]),
    GeneralPreset(
      id: "Softer Treble", preamp: 0,
      bands: [band(.peak, 3500, -1.5, q: 1.2), band(.highShelf, 6000, -3)]),
  ]

  /// The preamp that takes back the highest point of a curve.
  static func preamp(for bands: [EnhancedAudioEQBand]) -> Double {
    let filters = parametricFilters(bands)
    var peak = 0.0
    for step in 0...160 {
      peak = max(peak, response(of: filters, at: 20 * pow(1000, Double(step) / 160)))
    }
    return -(peak * 10).rounded() / 10
  }

  // MARK: Export

  /// The text that parseParametricText reads back, which is also what Equalizer APO and the
  /// apps that take AutoEq results accept.
  static func parametricText(preamp: Double, bands: [EnhancedAudioEQBand]) -> String {
    func number(_ value: Double, _ digits: Int) -> String {
      var text = String(format: "%.\(digits)f", value)
      if text.contains(".") {
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
      }
      return text == "-0" ? "0" : text
    }
    var lines = ["Preamp: \(number(preamp, 1)) dB"]
    for (index, band) in bands.enumerated() {
      let state = band.enabled ? "ON" : "OFF"
      let frequency = number(band.frequency, 1)
      let q = String(format: "%.2f", band.q)
      let head = "Filter \(index + 1): \(state)"
      switch band.kind {
      case .peak:
        lines.append("\(head) PK Fc \(frequency) Hz Gain \(number(band.gain, 1)) dB Q \(q)")
      case .lowShelf:
        lines.append("\(head) LSC Fc \(frequency) Hz Gain \(number(band.gain, 1)) dB Q \(q)")
      case .highShelf:
        lines.append("\(head) HSC Fc \(frequency) Hz Gain \(number(band.gain, 1)) dB Q \(q)")
      case .lowPass:
        lines.append("\(head) LPQ Fc \(frequency) Hz Q \(q)")
      case .highPass:
        lines.append("\(head) HPQ Fc \(frequency) Hz Q \(q)")
      }
    }
    return lines.joined(separator: "\n") + "\n"
  }

  // MARK: Import

  /// Reads the parametric text that AutoEq, Squiglink and Equalizer APO write:
  ///
  ///     Preamp: -6.2 dB
  ///     Filter 1: ON LSC Fc 105 Hz Gain 5.6 dB Q 0.70
  ///     Filter 2: ON PK Fc 189 Hz Gain -2.9 dB Q 0.58
  ///
  /// Lines that are neither are skipped, so the files of spinorama.org (speakers), which
  /// begin with a few lines of description, read the same way.
  ///
  /// Returns nil when no line is a filter this equalizer has.
  static func parseParametricText(_ text: String) -> ImportedProfile? {
    // With an optional sign either way: some tools write "Gain +2.59 dB".
    let number = #"([-+]?\d+(?:[.,]\d+)?)"#
    let preampPattern = try? NSRegularExpression(
      pattern: #"^\s*Preamp\s*:\s*"# + number + #"\s*dB"#, options: [.caseInsensitive])
    let filterPattern = try? NSRegularExpression(
      pattern: #"^\s*Filter\s*\d*\s*:\s*(ON|OFF)\s+([A-Za-z]+)"#, options: [.caseInsensitive])
    let frequencyPattern = try? NSRegularExpression(
      pattern: #"\bFc\s+"# + number + #"\s*Hz"#, options: [.caseInsensitive])
    let gainPattern = try? NSRegularExpression(
      pattern: #"\bGain\s+"# + number + #"\s*dB"#, options: [.caseInsensitive])
    let qPattern = try? NSRegularExpression(
      pattern: #"\bQ\s+"# + number, options: [.caseInsensitive])

    func capture(_ pattern: NSRegularExpression?, _ line: String, _ group: Int = 1) -> String? {
      let range = NSRange(line.startIndex..., in: line)
      guard let match = pattern?.firstMatch(in: line, range: range),
        match.numberOfRanges > group,
        let captured = Range(match.range(at: group), in: line)
      else { return nil }
      return String(line[captured])
    }
    func double(_ string: String?) -> Double? {
      string.flatMap { Double($0.replacingOccurrences(of: ",", with: ".")) }
    }

    var preamp = 0.0
    var bands: [EnhancedAudioEQBand] = []
    var skipped = 0
    for rawLine in text.components(separatedBy: .newlines) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if let value = double(capture(preampPattern, line)) {
        preamp = value
        continue
      }
      guard let state = capture(filterPattern, line, 1),
        let type = capture(filterPattern, line, 2)?.uppercased()
      else { continue }

      let kind: EnhancedAudioEQBand.Kind
      switch type {
      case "PK", "PEQ", "PEAK": kind = .peak
      case "LSC", "LS", "LSQ": kind = .lowShelf
      case "HSC", "HS", "HSQ": kind = .highShelf
      case "LP", "LPQ": kind = .lowPass
      case "HP", "HPQ": kind = .highPass
      default:
        skipped += 1
        continue
      }
      guard let frequency = double(capture(frequencyPattern, line)), frequency > 0 else {
        skipped += 1
        continue
      }
      guard bands.count < maxBands else {
        skipped += 1
        continue
      }
      bands.append(
        EnhancedAudioEQBand(
          kind: kind, frequency: frequency,
          gain: double(capture(gainPattern, line)) ?? 0,
          q: double(capture(qPattern, line)) ?? EnhancedAudioEQBand.defaultQ,
          enabled: state.uppercased() == "ON"))
    }
    guard !bands.isEmpty else { return nil }
    return ImportedProfile(
      preamp: EnhancedAudioEQBand.clamp(preamp, to: preampRange), bands: bands,
      skippedLines: skipped)
  }
}
