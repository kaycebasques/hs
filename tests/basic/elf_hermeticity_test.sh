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
# Specifically forbidden: libgmp.so*, libtinfo.so*, libffi.so*, libnuma.so*, libHS*.so
BAD=""
while IFS= read -r lib; do
    [ -z "$lib" ] && continue
    case "$lib" in
        libc.so.6|libm.so.6|libdl.so.2|libpthread.so.0|librt.so.1|libutil.so.1)
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
echo "=== Executing $BIN under env -i PATH=/nonexistent ==="
OUT=$(env -i PATH=/nonexistent "$BIN")
echo "$OUT"

echo "$OUT" | grep -q "Hello, rules_hs (36)"
echo "$OUT" | grep -q "bigint=1606938044258990275541962092341162602522202993782792835301376"
echo "$OUT" | grep -q "cfg=1337/1337"
echo "ELF HERMETICITY TEST PASSED!"
