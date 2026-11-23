#ifndef ASM_BIAS
#define ASM_BIAS 5
#endif

.text
.globl inline_asm_bias
.type inline_asm_bias, @function
inline_asm_bias:
#if defined(__x86_64__)
    leaq ASM_BIAS(%rdi), %rax
    ret
#elif defined(__aarch64__)
    add x0, x0, #ASM_BIAS
    ret
#else
#error "Unsupported CPU architecture"
#endif
.size inline_asm_bias, .-inline_asm_bias

.section .note.GNU-stack,"",@progbits
