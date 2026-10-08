#!/bin/bash
# Builds opProxy.app for other Macs: Developer ID-signed for CloudKit, notarized and stapled.
#   scripts/release.sh <version> [--publish]
# Builds from the committed source (a fresh export of HEAD), so no Mac's pinned approval key
# gets in. --publish uploads the zip as GitHub release v<version>. Needs Xcode signed in to
# the developer account and the "opProxy" notarytool profile (xcrun notarytool store-credentials).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERSION=${1:?usage: scripts/release.sh <version> [--publish]}
PUBLISH=${2:-}
OUT="$ROOT/.build/release-$VERSION"
rm -rf "$OUT" && mkdir -p "$OUT/src"
[ -z "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ] || echo "note: uncommitted changes aren't in the release"

echo "== building $(git -C "$ROOT" rev-parse --short HEAD)"
git -C "$ROOT" archive HEAD | tar -x -C "$OUT/src"
printf '%s\n' "// Release builds keep the approval key in the keychain; nothing is pinned." \
    "let pinnedApprovalPublicKey: String? = nil" > "$OUT/src/Sources/opProxy/ApprovalKeyPin.swift"
swift build -c release --package-path "$OUT/src" 2>&1 | grep -E "error|Build complete" || true
[ -x "$OUT/src/.build/release/opProxy" ] || { echo "build failed"; exit 1; }

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
# The stub's profile and its distribution entitlements (Production push) sign the real app.
export OPPROXY_PROFILE="$OUT/stub/opProxy.app/Contents/embedded.provisionprofile"
export OPPROXY_ENTITLEMENTS="$OUT/entitlements.plist"
codesign -d --entitlements :- "$OUT/stub/opProxy.app" > "$OPPROXY_ENTITLEMENTS" 2>/dev/null

echo "== signing"
APP="$OUT/opProxy.app"
"$ROOT/scripts/assemble-app.sh" "$OUT/src/.build/release/opProxy" "$APP" "$VERSION"
"$ROOT/scripts/sign-app.sh" "$APP" | grep -q "signing with CloudKit: Developer ID" || { echo "not signed with Developer ID"; exit 1; }

echo "== notarizing"
ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
xcrun notarytool submit "$OUT/notarize.zip" --keychain-profile opProxy --wait
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose "$APP"
ZIP="$OUT/opProxy-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "== built $ZIP"

if [ "$PUBLISH" = "--publish" ]; then
    gh release create "v$VERSION" "$ZIP" --repo chriswa/opProxy --title "opProxy $VERSION" \
        --notes "Unzip, move opProxy.app to Applications and open it; its Setup window takes it from there."
fi
