"""Starlark analysis & provider unit tests for rules_haskell."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("//haskell:providers.bzl", "HsHaddockInfo", "HsLinkInfo", "HsPackageInfo", "HsReplInfo", "HsToolchainInfo")
load("//haskell:toolchain.bzl", "TOOLCHAIN_TYPE")

# ==============================================================================
# Helpers
# ==============================================================================

def _find_actions_by_mnemonic(actions, mnemonic):
    return [a for a in actions if a.mnemonic == mnemonic]

def _get_flag_values(argv, flag):
    """Extracts all values immediately following `flag` in an argv list."""
    values = []
    for i in range(len(argv) - 1):
        if argv[i] == flag:
            values.append(argv[i + 1])
    return values

def _extract_static_archives(cc_info):
    archives = []
    for li in cc_info.linking_context.linker_inputs.to_list():
        for lib in li.libraries:
            a = lib.pic_static_library or lib.static_library
            if a and a not in archives:
                archives.append(a)
    return archives

# ==============================================================================
# 1. hs_toolchain_library provider checks
# ==============================================================================

def _toolchain_library_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)

    asserts.true(env, HsPackageInfo in target, "hs_toolchain_library must provide HsPackageInfo")
    asserts.true(env, HsLinkInfo in target, "hs_toolchain_library must provide HsLinkInfo")

    pkg = target[HsPackageInfo]
    link = target[HsLinkInfo]

    expected_name = ctx.attr.expected_name
    expected_module = ctx.attr.expected_module

    asserts.true(env, pkg.is_boot, "boot package must have is_boot = True")
    asserts.equals(env, expected_name, pkg.name)
    asserts.true(env, bool(pkg.version), "boot package version must be non-empty")
    asserts.true(
        env,
        bool(pkg.unit_id) and pkg.unit_id.startswith(expected_name + "-"),
        "boot package unit_id '{}' must start with '{}-'".format(pkg.unit_id, expected_name),
    )
    asserts.equals(env, None, pkg.pkg_db)
    asserts.equals(env, None, pkg.hs_lib)
    asserts.equals(env, None, pkg.hi_dir)
    asserts.true(
        env,
        expected_module in pkg.exposed_modules,
        "expected module '{}' in boot package exposed_modules".format(expected_module),
    )

    asserts.equals(env, [], link.pkg_dbs.to_list())
    asserts.equals(env, [], link.hs_libs.to_list())
    asserts.equals(env, [], link.include_dirs.to_list())
    asserts.equals(env, [], link.headers.to_list())
    asserts.true(env, link.cc_info != None, "HsLinkInfo.cc_info must be non-None")

    return analysistest.end(env)

toolchain_library_test = analysistest.make(
    _toolchain_library_test_impl,
    attrs = {
        "expected_name": attr.string(mandatory = True),
        "expected_module": attr.string(mandatory = True),
    },
)

# ==============================================================================
# 2. hs_library provider & transitive depset propagation checks
# ==============================================================================

def _hs_library_providers_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)

    asserts.true(env, HsPackageInfo in target, "hs_library must provide HsPackageInfo")
    asserts.true(env, HsLinkInfo in target, "hs_library must provide HsLinkInfo")
    asserts.true(env, CcInfo in target, "hs_library must provide CcInfo")

    pkg = target[HsPackageInfo]
    link = target[HsLinkInfo]

    asserts.false(env, pkg.is_boot, "hs_library must have is_boot = False")
    asserts.equals(env, "lib-c", pkg.name)
    asserts.equals(env, "0.0.0", pkg.version)
    asserts.true(env, bool(pkg.unit_id) and pkg.unit_id.endswith("-0.0.0"), "unexpected unit_id: " + str(pkg.unit_id))
    asserts.true(env, pkg.pkg_db != None, "hs_library must produce pkg_db")
    asserts.true(env, pkg.pkg_db.basename.endswith(".pkgdb"), "pkg_db basename must end with .pkgdb")
    asserts.true(env, pkg.hs_lib != None, "hs_library must produce hs_lib")
    asserts.equals(env, "libHS" + pkg.unit_id + ".a", pkg.hs_lib.basename)
    asserts.true(env, pkg.hi_dir != None, "hs_library must produce hi_dir")
    asserts.equals(env, "list", type(pkg.exposed_modules))

    lib_a_pkg = ctx.attr.lib_a[HsPackageInfo]
    lib_b_pkg = ctx.attr.lib_b[HsPackageInfo]

    pkg_dbs = link.pkg_dbs.to_list()
    hs_libs = link.hs_libs.to_list()

    asserts.true(env, pkg.pkg_db in pkg_dbs, "own pkg_db must be in HsLinkInfo.pkg_dbs")
    asserts.true(env, lib_b_pkg.pkg_db in pkg_dbs, "direct dep pkg_db must be in HsLinkInfo.pkg_dbs")
    asserts.true(env, lib_a_pkg.pkg_db in pkg_dbs, "transitive dep pkg_db must be in HsLinkInfo.pkg_dbs")

    asserts.true(env, pkg.hs_lib in hs_libs, "own hs_lib must be in HsLinkInfo.hs_libs")
    asserts.true(env, lib_b_pkg.hs_lib in hs_libs, "direct dep hs_lib must be in HsLinkInfo.hs_libs")
    asserts.true(env, lib_a_pkg.hs_lib in hs_libs, "transitive dep hs_lib must be in HsLinkInfo.hs_libs")

    return analysistest.end(env)

hs_library_providers_test = analysistest.make(
    _hs_library_providers_test_impl,
    attrs = {
        "lib_a": attr.label(mandatory = True, providers = [HsPackageInfo]),
        "lib_b": attr.label(mandatory = True, providers = [HsPackageInfo]),
    },
)

# ==============================================================================
# 3. Strict direct-dependency visibility in GHC compile actions
# ==============================================================================

def _strict_direct_dep_visibility_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    actions = analysistest.target_actions(env)

    compile_actions = _find_actions_by_mnemonic(actions, "HsCompileLibrary")
    asserts.equals(env, 1, len(compile_actions), "expected exactly one HsCompileLibrary action")
    argv = compile_actions[0].argv

    pkg_c = target[HsPackageInfo]
    pkg_b = ctx.attr.direct_dep[HsPackageInfo]
    pkg_a = ctx.attr.transitive_dep[HsPackageInfo]
    pkg_base = ctx.attr.base_dep[HsPackageInfo]

    # Must pass -hide-all-packages, -fPIC, and -dynamic-too (for cross-library TH).
    asserts.true(env, "-hide-all-packages" in argv, "-hide-all-packages must be passed to GHC")
    asserts.true(env, "-fPIC" in argv, "-fPIC must be passed to GHC")
    asserts.true(env, "-dynamic-too" in argv, "-dynamic-too must be passed to GHC on dynamic toolchains")
    this_unit_ids = _get_flag_values(argv, "-this-unit-id")
    asserts.equals(env, [pkg_c.unit_id], this_unit_ids)

    # Strict direct-dep check: direct deps (lib_b, base) MUST have -package-id;
    # transitive-only dep (lib_a) MUST NOT have -package-id.
    package_ids = _get_flag_values(argv, "-package-id")
    asserts.true(
        env,
        pkg_b.unit_id in package_ids,
        "direct dep lib_b unit_id '{}' must be exposed via -package-id (got {})".format(pkg_b.unit_id, package_ids),
    )
    asserts.true(
        env,
        pkg_base.unit_id in package_ids,
        "direct dep base unit_id '{}' must be exposed via -package-id (got {})".format(pkg_base.unit_id, package_ids),
    )
    asserts.false(
        env,
        pkg_a.unit_id in package_ids,
        "transitive dep lib_a unit_id '{}' MUST NOT be exposed via -package-id (got {})".format(pkg_a.unit_id, package_ids),
    )

    # Transitive package-dbs MUST still be passed so GHC can load transitive .hi files.
    package_dbs = _get_flag_values(argv, "-package-db")
    asserts.true(
        env,
        pkg_b.pkg_db.path in package_dbs,
        "direct dep lib_b pkg_db must be passed via -package-db",
    )
    asserts.true(
        env,
        pkg_a.pkg_db.path in package_dbs,
        "transitive dep lib_a pkg_db must be passed via -package-db for transitive interface resolution",
    )

    return analysistest.end(env)

strict_direct_dep_visibility_test = analysistest.make(
    _strict_direct_dep_visibility_test_impl,
    attrs = {
        "direct_dep": attr.label(mandatory = True, providers = [HsPackageInfo]),
        "transitive_dep": attr.label(mandatory = True, providers = [HsPackageInfo]),
        "base_dep": attr.label(mandatory = True, providers = [HsPackageInfo]),
    },
)

# ==============================================================================
# 4. hs_binary static GMP & threaded flag checks
# ==============================================================================

def _hs_binary_action_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    actions = analysistest.target_actions(env)

    asserts.true(
        env,
        target[DefaultInfo].files_to_run.executable != None,
        "hs_binary must declare an executable",
    )

    link_actions = _find_actions_by_mnemonic(actions, "HsLinkExecutable")
    asserts.equals(env, 1, len(link_actions), "expected exactly one HsLinkExecutable action")
    action = link_actions[0]
    argv = action.argv
    inputs = action.inputs.to_list()

    # Static libgmp.a must be an action input and its directory passed via -optl-L<dir>.
    gmp_libs = [f for f in inputs if f.basename == "libgmp.a"]
    asserts.true(
        env,
        len(gmp_libs) >= 1,
        "HsLinkExecutable must include static libgmp.a in action inputs",
    )
    gmp_lib = gmp_libs[0]
    expected_gmp_flag = "-optl-L" + gmp_lib.dirname
    asserts.true(
        env,
        expected_gmp_flag in argv,
        "expected static GMP search dir flag '{}' in argv".format(expected_gmp_flag),
    )

    asserts.true(env, "-hide-all-packages" in argv, "hs_binary must pass -hide-all-packages")
    asserts.true(env, "-optl-no-pie" in argv, "hs_binary must pass -optl-no-pie")

    if ctx.attr.expect_threaded:
        asserts.true(env, "-threaded" in argv, "threaded = True must pass -threaded to GHC")
        asserts.true(env, "-optc-DBIN_C_OPT=1" in argv, "cc_options must be forwarded via -optc to hs_binary GHC action")
    else:
        asserts.false(env, "-threaded" in argv, "threaded = False must NOT pass -threaded to GHC")

    if ctx.attr.direct_dep != None and ctx.attr.transitive_dep != None:
        direct_pkg = ctx.attr.direct_dep[HsPackageInfo]
        trans_pkg = ctx.attr.transitive_dep[HsPackageInfo]
        package_ids = _get_flag_values(argv, "-package-id")
        package_dbs = _get_flag_values(argv, "-package-db")
        asserts.true(
            env,
            direct_pkg.unit_id in package_ids,
            "hs_binary direct dep '{}' must be passed via -package-id".format(direct_pkg.unit_id),
        )
        asserts.false(
            env,
            trans_pkg.unit_id in package_ids,
            "hs_binary transitive dep '{}' must NOT be passed via -package-id".format(trans_pkg.unit_id),
        )
        asserts.true(
            env,
            trans_pkg.pkg_db.path in package_dbs,
            "hs_binary transitive dep pkg_db must be passed via -package-db",
        )

    return analysistest.end(env)

hs_binary_action_test = analysistest.make(
    _hs_binary_action_test_impl,
    attrs = {
        "expect_threaded": attr.bool(mandatory = True),
        "direct_dep": attr.label(providers = [HsPackageInfo]),
        "transitive_dep": attr.label(providers = [HsPackageInfo]),
    },
)

# ==============================================================================
# 5. hs_cabal_library cabal_macros.h, Paths_<pkg>, and default_language checks
# ==============================================================================

def _hs_cabal_library_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    actions = analysistest.target_actions(env)

    pkg = target[HsPackageInfo]
    asserts.false(env, pkg.is_boot, "hs_cabal_library must have is_boot = False")
    asserts.equals(env, ctx.attr.expected_pkg_name, pkg.name)
    asserts.equals(env, ctx.attr.expected_version, pkg.version)
    asserts.equals(
        env,
        "{}-{}".format(ctx.attr.expected_pkg_name, ctx.attr.expected_version),
        pkg.unit_id,
    )
    asserts.equals(env, ["SampleCabal"], pkg.exposed_modules)

    # Locate generated cabal_macros.h FileWrite action and inspect its content.
    macro_actions = [
        a
        for a in actions
        if a.mnemonic == "FileWrite" and any([o.basename == "cabal_macros.h" for o in a.outputs.to_list()])
    ]
    asserts.equals(env, 1, len(macro_actions), "expected exactly one cabal_macros.h FileWrite action")
    macro_action = macro_actions[0]
    macro_file = macro_action.outputs.to_list()[0]
    content = macro_action.content

    asserts.true(
        env,
        '#define CURRENT_PACKAGE_VERSION "{}"'.format(ctx.attr.expected_version) in content,
        "cabal_macros.h must define CURRENT_PACKAGE_VERSION",
    )
    asserts.true(
        env,
        '#define VERSION_base "' in content,
        "cabal_macros.h must define VERSION_base",
    )
    asserts.true(
        env,
        "#define MIN_VERSION_base(major1,major2,minor)" in content,
        "cabal_macros.h must define MIN_VERSION_base",
    )
    asserts.true(
        env,
        '#define VERSION_lib_a "0.0.0"' in content,
        "cabal_macros.h must define VERSION_lib_a for direct hs_library dep",
    )
    asserts.true(
        env,
        "#define MIN_VERSION_lib_a(major1,major2,minor)" in content,
        "cabal_macros.h must define MIN_VERSION_lib_a",
    )
    self_ident = ctx.attr.expected_pkg_name.replace("-", "_")
    asserts.true(
        env,
        '#define VERSION_{} "{}"'.format(self_ident, ctx.attr.expected_version) in content,
        "cabal_macros.h must define self VERSION_" + self_ident,
    )
    asserts.true(
        env,
        "#define MIN_VERSION_{}(major1,major2,minor)".format(self_ident) in content,
        "cabal_macros.h must define self MIN_VERSION_" + self_ident,
    )
    asserts.true(
        env,
        '#define TOOL_VERSION_ghc "' in content,
        "cabal_macros.h must define TOOL_VERSION_ghc",
    )
    asserts.true(
        env,
        "#define MIN_TOOL_VERSION_ghc(major1,major2,minor)" in content,
        "cabal_macros.h must define MIN_TOOL_VERSION_ghc",
    )

    if ctx.attr.expect_paths_module:
        expected_paths_file = "Paths_{}.hs".format(self_ident)
        paths_actions = [
            a
            for a in actions
            if a.mnemonic == "FileWrite" and any([o.basename == expected_paths_file for o in a.outputs.to_list()])
        ]
        asserts.equals(env, 1, len(paths_actions), "expected generated " + expected_paths_file)
        paths_content = paths_actions[0].content
        asserts.true(env, ("module Paths_" + self_ident) in paths_content, "Paths module header missing")

    # Verify HsCompileLibrary passes -X<default_language> and includes cabal_macros.h.
    compile_actions = _find_actions_by_mnemonic(actions, "HsCompileLibrary")
    asserts.equals(env, 1, len(compile_actions), "expected exactly one HsCompileLibrary action")
    argv = compile_actions[0].argv

    expected_lang_flag = "-X" + ctx.attr.expected_language
    forbidden_lang_flag = "-X" + ctx.attr.forbidden_language
    asserts.true(
        env,
        expected_lang_flag in argv,
        "expected '{}' in HsCompileLibrary argv".format(expected_lang_flag),
    )
    asserts.false(
        env,
        forbidden_lang_flag in argv,
        "did not expect '{}' in HsCompileLibrary argv".format(forbidden_lang_flag),
    )
    asserts.true(env, "-optP-include" in argv, "expected -optP-include for cabal_macros.h")
    asserts.true(env, ("-optP" + macro_file.path) in argv, "expected -optP<cabal_macros.h> in argv")
    asserts.true(env, "-optc-include" in argv, "expected -optc-include for cabal_macros.h")
    asserts.true(env, ("-optc" + macro_file.path) in argv, "expected -optc<cabal_macros.h> in argv")

    if ctx.attr.expect_paths_module:
        asserts.true(env, "-optc-DCABAL_C_OPT=1" in argv, "expected cc_options forwarded via -optc in HsCompileLibrary")
        user_link_flags = [
            f
            for li in target[CcInfo].linking_context.linker_inputs.to_list()
            for f in li.user_link_flags
        ]
        asserts.true(env, "-lm" in user_link_flags, "expected extra_libraries=['m'] to attach -lm to CcInfo")

    return analysistest.end(env)

hs_cabal_library_test = analysistest.make(
    _hs_cabal_library_test_impl,
    attrs = {
        "expected_pkg_name": attr.string(mandatory = True),
        "expected_version": attr.string(mandatory = True),
        "expected_language": attr.string(mandatory = True),
        "forbidden_language": attr.string(mandatory = True),
        "expect_paths_module": attr.bool(default = False),
    },
)

def _hs_cabal_c_only_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    actions = analysistest.target_actions(env)

    pkg = target[HsPackageInfo]
    asserts.false(env, pkg.is_boot)
    asserts.equals(env, "sample-c-only", pkg.name)
    asserts.equals(env, "0.9.1", pkg.version)
    asserts.equals(env, None, pkg.unit_id)
    asserts.equals(env, None, pkg.pkg_db)
    asserts.equals(env, None, pkg.hs_lib)

    compile_actions = _find_actions_by_mnemonic(actions, "HsCompileLibrary")
    asserts.equals(env, 0, len(compile_actions), "C-only hs_cabal_library must not invoke GHC")

    asserts.true(env, CcInfo in target, "C-only hs_cabal_library must provide CcInfo")
    hdr_basenames = [f.basename for f in target[CcInfo].compilation_context.headers.to_list()]
    asserts.true(env, "sample_cc.h" in hdr_basenames, "install_includes header must be in CcInfo")
    archives = _extract_static_archives(target[CcInfo])
    asserts.true(env, len(archives) >= 1, "C-only hs_cabal_library must produce a C static archive")

    return analysistest.end(env)

hs_cabal_c_only_test = analysistest.make(_hs_cabal_c_only_test_impl)

# ==============================================================================
# 6. CcInfo propagation from cc_deps through hs_library and into hs_binary
# ==============================================================================

def _hs_library_cc_propagation_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    cc_dep = ctx.attr.cc_dep

    asserts.true(env, CcInfo in target, "hs_library must propagate CcInfo")
    asserts.true(env, HsLinkInfo in target, "hs_library must provide HsLinkInfo")

    expected_archives = _extract_static_archives(cc_dep[CcInfo])
    asserts.true(env, len(expected_archives) >= 1, "fixture cc_library must provide a static archive")

    target_archives = _extract_static_archives(target[CcInfo])
    link_archives = _extract_static_archives(target[HsLinkInfo].cc_info)
    for a in expected_archives:
        asserts.true(
            env,
            a in target_archives,
            "expected cc_deps archive '{}' in hs_library CcInfo".format(a.path),
        )
        asserts.true(
            env,
            a in link_archives,
            "expected cc_deps archive '{}' in hs_library HsLinkInfo.cc_info".format(a.path),
        )

    cc_hdrs = target[CcInfo].compilation_context.headers.to_list()
    cc_hdr_names = [f.basename for f in cc_hdrs]
    asserts.true(
        env,
        "sample_cc.h" in cc_hdr_names,
        "expected sample_cc.h in hs_library CcInfo compilation_context.headers",
    )

    # Also verify HsCompileLibrary receives the C header in action inputs.
    compile_actions = _find_actions_by_mnemonic(analysistest.target_actions(env), "HsCompileLibrary")
    asserts.equals(env, 1, len(compile_actions))
    input_names = [f.basename for f in compile_actions[0].inputs.to_list()]
    asserts.true(
        env,
        "sample_cc.h" in input_names,
        "expected sample_cc.h in HsCompileLibrary inputs for CApiFFI/CPP",
    )

    return analysistest.end(env)

hs_library_cc_propagation_test = analysistest.make(
    _hs_library_cc_propagation_test_impl,
    attrs = {
        "cc_dep": attr.label(mandatory = True, providers = [CcInfo]),
    },
)

def _hs_binary_cc_propagation_test_impl(ctx):
    env = analysistest.begin(ctx)
    cc_dep = ctx.attr.cc_dep
    actions = analysistest.target_actions(env)

    link_actions = _find_actions_by_mnemonic(actions, "HsLinkExecutable")
    asserts.equals(env, 1, len(link_actions), "expected exactly one HsLinkExecutable action")
    action = link_actions[0]
    argv = action.argv
    inputs = action.inputs.to_list()

    expected_archives = _extract_static_archives(cc_dep[CcInfo])
    asserts.true(env, len(expected_archives) >= 1, "fixture cc_library must provide a static archive")

    asserts.true(env, "-optl-Wl,--start-group" in argv, "expected --start-group around cc archives")
    asserts.true(env, "-optl-Wl,--end-group" in argv, "expected --end-group around cc archives")

    for a in expected_archives:
        asserts.true(
            env,
            ("-optl" + a.path) in argv,
            "expected '-optl{}' in HsLinkExecutable argv".format(a.path),
        )
        asserts.true(
            env,
            a in inputs,
            "expected cc archive '{}' in HsLinkExecutable inputs".format(a.path),
        )

    input_names = [f.basename for f in inputs]
    asserts.true(env, "sample_cc.h" in input_names, "expected sample_cc.h in HsLinkExecutable inputs")

    return analysistest.end(env)

hs_binary_cc_propagation_test = analysistest.make(
    _hs_binary_cc_propagation_test_impl,
    attrs = {
        "cc_dep": attr.label(mandatory = True, providers = [CcInfo]),
    },
)

# ==============================================================================
# 7. hs_haddock provider & HsHaddock action checks
# ==============================================================================

def _hs_haddock_action_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    actions = analysistest.target_actions(env)

    asserts.true(env, HsHaddockInfo in target, "hs_haddock must provide HsHaddockInfo")
    hinfo = target[HsHaddockInfo]
    asserts.true(env, hinfo.html_dir != None, "HsHaddockInfo.html_dir must be set")
    asserts.true(env, hinfo.interface != None, "HsHaddockInfo.interface must be set")
    asserts.true(
        env,
        hinfo.interface.basename.endswith(".haddock"),
        "interface basename must end with .haddock",
    )

    default_files = target[DefaultInfo].files.to_list()
    asserts.equals(env, [hinfo.html_dir], default_files, "DefaultInfo.files must contain strictly html_dir")

    haddock_actions = _find_actions_by_mnemonic(actions, "HsHaddock")
    asserts.equals(env, 1, len(haddock_actions), "expected exactly one HsHaddock action")
    argv = haddock_actions[0].argv

    asserts.true(env, "--html" in argv, "expected --html in HsHaddock argv")
    asserts.true(env, "--quickjump" in argv, "expected --quickjump in HsHaddock argv")
    asserts.true(env, "--hyperlinked-source" in argv, "expected --hyperlinked-source in HsHaddock argv")
    asserts.true(env, "--optghc=-hide-all-packages" in argv, "expected --optghc=-hide-all-packages in HsHaddock argv")

    if ctx.attr.expect_hoogle:
        asserts.true(env, "--hoogle" in argv, "expected --hoogle in HsHaddock argv")
    else:
        asserts.false(env, "--hoogle" in argv, "did not expect --hoogle in HsHaddock argv")

    if ctx.attr.upstream_haddock != None:
        up_info = ctx.attr.upstream_haddock[HsHaddockInfo]
        expected_read_iface = "--read-interface=../{},{}".format(
            up_info.html_dir.basename,
            up_info.interface.path,
        )
        asserts.true(
            env,
            expected_read_iface in argv,
            "expected '{}' in HsHaddock argv".format(expected_read_iface),
        )

    return analysistest.end(env)

hs_haddock_action_test = analysistest.make(
    _hs_haddock_action_test_impl,
    attrs = {
        "upstream_haddock": attr.label(providers = [HsHaddockInfo]),
        "expect_hoogle": attr.bool(default = False),
    },
)

# ==============================================================================
# 8. GHC2024 language flag & multi-platform toolchain registration checks
# ==============================================================================

def _hs_library_language_flag_test_impl(ctx):
    env = analysistest.begin(ctx)
    actions = analysistest.target_actions(env)

    compile_actions = _find_actions_by_mnemonic(actions, "HsCompileLibrary")
    asserts.equals(env, 1, len(compile_actions), "expected one HsCompileLibrary action")
    argv = compile_actions[0].argv
    expected_flag = "-X" + ctx.attr.expected_language
    asserts.true(
        env,
        expected_flag in argv,
        "expected '{}' in HsCompileLibrary argv".format(expected_flag),
    )
    return analysistest.end(env)

hs_library_language_flag_test = analysistest.make(
    _hs_library_language_flag_test_impl,
    attrs = {
        "expected_language": attr.string(mandatory = True),
    },
)

def _toolchain_registration_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asserts.true(
        env,
        platform_common.ToolchainInfo in target or DefaultInfo in target,
        "registered toolchain target must resolve cleanly",
    )
    return analysistest.end(env)

toolchain_registration_test = analysistest.make(_toolchain_registration_test_impl)

# ==============================================================================
# 9. hs_repl provider, strict visibility, flag sanitization, and cbits checks
# ==============================================================================

def _hs_repl_interpreted_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    actions = analysistest.target_actions(env)

    asserts.true(env, HsReplInfo in target, "hs_repl must provide HsReplInfo")
    asserts.true(
        env,
        target[DefaultInfo].files_to_run.executable != None,
        "hs_repl must declare an executable launcher",
    )

    rinfo = target[HsReplInfo]
    asserts.equals(env, target[DefaultInfo].files_to_run.executable, rinfo.executable)
    asserts.true(env, rinfo.ghci_script.basename.endswith(".ghci"), "ghci_script must end with .ghci")

    src_names = [f.basename for f in rinfo.interpreted_srcs.to_list()]
    asserts.true(env, "LibC.hs" in src_names, "workspace dep LibC.hs must be interpreted from source")
    asserts.false(env, "LibB.hs" in src_names, "indirect workspace dep LibB.hs must remain compiled unless in deps")

    pkg_c = ctx.attr.interpreted_dep[HsPackageInfo]
    pkg_b = ctx.attr.direct_compiled_dep[HsPackageInfo]
    pkg_a = ctx.attr.transitive_dep[HsPackageInfo]
    pkg_base = ctx.attr.base_dep[HsPackageInfo]

    pkg_ids = rinfo.package_ids.to_list()
    asserts.false(env, pkg_c.unit_id in pkg_ids, "interpreted target's own unit_id must not be passed via -package-id")
    asserts.true(env, pkg_b.unit_id in pkg_ids, "interpreted target's direct dep lib_b must be passed via -package-id")
    asserts.true(env, pkg_base.unit_id in pkg_ids, "direct boot dep base must be passed via -package-id")
    asserts.false(env, pkg_a.unit_id in pkg_ids, "transitive-only dep lib_a must NOT be passed via -package-id")

    launcher_writes = [
        a
        for a in actions
        if a.mnemonic == "FileWrite" and any([o == rinfo.executable for o in a.outputs.to_list()])
    ]
    asserts.equals(env, 1, len(launcher_writes), "expected FileWrite action for hs_repl launcher")
    script_text = launcher_writes[0].content

    asserts.true(env, '"-hide-all-packages"' in script_text, "hs_repl must pass -hide-all-packages by default")
    asserts.true(env, '"-ignore-dot-ghci"' in script_text, "hs_repl must pass -ignore-dot-ghci by default")
    asserts.false(env, pkg_c.pkg_db.short_path in script_text, "interpreted target pkg_db must be excluded from -package-db")
    asserts.true(env, pkg_b.pkg_db.short_path in script_text, "direct compiled dep pkg_db must be passed via -package-db")
    asserts.true(env, pkg_a.pkg_db.short_path in script_text, "transitive compiled dep pkg_db must be passed via -package-db")
    asserts.false(env, "'-O2'" in script_text, "batch-only -O2 from upstream library ghc_opts must be stripped for GHCi")
    asserts.false(env, "'-Werror'" in script_text, "batch-only -Werror from upstream library ghc_opts must be stripped for GHCi")
    asserts.true(env, "'-Wall'" in script_text, "compatible warning flag -Wall must be preserved")

    cbits_actions = _find_actions_by_mnemonic(actions, "HsLinkReplCbits")
    asserts.equals(env, 0, len(cbits_actions), "pure-Haskell hs_repl must not emit HsLinkReplCbits")

    return analysistest.end(env)

hs_repl_interpreted_test = analysistest.make(
    _hs_repl_interpreted_test_impl,
    attrs = {
        "interpreted_dep": attr.label(mandatory = True, providers = [HsPackageInfo]),
        "direct_compiled_dep": attr.label(mandatory = True, providers = [HsPackageInfo]),
        "transitive_dep": attr.label(mandatory = True, providers = [HsPackageInfo]),
        "base_dep": attr.label(mandatory = True, providers = [HsPackageInfo]),
    },
)

def _hs_repl_cbits_and_compiled_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    actions = analysistest.target_actions(env)

    rinfo = target[HsReplInfo]
    src_names = [f.basename for f in rinfo.interpreted_srcs.to_list()]
    asserts.true(env, "WithCc.hs" in src_names, "hs_with_cc in deps must be interpreted")
    asserts.false(env, "LibB.hs" in src_names, "lib_b in compiled_deps must NOT be interpreted from source")

    pkg_b = ctx.attr.compiled_dep[HsPackageInfo]
    asserts.true(env, pkg_b.unit_id in rinfo.package_ids.to_list(), "compiled_deps unit_id must be in package_ids")

    cbits_actions = _find_actions_by_mnemonic(actions, "HsLinkReplCbits")
    asserts.equals(env, 1, len(cbits_actions), "hs_repl with C deps must emit one HsLinkReplCbits action")

    ghci_writes = [
        a
        for a in actions
        if a.mnemonic == "FileWrite" and any([o == rinfo.ghci_script for o in a.outputs.to_list()])
    ]
    asserts.equals(env, 1, len(ghci_writes))
    asserts.true(env, ":set +t" in ghci_writes[0].content, "ghci_commands must be written to static .ghci file")

    return analysistest.end(env)

hs_repl_cbits_and_compiled_test = analysistest.make(
    _hs_repl_cbits_and_compiled_test_impl,
    attrs = {
        "compiled_dep": attr.label(mandatory = True, providers = [HsPackageInfo]),
    },
)

def _toolchain_probe_impl(ctx):
    return [ctx.toolchains[TOOLCHAIN_TYPE].hs]

toolchain_probe = rule(
    implementation = _toolchain_probe_impl,
    toolchains = [TOOLCHAIN_TYPE],
    provides = [HsToolchainInfo],
)

def _hs_toolchain_interpreter_tools_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)

    asserts.true(env, HsToolchainInfo in target, "toolchain_probe must provide HsToolchainInfo")
    tc = target[HsToolchainInfo]
    asserts.true(env, tc.runghc != None, "HsToolchainInfo.runghc must be staged")
    asserts.true(env, tc.runghc.basename.startswith("runghc"), "unexpected runghc basename: " + tc.runghc.basename)
    if tc.is_dynamic_ghc:
        asserts.true(env, tc.ghc_iserv != None, "HsToolchainInfo.ghc_iserv must be staged on dynamic GHC")

    return analysistest.end(env)

hs_toolchain_interpreter_tools_test = analysistest.make(_hs_toolchain_interpreter_tools_test_impl)
