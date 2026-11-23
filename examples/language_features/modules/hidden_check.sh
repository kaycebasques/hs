#!/usr/bin/env bash
set -euo pipefail

PKGDB_DIR=""
for arg in "$@"; do
    case "$arg" in
        *.pkgdb) PKGDB_DIR="$arg" ;;
    esac
done

CONF_FILE="$(find "$PKGDB_DIR" -maxdepth 1 -name '*.conf' | head -n 1)"
grep -qE '^exposed-modules:.*Configured' "$CONF_FILE"
grep -qE '^hidden-modules:.*Configured\.Internal' "$CONF_FILE"
if grep -qE '^exposed-modules:.*Configured\.Internal' "$CONF_FILE"; then
    echo "FAIL: Configured.Internal leaked into exposed-modules" >&2
    exit 1
fi
