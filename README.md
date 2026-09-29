# opProxy

A drop-in `op` for AI agents. Each agent session approves each exact 1Password CLI command once, through a dialog that says who is asking and why. Repeats run silently for 7 days while that agent process lives.

## Why agents trigger Touch ID on every call

1Password scopes CLI authorization to the Unix session (`getsid`), and Claude Code, Codex and Cursor start every tool call in a new session.

opProxy runs the real `op` inside one long-lived **session holder**: a child of the launchd daemon that leads its own Unix session. 1Password authorizes that session once. A `whoami` poll every minute keeps 1Password's 10-minute idle timeout from firing and drives the menu bar icon. 1Password still ends the authorization 12 hours after it starts, or when the app locks. **Refresh Now** authorizes a new holder with one 1Password prompt and then switches traffic to it, so nothing fails while the prompt is open. Secrets are never stored.

## Flow

`~/opProxy/bin/op` links to the executable inside `bin/opProxy.app`, and PATH puts it ahead of Homebrew. It's an app bundle so macOS remembers its "access data from other apps" grant.

**Proxied** (sent to the daemon) whenever the command is read-only, from agents and terminals alike, so opProxy's dialog is always the one you see.

These can return secret values, so they need approval:
- `read` (including `-o FILE`, which the shim writes in the caller's cwd)
- `item get` (including `--otp`)
- `document get`

These are metadata and run without a dialog:
- `item list`, `document list`
- `vault list`, `vault get`
- `whoami`, `account list`, `account get`

**Exec'd unchanged as the real `op`**, so 1Password prompts exactly as before:
- opProxy switched off (menu bar **Installed** unchecked, or `opProxy disable`)
- writes, `op run`, `op inject`, `item share`, `signin`, `plugin run`, token creation
- stdin input, `--config`, `--session`
- service-account, Connect or `OP_SESSION_*` credentials
- the daemon being down

The daemon then:
1. Re-derives routing from `argv`. Anything that talks to the socket directly gets the same rules as the shim.
2. Walks the caller's process ancestry to the nearest **genuinely signed agent binary**: `claude` (Anthropic, Q6L2SF6YDW), `codex` (2DC432GLL2), or cursor-agent (Node.js-signed `node` running Cursor's `index.js`).
3. **Agents:** checks `~/.opProxy/approvals.json` for the key (agent process PID + start time, claimed session ID, exact argv, allowlisted `OP_*` env). Entries only count if their signature verifies.
   **Terminals** (no genuine agent above the caller): approvals work like 1Password's own. One approval covers every read from that terminal tab (Unix session) until it's unused for 10 minutes, and never beyond 12 hours. They're kept in memory only. The dialog shows the terminal app, TTY and the process chain up to the tab's shell.
4. Otherwise shows the approval dialog. Touch ID both approves and signs the approval with this Mac's Secure Enclave key. Deny, cancel or 110 seconds of silence returns an error that tells the agent to ask you first; denials aren't remembered.
5. Runs `op` in the holder, but only after checking the file is 1Password's signed binary (team 2BUA8C4S2C). `op` gets a minimal environment.

## Tamper resistance (no root)

Blocked:
- **Forged or edited approvals.** Signatures come from a Secure Enclave key that needs user presence for every signature. The public key is compiled into the binary (`ApprovalKeyPin.swift`, written by `install.sh`), so swapping the key blob only breaks approvals.
- **Env-var session spoofing, including `exec env CLAUDE_CODE_SESSION_ID=…`.** Approvals belong to the agent process, and a forged ID only matches approvals made inside the same process.
- **A wrapper swapped in for `/opt/homebrew/bin/op`.** It fails the 1Password signature check.
- **A binary swapped into `bin/opProxy.app`.** It can't become the next session holder, because the holder must match the running daemon's code hash (read from the kernel).
- **Test knobs** (`OPPROXY_*`): they exist only in debug builds.

Not blocked:
- **Replacing `bin/opProxy.app` or the LaunchAgent plist and restarting the daemon.** The restart drops 1Password's authorization, so the next request brings an unexpected 1Password prompt and the icon turns red. That's the tell.
- **An agent editing this source and waiting for you to run `install.sh`.**
- **An agent resuming another session** (`claude --resume <id>`). It gets its own process, so it has to be approved again; the risk is approving it.
- **A convincing fake dialog context.** Transcripts and Spaceterm titles are user-writable.

A resumed session is a new agent process, so its first use of each command prompts again.

## Commands

```
opProxy list | revoke --all | revoke <session-id>
opProxy status | refresh
opProxy disable | enable     # same as the menu bar's Installed checkbox
./install.sh     # build, pin key, sign bin/opProxy.app (bin/op and bin/opProxy link into it), restart the LaunchAgent
```

Signing works like VoiceOp and Claude Usage Tray: the first `Developer ID Application|Apple Development` identity, with identifier `com.chriswa.opproxy`. That keeps macOS's "access data from other apps" grant across rebuilds.

- **Log:** `~/.opProxy/daemon.log` (proxied command lines only).
- **LaunchAgent:** `~/Library/LaunchAgents/com.chriswa.opproxy.plist`.

## Tests

`Sources/opProxy/ApprovalKeyPin.swift` is per-Mac and untracked; `./install.sh` creates it, so run that once on a fresh checkout before `swift build`.

```
swift test                                   # parsing, signed approvals, identity, durations
swift build && Tests/integration.sh          # shim + daemon + holder vs a stub op and fake agent
```
