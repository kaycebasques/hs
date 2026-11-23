# `examples/haddock` — Haddock HTML, Hyperlinked Source, QuickJump & Cross-Target Linking

Minimal standalone Bazel 9 workspace demonstrating `hs_haddock`: HTML module pages, `--prologue`, syntax-highlighted hyperlinked source (`src/`), QuickJump search index (`doc-index.json`), Hoogle output (`hoogle = True`), `hidden_modules` filtering, and cross-target `.haddock` interface linking (`haddock_deps`).

## Build & Test

```bash
bazel build //:core_haddock //:app_haddock
bazel test //...
```
