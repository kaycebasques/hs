---
title: "Language, RTS, Runfiles & Template Haskell"
description: "Configure Haskell language editions, module visibility, .hs-boot mutual recursion, GHC RTS threading, Bazel runfiles, Template Haskell, and Haddock API documentation."
section: guide
nav_title: "Language, RTS, Runfiles & TH"
order: 40
---

This guide covers day-to-day Haskell language configuration, module encapsulation, `.hs-boot` cycles, GHC runtime system (RTS) threading, Bazel `data` runfiles, Template Haskell, and hermetic Haddock API documentation ([`hs_haddock`](../reference/rules.md#hs_haddock)) in `rules_hs`, grounded in the test suites under `tests/rules/` and `tests/basic/`.

## Language Editions & Compiler Extensions

### `default_language`

[`hs_library`](../reference/rules.md#hs_library), [`hs_binary`](../reference/rules.md#hs_binary), and [`hs_test`](../reference/rules.md#hs_test) pass `-X<default_language>` to GHC:

- **User rules (`hs_library`, `hs_binary`, `hs_test`)** default to **`"GHC2021"`**, enabling ergonomic modern extensions (`BangPatterns`, `DeriveFoldable`, `DeriveFunctor`, `DeriveGeneric`, `DeriveTraversable`, `EmptyCase`, `ExistentialQuantification`, `FlexibleContexts`, `FlexibleInstances`, `GeneralizedNewtypeDeriving`, `ImportQualifiedPost`, `InstanceSigs`, `MultiParamTypeClasses`, `NamedFieldPuns`, `NumericUnderscores`, `PolyKinds`, `RankNTypes`, `ScopedTypeVariables`, `StandaloneDeriving`, `TupleSections`, `TypeApplications`, `TypeOperators`, etc.) out of the box.
- **Third-party Cabal packages (`hs_cabal_library`)** default to **`"Haskell98"`**, matching the official Cabal specification when a `.cabal` file omits `default-language:`.

You can select `"Haskell98"`, `"Haskell2010"`, `"GHC2021"`, or `"GHC2024"` per target, and layer additional target-wide extensions via `default_extensions` (from `tests/rules/lang/BUILD.bazel`):

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

## Module Encapsulation & Mutual Recursion

### `hidden_modules` (`other-modules`)

By default, [`hs_library`](../reference/rules.md#hs_library) inspects the compiled `.hi` files produced by `ghc --make -c` and registers every module in `exposed-modules:` inside the library's relocatable `.pkgdb` package configuration.

To keep internal implementation modules private to the library — equivalent to Cabal's `other-modules:` — list their dotted Haskell module names in `hidden_modules`:

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

Modules inside `:math_lib` (`Math.Core`) can freely `import Math.Internal`, while downstream targets depending on `:math_lib` receive a GHC hidden-module compile error if they attempt to import `Math.Internal`.

### Mutual Module Recursion with `.hs-boot`

Because [`hs_library`](../reference/rules.md#hs_library) compiles all modules of a library together via `ghc --make -c`, mutually recursive modules using `.hs-boot` (or `.lhs-boot`) interface files work out of the box — simply include the `.hs-boot` file alongside the `.hs` sources in `srcs` (from `tests/basic/BUILD.bazel`):

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

`rules_hs` stages `.hs-boot` files as compilation inputs while passing only primary `.hs`/`.lhs` source files on the GHC command line, allowing GHC to discover `.hs-boot` files automatically through `-i` search paths.

---

## GHC Runtime System (RTS) & Concurrency

### Threaded vs. Non-Threaded RTS

Both [`hs_binary`](../reference/rules.md#hs_binary) and [`hs_test`](../reference/rules.md#hs_test) set **`threaded = True` by default**, passing `-threaded` at link time:

| Setting | `rtsSupportsBoundThreads` | Capabilities & `forkOS` | Best For |
|---|---|---|---|
| `threaded = True` (default) | `True` | Supports multi-core `getNumCapabilities`, OS-bound threads (`forkOS`), non-blocking `safe` C FFI calls concurrently with green threads, and multi-worker STM | Almost all servers, CLI tools (`async`, `http-client`), and parallel test suites |
| `threaded = False` | `False` | Single OS thread; cooperative green threads (`forkIO` + `MVar`/`STM`) still run, `forkOS` raises an error | Deterministic single-threaded benchmarks or minimal footprint tools |

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

> **Tip — Baking Default RTS Flags Into Executables:** Pass `"-rtsopts"` and `"-with-rtsopts=-N"` in `ghc_opts` on [`hs_binary`](../reference/rules.md#hs_binary) or [`hs_test`](../reference/rules.md#hs_test) when you want your binary to use all available CPU cores automatically without requiring callers to append `+RTS -N -RTS` on the command line.

---

## Bazel `data` Runfiles

Every rule ([`hs_library`](../reference/rules.md#hs_library), [`hs_binary`](../reference/rules.md#hs_binary), [`hs_test`](../reference/rules.md#hs_test), and [`hs_cabal_library`](../reference/rules.md#hs_cabal_library)) accepts a `data` attribute (`attr.label_list(allow_files = True)`) and merges `default_runfiles` transitively across `deps`, `cc_deps` (`extra_cc_deps`), and `data`.

That means:
- A fixture or asset attached to `data` on a deep [`hs_library`](../reference/rules.md#hs_library) target is **automatically available at runtime** to every [`hs_binary`](../reference/rules.md#hs_binary) and [`hs_test`](../reference/rules.md#hs_test) that transitively depends on that library.
- An [`hs_binary`](../reference/rules.md#hs_binary) helper tool placed in `data = [":helper_bin"]` of an [`hs_test`](../reference/rules.md#hs_test) is staged into the test's runfiles alongside all of `:helper_bin`'s own transitive `data` files.

### Reading Runfiles Hermetically in Haskell

Ensure `.bazelrc` sets `common --enable_runfiles`. Under Bzlmod, workspace-local files live under `<runfiles_root>/_main/<package>/<file>` (or `$TEST_WORKSPACE`, which defaults to `_main`).

Here is the zero-dependency runfile resolver pattern from `tests/rules/runfiles/DataLib.hs`:

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

Corresponding `BUILD.bazel` wiring:

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

`rules_hs` supports the full spectrum of Template Haskell out of the box — with zero opt-in attributes required and zero dynamic-library leakage into linked executables:

- **`TemplateHaskellQuotes`** (pure AST construction via `@hs_boot//:template-haskell`).
- **Boot-package & same-library splices** (`//tests/rules/th:th_test`).
- **Cross-library & Hackage Template Haskell splices** (`//tests/rules/th:cross_lib_th_test` and `//tests/rules/th:cross_lib_th_elf_test`), including splices defined in separate [`hs_library`](../reference/rules.md#hs_library) or [`hs_cabal_library`](../reference/rules.md#hs_cabal_library) targets (`aeson`, `file-embed`, `skylighting`, `pandoc`), multi-hop library chains, C FFI / `CApiFFI` calls inside splices, and `runIO` file reads.

### 1. `TemplateHaskellQuotes` (Zero Compile-Time Interpreter Overhead)

Whenever a module only constructs AST quotes (`[| ... |]`, `''MyType`, `'myFunc`) without evaluating `$( ... )` splices itself, prefer `{-# LANGUAGE TemplateHaskellQuotes #-}`:

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

You can evaluate `$( ... )` splices defined in the same library, in upstream [`hs_library`](../reference/rules.md#hs_library) targets, or in Hackage packages (`@hackage//:aeson`, `@hackage//:file-embed`, etc.):

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

### How Cross-Library TH Preserves Static Executables

When `HsToolchainInfo.is_dynamic_ghc == True`, `HsCompileLibrary` (`hs/private/actions.bzl`) compiles libraries with `-dynamic-too`:

1. Static `.o` objects are archived into `${pkgroot}/libHS<unit_id>.a` (`library-dirs` / `library-dirs-static`).
2. Dynamic `.dyn_o` objects (along with any `c_sources` and `cc_deps` archives, linked with `-Wl,-Bsymbolic`) are linked into `<name>.pkgdb/dyn/libHS<unit_id>-ghc<ver>.so`, and `dynamic-library-dirs: ${pkgroot}/<pkgdb_base>/dyn` is recorded in `<unit_id>.conf`.
3. Because `<name>.pkgdb/dyn` is isolated from `${pkgroot}`, GHC's compile-time TH loader resolves `.so` libraries cleanly across multi-hop C FFI and Haskell dependencies, while [`hs_binary`](../reference/rules.md#hs_binary) and [`hs_test`](../reference/rules.md#hs_test) link **100% statically** against `libHS*.a` and `libgmp.a` (`DT_NEEDED` remains strictly base glibc — zero `libHS*.so` or `libgmp.so` at runtime).

> **Tip — Compile-Time File Embedding with `data` (`file-embed` & `runIO`):** `data` files declared on [`hs_library`](../reference/rules.md#hs_library), [`hs_cabal_library`](../reference/rules.md#hs_cabal_library), [`hs_binary`](../reference/rules.md#hs_binary), and [`hs_test`](../reference/rules.md#hs_test) are automatically staged into the compilation sandbox (including package-root working directory staging on [`hs_cabal_library`](../reference/rules.md#hs_cabal_library)) **as well as** runtime runfiles. That means compile-time Template Haskell splices such as `file-embed`'s `$(embedFile "...")` / `$(embedDir "...")` (e.g., `--flag pandoc:embed_data_files=true`) and `runIO . readFile` work hermetically inside `linux-sandbox`!

---

## Generating Haddock API Documentation (`hs_haddock`) {#haddock}

`rules_hs` ships a first-class [`hs_haddock`](../reference/rules.md#hs_haddock) rule that runs the active GHC toolchain's `$ORIGIN`-staged `bin/haddock-ghc-<ver>` binary 100% hermetically inside `linux-sandbox` (with zero host tools or network access).

### Writing Haddock Docstrings & Declaring `hs_haddock`

Annotate modules, types, and functions using standard `-- |` and `-- ^` Haddock comments:

```haskell
-- |
-- Module      : Greet
-- Description : Greeting formatters for hermetic Bazel 9 builds.
module Greet
  ( greetingFor
  ) where

import Data.Text (Text)
import Data.Text qualified as T

-- | Format a trimmed greeting message for @who@.
greetingFor :: Text -> Text
greetingFor who = "Hello, " <> T.strip who <> ", from hermetic rules_hs!"
```

Declare an [`hs_haddock`](../reference/rules.md#hs_haddock) target in `BUILD.bazel` pointing at one or more [`hs_library`](../reference/rules.md#hs_library) (or [`hs_cabal_library`](../reference/rules.md#hs_cabal_library)) targets in `deps`:

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

Build the documentation tree:

```bash
bazel build //:greet_haddock
```

By default (`hyperlinked_source = True`, `quickjump = True`), `bazel-bin/greet_haddock/` is a self-contained HTML `TreeArtifact` containing:
- `index.html` and per-module `<Module>.html` pages (`hidden_modules` are automatically passed via `--hide=<mod>`),
- `src/<Module>.html` syntax-highlighted, clickable source views,
- `doc-index.json` powering Haddock's interactive QuickJump search modal,
- Automatic `--read-interface` hyperlinks to Hackage documentation for GHC boot types (`Text`, `IO`, `Map`, etc.) via `HsToolchainInfo.boot_haddocks`.

### Cross-Target Linking (`haddock_deps`) & Site Mounting

When documenting layered libraries separately, pass upstream `hs_haddock` targets in `haddock_deps` (which consume [`HsHaddockInfo`](../reference/extensions-and-providers.md#hshaddockinfo) `.haddock` interfaces via relative `--read-interface` paths). Because `DefaultInfo.files` of an `hs_haddock` target is a single directory `TreeArtifact`, downstream static-site or packaging rules can reference `$(rootpath :greet_haddock)` directly — just as `//docs:site` mounts `//tools/lock:lock_haddock` at `/haddock/lock/`.
