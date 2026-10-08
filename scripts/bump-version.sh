#!/bin/bash
# Sets the version both apps share: scripts/bump-version.sh 0.3.0
# VERSION is the source; the iPhone app's marketing version in phone/project.yml must match,
# since Xcode reads it from there. release.sh refuses to build if they differ.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERSION=${1:?usage: scripts/bump-version.sh <version>}
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "versions look like 1.2.3"; exit 1; }
echo "$VERSION" > "$ROOT/VERSION"
sed -i '' -E "s/^    MARKETING_VERSION: .*/    MARKETING_VERSION: \"$VERSION\"/" "$ROOT/phone/project.yml"
grep -q "MARKETING_VERSION: \"$VERSION\"" "$ROOT/phone/project.yml"
echo "version $VERSION"
