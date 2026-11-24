# `examples/quickstart`: core rules and boot libraries (GHC `9.10.3`)

Use this standalone Bazel 9 workspace to build your first targets with `hs_library`, `hs_binary`, `hs_test`, `hs_toolchain_library`, and `@hs_boot` on the default GHC `9.10.3` toolchain. It produces portable Linux executables with statically linked `libgmp.a` and verifies their runtime dependencies.

To explore other supported features, browse the [examples index](../README.md).

## Run and test

From `examples/quickstart`, run the test suite and sample binary with [`bazel test`](https://bazel.build/docs/user-manual#running-tests) and [`bazel run`](https://bazel.build/docs/user-manual#running-executables):

```bash
bazel test //...
bazel run //:hello -- "World"
```
