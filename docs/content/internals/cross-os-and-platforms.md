---
title: "Cross-OS Architecture & Platform Blueprints"
description: "Multi-architecture toolchain resolution, why glibc deb10 was chosen over static musl on Linux, and implementation blueprints for macOS, Windows, and static musl."
section: internals
nav_title: "Cross-OS & Platforms"
order: 50
---

> **New to Bazel Toolchains or GHC Internals?** Read the [Bazel Ruleset Primer](bazel-rules-primer.md) ([Toolchains & Configurations](bazel-rules-primer.md#toolchains-and-configs)) and the [Haskell & GHC Primer](haskell-and-ghc-primer.md) ([Why GMP and libtinfo Show Up](haskell-and-ghc-primer.md#gmp-and-tinfo) and [Template Haskell](haskell-and-ghc-primer.md#template-haskell)) first for background context.

`rules_hs` separates platform-specific GHC archive metadata, OS/CPU constraint mapping, and Cabal conditional `select()` evaluation from its core Starlark rule implementations. Today, `linux_x86_64` and `linux_arm64` are active in `SUPPORTED_PLATFORMS` (`linux_x86_64` is tested on every commit in GitHub Actions CI), while `macos_arm64`, `macos_x86_64`, `windows_x86_64`, and `linux_x86_64_musl` are cataloged with verified upstream URLs and SHA-256 digests for GHC `9.10.3` and `9.12.4` in `hs/private/ghc_versions.bzl`.

This page explains how multi-platform toolchain resolution and cross-platform `hackage.lock.json` generation work today, why Debian 10 (`glibc`) was chosen over Alpine (`musl` static) as the default Linux GHC archive, and what specific changes are needed to enable macOS, Windows, and static Linux `musl`.

---

## Declarative Bindist Matrix (`hs/private/ghc_versions.bzl`) {#ghc-versions-table}

`hs/private/ghc_versions.bzl` is a data-only Starlark file defining `DEFAULT_GHC_VERSION = "9.10.3"`, `SUPPORTED_PLATFORMS = ["linux_x86_64", "linux_arm64"]`, `BOOT_PACKAGE_NAMES` (42 `.conf` entries for `9.10.3` and 43 for `9.12.4`, which adds `file-io` — covering the 41/42 Haskell boot libraries plus GHC's metadata-only `system-cxx-std-lib` entry), and `GHC_BINDISTS`.

Each entry in `GHC_BINDISTS[ghc_version][platform_key]` records eleven platform properties:

| Platform Key | Current Status | Upstream Archive Name (`9.10.3` & `9.12.4`) | `os` / `cpu` | `arch_libdir` (`9.10.3`) | `bignum` | `dynamic_ghc` | `needs_tinfo_stub` |
|---|---|---|---|---|---|---|---|
| `linux_x86_64` | **Active** (`SUPPORTED_PLATFORMS`, CI-tested) | `ghc-<ver>-x86_64-deb10-linux.tar.xz` | `linux` / `x86_64` | `x86_64-linux-ghc-9.10.3` | `"gmp"` | `True` | `True` |
| `linux_arm64` | **Active** (`SUPPORTED_PLATFORMS`) | `ghc-<ver>-aarch64-deb10-linux.tar.xz` | `linux` / `arm64` | `aarch64-linux-ghc-9.10.3` | `"gmp"` | `True` | `True` |
| `macos_arm64` | Cataloged + lockfile `select()` emitted | `ghc-<ver>-aarch64-apple-darwin.tar.xz` | `macos` / `arm64` | `aarch64-osx-ghc-9.10.3` | `"gmp"` | `True` | `False` |
| `macos_x86_64` | Cataloged + lockfile `select()` emitted | `ghc-<ver>-x86_64-apple-darwin.tar.xz` | `macos` / `x86_64` | `x86_64-osx-ghc-9.10.3` | `"gmp"` | `True` | `False` |
| `windows_x86_64` | Cataloged | `ghc-<ver>-x86_64-unknown-mingw32.tar.xz` | `windows` / `x86_64` | `x86_64-windows-ghc-9.10.3` | `"gmp"` | `False` | `False` |
| `linux_x86_64_musl` | Cataloged static Linux option | `ghc-<ver>-x86_64-alpine3_12-linux-static-int_native.tar.xz` | `linux` / `x86_64` | `x86_64-linux-ghc-9.10.3` | `"native"` | `False` | `False` |

`staged_ghc` (`hs/private/staged_ghc.bzl`) branches on those capability attributes rather than hardcoding Linux assumptions:

- `if ctx.attr.bignum == "gmp":` — skips `@gmp//:gmp` archive extraction and `gmp_static/libgmp.a` symlinks when `bignum == "native"`.
- `if ctx.attr.is_dynamic_ghc:` — skips `HsLinkGmpShared` (`libgmp.so.10`) and omits `ghc-iserv-dyn` when `dynamic_ghc == False`.
- `if ctx.attr.needs_tinfo_stub and ctx.file.tinfo_stub:` — stages `libtinfo.so.6` and `libtinfo.a` only for Linux `deb10` archives (`False` on macOS, Windows, and Alpine `musl`).

---

## Bazel Toolchain Resolution and Multi-Arch Support {#toolchain-resolution}

### Lazy Archive Downloads via `@hs_toolchains`

When a workspace configures [`hs.toolchain`](../reference/extensions-and-providers.md#hs-toolchain) in `MODULE.bazel`, `_hs_extension_impl` (`hs/extensions.bzl`) declares three kinds of repositories:

1. **Lazy per-platform GHC repositories** (`@ghc_9_10_3_linux_x86_64`, `@ghc_9_10_3_linux_arm64`, ...). Because Bazel evaluates a `toolchain()` declaration's `toolchain = "@ghc_9_10_3_<plat>//:toolchain_impl"` label lazily *after* matching `exec_compatible_with` and `target_compatible_with`, an `x86_64` Linux machine never downloads the `arm64` GHC archive (and vice versa).
2. **`@hs_toolchains` (`hs_toolchains_repo` in `hs/private/ghc_bindist.bzl`)**: Writes one Bazel `toolchain()` declaration per enabled platform:
   ```starlark
   toolchain(
       name = "ghc_linux_arm64",
       exec_compatible_with = ["@platforms//os:linux", "@platforms//cpu:arm64"],
       target_compatible_with = ["@platforms//os:linux", "@platforms//cpu:arm64"],
       toolchain = "@ghc_9_10_3_linux_arm64//:toolchain_impl",
       toolchain_type = "@rules_hs//hs:toolchain_type",
   )
   ```
3. **`@hs_boot` (`hs_boot_repo`)**: Exposes platform-independent [`hs_toolchain_library`](../reference/rules.md#hs_toolchain_library) targets (`@hs_boot//:base`, etc.) that read package IDs from whichever `hs_toolchain` Bazel selected for the current build configuration.

### `linux_x86_64` and `linux_arm64` Layout Parity

Both active Linux architectures use the same layout and toolchain conventions:

- Upstream `deb10` archives on both `x86_64` and `aarch64` carry the same `$ORIGIN/../lib/<arch>-linux-ghc-<ver>` ELF `RUNPATH`, include `libffi.so.8` and `libCffi.a`, import the same 8 `libtinfo.so.6` `@NCURSES6_TINFO_5.0.19991023` functions, and keep `glibc` symbol version requirements at or below `GLIBC_2.28` (`memfd_create`, `fcntl64`, `statx`).
- Both pair with `hermetic_cc_toolchain` (`@zig_sdk//toolchain:linux_amd64_gnu.2.32` and `@zig_sdk//toolchain:linux_arm64_gnu.2.32`).
- `_hsc2hs_ghc_defines` (`hs/private/actions.bzl`) maps Bazel's `target_cpu = "arm64"` to Cabal's `-Daarch64_BUILD_ARCH=1` and `-Daarch64_HOST_ARCH=1` C preprocessor macros.

### Multi-Platform `hackage.lock.json` `select()` Generation

A single `hackage.lock.json` produced by [`//tools/lock:lock`](../reference/lock-cli.md) already records platform conditionals across Linux and macOS (`x86_64` and `arm64`):

- `allPlatforms` in `tools/lock/CabalExtract.hs` runs `finalizePD` for `linux_x86_64`, `linux_arm64`, `macos_arm64`, and `macos_x86_64`.
- `_PLATFORM_CONFIGS` in `hs/private/hackage.bzl` generates matching `config_setting` targets (`_linux_x86_64`, `_linux_arm64`, `_macos_arm64`, `_macos_x86_64`) and `select({...})` expressions for `srcs`, `hsc_srcs`, `c_sources`, `install_includes`, `include_dirs`, `hs_source_dirs`, `exposed_modules`, `other_modules`, `reexported_modules`, `default_extensions`, `ghc_opts`, `cpp_options`, `cc_options`, and `deps`.

---

## Why `deb10` (`glibc`) Was Chosen Over `alpine3_12` (`musl`) as the Linux Default {#deb10-vs-musl}

### Background: `glibc` vs. `musl` libc on Linux

On Linux, programs normally call the **C standard library (`libc`)** rather than raw kernel system calls for memory allocation (`malloc` and `free`), threads (`pthread_create`), DNS resolution (`getaddrinfo`), and dynamic library loading (`dlopen`). Linux distributions use one of two main `libc` implementations:

- **`glibc` (GNU C Library)**: The dynamic system C library (`libc.so.6` and `ld-linux.so`) shipped by Debian, Ubuntu, RHEL/Rocky, Fedora, and Arch Linux. It uses symbol versioning (`@GLIBC_2.xx`, described in [Hermeticity & Toolchain](hermeticity.md#glibc-window-and-ci)) and provides the standard OS dynamic loader (`dlopen`).
- **`musl` libc**: A lightweight C standard library used by Alpine Linux, designed so its static library (`libc.a`) links into standalone static ELF executables (`PT_INTERP = NONE` — meaning the ELF header requests no dynamic linker from the kernel).

When selecting `rules_hs`'s Linux GHC archive, both official Haskell.org GHC `9.10.3` Linux builds were tested with `hermetic_cc_toolchain` (`zig cc`) under `env -i PATH=/nonexistent`:

1. `ghc-9.10.3-{x86_64,aarch64}-deb10-linux.tar.xz` (dynamically linked `glibc` compiler, `bignum = gmp`)
2. `ghc-9.10.3-x86_64-alpine3_12-linux-static-int_native.tar.xz` (statically linked `musl` compiler, `PT_INTERP = NONE`, `bignum = native`)

Although a statically linked compiler binary avoids `$ORIGIN` shared-library staging, testing uncovered five practical trade-offs that make `deb10` (`glibc`) the better default:

| Comparison Area | `deb10` (`glibc`, Default) | `alpine3_12-linux-static-int_native` (`musl`, Opt-In) |
|---|---|---|
| **1. Upstream CPU availability** | Published for **both `x86_64` and `aarch64`** (`linux_arm64`) in GHC `9.10` and `9.12`. | **`x86_64` only** — upstream GHC does not publish `aarch64` static Alpine archives for GHC `9.10` or `9.12`. |
| **2. Template Haskell + C FFI** | Built with `GHC Dynamic = YES` (`ghc-iserv-dyn`); the OS dynamic loader (`dlopen`) loads `.so` libraries reliably when Template Haskell splices call C functions (`withCString`, `CApiFFI`). | Built with `GHC Dynamic = NO`; uses GHC's internal static-archive loader (`rts/Linker.c`), which **crashes with `SIGSEGV`** when cross-package Template Haskell splices call C `withCString` / `malloc` because two copies of `musl` `libc.a` collide in memory. |
| **3. BCR `cc_library` compatibility** | Matches the ABI of standard `glibc` `cc_toolchain`s (`hermetic_cc_toolchain` `gnu.2.32`, `toolchains_llvm`, GCC). | Cannot link against `glibc` C libraries (`undefined symbol: posix_spawn_file_actions_addchdir_np` in `libHSprocess.a` on older `glibc`, plus C struct layout differences); requires all `cc_library` targets to target `musl`. |
| **4. `Integer` bignum backend** | `bignum = "gmp"` — Hackage packages (`crypton`, `cborg`, `scientific`) build with their default flags and use GMP's assembly routines. | `bignum = "native"` — breaks Hackage packages that default `flag(integer-gmp)` or `flag(optimize-gmp)` to `True` unless overridden in `hackage.lock.json`, and uses slower pure-Haskell bignum arithmetic. |
| **5. Output binary portability** | Static `gmp_static/libgmp.a` produces ELF binaries whose `DT_NEEDED` entries are limited to base `glibc` (`libc`, `libm`, `libdl`, `libpthread`), running on Debian 10+, Ubuntu 22.04+, Rocky 8/9, and distroless `cc-debian12`. | Produces `PT_INTERP = NONE` static binaries (useful specifically for `FROM scratch` container images that have no `/lib/libc.so.6`). |

> **Note — Why Two Copies of `libc.a` Inside Static `musl` GHC Segfault During Template Haskell + C FFI:** Because the `alpine3_12-linux-static-int_native` `ghc` executable is statically linked (`PT_INTERP = NONE`), no OS dynamic linker is mapped into the process (`dlopen` cannot be used). To run cross-package [Template Haskell](haskell-and-ghc-primer.md#template-haskell) splices (`GHC Dynamic = NO`), GHC falls back to its own user-space ELF object loader (`rts/Linker.c`), which reads `.a` static archives from disk, maps executable memory pages via `mmap`, and resolves ELF relocations manually.
>
> The crash happens because the `ghc` executable *already* contains a compiled-in copy of `musl`'s `libc.a`, whose heap allocator locks and Thread-Local Storage (`TLS`, `%fs` register) state were initialized by `__libc_start_main` when `ghc` started. When a Template Haskell splice calls a C function (`withCString`, `malloc`, `strlen`), `rts/Linker.c` satisfies unresolved C symbols by loading `.o` files from a *second* `libc.a` archive off disk into fresh `mmap` pages — without running `libc` startup initialization on that second copy. When splice code calls into the second copy's uninitialized allocator locks or TLS pointers, `ghc` terminates with `SIGSEGV`. Dynamic `deb10` avoids `rts/Linker.c` by loading `.so` shared libraries through the OS's `dlopen`, which shares the single already-initialized `libc.so.6` across the process.

---

## Implementation Blueprint: Enabling macOS (`macos_arm64` and `macos_x86_64`) {#blueprint-macos}

### Background: Mach-O `LC_LOAD_DYLIB`, `@rpath`, `@loader_path`, and `-install_name` vs. Linux ELF

macOS uses the **Mach-O** executable format and Apple's **`dyld`** dynamic linker (inspected with `otool -L` and `otool -l`) instead of Linux's ELF format and `ld-linux.so`. The staging model translates directly once you map the dynamic-linker concepts across the two operating systems:

| Concept | Linux ELF (`ld-linux.so`) | macOS Mach-O (`dyld`) |
|---|---|---|
| **Shared library extension** | `.so` (`libgmp.so.10`) | `.dylib` (`libgmp.10.dylib`) |
| **Library's recorded identity** | `DT_SONAME` (`-Wl,-soname,libgmp.so.10` — bare filename) | `LC_ID_DYLIB` **`install_name`** (`-Wl,-install_name,@rpath/libgmp.10.dylib` — virtual path) |
| **Executable's import record** | `DT_NEEDED` (`libgmp.so.10`) | **`LC_LOAD_DYLIB`** (copies the `.dylib`'s `install_name` verbatim at link time) |
| **Search path list on binary** | `DT_RUNPATH` | **`LC_RPATH`** |
| **Binary-relative path token** | **`$ORIGIN`** (`$ORIGIN/../lib/...`) | **`@loader_path`** (`@loader_path/../lib/...`, directory of the loading binary or dylib) |
| **Include entire static `.a` in shared lib** | `-Wl,--whole-archive lib.a -Wl,--no-whole-archive` | `-Wl,-force_load,lib.a` |
| **Rescan circular static `.a` archives** | Requires `-Wl,--start-group ... -Wl,--end-group` | Done automatically by Apple `ld64` / `ld-prime` (`--start-group` is rejected) |

On macOS, `-install_name @rpath/...` and `@loader_path` work together: if `libgmp.10.dylib` were linked *without* `-Wl,-install_name,@rpath/libgmp.10.dylib`, the linker would record its temporary Bazel output path (`bazel-out/.../libgmp.10.dylib`) inside `LC_ID_DYLIB`, and any binary linking against it would copy that sandbox path into `LC_LOAD_DYLIB`. Setting `-install_name @rpath/libgmp.10.dylib` instructs `dyld` to expand `@rpath` using the loading binary's `LC_RPATH` list, where `@loader_path/../lib/<arch>-osx-ghc-<ver>` resolves relative to `staged_ghc/bin/ghc-<ver>`, matching Linux `$ORIGIN`.

Both Apple Silicon (`macos_arm64`) and Intel (`macos_x86_64`) archives are already pinned in `hs/private/ghc_versions.bzl`, `needs_tinfo_stub` is already `False`, `_hsc2hs_ghc_defines` already passes `-Ddarwin_BUILD_OS=1 -Ddarwin_HOST_OS=1`, and `hackage.lock.json` already contains `macos_arm64` and `macos_x86_64` `select()` deltas.

Enabling macOS requires three targeted changes:

### Step 1: Mach-O `@loader_path` Staging (`hs/private/staged_ghc.bzl`)

- **Shared GMP (`HsLinkGmpShared`)**: On Darwin (`target_os == "macos"`), build `libgmp.10.dylib` (plus a `libgmp.dylib` symlink) instead of `libgmp.so.10`, using Mach-O linker flags:
  ```bash
  "$CC" -dynamiclib -fPIC \
      -Wl,-install_name,@rpath/libgmp.10.dylib \
      -Wl,-force_load,"$GMP_PIC_A" \
      -o "$OUT_GMP_DYLIB"
  ```
- **Compiler `LC_RPATH` and Apple Silicon code signing**: Official Darwin GHC archives already carry `@loader_path/../lib/<arch>-osx-ghc-<ver>` `LC_RPATH` entries and link system `/usr/lib/libSystem.B.dylib`, `/usr/lib/libiconv.2.dylib`, and bundled `libffi.dylib`. Placing `libgmp.10.dylib` inside `<prefix>/lib/<arch>-osx-ghc-<ver>/` satisfies `dyld` without `DYLD_LIBRARY_PATH` or `install_name_tool` rewriting. (On Apple Silicon `arm64`, macOS requires valid code signatures at `execve` and `dlopen` time; avoiding binary header edits keeps upstream signatures valid, and `/usr/bin/codesign --force -s -` can apply an ad-hoc signature if file copies ever invalidate one.)

### Step 2: Mach-O Linker Flag Adjustments (`cc_wrapper.c`, `actions.bzl`, `rules.bzl`)

Apple's `ld64` / `ld-prime` and `lld -flavor darwin` reject several ELF-specific linker flags currently passed on Linux:

- In `hs/private/actions.bzl` (`ghc_tool_flags`): Pass `-optl-Wl,--no-as-needed` only when `hs_tc.target_os == "linux"`, and when `cc_tools.ld` is empty or `/usr/bin/false` (as in `hermetic_cc_toolchain` on macOS), use `ghc_cc_wrapper` or `ld -r` for `-pgmlm`.
- In `hs/private/rules.bzl` (`HsLinkExecutable`):
  - Pass `-optl-no-pie` only when `hs_tc.target_os == "linux"` (macOS `arm64` requires PIE executables and GHC's Darwin boot archives are already compiled with PIC).
  - Omit `-optl-Wl,--start-group` and `-optl-Wl,--end-group` when `hs_tc.target_os == "macos"` because Darwin's linker rescans static `.a` archives automatically and treats `--start-group` as an unknown option.
- In `hs/private/cc_wrapper.c`: Rewrite `-Wl,-h,<name>` to `-Wl,-soname,<name>` only on ELF targets, leaving `-install_name` / `-Wl,-install_name,@rpath/...` untouched on Darwin (`-dynamic-too` produces `.dylib` shared libraries rather than `.so`).

### Step 3: Enable and Test (`ghc_versions.bzl` + `otool -L` Check)

- Add `"macos_arm64"` and `"macos_x86_64"` to `SUPPORTED_PLATFORMS` in `hs/private/ghc_versions.bzl`.
- Extend `elf_hermeticity_test.sh` with a macOS branch running `otool -L "$BIN"` and checking that linked dynamic libraries are limited to `/usr/lib/libSystem.B.dylib` and `/usr/lib/libiconv.2.dylib` (no `libgmp.10.dylib`, no `libHS*.dylib`, and no `/opt/homebrew/*` or `/usr/local/*` paths).

---

## Implementation Blueprint: Enabling Windows (`windows_x86_64`) {#blueprint-windows}

### Background: Windows PE `.exe`/`.dll` Search Paths, `CreateProcessW` Quoting, and Avoiding `/bin/sh`

Supporting native Windows builds without requiring MSYS2 or Cygwin involves three OS differences from Linux and macOS:

1. **PE/COFF `.exe` and `.dll` loading (no `$ORIGIN` or `@loader_path`)**: Windows Portable Executable (`PE`) binaries have no embedded relative RPATH field. When starting `foo.exe`, the Windows loader checks **(a) the directory containing `foo.exe`**, followed by `C:\Windows\System32` and `%PATH%`. Upstream Windows GHC (`x86_64-unknown-mingw32`) therefore builds `ghc.exe` statically (`dynamic_ghc = False`, with GMP and boot libraries linked directly into `ghc.exe` and any MinGW `.dll` files placed beside the `.exe` tools), avoiding `%PATH%` DLL search issues.
2. **`CreateProcessW` command-line string quoting vs. POSIX `execv`**: On Linux and macOS, `execv(path, argv)` passes an array of null-terminated argument strings directly to the kernel, so spaces, quotes, and backslashes need no escaping. On Windows, `CreateProcessW` takes a **single flat UTF-16 string** (`lpCommandLine`) that the child process splits back into `argc`/`argv` using `CommandLineToArgvW` rules (where backslashes `\` are literal path separators except immediately before `"`, requiring `2n` or `2n+1` backslash escaping).
3. **Administrator-only symlinks and no built-in `/bin/sh`**: On Windows, `CreateSymbolicLinkW` fails unless Administrator privileges or Developer Mode are enabled (whereas hard links via `CreateHardLinkW` and copies via `CopyFileW` work for unprivileged users), and standard Windows installations do not provide `/bin/sh` unless MSYS2 or Git Bash is installed.

Official `ghc-{9.10.3,9.12.4}-x86_64-unknown-mingw32.tar.xz` archives are already recorded in `hs/private/ghc_versions.bzl` (`dynamic_ghc = False`, `needs_tinfo_stub = False`), and `_hsc2hs_ghc_defines` already passes `-Dmingw32_BUILD_OS=1 -Dmingw32_HOST_OS=1`. Enabling native Windows involves four steps:

### Step 1: `.exe` Suffixes and Bundled MinGW Toolchain (`ghc_bindist.bzl`, `staged_ghc.bzl`, `rules.bzl`)

- Add `.exe` suffixes to compiler executable declarations when `target_os == "windows"` (`ghc-9.10.3.exe`, `ghc-pkg-9.10.3.exe`, `hsc2hs-ghc-9.10.3.exe`, `haddock-ghc-9.10.3.exe`, `unlit.exe`) and to [`hs_binary`](../reference/rules.md#hs_binary) / [`hs_test`](../reference/rules.md#hs_test) output files (`ctx.label.name + ".exe"`).
- Stage the `mingw/` directory bundled inside the Windows GHC archive (or connect Bazel's Windows Clang/MinGW `cc_toolchain`) inside `staged_ghc`.

### Step 2: Win32 Port of `hs/private/cc_wrapper.c`

Add `#ifdef _WIN32` branches in `cc_wrapper.c`:

- Replace `unsetenv("RUNFILES_DIR")` with `_putenv_s("RUNFILES_DIR", "")` (and `RUNFILES_MANIFEST_FILE`, `RUNFILES_MANIFEST_ONLY`).
- Replace `realpath` and `symlink` in `ensure_dot_o_alias` with `GetFullPathNameW` and `CreateHardLinkW` (falling back to `CopyFileW` across drives) so builds do not require symlink privileges.
- Replace `execv(real_cc, final_args.items)` with `CreateProcessW` (encoding `final_args` according to `CommandLineToArgvW` quoting rules for spaces, `"`, and trailing `\`), followed by `WaitForSingleObject` and `GetExitCodeProcess`.

### Step 3: Native C Action Runner Instead of `run_shell` (`hs_action_runner.c`)

`HsStageGhc`, `HsHsc2hs`, `HsCompileLibrary`, and `HsLinkExecutable` currently use `ctx.actions.run_shell` (`mktemp -d`, `cp -R`, `rm -rf`). Replacing those shell wrappers with a small cross-platform C11 runner binary (`//hs/private:hs_action_runner`, built with `cc_binary` alongside `ghc_cc_wrapper`) invoked via `ctx.actions.run` removes `/bin/sh` and MSYS2 requirements on Windows (except for packages using `build-type: Configure`, which inherently run an upstream POSIX `./configure` shell script).

### Step 4: Windows Platform Entry in `tools/lock` and `hackage.bzl`

- Add `("windows_x86_64", Platform X86_64 Windows)` to `allPlatforms` in `tools/lock/CabalExtract.hs` and `_PLATFORM_CONFIGS` in `hs/private/hackage.bzl`.
- Include `"Win32"` in `builtinBootPackages` for Windows and keep `Win32` in `pdDeps` on the `windows_x86_64` `select()` branch while continuing to filter it out on Linux and macOS.

---

## Implementation Blueprint: Linux Static `musl` (`linux_x86_64_musl`) {#blueprint-linux-musl}

For deployments targeting empty `FROM scratch` container images that contain no `/lib/libc.so.6` (`PT_INTERP = NONE`), `linux_x86_64_musl` (`ghc-{9.10.3,9.12.4}-x86_64-alpine3_12-linux-static-int_native.tar.xz`) can be enabled as an opt-in Linux toolchain:

1. **Separate `libc` Constraint Value**: Today `linux_x86_64` and `linux_x86_64_musl` in `hs/private/ghc_versions.bzl` list the same `["@platforms//os:linux", "@platforms//cpu:x86_64"]` constraints. Registering both at once without a distinguishing `libc` constraint would cause Bazel to pick whichever toolchain came first. Add a `libc_musl` constraint (`@rules_hs//hs/constraints:libc_musl` / `@zig_sdk//libc:musl`) to `linux_x86_64_musl`'s `target_constraints`, selected via `--platforms=//:linux_x86_64_musl` alongside `@zig_sdk//libc_aware/toolchain:linux_amd64_musl`.
2. **Static Link Flag (`HsLinkExecutable`)**: When `hs_tc.bignum == "native"` and targeting static `musl`, `staged_ghc` already skips `gmp_static_dir`; pass `-optl-static` in `HsLinkExecutable` (`hs/private/rules.bzl`) so `zig cc -target x86_64-linux-musl` produces a fully static ELF executable (`readelf -l` shows no `INTERP` header and `readelf -d` shows no `NEEDED` libraries).
3. **Lockfile Flag Overrides**: When generating a lockfile for `bignum = "native"` via [`//tools/lock:lock`](../reference/lock-cli.md), disable explicit GMP flags on packages that expose them:
   ```bash
   bazel run @rules_hs//tools/lock:lock -- \
     --snapshot lts-24.67 \
     --flag crypton:integer-gmp=false \
     --flag cborg:optimize-gmp=false \
     ...
   ```
   *(Applications that use Haskell and C FFI without cross-package Template Haskell C-allocator splices — including the 69-package `examples/size` binary — link cleanly into static `musl` executables; applications that run cross-library Template Haskell splices calling C `malloc` should use the default `deb10` `glibc` toolchain or an external `iserv` runner.)*
