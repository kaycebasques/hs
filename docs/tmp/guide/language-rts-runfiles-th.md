---
title: "Language, RTS, runfiles, and Template Haskell"
description: "Configure Haskell language editions (GHC2021 and GHC2024), interactive GHCi sessions, module visibility, .hs-boot mutual recursion, GHC runtime threading, Bazel runfiles, Template Haskell, and Haddock API docs."
section: guide
nav_title: "Language, RTS, runfiles, and TH"
order: 40
---

Use this guide to configure day-to-day Haskell builds: language editions (`GHC2021` and `GHC2024`), interactive GHCi sessions, module visibility, `.hs-boot` mutual recursion, GHC runtime threading, Bazel [runfiles](https://bazel.build/extending/rules#runfiles), Template Haskell, and Haddock API docs. Every example below comes from the test suites under `tests/rules/` and `tests/basic/`.

If you're setting up your first workspace, start with the [Quickstart](quickstart.md). For full rule and attribute signatures, see the [Rules reference](../reference/rules.md).

## Language editions and extensions

A Haskell **language edition** (`Haskell98`, `Haskell2010`, `GHC2021`, or `GHC2024`) bundles a standard set of GHC compiler extensions under a single `-X<edition>` flag. Setting an edition on a target saves you from repeating `{-# LANGUAGE ... #-}` pragmas at the top of every source file.

### Why `default_language` defaults to `GHC2021` instead of `GHC2024`

By default, user rules ([`hs_library`](../reference/rules.md#hs_library), [`hs_binary`](../reference/rules.md#hs_binary), and [`hs_test`](../reference/rules.md#hs_test)) pass `-XGHC2021` to GHC. Third-party Cabal packages built with [`hs_cabal_library`](../reference/rules.md#hs_cabal_library) default to `"Haskell98"` when an older `.cabal` manifest omits `default-language:`, matching the Cabal specification.

Even on GHC `9.10.3` and `9.12.4`, user targets default to `"GHC2021"` for two reasons:

- **Upstream GHC compatibility:** GHC `9.10` and `9.12` both use `GHC2021` as their built-in default when you omit an explicit edition flag.
- **`MonoLocalBinds` breakage in `GHC2024`:** `GHC2024` adds useful extensions such as `LambdaCase`, `DerivingStrategies`, `GADTs`, and `DataKinds`, but it also enables `MonoLocalBinds`. With `MonoLocalBinds` active, GHC stops automatically inferring polymorphic types for local `let` and `where` helpers when certain type features are in scope, which can break existing `Haskell2010` and `GHC2021` modules until you add explicit type signatures.

Defaulting to `"GHC2021"` matches upstream GHC while enabling widely used features such as `ImportQualifiedPost`, `BangPatterns`, `DeriveGeneric`, `NamedFieldPuns`, `ScopedTypeVariables`, and `TypeApplications`.

### Opt in to `GHC2024` or earlier editions

Both GHC `9.10.3` and `9.12.4` support `GHC2024`. Set `default_language = "GHC2024"` on any target (or wrap `hs_library` in a project-local `.bzl` macro for new repositories):

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
load("@rules_haskell//haskell:defs.bzl", "hs_library")

hs_library(
    name = "status_lib",
    srcs = ["src/Status.hs"],
    default_language = "GHC2024",
    ghc_opts = ["-Wall"],
    hs_source_dirs = ["src"],
    deps = ["@hs_boot//:base"],
)
```

If you'd rather stay on `"GHC2021"` and add specific target-wide extensions, list them in `default_extensions` (from `tests/rules/lang/BUILD.bazel`):

```starlark
load("@rules_haskell//haskell:defs.bzl", "hs_library")

hs_library(
    name = "domain_lib",
    srcs = [
        "src/Org/RulesHaskell/Eval/Engine.hs",
        "src/Org/RulesHaskell/Internal/Secret.hs",
        "src/Org/RulesHaskell/Types.hs",
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
    hidden_modules = ["Org.RulesHaskell.Internal.Secret"],
    hs_source_dirs = ["src"],
    deps = [
        "@hs_boot//:base",
        "@hs_boot//:text",
    ],
)
```

## Interactive GHCi REPL and interpreter modes {#interactive-ghci-repl}

Alongside batch compilation, you can load targets into an interactive GHCi session, evaluate one-shot expressions, or run standalone Haskell scripts.

### Start a project REPL with `hs_repl`

Declare an [`hs_repl`](../reference/rules.md#hs_repl) target in [`BUILD.bazel`](https://bazel.build/concepts/build-files) pointing at one or more `hs_library`, `hs_binary`, or `hs_test` targets:

```starlark
load("@rules_haskell//haskell:defs.bzl", "hs_library", "hs_repl")

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

Launch the interactive `ghci` session with [`bazel run`](https://bazel.build/docs/user-manual#running-executables):

```bash
bazel run //:math_repl
```

Here's what works inside the session:

- **Bytecode scope (`*Module`):** By default (`interpret_deps = True`), GHCi loads workspace `deps` from source into bytecode, placing every module in scope—including `hidden_modules` and unexported top-level helpers. External `@hs_boot` and `@hackage` packages, along with any targets listed in `compiled_deps`, load from precompiled `.so` shared libraries.
- **Live `:reload` without rerunning Bazel:** When you launch the REPL with `bazel run`, workspace source files and `-i` search paths resolve against `$BUILD_WORKSPACE_DIRECTORY`. Edit any loaded `.hs` file in your editor and run `:reload` (`:r`) at the `ghci>` prompt to recompile in place.
- **Line editing, completion, and debugging:** GHC's `haskeline` prompt runs against `rules_haskell`'s C11 `libtinfo.so.6` implementation. Arrow-key history, Tab identifier completion, `Ctrl-C` evaluation interruption, and the `:break`, `:step`, and `:continue` bytecode debugger all work at the prompt.
- **C/C++ FFI, Template Haskell, and `data` files:** Native C and C++ archives from `c_sources` and `cc_deps` link automatically into a shared helper library (`HsLinkReplCbits`), and `ghc_cc_wrapper` compiles `CApiFFI` stubs on demand. Cross-library Template Haskell splices run in-process (or out-of-process with `-- -fexternal-interpreter`), and `RUNFILES_DIR` stays exported so your code can read `data` files.

### Evaluate one-shot expressions and run standalone scripts

To evaluate an expression in the loaded module context and exit, pass `-e '<expr>'` after `--`:

```bash
bazel run //:math_repl -- -e 'computeValue 5'
```

You don't need a `BUILD.bazel` target to open a plain `ghci` prompt or run a single `.hs` script. Use `@rules_haskell//tools/ghci` directly:

```bash
# Standalone ghci prompt with GHC's boot packages visible:
bazel run @rules_haskell//tools/ghci

# Evaluate an expression directly:
bazel run @rules_haskell//tools/ghci -- -e '2 ^ 64 :: Integer'

# Execute a standalone Haskell script via staged runghc:
bazel run @rules_haskell//tools/ghci:runghc -- ./script.hs arg1 arg2
```

## Module encapsulation and mutual recursion

You can restrict which modules downstream targets can import and break circular module imports without splitting targets.

### Keep internal modules private with `hidden_modules`

By default, every module in an `hs_library` target is public: `rules_haskell` inspects the compiled `.hi` interface files and registers all modules under `exposed-modules:` in the package database. To keep internal helper modules private—the equivalent of Cabal's `other-modules:` field—list their dotted Haskell module names in `hidden_modules`:

```starlark
load("@rules_haskell//haskell:defs.bzl", "hs_library")

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

Modules inside `:math_lib` (such as `Math.Core`) can still `import Math.Internal`. Any downstream target depending on `:math_lib` that tries to import `Math.Internal` fails at compile time with `Could not load module 'Math.Internal': it is a hidden module`.

### Break circular imports with `.hs-boot` files

Because GHC typechecks modules in dependency order, two `.hs` files can't normally import each other in a cycle (`BootA` importing `BootB` while `BootB` imports `BootA`). When two modules genuinely need each other's types or functions, add a **`.hs-boot` forward-declaration file**—similar to a `.h` header in C—to break the cycle:

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

Include the `.hs-boot` (or `.lhs-boot`) file alongside the `.hs` files in `srcs` (from `tests/basic/BUILD.bazel`):

```starlark
load("@rules_haskell//haskell:defs.bzl", "hs_library")

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

During compilation, `rules_haskell` stages `.hs-boot` files in the compile [sandbox](https://bazel.build/docs/sandboxing) and passes only `.hs` and `.lhs` entry points to `ghc --make -c`. GHC then resolves `{-# SOURCE #-}` imports automatically through its `-i` source search paths.

## GHC runtime system (RTS) and concurrency

Every compiled Haskell binary links GHC's **runtime system (RTS)**—a C library bundled with GHC that provides garbage collection, lightweight green threads (`forkIO`, similar to Go goroutines), software transactional memory (`STM`), and non-blocking network and timer I/O.

### Threaded vs. single-threaded RTS

GHC ships two RTS variants. Choose between them with the `threaded` attribute on `hs_binary` and `hs_test` (`threaded = True` by default):

| Setting | `rtsSupportsBoundThreads` | How threads and C calls run | When to use |
|---|---|---|---|
| `threaded = True` (default) | `True` | Schedules Haskell green threads across multiple OS worker threads (`-N`), supports OS-bound threads (`forkOS`), and runs `safe` blocking C FFI calls on dedicated OS threads without pausing other green threads | Servers, concurrent CLI tools (`async`, `http-client`), C FFI programs, and parallel test suites |
| `threaded = False` | `False` | Runs all Haskell green threads (`forkIO`, `MVar`, `STM`) cooperatively on a single OS thread; calling `forkOS` raises a runtime error, and a blocking C call pauses all green threads until it returns | Single-threaded benchmarks or tools that never need multi-core parallelism |

```starlark
load("@rules_haskell//haskell:defs.bzl", "hs_binary", "hs_test")

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

> **Tip:** Even with `threaded = True`, GHC binaries use only one CPU core at startup unless told otherwise. Pass `"-rtsopts"` and `"-with-rtsopts=-N"` in `ghc_opts` on `hs_binary` or `hs_test` (optionally adding `-A32m` for a 32 MiB garbage-collector allocation area) so your executable uses all available cores automatically without requiring callers to pass `+RTS -N -RTS`.

## Bazel `data` runfiles

When a binary or test needs non-code files at runtime—such as JSON schemas, SQL migrations, test fixtures, or helper executables—Bazel stages them inside a **runfiles** tree (`<binary>.runfiles/_main/<package>/<file>`) instead of assuming your program runs from the Git repository root.

Every Haskell rule (`hs_library`, `hs_binary`, `hs_test`, and `hs_cabal_library`) accepts a `data` attribute and forwards runfiles transitively across `deps`, `cc_deps` (`extra_cc_deps`), and `data`:

- **Library assets:** Files listed in `data` on an `hs_library` target are automatically available at runtime to every `hs_binary` and `hs_test` that transitively depends on that library.
- **Helper executables:** An `hs_binary` listed in `data = [":helper_bin"]` on an `hs_test` is staged into the test's runfiles along with all of `:helper_bin`'s own transitive `data` files.

### Locate runfiles in Haskell

Make sure [`.bazelrc`](https://bazel.build/run/bazelrc) includes [`common --enable_runfiles`](https://bazel.build/reference/command-line-reference#param-no-enable-runfiles). Under [Bzlmod](https://bazel.build/external/overview), files from your root workspace sit under `<runfiles_root>/_main/<package>/<file>` (or [`$TEST_WORKSPACE`](https://bazel.build/reference/test-encyclopedia#initial-conditions), which defaults to `_main`).

Here's a small runfile resolver that uses only GHC boot libraries (from `tests/rules/runfiles/DataLib.hs`):

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

Declare the library and test targets in `BUILD.bazel`:

```starlark
load("@rules_haskell//haskell:defs.bzl", "hs_library", "hs_test")

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

## Template Haskell (`TemplateHaskell` and `TemplateHaskellQuotes`)

**Template Haskell (TH)** is GHC's built-in compile-time code generation system, comparable to procedural macros in Rust. While compiling a module, GHC evaluates Haskell expressions wrapped in `$( ... )` (called **splices**) and inserts the generated declarations, types, or expressions directly into the module. Common Hackage libraries use TH to generate JSON encoders (`aeson`) or embed static files into binaries at compile time (`file-embed`).

You don't need extra rule attributes to use Template Haskell. `rules_haskell` supports:

- **`TemplateHaskellQuotes`:** Constructing syntax trees (`[| ... |]`, `''MyType`, `'myFunc`) using `@hs_boot//:template-haskell` without running splices in the current module.
- **Boot-package and same-library splices:** Covered by `//tests/rules/th:th_test`.
- **Cross-library and Hackage splices:** Covered by `//tests/rules/th:cross_lib_th_test` and `//tests/rules/th:cross_lib_th_elf_test`, including splices imported from separate `hs_library` or `hs_cabal_library` targets (`aeson`, `file-embed`, `skylighting`, `pandoc`), multi-hop library chains, C FFI and `CApiFFI` calls inside splices, and compile-time `runIO` file reads.

### Build syntax trees without running splices (`TemplateHaskellQuotes`)

When a helper module only constructs quoted syntax (`[| ... |]`, `''MyType`, `'myFunc`) for downstream modules to splice in, enable `{-# LANGUAGE TemplateHaskellQuotes #-}` instead of full `TemplateHaskell`. That way GHC doesn't start its compile-time interpreter for that module:

```haskell
{-# LANGUAGE TemplateHaskellQuotes #-}

module ThHelper (mkAnswerExp, maybeTypeName) where

import Language.Haskell.TH (Exp, Name, Q)

maybeTypeName :: Name
maybeTypeName = ''Maybe

mkAnswerExp :: Int -> Q Exp
mkAnswerExp n = [| n * 2 |]
```

### Run same-library and cross-library splices (`TemplateHaskell`)

To evaluate `$( ... )` splices defined in the same library, upstream `hs_library` targets, or Hackage packages (such as `@hackage//:aeson` or `@hackage//:file-embed`), enable `{-# LANGUAGE TemplateHaskell #-}`:

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
load("@rules_haskell//haskell:defs.bzl", "hs_library", "hs_test")

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

### How cross-library Template Haskell keeps binaries statically linked

Official GHC binary distributions are dynamically linked, so GHC's compile-time splice runner (`ghc-iserv`) must load upstream libraries as shared `.so` files while compiling a `TemplateHaskell` module. To support cross-library TH without making your final executables dynamically linked, `rules_haskell` compiles libraries with `-dynamic-too`:

1. Static `.o` objects are archived into `${pkgroot}/libHS<unit_id>.a` (`library-dirs` and `library-dirs-static`), where `${pkgroot}` is GHC's relocatable variable resolving to the directory holding the package registration file.
2. Dynamic `.dyn_o` objects—along with any `c_sources` and `cc_deps` C archives, linked with `-Wl,-Bsymbolic`—are linked into `<name>.pkgdb/dyn/libHS<unit_id>-ghc<ver>.so`, and `dynamic-library-dirs: ${pkgroot}/<pkgdb_base>/dyn` is recorded in `<unit_id>.conf`.
3. During compilation, GHC's TH loader reads `.so` files from `<name>.pkgdb/dyn` across multi-hop Haskell and C dependencies, while `hs_binary` and `hs_test` link only static `libHS*.a` and `libgmp.a` archives. Your final binaries carry no runtime `libHS*.so` or `libgmp.so` dependencies.

> **Tip:** Files listed in `data` on `hs_library`, `hs_cabal_library`, `hs_binary`, and `hs_test` are staged into the compilation sandbox as well as runtime runfiles. Compile-time Template Haskell splices—such as `file-embed`'s `$(embedFile "...")` and `$(embedDir "...")` (used by `--flag pandoc:embed_data_files=true`) or `runIO (readFile ...)`—can read declared `data` files directly inside `linux-sandbox`.

## Generate Haddock API documentation {#haddock}

**Haddock** is Haskell's standard API documentation generator, analogous to `rustdoc` in Rust or `godoc` in Go, and ships inside every GHC distribution. You can generate self-contained HTML API docs with [`hs_haddock`](../reference/rules.md#hs_haddock), which runs GHC's staged `bin/haddock-ghc-<ver>` binary inside Bazel's sandbox with no host tools or network access.

### Write Haddock comments and declare an `hs_haddock` target

Document modules, types, and functions with `-- |` comments (before an item) and `-- ^` comments (after an item or constructor field):

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
greetingFor who = "Hello, " <> T.strip who <> ", from rules_haskell."
```

Declare an `hs_haddock` target in `BUILD.bazel` listing one or more `hs_library` or `hs_cabal_library` targets in `deps`:

```starlark
load("@rules_haskell//haskell:defs.bzl", "hs_haddock", "hs_library")

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

Run [`bazel build`](https://bazel.build/run/build) to generate the documentation directory:

```bash
bazel build //:greet_haddock
```

By default (`hyperlinked_source = True`, `quickjump = True`), [`bazel-bin/greet_haddock/`](https://bazel.build/remote/output-directories) contains a self-contained HTML directory:

- **API pages:** `index.html` and per-module `<Module>.html` pages (`hidden_modules` are automatically hidden with `--hide=<mod>`).
- **Hyperlinked source:** `src/<Module>.html` syntax-highlighted, clickable source pages.
- **QuickJump search:** `doc-index.json` powering Haddock's client-side search dialog.
- **Boot-library cross-references:** Links to Hackage documentation for GHC boot types (such as `Text`, `IO`, and `Map`) using `HsToolchainInfo.boot_haddocks`.

### Link across targets and mount generated docs

When you generate separate Haddock bundles for layered libraries, pass upstream `hs_haddock` targets in `haddock_deps`. Haddock reads their `.haddock` interface files (`HsHaddockInfo`) and emits relative links between bundles.

Because an `hs_haddock` target outputs a single Bazel directory artifact, downstream static-site or packaging rules can consume [`$(rootpath :greet_haddock)`](https://bazel.build/reference/be/make-variables#predefined_label_variables) as one path—for example, `//docs:site` mounts `//tools/lock:lock_haddock` at `/haddock/lock/`.
