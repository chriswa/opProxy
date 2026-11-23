#!/bin/bash
# End-to-end test of shim + daemon against a stand-in for 1Password (the fake helper, which
# serves a fixture of vaults and items), a stub `op` for passthrough, a scripted approver and a
# fake agent process. No 1Password involved. Needs a debug build, which is the only kind that
# honours the OPPROXY_* test knobs.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN="$ROOT/.build/debug/opProxy"
[ -x "$BIN" ] || { echo "build first: swift build (after ./install.sh, or with a placeholder ApprovalKeyPin.swift)"; exit 1; }

# Unix socket paths are capped at 104 bytes, so keep the state dir short.
WORK=$(mktemp -d "${TMPDIR:-/tmp}/opp.XXXXXX")
export OPPROXY_HOME="$WORK/state"
export OPPROXY_REAL_OP="$WORK/real-op"
SDK="$WORK/sdk"
export OPPROXY_TEST_SDK="$SDK/fixture.json"
mkdir -p "$WORK/bin" "$OPPROXY_HOME" "$SDK"
# Run the same inside an agent as anywhere else: tests that want a session set it themselves.
unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID CODEX_THREAD_ID \
    CURSOR_CONVERSATION_ID CURSOR_AGENT_CHAT_ID
ln -s "$BIN" "$WORK/bin/op"
OP="$WORK/bin/op"
LOG="$OPPROXY_HOME/daemon.log"
# The daemon runs from a copy so a test can swap the file under it.
DAEMON_BIN="$WORK/opProxy"
cp "$BIN" "$DAEMON_BIN"

# A stand-in agent: debug builds treat argv[0] "opproxy-fake-agent" as a genuine Claude
# process whose instance is argv[2]. Like Claude, it runs each command in a child shell
# with the session ID in its environment.
FAKE="$WORK/fake-agent"
cat > "$FAKE" <<'AGENT'
export CLAUDE_CODE_SESSION_ID=$2
shift 2
/bin/bash -c '"$@"' tool-shell "$@"
AGENT

# The real op only runs for passthrough, and for the daemon's `account list`.
cat > "$OPPROXY_REAL_OP" <<STUB
#!/bin/bash
echo run >> "$WORK/stub-runs"
case "\$*" in
  "account list --format json") echo '[{"url": "stub.1password.com", "email": "me@stub.com", "user_uuid": "STUBUSER", "account_uuid": "STUBACCT"}]'; exit 0 ;;
esac
echo "stub args=\$* account=\${OP_ACCOUNT:-}"
STUB
chmod +x "$OPPROXY_REAL_OP"

# 1Password's stand-in: most items use their names as IDs, and every field's value names its
# item and field ("v:b:c"), so output shows the daemon read exactly that.
python3 - "$OPPROXY_TEST_SDK" <<'PY'
import json, sys
plain = ["a/b", "t/one", "t/two", "t/three", "strip/x", "Shared/api", "ctx/item", "p/q", "gone/x", "idle/x",
         "once/x", "day/x", "all/x", "phone/item", "d/e", "raw/item", "x/y", "forged/item", "signed/x", "n/a",
         "w/edit-me", "w/delete-me"]
names = ["c", "f", "field", "other", "y", "z", "me", "r", "env", "username", "password"]
def item(id, title, vault, category="Login"):
    return {"id": id, "title": title, "category": category, "vaultId": vault, "version": 1,
            "createdAt": "2026-11-01T00:00:00Z", "updatedAt": "2026-11-02T00:00:00Z",
            "fields": [{"id": n, "title": n, "fieldType": "Concealed" if n == "password" else "Text", "value": f"v:{id}:{n}"}
                       for n in names]}
vaults = {}
items = []
for v, i in (p.split("/") for p in plain):
    vaults[v] = {"id": v, "title": v, "vaultType": "personal" if v == "a" else "userCreated"}
    items.append(item(i, i, v))
vaults["zyxwvutsrqponmlkjihgfedcba"] = {"id": "zyxwvutsrqponmlkjihgfedcba", "title": "Stub Vault", "vaultType": "userCreated"}
vaults["other"] = {"id": "other", "title": "Other", "vaultType": "userCreated"}
items += [item("abcdefghijklmnopqrstuvwxyz", "Stub Item Title", "zyxwvutsrqponmlkjihgfedcba"),
          item("shared1shared1shared1share", "Shared Name", "zyxwvutsrqponmlkjihgfedcba"),
          item("shared2shared2shared2share", "Shared Name", "other"),
          item("pairingkey", "opProxy pairing key: iPhone · Mac", "a", "Password")]
json.dump({"vaults": list(vaults.values()), "items": items}, open(sys.argv[1], "w"))
PY

PASS=0; FAIL=0
check() { # name, condition...
  local name=$1; shift
  if "$@"; then PASS=$((PASS+1)); echo "ok   $name"; else FAIL=$((FAIL+1)); echo "FAIL $name:" "$@"; fi
}
count() { grep -c -- "$1" "$LOG" 2>/dev/null || true; }
DAEMON_PID=
start_daemon() { # decision [delay]
  stop_daemon
  OPPROXY_NO_AUTO_AUTH=${OPPROXY_NO_AUTO_AUTH-1} OPPROXY_NO_MENU_BAR=1 OPPROXY_POLL_SECONDS=1 OPPROXY_PHONE_DELAY=${OPPROXY_PHONE_DELAY:-0} OPPROXY_TERMINAL_IDLE=${OPPROXY_TERMINAL_IDLE:-600} OPPROXY_TEST_APPROVER=$1 OPPROXY_TEST_DELAY=${2:-0} \
    OPPROXY_OP_REQUIREMENT=${OP_REQUIREMENT-none} OPPROXY_TEST_SWAP_OP=${OPPROXY_TEST_SWAP_OP:-} OPPROXY_TEST_AUTO_PAIR=1 \
    "$DAEMON_BIN" daemon & DAEMON_PID=$!
  for _ in $(seq 50); do [ -S "$OPPROXY_HOME/daemon.sock" ] && return; sleep 0.1; done
  echo "daemon did not start"; exit 1
}
stop_daemon() {
  [ -n "$DAEMON_PID" ] && kill "$DAEMON_PID" 2>/dev/null && wait "$DAEMON_PID" 2>/dev/null
  DAEMON_PID=; rm -f "$OPPROXY_HOME/daemon.sock"
}
trap 'stop_daemon; rm -rf "$WORK"' EXIT
# SID picks the session; INST the agent process instance (default: one per session).
agent() { (exec -a opproxy-fake-agent /bin/bash "$FAKE" "${INST:-${SID:-sess-A}}" "${SID:-sess-A}" "$@"); }
via_daemon() { [[ "$1" == v:* ]]; }
not_daemon() { [[ "$1" == "stub args="* ]]; }
status() { "$BIN" status 2>&1; }
not_in() { ! grep -q -- "$1" "$2" 2>/dev/null; }
fixture_has() { python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if eval(sys.argv[2]) else 1)" "$OPPROXY_TEST_SDK" "$1"; }

# --- no agent session: exec the real op directly
out=$(env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID -u CODEX_THREAD_ID -u CURSOR_CONVERSATION_ID "$OP" read op://a/b/c)
check "no daemon: passthrough" not_daemon "$out"

# --- daemon down: agent calls still work via passthrough
out=$(agent "$OP" read op://a/b/c)
check "daemon down: passthrough" not_daemon "$out"

start_daemon approved
# --- a session ID in the environment alone proves nothing. Run it orphaned to launchd, so no
# agent is above it even when this suite itself runs inside one.
orphaned() {
  python3 - "$WORK/orphan.out" "$@" <<'PY'
import os, subprocess, sys, time
out = sys.argv[1]
if os.fork() == 0:
    os.setsid()
    if os.fork() == 0:
        with open(out + ".tmp", "w") as f: subprocess.run(sys.argv[2:], stdout=f, stderr=f)
        os.rename(out + ".tmp", out); os._exit(0)
    os._exit(0)
while not os.path.exists(out): time.sleep(0.05)
print(open(out).read(), end=""); os.remove(out)
PY
}
# With no genuine agent above it, a caller is a terminal tab: one approval covers every read
# from that Unix session, whatever session ID it claims.
out=$(orphaned /bin/bash -c "CLAUDE_CODE_SESSION_ID=sess-A $OP read op://t/one/f; $OP read op://t/two/f")
check "terminal: proxied" [ "$out" = $'v:one:f\nv:two:f' ]
check "terminal: one dialog for the tab" [ "$(count 'prompting: terminal:')" = 1 ]
check "terminal: second read allowed" grep -q "allowed: terminal:[0-9]* op read op://t/two/f → t / two \[authorized " "$LOG"
check "terminal: dialog shows the process chain" grep -q '"chain":\[.*read op:\\/\\/t\\/one\\/f' "$LOG"
orphaned "$OP" read op://t/three/f >/dev/null
check "terminal: another tab prompts again" [ "$(count 'prompting: terminal:')" = 2 ]
orphaned "$OP" vault list >/dev/null
check "terminal: listings need no dialog" [ "$(count 'prompting: terminal:')" = 2 ]

# --- an agent that strips its session variables is still an agent
agent env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID "$OP" read op://strip/x/y >/dev/null
check "agent without session env: agent rules" grep -q "prompting: claude:unknown op read op://strip/x/y" "$LOG"

out=$(agent "$OP" read op://a/b/c)
check "approved: answered by the daemon" [ "$out" = "v:b:c" ]
check "approved: prompted once" [ "$(count 'prompting: claude:sess-A op read op://a/b/c')" = 1 ]
out=$(agent "$OP" read op://a/b/c)
check "repeat: no second prompt" [ "$(count 'prompting: claude:sess-A op read op://a/b/c')" = 1 ]
check "repeat: allowed from allowlist" [ "$(count 'allowed: claude:sess-A op read op://a/b/c')" = 1 ]
check "repeat: still returns output" via_daemon "$out"

SID=sess-B agent "$OP" read op://a/b/c >/dev/null
check "other session: prompts again" [ "$(count 'prompting: claude:sess-B')" = 1 ]
agent "$OP" read op://a/b/other -n >/dev/null
agent "$OP" item get b --vault A --fields label=f >/dev/null
check "same item, other fields: no prompt" [ "$(count 'prompting: claude:sess-A')" = 1 ]
out=$(agent env OP_ACCOUNT=stub.1password.com "$OP" read op://a/b/c)
check "OP_ACCOUNT naming this account: answered" [ "$out" = "v:b:c" ]
check "OP_ACCOUNT is part of the key" [ "$(count 'prompting: claude:sess-A op read op://a/b/c → a / b')" = 2 ]
out=$(agent env OP_ACCOUNT=elsewhere "$OP" read op://a/b/c)
check "another account: passes through" [ "$out" = "stub args=read op://a/b/c account=elsewhere" ]

out=$(agent "$OP" whoami)
check "whoami: answered without a prompt" [ "$out" = $'URL:        https://stub.1password.com/\nEmail:      me@stub.com\nUser ID:    STUBUSER' ]
check "whoami: no prompt logged" [ "$(count 'prompting: claude:sess-A op whoami')" = 0 ]
out=$(agent "$OP" item list --vault Stub\ Vault --format json)
check "item list: from 1Password's listings" python3 -c "
import json, sys
items = json.loads(sys.argv[1])
assert sorted(i['title'] for i in items) == ['Shared Name', 'Stub Item Title'], items
assert items[0]['vault']['name'] == 'Stub Vault' and items[0]['category'] == 'LOGIN', items" "$out"
check "vault list: human columns" grep -q "^ID  *NAME$" <<<"$(agent "$OP" vault list)"
check "account list: passes through" [ "$(agent "$OP" account list)" = "stub args=account list account=" ]

# --- writes ask every time, show no values, and run through 1Password
out=$(agent "$OP" item create --category Login --title Created --vault w 'username=me' 'password=hunter2' --format json)
check "create: asks" grep -q "prompting: write:.* op item create --category Login --title Created --vault w username=‹hidden› password=‹hidden› --format json → w / Created" "$LOG"
check "create: dialog names fields, not values" grep -q '"details":\["Category=LOGIN","Title=Created","Sets=username (2 characters), password (7 characters)"\]' "$LOG"
check "create: only once is offered" grep -q '"options":\["once"\]' "$LOG"
check "create: saved" fixture_has "any(i['title'] == 'Created' and i['vaultId'] == 'w' and any(f['value'] == 'hunter2' for f in i['fields']) for i in d['items'])"
check "create: prints the item" python3 -c "import json,sys; assert json.loads(sys.argv[1])['title'] == 'Created'" "$out"
check "create: values never logged" [ "$(count hunter2)" = 0 ]
agent "$OP" item create --category Login --title Created2 --vault w 'password=x' >/dev/null
check "writes: asked again, never remembered" [ "$(count 'prompting: write:')" = 2 ]
agent "$OP" item edit edit-me 'password=rotated!' --title Edited >/dev/null
check "edit: saved" fixture_has "any(i['id'] == 'edit-me' and i['title'] == 'Edited' and any(f['value'] == 'rotated!' for f in i['fields']) for i in d['items'])"
check "edit: logged as ran" grep -q "ran: claude:sess-A op item edit edit-me password=‹hidden› --title Edited → w / edit-me" "$LOG"
agent "$OP" item delete delete-me >/dev/null
check "delete: gone" fixture_has "not any(i['id'] == 'delete-me' for i in d['items'])"
err=$(agent "$OP" item delete "opProxy pairing key: iPhone · Mac" 2>&1); rc=$?
check "pairing key: never changed" grep -q "opProxy's own pairing key" <<<"$err"
out=$(agent "$OP" item create --template t.json 'password=hunter3')
check "unsupported write: passes through" not_daemon "$out"
check "passthrough argv never logged" [ "$(count hunter3)" = 0 ]
check "passthrough: logged with who and why" grep -q "passed through: claude:sess-A op item create (uses --template)" "$LOG"
out=$(agent "$OP" run -- printenv)
check "op run: passes through" not_daemon "$out"
check "op run: logged" grep -q "passed through: claude:sess-A op run (\`op run\` is not a command opProxy handles)" "$LOG"
start_daemon denied
err=$(agent "$OP" item edit edit-me 'password=again' 2>&1); rc=$?
check "denied write: refused" [ $rc = 1 ]
check "denied write: not saved" fixture_has "not any(f['value'] == 'again' for i in d['items'] for f in i['fields'])"
start_daemon approved

# --- --out-file is written by the shim in the caller's cwd
mkdir -p "$WORK/cwd" && cd "$WORK/cwd"
out=$(agent "$OP" read op://Shared/api/env -o .env --force)
check "out-file: prints absolute path" [ "$out" = "$(pwd -P)/.env" ]
check "out-file: contents from daemon" grep -q "^v:api:env$" .env
check "out-file: mode 0600" [ "$(stat -f %Lp .env)" = 600 ]
err=$(agent "$OP" read op://Shared/api/env -o .env 2>&1); rc=$?
check "out-file: refuses overwrite without --force" [ $rc = 1 ]
cd - >/dev/null

# --- tool command recovered from the process tree
agent /bin/zsh -c "X=\$($OP read op://ctx/item/field) && echo done" >/dev/null
check "dialog shows the agent's shell command" grep -qF '"toolCommand":"X=$('"${OP//\//\\/}"' read op:\/\/ctx\/item\/field) && echo done","vault":"ctx","via":null' "$LOG"
check "dialog headlines the item" grep -q '"item":"item".*"vault":"ctx"' "$LOG"
check "dialog shows the field" grep -q '"details":\["Field=field"\]' "$LOG"
check "dialog headlines an unnamed agent generically" grep -q '"headline":"Claude Code Agent"' "$LOG"
agent /bin/zsh -c "$OP item edit edit-me 'password=from-tool' && echo done" >/dev/null
check "write dialog hides values in the shell command" grep -qF "password=‹hidden›' && echo done" "$LOG"
check "write values never logged, even from the shell command" [ "$(count from-tool)" = 0 ]

# --- concurrent identical requests share one dialog
start_daemon approved 1
pids=()
for i in 1 2 3 4 5; do SID=sess-C agent "$OP" read op://p/q/r > "$WORK/par$i" & pids+=($!); done
wait "${pids[@]}"
check "concurrent: one prompt for five calls" [ "$(count 'prompting: claude:sess-C')" = 1 ]
check "concurrent: all five got output" [ "$(cat "$WORK"/par* | grep -c '^v:q:r$')" = 5 ]

# --- an agent that gives up mid-dialog: the reply to its closed socket mustn't kill the
# daemon (SIGPIPE), and the approval still counts for its retry
SID=sess-G agent "$OP" read op://gone/x/y >/dev/null 2>&1 &
sleep 0.5; pkill -f "read op://gone/x/y"; sleep 2
check "requester left: noticed" grep -q "requester stopped waiting: claude:sess-G" "$LOG"
check "requester left: daemon survives replying" kill -0 "$DAEMON_PID"
out=$(SID=sess-G agent "$OP" read op://gone/x/y)
check "requester left: retry runs on the approval" via_daemon "$out"
check "requester left: retry needed no dialog" [ "$(count 'prompting: claude:sess-G')" = 1 ]

# --- terminal approvals lapse after the idle window (1s here)
OPPROXY_TERMINAL_IDLE=1 start_daemon approved
orphaned /bin/bash -c "$OP read op://idle/x/y; $OP read op://idle/x/y; sleep 1.5; $OP read op://idle/x/y" >/dev/null
check "terminal idle: second read in time, third after idle prompts" [ "$(count 'prompting: terminal:[0-9]* op read op://idle')" = 2 ]
start_daemon approved 1

# --- the dialog's duration choice
start_daemon approved-once
SID=sess-O agent "$OP" read op://once/x/y >/dev/null
SID=sess-O agent "$OP" read op://once/x/y >/dev/null
check "only this once: every call asks" [ "$(count 'prompting: claude:sess-O')" = 2 ]
check "only this once: nothing stored" not_in "sess-O" "$OPPROXY_HOME/approvals.json"
start_daemon approved
SID=sess-H agent "$OP" read op://day/x/y >/dev/null
INST=resumed SID=sess-H agent "$OP" read op://day/x/y >/dev/null
check "this agent: a resumed session (new process, same ID) runs silently" [ "$(count 'prompting: claude:sess-H')" = 1 ]
SID=sess-I agent "$OP" read op://day/x/y >/dev/null
check "this agent: another session asks" [ "$(count 'prompting: claude:sess-I')" = 1 ]
ttl=$(python3 -c "
import json, sys; from datetime import datetime
for a in json.load(open(sys.argv[1])):
    if a['key']['audience'].get('session', {}).get('sessionId') == 'sess-H':
        f = lambda s: datetime.fromisoformat(s.replace('Z', '+00:00'))
        print(int((f(a['expiresAt']) - f(a['approvedAt'])).total_seconds()))" "$OPPROXY_HOME/approvals.json")
check "1 day: stored with a signed 1-day expiry" [ "$ttl" = 86400 ]
start_daemon approved-all
SID=sess-J agent "$OP" read op://all/x/y >/dev/null
SID=sess-K agent "$OP" read op://all/x/y >/dev/null
agent env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID "$OP" read op://all/x/y >/dev/null
check "all agents: other sessions run silently" [ "$(count 'prompting: .* op read op://all/x/y')" = 1 ]
SID=sess-K agent "$OP" read op://all/x/other -n >/dev/null
check "all agents: every field of that item" [ "$(count 'prompting: claude:sess-K')" = 0 ]
SID=sess-K agent "$OP" read op://day/x/y >/dev/null
check "all agents: only that item" [ "$(count 'prompting: claude:sess-K op read op://day/x/y')" = 1 ]
check "all agents: stored forever for every agent" python3 -c "
import json, sys
[a] = [a for a in json.load(open(sys.argv[1])) if a['key']['item'] == {'vaultId': 'all', 'itemId': 'x'}]
assert a['key']['audience'] == {'allAgents': {}} and a['expiresAt'].startswith('2100'), a
assert a['grantedTo'] == {'session': {'agent': 'claude', 'sessionId': 'sess-J'}}, a" "$OPPROXY_HOME/approvals.json"
check "all agents: listed" grep -q "^All agents" <<<"$("$BIN" list)"
start_daemon approved 1

# --- the approval feed: a paired phone answers before the (scripted, 30s late) dialog
FEED="$OPPROXY_HOME/approval-feed.sock"
phone() { "$BIN" test-feed-client "$FEED" "$@"; }
ask() { # session, then the phone's arguments; leaves the request's output in $WORK/asked
  local sid=$1; shift
  SID=$sid agent "$OP" read op://phone/item/field > "$WORK/asked" 2>&1 & local apid=$!
  res=$(phone "$@"); wait $apid; asked_rc=$?
}
start_daemon denied 30
agent "$OP" vault list >/dev/null   # authorizes, which the status reports
check "feed: reports the 1Password authorization on connect" python3 -c "
import json, socket, sys
s = socket.socket(socket.AF_UNIX); s.settimeout(10); s.connect(sys.argv[1])
f = s.makefile()
for line in f:
    m = json.loads(line)
    if m['type'] == 'status': break
st = m['status']
assert st['label'] == '1Password' and st['ok'] is True and st['since'] > 0, st
assert 'until' not in st and 'title' not in st, st" "$FEED"
ask sess-P approve once --doc "$WORK/phone-doc.json"
check "phone once: reply accepted" [ "$res" = '{"id":"'"$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["id"])' "$res")"'","ok":true,"type":"reply-result"}' ]
check "phone once: request ran" via_daemon "$(cat "$WORK/asked")"
check "phone once: nothing stored" not_in "sess-P" "$OPPROXY_HOME/approvals.json"
check "phone once: logged" grep -q "phone approve once: Test Phone" "$LOG"
check "phone: document headlines the item" grep -q '"title":"phone / item"' "$WORK/phone-doc.json"
check "phone: document offers the dialog's options" grep -q '"default":"once","id":"duration","label":"Allow","options":\[{"facets":\[{"name":"Allow","value":"Once"}\],"hint":"Runs this one request' "$WORK/phone-doc.json"
check "phone: lasting options split into Allow and For" grep -q '"facets":\[{"name":"Allow","value":"1 Day"},{"name":"For","value":"All agents"}\]' "$WORK/phone-doc.json"
check "phone: document carries the command line" grep -q '"context":{"command":"op ' "$WORK/phone-doc.json"
check "phone: document names the requester and item" grep -q '"item":{"detail":"Vault: phone","title":"item"}' "$WORK/phone-doc.json"
check "phone: document offers all agents" grep -q '"id":"forever-all","label":"Forever · All agents"' "$WORK/phone-doc.json"
check "phone: document confirms what approving grants" grep -q '"confirm":"Let Claude Code .*read field from “phone / item”"' "$WORK/phone-doc.json"

ask sess-Q approve 1d
check "phone 1d: request ran" via_daemon "$(cat "$WORK/asked")"
out=$(SID=sess-Q agent "$OP" read op://phone/item/field)
check "phone 1d: repeat runs without a prompt" [ "$(count 'prompting: claude:sess-Q')" = 1 ]
check "phone 1d: repeat ran" via_daemon "$out"
check "phone 1d: stored with the phone's proof" python3 -c "
import json, sys; from datetime import datetime
f = lambda s: datetime.fromisoformat(s.replace('Z', '+00:00'))
[a] = [a for a in json.load(open(sys.argv[1])) if a['key']['audience'].get('session', {}).get('sessionId') == 'sess-Q']
assert a['deviceProof']['keyId'] and 'signature' not in a, a
assert (f(a['expiresAt']) - f(a['approvedAt'])).total_seconds() == 86400" "$OPPROXY_HOME/approvals.json"
check "phone 1d: devices lists the phone" grep -q "^Test Phone  [0-9a-f]\{4\} " <<<"$("$BIN" devices)"
python3 - "$OPPROXY_HOME/approvals.json" <<'PY'
import json, sys
entries = json.load(open(sys.argv[1]))
for a in entries:
    if a['key']['audience'].get('session', {}).get('sessionId') == 'sess-Q': a['expiresAt'] = '2099-01-01T00:00:00Z'
json.dump(entries, open(sys.argv[1] + '.edited', 'w'))
PY
check "phone 1d: an extended expiry doesn't verify" grep -q "Ignoring 1 entry with invalid signatures" <<<"$(cp "$OPPROXY_HOME/approvals.json" "$WORK/approvals.saved"; cp "$OPPROXY_HOME/approvals.json.edited" "$OPPROXY_HOME/approvals.json"; "$BIN" list; cp "$WORK/approvals.saved" "$OPPROXY_HOME/approvals.json")"
start_daemon denied
SID=sess-Q agent "$OP" read op://phone/item/field >/dev/null 2>&1
check "phone 1d: still approved after a restart" [ "$(count 'prompting: claude:sess-Q')" = 1 ]
"$BIN" unpair --all >/dev/null
SID=sess-Q agent "$OP" read op://phone/item/field >/dev/null 2>&1
check "unpair: the phone's approvals stop working" [ "$(count 'prompting: claude:sess-Q')" = 2 ]
"$BIN" revoke sess-Q >/dev/null  # now unverifiable; later checks count invalid entries

start_daemon approved 30
ask sess-R deny
check "phone deny: request fails" [ "$asked_rc" = 1 ]
check "phone deny: explains to the agent" grep -q "user denied" "$WORK/asked"
ask sess-S approve once --twice
check "phone twice: first reply accepted" grep -q '"ok":true' <<<"$(head -1 <<<"$res")"
check "phone twice: second refused" grep -q '"error":"That request was already answered.","id":".*","ok":false' <<<"$(tail -1 <<<"$res")"
SID=sess-T agent "$OP" read op://phone/item/field > "$WORK/asked" 2>&1 & apid=$!
res=$(phone approve once --unpaired)
check "unpaired phone: refused" grep -q "This phone isn't paired with opProxy." <<<"$res"
res=$(phone approve once --tamper-hash)
check "tampered document hash: refused" grep -q "The phone's copy of this request isn't one opProxy sent." <<<"$res"
res=$(phone approve once --stale)
check "old reply: refused" grep -q "That reply is too old" <<<"$res"
res=$(phone deny); wait $apid
check "refused replies: request still answerable" grep -q "user denied" "$WORK/asked"

# --- phones hear of a request only once the Mac has left it unanswered for a while (2-3s here)
OPPROXY_PHONE_DELAY=2 start_daemon denied 30
started=$(date +%s)
ask sess-U deny
elapsed=$(( $(date +%s) - started ))
check "phone delay: the phone hears after the delay" [ "$elapsed" -ge 2 ]
check "phone delay: the phone's answer still decides" [ "$elapsed" -lt 20 ] && [ "$asked_rc" = 1 ]
OPPROXY_PHONE_DELAY=3 start_daemon denied 1
python3 -c "
import json, socket, sys, time
s = socket.socket(socket.AF_UNIX); s.settimeout(0.5); s.connect(sys.argv[1])
data = b''; end = time.time() + 5
while time.time() < end:
    try: data += s.recv(65536)
    except (TimeoutError, socket.timeout): pass
msgs = [json.loads(l) for l in data.splitlines() if l.strip()]
print(sum(m['type'] == 'upsert' or (m['type'] == 'snapshot' and bool(m.get('items'))) for m in msgs))" "$FEED" > "$WORK/seen" & lpid=$!
sleep 0.3
SID=sess-V agent "$OP" read op://phone/item/field >/dev/null 2>&1
wait $lpid
check "phone delay: answered on the Mac first, never reaches the phone" [ "$(cat "$WORK/seen")" = 0 ]
start_daemon approved 1

# --- approvals persist across daemon restarts
out=$(agent "$OP" read op://a/b/c)
check "restart: approval persisted" [ "$(count 'prompting: claude:sess-A op read op://a/b/c → a / b')" = 2 ]

# --- denial: error, nothing stored, next call prompts again
start_daemon denied
err=$(SID=sess-D agent "$OP" read op://d/e/f 2>&1 >/dev/null); rc=$?
check "denied: exit 1" [ $rc = 1 ]
check "denied: explains to the agent" grep -q "user denied" <<<"$err"
SID=sess-D agent "$OP" read op://d/e/f >/dev/null 2>&1
check "denied: not remembered" [ "$(count 'prompting: claude:sess-D')" = 2 ]

# --- 1Password's errors reach the caller, as op prints them
start_daemon approved
err=$(agent "$OP" read op://a/b/no-such-field 2>&1); rc=$?
check "1Password error: exit 1" [ $rc = 1 ]
check "1Password error: op's format" grep -q '^\[ERROR\] [0-9/]* [0-9:]* no field no-such-field$' <<<"$err"

# --- raw socket clients get the same routing, verification and approval as the shim
cat > "$WORK/raw.py" <<'PY'
import json, socket, sys
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1])
req = {"session": {"agent": "claude", "sessionId": "sess-RAW"}, "argv": json.loads(sys.argv[2]),
       "env": {}, "cwd": "/", "requiresApproval": False, "daemonArgv": ["item", "delete", "x"]}
s.sendall(json.dumps({"proxy": {"_0": req}}).encode() + b"\n")
out = b""
while chunk := s.recv(65536): out += chunk
r = json.loads(out); print(r["exitCode"], r.get("passthrough")); print(__import__("base64").b64decode(r["stderr"]).decode(), end="")
PY
raw() { SID=sess-RAW agent python3 "$WORK/raw.py" "$OPPROXY_HOME/daemon.sock" "$1"; }
out=$(raw '["item","share","x","--emails","a@b.c"]')
check "raw socket: unhandled command rejected" grep -q "opProxy doesn't answer \`op item share\`" <<<"$out"
check "raw socket: rejected arguments never logged" [ "$(count a@b.c)" = 0 ]
raw '["read","op://raw/item/field"]' >/dev/null
check "raw socket: forged requiresApproval ignored" [ "$(count 'prompting: claude:sess-RAW op read op://raw/item/field')" = 1 ]

# --- the 1Password helper: authorized once, replaced by refresh, watched for the end
check "status: authorized after a run" grep -q "1Password: authorized .* ago (since " <<<"$(status)"
helper1=$(grep -o "refreshed: helper - → [0-9]*" "$LOG" | tail -1 | grep -o "[0-9]*$")
out=$("$BIN" refresh 2>&1); rc=$?
check "refresh: succeeds" [ $rc = 0 ]
check "refresh: a new helper" grep -q "refreshed: helper $helper1 → [0-9]*; 1Password authorized for me@stub.com" "$LOG"
check "refresh: requests still answered" via_daemon "$(agent "$OP" read op://a/b/c)"
touch "$SDK/refuse-auth"
out=$("$BIN" refresh 2>&1); rc=$?
check "refresh declined: reports failure" [ $rc = 1 ]
check "refresh declined: shows 1Password's error" grep -q "authorization dismissed" <<<"$out"
check "refresh declined: keeps the old session" via_daemon "$(agent "$OP" read op://a/b/c)"
rm -f "$SDK/refuse-auth"
rm -f "$SDK/authorized"; sleep 2.5
check "heartbeat: notices the end" grep -q "1Password: not authorized" <<<"$(status)"
check "heartbeat: logs how long it lasted" grep -q "1Password authorization ended after <1m: invalid client id" "$LOG"
check "next request: authorizes again" via_daemon "$(agent "$OP" read op://a/b/c)"

# --- every request is resolved to one item, by ID, before approval, and runs pinned to it
SID=sess-N agent "$OP" read op://zyxwvutsrqponmlkjihgfedcba/abcdefghijklmnopqrstuvwxyz/password >/dev/null
check "IDs: dialog shows the item's name" grep -q '"item":"Stub Item Title"' "$LOG"
check "IDs: dialog shows the vault's name" grep -q '"vault":"Stub Vault"' "$LOG"
check "IDs: approval labelled by name" grep -q '"itemLabel" : "Stub Item Title"' "$OPPROXY_HOME/approvals.json"
out=$(SID=sess-N agent "$OP" item get "stub item title" --vault "stub vault" --fields label=username)
check "names: the same item by name needs no prompt" [ "$(count 'prompting: claude:sess-N')" = 1 ]
check "names: reads that item" [ "$out" = "v:abcdefghijklmnopqrstuvwxyz:username" ]
err=$(SID=sess-N agent "$OP" item get "Shared Name" 2>&1); rc=$?
check "ambiguous: refused" [ $rc = 1 ]
check "ambiguous: lists the candidates" grep -q "matches 2 items: shared1shared1shared1share (“Shared Name” in Stub Vault), shared2" <<<"$err"
err=$(SID=sess-N agent "$OP" item get "Stub Item" 2>&1); rc=$?
check "substring: no match" grep -q "no item matches “Stub Item”" <<<"$err"
check "unresolved: never prompts" [ "$(count 'prompting: claude:sess-N')" = 1 ]
check "unlisted flag: passes through" not_daemon "$(SID=sess-N agent "$OP" item get "Stub Item Title" --share-link)"

# --- "this agent" approvals follow the claimed session ID, so a command that claims another
# session's ID reaches its approvals (README: known weaknesses)
SID=sess-B agent "$OP" read op://x/y/z >/dev/null
INST=sess-A SID=sess-A agent env CLAUDE_CODE_SESSION_ID=sess-B "$OP" read op://x/y/z >/dev/null
check "exec env session swap: reaches that session's approvals" [ "$(count 'prompting: claude:sess-B op read op://x/y/z')" = 1 ]

# --- forged or edited approvals.json entries don't verify
python3 - "$OPPROXY_HOME/approvals.json" <<'PY'
import json, sys
entries = json.load(open(sys.argv[1]))
forged = json.loads(json.dumps(entries[0]))
forged["key"]["audience"] = {"session": {"agent": "claude", "sessionId": "sess-E"}}
forged["key"]["item"] = {"vaultId": "forged", "itemId": "item"}
json.dump(entries + [forged], open(sys.argv[1], "w"))
PY
check "forged approval: listed as invalid" grep -q "Ignoring 1 entry with invalid signatures" <<<"$("$BIN" list)"
SID=sess-E agent "$OP" read op://forged/item/field >/dev/null
check "forged approval: prompts" [ "$(count 'prompting: claude:sess-E op read op://forged/item/field')" = 1 ]

# --- the op the daemon asks for accounts must be 1Password's signed binary
rm -f "$SDK/authorized"
OP_REQUIREMENT= start_daemon approved
runs=$(wc -l < "$WORK/stub-runs")
err=$(agent "$OP" read op://a/b/c 2>&1); rc=$?
check "unsigned op: refused" grep -q "no 1Password-signed op" <<<"$err"
check "unsigned op: never ran" [ "$(wc -l < "$WORK/stub-runs")" = "$runs" ]

# --- op runs only if the kernel loaded the exact binary that passed the signature check.
# /bin/echo (Apple-signed) stands in for op; the swap knob launches /bin/ls instead, as if it
# replaced the file between the check and exec.
SAVED_OP=$OPPROXY_REAL_OP
export OPPROXY_REAL_OP=/bin/echo
OP_REQUIREMENT="anchor apple" start_daemon approved
out=$("$BIN" refresh 2>&1)
check "signed op: runs after the loaded-code check" grep -q "could not list 1Password accounts" <<<"$out"
stop_daemon
OPPROXY_TEST_SWAP_OP=/bin/ls OP_REQUIREMENT="anchor apple" start_daemon approved
out=$("$BIN" refresh 2>&1)
check "swapped op: refused" grep -q "changed between its 1Password signature check and launch" <<<"$out"
stop_daemon
export OPPROXY_REAL_OP=$SAVED_OP
start_daemon approved

# --- the helper must be the daemon's own build
agent "$OP" read op://a/b/c >/dev/null
cp "$DAEMON_BIN" "$WORK/opProxy.orig"; rm "$DAEMON_BIN"; cp /bin/ls "$DAEMON_BIN"
err=$("$BIN" refresh 2>&1); rc=$?
check "swapped binary: refresh refused" grep -q "isn't this build" <<<"$err"
check "swapped binary: old session keeps working" via_daemon "$(agent "$OP" read op://a/b/c)"
rm "$DAEMON_BIN"; mv "$WORK/opProxy.orig" "$DAEMON_BIN"

# --- automatic authorization: at startup, again when it ends, but not after a decline
rm -f "$SDK/authorized"
OPPROXY_NO_AUTO_AUTH= start_daemon approved
sleep 1.5
check "auto-auth: at startup" grep -q "1Password authorized for me@stub.com (stub.1password.com): opProxy just started." "$LOG"
check "auto-auth: authorized without any request" grep -q "1Password: authorized" <<<"$(status)"
rm -f "$SDK/authorized"; sleep 2.5
check "auto-auth: re-authorizes when it ends" grep -q "1Password: authorized" <<<"$(status)"
touch "$SDK/refuse-auth"; rm -f "$SDK/authorized"; sleep 3.5
declines=$(grep -c "refresh failed: authorization dismissed" "$LOG")
sleep 3
check "auto-auth: a decline isn't retried" [ "$(grep -c "refresh failed: authorization dismissed" "$LOG")" = "$declines" ]
check "auto-auth: declined once" [ "$declines" -ge 1 ]
rm -f "$SDK/refuse-auth"
start_daemon approved

# --- revoke is picked up by the running daemon
"$BIN" revoke sess-A >/dev/null
agent "$OP" read op://a/b/c >/dev/null
check "revoke: running daemon prompts again" [ "$(count 'prompting: claude:sess-A op read op://a/b/c → a / b')" = 3 ]

# --- the Installed switch
"$BIN" disable >/dev/null
check "disabled: straight to the real op" not_daemon "$(agent "$OP" read op://a/b/c)"
"$BIN" enable >/dev/null
check "enabled again: proxied" via_daemon "$(agent "$OP" read op://a/b/c)"

# --- a reader that stops early doesn't crash the shim
agent /bin/bash -c "$OP item list | head -1" >/dev/null 2>"$WORK/pipe.err"
check "closed pipe: no crash" not_in "Terminating app" "$WORK/pipe.err"

# --- the label command: names the agent in the dialog; the title is stored, the name never
cat > "$WORK/label" <<'LABEL'
#!/bin/bash
# Names the agent from the variable the config forwards, as a terminal's own script would.
input=$(cat)
grep -q '"TERM_SURFACE":"s-1"' <<<"$input" && echo '{"name": "Kevin", "title": "fix flaky tests", "openURL": "example://s-1"}'
LABEL
chmod +x "$WORK/label"
cat > "$OPPROXY_HOME/config.json" <<CONFIG
{"requesterLabel": {"command": ["$WORK/label"], "environment": ["TERM_SURFACE"]}}
CONFIG
start_daemon approved
TERM_SURFACE=s-1 SID=sess-N agent "$OP" read op://n/a/me >/dev/null
check "label: dialog shows the agent's name" grep -q '"headline":"Kevin".*"label":"fix flaky tests".*"requester":"Kevin (Claude Code)"' "$LOG"
check "label: approval stores the title" grep -q '"sessionLabel" : "fix flaky tests"' "$OPPROXY_HOME/approvals.json"
check "label: approval never stores the name" not_in Kevin "$OPPROXY_HOME/approvals.json"
rm "$OPPROXY_HOME/config.json"

echo; echo "$PASS passed, $FAIL failed"
[ $FAIL = 0 ]
