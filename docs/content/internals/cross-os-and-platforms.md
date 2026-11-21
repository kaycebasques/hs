---
title: "Cross-OS Architecture & Platform Blueprints"
description: "Multi-architecture toolchain resolution, why glibc deb10 beat static musl on Linux, and step-by-step engineering blueprints for macOS, Windows, and static musl."
section: internals
nav_title: "Cross-OS & Platforms"
order: 50
---

> **New to Bazel Toolchains or GHC Internals?** Read the [Bazel Ruleset Primer](bazel-rules-primer.md) ([Toolchains & Configurations](bazel-rules-primer.md#toolchains-and-configs)) and the [Haskell & GHC Primer](haskell-and-ghc-primer.md) ([Why GMP and libtinfo Show Up](haskell-and-ghc-primer.md#gmp-and-tinfo) and [Template Haskell](haskell-and-ghc-primer.md#template-haskell)) first for background context.

From day one, `rules_hs` separated platform-specific bindist metadata, OS/CPU constraint mapping, and Cabal conditional `select()` evaluation from its core Starlark rule logic. `linux_x86_64` and `linux_arm64` are active out of the box today, while `macos_arm64`, `macos_x86_64`, `windows_x86_64`, and `linux_x86_64_musl` are already cataloged with verified upstream URLs and SHA-256 checksums across GHC `9.10.3` and `9.12.4` in `hs/private/ghc_versions.bzl`.

This page documents how multi-platform toolchain resolution and cross-platform `hackage.lock.json` generation work today, why `deb10` (`glibc`) was selected over `alpine3_12` (`musl` static) as the default Linux bindist, and the exact engineering blueprints required to activate macOS, Windows, and static Linux `musl`.

---

## Declarative Bindist Matrix (`hs/private/ghc_versions.bzl`) {#ghc-versions-table}

`hs/private/ghc_versions.bzl` is a pure data module defining `DEFAULT_GHC_VERSION = "9.10.3"`, `SUPPORTED_PLATFORMS = ["linux_x86_64", "linux_arm64"]`, `BOOT_PACKAGE_NAMES` (42 entries for `9.10.3` and 43 for `9.12.4`, adding `file-io` — covering the 41/42 Haskell boot libraries plus GHC's virtual `system-cxx-std-lib` entry), and `GHC_BINDISTS`.

Every entry in `GHC_BINDISTS[ghc_version][platform_key]` specifies eleven orthogonal fields:

| Platform Key | Status | Upstream Tarball Stem (`9.10.3` & `9.12.4`) | `os` / `cpu` | `arch_libdir` (`9.10.3`) | `bignum` | `dynamic_ghc` | `needs_tinfo_stub` |
|---|---|---|---|---|---|---|---|
| `linux_x86_64` | **Active** (`SUPPORTED_PLATFORMS`, CI-tested) | `ghc-<ver>-x86_64-deb10-linux.tar.xz` | `linux` / `x86_64` | `x86_64-linux-ghc-9.10.3` | `"gmp"` | `True` | `True` |
| `linux_arm64` | **Active** (`SUPPORTED_PLATFORMS`) | `ghc-<ver>-aarch64-deb10-linux.tar.xz` | `linux` / `arm64` | `aarch64-linux-ghc-9.10.3` | `"gmp"` | `True` | `True` |
| `macos_arm64` | Cataloged + lockfile `select()` ready | `ghc-<ver>-aarch64-apple-darwin.tar.xz` | `macos` / `arm64` | `aarch64-osx-ghc-9.10.3` | `"gmp"` | `True` | `False` |
| `macos_x86_64` | Cataloged + lockfile `select()` ready | `ghc-<ver>-x86_64-apple-darwin.tar.xz` | `macos` / `x86_64` | `x86_64-osx-ghc-9.10.3` | `"gmp"` | `True` | `False` |
| `windows_x86_64` | Cataloged | `ghc-<ver>-x86_64-unknown-mingw32.tar.xz` | `windows` / `x86_64` | `x86_64-windows-ghc-9.10.3` | `"gmp"` | `False` | `False` |
| `linux_x86_64_musl` | Cataloged opt-in static flavor | `ghc-<ver>-x86_64-alpine3_12-linux-static-int_native.tar.xz` | `linux` / `x86_64` | `x86_64-linux-ghc-9.10.3` | `"native"` | `False` | `False` |

Notice how `staged_ghc` (`hs/private/staged_ghc.bzl`) already branches declaratively on those boolean/string capabilities rather than hardcoding Linux assumptions:

- `if ctx.attr.bignum == "gmp":` — skips `@gmp//:gmp` archive extraction and `gmp_static/libgmp.a` symlinking when `bignum == "native"`.
- `if ctx.attr.is_dynamic_ghc:` — skips `HsLinkGmpShared` (`libgmp.so.10`) and omits `ghc-iserv-dyn` when `dynamic_ghc == False`.
- `if ctx.attr.needs_tinfo_stub and ctx.file.tinfo_stub:` — stages `libtinfo.so.6` exclusively for Linux `deb10` bindists (`False` on macOS, Windows, and Alpine `musl`).

---

## Bazel Toolchain Resolution & Multi-Arch Parity {#toolchain-resolution}

### Lazy Bindist Fetching via `@hs_toolchains`

When a consumer invokes [`hs.toolchain`](../reference/extensions-and-providers.md#hs-toolchain) in `MODULE.bazel`, `_hs_extension_impl` (`hs/extensions.bzl`) creates:

1. **Lazy per-platform bindist repositories** (`@ghc_9_10_3_linux_x86_64`, `@ghc_9_10_3_linux_arm64`, ...). Because Bazel evaluates `toolchain()` target `toolchain = "@ghc_9_10_3_<plat>//:toolchain_impl"` labels lazily **after** matching `exec_compatible_with` and `target_compatible_with`, an `x86_64` Linux machine never downloads the `aarch64` GHC tarball (and vice versa)!
2. **`@hs_toolchains` (`hs_toolchains_repo` in `hs/private/ghc_bindist.bzl`)**: Emits one Bazel `toolchain()` stanza per selected platform:
   ```starlark
   toolchain(
       name = "ghc_linux_arm64",
       exec_compatible_with = ["@platforms//os:linux", "@platforms//cpu:arm64"],
       target_compatible_with = ["@platforms//os:linux", "@platforms//cpu:arm64"],
       toolchain = "@ghc_9_10_3_linux_arm64//:toolchain_impl",
       toolchain_type = "@rules_hs//hs:toolchain_type",
   )
   ```
3. **`@hs_boot` (`hs_boot_repo`)**: Emits platform-agnostic [`hs_toolchain_library`](../reference/rules.md#hs_toolchain_library) targets (`@hs_boot//:base`, etc.) that dynamically inspect `ctx.toolchains["@rules_hs//hs:toolchain_type"].hs.boot_packages` during Bazel's analysis phase.

### `linux_x86_64` and `linux_arm64` Structural Parity

Both active Linux architectures share an identical architecture end-to-end:

- Upstream `deb10` tarballs on both `x86_64` and `aarch64` carry the exact same `$ORIGIN/../lib/<arch>-linux-ghc-<ver>` ELF `RUNPATH`, bundle `libffi.so.8` + `libCffi.a`, import the exact same 8 `libtinfo.so.6` `@NCURSES6_TINFO_5.0.19991023` symbols, and cap their glibc symbol requirements at `GLIBC_2.28` (`memfd_create`, `fcntl64`, `statx`).
- Both pair directly with `hermetic_cc_toolchain` (`@zig_sdk//toolchain:linux_amd64_gnu.2.32` and `@zig_sdk//toolchain:linux_arm64_gnu.2.32`).
- `_hsc2hs_ghc_defines` (`hs/private/actions.bzl`) maps `target_cpu = "arm64"` to Cabal's expected `-Daarch64_BUILD_ARCH=1` and `-Daarch64_HOST_ARCH=1` CPP macros.

### Multi-Platform `hackage.lock.json` `select()` Generation

A single `hackage.lock.json` generated by [`//tools/lock:lock`](../reference/lock-cli.md) is **already cross-platform across Linux and macOS (`x86_64` + `arm64`)**:

- `allPlatforms` in `tools/lock/CabalExtract.hs` evaluates `finalizePD` across `linux_x86_64`, `linux_arm64`, `macos_arm64`, and `macos_x86_64`.
- `_PLATFORM_CONFIGS` in `hs/private/hackage.bzl` emits matching `config_setting` blocks (`_linux_x86_64`, `_linux_arm64`, `_macos_arm64`, `_macos_x86_64`) and `select({...})` expressions for `srcs`, `hsc_srcs`, `c_sources`, `install_includes`, `include_dirs`, `hs_source_dirs`, `exposed_modules`, `other_modules`, `reexported_modules`, `default_extensions`, `ghc_opts`, `cpp_options`, `cc_options`, and `deps`.

---

## Why `deb10` (`glibc`) Beat `alpine3_12` (`musl`) as the Linux Default {#deb10-vs-musl}

### Background: `glibc` vs. `musl` libc on Linux

On Linux, programs do not invoke raw kernel `syscall` instructions directly for everyday tasks like heap allocation (`malloc`/`free`), threads (`pthread_create`), DNS lookups (`getaddrinfo`), or dynamic library loading (`dlopen`); they call the **C standard library (`libc`)**. The Linux ecosystem has two primary `libc` implementations with fundamentally different design goals:

- **`glibc` (GNU C Library)**: The standard dynamic system library (`libc.so.6` + `ld-linux.so`) shipped by Debian, Ubuntu, RHEL/Rocky, Fedora, and Arch Linux. Designed dynamic-first with symbol versioning (`@GLIBC_2.xx`, see [Hermeticity & Toolchain](hermeticity.md#glibc-window-and-ci)) and a mature OS dynamic loader (`dlopen`).
- **`musl` libc**: A compact, clean-slate C library used by Alpine Linux, engineered specifically so its static archive (`libc.a`) links cleanly into **100% static, zero-dependency ELF binaries** (`PT_INTERP = NONE` — meaning the ELF header requests *no* dynamic linker from the kernel at all).

When designing `rules_hs`'s Nix-free Linux toolchain, both official Haskell.org GHC `9.10.3` bindist families were audited live against `hermetic_cc_toolchain` (`zig cc`) under `env -i PATH=/nonexistent`:

1. `ghc-9.10.3-{x86_64,aarch64}-deb10-linux.tar.xz` (dynamically linked `glibc` compiler, `bignum = gmp`)
2. `ghc-9.10.3-x86_64-alpine3_12-linux-static-int_native.tar.xz` (100% static `musl` compiler, `PT_INTERP = NONE`, `bignum = native`)

At first glance, a statically linked compiler looks tempting because it needs zero `$ORIGIN` shared libraries. Live verification exposed **five decisive technical reasons** why `deb10` (`glibc`) is far superior as the default toolchain:

| Evaluation Axis | `deb10` (`glibc`, Default) | `alpine3_12-linux-static-int_native` (`musl`, Opt-In) |
|---|---|---|
| **1. Upstream Linux CPU coverage** | Ships **both `x86_64` and `aarch64`** (`linux_arm64`) across GHC `9.10` and `9.12`. | **`x86_64` only** — upstream GHC publishes zero `aarch64` static Alpine bindists for GHC `9.10`, `9.12`, or `9.14`. |
| **2. Template Haskell + C FFI stability** | Built with `GHC Dynamic = YES` (`ghc-iserv-dyn`); OS dynamic loader loads `.so` libraries cleanly on cross-package TH + `withCString` + `CApiFFI`. | Built with `GHC Dynamic = NO`; falls back to GHC's internal ELF RTS static archive loader, which **segfaults** on cross-package TH splices calling C `withCString`/`malloc` due to dual-`musl` `libc.a` heap/TLS state collisions! |
| **3. BCR `cc_library` ABI interop** | Native ABI match with standard `glibc` `cc_toolchain`s (`hermetic_cc_toolchain` `gnu.2.32`, `toolchains_llvm`, GCC). | Cannot link against `glibc` toolchains (`undefined symbol: posix_spawn_file_actions_addchdir_np` in `libHSprocess.a` on `glibc <= 2.28` + struct layout mismatches); forces every `cc_library` onto `musl`. |
| **4. Arbitrary-precision bignum** | `bignum = "gmp"` — Hackage packages (`crypton`, `cborg`, `scientific`) work with default flags and full assembly-optimized GMP speed. | `bignum = "native"` — breaks packages defaulting `flag(integer-gmp)` / `flag(optimize-gmp)` to `True` unless manually overridden in `hackage.lock.json`, and runs pure-Haskell bignum arithmetic. |
| **5. User binary portability** | Static `gmp_static/libgmp.a` yields ELF binaries whose `DT_NEEDED` is **strictly base `glibc`** (`libc`, `libm`, `libdl`, `libpthread`) — running on Debian 10+, Ubuntu 22.04+, Rocky 8/9, and distroless `cc-debian12`. | Produces `PT_INTERP = NONE` zero-libc static binaries (ideal specifically for `FROM scratch` containers without `glibc`). |

> **Note — Why Two Copies of `libc.a` Inside Static `musl` GHC Crash During TH + C FFI:** Because the `alpine3_12-linux-static-int_native` `ghc` binary is 100% statically linked (`PT_INTERP = NONE`), no OS dynamic linker exists in its address space (`dlopen` is unavailable). To run cross-package [Template Haskell](haskell-and-ghc-primer.md#template-haskell) splices (`GHC Dynamic = NO`), GHC falls back to its own user-space ELF object loader (`rts/Linker.c`), which reads `.a` static archives from disk, `mmap`s executable memory pages, and patches ELF relocations manually.
>
> Here is the trap: the `ghc` executable *already* contains a complete static copy of `musl`'s `libc.a` whose global heap arenas and Thread-Local Storage (`TLS`, `%fs` register) pointers were initialized by `__libc_start_main` when `ghc` booted. When a Template Haskell splice invokes C FFI (`withCString` / `malloc` / `strlen`), `rts/Linker.c` resolves C symbols by loading `.o` members from a *second* `libc.a` archive off disk into newly `mmap`ped pages — **without** running libc startup initialization on that second copy! The moment TH code calls into the second copy's uninitialized allocator locks or TLS pointers, `ghc` (or static `ghc-iserv`) dies with an immediate `SIGSEGV`. Dynamic `deb10` avoids `rts/Linker.c` completely by delegating `.so` loading to the OS's `dlopen`, which shares the single process-wide `libc.so.6` cleanly.

---

## Engineering Blueprint: Activating macOS (`macos_arm64` & `macos_x86_64`) {#blueprint-macos}

### Background: Mach-O `LC_LOAD_DYLIB`, `@rpath`, `@loader_path`, and `-install_name` vs. Linux ELF

macOS uses the **Mach-O** binary format and Apple's **`dyld`** dynamic linker (inspected via `otool -L` and `otool -l`) rather than Linux's ELF and `ld-linux.so`. Understanding one key difference makes the macOS staging blueprint effortless:

| Concept | Linux ELF (`ld-linux.so`) | macOS Mach-O (`dyld`) |
|---|---|---|
| **Shared library extension** | `.so` (`libgmp.so.10`) | `.dylib` (`libgmp.10.dylib`) |
| **Library's self-identity** | `DT_SONAME` (`-Wl,-soname,libgmp.so.10` — bare filename) | `LC_ID_DYLIB` **`install_name`** (`-Wl,-install_name,@rpath/libgmp.10.dylib` — full virtual path!) |
| **Consumer's import entry** | `DT_NEEDED` (`libgmp.so.10`) | **`LC_LOAD_DYLIB`** (copies the `.dylib`'s `install_name` verbatim at link time!) |
| **Search path list on binary** | `DT_RUNPATH` | **`LC_RPATH`** |
| **Binary-relative path token** | **`$ORIGIN`** (`$ORIGIN/../lib/...`) | **`@loader_path`** (`@loader_path/../lib/...`, directory of the loading binary/dylib) |
| **Export whole static `.a` into shared lib** | `-Wl,--whole-archive lib.a -Wl,--no-whole-archive` | `-Wl,-force_load,lib.a` |
| **Rescan static `.a` cycles** | Requires `-Wl,--start-group ... -Wl,--end-group` | Automatic by default in Apple `ld64` / `ld-prime` (`--start-group` is rejected!) |

Notice the two-part handshake between **`-install_name @rpath/...`** and **`@loader_path`**: on macOS, if you build `libgmp.10.dylib` *without* `-Wl,-install_name,@rpath/libgmp.10.dylib`, the linker stamps its ephemeral Bazel build path (`bazel-out/.../libgmp.10.dylib`) into `LC_ID_DYLIB`, and every binary linking it hardcodes that path inside `LC_LOAD_DYLIB`! Setting `-install_name @rpath/libgmp.10.dylib` tells `dyld` to expand `@rpath` against the loading binary's `LC_RPATH` list, where `@loader_path/../lib/<arch>-osx-ghc-<ver>` resolves relative to `staged_ghc/bin/ghc-<ver>` — exact parity with Linux `$ORIGIN`!

Both Apple Silicon (`macos_arm64`) and Intel (`macos_x86_64`) bindists are already hashed in `hs/private/ghc_versions.bzl`, `needs_tinfo_stub` is already `False`, `_hsc2hs_ghc_defines` already emits `-Ddarwin_BUILD_OS=1 -Ddarwin_HOST_OS=1`, and `hackage.lock.json` already carries `macos_arm64` and `macos_x86_64` `select()` deltas.

Activating macOS end-to-end requires three focused changes:

### Step 1: Mach-O `@loader_path` Staging (`hs/private/staged_ghc.bzl`)

- **Shared GMP (`HsLinkGmpShared`)**: On Darwin (`target_os == "macos"`), build `libgmp.10.dylib` (plus `libgmp.dylib` symlink) instead of `libgmp.so.10`, replacing ELF linker flags (`-Wl,-soname,libgmp.so.10 -Wl,--whole-archive <pic_a> -Wl,--no-whole-archive`) with Mach-O equivalents:
  ```bash
  "$CC" -dynamiclib -fPIC \
      -Wl,-install_name,@rpath/libgmp.10.dylib \
      -Wl,-force_load,"$GMP_PIC_A" \
      -o "$OUT_GMP_DYLIB"
  ```
- **Compiler binary `LC_RPATH` & Apple Silicon code signing**: Official Darwin GHC bindists already carry `@loader_path/../lib/<arch>-osx-ghc-<ver>` `LC_RPATH` entries and link system `/usr/lib/libSystem.B.dylib` + `/usr/lib/libiconv.2.dylib` + bundled `libffi.dylib`. Placing `libgmp.10.dylib` inside `<prefix>/lib/<arch>-osx-ghc-<ver>/` satisfies `dyld` with zero `DYLD_LIBRARY_PATH` and zero `install_name_tool` mutation (note that on Apple Silicon `arm64`, macOS kernels enforce Mach-O code signatures at `execve`/`dlopen` time; avoiding binary rewrites preserves upstream signatures, and if `cp` ever invalidates an ad-hoc signature on macOS 14+, `/usr/bin/codesign --force -s -` re-signs cleanly).

### Step 2: Mach-O Linker Flag Adaptation (`cc_wrapper.c`, `actions.bzl`, `rules.bzl`)

Apple's `ld64` / `ld-prime` and `lld -flavor darwin` reject several ELF-only flags currently emitted unconditionally for Linux:

- In `hs/private/actions.bzl` (`ghc_tool_flags`): Gate `-optl-Wl,--no-as-needed` on `hs_tc.target_os == "linux"` (on macOS, pass `-optl-Wl,-dead_strip_dylibs` if desired), and when `cc_tools.ld` is empty or `/usr/bin/false` (as in `hermetic_cc_toolchain` on macOS), pass `ghc_cc_wrapper` + `-Wl,-r` or `ld -r` for `-pgmlm`.
- In `hs/private/rules.bzl` (`HsLinkExecutable`):
  - Gate `-optl-no-pie` on `hs_tc.target_os == "linux"` (macOS ARM64 requires PIE executables by ABI and GHC Darwin boot archives are already PIC-clean).
  - Omit `-optl-Wl,--start-group` and `-optl-Wl,--end-group` when `hs_tc.target_os == "macos"` — Darwin's linker natively rescans static `.a` archives until fixpoint without `--start-group`, and rejects `--start-group` as an unknown flag!
- In `hs/private/cc_wrapper.c`: Translate `-Wl,-soname,<name>` / `-Wl,-h,<name>` only on ELF targets, while preserving GHC's `-install_name` / `-Wl,-install_name,@rpath/...` flags on Darwin (`-dynamic-too` produces `.dylib` files rather than `.so`).

### Step 3: Enable & Verify (`ghc_versions.bzl` + `otool -L` Test)

- Append `"macos_arm64"` and `"macos_x86_64"` to `SUPPORTED_PLATFORMS` in `hs/private/ghc_versions.bzl`.
- Add a macOS sibling to `elf_hermeticity_test.sh` invoking `otool -L "$BIN"` and asserting that dynamic load commands reference **only** `/usr/lib/libSystem.B.dylib` and `/usr/lib/libiconv.2.dylib` (zero `libgmp.10.dylib`, zero `libHS*.dylib`, zero Homebrew `/opt/homebrew/*` or `/usr/local/*` paths).

---

## Engineering Blueprint: Activating Windows (`windows_x86_64`) {#blueprint-windows}

### Background: Windows PE `.exe`/`.dll` Search Paths, `CreateProcessW` Quoting, and Zero `/bin/sh`

Supporting native Windows builds cleanly without requiring users to install MSYS2 or Cygwin involves three OS-level differences from POSIX (Linux/macOS):

1. **PE/COFF `.exe`/`.dll` search rules (no `$ORIGIN` or `@loader_path` RPATH)**: Windows Portable Executable (`PE`) binaries have **no embedded relative RPATH header**. When launching `foo.exe`, the Windows loader searches **(a) the directory containing `foo.exe` itself**, followed by `C:\Windows\System32` and `%PATH%`. That is why upstream Windows GHC (`x86_64-unknown-mingw32`) builds `ghc.exe` with `dynamic_ghc = False` (linking GMP and boot libraries statically right into `ghc.exe`, and co-locating any MinGW `.dll`s alongside `.exe` tools) — completely avoiding `%PATH%` DLL-search pollution!
2. **`CreateProcessW` flat command-line quoting vs. POSIX `execv`**: On Linux and macOS, `execv(path, argv)` passes a pre-split array of null-terminated strings directly to the kernel — spaces, quotes, and backslashes in paths require zero escaping. On Windows, `CreateProcessW` accepts a **single flat UTF-16 command-line string** (`lpCommandLine`), which the child process splits back into `argc`/`argv` via `CommandLineToArgvW` (where backslashes `\` act as literal path separators *except* immediately before `"`, requiring `2n` or `2n+1` backslash escaping!).
3. **Privileged symlinks and no native `/bin/sh`**: Windows `CreateSymbolicLinkW` fails unless Administrator privileges or Developer Mode are enabled (whereas hard links via `CreateHardLinkW` and file copies via `CopyFileW` work everywhere unprivileged), and bare Windows CI/developer machines have no `/bin/sh` unless MSYS2/Git-Bash is installed.

Official `ghc-{9.10.3,9.12.4}-x86_64-unknown-mingw32.tar.xz` bindists are already pinned in `hs/private/ghc_versions.bzl` (`dynamic_ghc = False`, `needs_tinfo_stub = False`), and `_hsc2hs_ghc_defines` already emits `-Dmingw32_BUILD_OS=1 -Dmingw32_HOST_OS=1`. Enabling native Windows without MSYS2 requires four clean steps:

### Step 1: `.exe` & Bundled MinGW Bindist Layout (`ghc_bindist.bzl`, `staged_ghc.bzl`, `rules.bzl`)

- Append `.exe` suffixes to compiler binary declarations when `target_os == "windows"` (`ghc-9.10.3.exe`, `ghc-pkg-9.10.3.exe`, `hsc2hs-ghc-9.10.3.exe`, `haddock-ghc-9.10.3.exe`, `unlit.exe`) and to [`hs_binary`](../reference/rules.md#hs_binary) / [`hs_test`](../reference/rules.md#hs_test) outputs (`ctx.label.name + ".exe"`).
- Official Windows GHC bindists bundle a self-contained `mingw/` toolchain directory alongside `bin/` and `lib/` and link GMP statically into `ghc.exe` (`dynamic_ghc = False`). Stage `mingw/` (or wire Bazel's Windows Clang/MinGW `cc_toolchain`) cleanly inside `staged_ghc`.

### Step 2: Win32 Port of `hs/private/cc_wrapper.c`

Guard POSIX calls in `cc_wrapper.c` behind `#ifdef _WIN32`:

- Replace `unsetenv("RUNFILES_DIR")` with `_putenv_s("RUNFILES_DIR", "")` (and `RUNFILES_MANIFEST_FILE`, `RUNFILES_MANIFEST_ONLY`).
- Replace `realpath` + `symlink` in `ensure_dot_o_alias` with `GetFullPathNameW` + `CreateHardLinkW` (falling back to `CopyFileW` across volumes) so unprivileged Windows builds never touch `CreateSymbolicLinkW`.
- Replace `execv(real_cc, final_args.items)` with `CreateProcessW` (serializing `final_args` using exact `CommandLineToArgvW`-inverse quoting for spaces, `"`, and trailing `\`) + `WaitForSingleObject` + `GetExitCodeProcess`, returning the child compiler's exact exit code.

### Step 3: Shell-Free Native Action Runner (`hs_action_runner.c`)

`HsStageGhc`, `HsHsc2hs`, `HsCompileLibrary`, and `HsLinkExecutable` currently invoke `ctx.actions.run_shell` (`set -euo pipefail`, `mktemp -d`, `find`, `cp -R`). Replacing those short shell snippets with a ~300-line cross-platform C11 helper binary (`//hs/private:hs_action_runner`, compiled by `cc_binary` alongside `ghc_cc_wrapper`) that executes directly via `ctx.actions.run` (`CreateProcessW` on Windows, `execve` on Unix, with zero `/bin/sh` wrapper) eliminates **all** `/bin/bash` / MSYS2 dependencies on Windows while also speeding up Linux/macOS action startup!

### Step 4: Windows Cabal Lockfile Platform (`tools/lock` & `hackage.bzl`)

- Add `("windows_x86_64", Platform X86_64 Windows)` to `allPlatforms` in `tools/lock/CabalExtract.hs` and `_PLATFORM_CONFIGS` in `hs/private/hackage.bzl`.
- Add `"Win32"` to `builtinBootPackages` on Windows (and allow `Win32` in `pdDeps` on the `windows_x86_64` `select()` delta while keeping it excluded from Unix platforms).

---

## Engineering Blueprint: Linux Static `musl` (`linux_x86_64_musl`) {#blueprint-linux-musl}

For users deploying ultra-minimal `FROM scratch` container images (`0` OS files, `PT_INTERP = NONE`), `linux_x86_64_musl` (`ghc-{9.10.3,9.12.4}-x86_64-alpine3_12-linux-static-int_native.tar.xz`) can be exposed as an explicit opt-in flavor:

1. **Distinct `libc` Constraint Value**: Currently, `linux_x86_64` and `linux_x86_64_musl` in `hs/private/ghc_versions.bzl` share `["@platforms//os:linux", "@platforms//cpu:x86_64"]`. Registering both simultaneously without a `libc` constraint would make Bazel pick whichever toolchain was registered first. Add a `@rules_hs//hs/constraints:libc_musl` / `@zig_sdk//libc:musl` constraint to `linux_x86_64_musl`'s `target_constraints` (matched by `--platforms=//:linux_x86_64_musl` paired with `@zig_sdk//libc_aware/toolchain:linux_amd64_musl`).
2. **Static Executable Link Flags (`HsLinkExecutable`)**: When `hs_tc.bignum == "native"` and targeting static `musl`, `staged_ghc` already omits `gmp_static_dir`; add `-optl-static` in `HsLinkExecutable` (`hs/private/rules.bzl`) so `zig cc -target x86_64-linux-musl` produces a 100% static ELF binary (`readelf -l` shows no `INTERP` segment and `readelf -d` shows zero `NEEDED` entries).
3. **Lockfile Flag Profile**: Document the two standard Hackage flag overrides needed when generating a `musl` / `bignum = native` lockfile via [`//tools/lock:lock`](../reference/lock-cli.md):
   ```bash
   bazel run @rules_hs//tools/lock:lock -- \
     --snapshot lts-24.67 \
     --flag crypton:integer-gmp=false \
     --flag cborg:optimize-gmp=false \
     ...
   ```
   *(Note: Pure-Haskell and C-FFI applications without cross-package Template Haskell C-allocator splices — including the entire 69-package `examples/size` application! — compile cleanly into static `musl` binaries; applications using cross-library TH + C FFI should stick with the default `deb10` `glibc` toolchain or run an external `iserv` proxy.)*
