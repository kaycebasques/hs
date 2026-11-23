# `examples/hackage` — Hackage Lockfiles, `hackage.override` & Cabal Features

Minimal standalone Bazel 9 workspace exercising `@rules_hs//tools/lock:lock`, `hackage.from_lock`, `hackage.override`, and all supported Cabal package features:

- **`hackage.override` (`MODULE.bazel`)**: Attaches BCR `@zlib//:zlib` (`extra_cc_deps`), `extra_cc_options`, `extra_cpp_options`, and `extra_ghc_opts` to `zlib` (`bundled-c-zlib=false`), plus `configure_args` to `network`
- **Cabal build types**: `Simple` (`split`), `Configure` (`network`, `unix-time`), and `Custom` `cabal-doctest` normalized to `Simple` (`xml-conduit`)
- **Cabal components & codegen**: C-only packages (`libyaml-clib`, `//vendored_cabal:tiny_clib`), internal sublibraries (`@hackage//:attoparsec__attoparsec-internal`), Cabal 3.0 public sublibraries (`@hackage//:tar__tar-internal`), `reexported-modules` (`ansi-terminal`, `//vendored_cabal:vendored_demo`), `Paths_<pkg>` & compile-time `data-files`, `.hsc` (`hsc2hs`), and source-bootstrapped `.x` (`alex`) and `.y`/`.ly` (`happy`) (`pretty-show`, `//vendored_cabal:expr_grammar`)

## Regenerate Lockfile, Run & Test

```bash
bazel run @rules_hs//tools/lock:lock -- \
  --snapshot lts-24.67 \
  --package split --package network --package unix-time \
  --package xml-conduit --package libyaml --package zlib \
  --package attoparsec --package tar --package ansi-terminal \
  --package pretty-show --package file-embed \
  --flag zlib:bundled-c-zlib=false \
  --flag zlib:pkg-config=false \
  --output "$PWD/hackage.lock.json"

bazel test //...
bazel run //:hackage_demo
```
