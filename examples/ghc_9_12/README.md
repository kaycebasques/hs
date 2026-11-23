# `examples/ghc_9_12` — Official GHC `9.12.4` Toolchain

Minimal standalone Bazel 9 workspace pinning `hs.toolchain(ghc_version = "9.12.4")`, using GHC 9.12's `file-io` boot package, `GHC2024`, `hs_haddock`, and static `libgmp.a` binary linking.

## Run & Test

```bash
bazel test //...
bazel run //:ghc_9_12_info
```
