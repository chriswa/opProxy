#!/bin/bash
# Builds opProxy.app for other Macs, with opProxy iCloud Relay inside it, and the relay on its
# own for Macs that build opProxy themselves: Developer ID-signed, notarized and stapled.
#   scripts/release.sh [--publish]
# Builds from the committed source (a fresh export of HEAD), so no Mac's pinned approval key
# gets in. --publish uploads the zip as GitHub release v<version>. Needs Xcode signed in to
# the developer account and the "opProxy" notarytool profile (xcrun notarytool store-credentials).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERSION=$(cat "$ROOT/VERSION")
PUBLISH=${1:-}
grep -q "MARKETING_VERSION: \"$VERSION\"" "$ROOT/phone/project.yml" \
    || { echo "phone/project.yml's version isn't $VERSION: run scripts/bump-version.sh"; exit 1; }
OUT="$ROOT/.build/release-$VERSION"
rm -rf "$OUT" && mkdir -p "$OUT/src"
[ -z "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ] || echo "note: uncommitted changes aren't in the release"

echo "== building $(git -C "$ROOT" rev-parse --short HEAD)"
git -C "$ROOT" archive HEAD | tar -x -C "$OUT/src"
printf '%s\n' "// Release builds keep the approval key in the keychain; nothing is pinned." \
    "let pinnedApprovalPublicKey: String? = nil" > "$OUT/src/Sources/opProxy/ApprovalKeyPin.swift"
swift build -c release --package-path "$OUT/src" 2>&1 | grep -E "error|Build complete" || true
[ -x "$OUT/src/.build/release/opProxy" ] && [ -x "$OUT/src/.build/release/opProxyRelay" ] || { echo "build failed"; exit 1; }

echo "== Developer ID provisioning profile"
(cd "$ROOT/phone" && xcodegen generate --quiet)
cat > "$OUT/export.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>7H2524M5TN</string>
</dict></plist>
PLIST
xcodebuild -project "$ROOT/phone/OpProxyPhone.xcodeproj" -scheme MacSigning -configuration Release \
    -archivePath "$OUT/MacSigning.xcarchive" -allowProvisioningUpdates -quiet archive
xcodebuild -exportArchive -archivePath "$OUT/MacSigning.xcarchive" -exportOptionsPlist "$OUT/export.plist" \
    -exportPath "$OUT/stub" -allowProvisioningUpdates -quiet
# The stub's profile and its distribution entitlements (Production push) sign the real app
# and the relay inside it.
export OPPROXY_PROFILE="$OUT/stub/opProxy.app/Contents/embedded.provisionprofile"
export OPPROXY_ENTITLEMENTS="$OUT/entitlements.plist"
codesign -d --entitlements :- "$OUT/stub/opProxy.app" > "$OPPROXY_ENTITLEMENTS" 2>/dev/null

echo "== signing"
APP="$OUT/opProxy.app"
RELAY="$APP/Contents/Helpers/opProxy iCloud Relay.app"
"$ROOT/scripts/assemble-app.sh" "$OUT/src/.build/release/opProxy" "$APP"
# The relay first: signing the app seals what's inside it.
"$ROOT/scripts/assemble-app.sh" "$OUT/src/.build/release/opProxyRelay" "$RELAY" relay
"$ROOT/scripts/sign-app.sh" "$RELAY" | grep -q "signing with profile: Developer ID" || { echo "relay not signed with Developer ID"; exit 1; }
"$ROOT/scripts/sign-app.sh" "$APP" | grep -q "signing with profile: Developer ID" || { echo "not signed with Developer ID"; exit 1; }

echo "== notarizing"
ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
xcrun notarytool submit "$OUT/notarize.zip" --keychain-profile opProxy --wait
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose "$APP"
ZIP="$OUT/opProxy-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
# The same relay on its own, for Macs running an opProxy they built: notarized as part of the app.
cp -R "$RELAY" "$OUT/"
xcrun stapler staple "$OUT/opProxy iCloud Relay.app"
RELAY_ZIP="$OUT/opProxy-iCloud-Relay-$VERSION.zip"
ditto -c -k --keepParent "$OUT/opProxy iCloud Relay.app" "$RELAY_ZIP"
echo "== built $ZIP and $RELAY_ZIP"

if [ "$PUBLISH" = "--publish" ]; then
    gh release create "v$VERSION" "$ZIP" "$RELAY_ZIP" --repo chriswa/opProxy --title "opProxy $VERSION" \
        --notes "Unzip, move opProxy.app to Applications and open it; its Setup window takes it from there. Building opProxy yourself? Put opProxy iCloud Relay.app in Applications so it can reach your iPhone."
fi
