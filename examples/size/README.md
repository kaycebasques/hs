# `examples/size` — Hermetic Haskell Sitemap Counter on Bazel 9

Standalone Bzlmod consumer showcase for [`rules_hs`](../../MODULE.bazel).

Counts unique documentation pages across XML `<urlset>`, recursive `<sitemapindex>`, and `.xml.gz` sitemaps over HTTP/HTTPS using idiomatic Hackage libraries — built 100% hermetically on Bazel 9 with **zero Nix, zero host GHC, zero host `cabal`/`stack`, zero host OpenSSL, and zero host `zlib`**.

## Stack

- **Bazel**: `9.3.3` (Bzlmod-only, `--incompatible_strict_action_env`, `--enable_runfiles`)
- **GHC**: `9.10.3` (`GHC2021`, `-Wall -Wcompat`), linked hermetically with `hermetic_cc_toolchain` (`zig cc`) and static BCR `gmp`
- **XML parsing**: `xml-conduit` (`Text.XML` + `Text.XML.Cursor`)
- **HTTP & TLS**: `http-client` + `http-client-tls` (`tls` + `crypton`, pure-Haskell TLS) + `http-types`
- **Compression**: `zlib` + vendored `zlib-clib` (compiled statically by `rules_hs`)
- **Concurrency**: `async` (`mapConcurrently` with `QSem` concurrency bound of 4)
- **Dependency lockfile**: [`hackage.lock.json`](hackage.lock.json) (69 pinned Hackage packages, zero host solver at build time)

## Running Tests

From `examples/size`:

```bash
bazel test //...
```

This builds all 69 Hackage packages + the `size` app and runs:
- `//:sitemap_test`: Canonical fixture tests (`urlset.xml`, `sitemapindex.xml`, `invalid_root.xml`, `urlset.xml.gz`, recursive `crawl/sitemap.xml`) plus BOM stripping, cycle/duplicate detection, blank `<loc>` handling, and corrupt gzip error handling.
- `//:http_e2e_test`: Offline loopback HTTP E2E test spinning up an ephemeral `127.0.0.1:0` server via `network` serving `testdata/crawl/*`, HTTP 302 redirects, and HTTP 404 responses.
- `//:elf_hermeticity_test`: Inspects `readelf -d` on `//:size` to verify only base glibc shared libraries (`libc`, `libm`, `libdl`, `libpthread`, `librt`, `libutil`) are linked — zero `libgmp`, `libtinfo`, `libffi`, `libz`, `libssl`, `libcrypto`, or `libHS*.so` — and runs `//:size` under `env -i PATH=/nonexistent`.

## Running Live Against a Documentation Sitemap

```bash
bazel run //:size -- https://docs.stripe.com/sitemap.xml
```
