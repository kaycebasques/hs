#!/usr/bin/env bash
set -euo pipefail

BIN="$1"
if [ ! -x "$BIN" ]; then
    echo "FAIL: binary not executable: $BIN" >&2
    exit 1
fi

echo "=== Inspecting ELF DT_NEEDED of $BIN ==="
NEEDED=$(readelf -d "$BIN" | awk '/\(NEEDED\)/{print $NF}' | tr -d '[]' | sort)
echo "$NEEDED"

# Assert ZERO non-base-glibc shared library dependencies!
# Specifically forbidden: libgmp, libtinfo, libffi, libz, libssl, libcrypto, libnuma, libHS*.so.
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
    echo "FAIL: unexpected non-glibc DT_NEEDED entries:" >&2
    echo "$BAD" >&2
    exit 1
fi

# Verify binary runs cleanly under a completely empty environment (zero LD_LIBRARY_PATH / PATH)
echo "=== Executing $BIN (0 args) under env -i PATH=/nonexistent ==="
STDOUT_FILE="$(mktemp "${TEST_TMPDIR:-/tmp}/size_stdout.XXXXXX")"
STDERR_FILE="$(mktemp "${TEST_TMPDIR:-/tmp}/size_stderr.XXXXXX")"
trap 'rm -f "$STDOUT_FILE" "$STDERR_FILE"' EXIT

set +e
env -i PATH=/nonexistent "$BIN" >"$STDOUT_FILE" 2>"$STDERR_FILE"
STATUS=$?
set -e

echo "Exit status: $STATUS"
cat "$STDERR_FILE"

if [ "$STATUS" -ne 1 ]; then
    echo "FAIL: expected exit code 1 with 0 args, got $STATUS" >&2
    exit 1
fi

if [ -s "$STDOUT_FILE" ]; then
    echo "FAIL: expected empty stdout on 0 args, got:" >&2
    cat "$STDOUT_FILE" >&2
    exit 1
fi

grep -qF "Usage: size <sitemap-url> [sitemap-url ...]" "$STDERR_FILE"
grep -qF "Example: bazel run //:size -- https://docs.stripe.com/sitemap.xml" "$STDERR_FILE"

echo "ELF HERMETICITY TEST PASSED!"
