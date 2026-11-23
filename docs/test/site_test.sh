#!/usr/bin/env bash
set -euo pipefail

SITE_DIR="$1"
DOCS_GEN_BIN="$2"
SERVE_BIN="$3"

echo "=== 1. Verifying //docs:site vanilla Hakyll + mounted Haddock outputs ==="
if [ ! -d "$SITE_DIR" ]; then
    echo "FAIL: built site directory not found at $SITE_DIR" >&2
    exit 1
fi

for required in \
    "index.html" \
    "guide/quickstart.html" \
    "guide/hackage.html" \
    "guide/c-interop-and-toolchains.html" \
    "guide/language-rts-runfiles-th.html" \
    "guide/showcase-size.html" \
    "guide/troubleshooting-and-migration.html" \
    "reference/rules.html" \
    "reference/extensions-and-providers.html" \
    "reference/lock-cli.html" \
    "internals/bazel-rules-primer.html" \
    "internals/haskell-and-ghc-primer.html" \
    "internals/overview.html" \
    "internals/rulesets-comparison.html" \
    "internals/hermeticity.html" \
    "internals/providers-and-actions.html" \
    "internals/ecosystem-and-hackage.html" \
    "internals/cross-os-and-platforms.html" \
    "internals/docs-engine.html" \
    "internals/dependencies.html" \
    "static/style.css" \
    "static/syntax.css" \
    "static/docs.js" \
    "haddock/lock/index.html" \
    "haddock/lock/CabalExtract.html" \
    "haddock/lock/LockJson.html" \
    "haddock/lock/doc-index.json" \
    "haddock/lock/src/CabalExtract.html" \
    "haddock/lock/src/LockJson.html"; do
    if [ ! -s "$SITE_DIR/$required" ]; then
        echo "FAIL: missing or empty required site artifact: $SITE_DIR/$required" >&2
        exit 1
    fi
done

grep -qF "Vanilla Hakyll" "$SITE_DIR/internals/docs-engine.html"
grep -qF "../haddock/lock/index.html" "$SITE_DIR/internals/docs-engine.html"
grep -qF "CabalExtract.html" "$SITE_DIR/haddock/lock/index.html"
grep -qF "parseStackageYaml" "$SITE_DIR/haddock/lock/doc-index.json"
echo "OK: all 20 Hakyll HTML pages, Skylighting CSS, and mounted //tools/lock Haddock verified"

echo "=== 2. Verifying ELF DT_NEEDED hermeticity of //docs:docs_gen and //docs:serve ==="
for bin in "$DOCS_GEN_BIN" "$SERVE_BIN"; do
    if [ ! -x "$bin" ]; then
        echo "FAIL: binary not executable: $bin" >&2
        exit 1
    fi
    NEEDED="$(readelf -d "$bin" | awk '/\(NEEDED\)/{print $NF}' | tr -d '[]' | sort)"
    echo "DT_NEEDED ($bin):"
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
        echo "FAIL: $bin dynamically links non-glibc libraries:" >&2
        echo "$BAD" >&2
        exit 1
    fi
done
echo "OK: both //docs:docs_gen and //docs:serve link strictly base glibc"

echo "=== 3. Verifying execution under env -i PATH=/nonexistent ==="
HELP_GEN="$(env -i PATH=/nonexistent "$DOCS_GEN_BIN" --help)"
grep -qi "hakyll" <<< "$HELP_GEN"

HELP_SERVE="$(env -i PATH=/nonexistent "$SERVE_BIN" --help)"
grep -qF "Usage: serve" <<< "$HELP_SERVE"

echo "=== 4. Verifying //docs:serve HTTP/1.1 static server for Hakyll & Haddock ==="
SERVE_LOG="${TEST_TMPDIR:-/tmp}/serve_test.$$.log"
"$SERVE_BIN" --host 127.0.0.1 --port 0 --site-dir "$SITE_DIR" >"$SERVE_LOG" 2>&1 &
SERVE_PID=$!
cleanup_serve() {
    kill "$SERVE_PID" 2>/dev/null || true
    wait "$SERVE_PID" 2>/dev/null || true
    rm -f "$SERVE_LOG"
}
trap cleanup_serve EXIT

ACTUAL_PORT=""
for _ in $(seq 1 50); do
    if grep -q "http://127.0.0.1:" "$SERVE_LOG" 2>/dev/null; then
        ACTUAL_PORT="$(sed -n 's/.*http:\/\/127\.0\.0\.1:\([0-9][0-9]*\)\/.*/\1/p' "$SERVE_LOG" | head -n 1)"
        [ -n "$ACTUAL_PORT" ] && break
    fi
    sleep 0.05
done

if [ -z "$ACTUAL_PORT" ]; then
    echo "FAIL: //docs:serve did not start listening in time:" >&2
    cat "$SERVE_LOG" >&2
    exit 1
fi

exec 3<>"/dev/tcp/127.0.0.1/${ACTUAL_PORT}"
printf 'GET /internals/docs-engine.html HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n' >&3
HTTP_RESP_HAKYLL="$(cat <&3)"
exec 3>&-

grep -qF "HTTP/1.1 200 OK" <<< "$HTTP_RESP_HAKYLL"
grep -qF "Hakyll" <<< "$HTTP_RESP_HAKYLL"

exec 4<>"/dev/tcp/127.0.0.1/${ACTUAL_PORT}"
printf 'GET /haddock/lock/index.html HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n' >&4
HTTP_RESP_HADDOCK="$(cat <&4)"
exec 4>&-

grep -qF "HTTP/1.1 200 OK" <<< "$HTTP_RESP_HADDOCK"
grep -qF "CabalExtract" <<< "$HTTP_RESP_HADDOCK"

echo "OK: //docs:serve served both Hakyll and /haddock/lock/index.html over HTTP/1.1 on port $ACTUAL_PORT"
echo "DOCS SITE & ELF HERMETICITY TEST PASSED!"
