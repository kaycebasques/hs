---
title: "Language, RTS, Runfiles & Template Haskell"
description: "Configure Haskell language editions, module visibility, .hs-boot mutual recursion, GHC RTS threading, Bazel runfiles, and Template Haskell."
section: guide
nav_title: "Language, RTS, Runfiles & TH"
order: 40
---

This guide covers day-to-day Haskell language configuration, module encapsulation, `.hs-boot` cycles, GHC runtime system (RTS) threading, Bazel `data` runfiles, and Template Haskell in `rules_hs`, grounded in the test suites under `tests/rules/` and `tests/basic/`.

## Language Editions & Compiler Extensions

### `default_language`

`bzl:rule:hs_library`, `bzl:rule:hs_binary`, and `bzl:rule:hs_test` pass `-X<default_language>` to GHC:

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

By default, `bzl:rule:hs_library` inspects the compiled `.hi` files produced by `ghc --make -c` and registers every module in `exposed-modules:` inside the library's relocatable `.pkgdb` package configuration.

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

Because `bzl:rule:hs_library` compiles all modules of a library together via `ghc --make -c`, mutually recursive modules using `.hs-boot` (or `.lhs-boot`) interface files work out of the box — simply include the `.hs-boot` file alongside the `.hs` sources in `srcs` (from `tests/basic/BUILD.bazel`):

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

Both `bzl:rule:hs_binary` and `bzl:rule:hs_test` set **`threaded = True` by default**, passing `-threaded` at link time:

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

::: {.tip title="Baking Default RTS Flags Into Executables"}
Pass `"-rtsopts"` and `"-with-rtsopts=-N"` in `ghc_opts` on `bzl:rule:hs_binary` or `bzl:rule:hs_test` when you want your binary to use all available CPU cores automatically without requiring callers to append `+RTS -N -RTS` on the command line.
:::

---

## Bazel `data` Runfiles

Every rule (`bzl:rule:hs_library`, `bzl:rule:hs_binary`, `bzl:rule:hs_test`, and `bzl:rule:hs_cabal_library`) accepts a `data` attribute (`attr.label_list(allow_files = True)`) and merges `default_runfiles` transitively across `deps`, `cc_deps` (`extra_cc_deps`), and `data`.

That means:
- A fixture or asset attached to `data` on a deep `bzl:rule:hs_library` target is **automatically available at runtime** to every `bzl:rule:hs_binary` and `bzl:rule:hs_test` that transitively depends on that library.
- An `bzl:rule:hs_binary` helper tool placed in `data = [":helper_bin"]` of an `bzl:rule:hs_test` is staged into the test's runfiles alongside all of `:helper_bin`'s own transitive `data` files.

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

`rules_hs` stages GHC's `template-haskell` boot library (`@hs_boot//:template-haskell` / `@hackage//:template-haskell`) and dynamic compiler support cleanly inside the sandbox.

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

### 2. Compile-Time Splices (`{-# LANGUAGE TemplateHaskell #-}`)

Compile-time TH splices (`$( ... )`, `deriveJSON`, `makeLenses`, `embedFile`, etc.) evaluate during compilation using GHC's staged toolchain:

```haskell
{-# LANGUAGE TemplateHaskell #-}

module ThConsumer (crossModAnswer, splicedFortyTwo) where

import ThHelper (mkAnswerExp)

splicedFortyTwo :: Int
splicedFortyTwo = $( [| 20 + 22 |] )

crossModAnswer :: Int
crossModAnswer = $(mkAnswerExp 21)
```

```starlark
hs_library(
    name = "th_lib",
    srcs = [
        "ThConsumer.hs",
        "ThHelper.hs",
    ],
    deps = [
        "@hs_boot//:base",
        "@hs_boot//:template-haskell",
    ],
)
```

::: {.note title="Compile-Time File Embedding with TH"}
When using `file-embed` (`$(embedFile "...")`) in a library or third-party Cabal package (such as `pandoc` with `--flag pandoc:embed_data_files=true`), make sure any files read at **compile time** by TH splices are included in `hdrs` (for `bzl:rule:hs_library` / `bzl:rule:hs_cabal_library`) so Bazel mounts them inside the compilation sandbox! Runtime-only files belong in `data`.
:::
