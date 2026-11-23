---
title: "Hermeticity, Toolchain Staging & C Wrapper"
description: "How rules_hs runs GHC on Linux without host compilers or system libraries via Starlark archive extraction, ELF $ORIGIN staging, static GMP linking, and ghc_cc_wrapper."
section: internals
nav_title: "Hermeticity & Toolchain"
order: 20
---

> **New to Bazel Rulesets or GHC Internals?** Read the [Bazel Ruleset Primer](bazel-rules-primer.md) (especially [Toolchains & Configurations](bazel-rules-primer.md#toolchains-and-configs) and [C/C++ Interop](bazel-rules-primer.md#cc-interop)) and the [Haskell & GHC Primer](haskell-and-ghc-primer.md) (especially [C Toolchain & RTS](haskell-and-ghc-primer.md#c-toolchain-and-rts) and [Why GMP and libtinfo Show Up](haskell-and-ghc-primer.md#gmp-and-tinfo)) first for background context.

A build is **hermetic** when every compiler binary, header file, and library comes from pinned, SHA-256-verified Bazel inputs rather than whatever packages happen to be installed on a developer's machine or CI runner. Running GHC hermetically on Linux without Nix requires addressing six places where a naive compiler setup leaks dependencies from the host OS:

1. **Fetch-time install scripts**: Running `./configure && make install` when downloading a GHC archive invokes host `make`, `perl`, `/bin/sh` probes, and host C compilers or libraries (`libgmp-dev`, `libtinfo-dev`).
2. **Hardcoded tool paths in `lib/settings`**: Official GHC binary archives ship a `lib/settings` file containing paths from the upstream release builder, such as `/usr/bin/gcc`, `/usr/bin/ld.gold`, `/usr/bin/ar`, and `-fuse-ld=gold`.
3. **Compiler shared-library dependencies**: GHC's Linux compiler executables (`ghc`, `ghc-pkg`, `hsc2hs`, `haddock`, `ghc-iserv-dyn`) dynamically link `libgmp.so.10` and `libtinfo.so.6` at process startup. Supplying those via `LD_LIBRARY_PATH` leaks library search paths into child `/bin/sh`, `./configure`, and C compiler processes.
4. **Dynamic GMP dependencies in user binaries**: Linking user executables against a shared `libgmp.so.10` produces binaries that fail to start in minimal containers where `libgmp10` is not installed.
5. **Bazel `RUNFILES_*` environment variables**: When Bazel runs tools with `--enable_runfiles`, inherited `RUNFILES_DIR` and `RUNFILES_MANIFEST_FILE` variables can confuse nested C compiler wrappers and child processes.
6. **C compiler flag differences**: Hermetic C/C++ toolchains (such as `hermetic_cc_toolchain`'s `zig cc`, `toolchains_llvm`, or custom sysroot Clang) differ from GCC on several flags emitted by GHC (`-Wl,-h`, `-fuse-ld=gold`, `-fno-PIC`, `.dyn_o` and `.p_o` object file suffixes, `--print-file-name`, and C++ header include ordering).

`rules_hs` closes each of these six paths using Starlark archive extraction, Linux ELF `$ORIGIN` library staging, static-only `libgmp.a` linking for user binaries, and a small C11 compiler adapter (`ghc_cc_wrapper`).

---

## `$ORIGIN`, `DT_NEEDED`, and Starlark GHC Archive Extraction {#ghc-bindist-repo}

Official Haskell.org Debian 10 (`deb10`) Linux archives (`ghc-9.10.3-{x86_64,aarch64}-deb10-linux.tar.xz` and `ghc-9.12.4-...`, called **binary distributions** or `bindists`) already contain compiled executables under `bin/` (`ghc-<ver>`, `ghc-pkg-<ver>`, `hsc2hs-ghc-<ver>`, `haddock-ghc-<ver>`, `unlit-ghc-<ver>`, `ghc-iserv-dyn-ghc-<ver>`) alongside a relocatable boot package database at `lib/package.conf.d/package.cache` whose paths use `${pkgroot}/../lib/...` (see [How GHC Compiles Code](haskell-and-ghc-primer.md#compilation-model)).

Because those files are already compiled and path-relative, running `./configure && make install` at download time is unnecessary. Instead, `ghc_bindist_repo` (`hs/private/ghc_bindist.bzl`) performs three deterministic steps in Starlark when Bazel fetches the repository:

### 1. SHA-256 Verified Extraction

`repository_ctx.download_and_extract` downloads the `.tar.xz` archive, verifies its SHA-256 digest from `hs/private/ghc_versions.bzl`, and strips the top-level directory prefix (`ghc-9.10.3-x86_64-unknown-linux`).

### 2. Sanitizing Host Paths in `lib/settings`

`_sanitize_settings` rewrites `lib/settings` in Starlark so GHC cannot fall back to host `/usr/bin/*` compilers, assemblers, archivers, or linkers:

| `lib/settings` Key | Rewritten Value | Per-Action Replacement Flag |
|---|---|---|
| `"C compiler command"` | `"/nonexistent/cc"` | `-pgmc <ghc_cc_wrapper>` |
| `"C++ compiler command"` | `"/nonexistent/cxx"` | `-pgmcxx <ghc_cc_wrapper>` |
| `"CPP command"` | `"/nonexistent/cpp"` | `-pgmP <ghc_cc_wrapper>` |
| `"Haskell CPP command"` | `"/nonexistent/hs-cpp"` | `-pgmP <ghc_cc_wrapper> -optP-E -optP-undef -optP-traditional` |
| `"JavaScript CPP command"` | `"/nonexistent/js-cpp"` | Unused on native targets (set to `/nonexistent` to prevent host calls) |
| `"C-- CPP command"` | `"/nonexistent/cmm-cpp"` | `-pgmCmmP <ghc_cc_wrapper> -optCmmP-E` |
| `"Merge objects command"` | `"/nonexistent/ld"` | `-pgmlm <cc_tools.ld> -optlm-r` |
| `"ar command"` | `"/nonexistent/ar"` | `-pgmar <cc_tools.ar>` |
| `"ranlib command"` | `"/nonexistent/ranlib"` | Unused (`ar s` writes archive symbol tables directly) |
| `"LLVM llc command"` | `"/nonexistent/llc"` | Set to `/nonexistent` to prevent host LLVM calls |
| `"LLVM opt command"` | `"/nonexistent/opt"` | Set to `/nonexistent` to prevent host LLVM calls |
| `"LLVM llvm-as command"` | `"/nonexistent/llvm-as"` | Set to `/nonexistent` to prevent host LLVM calls |

At the same time, `_sanitize_settings` removes legacy `-fuse-ld=gold` flags from `"C compiler link flags"` (modern Clang, `lld`, and `zig cc` toolchains do not ship GNU `ld.gold`). If a Bazel rule ever omitted a required `-pgm*` flag, GHC would fail immediately trying to execute `/nonexistent/*` instead of quietly running a host binary from `/usr/bin`.

### 3. Parsing `package.conf.d/*.conf` in Starlark

Spawning `ghc-pkg dump` during `bazel fetch` is not possible on a bare Linux container before `libgmp.so.10` and `libtinfo.so.6` have been compiled and staged. Instead, `_parse_pkg_conf` (`hs/private/ghc_bindist.bzl`) reads each `lib/package.conf.d/*.conf` text file directly in Starlark:

- Joins indented continuation lines (`" "` or `"\t"`) onto the preceding key.
- Reads each boot package's `name`, `version`, `id` (`unit_id`), `depends`, and `exposed_modules` (stripping `from <pkg>:<OrigMod>` suffixes on re-exported modules).
- Reads the `rts` package version (for example, `1.0.2`) to compute `rts_include_rel = "lib/<arch_libdir>/rts-<rts_version>/include"`, exposing `Rts.h`, `HsFFI.h`, and `ghcversion.h` as Bazel-tracked header files (`:rts_headers`).
- Stores the parsed metadata as `boot_packages_json` on [`hs_toolchain`](../reference/rules.md#hs_toolchain) (`:toolchain_impl`), keeping `lib/html/**` (Haddock stylesheets and scripts) and `doc/html/libraries/**/*.haddock` (boot `.haddock` cross-reference files on `HsToolchainInfo.boot_haddocks`) while omitting `lib/latex/**` files from `:lib_files`.

> **Important — Why the Staged Library Directory Must Be Named `lib`:** GHC's boot `.conf` files resolve `.hi` files, `.a` archives, and RTS headers via `${pkgroot}/../lib/...`, where `${pkgroot}` expands to the parent directory of `lib/package.conf.d` (namely `lib`). As a result, the directory output (`TreeArtifact`, a directory tracked by Bazel as a single build artifact) declared by `staged_ghc` must literally be named `lib` (`<prefix>/lib`) next to `<prefix>/bin`. Renaming `<prefix>/lib` to another name would break `${pkgroot}/../lib` resolution.

---

## `$ORIGIN` Toolchain Staging and Shared Library Shims {#origin-staging}

### Background: ELF `DT_NEEDED`, `RUNPATH`, and `$ORIGIN` on Linux

When Linux starts a dynamically linked ELF executable (such as `bin/ghc-9.10.3`), the kernel loads the dynamic linker (`ld-linux-x86-64.so.2` or `ld-linux-aarch64.so.1`) **before `main()` runs**. `ld-linux.so` reads two fields from the executable's `.dynamic` header (visible via `readelf -d`):

- **`DT_NEEDED`**: Required shared-library filenames (`SONAME`s, such as `libgmp.so.10`, `libtinfo.so.6`, `libc.so.6`). If any `DT_NEEDED` library cannot be opened, the process terminates before running any application code.
- **`DT_RUNPATH` (`RUNPATH`) and `$ORIGIN`**: A colon-separated list of search directories recorded inside the binary's ELF header. Inside `RUNPATH`, `ld-linux.so` expands the token **`$ORIGIN`** at runtime to **the directory containing the executable file itself** — even when Bazel mounts that executable at a different sandbox or remote-worker path on every action. Unlike `LD_LIBRARY_PATH` (an environment variable inherited by child `/bin/sh` and C compiler processes) or `patchelf` (which rewrites compiled ELF headers after linking), `$ORIGIN` requires no environment variables and no binary modification.

Inspecting every executable and shared library in the GHC `9.10.3` and `9.12.4` `deb10` archives (`x86_64` and `aarch64`) with `readelf -d` and `readelf -Ws` establishes three facts:

1. **Bundled `libffi`, no `libnuma`**: `libffi.so.8` and static `libCffi*.a` are already included inside `lib/<arch>-linux-ghc-<ver>/`, and `libHSrts` is compiled without `libnuma`.
2. **Existing `$ORIGIN` `RUNPATH`**: Every executable in `bin/` (`ghc`, `ghc-pkg`, `hsc2hs`, `haddock`, `ghc-iserv-dyn`, `unlit`) already contains an ELF `RUNPATH` pointing into `../lib`:
   ```text
   $ORIGIN/../lib/<arch>-linux-ghc-<ver>:$ORIGIN/../../../lib/<arch>-linux-ghc-<ver>
   ```
3. **Two non-glibc shared libraries**: Across all compiler binaries and `libHS*.so` libraries, the only external shared libraries outside base `glibc` are `libgmp.so.10` and `libtinfo.so.6` ([Why GMP and libtinfo Show Up](haskell-and-ghc-primer.md#gmp-and-tinfo)).

`staged_ghc` (`hs/private/staged_ghc.bzl`) builds both libraries using Bazel's `cc_toolchain` and places them into `<prefix>/lib/<arch_libdir>/`.

### 1. Building `libgmp.so.10` from BCR (`HsLinkGmpShared`)

`_find_static_archives` inspects `@gmp//:gmp[CcInfo]` (from BCR `gmp@6.3.0.bcr.5`) to locate both its position-independent archive (`libgmp.pic.a`) and its plain static archive (`libgmp.a`). When `is_dynamic_ghc = True`, the `HsLinkGmpShared` action links `libgmp.so.10` from the position-independent archive:

```bash
"$CC" -shared -fPIC -Wno-unused-command-line-argument \
    -Wl,-soname,libgmp.so.10 \
    -Wl,--whole-archive "$GMP_PIC_A" -Wl,--no-whole-archive \
    -o "$OUT_GMP_SO"
```

Because GHC `deb10` imports unversioned `__gmpn_*` and `__gmpz_*` symbols, `--whole-archive` exports the full GMP symbol table under `SONAME` `libgmp.so.10`.

### 2. Deep Dive: The 8-Symbol `libtinfo.so.6` / `libtinfo.a` Stub (`tinfo_stub.c` and `tinfo_stub.lds`)

#### Why `libtinfo` Is Referenced at All

`libtinfo` is the low-level terminal capability library from `ncurses`; it reads `/usr/share/terminfo` based on `$TERM` to look up escape sequences for cursor movement and colors. Because upstream GHC compiles the batch compiler (`ghc`) and interactive prompt (`ghci`) into a single binary (`bin/ghc-9.10.3`), `ghc` links `libHSghci` -> `libHShaskeline` -> `libHSterminfo` -> `libtinfo.so.6`. Even though batch compilation (`ghc -c`) never uses interactive terminal editing, `ld-linux.so` refuses to start `bin/ghc-9.10.3` unless `libtinfo.so.6` can be loaded and its symbol versions match.

#### Verifying the Exact Symbol Surface

Running `readelf -Ws` across every executable and `libHS*.so` shared object in the GHC `9.10.3` and `9.12.4` `deb10` distributions (`x86_64` and `aarch64`) shows that `libHSterminfo` is the **only** consumer of `libtinfo.so.6`, importing strictly **8 C functions** tagged with ELF version `NCURSES6_TINFO_5.0.19991023`: `setupterm`, `set_curterm`, `del_curterm`, `tigetflag`, `tigetnum`, `tigetstr`, `tparm`, and `tputs`.

#### Standard X/Open Curses Error Sentinels in `hs/private/tinfo_stub.c`

`//hs/private:libtinfo.so.6` (`hs/private/BUILD.bazel`) compiles a 56-line C11 file (`hs/private/tinfo_stub.c`) implementing those 8 functions:

| Exported Symbol (`@NCURSES6_TINFO_5.0.19991023`) | Signature in `tinfo_stub.c` | Return Value | Meaning in X/Open Curses & Effect in `libHSterminfo` |
|---|---|---|---|
| `setupterm` | `int setupterm(const char *term, int fildes, int *errret)` | Sets `*errret = -1` (when `errret != NULL`), returns `-1` (`ERR`) | Official X/Open Curses code for "terminfo database not found"; `System.Console.Terminfo.Base.setupTerm` raises `SetupTermError` and `haskeline`/GHC falls back to plain line-oriented I/O |
| `del_curterm` | `int del_curterm(void *oterm)` | `0` (`OK`) | No-op cleanup |
| `set_curterm` | `void *set_curterm(void *nterm)` | `NULL` | No active `TERMINAL` structure |
| `tigetflag` | `int tigetflag(const char *capname)` | `-1` | Standard sentinel for absent boolean capability |
| `tigetnum` | `int tigetnum(const char *capname)` | `-2` | Standard sentinel for absent numeric capability |
| `tigetstr` | `char *tigetstr(const char *capname)` | `(char *)-1` | Standard sentinel for absent or cancelled string capability |
| `tparm` | `char *tparm(const char *str, ...)` | `NULL` | Parameterized escape-string formatting unavailable |
| `tputs` | `int tputs(const char *str, int affcnt, int (*putc_fn)(int))` | `0` (`OK`) | Padding output no-op |

Returning `-1` (`*errret = -1`) from `setupterm` is not memory-unsafe fakery: it is the documented X/Open Curses return value when no terminfo database entry exists — **the exact same value real `libtinfo.so.6` returns inside a Bazel sandbox or headless CI runner** where `$TERM` is unset or `/usr/share/terminfo` is absent. Because `libHSterminfo` checks `setupterm == -1` first and immediately throws `SetupTermError`, it never passes an uninitialized `TERMINAL *` pointer to `tigetstr` or `tputs`.

#### Why `hs/private/tinfo_stub.lds` Is Required for ELF Symbol Versioning

On Linux, libraries like `glibc` and `ncurses` preserve binary compatibility across releases by attaching a version label to every exported function (`setupterm@@NCURSES6_TINFO_5.0.19991023`). When `libHSterminfo` was linked on Debian 10 against `ncurses6`, the linker recorded both the function name `setupterm` and the required version label `NCURSES6_TINFO_5.0.19991023` inside `libHSterminfo`'s `.gnu.version_r` ("version needed") ELF table.

If `tinfo_stub.c` were compiled into `libtinfo.so.6` without a linker version script, it would export an unversioned `setupterm` symbol, and `ld-linux.so` would fail at startup with `version 'NCURSES6_TINFO_5.0.19991023' not found`. Passing `-Wl,--version-script=tinfo_stub.lds` attaches the exact version node expected by `ld-linux.so`:

```text
NCURSES6_TINFO_5.0.19991023 {
  global:
    setupterm;
    del_curterm;
    set_curterm;
    tigetflag;
    tigetnum;
    tigetstr;
    tparm;
    tputs;
  local:
    *;
};
```

#### Why a 56-Line Stub Was Chosen Over Building Full `ncurses`, and Its Trade-Offs

Building `ncurses` from source in Bazel requires running autoconf `./configure`, invoking host `gawk` and shell scripts to generate capability tables, and compiling thousands of lines of C code — only for real `ncurses` to still fail `setupterm` with `-1` inside an empty Bazel sandbox without `/usr/share/terminfo`.

Alongside `libtinfo.so.6` (used by `ghc` at compile time), `//hs/private:tinfo_stub_static` compiles the same `tinfo_stub.c` into `gmp_static/libtinfo.a` so user executables linking `@hs_boot//:terminfo`, `@hs_boot//:haskeline`, or `@hs_boot//:ghc` (`extra-libraries: tinfo`) link statically without host `libtinfo-dev` or runtime `libtinfo.so.6`. That carries one explicit trade-off:

- **Supported by default**: All batch compilation, `haddock` builds, automated tests, web servers, and CLI binaries that either do not call `System.Console.Terminfo` or fall back cleanly to line-oriented mode (note that standard ANSI color libraries like `ansi-terminal` emit escape codes directly without `terminfo`).
- **Limitation for full-screen terminal UI (TUI) applications**: If you build an interactive full-screen TUI application using libraries such as **`vty`** or **`brick`** — which call `setupTermFromEnv` at runtime in an end user's terminal and require live capability strings — linking `gmp_static/libtinfo.a` causes `setupTermFromEnv` to report that terminfo is unavailable. To build a `vty` / `brick` TUI binary, attach a real `ncurses` / `tinfo` `cc_library` via `cc_deps` on [`hs_binary`](../reference/rules.md#hs_binary) or [`hackage.override`](../reference/extensions-and-providers.md#hackage-override) (`extra_cc_deps`), linking the real archive with `-Wl,--whole-archive` (or placing its `-L` directory ahead of `gmp_static` via `ghc_opts = ["-optl-L..."]`), and ensure `/usr/share/terminfo` and `$TERM` exist at runtime. Adding an interactive `hs_repl` rule is the planned milestone for optional built-in `ncurses` toolchain integration.

### 3. Staged `$ORIGIN` Directory Layout (`HsStageGhc`)

`HsStageGhc` (`hs/private/staged_ghc.bzl`) assembles a self-contained directory tree under `<prefix>` (`staged_ghc`) and regenerates `lib/package.conf.d/package.cache` via `ghc-pkg recache` (removing read-only sandbox input symlinks first so `ghc-pkg` can create writable cache files):

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
│       ├── libffi.so.8         # Bundled in official archive
│       ├── libCffi.a           # Static libffi linked into user binaries
│       ├── libgmp.so.10        # Built by HsLinkGmpShared (+ symlink libgmp.so)
│       ├── libtinfo.so.6       # Built from tinfo_stub.c (+ symlink libtinfo.so)
│       ├── libHS*.a / libHS*.so
│       └── rts-1.0.2/include/  # Rts.h, HsFFI.h, ghcversion.h
└── gmp_static/
    ├── libgmp.a                # Static archives only (no .so files in this directory)
    └── libtinfo.a              # Static terminfo fallback archive
```

When `ld-linux.so` launches `staged_ghc/bin/ghc-9.10.3`, it expands `$ORIGIN` to `.../staged_ghc/bin` and resolves `libgmp.so.10`, `libtinfo.so.6`, `libffi.so.8`, and `libHS*.so` inside `staged_ghc/lib/x86_64-linux-ghc-9.10.3/`:

- **No `LD_LIBRARY_PATH`** is set in any Bazel action environment, so child processes (`/bin/sh`, `./configure`, `cc_toolchain` binaries) never inherit altered shared-library search paths.
- **No `patchelf`** binary rewriting is needed, avoiding ELF header rewriting and host `patchelf` tool dependencies.
- Every staged compiler executable runs under `env -i PATH=/nonexistent`.

---

## Static-GMP User Executables and PIC vs. `-no-pie` {#static-gmp-executables}

A subtle linker behavior occurs if GHC links a user executable ([`hs_binary`](../reference/rules.md#hs_binary) or [`hs_test`](../reference/rules.md#hs_test)) while `libgmp.so` is present in any `-L` search directory: GHC's `ghc-bignum` package declares `extra-libraries: gmp`, causing GHC to pass `-lgmp` to the C linker. Whenever GNU `ld` or `lld` sees both `libgmp.so` and `libgmp.a` in a `-L` directory (without global `-static`), it picks `libgmp.so` by default — adding a runtime `DT_NEEDED: libgmp.so.10` dependency to the user's binary.

`rules_hs` prevents that by separating the compiler's shared libraries from the linker's static search directory:

1. `staged_ghc` places `libgmp.so.10` and `libtinfo.so.6` inside `staged_ghc/lib/<arch_libdir>/` (used by `ghc` via `$ORIGIN`, not passed as a `-L` search path for static linking), and creates a separate `staged_ghc/gmp_static/` directory containing **only** static archive symlinks (`libgmp.a` and `libtinfo.a`, with no `.so` files).
2. `HsLinkExecutable` (`hs/private/rules.bzl`) passes two flags:
   - `-optl-L<gmp_static_dir>` — the linker finds `gmp_static/libgmp.a` (and `libtinfo.a` if needed) and copies only the referenced `.o` members statically into the executable.
   - `-optl-no-pie` — links a fixed-address executable (`ET_EXEC`) rather than a Position-Independent Executable (`PIE` / `ET_DYN`).

> **Background — Position-Independent Code (`-fPIC`) vs. Non-PIC Boot Archives (`-no-pie`):** Modern Linux C compilers default to linking **PIE** executables so the OS kernel's Address Space Layout Randomization (ASLR) can map the executable at a randomized virtual address. Linking a PIE executable requires every input `.o` object file to have been compiled as **Position-Independent Code (`-fPIC`)**, using instruction-pointer-relative addressing rather than fixed 32-bit addresses.
>
> Upstream GHC `deb10` compiles its static boot `.a` archives (`libHSbase-*.a`, `libHSrts-*.a`, `libCffi.a`) *without* `-fPIC` to avoid indirect address lookups, emitting fixed 32-bit relocations (`R_X86_64_32S` on `x86_64` and `R_AARCH64_ADR_PREL_PG_HI21` on `arm64`). Passing `-optl-no-pie` tells `lld`, Clang, and `zig cc` to emit a standard fixed-address `ET_EXEC` binary so GHC's non-PIC boot `.a` archives link cleanly, while all library objects compiled by `rules_hs` itself use `-fPIC` so they work in both static `.a` executables and `.so` Template Haskell libraries.

The resulting ELF executable dynamically links only base `glibc` libraries (`libc.so.6`, `libm.so.6`, `libdl.so.2`, `libpthread.so.0`), checked automatically by `//tests/basic:elf_hermeticity_test`, `//tests/rules:bzlmod_hygiene_test`, `examples/size`'s `//:elf_hermeticity_test`, and `//docs:site_test`.

---

## Native C11 `ghc_cc_wrapper` and C-Toolchain Compatibility {#ghc-cc-wrapper}

`rules_hs` does not hardcode a specific C compiler. Instead, `resolve_cc_tools` (`hs/private/actions.bzl`) queries `@bazel_tools//tools/cpp:toolchain_type` through `rules_cc` (`find_cc_toolchain` and `cc_common`, explained in [C/C++ Interop in the Bazel Primer](bazel-rules-primer.md#cc-interop)):

- Looks up `cc` (`ACTION_NAMES.c_compile`), `ar` (`ACTION_NAMES.cpp_link_static_library`), and `ld` (`cc_toolchain.ld_executable`, ignoring placeholder `/false` paths such as macOS Zig).
- Queries `cc_common.create_compile_variables` and `cc_common.get_memory_inefficient_command_line` (falling back to `cc_toolchain.sysroot`) to collect any `--sysroot`, `--target`, or `-target` flags configured by toolchains such as `toolchains_llvm` or Pigweed.
- Passes the resolved C compiler and extra flags to `ghc_cc_wrapper` via environment variables (`ghc_base_env`):
  - `RULES_HS_REAL_CC`: path to the underlying C compiler driver (`cc_tools.cc`).
  - `RULES_HS_FORCE_PIC=1`: tells the wrapper to rewrite `-fno-PIC` to `-fPIC`.
  - `RULES_HS_CC_EXTRA_ARGS`: newline-separated `--sysroot` / `--target` flags (in `HsConfigure`, relative `--sysroot` paths are anchored to `$EXECROOT/` before `cd "$WORK"`).

### Inside `hs/private/cc_wrapper.c`

`//hs/private:ghc_cc_wrapper` is a 552-line POSIX C11 executable (`-std=c11 -O2 -Wall -Wextra`) invoked for every GHC external tool hook (`-pgmc`, `-pgmcxx`, `-pgml`, `-pgma`, `-pgmP`, `-pgmCmmP`), `hsc2hs` (`--cc`, `--ld`), and Cabal `./configure` (`CC`, `CXX`). On each call, `main` translates GCC-specific conventions emitted by GHC before calling `execv(real_cc, ...)` (or `fork`/`waitpid` when cleaning up temporary symlinks):

| Step in `cc_wrapper.c` | Function / Mechanism | Problem Addressed & Exact Behavior |
|---|---|---|
| **1. Clear Bazel runfiles env** | `unsetenv("RUNFILES_DIR")`, `RUNFILES_MANIFEST_FILE`, `RUNFILES_MANIFEST_ONLY` | Prevents Bazel runfiles variables from leaking into `zig cc`, Clang wrapper scripts, `hsc2hs` probe binaries, or `./configure` subshells. |
| **2. Handle `--print-file-name`** | `handle_print_file_name(argc, argv)` | GHC runs `--print-file-name=libm.a` / `.so` during linking and Template Haskell loading. Unwrapped Clang or GCC returns host `/usr/lib/x86_64-linux-gnu/libm.a` (a GNU `ld` text script — see note below), while `zig cc` errors on `.2.32` target suffixes. `handle_print_file_name` searches explicit `-B` and `-L` directories via `access(..., F_OK)` and prints the match, or prints `<file>` unchanged and exits `0`. |
| **3. Parse & rewrite `@rsp` files** | `parse_rsp`, `write_rsp`, recursive `rewrite_tokens` | GHC passes long linker flag lists in `@response_file` files. `parse_rsp` parses single quotes, double quotes, and `\` escapes, applies flag/object rewrites recursively, and writes the updated arguments to `rsp_path` (or `$TMPDIR/hs_ccw.XXXXXX/hs_rsp_<n>.rsp` if read-only, removed on exit). |
| **4. Rewrite `-Wl,-h` soname flags** | `rewrite_tokens` (`-Wl,-h` + `-Wl,<soname>` and `-Wl,-h,<soname>`) | When linking dynamic `.so` libraries (`-dynamic-too` for Template Haskell), GHC passes `-Wl,-h,<soname>`. `zig cc` rejects `-h`; `cc_wrapper.c` rewrites both 1-token and 2-token forms to `-Wl,-soname,<soname>`. |
| **5. Strip `-fuse-ld=gold`** | `rewrite_tokens` | Drops any remaining `-fuse-ld=gold` flag rejected by `lld` and `zig cc`. |
| **6. Rewrite `-fno-PIC` to `-fPIC`** | `rewrite_tokens` (when `RULES_HS_FORCE_PIC != "0"`) | GHC's native code generator passes `-fno-PIC` to `-pgma` on some assembly calls; `zig cc` `gnu.*` targets require PIC and reject `-fno-PIC` unless upgraded to `-fPIC`. |
| **7. Symlink `.dyn_o` & `.p_o` inputs** | `ensure_dot_o_alias` (`-o <out>` preserved) | During dynamic (`-dynamic-too`) or profiled builds, GHC passes `.dyn_o` or `.p_o` object files to the linker. `zig cc` determines file types from extensions and rejects non-`.o` object inputs. `rewrite_tokens` leaves `-o <out>` output paths untouched (`strcmp(a, "-o") == 0`) while symlinking `.dyn_o` and `.p_o` *inputs* via `realpath(path)` to `$TMPDIR/hs_ccw.XXXXXX/hs_obj_<counter>.o`. |
| **8. Suppress unused-arg warnings** | `main` (skipped on `--version`, `-dumpversion`, `-dumpmachine`) | `hermetic_cc_toolchain`'s `zig-wrapper` adds `-fno-sanitize=undefined`, which triggers Clang warnings during `-E` preprocessing, `-x assembler`, and `./configure` feature checks unless `-Wno-unused-command-line-argument` is added. |
| **9. Keep C headers ahead of C++ (`-nostdinc++`)** | `detect_cxx_invocation` + `-nostdinc++` | Stops `zig c++`'s `libc++` headers from including `<features.h>` before `_GNU_SOURCE` is defined (explained below). |

#### Why `/usr/lib/.../libm.a` on Debian and Ubuntu Is a Text Linker Script

On Debian and Ubuntu (`glibc >= 2.34`), `/usr/lib/x86_64-linux-gnu/libm.a` is not a binary `!<arch>` static archive. Instead, it is a ~100-byte ASCII **GNU `ld` linker script**:

```text
OUTPUT_FORMAT(elf64-x86-64)
GROUP ( /usr/lib/x86_64-linux-gnu/libm-2.39.a /usr/lib/x86_64-linux-gnu/libmvec.a )
```

Linux distributions use this text script so passing `-lm` to GNU `ld` or `lld` pulls in both scalar math (`libm-2.39.a`) and SIMD vector math (`libmvec.a`). However, when GHC's internal archive loader (`loadArchive` in `rts/Linker.c`) queries `-pgmc --print-file-name=libm.a` and opens that file directly, it checks for the 8-byte `!<arch>\n` `ar` file signature and aborts with `loadArchive "/usr/lib/.../libm.a": failed (Not an archive)`. Handling `--print-file-name` inside `cc_wrapper.c` keeps host `/usr/lib` linker scripts out of GHC.

#### Why `<features.h>`, `_GNU_SOURCE`, and `-nostdinc++` Matter Under `zig c++`

> **Warning — One-Time `<features.h>` Guard in `glibc`:** In GNU `glibc`, feature-test macros such as `#define _GNU_SOURCE 1` take effect **only if defined before the very first standard C header is included**. Every `glibc` header includes `<features.h>`, which uses a `#ifndef _FEATURES_H` guard to snapshot `_GNU_SOURCE` into internal `__USE_GNU` macros once per C file; any `#define _GNU_SOURCE` placed *after* `<features.h>` has been included has no effect.

`hermetic_cc_toolchain` routes C compilation (`ACTION_NAMES.c_compile`) through a `zig c++` wrapper that puts LLVM's C++ header directory (`libcxx/include`) **ahead** of Clang's freestanding C headers. When `hsc2hs` compiles `network`'s `.hsc` files, GHC's `template-hsc.h` includes `<stddef.h>` on line 1 — *before* the `.hsc` file's own `#include "HsNet.h"` (`#define _GNU_SOURCE 1`). With normal C include ordering, Clang's freestanding `<stddef.h>` defines `size_t` without including `glibc`'s `<features.h>`. With `libcxx/include/stddef.h` first on the path, `<__config>` transitively includes `<features.h>` **before `_GNU_SOURCE` is defined**, hiding Linux-specific socket structs (`struct ucred`, `struct in6_pktinfo`) when `HsNet.h` later includes `<sys/socket.h>` and `<netinet/in.h>`.

`detect_cxx_invocation` checks `argv` (and `@rsp` files) for explicit C++ flags or file extensions (`-xc++*`, `-x c++*`, `-std=c++*`, `-std=gnu++*`, `-stdlib=*`, or `.cc`/`.cpp`/`.cxx`/`.C`/`.hh`/`.hpp`/`.hxx` inputs) and adds `-nostdinc++` on all C, assembler, preprocessor, and linker calls, keeping standard C header order intact while leaving C++ compilation unaffected.

### Explicit GHC Tool Flags (`ghc_tool_flags`)

Overriding GHC's `-pgmP`, `-pgmCmmP`, `-pgml`, or `-pgmlm` command clears the default companion flags stored in `lib/settings`. `ghc_tool_flags` (`hs/private/actions.bzl`) therefore passes the required `-opt*` flags explicitly on every compile and link command:

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

Passing `-pgmlm <ld> -optlm-r` is essential for `CApiFFI`: when a Haskell module uses `foreign import capi`, GHC compiles a generated C wrapper `.o` alongside the Haskell `.o` and combines them into a single relocatable object file using `ld -r`. Leaving off `-optlm-r` after overriding `-pgmlm` drops relocatable merging and causes `CApiFFI` builds to fail.

### Compiler-RT `__cpu_model` Shim and `R_X86_64_PC32` Relocations (`hs/private/rt_shims.c`)

C files in SIMD-enabled Hackage packages (such as `bitvec`) call Clang/GCC's `__builtin_cpu_supports(...)` intrinsic on `x86_64`, which emits **`R_X86_64_PC32`** relocations referencing the compiler runtime struct `__cpu_model`:

- **What `R_X86_64_PC32` means**: On `x86_64`, `R_X86_64_PC32` is a signed 32-bit instruction-pointer-relative offset (`[rip + disp32]`) that reads a variable directly instead of going through a 64-bit pointer in the Global Offset Table (`GOT`). When linking a `.so` shared library (such as `-dynamic-too` outputs for Template Haskell), ELF linkers reject `R_X86_64_PC32` against undefined or externally overridable symbols because another `.so` could be loaded more than $\pm 2\text{ GiB}$ away in 64-bit virtual memory.
- **Why `zig cc` needs a shim**: GCC (`libgcc`) and upstream LLVM (`libclang_rt.builtins`) include a hidden `__cpu_model` definition in their compiler runtime archives, whereas `hermetic_cc_toolchain` (`zig cc`) omits `cpu_model.c` from its bundled `libcompiler_rt.a`, leaving `__cpu_model` undefined.

`//hs/private:rt_shims` (`hs/private/rt_shims.c`) compiles a 26-line C11 archive linked automatically whenever a target includes C static archives:

- Defines a zero-initialized `__cpu_model` struct marked `__attribute__((weak, visibility("hidden")))` on `x86_64` ELF targets (and an empty file on other architectures).
- **`visibility("hidden")`** places `__cpu_model` inside the same `.so` or executable (guaranteed to be within $\pm 2\text{ GiB}$, satisfying `R_X86_64_PC32`), while **`weak`** ensures that GCC (`libgcc`) and LLVM (`libclang_rt.builtins`) toolchains override it with their own runtime CPU-detection symbol (and under `zig cc`, zeroed feature bits select baseline `x86_64` SSE2 code paths).

---

## The `glibc` Compatibility Window and Clean-Container CI {#glibc-window-and-ci}

### Background: How `glibc` Symbol Versioning Controls Linux Binary Portability

On Linux, `libc.so.6` (`glibc`) is **forward-compatible** (a binary linked against `glibc 2.32` runs on newer distributions shipping `glibc 2.34` through `2.39`), but **not backward-compatible**:

- When `glibc` adds a new function or changes an existing function's ABI (such as `memfd_create@GLIBC_2.27`, `statx@GLIBC_2.28`, or `__isoc23_strtol@GLIBC_2.38`), linking against a newer host `glibc` records that `@GLIBC_2.xx` version requirement in the executable's `.gnu.version_r` table.
- As a result, a binary linked against Ubuntu 24.04's host `glibc 2.39` fails to start (`GLIBC_2.38 not found`) on Debian 12 (`glibc 2.36`) or Rocky Linux 9 (`glibc 2.34`).
- `hermetic_cc_toolchain` (`zig cc`) avoids host `glibc` coupling by bundling versioned `glibc` headers and stub libraries inside the toolchain (`-target x86_64-linux-gnu.2.32`), allowing `MODULE.bazel` to pin the target `glibc` baseline regardless of which Linux distribution runs the build.

### Selecting `gnu.2.32` on `hermetic_cc_toolchain`

When configuring `hermetic_cc_toolchain@4.3.0` (`zig cc`), `MODULE.bazel` registers the `gnu.2.32` toolchains ahead of the `@zig_sdk//toolchain/...` wildcard:

```starlark
register_toolchains(
    "@zig_sdk//toolchain:linux_amd64_gnu.2.32",
    "@zig_sdk//toolchain:linux_arm64_gnu.2.32",
    "@zig_sdk//toolchain/...",
    "@zig_sdk//libc_aware/toolchain/...",
    dev_dependency = True,
)
```

Three constraints determine `gnu.2.32` as the baseline:

1. **Why the wildcard default (`gnu.2.17`) is too old**: Registering `@zig_sdk//toolchain/...` alone causes Bazel to select `linux_amd64_gnu.2.17` first alphabetically. Linking GHC `deb10` boot archives against `glibc 2.17` fails with undefined references to `memfd_create` (`GLIBC_2.27` in `libCffi.a`) and `statx` / `fcntl64` (`GLIBC_2.28`).
2. **Why `gnu.2.32` is needed above `gnu.2.28`**: GHC `deb10` itself only requires `glibc <= 2.28`. However, building BCR `gmp@6.3.0.bcr.5` compiles BCR `m4` as a build tool, and under Zig's bundled headers `m4`'s gnulib includes `<sys/single_threaded.h>`, which was introduced in **`glibc 2.32`**.
3. **Distribution support**: Targeting `gnu.2.32` satisfies both GHC `deb10` and BCR `gmp`/`m4` while capping `@GLIBC_*` symbol requirements at `2.32`, so compiled binaries run on current Linux distributions:
   - Debian 12 Bookworm (`glibc 2.36`) and distroless `gcr.io/distroless/cc-debian12`
   - Ubuntu 22.04 Jammy (`glibc 2.35`) and Ubuntu 24.04 Noble (`glibc 2.39`)
   - Rocky Linux 9 / RHEL 9 / AlmaLinux 9 (`glibc 2.34`)

### Multi-Distro Clean-Container CI Verification

`.github/workflows/ci.yml` tests these guarantees across two CI job groups:

1. **`native-ubuntu` (`ubuntu-24.04`)**: Enables unprivileged user namespaces for Bazel's `linux-sandbox`, checks `bazel mod graph`, runs `bazel test //...` across the root workspace and `examples/size` (69 Hackage packages), runs `bazel run //tools/lock:lock -- --help`, and tests a live HTTPS crawl (`bazel run //:size -- https://docs.stripe.com/sitemap.xml`).
2. **`hermetic-containers` matrix (`debian:bookworm-slim`, `ubuntu:24.04`, `rockylinux:9`)**:
   - Installs only basic POSIX, archive, and TLS bootstrap utilities (`binutils`, `ca-certificates`, `curl`, `diffutils`, `findutils`, `gawk`, `git`, `grep`, `gzip`, `sed`, `tar`, `zstd`).
   - **Verifies that host compilers and C `-dev` headers are absent** before running Bazel:
     - Fails if `command -v` finds any of `ghc`, `cabal`, `stack`, `gcc`, `cc`, `clang`, `g++`, `c++`, `ghcup`, or `nix`.
     - Fails if any of `/usr/include/gmp.h`, `/usr/include/zlib.h`, `/usr/include/ncurses.h`, `/usr/include/curses.h`, or `/usr/include/openssl/ssl.h` exist on disk.
   - Runs the full root test suite and the 69-package `examples/size` test suite inside each minimal container with `--spawn_strategy=processwrapper-sandbox` and `--incompatible_strict_action_env`.
