# Caps Lock regression checks

Run `python3 tests/capslock/run.py` on macOS with Xcode or Command Line Tools.

The tests execute the production AppKit event normalizer and Caps Lock routing
branch with isolated output. They cover lock-on and lock-off transitions,
duplicate edges, keyboard capture, recapture, input-method notification, and
unrelated modifiers. The production recorder callback and handler are executed
to verify idle event identity, trigger/output recording, release, ordinary keys,
and cancellation. The supported display label is checked separately. No events are
posted to macOS or a remote host.

The tests also execute the direct capture's decision logic with simulated
keyboard edges. They cover foreground ownership, repeat and unmatched edges,
device removal, balanced teardown, AppKit fallback when Input Monitoring
is unavailable, and Command held while a raw Caps Lock press and release go
to the host.

For the AppKit lock-state path, a Release build passed with Xcode 27.1 on Apple Silicon. A user verified that
firmware-layer Fn+Tab mapped to standard Caps Lock works in a real streaming
session after this fix. Intel hardware has not been tested.
