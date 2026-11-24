---
title: "Quickstart"
description: "Set up a Bazel 9 Haskell workspace with Bzlmod and build a library, executable, and test target."
section: guide
nav_title: "Quickstart"
order: 10
---

In this quickstart, you create a standalone Bazel 9 Haskell workspace with [Bzlmod](https://bazel.build/external/overview) on Linux, without installing a host Haskell compiler or C development packages. By the end, you'll have a library, a command-line executable, and a unit test building and passing inside isolated [sandboxes](https://bazel.build/docs/sandboxing).

If you already have a working workspace and want third-party packages, continue to [Hackage and lockfiles](hackage.md). For conceptual background on Haskell or Bazel rulesets at any point, see the [Haskell and GHC primer](../internals/haskell-and-ghc-primer.md) and [Bazel ruleset primer](../internals/bazel-rules-primer.md).

## Prerequisites

The only host tool you need is **[Bazelisk](https://github.com/bazelbuild/bazelisk)**, a small launcher that downloads and runs the exact Bazel version listed in [`.bazelversion`](https://bazel.build/install/bazelisk) (`>= 9.0.0`).

On Linux (`x86_64` and `arm64`, with `glibc >= 2.28`), you don't need host `ghc`, `cabal`, `stack`, `nix`, `python3`, `gcc`, `clang`, or C development packages (`libgmp-dev`, `libtinfo-dev`, `zlib1g-dev`). Execution on macOS and Windows isn't supported yet; see [What is supported, planned, and out of scope](../index.md#project-scope) for current platform coverage.

## Project layout

You'll build a small workspace containing a library (`greet`), a command-line executable (`hello`), and a unit test (`greet_test`). Create a new directory named `my-hs-app/` and run every command in this guide from inside it.

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

- **`.bazelversion`:** Tells Bazelisk which Bazel release to download and run.
- **[`.bazelrc`](https://bazel.build/run/bazelrc):** Sets default command-line flags for [`bazel build`](https://bazel.build/run/build), [`bazel test`](https://bazel.build/docs/user-manual#running-tests), and [`bazel run`](https://bazel.build/docs/user-manual#running-executables).
- **[`MODULE.bazel`](https://bazel.build/external/module):** Declares external Bazel module dependencies and toolchains (C/C++ and GHC).
- **[`BUILD.bazel`](https://bazel.build/concepts/build-files):** Declares the build targets (`hs_library`, `hs_binary`, and `hs_test`) inside your repository.

## Step 1: Pin Bazel 9 and configure `.bazelrc`

Create `.bazelversion` to pin Bazel 9:

```text
9.3.3
```

Create `.bazelrc` with environment isolation and [runfiles](https://bazel.build/extending/rules#runfiles) flags:

```ini
common --enable_platform_specific_config
common --enable_runfiles
common --incompatible_strict_action_env
common --test_output=errors

# Shared Zig compiler cache mount when using hermetic_cc_toolchain
build:linux --repo_env=HERMETIC_CC_TOOLCHAIN_CACHE_PREFIX=/tmp/zig-cc-cache
build:linux --sandbox_add_mount_pair=/tmp
```

### Why each `.bazelrc` flag is here

- **[`--enable_platform_specific_config`](https://bazel.build/reference/command-line-reference#param-no-enable-platform-specific-config):** Enables `build:linux` lines automatically when you run on Linux.
- **[`--incompatible_strict_action_env`](https://bazel.build/reference/command-line-reference#param-no-incompatible-strict-action-env):** Prevents your shell's `PATH`, `LD_LIBRARY_PATH`, or `GHC_PACKAGE_PATH` environment variables from leaking into Bazel build sandboxes, so builds behave identically across developer machines and CI.
- **[`--enable_runfiles`](https://bazel.build/reference/command-line-reference#param-no-enable-runfiles):** Tells Bazel to create the `<binary>.runfiles` directory tree on disk so [`hs_binary`](../reference/rules.md#hs_binary) and [`hs_test`](../reference/rules.md#hs_test) targets can open runtime `data` files via `RUNFILES_DIR` and [`TEST_SRCDIR`](https://bazel.build/reference/test-encyclopedia#initial-conditions).
- **`HERMETIC_CC_TOOLCHAIN_CACHE_PREFIX` and [`--sandbox_add_mount_pair=/tmp`](https://bazel.build/reference/command-line-reference#param-sandbox-add-mount-pair):** Only needed when pairing `rules_haskell` with `hermetic_cc_toolchain` (`zig cc`). Zig compiles its C startup files on first use and caches them in this directory; mounting `/tmp` lets sandboxed actions share that cache instead of rebuilding C startup objects on every action. See [C FFI and toolchains](c-interop-and-toolchains.md) if you use `toolchains_llvm` or a system C compiler instead.

## Step 2: Configure `MODULE.bazel`

Create `MODULE.bazel` to load `rules_haskell`, register a C/C++ toolchain, and download GHC `9.10.3` through the [`hs`](../reference/extensions-and-providers.md#hs) [module extension](https://bazel.build/external/extension):

```starlark
module(
    name = "my_hs_project",
    version = "0.1.0",
    bazel_compatibility = [">=9.0.0"],
)

bazel_dep(name = "rules_haskell", version = "0.1.0")
# Until rules_haskell is published to the Bazel Central Registry (BCR),
# point git_override (or local_path_override) at your rules_haskell checkout:
git_override(
    module_name = "rules_haskell",
    remote = "https://github.com/kaycebasques/rules_haskell.git",
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
hs = use_extension("@rules_haskell//haskell:extensions.bzl", "hs")
hs.toolchain(ghc_version = "9.10.3")
use_repo(hs, "hs_boot", "hs_toolchains")

register_toolchains("@hs_toolchains//:all")
```

> **Important:** Register `gnu.2.32` before the `@zig_sdk` wildcard. When using `hermetic_cc_toolchain`, list `@zig_sdk//toolchain:linux_amd64_gnu.2.32` and `@zig_sdk//toolchain:linux_arm64_gnu.2.32` before `@zig_sdk//toolchain/...`. Without those two lines first, Bazel's wildcard registration picks `gnu.2.17` alphabetically, which lacks the `glibc` 2.28 and 2.32 symbols required by official GHC Linux archives and [BCR](https://bazel.build/external/registry#bazel-central-registry) `gmp`. See [C FFI and toolchains](c-interop-and-toolchains.md) for details.

### Why `MODULE.bazel` registers both a C toolchain and GHC

If this is your first Haskell and Bazel workspace, here's why two toolchains appear above:

- **Why GHC needs a C/C++ toolchain (`@zig_sdk`):** Unlike Go or Java, GHC uses a C assembler and system linker to produce native executables, linking your Haskell code against GHC's C Runtime System (`libHSrts.a`, the garbage collector and thread scheduler) and `libgmp.a` (arbitrary-precision integer arithmetic). Using `hermetic_cc_toolchain` gives you a self-contained `zig cc` C compiler and linker so you don't need `gcc` or `clang` installed on your machine (see [Dependency decisions](../internals/dependencies.md#module-bazel-anatomy)).
- **What [`hs.toolchain`](../reference/extensions-and-providers.md#hs-toolchain) creates:** Calling [`use_repo(hs, "hs_boot", "hs_toolchains")`](https://bazel.build/rules/lib/globals/module#use_repo) exposes two Bazel repositories:
  1. **`@hs_toolchains`:** Downloads and registers GHC (`9.10.3` by default, or `9.12.4`) for `linux_x86_64` and `linux_arm64`.
  2. **`@hs_boot`:** Exposes all 41 built-in "boot" libraries shipped inside GHC itself as Bazel targets, with no lockfile required. In this quickstart, you use two of them:
     - **`@hs_boot//:base`:** Haskell's standard library (`Prelude`, `IO`, `getArgs`, `exitFailure`).
     - **`@hs_boot//:text`:** Packed UTF-8 text (`Data.Text`, similar to Rust's `String`/`&str` or Go's `string`). In day-to-day Haskell code, prefer `Text` over `base`'s older `String` type, which is a linked list of characters (`[Char]`).

## Step 3: Write Haskell sources

Create a library module, an executable entry point, and a unit test. By default, [`hs_library`](../reference/rules.md#hs_library), `hs_binary`, and `hs_test` compile with `default_language = "GHC2021"`.

Create `src/Greet.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}

module Greet (greetingFor) where

import Data.Text (Text)
import Data.Text qualified as T

greetingFor :: Text -> Text
greetingFor who = "Hello, " <> T.strip who <> ", from rules_haskell."
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
      expected = "Hello, Haskell, from rules_haskell."
  unless (actual == expected) $ do
    putStrLn ("Expected: " <> show expected <> ", got: " <> show actual)
    exitFailure
```

### How these three `.hs` files work

- **`default_language = "GHC2021"`:** User targets compile with GHC's `GHC2021` language edition by default (matching GHC `9.10` and `9.12`'s own default), which enables features such as post-qualified imports (`import Data.Text qualified as T`). You can also set `default_language = "GHC2024"` or `"Haskell2010"` per target; see [Language, RTS, runfiles, and Template Haskell](language-rts-runfiles-th.md).
- **`{-# LANGUAGE OverloadedStrings #-}`:** A file-level compiler pragma that lets `"..."` string literals construct UTF-8 `Text` values directly instead of only `[Char]`.
- **`module Greet (greetingFor) where`:** Names the module `Greet` and exports `greetingFor :: Text -> Text`. Here `<>` concatenates two `Text` values, and `T.strip` trims leading and trailing whitespace.
- **`module Main (main) where` and `main :: IO ()`:** Every Haskell executable (`hs_binary` and `hs_test`) starts at `Main.main` of type `IO ()`—an I/O action sequenced step by step using `do` notation (`args <- getArgs`). In `GreetTest.hs`, returning normally exits with status `0` (test pass), while `exitFailure` exits with a non-zero status (test failure).

## Step 4: Declare targets in `BUILD.bazel`

Create `BUILD.bazel` to declare your library, executable, and test targets using `hs_library`, `hs_binary`, and `hs_test` from `@rules_haskell//haskell:defs.bzl`:

```starlark
load("@rules_haskell//haskell:defs.bzl", "hs_binary", "hs_library", "hs_test")

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

### What each `BUILD.bazel` attribute does

- **`hs_source_dirs = ["src"]` (or `["test"]`):** Sets the root directory from which GHC resolves dotted module names—mapping `module Greet` to `src/Greet.hs` (and `module Foo.Bar` to `src/Foo/Bar.hs`).
- **`ghc_opts = ["-Wall", "-Wcompat"]`:** Enables GHC's standard warning set (`-Wall`) plus forward-compatibility warnings (`-Wcompat`).
- **`hs_library`, `hs_binary`, and `hs_test`:** `hs_library` compiles reusable `.a` static archives and `.hi` compiler interface files; `hs_binary` compiles `Main.main` and links all transitive Haskell and C archives into a native executable; `hs_test` builds a test executable that `bazel test` runs inside an isolated sandbox.

> **Tip:** `rules_haskell` enforces direct-dependency visibility by passing `-hide-all-packages` to GHC and exposing only direct `deps` via `-package-id` (using separate direct [`HsPackageInfo`](../reference/extensions-and-providers.md#hspackageinfo) and transitive [`HsLinkInfo`](../reference/extensions-and-providers.md#hslinkinfo) [providers](https://bazel.build/extending/rules#providers)). Because `:hello` imports `Data.Text` in `src/Main.hs`, it lists `@hs_boot//:text` in its own `deps` even though `:greet` also depends on `@hs_boot//:text`. By contrast, `:greet_test` calls `greetingFor` without importing `Data.Text` directly, so it only needs `:greet` and `@hs_boot//:base`.

## Step 5: Build, test, and inspect runtime dependencies

Run the test suite and execute your binary:

```bash
bazel test //...
bazel run //:hello -- "World"
```

Expected output from `bazel run`:

```text
Hello, World, from rules_haskell.
```

> **Tip:** To experiment interactively in a `ghci` REPL, add an [`hs_repl`](../reference/rules.md#hs_repl) target (`hs_repl(name = "greet_repl", deps = [":greet"])`) and run `bazel run //:greet_repl`. That opens a `ghci` session with `Greet` loaded in bytecode (supporting `:reload` on workspace edits, `:type`, and `:break`). For a standalone prompt, run `bazel run @rules_haskell//tools/ghci`. See [Language, RTS, runfiles, and Template Haskell](language-rts-runfiles-th.md#interactive-ghci-repl) for details.

On Linux, every ELF executable records the shared `.so` libraries it needs at startup in `NEEDED` metadata entries. Inspect [`bazel-bin/hello`](https://bazel.build/remote/output-directories) with `readelf -d` and run it with an empty environment (`env -i PATH=/nonexistent`) to confirm it statically links `libgmp.a` and depends only on standard `glibc` libraries:

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
Hello, Clean Env, from rules_haskell.
```

## Switch to GHC 9.12.4

To change the GHC version across your workspace, update `ghc_version` in `MODULE.bazel`:

```starlark
hs = use_extension("@rules_haskell//haskell:extensions.bzl", "hs")
hs.toolchain(ghc_version = "9.12.4")
use_repo(hs, "hs_boot", "hs_toolchains")
```

A root module [`hs.toolchain`](../reference/extensions-and-providers.md#hs-toolchain) call overrides the default `9.10.3` toolchain across your workspace.

## Summary and next steps

You now have a standalone Bazel 9 Haskell workspace that compiles a library, links a portable Linux executable with static `libgmp.a`, and runs a sandboxed unit test—without installing host GHC or C development packages. For a complete in-tree version of this workspace (including an ELF dependency test), see `examples/quickstart/`.

From here, pick the next guide based on what your project needs:

- **Add Hackage dependencies (`aeson`, `http-client`, `xml-conduit`, `zlib`):** Continue to [Hackage and lockfiles](hackage.md).
- **Call C libraries or switch to `toolchains_llvm`:** Read [C FFI and toolchains](c-interop-and-toolchains.md).
- **Configure `GHC2021` vs. `GHC2024`, RTS concurrency, runfiles, Template Haskell, and Haddock API docs (`hs_haddock`):** Read [Language, RTS, runfiles, and Template Haskell](language-rts-runfiles-th.md).
- **Explore a complete 69-package application:** Walk through [Showcase: `examples/size`](showcase-size.md).
