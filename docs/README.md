# `rules_hs` Documentation Site & Engine

`//docs` contains `rules_hs`'s documentation static site generator and documentation suite. The engine is built in Haskell on top of **Hakyll + Pandoc + Skylighting** with a **Sphinx-inspired programmatic extension layer**, compiled and verified **100% hermetically by `rules_hs` itself** under Bazel 9 (zero Python, zero Node.js, zero Nix, and strictly `dev_dependency = True` in `MODULE.bazel`).

---

## Quick Commands

### Build the Static Site

```bash
bazel build //docs:site
```

Outputs a self-contained static HTML site directory at `bazel-bin/docs/site/` with relativized URLs (deployable at `/`, any subpath `/rules_hs/`, or local filesystem), adaptive light/dark Skylighting syntax highlighting (`static/syntax.css`), responsive 3-column UI (`static/style.css` + `static/docs.js`), and client-side instant search index (`search-index.json`).

### Preview Locally Over HTTP

```bash
bazel run //docs:serve
# Custom port or bind address:
bazel run //docs:serve -- --port 8080 --host 127.0.0.1
```

`//docs:serve` is a zero-Python, zero-Node pure-Haskell static HTTP server (`docs/app/ServeMain.hs` using `network`) serving the built `//docs:site` artifact at `http://127.0.0.1:8000/`.

### Run Documentation & Link-Check Tests

```bash
bazel test //docs/...
```

- **`//docs:engine_test`** (`hs_test`): Unit and end-to-end integration tests covering Sphinx-style fenced-div admonitions, GitHub blockquote alerts, cross-reference roles, `.md` link rewriting, Starlark `.bzl` parser & `bzl-autodoc`, TOC extraction, `search-index.json` generation, and strict rejection of broken internal links and `#anchor` fragments.
- **`//docs:site_test`** (`sh_test`): Verifies built `//docs:site` outputs, checks via `readelf -d` that `//docs:docs_gen` and `//docs:serve` dynamically link **only** base glibc (`libc.so.6`, `libm.so.6`, `libdl.so.2`, `libpthread.so.0`), and executes both binaries under `env -i PATH=/nonexistent`.

---

## Authoring Documentation Pages

Every Markdown file under `docs/content/**/*.md` starts with a YAML frontmatter block:

```yaml
---
title: "Full Page Title"
description: "Concise one-sentence summary used in page lead and search results."
section: overview | guide | reference | internals
nav_title: "Short Sidebar Label"
order: 10
---
```

- **Sections** are ordered canonically in the left sidebar across all 18 documentation pages:
  1. `overview` ("Overview"): `index.md`
  2. `guide` ("User Guide"): `quickstart.md`, `hackage.md`, `c-interop-and-toolchains.md`, `language-rts-runfiles-th.md`, `showcase-size.md`, `troubleshooting-and-migration.md`
  3. `reference` ("API & CLI Reference"): `rules.md`, `extensions-and-providers.md`, `lock-cli.md`
  4. `internals` ("Internals & Architecture"): `overview.md`, `rulesets-comparison.md`, `hermeticity.md`, `providers-and-actions.md`, `ecosystem-and-hackage.md`, `cross-os-and-platforms.md`, `docs-engine.md`, `dependencies.md`
- Within each section, pages sort deterministically by `(order, route)` and automatically receive breadcrumbs and sequential Previous / Next footer cards.
- Start the Markdown body directly with prose or `##` (`H2`) headings; the page template renders `title` as `<h1>` (any duplicate leading `# Title` in the Markdown body is stripped automatically).

---

## Sphinx-Inspired Authoring Features

### 1. Admonition Directives & GitHub Alerts (`Docs.Directive`)

Both Pandoc fenced divs (with optional custom `title="..."`) and GitHub-style blockquote alerts render semantic `<aside class="admonition admonition-<kind>">` callouts:

```markdown
::: {.note title="Custom Note Title"}
Inner Markdown supports **formatting**, code blocks, and `bzl:rule:hs_library` roles.
:::

> [!WARNING]
> Standard GitHub-flavored alert syntax works identically.
```

Supported classes/kinds: `note`, `tip`, `important`, `warning`, `caution`.

### 2. Cross-Reference Roles & `.md` Link Rewriting (`Docs.CrossRef`)

Relative Markdown links (`[Hermeticity](../internals/hermeticity.md#origin-staging)`) are rewritten automatically to `.html` links and relativized per page depth.

Inline code spans with role prefixes resolve into typed cross-reference links:

| Inline Role Syntax | Target URL | Rendered Label |
|---|---|---|
| `` `bzl:rule:hs_library` `` | `/reference/rules.html#hs_library` | `hs_library` |
| `` `bzl:ext:hackage.from_lock` `` | `/reference/extensions-and-providers.html#hackage-from_lock` | `hackage.from_lock` |
| `` `bzl:provider:HsPackageInfo` `` | `/reference/extensions-and-providers.html#hspackageinfo` | `HsPackageInfo` |
| `` `cli:lock` `` | `/reference/lock-cli.html` | `//tools/lock:lock` |
| `` `doc:guide/quickstart` `` | `/guide/quickstart.html` | Target page's `nav_title` |
| `` `doc:internals/rulesets-comparison` `` | `/internals/rulesets-comparison.html` | `Comparison with Other Rulesets` |

### 3. Starlark Introspection & `bzl-autodoc` (`Docs.Starlark`)

`Docs.Starlark` parses `hs/*.bzl` and `hs/private/*.bzl` to extract rules, attributes, defaults, providers, module extensions, and tag classes:

```markdown
::: {.bzl-autodoc source="hs/providers.bzl"}
:::

::: {.bzl-autodoc source="hs/defs.bzl" symbol="hs_library"}
:::
```

When `reference/rules.html` and `reference/extensions-and-providers.html` are built, `Docs.Starlark` also enforces **public symbol coverage**, failing the build if any public rule, provider, or module extension tag lacks its canonical anchor in the reference pages.

### 4. Strict Link & `#anchor` Verification (`Docs.LinkCheck`)

Whenever `docs/content/index.md` is present (or `--strict-links` is passed to `//docs:docs_gen`), `Docs.LinkCheck` parses every generated `.html` file in `out-dir` and verifies that **every** internal `<a href="...">` target file and `#id` fragment resolves cleanly.

---

## Regenerating `docs/hackage.lock.json`

`docs/hackage.lock.json` is generated hermetically by `rules_hs`'s own boot-only lockfile generator (`//tools/lock:lock`):

```bash
bazel run //tools/lock:lock -- \
  --snapshot lts-24.67 \
  --package hakyll \
  --package pandoc \
  --package pandoc-types \
  --package skylighting \
  --package skylighting-core \
  --package aeson \
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
