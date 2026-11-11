import Foundation
var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
  if !ok { failures += 1 }
  print("\(ok ? "PASS" : "FAIL") \(name)\(ok ? "" : " — " + detail())")
}
typealias B = BandwidthProbeRules
func caps(_ json: String) -> NSDictionary { try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! NSDictionary }

// the real answer of a current host (src/nvhttp/network_probe.cpp): no ceiling stated
let today = caps(#"{"version":1,"features":["bandwidth-probe-v1"],"bandwidthProbe":{"version":1,"endpoint":"/api/network/probe","minBytes":262144,"maxBytes":4194304,"cooldownMs":10000}}"#)
check("host today states no ceiling", B.hostOfferedCeilingKbps(capabilities: today) == 0)
check("a ceiling inside bandwidthProbe is read", B.hostOfferedCeilingKbps(capabilities: caps(#"{"bandwidthProbe":{"maxBitrateKbps":2000000}}"#)) == 2_000_000)
check("a ceiling at the top is read", B.hostOfferedCeilingKbps(capabilities: caps(#"{"maxBitrateKbps":800000,"bandwidthProbe":{}}"#)) == 800_000)
check("the one inside bandwidthProbe wins", B.hostOfferedCeilingKbps(capabilities: caps(#"{"maxBitrateKbps":800000,"bandwidthProbe":{"maxBitrateKbps":900000}}"#)) == 900_000)
check("a numeric string is read", B.hostOfferedCeilingKbps(capabilities: caps(#"{"bandwidthProbe":{"maxBitrateKbps":"500000"}}"#)) == 500_000)
check("zero, negative, tiny, huge, NaN-like and wrong types are nothing",
      ["0", "-5", "100", "1e12", "\"x\"", "true", "null", "[1]", "{}"].allSatisfy { B.hostOfferedCeilingKbps(capabilities: caps("{\"bandwidthProbe\":{\"maxBitrateKbps\":\($0)}}")) == 0 })
check("no dictionary, empty dictionary, bandwidthProbe of the wrong type: nothing", B.hostOfferedCeilingKbps(capabilities: nil) == 0 && B.hostOfferedCeilingKbps(capabilities: caps("{}")) == 0 && B.hostOfferedCeilingKbps(capabilities: caps(#"{"bandwidthProbe":7}"#)) == 0)

check("setting: nothing stored (0) gives 150 Mbps", B.settingCeilingKbps(storedMbps: 0) == 150_000)
check("setting: 2500 is outside the range and gives the default", B.settingCeilingKbps(storedMbps: 2500) == 150_000)
check("setting: 9 is below the range and gives the default", B.settingCeilingKbps(storedMbps: 9) == 150_000)
check("setting: negative gives the default", B.settingCeilingKbps(storedMbps: -300) == 150_000)
check("setting: 10 and 1000 are accepted", B.settingCeilingKbps(storedMbps: 10) == 10_000 && B.settingCeilingKbps(storedMbps: 1000) == 1_000_000)
check("setting: 900 for a 10 GbE LAN", B.settingCeilingKbps(storedMbps: 900) == 900_000)

check("host ceiling wins over the setting", B.ceilingKbps(hostOfferedKbps: 2_000_000, storedMbps: 150) == 2_000_000)
check("no host ceiling: the setting", B.ceilingKbps(hostOfferedKbps: 0, storedMbps: 800) == 800_000)
check("no host ceiling, no setting: 150 Mbps as before", B.ceilingKbps(hostOfferedKbps: 0, storedMbps: 0) == 150_000)

// the measured throughputs
check("old behaviour kept at the default: gigabit LAN (940 Mbps) is held to 150", B.safeBitrateKbps(measuredMbps: 940, ceilingKbps: 150_000) == 150_000)
check("10 GbE LAN (9400 Mbps measured) with the default ceiling: 150", B.safeBitrateKbps(measuredMbps: 9400, ceilingKbps: B.ceilingKbps(hostOfferedKbps: 0, storedMbps: 0)) == 150_000)
check("10 GbE LAN with the setting at 1000: 1000 Mbps", B.safeBitrateKbps(measuredMbps: 9400, ceilingKbps: B.ceilingKbps(hostOfferedKbps: 0, storedMbps: 1000)) == 1_000_000)
check("gigabit LAN with the setting at 1000: 65 % of 940, in steps of 500 kbps", B.safeBitrateKbps(measuredMbps: 940, ceilingKbps: 1_000_000) == 611_000)
check("below the ceiling the measure decides: 100 Mbps link", B.safeBitrateKbps(measuredMbps: 100, ceilingKbps: 150_000) == 65_000)
check("a link too slow for one step gives 0 (no intervention)", B.safeBitrateKbps(measuredMbps: 0.5, ceilingKbps: 150_000) == 0)
check("bad measures give 0", B.safeBitrateKbps(measuredMbps: .nan, ceilingKbps: 150_000) == 0 && B.safeBitrateKbps(measuredMbps: -3, ceilingKbps: 150_000) == 0 && B.safeBitrateKbps(measuredMbps: .infinity, ceilingKbps: 150_000) == 0)
check("the result is always a whole number of steps", stride(from: 1.0, to: 3000.0, by: 7.3).allSatisfy { B.safeBitrateKbps(measuredMbps: $0, ceilingKbps: 1_000_000) % 500 == 0 })

// Foundation rule (gap 11): StreamManager now uses the same rule as DeckHost.isFoundation
typealias S = DeckHostSoftware
check("foundation: Fs capability 1", S.isFoundation(fsCapability: "1", vddCapability: nil))
check("foundation: Fs capability 2", S.isFoundation(fsCapability: "2", vddCapability: nil))
check("foundation: only the Vdd capability (a build before the Fs fields)", S.isFoundation(fsCapability: nil, vddCapability: "1"))
check("foundation: both", S.isFoundation(fsCapability: "1", vddCapability: "1"))
check("foundation: neither tag (plain Sunshine, GFE)", !S.isFoundation(fsCapability: nil, vddCapability: nil))
check("foundation: tags present but 0 do not count (the old stream rule counted a present Vdd tag)", !S.isFoundation(fsCapability: "0", vddCapability: "0") && !S.isFoundation(fsCapability: nil, vddCapability: "0"))
check("foundation: empty, spaces, garbage do not count", !S.isFoundation(fsCapability: "", vddCapability: " ") && !S.isFoundation(fsCapability: "x", vddCapability: "1.5") && !S.isFoundation(fsCapability: "-1", vddCapability: "-1"))
check("foundation: padded numbers do", S.isFoundation(fsCapability: " 2\n", vddCapability: nil))
check("foundation: the Int form agrees with the String form", S.isFoundation(fsCapability: 2, vddCapability: 0) == S.isFoundation(fsCapability: "2", vddCapability: "0") && S.isFoundation(fsCapability: 0, vddCapability: 0) == S.isFoundation(fsCapability: "0", vddCapability: "0"))
print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
