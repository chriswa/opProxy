#!/bin/bash
# After upload-phone.sh: waits for App Store Connect to process the newest build, adds it to the
# "Coworkers" external group (whose public link is in README.md), and submits it for beta review.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP=6820385028
ASC="$ROOT/scripts/asc.sh"
json() { python3 -c "import json,sys; d=json.load(sys.stdin); $1"; }

for _ in $(seq 60); do
    read -r BUILD STATE < <("$ASC" GET "/v1/builds?filter[app]=$APP&sort=-uploadedDate&limit=1" \
        | json "b=d['data'][0]; print(b['id'], b['attributes']['processingState'])")
    [ "$STATE" = VALID ] && break
    echo "build $BUILD is $STATE; checking again in 30 seconds"
    sleep 30
done
[ "$STATE" = VALID ] || { echo "build $BUILD still $STATE: run this again later"; exit 1; }

GROUP=$("$ASC" GET "/v1/apps/$APP/betaGroups" | json "print(next(g['id'] for g in d['data'] if g['attributes']['name'] == 'Coworkers'))")
"$ASC" POST "/v1/betaGroups/$GROUP/relationships/builds" "{\"data\":[{\"type\":\"builds\",\"id\":\"$BUILD\"}]}" >/dev/null
"$ASC" POST /v1/betaAppReviewSubmissions \
    "{\"data\":{\"type\":\"betaAppReviewSubmissions\",\"relationships\":{\"build\":{\"data\":{\"type\":\"builds\",\"id\":\"$BUILD\"}}}}}" \
    | json "print('beta review:', d['data']['attributes']['betaReviewState'] if 'data' in d else d['errors'][0]['detail'])"
echo "build $BUILD is in the Coworkers group"
