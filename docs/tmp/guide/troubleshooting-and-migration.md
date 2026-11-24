---
title: "Migration and troubleshooting"
description: "Migrate projects from tweag/rules_haskell, Cabal, or Stack to rules_haskell and fix common build, Setup.hs, C header, and lockfile issues."
section: guide
nav_title: "Migration and troubleshooting"
order: 60
---

Use this guide to move an existing Haskell project from `tweag/rules_haskell`, Cabal, or Stack to `rules_haskell`, or to fix common build, `Setup.hs`, C toolchain, [runfiles](https://bazel.build/extending/rules#runfiles), and lockfile errors.

If you're starting a new project from scratch, follow the [Quickstart](quickstart.md). For an architectural comparison across `rules_haskell`, `tweag/rules_haskell`, Buck2, Please Build, and `haskell.nix`, see [Comparison with other rulesets](../internals/rulesets-comparison.md).

## Migrate from `tweag/rules_haskell`

Migrating from `tweag/rules_haskell` moves your workspace to Bazel 9 with [Bzlmod](https://bazel.build/external/overview) ([`MODULE.bazel`](https://bazel.build/external/module)), replacing legacy [`WORKSPACE`](https://bazel.build/external/overview#workspace-system) files, `rules_nixpkgs`, Python `cc_wrapper` scripts, and manual `haskell_toolchain_library` targets.

> **Important:** Check [What is supported, planned, and out of scope](../index.md#project-scope) before migrating. macOS and Windows execution, `-prof` profiling builds, `c2hs`, and GHC plugins are planned but not yet wired. Third-party Hackage packages with arbitrary `build-type: Custom` `Setup.hs` code generators are out of scope (see troubleshooting item 8 below for workarounds).

### Concept and rule mapping

| `tweag/rules_haskell` | `rules_haskell` | Key differences |
|---|---|---|
| `WORKSPACE` + `rules_haskell_dependencies()` | `MODULE.bazel` ([`bazel_compatibility = [">=9.0.0"]`](https://bazel.build/rules/lib/globals/module#module)) | Uses Bzlmod exclusively; delete `WORKSPACE` and `WORKSPACE.bzlmod` |
| `haskell_register_ghc_bindists()` / `haskell_register_ghc_nixpkgs()` | [`hs.toolchain`](../reference/extensions-and-providers.md#hs-toolchain) + [`register_toolchains("@hs_toolchains//:all")`](https://bazel.build/rules/lib/globals/module#register_toolchains) | Pinned Linux GHC archives (`9.10.3` and `9.12.4`) without Nix or host `./configure` |
| `haskell_toolchain_library(name = "base")` | `@hs_boot//:base` or `@hackage//:base` | Generated automatically for all 41 GHC boot libraries |
| `stack_snapshot(...)` (`@stackage//:pkg`) | [`//tools/lock:lock`](../reference/lock-cli.md) + [`hackage.from_lock`](../reference/extensions-and-providers.md#hackage-from_lock) (`@hackage//:pkg`) | Committed `hackage.lock.json` with no host `stack` binary at build time; 5-stage [`hs_cabal_library`](../reference/rules.md#hs_cabal_library) instead of `Setup.hs` |
| `haskell_library` | [`hs_library`](../reference/rules.md#hs_library) | Defaults to `GHC2021`, separates `deps` from `cc_deps`, and uses `hs_source_dirs` instead of `src_strip_prefix` |
| `haskell_binary` | [`hs_binary`](../reference/rules.md#hs_binary) | Links `libgmp.a` statically; defaults to `threaded = True` and `main_module = "Main"` |
| `haskell_test` | [`hs_test`](../reference/rules.md#hs_test) | Same attributes as `hs_binary` |
| `haskell_repl` / `@rules_haskell//tools/ghci` | [`hs_repl`](../reference/rules.md#hs_repl) / `@rules_haskell//tools/ghci` | Loads workspace targets into GHCi bytecode (`interpret_deps = True`, `:reload`, `:break`) and external packages from `.pkgdb/dyn/`; `@rules_haskell//tools/ghci:runghc` runs standalone scripts |
| `haskell_doc` | [`hs_haddock`](../reference/rules.md#hs_haddock) | Runs GHC's bundled `haddock` inside Bazel's [sandbox](https://bazel.build/docs/sandboxing) with hyperlinked source and QuickJump (`doc-index.json`) |
| `ghcopts = [...]` | `ghc_opts = [...]` | Snake-case attribute names (`ghc_opts`, `cpp_options`, `cc_options`) |
| `src_strip_prefix = "src"` | `hs_source_dirs = ["src"]` | Matches Cabal's `hs-source-dirs` list and supports multiple source roots |
| `extra_srcs = [...]` (CPP headers or TH files) | `hdrs = [...]` (compile-time headers) or `data = [...]` (TH and runtime files) | `hdrs` exposes C and CPP headers; `data` stages files into both the TH compile sandbox (`file-embed` and `runIO`) and runtime runfiles |
| `compiler_flags_select` | Standard Bazel [`select({...})`](https://bazel.build/configure/attributes) on `ghc_opts`, `deps`, or `srcs` | Standard Bazel configurable attributes work on all rules |

### Migration checklist

1. **Upgrade [`.bazelversion`](https://bazel.build/install/bazelisk) to `>= 9.0.0`** (for example, `9.3.3`) and remove legacy `WORKSPACE`, `WORKSPACE.bazel`, and `WORKSPACE.bzlmod` files.
2. **Replace toolchain setup in `MODULE.bazel`** with `hs.toolchain` plus `hermetic_cc_toolchain`, `toolchains_llvm`, or your existing Linux [`cc_toolchain`](https://bazel.build/reference/be/c-cpp#cc_toolchain) (see [C FFI and toolchains](c-interop-and-toolchains.md)). Remove `rules_nixpkgs` and manual `haskell_toolchain_library` targets.
3. **Replace `stack_snapshot` with `hackage.lock.json`:** Run `bazel run @rules_haskell//tools/lock:lock -- --snapshot lts-24.67 --package ... --output "$PWD/hackage.lock.json"` and load the lockfile with `hackage.from_lock` in `MODULE.bazel`.
4. **Update [`BUILD.bazel`](https://bazel.build/concepts/build-files) loads and attribute names:**
   - Replace `haskell_*` rule symbols in `load("@rules_haskell//haskell:defs.bzl", ...)` with `"hs_binary"`, `"hs_haddock"`, `"hs_library"`, `"hs_repl"`, and `"hs_test"` (the `@rules_haskell//haskell:defs.bzl` load path stays the same).
   - Rename `ghcopts` to `ghc_opts`, `src_strip_prefix` to `hs_source_dirs`, and `@stackage//:` to `@hackage//:`.
   - Check language defaults: `hs_library`, `hs_binary`, and `hs_test` default to `default_language = "GHC2021"` and `threaded = True`. If older code requires `Haskell2010` semantics, set `default_language = "Haskell2010"`.
5. **List all directly imported packages in `deps`:** Because `rules_haskell` compiles with `-hide-all-packages` and passes `-package-id` only for direct `deps`, add every directly imported boot or Hackage package to each target's `deps` list.

## Migrate from Cabal or Stack

Each field in a `.cabal` or `package.yaml` component maps directly to an attribute on `hs_library`, `hs_binary`, or `hs_test` in `BUILD.bazel`:

| `.cabal` stanza field | `rules_haskell` attribute |
|---|---|
| `exposed-modules` and `other-modules` | `srcs` (list `.hs`, `.lhs`, and `.hs-boot` files) and `hidden_modules` (for `other-modules` in `hs_library`) |
| `main-is` and `-main-is` | Include the main `.hs` file in `srcs`; set `main_module` if the entry module isn't `Main` |
| `build-depends` | `deps = ["@hackage//:...", ":local_lib"]` |
| `hs-source-dirs` | `hs_source_dirs = ["src"]` |
| `default-language` | `default_language = "GHC2021"` (or `"Haskell2010"`, `"Haskell98"`, `"GHC2024"`) |
| `default-extensions` | `default_extensions = ["OverloadedStrings", "LambdaCase"]` |
| `ghc-options` | `ghc_opts = ["-Wall", "-O2"]` (omit `-threaded` on executables and use `threaded = True` instead) |
| `cpp-options` | `cpp_options = ["-DFOO=1"]` |
| `c-sources`, `cc-options`, `include-dirs` | `c_sources`, `cc_options`, `include_dirs`, `hdrs` |
| `extra-libraries`, `pkgconfig-depends` | `cc_deps = ["@zlib//:zlib"]` (or bundled-C flags in `//tools/lock:lock`) |
| `data-files` | `data = [...]`, accessed through `RUNFILES_DIR` and [`TEST_SRCDIR`](https://bazel.build/reference/test-encyclopedia#initial-conditions) (see [Language, RTS, runfiles, and Template Haskell](language-rts-runfiles-th.md)) |

## Troubleshooting common issues

### 1. `Could not load module '...' — It is a member of the hidden package '...'`

**Cause:** `rules_haskell` passes `-hide-all-packages` to GHC and exposes only direct `deps` with `-package-id`. Your `.hs` file imports a module from a transitive dependency that isn't listed in the target's own `deps`.

**Fix:** Add that package to the target's `deps` list in `BUILD.bazel` (for example, `"@hs_boot//:bytestring"` or `"@hackage//:bytestring"`).

### 2. `undefined symbol: memfd_create` / `statx` or `fatal error: 'sys/single_threaded.h' file not found` with `hermetic_cc_toolchain`

**Cause:** You registered `@zig_sdk//toolchain/...` without listing the `gnu.2.32` toolchains ahead of the wildcard, so Bazel picks `gnu.2.17` alphabetically.

**Fix:** Register `linux_amd64_gnu.2.32` and `linux_arm64_gnu.2.32` before `@zig_sdk//toolchain/...` in `MODULE.bazel`:

```starlark
register_toolchains(
    "@zig_sdk//toolchain:linux_amd64_gnu.2.32",
    "@zig_sdk//toolchain:linux_arm64_gnu.2.32",
    "@zig_sdk//toolchain/...",
    "@zig_sdk//libc_aware/toolchain/...",
)
```

Also make sure [`.bazelrc`](https://bazel.build/run/bazelrc) mounts `/tmp` for Zig's compiler cache (`build:linux --repo_env=HERMETIC_CC_TOOLCHAIN_CACHE_PREFIX=/tmp/zig-cc-cache` and `build:linux --sandbox_add_mount_pair=/tmp`).

### 3. `bazel run @rules_haskell//tools/lock:lock` doesn't update `hackage.lock.json` in your repo

**Cause:** [`bazel run`](https://bazel.build/docs/user-manual#running-executables) executes binaries inside Bazel's temporary runfiles directory rather than your shell's working directory, so a relative `--output hackage.lock.json` writes inside the runfiles tree.

**Fix:** Pass an absolute path with `$PWD`:

```bash
bazel run @rules_haskell//tools/lock:lock -- \
  --snapshot lts-24.67 \
  --package aeson \
  --output "$PWD/hackage.lock.json"
```

### 4. Missing system C header (`zlib.h`, `pcre.h`, `sqlite3.h`) when building a Hackage package

**Cause:** Inside Bazel's sandbox, host `/usr/include` headers and `pkg-config` files are absent or ignored by sandboxed C toolchains.

**Fix:** Use one of the two patterns in [Hackage and lockfiles](hackage.md):

- **Enable a bundled-C Cabal flag** in `//tools/lock:lock`, such as `--flag zlib:bundled-c-zlib=true --flag zlib:pkg-config=false`.
- **Attach a [BCR](https://bazel.build/external/registry#bazel-central-registry) [`cc_library`](https://bazel.build/reference/be/c-cpp#cc_library)** in `MODULE.bazel` with [`hackage.override`](../reference/extensions-and-providers.md#hackage-override):

  ```starlark
  hackage.override(
      package = "zlib",
      extra_cc_deps = ["@zlib//:zlib"],
  )
  ```

### 5. `openFile: does not exist` when reading `data` files in `hs_test` or `hs_binary`

**Cause:** Either [`--enable_runfiles`](https://bazel.build/reference/command-line-reference#param-no-enable-runfiles) is missing from `.bazelrc`, or your Haskell code opens a bare relative path without checking `RUNFILES_DIR`, `TEST_SRCDIR`, and `TEST_WORKSPACE`.

**Fix:**

1. Add `common --enable_runfiles` to `.bazelrc`.
2. Resolve runfile paths using `RUNFILES_DIR`, `TEST_SRCDIR`, and `TEST_WORKSPACE` (which defaults to `"_main"` under Bzlmod). See the `resolveRunfile` helper in [Language, RTS, runfiles, and Template Haskell](language-rts-runfiles-th.md).

### 6. `forkOS: failed to create OS thread (Cannot create OS thread. Did you compile with -threaded?)`

**Cause:** Your target sets `threaded = False` on `hs_binary` or `hs_test`, linking GHC's single-threaded runtime (`rtsSupportsBoundThreads == False`).

**Fix:** Remove `threaded = False`, or set `threaded = True` (the default on both `hs_binary` and `hs_test`).

### 7. `Boot package '...' not found in GHC 9.10.3 global package DB`

**Cause:** An [`hs_toolchain_library`](../reference/rules.md#hs_toolchain_library) target requests a package name that isn't part of the active GHC release's boot package database. For example, `file-io` is a boot package in GHC `9.12.4` but not in GHC `9.10.3`, while third-party packages such as `aeson` or `network` come from Hackage rather than `@hs_boot`.

**Fix:** Check the list of available boot packages printed in the error message, or pin the package with `//tools/lock:lock` and depend on `@hackage//:<pkg>`.

### 8. `Unsupported Cabal build-type 'Custom' for package '...' (only 'Simple' and 'Configure' are supported)`

**Cause:** `rules_haskell` builds Cabal `build-type: Simple` packages, Autoconf `build-type: Configure` packages (`network`, `unix-time`, `old-time`), and `cabal-doctest`-only `build-type: Custom` packages (`xml-conduit`, which `//tools/lock:lock` normalizes to `Simple`). It intentionally doesn't compile or run arbitrary `Setup.hs` programs during builds—which affects under 1% of Hackage (see [How Cabal `build-type` and `Setup.hs` work](hackage.md#setup-hs-and-build-types)).

**Fix:**

1. Inspect the package's `Setup.hs` file in its Hackage source archive to see what custom step it performs.
2. If `Setup.hs` only computes C compiler flags, preprocessor defines, or system library links, adjust the package's `"build_type"` or supply those settings with `hackage.override` or a workspace `hs_library` target.
3. If `Setup.hs` generates `.hs` or `.h` files at build time, unpack or vendor the package and run the generator in a Bazel [`genrule`](https://bazel.build/reference/be/general#genrule) feeding an `hs_library` target.

### 9. Type error on a local `let` or `where` helper after setting `default_language = "GHC2024"`

**Cause:** `GHC2024` enables `MonoLocalBinds`, which stops GHC from automatically generalizing polymorphic types on local `let` and `where` bindings when extensions such as `GADTs` or `TypeFamilies` are active.

**Fix:** Add an explicit type signature to the local `let` or `where` helper, or keep `default_language = "GHC2021"` on that target (see [Language, RTS, runfiles, and Template Haskell](language-rts-runfiles-th.md)).

### 10. Custom terminal name (`TERM`) fails to initialize `terminfo`

**Cause:** `rules_haskell` links GHC and the `terminfo` boot package against a self-contained C11 `libtinfo` reader that searches `$TERMINFO`, `$HOME/.terminfo`, `$TERMINFO_DIRS`, and `/usr/share/terminfo`, falling back to built-in capability sets (`xterm-256color`, `xterm`, `tmux`, `screen`, `vt100`, `ansi`, `linux`, and `dumb`) when no terminfo files exist on disk. If `$TERM` is set to an uncommon custom name without a compiled `term(5)` entry in those directories, `setupTermFromEnv` raises `SetupTermError`.

**Fix:** Set `TERMINFO` (or `TERMINFO_DIRS`) to the directory containing your compiled `term(5)` file, or set `TERM=xterm-256color` inside minimal containers that don't include `/usr/share/terminfo`.
