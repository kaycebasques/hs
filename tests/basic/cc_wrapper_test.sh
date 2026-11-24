#!/usr/bin/env bash
set -euo pipefail

WRAPPER="$1"
if [ ! -x "$WRAPPER" ]; then
    echo "FAIL: ghc_cc_wrapper not executable: $WRAPPER" >&2
    exit 1
fi

WORK="$(mktemp -d "${TEST_TMPDIR:-/tmp}/ccw_test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Fake compiler recorder writing each received argv token on its own line.
FAKE_CC="$WORK/fake_cc.sh"
cat > "$FAKE_CC" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
    printf '%s\n' "$arg"
done
EOF
chmod +x "$FAKE_CC"

# 1. @cxx.rsp containing a .cpp source MUST NOT receive -nostdinc++.
CXX_RSP="$WORK/cxx.rsp"
printf '"%s"\n"%s"\n' "-c" "src/widget.cpp" > "$CXX_RSP"
CXX_OUT="$(RULES_HASKELL_REAL_CC="$FAKE_CC" TMPDIR="$WORK/tmp1" "$WRAPPER" "@$CXX_RSP")"
if printf '%s\n' "$CXX_OUT" | grep -qxF -- "-nostdinc++"; then
    echo "FAIL: ghc_cc_wrapper injected -nostdinc++ for @cxx.rsp C++ compilation:" >&2
    echo "$CXX_OUT" >&2
    exit 1
fi
echo "OK: @cxx.rsp detected as C++ (no -nostdinc++)"

# 2. @c.rsp containing a .c source MUST still receive -nostdinc++.
C_RSP="$WORK/c.rsp"
printf '"%s"\n"%s"\n' "-c" "src/widget.c" > "$C_RSP"
C_OUT="$(RULES_HASKELL_REAL_CC="$FAKE_CC" TMPDIR="$WORK/tmp1" "$WRAPPER" "@$C_RSP")"
if ! printf '%s\n' "$C_OUT" | grep -qxF -- "-nostdinc++"; then
    echo "FAIL: ghc_cc_wrapper omitted -nostdinc++ for @c.rsp C compilation:" >&2
    echo "$C_OUT" >&2
    exit 1
fi
echo "OK: @c.rsp detected as C (-nostdinc++ present)"

# 3. .dyn_o symlink aliasing uses mkdtemp inside TMPDIR and cleans up after execution.
SESSION_TMP="$WORK/session_tmp"
mkdir -p "$SESSION_TMP"
DYN_O="$WORK/Sample.dyn_o"
printf 'obj' > "$DYN_O"

# Verify inside fake_cc that the .o alias exists DURING execution, and is removed AFTER exit.
CHECK_CC="$WORK/check_cc.sh"
cat > "$CHECK_CC" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
FOUND=0
for arg in "$@"; do
    case "$arg" in
        *.o)
            if [ ! -e "$arg" ]; then
                echo "FAIL: .o alias missing during compiler execution: $arg" >&2
                exit 1
            fi
            FOUND=1
            ;;
    esac
done
if [ "$FOUND" != "1" ]; then
    echo "FAIL: expected rewritten .o alias argument" >&2
    exit 1
fi
EOF
chmod +x "$CHECK_CC"

RULES_HASKELL_REAL_CC="$CHECK_CC" TMPDIR="$SESSION_TMP" "$WRAPPER" "$DYN_O"

LEFTOVERS="$(ls -A "$SESSION_TMP")"
if [ -n "$LEFTOVERS" ]; then
    echo "FAIL: ghc_cc_wrapper leaked temporary files/dirs in TMPDIR:" >&2
    echo "$LEFTOVERS" >&2
    exit 1
fi
echo "OK: .dyn_o alias resolved during execution and cleaned up with zero TMPDIR leaks"

# 4. Rewriting @link.rsp MUST NOT mutate the input @rsp file in place.
LINK_RSP="$WORK/link.rsp"
printf '"%s"\n' "-Wl,-h,libdemo.so" > "$LINK_RSP"
ORIG_RSP_CONTENT="$(cat "$LINK_RSP")"

CHECK_RSP_CC="$WORK/check_rsp_cc.sh"
cat > "$CHECK_RSP_CC" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
FOUND_SONAME=0
for arg in "$@"; do
    case "$arg" in
        @*)
            rsp_file="${arg#@}"
            if grep -qF -- "-Wl,-soname,libdemo.so" "$rsp_file"; then
                FOUND_SONAME=1
            fi
            ;;
    esac
done
if [ "$FOUND_SONAME" != "1" ]; then
    echo "FAIL: expected rewritten @rsp containing -Wl,-soname,libdemo.so" >&2
    exit 1
fi
EOF
chmod +x "$CHECK_RSP_CC"

RULES_HASKELL_REAL_CC="$CHECK_RSP_CC" TMPDIR="$SESSION_TMP" "$WRAPPER" "@$LINK_RSP"

AFTER_RSP_CONTENT="$(cat "$LINK_RSP")"
if [ "$ORIG_RSP_CONTENT" != "$AFTER_RSP_CONTENT" ]; then
    echo "FAIL: ghc_cc_wrapper mutated input @rsp file in place!" >&2
    exit 1
fi
LEFTOVERS2="$(ls -A "$SESSION_TMP")"
if [ -n "$LEFTOVERS2" ]; then
    echo "FAIL: ghc_cc_wrapper leaked temporary @rsp files/dirs in TMPDIR:" >&2
    echo "$LEFTOVERS2" >&2
    exit 1
fi
echo "OK: @rsp rewritten into temporary file without mutating input @rsp"
