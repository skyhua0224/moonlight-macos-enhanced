import AVFoundation
import Accelerate
import Foundation

/// Live spectrum of what the audio enhancement plays, for the equalizer curve.
///
/// The settings pane asks for it while it shows the curve (`addViewer` / `removeViewer`); the
/// running stream then taps its own output and hands the buffers to `process(_:)`.
@objc(MLEnhancedAudioSpectrum)
final class EnhancedAudioSpectrum: NSObject, ObservableObject {
  @objc static let shared = EnhancedAudioSpectrum()
  @objc static let requestChangedNotification = "enhancedAudioSpectrumRequestChanged"

  static let bandCount = 64
  static let minFrequency = 20.0
  static let maxFrequency = 20000.0
  /// Level of an empty band, dB relative to full scale.
  static let floorLevel: Float = -100

  /// One level per band, dB relative to full scale; empty while nothing is measured.
  @Published private(set) var levels: [Float] = []

  // Main thread.
  private var viewers = 0
  // The settings window keeps its views while it is closed; nothing is measured for them then.
  private var windowVisible = true
  // Read by the stream (any thread).
  private let requestLock = NSLock()
  private var requested = false
  // Counts resets, so a measurement that was under way when one happened is not shown after it.
  private var epoch = 0

  // Tap thread only.
  private static let log2Size = vDSP_Length(12)
  private static let size = 1 << 12
  private let fftSetup = vDSP_create_fftsetup(EnhancedAudioSpectrum.log2Size, FFTRadix(kFFTRadix2))
  private var window = [Float](repeating: 0, count: EnhancedAudioSpectrum.size)
  private var history = [Float](repeating: 0, count: EnhancedAudioSpectrum.size)
  private var windowed = [Float](repeating: 0, count: EnhancedAudioSpectrum.size)
  private var real = [Float](repeating: 0, count: EnhancedAudioSpectrum.size / 2)
  private var imaginary = [Float](repeating: 0, count: EnhancedAudioSpectrum.size / 2)
  private var power = [Float](repeating: 0, count: EnhancedAudioSpectrum.size / 2)
  private var smoothed = [Float](
    repeating: EnhancedAudioSpectrum.floorLevel, count: EnhancedAudioSpectrum.bandCount)
  private var lastPublish = DispatchTime(uptimeNanoseconds: 0)

  private override init() {
    super.init()
    vDSP_hann_window(&window, vDSP_Length(Self.size), Int32(vDSP_HANN_DENORM))
  }

  /// Whether a view is showing the spectrum right now.
  @objc var isRequested: Bool {
    requestLock.lock()
    defer { requestLock.unlock() }
    return requested
  }

  func addViewer() {
    viewers += 1
    setRequested(viewers > 0 && windowVisible)
  }

  func removeViewer() {
    viewers = max(0, viewers - 1)
    setRequested(viewers > 0 && windowVisible)
  }

  func setWindowVisible(_ visible: Bool) {
    windowVisible = visible
    setRequested(viewers > 0 && windowVisible)
  }

  private func setRequested(_ value: Bool) {
    requestLock.lock()
    let changed = requested != value
    requested = value
    requestLock.unlock()
    guard changed else { return }
    if !value { levels = [] }
    NotificationCenter.default.post(
      name: Notification.Name(Self.requestChangedNotification), object: nil)
  }

  /// The stream stopped measuring (it ended, or its output is being rebuilt).
  @objc func reset() {
    requestLock.lock()
    epoch += 1
    requestLock.unlock()
    DispatchQueue.main.async { self.levels = [] }
  }

  private var currentEpoch: Int {
    requestLock.lock()
    defer { requestLock.unlock() }
    return epoch
  }

  static func frequency(ofBand index: Int) -> Double {
    minFrequency * pow(maxFrequency / minFrequency, (Double(index) + 0.5) / Double(bandCount))
  }

  /// Tap thread. Buffers arrive every 20 ms or so; each one moves a 4096 sample window on.
  @objc func process(_ buffer: AVAudioPCMBuffer) {
    guard let fftSetup, let channels = buffer.floatChannelData else { return }
    let startedIn = currentEpoch
    let frames = min(Int(buffer.frameLength), Self.size)
    guard frames > 0 else { return }
    let channelCount = Int(buffer.format.channelCount)
    let sampleRate = buffer.format.sampleRate
    let offset = Int(buffer.frameLength) - frames

    history.removeFirst(frames)
    if channelCount >= 2 {
      for frame in 0..<frames {
        history.append((channels[0][offset + frame] + channels[1][offset + frame]) * 0.5)
      }
    } else {
      for frame in 0..<frames { history.append(channels[0][offset + frame]) }
    }

    vDSP_vmul(history, 1, window, 1, &windowed, 1, vDSP_Length(Self.size))
    real.withUnsafeMutableBufferPointer { realPointer in
      imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
        var split = DSPSplitComplex(
          realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
        windowed.withUnsafeBufferPointer { input in
          input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: Self.size / 2) {
            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(Self.size / 2))
          }
        }
        vDSP_fft_zrip(fftSetup, &split, 1, Self.log2Size, FFTDirection(FFT_FORWARD))
        vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(Self.size / 2))
      }
    }

    // A sine of amplitude A through the window comes out as power (A * size / 2)^2.
    let reference = 20 * log10(2 / Float(Self.size))
    let binWidth = sampleRate / Double(Self.size)
    let ratio = pow(Self.maxFrequency / Self.minFrequency, 1 / Double(Self.bandCount))
    for band in 0..<Self.bandCount {
      let low = Self.minFrequency * pow(ratio, Double(band))
      let firstBin = max(1, Int((low / binWidth).rounded()))
      let lastBin = min(Self.size / 2 - 1, max(firstBin, Int((low * ratio / binWidth).rounded()) - 1))
      var peak: Float = 0
      if firstBin <= lastBin {
        for bin in firstBin...lastBin { peak = max(peak, power[bin]) }
      }
      let level = peak > 0 ? max(Self.floorLevel, 10 * log10(peak) + reference) : Self.floorLevel
      // Rises at once, falls slowly, so the display is readable.
      smoothed[band] = max(level, smoothed[band] - 1.5)
    }

    let now = DispatchTime.now()
    guard now.uptimeNanoseconds - lastPublish.uptimeNanoseconds >= 33_000_000 else { return }
    lastPublish = now
    let snapshot = smoothed
    DispatchQueue.main.async {
      guard self.isRequested, self.currentEpoch == startedIn else { return }
      self.levels = snapshot
    }
  }
}
