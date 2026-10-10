#!/bin/bash
# End-to-end test of the CloudKit approval feed against real iCloud: a debug daemon, a signed
# debug opProxy iCloud Relay, and `opProxyRelay test-phone` playing the iPhone app from a zone
# in this Mac's own private database. Needs scripts/provision-mac.sh to have run and this Mac
# signed in to iCloud. Not part of integration.sh or relay-integration.sh, which run offline.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
swift build --package-path "$ROOT" >/dev/null || exit 1
WORK=$(mktemp -d "${TMPDIR:-/tmp}/oppck.XXXXXX")
export OPPROXY_HOME="$WORK/state"
export OPPROXY_REAL_OP="$WORK/real-op"
mkdir -p "$OPPROXY_HOME"
unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID CODEX_THREAD_ID \
    CURSOR_CONVERSATION_ID CURSOR_AGENT_CHAT_ID

# CloudKit only works in a signed bundle with the provisioning profile.
RELAY_APP="$WORK/opProxy iCloud Relay.app"
"$ROOT/scripts/assemble-app.sh" "$ROOT/.build/debug/opProxyRelay" "$RELAY_APP" relay
"$ROOT/scripts/sign-app.sh" "$RELAY_APP" | grep -q "signing with profile" || { echo "no profile: run scripts/provision-mac.sh"; exit 1; }
export OPPROXY_RELAY="$RELAY_APP/Contents/MacOS/opProxyRelay"
PHONE() { "$OPPROXY_RELAY" test-phone "$@"; }
BIN="$ROOT/.build/debug/opProxy"
OP="$WORK/op"
ln -s "$BIN" "$OP"

# The pairing key is kept as a file: \$WORK/pairing-key.
cat > "$OPPROXY_REAL_OP" <<STUB
#!/bin/bash
case "\$*" in
  whoami*) exit 0 ;;
  "item list --format json"*) echo '[{"id": "cloud", "title": "cloud", "vault": {"id": "v", "name": "v"}}]'; exit 0 ;;
  "item create "*)
    printf '{"id":"pk","title":"opProxy pairing key: e2e","category":"PASSWORD","tags":["opproxy-pairing"],"fields":[{"id":"password","purpose":"PASSWORD","value":"%s"}]}' \
        "\$(openssl rand -hex 32)" | tee "$WORK/pairing-key"; exit 0 ;;
  "item get pk "*) cat "$WORK/pairing-key"; exit 0 ;;
  "item delete pk") rm -f "$WORK/pairing-key"; exit 0 ;;
esac
echo "stub ran: \$*"
STUB
chmod +x "$OPPROXY_REAL_OP"
FAKE="$WORK/fake-agent"
printf '%s\n' 'export CLAUDE_CODE_SESSION_ID=$2' 'shift 2' '/bin/bash -c '"'"'"$@"'"'"' tool-shell "$@"' > "$FAKE"
agent() { (exec -a opproxy-fake-agent /bin/bash "$FAKE" sess-C sess-C "$@"); }

PASS=0; FAIL=0
check() { local name=$1; shift; if "$@"; then PASS=$((PASS+1)); echo "ok   $name"; else FAIL=$((FAIL+1)); echo "FAIL $name"; fi; }
LOG="$OPPROXY_HOME/daemon.log"
QR="$WORK/qr"
# The Mac's dialog never answers on its own here: only the phone can decide in time.
OPPROXY_NO_AUTO_AUTH=1 OPPROXY_NO_MENU_BAR=1 OPPROXY_OP_REQUIREMENT=none OPPROXY_TEST_APPROVER=denied OPPROXY_TEST_DELAY=100 \
    OPPROXY_TEST_AUTO_PAIR=1 OPPROXY_TEST_CLOUD_PAIR="$QR" "$BIN" daemon & DAEMON=$!
trap 'kill $DAEMON 2>/dev/null; PHONE reset >/dev/null 2>&1; rm -rf "$WORK"' EXIT
for _ in $(seq 100); do [ -s "$QR" ] && break; sleep 0.1; done
check "pairing code written" test -s "$QR"

PHONE reset >/dev/null
out=$(PHONE pair "$(cat "$QR")" 2>&1)
echo "$out" | sed 's/^/     /'
check "phone paired over CloudKit" grep -q '"ok":true' <<<"$out"
check "phone received the pairing key" grep -q "pairing key received" <<<"$out"
check "mac linked the zone" grep -q "relay feed: linked own zone pair-" "$LOG"
check "same Apple ID: the zone isn't shared at all" grep -q "no share" <<<"$(PHONE share)"

agent "$OP" read op://v/cloud/password > "$WORK/read.out" 2>&1 & READ=$!
out=$(PHONE approve once 2>&1)
echo "$out" | sed 's/^/     /'
check "phone's approval accepted" grep -q '"ok":true' <<<"$out"
wait $READ
check "agent's read ran" grep -q "stub ran: read" "$WORK/read.out"

[ $FAIL -gt 0 ] && { echo "--- daemon log"; grep -v "^$" "$LOG" | tail -25; }
echo; echo "$PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
