# `rules_haskell` Documentation (`//docs`)

[![Pages](https://github.com/kaycebasques/rules_haskell/actions/workflows/pages.yml/badge.svg)](https://github.com/kaycebasques/rules_haskell/actions/workflows/pages.yml)
[![Documentation](https://img.shields.io/badge/docs-kaycebasques.github.io%2Frules__haskell-blue)](https://kaycebasques.github.io/rules_haskell/)

**Live site**: [**https://kaycebasques.github.io/rules_haskell/**](https://kaycebasques.github.io/rules_haskell/) · **Mounted Haddock API**: [**https://kaycebasques.github.io/rules_haskell/haddock/lock/index.html**](https://kaycebasques.github.io/rules_haskell/haddock/lock/index.html)

`//docs` builds the `rules_haskell` documentation site on Bazel 9 using `rules_haskell` itself. It does not use Python, Node.js, or Nix, and all documentation dependencies in `MODULE.bazel` are marked `dev_dependency = True` so downstream projects depending on `rules_haskell` never download them:

1. **Vanilla Hakyll + Pandoc + Skylighting** (`docs/site.hs` -> `//docs:docs_gen`): compiles standard GitHub-flavored Markdown guides, Starlark API references, and architecture pages into static HTML with Skylighting syntax highlighting and Pandoc's built-in table of contents.
2. **GHC Haddock** (`hs_haddock` -> `//tools/lock:lock_haddock`): runs GHC's staged `bin/haddock-ghc-<ver>` binary inside Bazel's sandbox to generate Haskell module API documentation, QuickJump search (`doc-index.json`), and hyperlinked source views (`src/*.html`), mounted into `//docs:site` at `/haddock/lock/`.

> **New to Bazel Rulesets or Haskell?** Start with these background guides and code walkthroughs:
> - **[Bazel Ruleset Primer](content/internals/bazel-rules-primer.md)** — Bazel ruleset authoring from first principles (`MODULE.bazel` `dev_dependency`, Loading/Analysis/Execution phases, lazy Bzlmod hubs, providers, transitive sets, directory outputs, and `CcInfo`).
> - **[Haskell & GHC Primer](content/internals/haskell-and-ghc-primer.md)** — GHC, Cabal, Hackage, Stackage, boot libraries, `.hi` compiler interfaces, RTS C linking, `gmp` and `libtinfo`, Template Haskell, and Haddock.
> - **[Walking Through `docs/site.hs`](content/internals/docs-engine.md#site-hs-walkthrough)** & **[Dependency Decisions](content/internals/dependencies.md#module-bazel-anatomy)** — Line-by-line plain-English guide to `docs/site.hs` and every dependency in `MODULE.bazel` and `docs/hackage.lock.json`.

---

## Quick Commands

### Build the Static Site & Haddock API Docs

```bash
bazel build //docs:site
# Or build individual Haddock bundles directly:
bazel build //tools/lock:lock_haddock
```

Outputs a self-contained static HTML directory tree at `bazel-bin/docs/site/` with relative URLs (deployable at `/`, any subpath such as `/rules_haskell/`, or directly from disk), light and dark Skylighting syntax highlighting (`static/syntax.css`), a responsive 3-column layout (`static/style.css` + `static/docs.js`), and mounted Haddock documentation (`haddock/lock/index.html`).

### Preview Locally Over HTTP

```bash
bazel run //docs:serve
# Custom port or bind address:
bazel run //docs:serve -- --port 8080 --host 127.0.0.1
```

`//docs:serve` (`docs/app/ServeMain.hs`) is a small Haskell HTTP/1.1 static file server built on `network` TCP sockets that serves `bazel-bin/docs/site/` at `http://127.0.0.1:8000/`.

### Run Documentation & Link-Check Tests

```bash
bazel test //docs/...
```

- **`//docs:link_check_test`** (`hs_test`, `docs/test/LinkCheckTest.hs`): parses every generated `.html` file across both the Hakyll pages and mounted `haddock/lock/` pages using `tagsoup` and verifies that every internal `<a href="...">` target file and `#id` anchor resolves cleanly.
- **`//docs:site_test`** (`sh_test`, `docs/test/site_test.sh`): checks all expected Hakyll and Haddock outputs (including QuickJump `doc-index.json` and hyperlinked `src/*.html`), verifies via `readelf -d` that `//docs:docs_gen` and `//docs:serve` dynamically link only base `glibc` (`libc.so.6`, `libm.so.6`, `libdl.so.2`, `libpthread.so.0`), runs `--help` under `env -i PATH=/nonexistent`, and tests `//docs:serve` over loopback TCP for both `/internals/docs-engine.html` and `/haddock/lock/index.html`.

### Continuous Deployment (GitHub Pages)

[`.github/workflows/pages.yml`](../.github/workflows/pages.yml) builds `//docs:site` and `//tools/lock:lock_haddock`, runs `//docs:link_check_test` and `//docs:site_test`, copies `bazel-bin/docs/site` into a dereferenced artifact, and deploys to [**https://kaycebasques.github.io/rules_haskell/**](https://kaycebasques.github.io/rules_haskell/) on push to `main` (and on manual `workflow_dispatch`).

---

## Authoring Documentation Pages

Pages under `docs/content/**/*.md` are written in standard GitHub/Pandoc Markdown with a YAML frontmatter block:

```yaml
---
title: "Full Page Title"
description: "Concise one-sentence summary shown beneath the page title."
section: overview | guide | reference | internals
nav_title: "Short Sidebar Label"
order: 10
---
```

- **Sections** appear in fixed order in the left sidebar across all 20 pages:
  1. `overview` ("Overview"): `index.md`
  2. `guide` ("User Guide"): `quickstart.md`, `hackage.md`, `c-interop-and-toolchains.md`, `language-rts-runfiles-th.md`, `showcase-size.md`, `troubleshooting-and-migration.md`
  3. `reference` ("API & CLI Reference"): `rules.md`, `extensions-and-providers.md`, `lock-cli.md`
  4. `internals` ("Internals & Architecture"): `bazel-rules-primer.md`, `haskell-and-ghc-primer.md`, `overview.md`, `rulesets-comparison.md`, `hermeticity.md`, `providers-and-actions.md`, `ecosystem-and-hackage.md`, `cross-os-and-platforms.md`, `docs-engine.md`, `dependencies.md`
- **Links**: use ordinary relative Markdown links (`[Quickstart](../guide/quickstart.md)` or `[`hs_library`](../reference/rules.md#hs_library)`). `docs/site.hs` rewrites relative `.md` targets to `.html` during Pandoc compilation, so links work both when reading raw `.md` files on GitHub and in the built site.
- **Callouts**: use standard Markdown blockquotes (`> **Note:** ...`, `> **Tip:** ...`, `> **Important:** ...`).
- **Haskell API docs**: document Haskell modules with standard `-- |` Haddock comments and expose an `hs_haddock` target; mount it in `docs/BUILD.bazel` via the `haddocks` attribute of `hs_docs_site`.

---

## Regenerating `docs/hackage.lock.json`

`docs/hackage.lock.json` is generated by `rules_haskell`'s lockfile CLI (`//tools/lock:lock`):

```bash
bazel run //tools/lock:lock -- \
  --snapshot lts-24.67 \
  --package hakyll \
  --package pandoc \
  --package pandoc-types \
  --package skylighting \
  --package skylighting-core \
  --package tagsoup \
  --package network \
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
