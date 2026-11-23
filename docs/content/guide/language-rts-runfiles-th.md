---
title: "Language, RTS, Runfiles & Template Haskell"
description: "Configure Haskell language editions (GHC2021 and GHC2024), module visibility, .hs-boot mutual recursion, GHC runtime threading, Bazel runfiles, Template Haskell, and Haddock API docs."
section: guide
nav_title: "Language, RTS, Runfiles & TH"
order: 40
---

This guide covers day-to-day Haskell language settings, interactive `ghci` interpreter sessions ([`hs_repl`](../reference/rules.md#hs_repl) and `@rules_hs//tools/ghci`), module visibility, `.hs-boot` mutually recursive modules, GHC runtime system (RTS) threading, Bazel `data` runfiles, Template Haskell, and Haddock API documentation ([`hs_haddock`](../reference/rules.md#hs_haddock)), based on the test suites under `tests/rules/` and `tests/basic/`.

## Language Editions (`GHC2021` vs. `GHC2024`) & Extensions

In Haskell, a **language edition** (`Haskell98`, `Haskell2010`, `GHC2021`, or `GHC2024`) is a named bundle of GHC compiler extensions enabled together via `-X<edition>`, saving you from repeating dozens of `{-# LANGUAGE ... #-}` headers at the top of every source file.

### Why `default_language` Defaults to `"GHC2021"` Instead of `"GHC2024"`

[`hs_library`](../reference/rules.md#hs_library), [`hs_binary`](../reference/rules.md#hs_binary), and [`hs_test`](../reference/rules.md#hs_test) pass `-X<default_language>` to GHC with the following defaults:

- **User rules (`hs_library`, `hs_binary`, `hs_test`)** default to **`"GHC2021"`**.
- **Third-party Cabal packages (`hs_cabal_library`)** default to **`"Haskell98"`** when an older `.cabal` manifest omits `default-language:`, matching the Cabal specification.

Why does `rules_hs` default user targets to `"GHC2021"` rather than `"GHC2024"` even on GHC `9.10.3` and `9.12.4`?

1. **Upstream GHC compatibility**: GHC `9.10` and `9.12` themselves still use `GHC2021` as the compiler's built-in default when invoked without an explicit language edition flag.
2. **`MonoLocalBinds` in `GHC2024`**: `GHC2024` adds several useful extensions on top of `GHC2021` — including `LambdaCase`, `DerivingStrategies`, `GADTs`, `DataKinds`, `DisambiguateRecordFields`, `ExplicitNamespaces`, and `RoleAnnotations` — **and** it also turns on `MonoLocalBinds`. With `MonoLocalBinds` enabled, GHC stops automatically inferring polymorphic (generic) types for local helper functions inside `let` and `where` blocks when certain type features are in scope. Existing `Haskell2010` and `GHC2021` modules that rely on polymorphic local helpers can fail typechecking under `GHC2024` until explicit type signatures are added to those `let`/`where` bindings.

Keeping `"GHC2021"` as the default matches upstream GHC behavior while enabling widely used features (`ImportQualifiedPost`, `BangPatterns`, `DeriveFunctor`, `DeriveGeneric`, `DeriveTraversable`, `FlexibleContexts`, `FlexibleInstances`, `GeneralizedNewtypeDeriving`, `MultiParamTypeClasses`, `NamedFieldPuns`, `NumericUnderscores`, `PolyKinds`, `RankNTypes`, `ScopedTypeVariables`, `StandaloneDeriving`, `TupleSections`, `TypeApplications`, and `TypeOperators`).

### Opting Into `GHC2024` (or `Haskell2010` / `Haskell98`)

Both GHC `9.10.3` and `9.12.4` support `GHC2024`. Pass `default_language = "GHC2024"` on any target (or wrap `hs_library` in a small `.bzl` macro in new projects):

```haskell
-- src/Status.hs (compiled with default_language = "GHC2024")
module Status (Status (..), describeStatus) where

-- DerivingStrategies (deriving stock) and LambdaCase (\case) are built into GHC2024,
-- so no {-# LANGUAGE #-} pragmas are needed in this file.
data Status = Pending | Complete
  deriving stock (Eq, Show)

describeStatus :: Status -> String
describeStatus = \case
  Pending -> "pending"
  Complete -> "complete"
```

```starlark
load("@rules_hs//hs:defs.bzl", "hs_library")

hs_library(
    name = "status_lib",
    srcs = ["src/Status.hs"],
    default_language = "GHC2024",
    ghc_opts = ["-Wall"],
    hs_source_dirs = ["src"],
    deps = ["@hs_boot//:base"],
)
```

You can also stay on `"GHC2021"` and add specific target-wide extensions via `default_extensions` (from `tests/rules/lang/BUILD.bazel`):

```starlark
load("@rules_hs//hs:defs.bzl", "hs_library")

hs_library(
    name = "domain_lib",
    srcs = [
        "src/Org/RulesHs/Eval/Engine.hs",
        "src/Org/RulesHs/Internal/Secret.hs",
        "src/Org/RulesHs/Types.hs",
    ],
    default_extensions = [
        "OverloadedStrings",
        "DerivingStrategies",
        "LambdaCase",
    ],
    default_language = "GHC2021",
    ghc_opts = [
        "-Wall",
        "-Werror",
        "-O2",
    ],
    hidden_modules = ["Org.RulesHs.Internal.Secret"],
    hs_source_dirs = ["src"],
    deps = [
        "@hs_boot//:base",
        "@hs_boot//:text",
    ],
)
```

---

## Interactive `ghci` REPL & Interpreter Modes (`hs_repl` and `//tools/ghci`) {#interactive-ghci-repl}

`rules_hs` supports GHC's interactive and non-interactive interpreter execution modes alongside batch compilation:

### 1. Project REPL Targets (`hs_repl`)

Declare an [`hs_repl`](../reference/rules.md#hs_repl) target in `BUILD.bazel` pointing at one or more [`hs_library`](../reference/rules.md#hs_library), [`hs_binary`](../reference/rules.md#hs_binary), or [`hs_test`](../reference/rules.md#hs_test) targets:

```starlark
load("@rules_hs//hs:defs.bzl", "hs_library", "hs_repl")

hs_library(
    name = "math_lib",
    srcs = [
        "Math/Core.hs",
        "Math/Internal.hs",
    ],
    hidden_modules = ["Math.Internal"],
    deps = ["@hs_boot//:base"],
)

hs_repl(
    name = "math_repl",
    ghci_commands = [":set +t"],
    deps = [":math_lib"],
)
```

Launch an interactive `ghci` session with `bazel run`:

```bash
bazel run //:math_repl
```

Inside the session:

- **Bytecode scope (`*Module`)**: Workspace targets in `deps` are loaded from source into GHCi bytecode (`interpret_deps = True` by default), placing all target modules (including `hidden_modules` and unexported top-level helpers) in scope at the `ghci>` prompt. External `@hs_boot` and `@hackage` packages (plus any targets listed in `compiled_deps`) load from precompiled `.so` shared libraries.
- **Live `:reload` without re-running Bazel**: When launched via `bazel run`, workspace source files and `-i` search paths resolve against `$BUILD_WORKSPACE_DIRECTORY`. Edit any loaded `.hs` file in your editor and run `:reload` (`:r`) at the `ghci>` prompt to recompile in place.
- **Line editing, completion, `Ctrl-C`, and `:break` debugging**: GHC's `haskeline` prompt runs against `rules_hs`'s C11 `libtinfo.so.6` implementation (supporting arrow-key history, Tab identifier completion, `Ctrl-C` evaluation interruption, and GHCi's `:break` / `:step` / `:continue` bytecode debugger).
- **C/C++ FFI, `CApiFFI`, Template Haskell, and `data` runfiles**: Native C and C++ archives in `c_sources` and `cc_deps` are linked automatically into a shared helper library (`HsLinkReplCbits`), `ghc_cc_wrapper` compiles `CApiFFI` stubs on demand, cross-library Template Haskell splices run in-process (or out-of-process when passing `-- -fexternal-interpreter`), and `RUNFILES_DIR` remains exported for `data` files.

### 2. One-Shot Expression Evaluation (`-e`) and Standalone `//tools/ghci`

Pass `-e '<expr>'` after `--` to evaluate an expression in the loaded module context and exit:

```bash
bazel run //:math_repl -- -e 'computeValue 5'
```

To open a standalone `ghci` prompt or run a single `.hs` script via `runghc` without declaring a rule in `BUILD.bazel`, use `@rules_hs//tools/ghci`:

```bash
# Standalone ghci prompt with GHC's boot packages visible:
bazel run @rules_hs//tools/ghci

# Evaluate an expression directly:
bazel run @rules_hs//tools/ghci -- -e '2 ^ 64 :: Integer'

# Execute a standalone Haskell script via staged runghc:
bazel run @rules_hs//tools/ghci:runghc -- ./script.hs arg1 arg2
```

---

## Module Encapsulation & Mutual Recursion

### Keeping Internal Modules Private (`hidden_modules`)

When [`hs_library`](../reference/rules.md#hs_library) compiles a library, it inspects the generated `.hi` compiler interface files and lists every module under `exposed-modules:` in the library's package database registration file unless told otherwise.

To keep internal helper modules private to a library — equivalent to Cabal's `other-modules:` field — list their dotted Haskell module names in `hidden_modules`:

```starlark
hs_library(
    name = "math_lib",
    srcs = [
        "Math/Core.hs",
        "Math/Internal.hs",
    ],
    hidden_modules = ["Math.Internal"],
    deps = ["@hs_boot//:base"],
)
```

Modules inside `:math_lib` (such as `Math.Core`) can `import Math.Internal`, while any downstream target depending on `:math_lib` receives a GHC compile error (`Could not load module 'Math.Internal': it is a hidden module`) if it tries to import `Math.Internal`.

### Mutually Recursive Modules with `.hs-boot`

Haskell compilers typecheck modules in dependency order, so two `.hs` files normally cannot import each other in a loop (`BootA` imports `BootB` and `BootB` imports `BootA`). When two modules genuinely need to reference each other's types or functions, GHC breaks the cycle with a **`.hs-boot` forward-declaration file** (similar in spirit to a `.h` forward declaration in C):

```haskell
-- BootA.hs-boot (declares only the abstract type/function signatures BootB needs first)
module BootA (NodeA, sumNodeA) where
data NodeA
sumNodeA :: NodeA -> Int
```

```haskell
-- BootB.hs (imports the lightweight BootA.hs-boot interface via {-# SOURCE #-})
module BootB (NodeB (..), sumNodeB) where
import {-# SOURCE #-} BootA (NodeA, sumNodeA)
data NodeB = NodeB Int NodeA
sumNodeB :: NodeB -> Int
sumNodeB (NodeB x a) = x + sumNodeA a
```

```haskell
-- BootA.hs (full implementation, checked by GHC against BootA.hs-boot)
module BootA (NodeA (..), sumNodeA) where
import BootB (NodeB, sumNodeB)
data NodeA = NodeA Int (Maybe NodeB)
sumNodeA :: NodeA -> Int
sumNodeA (NodeA x mb) = x + maybe 0 sumNodeB mb
```

Because [`hs_library`](../reference/rules.md#hs_library) compiles all modules of a library together via `ghc --make -c`, include the `.hs-boot` (or `.lhs-boot`) file alongside the `.hs` files in `srcs` (from `tests/basic/BUILD.bazel`):

```starlark
hs_library(
    name = "boot_cycle_lib",
    srcs = [
        "BootA.hs",
        "BootA.hs-boot",
        "BootB.hs",
    ],
    deps = ["@hs_boot//:base"],
)
```

`rules_hs` stages `.hs-boot` files in the compile sandbox while passing only `.hs` and `.lhs` files as command-line entry points to GHC, letting GHC resolve `{-# SOURCE #-}` imports automatically through its `-i` source search paths.

---

## GHC Runtime System (RTS) & Concurrency

Every compiled Haskell binary links in GHC's **Runtime System (RTS)** — a C library bundled with GHC that provides garbage collection, lightweight green threads (`forkIO`, similar to Go goroutines), software transactional memory (`STM`), and non-blocking network/timer I/O polling.

### Threaded vs. Single-Threaded RTS

GHC ships two variants of the RTS library, controlled by the `threaded` attribute on [`hs_binary`](../reference/rules.md#hs_binary) and [`hs_test`](../reference/rules.md#hs_test) (**`threaded = True` by default**):

| Setting | `rtsSupportsBoundThreads` | How Threads & C Calls Run | When to Use |
|---|---|---|---|
| `threaded = True` (default) | `True` | Schedules Haskell green threads across multiple OS worker threads (`-N`), supports OS-bound threads (`forkOS`), and runs `safe` blocking C FFI calls on dedicated OS threads without pausing other green threads | Servers, concurrent CLI tools (`async`, `http-client`), C FFI programs, and parallel test suites |
| `threaded = False` | `False` | Runs all Haskell green threads (`forkIO` + `MVar`/`STM`) cooperatively on a single OS thread; calling `forkOS` raises a runtime error, and a blocking C call pauses all green threads until it returns | Single-threaded benchmarks or tools that never need multi-core parallelism |

```starlark
load("@rules_hs//hs:defs.bzl", "hs_binary", "hs_test")

hs_binary(
    name = "worker_service",
    srcs = ["Main.hs"],
    ghc_opts = [
        "-rtsopts",
        "-with-rtsopts=-N -A32m",
    ],
    threaded = True,
    deps = [
        "@hs_boot//:base",
        "@hs_boot//:stm",
    ],
)

hs_test(
    name = "single_threaded_test",
    size = "small",
    srcs = ["NonThreadedRtsTest.hs"],
    threaded = False,
    deps = ["@hs_boot//:base"],
)
```

> **Tip — Setting default multi-core RTS flags at link time:** Even with `threaded = True`, GHC binaries default to using 1 CPU core at startup unless told otherwise. Pass `"-rtsopts"` and `"-with-rtsopts=-N"` in `ghc_opts` on [`hs_binary`](../reference/rules.md#hs_binary) or [`hs_test`](../reference/rules.md#hs_test) (optionally adding `-A32m` for a 32 MiB garbage-collector allocation area) so your executable uses all available CPU cores automatically without callers passing `+RTS -N -RTS` on the command line.

---

## Bazel `data` Runfiles

When a binary or test needs non-code files at runtime — such as JSON schemas, SQL migrations, test fixture files, or helper executables — Bazel stages those files inside a directory tree called **runfiles** (`<binary>.runfiles/_main/<package>/<file>`) rather than assuming your program runs from the Git repository root.

Every rule ([`hs_library`](../reference/rules.md#hs_library), [`hs_binary`](../reference/rules.md#hs_binary), [`hs_test`](../reference/rules.md#hs_test), and [`hs_cabal_library`](../reference/rules.md#hs_cabal_library)) accepts a `data` attribute and merges runfiles transitively across `deps`, `cc_deps` (`extra_cc_deps`), and `data`:

- A file listed in `data` on a [`hs_library`](../reference/rules.md#hs_library) target is **automatically available at runtime** to every [`hs_binary`](../reference/rules.md#hs_binary) and [`hs_test`](../reference/rules.md#hs_test) that transitively depends on that library.
- A helper [`hs_binary`](../reference/rules.md#hs_binary) listed in `data = [":helper_bin"]` on an [`hs_test`](../reference/rules.md#hs_test) is staged into the test's runfiles together with all of `:helper_bin`'s own transitive `data` files.

### Locating Runfiles in Haskell

Make sure `.bazelrc` includes `common --enable_runfiles`. Under Bzlmod, files from your root workspace sit under `<runfiles_root>/_main/<package>/<file>` (or `$TEST_WORKSPACE`, which defaults to `_main`).

Here is a small runfile path helper using only GHC boot libraries (from `tests/rules/runfiles/DataLib.hs`):

```haskell
module Runfiles (resolveRunfile) where

import Data.Maybe (fromMaybe)
import System.Directory (doesFileExist)
import System.Environment (getExecutablePath, lookupEnv)
import System.FilePath ((</>))

-- | Resolve a workspace-relative path (e.g. "testdata/config.json") across
-- bazel test (TEST_SRCDIR / RUNFILES_DIR) and bazel run (<exe>.runfiles).
resolveRunfile :: FilePath -> IO FilePath
resolveRunfile rel = do
  ws <- fromMaybe "_main" <$> lookupEnv "TEST_WORKSPACE"
  mRf <- lookupEnv "RUNFILES_DIR"
  mTs <- lookupEnv "TEST_SRCDIR"
  exe <- getExecutablePath
  let envCandidates =
        [ dir </> ws </> rel
        | Just dir <- [mRf, mTs]
        , not (null dir)
        ]
      candidates = envCandidates ++ [(exe ++ ".runfiles") </> ws </> rel, rel]
  pickExisting candidates
  where
    pickExisting [] = pure rel
    pickExisting [p] = pure p
    pickExisting (p : ps) = do
      exists <- doesFileExist p
      if exists then pure p else pickExisting ps
```

Corresponding `BUILD.bazel` targets:

```starlark
hs_library(
    name = "runfiles_lib",
    srcs = ["Runfiles.hs"],
    data = ["assets/default_schema.json"],
    deps = [
        "@hs_boot//:base",
        "@hs_boot//:directory",
        "@hs_boot//:filepath",
    ],
)

hs_test(
    name = "schema_test",
    size = "small",
    srcs = ["SchemaTest.hs"],
    data = ["testdata/sample.json"],
    deps = [
        ":runfiles_lib",
        "@hs_boot//:base",
    ],
)
```

---

## Template Haskell (`TemplateHaskell` & `TemplateHaskellQuotes`)

**Template Haskell (TH)** is GHC's built-in compile-time code generation system (comparable to procedural macros in Rust). While compiling a module, GHC can evaluate Haskell expressions wrapped in `$( ... )` (called **splices**) and insert the generated declarations, types, or expressions directly into the module being compiled. Common Hackage libraries use Template Haskell to generate boilerplate JSON encoders (`aeson`) or embed static files into binaries at compile time (`file-embed`).

`rules_hs` supports Template Haskell with no extra rule attributes required:

- **`TemplateHaskellQuotes`**: Constructing syntax trees (`[| ... |]`, `''MyType`, `'myFunc`) via `@hs_boot//:template-haskell` without running splices in the current module.
- **Boot-package and same-library splices** (`//tests/rules/th:th_test`).
- **Cross-library and Hackage Template Haskell splices** (`//tests/rules/th:cross_lib_th_test` and `//tests/rules/th:cross_lib_th_elf_test`), including splices imported from separate [`hs_library`](../reference/rules.md#hs_library) or [`hs_cabal_library`](../reference/rules.md#hs_cabal_library) targets (`aeson`, `file-embed`, `skylighting`, `pandoc`), multi-hop library chains, C FFI / `CApiFFI` calls inside splices, and compile-time `runIO` file reads.

### 1. `TemplateHaskellQuotes` (Building Syntax Trees Without Running the Interpreter)

When a helper module only constructs quoted syntax (`[| ... |]`, `''MyType`, `'myFunc`) for downstream modules to splice in, enable `{-# LANGUAGE TemplateHaskellQuotes #-}` instead of full `TemplateHaskell` so GHC does not start its compile-time interpreter for that module:

```haskell
{-# LANGUAGE TemplateHaskellQuotes #-}

module ThHelper (mkAnswerExp, maybeTypeName) where

import Language.Haskell.TH (Exp, Name, Q)

maybeTypeName :: Name
maybeTypeName = ''Maybe

mkAnswerExp :: Int -> Q Exp
mkAnswerExp n = [| n * 2 |]
```

### 2. Same-Library & Cross-Library Splices (`{-# LANGUAGE TemplateHaskell #-}`)

To evaluate `$( ... )` splices defined in the same library, in upstream [`hs_library`](../reference/rules.md#hs_library) targets, or in Hackage packages (`@hackage//:aeson`, `@hackage//:file-embed`, etc.), enable `{-# LANGUAGE TemplateHaskell #-}`:

```haskell
{-# LANGUAGE TemplateHaskell #-}

module ThConsumer (crossLibAnswer, splicedFortyTwo) where

import ThHelper (mkAnswerExp)

splicedFortyTwo :: Int
splicedFortyTwo = $( [| 20 + 22 |] )

crossLibAnswer :: Int
crossLibAnswer = $(mkAnswerExp 21)
```

```starlark
load("@rules_hs//hs:defs.bzl", "hs_library", "hs_test")

hs_library(
    name = "th_helper_lib",
    srcs = ["ThHelper.hs"],
    deps = [
        "@hs_boot//:base",
        "@hs_boot//:template-haskell",
    ],
)

hs_library(
    name = "th_consumer_lib",
    srcs = ["ThConsumer.hs"],
    deps = [
        ":th_helper_lib",
        "@hs_boot//:base",
        "@hs_boot//:template-haskell",
    ],
)

hs_test(
    name = "cross_lib_th_test",
    size = "small",
    srcs = ["ThTest.hs"],
    deps = [
        ":th_consumer_lib",
        "@hs_boot//:base",
    ],
)
```

### How Cross-Library Template Haskell Keeps Final Executables Statically Linked

Because official GHC binary distributions are dynamically linked executables, GHC's compile-time splice runner (`ghc-iserv`) must load upstream libraries as shared `.so` files while compiling a `TemplateHaskell` module. To support that without turning your final executables into dynamically linked binaries, `HsCompileLibrary` (`hs/private/actions.bzl`) compiles libraries with `-dynamic-too`:

1. Static `.o` objects are packed into `${pkgroot}/libHS<unit_id>.a` (`library-dirs` and `library-dirs-static`).
2. Dynamic `.dyn_o` objects (along with any `c_sources` and `cc_deps` C archives, linked with `-Wl,-Bsymbolic`) are linked into `<name>.pkgdb/dyn/libHS<unit_id>-ghc<ver>.so`, and `dynamic-library-dirs: ${pkgroot}/<pkgdb_base>/dyn` is recorded in `<unit_id>.conf`.
3. Keeping `.so` files in `<name>.pkgdb/dyn` lets GHC's compile-time TH loader load `.so` libraries across multi-hop Haskell and C dependencies during compilation, while [`hs_binary`](../reference/rules.md#hs_binary) and [`hs_test`](../reference/rules.md#hs_test) link only static `libHS*.a` and `libgmp.a` archives (so linked binaries carry no runtime `libHS*.so` or `libgmp.so` dependencies).

> **Tip — Compile-time file embedding with `data` (`file-embed` and `runIO`):** Files listed in `data` on [`hs_library`](../reference/rules.md#hs_library), [`hs_cabal_library`](../reference/rules.md#hs_cabal_library), [`hs_binary`](../reference/rules.md#hs_binary), and [`hs_test`](../reference/rules.md#hs_test) are staged into the compilation sandbox (as well as runtime runfiles). Compile-time Template Haskell splices such as `file-embed`'s `$(embedFile "...")` and `$(embedDir "...")` (used by `--flag pandoc:embed_data_files=true`) or `runIO (readFile ...)` can read declared `data` files directly inside `linux-sandbox`.

---

## Generating Haddock API Documentation (`hs_haddock`) {#haddock}

**Haddock** is Haskell's standard API documentation generator (analogous to `rustdoc` in Rust or `godoc` in Go) and ships inside every GHC distribution. [`hs_haddock`](../reference/rules.md#hs_haddock) runs GHC's staged `bin/haddock-ghc-<ver>` binary inside Bazel's sandbox with no host tools or network access.

### Writing Haddock Comments and Declaring `hs_haddock`

Document modules, types, and functions with `-- |` (before an item) and `-- ^` (after an item or constructor field) comments:

```haskell
-- |
-- Module      : Greet
-- Description : Greeting formatters for Bazel 9 builds.
module Greet
  ( greetingFor
  ) where

import Data.Text (Text)
import Data.Text qualified as T

-- | Format a trimmed greeting message for @who@.
greetingFor :: Text -> Text
greetingFor who = "Hello, " <> T.strip who <> ", from rules_hs."
```

Declare an [`hs_haddock`](../reference/rules.md#hs_haddock) target in `BUILD.bazel` listing one or more [`hs_library`](../reference/rules.md#hs_library) (or [`hs_cabal_library`](../reference/rules.md#hs_cabal_library)) targets in `deps`:

```starlark
load("@rules_hs//hs:defs.bzl", "hs_haddock", "hs_library")

hs_library(
    name = "greet",
    srcs = ["src/Greet.hs"],
    hs_source_dirs = ["src"],
    deps = [
        "@hs_boot//:base",
        "@hs_boot//:text",
    ],
)

hs_haddock(
    name = "greet_haddock",
    prologue = "README.md",
    title = "Greet Library API",
    deps = [":greet"],
)
```

Build the documentation directory:

```bash
bazel build //:greet_haddock
```

By default (`hyperlinked_source = True`, `quickjump = True`), `bazel-bin/greet_haddock/` is a self-contained HTML directory output containing:
- `index.html` and per-module `<Module>.html` pages (`hidden_modules` are automatically hidden via `--hide=<mod>`),
- `src/<Module>.html` syntax-highlighted, clickable source code pages,
- `doc-index.json` powering Haddock's client-side QuickJump search dialog,
- Cross-reference hyperlinks to Hackage documentation for GHC boot types (`Text`, `IO`, `Map`, etc.) via `HsToolchainInfo.boot_haddocks`.

### Cross-Target Linking (`haddock_deps`) and Site Mounting

When generating separate Haddock bundles for layered libraries, pass upstream `hs_haddock` targets in `haddock_deps` so Haddock reads their `.haddock` interface files (`HsHaddockInfo`) and emits relative links between them. Because the default output of an `hs_haddock` target is a single Bazel directory artifact, downstream static-site or packaging rules can consume `$(rootpath :greet_haddock)` as one path — just as `//docs:site` mounts `//tools/lock:lock_haddock` at `/haddock/lock/`.
