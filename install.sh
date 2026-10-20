#!/bin/bash
# Builds opProxy, installs `op` → opProxy in ~/opProxy/bin, and (re)starts the launchd daemon.
# Put ~/opProxy/bin ahead of /opt/homebrew/bin on PATH to activate it.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")" && pwd)

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
APP="$ROOT/bin/opProxy.app"
EXE="$APP/Contents/MacOS/opProxy"
"$ROOT/scripts/assemble-app.sh" "$ROOT/.build/release/opProxy" "$APP"
"$ROOT/scripts/sign-app.sh" "$APP"
# opProxy iCloud Relay, beside the app, only if it can be signed for CloudKit (a profile from
# provision-mac.sh): otherwise opProxy uses one from Applications, downloaded from the releases.
RELAY="$ROOT/bin/opProxy iCloud Relay.app"
rm -rf "$RELAY"
"$ROOT/scripts/assemble-app.sh" "$ROOT/.build/release/opProxyRelay" "$RELAY" relay
if ! "$ROOT/scripts/sign-app.sh" "$RELAY" | tee /dev/stderr | grep -q "signing with profile"; then
    rm -rf "$RELAY"
    echo "no relay built: to reach an iPhone, put opProxy iCloud Relay (from the GitHub releases) in Applications"
fi
# `op` (the shim) and `opProxy` (the CLI) run the bundle's executable.
rm -f "$ROOT/bin/opProxy"
ln -sfn opProxy.app/Contents/MacOS/opProxy "$ROOT/bin/opProxy"
ln -sfn opProxy.app/Contents/MacOS/opProxy "$ROOT/bin/op"
mkdir -p "$HOME/.opProxy" && chmod 700 "$HOME/.opProxy"

# Run from /Applications when it's writable: on macOS 27 the menu bar can't attribute status
# items from apps elsewhere, so menu bar managers that hide icons (Ice) hide opProxy's too.
# Without write access (no admin rights), the daemon runs from bin/ as before.
install_app() {   # $1 bundle; swaps it in by rename, so a failure leaves the old copy in place
    local name dest staging old
    name=$(basename "$1"); dest="/Applications/$name"
    staging="/Applications/.$name.new.$$"; old="/Applications/.$name.old.$$"
    ditto "$1" "$staging" || { rm -rf "$staging"; return 1; }
    if [ -e "$dest" ] && ! mv "$dest" "$old"; then rm -rf "$staging"; return 1; fi
    if ! mv "$staging" "$dest"; then
        [ -e "$old" ] && mv "$old" "$dest"
        rm -rf "$staging"; return 1
    fi
    rm -rf "$old" 2>/dev/null || echo "left the previous copy at $old"
}
if [ -w /Applications ] && install_app "$APP"; then
    EXE="/Applications/opProxy.app/Contents/MacOS/opProxy"
    if [ -d "$RELAY" ] && ! install_app "$RELAY"; then
        echo "couldn't copy opProxy iCloud Relay to /Applications; opProxy uses the one in Applications, if any"
    fi
    echo "installed: /Applications/opProxy.app"
else
    echo "couldn't copy opProxy.app to /Applications (needs admin rights): running from $APP, where menu bar managers may hide its icon"
fi

# Writes the LaunchAgent and (re)starts the daemon, as opening the app does on a Mac without one.
"$EXE" install-agent
"$ROOT/bin/opProxy" status
