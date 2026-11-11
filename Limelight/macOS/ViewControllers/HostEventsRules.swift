//
//  HostEventsRules.swift
//  What the discovery worker decides about Foundation Sunshine's events long-poll (FsCapabilityVersion >= 2, "events" in
//  FsFeatures, /serverinfo?fsWait=<seq>). Foundation only, so tests/host-events compiles it on its own with fixtures of a
//  capability 2 host and a capability 1 host.
//
//  A current host (FsCapabilityVersion 1) sends none of this; the client reads it for the host that will. A host at
//  capability 1, a host that lists no "events" feature and a host that ignores fsWait must all end on the same quiet refresh.
//

import Foundation

@objc(MLHostEventsAnswer)
final class HostEventsAnswer: NSObject {
  /// The answer was a valid serverinfo of this host.
  @objc let accepted: Bool
  /// The event counter moved: the answer is news (the worker reads the host into its model and polls again).
  @objc let changed: Bool
  /// The counter to ask after next time.
  @objc let nextSeq: Int
  /// Whether the next round may long-poll again; false = back to the quiet refresh.
  @objc let eventsStillEnabled: Bool
  init(accepted: Bool, changed: Bool, nextSeq: Int, eventsStillEnabled: Bool) {
    self.accepted = accepted; self.changed = changed; self.nextSeq = nextSeq; self.eventsStillEnabled = eventsStillEnabled
  }
}

@objc(MLHostEventsRules)
final class HostEventsRules: NSObject {
  /// A wait that is answered sooner than this did not wait: the host ignored fsWait (or failed at once).
  @objc static let minimumRealWait: Double = 1.0
  /// Seconds between rounds of an online host: the long-poll re-arms at once, a host without events is asked on a quiet timer.
  @objc static let eventRoundInterval: Double = 1.0
  @objc static let quietRefreshInterval: Double = 30.0

  /// `integerValue` of the NSString: "2" -> 2, "" -> 0, "x" -> 0, "2abc" -> 2 (what the Objective-C worker always did).
  @objc static func integer(_ text: String?) -> Int { ((text ?? "") as NSString).integerValue }

  /// The host offers the events long-poll: capability 2 or newer AND "events" among its features.
  @objc static func eventsEnabled(capability: String?, features: String?) -> Bool {
    integer(capability) >= 2 && (features ?? "").range(of: "events", options: .caseInsensitive) != nil
  }

  @objc static func refreshInterval(eventsEnabled: Bool) -> Double { eventsEnabled ? eventRoundInterval : quietRefreshInterval }

  /// What to do with the answer of one long-poll.
  /// - valid: the answer is a serverinfo of this host.
  /// - previousSeq: the counter asked after.
  /// - answeredSeq: FsEventSeq of the answer (0 when absent).
  /// - elapsed: seconds the request took.
  @objc static func answer(valid: Bool, previousSeq: Int, answeredSeq: Int, elapsed: Double) -> HostEventsAnswer {
    guard valid else {
      // a failure within a second is a host that does not know the request; a timeout or a dropped link is not
      return HostEventsAnswer(accepted: false, changed: false, nextSeq: previousSeq, eventsStillEnabled: elapsed >= minimumRealWait)
    }
    let changed = answeredSeq != previousSeq && answeredSeq > 0
    let next = answeredSeq > 0 ? answeredSeq : previousSeq
    // unchanged and instant: the host answered at once, whatever it advertises
    let still = changed || elapsed >= minimumRealWait
    return HostEventsAnswer(accepted: true, changed: changed, nextSeq: next, eventsStillEnabled: still)
  }
}
