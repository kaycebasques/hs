---
title: "C FFI and toolchains"
description: "Call C and C++ code from Haskell using ForeignFunctionInterface, CApiFFI, Bazel cc_library targets, inline c_sources, and any Bazel C/C++ toolchain."
section: guide
nav_title: "C FFI and toolchains"
order: 30
---

This guide shows you how to call C and C++ code from Haskell and pair `rules_haskell` with your preferred Linux C/C++ toolchain (`hermetic_cc_toolchain`, `toolchains_llvm`, or a system GCC or Clang toolchain). Every Haskell rule resolves Bazel's active `@bazel_tools//tools/cpp:toolchain_type` through `rules_cc` ([`cc_common`](https://bazel.build/rules/lib/toplevel/cc_common)) and adapts GHC's C compiler, assembler, preprocessor, and linker flags with a compiled C11 helper (`ghc_cc_wrapper`).

If you need to wire C libraries into third-party Hackage packages, see [Hackage and lockfiles](hackage.md). For the low-level design of `ghc_cc_wrapper` and toolchain isolation, see [Hermeticity and toolchain](../internals/hermeticity.md).

## Haskell C FFI basics: `ccall` vs. `capi`

If you're new to calling C from Haskell, GHC provides two language extensions for foreign imports:

- **`ForeignFunctionInterface` (`foreign import ccall`):** Calls an exported C function directly by its compiled linker symbol name, or takes the memory address of a C global variable via `"&name"`. Use `ccall` for ordinary C functions with fixed ABI types.
- **`CApiFFI` (`foreign import capi`):** Generates a small C wrapper file that `#include`s your `.h` header and compiles it with the C compiler. Because the C compiler sees your header directly, `capi` can bind `#define` preprocessor constants (`value MY_MACRO`), `static inline` C functions, and C functions whose types rely on platform `typedef`s.

## Choose how to attach C and C++ code

You can supply C or C++ code to Haskell rules in two ways, and mix both in the same build graph:

1. **Separate [`cc_library`](https://bazel.build/reference/be/c-cpp#cc_library) targets (`cc_deps` or `deps`):** Best when C or C++ code is shared across multiple targets, comes from the [Bazel Central Registry (BCR)](https://bazel.build/external/registry#bazel-central-registry), or has its own C tests.
2. **Inline `c_sources`, `hdrs`, `include_dirs`, and `cc_options`:** Convenient when small C helper files live inside a Haskell package directory (often named `cbits/`).

## Pattern 1: Link Bazel `cc_library` targets via `cc_deps`

This example (adapted from `tests/rules/ffi/`) binds a C header (`vec.h`) and implementation (`vec.c`) defining a preprocessor macro, a global constant, and struct operations:

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

### How the Haskell marshaling helpers work

- **`Ptr a` and `Storable`:** `Ptr Vec2` is a raw C memory pointer (`Vec2 *`). Implementing `Storable Vec2` tells Haskell the struct's byte size (`16`), byte alignment (`8`), and how to read (`peek`) or write (`poke`) fields at byte offsets (`0`, `4`, `8`). For larger C structs where computing byte offsets by hand is error-prone, `.hsc` templates via `hsc2hs` compute offsets from the C compiler automatically.
- **`alloca` and `with`:** `alloca` allocates temporary uninitialized memory for a `Storable` value, passes the `Ptr` to your callback, and frees it when the callback finishes. `with` does the same, except it writes (`poke`s) an existing Haskell value into the buffer first.
- **`unsafe` vs. `safe` on `foreign import ccall`:** In GHC, `unsafe` doesn't mean memory-unsafe; it means the C function finishes quickly and won't call back into Haskell or block on I/O, allowing GHC to emit a direct C call with minimal overhead. Omit `unsafe` (defaulting to `safe`) for C functions that block on network or disk I/O or run for a long time, so GHC's `-threaded` runtime can keep running other Haskell green threads concurrently.

Connect `:vec_cc` to `cc_deps` in [`BUILD.bazel`](https://bazel.build/concepts/build-files):

```starlark
load("@rules_cc//cc:cc_library.bzl", "cc_library")
load("@rules_haskell//haskell:defs.bzl", "hs_library", "hs_test")

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

> **Note:** You don't need to repeat `cc_deps` on downstream libraries, binaries, or tests. Because [`hs_library`](../reference/rules.md#hs_library) returns both [`HsLinkInfo`](../reference/extensions-and-providers.md#hslinkinfo) and Bazel's [`CcInfo`](https://bazel.build/rules/lib/providers/CcInfo) provider, `:vec_cc`'s header search paths, preprocessor `#define` flags, and `.a` archive propagate automatically to downstream `hs_library`, [`hs_binary`](../reference/rules.md#hs_binary), and [`hs_test`](../reference/rules.md#hs_test) targets. When linking a final executable, transitive static C archives are wrapped in `-Wl,--start-group ... -Wl,--end-group` so cross-archive C symbols resolve regardless of link order.

## Pattern 2: Compile inline `c_sources` in Haskell targets

When C or C++ helpers live inside a Haskell package rather than in a standalone `cc_library`, pass `c_sources`, `hdrs`, `include_dirs`, and `cc_options` directly on `hs_library`, `hs_binary`, or `hs_test`:

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

Each file in `c_sources` compiles via `cc_common.compile` with:

- **Position-independent code (`-fPIC`):** Compiled C objects link into both static `.a` executables and shared `.so` libraries loaded during Template Haskell splice evaluation.
- **GHC runtime headers on `-I`:** Your `.c` files can `#include <HsFFI.h>`, `#include <Rts.h>`, or `#include <ghcversion.h>` without extra include flags.
- **Transitive propagation:** Files in `hdrs` and `include_dirs` propagate downstream through `CcInfo` and `HsLinkInfo`.

> **Tip:** Choose `cpp_options` or `cc_options` based on which tool needs the flag:
>
> - Use **`cpp_options`** (for example, `cpp_options = ["-DFEATURE_X=1"]`) for flags passed to the C preprocessor on `.hs` files with `{-# LANGUAGE CPP #-}` (`-optP`) and `.hsc` files (`hsc2hs`).
> - Use **`cc_options`** (for example, `cc_options = ["-DINLINE_SCALE=3", "-msse4.2"]`) for flags passed to the C or C++ compiler when compiling `c_sources` via `cc_common.compile`.

## Choose a C/C++ toolchain

You can use any Linux C/C++ toolchain registered for `@bazel_tools//tools/cpp:toolchain_type`. Because `hermetic_cc_toolchain` is declared with [`dev_dependency = True`](https://bazel.build/rules/lib/globals/module#bazel_dep) in `rules_haskell`'s own [`MODULE.bazel`](https://bazel.build/external/module), your workspace chooses whichever C toolchain fits your build environment:

| Toolchain option | Host C packages needed? | Extra configuration | Best for |
|---|---|---|---|
| `hermetic_cc_toolchain` (`zig cc`) | No | `/tmp` cache mount on Linux | Minimal-setup local and CI builds |
| `toolchains_llvm` (Clang + `mold` or `lld`) | No (uses Debian `>= 10` sysroot) | None | Workspaces standardized on LLVM and Clang |
| System or container GCC / Clang | Yes (host or build container) | `-supports_start_end_lib` with GNU `ld.bfd` | Controlled build containers and [remote execution](https://bazel.build/remote/rbe) |

### Option A: Use `hermetic_cc_toolchain` (`zig cc`) with no host C packages

To build without host `gcc`, `clang`, `binutils`, or `libc6-dev`, register `hermetic_cc_toolchain` in `MODULE.bazel`. It downloads a self-contained Zig C/C++ compiler along with bundled `glibc` headers and link stubs:

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

Add the Zig cache directory mount to [`.bazelrc`](https://bazel.build/run/bazelrc) so `zig cc` reuses its compiled `libc` startup objects across [sandboxed](https://bazel.build/docs/sandboxing) actions:

```ini
build:linux --repo_env=HERMETIC_CC_TOOLCHAIN_CACHE_PREFIX=/tmp/zig-cc-cache
build:linux --sandbox_add_mount_pair=/tmp
```

> **Warning:** Don't omit the explicit `gnu.2.32` entries above. Registering `@zig_sdk//toolchain/...` alone selects `gnu.2.17` alphabetically, which fails for two reasons:
>
> 1. Official GHC `deb10` binary distributions reference `glibc` `2.27` and `2.28` symbols (`memfd_create`, `statx`, `fcntl64`).
> 2. BCR `gmp` and `m4` check `<sys/single_threaded.h>` under Zig, which requires `glibc >= 2.32`.
>
> Listing `linux_amd64_gnu.2.32` and `linux_arm64_gnu.2.32` first satisfies both requirements while keeping compiled binaries runnable across Debian 12 (`glibc` 2.36), Ubuntu 22.04 (2.35), Ubuntu 24.04 (2.39), and Rocky Linux 9 (2.34).

### Option B: Use `toolchains_llvm` (Clang, `mold` or `lld`, and a sysroot)

If your workspace uses `toolchains_llvm` with a Debian `>= 10` (`glibc >= 2.28`) sysroot (a directory tree containing target Linux headers and `libc` libraries), you can build with Clang without adding `/tmp` sandbox mounts to `.bazelrc`:

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

Flags configured on `toolchains_llvm`'s [`cc_toolchain`](https://bazel.build/reference/be/c-cpp#cc_toolchain)—including `--sysroot`, `--target`, `-B`, `-resource-dir`, `-fuse-ld`, and `--ld-path`—are forwarded automatically to `ghc_cc_wrapper` through `RULES_HASKELL_CC_EXTRA_ARGS`.

### Option C: Use a system or remote-execution GCC or Clang toolchain

If you omit both `hermetic_cc_toolchain` and `toolchains_llvm`, `rules_cc` detects the host or remote-execution container's GCC or Clang toolchain (see `examples/system_cc_toolchain`). Because GHC's hardcoded `lib/settings` paths are sanitized (`/usr/bin/gcc` becomes `/nonexistent/gcc`) and Bazel passes every tool path and `-B` search directory explicitly from `@bazel_tools//tools/cpp:toolchain_type`, GHC invokes the exact `cc`, `ar`, and `ld` configured by Bazel even under [`--incompatible_strict_action_env`](https://bazel.build/reference/command-line-reference#param-no-incompatible-strict-action-env).

On Linux hosts using GNU `ld.bfd`, disable `supports_start_end_lib` in `.bazelrc` via [`--features`](https://bazel.build/reference/command-line-reference#param-features) and [`--host_features`](https://bazel.build/reference/command-line-reference#param-host-features) so C and C++ dependencies link `.a` archives instead of `--start-lib`/`--end-lib` object lists:

```ini
build:linux --features=-supports_start_end_lib
build:linux --host_features=-supports_start_end_lib
```

## How `ghc_cc_wrapper` translates GHC flags for C toolchains

GHC invokes its C compiler and linker using older GCC-style flags that Clang, `lld`, and `zig cc` either reject or interpret differently. Instead of running a Python script on every compile or link action, `rules_haskell` compiles a small C11 adapter (`ghc_cc_wrapper`, built from `haskell/private/cc_wrapper.c`) that normalizes arguments before executing the real C compiler:

- **Strips wrapper environment variables:** Clears Bazel's [`RUNFILES_DIR`](https://bazel.build/extending/rules#runfiles), `RUNFILES_MANIFEST_FILE`, and `RUNFILES_MANIFEST_ONLY` from subprocesses so tools don't confuse wrapper runfiles with target inputs.
- **Normalizes shared-library name flags:** Rewrites Solaris/GCC `-Wl,-h,<soname>` flags into standard `-Wl,-soname,<soname>`, including inside `@args` response files (temporary files GHC uses for long command lines).
- **Adapts linker and PIC flags for `lld` and `zig cc`:** Removes `-fuse-ld=gold` (deprecated or absent on `lld` and `zig cc`), rewrites `-fno-PIC` to `-fPIC`, and creates temporary `.o` symlinks for `.dyn_o` and `.p_o` object files when `zig cc` checks file extensions.
- **Prevents C++ header shadowing:** Passes `-nostdinc++` on C, assembler, and linker calls so C++ standard library headers (such as `<version>`) don't shadow C headers or disrupt `<features.h>` and `_GNU_SOURCE` include ordering in `hsc2hs` and `CApiFFI`.

For a detailed walkthrough of `ghc_cc_wrapper`, see [Hermeticity and toolchain](../internals/hermeticity.md).
