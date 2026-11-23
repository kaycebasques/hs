#!/usr/bin/env bash
set -euo pipefail

TERMINFO_BIN="$1"
CALC_REPL="$2"
TOOLS_GHCI="$3"
TOOLS_RUNGHC="$4"
HELLO_SCRIPT="$5"

CLEAN_PATH="/usr/bin:/bin"

# 1. Verify static libtinfo.a + libgmp.a ELF linking on terminfo_test
NEEDED="$(readelf -d "$TERMINFO_BIN" | awk '/\(NEEDED\)/{print $NF}' | tr -d '[]' | sort)"
BAD=""
while IFS= read -r lib; do
    [ -z "$lib" ] && continue
    case "$lib" in
        libc.so.6|libm.so.6|libdl.so.2|libpthread.so.0|librt.so.1|libutil.so.1|ld-linux-*.so.*) ;;
        *) BAD="${BAD}${lib}"$'\n' ;;
    esac
done <<< "$NEEDED"
if [ -n "$BAD" ]; then
    echo "FAIL: unexpected non-glibc DT_NEEDED entries on terminfo_test:" >&2
    echo "$BAD" >&2
    exit 1
fi
env -i PATH=/nonexistent "$TERMINFO_BIN"

# 2. Evaluate CApiFFI, TH splice, hidden_modules, compiled_deps, .ghci hooks, and data runfiles via -e
EVAL_OUT="$(
    env -i PATH="$CLEAN_PATH" RUNFILES_DIR="${RUNFILES_DIR:-}" TEST_SRCDIR="${TEST_SRCDIR:-}" TMPDIR="${TEST_TMPDIR:-/tmp}" \
        "$CALC_REPL" -e '(\b -> (calcTotal 5, calcMagic, secretStep 10, precompiledOffset, inlineBonus * startupFactor, b)) <$> readReplBanner'
)"
grep -qF '(47,99,15,100,30,"repl-runfile-ok")' <<< "$EVAL_OUT"

# 3. Verify live :reload against modified BUILD_WORKSPACE_DIRECTORY sources in one session
RF_BASE="${RUNFILES_DIR:-${TEST_SRCDIR:-}}"
case "$RF_BASE" in
    /*) ;;
    *) RF_BASE="$(cd "$RF_BASE" && pwd)" ;;
esac
WS_TMP="$(mktemp -d "${TEST_TMPDIR:-/tmp}/repl_ws.XXXXXX")"
mkdir -p "$WS_TMP/src/Calc" "$WS_TMP/cbits"
cp -L "$RF_BASE/_main/src/Calc/Public.hs" "$WS_TMP/src/Calc/Public.hs"
cp -L "$RF_BASE/_main/src/Calc/Secret.hs" "$WS_TMP/src/Calc/Secret.hs"
cp -L "$RF_BASE/_main/cbits/calc_c.h" "$WS_TMP/cbits/calc_c.h"
chmod -R u+w "$WS_TMP"

RELOAD_OUT="$(
    printf 'calcTotal 5\n:! sed -i "s/x + 5/x + 105/" "%s/src/Calc/Secret.hs"\n:reload\ncalcTotal 5\n:quit\n' "$WS_TMP" | \
    env -i PATH="$CLEAN_PATH" BUILD_WORKSPACE_DIRECTORY="$WS_TMP" RUNFILES_DIR="$RF_BASE" TMPDIR="${TEST_TMPDIR:-/tmp}" \
        "$CALC_REPL"
)"
grep -qF "47" <<< "$RELOAD_OUT"
grep -qF "147" <<< "$RELOAD_OUT"

# 4. Verify GHCi bytecode debugger (:break and :continue)
DBG_OUT="$(
    printf ':break Calc.Secret.secretStep\ncalcTotal 5\n:continue\n:quit\n' | \
    env -i PATH="$CLEAN_PATH" RUNFILES_DIR="$RF_BASE" TMPDIR="${TEST_TMPDIR:-/tmp}" \
        "$CALC_REPL"
)"
grep -qF "Stopped in Calc.Secret.secretStep" <<< "$DBG_OUT"
grep -qF "47" <<< "$DBG_OUT"

# 5. Verify out-of-process external interpreter (-fexternal-interpreter via ghc-iserv-dyn)
ISERV_OUT="$(
    env -i PATH="$CLEAN_PATH" RUNFILES_DIR="$RF_BASE" TMPDIR="${TEST_TMPDIR:-/tmp}" \
        "$CALC_REPL" -fexternal-interpreter -e 'calcTotal 5'
)"
grep -qF "47" <<< "$ISERV_OUT"

# 6. Verify standalone @rules_haskell//tools/ghci and @rules_haskell//tools/ghci:runghc
GHCI_OUT="$(
    env -i PATH="$CLEAN_PATH" RUNFILES_DIR="$RF_BASE" TMPDIR="${TEST_TMPDIR:-/tmp}" \
        "$TOOLS_GHCI" -e '(2 :: Integer) ^ (64 :: Int)'
)"
grep -qF "18446744073709551616" <<< "$GHCI_OUT"

SCRIPT_ABS="$(cd "$(dirname "$HELLO_SCRIPT")" && pwd)/$(basename "$HELLO_SCRIPT")"
RUNGHC_OUT="$(
    env -i PATH="$CLEAN_PATH" RUNFILES_DIR="$RF_BASE" TMPDIR="${TEST_TMPDIR:-/tmp}" \
        "$TOOLS_RUNGHC" "$SCRIPT_ABS" alpha beta
)"
grep -qF "runghc-ok:alpha beta" <<< "$RUNGHC_OUT"
