#!/usr/bin/env bash
set -euo pipefail

CORE_DIR="$1"
CLIENT_DIR="$2"
BUNDLE_DIR="$3"

echo "=== 1. Verifying core_haddock HTML, prologue, QuickJump, and hyperlinked source ==="
for f in \
    "index.html" \
    "HaddockCore.html" \
    "HaddockLiterate.html" \
    "core-lib.txt" \
    "doc-index.json" \
    "linuwial.css" \
    "quick-jump.min.js" \
    "haddock-bundle.min.js" \
    "src/HaddockCore.html" \
    "src/HaddockLiterate.html" \
    "src/highlight.js" \
    "src/style.css"; do
    if [ ! -s "$CORE_DIR/$f" ]; then
        echo "FAIL: missing or empty expected Haddock artifact: $CORE_DIR/$f" >&2
        exit 1
    fi
done

# Prologue text and custom title appear on index.html
grep -qF "Core Haddock Suite" "$CORE_DIR/index.html"
grep -qF "Prologue overview rendered onto the Haddock contents page" "$CORE_DIR/index.html"

# Public module appears on index.html; hidden_modules entry HaddockSecret does NOT
grep -qF "HaddockCore.html" "$CORE_DIR/index.html"
if grep -qF "HaddockSecret.html" "$CORE_DIR/index.html"; then
    echo "FAIL: hidden_modules entry HaddockSecret leaked onto public index.html" >&2
    exit 1
fi

# Boot package types hyperlink to Hackage base docs via bundled boot .haddock interfaces
grep -qF "https://hackage.haskell.org/package/" "$CORE_DIR/HaddockCore.html"

# QuickJump JSON and Hoogle database contain documented symbols
grep -qF "renderCoreValue" "$CORE_DIR/doc-index.json"
grep -qF "CoreValue" "$CORE_DIR/doc-index.json"
grep -qF "literateGreeting" "$CORE_DIR/doc-index.json"
grep -qF "renderCoreValue ::" "$CORE_DIR/core-lib.txt"

# Hyperlinked source links back from HaddockCore.html -> src/HaddockCore.html
grep -qF "src/HaddockCore.html" "$CORE_DIR/HaddockCore.html"

echo "=== 2. Verifying cross-target haddock_deps (--read-interface) in client_haddock ==="
for f in "index.html" "HaddockClient.html" "doc-index.json" "src/HaddockClient.html"; do
    if [ ! -s "$CLIENT_DIR/$f" ]; then
        echo "FAIL: missing or empty expected client Haddock artifact: $CLIENT_DIR/$f" >&2
        exit 1
    fi
done
grep -qF "../core_haddock/HaddockCore.html" "$CLIENT_DIR/HaddockClient.html"

echo "=== 3. Verifying multi-library combined bundle_haddock ==="
for f in "index.html" "HaddockCore.html" "HaddockClient.html" "doc-index.json" "src/HaddockCore.html" "src/HaddockClient.html"; do
    if [ ! -s "$BUNDLE_DIR/$f" ]; then
        echo "FAIL: missing or empty expected bundle Haddock artifact: $BUNDLE_DIR/$f" >&2
        exit 1
    fi
done
grep -qF "HaddockCore.html#t:CoreValue" "$BUNDLE_DIR/HaddockClient.html"

echo "HS_HADDOCK E2E TEST PASSED!"
