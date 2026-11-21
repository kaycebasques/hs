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
    cflags_list = ["-fPIC", "-I$EXECROOT/" + hs_tc.rts_include_dir]
    for d in extra_include_dirs:
        cflags_list.append("-I$EXECROOT/" + d)

    cmd = """\
set -euo pipefail
unset RUNFILES_DIR RUNFILES_MANIFEST_FILE RUNFILES_MANIFEST_ONLY
EXECROOT="$(pwd)"
WORK="$(mktemp -d "${{TMPDIR:-/tmp}}/hs_cfg.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

{stage_cmds}

export RULES_HS_REAL_CC="$EXECROOT/{real_cc}"
export RULES_HS_FORCE_PIC=1
{extra_cc_env}
export CC="$EXECROOT/{cc_wrapper}"
export CXX="$EXECROOT/{cc_wrapper}"
export AR="$EXECROOT/{ar}"
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
        real_cc = cc_tools.cc,
        extra_cc_env = 'export RULES_HS_CC_EXTRA_ARGS="{}"'.format("\\n".join(cc_tools.extra_cc_args)) if cc_tools.extra_cc_args else "",
        cc_wrapper = hs_tc.cc_wrapper.path,
        ar = cc_tools.ar,
        ld_export = 'export LD="$EXECROOT/{}"'.format(cc_tools.ld) if cc_tools.ld else "",
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
        command = cmd,
    )

    return declared_outputs, out_dir_roots, configure_root

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
        args.add("-I" + hs_tc.rts_include_dir)
        for d in include_dirs:
            args.add("-I" + d)
        if cabal_macros_h:
            args.add("--cflag=-include")
            args.add("--cflag=" + cabal_macros_h.path)
        args.add("--cflag=-fPIC")
        for opt in cpp_options:
            args.add("--cflag=" + opt)
        for opt in cc_options:
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

def _resolve_install_includes(install_includes, hdrs, configure_outputs, include_dirs):
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
                # Prefer exact suffix match against include_dirs or basename.
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
    all_inc_dirs = []
    for d in resolved_inc_dirs + list(configure_include_dirs) + [hs_tc.rts_include_dir]:
        if d and d not in all_inc_dirs:
            all_inc_dirs.append(d)

    public_hdrs = _resolve_install_includes(
        install_includes,
        hdrs,
        configure_outputs,
        all_inc_dirs,
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
        "-I" + hs_tc.rts_include_dir,
    ]
    if cabal_macros_h:
        user_flags.extend(["-include", cabal_macros_h.path])
    user_flags.extend(cc_options)

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
        dep_info):
    """Compiles Haskell modules into libHS<unit_id>.a + relocatable ${pkgroot} ghc-pkg DB."""
    pkg_db = ctx.actions.declare_directory(ctx.label.name + ".pkgdb")
    hs_lib = ctx.actions.declare_file("libHS" + unit_id + ".a")

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

    # Build -i search directories.
    resolved_src_dirs = [resolve_package_dir(ctx, d) for d in (hs_source_dirs or ["."])]
    all_import_dirs = []
    for d in resolved_src_dirs + list(extra_import_dirs):
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
    explicit_exposed = " ".join(exposed_modules)
    explicit_hidden = " ".join(list(other_modules) + list(hidden_modules))
    explicit_reexported = ", ".join(reexported_modules)
    depends_str = " ".join(direct_unit_ids)
    has_hs_targets = "1" if compile_targets else "0"

    extra_in = list(hs_srcs) + list(generated_hs_srcs)
    if cabal_macros_h:
        extra_in.append(cabal_macros_h)

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
        env = ghc_base_env(cc_tools),
        command = """\
set -euo pipefail
unset RUNFILES_DIR RUNFILES_MANIFEST_FILE RUNFILES_MANIFEST_ONLY

GHC="$1"
GHC_PKG="$2"
GHC_LIB="$3"
AR="$4"
PKG_DB="$5"
PKG_DB_BASE="$6"
HS_LIB="$7"
PKG_NAME="$8"
PKG_VER="$9"
UNIT_ID="${10}"
EXPLICIT_EXPOSED="${11}"
EXPLICIT_HIDDEN="${12}"
EXPLICIT_REEXPORTED="${13}"
DEPENDS_STR="${14}"
HAS_TARGETS="${15}"
shift 15

HI_DIR="$PKG_DB/hi"
mkdir -p "$HI_DIR" "$PKG_DB"
ODIR="$(mktemp -d "${TMPDIR:-/tmp}/hs_o.XXXXXX")"
trap 'rm -rf "$ODIR"' EXIT

if [ "$HAS_TARGETS" = "1" ]; then
    "$GHC" -odir "$ODIR" -stubdir "$ODIR" "$@"
    OBJ_LIST="$ODIR/objects.rsp"
    find "$ODIR" -name '*.o' | sort > "$OBJ_LIST"
    if [ -s "$OBJ_LIST" ]; then
        "$AR" rcs "$HS_LIB" "@$OBJ_LIST"
    else
        "$AR" rcs "$HS_LIB"
    fi
else
    "$AR" rcs "$HS_LIB"
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
CONF="$PKG_DB/${UNIT_ID}.conf"
{
    printf 'name: %s\n' "$PKG_NAME"
    printf 'version: %s\n' "$PKG_VER"
    printf 'id: %s\n' "$UNIT_ID"
    printf 'key: %s\n' "$UNIT_ID"
    printf 'exposed: True\n'
    printf 'import-dirs: ${pkgroot}/%s/hi\n' "$PKG_DB_BASE"
    printf 'library-dirs: ${pkgroot}\n'
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
            ghc_args,
        ],
    )

    return pkg_db, pkg_db, hs_lib
