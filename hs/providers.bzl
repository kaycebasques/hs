"""Public providers for rules_hs."""

HsPackageInfo = provider(
    doc = "Direct metadata for a compiled Haskell package (or C-only Cabal package).",
    fields = {
        "name": "string: Cabal or library package name (e.g. 'base', 'http-client').",
        "version": "string: Package version (e.g. '4.20.2.0', '0.7.19').",
        "unit_id": "string | None: GHC unit/package ID, or None for C-only packages (e.g. zlib-clib).",
        "pkg_db": "File | None: Relocatable ghc-pkg DB directory (TreeArtifact), or None for boot/C-only packages.",
        "exposed_modules": "list[str]: Exposed Haskell module names.",
        "is_boot": "bool: True if this package comes from GHC's global boot package database.",
        "hs_lib": "File | None: Static archive libHS<unit_id>.a, or None for boot/C-only packages.",
        "hi_dir": "File | None: Directory (TreeArtifact) of compiled .hi files, or None for boot/C-only packages.",
    },
)

HsLinkInfo = provider(
    doc = "Transitive compilation and linking inputs propagated through a Haskell dependency graph.",
    fields = {
        "pkg_dbs": "depset[File]: Transitive relocatable ghc-pkg DB directories.",
        "hs_libs": "depset[File]: Transitive static Haskell library archives (libHS*.a).",
        "include_dirs": "depset[str]: Transitive C include directories for CApiFFI / CPP / hsc2hs.",
        "headers": "depset[File]: Transitive C header files for CApiFFI / CPP / hsc2hs.",
        "cc_info": "CcInfo: Merged transitive native C/C++ compilation and linking info.",
    },
)

HsToolchainInfo = provider(
    doc = "Resolved hermetic GHC toolchain and companion C-toolchain adapter tools.",
    fields = {
        "version": "string: GHC version string (e.g. '9.10.3').",
        "ghc": "File: Staged ghc executable.",
        "ghc_pkg": "File: Staged ghc-pkg executable.",
        "hsc2hs": "File: Staged hsc2hs executable.",
        "haddock": "File: Staged haddock executable.",
        "ghc_iserv": "File | None: Optional staged ghc-iserv-dyn / ghc-iserv executable.",
        "libdir": "File: Staged GHC lib/ directory TreeArtifact.",
        "template_hsc_h": "File: Path to template-hsc.h for hsc2hs.",
        "rts_include_dir": "string: Execroot-relative path to GHC RTS include directory (Rts.h, HsFFI.h).",
        "rts_headers": "depset[File]: GHC RTS header files.",
        "all_files": "depset[File]: All staged GHC files required at compile/link action runtime.",
        "cc_wrapper": "File: Compiled native C wrapper adapting Bazel's cc_toolchain for GHC.",
        "gmp_static_dir": "string | None: Directory containing only libgmp.a for static GMP linking.",
        "gmp_static_lib": "File | None: Static libgmp.a file.",
        "boot_packages": "dict[str, struct]: Parsed boot package metadata keyed by package name.",
        "boot_haddocks": "dict[str, File]: Map of boot package name to bundled .haddock interface File.",
        "bignum": "string: Bignum backend ('gmp' or 'native').",
        "is_dynamic_ghc": "bool: True if GHC compiler binary is dynamically linked.",
        "target_os": "string: Target OS ('linux', 'macos', 'windows').",
        "target_cpu": "string: Target CPU ('x86_64', 'arm64').",
        "arch_libdir": "string: GHC arch libdir basename (e.g. 'x86_64-linux-ghc-9.10.3').",
    },
)

HsHaddockInfo = provider(
    doc = "Generated Haddock HTML documentation directory and binary .haddock interface.",
    fields = {
        "html_dir": "File: Directory (TreeArtifact) containing generated Haddock HTML, QuickJump index, and hyperlinked source.",
        "interface": "File: Generated .haddock interface file (--dump-interface) for cross-package linking.",
        "unit_ids": "depset[str]: GHC unit IDs documented by this hs_haddock target.",
        "transitive_haddocks": "depset[struct]: Transitive struct(html_dir, interface) entries from this target and haddock_deps.",
    },
)
