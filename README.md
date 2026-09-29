# opProxy

A drop-in `op` that puts one approval dialog in front of 1Password CLI reads from AI agents and terminals. You approve each secret once, with Touch ID, in a dialog that shows the item, who is asking and why. Repeats then run silently for as long as you chose.

## How it works

1Password scopes CLI authorization to the Unix session (`getsid`). Claude Code, Codex and Cursor start every tool call in a new session, so without opProxy every `op` call raises a 1Password Touch ID prompt that gives no context.

`~/opProxy/bin/op` is a link into `bin/opProxy.app`, and PATH puts it ahead of Homebrew's `op`. When invoked as `op`, it sends read-only commands over a Unix socket to a launchd daemon. The daemon runs the real `op` inside a **session holder**, a child process that leads its own Unix session. 1Password authorizes that one session, and every approved request runs in it.

- **Authorization.** The daemon asks 1Password for access at startup, whenever the authorization ends, and when 1Password's 12-hour limit is reached. While 1Password's prompt is up, and the macOS privacy dialog that can precede it, a teal opProxy backdrop frames the prompt and explains why it's appearing. A `whoami` check every minute keeps 1Password's 10-minute idle timeout from firing, and it never raises a prompt itself.
- **Secrets are never stored.** Each approved request is a live `op` call.

### What gets proxied

Every read-only command is proxied, whether it comes from an agent or a terminal.

| Kind | Commands | Dialog |
|---|---|---|
| Can return secret values | `read` (including `-o FILE`, written by the shim in the caller's directory), `item get` (including `--otp`), `document get` | Yes |
| Metadata | `item list`, `document list`, `vault list`, `vault get`, `whoami`, `account list`, `account get` | No |

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

**Agents.** An approval covers one exact command (argv plus any allowed `OP_*` variables) in one agent session, inside one running agent process (PID and start time). You choose how long it lasts: **Once · 1 Hour · 7 Days · 3 Months · Forever**. It still ends when that agent process exits, so a resumed session asks again.

**Terminals and scripts** (no genuine agent above the caller). The approval works like 1Password's own: one approval covers every read from that terminal tab (Unix session) until it has been unused for 10 minutes, and never beyond 12 hours. The dialog shows the terminal app, the TTY and the process chain up to the tab's shell. These approvals are kept in memory only.

### The approval dialog

- **Always on top, one at a time.** The dialog takes focus when it appears. Any other requests wait in a queue, with a count shown; identical requests share one dialog.
- **The item is the headline.** Opaque item and vault IDs are resolved to their names through the real `op`, ahead of the dialog.
- **Context comes next:** the details, the exact `op` command, the agent's full shell command (recovered from the process tree), its most recent transcript message, then PIDs and the working directory.
- **Only Touch ID approves.** The dialog embeds Apple's inline Touch ID glyph (`LAAuthenticationView`), so there's no separate system sheet.
- **Deny, or wait for the countdown.** The Deny button shows the countdown; after 110 seconds the request is denied.
- **Guarded input.** The keyboard does nothing except ⌘C, and clicks are ignored for 500ms after the dialog appears.
- **Agents that stop waiting.** If an agent gives up before you answer, the dialog says so. Approving still lets the agent's retry go through silently.

### Menu bar

- **Status icon.** A key with the time left on the 1Password authorization, rounded to the nearest unit ("12h", "32m"). When it's unauthorized or past the 12 hours, it becomes a red snapped key.
- **Refresh Now.** Authorizes a fresh session before the current one runs out. The old session keeps serving requests until the new one is ready.
- **Recent Approvals.** Up to 20 active approvals, newest first. Each one has a submenu:
  - its details
  - **Duration** (1 Hour, 7 Days, 3 Months or Forever, counted from now, with the current setting checked)
  - **Revoke This Approval**
  - **Revoke Everything for This Session**

  Changing the duration re-signs the approval. It reuses your most recent approval's Touch ID, so it only asks again after a daemon restart. **Revoke All** sits at the bottom of the list.
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
```

The log is `~/.opProxy/daemon.log`. It records proxied command lines only; passthrough commands, which can carry secrets as arguments, are never logged.

## Security measures

opProxy runs as your own user, with no root component. Every measure below assumes the attacker is a malicious or prompt-injected agent running as you. Such an agent can read this source, write anywhere in your home directory (including `/opt/homebrew`), set any environment variables, start processes, and connect to the daemon's socket.

- **One authorized session, unreachable.** Only the session holder's Unix session has 1Password's authorization, and processes can't join another session. The holder takes instructions only over a pipe from the daemon.
- **The daemon decides everything.** It works out routing and the need for approval from `argv` itself, and never trusts fields a client sends. A raw socket client gets the same rules as the shim, and writes are refused outright.
- **Identity comes from code signatures, not the environment.** Agents are recognized by their vendors' code signatures on the running process, and approvals are bound to that process's PID and start time.
  - Setting `CLAUDE_CODE_SESSION_ID`, or `exec env …` in a tool call, can't reach another process's approvals.
  - A process renamed to `claude` isn't treated as an agent.
  - An agent that strips its session variables is still treated as an agent, not a terminal.
- **Approvals can't be forged.** Each agent approval, including its expiry, is signed by a Secure Enclave P-256 key that requires user presence for every signature. The private key can't leave this Mac's Secure Enclave. The daemon verifies entries against a public key compiled into the binary, so editing, replaying or adding entries in `approvals.json` does nothing, and swapping the key blob only breaks approvals.
- **Only 1Password's `op` runs in the session.** Before each run, the daemon checks the `op` file's code signature against 1Password's team (2BUA8C4S2C). It then starts `op` suspended and resumes it only if the kernel's code hash for the loaded code matches the file it verified. Swapping `op` on disk, even mid-launch, gets the process killed before it executes.
- **Only this build can hold the session.** A new session holder must have the same kernel-reported code hash as the running daemon, so a binary swapped into the bundle can't receive the next refresh's authorization.
- **Minimal environment for `op`.** Nothing from launchd or the plist is inherited. Only display and account `OP_*` variables are forwarded; `OP_CONFIG_DIR` and biometric settings are dropped.
- **Test knobs** (`OPPROXY_*`), such as auto-approval or a fake `op`, exist only in debug builds.
- **Hardened runtime** on a real signing identity blocks debugger attachment and dylib injection into the daemon.
- **The dialog can't be approved by accident.** Only Touch ID approves, and the keyboard does nothing.

## Known security weaknesses

**Can yield secrets without your Touch ID:**
- **Keystrokes typed into an approved terminal tab.** A tab approval covers every read for 10 idle minutes, so anything that can type into that tab (for example Spaceterm's `ship-it`, or AppleScript with Automation permission) can run `op read … | curl …` there. This is by design and matches 1Password's own per-tab model.
- **Reuse within an approved agent session.** A prompt-injected agent can re-run any command you already approved in that session, for the duration you chose. That's limited to those exact commands.
- **Metadata is free.** Item titles, vaults, URLs and usernames come back from listings without any dialog.
- **Duration changes from the menu.** Anything with Accessibility permission could click the menu to extend an existing approval, since those changes reuse your last Touch ID. It can't create new approvals.

**Need your Touch ID, but could trick you into giving it:**
- **A replaced opProxy.** An agent can replace `bin/opProxy.app` or the LaunchAgent plist and restart the daemon, or edit this source and wait for your next `./install.sh`. The fake daemon then needs 1Password's prompt to be authorized, and you approve those prompts routinely. An unexpected 1Password prompt, outside startup or the 12-hour cadence, is the warning sign. A root-owned install (binary, plist and a verified copy of `op` in locations only root can write) would close this, but needs sudo.
- **Unverified dialog context.** The session ID, Spaceterm title and "last message" come from the caller or from files the agent can write. The agent process, command and item shown are genuine.
- **Resumed sessions.** `claude --resume <id>` starts a new agent process, which asks again. Approving a resumed session you didn't start hands it that access.

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
swift test                             # parsing, signed approvals, identity, durations, terminal approvals
swift build && Tests/integration.sh    # shim, daemon and holder against a stub op and a fake agent
swift build && .build/debug/opProxy render-dialog <dir> --on-screen   # dialog and backdrop screenshots
```
