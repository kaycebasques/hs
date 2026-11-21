#!/usr/bin/env bash
set -euo pipefail

MODULE_FILE="$1"
BIN="$2"

if [ ! -f "$MODULE_FILE" ]; then
    echo "FAIL: MODULE.bazel not found at $MODULE_FILE" >&2
    exit 1
fi

if [ ! -x "$BIN" ]; then
    echo "FAIL: hermetic binary not executable: $BIN" >&2
    exit 1
fi

echo "=== 1. Checking for banned WORKSPACE files across repository ==="
REAL_MODULE="$(readlink -f "$MODULE_FILE")"
REPO_ROOT="$(dirname "$REAL_MODULE")"
if [ ! -f "$REPO_ROOT/MODULE.bazel" ] || [ ! -d "$REPO_ROOT/hs" ]; then
    echo "FAIL: resolved REPO_ROOT ($REPO_ROOT) does not look like the repository root" >&2
    exit 1
fi

FOUND_WS="$(find "$REPO_ROOT" \
    \( -name .git -o -name 'bazel-*' \) -prune -o \
    \( -name 'WORKSPACE' -o -name 'WORKSPACE.bazel' -o -name 'WORKSPACE.bzlmod' \) -print)"

if [ -n "$FOUND_WS" ]; then
    echo "FAIL: banned WORKSPACE files found in repository:" >&2
    echo "$FOUND_WS" >&2
    exit 1
fi

if [ -n "${TEST_SRCDIR:-}" ] && [ -n "${TEST_WORKSPACE:-}" ] && [ -d "$TEST_SRCDIR/$TEST_WORKSPACE" ]; then
    FOUND_RF_WS="$(find "$TEST_SRCDIR/$TEST_WORKSPACE" \
        \( -name 'WORKSPACE' -o -name 'WORKSPACE.bazel' -o -name 'WORKSPACE.bzlmod' \) -print)"
    if [ -n "$FOUND_RF_WS" ]; then
        echo "FAIL: banned WORKSPACE files found in runfiles:" >&2
        echo "$FOUND_RF_WS" >&2
        exit 1
    fi
fi
echo "OK: zero WORKSPACE / WORKSPACE.bazel / WORKSPACE.bzlmod files in $REPO_ROOT"

echo "=== 2. Auditing MODULE.bazel Bzlmod hygiene ==="
# Strip comments (#...) before inspecting declarations.
STRIPPED="$(sed 's/#.*$//' "$MODULE_FILE")"

# 2a. Assert bazel_compatibility = [">=9.0.0"]
if ! printf '%s\n' "$STRIPPED" | grep -Eq 'bazel_compatibility[[:space:]]*=[[:space:]]*\[[[:space:]]*">=9\.0\.0"[[:space:]]*\]'; then
    echo "FAIL: MODULE.bazel must declare bazel_compatibility = [\">=9.0.0\"]" >&2
    exit 1
fi
echo "OK: bazel_compatibility = [\">=9.0.0\"] declared"

# 2b. Assert zero banned legacy deps
for banned in rules_java protobuf rules_nodejs rules_python rules_nixpkgs; do
    if printf '%s\n' "$STRIPPED" | grep -Eq "\"${banned}\""; then
        echo "FAIL: banned legacy dependency '${banned}' found in MODULE.bazel" >&2
        exit 1
    fi
done
echo "OK: zero banned legacy deps (rules_java, protobuf, rules_nodejs, rules_python, rules_nixpkgs)"

# 2c. Assert every bazel_dep outside the minimal runtime allowlist is dev_dependency = True,
#     and every register_toolchains(...) block in MODULE.bazel is dev_dependency = True.
printf '%s\n' "$STRIPPED" | awk '
function flush_call(kind, buf,    dep_name, allowed, tmp) {
    if (kind == "bazel_dep") {
        tmp = buf
        if (sub(/^.*name[[:space:]]*=[[:space:]]*"/, "", tmp) && sub(/".*$/, "", tmp)) {
            dep_name = tmp
        } else {
            print "FAIL: could not parse bazel_dep name in: " buf > "/dev/stderr"
            exit 1
        }
        allowed = (dep_name == "platforms" || dep_name == "bazel_skylib" || dep_name == "rules_cc" || dep_name == "gmp")
        if (!allowed) {
            if (buf !~ /dev_dependency[[:space:]]*=[[:space:]]*True/) {
                print "FAIL: dev dependency \"" dep_name "\" in MODULE.bazel must set dev_dependency = True" > "/dev/stderr"
                exit 1
            }
            dev_deps_checked++
        }
    } else if (kind == "register_toolchains") {
        if (buf !~ /dev_dependency[[:space:]]*=[[:space:]]*True/) {
            print "FAIL: register_toolchains(...) in MODULE.bazel must set dev_dependency = True: " buf > "/dev/stderr"
            exit 1
        }
        tc_checked++
    } else if (kind == "use_extension") {
        if (buf ~ /@hermetic_cc_toolchain/ && buf !~ /dev_dependency[[:space:]]*=[[:space:]]*True/) {
            print "FAIL: hermetic_cc_toolchain use_extension in MODULE.bazel must set dev_dependency = True: " buf > "/dev/stderr"
            exit 1
        }
    }
}
{
    if (in_call == "") {
        if ($0 ~ /^[[:space:]]*bazel_dep[[:space:]]*\(/) {
            in_call = "bazel_dep"
            buf = $0
        } else if ($0 ~ /^[[:space:]]*register_toolchains[[:space:]]*\(/) {
            in_call = "register_toolchains"
            buf = $0
        } else if ($0 ~ /use_extension[[:space:]]*\(/) {
            in_call = "use_extension"
            buf = $0
        }
        if (in_call != "" && buf ~ /\)/) {
            flush_call(in_call, buf)
            in_call = ""
            buf = ""
        }
    } else {
        buf = buf " " $0
        if ($0 ~ /\)/) {
            flush_call(in_call, buf)
            in_call = ""
            buf = ""
        }
    }
}
END {
    if (in_call != "") {
        print "FAIL: unterminated " in_call " call in MODULE.bazel" > "/dev/stderr"
        exit 1
    }
    if (dev_deps_checked < 1) {
        print "FAIL: expected at least one dev_dependency bazel_dep to be checked" > "/dev/stderr"
        exit 1
    }
    print "OK: verified " dev_deps_checked " dev bazel_dep(s) and " tc_checked " register_toolchains block(s) all set dev_dependency = True"
}
'

echo "=== 3. Checking compiled binary ELF DT_NEEDED ==="
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
    echo "FAIL: unexpected non-glibc DT_NEEDED shared libraries:" >&2
    echo "$BAD" >&2
    exit 1
fi
echo "OK: DT_NEEDED contains ONLY base glibc shared libraries"

echo "=== 4. Running compiled binary under env -i PATH=/nonexistent ==="
ACTUAL_OUT="$(env -i PATH=/nonexistent "$BIN")"
EXPECTED_OUT=$'rules_hs:hermetic:ok\npow2_256=115792089237316195423570985008687907853269984665640564039457584007913129639936'

if [ "$ACTUAL_OUT" != "$EXPECTED_OUT" ]; then
    echo "FAIL: unexpected stdout from hermetic binary!" >&2
    echo "Expected:" >&2
    printf '%s\n' "$EXPECTED_OUT" >&2
    echo "Actual:" >&2
    printf '%s\n' "$ACTUAL_OUT" >&2
    exit 1
fi

echo "$ACTUAL_OUT"
echo "BZLMOD HYGIENE & HERMETICITY TEST PASSED!"
