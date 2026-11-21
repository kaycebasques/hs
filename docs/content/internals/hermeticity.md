---
title: "Hermeticity, Toolchain Staging & C Wrapper"
description: "How rules_hs achieves Nix-free Linux hermeticity via pure-Starlark bindists, $ORIGIN staging, static GMP linking, and the native C11 ghc_cc_wrapper."
section: internals
nav_title: "Hermeticity & Toolchain"
order: 20
---

Achieving true end-to-end hermeticity for GHC on Linux without Nix requires closing six distinct host-leakage vectors that affect naive bindist setups:

1. **Fetch-time build scripts**: Running `./configure && make install` inside a repository rule invokes host `make`, `perl`, `/bin/sh` probes, and host C compilers/libraries (`libgmp-dev`, `libtinfo5`).
2. **Baked-in tool paths in `lib/settings`**: Official GHC bindists ship a `lib/settings` file containing hardcoded paths to the upstream release builder's `/usr/bin/gcc`, `/usr/bin/ld.gold`, `/usr/bin/ar`, and `-fuse-ld=gold`.
3. **Compiler dynamic library dependencies**: GHC's dynamic Linux binaries (`ghc`, `ghc-pkg`, `hsc2hs`, `haddock`, `ghc-iserv-dyn`) import `libgmp.so.10` and `libtinfo.so.6` at startup. Satisfying these via `LD_LIBRARY_PATH` leaks library search paths into child `/bin/sh`, `./configure`, and `cc_toolchain` processes.
4. **User binary dynamic GMP leakage**: Linking user executables against a shared `libgmp.so.10` produces unportable ELF binaries that fail in minimal containers lacking `libgmp10`.
5. **Bazel `RUNFILES_*` environment variables**: When Bazel invokes tools under `--enable_runfiles`, inherited `RUNFILES_DIR` and `RUNFILES_MANIFEST_FILE` environment variables can confuse nested compiler wrappers and subprocesses.
6. **C compiler driver mismatches**: Modern hermetic C/C++ toolchains (such as `hermetic_cc_toolchain`'s `zig cc`, `toolchains_llvm`, or custom sysroot Clang) diverge from GCC on flags GHC emits (`-Wl,-h`, `-fuse-ld=gold`, `-fno-PIC`, `.dyn_o`/`.p_o` suffixes, `--print-file-name`, and C++ standard library include ordering).

`rules_hs` eliminates every one of these vectors cleanly using pure-Starlark repository extraction, ELF `$ORIGIN` toolchain staging, static-only `libgmp.a` linking for user binaries, and a compiled C11 adapter (`ghc_cc_wrapper`).

---

## Pure-Starlark GHC Bindist Extraction {#ghc-bindist-repo}

Official Haskell.org `deb10` Linux tarballs (`ghc-9.10.3-{x86_64,aarch64}-deb10-linux.tar.xz` and `ghc-9.12.4-...`) already contain compiled ELF binaries under `bin/` (`ghc-<ver>`, `ghc-pkg-<ver>`, `hsc2hs-ghc-<ver>`, `haddock-ghc-<ver>`, `unlit-ghc-<ver>`, `ghc-iserv-dyn-ghc-<ver>`) alongside a pre-populated, relocatable `lib/package.conf.d/package.cache` whose paths are expressed relative to `${pkgroot}/../lib/...`.

Because the upstream bindist is already relocatable, `./configure && make install` is completely unnecessary. Instead, `ghc_bindist_repo` (`hs/private/ghc_bindist.bzl`) executes three deterministic, pure-Starlark steps during repository fetch:

### 1. Verified Extraction

`repository_ctx.download_and_extract` fetches the official `.tar.xz` archive, verifies its pinned SHA-256 digest from `hs/private/ghc_versions.bzl`, and strips the top-level archive prefix (e.g., `ghc-9.10.3-x86_64-unknown-linux`).

### 2. Host-Path Sanitization of `lib/settings`

`_sanitize_settings` rewrites `lib/settings` in pure Starlark so GHC can **never** silently fall back to host `/usr/bin/*` compilers, assemblers, archivers, or linkers:

| `lib/settings` Key | Sanitized Value | Injected Per-Action Replacement |
|---|---|---|
| `"C compiler command"` | `"/nonexistent/cc"` | `-pgmc <ghc_cc_wrapper>` |
| `"C++ compiler command"` | `"/nonexistent/cxx"` | `-pgmcxx <ghc_cc_wrapper>` |
| `"CPP command"` | `"/nonexistent/cpp"` | `-pgmP <ghc_cc_wrapper>` |
| `"Haskell CPP command"` | `"/nonexistent/hs-cpp"` | `-pgmP <ghc_cc_wrapper> -optP-E -optP-undef -optP-traditional` |
| `"JavaScript CPP command"` | `"/nonexistent/js-cpp"` | Unused on native targets (poisoned against host leaks) |
| `"C-- CPP command"` | `"/nonexistent/cmm-cpp"` | `-pgmCmmP <ghc_cc_wrapper> -optCmmP-E` |
| `"Merge objects command"` | `"/nonexistent/ld"` | `-pgmlm <cc_tools.ld> -optlm-r` |
| `"ar command"` | `"/nonexistent/ar"` | `-pgmar <cc_tools.ar>` |
| `"ranlib command"` | `"/nonexistent/ranlib"` | Unused (`ar s` builds symbol tables directly) |
| `"LLVM llc command"` | `"/nonexistent/llc"` | Poisoned against host LLVM leaks |
| `"LLVM opt command"` | `"/nonexistent/opt"` | Poisoned against host LLVM leaks |
| `"LLVM llvm-as command"` | `"/nonexistent/llvm-as"` | Poisoned against host LLVM leaks |

At the same time, `_sanitize_settings` strips legacy `-fuse-ld=gold` linker flags from `"C compiler link flags"` (replacing `"-fuse-ld=gold -Wl,--no-as-needed -Wl,-z,noexecstack"` with `"-Wl,--no-as-needed -Wl,-z,noexecstack"`, `"-fuse-ld=gold -Wl,--no-as-needed"` with `"-Wl,--no-as-needed"`, and bare `"-fuse-ld=gold"` with `""`). If any rule ever forgot to pass an explicit `-pgm*` flag, GHC would fail fast trying to execute `/nonexistent/*` rather than quietly invoking a host binary.

### 3. Pure-Starlark `package.conf.d/*.conf` Parsing

Rather than spawning `ghc-pkg dump` during `bazel fetch` (which cannot run before `libgmp.so.10` and `libtinfo.so.6` are staged), `_parse_pkg_conf` (`hs/private/ghc_bindist.bzl`) parses every `lib/package.conf.d/*.conf` file directly in Starlark:

- Joins indented continuation lines (`" "` or `"\t"`) onto the active key.
- Extracts each boot package's exact `name`, `version`, `id` (`unit_id`), `depends`, and `exposed_modules` (stripping `from <pkg>:<OrigMod>` qualifiers on re-exported boot modules so only exposed module names remain).
- Reads the exact `rts` package version (e.g., `1.0.2`) to construct `rts_include_rel = "lib/<arch_libdir>/rts-<rts_version>/include"`, exposing `Rts.h`, `HsFFI.h`, and `ghcversion.h` as tracked Bazel files (`:rts_headers`).
- Encodes the parsed map into `boot_packages_json` on [`hs_toolchain`](../reference/rules.md#hs_toolchain) (`:toolchain_impl`), retaining `lib/html/**` (Haddock themes, QuickJump JS, and hyperlinked-source assets) and `doc/html/libraries/**/*.haddock` (bundled boot `.haddock` interfaces exposed on `HsToolchainInfo.boot_haddocks`) while excluding `lib/latex/**` documentation weight from `:lib_files`.

> **Important — The `${pkgroot}/../lib` Directory Name Invariant:** GHC's pre-built `lib/package.conf.d/package.cache` resolves boot `.hi` interfaces, archives, and RTS headers via `${pkgroot}/../lib/...`, where `${pkgroot}` is `lib/package.conf.d`'s parent (`lib`). Consequently, the staged library `TreeArtifact` declared by `staged_ghc` **must literally be named `lib`** (`<prefix>/lib`) alongside `<prefix>/bin`. Renaming `<prefix>/lib` to any other directory name would invalidate `package.cache`!

---

## `$ORIGIN` Toolchain Staging & Shared Library Shims {#origin-staging}

Auditing every executable and shared library inside the official GHC `9.10.3` `deb10` bindists (`x86_64` and `aarch64`) via `readelf -d` and `nm -D` establishes three facts:

1. **Bundled `libffi`, zero `libnuma`**: `libffi.so.8` and static `libCffi*.a` are already shipped inside `lib/<arch>-linux-ghc-<ver>/`, and `libHSrts` is compiled without `libnuma`.
2. **Baked-in `$ORIGIN` `RUNPATH`**: Every compiler executable in `bin/` (`ghc-9.10.3`, `ghc-pkg-9.10.3`, `hsc2hs-ghc-9.10.3`, `haddock-ghc-9.10.3`, `ghc-iserv-dyn-ghc-9.10.3`, `unlit-ghc-9.10.3`) carries a baked-in ELF `RUNPATH`:
   ```text
   $ORIGIN/../lib/<arch>-linux-ghc-<ver>:$ORIGIN/../../../lib/<arch>-linux-ghc-<ver>
   ```
3. **Minimal external dynamic surface**: Across all compiler binaries and `libHS*.so` libraries, only **two** non-glibc shared objects are dynamically imported: `libgmp.so.10` and `libtinfo.so.6`.

`staged_ghc` (`hs/private/staged_ghc.bzl`) satisfies both libraries hermetically using Bazel's active `cc_toolchain` and places them directly into `<prefix>/lib/<arch_libdir>/`:

### 1. Hermetic `libgmp.so.10` (`HsLinkGmpShared`)

`_find_gmp_static_archives` inspects `@gmp//:gmp[CcInfo]` (from BCR `gmp@6.3.0.bcr.5`) to extract both `pic_static_library` (`libgmp.pic.a`) and `static_library` (`libgmp.a`). When `is_dynamic_ghc = True`, the `HsLinkGmpShared` action links `libgmp.so.10` from the PIC archive:

```bash
"$CC" -shared -fPIC -Wno-unused-command-line-argument \
    -Wl,-soname,libgmp.so.10 \
    -Wl,--whole-archive "$GMP_PIC_A" -Wl,--no-whole-archive \
    -o "$OUT_GMP_SO"
```

Because GHC `deb10` imports unversioned `__gmpn_*` / `__gmpz_*` symbols, `--whole-archive` exports the complete GMP ABI with `SONAME = libgmp.so.10`.

### 2. The 8-Symbol `libtinfo.so.6` Stub (`tinfo_stub.c` + `tinfo_stub.lds`)

Symbol auditing across all `libHS*.so` files in `deb10` proves that `libtinfo.so.6` is imported **solely** by `libHSterminfo` for interactive terminal capability queries in GHCi / `haskeline`. Batch compilation actions never require live curses capabilities, but the ELF dynamic linker (`ld-linux`) still verifies that `libtinfo.so.6` exists and exports 8 symbols under exact GNU symbol version `NCURSES6_TINFO_5.0.19991023`.

Rather than pulling a heavyweight `ncurses` + `gawk` + terminfo-database build into every consumer's module graph, `//hs/private:libtinfo.so.6` (`hs/private/BUILD.bazel`) compiles a 56-line C11 shared library (`hs/private/tinfo_stub.c`) paired with a 13-line linker version script (`hs/private/tinfo_stub.lds`):

| Exported Symbol (`@NCURSES6_TINFO_5.0.19991023`) | Signature in `tinfo_stub.c` | Sentinel Returned | Effect in `libHSterminfo` |
|---|---|---|---|
| `setupterm` | `int setupterm(const char *term, int fildes, int *errret)` | Sets `*errret = -1` (if non-`NULL`), returns `-1` (`ERR`) | Signals terminal database unavailable; triggers clean dumb-terminal fallback |
| `del_curterm` | `int del_curterm(void *oterm)` | `0` (`OK`) | Safe no-op cleanup |
| `set_curterm` | `void *set_curterm(void *nterm)` | `NULL` | No active `TERMINAL` struct |
| `tigetflag` | `int tigetflag(const char *capname)` | `-1` | Capability absent / not a boolean |
| `tigetnum` | `int tigetnum(const char *capname)` | `-2` | Capability absent / not numeric |
| `tigetstr` | `char *tigetstr(const char *capname)` | `(char *)-1` | Capability absent / cancelled |
| `tparm` | `char *tparm(const char *str, ...)` | `NULL` | Parameterized string formatting disabled |
| `tputs` | `int tputs(const char *str, int affcnt, int (*putc_fn)(int))` | `0` (`OK`) | Output padding no-op |

`hs/private/tinfo_stub.lds` binds those 8 globals to `NCURSES6_TINFO_5.0.19991023` and hides all other symbols (`local: *;`), linked with `-Wl,-soname,libtinfo.so.6 -Wl,--version-script=...`. Alongside `libtinfo.so.6` (for the compiler's own `$ORIGIN` runtime), `//hs/private:tinfo_stub_static` compiles the same stub into a static `libtinfo.a` staged inside `gmp_static/` so user executables linking `@hs_boot//:terminfo`, `@hs_boot//:haskeline`, or `@hs_boot//:ghc` (`extra-libraries: tinfo`) resolve `-ltinfo` 100% statically with zero `libtinfo.so.6` in `DT_NEEDED`.

### 3. Staged `$ORIGIN` Directory Layout (`HsStageGhc`)

`HsStageGhc` (`hs/private/staged_ghc.bzl`) materializes a self-contained directory hierarchy under `<prefix>` (`staged_ghc`) and refreshes `lib/package.conf.d/package.cache` via `ghc-pkg recache` (removing any read-only sandbox input symlinks first):

```text
staged_ghc/
├── bin/
│   ├── ghc-9.10.3              # RUNPATH -> $ORIGIN/../lib/x86_64-linux-ghc-9.10.3
│   ├── ghc-pkg-9.10.3
│   ├── hsc2hs-ghc-9.10.3
│   ├── haddock-ghc-9.10.3      # Bundled GHC Haddock (for hs_haddock)
│   ├── ghc-iserv-dyn-ghc-9.10.3
│   └── unlit                   # Copied from bin/unlit-ghc-9.10.3 (GHC expects 'unlit')
├── lib/                        # Declared TreeArtifact (cp -R -P + ghc-pkg recache)
│   ├── settings                # Sanitized (/nonexistent/* tools, no -fuse-ld=gold)
│   ├── template-hsc.h
│   ├── html/                   # Bundled Haddock themes, CSS, and QuickJump JS assets
│   ├── package.conf.d/         # Relocatable ${pkgroot}/../lib/... boot package DB
│   └── x86_64-linux-ghc-9.10.3/
│       ├── libffi.so.8         # Bundled in official bindist
│       ├── libCffi.a           # Static libffi linked into user binaries
│       ├── libgmp.so.10        # Built by HsLinkGmpShared (+ symlink libgmp.so)
│       ├── libtinfo.so.6       # Built from tinfo_stub.c (+ symlink libtinfo.so)
│       ├── libHS*.a / libHS*.so
│       └── rts-1.0.2/include/  # Rts.h, HsFFI.h, ghcversion.h
└── gmp_static/
    ├── libgmp.a                # Strictly static archives ONLY (zero .so files!)
    └── libtinfo.a              # Static terminfo stub for terminfo/haskeline/ghc
```

When Linux's `ld-linux` kernel interpreter launches `staged_ghc/bin/ghc-9.10.3`, it expands `$ORIGIN` to `.../staged_ghc/bin` and immediately resolves `libgmp.so.10`, `libtinfo.so.6`, `libffi.so.8`, and `libHS*.so` inside `staged_ghc/lib/x86_64-linux-ghc-9.10.3/`:

- **Zero `LD_LIBRARY_PATH`** is ever set in any Bazel action environment, guaranteeing child processes (`/bin/sh`, `./configure`, `cc_toolchain` binaries) never inherit overridden shared libraries.
- **Zero `patchelf`** binary rewriting is needed, avoiding ELF program-header corruption and host `patchelf` dependencies.
- Every staged compiler binary runs cleanly under `env -i PATH=/nonexistent`.

---

## Static-GMP User Executables {#static-gmp-executables}

A subtle linker hazard arises if GHC links a user executable ([`hs_binary`](../reference/rules.md#hs_binary) or [`hs_test`](../reference/rules.md#hs_test)) while `libgmp.so` is visible on the library search path: GHC's `ghc-bignum` package declares `extra-libraries: gmp`, causing GHC to pass `-lgmp` to the C linker. Whenever GNU `ld` or `lld` sees both `libgmp.so` and `libgmp.a` in a `-L` directory (without global `-static`), it prefers `libgmp.so` — saddling the output executable with a runtime `DT_NEEDED: libgmp.so.10` dependency!

`rules_hs` solves this cleanly via directory isolation:

1. `staged_ghc` places `libgmp.so.10` and `libtinfo.so.6` inside `staged_ghc/lib/<arch_libdir>/` (which GHC's compiler binary uses via `$ORIGIN`, *not* as a static link `-L` path for `rts`/`ghc-bignum`/`terminfo`), and creates a separate directory `staged_ghc/gmp_static/` containing **exclusively** static archive symlinks (`libgmp.a` and `libtinfo.a`, with zero `.so` files).
2. `HsLinkExecutable` (`hs/private/rules.bzl`) passes:
   - `-optl-L<gmp_static_dir>` — the linker finds `gmp_static/libgmp.a` (and `libtinfo.a` when `terminfo`/`haskeline`/`ghc` is linked) and links only the required object members statically into the executable.
   - `-optl-no-pie` — allows `lld`, Clang, and `zig cc` to link GHC's non-PIC static boot `.a` archives (`libHSbase-*.a`, `libHSrts-*.a`, `libCffi.a`) without R_X86_64_32S / R_AARCH64_ADR_PREL_PG_HI21 relocation errors.

The resulting ELF executable dynamically links **only** base `glibc` (`libc.so.6`, `libm.so.6`, `libdl.so.2`, `libpthread.so.0`), verified automatically by `//tests/basic:elf_hermeticity_test`, `//tests/rules:bzlmod_hygiene_test`, `examples/size`'s `//:elf_hermeticity_test`, and `//docs:site_test`.

---

## Native C11 `ghc_cc_wrapper` & C-Toolchain Agnosticism {#ghc-cc-wrapper}

`rules_hs` never hardcodes a specific C compiler. Instead, `resolve_cc_tools` (`hs/private/actions.bzl`) inspects `@bazel_tools//tools/cpp:toolchain_type` via `rules_cc` (`find_cc_toolchain` + `cc_common`):

- Extracts `cc` (`ACTION_NAMES.c_compile`), `ar` (`ACTION_NAMES.cpp_link_static_library`), and `ld` (`cc_toolchain.ld_executable`, ignoring placeholder `/false` paths such as macOS Zig).
- Queries `cc_common.create_compile_variables` and `cc_common.get_memory_inefficient_command_line` (plus `cc_toolchain.sysroot` fallback) to extract any `--sysroot`, `--target`, or `-target` flags configured by toolchains like `toolchains_llvm` or Pigweed.
- Passes the resolved compiler and flags to `ghc_cc_wrapper` through environment variables (`ghc_base_env`):
  - `RULES_HS_REAL_CC`: path to the underlying C compiler driver (`cc_tools.cc`).
  - `RULES_HS_FORCE_PIC=1`: instructs the wrapper to upgrade `-fno-PIC` to `-fPIC`.
  - `RULES_HS_CC_EXTRA_ARGS`: newline-delimited `--sysroot` / `--target` flags (in `HsConfigure`, relative `--sysroot` paths are anchored to `$EXECROOT/` before `cd "$WORK"`).

### Inside `hs/private/cc_wrapper.c`

`//hs/private:ghc_cc_wrapper` is a zero-dependency 460-line POSIX C11 executable (`-std=c11 -O2 -Wall -Wextra`) invoked for every GHC tool hook (`-pgmc`, `-pgmcxx`, `-pgml`, `-pgma`, `-pgmP`, `-pgmCmmP`), `hsc2hs` (`--cc`, `--ld`), and Cabal `./configure` (`CC`, `CXX`). On every invocation, `main` executes the following pipeline before calling `execv(real_cc, ...)`:

| Step in `cc_wrapper.c` | Function / Mechanism | Root Cause & Exact Behavior |
|---|---|---|
| **1. Scrub Bazel runfiles env** | `unsetenv("RUNFILES_DIR")`, `RUNFILES_MANIFEST_FILE`, `RUNFILES_MANIFEST_ONLY` | Prevents Bazel runfiles variables from leaking into `zig cc`, Clang wrappers, `hsc2hs` probe binaries, or `./configure` subshells. |
| **2. Intercept `--print-file-name`** | `handle_print_file_name(argc, argv)` | GHC queries `--print-file-name=libm.a` / `.so` during linking and TH loading. Unwrapped Clang/Zig either leaks host `/usr/lib/x86_64-linux-gnu/libm.a` GNU `ld` scripts (`loadArchive: Not an archive`) or errors on Zig's `.2.32` target triple suffix. `handle_print_file_name` searches explicit `-B` and `-L` directories via `access(..., F_OK)` and prints the match, or echoes `<file>` verbatim and exits `0`. |
| **3. Parse & rewrite `@rsp` files** | `parse_rsp`, `write_rsp`, recursive `rewrite_tokens` | GHC passes long link argument lists via `@response_file`. `parse_rsp` tokenizes single quotes, double quotes, and `\` escapes, recursively applies flag/object rewrites, and writes back to `rsp_path` (or `$TMPDIR/hs_rsp_<pid>_<n>.rsp` if read-only). |
| **4. Rewrite `-Wl,-h` soname flags** | `rewrite_tokens` (`-Wl,-h` + `-Wl,<soname>` and `-Wl,-h,<soname>`) | When linking dynamic libraries (such as `-dynamic-too` `.so` outputs for cross-library Template Haskell), GHC emits Solaris/GNU `-Wl,-h,<soname>`. `zig cc` rejects `-h`; `cc_wrapper.c` rewrites both 1-arg and 2-arg forms to `-Wl,-soname,<soname>`. |
| **5. Strip `-fuse-ld=gold`** | `rewrite_tokens` | Drops any residual `-fuse-ld=gold` flag incompatible with `lld` and `zig cc`. |
| **6. Upgrade `-fno-PIC` to `-fPIC`** | `rewrite_tokens` (when `RULES_HS_FORCE_PIC != "0"`) | GHC's native codegen passes `-fno-PIC` to `-pgma` on certain assembly invocations; `zig cc` `gnu.*` targets mandate PIC and error out unless rewritten to `-fPIC`. |
| **7. Alias `.dyn_o` & `.p_o` inputs** | `ensure_dot_o_alias` (`-o <out>` preserved) | During dynamic (`-dynamic-too`) or profiled compilation, GHC passes `.dyn_o` or `.p_o` inputs to the linker. `zig cc` classifies inputs strictly by file extension and rejects non-`.o` object files. `rewrite_tokens` passes `-o <out>` output paths through untouched (`strcmp(a, "-o") == 0`) so GHC writes expected output filenames, while symlinking `.dyn_o`/`.p_o` *inputs* via `realpath(path)` to `$TMPDIR/hs_obj_<pid>_<counter>.o`. |
| **8. Silence unused-arg warnings** | `main` (skipped on `--version`, `-dumpversion`, `-dumpmachine`) | `hermetic_cc_toolchain`'s `zig-wrapper` injects `-fno-sanitize=undefined`, which triggers Clang warnings during `-E` preprocessing, `-x assembler`, and autoconf `./configure` probes unless `-Wno-unused-command-line-argument` is prepended. |
| **9. Restore C header order (`-nostdinc++`)** | `detect_cxx_invocation` + `-nostdinc++` | See the deep dive box below. |

> **Warning — Why `-nostdinc++` Is Essential for C / `hsc2hs` Under `hermetic_cc_toolchain`:** `hermetic_cc_toolchain` routes `ACTION_NAMES.c_compile` through a `zig c++` wrapper that places LLVM's `libcxx/include` **ahead** of standard C libc headers on the default include search path.
>
> When `hsc2hs` compiles `network`'s `.hsc` files, GHC's `template-hsc.h` includes `<stddef.h>` at the very top of the translation unit — *before* the `.hsc` file's own `#include "HsNet.h"` (`#define _GNU_SOURCE 1`). Under `libcxx/include/stddef.h`, `<__config>` transitively pulls glibc's `<features.h>` **without `_GNU_SOURCE`**, permanently locking out GNU socket extensions (`struct ucred`, `struct in6_pktinfo`) when `HsNet.h` subsequently includes `<sys/socket.h>` and `<netinet/in.h>`!
>
> `detect_cxx_invocation` inspects `argv` for explicit C++ markers (`-xc++*`, `-x c++*`, `-std=c++*`, `-std=gnu++*`, `-stdlib=*`, or `.cc`/`.cpp`/`.cxx`/`.C`/`.hh`/`.hpp`/`.hxx` inputs) and injects `-nostdinc++` on all C, assembler, preprocessor, and linker invocations — restoring canonical C header ordering without disturbing C++ FFI sources.

### Explicit GHC Tool Flags (`ghc_tool_flags`)

Overriding GHC's `-pgmP`, `-pgmCmmP`, `-pgml`, or `-pgmlm` command clears the corresponding default option list from `lib/settings`. `ghc_tool_flags` (`hs/private/actions.bzl`) therefore supplies the exact companion `-opt*` flags explicitly on every compile and link invocation:

```starlark
[
    "-pgmc", w,
    "-pgmcxx", w,
    "-pgml", w,
    "-pgma", w,
    "-pgmP", w,
    "-optP-E", "-optP-undef", "-optP-traditional",
    "-pgmCmmP", w,
    "-optCmmP-E",
    "-pgmar", cc_tools.ar,
    "-optl-Wl,--no-as-needed",
    # Plus when cc_tools.ld is non-empty:
    "-pgmlm", cc_tools.ld, "-optlm-r",
]
```

Passing `-pgmlm <ld> -optlm-r` is particularly subtle: when a module uses `CApiFFI`, GHC compiles a generated C stub `.o` alongside the Haskell `.o` and merges them into a single relocatable object via `ld -r`. Omitting `-optlm-r` after overriding `-pgmlm` drops relocatable merging and breaks `CApiFFI` builds.

### Compiler-RT `__cpu_model` Shim (`hs/private/rt_shims.c`)

C sources in SIMD-aware Hackage libraries (such as `bitvec`) invoke Clang/GCC's `__builtin_cpu_supports(...)` intrinsic on `x86_64`, which emits `R_X86_64_PC32` relocations against the compiler-runtime global `__cpu_model`. While GCC (`libgcc`) and upstream LLVM (`libclang_rt.builtins`) provide `__cpu_model`, `hermetic_cc_toolchain` (`zig cc`) omits `cpu_model.c` from its bundled `libcompiler_rt.a` — leaving `__cpu_model` unresolved when linking shared libraries for Template Haskell (`-dynamic-too`) or final executables.

`//hs/private:rt_shims` (`hs/private/rt_shims.c`) provides a 26-line C11 archive linked automatically whenever a target carries native C archives:

- Defines a zero-initialized `__cpu_model` struct marked `__attribute__((weak, visibility("hidden")))` on `x86_64` ELF targets (and an empty translation unit elsewhere).
- Marking the symbol **hidden** resolves `R_X86_64_PC32` locally inside each `.so` DSO without requiring GOT/PLT indirection, while marking it **weak** guarantees that GCC (`libgcc`) and LLVM (`libclang_rt.builtins`) toolchains automatically override it with their strong runtime CPU-detection symbol (and `zig cc` safely selects baseline `x86_64` SSE2 code paths).

---

## The `glibc` Compatibility Window & Clean-Container CI {#glibc-window-and-ci}

### Selecting `gnu.2.32` on `hermetic_cc_toolchain`

When pairing `rules_hs` with `hermetic_cc_toolchain@4.3.0` (`zig cc`), `MODULE.bazel` registers the `gnu.2.32` toolchains **before** the `@zig_sdk//toolchain/...` wildcard:

```starlark
register_toolchains(
    "@zig_sdk//toolchain:linux_amd64_gnu.2.32",
    "@zig_sdk//toolchain:linux_arm64_gnu.2.32",
    "@zig_sdk//toolchain/...",
    "@zig_sdk//libc_aware/toolchain/...",
    dev_dependency = True,
)
```

Why `gnu.2.32` is the exact compatibility sweet spot:

1. **Why wildcard default (`gnu.2.17`) is too old**: Registering `@zig_sdk//toolchain/...` alone causes Bazel to pick `linux_amd64_gnu.2.17` alphabetically. Linking GHC `deb10` boot archives against `glibc 2.17` fails with undefined symbol references to `memfd_create` (`GLIBC_2.27` in `libCffi.a`) as well as `statx` and `fcntl64` (`GLIBC_2.28`).
2. **Why `gnu.2.28` is almost enough, and `gnu.2.32` is required**: GHC `deb10` itself requires only `glibc <= 2.28`. However, building BCR `gmp@6.3.0.bcr.5` compiles BCR `m4` as an exec build tool, and under Zig's bundled headers `m4`'s gnulib includes `<sys/single_threaded.h>`, which was added in **`glibc 2.32`**.
3. **Broad production portability**: Targeting `gnu.2.32` satisfies both GHC `deb10` and BCR `gmp`/`m4` while producing binaries that run unmodified on every modern Linux distribution:
   - Debian 12 Bookworm (`glibc 2.36`) & distroless `gcr.io/distroless/cc-debian12`
   - Ubuntu 22.04 Jammy (`glibc 2.35`) & Ubuntu 24.04 Noble (`glibc 2.39`)
   - Rocky Linux 9 / RHEL 9 / AlmaLinux 9 (`glibc 2.34`)

### Multi-Distro Clean-Container CI Verification

`.github/workflows/ci.yml` proves hermeticity continuously across two complementary CI job families:

1. **`native-ubuntu` (`ubuntu-24.04`)**: Enables unprivileged user namespaces for Bazel's full `linux-sandbox`, inspects `bazel mod graph`, runs `bazel test //...` across root and `examples/size` (69 Hackage packages), smoke-tests `bazel run //tools/lock:lock -- --help`, and executes a live HTTPS crawl (`bazel run //:size -- https://docs.stripe.com/sitemap.xml`).
2. **`hermetic-containers` matrix (`debian:bookworm-slim`, `ubuntu:24.04`, `rockylinux:9`)**:
   - Installs strictly minimal POSIX/archive/TLS bootstrap utilities (`binutils`, `ca-certificates`, `curl`, `diffutils`, `findutils`, `gawk`, `git`, `grep`, `gzip`, `sed`, `tar`, `zstd`).
   - **Explicitly asserts the absence of host compilers and C `-dev` headers** before Bazel ever runs:
     - Fails immediately if `command -v` finds any of `ghc`, `cabal`, `stack`, `gcc`, `cc`, `clang`, `g++`, `c++`, `ghcup`, or `nix`.
     - Fails immediately if any of `/usr/include/gmp.h`, `/usr/include/zlib.h`, `/usr/include/ncurses.h`, `/usr/include/curses.h`, or `/usr/include/openssl/ssl.h` exist.
   - Runs the entire root test suite and the entire 69-package `examples/size` test suite inside each bare container under `--spawn_strategy=processwrapper-sandbox` and `--incompatible_strict_action_env`.
