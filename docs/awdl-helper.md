# AWDL stability helper

While a stream runs, awdl0 (the interface AirDrop, Handoff and Sidecar use) is turned off, because its channel hopping
makes Wi-Fi streams stutter. On a MacBook measured on Wi-Fi, 15 of 100 gateway pings took more than 20 ms with AWDL on
(P99 79.5 ms), none with it off (P99 6.7 ms); the stream lost 3.4 % of its packets and 2 of 10 key frames arrived
incomplete with AWDL on, nothing with it off.

The setting is on by default. A value the user set is kept: only a missing value takes the default.

## Parts

| Part | Where | Job |
| --- | --- | --- |
| Rules | `Limelight/macOS/Helpers/AwdlHelperPolicy.swift` | default, when to ask, self-check, session and restore paths; Foundation only |
| Manager | `Limelight/macOS/Helpers/AwdlHelperManager.swift` | the real interface and helper behind the rules, install, status |
| Question | `Limelight/macOS/Helpers/AwdlHelperSetup.swift` | the explanation and the authorization, before a stream |
| Helper | `AwdlPrivilegedHelperMain.m`, `AwdlHoldLedger.m` | root launchd daemon: awdl0 down/up, takes awdl0 back when its client goes |
| Client | `AwdlAuthorizationHelper.m` | XPC calls to the helper |

## Authorization

1. The user starts a stream. Before the stream window opens, the app looks at the helper (no prompt).
2. Helper missing: a sheet on the host window explains in one sentence (awdl0 is turned off while streaming, which reduces
   Wi-Fi stutter, and restored afterwards; AirDrop and Handoff are unavailable meanwhile) and offers **Authorize** and
   **Not Now**. The same for a helper older than the app, once per app build (**Update**).
3. **Authorize**: one administrator dialog installs the helper (`/Library/PrivilegedHelperTools`, a LaunchDaemon in
   `/Library/LaunchDaemons`), then the self-check runs.
4. Whatever the answer (not now, cancelled, no administrator rights, a profile that forbids it, a failed install), the
   stream starts. The answer is remembered and the question does not come back; the settings page shows the state and a
   button (**Authorize**, **Update**, **Retry**). Turning the switch off and on again asks again.
5. Never during a stream: a session that finds no usable helper leaves awdl0 alone.

## Self-check

After an install, and on **Retry**: the helper answers over XPC, its interface version is the one the app needs, awdl0 is
turned down and seen down, then up and seen up. A failure sets the status to *Failed* with the reason. awdl0 is brought
back whatever happens in between.

## Versions

`MLAwdlPrivilegedHelperInterfaceVersion` (`AwdlPrivilegedHelperProtocol.h`) is raised with every change to the helper or
its interface; `AwdlHelperContract.interfaceVersion` (Swift) must be the same number, which `tests/awdl-helper-policy`
checks. A helper of an older build answers no version call: it is reported as outdated, and one authorization updates it.
A new app build with an unchanged helper asks for nothing.

## Giving awdl0 back

| Event | What restores awdl0 |
| --- | --- |
| Stream ends, window closes, connection fails | the session ends: release, then check awdl0 is up, else `ifconfig awdl0 up` through the helper |
| App quits | the same, on the quit notification |
| Crash, force quit, kill | the helper sees the XPC connection go and brings awdl0 up when the last holder is gone |
| Helper could not be reached | a marker file stays; the next launch, wake or stream start brings awdl0 up first |
| Sleep and wake | with no stream: the marker is honored; under a stream: awdl0 is turned off again |
| Reboot | the system starts with awdl0 up |

With a Sidecar display connected the stream leaves awdl0 alone. awdl0 that was down before the stream is not touched and
not brought up afterwards.

## SMAppService

Evaluated against Apple's documentation (ServiceManagement, `SMAppService`, `register()`, `SMJobBless`):

- `SMAppService.daemon(plistName:)` needs macOS 13; the app supports macOS 12.
- `register()` only registers: a LaunchDaemon does not start until an administrator approves it in System Settings
  (Login Items). The app cannot ask for a password and use the helper in one step, which the question before a stream and the
  self-check right after it depend on.
- `SMJobBless` is deprecated since macOS 13 and needs Xcode signing with a team identity; release builds are signed with
  a self-signed certificate (see `code-signing.md`).

The helper therefore stays a LaunchDaemon installed with one administrator dialog, on every macOS version. Moving to
`SMAppService` on macOS 13 and later would change the flow to "register, then the user approves in System Settings", and
would need a migration of the installed daemon (`launchctl bootout`, remove both files); that is not done here.
