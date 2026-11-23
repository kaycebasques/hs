# `rules_hs`

[![CI](https://github.com/kaycebasques/hs/actions/workflows/ci.yml/badge.svg)](https://github.com/kaycebasques/hs/actions/workflows/ci.yml)
[![Pages](https://github.com/kaycebasques/hs/actions/workflows/pages.yml/badge.svg)](https://github.com/kaycebasques/hs/actions/workflows/pages.yml)
[![Documentation](https://img.shields.io/badge/docs-kaycebasques.github.io%2Fhs-blue)](https://kaycebasques.github.io/hs/)

Bazel 9 ruleset for Haskell using Bzlmod (`bazel_compatibility = [">=9.0.0"]`).

**Documentation**: [**https://kaycebasques.github.io/hs/**](https://kaycebasques.github.io/hs/) · [Haddock API (`//tools/lock`)](https://kaycebasques.github.io/hs/haddock/lock/index.html)

`rules_hs` compiles Haskell libraries, executables, tests, C/C++ bindings, Haddock API documentation, and third-party Hackage packages on Linux inside isolated Bazel sandboxes. It does not require Nix, legacy `WORKSPACE` files, Python wrapper scripts, or host installations of `ghc`, `cabal`, `stack`, `gcc`, `clang`, or system C `-dev` packages.

- **Self-contained Linux GHC toolchains**: Extracts official GHC `9.10.3` and `9.12.4` binary distributions in Starlark without running host `./configure && make install`. Compiler binaries load `libgmp.so.10` (built from Bazel Central Registry `@gmp`) and a small 8-symbol `libtinfo.so.6` stub via relative ELF library paths (`$ORIGIN`), without `LD_LIBRARY_PATH` or `patchelf`.
- **Portable Linux executables with static GMP**: `hs_binary` and `hs_test` link `libgmp.a` statically so compiled executables dynamically depend only on standard Linux `glibc` libraries (`libc.so.6`, `libm.so.6`, `libdl.so.2`, `libpthread.so.0`) and run under `env -i PATH=/nonexistent`.
- **Compiled C11 compiler wrapper**: Bridges GHC, `hsc2hs`, and Cabal `./configure` to Bazel's `cc_toolchain` through a small compiled C11 binary (`ghc_cc_wrapper`) instead of a Python wrapper script.
- **Two-phase Hackage lockfiles**: Uses `@rules_hs//tools/lock:lock` (built by `rules_hs` itself against GHC's built-in `Cabal-syntax` library) to generate a deterministic `hackage.lock.json`, read in Starlark (`reproducible = True`) and compiled with a 5-stage `hs_cabal_library` pipeline rather than running `Setup.hs`.
- **Small non-dev `MODULE.bazel` graph**: Directly depends on four Bazel modules (`platforms`, `bazel_skylib`, `rules_cc`, and `gmp`).

> **New to Bazel Rulesets or Haskell?** Our documentation assumes no prior Bazel ruleset-authoring or Haskell/GHC background:
> - **[Bazel Ruleset Primer](docs/content/internals/bazel-rules-primer.md)** — Loading, Analysis, and Execution phases, `dev_dependency = True`, lazy Bzlmod hubs, providers and transitive sets, directory outputs, host tool vs. target configurations, and `CcInfo` C/C++ interop.
> - **[Haskell & GHC Primer](docs/content/internals/haskell-and-ghc-primer.md)** — `GHC` vs. `Cabal` vs. `Hackage` vs. `Stackage`, GHC's 41 boot libraries, `.hi` compiler interfaces and relocatable package databases, RTS C linking, `gmp` and `libtinfo`, `hsc2hs`/Alex/Happy, Template Haskell, and Haddock.
> - **[Dependency Decisions & `MODULE.bazel` Anatomy](docs/content/internals/dependencies.md#module-bazel-anatomy)** — Plain-English explanation of every dependency across `rules_hs`, `examples/size`, and `//docs`, why it is needed, and what would fail without it.

---

## What Is Supported, Planned, and Out of Scope

### Supported Today

- **Build, test, and documentation rules**: `hs_library`, `hs_binary`, `hs_test`, `hs_haddock`, `hs_toolchain_library`, and `hs_cabal_library`.
- **Platforms and GHC versions**: Linux `x86_64` (tested in CI on bare Debian 12, Ubuntu 24.04, and Rocky Linux 9 containers with no host compilers installed) and Linux `arm64`, with official GHC `9.10.3` (default) and `9.12.4` binary distributions.
- **Language and compiler features**: `Haskell98`, `Haskell2010`, `GHC2021` (default), and `GHC2024` language editions; per-target GHC extensions and flags; private library modules (`hidden_modules`); `.hs-boot` mutually recursive modules; `.lhs` literate Haskell; single-threaded and `-threaded` GHC runtime; Bazel `data` runfiles; and Template Haskell (including cross-library splices and compile-time file reading such as `file-embed`).
- **C and C++ interoperability**: `foreign import ccall` and `CApiFFI`, inline `c_sources` (C, C++, and assembly), `cc_deps` (`cc_library` targets from your repository or the Bazel Central Registry), and compatibility with any Bazel `cc_toolchain` (`hermetic_cc_toolchain` `zig cc`, `toolchains_llvm`, GCC, or Clang).
- **Third-party Hackage and Stackage packages**: Lockfile generation via `@rules_hs//tools/lock:lock` and lazy per-package builds via `hackage.from_lock` and `hackage.override`, supporting:
  - Cabal `build-type: Simple` (over 95% of Hackage).
  - Cabal `build-type: Configure` (autoconf `./configure` scripts, such as `network`, `unix-time`, and `old-time`).
  - Cabal `build-type: Custom` packages whose custom setup only existed for `cabal-doctest` (automatically converted to `Simple`, such as `xml-conduit`).
  - C-only Cabal packages (`zlib-clib`, `libyaml-clib`), internal and Cabal 3.0 public sublibraries, `reexported-modules`, `Paths_<pkg>` and compile-time `data-files`, `.hsc` (`hsc2hs`), and automatic source-bootstrapped `.x` (`alex`) and `.y`/`.ly` (`happy`) lexer and parser generation.
- **API documentation**: Haddock HTML, hyperlinked source views, QuickJump search index (`doc-index.json`), and cross-target `.haddock` interfaces via `hs_haddock`.

> **Minimal runnable examples and tests:** Every supported feature above has a standalone Bazel 9 example workspace and test suite in [`examples/`](examples/README.md) ([`quickstart`](examples/quickstart/README.md), [`ghc_9_12`](examples/ghc_9_12/README.md), [`language_features`](examples/language_features/README.md), [`c_interop`](examples/c_interop/README.md), [`llvm_toolchain`](examples/llvm_toolchain/README.md), [`system_cc_toolchain`](examples/system_cc_toolchain/README.md), [`hackage`](examples/hackage/README.md), [`haddock`](examples/haddock/README.md), and [`size`](examples/size/README.md)) plus rule and analysis tests under `tests/`.

### Not Supported Today — Planned

- **macOS (`macos_arm64`, `macos_x86_64`) and Windows (`windows_x86_64`) execution**: GHC download URLs, SHA-256 digests, and multi-OS lockfile `select()` branches are already generated, but macOS Mach-O library staging and Windows `.exe` wrapper and action support are not wired yet.
- **Interactive `ghci` REPL rule (`hs_repl`) and IDE setup (`haskell-language-server` / `hie.yaml`)**: Today `rules_hs` runs GHC in batch mode only; you cannot yet run `bazel run` to open an interactive `ghci` session for a target.
- **Interactive full-screen terminal UI (`terminfo`) by default**: `rules_hs` links a minimal `libtinfo` stub that puts `terminfo` into basic non-ANSI terminal mode so batch builds need no host `ncurses`; full-screen TUI applications (`vty` or `brick`) currently require supplying a real `ncurses` `cc_library` via `cc_deps` or `hackage.override`.
- **Static `musl` Linux builds (`linux_x86_64_musl`)** for zero-glibc `FROM scratch` containers.
- **GHC profiling (`-prof`) and code coverage (`HPC`) build modes**.
- **`c2hs` FFI preprocessor** and **GHC compiler plugins (`-fplugin`)**.

### Out of Scope (By Design)

- **Arbitrary `build-type: Custom` `Setup.hs` scripts**: Packages (under 1% of Hackage) that execute bespoke Haskell programs inside `Setup.hs` to generate code during library compilation are not run by `rules_hs`, because running `Setup.hs` collapses builds into an opaque single-action wrapper that breaks fine-grained C/`hsc2hs` caching and Bazel `CcInfo` propagation. Workaround: inspect what the script generates and supply flags or files via `hackage.override` or custom Bazel targets (see [Hackage & Lockfiles](docs/content/guide/hackage.md) and [Migration & Troubleshooting](docs/content/guide/troubleshooting-and-migration.md)).
- **Legacy Bazel `WORKSPACE` files and Bazel `< 9.0.0`**: `rules_hs` uses Bzlmod (`MODULE.bazel`) exclusively.
- **Nix / `rules_nixpkgs` toolchains**: `rules_hs` downloads SHA-256-pinned archives directly into Bazel's cache rather than reading `/nix/store` on the host.
- **Bundling Python, Node.js, Java, or Protobuf rules inside `rules_hs`**: Keeping `rules_hs` free of foreign language runtimes keeps downstream `MODULE.bazel` graphs small; Protobuf or multi-language code generation belongs in separate companion rulesets.
- **GHCJS and WebAssembly compiler backends**.

---

## Comparison with `rules_haskell`

| Dimension | `rules_hs` | `tweag/rules_haskell` |
|---|---|---|
| **Bazel and module system** | Bazel 9+ (`>=9.0.0`), Bzlmod (`MODULE.bazel`) only | Targets Bazel 7 with legacy `WORKSPACE` roots; incompatible with Bazel 8 and 9 |
| **Direct non-dev `MODULE.bazel` deps** | 4 modules: `platforms`, `bazel_skylib`, `rules_cc`, `gmp` | Pulls `rules_java`, `protobuf`, `abseil-cpp`, `rules_proto`, `rules_nodejs`, `aspect_rules_js`, `rules_python`, `rules_sh` |
| **Linux GHC provisioning** | Starlark archive extraction + staged `@gmp` and `libtinfo.so.6` stub; compatible with remote execution | Bindist runs host `./configure && make install` (needs host `libgmp-dev`/`libtinfo`); sandboxed mode relies on `rules_nixpkgs` (`/nix/store`) |
| **C compiler adapter** | Compiled C11 binary (`ghc_cc_wrapper`), no Python dependency | `cc_wrapper.py.tpl`, pulling `rules_python` into compile and link actions |
| **Third-party Hackage builds** | 5-stage `hs_cabal_library` (`Simple` and `Configure`; arbitrary `Custom` `Setup.hs` out of scope) | Single Python wrapper (`cabal_wrapper.py`) running `runghc Setup.hs` (supports `Custom` `Setup.hs`, at the cost of per-file caching) |
| **Dependency pinning and boot libs** | `@rules_hs//tools/lock:lock` (built by `rules_hs` using GHC boot `Cabal-syntax`) + automatic `@hs_boot` and `@hackage` boot targets | External `stack` binary via `stack_snapshot` + manual `haskell_toolchain_library` declarations |
| **Linux binary runtime deps** | Static `libgmp.a`; dynamic dependencies limited to base `glibc` (`libc`, `libm`, `libdl`, `libpthread`) | Dynamic linking with `rpath` rewriting on bindist toolchains (`fully_static_link = False`) |

> See [Comparison with Other Haskell Build Rulesets](docs/content/internals/rulesets-comparison.md) for the full architectural comparison across `rules_hs`, `tweag/rules_haskell`, Buck2's `prelude/haskell` and `buck2-haskell`, Please Build, `haskell.nix`, and Cabal/Stack wrappers.

---

## Quickstart

**Prerequisites**: [Bazelisk](https://github.com/bazelbuild/bazelisk) (Bazel `>= 9.0.0`). On Linux, no host `ghc`, `cabal`, `stack`, `gcc`, `clang`, `libgmp-dev`, `libtinfo-dev`, or `zlib1g-dev` is required.

### 1. Boot-Library Project

Create `.bazelversion`:

```text
9.3.3
```

Create `.bazelrc`:

```ini
common --enable_platform_specific_config
common --enable_runfiles
common --incompatible_strict_action_env
common --test_output=errors

# Shared Zig compiler cache mount when using hermetic_cc_toolchain
build:linux --repo_env=HERMETIC_CC_TOOLCHAIN_CACHE_PREFIX=/tmp/zig-cc-cache
build:linux --sandbox_add_mount_pair=/tmp
```

Create `MODULE.bazel` (until `rules_hs` is published to the Bazel Central Registry, point `git_override` at this repository or use `local_path_override`):

```starlark
module(
    name = "my_hs_project",
    version = "0.1.0",
    bazel_compatibility = [">=9.0.0"],
)

bazel_dep(name = "rules_hs", version = "0.1.0")
git_override(
    module_name = "rules_hs",
    remote = "https://github.com/kaycebasques/hs.git",
    commit = "<commit-sha>",
)

# Self-contained Linux C/C++ toolchain (zig cc) — or register your own cc_toolchain.
bazel_dep(name = "hermetic_cc_toolchain", version = "4.3.0")

cc_toolchains = use_extension("@hermetic_cc_toolchain//toolchain:ext.bzl", "toolchains")
use_repo(cc_toolchains, "zig_sdk")

register_toolchains(
    "@zig_sdk//toolchain:linux_amd64_gnu.2.32",
    "@zig_sdk//toolchain:linux_arm64_gnu.2.32",
    "@zig_sdk//toolchain/...",
    "@zig_sdk//libc_aware/toolchain/...",
)

# GHC toolchain + automatic @hs_boot targets for all 41 GHC boot packages.
hs = use_extension("@rules_hs//hs:extensions.bzl", "hs")
hs.toolchain(ghc_version = "9.10.3")
use_repo(hs, "hs_boot", "hs_toolchains")
register_toolchains("@hs_toolchains//:all")
```

Create `BUILD.bazel`:

```starlark
load("@rules_hs//hs:defs.bzl", "hs_binary", "hs_library", "hs_test")

hs_library(
    name = "greet",
    srcs = ["src/Greet.hs"],
    hs_source_dirs = ["src"],
    deps = [
        "@hs_boot//:base",
        "@hs_boot//:text",
    ],
)

hs_binary(
    name = "hello",
    srcs = ["src/Main.hs"],
    hs_source_dirs = ["src"],
    deps = [
        ":greet",
        "@hs_boot//:base",
        "@hs_boot//:text",
    ],
)

hs_test(
    name = "greet_test",
    srcs = ["test/GreetTest.hs"],
    hs_source_dirs = ["test"],
    deps = [
        ":greet",
        "@hs_boot//:base",
    ],
)
```

Build and run:

```bash
bazel test //...
bazel run //:hello
```

### 2. Third-Party Hackage Project

**Step 1 — Generate `hackage.lock.json`** using `@rules_hs//tools/lock:lock` (built by `rules_hs` itself using GHC's `Cabal-syntax` boot library; no host `cabal` or `stack` required):

```bash
bazel run @rules_hs//tools/lock:lock -- \
  --snapshot lts-24.67 \
  --package xml-conduit \
  --package http-client \
  --package http-client-tls \
  --package http-types \
  --package zlib \
  --package async \
  --flag zlib:bundled-c-zlib=true \
  --flag zlib:pkg-config=false \
  --output "$PWD/hackage.lock.json"
```

**Step 2 — Load the lockfile in `MODULE.bazel`**:

```starlark
hackage = use_extension("@rules_hs//hs:extensions.bzl", "hackage")
hackage.from_lock(
    name = "hackage",
    lockfile = "//:hackage.lock.json",
)
# Optional: attach BCR C libraries or extra flags to any locked Hackage package:
# hackage.override(
#     package = "zlib",
#     extra_cc_deps = ["@zlib//:zlib"],
# )
use_repo(hackage, "hackage")
```

**Step 3 — Depend on `@hackage//:...` in `BUILD.bazel`** (`@hackage` exposes both GHC boot packages and pinned Hackage packages under one namespace, downloading each Hackage archive lazily only when referenced):

```starlark
load("@rules_hs//hs:defs.bzl", "hs_binary")

hs_binary(
    name = "app",
    srcs = ["src/Main.hs"],
    hs_source_dirs = ["src"],
    deps = [
        "@hackage//:async",
        "@hackage//:base",
        "@hackage//:http-client",
        "@hackage//:http-client-tls",
        "@hackage//:text",
        "@hackage//:xml-conduit",
        "@hackage//:zlib",
    ],
)
```

---

## API Overview

### Rules (`@rules_hs//hs:defs.bzl`)

| Rule | Purpose | Key Attributes |
|---|---|---|
| `hs_library` | Compiles a Haskell library into `libHS<unit_id>.a` and a relocatable `ghc-pkg` package database, enforcing direct-dependency visibility (`-hide-all-packages` + direct `-package-id` flags). | `srcs`, `deps`, `cc_deps`, `c_sources`, `hdrs`, `include_dirs`, `hs_source_dirs`, `hidden_modules`, `default_language` (`"GHC2021"`), `default_extensions`, `ghc_opts`, `cpp_options`, `cc_options`, `data` |
| `hs_binary` | Compiles and links a Haskell executable statically against `libgmp.a` and transitive `CcInfo` C archives. | Same as `hs_library` (minus `hidden_modules`), plus `main_module` (`"Main"`) and `threaded` (`True`) |
| `hs_test` | Test executable variant of `hs_binary`, supporting `data` runfiles via `TEST_SRCDIR` and `RUNFILES_DIR`. | Same as `hs_binary` |
| `hs_haddock` | Generates HTML API documentation, hyperlinked source (`src/`), QuickJump search index (`doc-index.json`), and `.haddock` interfaces using GHC's bundled `haddock`. | `deps`, `haddock_deps`, `title`, `prologue`, `hyperlinked_source` (`True`), `quickjump` (`True`), `hoogle` (`False`), `haddock_opts`, `ghc_opts` |
| `hs_toolchain_library` | Exposes a GHC boot package from the active `HsToolchainInfo`. Automatically generated for every boot library in `@hs_boot` and `@hackage`. | `package_name` |
| `hs_cabal_library` | 5-stage Cabal package builder (used by generated `@hackage__<pkg>` repos): sandboxed `./configure`, `cabal_macros.h` + `Paths_*`, per-file `hsc2hs`, `cc_common.compile` (including C-only packages like `zlib-clib`), and `ghc --make -c`. | `package_name`, `component_name`, `version`, `srcs`, `hsc_srcs`, `c_sources`, `hdrs`, `install_includes`, `include_dirs`, `exposed_modules`, `other_modules`, `reexported_modules`, `build_type`, `configure_*`, `generate_paths_module`, `deps`, `extra_cc_deps` |

### Module Extensions (`@rules_hs//hs:extensions.bzl`)

- **`hs`**:
  - `hs.toolchain(ghc_version = "9.10.3", platforms = [])`: Downloads official GHC binary distributions (`"9.10.3"` default or `"9.12.4"`), replaces hardcoded `/usr/bin/*` paths in `lib/settings`, parses `lib/package.conf.d/*.conf`, and creates `@hs_toolchains` and `@hs_boot` (`reproducible = True`). Root module declarations override `rules_hs`'s default version.
- **`hackage`**:
  - `hackage.from_lock(name = "hackage", lockfile = "//:hackage.lock.json")`: Reads a lockfile generated by `@rules_hs//tools/lock:lock` using Starlark `json.decode` (`reproducible = True`) and creates hub repo `@<name>` plus lazy per-package `@<name>__<pkg>` repos.
  - `hackage.override(hub = "hackage", package = "...", extra_cc_deps = [], extra_ghc_opts = [], extra_cpp_options = [], extra_cc_options = [], configure_args = [])`: Attaches `cc_library` dependencies or compiler and `./configure` flags to any locked package.

### Providers (`@rules_hs//hs:providers.bzl`)

- `HsPackageInfo`: Direct package metadata (`name`, `version`, `unit_id`, `pkg_db`, `exposed_modules`, `is_boot`, `hs_lib`, `hi_dir`).
- `HsLinkInfo`: Transitive sets (`pkg_dbs`, `hs_libs`, `include_dirs`, `headers`) and merged `CcInfo`.
- `HsHaddockInfo`: Generated Haddock HTML directory output (`html_dir`), `.haddock` `interface`, documented `unit_ids`, and `transitive_haddocks`.
- `HsToolchainInfo`: Staged GHC binaries (`ghc`, `ghc_pkg`, `hsc2hs`, `haddock`, `ghc_iserv`), `libdir` directory output, RTS headers, `cc_wrapper`, static `gmp_static_lib`, parsed `boot_packages`, and bundled `boot_haddocks`.

---

## Showcase: `examples/size`

[`examples/size`](examples/size/README.md) is a standalone Bazel 9 application that counts unique documentation pages across XML `<urlset>`, recursive `<sitemapindex>`, and `.xml.gz` sitemaps over HTTP and HTTPS.

It compiles **69 pinned Hackage packages** (plus 41 GHC 9.10.3 boot packages) from [`examples/size/hackage.lock.json`](examples/size/hackage.lock.json), exercising:
- **`xml-conduit`** (pure-Haskell XML 1.0 parser with namespace handling and entity decoding)
- **`http-client` + `http-client-tls`** (pure-Haskell `tls` + `crypton`, with no OpenSSL C dependency)
- **`zlib` + bundled `zlib-clib`** (C-only Cabal package compiled via `cc_common.compile`, propagating `<zlib.h>` transitively to `streaming-commons`)
- **`async` + `QSem`** (bounded 4-way concurrent crawling)
- Autoconf `build-type: Configure` (`network`, `unix-time`, `old-time`), `hsc2hs`, `.hs-boot` mutually recursive modules (`cborg`, `tls`), internal sublibraries (`attoparsec:attoparsec-internal`), `CApiFFI`, and `TemplateHaskellQuotes`.

Run the offline unit, loopback HTTP end-to-end, and ELF runtime-dependency tests (and build Haddock API documentation):

```bash
cd examples/size
bazel test //...
bazel build //:size_haddock
```

Run live against a documentation sitemap over HTTPS:

```bash
bazel run //:size -- https://docs.stripe.com/sitemap.xml
```

Sample output:

```text
    5253 pages  (1 sitemap(s))  https://docs.stripe.com/sitemap.xml
```

`//:elf_hermeticity_test` verifies via `readelf -d` that `//:size` dynamically links only base `glibc` (`libc.so.6`, `libdl.so.2`, `libm.so.6`, `libpthread.so.0` — no `libgmp`, `libtinfo`, `libffi`, `libz`, `libssl`, `libcrypto`, or `libHS*.so`) and runs cleanly under `env -i PATH=/nonexistent`.

---

## C Toolchain Compatibility

`rules_hs` works with any Bazel Linux C/C++ toolchain: every rule resolves `@bazel_tools//tools/cpp:toolchain_type` through `rules_cc` (`find_cc_toolchain` + `cc_common`) and forwards `--sysroot` and `--target` flags into `ghc_cc_wrapper`. `hermetic_cc_toolchain` is marked `dev_dependency = True` in `rules_hs`'s own `MODULE.bazel`, so downstream projects choose their own C toolchain:

- **`hermetic_cc_toolchain` (`zig cc`)**: Register `@zig_sdk//toolchain:linux_amd64_gnu.2.32` and `@zig_sdk//toolchain:linux_arm64_gnu.2.32` ahead of `@zig_sdk//toolchain/...`. Selecting `gnu.2.32` satisfies both GHC `deb10` bindists (`glibc <= 2.28`) and BCR `m4`/`gmp` (`<sys/single_threaded.h>` requires `glibc >= 2.32` under Zig) while keeping binaries compatible with Debian 12 (2.36), Ubuntu 22.04/24.04 (2.35/2.39), and Rocky 9 (2.34).
- **`toolchains_llvm`**: Use any Debian `>= 10` (`glibc >= 2.28`) sysroot for Clang + `lld` builds with no `/tmp` sandbox cache mount needed.
- **System or remote-execution GCC / Clang toolchains**: Including custom enterprise or RBE C/C++ toolchains.

---

## Platform Support & Roadmap

| Platform | GHC `9.10.3` & `9.12.4` Bindist Table | Status |
|---|---|---|
| `linux_x86_64` | Wired in [`hs/private/ghc_versions.bzl`](hs/private/ghc_versions.bzl) | **Supported and CI-tested** (Debian 12, Ubuntu 24.04, Rocky 9) |
| `linux_arm64` | Wired in [`hs/private/ghc_versions.bzl`](hs/private/ghc_versions.bzl) | **Supported** (`SUPPORTED_PLATFORMS`) |
| `macos_arm64` | URL + SHA-256 cataloged; lockfile `select()` ready | Planned (Mach-O `@loader_path` staging and linker flags) |
| `macos_x86_64` | URL + SHA-256 cataloged; lockfile `select()` ready | Planned (Mach-O `@loader_path` staging and linker flags) |
| `windows_x86_64` | URL + SHA-256 cataloged | Planned (`.exe` layout and Windows `cc_wrapper`) |
| `linux_x86_64_musl` | `alpine3_12-linux-static-int_native` cataloged | Planned opt-in flavor for `FROM scratch` static binaries |

**Template Haskell**: `rules_hs` supports `TemplateHaskellQuotes`, boot-package splices, same-library cross-module splices, and cross-library / Hackage Template Haskell splices (`aeson`, `file-embed`, `skylighting`, `pandoc`, C FFI / `CApiFFI`, and `runIO` across multi-hop library chains; verified in `//tests/rules/th:th_test`, `//tests/rules/th:cross_lib_th_test`, and `//tests/rules/th:cross_lib_th_elf_test`). Libraries compile with `-dynamic-too` and isolate shared TH `.so` objects under `<name>.pkgdb/dyn` (`dynamic-library-dirs`), so `hs_binary` and `hs_test` executables still link static `.a` archives and carry dynamic dependencies only on base `glibc`.

---

## Documentation

**Live site**: [**https://kaycebasques.github.io/hs/**](https://kaycebasques.github.io/hs/) (built and deployed on push to `main` via [`.github/workflows/pages.yml`](.github/workflows/pages.yml), including mounted Haddock API docs at [`/haddock/lock/`](https://kaycebasques.github.io/hs/haddock/lock/index.html)).

The documentation site is built by `rules_hs` itself without Python or Node.js (see [`docs/README.md`](docs/README.md)):

- **Hakyll + Pandoc + Skylighting** (`docs/site.hs`) rendering Markdown guides, Starlark reference pages, and architecture docs under [`docs/content/`](docs/content/index.md).
- **GHC Haddock (`hs_haddock`)** generating Haskell library API reference pages, hyperlinked source, and QuickJump search (`//tools/lock:lock_haddock`, mounted into the site at `/haddock/lock/`).

```bash
# Build the static HTML documentation site (including mounted /haddock/lock/ API docs)
bazel build //docs:site

# Build standalone Haddock API docs for //tools/lock
bazel build //tools/lock:lock_haddock

# Serve the documentation site locally (http://127.0.0.1:8000 by default)
bazel run //docs:serve

# Run the documentation site and link-check test suite
bazel test //docs:...
```

### Documentation Sections

- **Documentation Authoring & Site Guide**: [`docs/README.md`](docs/README.md)
- **Overview & Project Scope**: [`docs/content/index.md`](docs/content/index.md)
- **User Guide** ([`docs/content/guide/`](docs/content/guide/quickstart.md)):
  - [Quickstart](docs/content/guide/quickstart.md) · [Hackage & Lockfiles](docs/content/guide/hackage.md) · [C FFI & Toolchains](docs/content/guide/c-interop-and-toolchains.md) · [Language, RTS, Runfiles & TH](docs/content/guide/language-rts-runfiles-th.md) · [Showcase: `examples/size`](docs/content/guide/showcase-size.md) · [Migration & Troubleshooting](docs/content/guide/troubleshooting-and-migration.md)
- **API & CLI Reference** ([`docs/content/reference/`](docs/content/reference/rules.md)):
  - [Rules Reference](docs/content/reference/rules.md) · [Extensions & Providers](docs/content/reference/extensions-and-providers.md) · [Lock Generator CLI](docs/content/reference/lock-cli.md)
- **Internals & Architecture** ([`docs/content/internals/`](docs/content/internals/overview.md)):
  - [Bazel Ruleset Primer](docs/content/internals/bazel-rules-primer.md) · [Haskell & GHC Primer](docs/content/internals/haskell-and-ghc-primer.md) · [Architecture Overview](docs/content/internals/overview.md) · [Comparison with Other Rulesets](docs/content/internals/rulesets-comparison.md) · [Hermeticity & Toolchain](docs/content/internals/hermeticity.md) · [Providers & Action Graph](docs/content/internals/providers-and-actions.md) · [Hackage & Cabal Pipeline](docs/content/internals/ecosystem-and-hackage.md) · [Cross-OS & Platforms](docs/content/internals/cross-os-and-platforms.md) · [Hakyll & Haddock Docs](docs/content/internals/docs-engine.md) · [Dependency Decisions](docs/content/internals/dependencies.md)
- **Standalone Feature Examples & Index**: [`examples/README.md`](examples/README.md)
- **Standalone Sitemap Counter Showcase**: [`examples/size/README.md`](examples/size/README.md)

## License

Apache License 2.0 ([`LICENSE`](LICENSE))
