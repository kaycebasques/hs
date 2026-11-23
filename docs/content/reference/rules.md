---
title: "Rules Reference"
description: "Complete Starlark rule and attribute reference for hs_library, hs_binary, hs_test, hs_repl, hs_haddock, hs_toolchain_library, hs_cabal_library, and hs_toolchain."
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
    "hs_haddock",
    "hs_library",
    "hs_repl",
    "hs_test",
    "hs_toolchain_library",
)
```

Toolchain definition rules (used only if you are registering a custom GHC distribution rather than using `@hs_toolchains`) are loaded from `@rules_hs//hs:toolchain.bzl`:

```starlark
load("@rules_hs//hs:toolchain.bzl", "TOOLCHAIN_TYPE", "hs_toolchain")
```

> **Note — Which Rule Do I Need?**
> - Writing in-repo Haskell code? Use [`hs_library`](rules.md#hs_library) for reusable modules, [`hs_binary`](rules.md#hs_binary) for executables, [`hs_test`](rules.md#hs_test) for automated tests, [`hs_repl`](rules.md#hs_repl) for interactive `ghci` REPL sessions (or `@rules_hs//tools/ghci` and `@rules_hs//tools/ghci:runghc` for ad-hoc boot-package sessions and scripts), and [`hs_haddock`](rules.md#hs_haddock) for HTML API documentation.
> - Depending on GHC's built-in standard libraries (`base`, `text`, `bytestring`, `containers`) or third-party Hackage packages? Reference `@hs_boot//:<pkg>` or `@hackage//:<pkg>` in `deps` — those repositories already instantiate [`hs_toolchain_library`](rules.md#hs_toolchain_library) and [`hs_cabal_library`](rules.md#hs_cabal_library) for you automatically.
> - All rules also accept Bazel's built-in common attributes (`name`, `visibility`, `tags`, `testonly`, `features`, `compatible_with`, `target_compatible_with`, `exec_compatible_with`), and [`hs_test`](rules.md#hs_test) accepts Bazel's built-in test attributes (`size`, `timeout`, `flaky`, `local`, `shard_count`, `args`, `env`, `env_inherit`).

---

## `hs_library` {#hs_library}

Use `hs_library` whenever you want to compile one or more `.hs` modules in your repository so they can be imported by [`hs_binary`](rules.md#hs_binary), [`hs_test`](rules.md#hs_test), or other `hs_library` targets.

Under the hood, `hs_library` enforces **strict direct-dependency visibility**: it passes `-hide-all-packages` to GHC and unlocks only the packages listed directly in `deps` via `-package-id` (so you cannot accidentally `import` a transitive dependency you forgot to declare). Each `hs_library` outputs a static code archive (`libHS<unit_id>.a`) and a self-contained `ghc-pkg` package database directory (`<name>.pkgdb`) holding `.hi` type-interface files under `<name>.pkgdb/hi/` plus (on dynamic GHC toolchains) `.so` shared libraries under `<name>.pkgdb/dyn/` used when downstream targets run compile-time Template Haskell code. Any attached C files (`c_sources` and `hdrs`) are compiled via Bazel's C toolchain (`cc_common.compile`) and forwarded automatically through `CcInfo`.

- **Load from**: `@rules_hs//hs:defs.bzl` (implemented in `hs/private/rules.bzl`)
- **Toolchains**: `@rules_hs//hs:toolchain_type`, `@bazel_tools//tools/cpp:toolchain_type`
- **Provides**: `DefaultInfo`, [`HsPackageInfo`](extensions-and-providers.md#hspackageinfo), [`HsLinkInfo`](extensions-and-providers.md#hslinkinfo), `CcInfo`

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
| `name` | `Name` | — | **Yes** | Unique target name in this `BUILD.bazel` package. Also used to derive the internal Cabal package name (`name.replace("_", "-")`, version `"0.0.0"`) and unique GHC unit ID (`u_<repo>_<pkg>_<name>-0.0.0`) so two `hs_library` targets with the same short name in different directories never collide. |
| `srcs` | `list[Label]` | — | **Yes** | Haskell source files (`.hs`, literate `.lhs`) and mutual-recursion forward-declaration files (`.hs-boot`, `.lhs-boot`) belonging to this library. Every module compiled into this target must be listed here. |
| `deps` | `list[Label]` | `[]` | No | Direct Haskell (or C) library dependencies (`hs_library`, `@hs_boot//:<pkg>` [`hs_toolchain_library`](rules.md#hs_toolchain_library), `@hackage//:<pkg>` [`hs_cabal_library`](rules.md#hs_cabal_library), or `CcInfo` targets). List every Haskell package whose modules your `srcs` `import` directly; transitive packages are linked automatically but hidden from `import` statements. |
| `cc_deps` | `list[Label]` | `[]` | No | Existing Bazel C/C++ library targets (`cc_library` or any rule providing `CcInfo`). Use `cc_deps` (rather than `c_sources`) when linking against a shared C/C++ library in your monorepo or a third-party BCR module such as `@zlib//:zlib`; its public headers and static archives propagate automatically to downstream binaries and Template Haskell. |
| `c_sources` | `list[Label]` | `[]` | No | Small C, C++, or assembly helper files (`.c`, `.cc`, `.cpp`, `.S`, `.s`) owned directly by this Haskell library (for example, `cbits/fast_hash.c` backing a `foreign import ccall`). Compiled with `-fPIC` and GHC's runtime header path (`HsFFI.h`, `Rts.h`) automatically on the include path; prefer `cc_deps` if non-Haskell targets also depend on the C code. |
| `hdrs` | `list[Label]` | `[]` | No | C/C++ header files (`.h`) needed when compiling `c_sources`, evaluating `#include` directives in `{-# LANGUAGE CPP #-}` Haskell files, or generating `CApiFFI` C wrapper stubs. Also propagated to downstream targets via `CcInfo` and [`HsLinkInfo`](extensions-and-providers.md#hslinkinfo). |
| `include_dirs` | `list[str]` | `[]` | No | Directories (relative to this `BUILD.bazel` file, such as `["cbits"]` or `["include"]`) added to the `-I` C header search path so `c_sources` and `CApiFFI` imports can write `#include "fast_hash.h"` without directory prefixes. |
| `hs_source_dirs` | `list[str]` | `[]` | No | Haskell import root directories relative to this `BUILD.bazel` file, passed to GHC via `-i` (defaults to `["."]` when empty). GHC expects a module's dotted name (`module Engine.Internal`) to match its file path relative to a source root (`Engine/Internal.hs`); set `hs_source_dirs = ["src"]` when your files live at `src/Engine/Internal.hs` so imports stay `Engine.Internal` instead of requiring files at the package root. |
| `hidden_modules` | `list[str]` | `[]` | No | Dotted Haskell module names (for example, `["Engine.Internal"]`) that modules *inside* this `hs_library` can import freely, but downstream `deps` consumers cannot import (recorded under `hidden-modules:` in `.pkgdb` and omitted from [`hs_haddock`](rules.md#hs_haddock) output). Leave empty if all modules in `srcs` are public. |
| `default_language` | `str` | `"GHC2021"` | No | Baseline Haskell language edition passed to GHC via `-X<default_language>`. Supported editions: `"GHC2021"`, `"GHC2024"`, `"Haskell2010"`, `"Haskell98"` (or `""` to pass no `-X` edition flag). Defaults to `"GHC2021"` to match GHC `9.10` and `9.12`'s own compiler default: `"GHC2024"` turns on `MonoLocalBinds` (alongside `DataKinds` and `GADTs`), which restricts automatic type polymorphism on local `let` and `where` helper functions and can reject code written for `GHC2021`/`Haskell2010`. Set `default_language = "GHC2024"` explicitly when you want the newer edition's extensions. |
| `default_extensions` | `list[str]` | `[]` | No | Individual GHC language extensions enabled across every `.hs` file in this target without repeating `{-# LANGUAGE ... #-}` at the top of each file, passed as `-X<ext>` (for example, `["OverloadedStrings", "LambdaCase", "DerivingStrategies"]`). |
| `ghc_opts` | `list[str]` | `[]` | No | Extra flags passed directly to `ghc --make -c` when compiling Haskell modules (commonly `["-Wall", "-Wcompat", "-Werror", "-O2"]`). |
| `cpp_options` | `list[str]` | `[]` | No | **C Preprocessor** flags (not C++ compiler flags) forwarded to GHC as `-optP<opt>` when preprocessing Haskell `.hs` files that enable `{-# LANGUAGE CPP #-}`. Use `cpp_options` (for example, `["-DENABLE_METRICS=1"]`) to control `#ifdef` blocks inside Haskell source files; use `cc_options` for native `.c`/`.cpp` compilation flags. |
| `cc_options` | `list[str]` | `[]` | No | Native C/C++ compiler flags passed to `cc_common.compile` (and GHC `-optc` for C stubs) when compiling files in `c_sources` (for example, `["-O3", "-mavx2", "-std=c11"]`). Does not affect `#ifdef` preprocessing of `.hs` files (use `cpp_options` for that). |
| `data` | `list[Label]` | `[]` | No | Non-code files or helper binaries needed either **at compile time** inside the build sandbox (for Template Haskell `file-embed` / `runIO` reading schemas or templates) or **at runtime** in Bazel runfiles (forwarded automatically to every downstream [`hs_binary`](rules.md#hs_binary) and [`hs_test`](rules.md#hs_test)). |

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

Use `hs_binary` to compile and link a standalone Haskell executable (`bazel build //pkg:cli` or `bazel run //pkg:cli`).

`hs_binary` links GHC's runtime system, your Haskell dependencies, `libgmp.a` (`-optl-L<gmp_static_dir>`, `-optl-no-pie`), and all transitive native `CcInfo` C archives (wrapped inside `-Wl,--start-group ... -Wl,--end-group` so archive order never causes undefined-symbol errors) into a single executable. On Linux, the produced binary carries no dynamic `libgmp.so` or `libffi.so` runtime dependencies — its ELF `DT_NEEDED` list contains only base `glibc` (`libc.so.6`, `libm.so.6`, `libdl.so.2`, `libpthread.so.0`).

- **Load from**: `@rules_hs//hs:defs.bzl` (implemented in `hs/private/rules.bzl`)
- **Toolchains**: `@rules_hs//hs:toolchain_type`, `@bazel_tools//tools/cpp:toolchain_type`
- **Provides**: `DefaultInfo` (`executable` + transitive `runfiles`), [`HsLinkInfo`](extensions-and-providers.md#hslinkinfo) (allowing [`hs_repl`](rules.md#hs_repl) to load executable modules via `deps`)

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
| `srcs` | `list[Label]` | — | **Yes** | Haskell source files (`.hs`, `.lhs`, `.hs-boot`, `.lhs-boot`) compiled directly into this executable (typically just `["app/Main.hs"]` when core logic lives in an [`hs_library`](rules.md#hs_library) so [`hs_test`](rules.md#hs_test) and [`hs_haddock`](rules.md#hs_haddock) can share that library). |
| `deps` | `list[Label]` | `[]` | No | Direct library dependencies providing [`HsPackageInfo`](extensions-and-providers.md#hspackageinfo) or `CcInfo` imported by `srcs`. |
| `cc_deps` | `list[Label]` | `[]` | No | Existing Bazel `cc_library` (`CcInfo`) targets linked statically into the executable (use when linking shared C/C++ libraries rather than single-target C files). |
| `c_sources` | `list[Label]` | `[]` | No | Inline C/C++/assembly files (`.c`, `.cc`, `.cpp`, `.S`, `.s`) belonging solely to this executable, compiled via `cc_common.compile` and linked into the binary. |
| `hdrs` | `list[Label]` | `[]` | No | C header files available to `c_sources`, `CPP`, and `CApiFFI` while compiling this executable. |
| `include_dirs` | `list[str]` | `[]` | No | Package-relative `-I` C header directories for `hdrs` and `c_sources`. |
| `hs_source_dirs` | `list[str]` | `[]` | No | Package-relative Haskell import root directories passed via `-i` (for example, `["app"]` when `srcs = ["app/Main.hs"]`; defaults to `["."]` when empty). |
| `main_module` | `str` | `"Main"` | No | Entry-point module or function passed to GHC via `-main-is <main_module>`. Keep the default `"Main"` when your entry file starts with `module Main (main) where`; set it to another module or function (such as `"Cli.Entry"` or `"Cli.Entry.run"`) when multiple executables share a directory and use distinct module headers, or pass `""` to omit `-main-is`. |
| `default_language` | `str` | `"GHC2021"` | No | Haskell language edition passed via `-X<default_language>` (`"GHC2021"`, `"GHC2024"`, `"Haskell2010"`, `"Haskell98"`, or `""`). Defaults to `"GHC2021"` to match GHC `9.10`/`9.12` without forcing `GHC2024`'s `MonoLocalBinds`; see [`hs_library`](rules.md#hs_library) for details. |
| `default_extensions` | `list[str]` | `[]` | No | Language extensions enabled for all `srcs` in this executable, each passed as `-X<ext>`. |
| `threaded` | `bool` | `True` | No | Links GHC's multi-threaded Runtime System (`-threaded`) when `True`. Leave `True` for almost all binaries: it lets lightweight Haskell green threads run across multiple CPU cores (with `-with-rtsopts=-N` or `+RTS -N`) and prevents blocking C FFI calls from freezing other concurrent Haskell threads. Set `False` only for small single-threaded CLI tools that want slightly smaller binaries and zero OS thread-synchronization overhead. |
| `ghc_opts` | `list[str]` | `[]` | No | Extra GHC compile and link flags (for example, `["-Wall", "-O2", "-rtsopts", "-with-rtsopts=-N"]` to bake default Runtime System multicore flags into the binary). |
| `cpp_options` | `list[str]` | `[]` | No | C Preprocessor `#define` flags forwarded to GHC as `-optP<opt>` for `{-# LANGUAGE CPP #-}` `.hs` sources (not C++ compiler flags; use `cc_options` for `c_sources`). |
| `cc_options` | `list[str]` | `[]` | No | Native C/C++ compiler flags passed to `cc_common.compile` when compiling `c_sources`. |
| `data` | `list[Label]` | `[]` | No | Runtime assets, config files, or helper tools placed into `<name>.runfiles` (and staged into the compile sandbox for compile-time Template Haskell), merged with transitive `data` from `deps` and `cc_deps`. |

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

Use `hs_test` for unit, property, golden, or integration test suites run via `bazel test`. A test passes when its `main` action exits with status code `0` and fails on any non-zero exit code or uncaught Haskell exception.

`hs_test` shares the exact same compilation and static-linking implementation as [`hs_binary`](rules.md#hs_binary) (static `libgmp.a`, strict direct-dependency visibility, transitive `CcInfo` linking, and transitive `data` runfiles exposed under `$TEST_SRCDIR` at test runtime).

- **Load from**: `@rules_hs//hs:defs.bzl` (implemented in `hs/private/rules.bzl`)
- **Toolchains**: `@rules_hs//hs:toolchain_type`, `@bazel_tools//tools/cpp:toolchain_type`
- **Provides**: `DefaultInfo` (`executable` + transitive `runfiles`), [`HsLinkInfo`](extensions-and-providers.md#hslinkinfo) (allowing [`hs_repl`](rules.md#hs_repl) to load executable modules via `deps`)

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

`hs_test` accepts the exact same 15 rule-specific attributes as [`hs_binary`](rules.md#hs_binary) (`srcs`, `deps`, `cc_deps`, `c_sources`, `hdrs`, `include_dirs`, `hs_source_dirs`, `main_module`, `default_language`, `default_extensions`, `threaded`, `ghc_opts`, `cpp_options`, `cc_options`, `data` — including `default_language = "GHC2021"` and support for `"GHC2024"`, `"Haskell2010"`, and `"Haskell98"`), plus Bazel's built-in test attributes (`size`, `timeout`, `args`, `env`, `env_inherit`, `flaky`, `local`, `shard_count`). Set `size = "small"` on fast unit tests so Bazel assigns a 60-second timeout and schedules them lightly, and list fixture files in `data` so test code can read them from `$TEST_SRCDIR/_main/<pkg>/...`.

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

## `hs_repl` {#hs_repl}

Use `hs_repl` to launch a hermetic interactive `ghci` session (`bazel run //pkg:my_repl`) or evaluate one-shot expressions (`bazel run //pkg:my_repl -- -ignore-dot-ghci -e 'expr'`) with target sources, package databases, C/C++ FFI libraries, Template Haskell splices, and `data` runfiles wired to the active GHC and C/C++ toolchains.

By default (`interpret_deps = True`), `hs_repl` loads in-workspace targets in `deps` ([`hs_library`](rules.md#hs_library), [`hs_binary`](rules.md#hs_binary), and [`hs_test`](rules.md#hs_test)) **from source into GHCi bytecode**, resolving source files via `BUILD_WORKSPACE_DIRECTORY` under `bazel run` so editing `.hs` files in your editor and typing `:reload` (`:r`) reloads them without re-invoking Bazel. At startup, a generated session `.ghci` script loads all interpreted modules in topological order and runs `:module + *Mod1 *Mod2 ...` so top-level and internal bindings, `:break` / `:continue` bytecode breakpoints, and `:main` work immediately. External `@hs_boot` and `@hackage` packages (plus any targets listed in `compiled_deps`, or all `hs_library` deps when `interpret_deps = False`) load as precompiled packages via `-package-db` and `-package-id`, and any native C/C++ archives in `c_sources` or `cc_deps` are linked into a shared helper library (`HsLinkReplCbits`) for interactive FFI calls.

- **Load from**: `@rules_hs//hs:defs.bzl` (implemented in `hs/private/repl.bzl`)
- **Toolchains**: `@rules_hs//hs:toolchain_type`, `@bazel_tools//tools/cpp:toolchain_type`
- **Provides**: `DefaultInfo` (`executable` launcher + transitive `runfiles`), [`HsReplInfo`](extensions-and-providers.md#hsreplinfo)

### Signature

```starlark
hs_repl(
    name,
    srcs = [],
    deps = [],
    compiled_deps = [],
    interpret_deps = True,
    expose_boot_packages = False,
    cc_deps = [],
    c_sources = [],
    hdrs = [],
    include_dirs = [],
    hs_source_dirs = [],
    default_language = "",
    default_extensions = [],
    ghc_opts = [],
    ghci_opts = [],
    ghci_commands = [],
    ghci_script = None,
    allow_dot_ghci = False,
    cpp_options = [],
    cc_options = [],
    data = [],
)
```

### Attributes

| Attribute | Type | Default | Required | Description |
|---|---|---|---|---|
| `name` | `Name` | — | **Yes** | Target name and output REPL launcher script name (`bazel-bin/<pkg>/<name>`). |
| `srcs` | `list[Label]` | `[]` | No | Optional extra `.hs`, `.lhs`, `.hs-boot`, or `.lhs-boot` source files loaded directly into GHCi bytecode alongside any interpreted `deps`. |
| `deps` | `list[Label]` | `[]` | No | Haskell libraries ([`hs_library`](rules.md#hs_library)), executables/tests ([`hs_binary`](rules.md#hs_binary), [`hs_test`](rules.md#hs_test)), boot/Hackage packages (`@hs_boot//:<pkg>`, `@hackage//:<pkg>`), or `CcInfo` targets available in the session. |
| `compiled_deps` | `list[Label]` | `[]` | No | [`hs_library`](rules.md#hs_library) (or boot/Hackage) targets that should always be loaded as precompiled native packages (`-package-id`) rather than interpreted from source, even when `interpret_deps = True`. Useful when a large foundational workspace library rarely changes during interactive iteration. |
| `interpret_deps` | `bool` | `True` | No | When `True`, in-workspace targets in `deps` are loaded from source into GHCi bytecode (`*Module` scope, `:reload`, `:break`, internal bindings). When `False`, in-workspace [`hs_library`](rules.md#hs_library) targets load as precompiled packages from `.pkgdb` (enforcing `hidden_modules`). External `@hs_boot` and `@hackage` packages always load precompiled. |
| `expose_boot_packages` | `bool` | `False` | No | When `False` (default), passes `-hide-all-packages` so only packages declared in `deps` and `compiled_deps` (or `base` when both are empty) are visible. When `True`, omits `-hide-all-packages` so all 41+ GHC boot packages can be imported without listing each one (used by `@rules_hs//tools/ghci`). |
| `cc_deps` | `list[Label]` | `[]` | No | Native C/C++ `cc_library` (`CcInfo`) targets linked into the REPL's shared C/C++ helper library (`HsLinkReplCbits`) for interactive FFI calls. Transitive `CcInfo` archives from `deps` and `compiled_deps` are included automatically. |
| `c_sources` | `list[Label]` | `[]` | No | Inline C, C++, or assembly files (`.c`, `.cc`, `.cpp`, `.S`, `.s`) compiled with `-fPIC` and linked into the REPL's shared C/C++ helper library. |
| `hdrs` | `list[Label]` | `[]` | No | C/C++ header files visible to `c_sources`, `-XCPP`, and `CApiFFI` stubs inside GHCi. |
| `include_dirs` | `list[str]` | `[]` | No | Package-relative C header search directories (`-I`) for `srcs` and `c_sources`. |
| `hs_source_dirs` | `list[str]` | `[]` | No | Package-relative Haskell import root directories (`-i`) for `srcs`. |
| `default_language` | `str` | `""` | No | Haskell language edition passed via `-X<default_language>` (`"GHC2021"`, `"GHC2024"`, `"Haskell2010"`, `"Haskell98"`). When `""`, inherits `default_language` from the first interpreted dependency or falls back to `"GHC2021"`. |
| `default_extensions` | `list[str]` | `[]` | No | GHC language extensions enabled across interpreted modules via `-X<ext>`, combined with `default_extensions` inherited from interpreted `deps`. |
| `ghc_opts` | `list[str]` | `[]` | No | Extra GHC flags passed to the interpreter. Batch-only flags inherited from upstream targets (`-O*`, `-Werror`, `-threaded`, `-rtsopts`, `-with-rtsopts*`, `-dynamic-too`, `-optl-no-pie`, `-main-is`) are stripped automatically from inherited library/binary options so GHCi bytecode mode starts cleanly. |
| `ghci_opts` | `list[str]` | `[]` | No | Extra GHCi-specific flags appended at the end of the base compiler argument list (for example, `["-fobject-code"]` or `["-fexternal-interpreter"]`). |
| `ghci_commands` | `list[str]` | `[]` | No | Startup GHCi commands or imports written to `<name>.ghci` and executed automatically after modules load (for example, `[":set prompt \"app> \"", "import Data.Text (Text)"]`). |
| `ghci_script` | `Label` | `None` | No | Optional checked-in `.ghci` file executed at session startup after `ghci_commands`. |
| `allow_dot_ghci` | `bool` | `False` | No | When `False` (default), passes `-ignore-dot-ghci` so host `~/.ghc/ghci.conf` and local `.ghci` files cannot alter reproducible sessions. Set `True` to allow GHCi to read user `.ghci` configuration files. |
| `cpp_options` | `list[str]` | `[]` | No | C Preprocessor flags (`-optP`) for `{-# LANGUAGE CPP #-}` Haskell sources. |
| `cc_options` | `list[str]` | `[]` | No | Native C/C++ compiler flags for `c_sources` and `CApiFFI` stubs. |
| `data` | `list[Label]` | `[]` | No | Runtime data files placed into `<name>.runfiles` (accessible via `RUNFILES_DIR` inside GHCi and merged with transitive `data` from `deps`, `compiled_deps`, and `cc_deps`). |

### CLI Modes & Standalone Tool Targets

Every `hs_repl` launcher inspects arguments passed after `--`:

- **Interactive terminal mode** (`bazel run //pkg:my_repl`): Passes `--interactive`, enables `haskeline` arrow-key history, Tab completion, `Ctrl-C` evaluation interrupt (`Interrupted.`), and ANSI colors via `rules_hs`'s C11 `libtinfo.so.6` reader.
- **Expression evaluation mode** (`bazel run //pkg:my_repl -- -v0 -e 'myFn 42'`): Detects `-e` or `--run`, omits `--interactive`, loads the session's modules and `.ghci` commands, prints the result, and exits.
- **External interpreter mode** (`bazel run //pkg:my_repl -- -fexternal-interpreter`): Automatically pairs `-dynamic` on dynamic Linux GHC toolchains and spawns staged `bin/ghc-iserv-dyn` (`HsToolchainInfo.ghc_iserv`) to evaluate bytecode and Template Haskell out-of-process.
- **Standalone `@rules_hs//tools/ghci` and `@rules_hs//tools/ghci:runghc`**: Pre-defined public targets for launching `ghci` with all GHC boot packages exposed (`bazel run @rules_hs//tools/ghci`) or running standalone `.hs` / `.lhs` scripts without writing an `hs_binary` rule (`bazel run @rules_hs//tools/ghci:runghc -- path/to/Script.hs arg1`).

### Example

```starlark
load("@rules_hs//hs:defs.bzl", "hs_repl")

hs_repl(
    name = "engine_repl",
    ghci_commands = [":set prompt \"engine> \""],
    deps = [":engine"],
)
```

---

## `hs_haddock` {#hs_haddock}

Use `hs_haddock` to generate HTML API documentation from `-- |` and `{-| ... -}` Haddock docstrings in one or more [`hs_library`](rules.md#hs_library) (or [`hs_cabal_library`](rules.md#hs_cabal_library)) targets.

`hs_haddock` runs the active toolchain's `$ORIGIN`-staged `haddock` binary (`HsHaddock` action mnemonic) inside a hermetic Bazel sandbox (`-B <libdir> -l <libdir>`, `ghc_cc_wrapper`, sandbox-local `TMPDIR`, `-hide-all-packages`, and `--hide=<mod>` for library `hidden_modules`), producing module reference HTML, syntax-highlighted source pages (`src/<Module>.html`), an interactive QuickJump symbol search index (`doc-index.json`), and a binary `.haddock` interface file. Cross-package type links are wired automatically via `--read-interface`: GHC boot package types (`base`, `text`, `bytestring`, `Cabal-syntax`, etc.) link to official Hackage documentation using bundled [`HsToolchainInfo.boot_haddocks`](extensions-and-providers.md#hstoolchaininfo) interfaces without network access, while upstream `haddock_deps` targets link via relative paths.

- **Load from**: `@rules_hs//hs:defs.bzl` (implemented in `hs/private/haddock.bzl`)
- **Toolchains**: `@rules_hs//hs:toolchain_type`, `@bazel_tools//tools/cpp:toolchain_type`
- **Provides**: `DefaultInfo` (single HTML directory artifact `<name>`), [`HsHaddockInfo`](extensions-and-providers.md#hshaddockinfo), `OutputGroupInfo` (`haddock_interface`)

### Signature

```starlark
hs_haddock(
    name,
    deps,
    haddock_deps = [],
    title = "",
    prologue = None,
    hyperlinked_source = True,
    quickjump = True,
    hoogle = False,
    haddock_opts = [],
    ghc_opts = [],
)
```

### Attributes

| Attribute | Type | Default | Required | Description |
|---|---|---|---|---|
| `name` | `Name` | — | **Yes** | Target name. Also used as the output HTML directory name (`bazel-bin/<pkg>/<name>`) and fallback site heading when `title` is empty. |
| `deps` | `list[Label]` | — | **Yes** | Non-empty list of [`hs_library`](rules.md#hs_library) (or [`hs_cabal_library`](rules.md#hs_cabal_library)) targets whose exposed modules you want rendered into this HTML documentation site. Pass multiple libraries if you want one combined module index covering several sub-packages. |
| `haddock_deps` | `list[Label]` | `[]` | No | Other `hs_haddock` targets in your workspace whose types appear in the type signatures of `deps`. Use `haddock_deps` when library `B` re-exports or mentions types from in-repo library `A` and you want clicking `A`'s types in `B`'s docs to jump to `A`'s generated HTML pages (via `--read-interface`). Not needed for GHC boot types (`Text`, `Map`, `IO`), which link automatically. |
| `title` | `str` | `""` | No | Human-readable heading displayed at the top of the generated `index.html` landing page (`--title`). Defaults to `name` when left empty. |
| `prologue` | `Label` | `None` | No | Optional introductory overview file (`.txt`, `.prologue`, or Haddock-markup file) passed via `--prologue` and rendered above the module list on `index.html`. Use `prologue` when you want readers opening `index.html` to see an architecture summary and quick-start snippet before diving into individual modules. |
| `hyperlinked_source` | `bool` | `True` | No | Generates clickable, syntax-highlighted source code pages under `src/<Module>.html` (`--hyperlinked-source`) and adds `[Source]` links next to every documented function and type. Set `False` only if you want smaller HTML output without browsable source code. |
| `quickjump` | `bool` | `True` | No | Emits `doc-index.json` (`--quickjump`) to power Haddock's client-side `s`-key fuzzy search modal in the browser. Leave `True` for interactive browsing. |
| `hoogle` | `bool` | `False` | No | Emits a plain-text `<title>.txt` symbol signature database (`--hoogle`) inside the output directory. Enable `True` when indexing your internal libraries into a local Hoogle type-search server. |
| `haddock_opts` | `list[str]` | `[]` | No | Extra flags passed directly to the `haddock` CLI (for example, `["--warn-missing-export-lists"]` or custom `--source-url` templates). |
| `ghc_opts` | `list[str]` | `[]` | No | Extra GHC flags forwarded through Haddock via `--optghc=<opt>` while Haddock parses and typechecks `deps` sources. |

### Outputs

- **Default output (`DefaultInfo.files`)**: A single Bazel directory artifact (`TreeArtifact`) named `<name>/` containing `index.html`, per-module `<Module>.html` pages, `linuwial.css`, `doc-index.json` (when `quickjump = True`), and `src/<Module>.html` (when `hyperlinked_source = True`). Because `DefaultInfo.files` is one directory artifact, `$(rootpath :my_haddock)` works directly in downstream `genrule` or static-site packaging rules.
- **Interface file (`<name>.haddock`)**: Exposed to Starlark rules on [`HsHaddockInfo.interface`](extensions-and-providers.md#hshaddockinfo) and buildable on the command line via `bazel build --output_groups=haddock_interface //pkg:my_haddock`.

### Example

```starlark
load("@rules_hs//hs:defs.bzl", "hs_haddock", "hs_library")

hs_library(
    name = "lock_lib",
    srcs = [
        "CabalExtract.hs",
        "LockJson.hs",
    ],
    deps = [
        "@hs_boot//:Cabal-syntax",
        "@hs_boot//:base",
        "@hs_boot//:bytestring",
        "@hs_boot//:containers",
        "@hs_boot//:filepath",
        "@hs_boot//:text",
    ],
)

hs_haddock(
    name = "lock_haddock",
    title = "rules_hs Lock Generator API (//tools/lock)",
    deps = [":lock_lib"],
)
```

---

## `hs_toolchain_library` {#hs_toolchain_library}

Wraps one of GHC's pre-compiled boot libraries (from the active toolchain's global `package.conf.d` database on [`HsToolchainInfo`](extensions-and-providers.md#hstoolchaininfo)) as a normal Bazel target providing [`HsPackageInfo`](extensions-and-providers.md#hspackageinfo) (`is_boot = True`) and an empty [`HsLinkInfo`](extensions-and-providers.md#hslinkinfo) (since GHC already knows where its own boot archives live).

> **Tip — Already Generated for You in `@hs_boot` and `@hackage`:** In normal projects, you do not need to write `hs_toolchain_library` rules yourself. [`hs.toolchain`](extensions-and-providers.md#hs-toolchain) creates `@hs_boot//:<pkg>` for every boot library in your selected GHC version, and [`hackage.from_lock`](extensions-and-providers.md#hackage-from_lock) creates `@hackage//:<pkg>` for every boot library not overridden in `hackage.lock.json`. Call `hs_toolchain_library` directly only if you are assembling a custom hub `BUILD.bazel` or aliasing boot packages under project-specific names.

- **Load from**: `@rules_hs//hs:defs.bzl` (implemented in `hs/private/rules.bzl`)
- **Toolchains**: `@rules_hs//hs:toolchain_type`
- **Provides**: `DefaultInfo`, [`HsPackageInfo`](extensions-and-providers.md#hspackageinfo), [`HsLinkInfo`](extensions-and-providers.md#hslinkinfo)

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
| `name` | `Name` | — | **Yes** | Bazel target name. Also used as the boot library lookup key when `package_name` is left empty. |
| `package_name` | `str` | `""` | No | Exact Cabal package name in GHC's global boot package database (for example, `"Cabal-syntax"`, `"base"`, `"template-haskell"`). Set this when you want the Bazel target `name` (such as `"cabal_syntax"`) to differ from the upstream hyphenated/capitalized Cabal name (`"Cabal-syntax"`). If the named package does not exist in the active GHC release, Bazel fails at analysis time and prints the sorted list of available boot packages. |

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

Compiles a third-party Cabal/Hackage Haskell library, an internal Cabal sublibrary, or a C-only Cabal package (such as `zlib-clib` or `libyaml-clib`) across up to **five separate, cacheable Bazel build stages** — without compiling or running `Setup.hs`:

1. **Stage 1 (`HsConfigure`)**: Runs `/bin/sh ./configure` inside a sandbox via `ghc_cc_wrapper` when `build_type == "Configure"`.
2. **Stage 2 (`ctx.actions.write`)**: Writes Cabal's version-macro header `cabal_macros.h` (`VERSION_*`, `MIN_VERSION_*`, `MIN_TOOL_VERSION_ghc`) and optional `Paths_<pkg>.hs` with zero subprocesses.
3. **Stage 3 (`HsHsc2hs`)**: Runs parallel per-file `hsc2hs` C-struct/constant preprocessing actions for any `.hsc` files in `hsc_srcs`.
4. **Stage 4 (`cc_common.compile`)**: Compiles `c_sources` in parallel via `rules_cc` and exports public `install_includes` headers through `CcInfo` + [`HsLinkInfo`](extensions-and-providers.md#hslinkinfo) (finishing right here for C-only packages that have zero Haskell modules).
5. **Stage 5 (`HsCompileLibrary`)**: Compiles Haskell modules via `ghc --make -c`, archives `libHS<unit_id>.a` (where `unit_id` is `<package_name>-<version>` or `<package_name>-<version>-<component_name>`), and registers a relocatable `${pkgroot}` `.pkgdb` directory.

**When to use it**: [`hackage.from_lock`](extensions-and-providers.md#hackage-from_lock) generates `hs_cabal_library` targets automatically inside `@<hub>__<pkg>` repositories for every locked Hackage dependency. Call `hs_cabal_library` manually in your own `BUILD.bazel` only when vendoring or patching a third-party Cabal package's source tree directly inside your repository and needing Cabal-specific mechanics (`cabal_macros.h`, `Paths_<pkg>.hs`, `.hsc` preprocessing, `install_includes`, or `./configure`) that plain [`hs_library`](rules.md#hs_library) intentionally omits.

- **Load from**: `@rules_hs//hs:defs.bzl` (implemented in `hs/private/cabal_library.bzl`)
- **Toolchains**: `@rules_hs//hs:toolchain_type`, `@bazel_tools//tools/cpp:toolchain_type`
- **Provides**: `DefaultInfo`, [`HsPackageInfo`](extensions-and-providers.md#hspackageinfo), [`HsLinkInfo`](extensions-and-providers.md#hslinkinfo), `CcInfo`

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
| `name` | `Name` | — | **Yes** | Bazel target name (conventionally `package_name` for the package's main library or `component_name` for an internal sublibrary). |
| `package_name` | `str` | — | **Yes** | Upstream Cabal `name:` field (for example, `"attoparsec"`, `"network"`, `"zlib-clib"`). Determines `Paths_<pkg>` module naming, self `VERSION_*` macros in `cabal_macros.h`, and the base of the GHC unit ID. |
| `component_name` | `str` | `""` | No | Internal Cabal sublibrary name (`library <sublib>` stanza, such as `"attoparsec-internal"`). Leave `""` for a package's primary library (`unit_id = <package_name>-<version>`); set to the sublibrary name so GHC gives it a distinct unit ID (`<package_name>-<version>-<component_name>`). |
| `version` | `str` | — | **Yes** | Dotted Cabal version string (for example, `"0.14.4"`), written into `.pkgdb`, `Paths_<pkg>.version`, and `cabal_macros.h` (`CURRENT_PACKAGE_VERSION` and downstream `MIN_VERSION_<pkg>` checks). |
| `srcs` | `list[Label]` | `[]` | No | Haskell source files (`.hs`, `.lhs`, `.hs-boot`, `.lhs-boot`). Can be empty when a package consists solely of `.hsc` templates, `reexported_modules`, or C files (`zlib-clib`). |
| `hsc_srcs` | `list[Label]` | `[]` | No | `hsc2hs` C-binding template files (`*.hsc`). In Stage 3, each `.hsc` file is preprocessed into a `.hs` module using target C headers, `-include cabal_macros.h`, and standard GHC OS/CPU macros before Stage 5 compiles Haskell sources. |
| `c_sources` | `list[Label]` | `[]` | No | Native C/C++/assembly source files (`.c`, `.cc`, `.cpp`, `.S`, `.s`) from Cabal `c-sources:` / `cxx-sources:`, compiled in parallel in Stage 4 with `-fPIC`, `-include cabal_macros.h`, and GHC RTS headers. |
| `hdrs` | `list[Label]` | `[]` | No | All header files in the package (both private internal headers and public headers), plus any non-header `.c` files textually `#include`d by other `.c` files (such as `crypton`'s `cbits/*_impl.c`). |
| `install_includes` | `list[str]` | `[]` | No | Header filenames or relative paths from Cabal `install-includes:` (matched against `hdrs` and `configure_outputs`) that should be exported publicly via `CcInfo` + [`HsLinkInfo`](extensions-and-providers.md#hslinkinfo) so *downstream* packages can `#include` them (for example, `zlib-clib` exporting `["zlib.h", "zconf.h"]` to `streaming-commons`). Headers in `hdrs` omitted from `install_includes` stay private to this package. |
| `include_dirs` | `list[str]` | `[]` | No | Package-relative C include directories from Cabal `include-dirs:`, added to `-I` during `./configure`, `hsc2hs`, C compilation, and GHC compilation, and propagated publicly when `install_includes` are present. |
| `hs_source_dirs` | `list[str]` | `[]` | No | Package-relative Haskell import root directories from Cabal `hs-source-dirs:` (defaults to `["."]`). |
| `exposed_modules` | `list[str]` | `[]` | No | Dotted Haskell module names from Cabal `exposed-modules:` that downstream `deps` consumers are allowed to `import`. Passing explicit module names also tells GHC to ignore unreferenced scratch `.hs` files sitting in the tarball directory. |
| `other_modules` | `list[str]` | `[]` | No | Internal dotted Haskell module names from Cabal `other-modules:` compiled into the archive for private use by `exposed_modules`, but hidden from downstream `import`s (`hidden-modules:` in `.conf`). |
| `reexported_modules` | `list[str]` | `[]` | No | Cabal `reexported-modules:` entries (`"orig-pkg:Orig.Mod as New.Mod"` or `"Orig.Mod"`) allowing a package to re-expose a dependency's module under its own package namespace without wrapper `.hs` boilerplate. |
| `default_language` | `str` | `"Haskell98"` | No | Cabal `default-language:` edition passed via `-X<default_language>` (`"Haskell98"`, `"Haskell2010"`, `"GHC2021"`, or `"GHC2024"`). Unlike [`hs_library`](rules.md#hs_library) (which defaults to `"GHC2021"` for new user code), `hs_cabal_library` defaults to `"Haskell98"` because the official `.cabal` specification requires legacy packages that omit `default-language:` to be compiled as `Haskell98`. |
| `default_extensions` | `list[str]` | `[]` | No | Cabal `default-extensions:` / `extensions:`, each passed to GHC as `-X<ext>`. |
| `ghc_opts` | `list[str]` | `[]` | No | Compiler flags passed to `ghc --make -c` in Stage 5 (sanitized by [`//tools/lock:lock`](lock-cli.md) when generated from lockfiles so upstream `-Werror` flags do not break consumer builds). |
| `cpp_options` | `list[str]` | `[]` | No | C Preprocessor flags (`-D...`) from Cabal `cpp-options:`, passed to both `hsc2hs` (`--cflag`) in Stage 3 and GHC (`-optP`) in Stage 5 for `#ifdef` blocks in `.hsc` and `.hs` files. |
| `cc_options` | `list[str]` | `[]` | No | C/C++ compiler flags from Cabal `cc-options:` / `cxx-options:`, passed to both `hsc2hs` and Stage 4 `cc_common.compile`. |
| `build_type` | `str` | `"Simple"` | No | Normalized Cabal `build-type:` (`"Simple"` or `"Configure"`). Stage 1 `./configure` runs only when `build_type == "Configure"` and both `configure_script` and `configure_outputs` are set; unsupported bespoke `"Custom"` packages fail at analysis with a clear diagnostic rather than silently skipping `Setup.hs`. |
| `configure_script` | `Label` | `None` | No | Label of the pre-generated GNU Autoconf `configure` shell script inside the tarball when `build_type = "Configure"` (for example, in `network` or `unix-time`). |
| `configure_srcs` | `list[Label]` | `[]` | No | Supporting files copied into the temporary writable `./configure` sandbox directory (`config.guess`, `config.sub`, `install-sh`, `*.h.in` templates, `*.buildinfo`, and headers probed by `configure`). |
| `configure_outputs` | `list[str]` | `[]` | No | Tarball-relative paths of headers generated by `./configure` (such as `["include/HsNetworkConfig.h"]`), declared as Bazel action outputs and added automatically to `-I` include paths for Stages 3–5. |
| `configure_args` | `list[str]` | `[]` | No | Extra CLI flags appended to `/bin/sh ./configure` (for example, `["--disable-ipv6"]`), usually injected from `MODULE.bazel` via [`hackage.override`](extensions-and-providers.md#hackage-override). |
| `generate_paths_module` | `bool` | `False` | No | Set `True` when a Cabal package imports its autogenerated `Paths_<sanitized_pkg>` module (to read `version` or `getDataFileName`); Stage 2 writes a hermetic `Paths_<pkg>.hs` file and compiles it into Stage 5. |
| `deps` | `list[Label]` | `[]` | No | Direct Cabal `build-depends` library targets providing [`HsPackageInfo`](extensions-and-providers.md#hspackageinfo) or `CcInfo` (including C-only `hs_cabal_library` targets and local internal sublibraries). |
| `extra_cc_deps` | `list[Label]` | `[]` | No | Additional Bazel `cc_library` (`CcInfo`) targets wired into this package (used by [`hackage.override`](extensions-and-providers.md#hackage-override) when linking a Hackage wrapper like `zlib` against BCR `@zlib//:zlib`). |
| `data` | `list[Label]` | `[]` | No | Cabal `data-files` staged at their original relative paths inside the Stage 5 compilation sandbox (so compile-time `file-embed` Template Haskell splices in packages like `pandoc` and `citeproc` find them) and forwarded into Bazel runfiles. |

### Example

```starlark
load("@rules_hs//hs:defs.bzl", "hs_cabal_library")

# C-only Cabal library propagating public headers (<zlib.h>, <zconf.h>) to downstream Haskell packages
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

Connects a staged GHC compiler distribution (`staged_ghc`), the native C11 `ghc_cc_wrapper`, and parsed boot library metadata into Bazel's `toolchain()` resolution framework (`platform_common.ToolchainInfo(hs = HsToolchainInfo)`).

**When to use it**: Standard workspaces never call `hs_toolchain` directly — [`hs.toolchain`](extensions-and-providers.md#hs-toolchain) generates all `hs_toolchain` targets automatically inside `@hs_toolchains`. Instantiate `hs_toolchain` manually only when registering your own custom-built or corporate-mirrored GHC binary distribution.

- **Load from**: `@rules_hs//hs:toolchain.bzl`
- **Provides**: `platform_common.ToolchainInfo`, [`HsToolchainInfo`](extensions-and-providers.md#hstoolchaininfo)

### Attributes

| Attribute | Type | Default | Required | Description |
|---|---|---|---|---|
| `name` | `Name` | — | **Yes** | Target name of this `hs_toolchain` definition (paired with a Bazel `toolchain(toolchain = ":<name>", toolchain_type = "@rules_hs//hs:toolchain_type", ...)` target). |
| `version` | `str` | — | **Yes** | Dotted GHC compiler version string (for example, `"9.10.3"` or `"9.12.4"`), used to compute `TOOL_VERSION_ghc` macros and preprocessor defines. |
| `staged_ghc` | `Label` | — | **Yes** | Exec-configured `staged_ghc` target providing [`HsToolchainInfo`](extensions-and-providers.md#hstoolchaininfo) with `$ORIGIN`-staged compiler binaries (`ghc`, `ghc-pkg`, `hsc2hs`, `haddock`, `runghc`, `ghc-iserv-dyn`), dereferenced `lib/` directory, boot `.haddock` interfaces, and static `libgmp.a`. |
| `cc_wrapper` | `Label` | `Label("//hs/private:ghc_cc_wrapper")` | No | Exec-configured C11 adapter binary invoked by GHC, `hsc2hs`, `haddock`, and `./configure` to scrub `RUNFILES_*` variables and normalize C compiler/linker flags. Override only if supplying a custom wrapper. |
| `boot_packages_json` | `dict[str, str]` | `{}` | No | Map of boot package name (`"base"`, `"text"`, etc.) to a JSON object string `{"name", "version", "id", "depends", "exposed_modules"}` parsed from GHC's `lib/package.conf.d/*.conf` files, powering [`hs_toolchain_library`](rules.md#hs_toolchain_library). |
| `bignum` | `str` | `"gmp"` | No | Arbitrary-precision integer backend compiled into this GHC distribution: `"gmp"` (standard `deb10` bindists linking `libgmp.a`) or `"native"` (pure-Haskell integer backend used in static `musl` bindists). |
| `is_dynamic_ghc` | `bool` | `True` | No | Set `True` when `bin/ghc` itself is dynamically linked (standard `deb10` Linux and macOS bindists, enabling `-dynamic-too` shared libraries for Template Haskell); set `False` for static GHC executables. |
| `target_os` | `str` | — | **Yes** | Target operating system key (`"linux"`, `"macos"`, or `"windows"`), used to set Cabal/GHC `*_HOST_OS` C preprocessor macros during `hsc2hs` and C compilation. |
| `target_cpu` | `str` | — | **Yes** | Target CPU architecture key (`"x86_64"` or `"arm64"`), used to set `*_HOST_ARCH` C preprocessor macros (`x86_64_HOST_ARCH` or `aarch64_HOST_ARCH`). |
| `arch_libdir` | `str` | — | **Yes** | Subdirectory name inside GHC's `lib/` folder holding shared runtime libraries (for example, `"x86_64-linux-ghc-9.10.3"` or `"aarch64-linux-ghc-9.10.3"`). |
