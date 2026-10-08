#!/bin/bash
# Archives the iPhone app at the repo's VERSION, uploads it to App Store Connect, and hands it to
# testflight.sh, which puts it in the Coworkers group and submits it for beta review:
# scripts/upload-phone.sh. Needs Xcode signed in to the developer account. Every
# upload gets a new build number, from the time, since App Store Connect refuses repeats.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERSION=$(cat "$ROOT/VERSION")
grep -q "MARKETING_VERSION: \"$VERSION\"" "$ROOT/phone/project.yml" \
    || { echo "phone/project.yml's version isn't $VERSION: run scripts/bump-version.sh"; exit 1; }
BUILD=$(date -u +%Y%m%d%H%M)
OUT="$ROOT/.build/phone-$VERSION-$BUILD"
mkdir -p "$OUT"
(cd "$ROOT/phone" && xcodegen generate --quiet)
cat > "$OUT/export.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>7H2524M5TN</string>
</dict></plist>
PLIST
echo "== archiving the opProxy iPhone app $VERSION ($BUILD)"
xcodebuild -project "$ROOT/phone/OpProxyPhone.xcodeproj" -scheme OpProxyPhone -configuration Release \
    -destination 'generic/platform=iOS' -archivePath "$OUT/SecretProxy.xcarchive" -allowProvisioningUpdates \
    CURRENT_PROJECT_VERSION="$BUILD" -quiet archive
echo "== uploading"
xcodebuild -exportArchive -archivePath "$OUT/SecretProxy.xcarchive" -exportOptionsPlist "$OUT/export.plist" \
    -exportPath "$OUT/export" -allowProvisioningUpdates -quiet
echo "== uploaded $VERSION ($BUILD); waiting for Apple to process it"
"$ROOT/scripts/testflight.sh" "$BUILD"
