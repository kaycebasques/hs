# `examples/c_interop`: C, C++, assembly, and Bazel Central Registry `cc_deps`

Use this standalone Bazel 9 workspace to see how you can call C, C++, and assembly code from Haskell targets and link external C libraries. For conceptual background and toolchain details, read [C FFI and toolchains](../../docs/content/guide/c-interop-and-toolchains.md) or browse the [examples index](../README.md).

- **C and `CApiFFI` foreign imports:** Call standard `foreign import ccall` functions and header-checked `CApiFFI` bindings (including `#define` constants and `static inline` functions).
- **Inline `c_sources`:** Compile C (`.c`), C++17 (`.cc`), preprocessed assembly (`.S`), and raw assembly (`.s`) directly inside Haskell targets.
- **External `cc_deps`:** Link both an in-repository [`cc_library`](https://bazel.build/reference/be/c-cpp#cc_library) (`:checksum_cc`) and a [Bazel Central Registry](https://bazel.build/external/registry#bazel-central-registry) `cc_library` (`@zlib//:zlib`).

## Run and test

From `examples/c_interop`, run the test suite and demo binary with [`bazel test`](https://bazel.build/docs/user-manual#running-tests) and [`bazel run`](https://bazel.build/docs/user-manual#running-executables):

```bash
bazel test //...
bazel run //:c_interop_demo
```
