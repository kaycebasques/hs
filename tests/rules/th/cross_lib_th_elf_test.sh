#!/usr/bin/env bash
set -euo pipefail

BIN="$1"
if [ ! -x "$BIN" ]; then
    echo "FAIL: binary not executable: $BIN" >&2
    exit 1
fi

NEEDED="$(readelf -d "$BIN" | awk '/\(NEEDED\)/{print $NF}' | tr -d '[]' | sort)"
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
    echo "FAIL: cross-library TH executable leaked non-glibc DT_NEEDED libraries:" >&2
    echo "$BAD" >&2
    exit 1
fi

OUT="$(env -i PATH=/nonexistent "$BIN")"
echo "$OUT"
echo "$OUT" | grep -qF "CROSS-LIBRARY TEMPLATE HASKELL TEST PASSED!"
