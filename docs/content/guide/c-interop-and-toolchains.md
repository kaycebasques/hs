---
title: "C FFI & Toolchains"
description: "Call C and C++ code from Haskell using ForeignFunctionInterface, CApiFFI, Bazel cc_library targets, inline c_sources, and any Bazel C/C++ toolchain."
section: guide
nav_title: "C FFI & Toolchains"
order: 30
---

Every Haskell rule in `rules_hs` ([`hs_library`](../reference/rules.md#hs_library), [`hs_binary`](../reference/rules.md#hs_binary), [`hs_test`](../reference/rules.md#hs_test), and [`hs_cabal_library`](../reference/rules.md#hs_cabal_library)) resolves Bazel's active `@bazel_tools//tools/cpp:toolchain_type` through `rules_cc` (`cc_common`) and routes GHC's C compiler, assembler, preprocessor, and linker invocations through a small compiled C11 adapter binary (`ghc_cc_wrapper`).

## Haskell C FFI Basics (`ccall` vs. `capi`)

If you are new to calling C from Haskell, GHC provides two language extensions for foreign imports:

- **`ForeignFunctionInterface` (`foreign import ccall`)**: Calls an exported C function directly by its compiled linker symbol name (or takes the memory address of a C global variable via `"&name"`). Use `ccall` for ordinary C functions with fixed ABI types.
- **`CApiFFI` (`foreign import capi`)**: Tells GHC to generate a tiny C wrapper file that `#include`s your `.h` header and compiles it with the C compiler. Because the C compiler sees your header directly, `capi` can bind `#define` preprocessor constants (`value MY_MACRO`), `static inline` C functions, and C functions whose types rely on platform `typedef`s.

## Two Ways to Attach C/C++ Code in Bazel

You can supply C or C++ code to Haskell rules in two ways, and mix both in the same build graph:

1. **Separate `cc_library` targets (`cc_deps` or `deps`)**: Best when C/C++ code is shared across multiple targets, comes from the Bazel Central Registry (BCR), or has its own C tests.
2. **Inline `c_sources` + `hdrs` + `include_dirs` + `cc_options`**: Convenient when small C helper files live inside a Haskell package directory (often named `cbits/`).

---

## Pattern 1: Linking Bazel `cc_library` Targets via `cc_deps`

Suppose you have a C header `vec.h` and implementation `vec.c` defining a preprocessor macro, a global constant, and struct operations (based on `tests/rules/ffi`):

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

Bind to `vec.h` from Haskell using `capi` (for the `#define VEC_MAGIC_VERSION` macro) and `ccall` (for the `&vec_global_bias` global address and C functions):

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

### How the Haskell Marshaling Helpers Work

- **`Ptr a` and `Storable`**: `Ptr Vec2` is a raw C memory pointer (`Vec2 *`). Implementing `Storable Vec2` teaches Haskell the struct's byte size (`16`), byte alignment (`8`), and how to read (`peek`) or write (`poke`) fields at byte offsets (`0`, `4`, `8`). (For larger C structs where computing byte offsets by hand is tedious, `.hsc` templates via `hsc2hs` fill in those offsets automatically from the C compiler.)
- **`alloca` and `with`**: `alloca` allocates temporary uninitialized memory for a `Storable` value, passes the `Ptr` to your callback, and frees it automatically when the callback finishes; `with` does the same but writes (`poke`s) an existing Haskell value into the temporary buffer first.
- **`unsafe` vs. `safe` on `foreign import ccall`**: In GHC, `"unsafe"` does **not** mean memory-unsafe; it means "this C function finishes quickly and will not call back into Haskell or block on I/O," allowing GHC to emit a direct C function call with minimal overhead. Omit `unsafe` (defaulting to `safe`) for C functions that block on network/disk I/O or take a long time, so GHC's `-threaded` runtime can keep running other Haskell green threads concurrently.

Connect `:vec_cc` to `cc_deps` in `BUILD.bazel`:

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

> **Note — Automatic transitive C header and archive propagation (`CcInfo`):** In Bazel, C/C++ targets pass header search paths, preprocessor `#define` flags, and compiled `.a` static archives through a standard provider named `CcInfo`. [`hs_library`](../reference/rules.md#hs_library) returns both [`HsLinkInfo`](../reference/extensions-and-providers.md#hslinkinfo) and `CcInfo`, so downstream [`hs_library`](../reference/rules.md#hs_library), [`hs_binary`](../reference/rules.md#hs_binary), and [`hs_test`](../reference/rules.md#hs_test) targets inherit `:vec_cc`'s headers and `.a` archive automatically without repeating `cc_deps = [":vec_cc"]`. When linking a final executable, `rules_hs` wraps all transitive static C archives in `-Wl,--start-group ... -Wl,--end-group` so the linker resolves cross-archive C symbols regardless of ordering.

---

## Pattern 2: Inline `c_sources` Inside `hs_library` or `hs_binary`

When C or C++ files live inside a Haskell package rather than in a standalone `cc_library`, pass `c_sources`, `hdrs`, `include_dirs`, and `cc_options` directly on [`hs_library`](../reference/rules.md#hs_library) (or [`hs_binary`](../reference/rules.md#hs_binary) / [`hs_test`](../reference/rules.md#hs_test)):

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
- Position-independent code (`-fPIC`) enabled so the compiled C objects can be linked both into static `.a` executables and into shared `.so` libraries used when evaluating Template Haskell splices at compile time.
- GHC's own runtime header directory (`Rts.h`, `HsFFI.h`, `ghcversion.h`) automatically added to `-I`, so your `.c` files can `#include <HsFFI.h>` or `#include <Rts.h>` without extra configuration.
- All files in `hdrs` and `include_dirs` propagated downstream via `CcInfo` and [`HsLinkInfo`](../reference/extensions-and-providers.md#hslinkinfo).

> **Tip — `cpp_options` vs. `cc_options`:**
> - Use **`cpp_options`** (for example, `cpp_options = ["-DFEATURE_X=1"]`) for flags passed to the C preprocessor when preprocessing `.hs` files that enable `{-# LANGUAGE CPP #-}` (`-optP`) and `.hsc` files (`hsc2hs`).
> - Use **`cc_options`** (for example, `cc_options = ["-DINLINE_SCALE=3", "-msse4.2"]`) for flags passed to the C/C++ compiler when compiling `c_sources` via `cc_common.compile`.

---

## Choosing a C/C++ Toolchain

`rules_hs` works with any Linux C/C++ toolchain registered for `@bazel_tools//tools/cpp:toolchain_type`. `hermetic_cc_toolchain` is marked `dev_dependency = True` in `rules_hs`'s own `MODULE.bazel`, so your workspace chooses whichever C toolchain fits your build environment.

### Option A: `hermetic_cc_toolchain` (`zig cc`) — No Host C Packages Required

`hermetic_cc_toolchain` downloads a self-contained Zig C/C++ compiler and bundled `glibc` headers and link stubs, requiring no host `gcc`, `clang`, `binutils`, or `libc6-dev`:

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

> **Warning — Why `gnu.2.32` instead of default `gnu.2.17`?** Registering `@zig_sdk//toolchain/...` by itself selects `gnu.2.17` (the first alphabetical match), which fails for two reasons:
> 1. Official GHC `deb10` binary distributions reference `glibc` `2.27` and `2.28` symbols (`memfd_create`, `statx`, `fcntl64`).
> 2. BCR `gmp` and `m4` check `<sys/single_threaded.h>` under Zig, which requires `glibc >= 2.32`.
>
> Listing `linux_amd64_gnu.2.32` and `linux_arm64_gnu.2.32` first satisfies both requirements while keeping compiled binaries runnable across Debian 12 (`glibc` 2.36), Ubuntu 22.04 (2.35), Ubuntu 24.04 (2.39), and Rocky Linux 9 (2.34).

### Option B: `toolchains_llvm` (Clang + `mold` / `lld` + Sysroot)

If your workspace uses `toolchains_llvm` with a Debian `>= 10` (`glibc >= 2.28`) sysroot (a directory tree containing target Linux headers and `libc` libraries), `rules_hs` builds with Clang without needing `/tmp` sandbox mounts in `.bazelrc`:

```starlark
bazel_dep(name = "toolchains_llvm", version = "1.13.0")

llvm = use_extension("@toolchains_llvm//toolchain/extensions:llvm.bzl", "llvm")
llvm.toolchain(
    name = "llvm_toolchain",
    # Optional: select toolchains_llvm's self-contained mold binary so link
    # actions do not depend on host libxml2.so.2 (linked by upstream ld.lld).
    linker = {
        "linux-x86_64": "mold",
        "linux-aarch64": "mold",
    },
    linker_version = "2.42.1",
    llvm_version = "22.1.8",
)
# Attach a Debian >= 10 sysroot via llvm.sysroot(...) — see examples/llvm_toolchain
use_repo(llvm, "llvm_toolchain")

register_toolchains("@llvm_toolchain//:all")
```

`resolve_cc_tools` in `hs/private/actions.bzl` reads `--sysroot`, `--target`, `-B`, `-resource-dir`, `-fuse-ld`, and `--ld-path` flags from `toolchains_llvm`'s `cc_toolchain` configuration and forwards them to `ghc_cc_wrapper` through `RULES_HS_CC_EXTRA_ARGS`.

### Option C: System or Remote-Execution GCC / Clang Toolchain

If you omit `hermetic_cc_toolchain` and `toolchains_llvm`, `rules_cc` detects the host or remote-execution container's GCC or Clang toolchain (see `examples/system_cc_toolchain`). Because `rules_hs` replaces GHC's hardcoded `lib/settings` paths (`/usr/bin/gcc` -> `/nonexistent/gcc`) and passes every tool path and `-B` search directory explicitly from `@bazel_tools//tools/cpp:toolchain_type`, GHC uses the exact `cc`, `ar`, and `ld` configured by Bazel even under `--incompatible_strict_action_env`. On Linux hosts using GNU `ld.bfd`, add `build:linux --features=-supports_start_end_lib` and `build:linux --host_features=-supports_start_end_lib` to `.bazelrc` so C/C++ dependencies link `.a` archives rather than `--start-lib`/`--end-lib` object lists.

## What `ghc_cc_wrapper` Translates Between GHC and C Toolchains

GHC invokes its C compiler and linker using older GCC-style flags that Clang, `lld`, and `zig cc` either reject or interpret differently. Instead of running a Python script on every compile or link action, `rules_hs` compiles a small C11 program (`hs/private/cc_wrapper.c`, 552 lines) that adjusts arguments before executing the real C compiler:

- Clears Bazel's `RUNFILES_DIR`, `RUNFILES_MANIFEST_FILE`, and `RUNFILES_MANIFEST_ONLY` environment variables from subprocesses so tools do not confuse wrapper runfiles with target inputs.
- Rewrites Solaris/GCC shared-library name flags (`-Wl,-h,<soname>`) into standard `-Wl,-soname,<soname>` flags, including inside `@args` response files (temporary files GHC uses to pass long command lines).
- Removes `-fuse-ld=gold` (deprecated/absent on `lld` and `zig cc`), rewrites `-fno-PIC` to `-fPIC`, and creates temporary `.o` symlinks for `.dyn_o` and `.p_o` object files when `zig cc` checks file extensions.
- Passes `-nostdinc++` on C, assembler, and linker calls so C++ standard library headers (such as `<version>`) do not shadow C headers or disrupt `<features.h>` / `_GNU_SOURCE` include ordering in `hsc2hs` and `CApiFFI`.

For a detailed walkthrough of `ghc_cc_wrapper`, see [Hermeticity & Toolchain](../internals/hermeticity.md).
