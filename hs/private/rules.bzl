"""Core user-facing Haskell rules: hs_toolchain_library, hs_library, hs_binary, hs_test."""

load("@rules_cc//cc:find_cc_toolchain.bzl", "use_cc_toolchain")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("//hs:providers.bzl", "HsLinkInfo", "HsPackageInfo")
load("//hs:toolchain.bzl", "TOOLCHAIN_TYPE")
load(
    "//hs/private:actions.bzl",
    "HsDocSourceInfo",
    "collect_deps",
    "compile_c_sources",
    "compile_hs_library_action",
    "extract_cc_static_libs_and_flags",
    "get_hs_toolchain",
    "ghc_base_env",
    "ghc_tool_flags",
    "resolve_cc_tools",
    "resolve_package_dir",
)

def _sanitize_unit_id(label):
    """Generates a deterministic, GHC-valid unit ID for a Bazel target label."""
    parts = []
    if label.repo_name:
        parts.append(label.repo_name)
    if label.package:
        parts.append(label.package)
    parts.append(label.name)
    raw = "_".join(parts)
    out = []
    for i in range(len(raw)):
        ch = raw[i]
        if ch.isalnum() or ch == "_":
            out.append(ch)
        else:
            out.append("_")
    uid = "".join(out)
    return uid + "-0.0.0"

# ==============================================================================
# hs_toolchain_library
# ==============================================================================

def _hs_toolchain_library_impl(ctx):
    hs_tc = get_hs_toolchain(ctx)
    pkg_name = ctx.attr.package_name or ctx.label.name
    if pkg_name not in hs_tc.boot_packages:
        fail("Boot package '{}' not found in GHC {} global package DB. Available: {}".format(
            pkg_name,
            hs_tc.version,
            sorted(hs_tc.boot_packages.keys()),
        ))
    meta = hs_tc.boot_packages[pkg_name]
    return [
        DefaultInfo(),
        HsPackageInfo(
            name = meta["name"],
            version = meta["version"],
            unit_id = meta["id"],
            pkg_db = None,
            exposed_modules = meta.get("exposed_modules", []),
            is_boot = True,
            hs_lib = None,
            hi_dir = None,
        ),
        HsLinkInfo(
            pkg_dbs = depset(),
            hs_libs = depset(),
            include_dirs = depset(),
            headers = depset(),
            cc_info = CcInfo(),
        ),
    ]

hs_toolchain_library = rule(
    implementation = _hs_toolchain_library_impl,
    doc = "Exposes a GHC boot package from the active HsToolchainInfo as a Bazel dependency.",
    attrs = {
        "package_name": attr.string(
            default = "",
            doc = "Exact Cabal boot package name (defaults to target name).",
        ),
    },
    toolchains = [TOOLCHAIN_TYPE],
    provides = [HsPackageInfo, HsLinkInfo],
)

# ==============================================================================
# hs_library
# ==============================================================================

def _hs_library_impl(ctx):
    hs_tc = get_hs_toolchain(ctx)
    cc_tools = resolve_cc_tools(ctx)
    dep_info = collect_deps(ctx.attr.deps, ctx.attr.cc_deps)

    pkg_name = ctx.label.name.replace("_", "-")
    version = "0.0.0"
    unit_id = _sanitize_unit_id(ctx.label)

    # Compile any attached C sources and propagate C headers via CcInfo.
    merged_cc_info, pub_inc_dirs, pub_hdrs = compile_c_sources(
        ctx = ctx,
        hs_tc = hs_tc,
        cc_tools = cc_tools,
        c_sources = ctx.files.c_sources,
        hdrs = ctx.files.hdrs,
        install_includes = [f.basename for f in ctx.files.hdrs],
        include_dirs = ctx.attr.include_dirs,
        configure_outputs = [],
        configure_include_dirs = [],
        cabal_macros_h = None,
        cc_options = ctx.attr.cc_options,
        dep_cc_info = dep_info.cc_info,
    )

    hi_dir, pkg_db, hs_lib, doc_info = compile_hs_library_action(
        ctx = ctx,
        hs_tc = hs_tc,
        cc_tools = cc_tools,
        package_name = pkg_name,
        version = version,
        unit_id = unit_id,
        hs_srcs = ctx.files.srcs,
        generated_hs_srcs = [],
        hs_source_dirs = ctx.attr.hs_source_dirs,
        extra_import_dirs = [],
        exposed_modules = [],
        other_modules = [],
        hidden_modules = ctx.attr.hidden_modules,
        reexported_modules = [],
        default_language = ctx.attr.default_language,
        default_extensions = ctx.attr.default_extensions,
        ghc_opts = ctx.attr.ghc_opts,
        cpp_options = ctx.attr.cpp_options,
        cabal_macros_h = None,
        include_dirs = [resolve_package_dir(ctx, d) for d in ctx.attr.include_dirs],
        headers = depset(ctx.files.hdrs),
        dep_info = dep_info,
        cc_info = merged_cc_info,
        compile_data = ctx.files.data,
        rt_shims = extract_cc_static_libs_and_flags(ctx.attr._rt_shims[CcInfo])[0],
    )

    runfiles = ctx.runfiles(files = ctx.files.data).merge_all([
        dep[DefaultInfo].default_runfiles
        for dep in ctx.attr.deps + ctx.attr.cc_deps + ctx.attr.data
    ])

    return [
        DefaultInfo(
            files = depset([hs_lib, pkg_db, hi_dir]),
            runfiles = runfiles,
        ),
        HsPackageInfo(
            name = pkg_name,
            version = version,
            unit_id = unit_id,
            pkg_db = pkg_db,
            exposed_modules = [],
            is_boot = False,
            hs_lib = hs_lib,
            hi_dir = hi_dir,
        ),
        HsLinkInfo(
            pkg_dbs = depset([pkg_db], transitive = [dep_info.pkg_dbs]),
            hs_libs = depset([hs_lib], transitive = [dep_info.hs_libs]),
            include_dirs = depset(pub_inc_dirs, transitive = [dep_info.include_dirs]),
            headers = depset(transitive = [pub_hdrs, dep_info.headers]),
            cc_info = merged_cc_info,
        ),
        merged_cc_info,
        doc_info,
    ]

hs_library = rule(
    implementation = _hs_library_impl,
    doc = "Compiles a Haskell library with strict direct-dependency visibility.",
    attrs = {
        "srcs": attr.label_list(
            allow_files = [".hs", ".lhs", ".hs-boot", ".lhs-boot"],
            mandatory = True,
        ),
        "deps": attr.label_list(
            providers = [[HsPackageInfo], [CcInfo]],
            default = [],
        ),
        "cc_deps": attr.label_list(
            providers = [CcInfo],
            default = [],
        ),
        "c_sources": attr.label_list(
            allow_files = [".c", ".cc", ".cpp", ".S", ".s"],
            default = [],
        ),
        "hdrs": attr.label_list(
            allow_files = True,
            default = [],
        ),
        "include_dirs": attr.string_list(default = []),
        "hs_source_dirs": attr.string_list(default = []),
        "hidden_modules": attr.string_list(default = []),
        "default_language": attr.string(default = "GHC2021"),
        "default_extensions": attr.string_list(default = []),
        "ghc_opts": attr.string_list(default = []),
        "cpp_options": attr.string_list(default = []),
        "cc_options": attr.string_list(default = []),
        "data": attr.label_list(allow_files = True, default = []),
        "_rt_shims": attr.label(
            default = Label("//hs/private:rt_shims"),
            providers = [CcInfo],
        ),
    },
    toolchains = [TOOLCHAIN_TYPE] + use_cc_toolchain(),
    fragments = ["cpp"],
    provides = [HsPackageInfo, HsLinkInfo, CcInfo, HsDocSourceInfo],
)

# ==============================================================================
# hs_binary & hs_test
# ==============================================================================

def _hs_executable_impl(ctx):
    hs_tc = get_hs_toolchain(ctx)
    cc_tools = resolve_cc_tools(ctx)
    dep_info = collect_deps(ctx.attr.deps, ctx.attr.cc_deps)

    # Compile any C sources attached directly to the executable target.
    merged_cc_info, _, _ = compile_c_sources(
        ctx = ctx,
        hs_tc = hs_tc,
        cc_tools = cc_tools,
        c_sources = ctx.files.c_sources,
        hdrs = ctx.files.hdrs,
        install_includes = [f.basename for f in ctx.files.hdrs],
        include_dirs = ctx.attr.include_dirs,
        configure_outputs = [],
        configure_include_dirs = [],
        cabal_macros_h = None,
        cc_options = ctx.attr.cc_options,
        dep_cc_info = dep_info.cc_info,
    )

    cc_archives, cc_link_flags = extract_cc_static_libs_and_flags(merged_cc_info)
    if cc_archives:
        cc_archives = list(cc_archives) + extract_cc_static_libs_and_flags(ctx.attr._rt_shims[CcInfo])[0]

    out_exe = ctx.actions.declare_file(ctx.label.name)

    compile_src_files = [
        f
        for f in ctx.files.srcs
        if not (f.path.endswith(".hs-boot") or f.path.endswith(".lhs-boot"))
    ]

    resolved_src_dirs = [resolve_package_dir(ctx, d) for d in (ctx.attr.hs_source_dirs or ["."])]
    all_c_inc_dirs = []
    for d in [resolve_package_dir(ctx, x) for x in ctx.attr.include_dirs] + dep_info.include_dirs.to_list() + [hs_tc.rts_include_dir]:
        if d and d not in all_c_inc_dirs:
            all_c_inc_dirs.append(d)

    ghc_args = ctx.actions.args()
    ghc_args.add("--make")
    ghc_args.add("-fPIC")
    ghc_args.add("-hide-all-packages")

    if ctx.attr.threaded:
        ghc_args.add("-threaded")

    if ctx.attr.main_module:
        ghc_args.add("-main-is", ctx.attr.main_module)

    for db in dep_info.pkg_dbs.to_list():
        ghc_args.add("-package-db", db.path)

    seen_uid = {}
    for pkg in dep_info.direct_pkgs:
        if pkg.unit_id and pkg.unit_id not in seen_uid:
            seen_uid[pkg.unit_id] = True
            ghc_args.add("-package-id", pkg.unit_id)

    if ctx.attr.default_language:
        ghc_args.add("-X" + ctx.attr.default_language)
    for ext in ctx.attr.default_extensions:
        ghc_args.add("-X" + ext)

    ghc_args.add("-i")
    for d in resolved_src_dirs:
        ghc_args.add("-i" + d)

    for d in all_c_inc_dirs:
        ghc_args.add("-I" + d)

    for opt in ctx.attr.cpp_options:
        ghc_args.add("-optP" + opt)

    for flag in ghc_tool_flags(hs_tc, cc_tools):
        ghc_args.add(flag)

    # Link statically against non-PIC GHC boot archives cleanly on lld/clang/zig.
    ghc_args.add("-optl-no-pie")

    # Guarantee 100% static libgmp.a linking (zero libgmp.so.10 runtime dependency!).
    if hs_tc.gmp_static_dir:
        ghc_args.add("-optl-L" + hs_tc.gmp_static_dir)

    # Pass all transitive native C archives (from c_sources & cc_deps) AFTER -lHS*
    # via -optl inside --start-group/--end-group so symbol order is always satisfied.
    if cc_archives:
        ghc_args.add("-optl-Wl,--start-group")
        for a in cc_archives:
            ghc_args.add("-optl" + a.path)
        ghc_args.add("-optl-Wl,--end-group")

    for lf in cc_link_flags:
        ghc_args.add("-optl" + lf)

    for opt in ctx.attr.ghc_opts:
        ghc_args.add(opt)

    ghc_args.add("-o", out_exe.path)
    for f in compile_src_files:
        ghc_args.add(f.path)

    extra_in = list(ctx.files.srcs) + list(ctx.files.hdrs) + list(cc_archives) + list(ctx.files.data)
    if hs_tc.gmp_static_lib:
        extra_in.append(hs_tc.gmp_static_lib)

    ctx.actions.run_shell(
        mnemonic = "HsLinkExecutable",
        progress_message = "Compiling & linking Haskell executable {}".format(ctx.label),
        inputs = depset(
            extra_in,
            transitive = [
                hs_tc.all_files,
                dep_info.pkg_dbs,
                dep_info.hs_libs,
                dep_info.headers,
                cc_tools.all_files,
            ],
        ),
        tools = [hs_tc.ghc, hs_tc.cc_wrapper],
        outputs = [out_exe],
        env = ghc_base_env(cc_tools),
        command = """\
set -euo pipefail
unset RUNFILES_DIR RUNFILES_MANIFEST_FILE RUNFILES_MANIFEST_ONLY
GHC="$1"
shift
WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/hs_bin.XXXXXX")"
trap 'rm -rf "$WORK_ROOT"' EXIT
WORKDIR="$WORK_ROOT/objs"
export TMPDIR="$WORK_ROOT/tmp"
mkdir -p "$WORKDIR" "$TMPDIR"
"$GHC" -outputdir "$WORKDIR" "$@"
""",
        arguments = [hs_tc.ghc.path, ghc_args],
    )

    runfiles = ctx.runfiles(files = ctx.files.data).merge_all([
        dep[DefaultInfo].default_runfiles
        for dep in ctx.attr.deps + ctx.attr.cc_deps + ctx.attr.data
    ])

    return [
        DefaultInfo(
            executable = out_exe,
            files = depset([out_exe]),
            runfiles = runfiles,
        ),
    ]

_EXECUTABLE_ATTRS = {
    "srcs": attr.label_list(
        allow_files = [".hs", ".lhs", ".hs-boot", ".lhs-boot"],
        mandatory = True,
    ),
    "deps": attr.label_list(
        providers = [[HsPackageInfo], [CcInfo]],
        default = [],
    ),
    "cc_deps": attr.label_list(
        providers = [CcInfo],
        default = [],
    ),
    "c_sources": attr.label_list(
        allow_files = [".c", ".cc", ".cpp", ".S", ".s"],
        default = [],
    ),
    "hdrs": attr.label_list(
        allow_files = True,
        default = [],
    ),
    "include_dirs": attr.string_list(default = []),
    "hs_source_dirs": attr.string_list(default = []),
    "main_module": attr.string(default = "Main"),
    "default_language": attr.string(default = "GHC2021"),
    "default_extensions": attr.string_list(default = []),
    "threaded": attr.bool(default = True),
    "ghc_opts": attr.string_list(default = []),
    "cpp_options": attr.string_list(default = []),
    "cc_options": attr.string_list(default = []),
    "data": attr.label_list(allow_files = True, default = []),
    "_rt_shims": attr.label(
        default = Label("//hs/private:rt_shims"),
        providers = [CcInfo],
    ),
}

hs_binary = rule(
    implementation = _hs_executable_impl,
    doc = "Compiles and links a hermetic Haskell executable (statically linked against GMP).",
    attrs = _EXECUTABLE_ATTRS,
    executable = True,
    toolchains = [TOOLCHAIN_TYPE] + use_cc_toolchain(),
    fragments = ["cpp"],
)

hs_test = rule(
    implementation = _hs_executable_impl,
    doc = "Compiles and runs a hermetic Haskell test executable.",
    attrs = _EXECUTABLE_ATTRS,
    test = True,
    toolchains = [TOOLCHAIN_TYPE] + use_cc_toolchain(),
    fragments = ["cpp"],
)
