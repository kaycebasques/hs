#!/usr/bin/env bash
set -euo pipefail

SIZE_REPL="$1"
GZ_FIXTURE="$2"
TOOLS_GHCI="$3"

GZ_ABS="$(cd "$(dirname "$GZ_FIXTURE")" && pwd)/$(basename "$GZ_FIXTURE")"
CLEAN_PATH="/usr/bin:/bin"

echo "=== 1. Evaluating gzipped XML sitemap decoding inside //:size_repl (69 Hackage deps + C-only zlib-clib) ==="
OUT="$(
    printf 'raw <- BS.readFile %s\n(decodePayload raw >>= parse)\n:quit\n' "\"$GZ_ABS\"" | \
    env -i PATH="$CLEAN_PATH" RUNFILES_DIR="${RUNFILES_DIR:-}" TEST_SRCDIR="${TEST_SRCDIR:-}" TMPDIR="${TEST_TMPDIR:-/tmp}" \
        "$SIZE_REPL"
)"
echo "$OUT"
grep -qF "Right (UrlSet [" <<< "$OUT"

echo "=== 2. Invoking external @rules_haskell//tools/ghci from downstream consumer module ==="
EXT_OUT="$(
    env -i PATH="$CLEAN_PATH" RUNFILES_DIR="${RUNFILES_DIR:-}" TEST_SRCDIR="${TEST_SRCDIR:-}" TMPDIR="${TEST_TMPDIR:-/tmp}" \
        "$TOOLS_GHCI" -e '(2 :: Integer) ^ (100 :: Int)'
)"
grep -qF "1267650600228229401496703205376" <<< "$EXT_OUT"

echo "SIZE REPL & EXTERNAL TOOLS/GHCI TEST PASSED!"
