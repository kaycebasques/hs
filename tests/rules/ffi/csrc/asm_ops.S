#ifndef ASM_OFFSET
#define ASM_OFFSET 10
#endif

.text
.globl hs_asm_add_offset
.type hs_asm_add_offset, @function
hs_asm_add_offset:
#if defined(__x86_64__)
    leaq ASM_OFFSET(%rdi), %rax
    ret
#elif defined(__aarch64__)
    add x0, x0, #ASM_OFFSET
    ret
#else
#error "Unsupported architecture in asm_ops.S"
#endif
.size hs_asm_add_offset, .-hs_asm_add_offset

.section .note.GNU-stack,"",@progbits
