#!/bin/bash
# Builds build/TouchM-<version>.dmg containing TouchM.app and an Applications shortcut.
set -e
cd "$(dirname "$0")"
VERSION="${1:-0.1.0}"
./make_app.sh >/dev/null
STAGE=$(mktemp -d)
cp -R build/TouchM.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "build/TouchM-$VERSION.dmg"
hdiutil create -volname "TouchM" -srcfolder "$STAGE" -ov -format UDZO "build/TouchM-$VERSION.dmg" >/dev/null
rm -rf "$STAGE"
echo "built build/TouchM-$VERSION.dmg"
