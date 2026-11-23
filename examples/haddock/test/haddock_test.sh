#!/usr/bin/env bash
set -euo pipefail

CORE_DIR="$1"
APP_DIR="$2"

for f in "index.html" "DocCore.html" "doc-index.json" "core.txt" "src/DocCore.html"; do
    if [ ! -s "$CORE_DIR/$f" ]; then
        echo "FAIL: missing expected Haddock output: $CORE_DIR/$f" >&2
        exit 1
    fi
done

# Prologue, QuickJump, Hoogle, and boot Hackage links
grep -qF "two-package Haddock example" "$CORE_DIR/index.html"
grep -qF "stepCounter" "$CORE_DIR/doc-index.json"
grep -qF "stepCounter ::" "$CORE_DIR/core.txt"
grep -qF "src/DocCore.html" "$CORE_DIR/DocCore.html"
grep -qF "https://hackage.haskell.org/package/" "$CORE_DIR/DocCore.html"

# Hidden module must not appear on index.html
if grep -qF "DocInternal.html" "$CORE_DIR/index.html"; then
    echo "FAIL: hidden_modules entry DocInternal leaked into index.html" >&2
    exit 1
fi

# Cross-target .haddock interface link from app_haddock -> ../core_haddock/DocCore.html
for f in "index.html" "DocApp.html" "doc-index.json" "src/DocApp.html"; do
    if [ ! -s "$APP_DIR/$f" ]; then
        echo "FAIL: missing expected app Haddock output: $APP_DIR/$f" >&2
        exit 1
    fi
done
grep -qF "../core_haddock/DocCore.html" "$APP_DIR/DocApp.html"
