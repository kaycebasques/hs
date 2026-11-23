#!/usr/bin/env bash
set -euo pipefail

SITE_DIR="$1"
DOCS_GEN="$2"
SERVE_BIN="$3"

for required in index.html css/default.css haddock/lock/index.html; do
    if [ ! -s "$SITE_DIR/$required" ]; then
        echo "FAIL: missing or empty site artifact: $required" >&2
        exit 1
    fi
done

env -i PATH=/nonexistent "$DOCS_GEN" --help | grep -qi "hakyll"
env -i PATH=/nonexistent "$SERVE_BIN" --help | grep -qF "Usage: serve"
