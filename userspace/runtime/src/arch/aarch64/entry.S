.section .text.entry,"ax"
.balign 16
.global _start
.type _start,%function
_start:
    /* X0/X1/X2 retain trusted launch arguments. The user stack is aligned16. */
    mov x29, xzr
    mov x30, xzr
    bl bedrock_user_main
    brk #0
.size _start, . - _start
.section .note.GNU-stack,"",%progbits
