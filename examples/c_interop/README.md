# `examples/c_interop` — C, C++, Assembly & Bazel Central Registry `cc_deps`

Minimal standalone Bazel 9 workspace demonstrating:
- Standard `foreign import ccall` and header-checked `CApiFFI` (`#define` constants and `static inline` functions)
- Inline `c_sources`: C (`.c`), C++17 (`.cc`), preprocessed assembly (`.S`), and raw assembly (`.s`)
- `cc_deps`: both an in-repository `cc_library` (`:checksum_cc`) and a Bazel Central Registry `cc_library` (`@zlib//:zlib`)

## Run & Test

```bash
bazel test //...
bazel run //:c_interop_demo
```
