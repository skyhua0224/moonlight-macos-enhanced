# Stream window cleanup regression checks

Run `python3 tests/window-cleanup/run.py` on macOS with Xcode or Command Line Tools.

The tests execute production close and presentation-observer cleanup methods,
fullscreen exit continuation, and fullscreen failure recovery against a small
Foundation window model. They verify ownership-cycle release, stale-entry
removal, a close continuation after network stop, unrelated/repeated
notifications, and restoring an interactive window if fullscreen exit fails.
These tests do not drive a real AppKit fullscreen transition.

A Release build passed with Xcode 27.1 on Apple Silicon. A user verified that a
real Desktop streaming session closes without leftover windows after this fix.
Intel hardware has not been tested.
