# `examples/llvm_toolchain` — `toolchains_llvm` (Clang + `mold` + Debian Sysroot)

Minimal standalone Bazel 9 workspace pairing `rules_hs` with `toolchains_llvm` (`llvm_version = "22.1.8"`, catalogued `mold` `2.42.1` linker) and a SHA-256-pinned Debian 11 (`bullseye`, `glibc 2.31`) sysroot — requiring no `hermetic_cc_toolchain`, no `/tmp` sandbox mount, and no host compilers or `-dev` packages.

> **Why `linker = {"linux-x86_64": "mold", ...}`?** Upstream LLVM Linux binary archives dynamically link `ld.lld` against `libxml2.so.2` (absent on bare containers and newer Debian/Ubuntu distros shipping `libxml2.so.16`), whereas `toolchains_llvm`'s catalogued `mold` linker binary depends only on base `glibc`.

## Run & Test

```bash
bazel test //...
bazel run //:llvm_demo
```
