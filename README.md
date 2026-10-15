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

## Build and install
```bash
./make_app.sh        # builds build/TouchM.app
./install.sh         # copies it to /Applications and launches it
```
Grant **Accessibility** and **Input Monitoring** (and **Screen Recording** for the magnifier) when asked.
Any other vendor driver that claims the panel's USB interfaces must be switched off first.

## Layout
- `Sources/TouchMCore` – device access, parser, mapper/calibration, gesture engine, Commander, preset importer
- `Sources/TouchM` – the menu bar app (SwiftUI/AppKit)
- `Sources/touchm-cli` – command-line harness (`--simulate` runs the gesture scenarios)
- `Sources/hidprobe` – read-only HID probe
- `tools` – icon generator and the Korean string table

## License
MIT — see [LICENSE](LICENSE). Provided as is, without warranty.
