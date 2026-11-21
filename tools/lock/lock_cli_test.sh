#!/usr/bin/env bash
set -euo pipefail

LOCK_BIN="$1"
if [ ! -x "$LOCK_BIN" ]; then
    echo "FAIL: lock binary not executable: $LOCK_BIN" >&2
    exit 1
fi

WORK="$(mktemp -d "${TEST_TMPDIR:-/tmp}/lock_cli_test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

CACHE_DIR="$WORK/cache"
mkdir -p "$CACHE_DIR/cabals" "$CACHE_DIR/tarballs"

# 1. Create a local .cabal file with non-ASCII UTF-8 author metadata and compute its SHA-256.
CABAL_CONTENT="$(cat <<'EOF'
cabal-version: 2.2
name: utf8-pkg
version: 0.1.0
author: Café λ — Æther
build-type: Simple

library
  default-language: Haskell2010
  exposed-modules: Utf8Mod
  build-depends: base, system-cxx-std-lib
EOF
)"

TMP_CABAL="$WORK/utf8-pkg.cabal"
printf '%s\n' "$CABAL_CONTENT" > "$TMP_CABAL"
if command -v sha256sum >/dev/null 2>&1; then
    CABAL_SHA="$(sha256sum "$TMP_CABAL" | awk '{print $1}')"
else
    CABAL_SHA="$(shasum -a 256 "$TMP_CABAL" | awk '{print $1}')"
fi

# Seed immutable content-addressed cache entry <pkg>-<ver>-<sha256>.cabal and tarball.
cp "$TMP_CABAL" "$CACHE_DIR/cabals/utf8-pkg-0.1.0-${CABAL_SHA}.cabal"
mkdir -p "$WORK/utf8-pkg-0.1.0"
printf 'module Utf8Mod where\n' > "$WORK/utf8-pkg-0.1.0/Utf8Mod.hs"
tar -czf "$CACHE_DIR/tarballs/utf8-pkg-0.1.0.tar.gz" -C "$WORK" "utf8-pkg-0.1.0"

# 2. Write snapshot YAML & cabal.config containing UTF-8 comments, then run under LC_ALL=C!
SNAP_YAML="$WORK/snapshot.yaml"
cat > "$SNAP_YAML" <<EOF
# Snapshot commentary with UTF-8: Café λ — naïve résumé
resolver:
  compiler: ghc-9.10.3
packages:
- hackage: utf8-pkg-0.1.0@sha256:${CABAL_SHA},256
EOF

CABAL_CFG="$WORK/cabal.config"
cat > "$CABAL_CFG" <<'EOF'
-- Boot constraints (UTF-8: λ)
constraints: base installed,
             system-cxx-std-lib installed
EOF

OUT_LOCK="$WORK/hackage.lock.json"
LC_ALL=C LANG=C "$LOCK_BIN" \
    --snapshot custom-utf8 \
    --snapshot-yaml "$SNAP_YAML" \
    --cabal-config "$CABAL_CFG" \
    --cache-dir "$CACHE_DIR" \
    --package utf8-pkg \
    --output "$OUT_LOCK"

grep -qF '"system-cxx-std-lib": "1.0"' "$OUT_LOCK"
grep -qF '"utf8-pkg": {' "$OUT_LOCK"
echo "OK: //tools/lock succeeded under LC_ALL=C with UTF-8 inputs, SHA-256 cabal cache, and system-cxx-std-lib!"
