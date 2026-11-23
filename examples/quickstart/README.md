# `examples/quickstart` — Core Rules & Boot Libraries (GHC `9.10.3`)

Minimal standalone Bazel 9 workspace exercising `hs_library`, `hs_binary`, `hs_test`, `hs_toolchain_library`, `@hs_boot`, default GHC `9.10.3`, and portable Linux binaries with statically linked `libgmp.a`.

## Run & Test

```bash
bazel test //...
bazel run //:hello -- "World"
```
