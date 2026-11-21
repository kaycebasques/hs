---
title: "Migration & Troubleshooting"
description: "Migrate existing projects from tweag/rules_haskell, Cabal, or Stack to rules_hs and resolve common build and lockfile issues."
section: guide
nav_title: "Migration & Troubleshooting"
order: 60
---

This guide provides step-by-step migration recipes from `tweag/rules_haskell`, Cabal, and Stack, followed by solutions to the most common build, C toolchain, runfiles, and Hackage lockfile errors.

## Migrating from `tweag/rules_haskell`

`rules_hs` is a clean-slate Bazel 9 Bzlmod ruleset designed to eliminate `WORKSPACE` boilerplate, `rules_nixpkgs`, Python `cc_wrapper` scripts, and manual `haskell_toolchain_library` declarations. (For an architectural deep dive comparing `rules_hs`, `tweag/rules_haskell`, Buck2's Haskell rules, Please Build, and `haskell.nix`, see [Comparison with Other Rulesets](../internals/rulesets-comparison.md).)

### Concept & Rule Mapping

| `tweag/rules_haskell` | `rules_hs` | Key Differences |
|---|---|---|
| `WORKSPACE` + `rules_haskell_dependencies()` | `MODULE.bazel` (`bazel_compatibility = [">=9.0.0"]`) | Pure Bzlmod; delete `WORKSPACE` and `WORKSPACE.bzlmod` |
| `haskell_register_ghc_bindists()` / `haskell_register_ghc_nixpkgs()` | [`hs.toolchain`](../reference/extensions-and-providers.md#hs-toolchain) + `register_toolchains("@hs_toolchains//:all")` | Nix-free hermetic bindists (`9.10.3` / `9.12.4`) with `$ORIGIN` staging |
| `haskell_toolchain_library(name = "base")` | `@hs_boot//:base` or `@hackage//:base` | Generated automatically for every GHC boot library |
| `stack_snapshot(...)` (`@stackage//:pkg`) | [`//tools/lock:lock`](../reference/lock-cli.md) + [`hackage.from_lock`](../reference/extensions-and-providers.md#hackage-from_lock) (`@hackage//:pkg`) | Offline deterministic `hackage.lock.json`; zero host `stack` binary at build time; 5-stage [`hs_cabal_library`](../reference/rules.md#hs_cabal_library) instead of `Setup.hs` |
| `haskell_library` | [`hs_library`](../reference/rules.md#hs_library) | Defaults to `GHC2021`; separates `deps` and `cc_deps`; uses `hs_source_dirs` instead of `src_strip_prefix` |
| `haskell_binary` | [`hs_binary`](../reference/rules.md#hs_binary) | Links `libgmp.a` statically; defaults to `threaded = True` and `main_module = "Main"` |
| `haskell_test` | [`hs_test`](../reference/rules.md#hs_test) | Same attributes as [`hs_binary`](../reference/rules.md#hs_binary) |
| `haskell_doc` | [`hs_haddock`](../reference/rules.md#hs_haddock) | Runs GHC's `$ORIGIN`-staged `haddock` hermetically with hyperlinked source and QuickJump (`doc-index.json`) |
| `ghcopts = [...]` | `ghc_opts = [...]` | Snake-case attribute naming (`ghc_opts`, `cpp_options`, `cc_options`) |
| `src_strip_prefix = "src"` | `hs_source_dirs = ["src"]` | Matches Cabal's `hs-source-dirs` list directly (supports multiple source roots) |
| `extra_srcs = [...]` (for CPP headers / TH files) | `hdrs = [...]` (compile-time headers) or `data = [...]` (TH & runtime files) | `hdrs` exposes C/CPP headers; `data` stages files into both the TH compile sandbox (`file-embed` / `runIO`) and runtime runfiles |
| `compiler_flags_select` | Standard Bazel `select({...})` on `ghc_opts` / `deps` / `srcs` | Native Bazel configurable attributes work everywhere |

### 5-Step Migration Checklist

1. **Upgrade `.bazelversion` to `>= 9.0.0`** (e.g., `9.3.3`) and remove legacy `WORKSPACE` / `WORKSPACE.bazel` / `WORKSPACE.bzlmod` files.
2. **Replace `MODULE.bazel` toolchain setup** with [`hs.toolchain`](../reference/extensions-and-providers.md#hs-toolchain) (plus `hermetic_cc_toolchain` or `toolchains_llvm` — see [C FFI & Toolchains](c-interop-and-toolchains.md)). Remove `rules_nixpkgs`, `rules_python`, `rules_sh`, and manual `haskell_toolchain_library` targets.
3. **Replace `stack_snapshot` with `hackage.lock.json`**: Run `bazel run @rules_hs//tools/lock:lock -- --snapshot lts-24.67 --package ... --output "$PWD/hackage.lock.json"` and wire [`hackage.from_lock`](../reference/extensions-and-providers.md#hackage-from_lock) in `MODULE.bazel`.
4. **Update `BUILD.bazel` loads and attribute names**:
   - Change `load("@rules_haskell//haskell:defs.bzl", ...)` to `load("@rules_hs//hs:defs.bzl", "hs_binary", "hs_haddock", "hs_library", "hs_test")`.
   - Rename `ghcopts` -> `ghc_opts`, `src_strip_prefix` -> `hs_source_dirs`, and `@stackage//:` -> `@hackage//:`.
   - Note that [`hs_library`](../reference/rules.md#hs_library), [`hs_binary`](../reference/rules.md#hs_binary), and [`hs_test`](../reference/rules.md#hs_test) default to `default_language = "GHC2021"` and `threaded = True`. If legacy code assumes `Haskell2010`, pass `default_language = "Haskell2010"`.
5. **Verify strict direct dependencies**: Because `rules_hs` enforces strict direct-dependency visibility (`-hide-all-packages` + direct `-package-id`s), add any directly imported boot or Hackage packages to each target's own `deps`.

---

## Migrating from Cabal or Stack

Translating a `.cabal` or `package.yaml` component to `BUILD.bazel` is a direct 1-to-1 mapping:

| `.cabal` Stanza Field | `rules_hs` Attribute (`hs_library` / `hs_binary` / `hs_test`) |
|---|---|
| `exposed-modules` + `other-modules` | `srcs` (list `.hs` / `.lhs` / `.hs-boot` files) + `hidden_modules` (for `other-modules` in [`hs_library`](../reference/rules.md#hs_library)) |
| `main-is` + `-main-is` | Include main `.hs` file in `srcs`; set `main_module` if module is not `Main` |
| `build-depends` | `deps = ["@hackage//:...", ":local_lib"]` |
| `hs-source-dirs` | `hs_source_dirs = ["src"]` |
| `default-language` | `default_language = "GHC2021"` (or `"Haskell2010"`, `"Haskell98"`, `"GHC2024"`) |
| `default-extensions` | `default_extensions = ["OverloadedStrings", "LambdaCase"]` |
| `ghc-options` | `ghc_opts = ["-Wall", "-O2"]` (omit `-threaded` on executables; use `threaded = True` instead) |
| `cpp-options` | `cpp_options = ["-DFOO=1"]` |
| `c-sources` / `cc-options` / `include-dirs` | `c_sources`, `cc_options`, `include_dirs`, `hdrs` |
| `extra-libraries` / `pkgconfig-depends` | `cc_deps = ["@zlib//:zlib"]` (or bundled C flags in [`//tools/lock:lock`](../reference/lock-cli.md)) |
| `data-files` | `data = [...]` accessed via `RUNFILES_DIR` / `TEST_SRCDIR` (see [Language, RTS, Runfiles & Template Haskell](language-rts-runfiles-th.md)) |

---

## Troubleshooting Common Issues

### 1. `Could not load module '...' — It is a member of the hidden package '...'`

**Cause**: `rules_hs` passes `-hide-all-packages` and exposes only **direct** `deps` via `-package-id`. Your source file imports a module from a transitive dependency that is not listed in the target's own `deps`.

**Fix**: Add the package directly to the target's `deps` list in `BUILD.bazel` (e.g., `"@hs_boot//:bytestring"` or `"@hackage//:bytestring"`).

---

### 2. `undefined symbol: memfd_create` / `statx` or `fatal error: 'sys/single_threaded.h' file not found` with `hermetic_cc_toolchain`

**Cause**: `@zig_sdk//toolchain/...` was registered without placing the `gnu.2.32` toolchains first, causing Bazel to select `gnu.2.17` alphabetically.

**Fix**: Register `linux_amd64_gnu.2.32` and `linux_arm64_gnu.2.32` **before** `@zig_sdk//toolchain/...` in `MODULE.bazel`:

```starlark
register_toolchains(
    "@zig_sdk//toolchain:linux_amd64_gnu.2.32",
    "@zig_sdk//toolchain:linux_arm64_gnu.2.32",
    "@zig_sdk//toolchain/...",
    "@zig_sdk//libc_aware/toolchain/...",
)
```

Also ensure `.bazelrc` mounts `/tmp` for Zig's compiler cache (`build:linux --repo_env=HERMETIC_CC_TOOLCHAIN_CACHE_PREFIX=/tmp/zig-cc-cache` and `build:linux --sandbox_add_mount_pair=/tmp`).

---

### 3. `bazel run @rules_hs//tools/lock:lock` Did Not Update `hackage.lock.json` in My Repo

**Cause**: `bazel run` executes binaries inside Bazel's runfiles tree rather than your shell's working directory, so a relative `--output hackage.lock.json` writes inside the ephemeral runfiles directory.

**Fix**: Pass an absolute path using `$PWD`:

```bash
bazel run @rules_hs//tools/lock:lock -- \
  --snapshot lts-24.67 \
  --package aeson \
  --output "$PWD/hackage.lock.json"
```

---

### 4. Missing System C Header (`zlib.h`, `pcre.h`, `sqlite3.h`) When Building a Hackage Package

**Cause**: Inside Bazel's hermetic sandbox, host `/usr/include` headers and `pkg-config` files are intentionally absent or ignored by hermetic C toolchains.

**Fix**: Choose one of two hermetic remedies (detailed in [Hackage & Lockfiles](hackage.md)):
- **Flip a bundled-C Cabal flag** in [`//tools/lock:lock`](../reference/lock-cli.md), e.g., `--flag zlib:bundled-c-zlib=true --flag zlib:pkg-config=false`.
- **Attach a BCR `cc_library`** in `MODULE.bazel` using [`hackage.override`](../reference/extensions-and-providers.md#hackage-override):
  ```starlark
  hackage.override(
      package = "zlib",
      extra_cc_deps = ["@zlib//:zlib"],
  )
  ```

---

### 5. `openFile: does not exist` When Reading `data` Files in `hs_test` or `hs_binary`

**Cause**: Either `--enable_runfiles` is missing from `.bazelrc`, or the Haskell code is opening a bare relative path without checking `RUNFILES_DIR` / `TEST_SRCDIR` + `TEST_WORKSPACE`.

**Fix**:
1. Add `common --enable_runfiles` to `.bazelrc`.
2. Resolve runfiles via `RUNFILES_DIR` / `TEST_SRCDIR` and `TEST_WORKSPACE` (defaulting to `"_main"` in Bzlmod). Copy the self-contained `resolveRunfile` helper from [Language, RTS, Runfiles & Template Haskell](language-rts-runfiles-th.md).

---

### 6. `forkOS: failed to create OS thread (Cannot create OS thread. Did you compile with -threaded?)`

**Cause**: `threaded = False` was set on [`hs_binary`](../reference/rules.md#hs_binary) or [`hs_test`](../reference/rules.md#hs_test), linking GHC's single-threaded runtime (`rtsSupportsBoundThreads == False`).

**Fix**: Remove `threaded = False` (or set `threaded = True`, which is already the default on both [`hs_binary`](../reference/rules.md#hs_binary) and [`hs_test`](../reference/rules.md#hs_test)).

---

### 7. `Boot package '...' not found in GHC 9.10.3 global package DB`

**Cause**: A [`hs_toolchain_library`](../reference/rules.md#hs_toolchain_library) target requested a package name that is not part of the active GHC release's boot database (for instance, `file-io` is a boot package in GHC `9.12.4` but not in GHC `9.10.3`, whereas third-party packages like `aeson` or `network` live on Hackage rather than in `@hs_boot`).

**Fix**: Check the error message's printed list of available boot packages for your GHC version, or pin the package via [`//tools/lock:lock`](../reference/lock-cli.md) and reference `@hackage//:<pkg>`.
