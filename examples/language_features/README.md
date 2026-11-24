# `examples/language_features`: language editions, `.lhs`, `.hs-boot`, RTS, runfiles, and Template Haskell

Use this standalone Bazel 9 workspace to explore isolated examples of Haskell language editions, GHC runtime options, Bazel [runfiles](https://bazel.build/extending/rules#runfiles), and Template Haskell in `rules_haskell`. To explore other supported features, browse the [examples index](../README.md).

- [`editions/`](editions/BUILD.bazel) — `Haskell98`, `Haskell2010`, `GHC2021` (default), and `GHC2024` language editions.
- [`modules/`](modules/BUILD.bazel) — `default_extensions`, `ghc_opts`, `cpp_options`, and `hidden_modules`.
- [`mutual_recursion/`](mutual_recursion/BUILD.bazel) — `.hs-boot` mutually recursive modules.
- [`literate/`](literate/BUILD.bazel) — `.lhs` literate Haskell (Bird-style `>` and LaTeX `\begin{code}`).
- [`rts/`](rts/BUILD.bazel) — Single-threaded (`threaded = False`) and multi-core (`threaded = True`, `-with-rtsopts=-N2`) GHC runtime configurations.
- [`runfiles/`](runfiles/BUILD.bazel) — Bazel `data` runfiles accessed at both compile time and runtime.
- [`template_haskell/`](template_haskell/BUILD.bazel) — `TemplateHaskellQuotes`, cross-library `TemplateHaskell` splices, and compile-time file embedding with `@hackage//:file-embed`.

## Run all tests

From `examples/language_features`, run the full test suite with [`bazel test`](https://bazel.build/docs/user-manual#running-tests):

```bash
bazel test //...
```
