---
title: "Vanilla Hakyll & GHC Haddock Documentation"
description: "How rules_hs dogfoods canonical vanilla Hakyll + Pandoc + Skylighting for Markdown prose and bundled GHC Haddock (hs_haddock) for Haskell API docs."
section: internals
nav_title: "Hakyll & Haddock Docs"
order: 60
---

`rules_hs` builds its own documentation site (`//docs:site`), Haskell API reference ([`//tools/lock` Haddock API](../haddock/lock/index.html)), and local preview server (`//docs:serve`) **100% hermetically in Haskell** under Bazel 9 — using the canonical Haskell documentation stack of **vanilla Hakyll + Pandoc + Skylighting** for prose and **GHC Haddock** ([`hs_haddock`](../reference/rules.md)) for Haskell libraries, with zero Python, zero Node.js, zero Nix, and zero custom Markdown DSLs.

> **Important — Zero Downstream Bzlmod Footprint:** In `MODULE.bazel`, the `@hackage` hub backing `//docs/...` is loaded with `dev_dependency = True` (enforced by `//tests/rules:bzlmod_hygiene_test`). Downstream consumers of `rules_hs` never fetch or evaluate `docs/hackage.lock.json` and retain `rules_hs`'s minimal 4-module non-dev dependency graph (`platforms`, `bazel_skylib`, `rules_cc`, `gmp`).

## Why Canonical Vanilla Hakyll + GHC Haddock?

Rather than pulling in a foreign language runtime (`rules_python` + Sphinx/MkDocs or `aspect_rules_js` + Docusaurus) or inventing bespoke Sphinx-like custom roles and fenced-div directives on top of Pandoc, `rules_hs` pairs the two standard tools of the Haskell ecosystem for the exact jobs each was designed to solve:

1. **Vanilla Hakyll + Pandoc + Skylighting (`docs/site.hs`)** compiles standard GitHub-flavored Markdown guides, Starlark rule/provider tables, and architecture internals. Authors write ordinary Markdown links (`[Quickstart](../guide/quickstart.md)`), standard `>` blockquotes, and fenced code blocks — readable directly in any Git forge or editor with zero proprietary syntax.
2. **Bundled GHC Haddock (`hs/private/haddock.bzl`)** extracts module headers, type signatures, QuickJump `doc-index.json` indices, and syntax-highlighted hyperlinked source (`src/*.html`) directly from `-- |` Haddock comments in Haskell libraries such as `//tools/lock:lock_lib` and `examples/size//:size_haddock`.
3. **Production-scale `rules_hs` dogfooding**: Building `//docs:docs_gen` with [`hs_binary`](../reference/rules.md#hs_binary) and [`hs_cabal_library`](../reference/rules.md#hs_cabal_library) compiles **182 Hackage packages + 41 GHC boot packages** (`hakyll-4.16.8.0`, `pandoc-3.7.0.2`, `skylighting-0.14.7`, `citeproc-0.9.0.1`, `typst-0.7`, `aeson-2.2.5.1`, `yaml-0.11.11.2`, `libyaml-clib`, `zlib-clib`, `digest`), continuously exercising:
   - **Cross-library Template Haskell (`-dynamic-too`)**: `aeson`, `th-lift`, `file-embed`, `unicode-collation`, `citeproc`, and `pandoc` evaluate cross-package TH splices via relocatable `<name>.pkgdb/dyn/libHS*.so` shared libraries while keeping `//docs:docs_gen` statically linked (`DT_NEEDED` strictly base glibc).
   - **Compile-time data embedding in Bazel sandboxes**: `pandoc` (`--flag pandoc:embed_data_files=true`), `citeproc`, and `unicode-collation` embed data files via `file-embed` TH inside sandbox-staged package working directories.
   - **Source-bootstrapped `alex` & `happy` preprocessors** (`pretty-show`, `toml-parser`) and **mixed C / C++11 / `hsc2hs` / `./configure` packages** (`libyaml-clib`, `zlib-clib`, `digest`, `network`).

> **Tip — Trimming Hakyll's Dependency Closure with Cabal Flags:** Passing `--flag hakyll:checkexternal=false --flag hakyll:watchserver=false --flag hakyll:previewserver=false` and `--flag pandoc:embed_data_files=true` to [`//tools/lock:lock`](../reference/lock-cli.md) eliminates `http-conduit`, `warp`, and `fsnotify` and bakes Pandoc's templates directly into `//docs:docs_gen`, yielding a single portable executable with zero runtime `Paths_*` data-directory lookups.

---

## SSG & API Documentation Ecosystem Evaluation

Six documentation architectures were evaluated against `rules_hs`'s hermeticity, Stackage `lts-24.67` availability, and canonical Haskell ergonomics (see [Dependency Decisions](dependencies.md) for full catalyst records):

| Tool | Role & Ecosystem | Stackage `lts-24.67` | Fit & Tradeoffs | Decision |
|---|---|---|---|---|
| **Vanilla Hakyll + Pandoc + Skylighting** | Static site generator (`hakyll`, `pandoc`, `skylighting`) | **In Stackage LTS** (all 182 transitive deps) | Idiomatic `Rules`/`Compiler`/`Context` DSL, Pandoc native TOC (`writerTableOfContents = True`), 140+ Skylighting grammars, `relativizeUrls`, zero custom Markdown syntax | **Adopted (Prose & Starlark Docs)** |
| **GHC Bundled Haddock (`hs_haddock`)** | Haskell API documentation (`bin/haddock-ghc-<ver>`) | **Bundled in GHC bindist** (zero extra downloads) | Native GHC typechecker integration, `--hyperlinked-source`, `--quickjump` (`doc-index.json`), cross-package `--read-interface` links | **Adopted (Haskell Library APIs)** |
| **Emanote / Ema** | Reactive Nix-first Haskell SSG | **Absent** (Nix flake pins) | Tightly coupled to Nix flakes and external Tailwind tooling incompatible with Nix-free Bazel Bzlmod | Not Adopted |
| **Slick / Raw Shake + Pandoc** | Shake-based SSG wrappers | Partial / LTS | Duplicates Bazel's outer build graph with a second nested build database (`shake`) while lacking Hakyll's `Identifier` routing, `listField` contexts, and `relativizeUrls` | Not Adopted |
| **Custom Sphinx-like AST DSL on Pandoc** | Bespoke role code spans, fenced-div directives, and Starlark parsers | N/A (bespoke code) | Breaks standard GitHub Markdown previews, adds hundreds of lines of non-idiomatic AST machinery, and duplicates Haddock | Not Adopted |
| **Sphinx / MkDocs / mdBook / Docusaurus** | Python / Rust / Node.js SSGs | External ecosystems | Require pulling `rules_python`, `rules_rust`, or `aspect_rules_js` into `MODULE.bazel` and forfeit `rules_hs` dogfooding | Not Adopted |

---

## Architecture & Build Pipeline

The entire site generator is a single warning-clean file (`docs/site.hs`, compiled as `//docs:docs_gen` with `-Wall -Wcompat`), paired with `hs/private/haddock.bzl` (`hs_haddock`) and `docs/app/site.bzl` (`hs_docs_site`).

```mermaid
flowchart TD
    MD["docs/content/**/*.md (Standard GitHub Markdown)"] --> HAK["docs/site.hs: Vanilla Hakyll (hakyllWith)"]
    TPL["docs/templates/default.html + docs/static/*"] --> HAK
    HAK --> HTML["18 HTML Pages + Skylighting syntax.css + Native Pandoc TOC + relativizeUrls"]
    LOCK["//tools/lock:lock_lib (CabalExtract.hs, LockJson.hs)"] --> HAD["hs_haddock: //tools/lock:lock_haddock (HsHaddock)"]
    GHC["Staged GHC bin/haddock-ghc-9.10.3 + lib/html + boot .haddock"] --> HAD
    HTML --> SITE["hs_docs_site (//docs:site)"]
    HAD --> SITE
    SITE --> CHECK["//docs:link_check_test + //docs:site_test"]
```

### 1. Hermetic `hs_haddock` Action (`hs/private/haddock.bzl`)

As detailed in [Hermeticity & Toolchain](hermeticity.md) and [Providers & Actions](providers-and-actions.md), `staged_ghc.bzl` stages `bin/haddock-ghc-<ver>` alongside `bin/ghc-<ver>` under the same `$ORIGIN/../lib/<arch_libdir>` layout, retains `lib/html/**` (the `Linuwial` theme, `quick-jump.min.js`, `haddock-bundle.min.js`, and hyperlinked-source assets), and indexes bundled boot `.haddock` files on [`HsToolchainInfo`](../reference/extensions-and-providers.md#hstoolchaininfo).

When `hs_haddock` executes (`HsHaddock` mnemonic):
- It invokes `hs_tc.haddock` with `-B <libdir> -l <libdir>`, `--html`, `--use-unicode`, `--quickjump` (`doc-index.json`), `--hyperlinked-source` (`src/<Module>.html`), and `--dump-interface=<name>.haddock`.
- It forwards hermetic compiler and C-toolchain flags (`-hide-all-packages`, transitive `-package-db`s, direct `-package-id`s, and `ghc_cc_wrapper` `-pgm*` flags) via `--optghc=` so `{-# LANGUAGE CPP #-}`, `CApiFFI`, and cross-library Template Haskell work identically under `env -i` in `linux-sandbox`.
- It wires `--read-interface` against GHC's bundled boot `.haddock` interfaces (linking types like `Text`, `Map`, and `GenericPackageDescription` to Hackage) as well as any upstream `haddock_deps` targets.

### 2. Vanilla Hakyll Site Compilation (`docs/site.hs` & `docs/app/site.bzl`)

`docs/site.hs` uses standard Hakyll primitives end-to-end:
- `match "templates/*" $ compile templateBodyCompiler` and `match "static/**" $ route idRoute >> compile copyFileCompiler`.
- `create ["static/syntax.css"]` emitting dual light/dark CSS directly from `Skylighting.styleToCss` (`kate` + `breezeDark`).
- `version "nav"` and `version "toc"` snapshots powering Hakyll `listField` / `listFieldWith` section navigation (`overview`, `guide`, `reference`, `internals` ordered by YAML frontmatter `section` and `order`), sequential Previous / Next links, and Pandoc's native `writerTableOfContents = True` right-hand table of contents.
- `pandocCompilerWithTransform` performing **only** relative `.md` -> `.html` link target rewriting (so links work both in raw Markdown on GitHub and in the built site), `starlark`/`bzl` Skylighting language mapping, and `<pre class="mermaid">` emission, followed by `loadAndApplyTemplate "templates/default.html"` and `relativizeUrls`.
- Inside `HsDocsSite` (`docs/app/site.bzl`), inputs are staged into a sandbox-local scratch directory (`DOCS_PROVIDER_DIR`, `DOCS_CACHE_DIR`) so Hakyll never mutates source directories or leaks state into `/tmp`, and `haddocks = {"//tools/lock:lock_haddock": "haddock/lock"}` mounts the generated Haddock bundle at [`/haddock/lock/index.html`](../haddock/lock/index.html).

### 3. Verification (`//docs:link_check_test` & `//docs:site_test`)

Every `bazel test //docs/...` run executes two complementary hermetic checks:
- **`//docs:link_check_test`** (`docs/test/LinkCheckTest.hs`): parses every generated `.html` file across both Hakyll and `haddock/lock/` using `tagsoup` and verifies that every internal `<a href="...">` file target and `#id` anchor exists.
- **`//docs:site_test`** (`docs/test/site_test.sh`): verifies all 18 Hakyll pages + mounted `haddock/lock/` QuickJump & hyperlinked-source artifacts, checks via `readelf -d` that `//docs:docs_gen` and `//docs:serve` dynamically link strictly base glibc, and tests `//docs:serve` over loopback HTTP/1.1 for both Hakyll pages and `/haddock/lock/index.html`.
