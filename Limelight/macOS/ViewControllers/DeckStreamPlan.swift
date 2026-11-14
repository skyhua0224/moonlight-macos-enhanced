//
//  DeckStreamPlan.swift
//  What the next stream of a computer would be, from the settings that apply to it: resolution, frame rate,
//  and the codec and HDR it would really get. The status line of the host page says this instead of listing
//  what the host can do. The codec shown is the one the user chose, narrowed to what the host supports and
//  this Mac can decode; it is only written when it differs from the choice or needs software decoding.
//  No "may stutter" warning is made here: the risk assessor was too eager (2K120 and everything else was
//  flagged), so the host page shows none. StreamRiskAssessor itself is untouched and still serves the stream settings.
//

import AppKit
import SwiftUI
import VideoToolbox

struct DeckStreamPlan {
  var width = 0
  var height = 0
  var fps = 0
  /// Only when the codec that will be used is not the plain choice: "AV1 → H.265（主机不支持 AV1）", "AV1 · 软件解码".
  var codecNote: String?
  /// "HDR" (on and possible), "HDR 不可用" (on, not possible), nil (off).
  var hdrNote: String?

  var summary: String {
    var parts: [String] = []
    if width > 0 { parts.append("\(width)×\(height)") }
    if fps > 0 { parts.append(DLf("deck.plan.fps", fps)) }
    if let codecNote { parts.append(codecNote) }
    if let hdrNote { parts.append(hdrNote) }
    return parts.joined(separator: " · ")
  }

  private static let lock = NSLock()
  private static var cache: [String: (when: Date, plan: DeckStreamPlan)] = [:]

  /// Cached for a couple of seconds per computer and path: the page asks on every redraw.
  static func plan(for host: DeckHost) -> DeckStreamPlan {
    let key = "\(host.id)|\(host.address ?? "")|\((host.rtt ?? -1) / 10)|\(host.codecs.joined())|\(host.hdr)"
    lock.lock()
    if let hit = cache[key], Date().timeIntervalSince(hit.when) < 2 { lock.unlock(); return hit.plan }
    lock.unlock()
    let fresh = compute(host)
    lock.lock(); cache[key] = (Date(), fresh); lock.unlock()
    return fresh
  }

  private static func compute(_ host: DeckHost) -> DeckStreamPlan {
    var plan = DeckStreamPlan()
    guard let settings = Settings.getSettings(for: host.id) else { return plan }

    // resolution and frame rate: the screen's own when the setting follows the display
    let screen = StreamScreens.current()
    var size = settings.resolution
    if settings.matchDisplayResolution == true || size == SettingsModel.matchDisplayResolutionSentinel {
      size = screen?.fullPixels ?? NSScreen.main.map { CGSize(width: $0.frame.width * $0.backingScaleFactor, height: $0.frame.height * $0.backingScaleFactor) } ?? CGSize(width: 1920, height: 1080)
    } else if size == .zero, let custom = settings.customResolution, custom.width > 0 {
      size = custom
    }
    plan.width = Int(size.width)
    plan.height = Int(size.height)
    var fps = settings.fps
    if fps == StreamResolution.matchDisplayFps { fps = min(240, max(30, screen?.maxRefreshHz ?? 60)) }
    else if fps == 0, let custom = settings.customFps, custom > 0 { fps = Int(custom) }
    plan.fps = fps

    // codec: the choice, the host's bits, this Mac's decoder
    let names = ["H.264", "H.265", "AV1"]
    let choice = min(max(settings.codec, 0), 2)
    let hostHEVC = host.codecs.contains("HEVC")
    let hostAV1 = host.codecs.contains("AV1")
    let macHEVC = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
    let macAV1 = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
    var used = choice
    var why = ""
    if used == 2 && !hostAV1 {
      used = hostHEVC && macHEVC ? 1 : 0
      why = DLf("deck.plan.hostNo", names[2])
    }
    if used == 1 && !hostHEVC {
      used = 0
      if why.isEmpty { why = DLf("deck.plan.hostNo", names[1]) }
    } else if used == 1 && !macHEVC {
      used = 0
      if why.isEmpty { why = DLf("deck.plan.macNo", names[1]) }
    }
    if used != choice {
      plan.codecNote = "\(names[choice]) → \(names[used])（\(why)）"
    } else if used == 2 && !macAV1 {
      plan.codecNote = DLf("deck.plan.software", names[2])
    }

    // HDR: asked for, the host and the decoder both able
    if settings.hdr {
      let able = used != 0 && host.hdr
      plan.hdrNote = able ? "HDR" : DL("deck.plan.hdrNo")
    }

    return plan
  }
}
