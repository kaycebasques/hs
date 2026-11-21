---
title: "C FFI & Toolchains"
description: "Integrate Haskell ForeignFunctionInterface and CApiFFI code with Bazel cc_library targets, inline C sources, and hermetic C/C++ toolchains."
section: guide
nav_title: "C FFI & Toolchains"
order: 30
---

`rules_hs` treats C/C++ interoperability as a first-class citizen. Every Haskell rule ([`hs_library`](../reference/rules.md#hs_library), [`hs_binary`](../reference/rules.md#hs_binary), [`hs_test`](../reference/rules.md#hs_test), and [`hs_cabal_library`](../reference/rules.md#hs_cabal_library)) resolves Bazel's active `@bazel_tools//tools/cpp:toolchain_type` through `rules_cc` (`cc_common`) and routes GHC's C compiler, assembler, preprocessor, and linker phases through a compiled native C11 wrapper (`ghc_cc_wrapper`).

## Two Ways to Link C Code

You can combine Haskell FFI (`ForeignFunctionInterface` and `CApiFFI`) with native C/C++ code in two ways — or mix both freely in the same dependency graph:

1. **Separate `cc_library` targets (`cc_deps` or `deps`)**: Recommended when C/C++ code is shared across targets, comes from the Bazel Central Registry (BCR), or has its own C unit tests.
2. **Inline `c_sources` + `hdrs` + `include_dirs` + `cc_options`**: Convenient when small C helper routines live directly inside a Haskell package (`cbits/`).

---

## Pattern 1: Linking Bazel `cc_library` Targets via `cc_deps`

Given a C header `vec.h` and implementation `vec.c` defining constants, global symbols, and struct operations (grounded in `tests/rules/ffi`):

```c
// vec.h
#ifndef VEC_H
#define VEC_H

#include <stdint.h>

#define VEC_MAGIC_VERSION 2026

extern const int32_t vec_global_bias;

typedef struct {
    int32_t x;
    int32_t y;
    double weight;
} Vec2;

void vec2_init(Vec2 *out, int32_t x, int32_t y, double weight);
void vec2_add(const Vec2 *a, const Vec2 *b, Vec2 *out);
int64_t vec2_dot(const Vec2 *a, const Vec2 *b);

#endif
```

```c
// vec.c
#include "vec.h"

const int32_t vec_global_bias = 100;

void vec2_init(Vec2 *out, int32_t x, int32_t y, double weight) {
    out->x = x;
    out->y = y;
    out->weight = weight;
}

void vec2_add(const Vec2 *a, const Vec2 *b, Vec2 *out) {
    out->x = a->x + b->x;
    out->y = a->y + b->y;
    out->weight = a->weight + b->weight;
}

int64_t vec2_dot(const Vec2 *a, const Vec2 *b) {
    return (int64_t)a->x * (int64_t)b->x + (int64_t)a->y * (int64_t)b->y;
}
```

Bind to `vec.h` from Haskell using both `CApiFFI` (for C preprocessor macros and header-checked wrapper stubs) and `ccall` (for C functions and `&global` data addresses):

```haskell
{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE ForeignFunctionInterface #-}

module CcDepsFfi
  ( Vec2 (..)
  , vecMagicVersion
  , readVecGlobalBias
  , initVec2
  , addVec2
  , dotVec2
  ) where

import Data.Int (Int32, Int64)
import Foreign.C.Types (CInt (..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Marshal.Utils (with)
import Foreign.Ptr (Ptr)
import Foreign.Storable (Storable (..))

data Vec2 = Vec2
  { vecX :: !Int32
  , vecY :: !Int32
  , vecWeight :: !Double
  }
  deriving (Eq, Show)

instance Storable Vec2 where
  sizeOf _ = 16
  alignment _ = 8
  peek ptr = Vec2 <$> peekByteOff ptr 0 <*> peekByteOff ptr 4 <*> peekByteOff ptr 8
  poke ptr (Vec2 x y w) = pokeByteOff ptr 0 x >> pokeByteOff ptr 4 y >> pokeByteOff ptr 8 w

foreign import capi "vec.h value VEC_MAGIC_VERSION"
  c_vecMagicVersion :: CInt

foreign import ccall "&vec_global_bias"
  p_vecGlobalBias :: Ptr Int32

foreign import ccall unsafe "vec2_init"
  c_vec2Init :: Ptr Vec2 -> Int32 -> Int32 -> Double -> IO ()

foreign import ccall unsafe "vec2_add"
  c_vec2Add :: Ptr Vec2 -> Ptr Vec2 -> Ptr Vec2 -> IO ()

foreign import ccall unsafe "vec2_dot"
  c_vec2Dot :: Ptr Vec2 -> Ptr Vec2 -> IO Int64

vecMagicVersion :: Int
vecMagicVersion = fromIntegral c_vecMagicVersion

readVecGlobalBias :: IO Int32
readVecGlobalBias = peek p_vecGlobalBias

initVec2 :: Int32 -> Int32 -> Double -> IO Vec2
initVec2 x y w = alloca $ \out -> c_vec2Init out x y w >> peek out

addVec2 :: Vec2 -> Vec2 -> IO Vec2
addVec2 a b = with a $ \pa -> with b $ \pb -> alloca $ \out -> c_vec2Add pa pb out >> peek out

dotVec2 :: Vec2 -> Vec2 -> IO Int64
dotVec2 a b = with a $ \pa -> with b $ \pb -> c_vec2Dot pa pb
```

Wire the `cc_library` into `cc_deps` in `BUILD.bazel`:

```starlark
load("@rules_cc//cc:cc_library.bzl", "cc_library")
load("@rules_hs//hs:defs.bzl", "hs_library", "hs_test")

cc_library(
    name = "vec_cc",
    srcs = ["vec.c"],
    hdrs = ["vec.h"],
    includes = ["."],
)

hs_library(
    name = "cc_deps_lib",
    srcs = ["CcDepsFfi.hs"],
    cc_deps = [":vec_cc"],
    deps = ["@hs_boot//:base"],
)

hs_test(
    name = "ffi_test",
    size = "small",
    srcs = ["FfiTest.hs"],
    deps = [
        ":cc_deps_lib",
        "@hs_boot//:base",
    ],
)
```

> **Note — Automatic Transitive `CcInfo` Propagation:** [`hs_library`](../reference/rules.md#hs_library) returns both [`HsLinkInfo`](../reference/extensions-and-providers.md#hslinkinfo) and Bazel's standard `CcInfo` provider. Downstream [`hs_library`](../reference/rules.md#hs_library), [`hs_binary`](../reference/rules.md#hs_binary), and [`hs_test`](../reference/rules.md#hs_test) targets automatically inherit `:vec_cc`'s headers, include directories, and static archives without repeating `cc_deps = [":vec_cc"]`. At final executable link time, `rules_hs` wraps all transitive static C archives in `-Wl,--start-group ... -Wl,--end-group` so symbol resolution succeeds regardless of archive order.

---

## Pattern 2: Inline `c_sources` Inside `hs_library` or `hs_binary`

When C files belong directly to a Haskell library, pass `c_sources`, `hdrs`, `include_dirs`, and `cc_options` on [`hs_library`](../reference/rules.md#hs_library) (or [`hs_binary`](../reference/rules.md#hs_binary) / [`hs_test`](../reference/rules.md#hs_test)):

```starlark
hs_library(
    name = "inline_c_lib",
    srcs = ["InlineCFfi.hs"],
    c_sources = ["csrc/inline_helper.c"],
    cc_options = ["-DINLINE_SCALE=3"],
    hdrs = ["csrc/inline_helper.h"],
    include_dirs = ["csrc"],
    deps = ["@hs_boot//:base"],
)
```

`rules_hs` compiles `c_sources` via `cc_common.compile` with:
- `-fPIC` enabled so objects work seamlessly in both static archives and shared TH contexts.
- GHC's internal RTS header directory (`Rts.h`, `HsFFI.h`, `ghcversion.h`) automatically added to `-I` — your `.c` files can `#include <HsFFI.h>` or `#include <Rts.h>` out of the box.
- All files in `hdrs` and `include_dirs` propagated via `CcInfo` and [`HsLinkInfo`](../reference/extensions-and-providers.md#hslinkinfo).

> **Tip — CPP Options vs. C Compiler Options:**
> - Use **`cpp_options`** (e.g., `cpp_options = ["-DFEATURE_X=1"]`) for flags passed to the C preprocessor when preprocessing `.hs` files with `{-# LANGUAGE CPP #-}` (`-optP`) and `.hsc` files (`hsc2hs`).
> - Use **`cc_options`** (e.g., `cc_options = ["-DINLINE_SCALE=3", "-msse4.2"]`) for flags passed to the C compiler when compiling `c_sources` via `cc_common.compile`.

---

## Choosing a C/C++ Toolchain

`rules_hs` is **100% C-toolchain agnostic**: `hermetic_cc_toolchain` is strictly a `dev_dependency = True` in `rules_hs`'s own `MODULE.bazel`. In your project's `MODULE.bazel`, you can pair `rules_hs` with any Linux C/C++ toolchain registered for `@bazel_tools//tools/cpp:toolchain_type`.

### Option A: `hermetic_cc_toolchain` (`zig cc`) — Zero Host C Packages

`hermetic_cc_toolchain` downloads a self-contained Zig C/C++ cross-compiler and glibc headers/stubs, requiring zero host `gcc`, `clang`, `binutils`, or `libc6-dev`:

```starlark
bazel_dep(name = "hermetic_cc_toolchain", version = "4.3.0")

cc_toolchains = use_extension("@hermetic_cc_toolchain//toolchain:ext.bzl", "toolchains")
use_repo(cc_toolchains, "zig_sdk")

register_toolchains(
    "@zig_sdk//toolchain:linux_amd64_gnu.2.32",
    "@zig_sdk//toolchain:linux_arm64_gnu.2.32",
    "@zig_sdk//toolchain/...",
    "@zig_sdk//libc_aware/toolchain/...",
)
```

Add the Zig cache directory mount to `.bazelrc` so `zig cc` reuses its compiled `libc` startup objects across sandboxed actions:

```ini
build:linux --repo_env=HERMETIC_CC_TOOLCHAIN_CACHE_PREFIX=/tmp/zig-cc-cache
build:linux --sandbox_add_mount_pair=/tmp
```

> **Warning — Why `gnu.2.32` Instead of Default `gnu.2.17`?** Registering `@zig_sdk//toolchain/...` alone defaults to `gnu.2.17` (alphabetical match). `gnu.2.17` fails in two ways:
> 1. Official GHC `deb10` bindists reference glibc `2.27`/`2.28` symbols (`memfd_create`, `statx`, `fcntl64`).
> 2. BCR `gmp` / `m4` check `<sys/single_threaded.h>` under Zig, which requires glibc `>= 2.32`.
>
> Registering `linux_amd64_gnu.2.32` and `linux_arm64_gnu.2.32` first satisfies both constraints while keeping compiled binaries portable across Debian 12 (glibc 2.36), Ubuntu 22.04 (2.35), Ubuntu 24.04 (2.39), and Rocky Linux 9 (2.34).

### Option B: `toolchains_llvm` (Hermetic Clang + `lld` + Sysroot)

If your workspace already uses `toolchains_llvm` with a hermetic Debian `>= 10` (`glibc >= 2.28`) sysroot, `rules_hs` works with **zero** `/tmp` sandbox mounts in `.bazelrc`:

```starlark
bazel_dep(name = "toolchains_llvm", version = "1.4.0")

llvm = use_extension("@toolchains_llvm//toolchain/extensions:llvm.bzl", "llvm")
llvm.toolchain(
    name = "llvm_toolchain",
    llvm_version = "19.1.0",
)
# Optional: attach a Debian >= 10 sysroot via llvm.sysroot(...)
use_repo(llvm, "llvm_toolchain")

register_toolchains("@llvm_toolchain//:all")
```

`resolve_cc_tools` in `hs/private/actions.bzl` automatically extracts `--sysroot` and `--target` flags from `toolchains_llvm`'s `cc_toolchain` feature configuration and forwards them to `ghc_cc_wrapper` via `RULES_HS_CC_EXTRA_ARGS`.

### Option C: System or Enterprise RBE GCC / Clang Toolchain

If you omit `hermetic_cc_toolchain` and `toolchains_llvm`, `rules_cc` auto-detects the host or RBE container's GCC/Clang toolchain. Because `rules_hs` sanitizes GHC's baked-in `lib/settings` paths (`/usr/bin/gcc` -> `/nonexistent/gcc`) and passes every tool explicitly from `@bazel_tools//tools/cpp:toolchain_type`, GHC always uses the exact `cc`, `ar`, and `ld` configured by Bazel.

## How `ghc_cc_wrapper` Bridges GHC and Modern C Toolchains

Under the hood, GHC invokes external C tools with legacy GCC-oriented flags that trip up Clang, `lld`, and `zig cc`. Rather than spawning a Python interpreter on every action, `rules_hs` compiles a tiny C11 binary (`hs/private/cc_wrapper.c`) that handles:

- Scrubbing `RUNFILES_DIR`, `RUNFILES_MANIFEST_FILE`, and `RUNFILES_MANIFEST_ONLY` from subprocess environments.
- Rewriting `-Wl,-h,<soname>` to `-Wl,-soname,<soname>` (including inside `@response` files).
- Stripping legacy `-fuse-ld=gold`, rewriting `-fno-PIC` to `-fPIC`, and aliasing `.dyn_o`/`.p_o` inputs to `.o` symlinks for `zig cc`.
- Injecting `-nostdinc++` on C/assembler/link invocations so C++ standard library headers never shadow `<features.h>` / `_GNU_SOURCE` ordering in `hsc2hs` and `CApiFFI`.

For a complete line-by-line walkthrough of `ghc_cc_wrapper`, see [Hermeticity & Toolchain](../internals/hermeticity.md).
