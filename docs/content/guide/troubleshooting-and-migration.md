---
title: "Migration & Troubleshooting"
description: "Migrate projects from tweag/rules_haskell, Cabal, or Stack to rules_hs and fix common build, Setup.hs, C header, and lockfile issues."
section: guide
nav_title: "Migration & Troubleshooting"
order: 60
---

This guide covers migrating existing Haskell builds from `tweag/rules_haskell`, Cabal, and Stack to `rules_hs`, followed by causes and fixes for common build, `Setup.hs`, C toolchain, runfiles, and lockfile errors.

## Migrating from `tweag/rules_haskell`

`rules_hs` targets Bazel 9 with Bzlmod (`MODULE.bazel`), replacing `WORKSPACE` files, `rules_nixpkgs`, Python `cc_wrapper` scripts, and manual `haskell_toolchain_library` rules. (For a full comparison across `rules_hs`, `tweag/rules_haskell`, Buck2's Haskell rules, Please Build, and `haskell.nix`, see [Comparison with Other Rulesets](../internals/rulesets-comparison.md).)

Before starting a migration, check [What Is Supported, Planned, and Out of Scope](../index.md#project-scope): if your existing `rules_haskell` build currently depends on macOS or Windows execution, `-prof` profiling builds, `c2hs`, GHC plugins, or third-party Hackage packages with arbitrary `build-type: Custom` `Setup.hs` code generators, note that the first four are planned (not yet wired) and arbitrary `Custom` `Setup.hs` execution is out of scope (see Troubleshooting item 8 below for workarounds).

### Concept and Rule Mapping

| `tweag/rules_haskell` | `rules_hs` | Key Differences |
|---|---|---|
| `WORKSPACE` + `rules_haskell_dependencies()` | `MODULE.bazel` (`bazel_compatibility = [">=9.0.0"]`) | Uses Bzlmod exclusively; delete `WORKSPACE` and `WORKSPACE.bzlmod` |
| `haskell_register_ghc_bindists()` / `haskell_register_ghc_nixpkgs()` | [`hs.toolchain`](../reference/extensions-and-providers.md#hs-toolchain) + `register_toolchains("@hs_toolchains//:all")` | Pinned Linux GHC archives (`9.10.3` / `9.12.4`) without Nix or host `./configure` |
| `haskell_toolchain_library(name = "base")` | `@hs_boot//:base` or `@hackage//:base` | Generated automatically for all 41 GHC boot libraries |
| `stack_snapshot(...)` (`@stackage//:pkg`) | [`//tools/lock:lock`](../reference/lock-cli.md) + [`hackage.from_lock`](../reference/extensions-and-providers.md#hackage-from_lock) (`@hackage//:pkg`) | Committed `hackage.lock.json`; no host `stack` binary at build time; 5-stage [`hs_cabal_library`](../reference/rules.md#hs_cabal_library) instead of `Setup.hs` |
| `haskell_library` | [`hs_library`](../reference/rules.md#hs_library) | Defaults to `GHC2021`; separates `deps` and `cc_deps`; uses `hs_source_dirs` instead of `src_strip_prefix` |
| `haskell_binary` | [`hs_binary`](../reference/rules.md#hs_binary) | Links `libgmp.a` statically; defaults to `threaded = True` and `main_module = "Main"` |
| `haskell_test` | [`hs_test`](../reference/rules.md#hs_test) | Same attributes as [`hs_binary`](../reference/rules.md#hs_binary) |
| `haskell_repl` / `@rules_haskell//tools/ghci` | [`hs_repl`](../reference/rules.md#hs_repl) / `@rules_hs//tools/ghci` | Loads workspace targets into GHCi bytecode (`interpret_deps = True`, `:reload`, `:break`) and external packages from `.pkgdb/dyn/`; `@rules_hs//tools/ghci:runghc` runs standalone scripts |
| `haskell_doc` | [`hs_haddock`](../reference/rules.md#hs_haddock) | Runs GHC's bundled `haddock` inside Bazel's sandbox with hyperlinked source and QuickJump (`doc-index.json`) |
| `ghcopts = [...]` | `ghc_opts = [...]` | Snake-case attribute names (`ghc_opts`, `cpp_options`, `cc_options`) |
| `src_strip_prefix = "src"` | `hs_source_dirs = ["src"]` | Matches Cabal's `hs-source-dirs` list (supports multiple source roots) |
| `extra_srcs = [...]` (for CPP headers / TH files) | `hdrs = [...]` (compile-time headers) or `data = [...]` (TH and runtime files) | `hdrs` exposes C/CPP headers; `data` stages files into both the TH compile sandbox (`file-embed` / `runIO`) and runtime runfiles |
| `compiler_flags_select` | Standard Bazel `select({...})` on `ghc_opts` / `deps` / `srcs` | Standard Bazel configurable attributes work on all rules |

### 5-Step Migration Checklist

1. **Upgrade `.bazelversion` to `>= 9.0.0`** (for example, `9.3.3`) and remove legacy `WORKSPACE`, `WORKSPACE.bazel`, and `WORKSPACE.bzlmod` files.
2. **Replace `MODULE.bazel` toolchain setup** with [`hs.toolchain`](../reference/extensions-and-providers.md#hs-toolchain) (plus `hermetic_cc_toolchain`, `toolchains_llvm`, or your existing Linux `cc_toolchain` — see [C FFI & Toolchains](c-interop-and-toolchains.md)). Remove `rules_nixpkgs` and manual `haskell_toolchain_library` targets.
3. **Replace `stack_snapshot` with `hackage.lock.json`**: Run `bazel run @rules_hs//tools/lock:lock -- --snapshot lts-24.67 --package ... --output "$PWD/hackage.lock.json"` and load it via [`hackage.from_lock`](../reference/extensions-and-providers.md#hackage-from_lock) in `MODULE.bazel`.
4. **Update `BUILD.bazel` loads and attribute names**:
   - Change `load("@rules_haskell//haskell:defs.bzl", ...)` to `load("@rules_hs//hs:defs.bzl", "hs_binary", "hs_haddock", "hs_library", "hs_test")`.
   - Rename `ghcopts` -> `ghc_opts`, `src_strip_prefix` -> `hs_source_dirs`, and `@stackage//:` -> `@hackage//:`.
   - Note that [`hs_library`](../reference/rules.md#hs_library), [`hs_binary`](../reference/rules.md#hs_binary), and [`hs_test`](../reference/rules.md#hs_test) default to `default_language = "GHC2021"` and `threaded = True`. If older code requires `Haskell2010` semantics, set `default_language = "Haskell2010"`.
5. **List all directly imported packages in `deps`**: Because `rules_hs` compiles with `-hide-all-packages` and passes `-package-id` only for direct `deps`, add any directly imported boot or Hackage packages to each target's `deps` list.

---

## Migrating from Cabal or Stack

Each field in a `.cabal` or `package.yaml` component maps directly to an attribute in `BUILD.bazel`:

| `.cabal` Stanza Field | `rules_hs` Attribute (`hs_library` / `hs_binary` / `hs_test`) |
|---|---|
| `exposed-modules` + `other-modules` | `srcs` (list `.hs`, `.lhs`, and `.hs-boot` files) + `hidden_modules` (for `other-modules` in [`hs_library`](../reference/rules.md#hs_library)) |
| `main-is` + `-main-is` | Include main `.hs` file in `srcs`; set `main_module` if the entry module is not `Main` |
| `build-depends` | `deps = ["@hackage//:...", ":local_lib"]` |
| `hs-source-dirs` | `hs_source_dirs = ["src"]` |
| `default-language` | `default_language = "GHC2021"` (or `"Haskell2010"`, `"Haskell98"`, `"GHC2024"`) |
| `default-extensions` | `default_extensions = ["OverloadedStrings", "LambdaCase"]` |
| `ghc-options` | `ghc_opts = ["-Wall", "-O2"]` (omit `-threaded` on executables; use `threaded = True` instead) |
| `cpp-options` | `cpp_options = ["-DFOO=1"]` |
| `c-sources` / `cc-options` / `include-dirs` | `c_sources`, `cc_options`, `include_dirs`, `hdrs` |
| `extra-libraries` / `pkgconfig-depends` | `cc_deps = ["@zlib//:zlib"]` (or bundled-C flags in [`//tools/lock:lock`](../reference/lock-cli.md)) |
| `data-files` | `data = [...]` accessed via `RUNFILES_DIR` and `TEST_SRCDIR` (see [Language, RTS, Runfiles & Template Haskell](language-rts-runfiles-th.md)) |

---

## Troubleshooting Common Issues

### 1. `Could not load module '...' — It is a member of the hidden package '...'`

**Cause**: `rules_hs` passes `-hide-all-packages` to GHC and exposes only **direct** `deps` via `-package-id`. Your `.hs` file imports a module from a transitive dependency that is not listed in the target's own `deps`.

**Fix**: Add that package to the target's `deps` list in `BUILD.bazel` (for example, `"@hs_boot//:bytestring"` or `"@hackage//:bytestring"`).

---

### 2. `undefined symbol: memfd_create` / `statx` or `fatal error: 'sys/single_threaded.h' file not found` with `hermetic_cc_toolchain`

**Cause**: `@zig_sdk//toolchain/...` was registered without listing the `gnu.2.32` toolchains ahead of the wildcard, causing Bazel to pick `gnu.2.17` alphabetically.

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

**Cause**: `bazel run` executes binaries inside Bazel's temporary runfiles directory rather than your shell's current directory, so a relative `--output hackage.lock.json` writes inside the runfiles tree.

**Fix**: Pass an absolute path using `$PWD`:

```bash
bazel run @rules_hs//tools/lock:lock -- \
  --snapshot lts-24.67 \
  --package aeson \
  --output "$PWD/hackage.lock.json"
```

---

### 4. Missing System C Header (`zlib.h`, `pcre.h`, `sqlite3.h`) When Building a Hackage Package

**Cause**: Inside Bazel's sandbox, host `/usr/include` headers and `pkg-config` files are absent or ignored by sandboxed C toolchains.

**Fix**: Use one of the two patterns described in [Hackage & Lockfiles](hackage.md):
- **Enable a bundled-C Cabal flag** in [`//tools/lock:lock`](../reference/lock-cli.md), such as `--flag zlib:bundled-c-zlib=true --flag zlib:pkg-config=false`.
- **Attach a BCR `cc_library`** in `MODULE.bazel` using [`hackage.override`](../reference/extensions-and-providers.md#hackage-override):
  ```starlark
  hackage.override(
      package = "zlib",
      extra_cc_deps = ["@zlib//:zlib"],
  )
  ```

---

### 5. `openFile: does not exist` When Reading `data` Files in `hs_test` or `hs_binary`

**Cause**: Either `--enable_runfiles` is missing from `.bazelrc`, or the Haskell code opens a bare relative path without checking `RUNFILES_DIR` / `TEST_SRCDIR` and `TEST_WORKSPACE`.

**Fix**:
1. Add `common --enable_runfiles` to `.bazelrc`.
2. Resolve runfile paths via `RUNFILES_DIR` / `TEST_SRCDIR` and `TEST_WORKSPACE` (which defaults to `"_main"` under Bzlmod). See the `resolveRunfile` helper in [Language, RTS, Runfiles & Template Haskell](language-rts-runfiles-th.md).

---

### 6. `forkOS: failed to create OS thread (Cannot create OS thread. Did you compile with -threaded?)`

**Cause**: `threaded = False` was set on [`hs_binary`](../reference/rules.md#hs_binary) or [`hs_test`](../reference/rules.md#hs_test), linking GHC's single-threaded runtime (`rtsSupportsBoundThreads == False`).

**Fix**: Remove `threaded = False` (or set `threaded = True`, which is the default on both [`hs_binary`](../reference/rules.md#hs_binary) and [`hs_test`](../reference/rules.md#hs_test)).

---

### 7. `Boot package '...' not found in GHC 9.10.3 global package DB`

**Cause**: An [`hs_toolchain_library`](../reference/rules.md#hs_toolchain_library) target requested a package name that is not part of the active GHC release's boot package database (for example, `file-io` is a boot package in GHC `9.12.4` but not in GHC `9.10.3`, whereas third-party packages like `aeson` or `network` come from Hackage rather than `@hs_boot`).

**Fix**: Check the list of available boot packages printed in the error message, or pin the package via [`//tools/lock:lock`](../reference/lock-cli.md) and depend on `@hackage//:<pkg>`.

---

### 8. `Unsupported Cabal build-type 'Custom' for package '...' (only 'Simple' and 'Configure' are supported)`

**Cause**: `rules_hs` builds Cabal `build-type: Simple` packages, autoconf `build-type: Configure` packages (`network`, `unix-time`, `old-time`), and `cabal-doctest`-only `build-type: Custom` packages (`xml-conduit`, automatically normalized to `Simple` by [`//tools/lock:lock`](../reference/lock-cli.md)). It intentionally does not compile and run arbitrary `Setup.hs` programs during builds (under 1% of Hackage; see [How Cabal `build-type` and `Setup.hs` Work](hackage.md#setup-hs-and-build-types)).

**Fix**:
1. Inspect the package's `Setup.hs` file in its Hackage source archive to see what custom step it performs.
2. If `Setup.hs` only computes C compiler flags, preprocessor defines, or system library links, change the package's `"build_type"` or supply those settings via [`hackage.override`](../reference/extensions-and-providers.md#hackage-override) / a workspace `hs_library` target.
3. If `Setup.hs` generates `.hs` or `.h` files at build time, unpack or vendor the package and run the generator in a Bazel `genrule` feeding an [`hs_library`](../reference/rules.md#hs_library) target.

---

### 9. Type Error on a Local `let` or `where` Helper After Setting `default_language = "GHC2024"`

**Cause**: `GHC2024` enables `MonoLocalBinds`, which prevents GHC from automatically generalizing polymorphic types on local `let` and `where` bindings when extensions such as `GADTs` or `TypeFamilies` are active.

**Fix**: Add an explicit type signature to the local `let`/`where` helper binding, or keep `default_language = "GHC2021"` on that target (see [Language Editions (`GHC2021` vs. `GHC2024`)](language-rts-runfiles-th.md)).

---

### 10. Custom Terminal Name (`TERM`) Fails to Initialize `terminfo`

**Cause**: `rules_hs` links GHC and the `terminfo` boot package against a self-contained C11 `libtinfo` reader that searches `$TERMINFO`, `$HOME/.terminfo`, `$TERMINFO_DIRS`, and `/usr/share/terminfo` (and falls back to built-in `xterm-256color`, `xterm`, `tmux`, `screen`, `vt100`, `ansi`, `linux`, and `dumb` capability sets when no terminfo files exist on disk). If `$TERM` is set to an uncommon custom terminal name that has no compiled `term(5)` entry in those directories, `setupTermFromEnv` raises `SetupTermError`.

**Fix**: Set `TERMINFO` (or `TERMINFO_DIRS`) to the directory containing your custom compiled `term(5)` file, or set `TERM=xterm-256color` when running inside minimal containers without `/usr/share/terminfo`.
