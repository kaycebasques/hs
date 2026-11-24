---
title: "Extensions and providers reference"
description: "Starlark reference for the hs and hackage Bzlmod module extensions, public providers (HsPackageInfo, HsLinkInfo, HsHaddockInfo, HsReplInfo, HsToolchainInfo), and toolchain type."
section: reference
nav_title: "Extensions and providers"
order: 20
---

This page documents the [Bzlmod](https://bazel.build/external/overview) [module extensions](https://bazel.build/external/extension) you call in [`MODULE.bazel`](https://bazel.build/external/module) (`hs` and `hackage`), the five public [Starlark](https://bazel.build/rules/language) [providers](https://bazel.build/extending/rules#providers) exposed for custom rules and [aspects](https://bazel.build/extending/aspects), and the `@rules_haskell//haskell:toolchain_type` [Bazel toolchain type](https://bazel.build/extending/toolchains).

Looking for build rule attributes or the lockfile CLI? See [Rules reference](rules.md) and [Lock generator CLI reference](lock-cli.md). For step-by-step workspace setup and Hackage workflows, read [Quickstart](../guide/quickstart.md) and [Hackage and lockfiles](../guide/hackage.md); for internal architecture details, see [Providers and action graph](../internals/providers-and-actions.md) and [Hackage and Cabal pipeline](../internals/ecosystem-and-hackage.md).

---

## `hs` module extension {#hs}

Use the `hs` module extension in `MODULE.bazel` to download a SHA-256-pinned official GHC distribution and expose GHC's built-in boot libraries (`@hs_boot//:base`, `@hs_boot//:text`, and so on) without installing GHC on the host machine.

`hs` runs entirely in Starlark and returns [`module_ctx.extension_metadata(reproducible = True)`](https://bazel.build/external/extension#specify-reproducibility-and-use-facts), so [`MODULE.bazel.lock`](https://bazel.build/external/lockfile) stays identical across developer machines and CI. For how `rules_haskell` sanitizes GHC archives and stages runtime libraries, see [Hermeticity and toolchain](../internals/hermeticity.md).

- **Load from:** `@rules_haskell//haskell:extensions.bzl`
- **Repositories created:**
  - `hs_toolchains`: Contains Bazel `toolchain()` targets for all configured platforms. Activate them in `MODULE.bazel` with [`register_toolchains("@hs_toolchains//:all")`](https://bazel.build/rules/lib/globals/module#register_toolchains).
  - `hs_boot`: Contains one [`hs_toolchain_library`](rules.md#hs_toolchain_library) target per GHC boot library (such as `@hs_boot//:base`, `@hs_boot//:bytestring`, `@hs_boot//:text`, and `@hs_boot//:Cabal-syntax`) for projects that don't use Hackage or want to distinguish boot dependencies from `@hackage` dependencies.
  - `ghc_<ver>_<platform>`: Internal per-platform compiler repositories (such as `ghc_9_10_3_linux_x86_64` and `ghc_9_10_3_linux_arm64`), downloaded lazily by Bazel only for the active execution platform.
- **Root-module precedence:** If both your root `MODULE.bazel` and a dependency (including `rules_haskell` itself) call `hs.toolchain(...)`, your root module's first `hs.toolchain` tag always wins.

```starlark
hs = use_extension("@rules_haskell//haskell:extensions.bzl", "hs")
hs.toolchain(ghc_version = "9.10.3")
use_repo(hs, "hs_boot", "hs_toolchains")

register_toolchains("@hs_toolchains//:all")
```

### `hs.toolchain` {#hs-toolchain}

Use `hs.toolchain` to select a GHC release version and the host/target OS-CPU platforms registered in `@hs_toolchains`. If you're fine with the default GHC `"9.10.3"` on Linux `x86_64` and `arm64`, you can omit `hs.toolchain(...)`; call it explicitly to pin `"9.12.4"` or restrict platforms.

| Attribute | Type | Default | Required | Description |
|---|---|---|---|---|
| `ghc_version` | `str` | `"9.10.3"` | No | Official GHC compiler version to download and register. Supported versions: `"9.10.3"` (default, 41 boot packages, paired with Stackage LTS 24.x) and `"9.12.4"` (42 boot packages including `file-io`). Match this to the `ghc_version` in your `hackage.lock.json` when testing newer GHC releases. |
| `platforms` | `list[str]` | `[]` | No | Subset of platform keys (`"linux_x86_64"`, `"linux_arm64"`) to generate `toolchain()` definitions for. Leave empty (`[]`) in multi-architecture repositories so both `x86_64` and `arm64` Linux machines work without extra configuration (Bazel still downloads only the bindist matching the current machine); set `["linux_x86_64"]` only to restrict registration to one architecture. |

---

## `hackage` module extension {#hackage}

Use the `hackage` module extension in `MODULE.bazel` whenever your project imports third-party Haskell libraries from Hackage.

`hackage` reads a committed `hackage.lock.json` file (generated at development time with [`//tools/lock:lock`](lock-cli.md)) directly in Starlark, making zero network requests and running zero external tools during [`bazel mod`](https://bazel.build/external/mod-command) evaluation (`reproducible = True`). It creates a lightweight hub repository (conventionally `@hackage`) so [`BUILD.bazel`](https://bazel.build/concepts/build-files) files can write uniform `@hackage//:<pkg>` labels for both GHC boot libraries and Hackage packages, backed by lazy per-package repositories that Bazel fetches only when a target depends on them. For repository generation internals, see [Hackage and Cabal pipeline](../internals/ecosystem-and-hackage.md).

- **Load from:** `@rules_haskell//haskell:extensions.bzl`
- **Repositories created per `from_lock` hub `<name>`:**
  - `<name>` (default `"hackage"`): Unified hub repository exposing [`hs_toolchain_library`](rules.md#hs_toolchain_library) targets for non-overridden GHC boot packages (`@<name>//:base`), [`alias()`](https://bazel.build/reference/be/general#alias) targets for every locked Hackage package (`@<name>//:<pkg>`), and `alias()` targets for Cabal sublibraries (`@<name>//:<pkg>__<sublib>`).
  - `<name>__<sanitized_pkg>`: Lazy per-package source repository (mapping `-` and `.` to `_`, such as `hackage__http_client_tls`) containing the generated [`hs_cabal_library`](rules.md#hs_cabal_library) `BUILD.bazel` file. Bazel fetches it from Hackage only if reachable from your build targets.
- **Root-module precedence and multiple hubs:** If both the root module and a dependency register `hackage.from_lock` with the same `name`, the root module's lockfile wins. Large monorepos can also register multiple independent hubs with distinct names (for example, `name = "hackage"` for production code and `name = "tools_hackage"` for developer tooling).

```starlark
hackage = use_extension("@rules_haskell//haskell:extensions.bzl", "hackage")
hackage.from_lock(
    name = "hackage",
    lockfile = "//:hackage.lock.json",
)
hackage.override(
    hub = "hackage",
    package = "zlib",
    extra_cc_deps = ["@zlib//:zlib"],
)
use_repo(hackage, "hackage")
```

### `hackage.from_lock` {#hackage-from_lock}

Use `hackage.from_lock` to register a hub repository backed by a committed `hackage.lock.json` file (`schema_version == 1`). You need one `hackage.from_lock` call—paired with [`use_repo(hackage, "<name>")`](https://bazel.build/rules/lib/globals/module#use_repo)—per lockfile in your workspace.

| Attribute | Type | Default | Required | Description |
|---|---|---|---|---|
| `name` | `str` | `"hackage"` | No | Repository name for the generated hub, imported via `use_repo(hackage, "<name>")` so `BUILD.bazel` targets can depend on `@<name>//:<pkg>`. Keep `"hackage"` for single-lockfile projects; set a custom name (such as `"docs_hackage"`) when maintaining multiple separate lockfiles in one workspace. |
| `lockfile` | `Label` | — | **Yes** | Label of the committed `hackage.lock.json` file produced by `@rules_haskell//tools/lock:lock` (for example, `"//:hackage.lock.json"`). |

### `hackage.override` {#hackage-override}

Use `hackage.override` to wire a Bazel [`cc_library`](https://bazel.build/reference/be/c-cpp#cc_library) dependency into a locked Hackage package (instead of system `pkg-config` or OS C libraries) or pass extra compiler and `./configure` flags without hand-editing `hackage.lock.json`. If multiple `hackage.override` tags target the same `(hub, package)` pair, their `extra_cc_deps` lists are deduplicated and their flag lists are concatenated in module evaluation order.

| Attribute | Type | Default | Required | Description |
|---|---|---|---|---|
| `hub` | `str` | `"hackage"` | No | Name of the `hackage.from_lock` hub containing the package you want to customize. Leave as `"hackage"` unless you declared a custom hub `name`. |
| `package` | `str` | — | **Yes** | Exact upstream Cabal package name in `hackage.lock.json` (for example, `"zlib"`, `"digest"`, or `"network"`). |
| `extra_cc_deps` | `list[Label]` | `[]` | No | Bazel C/C++ library targets (`cc_library` or any rule providing [`CcInfo`](https://bazel.build/rules/lib/providers/CcInfo)) wired into this Hackage package's `extra_cc_deps` (for example, `["@zlib//:zlib"]` when `zlib` is locked with `--flag zlib:bundled-c-zlib=false` so it shares the same [BCR](https://bazel.build/external/registry#bazel-central-registry) C `zlib` as your C++ or Rust targets). |
| `extra_ghc_opts` | `list[str]` | `[]` | No | Extra GHC compiler flags appended to `ghc_opts` when compiling this package's Haskell modules (for example, tuning a package-specific codegen option). |
| `extra_cpp_options` | `list[str]` | `[]` | No | Extra C preprocessor `-D` macro definitions appended to `cpp_options` for `#ifdef` blocks in this package's `.hs` and `.hsc` files. |
| `extra_cc_options` | `list[str]` | `[]` | No | Extra C/C++ compiler flags appended to `cc_options` when compiling this package's `c_sources` (for example, `-Wno-...` when a C toolchain warns on older C code). |
| `configure_args` | `list[str]` | `[]` | No | Extra arguments passed to `/bin/sh ./configure` on `build_type == "Configure"` packages such as `network` (for example, `["--disable-largefile"]` or feature toggles). Ignored on `"Simple"` packages. |

---

## Public Starlark providers

If you only write `BUILD.bazel` and `MODULE.bazel` files, you don't need to import providers directly. Load them from `@rules_haskell//haskell:providers.bzl` when authoring custom Starlark rules, macros, or IDE and linter aspects (such as a code generator, packaging rule, or static-site bundler) that inspect or consume Haskell targets:

```starlark
load(
    "@rules_haskell//haskell:providers.bzl",
    "HsHaddockInfo",
    "HsLinkInfo",
    "HsPackageInfo",
    "HsReplInfo",
    "HsToolchainInfo",
)
```

> **Note:** The provider tables below use two Bazel types:
>
> - **[`TreeArtifact`](https://bazel.build/reference/glossary#tree-artifact)** (shown as [`File`](https://bazel.build/rules/lib/builtins/File) in Starlark): A single Bazel output representing an entire directory of generated files (such as `<name>.pkgdb/` or a Haddock HTML folder) tracked as one unit because its exact filenames are produced during action execution.
> - **[`depset`](https://bazel.build/extending/depsets):** Bazel's immutable, memory-sharing directed acyclic graph set used to pass transitive files and flags up deep dependency trees in `O(1)` per rule without copying lists at every layer. Call `.to_list()` on a `depset` only inside action command builders or terminal rules.

### `HsPackageInfo` {#hspackageinfo}

`HsPackageInfo` carries **single-library (non-transitive) metadata** for one compiled Haskell library, GHC boot library, or C-only Cabal package. `rules_haskell` keeps `HsPackageInfo` separate from transitive [`HsLinkInfo`](extensions-and-providers.md#hslinkinfo) so direct dependencies alone are unlocked with `-package-id` and written into `cabal_macros.h` (`VERSION_<pkg>` and `MIN_VERSION_<pkg>`). For how rules merge direct and transitive providers, see [Providers and action graph](../internals/providers-and-actions.md).

| Field | Type | Description |
|---|---|---|
| `name` | `str` | Cabal package name (for example, `"base"`, `"http-client"`, or `"engine"` for an [`hs_library`](rules.md#hs_library)). Used when generating `VERSION_<pkg>` and `MIN_VERSION_<pkg>` C preprocessor macros and resolving `reexported_modules` package prefixes. |
| `version` | `str` | Dotted package version string (`"4.20.2.0"` for boot `base`, `"0.7.19"` for Hackage `http-client`, or `"0.0.0"` for in-repo [`hs_library`](rules.md#hs_library) targets). |
| `unit_id` | `str \| None` | Exact GHC **unit ID**—the unique package identifier passed to `ghc -package-id <unit_id>` to unlock this library's modules for `import` and namespace its compiled symbols (for example, `"zlib-0.7.1.1"` or `"u__Sengine_Cengine-0.0.0"`). `None` on C-only Cabal packages like `zlib-clib` that contain no Haskell modules. |
| `pkg_db` | `File \| None` | Self-contained `ghc-pkg` package database directory (`TreeArtifact` ending in `.pkgdb`) containing `<unit_id>.conf`, `package.cache`, compiled `.hi` files, and `-dynamic-too` `.so` libraries using `${pkgroot}` relative paths so it works in any [sandbox](https://bazel.build/docs/sandboxing). `None` for GHC boot packages (which live in `HsToolchainInfo.libdir`'s global database) and C-only Cabal packages. |
| `exposed_modules` | `list[str]` | Public dotted Haskell module names known at [Bazel analysis time](https://bazel.build/extending/concepts#evaluation-model). Populated for boot libraries and [`hs_cabal_library`](rules.md#hs_cabal_library); empty `[]` on [`hs_library`](rules.md#hs_library), which discovers module names from generated `.hi` files during action execution so you don't have to duplicate module lists in `BUILD.bazel`. |
| `is_boot` | `bool` | `True` when this target wraps a precompiled GHC boot package via [`hs_toolchain_library`](rules.md#hs_toolchain_library); `False` for workspace and Hackage libraries. |
| `hs_lib` | `File \| None` | Static object archive `libHS<unit_id>.a` produced for this library, or `None` for boot packages and C-only Cabal packages. |
| `hi_dir` | `File \| None` | Directory `TreeArtifact` (`<name>.pkgdb`, whose `hi/` subdirectory holds GHC's compiled `.hi` interface files—binary summaries of exported types, signatures, and cross-module inlining unfoldings). `None` for boot packages and C-only Cabal packages. |

### `HsLinkInfo` {#hslinkinfo}

`HsLinkInfo` carries the **full transitive compilation and linking closure** accumulated across a target and all of its dependencies via `depset`s. Even though GHC only lets you `import` direct `HsPackageInfo` dependencies, GHC still needs every transitive library's `.pkgdb` (`-package-db`) to look up re-exported types and cross-module inlinings during compilation, and the linker needs every transitive `libHS*.a` and native `CcInfo` C archive to produce a standalone executable.

| Field | Type | Description |
|---|---|---|
| `pkg_dbs` | `depset[File]` | Transitive `.pkgdb` package database directories passed to `ghc` via `-package-db` so GHC can read `.hi` type interfaces and load `.so` shared libraries for cross-library Template Haskell across the dependency graph. |
| `hs_libs` | `depset[File]` | Transitive static Haskell archives (`libHS*.a`) staged as action inputs when compiling Template Haskell or linking final executables (`hs_binary` and `hs_test`). |
| `include_dirs` | `depset[str]` | Transitive [execroot](https://bazel.build/remote/output-directories)-relative C header search directories passed via `-I` to `hsc2hs`, [`cc_common.compile`](https://bazel.build/rules/lib/toplevel/cc_common), and GHC (`CPP` and `CApiFFI`). |
| `headers` | `depset[File]` | Transitive public C header `File`s (from `hdrs`, Cabal `install-includes`, and `cc_deps`) staged into `hsc2hs`, `./configure`, `cc_common.compile`, and GHC sandboxes. |
| `cc_info` | `CcInfo` | Merged transitive `rules_cc` `CcInfo` provider carrying all C/C++ compilation contexts, static C archives (compiled `c_sources` and `cc_deps`), and C++ runtime linker flags. |

### `HsHaddockInfo` {#hshaddockinfo}

[`hs_haddock`](rules.md#hs_haddock) targets return `HsHaddockInfo` so downstream `hs_haddock` rules (via `haddock_deps`) can cross-link module and type references across libraries and custom packaging rules (like `docs/site.bzl`) can mount generated Haddock HTML directories into a larger documentation site.

| Field | Type | Description |
|---|---|---|
| `html_dir` | `File` | Output `TreeArtifact` directory (`<name>/`) containing `index.html`, per-module `<Module>.html` pages, `doc-index.json` (QuickJump), `linuwial.css`, and `src/<Module>.html` (hyperlinked source). |
| `interface` | `File` | Generated `<name>.haddock` binary interface file (`--dump-interface`) recording every exported type and function's HTML anchor so downstream `hs_haddock` targets can pass `--read-interface` and emit clickable cross-library links. |
| `unit_ids` | `depset[str]` | GHC unit IDs of the libraries documented directly by this `hs_haddock` target. |
| `transitive_haddocks` | `depset[struct]` | Transitive `depset` of `struct(html_dir, interface)` entries across this target and all upstream `haddock_deps`, useful when bundling a multi-library documentation portal into one archive. |

### `HsReplInfo` {#hsreplinfo}

[`hs_repl`](rules.md#hs_repl) targets return `HsReplInfo` so custom Starlark rules, test harnesses, or editor integrations can inspect the generated GHCi launcher script, static `.ghci` startup configuration, bytecode-loaded source files, and exposed compiled package unit IDs.

| Field | Type | Description |
|---|---|---|
| `executable` | `File` | Executable launcher script (`<name>`) that configures [`RUNFILES_DIR`](https://bazel.build/extending/rules#runfiles), `ghc_cc_wrapper`, per-session `TMPDIR`, and `*Module` startup scope before invoking staged `ghc` in `--interactive` or `-e` mode. |
| `ghci_script` | `File` | Generated `<name>.ghci` file containing the target's static `ghci_commands` lines (appended after automatic `:load` and `:module + *...` directives at session startup). |
| `interpreted_srcs` | `depset[File]` | `.hs` and `.lhs` source files loaded directly into GHCi bytecode for this session (including `srcs` and in-workspace `deps` when `interpret_deps = True`, excluding `.hs-boot` and `.lhs-boot` files). |
| `package_ids` | `depset[str]` | Direct compiled GHC unit IDs passed via `-package-id` (external `@hs_boot` and `@hackage` packages, `compiled_deps`, transitive compiled dependencies of interpreted targets, and in-workspace libraries when `interpret_deps = False`). |

### `HsToolchainInfo` {#hstoolchaininfo}

`HsToolchainInfo` exposes the resolved GHC compiler and interpreter binaries, `$ORIGIN`-staged runtime libraries, bundled Haddock assets, static GMP archive, native C11 `ghc_cc_wrapper`, and parsed boot library metadata for the active `(exec_platform, target_platform)` pair. Read this provider inside custom Starlark rules when invoking `ghc`, `runghc`, `ghc-pkg`, `hsc2hs`, or `haddock` in custom build actions. For how these binaries and libraries are staged, see [Hermeticity and toolchain](../internals/hermeticity.md).

| Field | Type | Description |
|---|---|---|
| `version` | `str` | Active GHC compiler version string (`"9.10.3"` or `"9.12.4"`). |
| `ghc` | `File` | `$ORIGIN`-staged `ghc` compiler and interactive REPL executable (`<prefix>/bin/ghc-<ver>`). Always pass `-B <hs_tc.libdir.path>` when invoking it in a custom action. |
| `ghc_pkg` | `File` | `$ORIGIN`-staged `ghc-pkg` package database registration tool (`<prefix>/bin/ghc-pkg-<ver>`), used to validate `.conf` files and write `package.cache`. |
| `hsc2hs` | `File` | `$ORIGIN`-staged `hsc2hs` C-FFI preprocessor executable (`<prefix>/bin/hsc2hs-ghc-<ver>`) for compiling `.hsc` templates into `.hs` files. |
| `haddock` | `File` | `$ORIGIN`-staged `haddock` documentation generator executable (`<prefix>/bin/haddock-ghc-<ver>`). |
| `runghc` | `File` | `$ORIGIN`-staged `runghc` standalone script-interpreter executable (`<prefix>/bin/runghc-<ver>`), used by `@rules_haskell//tools/ghci:runghc`. |
| `ghc_iserv` | `File \| None` | Optional staged out-of-process interpreter executable (`<prefix>/bin/ghc-iserv-dyn-ghc-<ver>`, also staged at `<prefix>/bin/ghc-iserv-dyn` so `-fexternal-interpreter` locates it automatically under `$topdir/../bin`), or `None` if the bindist omits an external interpreter. |
| `libdir` | `File` | Dereferenced staged GHC `lib/` directory `TreeArtifact` (passed to `ghc -B` and `haddock -B -l`) containing `settings`, global `package.conf.d/`, `html/` (Haddock CSS/JS themes), boot `.a`/`.so`/`.hi` files, `libgmp.so.10`, and `libtinfo.so.6`. |
| `template_hsc_h` | `File` | GHC's `template-hsc.h` C macro header required by `hsc2hs` (`--template=<path>`). |
| `rts_include_dir` | `str` | Execroot-relative path to GHC's runtime system (RTS) C header directory (`Rts.h`, `HsFFI.h`, `ghcversion.h`), added to `-I` whenever compiling C FFI files. |
| `rts_headers` | `depset[File]` | Bazel-tracked `File` handles for GHC's RTS and boot C headers, added to action `inputs` so sandboxed C, `hsc2hs`, and `./configure` actions can `#include "HsFFI.h"`. |
| `all_files` | `depset[File]` | Complete `depset` of all staged GHC binaries, `libdir`, static archives, and RTS headers—include in `transitive` action `inputs` whenever running any GHC tool. |
| `cc_wrapper` | `File` | Compiled native C11 `ghc_cc_wrapper` binary; pass to GHC via `-pgmc`, `-pgmcxx`, `-pgml`, `-pgma`, and `-pgmP` so C invocations route through Bazel's [`cc_toolchain`](https://bazel.build/reference/be/c-cpp#cc_toolchain). |
| `gmp_static_dir` | `str \| None` | Execroot-relative path to an isolated directory containing only static `libgmp.a` and static `libtinfo.a` (with zero `.so` files), passed via `-optl-L` when linking executables so user binaries never dynamically depend on `libgmp.so.10` or `libtinfo.so.6`; `None` when `bignum` is `"native"`. |
| `gmp_static_lib` | `File \| None` | Static `libgmp.a` archive file from `@gmp//:gmp` (stage into link action inputs alongside `gmp_static_dir`), or `None` when `bignum` is `"native"`. |
| `boot_packages` | `dict[str, dict]` | Parsed global boot library table keyed by Cabal name (`"base"`, `"text"`, and so on), mapping each to `{name, version, id, depends, exposed_modules}`. |
| `boot_haddocks` | `dict[str, File]` | Map from boot package name (such as `"base"`, `"Cabal-syntax"`, or `"text"`) to its prebuilt `.haddock` interface `File` shipped inside the GHC bindist (`doc/html/libraries/`). Used by [`hs_haddock`](rules.md#hs_haddock) so references to standard library types hyperlink offline without recompiling boot docs. |
| `bignum` | `str` | Active integer arithmetic backend (`"gmp"` or `"native"`). |
| `is_dynamic_ghc` | `bool` | `True` when the staged `ghc` compiler binary is dynamically linked (`deb10` Linux, macOS), indicating libraries should compile with `-dynamic-too` for Template Haskell; `False` on static compiler builds (`alpine3_12`, Windows). |
| `target_os` | `str` | Target operating system identifier (`"linux"`, `"macos"`, or `"windows"`). |
| `target_cpu` | `str` | Target CPU architecture identifier (`"x86_64"` or `"arm64"`). |
| `arch_libdir` | `str` | Platform library folder name inside `libdir` (for example, `"x86_64-linux-ghc-9.10.3"` or `"aarch64-linux-ghc-9.10.3"`). |

---

## Toolchain type (`@rules_haskell//haskell:toolchain_type`) {#toolchain_type}

Every Haskell rule resolves the active GHC compiler through the Bazel toolchain type `@rules_haskell//haskell:toolchain_type` (exported as the constant `TOOLCHAIN_TYPE` in `@rules_haskell//haskell:toolchain.bzl`).

When writing a custom Starlark rule that needs GHC, declare `toolchains = [TOOLCHAIN_TYPE]` on [`rule(...)`](https://bazel.build/extending/rules) and read [`HsToolchainInfo`](extensions-and-providers.md#hstoolchaininfo) from `ctx.toolchains[TOOLCHAIN_TYPE].hs`:

```starlark
load("@rules_haskell//haskell:toolchain.bzl", "TOOLCHAIN_TYPE")

def _my_custom_hs_rule_impl(ctx):
    hs_tc = ctx.toolchains[TOOLCHAIN_TYPE].hs
    # Access hs_tc.version, hs_tc.ghc, hs_tc.libdir, hs_tc.all_files, etc.
    ...

my_custom_hs_rule = rule(
    implementation = _my_custom_hs_rule_impl,
    toolchains = [TOOLCHAIN_TYPE],
)
```
