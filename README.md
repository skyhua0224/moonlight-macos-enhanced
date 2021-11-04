# Moonlight macOS

Moonlight macOS is a native macOS client for NVIDIA's GameStream. It allows you to stream games from your desktop computer to your Mac.

![](readme-assets/images/app-list-and-game.jpg)

## Features

- Apple Silicon support
- Up to 4K streaming at 60fps
- Native AppKit app
- Hardware decoding
- HEVC and H.264
- HDR
- Keyboard and mouse support
- Custom HID driver to support popular controllers on older macOS versions that offer limited or no native gamepad (MFi) support.
- Local network host PC detection
- Adding hosts manually
- Wake-on-LAN support
- Dark Mode
- Support for older macOS versions, back to 10.14 (Mojave)

## Screenshots

<img src="readme-assets/images/host-list.png" width="600">

<img src="readme-assets/images/app-list.png" width="600">

<img src="readme-assets/images/preferences.png" width="500">

## Notes

- To release the mouse cursor from the stream, press both left and right `Option` keys at the same time.
- To quit an app and disconnect from stream in one keystroke press `Control-Shift-W`.
- To just disconnect from the stream (leaving the app running) press `Control-Option-W`.
- To quit apps from the apps grid, right-click on the running app and choose *Quit.*
- You can increase/decrease the app grid size with `Command +` and `Command -`.

## Known Issues

- At the moment, the HID driver doesn’t support multiple gamepads at once.
- Only Bluetooth Xbox controllers are supported.
- Xbox controllers don’t support wired mode.
- DualSense (PS5) rumble is different intensity in wired vs wireless modes.
- Switch Pro controllers are only supported in wireless mode.
- There is a bug with some PlayStation controllers where in first-person-shooter games the camera overshoots at times. This doesn’t happen to all my PlayStation controllers. I currently don’t know how to fix this. If this happens to you, change *Controller Driver to* MFi in Moonlight's Preferences.
- Controller rumble sometimes stops working. Rebooting your PC fixes this. This seems to be an NVIDIA issue.
- Side mouse buttons don't work.
- I haven’t added support for higher refresh-rates than 60Hz, yet. However, I don’t think it will be that hard.

## Build instructions

1. Run the following line in your Terminal:

```Bash
git clone --recursive https://github.com/MichaelMKenny/moonlight-macos.git
```

2. Open `Moonlight.xcodeproj`  in Xcode.
3. Open the Project file (the first item in the sidebar, labelled “Moonlight”).
4. Go to the *Signing & Capabilities* tab.
5. Change the *Team* to your own team (probably your name).
6. Change the *Bundle Identifier* from `com.coofdylabs.MoonlightMac`  to start with your own name or domain.
7. Select the Moonlight target in Xcode’s toolbar, then “My Mac” and press `Command-R`, to build and run.

## Acknowledgements

- This project is a fork of the main [moonlight-ios project](https://github.com/moonlight-stream/moonlight-ios), by the [Moonlight Stream team](https://github.com/moonlight-stream), made to work on macOS and use a Native AppKit UI. This is not a Mac Catalyst app.
- In addition, this project also uses the following Open-Source projects:
   - [MASPreferences](https://github.com/shpakovski/MASPreferences) to help handle preference-panes in preferences.
   - [KPCScaleToFillNSImageView](https://github.com/onekiloparsec/KPCScaleToFillNSImageView) for scaling app artwork nicely. NSImageView doesn't have a scale-fill content mode like iOS.

