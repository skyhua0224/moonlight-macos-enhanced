# Stream window cleanup regression checks

Run `python3 tests/window-cleanup/run.py` on macOS with Xcode or Command Line Tools.

The tests execute production close and presentation-observer cleanup methods,
fullscreen exit continuation, and fullscreen failure recovery against a small
Foundation window model with AppKit-compatible weak window-controller ownership.
They verify ownership-cycle release, stale-entry removal, a close continuation after network stop, unrelated/repeated
notifications, and restoring an interactive window if fullscreen exit fails.
The shared-input checks execute the production GCMouse registration and removal
methods on fake devices. They cover stale-owner cleanup, movement/buttons/scroll,
owned and repeated cleanup, driver refresh, and owner lifetime. The AWDL checks
execute production session methods with mocked interface operations. They cover
old/new owners with equal generation numbers, termination/deinit, repeated and
missing-owner cleanup, and disabled sessions. No input is sent to a host and no
network interface is changed. These tests do not drive a real AppKit fullscreen
transition or physical input devices.

A Release build passed with Xcode 27.1 on Apple Silicon. A user verified that a
real Desktop streaming session closes without leftover windows with the initial
cleanup fix. The ownership follow-ups are covered by the isolated checks above.
Intel hardware has not been tested.
