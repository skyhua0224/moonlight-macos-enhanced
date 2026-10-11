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

  init(
    eqEnabled: Bool = true, eqMode: Int = EnhancedAudioEQ.Mode.graphic.rawValue,
    eqPreamp: Double = 0, eqBands: [EnhancedAudioEQBand] = [], eqProfileName: String? = nil,
    spatialMode: Int = EnhancedAudioSpatialMode.automatic.rawValue
  ) {
    self.spatialMode = spatialMode
    self.eqEnabled = eqEnabled
    self.eqMode = eqMode
    self.eqPreamp = EnhancedAudioEQBand.clamp(eqPreamp, to: EnhancedAudioEQ.preampRange)
    self.eqBands = Array(eqBands.prefix(EnhancedAudioEQ.maxBands))
    self.eqProfileName = eqProfileName
  }

  private enum CodingKeys: String, CodingKey {
    case eqEnabled, eqMode, eqPreamp, eqBands, eqProfileName, spatialMode
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
      spatialMode: value(Int.self, .spatialMode) ?? EnhancedAudioSpatialMode.automatic.rawValue)
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

  // MARK: Import

  /// Reads the parametric text that AutoEq, Squiglink and Equalizer APO write:
  ///
  ///     Preamp: -6.2 dB
  ///     Filter 1: ON LSC Fc 105 Hz Gain 5.6 dB Q 0.70
  ///     Filter 2: ON PK Fc 189 Hz Gain -2.9 dB Q 0.58
  ///
  /// Returns nil when no line is a filter this equalizer has.
  static func parseParametricText(_ text: String) -> ImportedProfile? {
    let number = #"(-?\d+(?:[.,]\d+)?)"#
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
