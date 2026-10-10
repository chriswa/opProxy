#!/bin/bash
# End-to-end test of the daemon's side of opProxy iCloud Relay, offline: the debug relay with
# OPPROXY_TEST_FAKE_CLOUD stands in for CloudKit and a phone (Sources/opProxyRelay/FakeCloud.swift),
# and a stub `op` keeps pairing keys as files. Covers pairing with the key handshake, sealed
# records, a phone approval, reading the key back after a restart, refusing to hand the key
# out, and unpairing. Needs a debug build (swift build).
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN="$ROOT/.build/debug/opProxy"
RELAY="$ROOT/.build/debug/opProxyRelay"
[ -x "$BIN" ] && [ -x "$RELAY" ] || { echo "build first: swift build"; exit 1; }

# Unix socket paths are capped at 104 bytes, so keep the state dir short.
WORK=$(mktemp -d "${TMPDIR:-/tmp}/oppr.XXXXXX")
export OPPROXY_HOME="$WORK/state"
export OPPROXY_REAL_OP="$WORK/real-op"
export OPPROXY_RELAY="$RELAY"
export OPPROXY_TEST_FAKE_CLOUD="$WORK/cloud"
mkdir -p "$OPPROXY_HOME" "$WORK/cloud" "$WORK/items"
unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID CODEX_THREAD_ID \
    CURSOR_CONVERSATION_ID CURSOR_AGENT_CHAT_ID
OP="$WORK/op"
ln -s "$BIN" "$OP"
LOG="$OPPROXY_HOME/daemon.log"
CLOUD="$WORK/cloud"

FAKE="$WORK/fake-agent"
printf '%s\n' 'export CLAUDE_CODE_SESSION_ID=$2' 'shift 2' '/bin/bash -c '"'"'"$@"'"'"' tool-shell "$@"' > "$FAKE"
agent() { (exec -a opproxy-fake-agent /bin/bash "$FAKE" sess-R sess-R "$@"); }

# A stub op: always authorized; items are the catalog below plus the pairing keys it makes,
# kept as JSON files in $WORK/items.
cat > "$OPPROXY_REAL_OP" <<STUB
#!/bin/bash
ITEMS="$WORK/items"
echo "\$*" >> "$WORK/op-calls"
case "\$1 \$2" in
  "item create")
    python3 - "\$ITEMS" "\$@" <<'PY'
import json, os, secrets, sys
items, args = sys.argv[1], sys.argv[2:]
title = args[args.index("--title") + 1]
tags = args[args.index("--tags") + 1].split(",")
item_id = "pk" + secrets.token_hex(8)
item = {"id": item_id, "title": title, "category": "PASSWORD", "tags": tags,
        "vault": {"id": "pv", "name": "Personal"},
        "fields": [{"id": "password", "type": "CONCEALED", "purpose": "PASSWORD", "value": secrets.token_hex(32)}]}
json.dump(item, open(os.path.join(items, item_id), "w"))
print(json.dumps(item))
PY
    exit 0 ;;
  "item get")
    [ -f "\$ITEMS/\$3" ] && { cat "\$ITEMS/\$3"; exit 0; }
    echo "[ERROR] \"\$3\" isn't an item." >&2; exit 1 ;;
  "item delete")
    [ -f "\$ITEMS/\$3" ] && { rm "\$ITEMS/\$3"; exit 0; }
    echo "[ERROR] \"\$3\" isn't an item." >&2; exit 1 ;;
  "item list")
    python3 - "\$ITEMS" <<'PY'
import json, os, sys
items = [{"id": "plain", "title": "plain", "vault": {"id": "v", "name": "v"}}]
for name in os.listdir(sys.argv[1]):
    item = json.load(open(os.path.join(sys.argv[1], name)))
    items.append({"id": item["id"], "title": item["title"], "vault": item["vault"]})
print(json.dumps(items))
PY
    exit 0 ;;
esac
case "\$1" in whoami) exit 0 ;; esac
echo "stub ran: \$*"
STUB
chmod +x "$OPPROXY_REAL_OP"

PASS=0; FAIL=0
check() { local name=$1; shift; if "$@"; then PASS=$((PASS+1)); echo "ok   $name"; else FAIL=$((FAIL+1)); echo "FAIL $name"; fi; }
wait_for() { for _ in $(seq 100); do eval "$1" && return 0; sleep 0.1; done; return 1; }
DAEMON=
start_daemon() { # extra env assignments...
  env OPPROXY_NO_MENU_BAR=1 OPPROXY_OP_REQUIREMENT=none OPPROXY_TEST_APPROVER=denied OPPROXY_TEST_DELAY=100 \
      OPPROXY_TEST_AUTO_PAIR=1 OPPROXY_POLL_SECONDS=1 "$@" "$BIN" daemon & DAEMON=$!
  wait_for '[ -S "$OPPROXY_HOME/daemon.sock" ]' || { echo "daemon did not start"; exit 1; }
}
stop_daemon() { [ -n "$DAEMON" ] && kill "$DAEMON" 2>/dev/null && wait "$DAEMON" 2>/dev/null; DAEMON=; rm -f "$OPPROXY_HOME/daemon.sock"; }
trap 'stop_daemon; rm -rf "$WORK"' EXIT

# --- pairing: the daemon starts the relay, shows a v4 code, and the phone pairs through it
start_daemon OPPROXY_TEST_CLOUD_PAIR="$CLOUD/qr"
check "v4 pairing code written" wait_for 'grep -q "^opproxy-pair:4:" "$CLOUD/qr" 2>/dev/null'
check "pair-result carries a key the phone opened" wait_for 'grep -q "KEY OK" "$CLOUD/paired" 2>/dev/null'
check "pair-result ok" grep -q '"ok":true' "$CLOUD/paired"
check "the key was made in 1Password by generating it" grep -q -- "--generate-password" "$WORK/op-calls"
ITEM=$(ls "$WORK/items" | head -1)
check "the link names the key's item" grep -q "\"keyItem\" : \"$ITEM\"" "$OPPROXY_HOME/relay-links.json"
check "the phone read the sealed hello" wait_for 'grep -q "\"type\":\"hello\"" "$CLOUD/hello" 2>/dev/null'

# --- a request reaches the phone sealed, and the phone's sealed answer runs it
echo "approve once" > "$CLOUD/answer"
out=$(agent "$OP" read op://v/plain/password 2>&1)
check "phone's approval ran the read" grep -q "stub ran: read" <<<"$out"
check "the phone heard the reply-result" grep -q '"ok":true' "$CLOUD/replies"
check "nothing went to the relay in the clear" bash -c "! grep -q challenge '$CLOUD/commands'"

# --- the pairing key is never handed out, to an agent or anyone
out=$(agent "$OP" read "op://Personal/$ITEM/password" 2>&1)
check "pairing key refused" grep -q "opProxy's own pairing key" <<<"$out"
check "pairing key never read for a caller" bash -c "! grep -q 'read op://Personal/$ITEM' '$WORK/op-calls'"

# --- after a restart the daemon reads the key back from 1Password and serves the phone again
# (Left by a version before 0.3.0: its phones are told to pair again, once.)
stop_daemon
: > "$CLOUD/hello"
echo '[]' > "$OPPROXY_HOME/cloud-links.json"
start_daemon
check "key read back after restart" wait_for 'grep -q "read the pairing key" "$LOG"'
check "an update from before 0.3.0 asks to pair again" grep -q "have to pair again" "$LOG"
check "and only once" test ! -e "$OPPROXY_HOME/cloud-links.json"
check "the phone reads the resealed hello" wait_for 'grep -q "\"type\":\"hello\"" "$CLOUD/hello"'

# --- unpairing drops the zone and deletes the key from 1Password
"$BIN" unpair --all >/dev/null
check "unpair deletes the pairing key" wait_for '[ -z "$(ls "$WORK/items")" ]'
check "unpair unlinks the zone" wait_for 'grep -q "\"unlink\"" "$CLOUD/commands"'
check "the relay stops when no phone is left" wait_for 'grep -q "stopping the relay" "$LOG"'

# --- a relay that speaks another protocol is turned away, and pairing says why
stop_daemon
start_daemon OPPROXY_TEST_RELAY_PROTOCOL=99 OPPROXY_TEST_CLOUD_PAIR="$CLOUD/qr2"
check "a relay on another protocol is refused" wait_for 'grep -q "speaks relay protocol 99" "$LOG"'
check "pairing fails with the reason" wait_for 'grep -q "phone pairing: .*Update this opProxy" "$LOG"'

[ $FAIL -gt 0 ] && { echo "--- daemon log"; tail -30 "$LOG"; }
echo; echo "$PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
