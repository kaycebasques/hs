# `rules_haskell` documentation (`//docs`)

[![Pages](https://github.com/kaycebasques/rules_haskell/actions/workflows/pages.yml/badge.svg)](https://github.com/kaycebasques/rules_haskell/actions/workflows/pages.yml)
[![Documentation](https://img.shields.io/badge/docs-kaycebasques.github.io%2Frules__haskell-blue)](https://kaycebasques.github.io/rules_haskell/)

This guide shows you how to build, preview, test, and author the `rules_haskell` documentation site locally. If you're looking to read the docs instead, visit the [published documentation site](https://kaycebasques.github.io/rules_haskell/) or the [mounted `//tools/lock` Haddock API docs](https://kaycebasques.github.io/rules_haskell/haddock/lock/index.html).

You can build and serve the documentation site on Bazel 9 using `rules_haskell` itself—with no Python or Node.js required. All docs dependencies in [`MODULE.bazel`](https://bazel.build/external/module) are marked [`dev_dependency = True`](https://bazel.build/rules/lib/globals/module#bazel_dep), so downstream consumers don't pull them in:

1. **Hakyll site generator (`docs/site.hs` → `//docs:docs_gen`):** Renders Markdown pages using `pandocCompiler`, `defaultContext`, `templates/default.html`, `css/default.css`, `relativizeUrls`, and relative `.md` to `.html` URL rewriting.
2. **GHC Haddock (`hs_haddock` → `//tools/lock:lock_haddock`):** Mounts GHC's bundled Haddock API docs into `//docs:site` at `/haddock/lock/`.
3. **Local preview server (`docs/serve.hs` → `//docs:serve`):** Serves the built static site over HTTP using `wai-app-static` and `warp`.

## Build, preview, and test

Run these commands from the repository root using [`bazel build`](https://bazel.build/run/build), [`bazel run`](https://bazel.build/docs/user-manual#running-executables), and [`bazel test`](https://bazel.build/docs/user-manual#running-tests):

```bash
# Build the static HTML site (with mounted /haddock/lock/ API docs)
bazel build //docs:site

# Preview locally (http://127.0.0.1:8000 by default)
bazel run //docs:serve
bazel run //docs:serve -- --port 8080 --host 127.0.0.1

# Run the documentation smoke test
bazel test //docs/...
```

## Author documentation pages

Author pages under `docs/content/**/*.md` in standard Markdown following [`AGENTS.md`](../AGENTS.md), with YAML frontmatter containing at least `title:`:

```yaml
---
title: "Page title"
---
```

Use standard relative `.md` links (such as `[Quickstart](guide/quickstart.md)`). At build time, `docs/site.hs` rewrites `.md` links to `.html` so they work both on GitHub and on the published site.

## Regenerate `docs/hackage.lock.json`

Run the lock generator from the repository root to refresh the pinned Hackage dependencies for Hakyll and the preview server:

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
