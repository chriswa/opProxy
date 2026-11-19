#!/bin/bash
# Builds opProxy's 1Password helper (helper/, Go): build-helper.sh <output path>.
# Needs Go (brew install go); the SDK's version is pinned by helper/go.sum.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
command -v go >/dev/null || { echo "building opProxy needs Go for its 1Password helper: brew install go"; exit 1; }
(cd "$ROOT/helper" && CGO_ENABLED=1 go build -trimpath -o "$1" .)
