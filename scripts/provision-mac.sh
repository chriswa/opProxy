#!/bin/bash
# Has Xcode make (or refresh) the provisioning profile that lets opProxy use CloudKit, by
# building phone/'s MacSigning stub with the same bundle ID and entitlements. Needs Xcode
# signed in to the developer account. sign-app.sh embeds the result.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT="$ROOT/.build/cloudkit"
command -v xcodegen >/dev/null || { echo "needs xcodegen: brew install xcodegen"; exit 1; }
(cd "$ROOT/phone" && xcodegen generate --quiet)
xcodebuild -project "$ROOT/phone/OpProxyPhone.xcodeproj" -scheme MacSigning -configuration Debug \
    -derivedDataPath "$OUT/derived" -allowProvisioningUpdates -allowProvisioningDeviceRegistration -quiet build
mkdir -p "$OUT"
cp "$OUT/derived/Build/Products/Debug/opProxy.app/Contents/embedded.provisionprofile" "$OUT/opProxy.provisionprofile"
echo "profile: $OUT/opProxy.provisionprofile"
