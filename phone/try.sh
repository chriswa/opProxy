#!/bin/bash
# Try the iPhone app against a test daemon that runs beside the installed opProxy, with its
# own state in ~/.opProxy-try, its own menu bar icon, its own opProxy iCloud Relay, and a stub `op`
# (no 1Password; pairing keys are files).
#   phone/try.sh start     build, sign and start the test daemon; install the app if the iPhone is reachable
#   phone/try.sh pair      open the test daemon's pairing QR code
#   phone/try.sh request [session]   a fake Claude Code agent asks for a secret; another session queues another
#   phone/try.sh stop
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export OPPROXY_HOME="$HOME/.opProxy-try"
export OPPROXY_REAL_OP="$OPPROXY_HOME/stub-op"
APP="$OPPROXY_HOME/opProxy.app"
BIN="$APP/Contents/MacOS/opProxy"
PIDFILE="$OPPROXY_HOME/daemon.pid"

stop() {
    if [ -f "$PIDFILE" ]; then kill "$(cat "$PIDFILE")" 2>/dev/null || true; fi
    rm -f "$PIDFILE" "$OPPROXY_HOME/daemon.sock"
}

case "${1:-}" in
start)
    stop
    mkdir -p "$OPPROXY_HOME" && chmod 700 "$OPPROXY_HOME"
    swift build --package-path "$ROOT" >/dev/null
    rm -rf "$APP"
    "$ROOT/scripts/assemble-app.sh" "$ROOT/.build/debug/opProxy" "$APP"
    # opProxy iCloud Relay inside it, as in a release: signed first, since signing the app seals it.
    RELAY="$APP/Contents/Helpers/opProxy iCloud Relay.app"
    "$ROOT/scripts/assemble-app.sh" "$ROOT/.build/debug/opProxyRelay" "$RELAY" relay
    "$ROOT/scripts/sign-app.sh" "$RELAY" | grep -q "signing with profile" || { echo "no profile: run scripts/provision-mac.sh"; exit 1; }
    "$ROOT/scripts/sign-app.sh" "$APP" >/dev/null
    # Pairing keys are kept as files in $OPPROXY_HOME/items.
    mkdir -p "$OPPROXY_HOME/items"
    cat > "$OPPROXY_REAL_OP" <<'STUB'
#!/bin/bash
ITEMS="$(dirname "$0")/items"
case "$*" in
  whoami*|"vault list"*) exit 0 ;;
  "item list --format json"*) echo '[{"id": "ghtoken0000000000000000000", "title": "GitHub token", "vault": {"id": "priv0000000000000000000000", "name": "Private"}}]'; exit 0 ;;
  "item create "*)
    ID="pk$(openssl rand -hex 8)"
    TITLE=$(python3 -c 'import sys; a=sys.argv[1:]; print(a[a.index("--title")+1])' "$@")
    python3 -c 'import json,sys; print(json.dumps({"id":sys.argv[1],"title":sys.argv[2],"category":"PASSWORD","tags":["opproxy-pairing"],
"vault":{"id":"priv0000000000000000000000","name":"Private"},"fields":[{"id":"password","purpose":"PASSWORD","value":sys.argv[3]}]}))' \
        "$ID" "$TITLE" "$(openssl rand -hex 32)" | tee "$ITEMS/$ID"; exit 0 ;;
  "item get "*) [ -f "$ITEMS/$3" ] && { cat "$ITEMS/$3"; exit 0; }; echo "[ERROR] \"$3\" isn't an item." >&2; exit 1 ;;
  "item delete "*) [ -f "$ITEMS/$3" ] && { rm "$ITEMS/$3"; exit 0; }; echo "[ERROR] \"$3\" isn't an item." >&2; exit 1 ;;
esac
echo "(stub op) $*"
STUB
    chmod +x "$OPPROXY_REAL_OP"
    OPPROXY_NO_AUTO_AUTH=1 OPPROXY_OP_REQUIREMENT=none nohup "$BIN" daemon >>"$OPPROXY_HOME/launch.log" 2>&1 &
    echo $! > "$PIDFILE"
    echo "test daemon running (log: $OPPROXY_HOME/daemon.log). Pair from its menu bar icon: Pair an iPhone…"
    DEVICE=$(xcrun devicectl list devices 2>/dev/null | awk '/iPhone/ && $0 !~ /unavailable/ {print $3; exit}')
    if [ -n "$DEVICE" ]; then
        (cd "$ROOT/phone" && xcodegen generate --quiet)
        xcodebuild -project "$ROOT/phone/OpProxyPhone.xcodeproj" -scheme OpProxyPhone -configuration Debug \
            -destination 'generic/platform=iOS' -derivedDataPath "$ROOT/phone/build" -allowProvisioningUpdates -quiet build
        xcrun devicectl device install app --device "$DEVICE" "$ROOT/phone/build/Build/Products/Debug-iphoneos/opProxy.app" >/dev/null
        echo "installed the app on the iPhone"
    else
        echo "no reachable iPhone: the app wasn't installed"
    fi
    ;;
pair)
    # The test daemon opens its own QR window, as its menu's Pair an iPhone… does.
    [ -S "$OPPROXY_HOME/daemon.sock" ] || "$0" start
    "$BIN" pair-iphone
    ;;
request)
    # A stand-in Claude Code process (debug builds trust argv[0] opproxy-fake-agent).
    FAKE="$OPPROXY_HOME/fake-agent"
    printf '%s\n' 'export CLAUDE_CODE_SESSION_ID=$2' 'shift 2' '/bin/bash -c '"'"'"$@"'"'"' tool-shell "$@"' > "$FAKE"
    ln -sf "$BIN" "$OPPROXY_HOME/op"
    SESSION=${2:-try-session}
    (exec -a opproxy-fake-agent /bin/bash "$FAKE" "$SESSION" "$SESSION" "$OPPROXY_HOME/op" read "op://Private/GitHub token/credential")
    ;;
stop) stop ;;
*) sed -n 4,6p "$0"; exit 1 ;;
esac
