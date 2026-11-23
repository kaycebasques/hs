---
title: "Dependency Decision Record"
description: "Complete evaluation of every adopted and rejected/deferred dependency across rules_hs, examples/size, and the Hakyll documentation engine, with concrete catalysts for change."
section: internals
nav_title: "Dependency Decisions"
order: 70
---

This document records every dependency evaluated across `rules_hs` (`MODULE.bazel`), its standalone example application `examples/size` (`examples/size/MODULE.bazel`), and its self-hosted documentation generator `//docs` (`docs/BUILD.bazel`, `docs/hackage.lock.json`) — covering both **adopted** dependencies and **not-adopted** (rejected or deferred) alternatives.

For every entry, we state:

- **What & Role**: the exact version, artifact, or architectural role evaluated.
- **Why** (or **Why Not Adopted**): the concrete technical findings from live prototyping and CI verification.
- **Catalysts**: the specific conditions (*"if X, Y, and Z changed..."*) that would trigger reconsidering an adopted dependency or promoting a rejected or deferred alternative to a supported option or default.

> **Note — New to Bazel Rulesets or Haskell? Companion Chapters:** If you have used Bazel as an end user (`BUILD.bazel` / `MODULE.bazel`) or have no prior Haskell/GHC background, this chapter defines every dependency and systems term in plain English before using it. For foundational primers and subsystem deep dives, see [Bazel Ruleset Primer](bazel-rules-primer.md), [Haskell & GHC Primer](haskell-and-ghc-primer.md), [Architecture Overview](overview.md), [Comparison with Other Rulesets](rulesets-comparison.md), [Hermeticity & Toolchain](hermeticity.md), [Providers & Action Graph](providers-and-actions.md), [Hackage & Cabal Pipeline](ecosystem-and-hackage.md), [Cross-OS & Platforms](cross-os-and-platforms.md), and [Hakyll & Haddock Docs](docs-engine.md).

### Core Ecosystem & Systems Terms Used in This Chapter

Before reading the summary table below, seven everyday definitions unpack the Bazel, Haskell, and Linux ELF terms that appear across all seven categories:

- **Bzlmod & BCR (Bazel Central Registry)**: **Bzlmod** is Bazel's built-in external module system configured in `MODULE.bazel`. The **BCR** (`registry.bazel.build`) is Bazel's public package index of reusable build modules (`bazel_dep`), analogous to Rust's crates.io or Go's module proxy.
- **Hackage & Stackage LTS**: **Hackage** (`hackage.haskell.org`) is Haskell's central open-source package server hosting `.tar.gz` source archives and `.cabal` package manifests. **Stackage LTS** (*Long-Term Support*) is a curated snapshot picking one mutually compatible version of ~3,000 Hackage packages that have been verified to compile and pass tests together under one specific GHC compiler version.
- **Boot libraries (`@hs_boot`)**: The 41 core Haskell libraries (`base`, `bytestring`, `text`, `containers`, `filepath`, `Cabal-syntax`, `template-haskell`, `terminfo`, etc.) that ship pre-compiled inside the official GHC compiler archive itself, before any third-party Hackage packages are downloaded.
- **Template Haskell (`TH`) & `ghc-iserv-dyn`**: **Template Haskell** is GHC's compile-time code generation system — Haskell functions marked with `$(...)` that GHC compiles and runs *while compiling your code* to generate syntax trees or embed files into a binary (comparable to Rust procedural macros). When GHC itself is dynamically linked, it executes those compile-time functions in a separate helper process (`ghc-iserv-dyn`) that loads compiled `.so` shared libraries via OS `dlopen`.
- **GMP (`libgmp`)**: The **GNU Multiple Precision Arithmetic Library**, a C and assembly library that implements unbounded arbitrary-precision integer arithmetic. GHC's `ghc-bignum` boot library uses `libgmp` to back Haskell's standard `Integer` type (which never overflows 64 bits, similar to Python's `int` or Go's `math/big.Int`).
- **Linux ELF linking (`PIC`, `soname`, `DT_NEEDED`, `RUNPATH`, `$ORIGIN`)**: On Linux, code inside a `.so` shared library must be compiled as **PIC** (*Position-Independent Code*, `-fPIC`) using relative memory offsets so the OS can map it at any address. Each `.so` embeds an ABI version name called a **`soname`** (such as `libgmp.so.10`); linking against that `.so` records its `soname` as a **`DT_NEEDED`** entry in the executable's ELF header. Before `main()` runs, Linux's dynamic loader (`ld-linux.so`) searches the executable's **`RUNPATH`** header to find each `DT_NEEDED` library, expanding the special token **`$ORIGIN`** to *"the directory containing this executable"* — allowing staged tools to locate `../lib/.../*.so` relative to themselves without `LD_LIBRARY_PATH` environment variables or binary-rewriting tools like `patchelf`.
- **Fetch-time execution / IFD (*Import From Derivation*)**: Having the build system download, compile, and execute external programs *while still loading the dependency graph* just to discover what build targets exist (a pattern known in Nix as Import From Derivation). Avoiding fetch-time execution by reading static committed JSON (`hackage.lock.json`) keeps `bazel query` and `bazel mod` fast, offline-capable, and deterministic.

---

## Executive Summary {#executive-summary}

| Category | Adopted | Not Adopted (Rejected / Deferred) | Primary Deciding Factor |
|---|---|---|---|
| **1. C/C++ Toolchains** *(dev & showcase; `rules_hs` itself is C-toolchain independent)* | `hermetic_cc_toolchain@4.3.0` (`zig cc`, `gnu.2.32`, dev-only in root) | Pigweed `pw_toolchain/host_clang`, `toolchains_llvm@1.13.0` + Debian sysroot, host GCC/Clang (`rules_cc` default) | BCR-native, single-module multi-arch Linux (`x86_64` + `arm64`) hermeticity with zero external sysroot maintenance; Pigweed is non-BCR/monolithic + `glibc 2.27` |
| **2. GHC Distribution & Version** | Official Haskell.org `deb10` glibc bindists, GHC `9.10.3` (`x86_64` + `aarch64`), pure-Starlark extraction + `$ORIGIN` staging | `alpine3_12-linux-static-int_native` (`musl`), `rules_nixpkgs` / Nix, GHC `9.12.4` / `9.14.1` as default | `x86_64` + `arm64` parity, dynamic TH + C FFI support, clean BCR `CcInfo` interop, RBE/BCR compatibility, Stackage LTS 24.x stability |
| **3. Native Runtime & Compiler Libraries** | BCR `gmp@6.3.0.bcr.5` (`libgmp.so.10` + static `libgmp.a`), in-tree 8-symbol `libtinfo.so.6` / `libtinfo.a` stub, GHC-bundled `libffi.so.8`/`libCffi.a` | Full BCR `ncurses` build, host `libgmp-dev` / `libtinfo5` (`apt install`) | Zero host C `-dev` libraries, base-glibc-only user binary `DT_NEEDED`, avoids building `ncurses`/`gawk` for 8 batch-unused terminal query symbols |
| **4. Bazel Rule Foundations & Action Wrappers** | `platforms@1.1.0`, `bazel_skylib@1.9.2`, `rules_cc@0.2.28`, dev-only `rules_shell@0.6.1`, native C11 `ghc_cc_wrapper` | `rules_python` + Python `cc_wrapper.py` / `cabal_wrapper.py`, legacy non-dev deps (`rules_java`, `protobuf`, `rules_nodejs`, `aspect_rules_js`, `rules_sh`, non-dev `stardoc`) | Minimal Bazel 9+ non-dev `MODULE.bazel` graph; zero Python runtime in build actions |
| **5. 3p Hackage Resolution & Build Pipeline** | Self-hosted boot-only [`//tools/lock:lock`](../reference/lock-cli.md) (`Cabal-syntax`) + Stackage LTS -> `hackage.lock.json` -> pure-Starlark [`hackage`](../reference/extensions-and-providers.md#hackage) + 5-stage [`hs_cabal_library`](../reference/rules.md#hs_cabal_library) | `stack_snapshot` (Stack CLI + YAML pinning), pure-Starlark `.cabal` parser, opaque `cabal-install` / `runghc Setup.hs` actions | Complete `.cabal` spec evaluation with zero host `cabal`/`stack`/`python`, `reproducible = True` Bzlmod eval, fine-grained parallel caching & `CcInfo` propagation |
| **6. Showcase App 3p Haskell Libraries** (`examples/size`, 69 Hackage + 41 boot pkgs on `lts-24.67`) | `xml-conduit` `1.10.1.0`, `http-client` `0.7.19` + `http-client-tls` `0.3.6.4` + `http-types` `0.12.6`, `zlib` `0.7.1.1` (`bundled-c-zlib=true` / `zlib-clib` `1.3.2`), `async` `2.2.6` | `xml`, `xeno`, `hexml`, `hexpat`, `hxt`, `xmlbf`; `http-conduit`, `req`, `wreq`, `http-client-openssl`; BCR `@zlib` default, system `libz.so.1`; raw `Control.Concurrent`, `ki`, `streamly` | Spec-compliant XML, pure-Haskell TLS (zero OpenSSL), zero host C libs (`zlib-clib`), structured `async` concurrency, compact 69-pkg closure |
| **7. Documentation Engine & API Docs** (`//docs` & [`hs_haddock`](../reference/rules.md#hs_haddock)) | **Vanilla Hakyll + Pandoc + Skylighting + Bundled GHC Haddock** (`docs/site.hs` + `hs/private/haddock.bzl`) | Bespoke Sphinx-like Pandoc AST DSLs, Emanote / Ema, Slick, raw Shake + Pandoc, standalone Haddock without Hakyll, non-Haskell SSGs (Sphinx, MkDocs, mdBook, Docusaurus) | Standard Haskell documentation tools: GitHub/Pandoc Markdown in Hakyll + GHC Haddock for `.hs` APIs; exercises `rules_hs` & cross-library TH (`file-embed`) with zero custom AST syntax and zero Python/Node/Rust toolchains |

---

## Anatomy of MODULE.bazel: Why Every Direct Dependency Exists {#module-bazel-anatomy}

When an application repository declares `bazel_dep(name = "rules_hs", version = "0.1.0")`, Bazel's module system (**Bzlmod**) distinguishes strictly between **runtime ruleset dependencies** (which become part of every downstream consumer's dependency graph) and **`dev_dependency = True` dependencies** (which exist *only* when developing, testing, or building documentation inside the `rules_hs` repository itself and are completely ignored by Bazel in downstream consumer workspaces; see [Bazel Ruleset Primer](bazel-rules-primer.md#ruleset-vs-consumer)).

Here is `rules_hs`'s complete root `MODULE.bazel` (`58` lines):

```starlark
module(
    name = "rules_hs",
    version = "0.1.0",
    bazel_compatibility = [">=9.0.0"],
)

# 1. Runtime ruleset closure (inherited by downstream consumers: ONLY 4 BCR modules)
bazel_dep(name = "platforms", version = "1.1.0")
bazel_dep(name = "bazel_skylib", version = "1.9.2")
bazel_dep(name = "rules_cc", version = "0.2.28")
bazel_dep(name = "gmp", version = "6.3.0.bcr.5")

# 2. Ruleset dev/test/docs closure (completely pruned for downstream consumers)
bazel_dep(name = "hermetic_cc_toolchain", version = "4.3.0", dev_dependency = True)
bazel_dep(name = "rules_shell", version = "0.6.1", dev_dependency = True)

cc_toolchains = use_extension(
    "@hermetic_cc_toolchain//toolchain:ext.bzl",
    "toolchains",
    dev_dependency = True,
)
use_repo(cc_toolchains, "zig_sdk")

register_toolchains(
    "@zig_sdk//toolchain:linux_amd64_gnu.2.32",
    "@zig_sdk//toolchain:linux_arm64_gnu.2.32",
    "@zig_sdk//toolchain/...",
    "@zig_sdk//libc_aware/toolchain/...",
    dev_dependency = True,
)

# Non-dev extension handle so @rules_hs//tools/lock:lock can resolve @hs_boot
# when run from a downstream workspace; root hs.toolchain(...) overrides 9.10.3.
hs = use_extension("//hs:extensions.bzl", "hs")
hs.toolchain(ghc_version = "9.10.3")
use_repo(hs, "hs_boot", "hs_toolchains")

register_toolchains(
    "@hs_toolchains//:all",
    dev_dependency = True,
)

# Dev-only 182-package Hackage lockfile for building //docs:site
hackage = use_extension(
    "//hs:extensions.bzl",
    "hackage",
    dev_dependency = True,
)
hackage.from_lock(
    name = "hackage",
    lockfile = "//docs:hackage.lock.json",
)
use_repo(hackage, "hackage")
```

```mermaid
flowchart TB
    CONSUMER["Downstream Consumer Workspace (bazel_dep rules_hs)"] --> RHS["rules_hs@0.1.0"]

    subgraph NonDev["Downstream Consumer Closure (4 Non-Dev BCR Modules)"]
        PLAT["platforms@1.1.0 (OS & CPU constraint labels)"]
        SKY["bazel_skylib@1.9.2 (bzl_library & unittest Starlark helpers)"]
        RCC["rules_cc@0.2.28 (CcInfo, cc_common, ghc_cc_wrapper, C FFI)"]
        GMP["gmp@6.3.0.bcr.5 (libgmp.so.10 for GHC + libgmp.a for user binaries)"]
        HSEXT["hs extension (@hs_boot + @hs_toolchains; root overrides default)"]
    end

    RHS --> PLAT
    RHS --> SKY
    RHS --> RCC
    RHS --> GMP
    RHS --> HSEXT

    subgraph DevOnly["Ruleset Dev / Test / Docs Closure (dev_dependency = True — Pruned Downstream)"]
        ZIG["hermetic_cc_toolchain@4.3.0 (@zig_sdk gnu.2.32 C/C++ compiler)"]
        SH["rules_shell@0.6.1 (sh_test targets in //tests/... & //docs/...)"]
        DOCSHACK["hackage.from_lock (//docs:hackage.lock.json — 182 Hackage pkgs)"]
    end

    RHS -. "dev_dependency = True (ignored when rules_hs is a dependency)" .-> ZIG
    RHS -. "dev_dependency = True" .-> SH
    RHS -. "dev_dependency = True" .-> DOCSHACK
```

### The 4 Non-Dev Runtime Dependencies (Inherited by Consumers)

#### 1. `platforms@1.1.0` — Standard OS & CPU Constraint Vocabulary

- **What it actually is**: A small, zero-code repository of standard Bazel `constraint_value` targets (`@platforms//os:linux`, `@platforms//os:macos`, `@platforms//os:windows`, `@platforms//cpu:x86_64`, `@platforms//cpu:arm64`). Think of `platforms` as Bazel's shared dictionary for hardware and operating systems: instead of one ruleset spelling 64-bit ARM as `"aarch64"` and another spelling it `"arm64"`, every ruleset points at `@platforms//cpu:arm64` so Bazel's toolchain resolver and `select()` expressions agree on the active host and target machines.
- **Exactly where `rules_hs` uses it**:
  - `hs/private/ghc_versions.bzl` attaches `exec_constraints` and `target_constraints` (`@platforms//os:*` and `@platforms//cpu:*`) to every GHC binary distribution entry, which `hs/extensions.bzl` emits into `@hs_toolchains//:BUILD.bazel` (`toolchain(exec_compatible_with = ..., target_compatible_with = ...)`).
  - `hs/private/hackage.bzl` (`_PLATFORM_CONFIGS`) generates `config_setting` targets inside each `@hackage__<pkg>/BUILD.bazel` using `@platforms//os:*` and `@platforms//cpu:*` to drive per-platform `select({...})` attributes (for instance, `crypton` compiling x86 AES-NI/PCLMUL SIMD C files on `linux_x86_64` versus portable C reference code on `linux_arm64`).
- **What breaks if you remove it**: Bazel fails immediately during Loading and Toolchain Resolution because `@hs_toolchains` and `@hackage__<pkg>` cannot resolve `@platforms//os:*` or `@platforms//cpu:*` labels.

#### 2. `bazel_skylib@1.9.2` — Starlark Standard Library & Analysis Testing

- **What it actually is**: Bazel's official pure-Starlark utility library for ruleset authors. Because Bazel's built-in Starlark dialect intentionally omits domain-specific build-rule packaging and test-assertion frameworks, `bazel_skylib` provides `bzl_library` (a rule for grouping `.bzl` files into dependency-checked Starlark libraries) and `unittest.bzl` (`analysistest` and `asserts` for testing rule providers and action command lines in memory without running compilers).
- **Exactly where `rules_hs` uses it**:
  - `hs/BUILD.bazel` and `hs/private/BUILD.bazel` load `@bazel_skylib//:bzl_library.bzl` to package `rules_hs`'s public (`providers`, `toolchain`, `defs`, `extensions`) and private (`ghc_versions_bzl`, `ghc_bindist_bzl`, `cabal_codegen_bzl`, `hackage_bzl`, `staged_ghc_bzl`, `actions_bzl`, `rules_bzl`) `.bzl` files with explicit dependency edges.
  - `tests/starlark/rules_analysis_test.bzl` loads `analysistest` and `asserts` from `@bazel_skylib//lib:unittest.bzl` to verify [`HsPackageInfo`](../reference/extensions-and-providers.md#hspackageinfo), [`HsLinkInfo`](../reference/extensions-and-providers.md#hslinkinfo), `CcInfo`, and `ghc` command-line flags in memory.
- **What breaks if you remove it**: Evaluating any target in `@rules_hs//hs/...` or `@rules_hs//hs/private/...` fails at the `load("@bazel_skylib//:bzl_library.bzl", ...)` statement, and Starlark analysis unit tests (`//tests/starlark/...`) cannot run.

#### 3. `rules_cc@0.2.28` — C/C++ Toolchain Discovery, Native C Compilation & `CcInfo`

- **What it actually is**: Bazel's official C and C++ ruleset (`cc_binary`, `cc_library`) and Starlark C-toolchain API (`CcInfo`, `cc_common`, `find_cc_toolchain`, `use_cc_toolchain`, `ACTION_NAMES`). If you come from Go or Java, seeing `rules_cc` inside a Haskell ruleset can look surprising. Unlike Go's self-contained `cmd/compile` and internal linker, **GHC delegates directly to a C toolchain at multiple stages** (see [Haskell & GHC Primer](haskell-and-ghc-primer.md#c-toolchain-and-rts)): GHC invokes the C preprocessor (`-pgmP`) for `{-# LANGUAGE CPP #-}`, the assembler (`-pgma`), the C/C++ compiler (`-pgmc`/`-pgmcxx`) for Foreign Function Interface (`CApiFFI`) wrapper stubs and inline C files, `ar` to pack static `.a` libraries, and the system C linker (`cc`/`ld`) to link Haskell `.o` files against GHC's C Runtime System (`libHSrts.a`), `libCffi.a`, `libgmp.a`, and `glibc`.
- **Exactly where `rules_hs` uses it**:
  - `hs/private/BUILD.bazel` uses `cc_binary` and `cc_library` to compile `rules_hs`'s own C11 support targets: `//hs/private:ghc_cc_wrapper` (`cc_wrapper.c`), `//hs/private:libtinfo.so.6` and `tinfo_stub_static` (`tinfo_stub.c`), and `//hs/private:rt_shims` (`rt_shims.c`).
  - `hs/private/staged_ghc.bzl` uses `find_cc_toolchain`, `ACTION_NAMES`, and `CcInfo` to link `@gmp//:gmp`'s position-independent archive (`libgmp.pic.a`) into `libgmp.so.10` and stage `libtinfo.a`.
  - `hs/private/actions.bzl`, `hs/private/rules.bzl`, `hs/private/cabal_library.bzl`, and `hs/private/haddock.bzl` use `use_cc_toolchain()`, `find_cc_toolchain()`, `cc_common.compile()`, `cc_common.create_linking_context_from_compilation_outputs()`, and `cc_common.merge_cc_infos()` (`CcInfo`) to discover the active C compiler, archiver, and sysroot, compile C/C++ sources inside [`hs_library`](../reference/rules.md#hs_library) and Stage 4 of [`hs_cabal_library`](../reference/rules.md#hs_cabal_library) (such as `zlib-clib`, `libyaml-clib`, and `crypton`), and propagate C headers (`install-includes`) and `cc_deps` archives into final binary linking and Template Haskell. (See [Bazel Ruleset Primer](bazel-rules-primer.md#cc-interop).)
- **What breaks if you remove it**: Nothing in `rules_hs` can compile or link: `ghc_cc_wrapper` and `libtinfo.so.6` cannot be built, `rules_hs` cannot locate `cc`/`ld`/`ar` or `--sysroot` flags for GHC, C FFI and C-bearing Hackage packages fail to compile, and `cc_deps` interoperability with `cc_library` disappears.

#### 4. `gmp@6.3.0.bcr.5` — Arbitrary-Precision Arithmetic (`libgmp.so.10` & `libgmp.a`)

- **What it actually is**: The GNU Multiple Precision Arithmetic Library (`libgmp`), written in C and assembly and packaged on the Bazel Central Registry as a native `cc_library` (`@gmp//:gmp`). In Haskell, the standard `Integer` type in `base` represents **unbounded arbitrary-precision integers** (computing `2 ^ 10000` never overflows, just like Python's `int` or Go's `math/big.Int`). Under the hood, GHC's `ghc-bignum` boot library implements `Integer` arithmetic by calling `libgmp`'s C routines (`__gmpn_*`). Because `ghc` itself is a Haskell program compiled against `ghc-bignum`, **both** the GHC compiler binary and every compiled user executable depend on `libgmp`. (See [Haskell & GHC Primer](haskell-and-ghc-primer.md#gmp-and-tinfo).)
- **Exactly where `rules_hs` uses it**:
  - `hs/private/ghc_bindist.bzl` wires `gmp = "@gmp//:gmp"` into `staged_ghc` inside each `@ghc_<ver>_<platform>` repository.
  - `hs/private/staged_ghc.bzl` extracts both the position-independent archive `libgmp.pic.a` and the plain static archive `libgmp.a` from `@gmp//:gmp[CcInfo]`:
    1. It links `libgmp.pic.a` into a shared library with `soname` `libgmp.so.10` (`HsLinkGmpShared`) staged inside `<libdir>/<arch>-linux-ghc-<ver>/`, where `ghc`, `ghc-pkg`, `hsc2hs`, `haddock`, and `ghc-iserv-dyn` load it automatically via their ELF `$ORIGIN` `RUNPATH` with zero host `libgmp10`.
    2. It symlinks `libgmp.a` into an isolated static-only directory `gmp_static/libgmp.a` (containing no `.so` file).
  - `hs/private/rules.bzl` passes `-optl-L<gmp_static_dir>` and `gmp_static_lib` into `HsLinkExecutable`, causing the linker to embed `libgmp.a` statically so user `hs_binary` and `hs_test` executables carry **zero** `libgmp.so.10` runtime dependency in their ELF `DT_NEEDED` headers.
- **What breaks if you remove it**: On any clean Linux machine or container without `apt install libgmp-dev`, `bin/ghc-9.10.3` fails to start (`error while loading shared libraries: libgmp.so.10: cannot open shared object file`) and linking any Haskell binary fails (`ld: cannot find -lgmp`).

> **Note — Why `hs = use_extension("//hs:extensions.bzl", "hs")` Is Non-Dev While `register_toolchains` Is Dev-Only:** In `MODULE.bazel`, `use_repo(hs, "hs_boot", "hs_toolchains")` is intentionally non-dev so that when a downstream consumer runs `bazel run @rules_hs//tools/lock:lock -- ...`, targets inside `@rules_hs//tools/lock` can resolve `@hs_boot//:Cabal-syntax` and `@hs_boot//:base`. Inside `hs/extensions.bzl`, `mod.is_root` takes precedence, so a consumer's own `hs.toolchain(ghc_version = "9.12.4")` cleanly overrides `rules_hs`'s `9.10.3` default. Meanwhile, `register_toolchains("@hs_toolchains//:all", dev_dependency = True)` is marked dev-only so `rules_hs` never registers toolchains implicitly unless the consumer explicitly calls `register_toolchains("@hs_toolchains//:all")`.

### The 3 Dev-Only Dependencies (`dev_dependency = True` — Pruned Downstream)

1. **`hermetic_cc_toolchain@4.3.0` (`@zig_sdk`)**: Downloads a self-contained Zig `0.15.2` Clang/LLD C/C++ cross-compiler (`gnu.2.32`) used to compile `rules_hs`'s own test suite, `//tools/lock:lock`, and `//docs:site` on bare Linux CI containers with zero host `gcc` or `clang`. Marked `dev_dependency = True` so downstream consumers are never forced to download Zig if they already use `toolchains_llvm`, an enterprise Remote Build Execution (RBE) Clang toolchain, or system GCC. Removing it breaks `bazel test //...` inside `rules_hs` on clean containers lacking a host C compiler.
2. **`rules_shell@0.6.1`**: Provides the Starlark `sh_test` rule (extracted out of core Bazel in Bazel 8/9) used in `tests/basic/BUILD.bazel`, `tests/rules/**/BUILD.bazel`, `tools/lock/BUILD.bazel`, and `docs/BUILD.bazel` (`elf_hermeticity_test`, `bzlmod_hygiene_test`, `lock_cli_test`, `site_test`). Marked `dev_dependency = True` because `rules_hs`'s public rules (`hs_library`, `hs_binary`, `hs_test`, `hs_haddock`) invoke `ctx.actions.run_shell` directly and never instantiate `sh_test` or `sh_binary` in consumer workspaces. Removing it breaks `load("@rules_shell//shell:sh_test.bzl", "sh_test")` when running `rules_hs`'s own test suite.
3. **`hackage` extension (`lockfile = "//docs:hackage.lock.json"`)**: Exposes the 182 pinned Hackage packages (`hakyll`, `pandoc`, `skylighting`, `tagsoup`, `network`, etc.) needed exclusively to build `//docs:site`, `//docs:serve`, and `//docs:link_check_test`. Marking it `dev_dependency = True` guarantees downstream consumers never parse `docs/hackage.lock.json` or collide with `rules_hs`'s internal `@hackage` hub (verified continuously by `//tests/rules:bzlmod_hygiene_test`). Removing it breaks `bazel build //docs:site` and `bazel test //docs/...`.

### How Bzlmod's Minimal Version Selection (MVS) Reconciles Versions

Most downstream workspaces *also* declare direct dependencies on `platforms`, `rules_cc`, or `bazel_skylib` in their own `MODULE.bazel`. How does Bazel avoid version conflicts?

Traditional package managers like `cabal`, Cargo, or `pip` run a **dependency version solver** (often called a **SAT solver**, because version constraints reduce to boolean satisfiability): they search through `>=` and `<` version ranges across hundreds of packages and backtrack whenever two libraries demand conflicting versions. By contrast, Bzlmod uses **Minimal Version Selection (MVS)** — the single-pass deterministic algorithm introduced by Go modules:

- Every `bazel_dep(name = "X", version = "V")` specifies the **minimum** version of `X` that module requires.
- Across the entire transitive module graph (after stripping all non-root `dev_dependency = True` edges), Bzlmod selects **one single version** per module: the **highest** minimum version requested by any active module in the graph (`max(all requested versions)`).
- **Concrete example**: `rules_hs` requests `platforms@1.1.0`, `bazel_skylib@1.9.2`, `rules_cc@0.2.28`, and `gmp@6.3.0.bcr.5`. If your application's `MODULE.bazel` declares `bazel_dep(name = "platforms", version = "1.0.0")` and `bazel_dep(name = "rules_cc", version = "0.2.30")`, Bzlmod deterministically resolves `platforms@1.1.0` (`max(1.1.0, 1.0.0)`) and `rules_cc@0.2.30` (`max(0.2.28, 0.2.30)`) in a single pass — with zero solver backtracking, zero network fetches of unselected intermediate versions, and zero `dev_dependency` leakage from `rules_hs`.

---

## 1. C/C++ Toolchains (Dev & Showcase Hermeticity) {#cc-toolchains}

> **Important — Architectural Boundary (C-Toolchain Independence):** `rules_hs` itself does not hardcode any specific C compiler. Every rule queries `@bazel_tools//tools/cpp:toolchain_type` through `rules_cc` (`find_cc_toolchain` + `cc_common`) and forwards any resolved `--sysroot` and `--target` flags into `ghc_cc_wrapper` (`hs/private/cc_wrapper.c`). Neither `hermetic_cc_toolchain` nor any other concrete C toolchain is a non-dev dependency of `rules_hs` (in `MODULE.bazel`, `hermetic_cc_toolchain` is strictly `dev_dependency = True`). Downstream consumers can register any compliant Linux `cc_toolchain`.

### Context: Why Haskell Cares About C Compilers, Sysroots & `zig cc`

If you have never built a Haskell compiler toolchain before, three pieces of background clarify the C-toolchain trade-offs below (see also [Haskell & GHC Primer](haskell-and-ghc-primer.md#c-toolchain-and-rts)):

1. **Why GHC shells out to C tools and links `glibc`**: GHC compiles Haskell modules into native object code (`.o`), but delegates C preprocessing (`-XCPP`), assembly, C Foreign Function Interface compilation (`c_sources` and Hackage `cbits/*.c` in packages like `crypton`, `zlib-clib`, `bitvec`, and `network`), `./configure` feature probes, `ar` static archiving, and final executable linking to the active C toolchain. Every Haskell binary links GHC's C Runtime System (`libHSrts.a` — garbage collector, lightweight user-space green-thread scheduler, `epoll` event manager), `libCffi.a`, and `libgmp.a` against Linux's C standard library (`glibc`: `libc.so.6`, `libm.so.6`, `libpthread.so.0`, `libdl.so.2`).
2. **What a Linux `sysroot` and `glibc` symbol versioning are**: On Linux, compiling or linking against the host machine's `/usr/include` and `/usr/lib/libc.so.6` stamps output binaries with that machine's `glibc` symbol versions (for example, `statx@GLIBC_2.28` or `arc4random@GLIBC_2.36`). A binary compiled against Ubuntu 24.04's host GCC (`glibc 2.39`) will fail to start on Debian 12 (`2.36`) or Rocky Linux 9 (`2.34`). A **sysroot** is a self-contained directory of C headers and stub libraries frozen at an explicit target `glibc` baseline so builds never read `/usr/include` from the build host, and produced binaries run cleanly on any Linux distribution at or newer than that baseline.
3. **What `zig cc` vs. sysroot tarballs (and CIPD) actually are**: Traditional hermetic LLVM toolchains (`toolchains_llvm` or Google Pigweed's `pw_toolchain`, which fetches Fuchsia/Chromium artifacts from Google's **CIPD** — *Chrome Infrastructure Package Deployment* — binary store) pair Clang + `lld` with a separate pre-built Linux sysroot tarball (~300–500 MB per CPU architecture). By contrast, **`zig cc`** (`hermetic_cc_toolchain`) bundles upstream Clang/LLD **plus** compact multi-version `glibc` header and stub-library definitions inside a single ~50 MB Zig SDK download — generating exact `glibc` stubs on demand for specific target baselines (such as `gnu.2.28` or `gnu.2.32`) across both `x86_64` and `arm64` without external sysroot tarballs.

### Adopted (Dev & Showcase)

#### `hermetic_cc_toolchain@4.3.0` (`zig cc`, glibc `gnu.2.32`)

- **What & Role**: BCR-hosted Zig-based hermetic C/C++ toolchain (Zig `0.15.2`), registered as `dev_dependency = True` in `MODULE.bazel` and directly in `examples/size/MODULE.bazel`, with `@zig_sdk//toolchain:linux_amd64_gnu.2.32` and `@zig_sdk//toolchain:linux_arm64_gnu.2.32` registered ahead of `@zig_sdk//toolchain/...`.
- **Why**:
  - **Single BCR module, zero external sysroot maintenance**: Provides hermetic `linux_x86_64` and `linux_arm64` C/C++ compilation and linking (plus optional `musl` targeting) with zero host `gcc`/`clang`/`libc-dev` and zero manually mirrored Debian sysroot tarballs.
  - **Exact glibc compatibility window (`gnu.2.32`)**: By default, `@zig_sdk//toolchain/...` selects `gnu.2.17` alphabetically, which fails to link GHC `deb10`'s `libCffi.a` (`undefined symbol: memfd_create`, glibc `2.27`; `statx`/`fcntl64`, glibc `2.28`). Pinning `gnu.2.32` satisfies both GHC `deb10` bindists (`glibc <= 2.28`) **and** BCR `gmp@6.3.0.bcr.5`'s `m4` build-tool dependency (which includes Zig's `<sys/single_threaded.h>`, requiring `glibc >= 2.32`), while produced binaries remain portable across Debian 12 (`2.36`), Ubuntu 22.04 (`2.35`) / 24.04 (`2.39`), and Rocky Linux 9 (`2.34`).
  - **Verified Hackage compatibility**: All specialized Hackage `cc-options` in `examples/size` (`bitvec` `-fopenmp-simd`, `crypton` `-std=gnu99 -DWITH_AESNI -DWITH_PCLMUL -DWITH_TARGET_ATTRIBUTES`, `primitive` `-ftree-vectorize -msse2`, `unix-time` `-fPIC`) compile cleanly.
  - **Quirks isolated in one wrapper**: All six verified `zig cc` <-> GHC mismatches (`-fno-PIC`, `-Wl,-h`, `.dyn_o`/`.p_o`, `--print-file-name`, `-Wno-unused-command-line-argument`, and `zig c++`'s `libcxx/include/stddef.h` ordering fixed via `-nostdinc++`) are handled once in `hs/private/cc_wrapper.c`.
  - **Ecosystem alignment**: Matches sibling Bazel 9 polyglot projects (such as the reference `size` multi-language repository).
- **Catalysts to reconsider or replace**:
  - If a lightweight BCR Clang/`lld` toolchain ships built-in, SHA-256-pinned multi-arch (`x86_64` + `arm64`) Linux glibc `>= 2.32` sysroots — eliminating both the `.bazelrc` `/tmp` cache mount (`HERMETIC_CC_TOOLCHAIN_CACHE_PREFIX=/tmp/zig-cc-cache` + `--sandbox_add_mount_pair=/tmp`) and the `zig cc` flag rewrites in `cc_wrapper.c`.
  - If Remote Build Execution (RBE) fleets prohibit `--sandbox_add_mount_pair=/tmp`, causing Zig's compiler cache to rebuild cold on every remote action and increasing build latency.
  - If upstream Zig / `hermetic_cc_toolchain` regresses versioned glibc linking, breaks under future Bazel `rules_cc` rule-based toolchains, or breaks C++ FFI Hackage packages that require GNU `libstdc++` ABI compatibility instead of Zig's bundled LLVM `libc++`.

### Not Adopted

#### Pigweed C/C++ Toolchains (`pw_toolchain/host_clang:host_cc_toolchain_linux`)

- **What & Role**: Google Pigweed's rule-based host Clang toolchain — Fuchsia Clang 24 + `lld` + `llvm-ar` + `compiler-rt` + `libunwind` configured with modern `rules_cc` (`cc_toolchain` + `cc_sysroot`) and CIPD `fuchsia/third_party/sysroot/bionic` (`x86_64` and `aarch64`).
- **Why Not Adopted** *(evaluated live against cached Pigweed LLVM + Linux sysroot)*:
  - **What worked cleanly**: Real Clang 24 + `lld` + `cc_sysroot` avoided **all 5 core `zig cc` quirks** (`-fno-PIC` worked natively, `.dyn_o` and `-Wl,-h` worked, `--print-file-name=libm.a` resolved hermetically inside the sysroot, and C headers never clashed with `libcxx/include`). It only needed `-optl-no-pie` (disabling Position-Independent Executable linking because GHC's pre-compiled static boot `.a` archives contain fixed-address relocations — the same flag Pigweed passes in `cgo_link_flags`).
  - **Blocker 1 — Non-BCR & monolithic dependency graph**: Pigweed is not published on BCR (`404`) and does not ship a standalone `pw_toolchain` Bzlmod module. Consuming it pulls in its monolithic 892-line `MODULE.bazel`, adding CIPD infrastructure alongside `rules_android`, `rules_java`, `rules_go`, `rules_rust`, `protobuf`, `pico-sdk`, and `zephyr` — incompatible with `rules_hs`'s small dependency graph.
  - **Blocker 2 — Sysroot glibc version mismatch**: `fuchsia/third_party/sysroot/bionic` targets **glibc `2.27`** (it provides `memfd_create@@GLIBC_2.27`, but **lacks `statx` and `fcntl64@GLIBC_2.28`** referenced by GHC's `deb10` `x86_64` and `aarch64` bindists; GHC's older `ubuntu18_04` glibc `2.27` bindist is `x86_64`-only).
- **Catalysts to adopt**:
  - If Pigweed extracts and publishes a standalone, minimal `pw_toolchain` module to BCR (no Android/Java/Go/Rust/Zephyr/pico-sdk transitive deps, plain HTTPS artifact fetches without mandatory CIPD).
  - **And** Pigweed's Linux `cc_sysroot` upgrades to **glibc `>= 2.28`** (or `>= 2.32` if required by BCR `gmp`/`m4`, such as Debian 11/12 multi-arch `x86_64` + `aarch64`).
  - Under those two conditions, `pw_toolchain` would become a strong candidate to replace `hermetic_cc_toolchain` as our dev/showcase default, yielding standard Clang + `lld` without `/tmp` cache mounts or Zig flag rewrites.

#### `toolchains_llvm@1.13.0` (BCR) + Debian Sysroot

- **What & Role**: BCR-native LLVM/Clang + `lld` toolchain (`toolchains_llvm@1.13.0`) configured via `llvm.sysroot(...)` against an external Debian `>= 10` (`glibc >= 2.28`, e.g., Debian 12 `2.36`) sysroot tarball.
- **Why Not Adopted (Deferred as Default; Supported for Consumers)**:
  - Gives the same Clang + `lld` behavior observed with Pigweed (zero `zig cc` quirks, zero `/tmp` sandbox mount, straightforward RBE setup) while remaining lightweight and BCR-native.
  - Deferred as the out-of-the-box dev/showcase default solely because `toolchains_llvm` does not bundle Linux glibc sysroots itself: adopting it requires building, hosting, hashing, and maintaining external multi-arch (`linux_x86_64` + `linux_arm64`) Debian sysroot tarballs (either built via custom `mmdebstrap`/`debootstrap` CI or relying on third-party Chromium/custom sysroot mirrors). It also lacks built-in `musl` targeting.
- **Catalysts to adopt**:
  - If `toolchains_llvm` (or a maintained BCR `linux_sysroot` module) publishes official, SHA-256-pinned, multi-arch (`x86_64` + `arm64`) Debian `>= 10` sysroots directly in BCR with zero consumer tarball hosting.
  - Or if RBE-first requirements forbid `--sandbox_add_mount_pair=/tmp` or demand standard Clang + `libstdc++` without Zig's `libc++` defaults — making `toolchains_llvm` + Debian sysroot the immediate recommended toolchain (and dev CI secondary matrix target).

#### Auto-detected Host GCC/Clang (`rules_cc` Default)

- **What & Role**: Bazel's default `local_config_cc` host auto-detection against `/usr/bin/gcc`, `/usr/bin/clang`, system `ld`, and `/usr/include`.
- **Why Not Adopted**:
  - Non-hermetic: leaks host compiler versions, distro headers, and host glibc symbol versions into build artifacts.
  - Fails outright in bare Linux containers (`debian:bookworm-slim`, `ubuntu:24.04`, `rockylinux:9` with zero compilers installed, asserted in `.github/workflows/ci.yml`).
  - Breaks cross-distro binary portability and invalidates Remote Build Execution (RBE) cache keys across heterogeneous developer workstations.
- **Catalysts to adopt**:
  - **Never** as `rules_hs`'s dev or showcase default.
  - Appropriate **only as a consumer-side opt-in** when an organization already runs locked, immutable Linux build containers or RBE worker images with a pinned distro toolchain and intentionally wants host GCC/Clang ABI alignment (for example, dynamically linking internal system C++ libraries). *(Note: `hs/private/cc_wrapper.c` already supports standard `cc_toolchain`s; gating `-nostdinc++` on compiler flavor would further harden host-GCC builds under `-Werror`.)*

---

## 2. GHC Distribution & Version {#ghc-distribution}

### Context: Bindists, Companion Tools (`ghc-pkg`, `hsc2hs`, `unlit`), `deb10`, and `musl`

For engineers new to the Haskell toolchain ecosystem, five concepts explain what ships inside a GHC release and how Linux distributions affect it (see also [Haskell & GHC Primer](haskell-and-ghc-primer.md#boot-libraries)):

- **What a GHC "bindist" is**: GHC is a large, self-hosting compiler written in Haskell, C, and Cmm (GHC's low-level C-like intermediate language). Building GHC from source takes hours of CPU time and requires an existing bootstrap GHC compiler plus Python/Hadrian build scripts. Instead, the GHC team publishes official pre-compiled `.tar.xz` **binary distributions ("bindists")** containing ready-to-run compiler tools and 41 pre-compiled boot libraries.
- **What the companion binaries inside `bin/` do**: Alongside `ghc` itself and `haddock` (the API doc generator), every GHC bindist includes four smaller binaries staged by `hs/private/staged_ghc.bzl`:
  - **`ghc-pkg`**: GHC's package database registration tool. GHC tracks compiled libraries via small key-value text files (`*.conf`) stored inside a package database directory (`*.pkgdb`); `ghc-pkg recache` validates those `.conf` files and compiles them into a fast binary lookup index (`package.cache`) read by `ghc`.
  - **`hsc2hs`**: A C-interop preprocessor that converts `.hsc` files (Haskell modules containing inline `#peek`, `#poke`, and `#const` C directives) into plain `.hs` source files by compiling and running a tiny C probe program against target C headers (for example, turning `(#const AF_INET)` and `(#size struct sockaddr_in)` in the `network` package into exact platform integer literals).
  - **`ghc-iserv-dyn`**: GHC's out-of-process interpreter worker that loads compiled `.so` shared libraries when evaluating compile-time Template Haskell `$(...)` splices.
  - **`unlit`**: A small text filter invoked automatically by `ghc` when compiling `.lhs` ("literate Haskell") source files, stripping prose lines so only code blocks reach the parser.
- **What `ghcup` is**: `ghcup` is the Haskell community's standard interactive toolchain manager for developer laptops (analogous to Rust's `rustup` or Node's `nvm`). Its `Recommended` tag marks the community's consensus production compiler release (`9.10.3`). `rules_hs` never runs or requires `ghcup` — instead, Bazel downloads the same upstream `downloads.haskell.org` bindist tarballs directly by SHA-256.
- **Why `deb10` is in the filename (`ghc-9.10.3-x86_64-deb10-linux.tar.xz`)**: `deb10` does *not* restrict the compiler to Debian. It simply indicates that upstream built the tarball inside a **Debian 10 ("Buster")** container (`glibc 2.28`). Because Linux's `glibc` maintains forward symbol compatibility, compiling against an older `glibc 2.28` baseline guarantees the `ghc` binary runs unmodified on Debian 10+, Ubuntu 20.04/22.04/24.04 (`2.31`–`2.39`), Fedora, and RHEL/Rocky Linux 8/9 (`2.28`/`2.34`).
- **Why `glibc` vs. `musl` matters**: Standard Linux distributions (Debian, Ubuntu, RHEL/Rocky) use GNU `glibc`, whereas Alpine Linux containers use `musl` libc. A `musl`-linked static GHC bindist (`alpine3_12-linux-static-int_native`) has incompatible C header layouts and symbols against `glibc` C toolchains and cannot use OS `dlopen` to load `.so` shared libraries for Template Haskell — falling back to GHC's internal static object loader, which crashes when C FFI splices call `libc` memory allocators.

### Adopted

#### Official Haskell.org `deb10` glibc Bindists — GHC `9.10.3` (`x86_64` + `aarch64`)

- **What & Role**: Official `ghc-9.10.3-{x86_64,aarch64}-deb10-linux.tar.xz` bindists pinned by URL and SHA-256 in `hs/private/ghc_versions.bzl`, extracted via pure-Starlark `repository_ctx.download_and_extract` (zero fetch-time `./configure && make install`), sanitized in `lib/settings`, and `$ORIGIN`-staged by `hs/private/staged_ghc.bzl`.
- **Why**:
  - **Multi-arch Linux parity**: Official upstream bindists exist with identical directory and linking structure for both `linux_x86_64` and `linux_arm64` (`aarch64`).
  - **Broad Linux distro compatibility**: Ceiling is `<= GLIBC_2.28` (`memfd_create`/`expf`/`logf`/`powf@GLIBC_2.27`; `fcntl64`/`statx@GLIBC_2.28`), running natively on Debian 10+, Debian 12 (`2.36`), Ubuntu 22.04/24.04 (`2.35`/`2.39`), Rocky 8+/9 (`2.28`/`2.34`), and distroless `cc-debian12`.
  - **Small dynamic surface & zero `LD_LIBRARY_PATH`**: Ships bundled `libffi.so.8` + `libCffi*.a` with zero `libnuma` dependency; only `libgmp.so.10` and `libtinfo.so.6` are external, and both resolve cleanly via GHC's baked-in `$ORIGIN/../lib/<arch>-linux-ghc-9.10.3` `RUNPATH` with zero `patchelf` and zero `LD_LIBRARY_PATH`.
  - **Dynamic Template Haskell + C FFI**: Built with `GHC Dynamic = YES` (`ghc-iserv-dyn`), verified live on cross-package TH splices invoking `runIO`, `withCString`, `strlen`, `file-embed`, and `CApiFFI`.
  - **Broad ecosystem compatibility (`9.10.3`)**: Matches `ghcup` `Recommended` (`base-4.20.2.0`) and Stackage **LTS 24.x** (`lts-24.67`), providing CI-tested Hackage closures without Nightly package churn.
  - **Zero host build tools or fetch-time execution (IFD)**: Pure-Starlark extraction plus direct `package.conf.d/*.conf` text parsing replaces `rules_haskell`'s fetch-time `./configure && make install` repository rule (eliminating host `make`/`perl`/`gcc` requirements and slow fetch timeouts).
- **Catalysts to reconsider or replace**:
  - If upstream GHC retires `deb10` bindists in favor of `deb11`/`deb12` (raising the minimum glibc floor above Rocky 8 / older LTS images) — triggering a bindist family update in `hs/private/ghc_versions.bzl`.
  - If Stackage promotes a stable GHC `9.12.x` LTS release and `ghcup` advances `Recommended` to `9.12.x` — triggering a one-line bump of `DEFAULT_GHC_VERSION` to `"9.12.4"` (already pre-wired in `hs/private/ghc_versions.bzl`).
  - If upstream GHC begins publishing official dynamic Linux bindists with native bignum (`--bignum=native`) or statically-linked GMP and no `libtinfo` dependency — letting us simplify `staged_ghc.bzl` and drop non-dev `@gmp` and the `libtinfo.so.6` stub.

### Not Adopted

#### `alpine3_12-linux-static-int_native` (`musl` Static + Native Bignum)

- **What & Role**: Official Haskell.org fully static ELF bindist (`PT_INTERP = NONE`, `DT_NEEDED = NONE`, `--bignum=native`), already cataloged as `linux_x86_64_musl` in `hs/private/ghc_versions.bzl`.
- **Why Not Adopted as Default** *(audited live against GHC `9.10.3` + `zig cc`)*:
  1. **`x86_64`-only**: Upstream GHC publishes no `aarch64` (`linux_arm64`) static Alpine bindist for GHC `9.10`, `9.12`, or `9.14`.
  2. **Template Haskell + C FFI segfaults**: Because `ghc` is statically linked (`GHC Dynamic = NO`), TH falls back to the internal ELF RTS linker, which calls `--print-file-name=libm.a` (leaking host `/usr/lib/x86_64-linux-gnu/libm.a` linker scripts under Zig -> `loadArchive: Not an archive`), and even after supplying Zig's musl `libc.a` + `libcompiler_rt.a` via `-B`, cross-package TH splices calling `withCString`/`malloc` **segfault** in both `ghc` and `ghc-iserv` due to dual-musl `libc.a` clashes.
  3. **glibc ABI mismatch**: Cannot link against glibc `cc_toolchain`s (`undefined symbol: posix_spawn_file_actions_addchdir_np` in `libHSprocess.a` on glibc `<= 2.28`, plus musl/glibc struct layout mismatches), forcing every BCR `cc_library` dependency (`@zlib`, etc.) onto `@zig_sdk//libc:musl`.
  4. **Hackage GMP flag friction**: Uses `bignum = native`, requiring consumers to override default GMP flags on packages like `crypton` (`integer-gmp=false`) and `cborg` (`optimize-gmp=false`) and giving up GMP arbitrary-precision speed.
- **Catalysts to adopt**:
  - **As an opt-in static `musl` flavor** (for `FROM scratch` zero-glibc static `x86_64` binaries without runtime TH + C FFI splices — for example, `examples/size`'s 69-pkg graph has zero runtime TH splices): Wire a musl platform constraint matching `@zig_sdk//libc:musl`, expose a `libc = "musl"` / flavor selector on [`hs.toolchain`](../reference/extensions-and-providers.md#hs-toolchain), and document the `crypton`/`cborg` lockfile flags.
  - **As the default Linux bindist**: Would require (a) upstream GHC publishing official `aarch64` static musl bindists alongside `x86_64`, (b) upstream fixing the static RTS linker / `ghc-iserv` dual-libc crash on TH + C FFI, and (c) broad BCR `cc_library` support for musl builds.

#### `rules_nixpkgs` / Nix-Managed GHC

- **What & Role**: Provisioning GHC and its C runtime libraries (`gmp`, `ncurses`, `libffi`) via Nix expressions populating `/nix/store` (the hermetic Linux path used by `tweag/rules_haskell`).
- **Why Not Adopted**:
  - Requires a host Nix installation and mutates `/nix/store` during repository fetch, breaking Remote Build Execution (RBE), clean Docker/CI containers without a Nix daemon, and Bazel Central Registry (BCR) downstream consumption (`rules_haskell` issue #2451).
  - Imposes a heavyweight secondary build and package ecosystem on teams that chose Bazel specifically to avoid multi-tool orchestration.
- **Catalysts to adopt**:
  - **Never** as a dependency or default in `rules_hs`.
  - Suitable **only as an external consumer-provided `hs_toolchain`** when an organization already standardizes on Nix across its entire RBE worker fleet and needs custom-patched GHC builds or niche system C libraries unavailable in BCR.

#### GHC `9.12.4` / `9.14.1` as Default Version

- **What & Role**: Newer GHC release series (`9.12.4` with `base-4.21.2.0` tracking Stackage Nightly; `9.14.1` tagged `Latest` in `ghcup`).
- **Why Not Adopted as Default**:
  - `9.12.4` currently tracks **Stackage Nightly** rather than an LTS series, bringing moving-target package churn (+5 packages in `examples/size`: 74 vs. 69, plus newer Cabal features like `reexported-modules` in `crypton-asn1-encoding`/`crypton-asn1-parse` and `autogen-modules` in `mlkem`).
  - `9.14.1` is too recent for broad Hackage upper-bound compatibility.
  - *(Note: `rules_hs` is already forward-compatible with `9.12.4`: all six platform URLs, SHA-256 checksums, and `BOOT_PACKAGE_NAMES` including `file-io` are pre-wired in `hs/private/ghc_versions.bzl`, and `reexported-modules` is already implemented in [`hs_cabal_library`](../reference/rules.md#hs_cabal_library) and [`//tools/lock:lock`](../reference/lock-cli.md).)*
- **Catalysts to adopt as default**:
  - Stackage cuts a stable **LTS series** for GHC `9.12.x` (e.g., LTS 25+), `ghcup` promotes `9.12.x` to `Recommended`, and the `rules_hs` + `examples/size` + `//docs` CI matrix passes cleanly on that LTS. (Same criteria apply to `9.14.x` in a subsequent release cycle.)

---

## 3. Native Runtime & Compiler Libraries {#native-runtime-libs}

### Context: Why `gmp`, `tinfo` (`ncurses`), and `libffi` Exist in GHC's World

At first glance, it is surprising that a functional language compiler depends on C math, terminal, and foreign-call libraries. Each of the three solves a specific runtime requirement inside GHC (see [Haskell & GHC Primer](haskell-and-ghc-primer.md#gmp-and-tinfo)):

1. **`gmp` (`libgmp` — GNU Multiple Precision)**: Haskell's built-in `Integer` type in `base` provides arbitrary-precision integers (`factorial 1000` never overflows 64 bits). GHC's `ghc-bignum` boot library backs `Integer` with C's `libgmp` routines (`__gmpn_*`), so `ghc` itself dynamically loads `libgmp.so.10` when running, and user binaries link `libgmp.a` statically.
2. **`tinfo` (`libtinfo.so.6` / `libtinfo.a` from `ncurses`)**: In GHC's build architecture, the batch compiler (`ghc -c Foo.hs`) and the interactive REPL (`ghci`, which is a 3-line wrapper script passing `--interactive` to the exact same `ghc` binary) are **one single ELF executable**. Because interactive `ghci` supports arrow-key history and colored prompts through the `haskeline` and `terminfo` boot libraries (`libHSterminfo`), `bin/ghc` carries a dynamic `DT_NEEDED` entry for `ncurses`'s terminal-info library `libtinfo.so.6`. Even though batch Bazel build actions never open an interactive terminal, Linux's dynamic loader (`ld-linux.so`) resolves every `DT_NEEDED` shared library before `main()` begins — so without `libtinfo.so.6` (and static `libtinfo.a` when linking executables that transitively pull `terminfo`), `ghc` refuses to launch on minimal containers that do not have `ncurses` installed.
3. **`libffi` (`libffi.so.8` & `libCffi*.a` — Foreign Function Interface)**: The portable C Foreign Function Interface library (the same C library behind Python's `ctypes` and Ruby's `fiddle`) constructs C calling-convention stack and register frames at runtime. GHC's Runtime System uses `libffi.so.8` when executing C calls inside compile-time Template Haskell splices (`ghc-iserv-dyn`) and links `libCffi.a` into executables so Haskell functions can be exported as callable C function pointers (`foreign export ccall`).

### Adopted

#### BCR `gmp@6.3.0.bcr.5`

- **What & Role**: Non-dev BCR dependency in `MODULE.bazel` serving two distinct roles in `hs/private/staged_ghc.bzl`:
  1. **Compiler runtime (`libgmp.so.10`)**: Built hermetically from `@gmp//:gmp`'s position-independent archive (`libgmp.pic.a`) via `HsLinkGmpShared` (`-shared -Wl,-soname,libgmp.so.10 -Wl,--whole-archive`) and `$ORIGIN`-staged inside `<prefix>/lib/<arch_libdir>/` for GHC's own dynamic binaries.
  2. **User binaries (`libgmp.a`)**: Symlinked into a dedicated static-only directory `<prefix>/gmp_static/libgmp.a` (with zero `.so` present) and passed via `-optl-L` during `HsLinkExecutable`, statically linking `ghc-bignum` so produced user binaries carry **zero `libgmp.so.10`** in `DT_NEEDED`.
- **Why**:
  - Eliminates host `libgmp-dev` / `libgmp10` completely while matching GHC `deb10`'s unversioned `__gmpn_*` ABI.
  - Produces portable, self-contained user executables whose `DT_NEEDED` is strictly base glibc (`libc.so.6`, `libm.so.6`, `libdl.so.2`, `libpthread.so.0`).
  - **Known constraint**: BCR `gmp@6.3.0.bcr.5` pulls BCR `m4` as a build tool; under Zig (`hermetic_cc_toolchain`), compiling `m4` includes `<sys/single_threaded.h>`, which requires glibc `>= 2.32` (requiring `gnu.2.32` rather than `gnu.2.28` in `.bazelrc`/`MODULE.bazel`).
- **Catalysts to reconsider or replace**:
  - If upstream GHC switches its default Linux bindists away from GMP to `ghc-bignum`'s `native` backend — letting `rules_hs` drop `gmp` from its non-dev `MODULE.bazel` dependencies completely.
  - If downstream `hermetic_cc_toolchain` users need binary portability down to glibc `2.28`–`2.31` (e.g., Rocky Linux 8, Ubuntu 20.04, Debian 10) — catalyst to patch or eliminate `gmp`'s `m4` `<sys/single_threaded.h>` glibc `>= 2.32` requirement or pair with `toolchains_llvm` + a glibc `2.28` sysroot.
  - If a commercial consumer's LGPL compliance policy disallows static linking of `libgmp.a` into proprietary executables — catalyst to add a toolchain/rule option (`link_gmp_static = False`) staging `libgmp.so.10` alongside the binary or opting into `bignum = native`.

#### In-Tree `libtinfo.so.6` & `libtinfo.a` Stub (`hs/private/tinfo_stub.c` + `hs/private/tinfo_stub.lds`)

- **What & Role**: A 56-line C11 source file (`hs/private/tinfo_stub.c`, including comments) compiled twice in `hs/private/BUILD.bazel` and staged by `hs/private/staged_ghc.bzl`:
  1. **Dynamic `libtinfo.so.6`**: Linked with a 13-line ELF version script (`hs/private/tinfo_stub.lds`) that exports the exact 8 C symbols imported by GHC's `libHSterminfo`, tagged with ABI symbol version `@NCURSES6_TINFO_5.0.19991023`, and `$ORIGIN`-staged into `<prefix>/lib/<arch_libdir>/libtinfo.so.6` for `bin/ghc` and `bin/haddock`.
  2. **Static `libtinfo.a` (`tinfo_stub_static`)**: Archived and symlinked into `<prefix>/gmp_static/libtinfo.a` alongside `libgmp.a`, satisfying `-ltinfo` when statically linking any Haskell tool or binary whose dependency closure includes `@hs_boot//:terminfo` (for example, binaries that link the `ghc` API library).
- **Engineering Deep Dive — Why Those 8 Symbols and Sentinels Are Exact**:
  - **Complete dynamic symbol audit**: Inspecting every executable and shared library in GHC `9.10.3` and `9.12.4` `deb10` (`x86_64` and `aarch64`) with `readelf --dyn-syms` confirms that `libtinfo.so.6` is imported **solely** by `libHSterminfo`, which binds strictly 8 X/Open Curses functions under `NCURSES6_TINFO_5.0.19991023`:
    - `setupterm(term, fildes, errret)` sets `*errret = -1` (when `errret != NULL`) and returns `-1` (`ERR`), the documented X/Open Curses code meaning *"terminfo database could not be found"*.
    - `tigetflag(capname)` returns `-1` (*"not a boolean capability"*).
    - `tigetnum(capname)` returns `-2` (*"not a numeric capability"* per X/Open Curses, where `-1` indicates absent/cancelled and `-2` indicates unrecognized).
    - `tigetstr(capname)` returns `(char *)-1` (`TIGETSTR_ERROR`, distinct from `NULL` which means cancelled/absent).
    - `set_curterm(nterm)` and `tparm(str, ...)` return `NULL`; `del_curterm(oterm)` and `tputs(str, affcnt, putc_fn)` return `0` (`OK`).
  - **Same runtime behavior as real `ncurses` inside a Bazel sandbox**: When genuine `ncurses` `libtinfo.so.6` runs inside a hermetic Bazel `linux-sandbox` action (`env -i` with `TERM` unset, or inside a bare container without `/usr/share/terminfo` from `ncurses-base`), `setupterm` *also* cannot open a terminfo entry, sets `*errret = -1`, and returns `-1`. Haskell's `System.Console.Terminfo.Base.setupTerm` is explicitly written against this X/Open Curses contract: it converts `*errret == -1` into a clean `SetupTermError`, which `haskeline` and GHC catch to run in plain dumb-terminal mode. Compiling the 56-line C11 file takes a few milliseconds and keeps `ncurses`, `gawk`, and autoconf out of every downstream user's `MODULE.bazel` graph.
  - **Candid Trade-Off & Limitation (Interactive `brick`/`vty` TUIs and `hs_repl`)**: Because `gmp_static/libtinfo.a` is placed on GHC's link search path (`-optl-L<gmp_static_dir>`) and always reports *"no terminfo database"*, any user `hs_binary` that builds a full-screen interactive Terminal User Interface (TUI) using libraries such as **`brick`** or **`vty`** (which depend on `@hs_boot//:terminfo` to query cursor positioning, alternate-screen switching, and 256-color sequences on a live TTY at runtime) will fail at startup with `SetupTermError` if `-ltinfo` links against `gmp_static/libtinfo.a`. Likewise, interactive `ghci` (which `rules_hs` does not yet expose via an `hs_repl` rule) would fall back to basic dumb-terminal input without arrow-key line editing or colors.
    - *Workaround today*: An application needing real `terminfo` at runtime can supply a `cc_library` building real `ncurses` `tinfo` and force-link its archive ahead of `-ltinfo` via `ghc_opts = ["-optl-Wl,--whole-archive", ...]` (or dynamically link `-l:libtinfo.so.6` on target hosts that ship `ncurses-base`).
- **Catalysts to reconsider or replace**:
  - **Interactive TUI (`brick`/`vty`) consumers or adding `hs_repl`**: Supporting full-screen TUI `hs_binary` targets out of the box or introducing an interactive `hs_repl` rule (`bazel run` launching live `ghci` with rich `haskeline` editing) is the direct catalyst to add an opt-in real `ncurses` `libtinfo` mode (either a toolchain flag or per-target attribute) while keeping the zero-dependency stub as the default for batch compilation and standard servers/CLIs.
  - **Future GHC symbol changes**: If a future GHC release imports additional `libtinfo` symbols or updates the ncurses version tag beyond `NCURSES6_TINFO_5.0.19991023` (small addition if 1–2 symbols; catalyst to evaluate real `ncurses` if the surface expands substantially).
  - **Upstream GHC split**: If upstream GHC stops linking `libHSterminfo` / `libtinfo.so.6` into batch compiler invocations — allowing `rules_hs` to delete the stub completely.

#### GHC-Bundled `libffi.so.8` & `libCffi*.a`

- **What & Role**: Pre-built `libffi.so.8` (for GHC's own dynamic runtime via `$ORIGIN`) and `libCffi*.a` (statically linked into user executables) shipped directly inside official GHC `deb10` bindists under `lib/<arch>-linux-ghc-<ver>/`.
- **Why**:
  - Already bundled inside the SHA-256-pinned GHC archive, ABI-matched to GHC's `rts`, requires zero extra BCR dependency (`libffi`) or host `libffi-dev`, and leaves zero `libffi.so.8` entry in user binary `DT_NEEDED`.
- **Catalysts to reconsider or replace**:
  - If upstream GHC switches official Linux bindists to `--with-system-libffi` (dropping bundled `libffi.so.8` / `libCffi.a`) — catalyst to adopt a BCR `libffi` module and stage/static-link it identically to `gmp`.
  - If a polyglot C/C++ consumer statically links a separate `libffi` version via `cc_deps`, causing duplicate symbol collisions with GHC's `libCffi.a` — catalyst to expose a toolchain override substituting a shared BCR `@libffi` target.

### Not Adopted

#### Full BCR `ncurses` Build

- **What & Role**: Building full `ncurses` (and its `libtinfo.so.6` + terminfo database tools) from BCR for every `rules_hs` consumer to satisfy GHC's `libtinfo.so.6` import.
- **Why Not Adopted**:
  - Pulls a large C/autoconf/`gawk` build graph into every downstream consumer's non-dev `MODULE.bazel` closure solely to satisfy 8 interactive terminal query symbols that batch compilation never uses, while inside a Bazel sandbox without `/usr/share/terminfo` real `ncurses` `setupterm` returns `-1` anyway.
- **Catalysts to adopt**:
  - If a lean, zero-`gawk` BCR `tinfo`-only target becomes available **and** `rules_hs` adds an interactive `hs_repl` target or opt-in TUI (`brick`/`vty`) linking mode (still scoped to interactive/TUI targets rather than mandatory for batch compilation).
  - Or if future GHC releases depend on `ncurses`/`tinfo` capabilities during batch compilation where dumb-terminal error sentinels no longer suffice.

#### Host System `libgmp-dev` / `libtinfo5` / `libtinfo6` (`apt install`)

- **What & Role**: Requiring pre-installed OS packages on the host or CI image (the pattern used in `tweag/rules_haskell`'s BCR `1.0` `presubmit.yml`: `sudo apt install libtinfo5 libgmp-dev`).
- **Why Not Adopted**:
  - Breaks hermeticity and fails on clean containers (`debian:bookworm-slim`, `ubuntu:24.04`, `rockylinux:9` verified with zero C `-dev` headers in `.github/workflows/ci.yml`).
  - Fragile across distros (`libtinfo5` was removed in Ubuntu 24.04 and Debian 13 in favor of `libtinfo6`), breaks RBE portability, and leaks dynamic `libgmp.so.10` runtime dependencies into user binaries.
- **Catalysts to adopt**:
  - **Never** as default in `rules_hs`.
  - Only plausible as a consumer-configured escape hatch in controlled enterprise environments required to dynamically link centrally patched OS shared libraries across all deployed binaries.

---

## 4. Bazel Rule Foundations & Action Wrappers {#bazel-foundations}

### Context: Action Wrappers and `stardoc` in Bazel Rulesets

If you have only used Bazel rulesets rather than authoring one, two ruleset-engineering concepts explain the decisions in this section (see [Bazel Ruleset Primer](bazel-rules-primer.md#rules-and-actions)):

- **Why rulesets wrap the C compiler — and why Python wrappers burden consumers**: When GHC invokes a C compiler or linker (`-pgmc`, `-pgml`), it passes older GCC/GNU-ld flags (`-Wl,-h,libfoo.so`, `-fno-PIC`, `.dyn_o` output paths) that modern Clang/`lld`/`zig cc` toolchains either reject or misinterpret, and it inherits `RUNFILES_*` environment variables if unscrubbed. Early Bazel rulesets (like `tweag/rules_haskell`) wrote this adapter as a Python script (`cc_wrapper.py`), which forced every downstream user to add `rules_python` and download a Python interpreter toolchain just to compile Haskell. Because every `rules_hs` workspace already registers a C compiler (`cc_toolchain`), compiling a zero-dependency C11 adapter binary (`ghc_cc_wrapper`) once per build avoids Python completely and removes ~20–40 ms of interpreter startup overhead from every compile and link action.
- **What `stardoc` is**: `stardoc` is Bazel's official documentation tool that parses Starlark `.bzl` files and renders `doc = "..."` attribute strings into Markdown reference pages. Historically, rulesets that declared `stardoc` as a regular `bazel_dep` (forgetting `dev_dependency = True`) leaked `stardoc`'s transitive Java and Protobuf dependencies into every downstream user's `MODULE.bazel` graph.

### Adopted

#### Minimal BCR Non-Dev Modules (`platforms@1.1.0`, `bazel_skylib@1.9.2`, `rules_cc@0.2.28`) + Dev-Only `rules_shell@0.6.1`

- **What & Role**: Core Bazel 9 Bzlmod foundation in `MODULE.bazel`: OS/CPU constraint values (`platforms`), standard Starlark helpers (`bazel_skylib`), `cc_toolchain` / `cc_common` / `CcInfo` integration (`rules_cc`), plus shell test rules (`rules_shell`, strictly `dev_dependency = True`). Together with `gmp@6.3.0.bcr.5`, `rules_hs` has only **4 direct non-dev `bazel_dep`s**.
- **Why**:
  - Aligns with modern Bazel 9 Bzlmod-only rulesets (`rules_zig`, `rules_dotnet`, `rules_rust`, `rules_go`) with explicit `bazel_compatibility = [">=9.0.0"]` and zero legacy `WORKSPACE` files.
  - Keeps downstream `bazel mod graph` small and ensures test-only and docs-only dependencies (`rules_shell`, `hermetic_cc_toolchain`, `//docs` Hackage closure) never leak to consumers.
  - **Transitive BCR nuance (verified via `bazel mod graph`)**: `rules_cc@0.2.28` itself declares a transitive BCR dependency on `protobuf@33.4` (which remains unfetched unless referenced), while `rules_hs` declares zero `protobuf`, `rules_java`, `rules_python`, `rules_nodejs`, or `rules_nixpkgs`.
- **Catalysts to reconsider or replace**:
  - **Upgrade `rules_cc`**: As soon as a newer `rules_cc` release removes its transitive `protobuf` BCR dependency, bump `rules_cc` to shrink the resolved module graph further.
  - **Add `bazel_features`**: If Bazel 10 introduces Starlark API changes requiring conditional feature detection across Bazel 9 and 10, adding the small pure-Starlark `bazel_features` BCR module is justified.
  - **Drop dev-only `rules_shell`**: If all ELF/hygiene integration tests are rewritten in Haskell ([`hs_test`](../reference/rules.md#hs_test)) or Starlark analysis tests, even dev-only `rules_shell` can be removed.

#### Native C11 `ghc_cc_wrapper` (`hs/private/cc_wrapper.c`)

- **What & Role**: Self-contained 552-line POSIX C11 binary compiled once by Bazel's active `cc_toolchain`, invoked by GHC (`-pgmc`, `-pgmcxx`, `-pgml`, `-pgma`, `-pgmP`, `-pgmCmmP`), `hsc2hs` (`--cc`, `--ld`), and Cabal `./configure` (`CC`, `CXX`).
- **Why**:
  - Zero Python interpreter or `rules_python` dependency anywhere in the build graph; sub-millisecond startup overhead across hundreds of compile, link, and configure actions.
  - Centralizes Bazel `RUNFILES_*` environment scrubbing, generic `cc_toolchain` `--sysroot`/`--target` passthrough (`RULES_HS_CC_EXTRA_ARGS`), and all six `zig cc`/Clang <-> GHC compatibility rewrites (`--print-file-name`, `-Wl,-h` -> `-Wl,-soname` including `@response_file`s, `-fuse-ld=gold`, `-fno-PIC` -> `-fPIC`, `.dyn_o`/`.p_o` temp symlinks, `-Wno-unused-command-line-argument`, and `-nostdinc++` on non-C++ invocations).
- **Catalysts to reconsider or replace**:
  - **Windows support (`windows_x86_64`)**: `cc_wrapper.c` currently relies on POSIX APIs (`unistd.h`, `symlink`, `execv`, `unsetenv`); enabling Windows requires porting spawn/env/file-aliasing to Win32 (`_spawnv`/`CreateProcessW`, `_putenv_s`, `CreateHardLinkW`) or pairing with a cross-platform native runner.
  - **Host GCC under `-Werror`**: Unconditionally injecting `-nostdinc++` on C files works cleanly on `zig c++` and Clang, but GCC can warn on `-nostdinc++` for C inputs when `-Werror` is set — catalyst to gate `-nostdinc++` behind a compiler check or env toggle (`RULES_HS_NOSTDINCXX=1`).
  - **Wrapper elimination**: If future GHC stops emitting `-Wl,-h`, `-fuse-ld=gold`, `-fno-PIC`, and non-`.o` object extensions **and** consumer C toolchains stop triggering `zig c++` header ordering or `--print-file-name` host leaks, `cc_wrapper.c` could shrink to a minimal `RUNFILES_*` cleaner or be retired.

### Not Adopted

#### `rules_python` + Python `cc_wrapper.py` / `cabal_wrapper.py` (`rules_haskell` Pattern)

- **What & Role**: Python action wrappers executed on every GHC compile, link, and Hackage build action.
- **Why Not Adopted**:
  - Leaks `rules_python` (and a Python runtime toolchain or host `python3` assumption) into every downstream consumer's non-dev `MODULE.bazel` graph and every Haskell build action's inputs.
  - Adds Python interpreter startup latency across hundreds of actions and historically accumulated platform-specific wrapper bugs (`rules_haskell` #2492/#2493, #2317).
  - Redundant when Bazel already requires a `cc_toolchain` capable of compiling a 552-line C11 wrapper natively, and our 5-stage [`hs_cabal_library`](../reference/rules.md#hs_cabal_library) pipeline removes `cabal_wrapper.py` altogether.
- **Catalysts to adopt**:
  - **Never** on the build action hot path (`cc_wrapper` or `hs_cabal_library`).
  - Only conceivable for an isolated optional dev-only helper tool if third-party Python libraries were uniquely required — and even then, writing internal tools in Haskell ([`//tools/lock:lock`](../reference/lock-cli.md) and `//docs:docs_gen`) avoids adding an extra language runtime.

#### Legacy / Unrelated Non-Dev Deps (`rules_java`, `protobuf`, `abseil-cpp`, `rules_proto`, `rules_nodejs`, `aspect_rules_js`, `rules_sh`, Non-Dev `stardoc`)

- **What & Role**: Broad non-dev `bazel_dep`s inherited by `tweag/rules_haskell`'s `MODULE.bazel` (Java/Protobuf tooling, legacy Asterius WASM JS/Node deps, deprecated `rules_sh`, doc generators).
- **Why Not Adopted**:
  - Directly caused Bazel 8 and 9 evaluation failures in `rules_haskell` (`rules_sh@0.4.0` calling removed `get_cpu_value`, `aspect_rules_js@1.34.0` loading removed `npm_import.bzl`, `protobuf` Windows overrides) and added unrelated Java/Node/Protobuf module graphs to every downstream consumer.
- **Catalysts to adopt**:
  - **`stardoc`**: Suitable strictly as **`dev_dependency = True`** (or in an isolated submodule) if automated `.bzl` Markdown generation from Starlark `doc` strings is desired alongside hand-written reference pages — never as a non-dev dependency.
  - **JS/WASM rules**: Only inside a separate optional module (e.g., `rules_hs_wasm`) if GHC's `wasm32-wasi` backend is supported and needs JS/WASI test runners — never in core `rules_hs`.
  - **`rules_java` / `protobuf` / `abseil-cpp` / `rules_sh`**: Never as non-dev deps of core `rules_hs` (`rules_shell` supersedes `rules_sh` as dev-only).

---

## 5. 3p Hackage Resolution & Build Pipeline {#hackage-pipeline-decisions}

### Context: Conditional `.cabal` Manifests, `Cabal-syntax`, and `Setup.hs` Build Types

To understand why `rules_hs` splits third-party dependency handling into [`//tools/lock:lock`](../reference/lock-cli.md) + [`hs_cabal_library`](../reference/rules.md#hs_cabal_library) and rejects arbitrary `Setup.hs` execution, three pieces of Haskell packaging context are essential (see [Haskell & GHC Primer](haskell-and-ghc-primer.md#ecosystem-map)):

1. **Why `.cabal` files defeat regexes and hand-rolled Starlark parsers**: Unlike flat JSON manifests, a `.cabal` file is a domain-specific configuration language with indentation-scoped stanzas, shared `common` blocks, user-togglable boolean `flag`s, and nested conditionals (`if os(linux) && arch(x86_64)`, `if impl(ghc >= 9.10)`, `if flag(bundled-c-zlib)`) that alter `exposed-modules`, `c-sources`, `cc-options`, and `build-depends` per platform. Regex or hand-rolled Starlark parsers mis-evaluate real Hackage packages.
2. **Why `Cabal-syntax` inside `@hs_boot` avoids bootstrap cycles**: Every official GHC bindist ships the `Cabal-syntax` parser and evaluator library pre-compiled in its boot package database. That allows `rules_hs` to compile [`//tools/lock:lock`](../reference/lock-cli.md) directly against `@hs_boot//:Cabal-syntax` — evaluating the official Cabal specification across target OS/CPU platforms (`finalizePD`) into static JSON (`hackage.lock.json`) with **zero** host `cabal` or `stack` binaries, **zero** fetch-time execution (IFD), and **zero** third-party bootstrap dependencies.
3. **How Cabal's three `build-type` modes (`Simple`, `Configure`, `Custom`) and `Setup.hs` actually work**: Every Hackage tarball includes a `build-type:` field in its `.cabal` manifest and a small `Setup.hs` Haskell file in the package root:
   - **`build-type: Simple`** *(the vast majority of Hackage)*: `Setup.hs` is a two-line stub (`import Distribution.Simple; main = defaultMain`) with no custom code. Everything needed to build the package is declared statically in `.cabal`. `hs_cabal_library` compiles these directly across up to 5 granular Bazel actions without compiling or executing `Setup.hs`.
   - **`build-type: Configure`** *(POSIX system-probing packages like `network`, `unix-time`, and `old-time`)*: `Setup.hs` calls `defaultMainWithHooks autoconfUserHooks`, whose only extra job before a `Simple` build is running a standard GNU Autoconf `/bin/sh ./configure` script included in the tarball to probe C headers/constants and write a generated header (such as `include/HsNetworkConfig.h`) and optional `<pkg>.buildinfo`. `//tools/lock:lock` inspects the tarball, `.buildinfo`, and `configure.ac` at lock time, and `hs_cabal_library` runs `./configure` inside a sandboxed Bazel action in Stage 1 (`HsConfigure`) via `ghc_cc_wrapper` — again without `Setup.hs`.
   - **`build-type: Custom` — harmless `cabal-doctest` vs. arbitrary `Setup.hs` programs**: A `Custom` package declares a `custom-setup` stanza with its own `setup-depends` libraries so `Setup.hs` can run arbitrary Haskell code at build time.
     - *Doctest-only `Custom` (normalized to `Simple`)*: Many libraries (such as `xml-conduit` in `examples/size`) only declare `build-type: Custom` to invoke `cabal-doctest` (`defaultMainWithDoctests "doctest"`), which generates module-path metadata solely for the package's own `doctest` test suite and is a **complete no-op when building the library itself**. In `tools/lock/CabalExtract.hs` (`classifyBuildType`), `//tools/lock:lock` inspects `setup-depends`: if a `Custom` package depends exclusively on `{base, Cabal, Cabal-syntax, cabal-doctest, filepath, directory}`, it normalizes `"build_type"` to `"Simple"` in `hackage.lock.json`.
     - *Bespoke `Custom` `Setup.hs` scripts (intentionally unsupported in `hs_cabal_library`)*: A small fraction of Hackage packages (such as `entropy`, which compiles and runs a custom C CPU-instruction probe binary inside `Setup.hs` to check `RDRAND`, or `HsOpenSSL` and `gi-gtk`, which run custom code generators or host library discovery inside `Setup.hs`) execute arbitrary Haskell I/O during build configuration. Supporting them inside `hs_cabal_library` would require resolving a second `setup-depends` dependency graph, compiling and running a separate `Setup.hs` binary per package, collapsing compilation into an opaque single-directory action that hides individual `.c` and `.hsc` steps from Bazel's cache, and breaking cross-compilation whenever `Setup.hs` tries to run a target-CPU probe binary on the build host.

### Adopted

#### Self-Hosted Boot-Only `//tools/lock` (`Cabal-syntax`) + Stackage LTS -> `hackage.lock.json` -> Pure-Starlark `hackage` Extension + 5-Stage `hs_cabal_library`

- **What & Role**: Two-phase dependency pipeline split cleanly between dev time and build time:
  1. **Dev-time lock generator ([`//tools/lock:lock`](../reference/lock-cli.md) in `tools/lock/BUILD.bazel`)**: A Haskell binary compiled strictly from `@hs_boot` (`Cabal-syntax`, `base`, `bytestring`, `containers`, `directory`, `filepath`, `process`, `text`) — zero third-party deps — that reads a Stackage LTS snapshot (`lts-24.67`), evaluates `.cabal` conditionals across four platforms (`linux_x86_64`, `linux_arm64`, `macos_arm64`, `macos_x86_64`) via `Distribution.PackageDescription.Configuration.finalizePD`, verifies Hackage tarball SHA-256s, normalizes doctest-only `build-type: Custom` (`xml-conduit`), inspects `build-type: Configure` outputs (`network`, `unix-time`, `old-time`), and writes deterministic `hackage.lock.json` (`schema_version = 1`).
  2. **Build-time pure-Starlark extension (`hs/private/hackage.bzl`)**: Reads `hackage.lock.json` via `json.decode` (`reproducible = True`, zero network calls or IFD during extension evaluation), emits one uniform `@hackage` hub repo (boot [`hs_toolchain_library`](../reference/rules.md#hs_toolchain_library) targets + Hackage aliases) and lazy per-package `@hackage__<pkg>` repos downloaded only when referenced.
  3. **Fine-grained 5-stage builder (`hs/private/cabal_library.bzl`)**: Compiles each package through up to five cacheable, parallelizable Bazel actions — Stage 1 `HsConfigure`, Stage 2 zero-subprocess `cabal_macros.h` + `Paths_*`, Stage 3 parallel per-file `HsHsc2hs`, Stage 4 native `cc_common.compile` (including C-only packages like `zlib-clib` and transitive `install-includes` via `CcInfo`), and Stage 5 `HsCompileLibrary` (`ghc --make -c` + `ar` + relocatable `${pkgroot}` `ghc-pkg` DB).
- **Why**:
  - **Zero host `cabal`, `stack`, or `python`** at both lock generation time and build time.
  - **Complete `.cabal` spec evaluation** by reusing GHC's own `Cabal-syntax` library rather than re-implementing `.cabal` parsing in Starlark.
  - **Pre-vetted version sets** from Stackage LTS without maintaining a custom backtracking SAT version solver.
  - **Fast, reproducible Bzlmod evaluation** (`reproducible = True` confirmed via `--lockfile_mode=update`) with lazy per-package fetches and uniform `@hackage//:<pkg>` target names across boot and non-boot packages.
  - **Granular Bazel caching & native C interop**: `hsc2hs` and C files compile in parallel; `CcInfo` propagates transitive headers cleanly (`zlib-clib` -> `zlib` -> `streaming-commons/cbits/zlib-helper.c`).
- **Catalysts to reconsider or extend**:
  - **Non-Stackage packages / custom version overrides**: Users needing Hackage packages outside Stackage LTS, Hackage revisions, or git checkouts — catalyst to extend [`//tools/lock:lock`](../reference/lock-cli.md) to ingest `cabal.project.freeze` (or direct Hackage constraints and `extra-deps`) while keeping the same `hackage.lock.json` schema and build pipeline.
  - **Additional build-tool preprocessors (`c2hs`, `cpphs`, `hsc2hs #def`)**: `alex` (`3.5.4.2`) and `happy` (`2.1.7`) are already lazily bootstrapped from `@hs_boot` via `hs/private/cabal_codegen.bzl` whenever a locked package contains `.x`/`.y`/`.ly` grammars (incurring zero fetches on closures like `examples/size` that have zero grammar packages); demand from C-binding-heavy consumers (`language-c`, `gtk2hs`) is the catalyst to add optional `c2hs` / `cpphs` / `hsc2hs #def` object-emitting actions ahead of Stage 5.
  - **Boot `Cabal-syntax` lag**: If newer Hackage packages adopt a `cabal-version` unsupported by the active GHC's bundled `Cabal-syntax`, catalyst to allow building [`//tools/lock:lock`](../reference/lock-cli.md) against a newer GHC or an optional pinned `Cabal-syntax` package at dev time.

### Not Adopted

#### `stack_snapshot` (Stack CLI + YAML Pinning)

- **What & Role**: `rules_haskell`'s Hackage resolution flow invoking the external `stack` CLI (or `stack_snapshot_json` + `bazel run @stackage-unpinned//:pin` + per-package `setup_deps` overrides).
- **Why Not Adopted**:
  - Requires an external `stack` binary and ecosystem assumptions outside Bazel, imposes manual `setup_deps = ["@Cabal//:Cabal"]` boilerplate (`rules_haskell` #1871), and couples resolution to Stack's opaque `Setup.hs` build driver rather than Bazel-native actions.
- **Catalysts to adopt**:
  - **Never** as a build-time dependency or runtime tool in `rules_hs`.
  - Useful **only as an optional input format** in [`//tools/lock:lock`](../reference/lock-cli.md) (for example, `--stack-yaml stack.yaml` to import an existing Stack project's resolver, `extra-deps`, and flags directly into `hackage.lock.json`).

#### Pure-Starlark `.cabal` Parser Inside the Bzlmod Extension

- **What & Role**: Parsing `.cabal` files directly inside `hs/private/hackage.bzl` during Bzlmod module extension evaluation.
- **Why Not Adopted**:
  - `.cabal` syntax is stateful and complex (indentation-sensitive stanzas, nested `if/elif/else` over `os()`, `arch()`, `impl(ghc >= ...)`, `flag()`, `common` stanzas, internal sublibraries, `mixins`, `reexported-modules`, version range algebra). A Starlark reimplementation would be incomplete, slow down `bazel mod` evaluation, and force eager downloads of every `.cabal` file at extension eval time (hurting lazy fetching and `MODULE.bazel.lock` reproducibility).
- **Catalysts to adopt**:
  - **Never** for general `.cabal` parsing.
  - Only narrow Starlark parsing is appropriate for flat, single-format metadata already inside a fetched repository (such as GHC's `package.conf.d/*.conf` in `hs/private/ghc_bindist.bzl`), or if Hackage/Stackage ever published official pre-evaluated machine-readable JSON package manifests alongside `.cabal` files.

#### Opaque `cabal-install` / `runghc Setup.hs` Inside Bazel Build Actions

- **What & Role**: Executing `runghc Setup.hs configure && build && copy && register && clean` (or `cabal v2-build`) inside a single Bazel action per package (`rules_haskell`'s `cabal_wrapper.py` architecture).
- **Why Not Adopted**:
  - Collapses `./configure`, `hsc2hs`, C compilation, and GHC compilation into one opaque, non-parallelizable action; mutates the working directory; requires relocating `libHS*.a` to avoid directory-artifact overlaps with `.hi` directories and regex-patching `.conf` files (`rules_haskell` #2496/#2499); drops transitive `data-files` and native `CcInfo` C header propagation; and pays `Setup.hs` compilation overhead on every package even though `Simple`, `Configure`, and `cabal-doctest` `Custom` packages need zero `Setup.hs` execution.
- **Catalysts to adopt**:
  - **Never for `Simple`, `Configure`, or `cabal-doctest` `Custom` packages** (which stay on the 5-stage [`hs_cabal_library`](../reference/rules.md#hs_cabal_library) pipeline).
  - **Scoped opt-in fallback for bespoke `build-type: Custom` packages**: If consumer dependency closures require packages with genuine build-time `Setup.hs` logic (`entropy`, `HsOpenSSL`, `postgresql-libpq-configure`, `gi-gtk`, or packages with custom `HookedBuildInfo` hooks that static lockfile fields cannot express), that is the explicit catalyst to introduce a **separate, opt-in `hs_cabal_custom_library` rule** (recording `setup-depends` in `hackage.lock.json` and compiling and executing `Setup.hs` inside a sandboxed Bazel action strictly for those packages).

---

## 6. Showcase App 3p Haskell Libraries (`examples/size`) {#showcase-libraries}

All package counts and versions below are verified directly against `examples/size/hackage.lock.json` on Stackage `lts-24.67` / GHC `9.10.3` (**69 Hackage packages + 41 GHC boot packages**, **0 external Linux C libraries**, **0 runtime TH splices**; see [Showcase: examples/size](../guide/showcase-size.md)).

### Context: Decoding Haskell `deps` for Engineers New to Haskell

If you have never read a Haskell `BUILD.bazel` file or lockfile before, three pieces of ecosystem context explain every dependency in `examples/size`:

#### 1. Boot Packages & Why Haskell Has `String`, `Text`, and `ByteString`

When you inspect `examples/size/BUILD.bazel`, nearly every target depends on `@hackage//:base`, `@hackage//:bytestring`, and `@hackage//:text`. Knowing why Haskell separates these three types clears up a common point of confusion when reading Haskell dependency lists:

| Boot Package | Key Haskell Types | Go / Rust / Python Analog | Why It Exists & What `examples/size` Uses It For |
|---|---|---|---|
| **`base`** | `IO`, `String` (`[Char]`), `Maybe`, `Either`, `MVar`, `QSem` | Rust `std`, Go `builtin` + `os` + `sync`, Python `builtins` | Haskell's core standard library (`Prelude`, CLI `getArgs`, `stdout`, exceptions, concurrency primitives). For historical 1990s reasons, `base`'s built-in `String` is a **singly-linked list of heap-allocated Unicode characters (`[Char]`)** — convenient for small CLI arguments and error messages, but ~24–40 bytes per character and slow for network or file payloads. |
| **`bytestring`** | `ByteString` (strict & lazy) | Rust `&[u8]` / `Vec<u8>` / `bytes::Bytes`, Go `[]byte`, Python `bytes` | Contiguous raw byte arrays in memory with $O(1)$ pointer/length slicing. Used in `Fetch.hs` and `Sitemap.hs` for raw HTTP response bodies, TCP socket reads, and gzip byte streams before UTF-8 decoding. |
| **`text`** | `Text` (strict & lazy) | Rust `String` / `&str`, Go `string`, Python `str` | Contiguous packed **UTF-8** text arrays in memory. Used throughout `Sitemap.hs`, `Fetch.hs`, and `Main.hs` for validated XML text, URLs, and XML tag/namespace matching. |
| **`containers`** | `Set`, `Map` | Rust `BTreeSet` / `BTreeMap`, C++ `std::set` / `std::map` | Immutable balanced binary search trees. Used in `Sitemap.hs` (`Set Text`) to deduplicate discovered page URLs and track visited `<sitemapindex>` URLs without cycles. |
| **`filepath`** | `FilePath`, `(</>)` | Rust `std::path`, Go `path/filepath`, Python `pathlib` | Cross-platform file path joining (`</>`), used in `SitemapTest.hs` and `HttpE2eTest.hs` to locate Bazel `TEST_SRCDIR` fixture files. |

#### 2. Green Threads & Scoped Mutable Memory (`ST`)

Two GHC runtime concepts appear in the table below:

- **Lightweight green threads**: Like Go's goroutines, Haskell threads (`forkIO` / `async`) are **green threads** — lightweight user-space threads (~1–2 KB initial stack) multiplexed by GHC's runtime scheduler onto a small pool of OS kernel threads (`pthread`s), allowing thousands of concurrent network waits without spawning thousands of OS threads.
- **Scoped mutable memory (`ST`)**: Haskell functions are pure by default (they do not mutate shared globals), but algorithms like `zlib` decompression need fast in-place C/byte buffer mutation. GHC's built-in `ST` (*state-thread*) type lets a function allocate and mutate temporary buffers locally inside one self-contained block and freeze the finished output into an immutable pure value — giving C-like in-memory decompression (`decompressST`) without needing OS `IO`.

#### 3. Why 6 Direct Libraries Expand to a 69-Package Closure (Go / Rust / Python Map)

Haskell's package ecosystem favors small, single-purpose libraries (similar to Rust crates). Here is what every direct Hackage dependency — and each notable transitive library in `examples/size/hackage.lock.json` — does:

| Hackage Package(s) | Role in `examples/size` | Go / Rust / Python Analog | Why It Appears & Build Mechanics Exercised |
|---|---|---|---|
| **`xml-conduit`** (`1.10.1.0`) + `conduit`, `resourcet`, `xml-types`, `blaze-html` | Direct (`:sitemap`): streaming & cursor XML 1.0 parser | Rust `quick-xml` / `roxmltree`, Python `lxml` / `ElementTree` | Parses `<urlset>` and `<sitemapindex>` with XML namespaces and `&amp;` entity decoding; built atop `conduit` (streaming data pipelines with deterministic handle cleanup via `resourcet`). Exercises `build-type: Custom` (`cabal-doctest` normalized to `Simple`). |
| **`http-client`** (`0.7.19`) + **`http-types`** (`0.12.6`) | Direct (`:fetch`): HTTP/1.1 connection pool, redirect handling, status/header types | Go `net/http`, Rust `hyper` / `reqwest` + `http`, Python `urllib3` / `httpx` | Performs pooled HTTP/1.1 GET requests with timeouts and redirect following, keeping JSON parsers (`aeson`) out of the dependency graph. |
| **`http-client-tls`** (`0.3.6.4`) + **`tls`** (`2.1.8`) + **`crypton`** (`1.0.6`) + `crypton-x509*`, `asn1-*`, `pem`, `memory`, `basement` | Direct (`:fetch`) + ~22 transitive crypto/TLS/X.509 packages | **Rust `rustls` + `ring` / `aws-lc-rs` + `webpki`** | **Pure-Haskell TLS 1.2/1.3 protocol state machine** (`tls`) backed by C-accelerated symmetric and asymmetric primitives (`crypton`: AES-NI, SHA-2, Curve25519, ChaCha20-Poly1305) and X.509 system trust-store verification (`crypton-x509-system`). This stack allows `//:size` to make live HTTPS requests with **zero C `libssl.so` or `libcrypto.so` OpenSSL dependency**. |
| **`zlib`** (`0.7.1.1`) + **`zlib-clib`** (`1.3.2`) | Direct (`:sitemap`): `.xml.gz` gzip stream decompression | Rust `flate2` + `libz-sys` (vendored), Go `compress/gzip`, Python `gzip` | Decompresses gzipped sitemaps (`0x1f 0x8b` magic bytes) in local `ST` memory (`decompressST`). With `zlib:bundled-c-zlib=true`, `zlib-clib` compiles 11 vendored ANSI C `zlib` files natively via `rules_cc` — requiring zero host `libz.so.1`. |
| **`async`** (`2.2.6`) | Direct (`:sitemap`, `:http_e2e_test`): structured concurrency (`mapConcurrently`, `withAsync`) | Go `errgroup.Group`, Rust `tokio::task::JoinSet`, Python `asyncio.TaskGroup` | Simon Marlow's structured concurrency wrapper over GHC's lightweight green threads: spawns concurrent child tasks and guarantees automatic sibling cancellation if any branch throws an exception. |
| **`network`** (`3.2.14.0`) + **`streaming-commons`** (`0.2.3.1`) | Direct in `:http_e2e_test`; transitive under `http-client` & `conduit-extra` | Go `net`, Rust `socket2`, Python `socket` | `network` binds low-level BSD/POSIX TCP sockets (exercising Stage 1 `./configure` autoconf header generation + Stage 3 `hsc2hs` C struct offset probing); `streaming-commons` layers buffered socket streaming and C `<zlib.h>` helper wrappers on top. |
| **`attoparsec`** (`0.14.4`) | Transitive under `xml-conduit` & `http-client` | Rust `nom`, C++ `Boost.Spirit` | Byte and text parser combinator library for HTTP headers and XML tokens; exercises **Cabal internal sublibraries** (`attoparsec:attoparsec-internal`, a private helper library inside the same `.cabal` package). |
| **`cborg`** (`0.2.10.0`) + `serialise` (`0.2.6.1`) | Transitive under `tls` | Rust `ciborium` / `serde_cbor` | RFC 8949 CBOR binary serialization used by `tls` for session/ticket encoding; exercises **`.hs-boot` cyclic module compilation** (forward-declaration interface files that break mutual `import` cycles between two `.hs` modules) inside both `cborg` and `tls`. |

### 6.1 XML Parsing

#### Adopted: `xml-conduit` (`1.10.1.0`)

- **What & Role**: Pure-Haskell XML 1.0 parser and cursor query API (`Text.XML`, `Text.XML.Cursor`) used in `examples/size/src/Sitemap.hs`.
- **Why**:
  - Widely used, actively maintained pure-Haskell XML 1.0 library; natively handles XML namespaces (`nameNamespace` / `nameLocalName`), prefixed sibling elements (`<xhtml:link/>`), XML comments, entity decoding (`&amp;` -> `&`), strict UTF-8, and clear parse errors.
  - Its `build-type: Custom` is strictly `cabal-doctest` (normalized to `Simple`), and its 16-package delta over minimal `xml` (69 vs. 54 packages) exercises `rules_hs` on `attoparsec:attoparsec-internal` sublibraries, `Paths_*` generation, and `bitvec` C SIMD flags.
- **Catalysts to reconsider or replace**:
  - If an application has a strict cold-compile-time or binary-size ceiling where dropping 16 transitive packages (`conduit`, `blaze-html`, `blaze-markup`, `attoparsec`, `vector-algorithms`, etc.) outweighs XML 1.0 cursor ergonomics.
  - If parsing multi-hundred-MB sitemaps hits DOM memory ceilings — catalyst to switch from `Text.XML.parseText` to `xml-conduit`'s own streaming `Text.XML.Stream.Parse` API (zero new dependencies) or a streaming SAX parser.

#### Not Adopted

- **`xml` (`Text.XML.Light` `1.3.14`)**:
  - *Why Not Adopted*: Minimal runner-up (zero non-boot deps, `build-type: Simple`, trims graph to 54 packages, handles namespaces and `&amp;`), but largely unmaintained since 2014 (Hackage bounds revisions only), its `ByteString` `XmlSource` instance assumes Latin-1 (an easy UTF-8 bug), it returns `Maybe Element` with no parse error diagnostics, and it leniently accepts malformed XML.
  - *Catalysts to adopt*: Small dependency-budget tools or minimal demos that only need basic extraction from trusted XML and prioritize the smallest Hackage closure (54 vs. 69 packages) over strict diagnostics and active maintenance.
- **`xeno` & `hexml`**:
  - *Why Not Adopted*: Fast low-level parsers, **disqualified** because they explicitly do *not* decode XML entities (`&amp;`) or handle XML namespaces — failing `testdata/urlset.xml` (`https://docs.example.com/a?x=1&amp;y=2`, `xmlns=...`, `<xhtml:link/>`).
  - *Catalysts to adopt*: Only if `xeno`/`hexml` added spec-compliant namespace + entity decoding, or in a specialized multi-GB/s throughput pipeline willing to layer custom namespace/entity decoding on top.
- **`hexpat`**:
  - *Why Not Adopted*: Unmaintained C `libexpat` binding whose bundled `expat 2.2.1` carries known CVEs.
  - *Catalysts to adopt*: A maintained upstream revival wiring to a patched BCR `@expat` library, combined with streaming SAX requirements that `xml-conduit` cannot satisfy.
- **`hxt`**:
  - *Why Not Adopted*: Older arrow-based XML toolbox with a larger dependency footprint and steeper API for simple `<loc>` extraction.
  - *Catalysts to adopt*: Needing XPath, XSLT, or RelaxNG schema validation pipelines unavailable in `xml-conduit`.
- **`xmlbf`**:
  - *Why Not Adopted*: Combinator layer with no built-in raw XML parser (`xmlbf-xeno` / `xmlbf-xmlhtml` are absent from Stackage `lts-24.67`).
  - *Catalysts to adopt*: Inclusion of a spec-compliant `xmlbf-*` backend in Stackage LTS alongside a codebase wanting bidirectional XML serialization typeclasses.

### 6.2 HTTP + HTTPS/TLS

#### Adopted: `http-client` (`0.7.19`) + `http-client-tls` (`0.3.6.4`) + `http-types` (`0.12.6`)

- **What & Role**: Core HTTP/HTTPS transport in `examples/size/src/Fetch.hs`, backed transitively by pure-Haskell TLS (`tls` `2.1.8`, `crypton` `1.0.6`, `crypton-x509-system` `1.6.8`).
- **Why**:
  - **Zero OpenSSL C dependency**: Pure-Haskell TLS + C crypto primitives inside `crypton` (compiled natively by `rules_hs`) keep `libssl.so` and `libcrypto.so` completely out of `DT_NEEDED`.
  - **Standard Linux CA discovery**: `crypton-x509-system` checks `SSL_CERT_FILE` -> `SSL_CERT_DIR` -> `SYSTEM_CERTIFICATE_PATH` -> standard Linux CA paths (`/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem`, `/etc/ssl/certs/`, `/etc/ssl/cert.pem`), working out of the box on standard hosts and containers and remaining overrideable in distroless containers.
  - **Focused API without JSON dependencies**: Gives 30-second timeouts, redirect following, custom `User-Agent`, raw `ByteString` responses, and non-2xx status checking in ~55 lines without pulling in `aeson` (+26 packages).
- **Catalysts to reconsider or replace**:
  - If security or compliance policy requires **FIPS-140-3 validated OpenSSL or BoringSSL** instead of Haskell `tls`/`crypton` — catalyst to switch to `http-client-openssl` wired to BCR `@boringssl`/`@openssl`.
  - If high-volume crawling against a single host needs **HTTP/2 or HTTP/3 (QUIC)** multiplexing — catalyst to evaluate `http2`/`http3` clients.
  - *(Operational note, not a replacement)*: Running in `FROM scratch` containers without `/etc/ssl/certs/` is a catalyst to bundle Mozilla CA roots or inject `SSL_CERT_FILE` / an explicit `CertificateStore` into `http-client-tls`.

#### Not Adopted

- **`http-conduit` (`2.3.9.1`, `Network.HTTP.Simple`)**:
  - *Why Not Adopted*: With its default `flag(aeson) = true`, it adds **+26 packages** (96 total on `lts-24.67`) for JSON support `examples/size` does not use. Even with `flag(aeson) = false` (only +1 package -> 70 total, since `xml-conduit` already pulls `conduit`/`resourcet`/`attoparsec`), direct `http-client` + `http-client-tls` is already concise and avoids an extra lockfile flag override.
  - *Catalysts to adopt*: Adopting `http-conduit` (`aeson = false`) if streaming large sitemaps directly via `httpSink` into `xml-conduit`'s `sinkDoc`, or with `aeson = true` if the app expands to call JSON APIs (`httpJSON`).
- **`req` & `wreq`**:
  - *Why Not Adopted*: Larger REST client frameworks pulling **124** (`req`) or **120** (`wreq`) Hackage packages on `lts-24.67` (133 / 129 on Nightly) — adding `aeson`, `megaparsec` or `lens`, and `entropy` (bespoke `build-type: Custom` setup) for plain GET requests.
  - *Catalysts to adopt*: Building a typed JSON REST client that already depends on `aeson` + `lens`/`mtl` and benefits from typed URL/query/auth DSLs (paired with an opt-in `Custom` `Setup.hs` fallback if `entropy` remains in the closure).
- **`http-client-openssl`**:
  - *Why Not Adopted*: Requires external C `libssl`/`libcrypto` via `HsOpenSSL` (which also uses a bespoke `Custom` setup), adding OpenSSL build, version, and linking complexity where pure-Haskell `tls` works hermetically out of the box.
  - *Catalysts to adopt*: Mandatory FIPS-140-3 / BoringSSL compliance or enterprise TLS extensions/ciphers unsupported by Haskell `tls`, backed by BCR `@boringssl` or `@openssl` via [`hackage.override`](../reference/extensions-and-providers.md#hackage-override).

### 6.3 Gzip Decompression

#### Adopted: `zlib` (`0.7.1.1`) with `bundled-c-zlib = true`, `pkg-config = false` (`zlib-clib` `1.3.2`)

- **What & Role**: Gzip stream decompression in `examples/size/src/Sitemap.hs` (`Codec.Compression.GZip` + `Codec.Compression.Zlib.Internal.decompressST` for total error handling on corrupt archives), backed by `zlib`'s vendored C-only Hackage package `zlib-clib` (`1.3.2`).
- **Why**:
  - **Zero extra Hackage packages**: `http-client` already pulls `streaming-commons` -> `zlib`.
  - **Zero system C libraries & zero consumer `MODULE.bazel` boilerplate**: `zlib-clib` ships 11 ANSI C files + 11 `install-includes` headers (zero Haskell modules), compiled hermetically by [`hs_cabal_library`](../reference/rules.md#hs_cabal_library) Stage 4 (`cc_common.compile`) and statically linked into `//:size` — keeping `libz.so.1` completely out of `DT_NEEDED` while also testing `rules_hs`'s C-only package support and transitive `install-includes` propagation (`streaming-commons/cbits/zlib-helper.c` -> `<zlib.h>`).
- **Catalysts to reconsider or replace**:
  - In a polyglot Bazel monorepo (such as the multi-language `size` repo) that already depends on BCR `zlib` across C++/Rust/etc., switching to BCR `@zlib//:zlib` deduplicates C builds and shares one C security patch plane.
  - If an urgent C `zlib` CVE lands in BCR before Hackage publishes a new `zlib-clib` release — immediate catalyst to override `zlib` to patched BCR `@zlib//:zlib`.

#### Not Adopted

- **BCR `@zlib//:zlib` via `hackage.override` (as `examples/size` default)**:
  - *Why Not Adopted as Showcase Default*: `rules_hs` already supports this cleanly (`--flag zlib:bundled-c-zlib=false --flag zlib:pkg-config=false` plus `hackage.override(package = "zlib", extra_cc_deps = ["@zlib//:zlib"])`), but leaving `bundled-c-zlib = true` as the showcase default avoids an extra `bazel_dep(name = "zlib")` in `examples/size/MODULE.bazel` and directly verifies C-only Cabal packages + transitive `install-includes`.
  - *Catalysts to adopt*: Directly useful for polyglot Bazel repositories that already pin BCR `zlib` across C++/Rust/etc., or want centralized BCR CVE management or alternative C implementations like `zlib-ng`.
- **Host System `libz.so.1` / `pkg-config` (`zlib1g-dev`)**:
  - *Why Not Adopted*: Non-hermetic, fails on clean containers lacking `/usr/include/zlib.h` (asserted absent in CI), and leaks `libz.so.1` into binary `DT_NEEDED`.
  - *Catalysts to adopt*: Never for hermetic Bazel builds; only conceivable under an enterprise requirement mandating dynamic linking to a centrally patched OS `libz.so.1`.

### 6.4 Concurrency

#### Adopted: `async` (`2.2.6`) + Boot `Control.Concurrent.QSem`

- **What & Role**: Bounded 4-way concurrent recursive crawling in `examples/size/src/Sitemap.hs` (`Control.Concurrent.Async.mapConcurrently` + counting semaphore `QSem` acquired via `bracket_` only around the HTTP fetch call, paired with `MVar (Set Text)` cycle and duplicate tracking).
- **Why**:
  - **Zero extra Hackage packages**: `async` is already a transitive dependency of `http-client`.
  - **Safe structured concurrency**: `mapConcurrently` propagates exceptions and cancels sibling green threads without leaks, while releasing `QSem` prior to recursive descent ensures nested `<sitemapindex>` trees cannot deadlock.
- **Catalysts to reconsider or replace**:
  - If crawling scales to tens of thousands of child sitemaps per index where spawning one green thread per child ahead of `QSem` adds scheduling or memory pressure — catalyst to replace `mapConcurrently` + `QSem` with a fixed-size worker pool or bounded queue.
  - If a boot-only executable has zero Hackage dependencies ([`//tools/lock:lock`](../reference/lock-cli.md)) and cannot pull `async`.

#### Not Adopted

- **Raw `Control.Concurrent` (`forkIO` + manual `MVar`s)**:
  - *Why Not Adopted*: Zero dependency savings (since `async` is already present via `http-client`), while requiring manual boilerplate for asynchronous-exception masking, sibling cancellation, and thread-leak prevention.
  - *Catalysts to adopt*: Boot-only executables (zero `@hackage` deps) needing simple background threads where adding a Hackage lockfile would be unnecessary.
- **`ki` / `streamly`**:
  - *Why Not Adopted*: Additional structured-concurrency (`ki`) or concurrent-streaming (`streamly`) libraries that add extra packages and API surface unnecessary for a 15-line bounded tree crawl.
  - *Catalysts to adopt*: Long-lived server or crawler services requiring dynamic scoped thread supervision across non-tree lifetimes (`ki`), or high-throughput streaming pipelines needing backpressure and rate limiting (`streamly`).

---

## 7. Documentation Engine & API Docs (`//docs` & `hs_haddock`, Dev-Only) {#docs-engine-decisions}

> **Important — Strict Dev-Only Isolation:** `//docs` (`docs/BUILD.bazel`, `docs/hackage.lock.json`) is wired in root `MODULE.bazel` via `use_extension("//hs:extensions.bzl", "hackage", dev_dependency = True)`. Downstream consumers of `rules_hs` download **zero** documentation packages (enforced by `//tests/rules:bzlmod_hygiene_test`), while [`hs_haddock`](../reference/rules.md#hs_haddock) uses GHC's already-bundled `$ORIGIN`-staged `haddock` binary with zero extra dependencies. For the internal design of `docs/site.hs` and Haddock integration, see [Hakyll & Haddock Docs](docs-engine.md).

### Context: What Every Library in `//docs` Actually Is (182 Hackage Packages + Bundled Haddock)

For readers with no prior Haskell experience, `docs/BUILD.bazel` builds three small Haskell targets (`//docs:docs_gen`, `//docs:serve`, and `//docs:link_check_test`) alongside `//tools/lock:lock_haddock`. Here is what each library in that stack does in plain English — and why `docs/hackage.lock.json` resolves to **182 Hackage packages**:

- **`hakyll` (`4.16.8.0`) — Static Site Generator Library**: Haskell's widely used static site generator library (analogous to Hugo, Jekyll, or Eleventy exposed as a typed Haskell library rather than a fixed CLI). In `docs/site.hs`, `hakyll` provides file glob matching (`match`), output URL mapping (`route`), dependency-tracked page compilation (`Compiler`), HTML template substitution (`$for(sections)$`, `$if(toc)$`), and automatic relative URL rewriting (`relativizeUrls`).
- **`pandoc` (`3.7.0.2`) + `pandoc-types` (`1.23.1.2`) — Document Parser & HTML Compiler**: John MacFarlane's general-purpose document converter library. `pandoc-types` defines the typed abstract syntax tree (`Pandoc`, `Block`, `Inline`) that `docs/site.hs` traverses to rewrite `.md` links to `.html`, while `pandoc` parses GitHub-flavored Markdown + YAML frontmatter and emits HTML5 + Tables of Contents. **Why are there 182 packages in `docs/hackage.lock.json`?** `pandoc` alone accounts for **~145 of the 182 packages** because a single `pandoc` library supports dozens of publishing formats, pulling in:
  - *Markup & typesetting parsers*: `commonmark`, `commonmark-extensions`, `commonmark-pandoc`, `djot`, `jira-wiki-markup`, `haddock-library`, `ipynb`, `gridtables`, `texmath` (`0.12.10.3` LaTeX/MathML math), and `typst` (`0.8.0.2`).
  - *Bibliography & compile-time embedded assets*: `citeproc` (`0.9.0.1` Citation Style Language processor) and `unicode-collation` (`0.1.3.7`), which use **`file-embed`** (`0.0.16.0` Template Haskell `$(embedFile ...)`) to bake locale and template files directly into the binary at compile time.
  - *Structured data & C/grammar parsers*: `aeson` (`2.2.5.1`, Haskell's JSON library comparable to Rust's `serde_json`), `yaml` (`0.11.11.2`) + `libyaml` + **`libyaml-clib`** (`0.2.5`, C-only vendored `libyaml` compiled via `rules_cc` for Markdown YAML frontmatter), `toml-parser` (`2.0.2.0`, built via bootstrapped `alex`/`happy` lexer and parser generators), `JuicyPixels` (`3.3.9`, pure-Haskell PNG/JPEG/GIF/TIFF image decoder), and `zip-archive` + `digest` + `zlib-clib`.
- **`skylighting` (`0.14.7`) + `skylighting-core` (`0.14.7`) — Pure-Haskell Syntax Highlighter**: Syntax-highlights fenced code blocks across 140+ languages (`haskell`, `python`/`starlark`, `c`, `bash`, `json`, `yaml`, `ini`) and generates `static/syntax.css` (`kate` light + `breezeDark` dark themes). Analogous to Rust's `syntect` or Python's `Pygments`, it compiles KDE Kate XML syntax grammars into Haskell state machines using cross-library Template Haskell.
- **`tagsoup` (`0.14.8`) — Streaming HTML/XML Token Parser**: Lightweight, permissive HTML tokenizer (`parseTags`, analogous to Python's `html.parser` or Go's `x/net/html` tokenizer) used by `docs/test/LinkCheckTest.hs` (`//docs:link_check_test`) to scan every `<a href="...">` and `id="..."` attribute across all Hakyll and Haddock HTML files.
- **`network` (`3.2.14.0`) — POSIX/BSD TCP Sockets**: Low-level OS socket library (`Network.Socket`, analogous to Go's `net` package) used by `docs/app/ServeMain.hs` (`//docs:serve`) to serve `bazel-bin/docs/site/` over HTTP/1.1 on `127.0.0.1:8000` in ~270 lines of Haskell — avoiding a separate web-server framework dependency in `//docs:serve`.
- **Bundled GHC `haddock` (`hs_haddock` — 0 Hackage Packages)**: Haskell's official API documentation generator (analogous to Rust's `rustdoc` or Go's `pkgsite`), already included inside the official GHC `9.10.3` bindist (`bin/haddock-ghc-9.10.3` + `lib/html/` assets). `hs_haddock` runs it directly out of `@ghc_9_10_3_*` without adding any third-party Hackage packages.

### Adopted

#### Vanilla Hakyll + Pandoc + Skylighting (`docs/site.hs`) + Bundled GHC Haddock (`hs_haddock`)

- **What & Role**: A two-part Haskell documentation stack using each ecosystem tool for its standard role:
  1. **Vanilla Hakyll + Pandoc + Skylighting (`docs/site.hs`)**: Pinned in `docs/hackage.lock.json` via [`//tools/lock:lock`](../reference/lock-cli.md) on Stackage `lts-24.67` and compiled hermetically by `rules_hs` into `//docs:docs_gen` ([`hs_binary`](../reference/rules.md#hs_binary)), `//docs:site`, and the local preview server `//docs:serve` — rendering standard GitHub/Pandoc Markdown (`docs/content/**/*.md`) for conceptual guides, architecture chapters, and Starlark `.bzl` references. Locked with:
     - `--flag hakyll:checkexternal=false --flag hakyll:watchserver=false --flag hakyll:previewserver=false` (retaining Hakyll's `Rules`, `Compiler`, `Pandoc`, `Context`, `loadAndApplyTemplate`, and `relativizeUrls` library modules while pruning `http-conduit` and `fsnotify`).
     - `--flag pandoc:embed_data_files=true --flag citeproc:embed_data_files=true` (embedding Pandoc and Citeproc data templates at compile time via `file-embed` cross-library Template Haskell rather than runtime `Paths_*` filesystem lookups).
     - `--flag zlib:bundled-c-zlib=true --flag zlib:pkg-config=false` (building `zlib` hermetically from C sources via `zlib-clib`).
  2. **Bundled GHC Haddock ([`hs_haddock`](../reference/rules.md#hs_haddock) in `hs/private/haddock.bzl`)**: Uses GHC's official `bin/haddock-ghc-<ver>` binary and `lib/html/` theme assets already `$ORIGIN`-staged by `staged_ghc` to generate standard Haskell API documentation, hyperlinked sources, and QuickJump `doc-index.json` indices for Haskell libraries (`//tools/lock:lock_haddock` mounted into `//docs:site` at `/haddock/lock/`, plus `examples/size//:size_haddock`).
- **Why**:
  - **Standard Markdown & GHC Haddock over custom AST dialects**: Rather than inventing a custom Sphinx-like dialect on top of Pandoc (proprietary cross-reference code spans, custom fenced-div directives, or custom Starlark AST parsers), every Markdown page in `docs/content/**/*.md` uses ordinary relative `.md` links, standard Markdown blockquotes, tables, and code fences, and standard Hakyll compilation (`docs/site.hs`). Pages remain readable directly on GitHub, in any editor preview, or in standalone Pandoc — while Haskell library APIs (`//tools/lock:lock_lib`, `examples/size`) get standard GHC Haddock output (`--hyperlinked-source`, `--quickjump`, cross-package `--read-interface`).
  - **Comprehensive integration test for `rules_hs` itself**: Compiling `pandoc` + `hakyll` + `skylighting` + `aeson` exercises cross-library Template Haskell (`-dynamic-too` shared libraries + `file-embed`), `alex`/`happy` grammar bootstrapping, large multi-module packages, C/C++ FFI libraries, internal sublibraries, and `Configure` packages — while still producing a `//docs:docs_gen` ELF executable whose `DT_NEEDED` is strictly base `glibc` (`//docs:site_test`).
  - **Zero Python, Node.js, or Rust runtimes**: Preserves `rules_hs`'s zero-Python / zero-Node repository boundary (`//tests/rules:bzlmod_hygiene_test` verifies neither `rules_python` nor `rules_nodejs` appears in `MODULE.bazel`), implementing `bazel run //docs:serve` in Haskell (`network`).
- **Catalysts to reconsider or replace**:
  - If cold uncached build latency of `pandoc` + `skylighting` (~180 Hackage packages) becomes an issue in ephemeral environments lacking Bazel repository/action caches — catalyst to offer a lightweight `commonmark-hs` compiler mode or publish a cached release tool artifact while keeping `//docs:site` CI verification.
  - If `rules_hs`'s public Starlark API grows large enough that hand-written `reference/*.md` tables risk drifting from `.bzl` `doc = ...` strings — catalyst to generate standard Markdown reference snippets via Bazel `stardoc` (`dev_dependency = True`) and feed those plain `.md` files directly into the unchanged `docs/site.hs` Hakyll pipeline.

### Not Adopted

#### Bespoke Sphinx-Like Pandoc AST DSLs (Custom Role Code Spans, Custom Directives & Custom `.bzl` Parsers)

- **What & Role**: Layering multi-module custom Pandoc AST preprocessors onto Hakyll to emulate Sphinx inline roles, custom admonition fenced divs, and custom `.bzl` autodoc directives inside Markdown prose.
- **Why Not Adopted**:
  - **Breaks standard Markdown portability**: Proprietary inline code-span conventions and custom Pandoc fenced-div blocks render as raw, unlinked syntax in GitHub's web viewer, editor previews, and standard Markdown tools.
  - **Extra maintenance & complexity**: Maintaining hundreds of lines of custom AST rewrite passes and recursive-descent `.bzl` parsers obscures a straightforward `docs/site.hs` Hakyll program — while standard relative `.md#anchor` links (verified at build time on rendered HTML by `//docs:link_check_test`) and GHC [`hs_haddock`](../reference/rules.md#hs_haddock) cover prose cross-references and Haskell API docs directly.
- **Catalysts to adopt**:
  - **Never** for proprietary inline Markdown roles or custom Haskell API doc rendering (which belongs in GHC Haddock).
  - If automated Starlark `.bzl` reference extraction is needed at scale, use standard Bazel `stardoc` (`dev_dependency = True`) emitting plain GitHub Markdown rather than custom Pandoc AST directives.

#### Emanote / Ema

- **What & Role**: Haskell static site and personal knowledge-base engine built on `ema`, `commonmark-hs`, Tailwind CSS, and Nix flakes.
- **Why Not Adopted**:
  - Not packaged in standard Stackage LTS (`lts-24.67`), coupled to Nix flake provisioning, external Tailwind CLI asset pipelines, and live WebSocket hot-reload servers (`ema`), and designed around Zettelkasten wiki-links rather than versioned software reference manuals.
- **Catalysts to adopt**:
  - Inclusion of `ema` / `emanote` in Stackage LTS with a batch-only build flag profile (zero live server or external Tailwind CLI runtime dependencies) alongside a requirement for wiki-style backlink graph exploration.

#### Slick

- **What & Role**: Small Haskell static site helper library on Hackage combining `shake`, `pandoc`, `aeson`, and Mustache templates.
- **Why Not Adopted**:
  - Thin ~150-line wrapper with infrequent upstream maintenance that pulls in `shake` (duplicating Bazel's own build graph) and untyped JSON/Mustache contexts while lacking Hakyll's established `Identifier` / `Routes` / snapshot `Context` system and `relativizeUrls` HTML link rewriter.
- **Catalysts to adopt**:
  - Only for a small standalone micro-site that already depends on `shake` and explicitly requires Mustache template sharing with non-Haskell consumers.

#### Raw Shake + Pandoc (Without Hakyll)

- **What & Role**: Writing a custom build driver directly on `Development.Shake` and `Text.Pandoc` without `hakyll`.
- **Why Not Adopted**:
  - Inside Bazel, `Development.Shake`'s `.shake` database is redundant orchestration overhead, while dropping `hakyll` forces re-implementing HTML template composition (`$if()$`, `$for()$`), route mapping, item snapshots, and relative URL rewriting (`relativizeUrls`) that `hakyll` (configured with `watchserver=false`, `previewserver=false`, `checkexternal=false`) provides for minimal extra package weight over `pandoc`.
- **Catalysts to adopt**:
  - If `hakyll` ever lagged behind a newly released GHC/`pandoc` major version in Stackage while `pandoc` itself compiled cleanly — catalyst to replace the `Hakyll` outer driver with a ~200-line direct `Text.Pandoc` batch compiler orchestrated directly by Bazel (`Development.Shake` would still be omitted).

#### Haddock Alone (Without Hakyll for Prose & Starlark Docs)

- **What & Role**: Using GHC's bundled `haddock` binary as the sole documentation generator for the entire repository, without Hakyll + Pandoc.
- **Why Not Adopted (as Sole Site Generator)**:
  - While `rules_hs` **does** use bundled GHC Haddock via [`hs_haddock`](../reference/rules.md#hs_haddock) for Haskell library and tool API docs (`//tools/lock:lock_haddock`, `examples/size//:size_haddock`), `rules_hs`'s primary user interface is **Starlark** (`hs/defs.bzl`, `hs/extensions.bzl`, `hs/providers.bzl`, `hs/toolchain.bzl`) plus multi-page conceptual guides, architecture comparisons, and Mermaid diagrams — none of which Haddock alone can render into a multi-section documentation site.
- **Catalysts to adopt**:
  - Only for pure-Haskell downstream libraries whose entire public surface consists of `.hs` modules (which can use [`hs_haddock`](../reference/rules.md#hs_haddock) directly without needing a Hakyll prose site).

#### Non-Haskell SSGs (Sphinx, MkDocs Material, `mdBook`, Docusaurus)

- **What & Role**: General-purpose documentation generators in Python (`sphinx`, `mkdocs-material` via `rules_python`), Rust (`mdBook`), and Node.js (`docusaurus` via `rules_nodejs` / `aspect_rules_js`).
- **Why Not Adopted**:
  - **Adds foreign language toolchains to `MODULE.bazel`**: Sphinx/MkDocs and Docusaurus require `rules_python` (+ PyPI wheel lockfiles) or `rules_nodejs` / `aspect_rules_js` (+ `npm` lockfiles), breaking `rules_hs`'s zero-Python / zero-Node boundary (`//tests/rules:bzlmod_hygiene_test`).
  - **Misses self-hosted test coverage**: Building the `rules_hs` documentation site in Python, JS, or Rust would lose continuous CI coverage of `rules_hs` building a large real-world Haskell application (`hakyll` + `pandoc` + `skylighting`) mounted alongside [`hs_haddock`](../reference/rules.md#hs_haddock) output.
- **Catalysts to adopt**:
  - Only if `rules_hs` docs must be ingested into a multi-repo organization-wide documentation portal standardized on MkDocs or Docusaurus — which remains straightforward if ever needed because `docs/content/**/*.md` is written in plain Markdown with YAML frontmatter.
