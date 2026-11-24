# `examples/system_cc_toolchain`: system GCC or Clang C toolchain (`rules_cc`)

Use this standalone Bazel 9 workspace to pair `rules_haskell` with Bazel `rules_cc`'s auto-detected host GCC or Clang toolchain—without adding `hermetic_cc_toolchain` or `toolchains_llvm` to [`MODULE.bazel`](https://bazel.build/external/module). To explore other supported features and toolchain setups, browse the [examples index](../README.md).

> **Note:** This setup requires a host C compiler (`gcc` or `clang`) and `libc` development headers (`libc6-dev` or `glibc-devel`). If you want builds that don't depend on host compilers, use [`examples/quickstart`](../quickstart/README.md) (`hermetic_cc_toolchain`) or [`examples/llvm_toolchain`](../llvm_toolchain/README.md) (`toolchains_llvm` with a Debian sysroot) instead.

## Run and test

From `examples/system_cc_toolchain`, run the test suite and demo binary with [`bazel test`](https://bazel.build/docs/user-manual#running-tests) and [`bazel run`](https://bazel.build/docs/user-manual#running-executables):

```bash
bazel test //...
bazel run //:system_cc_demo
```
