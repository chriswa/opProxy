#!/bin/bash
# Signs an assembled opProxy.app or opProxy iCloud Relay.app. With the profile from
# provision-mac.sh, it's embedded and the app is signed with the profile's certificate and
# entitlements; without one, the app is signed as before: opProxy then pins its approval key
# instead, and a relay can't reach CloudKit. Both apps share one bundle ID and profile, but
# the relay gets only the iCloud entitlements, never the approval key's keychain group.
# release.sh passes a Developer ID profile and its entitlements in OPPROXY_PROFILE and
# OPPROXY_ENTITLEMENTS.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP=$1
PROFILE=${OPPROXY_PROFILE:-$ROOT/.build/cloudkit/opProxy.provisionprofile}
ENTITLEMENTS=${OPPROXY_ENTITLEMENTS:-$ROOT/phone/MacSigning/opProxy.entitlements}
if [ -x "$APP/Contents/MacOS/opProxyRelay" ]; then
    RELAY_ENTITLEMENTS=$(mktemp)
    trap 'rm -f "$RELAY_ENTITLEMENTS"' EXIT
    cp "$ENTITLEMENTS" "$RELAY_ENTITLEMENTS"
    /usr/libexec/PlistBuddy -c "Delete :keychain-access-groups" "$RELAY_ENTITLEMENTS" 2>/dev/null || true
    ENTITLEMENTS=$RELAY_ENTITLEMENTS
fi
IDENTITIES=$(security find-identity -v -p codesigning 2>/dev/null)
if [ -f "$PROFILE" ]; then
    # The profile names the certificates it allows; sign with the first one in the keychain.
    IDENTITY=$(security cms -D -i "$PROFILE" | python3 -c '
import hashlib, plistlib, sys
for der in plistlib.loads(sys.stdin.buffer.read())["DeveloperCertificates"]:
    print(hashlib.sha1(der).hexdigest().upper())' | while read -r SHA; do
        grep -q "$SHA" <<<"$IDENTITIES" && { echo "$SHA"; break; }
    done || true)
    if [ -n "$IDENTITY" ]; then
        echo "signing with profile: $(grep "$IDENTITY" <<<"$IDENTITIES" | awk -F'"' '{print $2}')"
        cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
        # Developer ID builds get a secure timestamp, which notarization requires.
        TIMESTAMP=$(grep "$IDENTITY" <<<"$IDENTITIES" | grep -q "Developer ID" && echo --timestamp || echo --timestamp=none)
        codesign --force --sign "$IDENTITY" --options runtime $TIMESTAMP --entitlements "$ENTITLEMENTS" "$APP"
        exit 0
    fi
    echo "the profile's certificate isn't in this keychain; signing without it"
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
