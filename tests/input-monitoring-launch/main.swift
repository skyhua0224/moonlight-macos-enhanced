import Foundation

var failures = 0

func check(
  _ name: String,
  _ expected: InputMonitoringLaunchAction,
  usesCoreHID: Bool = true,
  coreHIDSupported: Bool = true,
  access: InputMonitoringLaunchAccess,
  everGranted: Bool = false,
  promptedVersion: String? = nil,
  currentVersion: String = "1.3.9 (1700)"
) {
  let actual = InputMonitoringLaunchRules.action(
    usesCoreHID: usesCoreHID,
    coreHIDSupported: coreHIDSupported,
    access: access,
    everGranted: everGranted,
    promptedVersion: promptedVersion,
    currentVersion: currentVersion)
  if actual != expected {
    failures += 1
    print("FAIL \(name): expected \(expected), got \(actual)")
  } else {
    print("ok   \(name)")
  }
}

check("granted: no prompt", .nothing, access: .granted)
check("never asked: ask the system", .requestAccess, access: .unknown)
check("denied: alert", .showAlert, access: .denied)
check("stale grant, system has no answer: alert, the dialog would not appear", .showAlert, access: .unknown, everGranted: true)
check("stale grant, denied: alert", .showAlert, access: .denied, everGranted: true)
check("no CoreHID in any profile: not disturbed", .nothing, usesCoreHID: false, access: .denied)
check("no CoreHID, never asked: not disturbed", .nothing, usesCoreHID: false, access: .unknown)
check("macOS without CoreHID: not disturbed", .nothing, coreHIDSupported: false, access: .denied)
check("Later on this build: no second alert", .nothing, access: .denied, promptedVersion: "1.3.9 (1700)")
check("asked on this build: no second request", .nothing, access: .unknown, promptedVersion: "1.3.9 (1700)")
check("Later on an older build: alert again", .showAlert, access: .denied, promptedVersion: "1.3.9 (1665)")
check("granted on a build that was dismissed: nothing", .nothing, access: .granted, promptedVersion: "1.3.9 (1700)")

if failures > 0 {
  print("\(failures) failed")
  exit(1)
}
print("all passed")
