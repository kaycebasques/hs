---
title: "Lock generator CLI reference"
description: "CLI flag reference and deterministic hackage.lock.json schema specification for @rules_haskell//tools/lock:lock."
section: reference
nav_title: "Lock generator CLI"
order: 30
---

This page documents the CLI flags, normalization rules, and `hackage.lock.json` schema for `@rules_haskell//tools/lock:lock`, the command-line tool that generates third-party Hackage lockfiles for `rules_haskell`.

For a step-by-step guide to adding Hackage packages and configuring [`MODULE.bazel`](https://bazel.build/external/module), see [Hackage and lockfiles](../guide/hackage.md). For the extension that consumes this lockfile, see [`hackage` module extension](extensions-and-providers.md#hackage); for implementation details, see [Hackage and Cabal pipeline](../internals/ecosystem-and-hackage.md).

You run `@rules_haskell//tools/lock:lock` only at development time—when you add a Hackage dependency, bump your Stackage snapshot, or toggle a Cabal package flag—and commit the resulting `hackage.lock.json` to Git. Normal [`bazel build`](https://bazel.build/run/build) and [`bazel test`](https://bazel.build/docs/user-manual#running-tests) invocations never run the lock generator; they read `hackage.lock.json` directly in [Starlark](https://bazel.build/rules/language) through [`hackage.from_lock`](extensions-and-providers.md#hackage-from_lock).

Because the tool compiles solely against GHC's built-in boot libraries, you don't need a host `cabal` or `stack` installation. Given a **Stackage snapshot** (a curated set of Hackage package versions verified upstream to compile together for one GHC release) and your direct `--package` names, it resolves transitive dependencies, evaluates every `.cabal` manifest across four target platforms using GHC's `Cabal-syntax` library (`finalizePD`), verifies `.tar.gz` SHA-256 checksums against Hackage, and writes a sorted, deterministic `hackage.lock.json`.

> **Tip:** Module-level Haddock API documentation for `//tools/lock` (`CabalExtract` and `LockJson`), built with [`hs_haddock`](rules.md#hs_haddock), is published at [Haddock API (`//tools/lock`)](../haddock/lock/index.html) with hyperlinked source and QuickJump search.

---

## Synopsis {#synopsis}

Run from any downstream workspace using [`bazel run`](https://bazel.build/docs/user-manual#running-executables):

```bash
bazel run @rules_haskell//tools/lock:lock -- \
  [--snapshot <name>] \
  [--snapshot-yaml <path>] \
  [--cabal-config <path>] \
  [--cache-dir <dir>] \
  [--ghc-version <ver>] \
  --package <name> [--package <name> ...] \
  [--flag <pkg>:<flag>=<bool> ...] \
  [--boot-pkg <pkg>=<ver> ...] \
  [--output <path>]
```

Or from inside the `rules_haskell` repository:

```bash
bazel run //tools/lock:lock -- --help
```

> **Important:** Because `bazel run` launches executables inside Bazel's [runfiles](https://bazel.build/extending/rules#runfiles) directory instead of your shell's working directory, pass absolute paths to `--output` (for example, `--output "$PWD/hackage.lock.json"`), `--snapshot-yaml`, and `--cabal-config`.

---

## CLI flags {#flags}

| Flag | Repeatable | Default | Required | Description |
|---|---|---|---|---|
| `--snapshot <name>` | No | `"lts-24.67"` | No | Curated Stackage snapshot identifier (`lts-<major>.<minor>` for stable Long-Term Support releases or `nightly-YYYY-MM-DD` for newer GHC series). Determines the pinned version and default Cabal flags of every Hackage package by fetching the snapshot YAML from `commercialhaskell/stackage-snapshots` and boot constraints from `www.stackage.org/<name>/cabal.config` (unless local files are supplied via `--snapshot-yaml` and `--cabal-config`), and is recorded in the lockfile's `snapshot` field. |
| `--snapshot-yaml <path>` | No | `None` (fetched) | No | Path to a local copy of a Stackage snapshot `.yaml` file (`resolver`, `flags`, `packages`). Use this in air-gapped networks, offline tests, or when testing custom local edits to a snapshot file without fetching from GitHub. |
| `--cabal-config <path>` | No | `None` (fetched) | No | Path to a local Stackage `cabal.config` file listing `<pkg> installed` boot package constraints. Pair with `--snapshot-yaml` when running offline or testing custom snapshot fixtures. |
| `--cache-dir <dir>` | No | `"/tmp/rules_haskell_lock_cache"` | No | Local disk cache folder where downloaded snapshot manifests, `.cabal` files, and `.tar.gz` tarballs are saved so re-locking after adding a new `--package` reuses unchanged downloads. |
| `--ghc-version <ver>` | No | Snapshot compiler (fallback `"9.10.3"`) | No | Target GHC compiler version used when evaluating `.cabal` `if impl(ghc >= ...)` conditionals, selecting the default boot package table (`9.10.*` vs. `9.12.*`), and writing `ghc_version` in the lockfile. Inferred automatically from the Stackage snapshot's `compiler:` field; pass explicitly only when testing a snapshot against a different patch or minor GHC release. |
| `--package <name>` | **Yes** | — | **Yes** (at least 1) | Direct Hackage library name your project imports (for example, `--package aeson --package http-client-tls`). List only direct Hackage dependencies—the lock generator discovers and locks every transitive non-boot package automatically, and you don't need to pass GHC boot packages like `base` or `text`. |
| `--flag <pkg>:<flag>=<bool>` | **Yes** | Stackage snapshot `flags:` | No | Toggles a boolean `flag` stanza inside `<pkg>.cabal` (`true` or `false`, case-insensitive; flag names are lowercased) ahead of `finalizePD` evaluation, overriding both `.cabal` and Stackage defaults. Use `--flag` to prune optional dependency trees (such as `--flag hakyll:previewserver=false`) or switch a C binding between vendored C sources (`--flag zlib:bundled-c-zlib=true --flag zlib:pkg-config=false`) and an external Bazel [`cc_library`](https://bazel.build/reference/be/c-cpp#cc_library) supplied via [`hackage.override`](extensions-and-providers.md#hackage-override). |
| `--boot-pkg <pkg>=<ver>` | **Yes** | Built-in GHC `9.10` / `9.12` boot table | No | Adds or overrides the version of a GHC boot library in the boot package set and output `boot_packages` map (for example, `--boot-pkg filepath=1.5.4.0`). Needed only when targeting a custom GHC build whose bundled boot library versions differ from upstream `9.10.3` or `9.12.4`. |
| `--output <path>` | No | `"hackage.lock.json"` | No | Output path where the generated JSON lockfile is written. Always pass an absolute path under `bazel run`, such as `--output "$PWD/hackage.lock.json"`. |
| `-h`, `--help` | No | — | No | Prints CLI flag usage to `stdout` and exits with status `0`. |

### Flag sanitization and build-type normalization

While extracting `.cabal` metadata, `@rules_haskell//tools/lock:lock` applies three normalizations so third-party packages build deterministically inside Bazel [sandboxes](https://bazel.build/docs/sandboxing) (for implementation details, see [Hackage and Cabal pipeline](../internals/ecosystem-and-hackage.md)):

1. **GHC warning and link flag sanitization:** Many Hackage packages include `-Werror` or `-Wall` in `.cabal` `ghc-options:`, which breaks downstream builds when a newer GHC release adds a warning, or pass executable-only flags like `-threaded` and `-rtsopts` on library stanzas. The generator strips `-Werror`, `-Werror=*`, `-W*`, `-fwarn-*`, `-fno-warn-*`, `-w`, `-threaded`, `-rtsopts`, `-with-rtsopts=*`, `-fllvm`, and `-ferror-spans` while keeping optimization and code-generation flags (such as `-O2`, `-funbox-strict-fields`, `-fno-cse`, and `-optc-O3`).
2. **`cabal-doctest` `Custom` normalization:** Some Hackage packages (such as `xml-conduit`) declare `build-type: Custom` solely so `Setup.hs` can run `cabal-doctest` for the package's own test suite, which isn't needed to compile the library. Whenever a `Custom` package's `custom-setup` depends exclusively on `{base, Cabal, Cabal-syntax, cabal-doctest, filepath, directory}`, the generator normalizes `"build_type"` to `"Simple"` so [`hs_cabal_library`](rules.md#hs_cabal_library) builds it without `Setup.hs`. Packages with bespoke `Custom` `Setup.hs` dependencies keep `"build_type": "Custom"` and fail at analysis time with an unsupported-build-type error if targeted in Bazel.
3. **Autoconf `Configure` inspection:** For `build-type: Configure` packages (such as `network`, `unix-time`, and `old-time`) that run a GNU Autoconf `./configure` script before compiling C bindings, the generator inspects the extracted `.tar.gz` archive, `<pkg>.buildinfo`, and `configure.ac` to record `configure_script`, `configure_srcs` (`*.h.in`, `config.guess`, `config.sub`, `install-sh`), `configure_outputs` (such as `include/HsNetworkConfig.h` or `include/HsTimeConfig.h`), and generated `install_includes` headers.

---

## `hackage.lock.json` schema {#lockfile-schema}

`@rules_haskell//tools/lock:lock` formats `hackage.lock.json` with lexicographically sorted keys, 2-space indentation, and a trailing newline. Empty optional arrays and empty platform deltas are omitted so `git diff` stays concise when you update dependencies.

### Top-level object (`LockFile`)

| Field | JSON type | Required | Description |
|---|---|---|---|
| `schema_version` | `number` (`int`) | **Yes** | Lockfile format version integer. Currently `1` (validated by [`hackage.from_lock`](extensions-and-providers.md#hackage-from_lock) during [Bzlmod](https://bazel.build/external/overview) evaluation so incompatible future lockfile schemas fail with a clear error). |
| `snapshot` | `string` | **Yes** | Stackage snapshot name used to resolve this lockfile (for example, `"lts-24.67"`), recorded for reproducibility and auditability when re-running the lock generator. |
| `ghc_version` | `string` | **Yes** | GHC compiler version evaluated when resolving `.cabal` `impl(ghc ...)` conditionals (for example, `"9.10.3"`). |
| `boot_packages` | `object` (`{string: string}`) | **Yes** | Sorted map of GHC boot library name to version string (such as `"base": "4.20.2.0"` and `"text": "2.1.3"`). [`hackage.from_lock`](extensions-and-providers.md#hackage-from_lock) uses this map to generate `@<hub>//:<boot_pkg>` [`hs_toolchain_library`](rules.md#hs_toolchain_library) targets for every boot package not shadowed by an explicit entry in `packages`. |
| `packages` | `object` (`{string: LockedPackage}`) | **Yes** | Sorted map from each pinned third-party Hackage package name to its `LockedPackage` build specification. |

### Package object (`packages.<pkg>` — `LockedPackage`)

| Field | JSON type | Emitted when | Description |
|---|---|---|---|
| `version` | `string` | Always | Exact resolved Hackage version string (for example, `"3.2.14.0"`). |
| `url` | `string` | Always | HTTPS download URL of the immutable upstream source tarball (`https://hackage.haskell.org/package/<pkg>-<ver>/<pkg>-<ver>.tar.gz`) passed to Bazel's downloader when the `@<hub>__<pkg>` repository is fetched. |
| `sha256` | `string` | Always | Lowercase 64-character hex SHA-256 checksum of the `.tar.gz` archive, verified by Bazel on every download so cached or mirrored tarballs can't change silently. |
| `strip_prefix` | `string` | Always | Top-level folder name inside the `.tar.gz` archive (`"<pkg>-<version>"`) stripped by [`repository_ctx.download_and_extract`](https://bazel.build/rules/lib/builtins/repository_ctx) so package files unpack directly at the external repository root. |
| `cabal_revision` | `number` (`int`) | Always | Hackage **Cabal revision** number (`x-revision`, or `0` if unrevised). On Hackage, maintainers can update a published release's `.cabal` dependency version bounds without re-uploading the `.tar.gz` source archive; the lock generator evaluates the revised `.cabal` file and records its revision number here. |
| `build_type` | `string` | Always | Normalized Cabal build mode: `"Simple"` (standard 5-stage build), `"Configure"` (runs `./configure` first in Stage 1), or `"Custom"` (bespoke `Setup.hs`, rejected at [Bazel analysis time](https://bazel.build/extending/concepts#evaluation-model)). |
| `configure_script` | `string` | `build_type == "Configure"` | Tarball-relative path to the GNU Autoconf shell script executed in Stage 1 (typically `"configure"`). |
| `configure_srcs` | `array[string]` | `build_type == "Configure"` | Sorted list of tarball-relative helper scripts and header templates staged into the writable `./configure` sandbox (`config.guess`, `config.sub`, `install-sh`, `*.h.in`, `*.buildinfo`, `include/*.h`). |
| `configure_outputs` | `array[string]` | `build_type == "Configure"` | Sorted list of header paths written by `./configure` (such as `["include/HsNetworkConfig.h"]`), declared as [Bazel action](https://bazel.build/extending/rules#actions) outputs so Stages 3–5 can `#include` them. |
| `library` | `ComponentSpec` | Package has a buildable main `library` | Cross-platform compilation metadata for the package's primary `library` stanza. |
| `sublibraries` | `object` (`{string: ComponentSpec}`) | Package declares public sublibraries or internal `library <sublib>` stanzas used by `library` | Sorted map from sublibrary name (such as `"attoparsec-internal"`) to its `ComponentSpec`, each emitted as a sibling `hs_cabal_library` target inside `@<hub>__<pkg>` and aliased in `@<hub>` as `@<hub>//:<pkg>__<sublib>`. |

### Component object (`library` and `sublibraries.<sublib>` — `ComponentSpec`)

Every library and sublibrary is evaluated across four target platforms (`linux_x86_64`, `linux_arm64`, `macos_arm64`, `macos_x86_64`). Values shared across all four platforms live in the component's top-level fields below; values enabled only on specific OS/CPU combinations (for example, `x86_64` AES-NI C files vs. `arm64` portable C files) live under `select.<platform>`.

| Field | JSON type | Emitted when | Description |
|---|---|---|---|
| `exposed_modules` | `array[string]` | Always (`[]` for C-only packages) | Dotted Haskell module names exposed publicly on all platforms (`[]` on C-only packages like `zlib-clib` and `libyaml-clib`). |
| `other_modules` | `array[string]` | Always | Internal dotted Haskell module names (`other-modules:` and non-`Paths_*` `autogen-modules:` such as `.x` and `.y` parser modules) compiled privately into the library on all platforms. |
| `reexported_modules` | `array[string]` | Non-empty | Cabal `reexported-modules:` entries common to all platforms (`"pkg:Orig.Mod as New.Mod"`). |
| `hs_source_dirs` | `array[string]` | Always | Package-relative Haskell import root directories common to all platforms (defaults to `["."]`). |
| `default_language` | `string` | Always | Cabal `default-language:` edition (`"Haskell98"`, `"Haskell2010"`, `"GHC2021"`, or `"GHC2024"`), defaulting to `"Haskell98"` when omitted in `.cabal`. |
| `default_extensions` | `array[string]` | Non-empty | GHC `-X<ext>` language extensions enabled on all platforms. |
| `ghc_opts` | `array[string]` | Non-empty | Sanitized GHC compiler flags common to all platforms (preserving flag order). |
| `c_sources` | `array[string]` | Non-empty | Tarball-relative C, C++, or assembly source files compiled on all platforms. |
| `include_dirs` | `array[string]` | Non-empty | Tarball-relative `-I` C header directories common to all platforms. |
| `install_includes` | `array[string]` | Non-empty | Public C header names from `install-includes:` exported via [`CcInfo`](https://bazel.build/rules/lib/providers/CcInfo) to downstream dependents on all platforms. |
| `cpp_options` | `array[string]` | Non-empty | C preprocessor `-D` flags passed to `hsc2hs` and GHC (`{-# LANGUAGE CPP #-}`) on all platforms. |
| `cc_options` | `array[string]` | Non-empty | C/C++ compiler flags passed to `hsc2hs` and [`cc_common.compile`](https://bazel.build/rules/lib/toplevel/cc_common) on all platforms. |
| `extra_libraries` | `array[string]` | Non-empty | System C library names listed in Cabal `extra-libraries:` (for example, `["pthread"]` or `["m"]`). When a package lists a non-glibc library like `"z"` or `"ssl"`, supply a [hermetic](https://bazel.build/basics/hermeticity) Bazel `cc_library` via [`hackage.override`](extensions-and-providers.md#hackage-override) `extra_cc_deps`. |
| `generate_paths_module` | `boolean` | Always | `true` when the component lists Cabal's autogenerated `Paths_<pkg>` module (which exposes `version` and `getDataFileName`) in `other-modules` or `autogen-modules` on any platform; tells Stage 2 to generate `Paths_<pkg>.hs`. |
| `deps` | `array[string]` | Always | Direct external package dependencies common to all platforms, translated into `@<hub>//:<dep>` [Bazel labels](https://bazel.build/concepts/labels). |
| `sublib_deps` | `array[string]` | Non-empty | Direct dependencies on sibling sublibraries inside the same Cabal package, translated into local `:<sublib>` labels within `@<hub>__<pkg>`. |
| `select` | `object` (`{PlatformKey: PlatformDelta}`) | At least one platform has platform-specific values | Per-platform additions keyed by `"linux_arm64"`, `"linux_x86_64"`, `"macos_arm64"`, and `"macos_x86_64"`. [`hackage.from_lock`](extensions-and-providers.md#hackage-from_lock) renders these into Bazel `+` [`select()`](https://bazel.build/configure/attributes) expressions in `@<hub>__<pkg>/BUILD.bazel`. |

### Platform delta object (`select.<platform>` — `PlatformDelta`)

Each `PlatformDelta` object contains only the non-empty array fields from `ComponentSpec` (`exposed_modules`, `other_modules`, `reexported_modules`, `hs_source_dirs`, `default_extensions`, `ghc_opts`, `c_sources`, `include_dirs`, `install_includes`, `cpp_options`, `cc_options`, `extra_libraries`, `deps`, and `sublib_deps`) that apply on that specific OS/CPU platform on top of the component's common fields.

### Annotated example (`hackage.lock.json` excerpt)

The excerpt below (abridged from `examples/size/hackage.lock.json`) shows all three package shapes side by side—an internal sublibrary package (`attoparsec`), per-CPU `select` deltas (`crypton`), and an Autoconf `Configure` package (`network`):

```json
{
  "schema_version": 1,
  "snapshot": "lts-24.67",
  "ghc_version": "9.10.3",
  "boot_packages": {
    "Cabal": "3.12.1.0",
    "Cabal-syntax": "3.12.1.0",
    "base": "4.20.2.0",
    "bytestring": "0.12.2.0",
    "text": "2.1.3"
  },
  "packages": {
    "attoparsec": {
      "version": "0.14.4",
      "url": "https://hackage.haskell.org/package/attoparsec-0.14.4/attoparsec-0.14.4.tar.gz",
      "sha256": "3f337fe58624565de12426f607c23e60c7b09c86b4e3adfc827ca188c9979e6c",
      "strip_prefix": "attoparsec-0.14.4",
      "cabal_revision": 6,
      "build_type": "Simple",
      "library": {
        "exposed_modules": ["Data.Attoparsec", "Data.Attoparsec.Text"],
        "other_modules": ["Data.Attoparsec.Text.Internal"],
        "hs_source_dirs": ["."],
        "default_language": "Haskell2010",
        "ghc_opts": ["-O2"],
        "generate_paths_module": false,
        "deps": ["array", "base", "bytestring", "scientific", "text"],
        "sublib_deps": ["attoparsec-internal"]
      },
      "sublibraries": {
        "attoparsec-internal": {
          "exposed_modules": ["Data.Attoparsec.ByteString.FastSet"],
          "other_modules": [],
          "hs_source_dirs": ["internal"],
          "default_language": "Haskell2010",
          "generate_paths_module": false,
          "deps": ["array", "base", "bytestring", "text"]
        }
      }
    },
    "crypton": {
      "version": "1.0.6",
      "url": "https://hackage.haskell.org/package/crypton-1.0.6/crypton-1.0.6.tar.gz",
      "sha256": "9c6523e7f46df0bda731e5007a1f6b43b1ee1f0dcd159bed870abbff752b82e6",
      "strip_prefix": "crypton-1.0.6",
      "cabal_revision": 0,
      "build_type": "Simple",
      "library": {
        "exposed_modules": ["Crypto.Hash", "Crypto.Cipher.AES"],
        "other_modules": [],
        "hs_source_dirs": ["."],
        "default_language": "Haskell2010",
        "generate_paths_module": false,
        "deps": ["base", "basement", "bytestring", "ghc-prim", "memory"],
        "select": {
          "linux_arm64": {
            "c_sources": ["cbits/blake2/ref/blake2b-ref.c"],
            "include_dirs": ["cbits/blake2/ref"]
          },
          "linux_x86_64": {
            "other_modules": ["Crypto.Random.Entropy.RDRand"],
            "c_sources": ["cbits/aes/x86ni.c", "cbits/blake2/sse/blake2b.c"],
            "include_dirs": ["cbits/blake2/sse"],
            "cpp_options": ["-DARCH_X86_64", "-DSUPPORT_RDRAND", "-DSUPPORT_SSE"],
            "cc_options": ["-DWITH_AESNI", "-DWITH_PCLMUL"]
          },
          "macos_arm64": {
            "c_sources": ["cbits/blake2/ref/blake2b-ref.c"],
            "include_dirs": ["cbits/blake2/ref"]
          },
          "macos_x86_64": {
            "other_modules": ["Crypto.Random.Entropy.RDRand"],
            "c_sources": ["cbits/aes/x86ni.c", "cbits/blake2/sse/blake2b.c"],
            "include_dirs": ["cbits/blake2/sse"],
            "cpp_options": ["-DARCH_X86_64", "-DSUPPORT_RDRAND", "-DSUPPORT_SSE"],
            "cc_options": ["-DWITH_AESNI", "-DWITH_PCLMUL"]
          }
        }
      }
    },
    "network": {
      "version": "3.2.14.0",
      "url": "https://hackage.haskell.org/package/network-3.2.14.0/network-3.2.14.0.tar.gz",
      "sha256": "cc061f13f3d76f9c227d3ff96a2d3fb70a380d43e1aca6dcc13a91450159675c",
      "strip_prefix": "network-3.2.14.0",
      "cabal_revision": 0,
      "build_type": "Configure",
      "configure_script": "configure",
      "configure_srcs": [
        "config.guess",
        "config.sub",
        "configure",
        "configure.ac",
        "include/HsNet.h",
        "include/HsNetDef.h",
        "include/HsNetworkConfig.h.in",
        "install-sh"
      ],
      "configure_outputs": ["include/HsNetworkConfig.h"],
      "library": {
        "exposed_modules": ["Network.Socket", "Network.Socket.ByteString"],
        "other_modules": ["Network.Socket.Internal"],
        "hs_source_dirs": ["."],
        "default_language": "Haskell2010",
        "c_sources": ["cbits/HsNet.c"],
        "include_dirs": ["include"],
        "install_includes": ["HsNet.h", "HsNetworkConfig.h"],
        "generate_paths_module": false,
        "deps": ["base", "bytestring", "deepseq", "directory", "stm"]
      }
    }
  }
}
```
