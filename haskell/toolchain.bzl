"""Haskell toolchain type and rule declaration."""

load("//haskell:providers.bzl", "HsToolchainInfo")

TOOLCHAIN_TYPE = "@rules_haskell//haskell:toolchain_type"

def _hs_toolchain_impl(ctx):
    staged = ctx.attr.staged_ghc[HsToolchainInfo]
    boot_packages = {}
    for k, v in ctx.attr.boot_packages_json.items():
        boot_packages[k] = json.decode(v)

    toolchain_info = HsToolchainInfo(
        version = ctx.attr.version,
        ghc = staged.ghc,
        ghc_pkg = staged.ghc_pkg,
        hsc2hs = staged.hsc2hs,
        haddock = staged.haddock,
        runghc = staged.runghc,
        ghc_iserv = staged.ghc_iserv,
        libdir = staged.libdir,
        template_hsc_h = staged.template_hsc_h,
        rts_include_dir = staged.rts_include_dir,
        rts_headers = staged.rts_headers,
        all_files = staged.all_files,
        cc_wrapper = ctx.executable.cc_wrapper,
        gmp_static_dir = staged.gmp_static_dir,
        gmp_static_lib = staged.gmp_static_lib,
        boot_packages = boot_packages,
        boot_haddocks = staged.boot_haddocks,
        bignum = ctx.attr.bignum,
        is_dynamic_ghc = ctx.attr.is_dynamic_ghc,
        target_os = ctx.attr.target_os,
        target_cpu = ctx.attr.target_cpu,
        arch_libdir = ctx.attr.arch_libdir,
    )
    return [
        platform_common.ToolchainInfo(hs = toolchain_info),
        toolchain_info,
    ]

hs_toolchain = rule(
    implementation = _hs_toolchain_impl,
    doc = "Defines a hermetic GHC toolchain for Bazel toolchain resolution.",
    attrs = {
        "version": attr.string(mandatory = True),
        "staged_ghc": attr.label(
            mandatory = True,
            providers = [HsToolchainInfo],
            cfg = "exec",
        ),
        "cc_wrapper": attr.label(
            default = Label("//haskell/private:ghc_cc_wrapper"),
            executable = True,
            cfg = "exec",
        ),
        "boot_packages_json": attr.string_dict(
            default = {},
            doc = "Map of boot package name -> JSON-encoded {version, id, depends, exposed_modules}.",
        ),
        "bignum": attr.string(default = "gmp"),
        "is_dynamic_ghc": attr.bool(default = True),
        "target_os": attr.string(mandatory = True),
        "target_cpu": attr.string(mandatory = True),
        "arch_libdir": attr.string(mandatory = True),
    },
    provides = [platform_common.ToolchainInfo, HsToolchainInfo],
)
