# `examples/hackage`: Hackage lockfiles, `hackage.override`, and Cabal features

Use this standalone Bazel 9 workspace to pin and build third-party Hackage packages with `@rules_haskell//tools/lock:lock`, `hackage.from_lock`, and `hackage.override`. For a complete walkthrough of lockfile workflows and `Setup.hs` handling, read [Hackage and lockfiles](../../docs/content/guide/hackage.md) or browse the [examples index](../README.md).

- **`hackage.override` in [`MODULE.bazel`](https://bazel.build/external/module):** Attach [Bazel Central Registry](https://bazel.build/external/registry#bazel-central-registry) `@zlib//:zlib` (`extra_cc_deps`) along with `extra_cc_options`, `extra_cpp_options`, and `extra_ghc_opts` to `zlib` (`bundled-c-zlib=false`), and pass `configure_args` to `network`.
- **Cabal build types:** Build `Simple` (`split`), `Configure` (`network`, `unix-time`), and `Custom` `cabal-doctest` packages automatically converted to `Simple` (`xml-conduit`).
- **Cabal components and code generation:** Exercise C-only packages (`libyaml-clib`, `//vendored_cabal:tiny_clib`), internal sublibraries (`@hackage//:attoparsec__attoparsec-internal`), Cabal 3.0 public sublibraries (`@hackage//:tar__tar-internal`), `reexported-modules` (`ansi-terminal`, `//vendored_cabal:vendored_demo`), `Paths_<pkg>` and compile-time `data-files`, `.hsc` (`hsc2hs`), and source-bootstrapped `.x` (`alex`) and `.y`/`.ly` (`happy`) files (`pretty-show`, `//vendored_cabal:expr_grammar`).

## Run and test

From `examples/hackage`, run the test suite and demo binary with [`bazel test`](https://bazel.build/docs/user-manual#running-tests) and [`bazel run`](https://bazel.build/docs/user-manual#running-executables):

```bash
bazel test //...
bazel run //:hackage_demo
```

## Regenerate `hackage.lock.json`

To refresh the pinned lockfile from `examples/hackage`, run the lock generator:

```bash
bazel run @rules_haskell//tools/lock:lock -- \
  --snapshot lts-24.67 \
  --package split --package network --package unix-time \
  --package xml-conduit --package libyaml --package zlib \
  --package attoparsec --package tar --package ansi-terminal \
  --package pretty-show --package file-embed \
  --flag zlib:bundled-c-zlib=false \
  --flag zlib:pkg-config=false \
  --output "$PWD/hackage.lock.json"
```
