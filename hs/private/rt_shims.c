/*
 * Minimal hidden weak fallback for LLVM/GCC's x86_64 `__cpu_model` runtime
 * symbol used by `__builtin_cpu_supports(...)` (e.g. Hackage `bitvec`).
 *
 * `hermetic_cc_toolchain` (`zig cc`) omits `cpu_model.c` from its bundled
 * `libcompiler_rt.a`, leaving `R_X86_64_PC32` relocations against `__cpu_model`
 * unresolved when linking shared libraries for Template Haskell (`-dynamic-too`)
 * or executables calling `bitvec` SIMD routines.
 *
 * Marking `__cpu_model` both `weak` and `hidden`:
 *   1. Resolves `R_X86_64_PC32` locally inside each DSO without GOT/PLT entries.
 *   2. Yields automatically to strong definitions on GCC (`libgcc`) or LLVM
 *      (`libclang_rt.builtins`) toolchains.
 *   3. Safely selects portable baseline code paths (SSE2 on x86_64) when
 *      linked as the fallback.
 */
#if defined(__x86_64__) && (defined(__ELF__) || defined(__linux__))
__attribute__((weak, visibility("hidden"))) struct {
    unsigned int __cpu_vendor;
    unsigned int __cpu_type;
    unsigned int __cpu_subtype;
    unsigned int __cpu_features[4];
} __cpu_model = {0, 0, 0, {0, 0, 0, 0}};
#else
typedef int rules_haskell_rt_shims_nonempty_tu;
#endif
