# `rules_haskell` Documentation (`//docs`)

[![Pages](https://github.com/kaycebasques/rules_haskell/actions/workflows/pages.yml/badge.svg)](https://github.com/kaycebasques/rules_haskell/actions/workflows/pages.yml)
[![Documentation](https://img.shields.io/badge/docs-kaycebasques.github.io%2Frules__haskell-blue)](https://kaycebasques.github.io/rules_haskell/)

**Live site**: [https://kaycebasques.github.io/rules_haskell/](https://kaycebasques.github.io/rules_haskell/) · **Mounted Haddock API**: [https://kaycebasques.github.io/rules_haskell/haddock/lock/index.html](https://kaycebasques.github.io/rules_haskell/haddock/lock/index.html)

`//docs` builds the `rules_haskell` documentation site on Bazel 9 using `rules_haskell` itself with a minimal, canonical Haskell documentation setup (all docs dependencies in `MODULE.bazel` are `dev_dependency = True`):

1. **Minimal Hakyll (`docs/site.hs` → `//docs:docs_gen`)**: standard `hakyll-init`-style static site generator (`pandocCompiler`, `defaultContext`, `templates/default.html`, `css/default.css`, `relativizeUrls`, and relative `.md` → `.html` URL rewriting).
2. **GHC Haddock (`hs_haddock` → `//tools/lock:lock_haddock`)**: bundled GHC Haddock API docs mounted into `//docs:site` at `/haddock/lock/`.
3. **Local preview server (`docs/serve.hs` → `//docs:serve`)**: minimal static HTTP server using `wai-app-static` and `warp`.

## Commands

```bash
# Build the static HTML site (with mounted /haddock/lock/ API docs)
bazel build //docs:site

# Preview locally (http://127.0.0.1:8000 by default)
bazel run //docs:serve
bazel run //docs:serve -- --port 8080 --host 127.0.0.1

# Run the documentation smoke test
bazel test //docs/...
```

## Authoring Pages

Pages under `docs/content/**/*.md` use standard Markdown with YAML frontmatter containing at least `title:`:

```yaml
---
title: "Page Title"
---
```

Use ordinary relative `.md` links (`[Quickstart](guide/quickstart.md)`); `docs/site.hs` rewrites them to `.html` so links work both on GitHub and in the built site.

## Regenerating `docs/hackage.lock.json`

```bash
bazel run //tools/lock:lock -- \
  --snapshot lts-24.67 \
  --package hakyll \
  --flag hakyll:checkexternal=false \
  --flag hakyll:watchserver=false \
  --flag hakyll:previewserver=false \
  --flag pandoc:embed_data_files=true \
  --flag citeproc:embed_data_files=true \
  --flag zlib:bundled-c-zlib=true \
  --flag zlib:pkg-config=false \
  --flag digest:pkg-config=false \
  --output "$PWD/docs/hackage.lock.json"
```
