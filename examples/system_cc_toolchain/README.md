# `examples/system_cc_toolchain` — System GCC / Clang C Toolchain (`rules_cc`)

Minimal standalone Bazel 9 workspace pairing `rules_hs` with Bazel `rules_cc`'s auto-detected host GCC or Clang toolchain (with no `hermetic_cc_toolchain` or `toolchains_llvm` dependency in `MODULE.bazel`).

> **Note**: Requires a host C compiler (`gcc` or `clang`) and `libc` development headers (`libc6-dev` / `glibc-devel`). For builds on machines with zero host compilers installed, see [`examples/quickstart`](../quickstart/README.md) (`hermetic_cc_toolchain`) or [`examples/llvm_toolchain`](../llvm_toolchain/README.md) (`toolchains_llvm` + Debian sysroot).

## Run & Test

```bash
bazel test //...
bazel run //:system_cc_demo
```
