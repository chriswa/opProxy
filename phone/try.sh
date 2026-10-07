#!/bin/bash
# Try the iPhone app against a test daemon that runs beside the installed opProxy, with its
# own state in ~/.opProxy-try, its own menu bar icon, and a stub `op` (no 1Password).
#   phone/try.sh start     build, sign and start the test daemon; install the app if the iPhone is reachable
#   phone/try.sh pair      restart the test daemon and open a pairing QR code to scan
#   phone/try.sh request   a fake Claude Code agent asks for a secret
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
    mkdir -p "$APP/Contents/MacOS" && chmod 700 "$OPPROXY_HOME"
    swift build --package-path "$ROOT" >/dev/null
    cp "$ROOT/.build/debug/opProxy" "$BIN"
    cat > "$APP/Contents/Info.plist" <<INFO
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.chriswa.opproxy</string>
  <key>CFBundleExecutable</key><string>opProxy</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
</dict></plist>
INFO
    "$ROOT/scripts/sign-app.sh" "$APP" | grep -q "signing with CloudKit" || { echo "no CloudKit profile: run scripts/provision-mac.sh"; exit 1; }
    cat > "$OPPROXY_REAL_OP" <<'STUB'
#!/bin/bash
case "$*" in
  whoami*|"vault list"*) exit 0 ;;
  "item list --format json"*) echo '[{"id": "ghtoken0000000000000000000", "title": "GitHub token", "vault": {"id": "priv0000000000000000000000", "name": "Private"}}]'; exit 0 ;;
esac
echo "(stub op) $*"
STUB
    chmod +x "$OPPROXY_REAL_OP"
    OPPROXY_NO_AUTO_AUTH=1 OPPROXY_OP_REQUIREMENT=none OPPROXY_TEST_CLOUD_PAIR=${PAIR_FILE:-} nohup "$BIN" daemon >>"$OPPROXY_HOME/launch.log" 2>&1 &
    echo $! > "$PIDFILE"
    echo "test daemon running (log: $OPPROXY_HOME/daemon.log). Pair from its menu bar icon: Paired Phones → Pair an iPhone…"
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
    # The daemon writes the code instead of showing its window; draw it as a QR code here.
    export PAIR_FILE="$OPPROXY_HOME/pair-code"
    rm -f "$PAIR_FILE"
    "$0" start | grep -v "^installed\|no reachable"
    for _ in $(seq 100); do [ -s "$PAIR_FILE" ] && break; sleep 0.1; done
    swift - "$(cat "$PAIR_FILE")" "$OPPROXY_HOME/pair-qr.png" <<'QR'
import AppKit
import CoreImage
let filter = CIFilter(name: "CIQRCodeGenerator")!
filter.setValue(Data(CommandLine.arguments[1].utf8), forKey: "inputMessage")
let image = filter.outputImage!.transformed(by: CGAffineTransform(scaleX: 16, y: 16))
let rep = NSBitmapImageRep(cgImage: CIContext().createCGImage(image, from: image.extent)!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
QR
    open "$OPPROXY_HOME/pair-qr.png"
    echo "scan the QR code with the iPhone app; it works once, for 10 minutes"
    ;;
request)
    # A stand-in Claude Code process (debug builds trust argv[0] opproxy-fake-agent).
    FAKE="$OPPROXY_HOME/fake-agent"
    printf '%s\n' 'export CLAUDE_CODE_SESSION_ID=$2' 'shift 2' '/bin/bash -c '"'"'"$@"'"'"' tool-shell "$@"' > "$FAKE"
    ln -sf "$BIN" "$OPPROXY_HOME/op"
    (exec -a opproxy-fake-agent /bin/bash "$FAKE" try-session try-session "$OPPROXY_HOME/op" read "op://Private/GitHub token/credential")
    ;;
stop) stop ;;
*) sed -n 4,6p "$0"; exit 1 ;;
esac
