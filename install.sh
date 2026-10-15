#!/bin/bash
# Build TouchM and install it to /Applications (replaces an older copy), then launch it.
set -e
cd "$(dirname "$0")"
./make_app.sh
pkill -x TouchM 2>/dev/null || true
rm -rf /Applications/TouchM.app
cp -R build/TouchM.app /Applications/TouchM.app
open /Applications/TouchM.app
echo "Installed. Grant Accessibility + Input Monitoring to /Applications/TouchM.app if asked."
