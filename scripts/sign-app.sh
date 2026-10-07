#!/bin/bash
# Signs an assembled opProxy.app. With the CloudKit profile from provision-mac.sh, it's
# embedded and the app is signed with the profile's certificate and CloudKit entitlements;
# without one, the app is signed as before and simply runs without the iPhone app's feed.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP=$1
PROFILE="$ROOT/.build/cloudkit/opProxy.provisionprofile"
IDENTITIES=$(security find-identity -v -p codesigning 2>/dev/null)
if [ -f "$PROFILE" ]; then
    # The profile names the certificates it allows; sign with the first one in the keychain.
    IDENTITY=$(security cms -D -i "$PROFILE" | python3 -c '
import hashlib, plistlib, sys
for der in plistlib.loads(sys.stdin.buffer.read())["DeveloperCertificates"]:
    print(hashlib.sha1(der).hexdigest().upper())' | while read -r SHA; do
        grep -q "$SHA" <<<"$IDENTITIES" && { echo "$SHA"; break; }
    done)
    if [ -n "$IDENTITY" ]; then
        echo "signing with CloudKit: $(grep "$IDENTITY" <<<"$IDENTITIES" | awk -F'"' '{print $2}')"
        cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
        codesign --force --sign "$IDENTITY" --options runtime \
            --entitlements "$ROOT/phone/MacSigning/opProxy.entitlements" "$APP"
        exit 0
    fi
    echo "the CloudKit profile's certificate isn't in this keychain; signing without CloudKit"
fi
rm -f "$APP/Contents/embedded.provisionprofile"
# A real identity gives a stable designated requirement, so macOS keeps its grants across rebuilds.
IDENTITY=$(awk -F'"' '/Developer ID Application|Apple Development/{print $2; exit}' <<<"$IDENTITIES")
if [ -n "$IDENTITY" ]; then
    echo "signing as: $IDENTITY"
    codesign --force --sign "$IDENTITY" --options runtime "$APP"
else
    echo "signing ad-hoc (no identity found — macOS will re-prompt after every rebuild)"
    codesign --force --sign - "$APP"
fi
