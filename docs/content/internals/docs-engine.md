---
title: "Hakyll & GHC Haddock Documentation Engine"
description: "How rules_haskell builds its documentation site with Hakyll, Pandoc, and Skylighting for Markdown prose and bundled GHC Haddock (hs_haddock) for Haskell API docs."
section: internals
nav_title: "Hakyll & Haddock Docs"
order: 60
---

`rules_haskell` builds its own documentation site (`//docs:site`), Haskell API reference ([`//tools/lock` Haddock API](../haddock/lock/index.html)), and local preview server (`//docs:serve`) in Haskell under Bazel 9 — using **Hakyll + Pandoc + Skylighting** for Markdown prose and **GHC Haddock** ([`hs_haddock`](../reference/rules.md)) for Haskell library APIs, with zero Python, zero Node.js, zero Nix, and zero custom Markdown syntax extensions.

> **Important — Zero Downstream Bzlmod Footprint:** In `MODULE.bazel`, the `@hackage` hub backing `//docs/...` is loaded with `dev_dependency = True` (enforced by `//tests/rules:bzlmod_hygiene_test`). Downstream consumers of `rules_haskell` never fetch or evaluate `docs/hackage.lock.json` and inherit only `rules_haskell`'s 4 non-dev dependencies (`platforms`, `bazel_skylib`, `rules_cc`, `gmp`). If you are new to Bazel ruleset authoring or Haskell, see [Bazel Ruleset Primer](bazel-rules-primer.md) and [Haskell & GHC Primer](haskell-and-ghc-primer.md).

## Why Vanilla Hakyll + GHC Haddock?

Rather than adding a separate language runtime (`rules_python` + Sphinx/MkDocs or `aspect_rules_js` + Docusaurus) or inventing custom Sphinx-like inline roles and fenced-div directives on top of Pandoc, `rules_haskell` pairs the two standard documentation tools in the Haskell ecosystem for their intended jobs:

1. **Hakyll + Pandoc + Skylighting (`docs/site.hs`)** compiles standard GitHub-flavored Markdown guides, Starlark rule and provider tables, and architecture chapters. Authors write ordinary relative Markdown links (`[Quickstart](../guide/quickstart.md)`), standard `>` blockquotes, and fenced code blocks — readable directly in any Git web viewer or text editor without custom preprocessors.
2. **Bundled GHC Haddock (`hs/private/haddock.bzl`)** extracts module headers, type signatures, QuickJump `doc-index.json` search indices, and syntax-highlighted hyperlinked source (`src/*.html`) directly from `-- |` Haddock comments in Haskell libraries such as `//tools/lock:lock_lib` and `examples/size//:size_haddock`.
3. **End-to-end integration test for `rules_haskell` itself**: Building `//docs:docs_gen` with [`hs_binary`](../reference/rules.md#hs_binary) and [`hs_cabal_library`](../reference/rules.md#hs_cabal_library) compiles **182 Hackage packages + 41 GHC boot packages** (`hakyll-4.16.8.0`, `pandoc-3.7.0.2`, `skylighting-0.14.7`, `citeproc-0.9.0.1`, `typst-0.8.0.2`, `aeson-2.2.5.1`, `yaml-0.11.11.2`, `libyaml-clib-0.2.5`, `zlib-clib-1.3.2`, `digest-0.0.2.1`), exercising:
   - **Cross-library Template Haskell (`-dynamic-too`)**: `aeson`, `th-lift`, `file-embed`, `unicode-collation`, `citeproc`, and `pandoc` run compile-time code-generation splices via relocatable `<name>.pkgdb/dyn/libHS*.so` shared libraries while keeping the final `//docs:docs_gen` executable statically linked (dynamic `DT_NEEDED` entries limited strictly to base `glibc`).
   - **Compile-time data embedding in Bazel sandboxes**: `pandoc` (`--flag pandoc:embed_data_files=true`), `citeproc`, and `unicode-collation` read and embed data files into the binary at compile time via `file-embed` inside sandbox-staged package working directories.
   - **Source-bootstrapped `alex` & `happy` lexer/parser generators** (`pretty-show`, `toml-parser`) and **mixed C / C++11 / `hsc2hs` / `./configure` packages** (`libyaml-clib`, `zlib-clib`, `digest`, `network`).

> **Tip — Trimming Hakyll's Dependency Closure with Cabal Flags:** Passing `--flag hakyll:checkexternal=false --flag hakyll:watchserver=false --flag hakyll:previewserver=false` and `--flag pandoc:embed_data_files=true` to [`//tools/lock:lock`](../reference/lock-cli.md) drops `http-conduit` and `fsnotify` from the dependency graph and embeds Pandoc's HTML templates directly into `//docs:docs_gen`, producing a single self-contained executable with zero runtime `Paths_*` data-directory lookups.

---

## SSG & API Documentation Ecosystem Evaluation

Six documentation architectures were evaluated against `rules_haskell`'s hermeticity requirements, Stackage `lts-24.67` availability, and standard Markdown compatibility (see [Dependency Decisions](dependencies.md) for full catalyst records):

| Tool | Role & Ecosystem | Stackage `lts-24.67` | Fit & Tradeoffs | Decision |
|---|---|---|---|---|
| **Vanilla Hakyll + Pandoc + Skylighting** | Static site generator (`hakyll`, `pandoc`, `skylighting`) | **In Stackage LTS** (all 182 transitive deps) | Declarative `Rules`/`Compiler`/`Context` library, Pandoc native TOC (`writerTableOfContents = True`), 140+ Skylighting syntax grammars, `relativizeUrls`, zero custom Markdown syntax | **Adopted (Prose & Starlark Docs)** |
| **GHC Bundled Haddock (`hs_haddock`)** | Haskell API documentation (`bin/haddock-ghc-<ver>`) | **Bundled in GHC bindist** (zero extra downloads) | Native GHC typechecker integration, `--hyperlinked-source`, `--quickjump` (`doc-index.json`), cross-package `--read-interface` links | **Adopted (Haskell Library APIs)** |
| **Emanote / Ema** | Reactive Nix-oriented Haskell SSG | **Absent** (Nix flake pins) | Coupled to Nix flakes and external Tailwind tooling incompatible with Nix-free Bazel Bzlmod | Not Adopted |
| **Slick / Raw Shake + Pandoc** | Shake-based SSG wrappers | Partial / LTS | Duplicates Bazel's outer build graph with a second nested build database (`shake`) while lacking Hakyll's `Identifier` routing, `listField` contexts, and `relativizeUrls` | Not Adopted |
| **Custom Sphinx-like AST DSL on Pandoc** | Bespoke role code spans, fenced-div directives, and Starlark parsers | N/A (custom code) | Breaks standard GitHub Markdown previews, adds hundreds of lines of custom AST rewrite code, and duplicates Haddock | Not Adopted |
| **Sphinx / MkDocs / mdBook / Docusaurus** | Python / Rust / Node.js SSGs | External ecosystems | Require pulling `rules_python`, `rules_rust`, or `aspect_rules_js` into `MODULE.bazel` and lose Haskell integration test coverage | Not Adopted |

---

## Architecture & Build Pipeline

The site generator is a single warning-clean Haskell file (`docs/site.hs`, compiled as `//docs:docs_gen` with `-Wall -Wcompat`), paired with `hs/private/haddock.bzl` (`hs_haddock`) and `docs/app/site.bzl` (`hs_docs_site`).

```mermaid
flowchart TD
    MD["docs/content/**/*.md (Standard GitHub Markdown)"] --> HAK["docs/site.hs: Hakyll (hakyllWith)"]
    TPL["docs/templates/default.html + docs/static/*"] --> HAK
    HAK --> HTML["HTML Pages + Skylighting syntax.css + Native Pandoc TOC + relativizeUrls"]
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

### 2. Hakyll Site Compilation (`docs/site.hs` & `docs/app/site.bzl`)

`docs/site.hs` uses standard Hakyll building blocks from start to finish:
- `match "templates/*" $ compile templateBodyCompiler` and `match "static/**" $ route idRoute >> compile copyFileCompiler`.
- `create ["static/syntax.css"]` emitting dual light and dark CSS directly from `Skylighting.styleToCss` (`kate` + `breezeDark`).
- `version "nav"` and `version "toc"` snapshots driving Hakyll `listField` / `listFieldWith` section navigation (`overview`, `guide`, `reference`, `internals` ordered by YAML frontmatter `section` and `order`), sequential Previous / Next links, and Pandoc's native `writerTableOfContents = True` right-hand table of contents.
- `pandocCompilerWithTransform` performing **only** relative `.md` -> `.html` link target rewriting (so links work both in raw Markdown on GitHub and in the built site), `starlark`/`bzl` Skylighting language mapping, and `<pre class="mermaid">` emission, followed by `loadAndApplyTemplate "templates/default.html"` and `relativizeUrls`.
- Inside `HsDocsSite` (`docs/app/site.bzl`), inputs are staged into a sandbox-local scratch directory (`DOCS_PROVIDER_DIR`, `DOCS_CACHE_DIR`) so Hakyll never mutates source directories or leaks state into `/tmp`, and `haddocks = {"//tools/lock:lock_haddock": "haddock/lock"}` mounts the generated Haddock bundle at [`/haddock/lock/index.html`](../haddock/lock/index.html).

### 3. Verification (`//docs:link_check_test` & `//docs:site_test`)

Every `bazel test //docs/...` run executes two complementary hermetic checks:
- **`//docs:link_check_test`** (`docs/test/LinkCheckTest.hs`): parses every generated `.html` file across both Hakyll and `haddock/lock/` using `tagsoup` and verifies that every internal `<a href="...">` file target and `#id` anchor exists.
- **`//docs:site_test`** (`docs/test/site_test.sh`): verifies all generated Hakyll pages + mounted `haddock/lock/` QuickJump & hyperlinked-source artifacts, checks via `readelf -d` that `//docs:docs_gen` and `//docs:serve` dynamically link strictly base glibc, and tests `//docs:serve` over loopback HTTP/1.1 for both Hakyll pages and `/haddock/lock/index.html`.

---

## Walking Through `docs/site.hs` (For Readers New to Haskell) {#site-hs-walkthrough}

Unlike configuration-file static site generators (such as Hugo's `hugo.toml` or MkDocs's `mkdocs.yml`), **Hakyll is a library in Haskell**: your site configuration is a small Haskell program (`docs/site.hs`, compiled into the executable `//docs:docs_gen`).

You do not need any prior Haskell background to read `docs/site.hs`. First, here is a plain-English decoder for the small handful of Haskell syntax tokens that appear in the snippets below, followed by the five sections of the file.

### Quick Haskell Syntax Decoder (Read This Before the Code)

| Haskell Syntax | Everyday Meaning | Equivalent in Python / TypeScript / Go |
|---|---|---|
| `name :: Type` | **"`name` has type `Type`"** (`()` is Haskell's empty unit type, like `void` or `None`) | `function name(): Type` in TypeScript |
| `A -> B` | **Function type arrow**: takes an argument of type `A` and returns a `B` (`A -> B -> C` takes two arguments, `A` and `B`, and returns `C`) | `(a: A) => B` |
| `f x y` | **Function call**: spaces apply a function to its arguments without needing parentheses or commas | `f(x, y)` |
| `f $ g x` | **Avoid extra parentheses**: `$` evaluates everything on its right first and passes the result to `f`, so `compile $ makeItem css` means `compile (makeItem css)` | `compile(makeItem(css))` |
| `do` and `x <- step` | **Run steps in order**: a `do` block runs steps top-to-bottom; `x <- step` runs `step` and stores its result in `x`, whereas `let y = expr` defines an ordinary local variable | `const x = await step(); const y = expr;` |
| `a <> b` | **Combine / concatenate**: joins two strings, `Text` buffers, or template dictionaries (`Context`s) together | `a + b` or `{ ...a, ...b }` |
| `f . g` | **Compose two functions**: `(f . g) doc` runs `g doc` first, then passes that output into `f` | `f(g(doc))` |
| `` a `fn` b `` | **Infix call**: wrapping any two-argument function name in backticks lets you write it between its two arguments instead of `fn a b` | `a.fn(b)` |

> **What does "monad" mean when reading Hakyll code?** Haskell documentation often calls types like `IO`, `Rules`, and `Compiler` *monads*. Despite the academic name, a **monad** in `docs/site.hs` is just a **step-by-step recipe / action builder**:
> - `IO a` is a recipe for an operating-system action (like reading an environment variable or writing files) that produces an `a` when executed.
> - `Rules ()` is a recipe that registers file-matching build rules into Hakyll (much like evaluating a Bazel `BUILD.bazel` file registers targets before running any compiler).
> - `Compiler a` is a recipe for building one page or asset while automatically recording every file and template it read so Hakyll knows what depends on what.
>
> `do` blocks and the `>>=` pipe operator are simply how you chain smaller recipes together in sequence.

### 1. Language Pragmas & `main :: IO ()` (Reading Env Vars and Config)

At the top of `docs/site.hs`, `main` reads three environment variables passed by Bazel (`DOCS_PROVIDER_DIR`, `DOCS_OUT_DIR`, `DOCS_CACHE_DIR`), builds a Hakyll `Configuration` value, and hands `siteRules` to Hakyll:

```haskell
{-# LANGUAGE OverloadedStrings #-}

main :: IO ()
main = do
  setLocaleEncoding utf8
  providerDir <- fromMaybe "docs" <$> lookupEnv "DOCS_PROVIDER_DIR"
  outDir      <- fromMaybe "_site" <$> lookupEnv "DOCS_OUT_DIR"
  cacheDir    <- fromMaybe "_cache" <$> lookupEnv "DOCS_CACHE_DIR"
  let conf = defaultConfiguration
        { providerDirectory = providerDir
        , destinationDirectory = outDir
        , storeDirectory = cacheDir </> "store"
        , tmpDirectory = cacheDir </> "tmp"
        , inMemoryCache = True
        , ...
        }
  hakyllWith conf siteRules
```

Line by line:
- **`{-# LANGUAGE OverloadedStrings #-}`**: A compiler pragma (an opt-in GHC feature comment at the top of a file). By default in Haskell, a quoted string literal `"..."` only has the basic `String` type. Enabling `OverloadedStrings` lets the same `"templates/*"` literal also stand for a packed UTF-8 `Text` value or a Hakyll file glob `Pattern` without manual conversion calls.
- **`main :: IO ()` and `do`**: Declares `main` as an OS action returning `()`, and steps through its lines in order.
- **`fromMaybe "docs" <$> lookupEnv "DOCS_PROVIDER_DIR"`**: `lookupEnv` asks the OS for an environment variable and returns `IO (Maybe String)` — where `Maybe String` is Haskell's null-safe optional type (`Just "/path"` if set, or `Nothing` if unset). `fromMaybe "docs"` unwraps a `Maybe String`, returning `"docs"` when it is `Nothing`. Putting `<$>` between them applies `fromMaybe "docs"` to the result inside the `IO` step, and `providerDir <- ...` stores the resulting `String` in `providerDir`.
- **`defaultConfiguration { providerDirectory = providerDir, ... }`**: Creates a modified copy of Hakyll's default settings struct with our sandbox directory paths substituted in (identical in spirit to `{ ...defaultConfiguration, destinationDirectory: outDir }` in TypeScript; `</>` joins file paths like Python's `Path(cacheDir) / "store"`).

### 2. `siteRules :: Rules ()` (`match`, `create`, `route`, `compile`, and `version`)

Next, `siteRules` registers which input files exist, where their outputs should be written (`route`), and how their contents should be built (`compile`). Notice how `$` saves parentheses (`compile $ makeItem skylightingCss` means `compile (makeItem skylightingCss)`), and backticks let `composeRoutes` sit readably between two route steps:

```haskell
siteRules :: Rules ()
siteRules = do
  match "templates/*" $ compile templateBodyCompiler

  match "static/**" $ do
    route idRoute
    compile copyFileCompiler

  create ["static/syntax.css"] $ do
    route idRoute
    compile $ makeItem skylightingCss
```

- **`match <pattern>` vs. `create <paths>`**: `match` selects real input files copied into `DOCS_PROVIDER_DIR` (`templates/*`, `static/**`, `content/**.md`). `create ["static/syntax.css"]` generates a virtual output file from an in-memory string (`skylightingCss`, produced by `Skylighting.styleToCss` for the `kate` light and `breezeDark` dark themes) with no source file on disk.
- **`route` vs. `compile`**:
  - `route` controls **where** an output file is written inside `_site/`. `idRoute` keeps the relative path unchanged (`static/style.css` stays `static/style.css`). On Markdown pages, `gsubRoute "content/" (const "") \`composeRoutes\` setExtension "html"` strips the leading `"content/"` prefix and swaps `.md` for `.html` (mapping `content/internals/docs-engine.md` to `internals/docs-engine.html`). Leaving out `route` (as on `"templates/*"`) compiles the item in memory so other rules can use it without writing `templates/default.html` to `_site/`.
  - `compile` supplies the `Compiler` recipe that produces the item's contents.
- **Why `version "nav"` and `version "toc"` exist**: Every rendered HTML page includes a left navigation sidebar listing all pages in the site. If compiling page A tried to load the finished HTML of every page (including page A itself), Hakyll would hit a circular dependency (`A` waiting on `A`). Registering two helper snapshots per Markdown file breaks that cycle cleanly: `version "nav"` is an empty body handle that exposes each page's YAML frontmatter (`section`, `order`, `nav_title`) with no `route`, and `version "toc"` renders just that page's Table of Contents HTML fragment via Pandoc.

### 3. Building Each Page (`Compiler` and the `>>=` Pipe Operator)

Now look at the main Markdown-to-HTML rule. Before reading the last three lines, think of **`>>=`** (pronounced *"bind"*) as a **typed, dependency-tracked Unix pipe (`|`)**: `step1 >>= step2 >>= step3` runs `step1`, passes its output value as the argument to `step2`, and passes `step2`'s output into `step3` — while Hakyll records every template or file touched along the way:

```haskell
  match (fromGlob "content/**.md" .&&. hasNoVersion) $ do
    route $ gsubRoute "content/" (const "") `composeRoutes` setExtension "html"
    compile $ do
      ident    <- getUnderlying
      navItems <- loadSortedNavItems
      tocHtml  <- loadBody (setVersion (Just "toc") ident)
      pageCtx  <- buildPageContext ident navItems tocHtml
      pandocCompilerWithTransform docsReaderOptions docsWriterOptions transformMarkdownAst
        >>= loadAndApplyTemplate (fromFilePath "templates/default.html") pageCtx
        >>= relativizeUrls
```

Following the `do` steps and the `>>=` pipeline from top to bottom:
1. `ident`, `navItems`, `tocHtml`, and `pageCtx` gather the current file's identifier (`content/internals/docs-engine.md`), the sorted list of all sidebar navigation items, this page's Table of Contents HTML, and the template variable dictionary (`pageCtx`).
2. `pandocCompilerWithTransform ...` parses the Markdown file into a Pandoc syntax tree, runs our pure function `transformMarkdownAst`, and renders an HTML body wrapped in Hakyll's `Item String` container.
3. `>>= loadAndApplyTemplate ... pageCtx` pipes that HTML body into `templates/default.html`, filling in `$body$`, `$title$`, `$toc$`, sidebar `$sections$`, and Previous / Next links from `pageCtx`.
4. `>>= relativizeUrls` pipes the complete HTML document through Hakyll's URL relativizer, rewriting root-style paths like `/guide/quickstart.html` into `../guide/quickstart.html` (when viewed from `internals/docs-engine.html`) or `guide/quickstart.html` (when viewed from `index.html`). That final pipe stage is why the generated site works without broken links at `http://127.0.0.1:8000/`, on GitHub Pages under `/hs/`, or opened directly from disk via `file://`.

### 4. Rewriting Links & Code Blocks on Pandoc's Syntax Tree (`transformMarkdownAst`)

In Haskell, pure data transformations take a value in and return a new value out with zero side effects. Here, `transformMarkdownAst :: Pandoc -> Pandoc` takes a parsed `Pandoc` document tree and returns an updated `Pandoc` tree by chaining three small functions with `.` (right-to-left function composition, so `stripLeadingH1` runs first and `walk rewriteInline` runs last):

```haskell
transformMarkdownAst :: Pandoc -> Pandoc
transformMarkdownAst = walk rewriteInline . walk rewriteBlock . stripLeadingH1
```

- **`stripLeadingH1`**: Uses pattern matching on the document's top-level block list to drop a redundant `# Heading` if present, because `templates/default.html` already renders the YAML frontmatter `title:` field as the page's `<h1>`.
- **`walk rewriteBlock`**: `Text.Pandoc.Walk.walk` is a tree-walking helper from `pandoc-types` that visits every node of a given type at any nesting depth (inside tables, blockquotes, or lists) without manual recursion. `rewriteBlock` checks fenced `CodeBlock` nodes: `mermaid` blocks become `<div class="mermaid-container"><pre class="mermaid">...</pre></div>`, and `starlark`/`bzl`/`bazel` fences are tagged as `python` so Skylighting highlights them cleanly.
- **`walk rewriteInline`**: Visits every inline element and matches `Link` nodes, rewriting relative `.md` and `.md#anchor` targets to `.html` and `.html#anchor` while leaving `https://...` and `#anchor` links untouched.

### 5. Filling HTML Template Variables (`Context String`, `<>`, and `mconcat`)

In Hakyll, a `Context String` is a template lookup dictionary that tells `templates/default.html` how to fill placeholders like `$title$`, `$if(is_index)$`, and `$for(sections)$`:

- **`<>` and `mconcat` (combining dictionaries with left-to-right fallback)**: Combining two contexts with `ctxA <> ctxB` (or a list of contexts with `mconcat [ctx1, ctx2, ..., defaultContext]`) creates a **first-match-wins lookup chain**. When `templates/default.html` asks for `$nav_title$`, Hakyll checks the first context in the list; if a placeholder like `$title$` or `$description$` is not overridden earlier, lookup falls through to Hakyll's built-in `defaultContext`, which reads keys directly from the page's YAML frontmatter block.
- **`listField` and `listFieldWith`**: Supply list values for nested template loops (`$for(sections)$ ... $for(pages)$ ... $endfor$ $endfor$`), binding a child `Context` (`section_title`, `is_active`, `nav_label`, `url`) to each sidebar link.

---

## Anatomy of the 182-Package `docs/hackage.lock.json` Closure {#docs-closure-breakdown}

While `examples/size/hackage.lock.json` locks **69** Hackage packages, `docs/hackage.lock.json` locks **182** Hackage packages (plus GHC `9.10.3`'s 41 boot packages). Nearly the entire difference comes from **`pandoc`**, which is a multi-format document converter supporting dozens of markup, math, citation, and archive formats in a single library:

| Functional Sub-Tree | Root Target(s) in `docs/BUILD.bazel` | Representative Packages in `docs/hackage.lock.json` | Approximate Share & `rules_haskell` Features Exercised |
|---|---|---|---|
| **1. Pandoc Document AST, Readers & Writers** | `//docs:docs_gen` (`site.hs`) | `pandoc` (`3.7.0.2`), `pandoc-types` (`1.23.1.2`), `commonmark*`, `djot`, `jira-wiki-markup`, `haddock-library`, `ipynb`, `gridtables`, `texmath`, `typst` (`0.8.0.2`), `typst-symbols`, `doctemplates`, `doclayout`, `JuicyPixels`, `zip-archive`, `emojis` | ~90 packages — large multi-module libraries, cross-library TH (`embed_data_files=true`), `alex`/`happy` grammar codegen (`pretty-show`, `toml-parser`). |
| **2. Citations, Unicode Collation & Compile-Time Data** | Transitive under `pandoc` | `citeproc` (`0.9.0.1`), `unicode-collation` (`0.1.3.7`), `unicode-data`, `unicode-transforms`, `file-embed` (`0.0.16.0`), `xml-conduit`, `conduit` | ~20 packages — compile-time `file-embed` TH splices reading binary collation and CSL files from sandboxed package `data` directories via `<name>.pkgdb/dyn/libHS*.so`. |
| **3. Skylighting Syntax Highlighting** | `//docs:docs_gen` & `pandoc` | `skylighting` (`0.14.7`), `skylighting-core` (`0.14.7`), `skylighting-format-blaze-html`, `skylighting-format-ansi`, `skylighting-format-latex`, `skylighting-format-typst`, `regex-tdfa` | ~10 packages — TH-compiled KDE Kate XML syntax grammars for 140+ languages + dual light/dark CSS generation. |
| **4. YAML / JSON / Crypto / HTTP / C Archive Plumbing** | `hakyll` & `pandoc` | `aeson` (`2.2.5.1`), `yaml` (`0.11.11.2`), `libyaml`, `libyaml-clib` (`0.2.5`), `zlib`, `zlib-clib` (`1.3.2`), `digest` (`0.0.2.1`), `http-client`, `http-client-tls`, `tls`, `crypton*`, `cborg` | ~45 packages — C-only Cabal libraries (`libyaml-clib`, `zlib-clib`), C FFI (`digest`, `crypton`), `.hs-boot` mutual recursion (`cborg`, `tls`), internal sublibraries (`attoparsec-internal`). |
| **5. Hakyll Static Site Engine** | `//docs:docs_gen` | `hakyll` (`4.16.8.0`), `blaze-html`, `blaze-markup`, `lrucache`, `optparse-applicative`, `Glob`, `time-locale-compat`, `wai-app-static`, `warp` | ~15 packages — `Rules` / `Compiler` / `Context` library, HTML templating, and `relativizeUrls`. |
| **6. HTML Link Checker & Local HTTP Server** | `//docs:link_check_test`, `//docs:serve` | `tagsoup` (`0.14.8`), `network` (`3.2.14.0`) + GHC boot `base`, `bytestring`, `containers`, `directory`, `filepath`, `text` | 2 direct Hackage packages (already shared with `hakyll`/`pandoc`) — because `@hackage` fetches repositories lazily, running `bazel build //docs:serve` builds **only** `network` + boot packages in a few seconds without downloading or compiling `pandoc` or `hakyll`. |
| **7. Bundled GHC Haddock (`hs_haddock`)** | `//tools/lock:lock_haddock` | *Zero Hackage packages* (`bin/haddock-ghc-9.10.3` + `lib/html/` from `@ghc_9_10_3_*`) | **0 Hackage packages** — executes directly from the `$ORIGIN`-staged GHC bindist. |
