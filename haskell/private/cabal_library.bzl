"""Fine-grained Cabal package builder rule (`hs_cabal_library`) — zero Setup.hs."""

load("@rules_cc//cc:find_cc_toolchain.bzl", "use_cc_toolchain")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("//haskell:providers.bzl", "HsLinkInfo", "HsPackageInfo")
load("//haskell:toolchain.bzl", "TOOLCHAIN_TYPE")
load(
    "//haskell/private:actions.bzl",
    "HsDocSourceInfo",
    "collect_deps",
    "compile_c_sources",
    "compile_hs_library_action",
    "extract_cc_static_libs_and_flags",
    "get_hs_toolchain",
    "resolve_cc_tools",
    "resolve_package_dir",
    "run_configure_action",
    "run_hsc2hs_actions",
    "write_cabal_macros_h",
    "write_paths_module",
)

def resolve_override_labels(raw_labels):
    """Converts canonical label strings (e.g. '@@zlib+//:zlib') from hackage.override into Labels."""
    return [Label(s) for s in raw_labels]

def _cabal_unit_id(package_name, component_name, version):
    if component_name:
        return "{}-{}-{}".format(package_name, version, component_name)
    return "{}-{}".format(package_name, version)

def _hs_cabal_library_impl(ctx):
    hs_tc = get_hs_toolchain(ctx)
    cc_tools = resolve_cc_tools(ctx)
    dep_info = collect_deps(ctx.attr.deps, ctx.attr.extra_cc_deps)

    pkg_name = ctx.attr.package_name
    comp_name = ctx.attr.component_name
    version = ctx.attr.version
    unit_id = _cabal_unit_id(pkg_name, comp_name, version)

    if ctx.attr.build_type not in ("Simple", "Configure"):
        fail("Unsupported Cabal build-type '{}' for package '{}' (only 'Simple' and 'Configure' are supported)".format(
            ctx.attr.build_type,
            pkg_name,
        ))

    has_haskell = bool(
        ctx.files.srcs or
        ctx.files.hsc_srcs or
        any([f.path.endswith(".cmm") for f in ctx.files.c_sources]) or
        ctx.attr.generate_paths_module or
        ctx.attr.reexported_modules or
        ctx.attr.exposed_modules or
        ctx.attr.other_modules,
    )

    # ------------------------------------------------------------------
    # Stage 1: Autoconf ./configure (only for build-type: Configure)
    # ------------------------------------------------------------------
    configure_outputs = []
    configure_inc_dirs = []
    configure_root = None
    if ctx.attr.build_type == "Configure" and ctx.file.configure_script and ctx.attr.configure_outputs:
        configure_outputs, configure_inc_dirs, configure_root = run_configure_action(
            ctx = ctx,
            hs_tc = hs_tc,
            cc_tools = cc_tools,
            configure_script = ctx.file.configure_script,
            configure_srcs = ctx.files.configure_srcs,
            configure_outputs = ctx.attr.configure_outputs,
            configure_args = ctx.attr.configure_args,
            extra_include_dirs = [resolve_package_dir(ctx, d) for d in ctx.attr.include_dirs] + dep_info.include_dirs.to_list(),
            extra_headers = depset(ctx.files.hdrs, transitive = [dep_info.headers]),
        )

        # Also add <configure_root>/<inc_dir> for any package include_dirs (e.g. include/HsNetworkConfig.h).
        if configure_root:
            for d in ctx.attr.include_dirs:
                clean_d = d.strip("/")
                if clean_d and clean_d != ".":
                    cand = configure_root + "/" + clean_d
                    if cand not in configure_inc_dirs:
                        configure_inc_dirs.append(cand)

    # ------------------------------------------------------------------
    # Stage 2: Codegen (cabal_macros.h + optional Paths_<pkg>.hs)
    # ------------------------------------------------------------------
    cabal_macros_h = ctx.actions.declare_file(ctx.label.name + "_autogen/cabal_macros.h")
    write_cabal_macros_h(
        ctx = ctx,
        out_file = cabal_macros_h,
        package_name = pkg_name,
        version = version,
        unit_id = unit_id,
        hs_tc = hs_tc,
        direct_pkgs = dep_info.direct_pkgs,
    )

    generated_hs = []
    extra_import_dirs = []
    other_modules = list(ctx.attr.other_modules)
    if ctx.attr.generate_paths_module:
        paths_mod_name = "Paths_" + pkg_name.replace("-", "_")
        paths_hs = ctx.actions.declare_file(ctx.label.name + "_autogen/" + paths_mod_name + ".hs")
        write_paths_module(ctx, paths_hs, pkg_name, version)
        generated_hs.append(paths_hs)
        extra_import_dirs.append(paths_hs.dirname)
        if paths_mod_name not in other_modules and paths_mod_name not in ctx.attr.exposed_modules:
            other_modules.append(paths_mod_name)

    # ------------------------------------------------------------------
    # Stage 3: Per-file hsc2hs actions
    # ------------------------------------------------------------------
    local_inc_dirs = [resolve_package_dir(ctx, d) for d in ctx.attr.include_dirs]
    hsc_inc_dirs = []
    for d in local_inc_dirs + configure_inc_dirs + dep_info.include_dirs.to_list():
        if d and d not in hsc_inc_dirs:
            hsc_inc_dirs.append(d)

    hsc_headers = depset(
        ctx.files.hdrs + configure_outputs,
        transitive = [dep_info.headers],
    )

    if ctx.files.hsc_srcs:
        hsc_gen_files, hsc_root = run_hsc2hs_actions(
            ctx = ctx,
            hs_tc = hs_tc,
            cc_tools = cc_tools,
            hsc_srcs = ctx.files.hsc_srcs,
            hs_source_dirs = ctx.attr.hs_source_dirs,
            include_dirs = hsc_inc_dirs,
            headers = hsc_headers,
            cabal_macros_h = cabal_macros_h,
            cpp_options = ctx.attr.cpp_options,
            cc_options = ctx.attr.cc_options,
        )
        generated_hs.extend(hsc_gen_files)
        if hsc_root:
            extra_import_dirs.append(hsc_root)

    # ------------------------------------------------------------------
    # Stage 4: Native C compilation via cc_common & install-includes propagation
    # ------------------------------------------------------------------
    merged_cc_info, pub_inc_dirs, pub_hdrs = compile_c_sources(
        ctx = ctx,
        hs_tc = hs_tc,
        cc_tools = cc_tools,
        c_sources = ctx.files.c_sources,
        hdrs = ctx.files.hdrs,
        install_includes = ctx.attr.install_includes,
        include_dirs = ctx.attr.include_dirs,
        configure_outputs = configure_outputs,
        configure_include_dirs = configure_inc_dirs,
        cabal_macros_h = cabal_macros_h,
        cc_options = ctx.attr.cc_options,
        dep_cc_info = dep_info.cc_info,
        extra_libraries = ctx.attr.extra_libraries,
    )

    runfiles = ctx.runfiles(files = ctx.files.data).merge_all([
        dep[DefaultInfo].default_runfiles
        for dep in ctx.attr.deps + ctx.attr.extra_cc_deps + ctx.attr.data
    ])

    # C-only Cabal packages (e.g. zlib-clib): skip GHC compile/archive/ghc-pkg cleanly!
    if not has_haskell:
        return [
            DefaultInfo(
                files = depset(configure_outputs, transitive = [pub_hdrs]),
                runfiles = runfiles,
            ),
            HsPackageInfo(
                name = pkg_name,
                version = version,
                unit_id = None,
                pkg_db = None,
                exposed_modules = [],
                is_boot = False,
                hs_lib = None,
                hi_dir = None,
            ),
            HsLinkInfo(
                pkg_dbs = dep_info.pkg_dbs,
                hs_libs = dep_info.hs_libs,
                include_dirs = depset(pub_inc_dirs, transitive = [dep_info.include_dirs]),
                headers = depset(transitive = [pub_hdrs, dep_info.headers]),
                cc_info = merged_cc_info,
            ),
            merged_cc_info,
            HsDocSourceInfo(
                package_name = pkg_name,
                version = version,
                unit_id = None,
                pkg_db = None,
                all_hs_srcs = [],
                doc_src_files = [],
                import_dirs = [],
                c_include_dirs = [],
                headers = depset(),
                cabal_macros_h = None,
                hidden_modules = [],
                default_language = ctx.attr.default_language,
                default_extensions = [],
                ghc_opts = [],
                cpp_options = [],
                cc_options = [],
                direct_unit_ids = [],
                compile_data = [],
                pkg_root = ".",
                boot_pkg_names = dep_info.boot_pkg_names,
            ),
        ]

    # ------------------------------------------------------------------
    # Stage 5: Haskell compile + archive + relocatable ghc-pkg DB
    # ------------------------------------------------------------------
    # Include all local/configure headers for CApiFFI & CPP #includes during GHC compile.
    ghc_inc_dirs = []
    for d in local_inc_dirs + configure_inc_dirs:
        if d and d not in ghc_inc_dirs:
            ghc_inc_dirs.append(d)

    hi_dir, pkg_db, hs_lib, doc_info = compile_hs_library_action(
        ctx = ctx,
        hs_tc = hs_tc,
        cc_tools = cc_tools,
        package_name = pkg_name,
        version = version,
        unit_id = unit_id,
        hs_srcs = ctx.files.srcs,
        generated_hs_srcs = generated_hs,
        cmm_srcs = [f for f in ctx.files.c_sources if f.path.endswith(".cmm")],
        hs_source_dirs = ctx.attr.hs_source_dirs or ["."],
        extra_import_dirs = extra_import_dirs,
        exposed_modules = ctx.attr.exposed_modules,
        other_modules = other_modules,
        hidden_modules = [],
        reexported_modules = ctx.attr.reexported_modules,
        default_language = ctx.attr.default_language,
        default_extensions = ctx.attr.default_extensions,
        ghc_opts = ctx.attr.ghc_opts,
        cpp_options = ctx.attr.cpp_options,
        cc_options = ctx.attr.cc_options,
        cabal_macros_h = cabal_macros_h,
        include_dirs = ghc_inc_dirs,
        headers = depset(ctx.files.hdrs + configure_outputs),
        dep_info = dep_info,
        cc_info = merged_cc_info,
        compile_data = ctx.files.data,
        rt_shims = extract_cc_static_libs_and_flags(ctx.attr._rt_shims[CcInfo])[0],
    )

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
            exposed_modules = list(ctx.attr.exposed_modules) + [
                (r.split(" as ", 1)[1].strip() if " as " in r else r.split(":", 1)[-1].strip())
                for r in ctx.attr.reexported_modules
            ],
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

hs_cabal_library = rule(
    implementation = _hs_cabal_library_impl,
    doc = "Builds a Cabal/Hackage Haskell (or C-only) library with fine-grained Bazel actions.",
    attrs = {
        "package_name": attr.string(mandatory = True),
        "component_name": attr.string(default = ""),
        "version": attr.string(mandatory = True),
        "srcs": attr.label_list(
            allow_files = [".hs", ".lhs", ".hs-boot", ".lhs-boot"],
            default = [],
        ),
        "hsc_srcs": attr.label_list(
            allow_files = [".hsc"],
            default = [],
        ),
        "c_sources": attr.label_list(
            allow_files = [".c", ".cc", ".cpp", ".S", ".s", ".cmm"],
            default = [],
        ),
        "hdrs": attr.label_list(
            allow_files = True,
            default = [],
        ),
        "install_includes": attr.string_list(default = []),
        "include_dirs": attr.string_list(default = []),
        "hs_source_dirs": attr.string_list(default = []),
        "exposed_modules": attr.string_list(default = []),
        "other_modules": attr.string_list(default = []),
        "reexported_modules": attr.string_list(default = []),
        "default_language": attr.string(default = "Haskell98"),
        "default_extensions": attr.string_list(default = []),
        "ghc_opts": attr.string_list(default = []),
        "cpp_options": attr.string_list(default = []),
        "cc_options": attr.string_list(default = []),
        "extra_libraries": attr.string_list(default = []),
        "build_type": attr.string(default = "Simple"),
        "configure_script": attr.label(allow_single_file = True),
        "configure_srcs": attr.label_list(allow_files = True, default = []),
        "configure_outputs": attr.string_list(default = []),
        "configure_args": attr.string_list(default = []),
        "generate_paths_module": attr.bool(default = False),
        "deps": attr.label_list(
            providers = [[HsPackageInfo], [CcInfo]],
            default = [],
        ),
        "extra_cc_deps": attr.label_list(
            providers = [CcInfo],
            default = [],
        ),
        "data": attr.label_list(allow_files = True, default = []),
        "_rt_shims": attr.label(
            default = Label("//haskell/private:rt_shims"),
            providers = [CcInfo],
        ),
    },
    toolchains = [TOOLCHAIN_TYPE] + use_cc_toolchain(),
    fragments = ["cpp"],
    provides = [HsPackageInfo, HsLinkInfo, CcInfo, HsDocSourceInfo],
)
