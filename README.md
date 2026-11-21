# `rules_hs`

Modern, **Bzlmod-only** Bazel 9 ruleset for Haskell (`bazel_compatibility = [">=9.0.0"]`).

`rules_hs` builds Haskell libraries, executables, tests, and third-party Hackage packages **100% hermetically on Linux without Nix, without `WORKSPACE`, without a Python runtime wrapper, and without host GHC, Cabal, Stack, GCC, Clang, or C `-dev` libraries**.

- **Nix-free hermetic Linux GHC**: Pure-Starlark extraction of official GHC `9.10.3` / `9.12.4` bindists (zero `./configure && make install`), `$ORIGIN`-staged with BCR `gmp` (`libgmp.so.10`) and a minimal 8-symbol `libtinfo.so.6` stub (zero `LD_LIBRARY_PATH`, zero `patchelf`, RBE-friendly).
- **Portable static-GMP user binaries**: Executables link `libgmp.a` statically and carry `DT_NEEDED` limited strictly to base glibc (`libc.so.6`, `libm.so.6`, `libdl.so.2`, `libpthread.so.0`) — verified under `env -i PATH=/nonexistent`.
- **Zero Python runtime wrapper**: Bridges GHC, `hsc2hs`, and Cabal `./configure` to Bazel's `cc_toolchain` through a small compiled C11 binary (`ghc_cc_wrapper`).
- **Fine-grained Hackage builds**: Dogfoods GHC's boot `Cabal-syntax` library (`@rules_hs//tools/lock:lock`) to generate a deterministic `hackage.lock.json`, consumed by pure Starlark (`reproducible = True`) and built with a 5-stage `hs_cabal_library` pipeline instead of opaque `Setup.hs` wrappers.
- **Minimal non-dev `MODULE.bazel` graph**: Directly depends only on `platforms`, `bazel_skylib`, `rules_cc`, and `gmp`.

---

## Comparison with `rules_haskell`

| Dimension | `rules_hs` | `tweag/rules_haskell` |
|---|---|---|
| **Bazel & module system** | Bazel 9+ (`>=9.0.0`), Bzlmod-only, zero `WORKSPACE` files | Pins Bazel 7; legacy `WORKSPACE` roots; broken on Bazel 8/9 |
| **Direct non-dev `MODULE.bazel` deps** | 4 minimal modules: `platforms`, `bazel_skylib`, `rules_cc`, `gmp` | Leaks `rules_java`, `protobuf`, `abseil-cpp`, `rules_proto`, `rules_nodejs`, `aspect_rules_js`, `rules_python`, `rules_sh` |
| **Hermetic Linux GHC** | Nix-free pure-Starlark bindist + `$ORIGIN` staging (`@gmp` + `libtinfo.so.6` stub); RBE-friendly | Bindist runs host `./configure && make install` (needs apt `libgmp-dev`/`libtinfo5`); hermeticity requires `rules_nixpkgs` (`/nix/store` breaks RBE & BCR) |
| **C compiler adapter** | Native C11 binary (`ghc_cc_wrapper`), zero Python | `cc_wrapper.py.tpl`, pulls `rules_python` into every compile/link action |
| **3p Hackage builds** | Fine-grained 5-stage `hs_cabal_library` (`Configure`, codegen, parallel `hsc2hs`, `cc_common.compile`, `ghc --make -c` + relocatable `${pkgroot}` DB) | Single opaque Python `cabal_wrapper.py` running `runghc Setup.hs` with TreeArtifact workarounds |
| **Dependency pinning & boot libs** | Dogfooded boot-only `Cabal-syntax` lock generator (`@rules_hs//tools/lock:lock`); automatic `@hs_boot` & `@hackage` boot targets | External `stack` / `stack_snapshot` pinning + manual `haskell_toolchain_library` boilerplate |
| **Linux binary runtime deps** | Static `libgmp.a`; `DT_NEEDED` strictly base glibc (`libc`, `libm`, `libdl`, `libpthread`) | Dynamic linking / `$ORIGIN` rpath rewriting (`fully_static_link = False` on bindists) |

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

# Hermetic Linux C/C++ toolchain (zig cc) — or bring your own cc_toolchain.
bazel_dep(name = "hermetic_cc_toolchain", version = "4.3.0")

cc_toolchains = use_extension("@hermetic_cc_toolchain//toolchain:ext.bzl", "toolchains")
use_repo(cc_toolchains, "zig_sdk")

register_toolchains(
    "@zig_sdk//toolchain:linux_amd64_gnu.2.32",
    "@zig_sdk//toolchain:linux_arm64_gnu.2.32",
    "@zig_sdk//toolchain/...",
    "@zig_sdk//libc_aware/toolchain/...",
)

# Hermetic GHC toolchain + automatic @hs_boot targets for all GHC boot packages.
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

**Step 1 — Generate `hackage.lock.json`** using the dogfooded `Cabal-syntax` lock generator (no host `cabal` or `stack` required; runs using Bazel's hermetic GHC):

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

**Step 3 — Depend on `@hackage//:...` uniformly in `BUILD.bazel`** (`@hackage` exposes both GHC boot packages and pinned Hackage packages under one namespace, fetching each Hackage tarball lazily only when referenced):

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
| `hs_library` | Compiles a Haskell library into `libHS<unit_id>.a` and a relocatable `${pkgroot}` `ghc-pkg` DB with strict direct-dependency visibility (`-hide-all-packages` + direct `-package-id`s). | `srcs`, `deps`, `cc_deps`, `c_sources`, `hdrs`, `include_dirs`, `hs_source_dirs`, `hidden_modules`, `default_language` (`"GHC2021"`), `default_extensions`, `ghc_opts`, `cpp_options`, `cc_options`, `data` |
| `hs_binary` | Compiles and links a hermetic Haskell executable (statically linked against `libgmp.a` and transitive `CcInfo` archives). | Same as `hs_library` (minus `hidden_modules`), plus `main_module` (`"Main"`) and `threaded` (`True`) |
| `hs_test` | Test executable variant of `hs_binary`, supporting `data` runfiles via `TEST_SRCDIR` / `RUNFILES_DIR`. | Same as `hs_binary` |
| `hs_toolchain_library` | Exposes a GHC boot package from the active `HsToolchainInfo`. Automatically generated for every boot library in `@hs_boot` and `@hackage`. | `package_name` |
| `hs_cabal_library` | Fine-grained 5-stage Cabal package builder (used by generated `@hackage__<pkg>` repos): sandboxed `./configure`, `cabal_macros.h` + `Paths_*`, parallel `hsc2hs`, native `cc_common.compile` (including C-only packages like `zlib-clib`), and `ghc --make -c`. | `package_name`, `component_name`, `version`, `srcs`, `hsc_srcs`, `c_sources`, `hdrs`, `install_includes`, `include_dirs`, `exposed_modules`, `other_modules`, `reexported_modules`, `build_type`, `configure_*`, `generate_paths_module`, `deps`, `extra_cc_deps` |

### Module Extensions (`@rules_hs//hs:extensions.bzl`)

- **`hs`**:
  - `hs.toolchain(ghc_version = "9.10.3", platforms = [])`: Downloads official GHC bindists (`"9.10.3"` default or `"9.12.4"`), strips host `/usr/bin/*` paths in `lib/settings`, parses `lib/package.conf.d/*.conf`, and creates `@hs_toolchains` and `@hs_boot` (`reproducible = True`). Root module declarations override `rules_hs`'s own default.
- **`hackage`**:
  - `hackage.from_lock(name = "hackage", lockfile = "//:hackage.lock.json")`: Reads a lockfile generated by `@rules_hs//tools/lock:lock` using pure Starlark `json.decode` (`reproducible = True`) and creates hub repo `@<name>` plus lazy per-package `@<name>__<pkg>` repos.
  - `hackage.override(hub = "hackage", package = "...", extra_cc_deps = [], extra_ghc_opts = [], extra_cpp_options = [], extra_cc_options = [], configure_args = [])`: Attaches BCR `cc_library` deps or compiler/configure overrides to any locked package.

### Providers (`@rules_hs//hs:providers.bzl`)

- `HsPackageInfo`: Direct package metadata (`name`, `version`, `unit_id`, `pkg_db`, `exposed_modules`, `is_boot`, `hs_lib`, `hi_dir`).
- `HsLinkInfo`: Transitive `depset`s (`pkg_dbs`, `hs_libs`, `include_dirs`, `headers`) and merged `CcInfo`.
- `HsToolchainInfo`: Staged GHC binaries (`ghc`, `ghc_pkg`, `hsc2hs`, `ghc_iserv`), `libdir` TreeArtifact, RTS headers, `cc_wrapper`, static `gmp_static_lib`, and parsed `boot_packages`.

---

## Showcase: `examples/size`

[`examples/size`](examples/size/README.md) is a standalone Bzlmod Bazel 9 application that counts unique documentation pages across XML `<urlset>`, recursive `<sitemapindex>`, and `.xml.gz` sitemaps over HTTP/HTTPS.

It compiles **69 pinned Hackage packages** (plus 41 GHC 9.10.3 boot packages) from [`examples/size/hackage.lock.json`](examples/size/hackage.lock.json), exercising:
- **`xml-conduit`** (pure-Haskell XML 1.0 with namespaces and entity decoding)
- **`http-client` + `http-client-tls`** (pure-Haskell `tls` + `crypton`, zero OpenSSL)
- **`zlib` + bundled `zlib-clib`** (C-only Cabal package compiled via `cc_common.compile`, propagating `<zlib.h>` transitively to `streaming-commons`)
- **`async` + `QSem`** (bounded 4-way concurrent crawling)
- Autoconf `build-type: Configure` (`network`, `unix-time`, `old-time`), `hsc2hs`, `.hs-boot` cycles (`cborg`, `tls`), internal sublibraries (`attoparsec:attoparsec-internal`), `CApiFFI`, and `TemplateHaskellQuotes`.

Run the offline unit, loopback HTTP E2E, and ELF hermeticity tests:

```bash
cd examples/size
bazel test //...
```

Run live against a real documentation sitemap over HTTPS:

```bash
bazel run //:size -- https://docs.stripe.com/sitemap.xml
```

Sample output:

```text
    5253 pages  (1 sitemap(s))  https://docs.stripe.com/sitemap.xml
```

`//:elf_hermeticity_test` verifies via `readelf -d` that `//:size` dynamically links **only** base glibc (`libc.so.6`, `libdl.so.2`, `libm.so.6`, `libpthread.so.0` — zero `libgmp`, `libtinfo`, `libffi`, `libz`, `libssl`, `libcrypto`, or `libHS*.so`) and executes cleanly under `env -i PATH=/nonexistent`.

---

## C Toolchain Agnosticism

`rules_hs` is **C-toolchain agnostic**: every rule resolves `@bazel_tools//tools/cpp:toolchain_type` through `rules_cc` (`find_cc_toolchain` + `cc_common`) and forwards detected `--sysroot` and `--target` flags into `ghc_cc_wrapper`. `hermetic_cc_toolchain` is strictly a `dev_dependency = True` in `rules_hs`'s own `MODULE.bazel`.

You can pair `rules_hs` with:
- **`hermetic_cc_toolchain` (`zig cc`)**: Register `@zig_sdk//toolchain:linux_amd64_gnu.2.32` and `@zig_sdk//toolchain:linux_arm64_gnu.2.32` ahead of `@zig_sdk//toolchain/...`. Selecting `gnu.2.32` satisfies both GHC `deb10` bindists (`glibc <= 2.28`) and BCR `m4`/`gmp` (`<sys/single_threaded.h>` requires `glibc >= 2.32` under Zig) while keeping binaries portable across Debian 12 (2.36), Ubuntu 22.04/24.04 (2.35/2.39), and Rocky 9 (2.34).
- **`toolchains_llvm`**: Use any Debian `>= 10` (`glibc >= 2.28`) sysroot for pure Clang + `lld` builds with zero `/tmp` sandbox mounts.
- **Any standard Linux `cc_toolchain`**: Including custom enterprise/RBE Clang or GCC toolchains.

---

## Platform Support & Roadmap

| Platform | GHC `9.10.3` & `9.12.4` Bindist Table | Status |
|---|---|---|
| `linux_x86_64` | Wired in [`hs/private/ghc_versions.bzl`](hs/private/ghc_versions.bzl) | **Supported & CI-tested** (Debian 12, Ubuntu 24.04, Rocky 9) |
| `linux_arm64` | Wired in [`hs/private/ghc_versions.bzl`](hs/private/ghc_versions.bzl) | **Wired** (`SUPPORTED_PLATFORMS`) |
| `macos_arm64` | URL + SHA-256 cataloged; lockfile `select()` ready | Planned (Mach-O `@loader_path` staging & linker flags) |
| `macos_x86_64` | URL + SHA-256 cataloged; lockfile `select()` ready | Planned (Mach-O `@loader_path` staging & linker flags) |
| `windows_x86_64` | URL + SHA-256 cataloged | Planned (`.exe` layout & Windows `cc_wrapper`) |
| `linux_x86_64_musl` | `alpine3_12-linux-static-int_native` cataloged | Planned opt-in flavor for `FROM scratch` static binaries |

**Known limitation**: `TemplateHaskellQuotes`, boot-package splices, and same-library cross-module Template Haskell splices work today (`//tests/rules/th:th_test`). Cross-library Template Haskell splices (executing a splice defined in a separate `hs_library` target) are planned via opt-in `-dynamic-too` shared archives and `dynamic-library-dirs`.

---

## Documentation & License

- **Architecture & Prior-Art Deep Dive**: [`docs/architecture.md`](docs/architecture.md)
- **Standalone Sitemap Counter Showcase**: [`examples/size/README.md`](examples/size/README.md)
- **License**: Apache License 2.0 ([`LICENSE`](LICENSE))
