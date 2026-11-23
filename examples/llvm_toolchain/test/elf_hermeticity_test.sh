#!/usr/bin/env bash
set -euo pipefail

BIN="$1"
NEEDED="$(readelf -d "$BIN" | awk '/\(NEEDED\)/{print $NF}' | tr -d '[]' | sort)"
BAD=""
while IFS= read -r lib; do
    [ -z "$lib" ] && continue
    case "$lib" in
        libc.so.6|libm.so.6|libdl.so.2|libpthread.so.0|librt.so.1|libutil.so.1|ld-linux-*.so.*) ;;
        *) BAD="${BAD}${lib}"$'\n' ;;
    esac
done <<< "$NEEDED"

if [ -n "$BAD" ]; then
    echo "FAIL: unexpected non-glibc DT_NEEDED entries:" >&2
    echo "$BAD" >&2
    exit 1
fi

OUT="$(env -i PATH=/nonexistent "$BIN")"
if [ "$OUT" != "clang=True sum=42" ]; then
    echo "FAIL: unexpected output: $OUT" >&2
    exit 1
fi
