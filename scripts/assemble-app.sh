#!/bin/bash
# Wraps a built opProxy binary in an app bundle: assemble-app.sh <binary> <path/to/opProxy.app>
# Its version is the repo's VERSION, which the iPhone app shares.
# A bundle, not a bare binary: macOS only remembers privacy grants (the "access data from other
# apps" prompt, raised because the daemon's `op` reads 1Password's group container) for something
# with a bundle identifier, and CloudKit needs one too.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BINARY=$1 APP=$2 VERSION=$(cat "$ROOT/VERSION")
mkdir -p "$APP/Contents/MacOS"
install -m 0755 "$BINARY" "$APP/Contents/MacOS/opProxy"
cat > "$APP/Contents/Info.plist" <<INFO
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.chriswa.opproxy</string>
  <key>CFBundleName</key><string>opProxy</string>
  <key>CFBundleExecutable</key><string>opProxy</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
INFO
