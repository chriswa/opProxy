# opProxy

A drop-in `op` that puts one approval dialog in front of 1Password CLI reads from AI agents and terminals. You approve each secret once, with Touch ID, in a dialog that shows the item, who is asking and why, or from a paired iPhone running Spaceterm. Repeats then run silently for as long as you chose.

## How it works

1Password scopes CLI authorization to the Unix session (`getsid`). Claude Code, Codex and Cursor start every tool call in a new session, so without opProxy every `op` call raises a 1Password Touch ID prompt that gives no context.

`~/opProxy/bin/op` is a link into `bin/opProxy.app`, and PATH puts it ahead of Homebrew's `op`. When invoked as `op`, it sends read-only commands over a Unix socket to a launchd daemon. The daemon runs the real `op` inside a **session holder**, a child process that leads its own Unix session. 1Password authorizes that one session, and every approved request runs in it.

- **Authorization.** The daemon asks 1Password for access at startup, whenever the authorization ends, and when 1Password's 12-hour limit is reached. While 1Password's prompt is up, and the macOS privacy dialog that can precede it, a teal opProxy backdrop frames the prompt and explains why it's appearing, and each prompt it frames plays the approval dialog's chime as it appears. A `whoami` check every minute keeps 1Password's 10-minute idle timeout from firing, and it never raises a prompt itself.
- **Secrets are never stored.** Each approved request is a live `op` call.

### What gets proxied

Every read-only command is proxied, whether it comes from an agent or a terminal.

| Kind | Commands | Dialog |
|---|---|---|
| Can return secret values | `read` (including `-o FILE`, written by the shim in the caller's directory), `item get` (including `--otp`), `document get` | Yes |
| Metadata | `item list`, `document list`, `vault list`, `vault get`, `whoami`, `account list`, `account get` | No |

Each command that can return secret values reads exactly one item, so opProxy works out which item before anything else:
- **Only known shapes.** One item, named by its ID or title, plus allowlisted flags (`--vault`, `--fields`, `--reveal`, `--otp`, `--include-archive`, `-n`, `--format`, `--account` and a few display flags). Anything else, such as `--share-link` or a second item, goes to the real `op`.
- **Resolved from the item list.** The daemon reads `op item list`, which returns no secrets, and finds the item by its ID, else its exact title, else its title in any case. A vault narrows the search, by ID or by name in any case. Substrings never match. No match, or several (the same title in two vaults), fails with a message that lists the candidates, and no dialog appears.
- **Run by ID.** The command runs with the item and vault replaced by their IDs, so what runs is exactly the item that was checked and approved.

The real `op` runs unchanged, so 1Password prompts exactly as it always has, for:
- writes, `op run`, `op inject`, `item share`, `signin`, `plugin run`, and token creation
- stdin input, `--config` or `--session`
- service-account, Connect or `OP_SESSION_*` credentials
- the daemon being stopped
- opProxy being switched off (menu bar **Installed**, or `opProxy disable`)

### Who is asking

The daemon walks the caller's process ancestry, looking for the nearest **genuinely signed agent binary**:
- `claude`, signed by Anthropic (Q6L2SF6YDW)
- `codex`, signed with team 2DC432GLL2
- `cursor-agent`, a Node.js-signed `node` running Cursor's own `index.js`

**Agents.** An approval covers one item: every field of it, through `read`, `item get` or `document get`. It's stored with the item's ID, its vault's ID and the account (`--account` or `OP_ACCOUNT`, if given). The dialog asks two things:
- **Allow: Once · 1 Day · Forever.** Once is the default and remembers nothing.
- **For: This agent · All agents.** Only applies to 1 Day and Forever. This agent means the session ID the agent claims, so a resumed session (`claude --resume <id>`) is covered too; an agent that names no session gets just its running process. All agents means every Claude Code, Codex and Cursor session, including ones started later.

**Terminals and scripts** (no genuine agent above the caller). The approval works like 1Password's own: one approval covers every read from that terminal tab (Unix session) until it has been unused for 10 minutes, and never beyond 12 hours. The dialog shows the terminal app, the TTY and the process chain up to the tab's shell. These approvals are kept in memory only.

### The approval dialog

- **Always on top, one at a time.** The dialog takes focus and plays a rising, question-like chime when it appears. Any other requests wait in a queue, with a count shown; requests for the same item from the same agent or tab share one dialog.
- **Who, then what, in the largest type.** First the agent's name, then the item as "Vault / Item". For a request from a Spaceterm surface the name is the one Spaceterm gave it ("Kevin"), with "Claude Code · in “fix flaky tests”" beneath; otherwise it's "Claude Code Agent" (or Codex, Cursor). Spaceterm reuses names once a surface is archived, so the name appears only in live prompts (the dialog, the phone and the Touch ID reason) and is never saved with an approval; stored approvals keep only the surface's title.
- **Context comes next:** the fields asked for, the item and vault IDs, the `op` command as the agent wrote it, the agent's full shell command (recovered from the process tree), its most recent transcript message, then PIDs and the working directory.
- **Only Touch ID approves.** The dialog embeds Apple's inline Touch ID glyph (`LAAuthenticationView`), so there's no separate system sheet.
- **Deny, or wait for the countdown.** The Deny button shows the countdown; after 110 seconds the request is denied.
- **Guarded input.** The keyboard does nothing except ⌘C, and clicks are ignored for 500ms after the dialog appears.
- **Agents that stop waiting.** If an agent gives up before you answer, the dialog says so. Approving still lets the agent's retry go through silently.

### Approving from your phone

Every request that would show the dialog is also published on a feed socket, `~/.opProxy/approval-feed.sock`, which Spaceterm relays to its iPhone app. The protocol is `~/spaceterm/APPROVAL_FEED.md`.

- **The authorization on the phone.** The feed also reports whether 1Password has authorized opProxy and until when, so the phone shows the time left on its bottom bar, and a notification when the authorization is lost.
- **The same chime.** A new request rings the phone with the dialog's chime while Spaceterm is open on it.
- **Same options as the desktop.** The phone shows what the dialog shows (the item, the request, the `op` command, the agent's shell command and last message, PIDs and directory) and offers the same choices as one list: **Once**, then **1 Day** and **Forever**, each for this agent or all agents, for agents; **Once · This Terminal Tab** for terminals.
- **The first answer wins.** The dialog and the phone ask at the same time. Answer on either and the other one goes away; a late answer from the other side is refused. A request leaves the phone when it's answered anywhere or times out, and its countdown on the phone starts when its dialog appears on the Mac.
- **Phone approvals work like Touch ID ones.** A lasting agent approval from the phone is stored and lasts just as long. It can't be signed by the Mac's Secure Enclave key without your Touch ID, so it's stored with the phone's own signed reply instead. That reply commits to the exact entry (which agents, item, approval time and expiry), so it can't be edited, moved to another request, widened to all agents or extended.
- **Pairing.** The phone asks to pair over the feed. The Mac shows the phone's name and key fingerprint, with the approval dialog's chime; check the phone shows the same fingerprint, click **Pair…**, then touch Touch ID. The paired key is signed with the approval key, so nothing can pair a phone without your Touch ID.
- **Unpairing.** `opProxy devices` lists paired phones with their fingerprints, and `opProxy unpair <key-id> | --all` (or the menu's **Paired Phones**) removes one. Unpairing a phone also ends every lasting approval made on it.

### Menu bar

- **Status icon.** A key with the time left on the 1Password authorization, rounded to the nearest unit ("12h", "32m"). When it's unauthorized or past the 12 hours, it becomes a red snapped key.
- **Refresh Now.** Authorizes a fresh session before the current one runs out. The old session keeps serving requests until the new one is ready.
- **Recent Approvals.** Up to 20 active approvals, newest first. Each one has a submenu:
  - its details
  - **Duration** (1 Day from now, or Forever, with the current setting checked)
  - **For** (This Session or All Agents). An all-agents approval narrows back to the session that asked for it.
  - **Revoke This Approval**
  - **Revoke Everything for This Session** (not shown for all-agents approvals)

  Changing either re-signs the approval. It reuses your most recent approval's Touch ID, so it only asks again after a daemon restart. **Revoke All** sits at the bottom of the list.
- **Paired Phones.** Each paired phone with its fingerprint; choosing one unpairs it.
- **Installed.** Turns proxying off and on everywhere. When it's off, `op` goes straight to 1Password.
- **Open at Login**, **Restart opProxy**, **Quit opProxy.** The LaunchAgent relaunches the daemon only after a crash, so Quit stays quit until you log in again or open `bin/opProxy.app`.

## Install

```
./install.sh
```

The script:
1. Builds the release binary.
2. Creates this Mac's Secure Enclave approval key on the first run and pins its public key into the build (`Sources/opProxy/ApprovalKeyPin.swift`, per-Mac and untracked).
3. Wraps the binary in `bin/opProxy.app`, signed like VoiceOp and Claude Usage Tray: the first `Developer ID Application|Apple Development` identity, bundle ID `com.chriswa.opproxy`, hardened runtime.
4. Links `bin/op` and `bin/opProxy` into the bundle.
5. Writes and restarts the LaunchAgent (`~/Library/LaunchAgents/com.chriswa.opproxy.plist`), keeping your Open at Login choice.

`~/.zshrc` and `~/.zprofile` prepend `~/opProxy/bin` to PATH. Agent sessions that started before that change keep their old PATH until they restart.

Every daemon start brings a macOS "access data from other apps" dialog: `op` reads 1Password's group container, and macOS charges that to opProxy. 1Password's prompt follows.

```
opProxy status | refresh
opProxy list | revoke --all | revoke <session-id>
opProxy disable | enable
opProxy devices | unpair <key-id> | unpair --all
```

The log is `~/.opProxy/daemon.log`. It records proxied command lines only; passthrough commands, which can carry secrets as arguments, are never logged.

## Security measures

opProxy runs as your own user, with no root component. Every measure below assumes the attacker is a malicious or prompt-injected agent running as you. Such an agent can read this source, write anywhere in your home directory (including `/opt/homebrew`), set any environment variables, start processes, and connect to the daemon's socket.

- **One authorized session, unreachable.** Only the session holder's Unix session has 1Password's authorization, and processes can't join another session. The holder takes instructions only over a pipe from the daemon.
- **The daemon decides everything.** It works out routing and the need for approval from `argv` itself, and never trusts fields a client sends. A raw socket client gets the same rules as the shim, and writes are refused outright.
- **Agents are recognized by code signatures, not the environment.** Only a process with its vendor's code signature counts as an agent.
  - A process renamed to `claude` isn't treated as an agent.
  - An agent that strips its session variables is still treated as an agent, not a terminal.
- **Phone replies are signed by the phone.** Anything running as you can connect to the feed socket and to Spaceterm's, so the feed acts only on replies signed by a paired phone's key, for a request it has pending and a document it actually sent. Phone approvals stored for later carry that signed reply, which commits to the exact entry, and stop verifying once the phone is unpaired.
- **Approvals can't be forged.** Each agent approval, including which agents it covers and its expiry, is signed by a Secure Enclave P-256 key that requires user presence for every signature. The private key can't leave this Mac's Secure Enclave. The daemon verifies entries against a public key compiled into the binary, so editing, replaying or adding entries in `approvals.json` does nothing, and swapping the key blob only breaks approvals.
- **Only 1Password's `op` runs in the session.** Before each run, the daemon checks the `op` file's code signature against 1Password's team (2BUA8C4S2C). It then starts `op` suspended and resumes it only if the kernel's code hash for the loaded code matches the file it verified. Swapping `op` on disk, even mid-launch, gets the process killed before it executes.
- **Only this build can hold the session.** A new session holder must have the same kernel-reported code hash as the running daemon, so a binary swapped into the bundle can't receive the next refresh's authorization.
- **Minimal environment for `op`.** Nothing from launchd or the plist is inherited. Only display and account `OP_*` variables are forwarded; `OP_CONFIG_DIR` and biometric settings are dropped.
- **Test knobs** (`OPPROXY_*`), such as auto-approval or a fake `op`, exist only in debug builds.
- **Hardened runtime** on a real signing identity blocks debugger attachment and dylib injection into the daemon.
- **The dialog can't be approved by accident.** Only Touch ID approves, and the keyboard does nothing.

## Known security weaknesses

**Can yield secrets without your Touch ID:**
- **Keystrokes typed into an approved terminal tab.** A tab approval covers every read for 10 idle minutes, so anything that can type into that tab (for example Spaceterm's `ship-it`, or AppleScript with Automation permission) can run `op read … | curl …` there. This is by design and matches 1Password's own per-tab model.
- **Reuse of approved items.** A prompt-injected agent can read any field of an item you approved for all agents, or for its own session, for the duration you chose. That's limited to those items.
- **Session IDs can be claimed.** This-agent approvals follow the session ID in the caller's environment, which opProxy can't verify. An agent that sets `CLAUDE_CODE_SESSION_ID` (or runs `exec env …`) to another session's ID reaches that session's approvals, so in practice a this-agent approval is open to any agent that knows the session ID. Session IDs appear in transcript file names under `~/.claude/projects`.
- **Metadata is free.** Item titles, vaults, URLs and usernames come back from listings without any dialog.
- **Changes from the menu.** Anything with Accessibility permission could click the menu to extend an existing approval or widen it to all agents, since those changes reuse your last Touch ID. It can't create new approvals.

**Can yield secrets from your phone, without Touch ID:**
- **Phone approvals need no biometric.** The Spaceterm app signs a reply with its Secure Enclave key once you drag the slide control in its native panel all the way across. Neither Face ID nor Touch ID is involved.
- **Only the native panel is trustworthy.** The rest of the request on the phone (item, command, agent context) is drawn by Spaceterm's web page, which agents can modify. A modified page can show you a harmless-looking request while the native panel's one-line confirmation ("Let Claude Code … read …") and the option you chose describe what you're really approving. Read that line.
- **A lost or stolen unlocked phone.** Anyone holding it unlocked, with the app open, can approve requests that are pending. Unpair it (`opProxy unpair`), which also ends the lasting approvals made on it.

**Need your Touch ID, but could trick you into giving it:**
- **A replaced opProxy.** An agent can replace `bin/opProxy.app` or the LaunchAgent plist and restart the daemon, or edit this source and wait for your next `./install.sh`. The fake daemon then needs 1Password's prompt to be authorized, and you approve those prompts routinely. An unexpected 1Password prompt, outside startup or the 12-hour cadence, is the warning sign. A root-owned install (binary, plist and a verified copy of `op` in locations only root can write) would close this, but needs sudo.
- **Unverified dialog context.** The session ID, Spaceterm title and "last message" come from the caller or from files the agent can write. The agent process, command and item shown are genuine.

## Future improvement: a persistent 1Password authorization

1Password ends every CLI authorization after 12 hours at most, so opProxy has to ask again about twice a day. That regular cadence is itself a risk, because it trains you to approve 1Password prompts without thinking.

If there were a supported way to hold a CLI authorization indefinitely, opProxy could ask 1Password once, at install, and every later decision would happen in opProxy's own dialogs. An unexpected 1Password prompt would then always be a red flag.

None of the options available today fits:
- **Service accounts** don't expire, but they can't read personal or Employee vaults, need an admin to create, and their token would be a secret stored outside 1Password.
- **Connect servers** have the same stored-token problem.
- **Manual `op signin` sessions** expire even sooner.

A future 1Password option that trusts a specific signed app, or allows longer authorization windows, would make this possible.

## Tests

`Sources/opProxy/ApprovalKeyPin.swift` is per-Mac and untracked, and `./install.sh` creates it. Run that once on a fresh checkout before building.

```
swift test                             # parsing, signed approvals, phone proofs and pairing, identity, durations, terminal approvals
swift build && Tests/integration.sh    # shim, daemon, holder and approval feed against a stub op, a fake agent and a fake phone
swift build && .build/debug/opProxy render-dialog <dir> --on-screen   # dialog and backdrop screenshots
```
