# TouchM

An all-in-one touch-screen driver for macOS: multi-touch input, calibration, a gesture engine with
per-app rules (Commander), a screen magnifier, annotation tools, and display controls
(brightness, contrast, resolution, rotation) in a menu bar app.

## Compatibility
**Tested only with one device**: a SiS HID Touch Controller (USB `0457:0819`) built into the **ZEUSLAP P16KT** portable touch monitor
(macOS lists it as “ZEUSLAP TYPEC”), on a Mac with an Apple M4 chip. Nothing else has been verified.

- **Touch input** is written for that controller's HID report format (multi-touch report `0x91`, 0–4095 coordinates) and
  matches any device with USB vendor ID `0x0457`. Panels from other vendors, or other SiS firmware, will probably not work
  without changes to `Sources/TouchMCore/Contact.swift` and `TouchDevice.swift`. `hidprobe` prints what a panel reports.
- **Brightness / contrast (DDC/CI), resolution and rotation** talk to the display itself, not the touch panel, and are not
  tied to one model. They have only been tried on the monitor above, and DDC support varies by monitor; software dimming is the fallback.
- Reports and pull requests for other panels are welcome.

## Features
- Multi-touch panel access through IOHIDManager (no kernel or driver extension).
- Click, drag, long-press right-click, scrolling with momentum, edge swipes, N-finger swipes, pinch and rotate.
- Commander: rules per application and per UI element (web content, scroll areas, buttons…).
- 4/9/25-point calibration, display-rotation aware.
- Smart magnifier, annotation overlay, touch test.
- Brightness and contrast over DDC/CI, with software dimming as a fallback; resolution (HiDPI) and rotation switching.
- Interface in English and Korean (follows the system language).

## Install
Download the DMG from [Releases](https://github.com/designloves2/TouchM/releases), drag TouchM to Applications.
The app is ad-hoc signed, not notarized: on first launch right-click it → Open (or run `xattr -dr com.apple.quarantine /Applications/TouchM.app`).

## Build from source
```bash
./make_app.sh        # builds build/TouchM.app
./install.sh         # copies it to /Applications and launches it
./make_dmg.sh 0.1.0  # builds build/TouchM-0.1.0.dmg
```
Grant **Accessibility** and **Input Monitoring** (and **Screen Recording** for the magnifier) when asked.
Any other vendor driver that claims the panel's USB interfaces must be switched off first.

## Known issues and limitations
- **Not notarized.** The app is only ad-hoc signed (no Apple Developer ID), so macOS shows an "unidentified developer" warning on first launch. Right-click → Open, or remove the quarantine flag as described above.
- **One tested device.** See Compatibility; other touch panels and monitors are unverified.
- **Permissions.** Accessibility and Input Monitoring are required, and Screen Recording for the magnifier. After rebuilding the app from source you may have to re-grant them.
- **Screen rotation.** Touch positions follow the display rotation, including after calibration. Gesture directions are mirrored automatically only at 180°; at 90° and 270° they follow the screen as drawn.
- **Brightness over DDC/CI** depends on the monitor. Some monitors need 1–3 seconds to apply a change, ignore commands while busy, or show a different number in their own menu. Software dimming is the fallback.
- **On-screen keyboard** uses the macOS Keyboard Viewer through the menu bar's Input menu, so that menu must be shown in the menu bar (System Settings → Keyboard → Text Input).
- **Private system calls.** Screen rotation and the Keyboard Viewer toggle rely on undocumented macOS interfaces and may break with a macOS update.
- This is a first release; several features were written for one machine and have had little testing. Please open an issue with the log (`~/Library/Application Support/TouchM/debug.log`).

## Layout
- `Sources/TouchMCore` – device access, parser, mapper/calibration, gesture engine, Commander, preset importer
- `Sources/TouchM` – the menu bar app (SwiftUI/AppKit)
- `Sources/touchm-cli` – command-line harness (`--simulate` runs the gesture scenarios)
- `Sources/hidprobe` – read-only HID probe
- `tools` – icon generator and the Korean string table

## License
MIT — see [LICENSE](LICENSE). Provided as is, without warranty.
