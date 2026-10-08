#!/bin/bash
# One App Store Connect API call: scripts/asc.sh METHOD /v1/path [JSON body]. Prints the response.
# Uses the API key in ~/.appstoreconnect/private_keys (see CLAUDE.md); the token is made fresh
# for each call, into a private temporary file, and never printed.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TOKEN=$(mktemp)
trap 'rm -f "$TOKEN"' EXIT
swift "$ROOT/scripts/asc-token.swift" "$TOKEN"
curl -sg -X "$1" -H "Authorization: Bearer $(cat "$TOKEN")" -H "Content-Type: application/json" \
    ${3:+--data "$3"} "https://api.appstoreconnect.apple.com$2"
