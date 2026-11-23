#!/usr/bin/env bash
set -euo pipefail

BIN="$1"
HADDOCK_DIR="$2"

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
if [ "$OUT" != "ghc=912" ]; then
    echo "FAIL: expected ghc=912, got: $OUT" >&2
    exit 1
fi

for f in "index.html" "FileNote.html" "doc-index.json" "src/FileNote.html"; do
    if [ ! -s "$HADDOCK_DIR/$f" ]; then
        echo "FAIL: missing GHC 9.12.4 Haddock output $HADDOCK_DIR/$f" >&2
        exit 1
    fi
done
