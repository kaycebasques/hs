---
title: "Showcase: examples/size"
description: "Walkthrough of examples/size, a standalone 69-package HTTPS XML and gzip sitemap crawler built with rules_hs."
section: guide
nav_title: "Showcase: examples/size"
order: 50
---

`examples/size` is a standalone Bazel 9 workspace included in the `rules_hs` repository. It builds a concurrent command-line tool (`//:size`) that crawls XML `<urlset>`, nested `<sitemapindex>`, and gzipped `.xml.gz` documentation sitemaps over HTTP and HTTPS to count unique pages.

`examples/size` also serves as an end-to-end integration example compiling **69 pinned Hackage packages** (plus 41 GHC `9.10.3` boot libraries) without Nix or host installations of GHC, Cabal, Stack, OpenSSL, or `zlib`.

## Architecture at a Glance

```mermaid
flowchart TD
    CLI["src/Main.hs (//:size hs_binary)"] --> FETCH["src/Fetch.hs (//:fetch hs_library)"]
    CLI --> SM["src/Sitemap.hs (//:sitemap hs_library)"]
    FETCH --> SM
    FETCH --> HTTP["@hackage//:http-client + http-client-tls (pure-Haskell tls + crypton)"]
    SM --> XML["@hackage//:xml-conduit (XML 1.0 namespaces + Cursor)"]
    SM --> ZLIB["@hackage//:zlib -> zlib-clib (bundled C zlib via cc_common.compile)"]
    SM --> ASYNC["@hackage//:async (4-way QSem + mapConcurrently)"]
    DOC["//:size_haddock (hs_haddock HTML + QuickJump)"] --> FETCH
    DOC --> SM
    REPL["//:size_repl (hs_repl interactive ghci)"] --> FETCH
    REPL --> SM
    TEST1["test/SitemapTest.hs (//:sitemap_test)"] --> SM
    TEST2["test/HttpE2eTest.hs (//:http_e2e_test, loopback TCP server)"] --> FETCH
    TEST3["test/elf_hermeticity_test.sh (readelf NEEDED + env -i)"] --> CLI
```

### Cabal and GHC Features Exercised

Building `examples/size` exercises several common Hackage packaging patterns in one workspace:

| Ecosystem Feature | Packages Exercising It in `examples/size` | How `rules_hs` Builds It |
|---|---|---|
| **C-only Cabal package + transitive `install-includes`** | `zlib-clib` -> `zlib` -> `streaming-commons` | Stage 4 `cc_common.compile` compiles 11 `.c` files and exports `<zlib.h>` via `CcInfo` and [`HsLinkInfo`](../reference/extensions-and-providers.md#hslinkinfo) without invoking GHC |
| **Autoconf `build-type: Configure` + `hsc2hs`** | `network`, `unix-time`, `old-time` | Stage 1 runs sandboxed `./configure` via `ghc_cc_wrapper`, feeding `HsNetworkConfig.h` into Stage 3 `hsc2hs` actions |
| **`build-type: Custom` (`cabal-doctest`)** | `xml-conduit` | Converted automatically to `"Simple"` by [`//tools/lock:lock`](../reference/lock-cli.md) |
| **Platform `select()` + `#include`-d `.c` files** | `crypton` (AESNI/SSE2 on `x86_64` vs. portable C on `arm64`) | [`//tools/lock:lock`](../reference/lock-cli.md) emits per-platform `select` deltas; `hackage.bzl` keeps `#include`-d `cbits/*_impl.c` files in `hdrs` |
| **Mutual recursion via `.hs-boot` files** | `cborg`, `tls` | Stage 5 `ghc --make -c` compiles `.hs-boot` cycles within each library |
| **Internal Cabal sublibraries** | `attoparsec` (`attoparsec-internal`) | Compiled as `:attoparsec-internal` in `@hackage__attoparsec` and aliased on `@hackage` |
| **Pure-Haskell TLS 1.2 / 1.3** | `http-client-tls`, `tls`, `crypton-x509*` | Connects over HTTPS without linking C OpenSSL (`libssl.so` / `libcrypto.so`) |

---

## Workspace Configuration (`examples/size/MODULE.bazel`)

`examples/size` is an independent Bazel workspace with its own `MODULE.bazel`:

```starlark
module(
    name = "size_example",
    version = "0.1.0",
    bazel_compatibility = [">=9.0.0"],
)

bazel_dep(name = "rules_hs", version = "0.1.0")
local_path_override(
    module_name = "rules_hs",
    path = "../..",
)

# Self-contained Linux C/C++ toolchain (zig cc) — no host gcc/ld/libc-dev required.
bazel_dep(name = "hermetic_cc_toolchain", version = "4.3.0")
bazel_dep(name = "rules_shell", version = "0.6.1", dev_dependency = True)

cc_toolchains = use_extension("@hermetic_cc_toolchain//toolchain:ext.bzl", "toolchains")
use_repo(cc_toolchains, "zig_sdk")

register_toolchains(
    "@zig_sdk//toolchain:linux_amd64_gnu.2.32",
    "@zig_sdk//toolchain:linux_arm64_gnu.2.32",
    "@zig_sdk//toolchain/...",
    "@zig_sdk//libc_aware/toolchain/...",
)

# GHC toolchain
hs = use_extension("@rules_hs//hs:extensions.bzl", "hs")
hs.toolchain(ghc_version = "9.10.3")
use_repo(hs, "hs_toolchains")
register_toolchains("@hs_toolchains//:all")

# Pinned third-party Hackage packages (69 packages, no host cabal/stack at build time)
hackage = use_extension("@rules_hs//hs:extensions.bzl", "hackage")
hackage.from_lock(
    name = "hackage",
    lockfile = "//:hackage.lock.json",
)
use_repo(hackage, "hackage")
```

`examples/size/hackage.lock.json` was generated with `zlib:bundled-c-zlib=true` and `zlib:pkg-config=false` so `zlib` compiles its vendored C sources through Bazel's `cc_toolchain`:

```bash
bazel run @rules_hs//tools/lock:lock -- \
  --snapshot lts-24.67 \
  --package async \
  --package http-client \
  --package http-client-tls \
  --package http-types \
  --package network \
  --package xml-conduit \
  --package zlib \
  --flag zlib:bundled-c-zlib=true \
  --flag zlib:pkg-config=false \
  --output "$PWD/hackage.lock.json"
```

---

## Build Graph (`examples/size/BUILD.bazel`)

The project splits its code into a pure XML/sitemap parsing library (`:sitemap`), an HTTP/TLS client library (`:fetch`), a small CLI entry point (`:size`), a combined [`hs_haddock`](../reference/rules.md#hs_haddock) API documentation target (`:size_haddock`), an interactive [`hs_repl`](../reference/rules.md#hs_repl) target (`:size_repl`), and four test targets:

```starlark
load("@rules_hs//hs:defs.bzl", "hs_binary", "hs_haddock", "hs_library", "hs_repl", "hs_test")
load("@rules_shell//shell:sh_test.bzl", "sh_test")

hs_library(
    name = "sitemap",
    srcs = ["src/Sitemap.hs"],
    ghc_opts = ["-Wall", "-Wcompat"],
    hs_source_dirs = ["src"],
    deps = [
        "@hackage//:async",
        "@hackage//:base",
        "@hackage//:bytestring",
        "@hackage//:containers",
        "@hackage//:text",
        "@hackage//:xml-conduit",
        "@hackage//:zlib",
    ],
)

hs_library(
    name = "fetch",
    srcs = ["src/Fetch.hs"],
    ghc_opts = ["-Wall", "-Wcompat"],
    hs_source_dirs = ["src"],
    deps = [
        ":sitemap",
        "@hackage//:base",
        "@hackage//:bytestring",
        "@hackage//:http-client",
        "@hackage//:http-client-tls",
        "@hackage//:http-types",
        "@hackage//:text",
    ],
)

hs_binary(
    name = "size",
    srcs = ["src/Main.hs"],
    ghc_opts = ["-Wall", "-Wcompat"],
    hs_source_dirs = ["src"],
    visibility = ["//visibility:public"],
    deps = [
        ":fetch",
        ":sitemap",
        "@hackage//:base",
        "@hackage//:text",
    ],
)

hs_haddock(
    name = "size_haddock",
    title = "size — Sitemap Size Tracker API",
    visibility = ["//visibility:public"],
    deps = [
        ":sitemap",
        ":fetch",
    ],
)

hs_repl(
    name = "size_repl",
    visibility = ["//visibility:public"],
    deps = [
        ":sitemap",
        ":fetch",
    ],
)
```

### Direct Dependency Breakdown (`examples/size/BUILD.bazel`) {#dependency-breakdown}

Across its library, binary, and test targets (`:sitemap`, `:fetch`, `:size`, `:sitemap_test`, and `:http_e2e_test`), `examples/size/BUILD.bazel` declares **12 direct `@hackage//:*` dependencies** — 5 GHC boot packages and 7 third-party Hackage libraries, which pull in the 69-package transitive closure in `examples/size/hackage.lock.json` (see [Dependency Decisions](../internals/dependencies.md#showcase-libraries) for details on each library choice):

| Dependency Target | Source | Go / Rust / Python Analog | Imported By (`BUILD.bazel` Targets -> Modules) | Why It Is Needed |
|---|---|---|---|---|
| `@hackage//:base` | GHC Boot (`4.20.2.0`) | Rust `std`, Go `builtin` + `os` + `sync` | All 5 Haskell targets (`Main`, `Fetch`, `Sitemap`, `SitemapTest`, `HttpE2eTest`) | Standard library: `IO`, CLI `getArgs`/`exitFailure`, exceptions, `MVar` (thread-safe mutable box) and `QSem` (counting semaphore) concurrency primitives, and `runST` for pure local state. |
| `@hackage//:bytestring` | GHC Boot | Rust `&[u8]` / `bytes::Bytes`, Go `[]byte`, Python `bytes` | `:sitemap`, `:fetch`, `:sitemap_test`, `:http_e2e_test` (`Sitemap`, `Fetch`, `SitemapTest`, `HttpE2eTest`) | Packed raw byte buffers (`ByteString`) for HTTP response bodies, gzip two-byte header checks (`0x1f 0x8b`), and loopback TCP socket I/O. |
| `@hackage//:text` | GHC Boot | Rust `String` / `&str`, Go `string`, Python `str` | All 5 Haskell targets (`Main`, `Fetch`, `Sitemap`, `SitemapTest`, `HttpE2eTest`) | Packed UTF-8 text (`Text`), UTF-8 decoding (`decodeUtf8'`), UTF-8 byte-order mark (BOM) stripping, and URL/XML element strings. |
| `@hackage//:containers` | GHC Boot | Rust `BTreeSet` / `BTreeMap`, C++ `std::set` / `std::map` | `:sitemap` (`Sitemap`), `:sitemap_test` (`SitemapTest`) | `Data.Set` deduplicates discovered page URLs and tracks visited `<sitemapindex>` URLs; `Data.Map.Strict` stores in-memory test fixtures. |
| `@hackage//:filepath` | GHC Boot | Rust `std::path`, Go `path/filepath`, Python `pathlib` | `:sitemap_test` (`SitemapTest`), `:http_e2e_test` (`HttpE2eTest`) | Joins `TEST_SRCDIR` and `TEST_WORKSPACE` runfile paths (`</>`) when loading `testdata/` XML and `.xml.gz` fixtures. |
| `@hackage//:async` | Hackage (`2.2.6`) | Go `errgroup.Group`, Rust `tokio::task::JoinSet` | `:sitemap` (`Sitemap`), `:http_e2e_test` (`HttpE2eTest`) | Structured concurrency over GHC green threads: `mapConcurrently` crawls child sitemaps concurrently and `withAsync` scopes the loopback test HTTP server. |
| `@hackage//:xml-conduit` | Hackage (`1.10.1.0`) | Rust `quick-xml` / `roxmltree`, Python `lxml` | `:sitemap` (`Sitemap`: `Text.XML`, `Text.XML.Cursor`) | XML 1.0 parser and cursor query combinators (`$/`) handling XML namespaces, `<xhtml:link/>` sibling elements, and `&amp;` entity decoding. |
| `@hackage//:zlib` | Hackage (`0.7.1.1`) | Rust `flate2` (vendored `zlib`), Go `compress/gzip` | `:sitemap` (`Sitemap`: `Codec.Compression.GZip`, `Codec.Compression.Zlib.Internal`) | Streaming `decompressST` decompression of `.xml.gz` sitemaps with structured error values on corrupt archives, statically linked against vendored C `zlib-clib`. |
| `@hackage//:http-client` | Hackage (`0.7.19`) | Go `net/http`, Rust `hyper` / `reqwest` | `:fetch` (`Fetch`: `Network.HTTP.Client`) | Connection-pooled HTTP/1.1 client with 30-second response timeouts, HTTP `302` redirect following, and streaming response buffers. |
| `@hackage//:http-client-tls` | Hackage (`0.3.6.4`) | Rust `reqwest` + `rustls` | `:fetch` (`Fetch`: `Network.HTTP.Client.TLS`) | Connects pure-Haskell TLS 1.2/1.3 (`tls` + `crypton` + `crypton-x509-system`) to `http-client`, avoiding any C OpenSSL (`libssl.so`) runtime dependency. |
| `@hackage//:http-types` | Hackage (`0.12.6`) | Rust `http` crate, Go `net/http` status/headers | `:fetch` (`Fetch`: `Network.HTTP.Types.Header`, `Network.HTTP.Types.Status`) | Standard HTTP header names (`hUserAgent`) and status-code checks (`statusIsSuccessful`, `statusCode`). |
| `@hackage//:network` | Hackage (`3.2.14.0`) | Go `net`, Python `socket` | `:http_e2e_test` (`HttpE2eTest`: `Network.Socket`, `Network.Socket.ByteString`) | Binds an ephemeral `127.0.0.1:0` loopback TCP socket to test HTTP redirects, `.xml.gz` responses, `User-Agent` headers, and `404` handling offline inside Bazel's sandbox. |

### Injectable Fetcher and Bounded Concurrency (`src/Sitemap.hs`)

`Sitemap.hs` passes network calls through a function type alias (`type Fetcher = Text -> IO (Either String ByteString)` — a function taking a URL and returning either an error string in `Left` or raw response bytes in `Right`). Unit tests can pass an in-memory `Map` lookup as the `Fetcher`, testing gzip decompression, UTF-8 BOM stripping, XML namespaces, and cycle detection without opening network sockets.

To cap concurrent HTTP downloads at 4 without deadlocking when a `<sitemapindex>` points to nested child `<sitemapindex>` files, `countPagesWithConcurrency` acquires the `QSem` counting semaphore **only around the single `fetch url` call**, releasing it before recursing into children with `mapConcurrently`:

```haskell
walk :: MVar (Set Text) -> QSem -> Text -> IO (Either String CrawlSummary)
walk visitedVar sem url = do
  claimed <- claimUrl visitedVar url
  if not claimed
    then pure (Right mempty)
    else do
      -- Release the semaphore before recursing into child sitemaps so nested
      -- sitemap index trees cannot deadlock waiting for permits.
      fetched <- bracket_ (waitQSem sem) (signalQSem sem) (fetch url)
      case fetched of
        Left err -> pure (Left err)
        Right rawBytes ->
          case decodePayload rawBytes >>= parse of
            Left err -> pure (Left (T.unpack url <> ": " <> err))
            Right (UrlSet urls) ->
              pure (Right (CrawlSummary (Set.fromList urls) 1))
            Right (SitemapIndex children) -> do
              childResults <- mapConcurrently (walk visitedVar sem) children
              pure $ case sequenceA childResults of
                Left err -> Left err
                Right summaries -> Right (CrawlSummary Set.empty 1 <> mconcat summaries)
```

For readers new to Haskell, here is what each piece of `walk` does:
- **`MVar (Set Text)`**: A thread-safe mutable box holding the set of URLs already claimed by a worker thread so duplicate or cyclic sitemap links are fetched only once.
- **`bracket_ (waitQSem sem) (signalQSem sem) (fetch url)`**: Acquires one permit from the counting semaphore `sem`, runs `fetch url`, and guarantees `signalQSem sem` runs afterward even if `fetch` throws an exception (like `try ... finally` in Python or Java).
- **`decodePayload rawBytes >>= parse`**: Chains two `Either String ...` steps together — decompressing `.xml.gz` if gzipped and then parsing the XML — short-circuiting on the first `Left err`.
- **`mapConcurrently` and `sequenceA`**: `mapConcurrently` runs `walk` on all child sitemaps on separate green threads; `sequenceA` turns `[Either String CrawlSummary]` into `Either String [CrawlSummary]`, returning the first error if any child failed or combining all `CrawlSummary` sets (`mconcat`) if all succeeded.

---

## Running the Test Suite and Live CLI

From `examples/size`, run all four test targets, build the Haddock API documentation, or open an interactive `ghci` session:

```bash
cd examples/size
bazel test //...
bazel build //:size_haddock
bazel run //:size_repl
```

`//:size_haddock` runs [`hs_haddock`](../reference/rules.md#hs_haddock) across `:sitemap` and `:fetch`, writing `bazel-bin/size_haddock/index.html`, `Sitemap.html`, `Fetch.html`, QuickJump `doc-index.json`, and hyperlinked source files under `src/`. `//:size_repl` opens `ghci` with `Sitemap` and `Fetch` loaded from source alongside all 69 compiled Hackage dependencies (including C-only `zlib-clib`).

What `bazel test //...` checks:
1. **`//:sitemap_test`** ([`hs_test`](../reference/rules.md#hs_test) with `data = ["//testdata:sitemaps"]`): Tests `<urlset>`, `<sitemapindex>`, `.xml.gz`, invalid HTML root rejection, UTF-8 BOM stripping, cyclic `<sitemapindex>` graphs (verifying each URL is fetched once), case-insensitive tags, and corrupt gzip error reporting.
2. **`//:http_e2e_test`** ([`hs_test`](../reference/rules.md#hs_test)): Binds an ephemeral `127.0.0.1:0` loopback TCP socket via `@hackage//:network`, serves XML and `.xml.gz` fixtures, HTTP `302 Found` redirects, and `404 Not Found` errors, and tests `Fetch.httpFetcher` inside the Bazel test sandbox with no external network access.
3. **`//:size_repl_test`** (`sh_test`): Evaluates `.xml.gz` decompression and XML parsing inside `//:size_repl` and verifies `@rules_hs//tools/ghci` from an external consumer workspace.
4. **`//:elf_hermeticity_test`** (`sh_test`): Runs `readelf -d` on `//:size` to verify that ELF `NEEDED` entries list only base `glibc` shared libraries — no `libgmp`, `libtinfo`, `libffi`, `libz`, `libssl`, `libcrypto`, or `libHS*.so` — and runs `//:size` under `env -i PATH=/nonexistent`.

To run `//:size` live over HTTPS against a public documentation site:

```bash
cd examples/size
bazel run //:size -- https://docs.stripe.com/sitemap.xml
```

Sample output:

```text
    5253 pages  (1 sitemap(s))  https://docs.stripe.com/sitemap.xml
```
