# `examples/size`: Haskell sitemap counter on Bazel 9

Explore a standalone [Bzlmod](https://bazel.build/external/overview) application built with [`rules_haskell`](../../MODULE.bazel). This CLI counts unique documentation pages across XML `<urlset>`, nested `<sitemapindex>`, and `.xml.gz` sitemaps over HTTP and HTTPS using 69 pinned Hackage libraries—compiled on Bazel 9 inside isolated [sandboxes](https://bazel.build/docs/sandboxing) without Nix or host installations of GHC, `cabal`, `stack`, OpenSSL, or `zlib`.

For a detailed walkthrough of this application, read [Showcase: `examples/size`](../../docs/content/guide/showcase-size.md), or browse the [examples index](../README.md) for smaller focused workspaces.

## Stack

- **Bazel:** `9.3.3` (Bzlmod, [`--incompatible_strict_action_env`](https://bazel.build/reference/command-line-reference#param-no-incompatible-strict-action-env), [`--enable_runfiles`](https://bazel.build/reference/command-line-reference#param-no-enable-runfiles)).
- **GHC:** `9.10.3` (`GHC2021`, `-Wall -Wcompat`), linked with `hermetic_cc_toolchain` (`zig cc`) and static [Bazel Central Registry](https://bazel.build/external/registry#bazel-central-registry) `gmp`.
- **XML parsing:** `xml-conduit` (`Text.XML` + `Text.XML.Cursor`).
- **HTTP and TLS:** `http-client` + `http-client-tls` (`tls` + `crypton`, pure-Haskell TLS) + `http-types`.
- **Compression:** `zlib` + vendored `zlib-clib` (compiled statically by `rules_haskell`).
- **Concurrency:** `async` (`mapConcurrently` with a `QSem` concurrency limit of 4).
- **Dependency lockfile:** [`hackage.lock.json`](hackage.lock.json) (69 pinned Hackage packages, with no host version solver needed at build time).

## Run tests, docs, and the REPL

From `examples/size`, run the test suite, build Haddock API docs, and launch the interactive REPL with [`bazel test`](https://bazel.build/docs/user-manual#running-tests) and [`bazel run`](https://bazel.build/docs/user-manual#running-executables):

```bash
bazel test //...
bazel build //:size_haddock
bazel run //:size_repl
```

Running `bazel test //...` builds all 69 Hackage packages and the `size` executable, then runs four tests:

- **`//:sitemap_test`:** Runs fixture tests (`urlset.xml`, `sitemapindex.xml`, `invalid_root.xml`, `urlset.xml.gz`, recursive `crawl/sitemap.xml`) plus UTF-8 BOM stripping, cycle and duplicate detection, blank `<loc>` handling, and corrupt gzip error handling.
- **`//:http_e2e_test`:** Runs an offline loopback HTTP end-to-end test binding an ephemeral `127.0.0.1:0` server via `network` to serve `testdata/crawl/*`, HTTP `302` redirects, and HTTP `404` responses.
- **`//:size_repl_test`:** Evaluates gzipped XML sitemap decoding inside `//:size_repl` (`hs_repl` over `:sitemap` and `:fetch` plus C-only `zlib-clib`) and tests `@rules_haskell//tools/ghci`.
- **`//:elf_hermeticity_test`:** Inspects `readelf -d` on `//:size` to verify that only base `glibc` shared libraries (`libc`, `libm`, `libdl`, `libpthread`, `librt`, `libutil`) are dynamically linked—no `libgmp`, `libtinfo`, `libffi`, `libz`, `libssl`, `libcrypto`, or `libHS*.so`—and runs `//:size` under `env -i PATH=/nonexistent`.

## Run against a live documentation sitemap

From `examples/size`, point `//:size` at any live XML or `.xml.gz` sitemap URL:

```bash
bazel run //:size -- https://docs.stripe.com/sitemap.xml
```
