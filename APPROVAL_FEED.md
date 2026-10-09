# The approval feed

How opProxy on a Mac publishes the requests it would ask about to paired iPhones, and how a phone answers. `Sources/FeedProtocol` implements the shared parts; the Mac's side is `ApprovalFeed` and `CloudTransport`, the phone's is `phone/App/FeedModel.swift`.

## Who knows what

- **The Mac** owns everything about a request: what it shows, which options it offers, what they mean, and whether a reply is good enough to act on. It describes each request as a **document**, presentation data the phone draws without knowing what a 1Password item is.
- **iCloud only carries it.** Anything that can write to a zone could try to answer, so the Mac trusts a reply only because a paired phone's Secure Enclave key signed it, never because of where it came from.
- **The phone** draws the document and signs its answers.

## CloudKit layout

Container `iCloud.com.chriswa.opproxy`, Production environment, schema `phone/schema.ckdb`. For each Mac it's paired with, the phone owns a zone named `feed-<mac id>` in its private database, shared with that Mac's iCloud account alone (invited by user record, never open to whoever holds the link). When the phone and Mac share an Apple ID, there's no share: the Mac reads the zone from its own private database. Every field below is an encrypted value.

| Record type | Name | Written by | Holds |
|---|---|---|---|
| `FeedItem` | the item's ID | Mac | `item`: an Item (below) as JSON; `note`, once it's no longer pending ("Allowed on the Mac", "Timed out") |
| `FeedState` | `hello` | Mac | `{"type":"hello","protocol":1,"provider":"opProxy","pairedKeys":[…],"mac":{"id","name"}}` |
| `FeedState` | `status` | Mac | `{"type":"status","status":Status}` |
| `FeedState` | `presence` | Mac | `{"type":"presence","aliveAt":ms}`, every 30 seconds while requests are pending |
| `FeedInbox` | random | phone | `message`: a reply or pair message; `response`: the Mac's answer to it |
| `PairingRendezvous` | from the pairing code | phone, public database | `sealed`: the invitation, sealed with the code |

The Mac removes an answered or timed-out item by setting its `note`, and deletes it 10 minutes later. The phone subscribes to new `FeedItem` records in each zone, and silently to their updates and deletions so it can take down notifications for requests that are over. That is why it owns the zones: only a zone's owner can make those subscriptions. A phone treats a Mac whose `presence` is more than 90 seconds old, with requests pending, as asleep or offline.

## Pairing

1. The Mac's QR code holds `opproxy-pair:3:<code>:<Mac's iCloud user record name>:<Mac ID>`, where the code is 16 random bytes, base64url.
2. The phone makes the zone `feed-<Mac ID>`, invites that iCloud user to it with read/write (or, on the same Apple ID, shares nothing), and writes a `PairingRendezvous` record to the public database: named by an HMAC of the code, holding the invitation (`{"share": url}` or `{"ownZone": name}`) sealed with ChaCha20-Poly1305 under a key derived from the code. Only someone who saw the code can find it or open it.
3. The Mac accepts the share, refusing one open to anyone with its link, and writes its `hello`.
4. The phone sends `{"type":"pair","publicKey":"<base64>","name":"iPhone"}` to the inbox. The Mac shows the phone's name and key fingerprint, and pairs it only once you confirm with Touch ID. The answer is `{"type":"pair-result","keyId":"…","ok":true}` or `ok: false` with an `error`.

## Item

```jsonc
{
  "id": "…",              // unique for the daemon's lifetime
  "revision": 1,          // bumped whenever `document` changes
  "createdAt": 1760000000000,
  "expiresAt": null,      // when it times out; null while it waits its turn on the Mac
  "challenge": "…",       // opaque to the phone; echoed in the signed statement
  "document": "{…}"       // a JSON document, as a string, so the phone hashes exactly what was sent
}
```

## Document

```jsonc
{
  "tone": "caution",                 // "info" | "caution" | "danger"
  "title": "Private / GitHub token", // a headline, for consumers that don't lay out `requester` and `item`
  "subtitle": "Kevin (Claude Code) · “fix flaky tests”",
  "requester": { "name": "Kevin", "detail": "Claude Code · session c7d70e94", "context": "in “fix flaky tests”" },
  "item": { "title": "GitHub token", "detail": "Vault: Private" },
  "context": { "command": "gh pr checks 4127 …", "message": "CI is red on the PR…" },
  "notice": "The agent stopped waiting. Allowing still lets its retry through.",
  "sections": [ … ],                 // the same facts as fields and text, for consumers without `context`
  "pickers": [
    { "id": "duration", "label": "Allow", "default": "once",
      "options": [ { "id": "once", "label": "Once", "hint": "…", "facets": [ { "name": "Allow", "value": "Once" } ] },
                   { "id": "1d-all", "label": "1 Day · All agents", "hint": "…",
                     "facets": [ { "name": "Allow", "value": "1 Day" }, { "name": "For", "value": "All agents" } ] } ] }
  ],
  "actions": [ { "id": "deny", "label": "Deny", "role": "deny" }, { "id": "approve", "label": "Allow", "role": "approve" } ],
  "confirm": "Let Kevin (Claude Code) in “fix flaky tests” read “GitHub token”"
}
```

Every field but `title`, `actions` and `confirm` is optional. `facets` split an option into separate choices, so the phone can offer them as rows; options without a facet skip that row.

## Status

```jsonc
{ "ok": true, "label": "1Password", "since": 1760000000000, "until": 1760043200000 }
{ "ok": false, "label": "1Password", "since": …, "title": "1Password authorization lost", "detail": "…" }
```

## Replies

```jsonc
{ "type": "reply", "id": "…", "keyId": "…", "statement": "{…}", "signature": "<base64>" }
```

The phone signs the statement's UTF-8 bytes (ECDSA P-256 over SHA-256, DER, base64) with its Secure Enclave key, and sends the exact string it signed:

```jsonc
{ "v": 1, "provider": "opProxy", "id": "…", "revision": 2, "challenge": "…",
  "documentSha256": "…", "action": "approve", "picks": { "duration": "1d-all" },
  "keyId": "…", "signedAt": 1760000000000 }
```

The Mac acts on a reply only if all of these hold:
1. `keyId` is a paired phone's key, and the signature verifies over `statement` with it.
2. It was signed less than a minute ago.
3. `id` names a pending item, and `challenge` is that item's.
4. `documentSha256` is the hash of a document the Mac published for that item. Any revision counts, since a revision only adds context such as `notice`.
5. `action` and every pick name an action and an option that document offered.

It answers with `{"type":"reply-result","id":"…","ok":true}`, or `ok: false` with an `error`.

## Keys

A phone's key is a P-256 key in its Secure Enclave, usable only while the phone is unlocked. `publicKey` is its raw 64-byte X‖Y form, base64. `keyId` is the lowercase hex of the first 16 bytes of SHA-256 of that, and the fingerprint people compare is its first 16 hex digits in groups of four (`ab12 cd34 ef56 7890`).

The challenge also commits to the exact approval each lasting option would store, so a phone's signature can stand in for the Mac's Touch ID-gated approval key: an entry stored from a phone's reply verifies only if it is exactly the grant the phone picked.
