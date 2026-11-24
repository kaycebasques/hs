"""Shared hermetic build action helpers for rules_haskell."""

load("@rules_cc//cc:action_names.bzl", "ACTION_NAMES")
load("@rules_cc//cc:find_cc_toolchain.bzl", "find_cc_toolchain")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("//haskell:providers.bzl", "HsLinkInfo", "HsPackageInfo")
load("//haskell:toolchain.bzl", "TOOLCHAIN_TYPE")

visibility(["//haskell/..."])

HsDocSourceInfo = provider(
    doc = "Internal library source and GHC flag metadata consumed by hs_haddock.",
    fields = [
        "package_name",
        "version",
        "unit_id",
        "pkg_db",
        "all_hs_srcs",
        "doc_src_files",
        "import_dirs",
        "c_include_dirs",
        "headers",
        "cabal_macros_h",
        "hidden_modules",
        "default_language",
        "default_extensions",
        "ghc_opts",
        "cpp_options",
        "cc_options",
        "direct_unit_ids",
        "compile_data",
        "pkg_root",
        "boot_pkg_names",
    ],
)

_HEADER_EXTENSIONS = (".h", ".hh", ".hpp", ".hxx", ".inc", ".inl")

def get_hs_toolchain(ctx):
    return ctx.toolchains[TOOLCHAIN_TYPE].hs

def toolchain_c_include_dirs(hs_tc):
    """Returns deduplicated C include directories for RTS and boot packages (base, unix, time, etc.)."""
    dirs = []
    seen = {}
    if hs_tc.rts_include_dir:
        dirs.append(hs_tc.rts_include_dir)
        seen[hs_tc.rts_include_dir] = True
    for f in hs_tc.rts_headers.to_list():
        d = f.dirname
        idx = d.rfind("/include")
        inc_d = d[:idx + len("/include")] if idx != -1 else d
        if inc_d and inc_d not in seen:
            seen[inc_d] = True
            dirs.append(inc_d)
    return dirs

def resolve_cc_tools(ctx):
    """Resolves C compiler, archiver, linker, and sysroot/target flags from Bazel's cc_toolchain."""
    cc_toolchain = find_cc_toolchain(ctx)
    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = ctx.features,
        unsupported_features = ctx.disabled_features,
    )
    cc_bin = cc_common.get_tool_for_action(
        feature_configuration = feature_configuration,
        action_name = ACTION_NAMES.c_compile,
    )
    ar_bin = cc_common.get_tool_for_action(
        feature_configuration = feature_configuration,
        action_name = ACTION_NAMES.cpp_link_static_library,
    )
    ld_bin = cc_toolchain.ld_executable or ""
    if ld_bin.endswith("/false"):
        ld_bin = ""

    # Extract any --sysroot / --target / -B / -fuse-ld / --ld-path flags configured by
    # rules_cc / toolchains_llvm / hermetic_cc_toolchain so ghc_cc_wrapper stays C-toolchain-agnostic.
    compile_vars = cc_common.create_compile_variables(
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        user_compile_flags = [],
    )
    raw_flags = cc_common.get_memory_inefficient_command_line(
        feature_configuration = feature_configuration,
        action_name = ACTION_NAMES.c_compile,
        variables = compile_vars,
    )

    # Extract C++ runtime library flags (e.g. -lstdc++, -lc++) and linker search paths
    # from cpp_link_executable for targets that compile .cc/.cpp sources or invoke linkers.
    link_vars = cc_common.create_link_variables(
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        is_using_linker = True,
        is_linking_dynamic_library = False,
    )
    raw_link_flags = cc_common.get_memory_inefficient_command_line(
        feature_configuration = feature_configuration,
        action_name = ACTION_NAMES.cpp_link_executable,
        variables = link_vars,
    )

    combined_tc_flags = list(raw_flags) + list(raw_link_flags)
    extra_cc_args = []
    skip_next = False
    for idx in range(len(combined_tc_flags)):
        if skip_next:
            skip_next = False
            continue
        flag = combined_tc_flags[idx]
        if (flag.startswith("--sysroot=") or
            flag.startswith("--target=") or
            flag.startswith("--ld-path=") or
            flag.startswith("-resource-dir=") or
            (flag.startswith("-fuse-ld=") and flag != "-fuse-ld=gold") or
            (flag.startswith("-B") and len(flag) > 2 and flag not in ("-Bdynamic", "-Bstatic", "-Bsymbolic", "-Bsymbolic-functions"))):
            if flag not in extra_cc_args:
                extra_cc_args.append(flag)
        elif (flag == "--sysroot" or flag == "-target" or flag == "--target" or flag == "-B" or flag == "-resource-dir") and idx + 1 < len(combined_tc_flags):
            nxt = combined_tc_flags[idx + 1]
            if flag == "-B":
                combined_b = "-B" + nxt
                if combined_b not in extra_cc_args:
                    extra_cc_args.append(combined_b)
            elif flag == "-resource-dir":
                combined_r = "-resource-dir=" + nxt
                if combined_r not in extra_cc_args:
                    extra_cc_args.append(combined_r)
            else:
                extra_cc_args.append(flag)
                extra_cc_args.append(nxt)
            skip_next = True

    # Fall back to cc_toolchain.sysroot if present and not already in flags.
    if cc_toolchain.sysroot and not any([f.startswith("--sysroot") for f in extra_cc_args]):
        extra_cc_args.append("--sysroot=" + cc_toolchain.sysroot)

    # If ld tool_path is missing or /usr/bin/false (e.g. macOS zig), fall back to cc_bin.
    if not ld_bin or ld_bin.endswith("/false"):
        ld_bin = ""

    compiler_name = (cc_toolchain.compiler or "").lower()
    cc_base = cc_bin.rsplit("/", 1)[-1].lower()
    is_gcc = ("clang" not in compiler_name and "zig" not in compiler_name) and (
        "gcc" in compiler_name or cc_base == "gcc" or cc_base.startswith("gcc-") or "-gcc" in cc_base
    )

    cxx_link_flags = []
    for lf in raw_link_flags:
        if (lf in ("-lstdc++", "-lc++", "-lc++abi", "-lsupc++", "-l:libstdc++.a", "-l:libstdc++.so", "-l:libc++.a", "-l:libc++abi.a", "-l:libunwind.a") or
            lf.startswith("-stdlib=") or
            lf.startswith("-rtlib=") or
            (lf.startswith("-L") and len(lf) > 2)):
            if lf not in cxx_link_flags:
                cxx_link_flags.append(lf)
    if not any([f.startswith("-l") for f in cxx_link_flags]):
        cxx_link_flags.append("-lc++" if ("macos" in cc_bin or "darwin" in cc_bin) else "-lstdc++")

    return struct(
        cc_toolchain = cc_toolchain,
        feature_configuration = feature_configuration,
        cc = cc_bin,
        ar = ar_bin,
        ld = ld_bin,
        is_gcc = is_gcc,
        extra_cc_args = extra_cc_args,
        cxx_link_flags = cxx_link_flags,
        all_files = cc_toolchain.all_files,
    )

def collect_deps(deps, cc_deps = []):
    """Splits direct HsPackageInfo deps from transitive HsLinkInfo and CcInfo deps."""
    direct_pkgs = []
    pkg_dbs = []
    hs_libs = []
    include_dirs = []
    headers = []
    cc_infos = []
    direct_boot_names = []
    trans_boot_names = []

    for dep in deps:
        if HsPackageInfo in dep:
            pkg = dep[HsPackageInfo]
            direct_pkgs.append(pkg)
            if pkg.is_boot and pkg.name:
                direct_boot_names.append(pkg.name)
        if HsDocSourceInfo in dep:
            trans_boot_names.append(dep[HsDocSourceInfo].boot_pkg_names)
        if HsLinkInfo in dep:
            link = dep[HsLinkInfo]
            pkg_dbs.append(link.pkg_dbs)
            hs_libs.append(link.hs_libs)
            include_dirs.append(link.include_dirs)
            headers.append(link.headers)
            if link.cc_info:
                cc_infos.append(link.cc_info)
        elif CcInfo in dep:
            cc_infos.append(dep[CcInfo])

    for dep in cc_deps:
        if CcInfo in dep:
            cc_infos.append(dep[CcInfo])

    merged_cc = cc_common.merge_cc_infos(cc_infos = cc_infos) if cc_infos else CcInfo()

    # Also collect include dirs & headers exposed via CcInfo compilation contexts
    # (critical for CApiFFI / CPP / hsc2hs consuming BCR cc_libraries or transitive install-includes!).
    cc_inc_dirs = depset(
        transitive = [
            merged_cc.compilation_context.includes,
            merged_cc.compilation_context.quote_includes,
            merged_cc.compilation_context.system_includes,
        ],
    )
    cc_hdrs = merged_cc.compilation_context.headers

    return struct(
        direct_pkgs = direct_pkgs,
        pkg_dbs = depset(transitive = pkg_dbs),
        hs_libs = depset(transitive = hs_libs),
        include_dirs = depset(transitive = include_dirs + [cc_inc_dirs]),
        headers = depset(transitive = headers + [cc_hdrs]),
        cc_info = merged_cc,
        boot_pkg_names = depset(direct_boot_names, transitive = trans_boot_names),
    )

def _parse_version_tuple(version_str):
    parts = []
    for p in version_str.split("."):
        if p.isdigit():
            parts.append(int(p))
        else:
            break
    for _ in range(3):
        if len(parts) < 3:
            parts.append(0)
    return parts[0], parts[1], parts[2]

def _sanitize_ident(name):
    return name.replace("-", "_").replace(".", "_")

def write_cabal_macros_h(ctx, out_file, package_name, version, unit_id, hs_tc, direct_pkgs):
    """Generates Cabal-compatible cabal_macros.h via ctx.actions.write (zero subprocesses)."""
    lines = [
        "/* Auto-generated by rules_haskell */",
        "#ifndef CURRENT_PACKAGE_VERSION",
        '#define CURRENT_PACKAGE_VERSION "{}"'.format(version),
        "#endif",
        "#ifndef CURRENT_PACKAGE_KEY",
        '#define CURRENT_PACKAGE_KEY "{}"'.format(unit_id),
        "#endif",
        "#ifndef CURRENT_COMPONENT_ID",
        '#define CURRENT_COMPONENT_ID "{}"'.format(unit_id),
        "#endif",
        "",
    ]

    # Emit TOOL_VERSION_ghc / MIN_TOOL_VERSION_ghc.
    g1, g2, g3 = _parse_version_tuple(hs_tc.version)
    lines.extend([
        "#ifndef TOOL_VERSION_ghc",
        '#define TOOL_VERSION_ghc "{}"'.format(hs_tc.version),
        "#endif",
        "#ifndef MIN_TOOL_VERSION_ghc",
        "#define MIN_TOOL_VERSION_ghc(major1,major2,minor) (\\",
        "  (major1) <  {} || \\".format(g1),
        "  (major1) == {} && (major2) <  {} || \\".format(g1, g2),
        "  (major1) == {} && (major2) == {} && (minor) <= {})".format(g1, g2, g3),
        "#endif",
        "",
    ])

    seen = {}
    for pkg in direct_pkgs:
        ident = _sanitize_ident(pkg.name)
        if ident in seen:
            continue
        seen[ident] = True
        m1, m2, m3 = _parse_version_tuple(pkg.version)
        lines.extend([
            "/* package {}-{} */".format(pkg.name, pkg.version),
            "#ifndef VERSION_{}".format(ident),
            '#define VERSION_{} "{}"'.format(ident, pkg.version),
            "#endif",
            "#ifndef MIN_VERSION_{}".format(ident),
            "#define MIN_VERSION_{}(major1,major2,minor) (\\".format(ident),
            "  (major1) <  {} || \\".format(m1),
            "  (major1) == {} && (major2) <  {} || \\".format(m1, m2),
            "  (major1) == {} && (major2) == {} && (minor) <= {})".format(m1, m2, m3),
            "#endif",
            "",
        ])

    # Also emit self VERSION/MIN_VERSION if not already present.
    self_ident = _sanitize_ident(package_name)
    if self_ident not in seen and version:
        m1, m2, m3 = _parse_version_tuple(version)
        lines.extend([
            "#ifndef VERSION_{}".format(self_ident),
            '#define VERSION_{} "{}"'.format(self_ident, version),
            "#endif",
            "#ifndef MIN_VERSION_{}".format(self_ident),
            "#define MIN_VERSION_{}(major1,major2,minor) (\\".format(self_ident),
            "  (major1) <  {} || \\".format(m1),
            "  (major1) == {} && (major2) <  {} || \\".format(m1, m2),
            "  (major1) == {} && (major2) == {} && (minor) <= {})".format(m1, m2, m3),
            "#endif",
            "",
        ])

    ctx.actions.write(output = out_file, content = "\n".join(lines) + "\n")

def write_paths_module(ctx, out_file, package_name, version):
    """Generates a Cabal-compatible Paths_<pkg>.hs module via ctx.actions.write."""
    mod_name = "Paths_" + _sanitize_ident(package_name)
    ver_parts = [p for p in version.split(".") if p.isdigit()]
    if not ver_parts:
        ver_parts = ["0"]
    ver_list = ", ".join(ver_parts)
    content = """\
{{-# LANGUAGE CPP #-}}
{{-# LANGUAGE NoRebindableSyntax #-}}
{{-# OPTIONS_GHC -fno-warn-missing-import-lists #-}}
{{-# OPTIONS_GHC -w #-}}
module {mod_name} (
    version,
    getBinDir, getLibDir, getDynLibDir, getDataDir, getLibexecDir,
    getDataFileName, getSysconfDir
  ) where

import Prelude
import qualified Data.Version as V

version :: V.Version
version = V.Version [{ver_list}] []

bindir, libdir, dynlibdir, datadir, libexecdir, sysconfdir :: FilePath
bindir     = "."
libdir     = "."
dynlibdir  = "."
datadir    = "."
libexecdir = "."
sysconfdir = "."

getBinDir, getLibDir, getDynLibDir, getDataDir, getLibexecDir, getSysconfDir :: IO FilePath
getBinDir     = return bindir
getLibDir     = return libdir
getDynLibDir  = return dynlibdir
getDataDir    = return datadir
getLibexecDir = return libexecdir
getSysconfDir = return sysconfdir

getDataFileName :: FilePath -> IO FilePath
getDataFileName name = return (datadir ++ "/" ++ name)
""".format(mod_name = mod_name, ver_list = ver_list)
    ctx.actions.write(output = out_file, content = content)

def resolve_package_dir(ctx, rel_dir):
    """Resolves a directory path relative to the current Bazel package root (supporting external repos)."""
    root = ctx.label.workspace_root
    pkg = ctx.label.package
    parts = []
    if root:
        parts.append(root)
    if pkg:
        parts.append(pkg)
    cleaned = rel_dir.strip("/")
    if cleaned and cleaned != ".":
        parts.append(cleaned)
    return "/".join(parts) if parts else "."

def _strip_prefix_path(file_path, dir_prefixes):
    """Computes a file's path relative to the longest matching source directory prefix."""
    best = None
    for d in dir_prefixes:
        prefix = "" if d == "." else (d.rstrip("/") + "/")
        if prefix == "":
            cand = file_path
        elif file_path.startswith(prefix):
            cand = file_path[len(prefix):]
        else:
            continue
        if best == None or len(cand) < len(best):
            best = cand
    return best if best != None else file_path

def ghc_base_env(cc_tools):
    """Environment dict for GHC / hsc2hs / configure actions using ghc_cc_wrapper."""
    env = {
        "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8",
        "RULES_HASKELL_REAL_CC": cc_tools.cc,
        "RULES_HASKELL_FORCE_PIC": "1",
    }
    if cc_tools.is_gcc:
        env["RULES_HASKELL_CC_IS_GCC"] = "1"
    if cc_tools.extra_cc_args:
        env["RULES_HASKELL_CC_EXTRA_ARGS"] = "\n".join(cc_tools.extra_cc_args)
    return env

def ghc_tool_flags(hs_tc, cc_tools):
    """Returns hermetic GHC -pgm* and -opt* flags wired to Bazel's cc_toolchain."""
    w = hs_tc.cc_wrapper.path
    flags = [
        "-pgmc",
        w,
        "-pgmcxx",
        w,
        "-pgml",
        w,
        "-pgma",
        w,
        "-pgmP",
        w,
        "-optP-E",
        "-optP-undef",
        "-optP-traditional",
        "-pgmCmmP",
        w,
        "-optCmmP-E",
        "-pgmar",
        cc_tools.ar,
        "-optl-Wl,--no-as-needed",
    ]
    if cc_tools.ld:
        flags.extend([
            "-pgmlm",
            cc_tools.ld,
            "-optlm-r",
        ])
    return flags

_CONFIGURE_COMMAND = """\
set -euo pipefail
unset RUNFILES_DIR RUNFILES_MANIFEST_FILE RUNFILES_MANIFEST_ONLY

REAL_CC_RAW="$1"
CC_WRAPPER_RAW="$2"
AR_RAW="$3"
LD_RAW="$4"
LDFLAGS_VAL="$5"
SCRIPT_REL="$6"
shift 6

EXECROOT="$(pwd)"
anchor_path() {
    case "$1" in
        ""|/*) printf '%s' "$1" ;;
        *) printf '%s/%s' "$EXECROOT" "$1" ;;
    esac
}

WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/hs_cfg.XXXXXX")"
trap 'rm -rf "$WORK_ROOT"' EXIT
WORK="$WORK_ROOT/src"
export TMPDIR="$WORK_ROOT/tmp"
mkdir -p "$WORK" "$TMPDIR"

STAGE_SPECS=()
INC_DIRS=()
CFG_ARGS=()
OUT_SPECS=()
for item in "$@"; do
    case "$item" in
        stage:*) STAGE_SPECS+=("${item#stage:}") ;;
        inc:*)   INC_DIRS+=("${item#inc:}") ;;
        arg:*)   CFG_ARGS+=("${item#arg:}") ;;
        out:*)   OUT_SPECS+=("${item#out:}") ;;
    esac
done

for spec in "${STAGE_SPECS[@]+"${STAGE_SPECS[@]}"}"; do
    rel="${spec%%=*}"
    src="${spec#*=}"
    mkdir -p "$WORK/$(dirname "$rel")"
    cp -L "$EXECROOT/$src" "$WORK/$rel"
done

export RULES_HASKELL_REAL_CC="$(anchor_path "$REAL_CC_RAW")"
export RULES_HASKELL_FORCE_PIC=1
if [ -n "${RULES_HASKELL_CC_EXTRA_ARGS:-}" ]; then
    RESOLVED_EXTRA=""
    PREV_IS_SYSROOT=0
    while IFS= read -r arg; do
        [ -z "$arg" ] && continue
        if [ "$PREV_IS_SYSROOT" = "1" ]; then
            PREV_IS_SYSROOT=0
            case "$arg" in
                /*) ;;
                *) arg="$EXECROOT/$arg" ;;
            esac
        elif [ "$arg" = "--sysroot" ]; then
            PREV_IS_SYSROOT=1
        else
            case "$arg" in
                --sysroot=/*) ;;
                --sysroot=*) arg="--sysroot=$EXECROOT/${arg#--sysroot=}" ;;
                -resource-dir=/*) ;;
                -resource-dir=*) arg="-resource-dir=$EXECROOT/${arg#-resource-dir=}" ;;
                -B/*) ;;
                -B*) arg="-B$EXECROOT/${arg#-B}" ;;
                --ld-path=external/*|--ld-path=bazel-out/*) arg="--ld-path=$EXECROOT/${arg#--ld-path=}" ;;
            esac
        fi
        if [ -n "$RESOLVED_EXTRA" ]; then
            RESOLVED_EXTRA="${RESOLVED_EXTRA}
${arg}"
        else
            RESOLVED_EXTRA="$arg"
        fi
    done <<EOF_EXTRA
$RULES_HASKELL_CC_EXTRA_ARGS
EOF_EXTRA
    export RULES_HASKELL_CC_EXTRA_ARGS="$RESOLVED_EXTRA"
fi
export CC="$(anchor_path "$CC_WRAPPER_RAW")"
export CXX="$(anchor_path "$CC_WRAPPER_RAW")"
export AR="$(anchor_path "$AR_RAW")"
if [ -n "$LD_RAW" ]; then
    export LD="$(anchor_path "$LD_RAW")"
fi
CFLAGS_VAL="-fPIC"
for inc_d in "${INC_DIRS[@]+"${INC_DIRS[@]}"}"; do
    [ -z "$inc_d" ] && continue
    CFLAGS_VAL="$CFLAGS_VAL -I$(anchor_path "$inc_d")"
done
export CFLAGS="$CFLAGS_VAL"
export LDFLAGS="$LDFLAGS_VAL"
export CONFIG_SHELL="/bin/sh"

chmod +x "$WORK/$SCRIPT_REL"
for aux in config.guess config.sub install-sh; do
    if [ -f "$WORK/$aux" ]; then
        chmod +x "$WORK/$aux"
    fi
done
(cd "$WORK" && /bin/sh "./$SCRIPT_REL" "${CFG_ARGS[@]+"${CFG_ARGS[@]}"}")

for spec in "${OUT_SPECS[@]+"${OUT_SPECS[@]}"}"; do
    rel="${spec%%=*}"
    dst="${spec#*=}"
    cp "$WORK/$rel" "$EXECROOT/$dst"
done
"""

def run_configure_action(
        ctx,
        hs_tc,
        cc_tools,
        configure_script,
        configure_srcs,
        configure_outputs,
        configure_args,
        extra_include_dirs,
        extra_headers,
        dep_include_dirs = depset()):
    """Runs a Cabal package's pre-generated autoconf ./configure hermetically."""
    out_prefix = ctx.label.name + "_configure"
    declared_outputs = []
    out_dir_roots = []
    pkg_root = resolve_package_dir(ctx, ".")

    out_specs = []
    for rel_out in configure_outputs:
        rel_clean = rel_out.lstrip("/")
        f = ctx.actions.declare_file(out_prefix + "/" + rel_clean)
        declared_outputs.append(f)

        # Ensure parent directory of generated output is searchable in -I.
        if f.dirname not in out_dir_roots:
            out_dir_roots.append(f.dirname)
        out_specs.append("out:{}={}".format(rel_clean, f.path))

    # Also add the top-level configure output root itself to -I (for `#include "include/HsNetworkConfig.h"`).
    configure_root = declared_outputs[0].path[:-len(configure_outputs[0].lstrip("/"))].rstrip("/")
    if configure_root and configure_root not in out_dir_roots:
        out_dir_roots.append(configure_root)

    # Stage configure inputs into a writable workdir so autoconf can write config.log/headers.
    stage_specs = []
    all_cfg_files = [configure_script] + list(configure_srcs)
    seen_paths = {}
    for f in all_cfg_files:
        if f.path in seen_paths:
            continue
        seen_paths[f.path] = True
        rel = _strip_prefix_path(f.path, [pkg_root])
        stage_specs.append("stage:{}={}".format(rel, f.path))

    script_rel = _strip_prefix_path(configure_script.path, [pkg_root])

    args = ctx.actions.args()
    args.add(cc_tools.cc)
    args.add(hs_tc.cc_wrapper.path)
    args.add(cc_tools.ar)
    args.add(cc_tools.ld or "")
    args.add("" if cc_tools.is_gcc else "-Wno-unused-command-line-argument")
    args.add(script_rel)
    args.add_all(stage_specs)
    args.add_all([d for d in extra_include_dirs if d], format_each = "inc:%s", uniquify = True)
    args.add_all(dep_include_dirs, format_each = "inc:%s", uniquify = True)
    args.add_all(toolchain_c_include_dirs(hs_tc), format_each = "inc:%s", uniquify = True)
    args.add_all(configure_args, format_each = "arg:%s")
    args.add_all(out_specs)

    cfg_env = {
        "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8",
    }
    if cc_tools.is_gcc:
        cfg_env["RULES_HASKELL_CC_IS_GCC"] = "1"
    if cc_tools.extra_cc_args:
        cfg_env["RULES_HASKELL_CC_EXTRA_ARGS"] = "\n".join(cc_tools.extra_cc_args)

    ctx.actions.run_shell(
        mnemonic = "HsConfigure",
        progress_message = "Running hermetic ./configure for {}".format(ctx.label),
        inputs = depset(
            all_cfg_files,
            transitive = [hs_tc.rts_headers, extra_headers, cc_tools.all_files],
        ),
        tools = [hs_tc.cc_wrapper],
        outputs = declared_outputs,
        env = cfg_env,
        command = _CONFIGURE_COMMAND,
        arguments = [args],
    )

    return declared_outputs, out_dir_roots, configure_root

def _hsc2hs_ghc_defines(hs_tc):
    """Returns Cabal's standard GHC/OS/arch CPP defines for hsc2hs."""
    m1, m2, m3 = _parse_version_tuple(hs_tc.version)
    defines = [
        "-D__GLASGOW_HASKELL__={}".format(m1 * 100 + m2),
        "-D__GLASGOW_HASKELL_PATCHLEVEL1__={}".format(m3),
    ]
    os_map = {
        "linux": "linux",
        "macos": "darwin",
        "windows": "mingw32",
    }
    cpu_map = {
        "x86_64": "x86_64",
        "arm64": "aarch64",
    }
    os_macro = os_map.get(hs_tc.target_os)
    if os_macro:
        defines.append("-D{}_BUILD_OS=1".format(os_macro))
        defines.append("-D{}_HOST_OS=1".format(os_macro))
    cpu_macro = cpu_map.get(hs_tc.target_cpu)
    if cpu_macro:
        defines.append("-D{}_BUILD_ARCH=1".format(cpu_macro))
        defines.append("-D{}_HOST_ARCH=1".format(cpu_macro))
    return defines

def run_hsc2hs_actions(
        ctx,
        hs_tc,
        cc_tools,
        hsc_srcs,
        hs_source_dirs,
        include_dirs,
        headers,
        cabal_macros_h,
        cpp_options,
        cc_options,
        dep_include_dirs = depset()):
    """Runs per-file hsc2hs actions hermetically, preserving module-relative .hs paths."""
    if not hsc_srcs:
        return [], None

    out_prefix = ctx.label.name + "_hsc"
    resolved_src_dirs = [resolve_package_dir(ctx, d) for d in (hs_source_dirs or ["."])]
    ghc_defines = _hsc2hs_ghc_defines(hs_tc)
    generated_hs = []
    hsc_root = None

    for hsc_file in hsc_srcs:
        rel_hsc = _strip_prefix_path(hsc_file.path, resolved_src_dirs)
        if rel_hsc.endswith(".hsc"):
            rel_hs = rel_hsc[:-4] + ".hs"
        else:
            rel_hs = rel_hsc + ".hs"
        out_hs = ctx.actions.declare_file(out_prefix + "/" + rel_hs)
        generated_hs.append(out_hs)
        if hsc_root == None:
            hsc_root = out_hs.path[:-len(rel_hs)].rstrip("/")

        args = ctx.actions.args()
        args.add("--template=" + hs_tc.template_hsc_h.path)
        args.add("--cc=" + hs_tc.cc_wrapper.path)
        args.add("--ld=" + hs_tc.cc_wrapper.path)
        args.add("-I.")
        args.add_all([d for d in include_dirs if d], format_each = "-I%s", uniquify = True)
        args.add_all(dep_include_dirs, format_each = "-I%s", uniquify = True)
        args.add_all(toolchain_c_include_dirs(hs_tc), format_each = "-I%s", uniquify = True)
        if cabal_macros_h:
            args.add("--cflag=-include")
            args.add("--cflag=" + cabal_macros_h.path)
        args.add("--cflag=-fPIC")
        for d_flag in ghc_defines:
            args.add("--cflag=" + d_flag)
        for opt in cpp_options:
            args.add("--cflag=" + opt)
        for opt in cc_options:
            if not (opt.startswith("-std=c++") or opt.startswith("-std=gnu++") or opt.startswith("-stdlib=")):
                args.add("--cflag=" + opt)
        args.add("-o", out_hs.path)
        args.add(hsc_file.path)

        extra_in = [hsc_file]
        if cabal_macros_h:
            extra_in.append(cabal_macros_h)

        ctx.actions.run_shell(
            mnemonic = "HsHsc2hs",
            progress_message = "Running hsc2hs on {}".format(hsc_file.short_path),
            inputs = depset(
                extra_in,
                transitive = [hs_tc.all_files, headers, cc_tools.all_files],
            ),
            tools = [hs_tc.hsc2hs, hs_tc.cc_wrapper],
            outputs = [out_hs],
            env = ghc_base_env(cc_tools),
            command = """\
set -euo pipefail
unset RUNFILES_DIR RUNFILES_MANIFEST_FILE RUNFILES_MANIFEST_ONLY
HSC2HS="$1"
shift
HSC_TMP="$(mktemp -d "${TMPDIR:-/tmp}/hs_hsc.XXXXXX")"
trap 'rm -rf "$HSC_TMP"' EXIT
export TMPDIR="$HSC_TMP"
"$HSC2HS" "$@"
""",
            arguments = [hs_tc.hsc2hs.path, args],
        )

    return generated_hs, hsc_root

def _resolve_install_includes(install_includes, hdrs, configure_outputs):
    """Maps Cabal install-includes header names to File objects from hdrs and configure_outputs."""
    if not install_includes:
        return []
    candidates = list(hdrs) + list(configure_outputs)
    matched = []
    seen = {}
    for inc_name in install_includes:
        clean = inc_name.lstrip("/")
        for f in candidates:
            if f.path in seen:
                continue
            if f.path.endswith("/" + clean) or f.basename == clean:
                # Prefer exact suffix match against clean relative include path or basename.
                matched.append(f)
                seen[f.path] = True
                break
    return matched

def compile_c_sources(
        ctx,
        hs_tc,
        cc_tools,
        c_sources,
        hdrs,
        install_includes,
        include_dirs,
        configure_outputs,
        configure_include_dirs,
        cabal_macros_h,
        cc_options,
        dep_cc_info,
        extra_libraries = []):
    """Compiles C/C++ sources via rules_cc cc_common and propagates install_includes & extra_libraries."""
    c_sources = [f for f in c_sources if not f.path.endswith(".cmm")]
    resolved_inc_dirs = [resolve_package_dir(ctx, d) for d in include_dirs]

    public_hdrs = _resolve_install_includes(
        install_includes,
        hdrs,
        configure_outputs,
    )

    # Only expose package/configure include dirs publicly (NOT GHC's internal RTS include dir).
    public_inc_dirs = []
    for d in resolved_inc_dirs + list(configure_include_dirs):
        if d and d not in public_inc_dirs:
            public_inc_dirs.append(d)

    has_cxx = any([f.path.endswith((".cc", ".cpp", ".cxx", ".C")) for f in c_sources])
    extra_link_flags = []
    if has_cxx:
        for lf in cc_tools.cxx_link_flags:
            if lf not in extra_link_flags:
                extra_link_flags.append(lf)
    for lib in extra_libraries:
        if lib:
            flag = "-l" + lib
            if flag not in extra_link_flags:
                extra_link_flags.append(flag)

    extra_cc_infos = []
    if extra_link_flags:
        extra_linker_input = cc_common.create_linker_input(
            owner = ctx.label,
            user_link_flags = extra_link_flags,
        )
        extra_cc_infos.append(CcInfo(
            linking_context = cc_common.create_linking_context(
                linker_inputs = depset([extra_linker_input]),
            ),
        ))

    # If there are no C sources AND no public headers/includes, forward dep_cc_info (+ any extra_link_flags).
    if not c_sources and not public_hdrs and not public_inc_dirs:
        if not extra_cc_infos:
            return dep_cc_info, public_inc_dirs, depset(public_hdrs)
        return cc_common.merge_cc_infos(cc_infos = extra_cc_infos + [dep_cc_info]), public_inc_dirs, depset(public_hdrs)

    # Separate real header files (for private_hdrs) from non-header textual includes
    # (e.g. crypton's `.c` files `#include`d by other `.c` files, passed via additional_inputs!).
    private_hdrs = []
    additional_inputs = []
    for f in list(hdrs) + list(configure_outputs):
        if f.path.endswith(_HEADER_EXTENSIONS):
            private_hdrs.append(f)
        additional_inputs.append(f)
    if cabal_macros_h:
        private_hdrs.append(cabal_macros_h)
        additional_inputs.append(cabal_macros_h)

    # Always include GHC RTS headers (Rts.h, HsFFI.h, ghcversion.h) for C FFI sources.
    private_hdrs.extend(hs_tc.rts_headers.to_list())

    user_flags = ["-fPIC"]
    if not cc_tools.is_gcc:
        user_flags.append("-Wno-unused-command-line-argument")
    user_flags.extend(_hsc2hs_ghc_defines(hs_tc))
    for tc_inc in toolchain_c_include_dirs(hs_tc):
        user_flags.append("-I" + tc_inc)
    if cabal_macros_h:
        user_flags.extend(["-include", cabal_macros_h.path])
    conly_flags = []
    cxx_flags = []
    for opt in cc_options:
        if opt.startswith("-std=c++") or opt.startswith("-std=gnu++") or opt.startswith("-stdlib="):
            cxx_flags.append(opt)
        elif opt.startswith("-std="):
            conly_flags.append(opt)
        else:
            user_flags.append(opt)

    comp_ctx, comp_outs = cc_common.compile(
        actions = ctx.actions,
        feature_configuration = cc_tools.feature_configuration,
        cc_toolchain = cc_tools.cc_toolchain,
        name = ctx.label.name + "_c",
        srcs = list(c_sources),
        public_hdrs = public_hdrs,
        private_hdrs = private_hdrs,
        includes = public_inc_dirs,
        quote_includes = [resolve_package_dir(ctx, ".")],
        compilation_contexts = [dep_cc_info.compilation_context],
        user_compile_flags = user_flags,
        conly_flags = conly_flags,
        cxx_flags = cxx_flags,
        additional_inputs = additional_inputs,
    )

    if c_sources:
        link_ctx, _ = cc_common.create_linking_context_from_compilation_outputs(
            actions = ctx.actions,
            feature_configuration = cc_tools.feature_configuration,
            cc_toolchain = cc_tools.cc_toolchain,
            compilation_outputs = comp_outs,
            name = ctx.label.name + "_c",
            disallow_dynamic_library = True,
        )
        own_cc_info = CcInfo(
            compilation_context = comp_ctx,
            linking_context = link_ctx,
        )
    else:
        own_cc_info = CcInfo(compilation_context = comp_ctx)

    merged = cc_common.merge_cc_infos(cc_infos = [own_cc_info] + extra_cc_infos + [dep_cc_info])
    return merged, public_inc_dirs, depset(public_hdrs)

def extract_cc_static_libs_and_flags(cc_info):
    """Extracts static library Files and user_link_flags from a merged CcInfo."""
    archives = []
    seen_archives = {}
    link_flags = []
    for li in cc_info.linking_context.linker_inputs.to_list():
        for lib in li.libraries:
            a = lib.pic_static_library or lib.static_library
            if a and a.path not in seen_archives:
                seen_archives[a.path] = True
                archives.append(a)
        for f in li.user_link_flags:
            link_flags.append(f)
    return archives, link_flags

def _resolve_reexported_for_conf(reexported_modules, exposed_modules, other_modules, unit_id, direct_pkgs):
    """Formats Cabal reexported-modules into ghc-pkg exposed-modules 'New from <unit_id>:Orig' entries."""
    if not reexported_modules:
        return [], []
    resolved = []
    unresolved = []
    for raw in reexported_modules:
        entry = raw.strip()
        if not entry:
            continue
        if " as " in entry:
            parts = entry.split(" as ", 1)
            orig_ref = parts[0].strip()
            new_mod = parts[1].strip()
        else:
            orig_ref = entry
            new_mod = entry.split(":", 1)[-1].strip()
        if ":" in orig_ref:
            pkg_parts = orig_ref.split(":", 1)
            orig_pkg = pkg_parts[0].strip()
            orig_mod = pkg_parts[1].strip()
        else:
            orig_pkg = ""
            orig_mod = orig_ref
        origin_uid = ""
        if orig_pkg:
            for p in direct_pkgs:
                if p.name == orig_pkg and p.unit_id:
                    origin_uid = p.unit_id
                    break
        elif orig_mod in exposed_modules or orig_mod in other_modules:
            origin_uid = unit_id
        else:
            for p in direct_pkgs:
                if p.unit_id and orig_mod in p.exposed_modules:
                    origin_uid = p.unit_id
                    break
        if origin_uid:
            if origin_uid == unit_id and new_mod == orig_mod:
                if new_mod not in exposed_modules:
                    resolved.append(new_mod)
            else:
                resolved.append("{} from {}:{}".format(new_mod, origin_uid, orig_mod))
        else:
            unresolved.append("{}|{}|{}".format(orig_pkg, orig_mod, new_mod))
    return resolved, unresolved

def compile_hs_library_action(
        ctx,
        hs_tc,
        cc_tools,
        package_name,
        version,
        unit_id,
        hs_srcs,
        generated_hs_srcs,
        hs_source_dirs,
        extra_import_dirs,
        exposed_modules,
        other_modules,
        hidden_modules,
        reexported_modules,
        default_language,
        default_extensions,
        ghc_opts,
        cpp_options,
        cc_options = [],
        cmm_srcs = [],
        cabal_macros_h = None,
        include_dirs = [],
        headers = depset(),
        dep_info = None,
        cc_info = None,
        compile_data = [],
        rt_shims = []):
    """Compiles Haskell modules into libHS<unit_id>.a (+ dynamic .so for TH) + relocatable ${pkgroot} ghc-pkg DB."""
    pkg_db = ctx.actions.declare_directory(ctx.label.name + ".pkgdb")
    hs_lib = ctx.actions.declare_file("libHS" + unit_id + ".a")
    cc_archives, cc_link_flags = extract_cc_static_libs_and_flags(cc_info) if cc_info else ([], [])

    # Separate .hs-boot files from directly compiled source files (GHC discovers .hs-boot via -i).
    compile_src_files = []
    for f in list(hs_srcs) + list(generated_hs_srcs):
        if not (f.path.endswith(".hs-boot") or f.path.endswith(".lhs-boot")):
            compile_src_files.append(f)

    # When explicit module lists are provided (hs_cabal_library), pass module names to
    # `ghc --make -c` so GHC automatically resolves .hs/.lhs/.hs-boot via -i and ignores
    # stray unreferenced files in source dirs. Otherwise (user hs_library), pass source paths.
    use_module_names = bool(exposed_modules or other_modules)
    compile_targets = []
    if use_module_names:
        seen_m = {}
        for m in list(exposed_modules) + list(other_modules):
            if m and m not in seen_m:
                seen_m[m] = True
                compile_targets.append(m)
    else:
        compile_targets = [f.path for f in compile_src_files]

    # Build -i search directories (including bin_dir equivalents when srcs contains generated .hs files).
    resolved_src_dirs = [resolve_package_dir(ctx, d) for d in (hs_source_dirs or ["."])]
    has_generated_srcs = any([not f.is_source for f in hs_srcs])
    bin_src_dirs = []
    if has_generated_srcs and ctx.bin_dir.path:
        for d in resolved_src_dirs:
            bin_src_dirs.append(ctx.bin_dir.path + "/" + d if d != "." else ctx.bin_dir.path)
    all_import_dirs = []
    for d in resolved_src_dirs + bin_src_dirs + list(extra_import_dirs):
        if d and d not in all_import_dirs:
            all_import_dirs.append(d)

    local_c_inc_dirs = [d for d in include_dirs if d]
    tc_c_inc_dirs = toolchain_c_include_dirs(hs_tc)

    # Assemble GHC args (using depset-backed Args to avoid analysis-time .to_list() flattening).
    ghc_args = ctx.actions.args()
    ghc_args.add("--make")
    ghc_args.add("-c")
    ghc_args.add("-fPIC")
    if hs_tc.is_dynamic_ghc:
        ghc_args.add("-dynamic-too")
    ghc_args.add("-this-unit-id", unit_id)
    ghc_args.add("-hide-all-packages")
    ghc_args.add("-hidir", pkg_db.path + "/hi")

    ghc_args.add_all(
        dep_info.pkg_dbs,
        before_each = "-package-db",
        uniquify = True,
        expand_directories = False,
    )

    direct_unit_ids = []
    seen_uid = {}
    for pkg in dep_info.direct_pkgs:
        if pkg.unit_id and pkg.unit_id not in seen_uid:
            seen_uid[pkg.unit_id] = True
            direct_unit_ids.append(pkg.unit_id)
            ghc_args.add("-package-id", pkg.unit_id)

    if default_language:
        ghc_args.add("-X" + default_language)
    for ext in default_extensions:
        ghc_args.add("-X" + ext)

    # Clear default `-i.` and add explicit import dirs.
    ghc_args.add("-i")
    for d in all_import_dirs:
        ghc_args.add("-i" + d)

    ghc_args.add_all(local_c_inc_dirs, format_each = "-I%s", uniquify = True)
    ghc_args.add_all(dep_info.include_dirs, format_each = "-I%s", uniquify = True)
    ghc_args.add_all(tc_c_inc_dirs, format_each = "-I%s", uniquify = True)

    if cabal_macros_h:
        ghc_args.add("-optP-include")
        ghc_args.add("-optP" + cabal_macros_h.path)
        ghc_args.add("-optc-include")
        ghc_args.add("-optc" + cabal_macros_h.path)

    for opt in cpp_options:
        ghc_args.add("-optP" + opt)

    for opt in cc_options:
        if not (opt.startswith("-std=c++") or opt.startswith("-std=gnu++") or opt.startswith("-stdlib=")):
            ghc_args.add("-optc" + opt)

    for flag in ghc_tool_flags(hs_tc, cc_tools):
        ghc_args.add(flag)

    for opt in ghc_opts:
        ghc_args.add(opt)

    for tgt in compile_targets:
        ghc_args.add(tgt)

    # Construct relocatable ${pkgroot} paths.
    # Because pkg_db, hi_dir, and hs_lib are all declared in the same output directory,
    # `${pkgroot}/..` is their shared parent directory!
    resolved_reexports, unresolved_reexports = _resolve_reexported_for_conf(
        reexported_modules,
        exposed_modules,
        other_modules,
        unit_id,
        dep_info.direct_pkgs,
    )
    if resolved_reexports:
        explicit_exposed = ", ".join(list(exposed_modules) + resolved_reexports)
    else:
        explicit_exposed = " ".join(exposed_modules)
    explicit_hidden = " ".join(list(other_modules) + list(hidden_modules))
    depends_str = " ".join(direct_unit_ids)
    has_hs_targets = "1" if compile_targets else "0"
    is_dynamic = "1" if hs_tc.is_dynamic_ghc else "0"
    has_compile_data = "1" if compile_data else "0"
    pkg_root = resolve_package_dir(ctx, ".")

    action_env = dict(ghc_base_env(cc_tools))
    extra_in = list(hs_srcs) + list(generated_hs_srcs) + list(cmm_srcs) + list(compile_data)
    if cabal_macros_h:
        extra_in.append(cabal_macros_h)
    if cmm_srcs:
        cmm_args_file = ctx.actions.declare_file(ctx.label.name + ".cmm.args")
        cmm_args = ctx.actions.args()
        cmm_args.set_param_file_format("multiline")
        cmm_args.add_all(["-c", "-fPIC", "-this-unit-id", unit_id, "-hide-all-packages"])
        cmm_args.add_all(
            dep_info.pkg_dbs,
            before_each = "-package-db",
            uniquify = True,
            expand_directories = False,
        )
        cmm_args.add_all(direct_unit_ids, before_each = "-package-id")
        cmm_args.add_all(local_c_inc_dirs, format_each = "-I%s", uniquify = True)
        cmm_args.add_all(dep_info.include_dirs, format_each = "-I%s", uniquify = True)
        cmm_args.add_all(tc_c_inc_dirs, format_each = "-I%s", uniquify = True)
        if cabal_macros_h:
            cmm_args.add("-optCmmP-include")
            cmm_args.add("-optCmmP" + cabal_macros_h.path)
        cmm_args.add_all(cpp_options, format_each = "-optCmmP%s")
        cmm_args.add_all(ghc_tool_flags(hs_tc, cc_tools))
        ctx.actions.write(output = cmm_args_file, content = cmm_args)
        extra_in.append(cmm_args_file)
        action_env["RULES_HASKELL_CMM_ARGS_FILE"] = cmm_args_file.path
        action_env["RULES_HASKELL_CMM_SRCS"] = "\n".join([f.path for f in cmm_srcs])
    if unresolved_reexports:
        action_env["RULES_HASKELL_UNRESOLVED_REEXPORTS"] = "\n".join(unresolved_reexports)
        action_env["RULES_HASKELL_DIRECT_PKG_DBS"] = "\n".join([
            "{}|{}".format(p.unit_id, p.pkg_db.path)
            for p in dep_info.direct_pkgs
            if p.unit_id and p.pkg_db
        ])
    if hs_tc.is_dynamic_ghc:
        shim_archives = [f for f in rt_shims if f.path.endswith(".a")] if cc_archives else []
        all_dyn_cc_archives = list(cc_archives) + shim_archives
        extra_in.extend(all_dyn_cc_archives)
        dyn_args_file = ctx.actions.declare_file(ctx.label.name + ".dyn_link.args")
        dyn_args = ctx.actions.args()
        dyn_args.set_param_file_format("multiline")
        dyn_args.add_all([
            "-shared",
            "-dynamic",
            "-fPIC",
            "-this-unit-id",
            unit_id,
            "-hide-all-packages",
            "-no-auto-link-packages",
        ])
        dyn_args.add_all(
            dep_info.pkg_dbs,
            before_each = "-package-db",
            uniquify = True,
            expand_directories = False,
        )
        dyn_args.add_all(direct_unit_ids, before_each = "-package-id")
        dyn_args.add_all(ghc_tool_flags(hs_tc, cc_tools))
        dyn_args.add("-optl-Wl,-Bsymbolic")
        dyn_args.add("-optl-L{}/{}".format(hs_tc.libdir.path, hs_tc.arch_libdir))
        if cc_archives:
            dyn_args.add("-optl-Wl,--whole-archive")
            dyn_args.add_all(cc_archives, format_each = "-optl%s", expand_directories = False)
            dyn_args.add("-optl-Wl,--no-whole-archive")
            dyn_args.add_all(shim_archives, format_each = "-optl%s", expand_directories = False)
        dyn_args.add_all(cc_link_flags, format_each = "-optl%s")
        ctx.actions.write(output = dyn_args_file, content = dyn_args)
        extra_in.append(dyn_args_file)
        action_env["RULES_HASKELL_DYN_LINK_ARGS_FILE"] = dyn_args_file.path

    ctx.actions.run_shell(
        mnemonic = "HsCompileLibrary",
        progress_message = "Compiling Haskell library {} ({})".format(package_name, unit_id),
        inputs = depset(
            extra_in,
            transitive = [
                hs_tc.all_files,
                dep_info.pkg_dbs,
                dep_info.hs_libs,
                dep_info.headers,
                headers,
                cc_tools.all_files,
            ],
        ),
        tools = [hs_tc.ghc, hs_tc.ghc_pkg, hs_tc.cc_wrapper],
        outputs = [pkg_db, hs_lib],
        env = action_env,
        command = """\
set -euo pipefail
unset RUNFILES_DIR RUNFILES_MANIFEST_FILE RUNFILES_MANIFEST_ONLY

GHC="$1"
GHC_PKG="$2"
GHC_LIB="$3"
GHC_VER="$4"
AR="$5"
PKG_DB="$6"
PKG_DB_BASE="$7"
HS_LIB="$8"
PKG_NAME="$9"
PKG_VER="${10}"
UNIT_ID="${11}"
EXPLICIT_EXPOSED="${12}"
EXPLICIT_HIDDEN="${13}"
DEPENDS_STR="${14}"
HAS_TARGETS="${15}"
IS_DYNAMIC="${16}"
HAS_COMPILE_DATA="${17}"
PKG_ROOT="${18}"
shift 18

EXECROOT="$(pwd)"
case "${RULES_HASKELL_REAL_CC:-}" in
    ""|/*) ;;
    *) export RULES_HASKELL_REAL_CC="$EXECROOT/$RULES_HASKELL_REAL_CC" ;;
esac
case "$GHC" in
    /*) GHC_ABS="$GHC" ;;
    *) GHC_ABS="$EXECROOT/$GHC" ;;
esac

HI_DIR="$PKG_DB/hi"
mkdir -p "$HI_DIR" "$PKG_DB"
WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/hs_lib.XXXXXX")"
trap 'rm -rf "$WORK_ROOT"' EXIT
ODIR="$WORK_ROOT/objs"
export TMPDIR="$WORK_ROOT/tmp"
mkdir -p "$ODIR" "$TMPDIR"

GHC_CWD="$EXECROOT"
if [ "$HAS_COMPILE_DATA" = "1" ] && [ "$PKG_ROOT" != "." ] && [ -d "$EXECROOT/$PKG_ROOT" ]; then
    GHC_CWD="$WORK_ROOT/pkg_cwd"
    mkdir -p "$GHC_CWD"
    for top in "$EXECROOT"/*; do
        [ -e "$top" ] || [ -L "$top" ] || continue
        ln -s "$top" "$GHC_CWD/$(basename "$top")"
    done
    for item in "$EXECROOT/$PKG_ROOT"/* "$EXECROOT/$PKG_ROOT"/.*; do
        [ -e "$item" ] || [ -L "$item" ] || continue
        iname="$(basename "$item")"
        [ "$iname" = "." ] || [ "$iname" = ".." ] && continue
        if [ "$iname" != "bazel-out" ] && [ "$iname" != "external" ]; then
            ln -snf "$item" "$GHC_CWD/$iname"
        fi
    done
fi

if [ "$HAS_TARGETS" = "1" ]; then
    (cd "$GHC_CWD" && "$GHC_ABS" -odir "$ODIR" -stubdir "$ODIR" "$@")
fi

if [ -n "${RULES_HASKELL_CMM_SRCS:-}" ]; then
    CMM_ARGV=()
    while IFS= read -r carg; do
        [ -z "$carg" ] && continue
        CMM_ARGV+=("$carg")
    done < "$EXECROOT/$RULES_HASKELL_CMM_ARGS_FILE"
    CMM_IDX=0
    while IFS= read -r cmm_src; do
        [ -z "$cmm_src" ] && continue
        (cd "$GHC_CWD" && "$GHC_ABS" "${CMM_ARGV[@]}" -o "$ODIR/_cmm_${CMM_IDX}.o" "$cmm_src")
        if [ "$IS_DYNAMIC" = "1" ]; then
            (cd "$GHC_CWD" && "$GHC_ABS" "${CMM_ARGV[@]}" -dynamic -o "$ODIR/_cmm_${CMM_IDX}.dyn_o" "$cmm_src")
        fi
        CMM_IDX=$((CMM_IDX + 1))
    done <<EOF_CMM_SRCS
$RULES_HASKELL_CMM_SRCS
EOF_CMM_SRCS
fi

OBJ_LIST="$WORK_ROOT/objects.rsp"
find "$ODIR" -name '*.o' | sort > "$OBJ_LIST"
if [ -s "$OBJ_LIST" ]; then
    "$AR" rcs "$HS_LIB" "@$OBJ_LIST"
    HAS_ARCHIVE_OBJS="1"
else
    "$AR" rcs "$HS_LIB"
    HAS_ARCHIVE_OBJS="$HAS_TARGETS"
fi

if [ "$IS_DYNAMIC" = "1" ] && [ "$HAS_ARCHIVE_OBJS" = "1" ]; then
    DYN_DIR="$PKG_DB/dyn"
    mkdir -p "$DYN_DIR"
    DYN_LIB="$DYN_DIR/libHS${UNIT_ID}-ghc${GHC_VER}.so"
    DYN_ARGV=()
    if [ -n "${RULES_HASKELL_DYN_LINK_ARGS_FILE:-}" ]; then
        while IFS= read -r darg; do
            [ -z "$darg" ] && continue
            DYN_ARGV+=("$darg")
        done < "$EXECROOT/$RULES_HASKELL_DYN_LINK_ARGS_FILE"
    fi
    while IFS= read -r dyn_obj; do
        [ -z "$dyn_obj" ] && continue
        DYN_ARGV+=("$dyn_obj")
    done < <(find "$ODIR" -name '*.dyn_o' | sort)
    DYN_ARGV+=("-o" "$DYN_LIB")
    "$GHC" "${DYN_ARGV[@]}"
fi

# Auto-discover exposed-modules from produced .hi files when not explicitly specified.
EXPOSED="$EXPLICIT_EXPOSED"
HIDDEN="$EXPLICIT_HIDDEN"
if [ -z "$EXPOSED" ] && [ -z "${RULES_HASKELL_UNRESOLVED_REEXPORTS:-}" ] && [ "$HAS_TARGETS" = "1" ]; then
    DISCOVERED=""
    while IFS= read -r hi; do
        [ -z "$hi" ] && continue
        mod="${hi#./}"
        mod="${mod%.hi}"
        mod="$(printf '%s' "$mod" | tr '/' '.')"
        case " $HIDDEN " in
            *" $mod "*) ;;
            *) DISCOVERED="$DISCOVERED $mod" ;;
        esac
    done < <(cd "$HI_DIR" && find . -name '*.hi' | sort)
    EXPOSED="${DISCOVERED# }"
fi

if [ -n "${RULES_HASKELL_UNRESOLVED_REEXPORTS:-}" ]; then
    while IFS='|' read -r _orig_pkg orig_mod new_mod; do
        [ -z "$orig_mod" ] && continue
        mod_rel="$(printf '%s' "$orig_mod" | tr '.' '/')"
        found_uid=""
        if [ -f "$HI_DIR/${mod_rel}.hi" ]; then
            found_uid="$UNIT_ID"
        elif [ -n "${RULES_HASKELL_DIRECT_PKG_DBS:-}" ]; then
            while IFS='|' read -r dep_uid dep_db; do
                [ -z "$dep_uid" ] && continue
                if [ -f "$dep_db/hi/${mod_rel}.hi" ]; then
                    found_uid="$dep_uid"
                    break
                fi
            done <<EOF_DBS
$RULES_HASKELL_DIRECT_PKG_DBS
EOF_DBS
        fi
        if [ -n "$found_uid" ]; then
            entry="${new_mod} from ${found_uid}:${orig_mod}"
        else
            entry="${new_mod}"
        fi
        if [ -n "$EXPOSED" ]; then
            EXPOSED="${EXPOSED}, ${entry}"
        else
            EXPOSED="${entry}"
        fi
    done <<EOF_REEX
$RULES_HASKELL_UNRESOLVED_REEXPORTS
EOF_REEX
fi

# Note: In GHC's package DB format, ${pkgroot} expands to dirname($PKG_DB).
# Static archives live in ${pkgroot} (library-dirs / library-dirs-static), while
# dynamic shared libraries for Template Haskell live strictly in ${pkgroot}/<pkgdb>/dyn
# (dynamic-library-dirs) so static hs_binary / hs_test links never pick up libHS*.so.
CONF="$PKG_DB/${UNIT_ID}.conf"
{
    printf 'name: %s\n' "$PKG_NAME"
    printf 'version: %s\n' "$PKG_VER"
    printf 'id: %s\n' "$UNIT_ID"
    printf 'key: %s\n' "$UNIT_ID"
    printf 'exposed: True\n'
    printf 'import-dirs: ${pkgroot}/%s/hi\n' "$PKG_DB_BASE"
    printf 'library-dirs: ${pkgroot}\n'
    printf 'library-dirs-static: ${pkgroot}\n'
    if [ "$IS_DYNAMIC" = "1" ] && [ "$HAS_ARCHIVE_OBJS" = "1" ]; then
        printf 'dynamic-library-dirs: ${pkgroot}/%s/dyn\n' "$PKG_DB_BASE"
    fi
    if [ "$HAS_ARCHIVE_OBJS" = "1" ]; then
        printf 'hs-libraries: HS%s\n' "$UNIT_ID"
    fi
    if [ -n "$EXPOSED" ]; then
        printf 'exposed-modules: %s\n' "$EXPOSED"
    fi
    if [ -n "$HIDDEN" ]; then
        printf 'hidden-modules: %s\n' "$HIDDEN"
    fi
    if [ -n "$DEPENDS_STR" ]; then
        printf 'depends: %s\n' "$DEPENDS_STR"
    fi
} > "$CONF"

"$GHC_PKG" --global-package-db="$GHC_LIB/package.conf.d" --package-db="$PKG_DB" recache
""",
        arguments = [
            hs_tc.ghc.path,
            hs_tc.ghc_pkg.path,
            hs_tc.libdir.path,
            hs_tc.version,
            cc_tools.ar,
            pkg_db.path,
            pkg_db.basename,
            hs_lib.path,
            package_name,
            version,
            unit_id,
            explicit_exposed,
            explicit_hidden,
            depends_str,
            has_hs_targets,
            is_dynamic,
            has_compile_data,
            pkg_root,
            ghc_args,
        ],
    )

    if use_module_names:
        wanted_rel_paths = {}
        for m in compile_targets:
            mod_rel = m.replace(".", "/")
            wanted_rel_paths[mod_rel + ".hs"] = True
            wanted_rel_paths[mod_rel + ".lhs"] = True
        doc_src_files = [
            f
            for f in compile_src_files
            if _strip_prefix_path(f.path, all_import_dirs) in wanted_rel_paths
        ]
    else:
        doc_src_files = compile_src_files

    doc_info = HsDocSourceInfo(
        package_name = package_name,
        version = version,
        unit_id = unit_id,
        pkg_db = pkg_db,
        all_hs_srcs = list(hs_srcs) + list(generated_hs_srcs),
        doc_src_files = doc_src_files,
        import_dirs = all_import_dirs,
        c_include_dirs = list(include_dirs),
        headers = headers,
        cabal_macros_h = cabal_macros_h,
        hidden_modules = list(other_modules) + list(hidden_modules),
        default_language = default_language,
        default_extensions = list(default_extensions),
        ghc_opts = list(ghc_opts),
        cpp_options = list(cpp_options),
        cc_options = list(cc_options),
        direct_unit_ids = direct_unit_ids,
        compile_data = list(compile_data),
        pkg_root = pkg_root,
        boot_pkg_names = dep_info.boot_pkg_names,
    )

    return pkg_db, pkg_db, hs_lib, doc_info
