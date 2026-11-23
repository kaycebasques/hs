.text
.globl hs_asm_double
.type hs_asm_double, @function
hs_asm_double:
    lsl x0, x0, #1
    ret
.size hs_asm_double, .-hs_asm_double

.section .note.GNU-stack,"",@progbits
