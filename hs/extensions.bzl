"""Bzlmod module extensions for rules_hs."""

load("//hs/private:ghc_bindist.bzl", "ghc_bindist_repo", "hs_boot_repo", "hs_toolchains_repo")
load("//hs/private:ghc_versions.bzl", "DEFAULT_GHC_VERSION", "GHC_BINDISTS", "SUPPORTED_PLATFORMS")

# NOTE: After merge with hackage-author, re-export `hackage` from `//hs/private:hackage.bzl`:
# load("//hs/private:hackage.bzl", _hackage = "hackage")
# hackage = _hackage

_toolchain_tag = tag_class(
    doc = "Configures the GHC version to download and register.",
    attrs = {
        "ghc_version": attr.string(
            default = DEFAULT_GHC_VERSION,
            doc = "Official GHC version (e.g. '9.10.3' or '9.12.4').",
        ),
        "platforms": attr.string_list(
            default = [],
            doc = "Optional subset of platform keys (default: all Linux platforms with verified bindists).",
        ),
    },
)

def _hs_extension_impl(module_ctx):
    selected_version = None
    selected_platforms = []

    # Root module takes precedence over non-root defaults (e.g. rules_hs itself).
    root_tags = []
    other_tags = []
    for mod in module_ctx.modules:
        for tag in mod.tags.toolchain:
            if mod.is_root:
                root_tags.append(tag)
            else:
                other_tags.append(tag)

    chosen = root_tags[0] if root_tags else (other_tags[0] if other_tags else None)
    if chosen:
        selected_version = chosen.ghc_version
        selected_platforms = list(chosen.platforms)
    else:
        selected_version = DEFAULT_GHC_VERSION

    if selected_version not in GHC_BINDISTS:
        fail("Unsupported GHC version '{}'. Supported versions: {}".format(
            selected_version,
            sorted(GHC_BINDISTS.keys()),
        ))

    version_map = GHC_BINDISTS[selected_version]
    if not selected_platforms:
        selected_platforms = [p for p in SUPPORTED_PLATFORMS if p in version_map]

    ver_id = selected_version.replace(".", "_")
    platform_repos = {}

    for plat in selected_platforms:
        if plat not in version_map:
            fail("GHC {} has no bindist entry for platform '{}'".format(selected_version, plat))
        spec = version_map[plat]
        repo_name = "ghc_{}_{}".format(ver_id, plat)
        ghc_bindist_repo(
            name = repo_name,
            ghc_version = selected_version,
            url = spec["url"],
            sha256 = spec["sha256"],
            strip_prefix = spec["strip_prefix"],
            arch_libdir = spec["arch_libdir"],
            bignum = spec["bignum"],
            is_dynamic_ghc = spec["dynamic_ghc"],
            needs_tinfo_stub = spec["needs_tinfo_stub"],
            target_os = spec["os"],
            target_cpu = spec["cpu"],
        )
        platform_repos[plat] = repo_name

    # Pick a representative bindist repo for @hs_boot package names.
    # All platforms for a given GHC release share the same boot package names
    # (exact unit IDs are resolved at analysis time from the active HsToolchainInfo!).
    hs_toolchains_repo(
        name = "hs_toolchains",
        ghc_version = selected_version,
        platform_repos = platform_repos,
    )

    hs_boot_repo(
        name = "hs_boot",
        ghc_version = selected_version,
    )

    return module_ctx.extension_metadata(reproducible = True)

hs = module_extension(
    implementation = _hs_extension_impl,
    tag_classes = {
        "toolchain": _toolchain_tag,
    },
    doc = "Downloads hermetic GHC bindists and generates @hs_toolchains and @hs_boot repositories.",
)
