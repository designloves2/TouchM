#!/bin/bash
# Builds TouchM.app (menu-bar app) into ./build
set -e
cd "$(dirname "$0")"
swift build -c release --product TouchM
APP=build/TouchM.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp .build/release/TouchM "$APP/Contents/MacOS/TouchM"
mkdir -p "$APP/Contents/Resources"
swift tools/make_icon.swift build/TouchM.iconset >/dev/null 2>&1 && iconutil -c icns build/TouchM.iconset -o "$APP/Contents/Resources/TouchM.icns" || true
for L in en ko; do mkdir -p "$APP/Contents/Resources/$L.lproj"; done
python3 tools/ko.py "$APP/Contents/Resources/ko.lproj/Localizable.strings"
: > "$APP/Contents/Resources/en.lproj/Localizable.strings"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.touchm.app</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>ko</string></array>
<key>CFBundleName</key><string>TouchM</string>
<key>CFBundleIconFile</key><string>TouchM</string>
<key>CFBundleExecutable</key><string>TouchM</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSInputMonitoringUsageDescription</key><string>TouchM reads the touch screen.</string>
</dict></plist>
PL
# Stable designated requirement so Accessibility / Input Monitoring grants survive rebuilds.
codesign --force --sign - -r='designated => identifier "com.touchm.app"' "$APP"
echo "built $APP"
