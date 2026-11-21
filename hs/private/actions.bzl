"""Shared hermetic build action helpers for rules_hs."""

load("@rules_cc//cc:action_names.bzl", "ACTION_NAMES")
load("@rules_cc//cc:find_cc_toolchain.bzl", "find_cc_toolchain")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("//hs:providers.bzl", "HsLinkInfo", "HsPackageInfo")
load("//hs:toolchain.bzl", "TOOLCHAIN_TYPE")

_HEADER_EXTENSIONS = (".h", ".hh", ".hpp", ".hxx", ".inc", ".inl")

def get_hs_toolchain(ctx):
    return ctx.toolchains[TOOLCHAIN_TYPE].hs

def _toolchain_c_include_dirs(hs_tc):
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

    # Extract any --sysroot / --target flags configured by rules_cc / toolchains_llvm / Pigweed
    # so ghc_cc_wrapper stays 100% C-toolchain-agnostic.
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
    extra_cc_args = []
    skip_next = False
    for idx in range(len(raw_flags)):
        if skip_next:
            skip_next = False
            continue
        flag = raw_flags[idx]
        if flag.startswith("--sysroot=") or flag.startswith("--target="):
            extra_cc_args.append(flag)
        elif (flag == "--sysroot" or flag == "-target" or flag == "--target") and idx + 1 < len(raw_flags):
            extra_cc_args.append(flag)
            extra_cc_args.append(raw_flags[idx + 1])
            skip_next = True

    # Fall back to cc_toolchain.sysroot if present and not already in flags.
    if cc_toolchain.sysroot and not any([f.startswith("--sysroot") for f in extra_cc_args]):
        extra_cc_args.append("--sysroot=" + cc_toolchain.sysroot)

    # If ld tool_path is missing or /usr/bin/false (e.g. macOS zig), fall back to cc_bin.
    if not ld_bin or ld_bin.endswith("/false"):
        ld_bin = ""

    return struct(
        cc_toolchain = cc_toolchain,
        feature_configuration = feature_configuration,
        cc = cc_bin,
        ar = ar_bin,
        ld = ld_bin,
        extra_cc_args = extra_cc_args,
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

    for dep in deps:
        if HsPackageInfo in dep:
            direct_pkgs.append(dep[HsPackageInfo])
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
        "/* Auto-generated by rules_hs */",
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
        "RULES_HS_REAL_CC": cc_tools.cc,
        "RULES_HS_FORCE_PIC": "1",
    }
    if cc_tools.extra_cc_args:
        env["RULES_HS_CC_EXTRA_ARGS"] = "\n".join(cc_tools.extra_cc_args)
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

def _execroot_or_abs(path):
    """Preserves absolute tool/include paths while anchoring execroot-relative paths to $EXECROOT."""
    return path if path.startswith("/") else ("$EXECROOT/" + path)

def run_configure_action(
        ctx,
        hs_tc,
        cc_tools,
        configure_script,
        configure_srcs,
        configure_outputs,
        configure_args,
        extra_include_dirs,
        extra_headers):
    """Runs a Cabal package's pre-generated autoconf ./configure hermetically."""
    out_prefix = ctx.label.name + "_configure"
    declared_outputs = []
    out_dir_roots = []
    pkg_root = resolve_package_dir(ctx, ".")

    copy_cmds = []
    for rel_out in configure_outputs:
        rel_clean = rel_out.lstrip("/")
        f = ctx.actions.declare_file(out_prefix + "/" + rel_clean)
        declared_outputs.append(f)

        # Ensure parent directory of generated output is searchable in -I.
        if f.dirname not in out_dir_roots:
            out_dir_roots.append(f.dirname)
        copy_cmds.append('cp "$WORK/{rel}" "$EXECROOT/{dst}"'.format(
            rel = rel_clean,
            dst = f.path,
        ))

    # Also add the top-level configure output root itself to -I (for `#include "include/HsNetworkConfig.h"`).
    configure_root = declared_outputs[0].path[:-len(configure_outputs[0].lstrip("/"))].rstrip("/")
    if configure_root and configure_root not in out_dir_roots:
        out_dir_roots.append(configure_root)

    # Stage configure inputs into a writable workdir so autoconf can write config.log/headers.
    stage_lines = []
    all_cfg_files = [configure_script] + list(configure_srcs)
    seen_paths = {}
    for f in all_cfg_files:
        if f.path in seen_paths:
            continue
        seen_paths[f.path] = True
        rel = _strip_prefix_path(f.path, [pkg_root])
        stage_lines.append('mkdir -p "$WORK/$(dirname "{rel}")" && cp -L "$EXECROOT/{src}" "$WORK/{rel}"'.format(
            src = f.path,
            rel = rel,
        ))

    script_rel = _strip_prefix_path(configure_script.path, [pkg_root])
    cflags_list = ["-fPIC"]
    for tc_inc in _toolchain_c_include_dirs(hs_tc):
        cflags_list.append("-I" + _execroot_or_abs(tc_inc))
    for d in extra_include_dirs:
        cflags_list.append("-I" + _execroot_or_abs(d))

    cfg_env = {}
    if cc_tools.extra_cc_args:
        cfg_env["RULES_HS_CC_EXTRA_ARGS"] = "\n".join(cc_tools.extra_cc_args)

    cmd = """\
set -euo pipefail
unset RUNFILES_DIR RUNFILES_MANIFEST_FILE RUNFILES_MANIFEST_ONLY
EXECROOT="$(pwd)"
WORK="$(mktemp -d "${{TMPDIR:-/tmp}}/hs_cfg.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

{stage_cmds}

export RULES_HS_REAL_CC="{real_cc}"
export RULES_HS_FORCE_PIC=1
if [ -n "${{RULES_HS_CC_EXTRA_ARGS:-}}" ]; then
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
                --sysroot=*) arg="--sysroot=$EXECROOT/${{arg#--sysroot=}}" ;;
            esac
        fi
        if [ -n "$RESOLVED_EXTRA" ]; then
            RESOLVED_EXTRA="${{RESOLVED_EXTRA}}
${{arg}}"
        else
            RESOLVED_EXTRA="$arg"
        fi
    done <<EOF_EXTRA
$RULES_HS_CC_EXTRA_ARGS
EOF_EXTRA
    export RULES_HS_CC_EXTRA_ARGS="$RESOLVED_EXTRA"
fi
export CC="{cc_wrapper}"
export CXX="{cc_wrapper}"
export AR="{ar}"
{ld_export}
export CFLAGS="{cflags}"
export LDFLAGS="-Wno-unused-command-line-argument"
export CONFIG_SHELL="/bin/sh"

chmod +x "$WORK/{script_rel}"
for aux in config.guess config.sub install-sh; do
    if [ -f "$WORK/$aux" ]; then
        chmod +x "$WORK/$aux"
    fi
done
(cd "$WORK" && /bin/sh "./{script_rel}" {cfg_args})

{copy_cmds}
""".format(
        stage_cmds = "\n".join(stage_lines),
        real_cc = _execroot_or_abs(cc_tools.cc),
        cc_wrapper = _execroot_or_abs(hs_tc.cc_wrapper.path),
        ar = _execroot_or_abs(cc_tools.ar),
        ld_export = 'export LD="{}"'.format(_execroot_or_abs(cc_tools.ld)) if cc_tools.ld else "",
        cflags = " ".join(cflags_list),
        script_rel = script_rel,
        cfg_args = " ".join(["'" + a.replace("'", "'\"'\"'") + "'" for a in configure_args]),
        copy_cmds = "\n".join(copy_cmds),
    )

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
        command = cmd,
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
        cc_options):
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
        for tc_inc in _toolchain_c_include_dirs(hs_tc):
            args.add("-I" + tc_inc)
        for d in include_dirs:
            args.add("-I" + d)
        if cabal_macros_h:
            args.add("--cflag=-include")
            args.add("--cflag=" + cabal_macros_h.path)
        args.add("--cflag=-fPIC")
        for d_flag in ghc_defines:
            args.add("--cflag=" + d_flag)
        for opt in cpp_options:
            args.add("--cflag=" + opt)
        for opt in cc_options:
            if not (opt.startswith("-std=c++") or opt.startswith("-std=gnu++")):
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
exec "$HSC2HS" "$@"
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
        dep_cc_info):
    """Compiles C sources via rules_cc cc_common and propagates install_includes headers."""
    resolved_inc_dirs = [resolve_package_dir(ctx, d) for d in include_dirs]

    public_hdrs = _resolve_install_includes(
        install_includes,
        hdrs,
        configure_outputs,
    )

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
    rts_hdr_list = hs_tc.rts_headers.to_list()
    private_hdrs.extend(rts_hdr_list)

    # Only expose package/configure include dirs publicly (NOT GHC's internal RTS include dir).
    public_inc_dirs = []
    for d in resolved_inc_dirs + list(configure_include_dirs):
        if d and d not in public_inc_dirs:
            public_inc_dirs.append(d)

    # If there are no C sources AND no public headers/includes, just forward dep_cc_info.
    if not c_sources and not public_hdrs and not public_inc_dirs:
        return dep_cc_info, public_inc_dirs, depset(public_hdrs)

    user_flags = [
        "-fPIC",
        "-Wno-unused-command-line-argument",
    ]
    user_flags.extend(_hsc2hs_ghc_defines(hs_tc))
    for tc_inc in _toolchain_c_include_dirs(hs_tc):
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

    merged = cc_common.merge_cc_infos(cc_infos = [own_cc_info, dep_cc_info])
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
        return []
    resolved = []
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
            new_mod = entry
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
            resolved.append("{} from {}:{}".format(new_mod, origin_uid, orig_mod))
        else:
            resolved.append(new_mod)
    return resolved

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
        cabal_macros_h,
        include_dirs,
        headers,
        dep_info,
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

    # Collect all -I C include dirs for CPP & CApiFFI.
    all_c_inc_dirs = []
    for d in list(include_dirs) + dep_info.include_dirs.to_list() + [hs_tc.rts_include_dir]:
        if d and d not in all_c_inc_dirs:
            all_c_inc_dirs.append(d)

    # Assemble GHC args.
    ghc_args = ctx.actions.args()
    ghc_args.add("--make")
    ghc_args.add("-c")
    ghc_args.add("-fPIC")
    if hs_tc.is_dynamic_ghc:
        ghc_args.add("-dynamic-too")
    ghc_args.add("-this-unit-id", unit_id)
    ghc_args.add("-hide-all-packages")
    ghc_args.add("-hidir", pkg_db.path + "/hi")

    for db in dep_info.pkg_dbs.to_list():
        ghc_args.add("-package-db", db.path)

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

    for d in all_c_inc_dirs:
        ghc_args.add("-I" + d)

    if cabal_macros_h:
        ghc_args.add("-optP-include")
        ghc_args.add("-optP" + cabal_macros_h.path)
        ghc_args.add("-optc-include")
        ghc_args.add("-optc" + cabal_macros_h.path)

    for opt in cpp_options:
        ghc_args.add("-optP" + opt)

    for flag in ghc_tool_flags(hs_tc, cc_tools):
        ghc_args.add(flag)

    for opt in ghc_opts:
        ghc_args.add(opt)

    for tgt in compile_targets:
        ghc_args.add(tgt)

    # Construct relocatable ${pkgroot} paths.
    # Because pkg_db, hi_dir, and hs_lib are all declared in the same output directory,
    # `${pkgroot}/..` is their shared parent directory!
    resolved_reexports = _resolve_reexported_for_conf(
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
    explicit_reexported = ""
    depends_str = " ".join(direct_unit_ids)
    has_hs_targets = "1" if compile_targets else "0"
    is_dynamic = "1" if hs_tc.is_dynamic_ghc else "0"
    has_compile_data = "1" if compile_data else "0"
    pkg_root = resolve_package_dir(ctx, ".")

    action_env = dict(ghc_base_env(cc_tools))
    extra_in = list(hs_srcs) + list(generated_hs_srcs) + list(compile_data)
    if cabal_macros_h:
        extra_in.append(cabal_macros_h)
    if hs_tc.is_dynamic_ghc:
        shim_archives = [f for f in rt_shims if f.path.endswith(".a")] if cc_archives else []
        all_dyn_cc_archives = list(cc_archives) + shim_archives
        extra_in.extend(all_dyn_cc_archives)
        dyn_link_args = [
            "-shared",
            "-dynamic",
            "-fPIC",
            "-this-unit-id",
            unit_id,
            "-hide-all-packages",
            "-no-auto-link-packages",
        ]
        for db in dep_info.pkg_dbs.to_list():
            dyn_link_args.extend(["-package-db", db.path])
        for uid in direct_unit_ids:
            dyn_link_args.extend(["-package-id", uid])
        dyn_link_args.extend(ghc_tool_flags(hs_tc, cc_tools))
        dyn_link_args.append("-optl-Wl,-Bsymbolic")
        dyn_link_args.append("-optl-L{}/{}".format(hs_tc.libdir.path, hs_tc.arch_libdir))
        if cc_archives:
            dyn_link_args.append("-optl-Wl,--whole-archive")
            for a in cc_archives:
                dyn_link_args.append("-optl" + a.path)
            dyn_link_args.append("-optl-Wl,--no-whole-archive")
            for sa in shim_archives:
                dyn_link_args.append("-optl" + sa.path)
        for lf in cc_link_flags:
            dyn_link_args.append("-optl" + lf)
        action_env["RULES_HS_DYN_LINK_ARGS"] = "\n".join(dyn_link_args)

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
EXPLICIT_REEXPORTED="${14}"
DEPENDS_STR="${15}"
HAS_TARGETS="${16}"
IS_DYNAMIC="${17}"
HAS_COMPILE_DATA="${18}"
PKG_ROOT="${19}"
shift 19

EXECROOT="$(pwd)"
case "${RULES_HS_REAL_CC:-}" in
    ""|/*) ;;
    *) export RULES_HS_REAL_CC="$EXECROOT/$RULES_HS_REAL_CC" ;;
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
    OBJ_LIST="$WORK_ROOT/objects.rsp"
    find "$ODIR" -name '*.o' | sort > "$OBJ_LIST"
    if [ -s "$OBJ_LIST" ]; then
        "$AR" rcs "$HS_LIB" "@$OBJ_LIST"
    else
        "$AR" rcs "$HS_LIB"
    fi
else
    "$AR" rcs "$HS_LIB"
fi

if [ "$IS_DYNAMIC" = "1" ]; then
    DYN_DIR="$PKG_DB/dyn"
    mkdir -p "$DYN_DIR"
    DYN_LIB="$DYN_DIR/libHS${UNIT_ID}-ghc${GHC_VER}.so"
    DYN_ARGV=()
    if [ -n "${RULES_HS_DYN_LINK_ARGS:-}" ]; then
        while IFS= read -r darg; do
            [ -z "$darg" ] && continue
            DYN_ARGV+=("$darg")
        done <<EOF_DYN
$RULES_HS_DYN_LINK_ARGS
EOF_DYN
    fi
    if [ "$HAS_TARGETS" = "1" ]; then
        while IFS= read -r dyn_obj; do
            [ -z "$dyn_obj" ] && continue
            DYN_ARGV+=("$dyn_obj")
        done < <(find "$ODIR" -name '*.dyn_o' | sort)
    fi
    DYN_ARGV+=("-o" "$DYN_LIB")
    "$GHC" "${DYN_ARGV[@]}"
fi

# Auto-discover exposed-modules from produced .hi files when not explicitly specified.
EXPOSED="$EXPLICIT_EXPOSED"
HIDDEN="$EXPLICIT_HIDDEN"
if [ -z "$EXPOSED" ] && [ "$HAS_TARGETS" = "1" ]; then
    DISCOVERED=""
    for hi in $(cd "$HI_DIR" && find . -name '*.hi' | sort); do
        mod="${hi#./}"
        mod="${mod%.hi}"
        mod="$(printf '%s' "$mod" | tr '/' '.')"
        case " $HIDDEN " in
            *" $mod "*) ;;
            *) DISCOVERED="$DISCOVERED $mod" ;;
        esac
    done
    EXPOSED="${DISCOVERED# }"
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
    if [ "$IS_DYNAMIC" = "1" ]; then
        printf 'dynamic-library-dirs: ${pkgroot}/%s/dyn\n' "$PKG_DB_BASE"
    fi
    printf 'hs-libraries: HS%s\n' "$UNIT_ID"
    if [ -n "$EXPOSED" ]; then
        printf 'exposed-modules: %s\n' "$EXPOSED"
    fi
    if [ -n "$HIDDEN" ]; then
        printf 'hidden-modules: %s\n' "$HIDDEN"
    fi
    if [ -n "$EXPLICIT_REEXPORTED" ]; then
        printf 'reexported-modules: %s\n' "$EXPLICIT_REEXPORTED"
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
            explicit_reexported,
            depends_str,
            has_hs_targets,
            is_dynamic,
            has_compile_data,
            pkg_root,
            ghc_args,
        ],
    )

    return pkg_db, pkg_db, hs_lib
