# `examples/llvm_toolchain`: `toolchains_llvm` (Clang, `mold`, and Debian sysroot)

Use this standalone Bazel 9 workspace to pair `rules_haskell` with `toolchains_llvm` (`llvm_version = "20.1.8"` and the catalogued `mold` `3.0.0` linker) and a SHA-256-pinned Debian 11 (`bullseye`, `glibc 2.31`) sysroot. You don't need `hermetic_cc_toolchain`, a `/tmp` [sandbox](https://bazel.build/docs/sandboxing) mount, or host compilers and `-dev` packages.

To explore other supported features and toolchain setups, browse the [examples index](../README.md).

> **Note:** Why does this example pin `llvm_version = "20.1.8"`, `mold` `3.0.0`, and the `3bdb3503` / `286feb74` Debian 11 sysroot snapshots?
> - **LLVM `20.1.8`:** Upstream Linux archives for LLVM `20.1.8` statically link the C++ standard library into `clang`, `llvm-ar`, and `llvm-objcopy` (no `libstdc++.so.6` / `GLIBCXX_3.4.30` requirement, max `GLIBC_2.34`), so the toolchain runs on Rocky Linux 9 as well as Debian 12 and Ubuntu 24.04.
> - **`mold` `3.0.0`:** Drops both `ld.lld`'s `libxml2.so.2` dependency and `mold` `2.x`'s `libatomic.so.1` dependency so the linker runs in minimal containers with only base `glibc` and `libgcc_s.so.1`.
> - **Unstripped Debian 11 sysroot:** Newer Chromium sysroot archives strip non-dynamic ELF sections from `libc-2.31.so` while leaving `.dynsym` entries pointing to the old section indices, which triggers a bounds-check panic in `mold` `3.0.0` during `-no-pie` copy relocations. These Debian 11 (`glibc 2.31`) snapshots retain intact ELF section headers.

## Run and test

From `examples/llvm_toolchain`, run the test suite and demo binary with [`bazel test`](https://bazel.build/docs/user-manual#running-tests) and [`bazel run`](https://bazel.build/docs/user-manual#running-executables):

```bash
bazel test //...
bazel run //:llvm_demo
```
