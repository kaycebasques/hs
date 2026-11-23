#!/usr/bin/env bash
set -euo pipefail

TERMINFO_BIN="$1"
FULL_REPL="$2"
TH_REPL="$3"
RUNFILES_REPL="$4"
SMOKE_BIN_REPL="$5"
COMPILED_REPL="$6"
SCRIPTED_REPL="$7"
TOOLS_GHCI="$8"
TOOLS_RUNGHC="$9"

CLEAN_PATH="/usr/bin:/bin"

echo "=== 1. Verifying ELF DT_NEEDED hermeticity of terminfo_test (static libtinfo.a) ==="
NEEDED="$(readelf -d "$TERMINFO_BIN" | awk '/\(NEEDED\)/{print $NF}' | tr -d '[]' | sort)"
echo "$NEEDED"
BAD=""
while IFS= read -r lib; do
    [ -z "$lib" ] && continue
    case "$lib" in
        libc.so.6|libm.so.6|libdl.so.2|libpthread.so.0|librt.so.1|libutil.so.1|ld-linux-*.so.*)
            ;;
        *)
            BAD="${BAD}${lib}"$'\n'
            ;;
    esac
done <<< "$NEEDED"
if [ -n "$BAD" ]; then
    echo "FAIL: unexpected non-glibc DT_NEEDED entries on terminfo_test:" >&2
    echo "$BAD" >&2
    exit 1
fi
env -i PATH=/nonexistent TEST_TMPDIR="${TEST_TMPDIR:-/tmp}" "$TERMINFO_BIN"

echo "=== 2. Full FFI (C, C++17, CApiFFI), .hs-boot, .lhs, and Cabal Configure/hsc2hs/Paths_* in -e mode ==="
OUT_MATRIX="$(
    env -i PATH="$CLEAN_PATH" RUNFILES_DIR="${RUNFILES_DIR:-}" TEST_SRCDIR="${TEST_SRCDIR:-}" TMPDIR="${TEST_TMPDIR:-/tmp}" \
        "$FULL_REPL" -e '(betaCombined 10, cxxSortedWeightedSum 5 2 9, vecMagicVersion, treeSum (Node [Leaf 20, Leaf 22]), cfgMagicHsc, topValue 5, literateDouble 15)'
)"
echo "Matrix output: $OUT_MATRIX"
grep -qF "(376,48,2026,42,1337,94,30)" <<< "$OUT_MATRIX"

echo "=== 3. Cross-library & interactive Template Haskell splices in hs_repl ==="
OUT_TH="$(
    printf ':set -XTemplateHaskell\n(crossLibSplicedFortyTwo, $(mkSecondHopExp 8))\n:quit\n' | \
    env -i PATH="$CLEAN_PATH" RUNFILES_DIR="${RUNFILES_DIR:-}" TEST_SRCDIR="${TEST_SRCDIR:-}" TMPDIR="${TEST_TMPDIR:-/tmp}" \
        "$TH_REPL"
)"
echo "$OUT_TH"
grep -qF "(42,50)" <<< "$OUT_TH"

echo "=== 4. Bazel data runfiles resolution inside hs_repl ==="
OUT_RF="$(
    env -i PATH="$CLEAN_PATH" RUNFILES_DIR="${RUNFILES_DIR:-}" TEST_SRCDIR="${TEST_SRCDIR:-}" TMPDIR="${TEST_TMPDIR:-/tmp}" \
        "$RUNFILES_REPL" -e '(,) <$> readDirectLibData <*> readTransitiveLibData'
)"
echo "Runfiles output: $OUT_RF"
grep -qF '("from-direct-hs-library-data","from-hs-library-transitive-data")' <<< "$OUT_RF"

echo "=== 5. hs_repl wrapping an hs_binary target (:main execution) ==="
OUT_BIN="$(
    printf ':main\n:quit\n' | \
    env -i PATH="$CLEAN_PATH" RUNFILES_DIR="${RUNFILES_DIR:-}" TEST_SRCDIR="${TEST_SRCDIR:-}" TMPDIR="${TEST_TMPDIR:-/tmp}" \
        "$SMOKE_BIN_REPL"
)"
echo "$OUT_BIN"
grep -qF "Hello, rules_haskell (36)" <<< "$OUT_BIN"
grep -qF "cfg=1337/1337" <<< "$OUT_BIN"
grep -qF "tinfo=real" <<< "$OUT_BIN"

echo "=== 6. Precompiled package mode (interpret_deps = False) enforcing hidden_modules ==="
OUT_COMP_OK="$(
    printf 'import ReplBeta\nbetaCombined 10\n:quit\n' | \
    env -i PATH="$CLEAN_PATH" RUNFILES_DIR="${RUNFILES_DIR:-}" TEST_SRCDIR="${TEST_SRCDIR:-}" TMPDIR="${TEST_TMPDIR:-/tmp}" \
        "$COMPILED_REPL"
)"
grep -qF "376" <<< "$OUT_COMP_OK"

OUT_COMP_HIDDEN="$(
    printf 'import ReplHidden\n:quit\n' | \
    env -i PATH="$CLEAN_PATH" RUNFILES_DIR="${RUNFILES_DIR:-}" TEST_SRCDIR="${TEST_SRCDIR:-}" TMPDIR="${TEST_TMPDIR:-/tmp}" \
        "$COMPILED_REPL" 2>&1 || true
)"
grep -qi "hidden module" <<< "$OUT_COMP_HIDDEN"

echo "=== 7. Startup ghci_commands and ghci_script hooks ==="
OUT_SCRIPTED="$(
    env -i PATH="$CLEAN_PATH" RUNFILES_DIR="${RUNFILES_DIR:-}" TEST_SRCDIR="${TEST_SRCDIR:-}" TMPDIR="${TEST_TMPDIR:-/tmp}" \
        "$SCRIPTED_REPL" -e '(inlineCmdValue, startupScriptValue, alphaExported 5)'
)"
echo "Scripted output: $OUT_SCRIPTED"
grep -qF "(111,777,305)" <<< "$OUT_SCRIPTED"

echo "=== 8. Out-of-process external interpreter mode (-fexternal-interpreter via ghc-iserv-dyn) ==="
OUT_ISERV="$(
    printf ':set -XTemplateHaskell\n($(mkSecondHopExp 58), (2 :: Integer) ^ (128 :: Int))\n:quit\n' | \
    env -i PATH="$CLEAN_PATH" RUNFILES_DIR="${RUNFILES_DIR:-}" TEST_SRCDIR="${TEST_SRCDIR:-}" TMPDIR="${TEST_TMPDIR:-/tmp}" \
        "$TH_REPL" -fexternal-interpreter
)"
echo "$OUT_ISERV"
grep -qF "(100,340282366920938463463374607431768211456)" <<< "$OUT_ISERV"

echo "=== 9. Standalone //tools/ghci and //tools/ghci:runghc (including CApiFFI script) ==="
VER_OUT="$(
    env -i PATH="$CLEAN_PATH" RUNFILES_DIR="${RUNFILES_DIR:-}" TEST_SRCDIR="${TEST_SRCDIR:-}" TMPDIR="${TEST_TMPDIR:-/tmp}" \
        "$TOOLS_GHCI" --numeric-version
)"
grep -Eq '^9\.(10|12)\.' <<< "$VER_OUT"

SCRIPT_FILE="${TEST_TMPDIR:-/tmp}/standalone_capi_script.hs"
cat > "$SCRIPT_FILE" <<'EOF'
{-# LANGUAGE CApiFFI #-}
module Main (main) where
import Foreign.C.Types (CInt (..))
import System.Environment (getArgs)

foreign import capi "sys/stat.h value S_IFREG" c_s_ifreg :: CInt

main :: IO ()
main = do
    args <- getArgs
    putStrLn ("runghc_capi:" ++ show (fromIntegral c_s_ifreg :: Int) ++ ":" ++ unwords args)
EOF

OUT_RUNGHC="$(
    env -i PATH="$CLEAN_PATH" RUNFILES_DIR="${RUNFILES_DIR:-}" TEST_SRCDIR="${TEST_SRCDIR:-}" TMPDIR="${TEST_TMPDIR:-/tmp}" \
        "$TOOLS_RUNGHC" "$SCRIPT_FILE" arg_one arg_two
)"
echo "runghc output: $OUT_RUNGHC"
grep -qF "runghc_capi:32768:arg_one arg_two" <<< "$OUT_RUNGHC"

echo "ALL INTERPRETER EXECUTION MODES VERIFIED!"
