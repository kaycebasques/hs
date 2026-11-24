# `examples/ghc_9_12`: official GHC `9.12.4` toolchain

Use this standalone Bazel 9 workspace to pin GHC `9.12.4` with `hs.toolchain(ghc_version = "9.12.4")` instead of the default GHC `9.10.3`. It exercises GHC 9.12's `file-io` boot package, the `GHC2024` language edition, `hs_haddock` API documentation, and static `libgmp.a` binary linking.

For the default GHC `9.10.3` setup, see [`examples/quickstart`](../quickstart/README.md). For toolchain configuration options, read [Extensions and providers](../../docs/content/reference/extensions-and-providers.md) or browse the [examples index](../README.md).

## Run and test

From `examples/ghc_9_12`, run the test suite and info binary with [`bazel test`](https://bazel.build/docs/user-manual#running-tests) and [`bazel run`](https://bazel.build/docs/user-manual#running-executables):

```bash
bazel test //...
bazel run //:ghc_9_12_info
```
