# `examples/size` — Haskell Sitemap Counter on Bazel 9

Standalone Bzlmod consumer example for [`rules_hs`](../../MODULE.bazel).

Counts unique documentation pages across XML `<urlset>`, nested `<sitemapindex>`, and `.xml.gz` sitemaps over HTTP and HTTPS using Hackage libraries, built on Bazel 9 inside isolated sandboxes without requiring Nix or host installations of GHC, `cabal`, `stack`, OpenSSL, or `zlib`.

## Stack

- **Bazel**: `9.3.3` (Bzlmod, `--incompatible_strict_action_env`, `--enable_runfiles`)
- **GHC**: `9.10.3` (`GHC2021`, `-Wall -Wcompat`), linked using `hermetic_cc_toolchain` (`zig cc`) and static BCR `gmp`
- **XML parsing**: `xml-conduit` (`Text.XML` + `Text.XML.Cursor`)
- **HTTP & TLS**: `http-client` + `http-client-tls` (`tls` + `crypton`, pure-Haskell TLS) + `http-types`
- **Compression**: `zlib` + vendored `zlib-clib` (compiled statically by `rules_hs`)
- **Concurrency**: `async` (`mapConcurrently` with `QSem` concurrency limit of 4)
- **Dependency lockfile**: [`hackage.lock.json`](hackage.lock.json) (69 pinned Hackage packages, with no host version solver needed at build time)

## Running Tests

From `examples/size`:

```bash
bazel test //...
bazel build //:size_haddock
```

This builds all 69 Hackage packages plus the `size` executable and runs:
- `//:sitemap_test`: Fixture tests (`urlset.xml`, `sitemapindex.xml`, `invalid_root.xml`, `urlset.xml.gz`, recursive `crawl/sitemap.xml`) plus UTF-8 BOM stripping, cycle and duplicate detection, blank `<loc>` handling, and corrupt gzip error handling.
- `//:http_e2e_test`: Offline loopback HTTP end-to-end test binding an ephemeral `127.0.0.1:0` server via `network` to serve `testdata/crawl/*`, HTTP `302` redirects, and HTTP `404` responses.
- `//:elf_hermeticity_test`: Inspects `readelf -d` on `//:size` to verify only base `glibc` shared libraries (`libc`, `libm`, `libdl`, `libpthread`, `librt`, `libutil`) are dynamically linked — no `libgmp`, `libtinfo`, `libffi`, `libz`, `libssl`, `libcrypto`, or `libHS*.so` — and runs `//:size` under `env -i PATH=/nonexistent`.

## Running Live Against a Documentation Sitemap

```bash
bazel run //:size -- https://docs.stripe.com/sitemap.xml
```
