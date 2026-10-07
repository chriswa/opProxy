#!/bin/bash
# Builds opProxy, installs `op` → opProxy in ~/opProxy/bin, and (re)starts the launchd daemon.
# Put ~/opProxy/bin ahead of /opt/homebrew/bin on PATH to activate it.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")" && pwd)
LABEL=com.chriswa.opproxy
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

# The pin file is per-Mac and untracked; start from "no key" so a fresh checkout builds.
PIN_FILE="$ROOT/Sources/opProxy/ApprovalKeyPin.swift"
[ -f "$PIN_FILE" ] || printf '%s\n%s\n' "// Written by install.sh: this Mac's Secure Enclave approval public key (raw P-256, base64)." \
    "let pinnedApprovalPublicKey: String? = nil" > "$PIN_FILE"
swift build -c release --package-path "$ROOT"
# Pin this Mac's Secure Enclave approval key into the binary (created on first install), so
# approvals verify against a key an attacker can't swap on disk.
PUB=$("$ROOT/.build/release/opProxy" keygen)
if ! grep -qF "\"$PUB\"" "$PIN_FILE"; then
    printf '%s\n%s\n' "// Written by install.sh: this Mac's Secure Enclave approval public key (raw P-256, base64)." \
        "let pinnedApprovalPublicKey: String? = \"$PUB\"" > "$PIN_FILE"
    swift build -c release --package-path "$ROOT"
fi
# An app bundle, not a bare binary: macOS only remembers privacy grants (the "access data from
# other apps" prompt, raised because the daemon's `op` reads 1Password's group container) for
# something with a bundle identifier.
APP="$ROOT/bin/opProxy.app"
EXE="$APP/Contents/MacOS/opProxy"
mkdir -p "$APP/Contents/MacOS"
install -m 0755 "$ROOT/.build/release/opProxy" "$EXE"
cat > "$APP/Contents/Info.plist" <<INFO
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$LABEL</string>
  <key>CFBundleName</key><string>opProxy</string>
  <key>CFBundleExecutable</key><string>opProxy</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
INFO
"$ROOT/scripts/sign-app.sh" "$APP"
# `op` (the shim) and `opProxy` (the CLI) run the bundle's executable.
rm -f "$ROOT/bin/opProxy"
ln -sfn opProxy.app/Contents/MacOS/opProxy "$ROOT/bin/opProxy"
ln -sfn opProxy.app/Contents/MacOS/opProxy "$ROOT/bin/op"
mkdir -p "$HOME/.opProxy" && chmod 700 "$HOME/.opProxy"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$EXE</string><string>daemon</string></array>
  <key>RunAtLoad</key><true/>
  <!-- Relaunch after a crash, but not after the menu's Quit (a clean exit). -->
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardErrorPath</key><string>$HOME/.opProxy/launchd.log</string>
  <key>StandardOutPath</key><string>$HOME/.opProxy/launchd.log</string>
</dict>
</plist>
PLIST

DOMAIN="gui/$(id -u)"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
# bootout returns before the job is fully gone; bootstrapping too early fails with EIO.
for _ in $(seq 50); do launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break; sleep 0.1; done
rm -f "$HOME/.opProxy/daemon.sock"
# A disabled agent (Open at Login unchecked) can't be bootstrapped: enable it to start it now,
# then put the user's choice back, since disabling only affects future logins.
WAS_DISABLED=$(launchctl print-disabled "$DOMAIN" | grep -E "\"$LABEL\" => (disabled|true)" || true)
launchctl enable "$DOMAIN/$LABEL"
launchctl bootstrap "$DOMAIN" "$PLIST"
[ -n "$WAS_DISABLED" ] && launchctl disable "$DOMAIN/$LABEL"
for _ in $(seq 50); do [ -S "$HOME/.opProxy/daemon.sock" ] && break; sleep 0.1; done
"$ROOT/bin/opProxy" status
