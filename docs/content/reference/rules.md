---
title: "Rules Reference"
description: "Complete Starlark rule and attribute reference for hs_library, hs_binary, hs_test, hs_toolchain_library, hs_cabal_library, and hs_toolchain."
section: reference
nav_title: "Rules Reference"
order: 10
---

Public user-facing build rules are loaded from `@rules_hs//hs:defs.bzl`:

```starlark
load(
    "@rules_hs//hs:defs.bzl",
    "hs_binary",
    "hs_cabal_library",
    "hs_library",
    "hs_test",
    "hs_toolchain_library",
)
```

Toolchain definition rules are loaded from `@rules_hs//hs:toolchain.bzl`:

```starlark
load("@rules_hs//hs:toolchain.bzl", "TOOLCHAIN_TYPE", "hs_toolchain")
```

::: {.note title="Common Bazel Attributes"}
In addition to the rule-specific attributes documented below, all rules accept standard Bazel common attributes (`name`, `visibility`, `tags`, `testonly`, `features`, `compatible_with`, `target_compatible_with`, `exec_compatible_with`), and `bzl:rule:hs_test` accepts standard Bazel test attributes (`size`, `timeout`, `flaky`, `local`, `shard_count`, `args`, `env`, `env_inherit`).
:::

---

## `hs_library` {#hs_library}

Compiles a Haskell library with strict direct-dependency visibility (`-hide-all-packages` plus `-package-id` for direct `deps`), producing a static archive `libHS<unit_id>.a` and a relocatable `${pkgroot}` `ghc-pkg` package database `<name>.pkgdb` (containing `.hi` interface files under `<name>.pkgdb/hi/`). Any attached `c_sources` and `hdrs` are compiled via `cc_common.compile` and propagated through `CcInfo`.

- **Load from**: `@rules_hs//hs:defs.bzl` (implemented in `hs/private/rules.bzl`)
- **Toolchains**: `@rules_hs//hs:toolchain_type`, `@bazel_tools//tools/cpp:toolchain_type`
- **Provides**: `DefaultInfo`, `bzl:provider:HsPackageInfo`, `bzl:provider:HsLinkInfo`, `CcInfo`

### Signature

```starlark
hs_library(
    name,
    srcs,
    deps = [],
    cc_deps = [],
    c_sources = [],
    hdrs = [],
    include_dirs = [],
    hs_source_dirs = [],
    hidden_modules = [],
    default_language = "GHC2021",
    default_extensions = [],
    ghc_opts = [],
    cpp_options = [],
    cc_options = [],
    data = [],
)
```

### Attributes

| Attribute | Type | Default | Required | Description |
|---|---|---|---|---|
| `name` | `Name` | — | **Yes** | Unique target name. Used to derive the Cabal package name (`name.replace("_", "-")`, version `"0.0.0"`) and sanitized GHC unit ID (`<repo>_<pkg>_<name>-0.0.0`). |
| `srcs` | `list[Label]` | — | **Yes** | Haskell source files (`.hs`, `.lhs`) and mutual-recursion boot interface files (`.hs-boot`, `.lhs-boot`). |
| `deps` | `list[Label]` | `[]` | No | Direct dependencies providing `bzl:provider:HsPackageInfo` (such as `bzl:rule:hs_library`, `bzl:rule:hs_toolchain_library`, `bzl:rule:hs_cabal_library`) or `CcInfo`. Only direct `HsPackageInfo` targets are exposed via `-package-id`. |
| `cc_deps` | `list[Label]` | `[]` | No | Native C/C++ dependencies providing `CcInfo` (e.g., `cc_library` targets). Headers, include directories, and static archives are available during compilation and propagated transitively. |
| `c_sources` | `list[Label]` | `[]` | No | Inline C/C++/assembly source files (`.c`, `.cc`, `.cpp`, `.S`, `.s`) compiled via `cc_common.compile` with `-fPIC` and GHC's RTS include path (`HsFFI.h`, `Rts.h`). |
| `hdrs` | `list[Label]` | `[]` | No | Header files (and compile-time `#include` / Template Haskell inputs) exposed to `c_sources`, `CPP`, `CApiFFI`, and downstream dependents via `CcInfo` and `bzl:provider:HsLinkInfo`. |
| `include_dirs` | `list[str]` | `[]` | No | Package-relative C header search directories passed via `-I` to `cc_common.compile` and GHC (`CPP` / `CApiFFI`) and propagated transitively. |
| `hs_source_dirs` | `list[str]` | `[]` | No | Package-relative Haskell import root directories passed via `-i` (defaults to `["."]` relative to the Bazel package when empty). |
| `hidden_modules` | `list[str]` | `[]` | No | Dotted Haskell module names (e.g., `["Math.Internal"]`) excluded from `exposed-modules` and recorded under `hidden-modules` in the generated `.conf` file. |
| `default_language` | `str` | `"GHC2021"` | No | Haskell language edition passed via `-X<default_language>` (e.g., `"GHC2021"`, `"GHC2024"`, `"Haskell2010"`, `"Haskell98"`). Pass `""` to omit. |
| `default_extensions` | `list[str]` | `[]` | No | Language extensions enabled for all modules in this target, each passed as `-X<ext>` (e.g., `["OverloadedStrings", "LambdaCase"]`). |
| `ghc_opts` | `list[str]` | `[]` | No | Additional flags passed directly to `ghc --make -c` (e.g., `["-Wall", "-Werror", "-O2"]`). |
| `cpp_options` | `list[str]` | `[]` | No | Preprocessor flags forwarded to GHC as `-optP<opt>` for `{-# LANGUAGE CPP #-}` sources (e.g., `["-DFEATURE_FLAG=1"]`). |
| `cc_options` | `list[str]` | `[]` | No | Additional C compiler flags passed to `cc_common.compile` when compiling `c_sources` (e.g., `["-DINLINE_SCALE=3"]`). |
| `data` | `list[Label]` | `[]` | No | Runtime files or tools staged into Bazel runfiles and merged transitively into downstream `bzl:rule:hs_binary` and `bzl:rule:hs_test` targets. |

### Example

```starlark
load("@rules_hs//hs:defs.bzl", "hs_library")

hs_library(
    name = "engine",
    srcs = [
        "src/Engine.hs",
        "src/Engine/Internal.hs",
    ],
    c_sources = ["cbits/fast_hash.c"],
    default_extensions = ["OverloadedStrings"],
    ghc_opts = ["-Wall", "-Wcompat", "-O2"],
    hdrs = ["cbits/fast_hash.h"],
    hidden_modules = ["Engine.Internal"],
    hs_source_dirs = ["src"],
    include_dirs = ["cbits"],
    deps = [
        "@hs_boot//:base",
        "@hs_boot//:bytestring",
        "@hs_boot//:text",
    ],
)
```

---

## `hs_binary` {#hs_binary}

Compiles and links a hermetic Haskell executable (`executable = True`), statically linking `libgmp.a` (`-optl-L<gmp_static_dir>`, `-optl-no-pie`) and wrapping all transitive native `CcInfo` static archives inside `-Wl,--start-group ... -Wl,--end-group`. On Linux, the output binary's ELF `DT_NEEDED` entries are restricted strictly to base glibc (`libc.so.6`, `libm.so.6`, `libdl.so.2`, `libpthread.so.0`).

- **Load from**: `@rules_hs//hs:defs.bzl` (implemented in `hs/private/rules.bzl`)
- **Toolchains**: `@rules_hs//hs:toolchain_type`, `@bazel_tools//tools/cpp:toolchain_type`
- **Provides**: `DefaultInfo` (`executable` + transitive `runfiles`)

### Signature

```starlark
hs_binary(
    name,
    srcs,
    deps = [],
    cc_deps = [],
    c_sources = [],
    hdrs = [],
    include_dirs = [],
    hs_source_dirs = [],
    main_module = "Main",
    default_language = "GHC2021",
    default_extensions = [],
    threaded = True,
    ghc_opts = [],
    cpp_options = [],
    cc_options = [],
    data = [],
)
```

### Attributes

| Attribute | Type | Default | Required | Description |
|---|---|---|---|---|
| `name` | `Name` | — | **Yes** | Target name and output executable filename (`bazel-bin/<pkg>/<name>`). |
| `srcs` | `list[Label]` | — | **Yes** | Haskell source files (`.hs`, `.lhs`, `.hs-boot`, `.lhs-boot`) compiled directly into the executable. |
| `deps` | `list[Label]` | `[]` | No | Direct dependencies providing `bzl:provider:HsPackageInfo` or `CcInfo`. |
| `cc_deps` | `list[Label]` | `[]` | No | Native C/C++ dependencies providing `CcInfo`, linked statically into the executable. |
| `c_sources` | `list[Label]` | `[]` | No | Inline C/C++/assembly files (`.c`, `.cc`, `.cpp`, `.S`, `.s`) compiled via `cc_common.compile` and linked into the executable. |
| `hdrs` | `list[Label]` | `[]` | No | Header files available to `c_sources`, `CPP`, and `CApiFFI` during compilation. |
| `include_dirs` | `list[str]` | `[]` | No | Package-relative C include directories passed via `-I`. |
| `hs_source_dirs` | `list[str]` | `[]` | No | Package-relative Haskell source directories passed via `-i` (defaults to `["."]` when empty). |
| `main_module` | `str` | `"Main"` | No | Entry-point module/function specification passed to GHC via `-main-is <main_module>` (e.g., `"Main"` or `"App.Entry.run"`). Pass `""` to omit `-main-is`. |
| `default_language` | `str` | `"GHC2021"` | No | Haskell language edition passed via `-X<default_language>`. |
| `default_extensions` | `list[str]` | `[]` | No | Language extensions passed as `-X<ext>`. |
| `threaded` | `bool` | `True` | No | When `True`, passes `-threaded` to link GHC's multi-threaded RTS (`rtsSupportsBoundThreads == True`, enabling `forkOS` and multi-core capabilities). Set `False` for the single-threaded RTS. |
| `ghc_opts` | `list[str]` | `[]` | No | Additional GHC compile and link flags (e.g., `["-Wall", "-O2", "-rtsopts", "-with-rtsopts=-N"]`). |
| `cpp_options` | `list[str]` | `[]` | No | Preprocessor flags forwarded to GHC as `-optP<opt>`. |
| `cc_options` | `list[str]` | `[]` | No | Additional C compiler flags passed to `cc_common.compile` for `c_sources`. |
| `data` | `list[Label]` | `[]` | No | Runtime data files and helper binaries staged into `<name>.runfiles`, merged with transitive `data` from `deps` and `cc_deps`. |

### Example

```starlark
load("@rules_hs//hs:defs.bzl", "hs_binary")

hs_binary(
    name = "cli",
    srcs = ["app/Main.hs"],
    ghc_opts = ["-Wall", "-Wcompat", "-O2", "-rtsopts"],
    hs_source_dirs = ["app"],
    threaded = True,
    deps = [
        ":engine",
        "@hs_boot//:base",
        "@hs_boot//:text",
    ],
)
```

---

## `hs_test` {#hs_test}

Compiles and links a hermetic Haskell test executable (`test = True`) executed by `bazel test`. Uses the exact same implementation and linking pipeline as `bzl:rule:hs_binary` (static `libgmp.a`, strict direct-dependency visibility, transitive `CcInfo` linking, and transitive `data` runfiles).

- **Load from**: `@rules_hs//hs:defs.bzl` (implemented in `hs/private/rules.bzl`)
- **Toolchains**: `@rules_hs//hs:toolchain_type`, `@bazel_tools//tools/cpp:toolchain_type`
- **Provides**: `DefaultInfo` (`executable` + transitive `runfiles`)

### Signature

```starlark
hs_test(
    name,
    srcs,
    deps = [],
    cc_deps = [],
    c_sources = [],
    hdrs = [],
    include_dirs = [],
    hs_source_dirs = [],
    main_module = "Main",
    default_language = "GHC2021",
    default_extensions = [],
    threaded = True,
    ghc_opts = [],
    cpp_options = [],
    cc_options = [],
    data = [],
    size = "medium",  # Standard Bazel test attribute
)
```

### Attributes

`bzl:rule:hs_test` accepts the exact same 15 rule-specific attributes as `bzl:rule:hs_binary` (`srcs`, `deps`, `cc_deps`, `c_sources`, `hdrs`, `include_dirs`, `hs_source_dirs`, `main_module`, `default_language`, `default_extensions`, `threaded`, `ghc_opts`, `cpp_options`, `cc_options`, `data`), plus Bazel's built-in test attributes (`size`, `timeout`, `args`, `env`, `env_inherit`, `flaky`, `local`, `shard_count`).

### Example

```starlark
load("@rules_hs//hs:defs.bzl", "hs_test")

hs_test(
    name = "engine_test",
    size = "small",
    srcs = ["test/EngineTest.hs"],
    data = ["testdata/golden.json"],
    ghc_opts = ["-Wall", "-Wcompat"],
    hs_source_dirs = ["test"],
    deps = [
        ":engine",
        "@hs_boot//:base",
        "@hs_boot//:filepath",
    ],
)
```

---

## `hs_toolchain_library` {#hs_toolchain_library}

Exposes a pre-compiled boot package from the active GHC toolchain's global `package.conf.d` database (`bzl:provider:HsToolchainInfo`) as a standard Bazel dependency providing `bzl:provider:HsPackageInfo` (`is_boot = True`) and an empty `bzl:provider:HsLinkInfo`.

::: {.tip title="Generated Automatically in @hs_boot and @hackage"}
You rarely need to instantiate `bzl:rule:hs_toolchain_library` manually: `bzl:ext:hs.toolchain` automatically generates `@hs_boot//:<pkg>` for every boot library in your selected GHC release, and `bzl:ext:hackage.from_lock` generates `@hackage//:<pkg>` for every non-overridden boot library.
:::

- **Load from**: `@rules_hs//hs:defs.bzl` (implemented in `hs/private/rules.bzl`)
- **Toolchains**: `@rules_hs//hs:toolchain_type`
- **Provides**: `DefaultInfo`, `bzl:provider:HsPackageInfo`, `bzl:provider:HsLinkInfo`

### Signature

```starlark
hs_toolchain_library(
    name,
    package_name = "",
)
```

### Attributes

| Attribute | Type | Default | Required | Description |
|---|---|---|---|---|
| `name` | `Name` | — | **Yes** | Target name. Used as the boot package lookup key when `package_name` is empty. |
| `package_name` | `str` | `""` | No | Exact Cabal boot package name in GHC's global package database (e.g., `"Cabal-syntax"`, `"base"`, `"template-haskell"`). Defaults to `name` when `""`. Fails at analysis time with the sorted list of available boot packages if not present in the active GHC release. |

### Example

```starlark
load("@rules_hs//hs:defs.bzl", "hs_toolchain_library")

hs_toolchain_library(
    name = "cabal_syntax",
    package_name = "Cabal-syntax",
)
```

---

## `hs_cabal_library` {#hs_cabal_library}

Builds a third-party Cabal/Hackage Haskell library, internal sublibrary, or C-only Cabal package (such as `zlib-clib`) using up to **five fine-grained, cacheable Bazel stages** — with zero `Setup.hs` execution:

1. **Stage 1 (`HsConfigure`)**: Runs `/bin/sh ./configure` hermetically via `ghc_cc_wrapper` when `build_type == "Configure"`.
2. **Stage 2 (`ctx.actions.write`)**: Emits `cabal_macros.h` (`VERSION_*`, `MIN_VERSION_*`, `MIN_TOOL_VERSION_ghc`) and optional `Paths_<pkg>.hs`.
3. **Stage 3 (`HsHsc2hs`)**: Spawns parallel per-file `hsc2hs` actions for `hsc_srcs`.
4. **Stage 4 (`cc_common.compile`)**: Compiles `c_sources` in parallel and propagates `install_includes` headers via `CcInfo` + `bzl:provider:HsLinkInfo` (returning immediately for C-only packages with no Haskell modules).
5. **Stage 5 (`HsCompileLibrary`)**: Compiles Haskell modules via `ghc --make -c`, archives `libHS<unit_id>.a` (where `unit_id` is `<package_name>-<version>` or `<package_name>-<version>-<component_name>`), and writes a relocatable `${pkgroot}` `.pkgdb`.

Generated automatically inside `@<hub>__<pkg>` repositories by `bzl:ext:hackage.from_lock`, and also directly usable in custom `BUILD.bazel` files for vendored Cabal packages.

- **Load from**: `@rules_hs//hs:defs.bzl` (implemented in `hs/private/cabal_library.bzl`)
- **Toolchains**: `@rules_hs//hs:toolchain_type`, `@bazel_tools//tools/cpp:toolchain_type`
- **Provides**: `DefaultInfo`, `bzl:provider:HsPackageInfo`, `bzl:provider:HsLinkInfo`, `CcInfo`

### Signature

```starlark
hs_cabal_library(
    name,
    package_name,
    version,
    component_name = "",
    srcs = [],
    hsc_srcs = [],
    c_sources = [],
    hdrs = [],
    install_includes = [],
    include_dirs = [],
    hs_source_dirs = [],
    exposed_modules = [],
    other_modules = [],
    reexported_modules = [],
    default_language = "Haskell98",
    default_extensions = [],
    ghc_opts = [],
    cpp_options = [],
    cc_options = [],
    build_type = "Simple",
    configure_script = None,
    configure_srcs = [],
    configure_outputs = [],
    configure_args = [],
    generate_paths_module = False,
    deps = [],
    extra_cc_deps = [],
    data = [],
)
```

### Attributes

| Attribute | Type | Default | Required | Description |
|---|---|---|---|---|
| `name` | `Name` | — | **Yes** | Bazel target name (typically `package_name` for the main library or `component_name` for an internal sublibrary). |
| `package_name` | `str` | — | **Yes** | Upstream Cabal `name:` (e.g., `"attoparsec"`, `"network"`, `"zlib-clib"`). Used for `Paths_<pkg>` generation, `cabal_macros.h`, and GHC unit ID construction. |
| `component_name` | `str` | `""` | No | Internal Cabal sublibrary name (e.g., `"attoparsec-internal"`). When non-empty, the GHC unit ID becomes `<package_name>-<version>-<component_name>`; when `""`, `<package_name>-<version>`. |
| `version` | `str` | — | **Yes** | Package version string (e.g., `"0.14.4"`), recorded in `.pkgdb` and `cabal_macros.h` (`CURRENT_PACKAGE_VERSION` / `MIN_VERSION_*`). |
| `srcs` | `list[Label]` | `[]` | No | Haskell source files (`.hs`, `.lhs`, `.hs-boot`, `.lhs-boot`). May be empty for `.hsc`-only, re-export-only, or C-only Cabal packages. |
| `hsc_srcs` | `list[Label]` | `[]` | No | `hsc2hs` template files (`.hsc`), each compiled into a `.hs` module in Stage 3 with `-include cabal_macros.h` and standard OS/arch macros. |
| `c_sources` | `list[Label]` | `[]` | No | C/C++/assembly files (`.c`, `.cc`, `.cpp`, `.S`, `.s`) compiled via `cc_common.compile` in Stage 4 with `-include cabal_macros.h` and GHC RTS headers. |
| `hdrs` | `list[Label]` | `[]` | No | Private and public header files (plus textual `.c` `#include`s such as `crypton`'s `cbits/*_impl.c`, passed via `additional_inputs`). |
| `install_includes` | `list[str]` | `[]` | No | Header filenames or relative paths from Cabal `install-includes:` (matched against `hdrs` and `configure_outputs`) that are exported publicly to downstream C/FFI/`hsc2hs` consumers. |
| `include_dirs` | `list[str]` | `[]` | No | Package-relative C include directories from Cabal `include-dirs:`, used locally and propagated publicly via `CcInfo` + `bzl:provider:HsLinkInfo`. |
| `hs_source_dirs` | `list[str]` | `[]` | No | Package-relative Haskell source directories from Cabal `hs-source-dirs:` (defaults to `["."]`). |
| `exposed_modules` | `list[str]` | `[]` | No | Publicly exposed dotted Haskell module names from Cabal `exposed-modules:`. |
| `other_modules` | `list[str]` | `[]` | No | Internal dotted Haskell module names from Cabal `other-modules:`, compiled with the package and recorded under `hidden-modules:` in `.conf`. |
| `reexported_modules` | `list[str]` | `[]` | No | Cabal `reexported-modules:` specifications formatted for `ghc-pkg` (e.g., `["orig-pkg:Orig.Mod as New.Mod"]`). |
| `default_language` | `str` | `"Haskell98"` | No | Cabal `default-language:` passed via `-X<default_language>`. Defaults to `"Haskell98"` per the Cabal specification when omitted in `.cabal`. |
| `default_extensions` | `list[str]` | `[]` | No | Cabal `default-extensions:`, each passed as `-X<ext>`. |
| `ghc_opts` | `list[str]` | `[]` | No | GHC flags passed to `ghc --make -c` in Stage 5. |
| `cpp_options` | `list[str]` | `[]` | No | Preprocessor flags passed to both `hsc2hs` (`--cflag`) and GHC (`-optP`). |
| `cc_options` | `list[str]` | `[]` | No | C compiler flags passed to both `hsc2hs` (`--cflag`) and `cc_common.compile`. |
| `build_type` | `str` | `"Simple"` | No | Cabal `build-type:` (`"Simple"`, `"Configure"`, or `"Custom"`). Stage 1 `./configure` runs when `build_type == "Configure"` and both `configure_script` and `configure_outputs` are provided. |
| `configure_script` | `Label` | `None` | No | Single-file label pointing to the autoconf `configure` script for `build_type = "Configure"`. |
| `configure_srcs` | `list[Label]` | `[]` | No | Auxiliary inputs staged into the temporary `./configure` working directory (`config.guess`, `config.sub`, `install-sh`, `*.h.in`, `*.buildinfo`, `configure.ac`). |
| `configure_outputs` | `list[str]` | `[]` | No | Relative paths of files generated by `./configure` (e.g., `["include/HsNetworkConfig.h"]`), declared as Bazel action outputs and added to header search paths. |
| `configure_args` | `list[str]` | `[]` | No | Extra command-line arguments passed to `/bin/sh ./configure` (typically supplied via `bzl:ext:hackage.override`). |
| `generate_paths_module` | `bool` | `False` | No | When `True`, emits an autogenerated `Paths_<sanitized_pkg>.hs` module in Stage 2 and compiles it into the package. |
| `deps` | `list[Label]` | `[]` | No | Direct Cabal `build-depends` targets providing `bzl:provider:HsPackageInfo` or `CcInfo` (including C-only `hs_cabal_library` targets). |
| `extra_cc_deps` | `list[Label]` | `[]` | No | Additional Bazel `cc_library` (`CcInfo`) targets attached via `bzl:ext:hackage.override`. |
| `data` | `list[Label]` | `[]` | No | Runtime data files propagated through Bazel runfiles. |

### Example

```starlark
load("@rules_hs//hs:defs.bzl", "hs_cabal_library")

# C-only Cabal library propagating public headers to downstream Haskell packages
hs_cabal_library(
    name = "zlib-clib",
    package_name = "zlib-clib",
    c_sources = ["cbits/adler32.c", "cbits/crc32.c", "cbits/deflate.c", "cbits/inflate.c"],
    hdrs = ["cbits/zlib.h", "cbits/zconf.h"],
    include_dirs = ["cbits"],
    install_includes = ["zlib.h", "zconf.h"],
    version = "1.3.2",
)
```

---

## `hs_toolchain` {#hs_toolchain}

Binds a staged hermetic GHC distribution (`staged_ghc`), the native C11 `ghc_cc_wrapper`, and parsed boot package metadata into Bazel's toolchain resolution system (`platform_common.ToolchainInfo(hs = HsToolchainInfo)`). Instantiated automatically inside `@hs_toolchains` by `bzl:ext:hs.toolchain`.

- **Load from**: `@rules_hs//hs:toolchain.bzl`
- **Provides**: `platform_common.ToolchainInfo`, `bzl:provider:HsToolchainInfo`

### Attributes

| Attribute | Type | Default | Required | Description |
|---|---|---|---|---|
| `name` | `Name` | — | **Yes** | Target name of the `hs_toolchain` instance. |
| `version` | `str` | — | **Yes** | GHC release version string (e.g., `"9.10.3"` or `"9.12.4"`). |
| `staged_ghc` | `Label` | — | **Yes** | Exec-configured `staged_ghc` target providing `bzl:provider:HsToolchainInfo` with `$ORIGIN`-staged binaries, `lib/` `TreeArtifact`, and static `libgmp.a`. |
| `cc_wrapper` | `Label` | `Label("//hs/private:ghc_cc_wrapper")` | No | Exec-configured compiled C11 wrapper adapting Bazel's `cc_toolchain` for GHC, `hsc2hs`, and `./configure`. |
| `boot_packages_json` | `dict[str, str]` | `{}` | No | Map of boot package name to JSON-encoded `{name, version, id, depends, exposed_modules}` parsed from `lib/package.conf.d/*.conf`. |
| `bignum` | `str` | `"gmp"` | No | GHC bignum backend (`"gmp"` or `"native"`). |
| `is_dynamic_ghc` | `bool` | `True` | No | Whether the staged GHC compiler executable itself is dynamically linked. |
| `target_os` | `str` | — | **Yes** | Target OS identifier (`"linux"`, `"macos"`, or `"windows"`). |
| `target_cpu` | `str` | — | **Yes** | Target CPU architecture identifier (`"x86_64"` or `"arm64"`). |
| `arch_libdir` | `str` | — | **Yes** | Basename of GHC's platform library directory under `lib/` (e.g., `"x86_64-linux-ghc-9.10.3"`). |
