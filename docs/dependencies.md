# `rules_hs` Dependency Decision Record

This document records every dependency evaluated across [`rules_hs`](../MODULE.bazel) and its standalone showcase [`examples/size`](../examples/size/MODULE.bazel) — covering both **adopted** dependencies and **not-adopted** (rejected or deferred) alternatives.

For every entry, we state:
- **What it is** (exact version, artifact, or role evaluated).
- **Why** we adopted it (or why we did not).
- **Catalysts**: the concrete conditions (*"if X, Y, and Z changed..."*) that would trigger reconsidering an adopted dependency or adopting a rejected/deferred alternative as a default or first-class option.

> For system design and implementation internals, see [`docs/architecture.md`](architecture.md).

---

## Executive Summary

| Category | Adopted | Not Adopted (Rejected / Deferred) | Primary Deciding Factor |
|---|---|---|---|
| **1. C/C++ Toolchains** *(dev & showcase; `rules_hs` is C-toolchain agnostic)* | `hermetic_cc_toolchain@4.3.0` (`zig cc`, `gnu.2.32`, dev-only in root) | Pigweed `pw_toolchain/host_clang`, `toolchains_llvm@1.13.0` + Debian sysroot, host GCC/Clang (`rules_cc` default) | BCR-native, single-module multi-arch Linux (`x86_64` + `arm64`) hermeticity with zero external sysroot maintenance; Pigweed is non-BCR/monolithic + glibc `2.27` |
| **2. GHC Distribution & Version** | Official Haskell.org `deb10` glibc bindists, GHC `9.10.3` (`x86_64` + `aarch64`), pure-Starlark extraction + `$ORIGIN` staging | `alpine3_12-linux-static-int_native` (musl), `rules_nixpkgs` / Nix, GHC `9.12.4` / `9.14.1` as default | `x86_64` + `arm64` parity, full dynamic TH + C FFI, clean BCR `CcInfo` interop, RBE/BCR friendliness, Stackage LTS 24.x stability |
| **3. Native Runtime & Compiler Libraries** | BCR `gmp@6.3.0.bcr.5` (`libgmp.so.10` + static `libgmp.a`), in-tree 8-symbol `libtinfo.so.6` stub, GHC-bundled `libffi.so.8`/`libCffi.a` | Full BCR `ncurses` build, host `libgmp-dev` / `libtinfo5` (`apt install`) | Zero host C `-dev` libraries, base-glibc-only user binary `DT_NEEDED`, avoids heavy `ncurses`/`gawk` graph for 8 unused batch-compiler symbols |
| **4. Bazel Rule Foundations & Action Wrappers** | `platforms@1.1.0`, `bazel_skylib@1.9.2`, `rules_cc@0.2.28`, dev-only `rules_shell@0.6.1`, native C11 `ghc_cc_wrapper` | `rules_python` + Python `cc_wrapper.py` / `cabal_wrapper.py`, legacy non-dev deps (`rules_java`, `protobuf`, `rules_nodejs`, `aspect_rules_js`, `rules_sh`, non-dev `stardoc`) | Bazel 9+ clean minimal non-dev `MODULE.bazel` graph; zero Python runtime in build actions |
| **5. 3p Hackage Resolution & Build Pipeline** | Dogfooded boot-only `//tools/lock` (`Cabal-syntax`) + Stackage LTS -> `hackage.lock.json` -> pure-Starlark `hackage` ext + 5-stage `hs_cabal_library` | `stack_snapshot` (Stack CLI + YAML pinning), pure-Starlark `.cabal` parser, opaque `cabal-install` / `runghc Setup.hs` actions | 100% Cabal spec fidelity with zero host `cabal`/`stack`/`python`, `reproducible = True` Bzlmod eval, fine-grained parallel caching & `CcInfo` propagation |
| **6. Showcase App 3p Haskell Libraries** (`examples/size`, 69 Hackage + 41 boot pkgs on `lts-24.67`) | `xml-conduit` `1.10.1.0`, `http-client` `0.7.19` + `http-client-tls` `0.3.6.4` + `http-types` `0.12.6`, `zlib` `0.7.1.1` (`bundled-c-zlib=true` / `zlib-clib` `1.3.2`), `async` `2.2.6` | `xml`, `xeno`, `hexml`, `hexpat`, `hxt`, `xmlbf`; `http-conduit`, `req`, `wreq`, `http-client-openssl`; BCR `@zlib` default, system `libz.so.1`; raw `Control.Concurrent`, `ki`, `streamly` | Idiomatic spec-compliant XML, pure-Haskell TLS (zero OpenSSL), zero host C libs (`zlib-clib`), zero-cost `async`, minimal 69-pkg closure |

---

## 1. C/C++ Toolchains (Dev & Showcase Hermeticity)

> **Crucial architectural boundary**: `rules_hs` itself is **100% C-toolchain agnostic**. Every rule queries `@bazel_tools//tools/cpp:toolchain_type` through `rules_cc` (`find_cc_toolchain` + `cc_common`) and forwards any resolved `--sysroot` and `--target` flags into [`ghc_cc_wrapper`](../hs/private/cc_wrapper.c). Neither `hermetic_cc_toolchain` nor any other concrete C toolchain is a non-dev dependency of `rules_hs` (in [`MODULE.bazel`](../MODULE.bazel), `hermetic_cc_toolchain` is strictly `dev_dependency = True`). Downstream consumers can bring any compliant Linux `cc_toolchain`.

### Adopted (Dev & Showcase)

#### `hermetic_cc_toolchain@4.3.0` (`zig cc`, glibc `gnu.2.32`)

- **What & Role**: BCR-hosted Zig-based hermetic C/C++ toolchain (Zig `0.15.2`), registered as `dev_dependency = True` in [`MODULE.bazel`](../MODULE.bazel) and directly in [`examples/size/MODULE.bazel`](../examples/size/MODULE.bazel), with `@zig_sdk//toolchain:linux_amd64_gnu.2.32` and `@zig_sdk//toolchain:linux_arm64_gnu.2.32` registered ahead of `@zig_sdk//toolchain/...`.
- **Why**:
  - **Single BCR module, zero external sysroot maintenance**: Provides hermetic `linux_x86_64` and `linux_arm64` C/C++ compilation and linking (plus optional `musl` targeting) with zero host `gcc`/`clang`/`libc-dev` and zero manually mirrored Debian sysroot tarballs.
  - **Exact glibc compatibility window (`gnu.2.32`)**: By default, `@zig_sdk//toolchain/...` selects `gnu.2.17` alphabetically, which fails to link GHC `deb10`'s `libCffi.a` (`undefined symbol: memfd_create`, glibc `2.27`; `statx`/`fcntl64`, glibc `2.28`). Pinning `gnu.2.32` satisfies both GHC `deb10` bindists (`glibc <= 2.28`) **and** BCR `gmp@6.3.0.bcr.5`'s `m4` dependency (which includes Zig's `<sys/single_threaded.h>`, requiring `glibc >= 2.32`), while produced binaries remain portable across Debian 12 (`2.36`), Ubuntu 22.04 (`2.35`) / 24.04 (`2.39`), and Rocky Linux 9 (`2.34`).
  - **Verified Hackage compatibility**: All specialized Hackage `cc-options` in `examples/size` (`bitvec` `-fopenmp-simd`, `crypton` `-std=gnu99 -DWITH_AESNI -DWITH_PCLMUL -DWITH_TARGET_ATTRIBUTES`, `primitive` `-ftree-vectorize -msse2`, `unix-time` `-fPIC`) compile cleanly.
  - **Quirks cleanly isolated**: All six verified `zig cc` <-> GHC mismatches (`-fno-PIC`, `-Wl,-h`, `.dyn_o`/`.p_o`, `--print-file-name`, `-Wno-unused-command-line-argument`, and `zig c++`'s `libcxx/include/stddef.h` ordering fixed via `-nostdinc++`) are encapsulated once in [`hs/private/cc_wrapper.c`](../hs/private/cc_wrapper.c).
  - **Ecosystem alignment**: Matches sibling Bazel 9 polyglot projects (such as the reference `size` multi-language repository).
- **Catalysts to reconsider or replace**:
  - If a lightweight BCR Clang/`lld` toolchain ships built-in, SHA-256-pinned multi-arch (`x86_64` + `arm64`) Linux glibc `>= 2.32` sysroots — eliminating both the `.bazelrc` `/tmp` cache mount (`HERMETIC_CC_TOOLCHAIN_CACHE_PREFIX=/tmp/zig-cc-cache` + `--sandbox_add_mount_pair=/tmp`) and the `zig cc` workarounds in `cc_wrapper.c`.
  - If Remote Build Execution (RBE) fleets prohibit `--sandbox_add_mount_pair=/tmp`, causing Zig's compiler cache to rebuild cold on every remote action and degrading build latency.
  - If upstream Zig / `hermetic_cc_toolchain` regresses versioned glibc linking, breaks under future Bazel `rules_cc` rule-based toolchains, or breaks C++ FFI Hackage packages that require `libstdc++` ABI compatibility instead of Zig's bundled `libc++`.

### Not Adopted

#### Pigweed C/C++ Toolchains (`pw_toolchain/host_clang:host_cc_toolchain_linux`)

- **What & Role**: Google Pigweed's rule-based host Clang toolchain — Fuchsia Clang 24 + `lld` + `llvm-ar` + `compiler-rt` + `libunwind` configured with modern `rules_cc` (`cc_toolchain` + `cc_sysroot`) and CIPD `fuchsia/third_party/sysroot/bionic` (`x86_64` and `aarch64`).
- **Why Not Adopted** *(evaluated live against cached Pigweed LLVM + Linux sysroot)*:
  - **What worked remarkably well**: Real Clang 24 + `lld` + `cc_sysroot` avoided **all 5 core `zig cc` quirks** (`-fno-PIC` worked natively, `.dyn_o` and `-Wl,-h` worked, `--print-file-name=libm.a` resolved hermetically inside the sysroot, and C headers never clashed with `libcxx/include`). It only needed `-optl-no-pie` for non-PIC static GHC `.a` archives (the same flag Pigweed uses for `cgo_link_flags`).
  - **Blocker 1 — Non-BCR & monolithic dependency graph**: Pigweed is not published on BCR (`404`) and does not ship a standalone `pw_toolchain` Bzlmod module. Consuming it drags in its monolithic 892-line `MODULE.bazel`, pulling CIPD infrastructure alongside `rules_android`, `rules_java`, `rules_go`, `rules_rust`, `protobuf`, `pico-sdk`, and `zephyr` — completely antithetical to `rules_hs`'s minimal dependency graph.
  - **Blocker 2 — Sysroot glibc version mismatch**: `fuchsia/third_party/sysroot/bionic` targets **glibc `2.27`** (it provides `memfd_create@@GLIBC_2.27`, but **lacks `statx` and `fcntl64@GLIBC_2.28`** referenced by GHC's `deb10` `x86_64` and `aarch64` bindists; GHC's older `ubuntu18_04` glibc `2.27` bindist is `x86_64`-only).
- **Catalysts to adopt**:
  - If Pigweed extracts and publishes a standalone, zero-bloat `pw_toolchain` module to BCR (no Android/Java/Go/Rust/Zephyr/pico-sdk transitive deps, pure HTTPS artifact fetches without mandatory CIPD).
  - **And** Pigweed's Linux `cc_sysroot` upgrades to **glibc `>= 2.28`** (or `>= 2.32` if required by BCR `gmp`/`m4`, e.g., Debian 11/12 multi-arch `x86_64` + `aarch64`).
  - Under those two conditions, `pw_toolchain` would become a top candidate to replace `hermetic_cc_toolchain` as our dev/showcase default, yielding pure Clang + `lld` without `/tmp` cache mounts or Zig flag rewrites.

#### `toolchains_llvm@1.13.0` (BCR) + Debian Sysroot

- **What & Role**: BCR-native LLVM/Clang + `lld` toolchain (`toolchains_llvm@1.13.0`) configured via `llvm.sysroot(...)` against an external Debian `>= 10` (`glibc >= 2.28`, e.g., Debian 12 `2.36`) sysroot tarball.
- **Why Not Adopted (Deferred as Default; Supported for Consumers)**:
  - Gives the exact same Clang + `lld` cleanliness observed with Pigweed (zero `zig cc` quirks, zero `/tmp` sandbox mount, clean RBE story) while remaining lightweight and BCR-native.
  - Deferred as the out-of-the-box dev/showcase default strictly because `toolchains_llvm` does not bundle Linux glibc sysroots itself: adopting it requires provisioning, hosting, hashing, and maintaining external multi-arch (`linux_x86_64` + `linux_arm64`) Debian sysroot tarballs (either built via custom `mmdebstrap`/`debootstrap` CI or relying on third-party Chromium/custom sysroot mirrors). It also lacks built-in `musl` targeting.
- **Catalysts to adopt**:
  - If `toolchains_llvm` (or a well-maintained BCR `linux_sysroot` module) publishes official, SHA-256-pinned, multi-arch (`x86_64` + `arm64`) Debian `>= 10` sysroots directly in BCR with zero consumer tarball hosting.
  - Or if RBE-first requirements forbid `--sandbox_add_mount_pair=/tmp` or demand full Clang + `libstdc++` without Zig's `libc++` defaults — making `toolchains_llvm` + Debian sysroot the immediate first-class recommendation (and dev CI secondary matrix target).

#### Auto-detected Host GCC/Clang (`rules_cc` Default)

- **What & Role**: Bazel's default `local_config_cc` host auto-detection against `/usr/bin/gcc`, `/usr/bin/clang`, system `ld`, and `/usr/include`.
- **Why Not Adopted**:
  - Non-hermetic: leaks host compiler versions, distro headers, and host glibc symbol versions into build artifacts.
  - Fails outright in bare Linux containers (`debian:bookworm-slim`, `ubuntu:24.04`, `rockylinux:9` with zero compilers installed, asserted in [`.github/workflows/ci.yml`](../.github/workflows/ci.yml)).
  - Breaks cross-distro binary portability and poisons Remote Build Execution (RBE) cache keys across heterogeneous developer workstations.
- **Catalysts to adopt**:
  - **Never** as `rules_hs`'s dev or showcase default.
  - Attractive **only as a consumer-side opt-in** when an organization already runs locked, immutable Linux build containers or RBE worker images with a pinned distro toolchain and intentionally wants host GCC/Clang ABI alignment (e.g., dynamically linking corporate system C++ libraries). *(Note: [`hs/private/cc_wrapper.c`](../hs/private/cc_wrapper.c) already supports standard `cc_toolchain`s; gating `-nostdinc++` on compiler flavor would further harden host-GCC builds under `-Werror`.)*

---

## 2. GHC Distribution & Version

### Adopted

#### Official Haskell.org `deb10` glibc Bindists — GHC `9.10.3` (`x86_64` + `aarch64`)

- **What & Role**: Official `ghc-9.10.3-{x86_64,aarch64}-deb10-linux.tar.xz` bindists pinned by URL and SHA-256 in [`hs/private/ghc_versions.bzl`](../hs/private/ghc_versions.bzl), extracted via pure-Starlark `repository_ctx.download_and_extract` (zero `./configure && make install`), sanitized in `lib/settings`, and `$ORIGIN`-staged by [`hs/private/staged_ghc.bzl`](../hs/private/staged_ghc.bzl).
- **Why**:
  - **Multi-arch Linux parity**: Official upstream bindists exist with identical directory and linking structure for both `linux_x86_64` and `linux_arm64` (`aarch64`).
  - **Broad Linux distro compatibility**: Ceiling is `<= GLIBC_2.28` (`memfd_create`/`expf`/`logf`/`powf@GLIBC_2.27`; `fcntl64`/`statx@GLIBC_2.28`), running natively on Debian 10+, Debian 12 (`2.36`), Ubuntu 22.04/24.04 (`2.35`/`2.39`), Rocky 8+/9 (`2.28`/`2.34`), and distroless `cc-debian12`.
  - **Minimal dynamic surface & zero `LD_LIBRARY_PATH`**: Ships bundled `libffi.so.8` + `libCffi*.a` with zero `libnuma` dependency; only `libgmp.so.10` and `libtinfo.so.6` are external, and both resolve cleanly via GHC's baked-in `$ORIGIN/../lib/<arch>-linux-ghc-9.10.3` `RUNPATH` with zero `patchelf` and zero `LD_LIBRARY_PATH`.
  - **Full Template Haskell + C FFI**: Built with `GHC Dynamic = YES` (`ghc-iserv-dyn`), verified live on cross-package TH splices invoking `runIO`, `withCString`, `strlen`, and `CApiFFI`.
  - **Ecosystem sweet spot (`9.10.3`)**: Matches `ghcup` `Recommended` (`base-4.20.2.0`) and Stackage **LTS 24.x** (`lts-24.67`), delivering stable, CI-vetted Hackage closures without Nightly churn.
  - **Zero host build tools at fetch time**: Pure-Starlark extraction + `package.conf.d/*.conf` parsing replaces `rules_haskell`'s `./configure && make install` repo rule (eliminating host `make`/`perl`/`gcc` requirements and 30-minute fetch timeouts).
- **Catalysts to reconsider or replace**:
  - If upstream GHC retires `deb10` bindists in favor of `deb11`/`deb12` (raising the minimum glibc floor above Rocky 8 / older LTS images) — triggering a bindist family update in [`hs/private/ghc_versions.bzl`](../hs/private/ghc_versions.bzl).
  - If Stackage promotes a stable GHC `9.12.x` LTS release and `ghcup` advances `Recommended` to `9.12.x` — triggering a one-line bump of `DEFAULT_GHC_VERSION` to `"9.12.4"` (already pre-wired in `ghc_versions.bzl`).
  - If upstream GHC begins publishing official dynamic Linux bindists with native bignum (`--bignum=native`) or statically-linked GMP and no `libtinfo` dependency — letting us simplify `staged_ghc.bzl` and drop non-dev `@gmp` and the `libtinfo.so.6` stub.

### Not Adopted

#### `alpine3_12-linux-static-int_native` (`musl` Static + Native Bignum)

- **What & Role**: Official Haskell.org 100% static ELF bindist (`PT_INTERP = NONE`, `DT_NEEDED = NONE`, `--bignum=native`), already cataloged as `linux_x86_64_musl` in [`hs/private/ghc_versions.bzl`](../hs/private/ghc_versions.bzl).
- **Why Not Adopted as Default** *(audited live against GHC `9.10.3` + `zig cc`)*:
  1. **`x86_64`-only**: Upstream GHC publishes no `aarch64` (`linux_arm64`) static Alpine bindist for GHC `9.10`, `9.12`, or `9.14`.
  2. **Template Haskell + C FFI segfaults**: Because `ghc` is statically linked (`GHC Dynamic = NO`), TH falls back to the internal ELF RTS linker, which calls `--print-file-name=libm.a` (leaking host `/usr/lib/x86_64-linux-gnu/libm.a` linker scripts under Zig -> `loadArchive: Not an archive`), and even after supplying Zig's musl `libc.a` + `libcompiler_rt.a` via `-B`, cross-package TH splices calling `withCString`/`malloc` **segfault** in both `ghc` and `ghc-iserv` due to dual-musl `libc.a` clashes.
  3. **glibc ABI mismatch**: Cannot link against glibc `cc_toolchain`s (`undefined symbol: posix_spawn_file_actions_addchdir_np` in `libHSprocess.a` on glibc `<= 2.28`, plus musl/glibc struct layout mismatches), forcing every BCR `cc_library` dependency (`@zlib`, etc.) onto `@zig_sdk//libc:musl`.
  4. **Hackage GMP flag friction**: Uses `bignum = native`, requiring consumers to override default GMP flags on packages like `crypton` (`integer-gmp=false`) and `cborg` (`optimize-gmp=false`) and forfeiting GMP arbitrary-precision performance.
- **Catalysts to adopt**:
  - **As a first-class opt-in flavor** (for `FROM scratch` zero-glibc static `x86_64` binaries without runtime TH + C FFI splices — note `examples/size`'s 69-pkg graph has 0 runtime TH splices!): Wire a musl platform constraint matching `@zig_sdk//libc:musl`, expose a `libc = "musl"` / flavor selector on `hs.toolchain(...)`, and document the `crypton`/`cborg` lockfile flags.
  - **As the default Linux bindist**: Would require (a) upstream GHC publishing official `aarch64` static musl bindists alongside `x86_64`, (b) upstream fixing the static RTS linker / `ghc-iserv` dual-libc crash on TH + C FFI, and (c) broad BCR `cc_library` support for musl builds.

#### `rules_nixpkgs` / Nix-Managed GHC

- **What & Role**: Provisioning GHC and its C runtime libraries (`gmp`, `ncurses`, `libffi`) via Nix expressions populating `/nix/store` (the hermetic Linux path used by `tweag/rules_haskell`).
- **Why Not Adopted**:
  - Requires a host Nix installation and mutates `/nix/store` during repository fetch, breaking Remote Build Execution (RBE), clean Docker/CI containers without a Nix daemon, and Bazel Central Registry (BCR) downstream consumption (`rules_haskell` issue #2451).
  - Imposes a heavyweight secondary build/package ecosystem on teams that chose Bazel specifically to avoid multi-tool orchestration.
- **Catalysts to adopt**:
  - **Never** as a dependency or default in `rules_hs`.
  - Attractive **only as an external consumer-provided `hs_toolchain`** when an organization already standardizes on Nix across its entire RBE worker fleet and needs custom-patched GHC builds or niche system C libraries unavailable in BCR.

#### GHC `9.12.4` / `9.14.1` as Default Version

- **What & Role**: Newer GHC release series (`9.12.4` with `base-4.21.2.0` tracking Stackage Nightly; `9.14.1` tagged `Latest` in `ghcup`).
- **Why Not Adopted as Default**:
  - `9.12.4` currently tracks **Stackage Nightly** rather than an LTS series, bringing moving-target package churn (+5 packages in `examples/size`: 74 vs. 69, plus newer Cabal features like `reexported-modules` in `crypton-asn1-encoding`/`crypton-asn1-parse` and `autogen-modules` in `mlkem`).
  - `9.14.1` is too recent for broad Hackage upper-bound compatibility.
  - *(Note: `rules_hs` is already forward-compatible with `9.12.4`: all six platform URLs, SHA-256 checksums, and `BOOT_PACKAGE_NAMES` including `file-io` are pre-wired in [`hs/private/ghc_versions.bzl`](../hs/private/ghc_versions.bzl), and `reexported-modules` is already implemented in `hs_cabal_library` and `//tools/lock`.)*
- **Catalysts to adopt as default**:
  - Stackage cuts a stable **LTS series** for GHC `9.12.x` (e.g., LTS 25+), `ghcup` promotes `9.12.x` to `Recommended`, and the full `rules_hs` + `examples/size` CI matrix passes cleanly on that LTS. (Same criteria apply to `9.14.x` in a subsequent release cycle.)

---

## 3. Native Runtime & Compiler Libraries

### Adopted

#### BCR `gmp@6.3.0.bcr.5`

- **What & Role**: Non-dev BCR dependency in [`MODULE.bazel`](../MODULE.bazel) serving two distinct roles in [`hs/private/staged_ghc.bzl`](../hs/private/staged_ghc.bzl):
  1. **Compiler runtime (`libgmp.so.10`)**: Built hermetically from `@gmp//:gmp`'s PIC archive via `HsLinkGmpShared` (`-shared -Wl,-soname,libgmp.so.10 -Wl,--whole-archive`) and `$ORIGIN`-staged inside `<prefix>/lib/<arch_libdir>/` for GHC's own dynamic binaries.
  2. **User binaries (`libgmp.a`)**: Symlinked into a dedicated static-only directory `<prefix>/gmp_static/libgmp.a` (with zero `.so` present) and passed via `-optl-L` during `HsLinkExecutable`, statically linking `ghc-bignum` so produced user binaries carry **zero `libgmp.so.10`** in `DT_NEEDED`.
- **Why**:
  - Eliminates host `libgmp-dev` / `libgmp10` completely while matching GHC `deb10`'s unversioned `__gmpn_*` ABI.
  - Produces portable, self-contained user executables whose `DT_NEEDED` is strictly base glibc (`libc.so.6`, `libm.so.6`, `libdl.so.2`, `libpthread.so.0`).
  - **Known constraint**: BCR `gmp@6.3.0.bcr.5` pulls BCR `m4` as a build tool; under Zig (`hermetic_cc_toolchain`), compiling `m4` includes `<sys/single_threaded.h>`, which requires glibc `>= 2.32` (forcing `gnu.2.32` rather than `gnu.2.28` in `.bazelrc`/`MODULE.bazel`).
- **Catalysts to reconsider or replace**:
  - If upstream GHC switches its default Linux bindists away from GMP to `ghc-bignum`'s `native` backend — letting `rules_hs` drop `gmp` from its non-dev `MODULE.bazel` dependencies completely.
  - If downstream `hermetic_cc_toolchain` users need binary portability down to glibc `2.28`–`2.31` (e.g., Rocky Linux 8, Ubuntu 20.04, Debian 10) — catalyst to patch/eliminate `gmp`'s `m4` `<sys/single_threaded.h>` glibc `>= 2.32` requirement or pair with `toolchains_llvm` + a glibc `2.28` sysroot.
  - If a commercial consumer's LGPL compliance policy disallows static linking of `libgmp.a` into proprietary executables — catalyst to add a toolchain/rule option (`link_gmp_static = False`) staging `libgmp.so.10` alongside the binary or opting into `bignum = native`.

#### In-Tree `libtinfo.so.6` Stub (`hs/private/tinfo_stub.c` + `hs/private/tinfo_stub.lds`)

- **What & Role**: Minimal in-tree C11 shared library ([`hs/private/tinfo_stub.c`](../hs/private/tinfo_stub.c), 56 lines incl. comments) linked with a 13-line linker version script ([`hs/private/tinfo_stub.lds`](../hs/private/tinfo_stub.lds)) exporting the exact 8 symbols versioned `@NCURSES6_TINFO_5.0.19991023` (`setupterm`, `del_curterm`, `set_curterm`, `tigetflag`, `tigetnum`, `tigetstr`, `tparm`, `tputs`), `$ORIGIN`-staged into `<prefix>/lib/<arch_libdir>/`.
- **Why**:
  - Auditing every binary and `.so` inside GHC `9.10.3` `deb10` (`x86_64` and `aarch64`) proved that `libtinfo.so.6` is imported **exclusively** by `libHSterminfo` for interactive GHCi/haskeline terminal capability queries.
  - Returning the standard terminfo error/NULL sentinels causes `terminfo` to fall back cleanly to dumb-terminal mode in batch Bazel build actions — compiling in milliseconds with **zero external dependencies** (no host `libtinfo5`/`libtinfo6`, no BCR `ncurses`/`gawk`).
- **Catalysts to reconsider or replace**:
  - If a future GHC release imports additional `libtinfo` symbols or changes the ncurses symbol version tag beyond `NCURSES6_TINFO_5.0.19991023` (trivial update if small; signal to reconsider real `ncurses` if the surface grows large).
  - If `rules_hs` introduces a first-class interactive REPL rule (`hs_repl` / `bazel run` GHCi with rich `haskeline` line-editing and ANSI colors) or a user target links `@hs_boot//:terminfo` expecting live terminal capabilities — catalyst to add an opt-in real `ncurses` `libtinfo` provider for interactive targets while retaining the zero-dep stub for batch compilation.
  - If upstream GHC removes the `libtinfo` dynamic import from non-interactive compiler binaries — allowing us to delete the stub outright.

#### GHC-Bundled `libffi.so.8` & `libCffi*.a`

- **What & Role**: Pre-built `libffi.so.8` (for GHC's own dynamic runtime via `$ORIGIN`) and `libCffi*.a` (statically linked into user executables) shipped directly inside official GHC `deb10` bindists under `lib/<arch>-linux-ghc-<ver>/`.
- **Why**:
  - Already hermetically bundled, ABI-matched to GHC's `rts`, requires zero extra BCR dependency (`libffi`) or host `libffi-dev`, and leaves zero `libffi.so.8` entry in user binary `DT_NEEDED`.
- **Catalysts to reconsider or replace**:
  - If upstream GHC switches official Linux bindists to `--with-system-libffi` (dropping bundled `libffi.so.8` / `libCffi.a`) — catalyst to adopt a BCR `libffi` module and stage/static-link it identically to `gmp`.
  - If a polyglot C/C++ consumer statically links a separate `libffi` version via `cc_deps`, causing duplicate symbol collisions with GHC's `libCffi.a` — catalyst to expose a toolchain override substituting a shared BCR `@libffi` target.

### Not Adopted

#### Full BCR `ncurses` Build

- **What & Role**: Building full `ncurses` (and its `libtinfo.so.6`) from BCR to satisfy GHC's `libtinfo.so.6` import.
- **Why Not Adopted**:
  - Pulls a heavy transitive build graph (`ncurses`, `gawk`, terminfo database compilation, autoconf scripts) into every consumer's non-dev module graph solely to satisfy 8 unused interactive terminal query symbols in batch compilation actions — adding cold-build overhead and supply-chain surface for zero functional benefit.
- **Catalysts to adopt**:
  - If a lean, zero-`gawk` BCR `tinfo`-only target becomes available **and** `rules_hs` adds a first-class interactive GHCi/REPL target requiring full `haskeline`/terminfo behavior (still scoped as opt-in or dev/REPL-only rather than required for batch compilation).
  - Or if future GHC releases depend on a broad set of `ncurses`/`tinfo` behaviors during batch compilation where dumb-terminal error sentinels fail.

#### Host System `libgmp-dev` / `libtinfo5` / `libtinfo6` (`apt install`)

- **What & Role**: Requiring pre-installed OS packages on the host or CI image (the pattern used in `tweag/rules_haskell`'s BCR `1.0` `presubmit.yml`: `sudo apt install libtinfo5 libgmp-dev`).
- **Why Not Adopted**:
  - Directly violates hermeticity and fails on clean containers (`debian:bookworm-slim`, `ubuntu:24.04`, `rockylinux:9` verified with zero C `-dev` headers in [`.github/workflows/ci.yml`](../.github/workflows/ci.yml)).
  - Fragile across distros (`libtinfo5` was dropped in Ubuntu 24.04 and Debian 13 in favor of `libtinfo6`), breaks RBE portability, and leaks dynamic `libgmp.so.10` runtime dependencies into user binaries.
- **Catalysts to adopt**:
  - **Never** as default in `rules_hs`.
  - Only plausible as a consumer-configured escape hatch in tightly controlled enterprise environments mandated to dynamically link centrally patched OS shared libraries across all deployed binaries.

---

## 4. Bazel Rule Foundations & Action Wrappers

### Adopted

#### Minimal BCR Non-Dev Modules (`platforms@1.1.0`, `bazel_skylib@1.9.2`, `rules_cc@0.2.28`) + Dev-Only `rules_shell@0.6.1`

- **What & Role**: Core Bazel 9 Bzlmod foundation in [`MODULE.bazel`](../MODULE.bazel): OS/CPU constraint values (`platforms`), standard Starlark helpers (`bazel_skylib`), `cc_toolchain` / `cc_common` / `CcInfo` integration (`rules_cc`), plus shell test rules (`rules_shell`, strictly `dev_dependency = True`). Together with `gmp@6.3.0.bcr.5`, `rules_hs` has only **4 direct non-dev `bazel_dep`s**.
- **Why**:
  - Matches modern Bazel 9 Bzlmod-only rulesets (`rules_zig`, `rules_dotnet`, `rules_rust`, `rules_go`) with explicit `bazel_compatibility = [">=9.0.0"]` and zero `WORKSPACE` files.
  - Keeps downstream `bazel mod graph` lean and ensures test-only dependencies (`rules_shell`, `hermetic_cc_toolchain`) never leak to consumers.
  - **Transitive BCR nuance (verified via `bazel mod graph`)**: `rules_cc@0.2.28` itself declares a transitive BCR dependency on `protobuf@33.4` (which remains unfetched unless referenced), while `rules_hs` declares zero `protobuf`, `rules_java`, `rules_python`, `rules_nodejs`, or `rules_nixpkgs`.
- **Catalysts to reconsider or replace**:
  - **Upgrade `rules_cc`**: As soon as a newer `rules_cc` release removes its transitive `protobuf` BCR dependency, bump `rules_cc` to make the entire resolved module graph even cleaner.
  - **Add `bazel_features`**: If Bazel 10 introduces Starlark API changes requiring conditional feature detection across Bazel 9 and 10, adding the tiny pure-Starlark `bazel_features` BCR module is justified.
  - **Drop dev-only `rules_shell`**: If all ELF/hygiene integration tests are rewritten in pure Haskell (`hs_test`) or Starlark analysis tests, even dev-only `rules_shell` can be removed.

#### Native C11 `ghc_cc_wrapper` (`hs/private/cc_wrapper.c`)

- **What & Role**: Self-contained 460-line POSIX C11 binary compiled once by Bazel's active `cc_toolchain`, invoked by GHC (`-pgmc`, `-pgmcxx`, `-pgml`, `-pgma`, `-pgmP`, `-pgmCmmP`), `hsc2hs` (`--cc`, `--ld`), and Cabal `./configure` (`CC`, `CXX`).
- **Why**:
  - Zero Python interpreter or `rules_python` dependency anywhere in the build graph; sub-millisecond startup overhead across hundreds of compile/link/configure actions.
  - Centralizes Bazel `RUNFILES_*` environment scrubbing, generic `cc_toolchain` `--sysroot`/`--target` passthrough (`RULES_HS_CC_EXTRA_ARGS`), and all six `zig cc`/Clang <-> GHC compatibility rewrites (`--print-file-name`, `-Wl,-h` -> `-Wl,-soname` including `@response_file`s, `-fuse-ld=gold`, `-fno-PIC` -> `-fPIC`, `.dyn_o`/`.p_o` temp symlinks, `-Wno-unused-command-line-argument`, and `-nostdinc++` on non-C++ invocations).
- **Catalysts to reconsider or replace**:
  - **Windows support (`windows_x86_64`)**: `cc_wrapper.c` currently relies on POSIX APIs (`unistd.h`, `symlink`, `execvp`, `unsetenv`); enabling Windows requires porting spawn/env/file-aliasing to Win32 (`_spawnv`/`CreateProcess`, `_putenv_s`) or replacing shell/POSIX action glue with a cross-platform native runner.
  - **Host GCC under `-Werror`**: Unconditionally injecting `-nostdinc++` on C files works cleanly on `zig c++` and Clang, but GCC can warn on `-nostdinc++` for C inputs when `-Werror` is set — catalyst to gate `-nostdinc++` behind a compiler check or env toggle (`RULES_HS_NOSTDINCXX=1`).
  - **Wrapper elimination**: If future GHC stops emitting `-Wl,-h`, `-fuse-ld=gold`, `-fno-PIC`, and non-`.o` object extensions **and** consumer C toolchains stop triggering `zig c++` header ordering or `--print-file-name` host leaks, `cc_wrapper.c` could shrink to a minimal `RUNFILES_*` cleaner or be retired.

### Not Adopted

#### `rules_python` + Python `cc_wrapper.py` / `cabal_wrapper.py` (`rules_haskell` Pattern)

- **What & Role**: Python action wrappers executed on every GHC compile, link, and Hackage build action.
- **Why Not Adopted**:
  - Leaks `rules_python` (and a Python runtime toolchain or host `python3` assumption) into every downstream consumer's non-dev `MODULE.bazel` graph and every Haskell build action's inputs.
  - Adds noticeable interpreter startup latency across hundreds of actions and historically accumulated platform-specific wrapper bugs (`rules_haskell` #2492/#2493, #2317).
  - Completely redundant when Bazel already requires a `cc_toolchain` capable of compiling a 460-line C11 wrapper natively, and our 5-stage `hs_cabal_library` pipeline eliminates `cabal_wrapper.py` altogether.
- **Catalysts to adopt**:
  - **Never** on the build action hot path (`cc_wrapper` or `hs_cabal_library`).
  - Only conceivable for an isolated optional dev-only helper tool if third-party Python libraries were uniquely required — and even then, dogfooding boot-only Haskell (`//tools/lock`) avoids adding an extra language runtime.

#### Legacy / Unrelated Non-Dev Deps (`rules_java`, `protobuf`, `abseil-cpp`, `rules_proto`, `rules_nodejs`, `aspect_rules_js`, `rules_sh`, Non-Dev `stardoc`)

- **What & Role**: Broad non-dev `bazel_dep`s inherited by `tweag/rules_haskell`'s `MODULE.bazel` (Java/Protobuf tooling, legacy Asterius WASM JS/Node deps, deprecated `rules_sh`, doc generators).
- **Why Not Adopted**:
  - Directly caused Bazel 8 and 9 evaluation failures in `rules_haskell` (`rules_sh@0.4.0` calling removed `get_cpu_value`, `aspect_rules_js@1.34.0` loading removed `npm_import.bzl`, `protobuf` Windows overrides) and polluted every downstream consumer with unrelated Java/Node/Protobuf module graphs.
- **Catalysts to adopt**:
  - **`stardoc`**: Attractive strictly as **`dev_dependency = True`** (or in an isolated `docs/` Bzlmod submodule) once automated API reference generation from `hs/*.bzl` docstrings is added — never as a non-dev dependency.
  - **JS/WASM rules**: Only inside a separate optional module (e.g., `rules_hs_wasm`) if GHC's modern `wasm32-wasi` backend is supported and needs JS/WASI test runners — never in core `rules_hs`.
  - **`rules_java` / `protobuf` / `abseil-cpp` / `rules_sh`**: Never as non-dev deps of core `rules_hs` (`rules_shell` supersedes `rules_sh` as dev-only).

---

## 5. 3p Hackage Resolution & Build Pipeline

### Adopted

#### Dogfooded Boot-Only `//tools/lock` (`Cabal-syntax`) + Stackage LTS -> `hackage.lock.json` -> Pure-Starlark `hackage` Extension + 5-Stage `hs_cabal_library`

- **What & Role**: Two-phase dependency pipeline split cleanly between dev time and build time:
  1. **Dev-time lock generator ([`//tools/lock`](../tools/lock/BUILD.bazel))**: A Haskell binary compiled strictly from `@hs_boot` (`Cabal-syntax`, `base`, `bytestring`, `containers`, `directory`, `filepath`, `process`, `text`) — zero third-party deps — that reads a Stackage LTS snapshot (`lts-24.67`), evaluates `.cabal` conditionals across four platforms (`linux_x86_64`, `linux_arm64`, `macos_arm64`, `macos_x86_64`) via `Distribution.PackageDescription.Configuration.finalizePD`, verifies Hackage tarball SHA-256s, normalizes doctest-only `build-type: Custom` (`xml-conduit`), inspects `build-type: Configure` outputs (`network`, `unix-time`, `old-time`), and writes deterministic `hackage.lock.json` (`schema_version = 1`).
  2. **Build-time pure-Starlark extension ([`hs/private/hackage.bzl`](../hs/private/hackage.bzl))**: Reads `hackage.lock.json` via `json.decode` (`reproducible = True`, zero network calls during extension eval), emits one uniform `@hackage` hub repo (boot `hs_toolchain_library` targets + Hackage aliases) and lazy per-package `@hackage__<pkg>` repos downloaded only when referenced.
  3. **Fine-grained 5-stage builder ([`hs/private/cabal_library.bzl`](../hs/private/cabal_library.bzl))**: Compiles each package through up to five cacheable, parallelizable Bazel actions — Stage 1 `HsConfigure`, Stage 2 zero-subprocess `cabal_macros.h` + `Paths_*`, Stage 3 parallel per-file `HsHsc2hs`, Stage 4 native `cc_common.compile` (including C-only packages like `zlib-clib` and transitive `install-includes` via `CcInfo`), and Stage 5 `HsCompileLibrary` (`ghc --make -c` + `ar` + relocatable `${pkgroot}` `ghc-pkg` DB).
- **Why**:
  - **Zero host `cabal`, `stack`, or `python`** at both lock generation time and build time.
  - **100% Cabal spec fidelity** by reusing GHC's own `Cabal-syntax` library rather than re-implementing `.cabal` evaluation in Starlark.
  - **CI-vetted version resolution** from Stackage LTS without writing a custom SAT/backtracking solver.
  - **Fast, reproducible Bzlmod evaluation** (`reproducible = True` confirmed via `--lockfile_mode=update`) with lazy per-package fetches and uniform `@hackage//:<pkg>` target names across boot and non-boot packages.
  - **Granular Bazel caching & native C interop**: `hsc2hs` and C files compile in parallel; `CcInfo` propagates transitive headers cleanly (`zlib-clib` -> `zlib` -> `streaming-commons/cbits/zlib-helper.c`).
- **Catalysts to reconsider or extend**:
  - **Non-Stackage packages / custom version overrides**: Users needing Hackage packages outside Stackage LTS, Hackage revisions, or git checkouts — catalyst to extend `//tools/lock` to ingest `cabal.project.freeze` (or direct Hackage constraints/extra-deps) while keeping the exact same `hackage.lock.json` schema and build pipeline.
  - **Build-tool preprocessors (`alex`, `happy`, `c2hs`, `hsc2hs #def`)**: Our 69-pkg showcase has 0 `alex`/`happy`/`c2hs` packages; demand from parser/FFI-heavy consumers (`language-c`, `haskell-src-exts`, `gtk2hs`) is the catalyst to add optional prebuilt/bootstrapped preprocessor actions ahead of Stage 5.
  - **Boot `Cabal-syntax` lag**: If newer Hackage packages adopt a `cabal-version` unsupported by the active GHC's bundled `Cabal-syntax`, catalyst to allow building `//tools/lock` against a newer GHC or an optional pinned `Cabal-syntax` package at dev time.

### Not Adopted

#### `stack_snapshot` (Stack CLI + YAML Pinning)

- **What & Role**: `rules_haskell`'s Hackage resolution flow invoking the external `stack` CLI (or `stack_snapshot_json` + `bazel run @stackage-unpinned//:pin` + per-package `setup_deps` overrides).
- **Why Not Adopted**:
  - Requires an external `stack` binary and ecosystem assumptions outside Bazel, imposes noisy `setup_deps = ["@Cabal//:Cabal"]` boilerplate (`rules_haskell` #1871), and couples resolution to Stack's opaque build driver rather than Bazel-native actions.
- **Catalysts to adopt**:
  - **Never** as a build-time dependency or runtime tool in `rules_hs`.
  - Attractive **only as an optional input format** in `//tools/lock` (e.g., `--stack-yaml stack.yaml` to import an existing Stack project's resolver, `extra-deps`, and flags directly into `hackage.lock.json`).

#### Pure-Starlark `.cabal` Parser Inside the Bzlmod Extension

- **What & Role**: Parsing `.cabal` files directly inside `hs/private/hackage.bzl` during Bzlmod module extension evaluation.
- **Why Not Adopted**:
  - `.cabal` syntax is complex and stateful (indentation-sensitive stanzas, nested `if/elif/else` over `os()`, `arch()`, `impl(ghc >= ...)`, `flag()`, `common` stanzas, internal sublibraries, `mixins`, `reexported-modules`, version range algebra). A Starlark reimplementation would be perpetually incomplete, slow down `bazel mod` evaluation, and force eager downloads of every `.cabal` file at extension eval time (hurting lazy fetching and `MODULE.bazel.lock` reproducibility).
- **Catalysts to adopt**:
  - **Never** for general `.cabal` parsing.
  - Only narrow Starlark parsing is appropriate for flat, single-format metadata already inside a fetched repository (such as GHC's `package.conf.d/*.conf` in `hs/private/ghc_bindist.bzl`), or if Hackage/Stackage ever published official pre-evaluated machine-readable JSON package manifests alongside `.cabal` files.

#### Opaque `cabal-install` / `runghc Setup.hs` Inside Bazel Build Actions

- **What & Role**: Executing `runghc Setup.hs configure && build && copy && register && clean` (or `cabal v2-build`) inside a single Bazel action per package (`rules_haskell`'s `cabal_wrapper.py` architecture).
- **Why Not Adopted**:
  - Collapses configure, `hsc2hs`, C compilation, and GHC compilation into one opaque, non-parallelizable action; mutates `cwd`; requires relocating `libHS*.a` to dodge TreeArtifact overlaps with `.hi` directories and regex-patching `.conf` files (`rules_haskell` #2496/#2499); drops transitive `data-files` and native `CcInfo` C header propagation; and pays `Setup.hs` compilation overhead on every package.
  - **Doctest-only `Custom` distinction**: Across all 69 Hackage packages in `examples/size`, the sole `build-type: Custom` package (`xml-conduit`) uses `Setup.hs = defaultMainWithDoctests "doctest"` (`cabal-doctest`), which is a **complete no-op for library builds** — cleanly normalized to `Simple` by `//tools/lock` with zero `Setup.hs` execution.
- **Catalysts to adopt**:
  - **Not for `Simple`, `Configure`, or doctest-only `Custom` packages** (which remain on the 5-stage `hs_cabal_library` pipeline).
  - **Real non-trivial `build-type: Custom` packages** (such as `entropy`, `HsOpenSSL`, `gi-gtk`, or packages whose `Setup.hs` runs arbitrary build-time codegen, custom C probes beyond autoconf, or dynamic `HookedBuildInfo` hooks): If consumer dependency graphs require such packages and static lockfile metadata cannot represent them, that is the concrete catalyst to add a **scoped, opt-in fallback `hs_cabal_custom_library` rule** that compiles and executes `Setup.hs` (with pinned `setup-depends`) inside a hermetic sandboxed Bazel action strictly for those packages.

---

## 6. Showcase App 3p Haskell Libraries (`examples/size`)

All package counts and versions below are verified directly against [`examples/size/hackage.lock.json`](../examples/size/hackage.lock.json) on Stackage `lts-24.67` / GHC `9.10.3` (**69 Hackage packages + 41 GHC boot packages**, **0 external Linux C libraries**, **0 runtime TH splices**).

### 6.1 XML Parsing

#### Adopted: `xml-conduit` (`1.10.1.0`)

- **What & Role**: Pure-Haskell XML 1.0 parser and cursor query API (`Text.XML`, `Text.XML.Cursor`) used in [`examples/size/src/Sitemap.hs`](../examples/size/src/Sitemap.hs).
- **Why**:
  - Most idiomatic, actively maintained pure-Haskell XML 1.0 library; natively handles XML namespaces (`nameNamespace` / `nameLocalName`), prefixed sibling elements (`<xhtml:link/>`), XML comments, entity decoding (`&amp;` -> `&`), strict UTF-8, and informative parse errors.
  - Its `build-type: Custom` is strictly `cabal-doctest` (normalized to `Simple`), and its 16-package delta over minimal `xml` (69 vs. 54 packages) doubles as a realistic stress test for `rules_hs` (`attoparsec:attoparsec-internal` sublibrary, `Paths_*`, `bitvec` C SIMD flags).
- **Catalysts to reconsider or replace**:
  - If an application has a strict cold-compile-time or binary-size ceiling where dropping 16 transitive packages (`conduit`, `blaze-html`, `blaze-markup`, `attoparsec`, `vector-algorithms`, etc.) outweighs idiomatic XML 1.0 ergonomics.
  - If parsing multi-hundred-MB sitemaps hits DOM memory ceilings — catalyst to switch from `Text.XML.parseText` to `xml-conduit`'s own streaming `Text.XML.Stream.Parse` API (zero new dependencies) or a streaming SAX parser.

#### Not Adopted

- **`xml` (`Text.XML.Light` `1.3.14`)**:
  - *Why Not Adopted*: Minimal runner-up (zero non-boot deps, `build-type: Simple`, trims graph to 54 packages, handles namespaces and `&amp;`), but effectively unmaintained since 2014 (Hackage revisions only), its `ByteString` `XmlSource` instance assumes Latin-1 (easy UTF-8 bug), it returns `Maybe Element` with zero parse error diagnostics, and it leniently accepts malformed XML.
  - *Catalysts to adopt*: Ultra-minimal dependency-budget tools or small demos that only need basic extraction from trusted XML and prioritize the smallest possible Hackage closure (54 vs. 69 packages) over strict diagnostics and active maintenance.
- **`xeno` & `hexml`**:
  - *Why Not Adopted*: High-throughput low-level parsers, **disqualified** because they explicitly do *not* decode XML entities (`&amp;`) or handle XML namespaces — failing `testdata/urlset.xml` (`https://docs.example.com/a?x=1&amp;y=2`, `xmlns=...`, `<xhtml:link/>`).
  - *Catalysts to adopt*: Only if `xeno`/`hexml` added spec-compliant namespace + entity decoding, or in a specialized multi-GB/s throughput pipeline willing to layer custom namespace/entity decoding on top.
- **`hexpat`**:
  - *Why Not Adopted*: Unmaintained C `libexpat` binding whose bundled `expat 2.2.1` carries known CVEs.
  - *Catalysts to adopt*: A maintained upstream revival wiring to a patched BCR `@expat` library, combined with streaming SAX requirements that `xml-conduit` cannot satisfy.
- **`hxt`**:
  - *Why Not Adopted*: Legacy arrow-based XML toolbox with a heavy dependency footprint and steep ergonomics for simple `<loc>` extraction.
  - *Catalysts to adopt*: Needing full XPath, XSLT, or RelaxNG schema validation pipelines unavailable in `xml-conduit`.
- **`xmlbf`**:
  - *Why Not Adopted*: Combinator layer with no built-in raw XML parser (`xmlbf-xeno` / `xmlbf-xmlhtml` are absent from Stackage `lts-24.67`).
  - *Catalysts to adopt*: Inclusion of a spec-compliant `xmlbf-*` backend in Stackage LTS alongside a codebase wanting bidirectional XML serialization typeclasses.

### 6.2 HTTP + HTTPS/TLS

#### Adopted: `http-client` (`0.7.19`) + `http-client-tls` (`0.3.6.4`) + `http-types` (`0.12.6`)

- **What & Role**: Core HTTP/HTTPS transport in [`examples/size/src/Fetch.hs`](../examples/size/src/Fetch.hs), backed transitively by pure-Haskell TLS (`tls` `2.1.8`, `crypton` `1.0.6`, `crypton-x509-system` `1.6.8`).
- **Why**:
  - **Zero OpenSSL C dependency**: Pure-Haskell TLS + C crypto primitives inside `crypton` (compiled natively by `rules_hs`) keep `libssl.so` and `libcrypto.so` completely out of `DT_NEEDED`.
  - **Clean Linux CA discovery**: `crypton-x509-system` checks `SSL_CERT_FILE` -> `SSL_CERT_DIR` -> `SYSTEM_CERTIFICATE_PATH` -> standard Linux CA paths (`/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem`, `/etc/ssl/certs/`, `/etc/ssl/cert.pem`), working out-of-the-box on standard hosts and containers and remaining overrideable in distroless containers.
  - **Exact ergonomics without JSON bloat**: Gives 30-second timeouts, redirect following, custom `User-Agent`, raw `ByteString` responses, and non-2xx status checking in ~55 lines without dragging in `aeson` (+26 packages).
- **Catalysts to reconsider or replace**:
  - If security/compliance policy mandates **FIPS-140-3 validated OpenSSL or BoringSSL** instead of Haskell `tls`/`crypton` — catalyst to swap to `http-client-openssl` wired to BCR `@boringssl`/`@openssl`.
  - If high-volume crawling against a single host needs **HTTP/2 or HTTP/3 (QUIC)** multiplexing — catalyst to evaluate `http2`/`http3` clients.
  - *(Operational note, not a replacement)*: Running in `FROM scratch` containers without `/etc/ssl/certs/` is a catalyst to bundle Mozilla CA roots or inject `SSL_CERT_FILE` / an explicit `CertificateStore` into `http-client-tls`.

#### Not Adopted

- **`http-conduit` (`2.3.9.1`, `Network.HTTP.Simple`)**:
  - *Why Not Adopted*: With its default `flag(aeson) = true`, it adds **+26 packages** (96 total on `lts-24.67`) for JSON support `examples/size` does not use. Even with `flag(aeson) = false` (only +1 package -> 70 total, since `xml-conduit` already pulls `conduit`/`resourcet`/`attoparsec`), direct `http-client` + `http-client-tls` is already concise and avoids an extra lockfile flag override.
  - *Catalysts to adopt*: Adopting `http-conduit` (`aeson = false`) if we stream huge sitemaps directly via `httpSink` into `xml-conduit`'s `sinkDoc`, or with `aeson = true` if the app expands to call JSON APIs (`httpJSON`).
- **`req` & `wreq`**:
  - *Why Not Adopted*: Heavy REST client frameworks pulling **124** (`req`) or **120** (`wreq`) Hackage packages on `lts-24.67` (133 / 129 on Nightly) — dragging in `aeson`, `megaparsec` or `lens`, and `entropy` (real `build-type: Custom` setup) for plain GET requests.
  - *Catalysts to adopt*: Building a full-featured typed JSON REST client that already depends on `aeson` + `lens`/`mtl` and benefits from typed URL/query/auth DSLs (paired with a `Custom` `Setup.hs` fallback if `entropy` remains in the closure).
- **`http-client-openssl`**:
  - *Why Not Adopted*: Requires external C `libssl`/`libcrypto` via `HsOpenSSL` (which also uses a non-trivial `Custom` setup), adding OpenSSL build/version/linking complexity where pure-Haskell `tls` works hermetically out of the box.
  - *Catalysts to adopt*: Mandatory FIPS-140-3 / BoringSSL compliance or enterprise TLS extensions/ciphers unsupported by Haskell `tls`, backed by BCR `@boringssl` or `@openssl` via `hackage.override`.

### 6.3 Gzip Decompression

#### Adopted: `zlib` (`0.7.1.1`) with `bundled-c-zlib = true`, `pkg-config = false` (`zlib-clib` `1.3.2`)

- **What & Role**: Gzip stream decompression in [`examples/size/src/Sitemap.hs`](../examples/size/src/Sitemap.hs) (`Codec.Compression.GZip` + `Codec.Compression.Zlib.Internal.decompressST` for total error handling on corrupt archives), backed by `zlib`'s vendored C-only Hackage package `zlib-clib` (`1.3.2`).
- **Why**:
  - **Zero extra Hackage packages**: `http-client` already pulls `streaming-commons` -> `zlib`.
  - **Zero system C libraries & zero consumer `MODULE.bazel` boilerplate**: `zlib-clib` ships 11 ANSI C files + 11 `install-includes` headers (zero Haskell modules), compiled hermetically by `hs_cabal_library` Stage 4 (`cc_common.compile`) and statically linked into `//:size` — keeping `libz.so.1` completely out of `DT_NEEDED` while also exercising `rules_hs`'s C-only package support and transitive `install-includes` propagation (`streaming-commons/cbits/zlib-helper.c` -> `<zlib.h>`).
- **Catalysts to reconsider or replace**:
  - In a polyglot Bazel monorepo (such as the multi-language `size` repo) that already depends on BCR `zlib` across C++/Rust/etc., switching to BCR `@zlib//:zlib` deduplicates C builds and shares one C security patch plane.
  - If an urgent C `zlib` CVE lands in BCR before Hackage publishes a new `zlib-clib` release — immediate catalyst to override `zlib` to patched BCR `@zlib//:zlib`.

#### Not Adopted

- **BCR `@zlib//:zlib` via `hackage.override` (as `examples/size` default)**:
  - *Why Not Adopted as Showcase Default*: `rules_hs` already supports this cleanly (`--flag zlib:bundled-c-zlib=false --flag zlib:pkg-config=false` plus `hackage.override(package = "zlib", extra_cc_deps = ["@zlib//:zlib"])`), but leaving `bundled-c-zlib = true` as the showcase default eliminates an extra `bazel_dep(name = "zlib")` from [`examples/size/MODULE.bazel`](../examples/size/MODULE.bazel) and directly verifies C-only Cabal packages + transitive `install-includes`.
  - *Catalysts to adopt*: Immediately attractive for polyglot Bazel repositories that already pin BCR `zlib` across C++/Rust/etc., or want centralized BCR CVE management / alternative C implementations like `zlib-ng`.
- **Host System `libz.so.1` / `pkg-config` (`zlib1g-dev`)**:
  - *Why Not Adopted*: Non-hermetic, fails on clean containers lacking `/usr/include/zlib.h` (asserted absent in CI), and leaks `libz.so.1` into binary `DT_NEEDED`.
  - *Catalysts to adopt*: Never for hermetic Bazel builds; only conceivable under a strict enterprise mandate requiring dynamic linking to a centrally patched OS `libz.so.1`.

### 6.4 Concurrency

#### Adopted: `async` (`2.2.6`) + Boot `Control.Concurrent.QSem`

- **What & Role**: Bounded 4-way concurrent recursive crawling in [`examples/size/src/Sitemap.hs`](../examples/size/src/Sitemap.hs) (`Control.Concurrent.Async.mapConcurrently` + `QSem` acquired via `bracket_` only around the fetch call, paired with `MVar (Set Text)` cycle/duplicate tracking).
- **Why**:
  - **Zero extra Hackage packages**: `async` is already a transitive dependency of `http-client`.
  - **Safe structured concurrency**: `mapConcurrently` cleanly propagates exceptions and cancels sibling threads without leaks, while releasing `QSem` prior to recursive descent guarantees arbitrary `<sitemapindex>` nesting depth can never deadlock.
- **Catalysts to reconsider or replace**:
  - If crawling scales to tens of thousands of child sitemaps per index where spawning one green thread per child ahead of `QSem` adds excessive scheduling/memory pressure — catalyst to replace `mapConcurrently` + `QSem` with a fixed-size worker pool or bounded streaming queue.
  - If a pure boot-only executable has zero Hackage dependencies (`//tools/lock`) and cannot pull `async`.

#### Not Adopted

- **Raw `Control.Concurrent` (`forkIO` + manual `MVar`s)**:
  - *Why Not Adopted*: Zero dependency savings (since `async` is already free via `http-client`), while introducing boilerplate for async-exception masking, sibling cancellation, and thread-leak prevention.
  - *Catalysts to adopt*: Boot-only executables (zero `@hackage` deps) needing trivial one-off background threads where adding a Hackage lockfile would be disproportionate.
- **`ki` / `streamly`**:
  - *Why Not Adopted*: Heavier structured-concurrency (`ki`) or fused concurrent-streaming (`streamly`) libraries that add extra packages and API surface unnecessary for a 15-line bounded tree crawl.
  - *Catalysts to adopt*: Long-lived server/crawler services requiring dynamic scoped thread supervision across non-tree lifetimes (`ki`), or high-throughput streaming ETL/crawlers needing backpressure, adaptive rate limiting, and streaming XML fusion (`streamly`).
