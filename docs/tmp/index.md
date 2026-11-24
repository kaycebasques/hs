---
title: "rules_haskell documentation"
description: "Bazel 9 ruleset for Haskell using Bzlmod to build libraries, executables, tests, C bindings, and Hackage packages."
section: overview
nav_title: "Overview"
order: 1
---

`rules_haskell` is a Bazel 9 ruleset for Haskell ([`bazel_compatibility = [">=9.0.0"]`](https://bazel.build/rules/lib/globals/module#module)) configured through [Bzlmod](https://bazel.build/external/overview) ([`MODULE.bazel`](https://bazel.build/external/module)). Use it to compile Haskell libraries, executables, tests, interactive `ghci` REPL targets, C and C++ bindings, Haddock API documentation, and third-party Hackage packages inside isolated Bazel [sandboxes](https://bazel.build/docs/sandboxing).

On Linux (`x86_64` and `arm64`), the only host tool you need is [Bazelisk](https://github.com/bazelbuild/bazelisk). `rules_haskell` downloads SHA-256-pinned GHC binary distributions into Bazel's cache, so you don't need Nix, legacy [`WORKSPACE`](https://bazel.build/external/overview#workspace-system) files, Python wrapper scripts, or host installations of `ghc`, `cabal`, `stack`, `gcc`, `clang`, or system C `-dev` libraries.

> **Tip:** Follow [Quickstart](guide/quickstart.md) to set up a workspace and build a Haskell library, executable, and test target in a few minutes, read [Showcase: `examples/size`](guide/showcase-size.md) for a walkthrough of a 69-package HTTPS sitemap crawler, or jump straight to the [Rules reference](reference/rules.md).

## What's supported, planned, and out of scope {#project-scope}

Before adopting `rules_haskell`, check what works today, what's planned, and what's intentionally out of scope.

### Supported today

- **Build, test, REPL, and documentation rules:** [`hs_library`](reference/rules.md#hs_library), [`hs_binary`](reference/rules.md#hs_binary), [`hs_test`](reference/rules.md#hs_test), [`hs_repl`](reference/rules.md#hs_repl), [`hs_haddock`](reference/rules.md#hs_haddock), [`hs_toolchain_library`](reference/rules.md#hs_toolchain_library), and [`hs_cabal_library`](reference/rules.md#hs_cabal_library), plus standalone `@rules_haskell//tools/ghci` and `@rules_haskell//tools/ghci:runghc` targets.
- **Interactive interpreter execution (`ghci`, `-e`, `runghc`, and `ghc-iserv-dyn`):** Run [`bazel run`](https://bazel.build/docs/user-manual#running-executables) on an [`hs_repl`](reference/rules.md#hs_repl) target to open an interactive `ghci` session preloaded with workspace modules. Sessions support live `:reload` on edited files, `:break`/`:continue` bytecode debugging, C/C++ FFI, `CApiFFI`, Template Haskell, `data` [runfiles](https://bazel.build/extending/rules#runfiles), `-e` expression evaluation, `.ghci` scripts, `-fexternal-interpreter`, and `terminfo` terminal capabilities (`haskeline` arrow-key history, Tab completion, and 256-color output via a self-contained C11 `libtinfo` reader with built-in `xterm-256color`/`vt100`/`dumb` fallbacks).
- **Platforms and GHC versions:** Linux `x86_64` (tested in CI on bare Debian 12, Ubuntu 24.04, and Rocky Linux 9 containers with no host compilers installed) and Linux `arm64`, with official GHC `9.10.3` (default) and `9.12.4` binary distributions.
- **Language and compiler features:**
  - `Haskell98`, `Haskell2010`, `GHC2021` (default), and `GHC2024` language editions (see [Language, RTS, runfiles, and Template Haskell](guide/language-rts-runfiles-th.md) for why `GHC2021` is the default and how to opt into `GHC2024`).
  - Per-target GHC extensions (`default_extensions`) and compiler flags (`ghc_opts`), private library modules (`hidden_modules`), `.hs-boot` files for mutually recursive modules, and `.lhs` literate Haskell sources.
  - Single-threaded and multi-core (`-threaded`) GHC runtime configurations, plus Bazel `data` runfiles accessible at both compile time and runtime.
  - Template Haskell compile-time code generation (`TemplateHaskellQuotes` and `TemplateHaskell`), including splices imported across separate libraries and compile-time file reading such as `file-embed`.
- **C and C++ interoperability:** Standard `foreign import ccall` and header-checked `CApiFFI` bindings, inline `c_sources` (C, C++, and assembly), `cc_deps` ([`cc_library`](https://bazel.build/reference/be/c-cpp#cc_library) targets from your repository or the [Bazel Central Registry](https://bazel.build/external/registry#bazel-central-registry)), and compatibility with any Bazel [`cc_toolchain`](https://bazel.build/reference/be/c-cpp#cc_toolchain) (`hermetic_cc_toolchain` `zig cc`, `toolchains_llvm`, GCC, or Clang).
- **Third-party Hackage and Stackage packages:** Generate lockfiles with [`@rules_haskell//tools/lock:lock`](reference/lock-cli.md) and build packages lazily via [`hackage.from_lock`](reference/extensions-and-providers.md#hackage-from_lock) and [`hackage.override`](reference/extensions-and-providers.md#hackage-override), supporting:
  - Cabal `build-type: Simple` packages (over 95% of Hackage, where `Setup.hs` only calls Cabal's standard `defaultMain`).
  - Cabal `build-type: Configure` packages that run autoconf `./configure` scripts to probe C headers and constants (such as `network`, `unix-time`, and `old-time`).
  - Cabal `build-type: Custom` packages whose `Setup.hs` only existed for `cabal-doctest` test setup (automatically converted to `Simple` during lockfile generation, such as `xml-conduit`).
  - C-only Cabal packages (`zlib-clib`, `libyaml-clib`), internal sublibraries and Cabal 3.0 public sublibraries, `reexported-modules`, generated `Paths_<pkg>` modules and compile-time `data-files`, `.hsc` C-binding templates (`hsc2hs`), and automatic source-bootstrapped `.x` (`alex`) lexer and `.y`/`.ly` (`happy`) parser generation.
- **API documentation:** Generate Haddock HTML pages, syntax-highlighted hyperlinked source views, QuickJump search indexes (`doc-index.json`), and cross-target `.haddock` interface linking with [`hs_haddock`](reference/rules.md#hs_haddock).

> **Note:** Every feature listed above has a standalone Bazel 9 workspace and test suite under [`examples/`](https://github.com/kaycebasques/rules_haskell/tree/main/examples) (`quickstart`, `repl`, `ghc_9_12`, `language_features`, `c_interop`, `llvm_toolchain`, `system_cc_toolchain`, `hackage`, `haddock`, and `size`) alongside unit and integration tests under [`tests/`](https://github.com/kaycebasques/rules_haskell/tree/main/tests).

### Not supported today — planned

- **macOS (`macos_arm64`, `macos_x86_64`) and Windows (`windows_x86_64`) execution:** Official GHC download URLs, SHA-256 digests, and multi-OS lockfile [`select()`](https://bazel.build/configure/attributes) branches are already generated, but macOS Mach-O shared-library staging and Windows `.exe` wrapper and action support aren't wired yet.
- **IDE setup (`haskell-language-server` / `hie.yaml`):** Automatic `hie.yaml` cradle generation for editor integration isn't implemented yet.
- **Static `musl` Linux builds (`linux_x86_64_musl`):** Opt-in static linking against `musl` libc for zero-glibc `FROM scratch` containers.
- **GHC profiling (`-prof`) and code coverage (`HPC`) build modes:** Building profiling archives (`.p_o`) and Haskell Program Coverage instrumentation.
- **`c2hs` FFI preprocessor and GHC compiler plugins (`-fplugin`):** Pre-compilation `.chs` hook expansion and loading external GHC compiler plugins.

### Out of scope (by design)

- **Arbitrary `build-type: Custom` `Setup.hs` scripts:** `rules_haskell` doesn't run packages (under 1% of Hackage) that execute bespoke Haskell programs inside `Setup.hs` to generate code during library compilation. Running `Setup.hs` collapses a package build into an opaque single-action wrapper that prevents per-file C and `hsc2hs` caching and blocks Bazel [`CcInfo`](https://bazel.build/rules/lib/providers/CcInfo) header and archive propagation. As a workaround, inspect what the script generates and supply flags or files via [`hackage.override`](reference/extensions-and-providers.md#hackage-override) or custom Bazel targets (see [Hackage and lockfiles](guide/hackage.md) and [Migration and troubleshooting](guide/troubleshooting-and-migration.md)).
- **Legacy Bazel `WORKSPACE` files and Bazel `< 9.0.0`:** `rules_haskell` uses Bzlmod (`MODULE.bazel`) exclusively.
- **Nix / `rules_nixpkgs` toolchains:** `rules_haskell` downloads SHA-256-pinned archives directly into Bazel's cache rather than reading `/nix/store` on your host, keeping local sandboxes and [remote execution](https://bazel.build/remote/rbe) workers consistent.
- **Bundling Python, Node.js, Java, or Protobuf rules inside `rules_haskell`:** Keeping `rules_haskell` free of foreign language runtimes keeps downstream `MODULE.bazel` graphs small. Protobuf or multi-language code generation belongs in separate companion rulesets.
- **GHCJS and WebAssembly compiler backends:** `rules_haskell` targets native Linux (and planned macOS/Windows) compilation rather than JavaScript or WebAssembly backends.

## New to Bazel rulesets or Haskell?

You don't need prior Bazel ruleset-authoring experience or Haskell and GHC background to read these docs. If any build or compiler concept feels unfamiliar, start with these primers:

- **[Bazel ruleset primer](internals/bazel-rules-primer.md)** — How Bazel rulesets work from first principles: consumer vs. ruleset `MODULE.bazel` files ([`dev_dependency = True`](https://bazel.build/rules/lib/globals/module#bazel_dep)), Bazel's [Loading, Analysis, and Execution phases](https://bazel.build/extending/concepts#evaluation-model), lazy Bzlmod package repositories, how rules pass structured metadata ([providers](https://bazel.build/extending/rules#providers)) and transitive sets ([`depset`s](https://bazel.build/extending/depsets)) between targets, directory outputs, host tool vs. target compilation configurations, and C/C++ library interoperability (`CcInfo`).
- **[Haskell and GHC primer](internals/haskell-and-ghc-primer.md)** — How Haskell compilation and packaging fit together: the roles of GHC, `.cabal` manifests, `Cabal-syntax`, Hackage, and Stackage; GHC's 41 built-in boot libraries; compiled `.a` archives, `.hi` compiler interface files, and relocatable package databases; why GHC invokes a C compiler and links `gmp` and `libtinfo`; `hsc2hs`, Alex, Happy, and `.hs-boot` files; Template Haskell; and Haddock.
- **[Anatomy of `MODULE.bazel` and dependency decisions](internals/dependencies.md#module-bazel-anatomy)** — Line-by-line plain-English walkthrough of every dependency in `MODULE.bazel`, `examples/size` (69 Hackage packages), and `//docs` (182 Hackage packages), with Go, Rust, and Python equivalents and what breaks without each dependency.

## How `rules_haskell` works

- **Pinned Linux GHC toolchains without Nix (`9.10.3` and `9.12.4`):** Extract official GHC binary distributions in [Starlark](https://bazel.build/rules/language) via [`hs.toolchain`](reference/extensions-and-providers.md#hs-toolchain) without running `./configure && make install` on your host. Because GHC's binaries embed relative ELF library search paths (`$ORIGIN`, the directory holding the binary itself), `rules_haskell` stages `libgmp.so.10` (built from Bazel Central Registry `@gmp`) and a self-contained C11 `libtinfo.so.6` terminfo library alongside GHC's libraries, so compiler and REPL actions don't need `LD_LIBRARY_PATH` or `patchelf`.
- **Portable Linux executables with statically linked GMP:** Link `libgmp.a` statically in [`hs_binary`](reference/rules.md#hs_binary) and [`hs_test`](reference/rules.md#hs_test) so your compiled executables dynamically depend only on standard Linux `glibc` libraries (`libc.so.6`, `libm.so.6`, `libdl.so.2`, `libpthread.so.0`). Binaries run in an empty environment (`env -i PATH=/nonexistent`) across Debian 12, Ubuntu 22.04 and 24.04, and Rocky Linux 9.
- **Compiled C11 compiler wrapper instead of Python:** A small compiled C11 program (`ghc_cc_wrapper`) adapts GHC, `hsc2hs`, and Cabal `./configure` flags for any Bazel C/C++ toolchain (`hermetic_cc_toolchain` `zig cc`, `toolchains_llvm`, GCC, or Clang) without pulling a Python runtime into compile actions.
- **Two-phase Hackage lockfiles and 5-stage Cabal builds:** Resolve Stackage snapshots into a deterministic `hackage.lock.json` file with [`//tools/lock:lock`](reference/lock-cli.md) (`@rules_haskell//tools/lock:lock`, built by `rules_haskell` itself using only GHC's built-in `Cabal-syntax` library). During builds, [`hackage.from_lock`](reference/extensions-and-providers.md#hackage-from_lock) reads that JSON in Starlark and compiles needed packages via [`hs_cabal_library`](reference/rules.md#hs_cabal_library) without executing `Setup.hs`.
- **GHC Haddock API documentation:** Run GHC's bundled `haddock` binary inside Bazel's sandbox with [`hs_haddock`](reference/rules.md#hs_haddock) to produce HTML module docs, clickable source code, and QuickJump (`doc-index.json`) search indexes—see the [Haddock API (`//tools/lock`)](haddock/lock/index.html) mounted in this site.
- **Small `MODULE.bazel` dependency graph:** `rules_haskell` declares four non-dev `MODULE.bazel` dependencies (`platforms`, `bazel_skylib`, `rules_cc`, and `gmp`), avoiding transitive Java, Python, Node.js, or Protobuf dependencies in downstream workspaces.

## End-to-end workflow

This diagram traces how a workspace moves from `MODULE.bazel` setup to compiled libraries, executables, tests, REPL sessions, and Haddock documentation:

```mermaid
flowchart LR
    subgraph Setup["1. Module setup (MODULE.bazel)"]
        TC["hs.toolchain(ghc_version = '9.10.3')"] --> BOOT["@hs_boot + @hs_toolchains"]
        LOCKCLI["bazel run @rules_haskell//tools/lock:lock"] --> LOCKJSON["hackage.lock.json"]
        LOCKJSON --> HACK["hackage.from_lock(...) -> @hackage"]
    end

    subgraph Build["2. Build, test, and docs (BUILD.bazel)"]
        BOOT --> LIB["hs_library"]
        HACK --> LIB
        CC["cc_library / c_sources"] --> LIB
        LIB --> BIN["hs_binary (static libgmp.a)"]
        LIB --> TEST["hs_test (sandboxed test)"]
        LIB --> REPL["hs_repl (interactive ghci)"]
        LIB --> DOC["hs_haddock (HTML + QuickJump)"]
    end
```

## Comparison with `tweag/rules_haskell`

| Dimension | `rules_haskell` | `tweag/rules_haskell` |
|---|---|---|
| **Bazel and module system** | Bazel 9+ (`>=9.0.0`), Bzlmod (`MODULE.bazel`) only | Targets Bazel 7 with legacy `WORKSPACE` support; incompatible with Bazel 8 and 9 |
| **Non-dev `MODULE.bazel` deps** | 4 modules: `platforms`, `bazel_skylib`, `rules_cc`, `gmp` | Pulls `rules_java`, `protobuf`, `abseil-cpp`, `rules_proto`, `rules_nodejs`, `aspect_rules_js`, `rules_python`, `rules_sh` |
| **Linux GHC provisioning** | Starlark archive extraction + staged `@gmp` and C11 `libtinfo`; works on remote execution workers | Bindist mode runs host `./configure && make install` (needs host `libgmp-dev`/`libtinfo`); sandboxed mode relies on `rules_nixpkgs` (`/nix/store`) |
| **C compiler adapter** | Compiled C11 binary (`ghc_cc_wrapper`), no Python dependency | Python script (`cc_wrapper.py.tpl`), adding `rules_python` to compile and link actions |
| **Third-party Hackage builds** | 5-stage [`hs_cabal_library`](reference/rules.md#hs_cabal_library) (`Simple` and `Configure`; arbitrary `Custom` `Setup.hs` out of scope) | Single Python wrapper (`cabal_wrapper.py`) running `runghc Setup.hs` (supports `Custom` `Setup.hs`, at the cost of per-file caching) |
| **Dependency pinning and boot libs** | [`//tools/lock:lock`](reference/lock-cli.md) (built with GHC boot `Cabal-syntax`) + automatic `@hs_boot` and `@hackage` targets | External `stack` binary via `stack_snapshot` + manual `haskell_toolchain_library` declarations |
| **Linux binary runtime deps** | Links `libgmp.a` statically; dynamic dependencies limited to base `glibc` (`libc`, `libm`, `libdl`, `libpthread`) | Links dynamic libraries with `rpath` entries on bindist toolchains (`fully_static_link = False`) |

For a detailed architectural comparison across `tweag/rules_haskell`, Buck2's Haskell prelude, Please Build, `haskell.nix`, and Cabal/Stack wrappers, see [Comparison with other rulesets](internals/rulesets-comparison.md).

## Documentation map

### User guide

1. **[Quickstart](guide/quickstart.md)** — Set up [`.bazelversion`](https://bazel.build/install/bazelisk), [`.bazelrc`](https://bazel.build/run/bazelrc), `MODULE.bazel`, and [`BUILD.bazel`](https://bazel.build/concepts/build-files) to compile and test a library and executable with [`hs_library`](reference/rules.md#hs_library), [`hs_binary`](reference/rules.md#hs_binary), and [`hs_test`](reference/rules.md#hs_test).
2. **[Hackage and lockfiles](guide/hackage.md)** — Pin Stackage packages with [`//tools/lock:lock`](reference/lock-cli.md), configure [`hackage.from_lock`](reference/extensions-and-providers.md#hackage-from_lock) and [`hackage.override`](reference/extensions-and-providers.md#hackage-override), use sublibraries, and see how `Setup.hs` (`Simple`, `Configure`, and `Custom`) works.
3. **[C FFI and toolchains](guide/c-interop-and-toolchains.md)** — Call C code via `ForeignFunctionInterface` and `CApiFFI`, link `cc_library` targets through `cc_deps` or inline `c_sources`, and pair `rules_haskell` with `hermetic_cc_toolchain`, `toolchains_llvm`, or system C toolchains.
4. **[Language, RTS, runfiles, and Template Haskell](guide/language-rts-runfiles-th.md)** — Configure `GHC2021` vs. `GHC2024`, interactive `ghci` REPL ([`hs_repl`](reference/rules.md#hs_repl) and `@rules_haskell//tools/ghci`), `hidden_modules`, `.hs-boot` mutual recursion, GHC runtime threading, Bazel `data` runfiles, Template Haskell, and [`hs_haddock`](reference/rules.md#hs_haddock) API docs.
5. **[Showcase: `examples/size`](guide/showcase-size.md)** — Walkthrough of `examples/size`, a standalone 69-package HTTPS XML and gzip sitemap page counter with offline loopback HTTP tests, Haddock API docs (`//:size_haddock`), and Linux binary dependency checks.
6. **[Migration and troubleshooting](guide/troubleshooting-and-migration.md)** — Migration steps from `tweag/rules_haskell`, Cabal, and Stack, plus fixes for common build, `Setup.hs`, C header, and lockfile errors.

### API and CLI reference

- **[Rules reference](reference/rules.md)** — Attribute, output, and provider reference for [`hs_library`](reference/rules.md#hs_library), [`hs_binary`](reference/rules.md#hs_binary), [`hs_test`](reference/rules.md#hs_test), [`hs_repl`](reference/rules.md#hs_repl), [`hs_haddock`](reference/rules.md#hs_haddock), [`hs_toolchain_library`](reference/rules.md#hs_toolchain_library), [`hs_cabal_library`](reference/rules.md#hs_cabal_library), and [`hs_toolchain`](reference/rules.md#hs_toolchain).
- **[Extensions and providers](reference/extensions-and-providers.md)** — Reference for [Bzlmod extensions](https://bazel.build/external/extension) ([`hs`](reference/extensions-and-providers.md#hs), [`hackage`](reference/extensions-and-providers.md#hackage)), Starlark providers ([`HsPackageInfo`](reference/extensions-and-providers.md#hspackageinfo), [`HsLinkInfo`](reference/extensions-and-providers.md#hslinkinfo), [`HsHaddockInfo`](reference/extensions-and-providers.md#hshaddockinfo), [`HsReplInfo`](reference/extensions-and-providers.md#hsreplinfo), [`HsToolchainInfo`](reference/extensions-and-providers.md#hstoolchaininfo)), and `@rules_haskell//haskell:toolchain_type`.
- **[Lock generator CLI](reference/lock-cli.md)** — CLI flag and `hackage.lock.json` JSON schema reference for `@rules_haskell//tools/lock:lock`, plus generated [Haddock API (`//tools/lock`)](haddock/lock/index.html) (`//tools/lock:lock_haddock`).

### Internals and architecture

- **[Bazel ruleset primer](internals/bazel-rules-primer.md)** — Guide from Bazel user to ruleset author: Loading, Analysis, and Execution phases, Bzlmod lazy hubs, providers and transitive sets, directory outputs, tool configurations, and `CcInfo` interop.
- **[Haskell and GHC primer](internals/haskell-and-ghc-primer.md)** — Guide to GHC, Cabal, Hackage, Stackage, boot libraries, `.hi` interfaces, RTS C linking, `gmp` and `libtinfo`, `hsc2hs`/Alex/Happy, Template Haskell, and Haddock.
- **[Architecture overview](internals/overview.md)** — Design goals, lessons from `tweag/rules_haskell` and Buck2's Haskell rules, phase boundaries, and repository layout.
- **[Comparison with other rulesets](internals/rulesets-comparison.md)** — Architectural comparison across `tweag/rules_haskell`, Buck2's `prelude/haskell` and `buck2-haskell`, Please Build, `haskell.nix`, and Cabal/Stack wrappers.
- **[Hermeticity and toolchain](internals/hermeticity.md)** — GHC binary archive sanitization, relative shared-library staging, the self-contained C11 `libtinfo.so.6` / `libtinfo.a` terminfo reader, static GMP linking, and `ghc_cc_wrapper`.
- **[Providers and action graph](internals/providers-and-actions.md)** — Direct vs. transitive provider split, `-hide-all-packages` visibility enforcement, relocatable package databases, Template Haskell shared-object isolation, interactive `hs_repl` staging, and Haddock actions.
- **[Hackage and Cabal pipeline](internals/ecosystem-and-hackage.md)** — `Cabal-syntax` multi-platform evaluation, lazy hub and package repositories, and the 5-stage [`hs_cabal_library`](reference/rules.md#hs_cabal_library) [action graph](https://bazel.build/extending/rules#actions).
- **[Cross-OS and platforms](internals/cross-os-and-platforms.md)** — Multi-architecture Linux support, `deb10` glibc vs. `alpine3_12` musl trade-offs, and implementation plans for macOS and Windows.
- **[Hakyll and Haddock docs](internals/docs-engine.md)** — How this documentation site is built by `rules_haskell` itself using Hakyll and GHC Haddock.
- **[Dependency decisions](internals/dependencies.md)** — Engineering record of adopted and rejected dependencies, along with the conditions that justify reconsidering each choice.

## Platform support matrix

| Platform key | GHC `9.10.3` and `9.12.4` bindist metadata | Status |
|---|---|---|
| `linux_x86_64` | Wired in `haskell/private/ghc_versions.bzl` (`deb10` glibc) | **Supported and CI-tested** (Debian 12, Ubuntu 24.04, Rocky Linux 9) |
| `linux_arm64` | Wired in `haskell/private/ghc_versions.bzl` (`deb10` glibc) | **Supported** (active in `SUPPORTED_PLATFORMS`) |
| `macos_arm64` | Official URL + SHA-256 cataloged; lockfile `select()` active | Planned (Mach-O `@loader_path` staging and linker flags) |
| `macos_x86_64` | Official URL + SHA-256 cataloged; lockfile `select()` active | Planned (Mach-O `@loader_path` staging and linker flags) |
| `windows_x86_64` | Official URL + SHA-256 cataloged | Planned (`.exe` layout and Win32 `cc_wrapper`) |
| `linux_x86_64_musl` | `alpine3_12-linux-static-int_native` cataloged | Planned opt-in flavor for zero-glibc `FROM scratch` containers |
