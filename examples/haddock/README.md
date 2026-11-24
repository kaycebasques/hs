# `examples/haddock`: Haddock HTML, hyperlinked source, QuickJump, and cross-target linking

Use this standalone Bazel 9 workspace to generate Haskell API documentation with `hs_haddock`. It builds HTML module pages, `--prologue` intros, syntax-highlighted hyperlinked source (`src/`), QuickJump search indexes (`doc-index.json`), Hoogle output (`hoogle = True`), `hidden_modules` filtering, and cross-target `.haddock` interface links (`haddock_deps`).

For attribute defaults and options, see [`hs_haddock` in the Rules reference](../../docs/content/reference/rules.md#hs_haddock) or browse the [examples index](../README.md).

## Build and test

From `examples/haddock`, build both Haddock targets and run the verification tests with [`bazel test`](https://bazel.build/docs/user-manual#running-tests):

```bash
bazel build //:core_haddock //:app_haddock
bazel test //...
```
