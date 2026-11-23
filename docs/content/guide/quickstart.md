---
title: "Quickstart"
description: "Set up a Bazel 9 Haskell workspace with Bzlmod and build a library, executable, and test target."
section: guide
nav_title: "Quickstart"
order: 10
---

This guide walks through creating a standalone Bazel 9 Haskell project using `rules_hs` on Linux, without installing a host Haskell compiler or C development packages first.

> **Tip — New to Haskell or Bazel rulesets?** Each step below explains the Haskell and Bazel files as they appear. For broader background at any point, see [Haskell & GHC Primer](../internals/haskell-and-ghc-primer.md) and [Bazel Ruleset Primer](../internals/bazel-rules-primer.md).

## Prerequisites

The only host tool you need is **[Bazelisk](https://github.com/bazelbuild/bazelisk)**, a small launcher that downloads and runs the exact Bazel version listed in `.bazelversion` (`>= 9.0.0`).

On Linux (`x86_64` and `arm64`, with `glibc >= 2.28`), you do **not** need host `ghc`, `cabal`, `stack`, `nix`, `python3`, `gcc`, `clang`, `libgmp-dev`, `libtinfo-dev`, or `zlib1g-dev`. (macOS and Windows execution are planned; see [What Is Supported, Planned, and Out of Scope](../index.md#project-scope).)

## Project Layout

We will create a small workspace containing a library (`greet`), a command-line executable (`hello`), and a unit test (`greet_test`):

```text
my-hs-app/
├── .bazelrc
├── .bazelversion
├── MODULE.bazel
├── BUILD.bazel
├── src/
│   ├── Greet.hs
│   └── Main.hs
└── test/
    └── GreetTest.hs
```

- **`.bazelversion`**: Tells Bazelisk which Bazel release to download and run.
- **`.bazelrc`**: Sets default command-line flags for `bazel build`, `bazel test`, and `bazel run`.
- **`MODULE.bazel`**: Declares external Bazel module dependencies and toolchains (C/C++ and GHC).
- **`BUILD.bazel`**: Declares the targets (`hs_library`, `hs_binary`, `hs_test`) inside your repository.

## Step 1: Pin Bazel 9 and Configure `.bazelrc`

Create `.bazelversion` to pin Bazel 9:

```text
9.3.3
```

Create `.bazelrc` with environment isolation and runfiles flags:

```ini
common --enable_platform_specific_config
common --enable_runfiles
common --incompatible_strict_action_env
common --test_output=errors

# Shared Zig compiler cache mount when using hermetic_cc_toolchain
build:linux --repo_env=HERMETIC_CC_TOOLCHAIN_CACHE_PREFIX=/tmp/zig-cc-cache
build:linux --sandbox_add_mount_pair=/tmp
```

### Why Each `.bazelrc` Flag Is Here

- **`--enable_platform_specific_config`**: Automatically enables `build:linux` lines when running on Linux.
- **`--incompatible_strict_action_env`**: Prevents your shell's `PATH`, `LD_LIBRARY_PATH`, or `GHC_PACKAGE_PATH` environment variables from leaking into Bazel build sandboxes, so builds behave identically across developer machines and CI.
- **`--enable_runfiles`**: Tells Bazel to create the `<binary>.runfiles` directory tree on disk so [`hs_binary`](../reference/rules.md#hs_binary) and [`hs_test`](../reference/rules.md#hs_test) targets can open runtime `data` files via `RUNFILES_DIR` and `TEST_SRCDIR`.
- **`HERMETIC_CC_TOOLCHAIN_CACHE_PREFIX` and `--sandbox_add_mount_pair=/tmp`**: Only used when pairing `rules_hs` with `hermetic_cc_toolchain` (`zig cc`). Zig compiles its C startup files on first use and caches them in this directory; mounting `/tmp` lets sandboxed actions share that cache instead of rebuilding C startup objects on every action. See [C FFI & Toolchains](c-interop-and-toolchains.md) if you use `toolchains_llvm` or a system C compiler instead.

## Step 2: Configure `MODULE.bazel`

Create `MODULE.bazel` to load `rules_hs`, register a C/C++ toolchain, and download GHC `9.10.3` through the [`hs`](../reference/extensions-and-providers.md#hs) module extension:

```starlark
module(
    name = "my_hs_project",
    version = "0.1.0",
    bazel_compatibility = [">=9.0.0"],
)

bazel_dep(name = "rules_hs", version = "0.1.0")
# Until rules_hs is published to the Bazel Central Registry (BCR),
# point git_override (or local_path_override) at your rules_hs checkout:
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

# GHC toolchain + automatic @hs_boot targets for all GHC boot packages.
hs = use_extension("@rules_hs//hs:extensions.bzl", "hs")
hs.toolchain(ghc_version = "9.10.3")
use_repo(hs, "hs_boot", "hs_toolchains")

register_toolchains("@hs_toolchains//:all")
```

> **Important — Register `gnu.2.32` before the `@zig_sdk` wildcard:** When using `hermetic_cc_toolchain`, list `@zig_sdk//toolchain:linux_amd64_gnu.2.32` and `@zig_sdk//toolchain:linux_arm64_gnu.2.32` **before** `@zig_sdk//toolchain/...`. Without those two lines first, Bazel's wildcard registration picks `gnu.2.17` alphabetically, which lacks `glibc` 2.28 and 2.32 symbols needed by official GHC Linux archives and BCR `gmp`. See [C FFI & Toolchains](c-interop-and-toolchains.md) for details.

### Why `MODULE.bazel` Registers Both a C Toolchain and GHC

If this is your first Haskell + Bazel workspace, it helps to see why two toolchains appear above:

- **Why GHC needs a C/C++ toolchain (`@zig_sdk`)**: Unlike Go or Java, GHC uses a C assembler and system linker to produce native executables, linking your Haskell code against GHC's C Runtime System (`libHSrts.a` — the garbage collector and thread scheduler) and `libgmp.a` (arbitrary-precision integer arithmetic). `hermetic_cc_toolchain` downloads a self-contained `zig cc` C compiler and linker so you do not need `gcc` or `clang` installed on your machine (see [Dependency Decisions](../internals/dependencies.md#module-bazel-anatomy)).
- **What [`hs.toolchain`](../reference/extensions-and-providers.md#hs-toolchain) creates**: Calling `use_repo(hs, "hs_boot", "hs_toolchains")` exposes two Bazel repositories:
  1. **`@hs_toolchains`**: Downloads and registers GHC (`9.10.3` by default, or `9.12.4`) for `linux_x86_64` and `linux_arm64`.
  2. **`@hs_boot`**: Exposes all **41 built-in "boot" libraries** shipped inside GHC itself as Bazel targets, with no lockfile required. In this tutorial we use two of them:
     - **`@hs_boot//:base`**: Haskell's standard library (`Prelude`, `IO`, command-line `getArgs`, `exitFailure`).
     - **`@hs_boot//:text`**: Packed UTF-8 text (`Data.Text`, similar to Rust's `String`/`&str` or Go's `string`). In day-to-day Haskell code, `Text` is preferred over `base`'s older `String` type, which is a linked list of characters (`[Char]`).

## Step 3: Write Haskell Sources

Create `src/Greet.hs` ([`hs_library`](../reference/rules.md#hs_library), [`hs_binary`](../reference/rules.md#hs_binary), and [`hs_test`](../reference/rules.md#hs_test) compile with `default_language = "GHC2021"` by default):

```haskell
{-# LANGUAGE OverloadedStrings #-}

module Greet (greetingFor) where

import Data.Text (Text)
import Data.Text qualified as T

greetingFor :: Text -> Text
greetingFor who = "Hello, " <> T.strip who <> ", from rules_hs."
```

Create `src/Main.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Greet (greetingFor)
import System.Environment (getArgs)

main :: IO ()
main = do
  args <- getArgs
  let target = case args of
        (name : _) -> T.pack name
        [] -> "Bazel 9"
  TIO.putStrLn (greetingFor target)
```

Create `test/GreetTest.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Monad (unless)
import Greet (greetingFor)
import System.Exit (exitFailure)

main :: IO ()
main = do
  let actual = greetingFor "  Haskell  "
      expected = "Hello, Haskell, from rules_hs."
  unless (actual == expected) $ do
    putStrLn ("Expected: " <> show expected <> ", got: " <> show actual)
    exitFailure
```

### Understanding These Three `.hs` Files

- **`default_language = "GHC2021"`**: `rules_hs` compiles user targets with GHC's `GHC2021` language edition by default (matching GHC `9.10` and `9.12`'s own default), which enables features such as post-qualified imports (`import Data.Text qualified as T`). You can also set `default_language = "GHC2024"` or `"Haskell2010"` per target; see [Language, RTS, Runfiles & Template Haskell](language-rts-runfiles-th.md).
- **`{-# LANGUAGE OverloadedStrings #-}`**: A file-level compiler pragma that allows `"..."` string literals to construct UTF-8 `Text` values directly instead of only `[Char]`.
- **`module Greet (greetingFor) where`**: Names the module `Greet` and exports `greetingFor :: Text -> Text` (`<>` concatenates two `Text` values, and `T.strip` trims leading and trailing whitespace).
- **`module Main (main) where` and `main :: IO ()`**: Every Haskell executable (`hs_binary` and `hs_test`) starts at `Main.main` of type `IO ()` — an I/O action sequenced step-by-step using `do` notation (`args <- getArgs`). In `GreetTest.hs`, returning normally exits with status `0` (test pass), while `exitFailure` exits with a non-zero status (test failure).

## Step 4: Declare Targets in `BUILD.bazel`

Load [`hs_library`](../reference/rules.md#hs_library), [`hs_binary`](../reference/rules.md#hs_binary), and [`hs_test`](../reference/rules.md#hs_test) from `@rules_hs//hs:defs.bzl`:

```starlark
load("@rules_hs//hs:defs.bzl", "hs_binary", "hs_library", "hs_test")

hs_library(
    name = "greet",
    srcs = ["src/Greet.hs"],
    ghc_opts = [
        "-Wall",
        "-Wcompat",
    ],
    hs_source_dirs = ["src"],
    deps = [
        "@hs_boot//:base",
        "@hs_boot//:text",
    ],
)

hs_binary(
    name = "hello",
    srcs = ["src/Main.hs"],
    ghc_opts = [
        "-Wall",
        "-Wcompat",
    ],
    hs_source_dirs = ["src"],
    deps = [
        ":greet",
        "@hs_boot//:base",
        "@hs_boot//:text",
    ],
)

hs_test(
    name = "greet_test",
    size = "small",
    srcs = ["test/GreetTest.hs"],
    ghc_opts = [
        "-Wall",
        "-Wcompat",
    ],
    hs_source_dirs = ["test"],
    deps = [
        ":greet",
        "@hs_boot//:base",
    ],
)
```

### What Each `BUILD.bazel` Attribute Does

- **`hs_source_dirs = ["src"]` (or `["test"]`)**: Sets the root folder from which GHC resolves dotted module names — mapping `module Greet` to `src/Greet.hs` (and `module Foo.Bar` to `src/Foo/Bar.hs`).
- **`ghc_opts = ["-Wall", "-Wcompat"]`**: Enables GHC's standard warning set (`-Wall`) plus forward-compatibility warnings (`-Wcompat`).
- **`hs_library` vs. `hs_binary` vs. `hs_test`**: [`hs_library`](../reference/rules.md#hs_library) compiles reusable `.a` static archives and `.hi` compiler interface files; [`hs_binary`](../reference/rules.md#hs_binary) compiles `Main.main` and links all transitive Haskell and C archives into a native executable; [`hs_test`](../reference/rules.md#hs_test) builds a test executable that `bazel test` runs inside an isolated sandbox.

> **Tip — Direct-dependency visibility:** `rules_hs` passes `-hide-all-packages` to GHC and exposes **only** direct `deps` via `-package-id` (using separate direct [`HsPackageInfo`](../reference/extensions-and-providers.md#hspackageinfo) and transitive [`HsLinkInfo`](../reference/extensions-and-providers.md#hslinkinfo) providers). Because `:hello` imports `Data.Text` in `src/Main.hs`, it lists `@hs_boot//:text` in its own `deps` even though `:greet` also depends on `@hs_boot//:text`. By contrast, `:greet_test` calls `greetingFor` without importing `Data.Text` directly, so it only needs `:greet` and `@hs_boot//:base`.

## Step 5: Build, Test, and Inspect Runtime Dependencies

Run the test suite and execute your binary:

```bash
bazel test //...
bazel run //:hello -- "World"
```

Output:

```text
Hello, World, from rules_hs.
```

> **Tip — Interactive `ghci` REPL:** Add an [`hs_repl`](../reference/rules.md#hs_repl) target (`hs_repl(name = "greet_repl", deps = [":greet"])`) and run `bazel run //:greet_repl` to open an interactive `ghci` session with `Greet` loaded in bytecode (supporting `:reload` on workspace edits, `:type`, and `:break`), or run `bazel run @rules_hs//tools/ghci` for a standalone prompt. See [Language, RTS, Runfiles & Template Haskell](language-rts-runfiles-th.md#interactive-ghci-repl) for details.

On Linux, every ELF executable records the shared `.so` libraries it needs at startup in `NEEDED` metadata entries. You can inspect `bazel-bin/hello` with `readelf -d` and run it with an empty environment (`env -i PATH=/nonexistent`) to confirm it statically links `libgmp.a` and depends only on standard `glibc` libraries:

```bash
readelf -d bazel-bin/hello | grep NEEDED
env -i PATH=/nonexistent ./bazel-bin/hello "Clean Env"
```

Expected output:

```text
 0x0000000000000001 (NEEDED)             Shared library: [libc.so.6]
 0x0000000000000001 (NEEDED)             Shared library: [libdl.so.2]
 0x0000000000000001 (NEEDED)             Shared library: [libm.so.6]
 0x0000000000000001 (NEEDED)             Shared library: [libpthread.so.0]
Hello, Clean Env, from rules_hs.
```

## Switching to GHC 9.12.4

Changing the GHC version across your workspace is a one-line edit in `MODULE.bazel`:

```starlark
hs = use_extension("@rules_hs//hs:extensions.bzl", "hs")
hs.toolchain(ghc_version = "9.12.4")
use_repo(hs, "hs_boot", "hs_toolchains")
```

Root module [`hs.toolchain`](../reference/extensions-and-providers.md#hs-toolchain) declarations override `rules_hs`'s default `9.10.3` toolchain.

## Next Steps

- **Add Hackage dependencies (`aeson`, `http-client`, `xml-conduit`, `zlib`, etc.)**: Continue to [Hackage & Lockfiles](hackage.md).
- **Call C libraries or configure `toolchains_llvm`**: Read [C FFI & Toolchains](c-interop-and-toolchains.md).
- **Configure `GHC2021` vs. `GHC2024`, RTS concurrency, runfiles, Template Haskell, and Haddock API docs (`hs_haddock`)**: Read [Language, RTS, Runfiles & Template Haskell](language-rts-runfiles-th.md).
- **Explore a complete 69-package application**: Walk through [Showcase: `examples/size`](showcase-size.md).
