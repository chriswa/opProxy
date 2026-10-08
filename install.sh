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
# `op` (the shim) and `opProxy` (the CLI) run the bundle's executable.
rm -f "$ROOT/bin/opProxy"
ln -sfn opProxy.app/Contents/MacOS/opProxy "$ROOT/bin/opProxy"
ln -sfn opProxy.app/Contents/MacOS/opProxy "$ROOT/bin/op"
mkdir -p "$HOME/.opProxy" && chmod 700 "$HOME/.opProxy"
# With Spaceterm installed, name agents the way it does, unless a config already says otherwise.
if [ -d "$HOME/.spaceterm" ] && [ ! -e "$HOME/.opProxy/config.json" ]; then
    cat > "$HOME/.opProxy/config.json" <<CONFIG
{"requesterLabel": {"command": ["$ROOT/scripts/spaceterm-label.py"],
                    "environment": ["SPACETERM_NODE_ID", "SPACETERM_SURFACE_ID"]}}
CONFIG
fi

# Writes the LaunchAgent and (re)starts the daemon, as opening the app does on a Mac without one.
"$EXE" install-agent
"$ROOT/bin/opProxy" status
