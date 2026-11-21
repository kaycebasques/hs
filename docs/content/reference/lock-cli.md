---
title: "Lock Generator CLI Reference"
description: "Complete CLI flag reference and deterministic hackage.lock.json schema specification for @rules_hs//tools/lock:lock."
section: reference
nav_title: "Lock Generator CLI"
order: 30
---

`@rules_hs//tools/lock:lock` (implemented in `tools/lock/Main.hs` over the `//tools/lock:lock_lib` library modules `tools/lock/CabalExtract.hs` and `tools/lock/LockJson.hs`) is `rules_hs`'s dogfooded Hackage lockfile generator.

Built exclusively with GHC's boot libraries (`base`, `Cabal-syntax`, `bytestring`, `containers`, `directory`, `filepath`, `process`, `text`), `//tools/lock:lock` resolves a transitive package closure from a Stackage snapshot, evaluates every `.cabal` file across supported target platforms via `Cabal-syntax`, verifies Hackage tarball SHA-256 checksums, and writes a deterministic `hackage.lock.json` consumed by [`hackage.from_lock`](extensions-and-providers.md#hackage-from_lock).

> **Tip — Haddock API Documentation (`//tools/lock`):** Module-level Haskell API documentation for `tools/lock` (`CabalExtract` and `LockJson`), generated hermetically via [`hs_haddock`](rules.md#hs_haddock) (`//tools/lock:lock_haddock`), is mounted at **[Haddock API (`//tools/lock`)](../haddock/lock/index.html)** (with hyperlinked source and QuickJump `doc-index.json`).

---

## Synopsis {#synopsis}

Run from any downstream workspace using `bazel run`:

```bash
bazel run @rules_hs//tools/lock:lock -- \
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

Or from inside the `rules_hs` repository itself:

```bash
bazel run //tools/lock:lock -- --help
```

> **Important — Working Directory Under `bazel run`:** Because `bazel run` launches executables inside Bazel's runfiles directory rather than your shell's current directory, always pass an absolute path to `--output` (for example, `--output "$PWD/hackage.lock.json"`), and pass absolute paths to `--snapshot-yaml` or `--cabal-config` if using local files.

---

## CLI Flags {#flags}

| Flag | Repeatable | Default | Required | Description |
|---|---|---|---|---|
| `--snapshot <name>` | No | `"lts-24.67"` | No | Stackage snapshot name (`lts-<major>.<minor>` or `nightly-YYYY-MM-DD`). Recorded in the output `snapshot` field and used to fetch the snapshot YAML (`raw.githubusercontent.com/commercialhaskell/stackage-snapshots`) and `cabal.config` (`www.stackage.org/<name>/cabal.config`) unless local paths are supplied. |
| `--snapshot-yaml <path>` | No | `None` (fetched) | No | Read a local Stackage snapshot YAML file (`resolver`, `flags`, `packages`) from `<path>` instead of downloading it. |
| `--cabal-config <path>` | No | `None` (fetched) | No | Read a local Stackage `cabal.config` file from `<path>` to determine `<pkg> installed` boot package constraints instead of downloading it. |
| `--cache-dir <dir>` | No | `"/tmp/rules_hs_lock_cache"` | No | Local cache directory storing downloaded `<snapshot>.yaml`, `<snapshot>.cabal.config`, `cabals/<pkg>-<ver>.cabal`, and `tarballs/<pkg>-<ver>.tar.gz` across invocations. |
| `--ghc-version <ver>` | No | Snapshot compiler (fallback `"9.10.3"`) | No | Override the GHC version used for `Cabal-syntax` `finalizePD` conditionals (`impl(ghc >= ...)`), built-in boot package table selection (`9.10.*` or `9.12.*`), and the output `ghc_version` field. |
| `--package <name>` | **Yes** | — | **Yes** (at least 1) | Root Hackage package name to include. `//tools/lock:lock` resolves the full transitive non-boot dependency closure reachable from all `--package` roots. |
| `--flag <pkg>:<flag>=<bool>` | **Yes** | Stackage snapshot `flags:` | No | Override a Cabal package flag during `finalizePD` evaluation. `<bool>` is case-insensitively `true` or `false` (flag names are normalized to lowercase). Takes precedence over Stackage's snapshot flag defaults. |
| `--boot-pkg <pkg>=<ver>` | **Yes** | Built-in GHC `9.10` / `9.12` boot table | No | Add or override a GHC boot package version in the boot package set and output `boot_packages` map (e.g., `--boot-pkg filepath=1.5.4.0`). |
| `--output <path>` | No | `"hackage.lock.json"` | No | Destination file path for the generated JSON lockfile. |
| `-h`, `--help` | No | — | No | Print usage synopsis to `stdout` and exit with status `0`. |

### Flag Sanitization & Build-Type Normalization

When extracting `.cabal` stanzas, `//tools/lock:lock` automatically performs three hermetic normalizations (`tools/lock/CabalExtract.hs`):

1. **GHC warning & link flag sanitization (`sanitizeGhcOpts`)**: Strips `-Werror`, `-Werror=*`, `-W*`, `-fwarn-*`, `-fno-warn-*`, `-w`, `-threaded`, `-rtsopts`, `-with-rtsopts=*`, `-fllvm`, and `-ferror-spans` from third-party `ghc-options` while preserving semantic and optimization flags (`-O2`, `-funbox-strict-fields`, `-fno-cse`, `-optc-O3`, etc.).
2. **`cabal-doctest` `Custom` normalization**: Packages declaring `build-type: Custom` whose `custom-setup` depends exclusively on `base`, `Cabal`, `Cabal-syntax`, `cabal-doctest`, `filepath`, and `directory` (such as `xml-conduit`) are normalized to `"build_type": "Simple"`.
3. **Autoconf `Configure` inspection**: For `build-type: Configure` packages (`network`, `unix-time`, `old-time`), `//tools/lock:lock` inspects the tarball contents, `<pkg>.buildinfo`, and `configure.ac` to populate `configure_script`, `configure_srcs`, `configure_outputs`, and generated `install_includes` headers (`HsNetworkConfig.h`, `HsTimeConfig.h`).

---

## `hackage.lock.json` Schema {#lockfile-schema}

`//tools/lock:lock` encodes `hackage.lock.json` with deterministic lexicographic map keys, 2-space indentation, and a trailing newline (`tools/lock/LockJson.hs`). Empty optional arrays and empty platform deltas are omitted to keep lockfiles compact and diff-friendly.

### Top-Level Object (`LockFile`)

| Field | JSON Type | Required | Description |
|---|---|---|---|
| `schema_version` | `number` (`int`) | **Yes** | Lockfile schema version. Must be `1` (verified by [`hackage.from_lock`](extensions-and-providers.md#hackage-from_lock)). |
| `snapshot` | `string` | **Yes** | Stackage snapshot name passed to `--snapshot` (e.g., `"lts-24.67"`). |
| `ghc_version` | `string` | **Yes** | Target GHC version evaluated during lock generation (e.g., `"9.10.3"`). |
| `boot_packages` | `object` (`{string: string}`) | **Yes** | Sorted map of GHC boot package name to version string (`"base": "4.20.2.0"`, `"text": "2.1.3"`, etc.). Used by `@hackage` to emit [`hs_toolchain_library`](rules.md#hs_toolchain_library) targets for non-overridden boot packages. |
| `packages` | `object` (`{string: LockedPackage}`) | **Yes** | Sorted map of pinned Hackage package name to its `LockedPackage` specification. |

### Package Object (`packages.<pkg>` — `LockedPackage`)

| Field | JSON Type | Emitted When | Description |
|---|---|---|---|
| `version` | `string` | Always | Exact package version (e.g., `"3.2.14.0"`). |
| `url` | `string` | Always | Official Hackage tarball URL (`https://hackage.haskell.org/package/<pkg>-<ver>/<pkg>-<ver>.tar.gz`). |
| `sha256` | `string` | Always | Lowercase 64-character hex SHA-256 digest of the `.tar.gz` archive. |
| `strip_prefix` | `string` | Always | Top-level archive directory stripped on extraction (`"<pkg>-<version>"`). |
| `cabal_revision` | `number` (`int`) | Always | `x-revision` integer parsed from the fetched `.cabal` file (`0` if unrevised). |
| `build_type` | `string` | Always | Normalized Cabal build type: `"Simple"`, `"Configure"`, or `"Custom"`. |
| `configure_script` | `string` | `build_type == "Configure"` | Relative path to the autoconf script inside the tarball (e.g., `"configure"`). |
| `configure_srcs` | `array[string]` | `build_type == "Configure"` | Sorted list of tarball-relative files staged into `./configure` (`config.guess`, `config.sub`, `install-sh`, `*.h.in`, `*.buildinfo`, `include/*.h`). |
| `configure_outputs` | `array[string]` | `build_type == "Configure"` | Sorted list of generated header paths produced by `./configure` (e.g., `["include/HsNetworkConfig.h"]`). |
| `library` | `ComponentSpec` | Package has a buildable main `library` | Common and per-platform build metadata for the package's primary library component. |
| `sublibraries` | `object` (`{string: ComponentSpec}`) | Main library transitively references internal Cabal `library <sublib>` stanzas | Sorted map of internal sublibrary name (e.g., `"attoparsec-internal"`) to its `ComponentSpec`. |

### Component Object (`library` & `sublibraries.<sublib>` — `ComponentSpec`)

`//tools/lock:lock` evaluates every component across four platforms (`linux_x86_64`, `linux_arm64`, `macos_arm64`, `macos_x86_64`). Items present on **all** evaluated platforms are placed in the component's common top-level fields; items specific to a subset of platforms are placed under `select.<platform>`.

| Field | JSON Type | Emitted When | Description |
|---|---|---|---|
| `exposed_modules` | `array[string]` | Always (`[]` for C-only packages) | Common exposed Haskell module names across all platforms. |
| `other_modules` | `array[string]` | Always | Common internal (`other-modules` / non-`Paths_*` `autogen-modules`) Haskell module names. |
| `reexported_modules` | `array[string]` | Non-empty | Common Cabal `reexported-modules` entries. |
| `hs_source_dirs` | `array[string]` | Always | Common relative Haskell source directories (defaults to `["."]`). |
| `default_language` | `string` | Always | Cabal `default-language` (`"Haskell98"`, `"Haskell2010"`, `"GHC2021"`, `"GHC2024"`). |
| `default_extensions` | `array[string]` | Non-empty | Common language extensions enabled across all platforms. |
| `ghc_opts` | `array[string]` | Non-empty | Common sanitized GHC compiler options. |
| `c_sources` | `array[string]` | Non-empty | Common relative C source file paths. |
| `include_dirs` | `array[string]` | Non-empty | Common relative C header directories. |
| `install_includes` | `array[string]` | Non-empty | Common public C headers exported to downstream dependents. |
| `cpp_options` | `array[string]` | Non-empty | Common C preprocessor options (`-D...`). |
| `cc_options` | `array[string]` | Non-empty | Common C compiler options. |
| `extra_libraries` | `array[string]` | Non-empty | Informational system C library names declared in Cabal `extra-libraries:` (link external C libs hermetically via [`hackage.override`](extensions-and-providers.md#hackage-override) `extra_cc_deps`). |
| `generate_paths_module` | `boolean` | Always | `true` if `Paths_<pkg>` appears in `other-modules` or `autogen-modules` on any platform. |
| `deps` | `array[string]` | Always | Common package dependencies (referencing `@<hub>//:<dep>`). |
| `sublib_deps` | `array[string]` | Non-empty | Common dependencies on internal sublibraries within the same package (referencing `:<sublib>`). |
| `select` | `object` (`{PlatformKey: PlatformDelta}`) | At least one platform has a non-empty delta | Per-platform delta map keyed by `"linux_arm64"`, `"linux_x86_64"`, `"macos_arm64"`, and `"macos_x86_64"`. Translated into Bazel `select({...})` expressions by [`hackage.from_lock`](extensions-and-providers.md#hackage-from_lock). |

### Platform Delta Object (`select.<platform>` — `PlatformDelta`)

Each `PlatformDelta` object contains **only** the non-empty array fields from `{exposed_modules, other_modules, reexported_modules, hs_source_dirs, default_extensions, ghc_opts, c_sources, include_dirs, install_includes, cpp_options, cc_options, extra_libraries, deps, sublib_deps}` that apply on that platform in addition to the component's common fields.

### Annotated Example (`hackage.lock.json` Excerpt)

The excerpt below (drawn directly from `examples/size/hackage.lock.json`) illustrates a `Configure` package (`network`), an internal sublibrary package (`attoparsec`), and platform `select` deltas (`crypton`):

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
    }
  }
}
```
