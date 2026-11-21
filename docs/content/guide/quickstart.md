---
title: "Quickstart"
description: "Set up a Bzlmod Bazel 9 Haskell workspace and build your first hermetic library, binary, and test suite."
section: guide
nav_title: "Quickstart"
order: 10
---

This guide walks you through creating a standalone Bazel 9 Haskell project from scratch using `rules_hs` — with zero host Haskell or C toolchain packages installed.

> **Tip — Brand New to Haskell or Bazel Rulesets?** Every step below explains the Haskell and Bazel concepts inline as they appear. For deeper background at any time, see [Haskell & GHC Primer](../internals/haskell-and-ghc-primer.md) and [Bazel Ruleset Primer](../internals/bazel-rules-primer.md).

## Prerequisites

The only host tool required is **[Bazelisk](https://github.com/bazelbuild/bazelisk)** (which automatically downloads and runs the pinned Bazel `>= 9.0.0` binary declared in `.bazelversion`).

On Linux (`x86_64` and `arm64`, glibc `>= 2.28`), you do **not** need host `ghc`, `cabal`, `stack`, `nix`, `python3`, `gcc`, `clang`, `libgmp-dev`, `libtinfo-dev`, or `zlib1g-dev`.

## Project Layout

We will create a small workspace with a library (`greet`), a CLI executable (`hello`), and a unit test (`greet_test`):

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

## Step 1: Pin Bazel 9 and Recommended `.bazelrc` Flags

Create `.bazelversion` to pin Bazel 9:

```text
9.3.3
```

Create `.bazelrc` with strict action environment isolation and runfiles support:

```ini
common --enable_platform_specific_config
common --enable_runfiles
common --incompatible_strict_action_env
common --test_output=errors

# Shared Zig compiler cache mount when using hermetic_cc_toolchain
build:linux --repo_env=HERMETIC_CC_TOOLCHAIN_CACHE_PREFIX=/tmp/zig-cc-cache
build:linux --sandbox_add_mount_pair=/tmp
```

> **Note — Why `--enable_runfiles` and `--incompatible_strict_action_env`?**
> - `--incompatible_strict_action_env` prevents host `PATH`, `LD_LIBRARY_PATH`, or `GHC_PACKAGE_PATH` variables from leaking into build actions, guaranteeing reproducible builds across developer machines and CI.
> - `--enable_runfiles` ensures Bazel materializes the `<bin>.runfiles` directory tree so [`hs_binary`](../reference/rules.md#hs_binary) and [`hs_test`](../reference/rules.md#hs_test) targets can read `data` files directly via `RUNFILES_DIR` and `TEST_SRCDIR`.
> - The `/tmp/zig-cc-cache` mount is only needed when using `hermetic_cc_toolchain` (`zig cc`) so Zig does not recompile its C runtime startup objects in every sandboxed action. See [C FFI & Toolchains](c-interop-and-toolchains.md) for `toolchains_llvm` or system C toolchains.

## Step 2: Configure `MODULE.bazel`

Create `MODULE.bazel` to declare `rules_hs`, register a hermetic C toolchain, and provision GHC `9.10.3` via the [`hs`](../reference/extensions-and-providers.md#hs) module extension:

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

> **Important — Register `gnu.2.32` before the `@zig_sdk` wildcard:** When pairing `rules_hs` with `hermetic_cc_toolchain`, always list `@zig_sdk//toolchain:linux_amd64_gnu.2.32` and `@zig_sdk//toolchain:linux_arm64_gnu.2.32` **before** `@zig_sdk//toolchain/...`. Otherwise Bazel's wildcard registration picks `gnu.2.17` alphabetically, which lacks glibc 2.28/2.32 symbols required by GHC `deb10` bindists and BCR `gmp`. See [C FFI & Toolchains](c-interop-and-toolchains.md) for details.

### What `MODULE.bazel` and `hs.toolchain` Set Up

If this is your first Haskell + Bazel workspace, notice why `MODULE.bazel` configures two toolchains:

- **Why a C toolchain (`hermetic_cc_toolchain` / `@zig_sdk`) sits alongside GHC**: Unlike Go or Java, GHC compiles Haskell via a C assembler and system linker, linking your code against GHC's C Runtime System (`libHSrts.a` — garbage collector and green-thread scheduler) and static `libgmp.a` (arbitrary-precision math). `hermetic_cc_toolchain` downloads a self-contained `zig cc` compiler so you need zero host `gcc` or `clang` installed (see [Dependency Decisions](../internals/dependencies.md#module-bazel-anatomy)).
- **What [`hs.toolchain`](../reference/extensions-and-providers.md#hs-toolchain) creates**: Calling `use_repo(hs, "hs_boot", "hs_toolchains")` exposes two repositories:
  1. **`@hs_toolchains`**: Registers hermetic GHC (`9.10.3` by default, or `9.12.4`) for `linux_x86_64` and `linux_arm64`.
  2. **`@hs_boot`**: Exposes all **41 built-in "boot" libraries** bundled inside GHC itself as ready-to-use Bazel targets — with zero lockfile needed! In this tutorial we use two of them:
     - **`@hs_boot//:base`**: Haskell's core standard library (`Prelude`, `IO`, CLI `getArgs`, `exitFailure`).
     - **`@hs_boot//:text`**: Contiguous, packed UTF-8 text (`Data.Text`, analogous to Rust's `String`/`&str` or Go's `string`). In real Haskell code, `Text` is preferred over `base`'s legacy `String` type (which is a linked list of characters `[Char]`).

## Step 3: Write Haskell Sources

Create `src/Greet.hs` (note that [`hs_library`](../reference/rules.md#hs_library), [`hs_binary`](../reference/rules.md#hs_binary), and [`hs_test`](../reference/rules.md#hs_test) all default to `default_language = "GHC2021"`):

```haskell
{-# LANGUAGE OverloadedStrings #-}

module Greet (greetingFor) where

import Data.Text (Text)
import Data.Text qualified as T

greetingFor :: Text -> Text
greetingFor who = "Hello, " <> T.strip who <> ", from hermetic rules_hs!"
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
      expected = "Hello, Haskell, from hermetic rules_hs!"
  unless (actual == expected) $ do
    putStrLn ("Expected: " <> show expected <> ", got: " <> show actual)
    exitFailure
```

### Understanding These Three `.hs` Files (For First-Time Haskell Readers)

- **`default_language = "GHC2021"`**: All `rules_hs` rules compile with GHC's modern `GHC2021` language edition by default (rather than legacy `Haskell2010`), enabling ergonomic features like post-qualified imports (`import Data.Text qualified as T`) automatically.
- **`{-# LANGUAGE OverloadedStrings #-}`**: A per-file compiler pragma allowing `"..."` string literals to construct packed UTF-8 `Text` values directly instead of only `[Char]`.
- **`module Greet (greetingFor) where`**: Names the module `Greet` and exports `greetingFor :: Text -> Text` publicly (`<>` concatenates two `Text` values, and `T.strip` trims whitespace).
- **`module Main (main) where` and `main :: IO ()`**: Every Haskell executable (`hs_binary` and `hs_test`) starts at `Main.main` of type `IO ()` — an effectful program sequenced step-by-step using `do`-notation (`args <- getArgs`). In `GreetTest.hs`, returning normally exits with code `0` (test pass), while `exitFailure` exits non-zero (test failure).

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

- **`hs_source_dirs = ["src"]` (or `["test"]`)**: Sets the root directory from which GHC resolves hierarchical module names — mapping `module Greet` -> `src/Greet.hs` (and `module Foo.Bar` -> `src/Foo/Bar.hs`).
- **`ghc_opts = ["-Wall", "-Wcompat"]`**: Enables GHC's standard warning suite (`-Wall`) plus forward-compatibility warnings (`-Wcompat`).
- **`hs_library` vs. `hs_binary` vs. `hs_test`**: [`hs_library`](../reference/rules.md#hs_library) compiles reusable `.a` archives and `.hi` compiler interface files; [`hs_binary`](../reference/rules.md#hs_binary) compiles `Main.main` and links all transitive Haskell and C archives into a standalone native binary; [`hs_test`](../reference/rules.md#hs_test) builds a test binary that `bazel test` executes inside an isolated sandbox.

> **Tip — Strict Direct-Dependency Visibility:** `rules_hs` compiles every target with `-hide-all-packages` and exposes **only** direct `deps` via `-package-id` (modeled on Buck2 Haskell's [`HsPackageInfo`](../reference/extensions-and-providers.md#hspackageinfo) vs. [`HsLinkInfo`](../reference/extensions-and-providers.md#hslinkinfo) split). Notice how `:hello` imports `Data.Text` directly, so it declares `@hs_boot//:text` in its own `deps` even though `:greet` also depends on `@hs_boot//:text`. Conversely, `:greet_test` only calls `greetingFor` without importing `Data.Text` directly, so it only needs `:greet` and `@hs_boot//:base`.

## Step 5: Build, Test, and Inspect Hermeticity

Run the test suite and execute your binary:

```bash
bazel test //...
bazel run //:hello -- "World"
```

Output:

```text
Hello, World, from hermetic rules_hs!
```

You can verify that the resulting binary links `libgmp.a` statically and has zero dynamic dependencies outside base glibc:

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
Hello, Clean Env, from hermetic rules_hs!
```

## Switching to GHC 9.12.4

Upgrading GHC across your workspace is a one-line change in `MODULE.bazel`:

```starlark
hs = use_extension("@rules_hs//hs:extensions.bzl", "hs")
hs.toolchain(ghc_version = "9.12.4")
use_repo(hs, "hs_boot", "hs_toolchains")
```

Root module [`hs.toolchain`](../reference/extensions-and-providers.md#hs-toolchain) declarations automatically override `rules_hs`'s default `9.10.3` toolchain.

## Next Steps

- **Add Hackage dependencies (`aeson`, `http-client`, `xml-conduit`, `zlib`, etc.)**: Continue to [Hackage & Lockfiles](hackage.md).
- **Call C libraries or configure `toolchains_llvm`**: Read [C FFI & Toolchains](c-interop-and-toolchains.md).
- **Configure language editions, RTS concurrency, runfiles, Template Haskell, and Haddock API docs (`hs_haddock`)**: Read [Language, RTS, Runfiles & Template Haskell](language-rts-runfiles-th.md).
- **Explore a complete 69-package real-world application**: Walk through [Showcase: `examples/size`](showcase-size.md).
