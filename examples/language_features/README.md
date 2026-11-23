# `examples/language_features` — Language Editions, `.lhs`, `.hs-boot`, RTS, Runfiles & Template Haskell

Minimal, isolated examples for each language and runtime feature in `rules_haskell`:

- [`editions/`](editions/BUILD.bazel) — `Haskell98`, `Haskell2010`, `GHC2021` (default), and `GHC2024`
- [`modules/`](modules/BUILD.bazel) — `default_extensions`, `ghc_opts`, `cpp_options`, and `hidden_modules`
- [`mutual_recursion/`](mutual_recursion/BUILD.bazel) — `.hs-boot` mutually recursive modules
- [`literate/`](literate/BUILD.bazel) — `.lhs` literate Haskell (Bird-style `>` and LaTeX `\begin{code}`)
- [`rts/`](rts/BUILD.bazel) — single-threaded (`threaded = False`) and multi-core (`threaded = True`, `-with-rtsopts=-N2`) GHC runtime
- [`runfiles/`](runfiles/BUILD.bazel) — Bazel `data` runfiles accessed at both compile time and runtime
- [`template_haskell/`](template_haskell/BUILD.bazel) — `TemplateHaskellQuotes`, cross-library `TemplateHaskell` splices, and compile-time file embedding with `@hackage//:file-embed`

## Run All Tests

```bash
bazel test //...
```
