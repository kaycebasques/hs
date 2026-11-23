# `examples/` — Standalone Feature Examples for `rules_hs`

Every directory in `examples/` is a standalone Bazel 9 (`MODULE.bazel`) workspace with automated tests (`bazel test //...`).

## Example Workspaces

| Example | What It Demonstrates |
|---|---|
| [`quickstart/`](quickstart/README.md) | `hs_library`, `hs_binary`, `hs_test`, `hs_toolchain_library`, `@hs_boot`, default GHC `9.10.3`, and portable static-GMP Linux executables (`readelf -d` + `env -i PATH=/nonexistent`). |
| [`ghc_9_12/`](ghc_9_12/README.md) | Official GHC `9.12.4` toolchain (`hs.toolchain(ghc_version = "9.12.4")`), GHC 9.12's `file-io` boot library, `GHC2024`, `hs_haddock`, and static-GMP linking. |
| [`language_features/`](language_features/README.md) | `Haskell98`/`Haskell2010`/`GHC2021`/`GHC2024`, `default_extensions` & `ghc_opts`, `hidden_modules`, `.hs-boot` mutual recursion, `.lhs` literate Haskell, single-threaded & `-threaded` RTS, compile-time & runtime `data` runfiles, and Template Haskell (`TemplateHaskellQuotes`, cross-library splices, and `file-embed`). |
| [`c_interop/`](c_interop/README.md) | Standard `foreign import ccall` and `CApiFFI`, inline `c_sources` (C `.c`, C++ `.cc`, preprocessed assembly `.S`, and raw assembly `.s`), in-repository `cc_library` `cc_deps`, and Bazel Central Registry `cc_deps` (`@zlib//:zlib`). |
| [`llvm_toolchain/`](llvm_toolchain/README.md) | Pairing `rules_hs` with `toolchains_llvm` (Clang + catalogued `mold` linker + pinned Debian 11 `bullseye` sysroot) instead of `hermetic_cc_toolchain`. |
| [`system_cc_toolchain/`](system_cc_toolchain/README.md) | Pairing `rules_hs` with Bazel `rules_cc`'s host GCC or Clang toolchain (no `hermetic_cc_toolchain` or `toolchains_llvm`). |
| [`hackage/`](hackage/README.md) | `@rules_hs//tools/lock:lock`, `hackage.from_lock`, `hackage.override` (attaching BCR `@zlib//:zlib` and `configure_args`), `Simple`/`Configure`/`Custom` (`cabal-doctest`), C-only Cabal packages, internal & Cabal 3.0 public sublibraries, `reexported-modules`, `Paths_<pkg>` & compile-time `data-files`, `.hsc` (`hsc2hs`), `.x` (`alex`), `.y`/`.ly` (`happy`), and `hs_cabal_library`. |
| [`haddock/`](haddock/README.md) | `hs_haddock` HTML pages, `--prologue`, syntax-highlighted hyperlinked source (`src/`), QuickJump search (`doc-index.json`), Hoogle output (`hoogle = True`), and cross-target `.haddock` interface linking (`haddock_deps`). |
| [`size/`](size/README.md) | Real-world 69-package HTTPS XML and `.xml.gz` sitemap page counter (`xml-conduit`, `http-client-tls`, `zlib`, `async`, `network`). |

## Feature-to-Example & Test Index

| Homepage Feature | Minimal Example | Example Test(s) | Root Test(s) |
|---|---|---|---|
| `hs_library`, `hs_binary`, `hs_test`, `hs_toolchain_library` | [`quickstart/`](quickstart/BUILD.bazel) | `//:greet_test`, `//:elf_hermeticity_test` | `//tests/basic:basic_test`, `//tests/starlark:...` |
| `hs_haddock` (HTML, hyperlinked source, QuickJump, Hoogle, cross-target `haddock_deps`) | [`haddock/`](haddock/BUILD.bazel) | `//:haddock_test` | `//tests/rules/haddock:haddock_test`, `//tests/starlark:hs_haddock_action_test` |
| `hs_cabal_library` (5-stage Cabal rule) | [`hackage/vendored_cabal/`](hackage/vendored_cabal/BUILD.bazel) | `//vendored_cabal:vendored_cabal_test` | `//tests/basic:basic_test`, `//tests/rules/codegen:codegen_test` |
| GHC `9.10.3` (default) & Linux `x86_64` / `arm64` toolchains | [`quickstart/`](quickstart/MODULE.bazel) | `//:greet_test` | `//tests/starlark:toolchain_linux_x86_64_registered_test`, `//tests/starlark:toolchain_linux_arm64_registered_test` |
| GHC `9.12.4` | [`ghc_9_12/`](ghc_9_12/MODULE.bazel) | `//:ghc_9_12_test`, `//:elf_hermeticity_test` | CI + `examples/ghc_9_12/...` |
| Portable Linux binaries (static `libgmp.a`, base `glibc` `DT_NEEDED`, `env -i`) | [`quickstart/`](quickstart/test/elf_hermeticity_test.sh) | `//:elf_hermeticity_test` | `//tests/basic:elf_hermeticity_test`, `//tests/rules:bzlmod_hygiene_test` |
| Language editions (`Haskell98`, `Haskell2010`, `GHC2021`, `GHC2024`) | [`language_features/editions/`](language_features/editions/BUILD.bazel) | `//editions:editions_test` | `//tests/rules/lang:lang_test`, `//tests/starlark:hs_library_ghc2024_flag_test` |
| `default_extensions`, `ghc_opts`, `cpp_options`, `hidden_modules` | [`language_features/modules/`](language_features/modules/BUILD.bazel) | `//modules:modules_test`, `//modules:hidden_check_test` | `//tests/rules/lang:lang_test`, `//tests/rules/lang:hidden_modules_test` |
| `.hs-boot` mutually recursive modules | [`language_features/mutual_recursion/`](language_features/mutual_recursion/BUILD.bazel) | `//mutual_recursion:mutual_recursion_test` | `//tests/basic:basic_test`, `//tests/rules/lang:lang_test` |
| `.lhs` literate Haskell sources | [`language_features/literate/`](language_features/literate/BUILD.bazel) | `//literate:literate_test` | `//tests/rules/lang:lang_test`, `//tests/rules/haddock:haddock_test` |
| Single-threaded & multi-core (`-threaded`) GHC runtime | [`language_features/rts/`](language_features/rts/BUILD.bazel) | `//rts:single_threaded_test`, `//rts:multicore_threaded_test` | `//tests/rules/rts:non_threaded_rts_test`, `//tests/rules/rts:threaded_rts_test` |
| Bazel `data` runfiles (compile time & runtime) | [`language_features/runfiles/`](language_features/runfiles/BUILD.bazel) | `//runfiles:runfiles_test` | `//tests/rules/runfiles:runfiles_test`, `//tests/rules/th:file_embed_th_test` |
| Template Haskell (`TemplateHaskellQuotes`, cross-lib splices, `file-embed`) | [`language_features/template_haskell/`](language_features/template_haskell/BUILD.bazel) | `//template_haskell:th_test`, `//template_haskell:th_elf_test` | `//tests/rules/th:th_test`, `//tests/rules/th:cross_lib_th_test`, `//tests/rules/th:file_embed_th_test` |
| `foreign import ccall` & `CApiFFI` | [`c_interop/`](c_interop/src/NativeInterop.hs) | `//:c_interop_test` | `//tests/rules/ffi:ffi_test` |
| Inline `c_sources` (C, C++, and assembly `.S`/`.s`) | [`c_interop/`](c_interop/BUILD.bazel) | `//:c_interop_test` | `//tests/rules/ffi:ffi_test` |
| `cc_deps` (repository `cc_library` & BCR `@zlib//:zlib`) | [`c_interop/`](c_interop/BUILD.bazel) | `//:c_interop_test`, `//:elf_hermeticity_test` | `//tests/rules/ffi:ffi_test` |
| C toolchains (`hermetic_cc_toolchain`, `toolchains_llvm`, GCC/Clang) | [`quickstart/`](quickstart/MODULE.bazel), [`llvm_toolchain/`](llvm_toolchain/MODULE.bazel), [`system_cc_toolchain/`](system_cc_toolchain/MODULE.bazel) | `//:llvm_test`, `//:sys_cc_test` | CI + standalone toolchain workspaces |
| `@rules_hs//tools/lock:lock`, `hackage.from_lock`, `hackage.override` | [`hackage/`](hackage/MODULE.bazel) | `//:hackage_test`, `//:elf_hermeticity_test` | `//tools/lock:lock_test`, `//tools/lock:lock_cli_test` |
| Cabal `Simple`, `Configure` (`./configure`), `Custom` (`cabal-doctest`) | [`hackage/`](hackage/test/HackageTest.hs) | `//:hackage_test` | `//tests/basic:basic_test`, `//tests/rules/codegen:codegen_test` |
| C-only Cabal packages, internal & Cabal 3.0 public sublibraries, `reexported-modules` | [`hackage/`](hackage/BUILD.bazel), [`hackage/vendored_cabal/`](hackage/vendored_cabal/BUILD.bazel) | `//:hackage_test`, `//vendored_cabal:vendored_cabal_test` | `//tests/basic:basic_test`, `//tests/rules/codegen:codegen_test` |
| `Paths_<pkg>` & compile-time `data-files`, `.hsc` (`hsc2hs`), `.x` (`alex`), `.y`/`.ly` (`happy`) | [`hackage/`](hackage/BUILD.bazel), [`hackage/vendored_cabal/`](hackage/vendored_cabal/BUILD.bazel) | `//:hackage_test`, `//vendored_cabal:vendored_cabal_test` | `//tests/basic:basic_test`, `//tests/rules/codegen:codegen_test` |
