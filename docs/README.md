# `rules_hs` Documentation (`//docs`)

`//docs` builds the `rules_hs` documentation site using the canonical, vanilla Haskell documentation stack — **100% hermetically on Bazel 9 via `rules_hs` itself** (zero Python, zero Node.js, zero Nix, and strictly `dev_dependency = True` in `MODULE.bazel`):

1. **Vanilla Hakyll + Pandoc + Skylighting** (`docs/site.hs` -> `//docs:docs_gen`): compiles pure GitHub-flavored Markdown prose, guides, Starlark references, and architecture internals into static HTML with Skylighting syntax highlighting and Pandoc's native table of contents.
2. **GHC Haddock** (`hs_haddock` -> `//tools/lock:lock_haddock`): invokes GHC's `$ORIGIN`-staged `bin/haddock-ghc-<ver>` to generate Haskell module API documentation, QuickJump `doc-index.json`, and hyperlinked source (`src/*.html`), mounted into `//docs:site` at `/haddock/lock/`.

---

## Quick Commands

### Build the Static Site & Haddock API Docs

```bash
bazel build //docs:site
# Or build individual Haddock bundles directly:
bazel build //tools/lock:lock_haddock
```

Outputs a self-contained static HTML tree at `bazel-bin/docs/site/` with relativized URLs (deployable at `/`, any subpath `/rules_hs/`, or local filesystem), dual light/dark Skylighting syntax highlighting (`static/syntax.css`), responsive 3-column layout (`static/style.css` + `static/docs.js`), and mounted Haddock documentation (`haddock/lock/index.html`).

### Preview Locally Over HTTP

```bash
bazel run //docs:serve
# Custom port or bind address:
bazel run //docs:serve -- --port 8080 --host 127.0.0.1
```

`//docs:serve` (`docs/app/ServeMain.hs`) is a pure-Haskell HTTP/1.1 static server built on `network` sockets serving `bazel-bin/docs/site/` at `http://127.0.0.1:8000/`.

### Run Documentation & Link-Check Tests

```bash
bazel test //docs/...
```

- **`//docs:link_check_test`** (`hs_test`, `docs/test/LinkCheckTest.hs`): parses every generated `.html` file across both the Hakyll pages and mounted `haddock/lock/` pages using `tagsoup` and verifies that every internal `<a href="...">` target file and `#id` fragment resolves cleanly.
- **`//docs:site_test`** (`sh_test`, `docs/test/site_test.sh`): verifies all expected Hakyll + Haddock outputs (including QuickJump `doc-index.json` and hyperlinked `src/*.html`), asserts via `readelf -d` that `//docs:docs_gen` and `//docs:serve` dynamically link **only** base glibc (`libc.so.6`, `libm.so.6`, `libdl.so.2`, `libpthread.so.0`), executes `--help` under `env -i PATH=/nonexistent`, and smoke-tests `//docs:serve` over loopback TCP for both `/internals/docs-engine.html` and `/haddock/lock/index.html`.

---

## Authoring Documentation Pages

Pages under `docs/content/**/*.md` are written in **100% standard GitHub/Pandoc Markdown** with a YAML frontmatter block:

```yaml
---
title: "Full Page Title"
description: "Concise one-sentence summary shown beneath the page title."
section: overview | guide | reference | internals
nav_title: "Short Sidebar Label"
order: 10
---
```

- **Sections** appear in canonical order in the left sidebar across all 18 pages:
  1. `overview` ("Overview"): `index.md`
  2. `guide` ("User Guide"): `quickstart.md`, `hackage.md`, `c-interop-and-toolchains.md`, `language-rts-runfiles-th.md`, `showcase-size.md`, `troubleshooting-and-migration.md`
  3. `reference` ("API & CLI Reference"): `rules.md`, `extensions-and-providers.md`, `lock-cli.md`
  4. `internals` ("Internals & Architecture"): `overview.md`, `rulesets-comparison.md`, `hermeticity.md`, `providers-and-actions.md`, `ecosystem-and-hackage.md`, `cross-os-and-platforms.md`, `docs-engine.md`, `dependencies.md`
- **Links**: use ordinary relative Markdown links (`[Quickstart](../guide/quickstart.md)` or `[`hs_library`](../reference/rules.md#hs_library)`). `docs/site.hs` rewrites relative `.md` targets to `.html` during Pandoc compilation, so links work both when browsing raw `.md` files on GitHub and in the built site.
- **Callouts**: use standard Markdown blockquotes (`> **Note:** ...`, `> **Tip:** ...`, `> **Important:** ...`).
- **Haskell API docs**: document Haskell modules with standard `-- |` Haddock comments and expose an `hs_haddock` target; mount it in `docs/BUILD.bazel` via the `haddocks` attribute of `hs_docs_site`.

---

## Regenerating `docs/hackage.lock.json`

`docs/hackage.lock.json` is generated hermetically by `rules_hs`'s boot-only lockfile generator (`//tools/lock:lock`):

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
