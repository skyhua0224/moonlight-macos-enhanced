# Settings Analysis: Moonlight macOS vs Reference (Qt)

This document outlines the features and settings present in the reference implementation (Moonlight Qt) that are currently missing or implemented differently in the Moonlight macOS client.

## Host Settings

- **Custom Screen Mode**: The reference client allows changing host display topology (e.g., "Activate the display automatically", "Deactivate other displays"). This is missing in macOS.
- **Quit App After Stream**: The reference client has an option to automatically quit the host app when the stream ends.

## Input Settings

- **Absolute Mouse Mode**: "Optimize mouse for remote desktop" is missing. This is crucial for remote desktop usage.
- **Show Local Cursor**: Option to keep the local cursor visible is missing.
- **Swap Win/Alt Keys**: Useful for Mac users connecting to Windows hosts to map Command to Win key correctly.
- **Reverse Scroll Direction**: Option to invert mouse scrolling.
- **Touchscreen Mode**: Option to use touchscreen as a trackpad or direct input.
- **Swap Mouse Buttons**: Option to swap left/right mouse buttons.

## Gamepad Settings

- **Gamepad Mouse Emulation**: Holding 'Start' to control mouse with gamepad is missing.
- **Background Input**: Processing gamepad input when the window is in the background.

## Video Settings

- **Video AI-Enhancement**: The reference client supports AI upscaling (if GPU supported).
- **Stream Resolution Scale**: Option to render at a percentage of the stream resolution.
- **Remote Resolution/FPS**: Options to request specific resolution/FPS from the host different from the stream.
- **Stretch Presentation**: "Ignore Aspect Ratio" option is missing.

## Audio Settings

- **Mute on Focus Loss**: Option to mute audio when the stream window loses focus.
- **Microphone Streaming**: Support for streaming the client microphone to the host.

## UI/Other

- **Connection/Configuration Warnings**: Options to hide warning overlays.
- **Discord Rich Presence**: Integration with Discord status.
- **Keep Display Awake**: Explicit option to prevent sleep (macOS client handles this internally during stream, but no toggle).
