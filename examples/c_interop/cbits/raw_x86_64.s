.text
.globl raw_asm_mul2
.type raw_asm_mul2, @function
raw_asm_mul2:
    leaq (%rdi, %rdi), %rax
    ret
.size raw_asm_mul2, .-raw_asm_mul2

.section .note.GNU-stack,"",@progbits
