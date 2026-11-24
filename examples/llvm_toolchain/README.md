# `examples/llvm_toolchain`: `toolchains_llvm` (Clang, `mold`, and Debian sysroot)

Use this standalone Bazel 9 workspace to pair `rules_haskell` with `toolchains_llvm` (`llvm_version = "22.1.8"` and the catalogued `mold` `2.42.1` linker) and a SHA-256-pinned Debian 11 (`bullseye`, `glibc 2.31`) sysroot. You don't need `hermetic_cc_toolchain`, a `/tmp` [sandbox](https://bazel.build/docs/sandboxing) mount, or host compilers and `-dev` packages.

To explore other supported features and toolchain setups, browse the [examples index](../README.md).

> **Note:** Why does this example set `linker = {"linux-x86_64": "mold", ...}`? Upstream LLVM Linux binary archives dynamically link `ld.lld` against `libxml2.so.2`, which isn't present on bare containers or newer Debian and Ubuntu distros shipping `libxml2.so.16`. By contrast, `toolchains_llvm`'s catalogued `mold` binary dynamically depends only on base `glibc`.

## Run and test

From `examples/llvm_toolchain`, run the test suite and demo binary with [`bazel test`](https://bazel.build/docs/user-manual#running-tests) and [`bazel run`](https://bazel.build/docs/user-manual#running-executables):

```bash
bazel test //...
bazel run //:llvm_demo
```
