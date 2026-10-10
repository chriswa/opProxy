# Plan: provider adapters

FEATURE: opProxy becomes a generic approval broker for agents' secret reads, with 1Password as the first of several providers, each added by installing a small adapter instead of changing the signed app.

CAVEATS:
- A trusted adapter holds a provider's authorized session. A malicious adapter you approve can read any secret, the same trust you place in opProxy itself. Pinning stops an approved adapter being swapped or edited; it can't make a bad one safe.
- Interpreted adapters (shell, Python, Node) can't be trusted, because the running code isn't what gets measured. Trusted adapters must be compiled binaries.
- Ad-hoc-signed adapters need re-approval with Touch ID after every rebuild or update.
- Spaceterm's phone app and the iPhone app are unaffected, since the feed document is already provider-neutral, but the approval dialog and menu must stop assuming 1Password.

## Context

opProxy is 1Password-specific all the way through. `bin/op` is the signed app's own executable, and the daemon:
- parses `op` commands and resolves the item a read means (`OpCommand`, `ItemRequest`);
- runs the real `op` inside a session holder, so 1Password authorizes one Unix session;
- reports the 1Password authorization in the menu bar and on the phone (`AuthTracker`, `FeedStatus`);
- keeps each phone's pairing key as a 1Password item (`PairingKeyVault`: `op item create/get/delete` in the authorized session), reads it back only once 1Password has authorized, and refuses to hand it to any caller (the title check in `Daemon`). Paired phones get nothing until 1Password authorizes, and saving or deleting a key can raise its own 1Password prompt (`AuthReason.pairingKey`, `.unpairing`).

The parts that don't depend on 1Password (who is asking, the dialog, Touch ID, lasting approvals) share the same binary. Pairing and the feed depend on it only for storing pairing keys. CloudKit isn't in that binary: it's in opProxy iCloud Relay (`Sources/opProxyRelay`), a separately signed helper that only carries sealed records and knows nothing of any provider.

Install today: the signed, notarized `opProxy.app` from GitHub releases, with the relay inside, or a build from source with `install.sh` plus the released relay. Target: install the signed broker app, then add a provider's shim and adapter, for example the `op` shim from GitHub. Spaceterm keeps its label script.

## Design

Three pieces, with different trust.

### Broker (signed app, trusted)

What opProxy is today, minus the 1Password specifics:
- identifies the requester from the kernel's process tree for the shim's process, never from anything the shim or adapter says;
- shows the dialog, takes Touch ID, stores and checks lasting approvals, and publishes the feed to phones;
- launches and supervises adapters, pins them (below), and relays requests and approvals between shims and adapters.

### Shim (untrusted, can be a script)

The provider's command on PATH, such as `op`. It forwards argv, cwd and the variables the adapter asks for to the broker's socket, and prints what comes back. Anything running as the user can edit it, so nothing depends on it: a lying shim can only misdescribe its own arguments, and the adapter decides what they mean. Shims for agents that don't run in a terminal can be anything that speaks the socket.

### Adapter (trusted, compiled, pinned)

One long-running process per provider, launched by the broker. It:
- turns a request into a description for the dialog (provider, item, fields, account) plus an exact plan to carry it out;
- holds the provider's authorized session (for 1Password, today's session holder);
- carries out a plan only with the broker's approval for that request;
- reports its provider's status ("authorized for 11h") for the menu bar and the phone.

## Trusting an adapter

- **The broker launches it.** It then knows the adapter's PID for certain and controls its environment, so nothing is injected through `DYLD_INSERT_LIBRARIES` or a changed `PATH`.
- **It's pinned by code hash.** On first launch, and whenever the binary changes, the broker asks: "Trust the 1Password adapter at <path>, code <cdhash>?" Touch ID confirms, and the broker signs the record with its Secure Enclave approval key, as it does paired phones, so an agent can't add a record. Every connection is checked against the kernel's cdhash for the process (audit token, as `KernelSignature` does for agents today).
- **It must use the hardened runtime.** Without it, a process running as the same user could attach a debugger and read the session from memory. The broker refuses adapters without the runtime flag or with `get-task-allow`.
- **An ad-hoc signature is enough** (`codesign -s - -o runtime`), so authors need no Apple account. Users can also choose to trust a Developer ID team once, so that team's signed updates need no re-approval.
- **Every request names its adapter.** The dialog and the phone show which adapter is asking, and approvals are stored per adapter, so an approval for one provider never covers another.

## Adapter protocol

Newline-delimited JSON over a socket the broker creates for each adapter it launches. The adapter connects back and is verified by its audit token.

The relay is a precedent: a separately signed helper the broker launches and talks to in JSON lines over its stdin and stdout, which by itself means only the broker can talk to the copy it runs, with no audit-token check, and with its own protocol number (`RelayProtocol`). It ships in `Contents/Helpers`. Its protocol is separate from this one, and it needs no change for a new provider.

```jsonc
// broker → adapter
{ "type": "describe", "id": "…", "argv": [...], "cwd": "…", "env": {...} }
{ "type": "run", "id": "…", "approval": "<broker-signed token naming id and plan>" }
// adapter → broker
{ "type": "described", "id": "…", "item": {...}, "plan": {...}, "dialog": {...} }   // or "passthrough": true
{ "type": "ran", "id": "…", "exitCode": 0, "stdout": "<base64>", "stderr": "<base64>" }
{ "type": "status", "label": "…", "ok": true, "until": 1760043200000 }
```

The approval key is `(adapter cdhash or team, provider account, item)`, so lasting approvals keep today's meaning per provider.

## Steps

1. **Define the protocol and the adapter registry** in the broker: launching, supervising and restarting adapters; pinning by cdhash with Touch ID; the signed registry file.
2. **Move 1Password out** into `adapters/onepassword`: `OpCommand`, `ItemRequest`, the session holder, `AuthTracker`, and the real-`op` signature check. The broker keeps the requester logic, dialog, approvals, feed and pairing, and so has to keep pairing keys somewhere other than 1Password: its own keychain access group (which a build without the team's profile doesn't get, so it needs a fallback), or a designated adapter, with new messages to create, read and delete a broker secret. Whichever holds them must refuse to hand them out, as `PairingKeyVault` and the title check in `Daemon` do now.
3. **Make the broker's UI provider-neutral**: the dialog takes its item and wording from the adapter's description; the menu bar shows each adapter's status; `FeedStatus` reports per adapter.
4. **Replace `bin/op`** with a script shim that forwards to the broker, and publish it with the adapter.
5. **Migrate approvals and pairing keys**: existing approvals become 1Password-adapter approvals on first launch, re-signed with Touch ID. `relay-links.json` names each pairing key's 1Password item (`keyItem`): move those secrets to the new store, or have phones pair again.
6. **Tests**: integration tests with a stub adapter (pinning, re-approval on change, refusing unhardened or unpinned adapters, an edited shim) and today's suite against the 1Password adapter.
7. **Docs**: install steps (broker app, then a provider's shim and adapter), and how to write an adapter.

## Open questions

- Should the broker ship the 1Password adapter inside its bundle (signed with the app) while still treating it like any other adapter? The relay already ships that way, in `Contents/Helpers`.
- Where do pairing keys live when 1Password isn't installed? See step 2.
- How long should a provider's status take to reach the phone, and should a phone show adapters it can't act on?
