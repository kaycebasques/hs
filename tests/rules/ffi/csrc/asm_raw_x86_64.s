.text
.globl hs_asm_double
.type hs_asm_double, @function
hs_asm_double:
    leaq (%rdi, %rdi), %rax
    ret
.size hs_asm_double, .-hs_asm_double

.section .note.GNU-stack,"",@progbits
