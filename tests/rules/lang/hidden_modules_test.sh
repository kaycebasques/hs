#!/usr/bin/env bash
set -euo pipefail

PKGDB_DIR=""
for arg in "$@"; do
    case "$arg" in
        *.pkgdb) PKGDB_DIR="$arg" ;;
    esac
done

if [ -z "$PKGDB_DIR" ] || [ ! -d "$PKGDB_DIR" ]; then
    echo "FAIL: no .pkgdb directory found in args: $*" >&2
    exit 1
fi

CONF_FILE="$(find "$PKGDB_DIR" -maxdepth 1 -name '*.conf' | head -n 1)"
if [ -z "$CONF_FILE" ] || [ ! -f "$CONF_FILE" ]; then
    echo "FAIL: no .conf file found in $PKGDB_DIR" >&2
    exit 1
fi

grep -qE '^exposed-modules:.*Org\.RulesHaskell\.Eval\.Engine' "$CONF_FILE"
grep -qE '^exposed-modules:.*Org\.RulesHaskell\.Types' "$CONF_FILE"
grep -qE '^hidden-modules:.*Org\.RulesHaskell\.Internal\.Secret' "$CONF_FILE"

if grep -qE '^exposed-modules:.*Org\.RulesHaskell\.Internal\.Secret' "$CONF_FILE"; then
    echo "FAIL: hidden module Org.RulesHaskell.Internal.Secret leaked into exposed-modules!" >&2
    cat "$CONF_FILE" >&2
    exit 1
fi

echo "OK: hidden_modules recorded strictly in hidden-modules of $CONF_FILE"
