---
title: "Cross-OS architecture and platform blueprints"
description: "Multi-architecture toolchain resolution, why glibc deb10 is the default over static musl on Linux, and implementation blueprints for macOS, Windows, and static musl."
section: internals
nav_title: "Cross-OS and platforms"
order: 50
---

This page explains how `rules_haskell` handles multi-platform [toolchain resolution](https://bazel.build/extending/toolchains) and cross-platform `hackage.lock.json` generation, why Debian 10 (`glibc`) is the default Linux GHC archive instead of Alpine (`musl` static), and what concrete changes enable macOS, Windows, and static Linux `musl`. Read this if you're porting `rules_haskell` to a new OS or CPU architecture, or evaluating Linux `glibc` versus `musl` trade-offs.

If you're new to Bazel toolchains or GHC's runtime dependencies, read [Toolchains and configurations](bazel-rules-primer.md#toolchains-and-configs), [Why GMP and libtinfo show up](haskell-and-ghc-primer.md#gmp-and-tinfo), and [Template Haskell](haskell-and-ghc-primer.md#template-haskell) first.

To keep core build rules portable, `rules_haskell` separates platform-specific GHC archive metadata, OS/CPU constraint mapping, and Cabal conditional [`select()`](https://bazel.build/configure/attributes) generation from its core [Starlark](https://bazel.build/rules/language) implementations. Today, `linux_x86_64` and `linux_arm64` are active in `SUPPORTED_PLATFORMS` (with `linux_x86_64` tested on every commit in GitHub Actions CI), while `macos_arm64`, `macos_x86_64`, `windows_x86_64`, and `linux_x86_64_musl` are already cataloged with verified upstream URLs and SHA-256 digests for GHC `9.10.3` and `9.12.4`.

---

## Declarative bindist matrix (`haskell/private/ghc_versions.bzl`) {#ghc-versions-table}

You can inspect or extend GHC platform archives in one data-only Starlark table (`haskell/private/ghc_versions.bzl`) without touching rule logic. It defines `DEFAULT_GHC_VERSION = "9.10.3"`, `SUPPORTED_PLATFORMS = ["linux_x86_64", "linux_arm64"]`, `BOOT_PACKAGE_NAMES` (42 `.conf` entries for `9.10.3` and 43 for `9.12.4`, which adds `file-io`—covering the 41/42 Haskell boot libraries plus GHC's metadata-only `system-cxx-std-lib` entry), and `GHC_BINDISTS`.

Each entry in `GHC_BINDISTS[ghc_version][platform_key]` records 11 platform properties:

| Platform key | Current status | Upstream archive name (`9.10.3` and `9.12.4`) | `os` / `cpu` | `arch_libdir` (`9.10.3`) | `bignum` | `dynamic_ghc` | `needs_tinfo_stub` |
|---|---|---|---|---|---|---|---|
| `linux_x86_64` | **Active** (`SUPPORTED_PLATFORMS`, CI-tested) | `ghc-<ver>-x86_64-deb10-linux.tar.xz` | `linux` / `x86_64` | `x86_64-linux-ghc-9.10.3` | `"gmp"` | `True` | `True` |
| `linux_arm64` | **Active** (`SUPPORTED_PLATFORMS`) | `ghc-<ver>-aarch64-deb10-linux.tar.xz` | `linux` / `arm64` | `aarch64-linux-ghc-9.10.3` | `"gmp"` | `True` | `True` |
| `macos_arm64` | Cataloged + lockfile `select()` emitted | `ghc-<ver>-aarch64-apple-darwin.tar.xz` | `macos` / `arm64` | `aarch64-osx-ghc-9.10.3` | `"gmp"` | `True` | `False` |
| `macos_x86_64` | Cataloged + lockfile `select()` emitted | `ghc-<ver>-x86_64-apple-darwin.tar.xz` | `macos` / `x86_64` | `x86_64-osx-ghc-9.10.3` | `"gmp"` | `True` | `False` |
| `windows_x86_64` | Cataloged | `ghc-<ver>-x86_64-unknown-mingw32.tar.xz` | `windows` / `x86_64` | `x86_64-windows-ghc-9.10.3` | `"gmp"` | `False` | `False` |
| `linux_x86_64_musl` | Cataloged static Linux option | `ghc-<ver>-x86_64-alpine3_12-linux-static-int_native.tar.xz` | `linux` / `x86_64` | `x86_64-linux-ghc-9.10.3` | `"native"` | `False` | `False` |

Toolchain staging (`staged_ghc` in `haskell/private/staged_ghc.bzl`) branches on those capability attributes instead of hardcoding Linux assumptions:

- **`bignum == "gmp"`:** Skips `@gmp//:gmp` archive extraction and `gmp_static/libgmp.a` symlinks when `bignum == "native"`.
- **`is_dynamic_ghc`:** Skips `HsLinkGmpShared` (`libgmp.so.10`) and omits `ghc-iserv-dyn` when `dynamic_ghc == False`.
- **`needs_tinfo_stub`:** Stages `libtinfo.so.6` and `libtinfo.a` only for Linux `deb10` archives (`False` on macOS, Windows, and Alpine `musl`).

---

## Bazel toolchain resolution and multi-arch support {#toolchain-resolution}

### Lazy archive downloads via `@hs_toolchains`

When you configure [`hs.toolchain`](../reference/extensions-and-providers.md#hs-toolchain) in [`MODULE.bazel`](https://bazel.build/external/module), `haskell/extensions.bzl` declares three repository types so Bazel downloads only the GHC archive matching your active platform:

1. **Lazy per-platform GHC repositories (`@ghc_9_10_3_linux_x86_64`, `@ghc_9_10_3_linux_arm64`, and so on):** Bazel evaluates a `toolchain()` rule's `toolchain = "@ghc_9_10_3_<plat>//:toolchain_impl"` label *after* matching [`exec_compatible_with`](https://bazel.build/concepts/platforms) and `target_compatible_with`. An `x86_64` Linux machine never fetches the `arm64` archive, and vice versa.
2. **Toolchain registrations (`@hs_toolchains`):** Generated by `hs_toolchains_repo` (`haskell/private/ghc_bindist.bzl`), writing one `toolchain()` declaration per enabled platform:
   ```starlark
   toolchain(
       name = "ghc_linux_arm64",
       exec_compatible_with = ["@platforms//os:linux", "@platforms//cpu:arm64"],
       target_compatible_with = ["@platforms//os:linux", "@platforms//cpu:arm64"],
       toolchain = "@ghc_9_10_3_linux_arm64//:toolchain_impl",
       toolchain_type = "@rules_haskell//haskell:toolchain_type",
   )
   ```
3. **Platform-independent boot libraries (`@hs_boot`):** Exposes [`hs_toolchain_library`](../reference/rules.md#hs_toolchain_library) targets (`@hs_boot//:base`, and the other boot libraries) that read package IDs from whichever `hs_toolchain` Bazel resolves for the current [build configuration](https://bazel.build/extending/config).

### `linux_x86_64` and `linux_arm64` layout parity

Both active Linux architectures share identical archive layout and toolchain conventions:

- **Shared `deb10` binary contract:** Upstream `x86_64` and `aarch64` archives both embed `$ORIGIN/../lib/<arch>-linux-ghc-<ver>` in ELF `RUNPATH`, bundle `libffi.so.8` and `libCffi.a`, import the same 8 `libtinfo.so.6` `@NCURSES6_TINFO_5.0.19991023` functions, and cap `glibc` symbol versions at `GLIBC_2.28` (`memfd_create`, `fcntl64`, `statx`).
- **Matching C toolchains:** Both pair with `hermetic_cc_toolchain` (`@zig_sdk//toolchain:linux_amd64_gnu.2.32` and `@zig_sdk//toolchain:linux_arm64_gnu.2.32`).
- **Architecture preprocessor macros:** During `hsc2hs` runs (`_hsc2hs_ghc_defines` in `haskell/private/actions.bzl`), Bazel's `target_cpu = "arm64"` maps to Cabal's `-Daarch64_BUILD_ARCH=1` and `-Daarch64_HOST_ARCH=1` C preprocessor macros.

### Multi-platform `hackage.lock.json` `select()` generation

A single `hackage.lock.json` generated by [`//tools/lock:lock`](../reference/lock-cli.md) already carries platform conditionals across Linux and macOS on both `x86_64` and `arm64`:

- **Four-platform evaluation at lock time:** `allPlatforms` in `tools/lock/CabalExtract.hs` evaluates each `.cabal` file with `finalizePD` for `linux_x86_64`, `linux_arm64`, `macos_arm64`, and `macos_x86_64`.
- **Automatic `select()` emission at build time:** `_PLATFORM_CONFIGS` in `haskell/private/hackage.bzl` emits matching [`config_setting`](https://bazel.build/reference/be/general#config_setting) targets (`_linux_x86_64`, `_linux_arm64`, `_macos_arm64`, `_macos_x86_64`) and `select({...})` expressions wherever a package's sources, include paths, module lists, compiler flags, or `deps` differ across platforms.

---

## Why `deb10` (`glibc`) was chosen over `alpine3_12` (`musl`) as the Linux default {#deb10-vs-musl}

### Background: `glibc` vs. `musl` libc on Linux

On Linux, programs typically call the **C standard library (`libc`)** rather than raw kernel syscalls for memory allocation (`malloc`/`free`), threads (`pthread_create`), DNS resolution (`getaddrinfo`), and dynamic loading (`dlopen`). Linux distributions rely on one of two main implementations:

- **`glibc` (GNU C Library):** The dynamic system C library (`libc.so.6` and `ld-linux.so`) used by Debian, Ubuntu, RHEL/Rocky, Fedora, and Arch Linux. It uses symbol versioning (`@GLIBC_2.xx`, covered in [Hermeticity and toolchain](hermeticity.md#glibc-window-and-ci)) and provides the standard OS dynamic loader (`dlopen`).
- **`musl` libc:** A lightweight C library used by Alpine Linux, designed so its static archive (`libc.a`) links into standalone static ELF executables (`PT_INTERP = NONE`, requesting no dynamic linker from the kernel).

Both official Haskell.org GHC `9.10.3` Linux archives were evaluated with `hermetic_cc_toolchain` (`zig cc`) under `env -i PATH=/nonexistent`:

1. `ghc-9.10.3-{x86_64,aarch64}-deb10-linux.tar.xz` (dynamically linked `glibc` compiler, `bignum = gmp`)
2. `ghc-9.10.3-x86_64-alpine3_12-linux-static-int_native.tar.xz` (statically linked `musl` compiler, `PT_INTERP = NONE`, `bignum = native`)

Although a static compiler binary avoids `$ORIGIN` shared-library staging, live testing surfaced five trade-offs that make `deb10` (`glibc`) the stronger default:

| Comparison area | `deb10` (`glibc`, default) | `alpine3_12-linux-static-int_native` (`musl`, opt-in) |
|---|---|---|
| **1. Upstream CPU availability** | Published for **both `x86_64` and `aarch64`** (`linux_arm64`) in GHC `9.10` and `9.12`. | **`x86_64` only**—upstream GHC doesn't publish `aarch64` static Alpine archives for GHC `9.10` or `9.12`. |
| **2. Template Haskell and C FFI** | Built with `GHC Dynamic = YES` (`ghc-iserv-dyn`); OS `dlopen` loads `.so` libraries reliably when TH splices call C functions (`withCString`, `CApiFFI`). | Built with `GHC Dynamic = NO`; falls back to GHC's internal static-archive loader (`rts/Linker.c`), which **crashes with `SIGSEGV`** when cross-package TH splices call C `withCString` or `malloc` because two copies of `musl` `libc.a` collide in memory. |
| **3. [BCR](https://bazel.build/external/registry#bazel-central-registry) [`cc_library`](https://bazel.build/reference/be/c-cpp#cc_library) compatibility** | Matches the ABI of standard `glibc` [`cc_toolchain`](https://bazel.build/reference/be/c-cpp#cc_toolchain)s (`hermetic_cc_toolchain` `gnu.2.32`, `toolchains_llvm`, GCC). | Can't link against `glibc` C libraries (`undefined symbol: posix_spawn_file_actions_addchdir_np` in `libHSprocess.a` on older `glibc`, plus C struct layout differences); requires all `cc_library` targets to target `musl`. |
| **4. `Integer` bignum backend** | `bignum = "gmp"`—Hackage packages (`crypton`, `cborg`, `scientific`) build with their default flags and use GMP's assembly routines. | `bignum = "native"`—breaks Hackage packages that default `flag(integer-gmp)` or `flag(optimize-gmp)` to `True` unless overridden in `hackage.lock.json`, and uses slower pure-Haskell bignum arithmetic. |
| **5. Output binary portability** | Static `gmp_static/libgmp.a` produces ELF binaries whose `DT_NEEDED` entries contain only base `glibc` (`libc`, `libm`, `libdl`, `libpthread`), running on Debian 10+, Ubuntu 22.04+, Rocky 8/9, and distroless `cc-debian12`. | Produces `PT_INTERP = NONE` static binaries (useful specifically for `FROM scratch` container images with no `/lib/libc.so.6`). |

> **Note:** Why do two copies of `libc.a` inside static `musl` GHC crash during Template Haskell with C FFI? Because `alpine3_12-linux-static-int_native` links `ghc` statically (`PT_INTERP = NONE`), no OS dynamic linker exists in the process, so `dlopen` isn't available. To evaluate cross-package Template Haskell splices, GHC uses its user-space ELF loader (`rts/Linker.c`) to map `.a` archives into memory via `mmap` and resolve relocations by hand.
>
> The `ghc` binary *already* holds one compiled-in copy of `musl`'s `libc.a` whose allocator locks and thread-local storage (`%fs` register) were initialized at startup by `__libc_start_main`. When a TH splice calls a C function (`withCString`, `malloc`, `strlen`), `rts/Linker.c` loads `.o` files from a *second* `libc.a` off disk without running `libc` startup initialization; calling into that second copy's uninitialized locks or TLS pointers triggers `SIGSEGV`. Dynamic `deb10` avoids `rts/Linker.c` by loading `.so` libraries through `dlopen`, which shares the single initialized `libc.so.6` across the process.

---

## Implementation blueprint: enabling macOS (`macos_arm64` and `macos_x86_64`) {#blueprint-macos}

### Background: Mach-O `LC_LOAD_DYLIB`, `@rpath`, `@loader_path`, and `-install_name` vs. Linux ELF

macOS uses the **Mach-O** binary format and Apple's **`dyld`** dynamic linker (inspected with `otool -L` and `otool -l`) instead of Linux ELF and `ld-linux.so`. The staging model translates directly once you map each dynamic-linker concept across both operating systems:

| Concept | Linux ELF (`ld-linux.so`) | macOS Mach-O (`dyld`) |
|---|---|---|
| **Shared library extension** | `.so` (`libgmp.so.10`) | `.dylib` (`libgmp.10.dylib`) |
| **Library's recorded identity** | `DT_SONAME` (`-Wl,-soname,libgmp.so.10`, bare filename) | `LC_ID_DYLIB` **`install_name`** (`-Wl,-install_name,@rpath/libgmp.10.dylib`, virtual path) |
| **Executable's import record** | `DT_NEEDED` (`libgmp.so.10`) | **`LC_LOAD_DYLIB`** (copies the `.dylib`'s `install_name` verbatim at link time) |
| **Search path list on binary** | `DT_RUNPATH` | **`LC_RPATH`** |
| **Binary-relative path token** | **`$ORIGIN`** (`$ORIGIN/../lib/...`) | **`@loader_path`** (`@loader_path/../lib/...`, directory of the loading binary or dylib) |
| **Include entire static `.a` in shared lib** | `-Wl,--whole-archive lib.a -Wl,--no-whole-archive` | `-Wl,-force_load,lib.a` |
| **Rescan circular static `.a` archives** | Requires `-Wl,--start-group ... -Wl,--end-group` | Automatic in Apple `ld64` / `ld-prime` (`--start-group` is rejected) |

On macOS, `-install_name @rpath/...` and `@loader_path` work as a pair. Without `-Wl,-install_name,@rpath/libgmp.10.dylib`, the linker records the temporary Bazel output path (`bazel-out/.../libgmp.10.dylib`) in `LC_ID_DYLIB`, leaking that [sandbox](https://bazel.build/docs/sandboxing) path into every downstream binary's `LC_LOAD_DYLIB`. Setting `-install_name @rpath/libgmp.10.dylib` tells `dyld` to resolve `@rpath` through the loading binary's `LC_RPATH`, where `@loader_path/../lib/<arch>-osx-ghc-<ver>` points relative to `staged_ghc/bin/ghc-<ver>` just like Linux `$ORIGIN`.

Apple Silicon (`macos_arm64`) and Intel (`macos_x86_64`) archives are already pinned in `haskell/private/ghc_versions.bzl` (`needs_tinfo_stub = False`), `_hsc2hs_ghc_defines` already passes `-Ddarwin_BUILD_OS=1 -Ddarwin_HOST_OS=1`, and `hackage.lock.json` already emits `macos_arm64` and `macos_x86_64` `select()` branches. Three changes remain to enable macOS:

### Step 1: stage Mach-O `@loader_path` libraries

Update `haskell/private/staged_ghc.bzl` to produce and stage Darwin dynamic libraries:

- **Shared GMP (`HsLinkGmpShared`):** When `target_os == "macos"`, build `libgmp.10.dylib` (plus a `libgmp.dylib` symlink) instead of `libgmp.so.10`:
  ```bash
  "$CC" -dynamiclib -fPIC \
      -Wl,-install_name,@rpath/libgmp.10.dylib \
      -Wl,-force_load,"$GMP_PIC_A" \
      -o "$OUT_GMP_DYLIB"
  ```
- **Compiler `LC_RPATH` and Apple Silicon code signing:** Official Darwin GHC archives already carry `@loader_path/../lib/<arch>-osx-ghc-<ver>` in `LC_RPATH` and link system `/usr/lib/libSystem.B.dylib`, `/usr/lib/libiconv.2.dylib`, and bundled `libffi.dylib`. Placing `libgmp.10.dylib` in `<prefix>/lib/<arch>-osx-ghc-<ver>/` satisfies `dyld` without `DYLD_LIBRARY_PATH` or `install_name_tool` header edits—keeping upstream code signatures intact on Apple Silicon (and `/usr/bin/codesign --force -s -` can re-apply an ad-hoc signature if copies ever invalidate one).

### Step 2: adjust Mach-O linker flags

Apple's `ld64`, `ld-prime`, and `lld -flavor darwin` reject several ELF-specific flags currently passed on Linux:

- **Conditional ELF flags (`haskell/private/actions.bzl`):** In `ghc_tool_flags`, pass `-optl-Wl,--no-as-needed` only when `hs_tc.target_os == "linux"`. When `cc_tools.ld` is empty or `/usr/bin/false` (as with `hermetic_cc_toolchain` on macOS), route `-pgmlm` through `ghc_cc_wrapper` or `ld -r`.
- **PIE and archive groups (`haskell/private/rules.bzl`):** In `HsLinkExecutable`, pass `-optl-no-pie` only on Linux (macOS `arm64` requires PIE executables and Darwin boot archives are already PIC). Omit `-optl-Wl,--start-group` and `-optl-Wl,--end-group` on macOS because Apple's linker rescans `.a` archives automatically and rejects `--start-group`.
- **Shared library naming (`haskell/private/cc_wrapper.c`):** Rewrite `-Wl,-h,<name>` to `-Wl,-soname,<name>` only on ELF targets, leaving `-install_name` and `-Wl,-install_name,@rpath/...` untouched on Darwin (where `-dynamic-too` produces `.dylib` libraries).

### Step 3: enable macOS platforms and add `otool -L` checks

- Add `"macos_arm64"` and `"macos_x86_64"` to `SUPPORTED_PLATFORMS` in `haskell/private/ghc_versions.bzl`.
- Extend `elf_hermeticity_test.sh` with a macOS branch that runs `otool -L "$BIN"` and asserts linked dynamic libraries are limited to `/usr/lib/libSystem.B.dylib` and `/usr/lib/libiconv.2.dylib`—no `libgmp.10.dylib`, no `libHS*.dylib`, and no `/opt/homebrew/*` or `/usr/local/*` paths.

---

## Implementation blueprint: enabling Windows (`windows_x86_64`) {#blueprint-windows}

### Background: Windows PE `.exe`/`.dll` search paths, `CreateProcessW` quoting, and avoiding `/bin/sh`

Supporting native Windows builds without requiring MSYS2 or Cygwin requires addressing three OS differences from Linux and macOS:

1. **PE/COFF `.exe` and `.dll` loading (no `$ORIGIN` or `@loader_path`):** Windows Portable Executable (`PE`) binaries don't have an embedded relative RPATH header. When launching `foo.exe`, the Windows loader checks the directory containing `foo.exe` first, then `C:\Windows\System32` and `%PATH%`. Official Windows GHC (`x86_64-unknown-mingw32`) therefore links `ghc.exe` statically (`dynamic_ghc = False`, baking GMP and boot libraries into `ghc.exe` and placing any MinGW `.dll` files beside the `.exe` tools) to avoid `%PATH%` DLL conflicts.
2. **`CreateProcessW` command-line quoting vs. POSIX `execv`:** On Linux and macOS, `execv(path, argv)` passes an array of null-terminated strings directly to the kernel, so spaces, quotes, and backslashes need no escaping. On Windows, `CreateProcessW` takes a single flat UTF-16 string (`lpCommandLine`) that the child process splits with `CommandLineToArgvW` rules, where backslashes are literal path separators except immediately before `"`, requiring `2n` or `2n+1` escaping.
3. **Administrator-only symlinks and no built-in `/bin/sh`:** `CreateSymbolicLinkW` fails unless Administrator privileges or Developer Mode are enabled (while `CreateHardLinkW` and `CopyFileW` work for unprivileged users), and stock Windows doesn't include `/bin/sh` without MSYS2 or Git Bash.

Official `ghc-{9.10.3,9.12.4}-x86_64-unknown-mingw32.tar.xz` archives are already recorded in `haskell/private/ghc_versions.bzl` (`dynamic_ghc = False`, `needs_tinfo_stub = False`), and `_hsc2hs_ghc_defines` already passes `-Dmingw32_BUILD_OS=1 -Dmingw32_HOST_OS=1`. Four steps enable native Windows builds:

### Step 1: add `.exe` suffixes and bundle MinGW

- In `ghc_bindist.bzl`, `staged_ghc.bzl`, and `rules.bzl`, append `.exe` to compiler binaries when `target_os == "windows"` (`ghc-9.10.3.exe`, `ghc-pkg-9.10.3.exe`, `hsc2hs-ghc-9.10.3.exe`, `haddock-ghc-9.10.3.exe`, `unlit.exe`) and to [`hs_binary`](../reference/rules.md#hs_binary) and [`hs_test`](../reference/rules.md#hs_test) outputs (`ctx.label.name + ".exe"`).
- Stage the `mingw/` directory bundled inside the Windows GHC archive inside `staged_ghc`, or wire Bazel's Windows Clang/MinGW `cc_toolchain`.

### Step 2: port `haskell/private/cc_wrapper.c` to Win32

Add `#ifdef _WIN32` branches for the three POSIX operations in `cc_wrapper.c`:

- Replace `unsetenv("RUNFILES_DIR")` (and `RUNFILES_MANIFEST_FILE`, `RUNFILES_MANIFEST_ONLY`) with `_putenv_s(..., "")`.
- Replace `realpath` and `symlink` in `ensure_dot_o_alias` with `GetFullPathNameW` and `CreateHardLinkW` (falling back to `CopyFileW` across drives) so builds don't need symlink privileges.
- Replace `execv(real_cc, final_args.items)` with `CreateProcessW` (encoding `final_args` using `CommandLineToArgvW` quoting rules for spaces, `"`, and trailing `\`), followed by `WaitForSingleObject` and `GetExitCodeProcess`.

### Step 3: replace `run_shell` with a native C action runner

`HsStageGhc`, `HsHsc2hs`, `HsCompileLibrary`, and `HsLinkExecutable` currently invoke [`ctx.actions.run_shell`](https://bazel.build/extending/rules#actions) (`mktemp -d`, `cp -R`, `rm -rf`). Replacing those shell scripts with a small cross-platform C11 binary (`//haskell/private:hs_action_runner`, built with [`cc_binary`](https://bazel.build/reference/be/c-cpp#cc_binary) beside `ghc_cc_wrapper`) run via `ctx.actions.run` removes the `/bin/sh` and MSYS2 dependency on Windows—except for `build-type: Configure` packages, which inherently run an upstream POSIX `./configure` shell script.

### Step 4: add Windows platform entries in `tools/lock` and `hackage.bzl`

- Add `("windows_x86_64", Platform X86_64 Windows)` to `allPlatforms` in `tools/lock/CabalExtract.hs` and `_PLATFORM_CONFIGS` in `haskell/private/hackage.bzl`.
- Include `"Win32"` in `builtinBootPackages` for Windows, keeping `Win32` in `pdDeps` on the `windows_x86_64` `select()` branch while continuing to filter it out on Linux and macOS.

---

## Implementation blueprint: Linux static `musl` (`linux_x86_64_musl`) {#blueprint-linux-musl}

If you deploy to empty `FROM scratch` container images that lack `/lib/libc.so.6` (`PT_INTERP = NONE`), you can enable `linux_x86_64_musl` (`ghc-{9.10.3,9.12.4}-x86_64-alpine3_12-linux-static-int_native.tar.xz`) as an opt-in Linux toolchain in three steps:

1. **Add a distinct `libc` constraint value:** Currently `linux_x86_64` and `linux_x86_64_musl` in `haskell/private/ghc_versions.bzl` share `["@platforms//os:linux", "@platforms//cpu:x86_64"]`. Registering both without a distinguishing constraint would make Bazel pick whichever came first. Add a `libc_musl` constraint (`@rules_haskell//haskell/constraints:libc_musl` or `@zig_sdk//libc:musl`) to `linux_x86_64_musl`'s `target_constraints`, selected with [`--platforms=//:linux_x86_64_musl`](https://bazel.build/reference/command-line-reference#param-platforms) alongside `@zig_sdk//libc_aware/toolchain:linux_amd64_musl`.
2. **Pass `-optl-static` in `HsLinkExecutable`:** When `hs_tc.bignum == "native"` and targeting static `musl`, `staged_ghc` already skips `gmp_static_dir`. Passing `-optl-static` in `haskell/private/rules.bzl` instructs `zig cc -target x86_64-linux-musl` to produce a fully static ELF executable (`readelf -l` shows no `INTERP` header and `readelf -d` shows no `NEEDED` libraries).
3. **Disable explicit GMP flags in your lockfile:** When generating `hackage.lock.json` for `bignum = "native"` with [`//tools/lock:lock`](../reference/lock-cli.md), turn off explicit GMP flags on packages that expose them:
   ```bash
   bazel run @rules_haskell//tools/lock:lock -- \
     --snapshot lts-24.67 \
     --flag crypton:integer-gmp=false \
     --flag cborg:optimize-gmp=false \
     ...
   ```

> **Note:** Applications using Haskell and C FFI without cross-package Template Haskell C-allocator splices—including the 69-package `examples/size` binary—link into static `musl` executables cleanly. If your build runs cross-library TH splices that call C `malloc`, use the default `deb10` `glibc` toolchain or an external `iserv` runner instead.
