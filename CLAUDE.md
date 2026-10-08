# opProxy: notes for agents

opProxy is a Mac app (Swift package, `Sources/`) that puts an approval dialog in front of agents' 1Password CLI reads. Its iPhone app, also called opProxy, is in `phone/`, which answers the same requests over iCloud. README.md says how both work; APPROVAL_FEED.md is the protocol between them; PROVIDER_ADAPTERS.md is a plan for later.

## Layout

- `Sources/FeedProtocol`: shared by the Mac and the phone. Wire types, the CloudKit layout (`CloudFeed`), documents, signed statements, `Duration`.
- `Sources/OpProxyCore`: the Mac's logic that doesn't need AppKit. `Sources/opProxy`: the Mac app (daemon, dialog, menu, Setup, `CloudTransport`, `CloudPairing`).
- `phone/project.yml`: the iPhone app, its notification extension, and `MacSigning`, a stub Mac app built only so Xcode makes the Mac's provisioning profiles. Generate the Xcode project with `xcodegen generate` in `phone/`; `OpProxyPhone.xcodeproj` is generated and ignored.
- `phone/schema.ckdb`: the CloudKit schema deployed to Production.
- `scripts/`: building, signing, releasing, App Store Connect.

## Apple identifiers

| What | Value |
|---|---|
| Team | 7H2524M5TN |
| Mac app | `com.chriswa.opproxy` |
| iPhone app / notification extension | `com.chriswa.opproxy.phone` / `.phone.notifications` |
| CloudKit container | `iCloud.com.chriswa.opproxy`, Production environment for every build (an entitlement in `project.yml`) |
| App Store Connect app | opProxy (iPhone), ID 6820385028, SKU `secretproxy` |
| TestFlight | external group "Coworkers", public link https://testflight.apple.com/join/6MFDbtVE |
| App Store Connect API key | "opProxy releases", key ID DFK3C9K7M4, issuer bb77b192-3592-48c2-9168-4ba2c99cf7d0, App Manager role; the `.p8` is at `~/.appstoreconnect/private_keys/AuthKey_DFK3C9K7M4.p8` |
| Notarization | `notarytool` keychain profile `opProxy`, made from that key |
| Privacy policy | https://gist.github.com/chris-spare/d5d6102f662ac4a5d653b079adfc8d43 |

## What a machine needs

- Xcode signed in to an Apple account on team 7H2524M5TN (Settings → Accounts). Signing, provisioning and uploads use it: the API key's App Manager role can't use Xcode's cloud signing, so exports go through Xcode's account.
- `brew install xcodegen`; `gh` logged in with write access to `chriswa/opProxy`.
- For releases: the API key file above and the `opProxy` notarytool profile (`xcrun notarytool store-credentials opProxy --key … --key-id DFK3C9K7M4 --issuer bb77b192-…`). To make a new key: App Store Connect → Users and Access → Integrations → Team Keys; it downloads only once.
- For schema work: a CloudKit management token in the keychain (`xcrun cktool save-token --type management`; the token comes from the CloudKit Console's account Settings → Tokens).

## Build and test

```
swift build && swift test           # Mac, unit tests
bash Tests/integration.sh           # shim, daemon and feed against a stub op, a fake agent and a stand-in phone
Tests/cloud-e2e.sh                  # the CloudKit feed against real iCloud (needs the provisioning profile)
cd phone && xcodegen generate && xcodebuild -project OpProxyPhone.xcodeproj -scheme OpProxyPhone \
    -destination 'generic/platform=iOS' -derivedDataPath build -allowProvisioningUpdates build
xcrun devicectl device install app --device <id from `xcrun devicectl list devices`> \
    phone/build/Build/Products/Debug-iphoneos/opProxy.app
```

The phone must be unlocked and reachable (same Wi-Fi, or a cable) for `devicectl`; a locked phone shows as unavailable. The simulator has no iCloud account, so it can't pair. For screenshots (the README's are in `docs/screenshots`), debug builds open a fixed screen with sample data when launched with `-shot pairing|guide|confirm|request|allowed|macs`, e.g. `xcrun simctl launch --terminate-running-process "iPhone 17 Pro" com.chriswa.opproxy.phone -shot request`, after `xcrun simctl status_bar "iPhone 17 Pro" override --time 9:41`.

`phone/try.sh start | pair | request [session] | stop` runs a test daemon beside the installed one (state in `~/.opProxy-try`, its own key icon, a stub `op`) for trying the phone with fake requests. Debug builds honour `OPPROXY_*` test knobs; release builds ignore them, so a release binary's CLI always reads the real `~/.opProxy`.

Installing locally (`./install.sh`, after `scripts/provision-mac.sh` once a year) restarts the daemon, so 1Password asks to authorize again.

## Versions and releases

Both apps share one version, in `VERSION`. `scripts/bump-version.sh 0.3.0` sets it there and as the iPhone app's `MARKETING_VERSION` in `phone/project.yml`; the release scripts refuse to run if they differ. The phone warns when a paired Mac runs a different version, so release both together.

1. `scripts/bump-version.sh <version>` and commit.
2. **Mac:** `scripts/release.sh --publish`. It builds from a fresh export of `HEAD` (uncommitted changes aren't included, and no per-Mac key pin gets in), fetches a Developer ID provisioning profile by exporting the `MacSigning` stub, signs with Developer ID, notarizes, staples, and creates GitHub release `v<version>`. Push `main` first, so the tag points at the right commit.
3. **iPhone:** `scripts/upload-phone.sh`. It archives with a build number from the time, uploads with Xcode's account, then `scripts/testflight.sh` waits for processing, adds the build to the Coworkers group, and submits it for beta review (about a day; later builds of the same version are often approved automatically).
4. **App Store** (not done yet): in App Store Connect, the iOS version needs screenshots, a description, keywords, a support URL, the privacy policy, age rating and app privacy answers ("Data Not Collected"), and review notes pointing to **Try a demo**; then choose the build and submit.

`scripts/asc.sh METHOD /v1/… [json]` makes any App Store Connect API call with a fresh token (`scripts/asc-token.swift`). In App Store Connect's web pages, the 1Password browser extension pops up on text fields and blocks typing by automation; set fields through the page's script instead.

## CloudKit schema

Production's schema is permanent: record types and fields can be added but never renamed or removed. To change it:

1. Edit `phone/schema.ckdb`.
2. `xcrun cktool import-schema --team-id 7H2524M5TN --container-id iCloud.com.chriswa.opproxy --environment development --file phone/schema.ckdb` (`validate-schema` first if unsure).
3. Deploy Development to Production in the CloudKit Console: CloudKit Database → the container → Deploy Schema Changes. Check the dialog lists only what you meant.
4. Ship app versions that read new fields before ones that depend on them.

## Gotchas

- Every build that uses CloudKit must be signed with a provisioning profile: `scripts/provision-mac.sh` (development, for `install.sh` and the tests) or `release.sh`'s Developer ID profile. CloudKit raises an exception, not an error, without one, so `CloudTransport.available` checks the entitlement first.
- The approval key lives in the keychain access group `7H2524M5TN.com.chriswa.opproxy` for profile-signed builds (`KeychainSigner`); other builds use the pin `install.sh` compiles in.
- A phone that shares the Mac's Apple ID needs no share: the Mac reads the phone's zone from its own private database. Different Apple IDs use an invite-only share; never make a share public.
- A Mac whose share membership changed can't overwrite records it wrote before; `CloudTransport` deletes and rewrites them ("written under an earlier membership" in the log).
- `~/.opProxy/daemon.log` is the Mac's log; on the phone, `xcrun devicectl device process launch --console --terminate-existing --device <id> com.chriswa.opproxy.phone` shows `print` output.
